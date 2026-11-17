//! API C của lõi Roza cho app iOS (Objective-C). Mọi thứ đi bằng JSON — xem docs/FFI.md.
//!
//! ```c
//! typedef void (*rz_cb)(const char *json, void *ctx);
//! int  rz_init(const char *config_json, rz_cb on_event, void *ctx);   // 0 = được
//! void rz_call(const char *request_json, rz_cb on_result, void *ctx); // chạy nền, kết quả qua on_result (một lần)
//! ```
//!
//! Callback chạy trên luồng của lõi; chuỗi JSON chỉ dùng được trong lúc gọi (app chép ra rồi chuyển về luồng chính).

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use rz_core::{Config, Core, CoreError};
use serde_json::{json, Value};

pub type Callback = extern "C" fn(json: *const c_char, ctx: *mut c_void);

#[derive(Clone, Copy)]
struct Cb {
    f: Callback,
    ctx: usize,
}

impl Cb {
    fn send(&self, v: &Value) {
        if let Ok(s) = CString::new(v.to_string()) {
            (self.f)(s.as_ptr(), self.ctx as *mut c_void);
        }
    }
}

static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static CORE: OnceLock<Arc<Core>> = OnceLock::new();

fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

/// Mở lõi. `config_json`: `{"data_dir", "cache_dir", "user_agent"?}`. Trả 0 nếu được, 1 nếu cấu hình sai, 3 nếu không mở được
/// dữ liệu, 4 nếu đã mở rồi.
#[unsafe(no_mangle)]
pub extern "C" fn rz_init(config_json: *const c_char, on_event: Callback, ctx: *mut c_void) -> c_int {
    if CORE.get().is_some() {
        return 4;
    }
    let Ok(cfg) = serde_json::from_str::<Value>(&cstr(config_json)) else { return 1 };
    let s = |k: &str| cfg.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let data_dir = PathBuf::from(s("data_dir"));
    if data_dir.as_os_str().is_empty() {
        return 1;
    }
    let cache_dir = match s("cache_dir") {
        c if c.is_empty() => data_dir.join("cache"),
        c => PathBuf::from(c),
    };
    let ua = s("user_agent");
    let config = Config { data_dir, cache_dir, user_agent: if ua.is_empty() { None } else { Some(ua) } };
    let rt = RT.get_or_init(|| {
        // Một luồng làm việc là đủ (A4 một nhân); DNS chạy ở luồng blocking riêng
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("rz-core")
            .thread_stack_size(2 << 20)
            .enable_all()
            .build()
            .expect("tokio runtime")
    });
    let cb = Cb { f: on_event, ctx: ctx as usize };
    let emit: rz_core::Emit = Arc::new(move |v| cb.send(&v));
    let _guard = rt.enter();
    match Core::start(config, emit) {
        Ok(core) => {
            let _ = CORE.set(core);
            0
        }
        Err(_) => 3,
    }
}

/// Gọi một lệnh: `{"m": "<nhóm.lệnh>", "a": {…}}`. Kết quả (một lần, trên luồng của lõi): `{"ok": <giá trị>}` hoặc
/// `{"err": {"code", "msg"}}`.
#[unsafe(no_mangle)]
pub extern "C" fn rz_call(request_json: *const c_char, on_result: Callback, ctx: *mut c_void) {
    let cb = Cb { f: on_result, ctx: ctx as usize };
    let req = cstr(request_json);
    let (Some(rt), Some(core)) = (RT.get(), CORE.get()) else {
        cb.send(&json!({"err": CoreError::new("NOT_STARTED", "Lõi chưa mở.").to_json()}));
        return;
    };
    let core = Arc::clone(core);
    rt.spawn(async move {
        let v: Value = serde_json::from_str(&req).unwrap_or(Value::Null);
        let method = v.get("m").and_then(Value::as_str).unwrap_or("").to_string();
        let args = v.get("a").cloned().unwrap_or(json!({}));
        // Trên heap: khối trạng thái của `call` lớn (GramMini D20 — luồng tokio trên iOS chỉ 2 MB)
        let out = match Box::pin(core.call(&method, args)).await {
            Ok(r) => json!({"ok": r}),
            Err(e) => json!({"err": e.to_json()}),
        };
        cb.send(&out);
    });
}
