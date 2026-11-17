//! Lõi Roza: một tài khoản Zalo trên máy. Giữ phiên (cookie + imei, tệp 0600), đăng nhập lại mỗi lần mở, giữ WebSocket (tự nối
//! lại), lưu tin vào SQLite, đẩy sự kiện lên app. Lệnh / sự kiện: docs/FFI.md.

mod media;
mod upload;
mod backup;
mod sync;
mod extras;
pub mod msg;
pub mod store;
pub mod vietqr;

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rz_zalo::listen::{self, WsCmd, WsEvent};
use rz_zalo::login::{self, Credentials, QrEvent};
use rz_zalo::{Api, MsgRef, Quote, Thread};
use serde_json::{json, Value};
use tokio::sync::{mpsc, Notify};

pub use media::Media;
use msg::{n, parse_key, s, thread_key};
use store::Store;
use upload::{FileWait, MediaJob};

/// Đẩy sự kiện lên app (`{"e": tên, …}`).
pub type Emit = Arc<dyn Fn(Value) + Send + Sync>;

pub fn now_ms() -> u64 {
    rz_zalo::now_ms()
}

#[derive(Clone, Debug)]
pub struct Config {
    /// ~/Library/Roza: phiên, cơ sở dữ liệu, nhật ký.
    pub data_dir: PathBuf,
    /// ~/Library/Caches/Roza: ảnh, tệp tải về.
    pub cache_dir: PathBuf,
    /// User agent trình duyệt máy tính giả lập (mặc định Firefox / Windows như zca-js).
    pub user_agent: Option<String>,
}

#[derive(Clone, Debug)]
pub struct CoreError {
    pub code: String,
    pub msg: String,
}

impl CoreError {
    pub fn new(code: &str, msg: impl Into<String>) -> Self {
        Self { code: code.into(), msg: msg.into() }
    }
    pub fn to_json(&self) -> Value {
        json!({"code": self.code, "msg": self.msg})
    }
}

impl From<rz_zalo::Error> for CoreError {
    fn from(e: rz_zalo::Error) -> Self {
        let msg = match (e.code, e.zalo_code) {
            ("NETWORK" | "TIMEOUT", _) => "Không kết nối được máy chủ Zalo. Kiểm tra mạng.".to_string(),
            ("AUTH", _) => "Phiên đăng nhập đã hết hạn. Hãy đăng nhập lại.".to_string(),
            (_, Some(z)) => format!("{} (mã {z})", e.msg),
            _ => e.msg.clone(),
        };
        Self { code: e.code.to_string(), msg }
    }
}

type R<T> = Result<T, CoreError>;

#[derive(Default)]
struct State {
    cred: Option<Credentials>,
    api: Option<Api>,
    me: Value,
    net: &'static str,
    /// Zalo Web đang mở ở nơi khác (WebSocket bị đóng mã 3000) — chờ người dùng bấm «Dùng ở đây».
    duplicate: bool,
    qr: Option<tokio::task::AbortHandle>,
    /// Cuộc trò chuyện đang mở trên màn hình (tin đến thì báo đã xem luôn).
    open_thread: Option<String>,
    dead: bool,
}

pub struct Core {
    cfg: Config,
    emit: Emit,
    store: Mutex<Store>,
    media: Arc<Media>,
    st: Mutex<State>,
    ws_tx: Mutex<Option<mpsc::UnboundedSender<WsCmd>>>,
    wake: Notify,
    last_cid: AtomicU64,
    /// Đã tải lịch sử nhóm từ máy chủ trong phiên chạy này.
    cloud_synced: Mutex<std::collections::HashSet<String>>,
    pending_users: Mutex<std::collections::HashSet<String>>,
    pending_groups: Mutex<std::collections::HashSet<String>>,
    /// Tệp đã tải lên chờ máy chủ báo xong (`file_done` qua WebSocket): mã tệp → đang chờ / địa chỉ đã có.
    files: Mutex<std::collections::HashMap<String, FileWait>>,
    lookup_wake: Notify,
}

fn log_line(dir: &PathBuf, s: &str) {
    use std::io::Write;
    let p = dir.join("core.log");
    if std::fs::metadata(&p).map(|m| m.len() > 1 << 20).unwrap_or(false) {
        let _ = std::fs::remove_file(&p);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&p) {
        let t = now_ms();
        let _ = writeln!(f, "{}.{:03} {s}", t / 1000, t % 1000);
    }
}

impl Core {
    /// Mở lõi: đọc phiên, mở kho, chạy vòng kết nối ở nền (cần đang ở trong runtime tokio). Không đụng mạng lúc gọi.
    pub fn start(cfg: Config, emit: Emit) -> R<Arc<Core>> {
        std::fs::create_dir_all(&cfg.data_dir).map_err(|e| CoreError::new("IO", format!("Tạo thư mục dữ liệu: {e}")))?;
        let _ = std::fs::create_dir_all(&cfg.cache_dir);
        let store = Store::open(&cfg.data_dir.join("roza.db")).map_err(|e| CoreError::new("IO", e))?;
        let cred: Option<Credentials> = std::fs::read(cfg.data_dir.join("session.json")).ok().and_then(|d| serde_json::from_slice(&d).ok());
        let me: Value = store.kv_get("me").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null);
        let core = Arc::new(Core {
            media: Arc::new(Media::new(&cfg.cache_dir)),
            cfg,
            emit,
            store: Mutex::new(store),
            st: Mutex::new(State { cred, me, net: "idle", ..Default::default() }),
            ws_tx: Mutex::new(None),
            wake: Notify::new(),
            last_cid: AtomicU64::new(0),
            cloud_synced: Mutex::new(Default::default()),
            pending_users: Mutex::new(Default::default()),
            pending_groups: Mutex::new(Default::default()),
            files: Mutex::new(Default::default()),
            lookup_wake: Notify::new(),
        });
        core.log("lõi mở");
        tokio::spawn(Arc::clone(&core).run());
        tokio::spawn(Arc::clone(&core).lookup_loop());
        Ok(core)
    }

    fn log(&self, s: &str) {
        log_line(&self.cfg.data_dir, s);
    }

    fn ev(&self, name: &str, mut v: Value) {
        if !v.is_object() {
            v = json!({});
        }
        v["e"] = json!(name);
        (self.emit)(v);
    }

    fn me_uid(&self) -> String {
        let st = self.st.lock().unwrap();
        st.api.as_ref().map(|a| a.info.uid.clone()).or_else(|| st.me.get("uid").and_then(Value::as_str).map(str::to_string)).unwrap_or_default()
    }

    fn api(&self) -> R<Api> {
        let st = self.st.lock().unwrap();
        if st.cred.is_none() {
            return Err(CoreError::new("AUTH", "Chưa đăng nhập."));
        }
        st.api.clone().ok_or_else(|| CoreError::new("NETWORK", "Chưa kết nối được Zalo. Kiểm tra mạng."))
    }

    fn set_net(&self, s: &'static str) {
        let changed = {
            let mut st = self.st.lock().unwrap();
            let c = st.net != s;
            st.net = s;
            c
        };
        if changed {
            self.log(&format!("mạng: {s}"));
            self.ev("net.state", json!({"state": s}));
        }
    }

    fn auth_state(&self) -> Value {
        let st = self.st.lock().unwrap();
        let mut v = json!({"authorized": st.cred.is_some()});
        if !st.me.is_null() {
            v["me"] = st.me.clone();
        }
        if st.dead {
            v["dead"] = json!(true);
        }
        v
    }

    fn save_session(&self, cred: &Credentials) {
        let p = self.cfg.data_dir.join("session.json");
        let tmp = p.with_extension("tmp");
        if std::fs::write(&tmp, serde_json::to_vec(cred).unwrap_or_default()).is_ok() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
            }
            let _ = std::fs::rename(&tmp, &p);
        }
    }

    /// Mã tạm (cliMsgId) tăng dần, theo ms.
    fn next_cid(&self) -> u64 {
        let now = now_ms();
        let mut prev = self.last_cid.load(Ordering::SeqCst);
        loop {
            let next = now.max(prev + 1);
            match self.last_cid.compare_exchange(prev, next, Ordering::SeqCst, Ordering::SeqCst) {
                Ok(_) => return next,
                Err(p) => prev = p,
            }
        }
    }

    // ───── Vòng kết nối ─────

    async fn run(self: Arc<Self>) {
        let mut fails: u32 = 0;
        let mut rotate: usize = 0;
        loop {
            let (has_cred, has_api, dup) = {
                let st = self.st.lock().unwrap();
                (st.cred.is_some(), st.api.is_some(), st.duplicate)
            };
            if !has_cred {
                self.set_net("idle");
                self.ev("auth.state", self.auth_state());
                self.wake.notified().await;
                continue;
            }
            if dup {
                self.set_net("duplicate");
                self.wake.notified().await;
                continue;
            }
            if !has_api {
                self.set_net("connecting");
                match self.login().await {
                    Ok(()) => {
                        fails = 0;
                        tokio::spawn(Arc::clone(&self).refresh_all());
                    }
                    Err(e) if e.code == "AUTH" => {
                        self.session_dead(&e.msg);
                        continue;
                    }
                    Err(e) => {
                        self.log(&format!("đăng nhập lỗi: {} {}", e.code, e.msg));
                        self.set_net("offline");
                        fails += 1;
                        self.backoff(fails).await;
                        continue;
                    }
                }
            }
            // WebSocket
            let api = match self.api() {
                Ok(a) => a,
                Err(_) => continue,
            };
            if api.info.ws_urls.is_empty() {
                self.log("không có địa chỉ WebSocket");
                self.backoff(5).await;
                continue;
            }
            let url = api.info.ws_urls[rotate % api.info.ws_urls.len()].clone();
            self.set_net("connecting");
            let (etx, mut erx) = mpsc::unbounded_channel();
            let (ctx, mut crx) = mpsc::unbounded_channel();
            *self.ws_tx.lock().unwrap() = Some(ctx);
            let info = api.info.clone();
            let http = api.http.clone();
            let emit = Arc::clone(&self.emit);
            let ws = tokio::spawn(async move {
                let hook = move |fd: i64| (emit)(json!({"e": "net.socket", "fd": fd}));
                listen::run(&info, &http, &url, &etx, &mut crx, &hook).await
            });
            let mut old_rounds = 0u32;
            while let Some(e) = erx.recv().await {
                if matches!(e, WsEvent::Ready) {
                    fails = 0;
                }
                self.on_ws(e, &mut old_rounds);
            }
            *self.ws_tx.lock().unwrap() = None;
            let closed = ws.await.ok();
            match closed {
                Some(Ok(c)) => {
                    self.log(&format!("WebSocket đóng: {} {}", c.code, c.reason));
                    if c.code == 3000 {
                        self.st.lock().unwrap().duplicate = true;
                        continue;
                    }
                    if c.code == 1000 && self.st.lock().unwrap().cred.is_none() {
                        continue;
                    }
                    if c.code == 3003 || (!c.was_ready && fails >= 2) {
                        // Bị đá / không mở lại được → đăng nhập lại để lấy khoá + địa chỉ mới
                        self.st.lock().unwrap().api = None;
                    }
                    if !c.was_ready {
                        rotate += 1;
                    }
                }
                Some(Err(e)) => {
                    self.log(&format!("WebSocket lỗi: {e}"));
                    rotate += 1;
                }
                None => {}
            }
            self.set_net("offline");
            fails += 1;
            self.backoff(fails).await;
        }
    }

    async fn backoff(&self, fails: u32) {
        let secs = match fails {
            0 | 1 => 2,
            2 => 5,
            3 => 10,
            4 => 20,
            _ => 45,
        };
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(secs)) => {}
            _ = self.wake.notified() => {}
        }
    }

    async fn login(&self) -> R<()> {
        let mut cred = self.st.lock().unwrap().cred.clone().ok_or_else(|| CoreError::new("AUTH", "Chưa đăng nhập"))?;
        let t = now_ms();
        let r = tokio::time::timeout(Duration::from_secs(60), login::login_cookie(&mut cred)).await;
        let (info, http) = match r {
            Err(_) => return Err(CoreError::new("TIMEOUT", "Hết thời gian đăng nhập")),
            Ok(Err(e)) => return Err(e.into()),
            Ok(Ok(x)) => x,
        };
        self.log(&format!("đăng nhập lại sau {} ms (API {} / {})", now_ms() - t, info.api_type, info.api_version));
        self.save_session(&cred);
        let uid = info.uid.clone();
        {
            let mut st = self.st.lock().unwrap();
            st.cred = Some(cred);
            st.api = Some(Api::new(info, http));
            if st.me.get("uid").and_then(Value::as_str) != Some(uid.as_str()) {
                st.me = json!({"uid": uid});
            }
        }
        self.ev("auth.state", self.auth_state());
        Ok(())
    }

    fn session_dead(&self, why: &str) {
        self.log(&format!("phiên hết hiệu lực: {why}"));
        let p = self.cfg.data_dir.join("session.json");
        let _ = std::fs::rename(&p, self.cfg.data_dir.join(format!("session.dead-{}.json", now_ms() / 1000)));
        {
            let mut st = self.st.lock().unwrap();
            st.cred = None;
            st.api = None;
            st.dead = true;
        }
        self.ev("auth.state", self.auth_state());
    }

    // ───── Sự kiện WebSocket ─────

    fn on_ws(self: &Arc<Self>, e: WsEvent, old_rounds: &mut u32) {
        match e {
            WsEvent::Ready => {
                self.set_net("online");
                let (u, g) = {
                    let st = self.store.lock().unwrap();
                    (st.max_msg_id(false), st.max_msg_id(true))
                };
                self.ws_send(WsCmd::RequestOld { group: false, last_id: u });
                self.ws_send(WsCmd::RequestOld { group: true, last_id: g });
            }
            WsEvent::Messages { group, msgs } => {
                for m in &msgs {
                    self.on_msg(m, group, true);
                }
            }
            WsEvent::OldMessages { group, msgs } => {
                let mut fresh = 0;
                for m in &msgs {
                    if self.on_msg(m, group, false) {
                        fresh += 1;
                    }
                }
                self.log(&format!("đồng bộ {}: {} tin, {} mới", if group { "nhóm" } else { "riêng" }, msgs.len(), fresh));
                self.store.lock().unwrap().kv_set("sync.last", &now_ms().to_string());
                self.ev("sync.done", json!({"group": group, "msgs": msgs.len(), "fresh": fresh}));
                self.ev("threads.changed", json!({}));
                // Còn nữa → xin tiếp (tối đa vài lượt mỗi lần kết nối)
                if fresh > 0 && msgs.len() >= 40 && *old_rounds < 8 {
                    *old_rounds += 1;
                    let last = self.store.lock().unwrap().max_msg_id(group);
                    self.ws_send(WsCmd::RequestOld { group, last_id: last });
                }
                self.lookup_wake.notify_one();
            }
            WsEvent::Typing(acts) => {
                for a in acts {
                    let d = &a["data"];
                    let group = a.get("act").and_then(Value::as_str) == Some("gtyping");
                    let uid = s(d, "uid");
                    let tid = if group { s(d, "gid") } else { uid.clone() };
                    if tid.is_empty() {
                        continue;
                    }
                    let name = self.store.lock().unwrap().user_brief(&uid).0;
                    self.ev("typing", json!({"thread": thread_key(group, &tid), "uid": uid, "name": name}));
                }
            }
            WsEvent::Seen { group, seen, .. } => {
                for x in seen {
                    let (thread, id) = if group { (thread_key(true, &s(&x, "groupId")), s(&x, "msgId")) } else { (thread_key(false, &s(&x, "idTo")), s(&x, "msgId")) };
                    if id.is_empty() {
                        continue;
                    }
                    // «Đã xem» một tin của người khác = chính mình vừa đọc ở điện thoại / PC → bỏ số chưa đọc trên Roza
                    let dto = self.store.lock().unwrap().dto(&thread, &id);
                    if dto.as_ref().map_or(false, |d| d.get("out").and_then(Value::as_bool) == Some(false)) {
                        let ts = dto.as_ref().map(|d| n(d, "ts")).unwrap_or(0);
                        self.store.lock().unwrap().mark_read(&thread, ts);
                        let t = self.store.lock().unwrap().thread(&thread);
                        self.ev("threads.upsert", json!({"threads": [t]}));
                        continue;
                    }
                    self.store.lock().unwrap().set_seen(&thread, &id);
                    let uids = x.get("seenUids").cloned().unwrap_or(json!([]));
                    self.ev("msg.seen", json!({"thread": thread, "id": id, "uids": uids}));
                }
            }
            WsEvent::Reactions { reacts, group_reacts, .. } => {
                for (r, group) in reacts.iter().map(|r| (r, false)).chain(group_reacts.iter().map(|r| (r, true))) {
                    self.on_reaction(r, group);
                }
            }
            WsEvent::Controls(ctrls) => {
                for c in ctrls {
                    let ct = &c["content"];
                    match ct.get("act_type").and_then(Value::as_str) {
                        Some("group") => {
                            let data: Value = match ct.get("data") {
                                Some(Value::String(s)) => serde_json::from_str(s).unwrap_or(Value::Null),
                                Some(v) => v.clone(),
                                None => Value::Null,
                            };
                            let gid = s(&data, "groupId");
                            if !gid.is_empty() {
                                self.pending_groups.lock().unwrap().insert(gid.clone());
                                self.lookup_wake.notify_one();
                                let act = ct.get("act").and_then(Value::as_str).unwrap_or("");
                                self.ev("group.event", json!({"thread": thread_key(true, &gid), "act": act}));
                            }
                        }
                        Some("file_done") => {
                            let data: Value = match ct.get("data") {
                                Some(Value::String(s)) => serde_json::from_str(s).unwrap_or(Value::Null),
                                Some(v) => v.clone(),
                                None => Value::Null,
                            };
                            self.file_done(s(ct, "fileId"), s(&data, "url"));
                        }
                        Some("fr") => {
                            let me = Arc::clone(self);
                            tokio::spawn(async move { me.refresh_friends().await });
                        }
                        _ => {}
                    }
                }
            }
            WsEvent::Duplicate => {
                self.ev("net.state", json!({"state": "duplicate"}));
            }
            WsEvent::Other { .. } => {}
        }
    }

    fn ws_send(&self, c: WsCmd) {
        if let Some(tx) = self.ws_tx.lock().unwrap().as_ref() {
            let _ = tx.send(c);
        }
    }

    /// Một tin từ WebSocket / lịch sử. Trả true nếu là tin mới.
    fn on_msg(self: &Arc<Self>, raw: &Value, group: bool, live: bool) -> bool {
        let me = self.me_uid();
        let Some(norm) = msg::normalize(raw, &me, group) else { return false };
        if let Some((oid, ocid)) = &norm.undo {
            let v = self.store.lock().unwrap().recall(&norm.thread, oid, ocid);
            if let Some(v) = v {
                self.ev("msg.update", json!({"thread": norm.thread, "msg": v}));
                self.ev("threads.upsert", json!({"threads": [self.store.lock().unwrap().thread(&norm.thread)]}));
            }
            return false;
        }
        let (fresh, replaced) = {
            let mut st = self.store.lock().unwrap();
            if !norm.out {
                st.hint_user_name(&norm.from, &s(raw, "dName"));
            }
            st.put_msg2(&norm, raw)
        };
        // Mình nhắn từ điện thoại / PC (cùng tài khoản) → chat đó coi như đã đọc, như app Zalo
        if norm.out && live && fresh {
            self.store.lock().unwrap().mark_read(&norm.thread, norm.ts);
        }
        if fresh && norm.dto.get("kind").and_then(Value::as_str) == Some("sticker") {
            let m = &norm.dto["media"];
            self.remember_sticker(n(m, "id"), n(m, "cat"), n(m, "type"));
        }
        if group {
            let gid = norm.thread[1..].to_string();
            if self.store.lock().unwrap().group_brief(&gid).0.is_empty() {
                self.pending_groups.lock().unwrap().insert(gid);
            }
        } else {
            let uid = norm.thread[1..].to_string();
            if self.store.lock().unwrap().user_brief(&uid).1.is_empty() {
                self.pending_users.lock().unwrap().insert(uid);
            }
        }
        if !norm.out && group && self.store.lock().unwrap().user_brief(&norm.from).1.is_empty() {
            self.pending_users.lock().unwrap().insert(norm.from.clone());
        }
        let open = self.st.lock().unwrap().open_thread.as_deref() == Some(norm.thread.as_str());
        if open && !norm.out {
            self.store.lock().unwrap().mark_read(&norm.thread, norm.ts);
            if live {
                let me2 = Arc::clone(self);
                let t = norm.thread.clone();
                tokio::spawn(async move { me2.send_seen(&t).await });
            }
        }
        if live && (fresh || replaced.is_some()) {
            let mut dto = norm.dto.clone();
            self.store.lock().unwrap().enrich(&mut dto);
            let mut v = json!({"thread": norm.thread, "msg": dto});
            if let Some(old) = &replaced {
                v["old_id"] = json!(old);
            }
            self.ev(if replaced.is_some() { "msg.update" } else { "msg.new" }, v);
            let t = self.store.lock().unwrap().thread(&norm.thread);
            self.ev("threads.upsert", json!({"threads": [t]}));
            if fresh && !norm.out && !open {
                let mentioned = norm.dto.get("mentions").and_then(Value::as_array).map_or(false, |a| a.iter().any(|x| s(x, "uid") == me));
                let unread_total = self.store.lock().unwrap().unread_total();
                let secret = self.store.lock().unwrap().is_secret(&norm.thread);
                self.ev("notify", json!({"thread": norm.thread, "from": norm.from, "name": t["name"], "group": group, "secret": secret,
                                         "sender": s(raw, "dName"), "text": msg::preview(&norm.dto), "muted": t["muted"],
                                         "mentioned": mentioned, "ts": norm.ts, "unread_total": unread_total}));
            }
            self.lookup_wake.notify_one();
        }
        fresh
    }

    fn on_reaction(&self, r: &Value, group: bool) {
        let content: Value = match r.get("content") {
            Some(Value::String(s)) => serde_json::from_str(s).unwrap_or(Value::Null),
            Some(v) => v.clone(),
            None => return,
        };
        let me = self.me_uid();
        let from_raw = s(r, "uidFrom");
        let from = if from_raw == "0" { me.clone() } else { from_raw.clone() };
        let tid = if group || from_raw == "0" { s(r, "idTo") } else { from_raw };
        let thread = thread_key(group, &tid);
        let icon = s(&content, "rIcon");
        let Some(targets) = content.get("rMsg").and_then(Value::as_array) else { return };
        for t in targets {
            let id = s(t, "gMsgID");
            let mut st = self.store.lock().unwrap();
            let Some(mut dto) = st.dto(&thread, &id) else { continue };
            if !dto.get("reacts").map_or(false, Value::is_object) {
                dto["reacts"] = json!({});
            }
            if icon.is_empty() || n(&content, "rType") < 0 {
                if let Some(o) = dto["reacts"].as_object_mut() {
                    o.remove(&from);
                }
            } else {
                dto["reacts"][&from] = json!(icon);
            }
            st.update_dto(&thread, &id, &dto);
            drop(st);
            self.ev("msg.update", json!({"thread": thread, "msg": dto}));
        }
    }

    // ───── Tải thông tin người / nhóm còn thiếu (gộp, ≤ 1 lần / 2 giây) ─────

    async fn lookup_loop(self: Arc<Self>) {
        loop {
            self.lookup_wake.notified().await;
            tokio::time::sleep(Duration::from_millis(1500)).await;
            let Ok(api) = self.api() else { continue };
            let users: Vec<String> = self.pending_users.lock().unwrap().drain().collect();
            let mut changed = false;
            for chunk in users.chunks(50) {
                if let Ok(v) = api.user_info(chunk, 120).await {
                    if let Some(m) = v.get("changed_profiles").and_then(Value::as_object) {
                        let mut st = self.store.lock().unwrap();
                        for (_, u) in m {
                            st.put_user(u, None);
                        }
                        changed = true;
                    }
                }
            }
            let groups: Vec<String> = {
                let mut p = self.pending_groups.lock().unwrap();
                let mut v: Vec<String> = p.drain().collect();
                v.extend(self.store.lock().unwrap().groups_missing());
                v.sort();
                v.dedup();
                v
            };
            for chunk in groups.chunks(50) {
                if let Ok(v) = api.group_info(chunk).await {
                    if let Some(m) = v.get("gridInfoMap").and_then(Value::as_object) {
                        let mut st = self.store.lock().unwrap();
                        for (gid, g) in m {
                            st.put_group(gid, g);
                        }
                        changed = true;
                    }
                }
            }
            if changed {
                self.ev("threads.changed", json!({}));
            }
        }
    }

    // ───── Làm mới danh bạ, nhóm, ghim, tắt tiếng sau khi đăng nhập ─────

    async fn refresh_all(self: Arc<Self>) {
        let Ok(api) = self.api() else { return };
        {
            // Tự sao lưu (nếu bật, bản trước đã quá 24 giờ) — sau khi mở app 30 giây cho đỡ tranh mạng
            let me = Arc::clone(&self);
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(30)).await;
                me.backup_auto().await;
            });
        }
        if let Ok(v) = api.account_info().await {
            let p = v.get("profile").cloned().unwrap_or(v);
            // send2me_id: «Cloud của tôi» (chat với chính mình)
            let me = json!({"uid": api.info.uid, "name": s(&p, "displayName"), "avatar": s(&p, "avatar"), "phone": s(&p, "phoneNumber"),
                            "zname": s(&p, "zaloName"), "username": s(&p, "username"), "cloud": s(&api.info.raw, "send2me_id")});
            self.store.lock().unwrap().kv_set("me", &me.to_string());
            self.st.lock().unwrap().me = me;
            self.ev("auth.state", self.auth_state());
        }
        self.refresh_friends().await;
        self.refresh_groups().await;
        self.sync_hidden().await;
        self.sync_aliases().await;
        {
            // Một lần sau khi cập nhật: đọc lại tin cũ theo loại tin mới nhận ra (danh thiếp, thẻ ngân hàng, nhắc hẹn…)
            let mut st = self.store.lock().unwrap();
            if st.kv_get("renorm").as_deref() != Some("2") {
                let n = st.renormalize(&api.info.uid);
                st.kv_set("renorm", "2");
                drop(st);
                self.log(&format!("đọc lại {n} tin theo loại mới"));
            }
        }
        {
            let missing = self.store.lock().unwrap().thread_users_missing();
            self.pending_users.lock().unwrap().extend(missing);
        }
        if let Ok(v) = api.pinned().await {
            let keys: Vec<String> = v
                .get("conversations")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .map(|k| if k.starts_with('u') || k.starts_with('g') { k.to_string() } else { format!("u{k}") })
                        .collect()
                })
                .unwrap_or_default();
            self.store.lock().unwrap().set_pinned(&keys);
        }
        if let Ok(v) = api.mutes().await {
            let now = (now_ms() / 1000) as i64;
            let mut keys = Vec::new();
            for (field, group) in [("chatEntries", false), ("groupChatEntries", true)] {
                for x in v.get(field).and_then(Value::as_array).cloned().unwrap_or_default() {
                    let dur = n(&x, "duration");
                    let start = n(&x, "startTime");
                    if dur == -1 || start + dur > now {
                        keys.push(thread_key(group, &s(&x, "id")));
                    }
                }
            }
            self.store.lock().unwrap().set_muted(&keys);
        }
        self.ev("threads.changed", json!({}));
        self.ev("contacts.changed", json!({}));
        self.lookup_wake.notify_one();
    }

    /// Tên gợi nhớ từ máy chủ (đồng bộ với Zalo trên điện thoại).
    async fn sync_aliases(&self) {
        let Ok(api) = self.api() else { return };
        let mut items: Vec<(String, String)> = Vec::new();
        for page in 1..=20u32 {
            let v = match api.alias_list(page, 100).await {
                Ok(v) => v,
                Err(e) => {
                    self.log(&format!("tên gợi nhớ lỗi: {e}"));
                    return;  // lỗi giữa chừng: giữ danh sách cũ
                }
            };
            let got = v.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
            for x in &got {
                let (uid, alias) = (s(x, "userId"), s(x, "alias"));
                if !uid.is_empty() && !alias.trim().is_empty() {
                    items.push((uid, alias));
                }
            }
            if got.len() < 100 {
                break;
            }
        }
        self.log(&format!("tên gợi nhớ: {}", items.len()));
        self.store.lock().unwrap().set_aliases(&items);
    }

    /// Đặt (hoặc bỏ, khi `alias` rỗng) tên gợi nhớ cho một người — cả người chưa kết bạn.
    async fn alias_set(&self, uid: &str, alias: &str) -> R<Value> {
        let alias = alias.trim();
        if uid.is_empty() {
            return Err(CoreError::new("BAD_ARGS", "Thiếu người cần đặt tên"));
        }
        if alias.chars().count() > 50 {
            return Err(CoreError::new("BAD_ARGS", "Tên gợi nhớ tối đa 50 ký tự"));
        }
        let api = self.api()?;
        if alias.is_empty() {
            api.alias_remove(uid).await?;
        } else {
            api.alias_set(uid, alias).await?;
        }
        self.store.lock().unwrap().set_alias(uid, alias);
        self.ev("threads.changed", json!({}));
        self.ev("contacts.changed", json!({}));
        Ok(self.store.lock().unwrap().user(uid).unwrap_or(json!({"uid": uid, "name": alias, "alias": alias})))
    }

    /// Trò chuyện ẩn + PIN từ máy chủ (đồng bộ với điện thoại).
    async fn sync_hidden(&self) {
        let Ok(api) = self.api() else { return };
        match api.hidden_list().await {
            Ok(v) => {
                let keys: Vec<String> = v
                    .get("threads")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().map(|t| thread_key(n(t, "is_group") != 0, &s(t, "thread_id"))).collect())
                    .unwrap_or_default();
                let mut st = self.store.lock().unwrap();
                st.set_secret(&keys);
                st.kv_set("hidden.pin", &s(&v, "pin"));
                drop(st);
                self.log(&format!("trò chuyện ẩn: {}", keys.len()));
            }
            Err(e) => self.log(&format!("trò chuyện ẩn lỗi: {e}")),
        }
    }

    async fn refresh_friends(&self) {
        let Ok(api) = self.api() else { return };
        match api.friends(120).await {
            Ok(Value::Array(list)) => {
                let mut st = self.store.lock().unwrap();
                st.clear_friends();
                for u in &list {
                    st.put_user(u, Some(true));
                }
                drop(st);
                self.log(&format!("bạn bè: {}", list.len()));
                self.ev("contacts.changed", json!({}));
            }
            Ok(_) => {}
            Err(e) => self.log(&format!("bạn bè lỗi: {e}")),
        }
    }

    async fn refresh_groups(&self) {
        let Ok(api) = self.api() else { return };
        let Ok(v) = api.groups().await else { return };
        let Some(map) = v.get("gridVerMap").and_then(Value::as_object) else { return };
        let ids: Vec<String> = map.keys().cloned().collect();
        let changed: Vec<String> = {
            let mut st = self.store.lock().unwrap();
            st.set_groups_present(&ids);
            map.iter()
                .filter(|(gid, ver)| st.kv_get(&format!("gver:{gid}")).as_deref() != Some(ver.to_string().as_str()) || st.group_brief(gid).0.is_empty())
                .map(|(g, _)| g.clone())
                .collect()
        };
        for chunk in changed.chunks(50) {
            if let Ok(info) = api.group_info(chunk).await {
                if let Some(m) = info.get("gridInfoMap").and_then(Value::as_object) {
                    let mut st = self.store.lock().unwrap();
                    for (gid, g) in m {
                        st.put_group(gid, g);
                        if let Some(ver) = map.get(gid) {
                            st.kv_set(&format!("gver:{gid}"), &ver.to_string());
                        }
                    }
                }
            }
        }
        self.log(&format!("nhóm: {} ({} cập nhật)", ids.len(), changed.len()));
        self.ev("contacts.changed", json!({}));
    }

    async fn send_seen(&self, thread: &str) {
        let Ok(api) = self.api() else { return };
        let Some((group, id)) = parse_key(thread) else { return };
        let key = format!("seen:{thread}");
        let (msgs, last_ts) = {
            let st = self.store.lock().unwrap();
            let since: i64 = st.kv_get(&key).and_then(|s| s.parse().ok()).unwrap_or(0);
            (st.unseen_incoming(thread, since), since)
        };
        if msgs.is_empty() {
            return;
        }
        let max_ts = msgs.iter().map(|m| n(m, "ts")).max().unwrap_or(last_ts);
        let me = api.info.uid.clone();
        let refs: Vec<MsgRef> = msgs
            .iter()
            .rev()
            .map(|m| MsgRef {
                msg_id: s(m, "msgId"),
                cli_msg_id: s(m, "cliMsgId"),
                uid_from: s(m, "uidFrom"),
                id_to: {
                    let t = s(m, "idTo");
                    if t == "0" { me.clone() } else { t }
                },
                msg_type: s(m, "msgType"),
            })
            .collect();
        let th = if group { Thread::Group } else { Thread::User };
        match api.send_seen(th, id, &refs).await {
            Ok(_) => self.store.lock().unwrap().kv_set(&key, &max_ts.to_string()),
            Err(e) => self.log(&format!("báo đã xem lỗi: {e}")),
        }
    }

    // ───── Lệnh của app ─────

    /// Gọi một lệnh (`docs/FFI.md`).
    pub async fn call(self: &Arc<Self>, method: &str, a: Value) -> R<Value> {
        let gs = |k: &str| a.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let gi = |k: &str, d: i64| a.get(k).and_then(Value::as_i64).unwrap_or(d);
        match method {
            "auth.state" => Ok(self.auth_state()),
            "auth.qrStart" => self.qr_start(),
            "auth.qrCancel" => {
                if let Some(h) = self.st.lock().unwrap().qr.take() {
                    h.abort();
                }
                Ok(json!({}))
            }
            "auth.logout" => self.logout().await,
            "net.state" => Ok(json!({"state": self.st.lock().unwrap().net})),
            "net.check" => {
                // iOS đánh thức app (giữ kết nối 10 phút / socket VoIP có dữ liệu): ping ngay; chưa có kết nối thì nối lại
                if self.ws_tx.lock().unwrap().is_some() {
                    self.ws_send(WsCmd::Ping);
                } else {
                    self.wake.notify_one();
                }
                Ok(json!({"state": self.st.lock().unwrap().net}))
            }
            "net.reconnect" => {
                {
                    let mut st = self.st.lock().unwrap();
                    st.duplicate = false;
                }
                self.ws_send(WsCmd::Close);
                self.wake.notify_one();
                Ok(json!({}))
            }
            "threads.list" => Ok(json!(self.store.lock().unwrap().threads(gi("limit", 300)))),
            "threads.get" => Ok(self.store.lock().unwrap().thread(&gs("thread"))),
            "threads.hide" => {
                self.store.lock().unwrap().set_thread_flag(&gs("thread"), "hidden", 1);
                Ok(json!({}))
            }
            "threads.mute" => {
                let thread = gs("thread");
                let mute = a.get("mute").and_then(Value::as_bool).unwrap_or(true);
                let (group, id) = parse_key(&thread).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
                self.api()?.set_mute(if group { Thread::Group } else { Thread::User }, id, mute, gi("duration", -1)).await?;
                self.store.lock().unwrap().set_thread_flag(&thread, "muted", mute as i64);
                Ok(json!({"muted": mute}))
            }
            "messages.history" => self.history(&gs("thread"), gi("before_ts", 0), gi("limit", 40)).await,
            "messages.open" => {
                let thread = gs("thread");
                let last_ts = self.store.lock().unwrap().thread(&thread)["ts"].as_i64().unwrap_or(now_ms() as i64);
                self.st.lock().unwrap().open_thread = Some(thread.clone());
                self.store.lock().unwrap().mark_read(&thread, last_ts.max(now_ms() as i64));
                let me = Arc::clone(self);
                let t2 = thread.clone();
                tokio::spawn(async move { me.send_seen(&t2).await });
                let t = self.store.lock().unwrap().thread(&thread);
                self.ev("threads.upsert", json!({"threads": [t.clone()]}));
                // Chat 1-1 chưa có thông tin người (vd. mình nhắn trước cho người lạ) → hỏi getUserInfo, có tên thì báo threads.changed
                if let Some(uid) = thread.strip_prefix('u') {
                    if self.store.lock().unwrap().user_brief(uid).1.is_empty() {
                        self.pending_users.lock().unwrap().insert(uid.to_string());
                        self.lookup_wake.notify_one();
                    }
                }
                Ok(t)
            }
            "messages.close" => {
                let mut st = self.st.lock().unwrap();
                if st.open_thread.as_deref() == Some(gs("thread").as_str()) {
                    st.open_thread = None;
                }
                Ok(json!({}))
            }
            "messages.send" => self.send_text(&gs("thread"), &gs("text"), a.get("reply_to").and_then(Value::as_str), a.get("mentions")),
            "messages.retry" => {
                let thread = gs("thread");
                let cid = gs("cid");
                let dto = self.store.lock().unwrap().dto(&thread, &format!("l{cid}"));
                let dto = dto.ok_or_else(|| CoreError::new("NOT_FOUND", "Không còn tin này"))?;
                self.store.lock().unwrap().delete_msg(&thread, &format!("l{cid}"));
                self.ev("msg.delete", json!({"thread": thread, "id": format!("l{cid}")}));
                let reply = dto.pointer("/quote/id").and_then(Value::as_str).map(str::to_string);
                self.send_text(&thread, dto["text"].as_str().unwrap_or(""), reply.as_deref(), None)
            }
            "messages.sendPhoto" | "messages.sendFile" | "messages.sendVideo" | "messages.sendVoice" => {
                let job = match method {
                    "messages.sendPhoto" => MediaJob::Photo { path: gs("path"), w: gi("w", 0) as u32, h: gi("h", 0) as u32 },
                    "messages.sendFile" => MediaJob::File { path: gs("path"), name: gs("name") },
                    "messages.sendVideo" => MediaJob::Video {
                        path: gs("path"),
                        thumb: gs("thumb"),
                        w: gi("w", 0) as u32,
                        h: gi("h", 0) as u32,
                        dur: gi("dur", 0) as u64,
                    },
                    _ => MediaJob::Voice { path: gs("path"), dur: gi("dur", 0) as u64 },
                };
                self.send_media(&gs("thread"), job)
            }
            "messages.sendSticker" => self.send_sticker(&gs("thread"), gi("id", 0), gi("cat", 0), gi("type", 7)),
            "stickers.recent" => {
                let st = self.store.lock().unwrap();
                Ok(st.kv_get("stickers.recent").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(json!([])))
            }
            "stickers.cats" => {
                let st = self.store.lock().unwrap();
                Ok(st.kv_get("stickers.cats").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(json!([])))
            }
            "stickers.search" => self.sticker_search(&gs("q")).await,
            "sticker.info" => self.sticker_info(gi("id", 0)).await,
            "stickers.category" => self.sticker_category(gi("cat", 0)).await,
            "messages.typing" => {
                let thread = gs("thread");
                let (group, id) = parse_key(&thread).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
                self.api()?.send_typing(if group { Thread::Group } else { Thread::User }, id).await?;
                Ok(json!({}))
            }
            "messages.recall" => {
                let thread = gs("thread");
                let id = gs("id");
                let (group, tid) = parse_key(&thread).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
                let raw = self.store.lock().unwrap().raw_msg(&thread, &id).ok_or_else(|| CoreError::new("NOT_FOUND", "Không tìm thấy tin"))?;
                self.api()?.undo(if group { Thread::Group } else { Thread::User }, tid, &id, &s(&raw, "cliMsgId")).await?;
                let v = self.store.lock().unwrap().recall(&thread, &id, "");
                if let Some(v) = &v {
                    self.ev("msg.update", json!({"thread": thread, "msg": v}));
                }
                Ok(v.unwrap_or(Value::Null))
            }
            "messages.delete" => {
                let thread = gs("thread");
                let id = gs("id");
                if !id.starts_with('l') {
                    let (group, tid) = parse_key(&thread).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
                    let raw = self.store.lock().unwrap().raw_msg(&thread, &id);
                    if let Some(raw) = raw {
                        let me = self.me_uid();
                        let from = s(&raw, "uidFrom");
                        let r = MsgRef {
                            msg_id: id.clone(),
                            cli_msg_id: s(&raw, "cliMsgId"),
                            uid_from: if from == "0" { me } else { from },
                            id_to: tid.to_string(),
                            msg_type: s(&raw, "msgType"),
                        };
                        self.api()?.delete_message(if group { Thread::Group } else { Thread::User }, tid, &r, true).await?;
                    }
                }
                self.store.lock().unwrap().delete_msg(&thread, &id);
                self.ev("msg.delete", json!({"thread": thread, "id": id}));
                Ok(json!({}))
            }
            "messages.react" => {
                let thread = gs("thread");
                let id = gs("id");
                let icon = gs("icon");
                let r_type = match icon.as_str() {
                    "/-heart" => 5,
                    "/-strong" => 3,
                    ":>" => 0,
                    ":o" => 32,
                    ":-((" => 2,
                    ":-h" => 20,
                    _ => -1,
                };
                let (group, tid) = parse_key(&thread).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
                let raw = self.store.lock().unwrap().raw_msg(&thread, &id).ok_or_else(|| CoreError::new("NOT_FOUND", "Không tìm thấy tin"))?;
                self.api()?.add_reaction(if group { Thread::Group } else { Thread::User }, tid, &id, &s(&raw, "cliMsgId"), r_type, &icon).await?;
                Ok(json!({}))
            }
            "contacts.list" => Ok(json!(self.store.lock().unwrap().friends())),
            "contacts.refresh" => {
                self.refresh_friends().await;
                Ok(json!(self.store.lock().unwrap().friends()))
            }
            "contacts.find" => {
                let v = self.api()?.find_user(&gs("phone")).await?;
                // Kết quả tìm theo số dùng tên trường khác getUserInfo (uid / display_name / zalo_name) — đổi lại cho put_user,
                // không thì người lạ tìm được không được lưu tên → chat với họ chỉ hiện «Người dùng Zalo»
                let u = json!({"userId": s(&v, "uid"), "displayName": s(&v, "display_name"), "zaloName": s(&v, "zalo_name"),
                               "avatar": s(&v, "avatar"), "phoneNumber": s(&v, "phone_number")});
                self.store.lock().unwrap().put_user(&u, None);
                Ok(json!({"uid": s(&v, "uid"), "name": s(&v, "display_name"), "zname": s(&v, "zalo_name"), "avatar": s(&v, "avatar")}))
            }
            "groups.list" => Ok(json!(self.store.lock().unwrap().groups())),
            "groups.refresh" => {
                self.refresh_groups().await;
                Ok(json!(self.store.lock().unwrap().groups()))
            }
            "user.info" => {
                let uid = gs("uid");
                if let Ok(api) = self.api() {
                    if let Ok(v) = api.user_info(&[uid.clone()], 240).await {
                        if let Some(m) = v.get("changed_profiles").and_then(Value::as_object) {
                            let mut st = self.store.lock().unwrap();
                            for (_, u) in m {
                                st.put_user(u, None);
                            }
                        }
                    }
                }
                self.store.lock().unwrap().user(&uid).ok_or_else(|| CoreError::new("NOT_FOUND", "Không tìm thấy người này"))
            }
            "user.lastOnline" => {
                let v = self.api()?.last_online(&gs("uid")).await?;
                Ok(json!({"last": n(&v, "lastOnline"), "show": v.pointer("/settings/show_online_status").cloned().unwrap_or(json!(true))}))
            }
            "group.info" => {
                let gid = gs("gid");
                if let Ok(api) = self.api() {
                    if let Ok(v) = api.group_info(&[gid.clone()]).await {
                        if let Some(g) = v.get("gridInfoMap").and_then(|m| m.get(&gid)) {
                            self.store.lock().unwrap().put_group(&gid, g);
                        }
                    }
                }
                self.store.lock().unwrap().group(&gid).ok_or_else(|| CoreError::new("NOT_FOUND", "Không tìm thấy nhóm"))
            }
            "media.fetch" => {
                let url = gs("url");
                let kind = a.get("kind").and_then(Value::as_str).unwrap_or("thumb").to_string();
                let hint = gs("ext");
                if a.get("from").and_then(Value::as_str) == Some("backup") {
                    let p = self.fetch_from_backup(&url, &kind, &hint).await?;
                    return Ok(json!({"path": p.to_string_lossy(), "from": "backup"}));
                }
                if let Some(p) = self.media.cached_ext(&url, &kind, &hint) {
                    return Ok(json!({"path": p.to_string_lossy()}));
                }
                let http = self.http()?;
                let t = now_ms();
                match self.media.fetch_ext(&http, &url, &kind, &hint).await {
                    Ok(p) => Ok(json!({"path": p.to_string_lossy()})),
                    Err(e) => {
                        let host = url.split('/').nth(2).unwrap_or("?");
                        self.log(&format!("tải {kind} lỗi sau {} ms ({host}): {}", now_ms() - t, e.msg));
                        // Địa chỉ Zalo hết hạn / lỗi → lấy từ bản sao lưu Telegram nếu tệp đã được chép
                        if self.store.lock().unwrap().media_bk_parts(&url).is_some() {
                            let p = self.fetch_from_backup(&url, &kind, &hint).await?;
                            return Ok(json!({"path": p.to_string_lossy(), "from": "backup"}));
                        }
                        Err(e)
                    }
                }
            }
            "media.cached" => Ok(json!({"path": self.media.cached(&gs("url"), a.get("kind").and_then(Value::as_str).unwrap_or("thumb")).map(|p| p.to_string_lossy().into_owned())})),
            "sticker.url" => self.sticker_url(gi("id", 0)).await,
            "hidden.state" => {
                let st = self.store.lock().unwrap();
                Ok(json!({"has_pin": st.kv_get("hidden.pin").map_or(false, |p| !p.is_empty()), "count": st.secret_threads().len()}))
            }
            "hidden.sync" => {
                self.sync_hidden().await;
                Ok(json!({}))
            }
            "hidden.unlock" => {
                // So MD5(mã) với PIN máy chủ (đồng bộ lúc đăng nhập); đúng → danh sách trò chuyện ẩn
                let pin = gs("pin");
                let want = self.store.lock().unwrap().kv_get("hidden.pin").unwrap_or_default();
                if want.is_empty() || rz_zalo::crypto::md5_hex(pin.as_bytes()) != want {
                    return Err(CoreError::new("PIN", "Mã PIN không đúng"));
                }
                Ok(json!(self.store.lock().unwrap().secret_threads()))
            }
            "hidden.setPin" => {
                let pin = gs("pin");
                if pin.len() != 4 || !pin.chars().all(|c| c.is_ascii_digit()) {
                    return Err(CoreError::new("BAD_ARGS", "Mã PIN gồm 4 chữ số"));
                }
                self.api()?.set_hidden_pin(&pin).await?;
                self.store.lock().unwrap().kv_set("hidden.pin", &rz_zalo::crypto::md5_hex(pin.as_bytes()));
                Ok(json!({}))
            }
            "hidden.set" => {
                let thread = gs("thread");
                let hide = a.get("hidden").and_then(Value::as_bool).unwrap_or(true);
                let (group, tid) = parse_key(&thread).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
                if hide && self.store.lock().unwrap().kv_get("hidden.pin").map_or(true, |p| p.is_empty()) {
                    return Err(CoreError::new("NO_PIN", "Cần đặt mã PIN trước khi ẩn trò chuyện"));
                }
                self.api()?.set_hidden(hide, if group { Thread::Group } else { Thread::User }, &[tid.to_string()]).await?;
                self.store.lock().unwrap().set_secret_one(&thread, hide);
                self.ev("threads.changed", json!({}));
                Ok(json!({"hidden": hide}))
            }
            "alias.set" => self.alias_set(&gs("uid"), &gs("alias")).await,
            "card.send" => self.card_send(&gs("thread"), &gs("uid"), &gs("phone")).await,
            "bank.list" => self.bank_list().await,
            "bank.accounts" => self.bank_accounts().await,
            "bank.addAccount" => self.bank_account_add(gi("bin", 0), &gs("number"), &gs("holder")).await,
            "bank.removeAccount" => self.bank_account_remove(gi("id", 0), a.get("default").and_then(Value::as_bool).unwrap_or(false)).await,
            "bank.resolve" => self.bank_resolve(&gs("thread"), &gs("id")).await,
            "bank.sendCard" => self.bank_send_card(&gs("thread"), gi("bin", 0), &gs("number"), &gs("holder")).await,
            "vietqr.make" => self.vietqr_make(gi("bin", 0), &gs("number"), gi("amount", 0), &gs("note")),
            "map.address" => self.map_address(a.get("lat").and_then(Value::as_f64).unwrap_or(999.0), a.get("lng").and_then(Value::as_f64).unwrap_or(999.0)).await,
            "map.tile" => self.map_tile(gi("z", 0), gi("x", -1), gi("y", -1)).await,
            "reminders.list" => self.reminders_list(&gs("thread")).await,
            "reminders.save" => self.reminder_save(&gs("thread"), &gs("id"), &gs("title"), &gs("emoji"), gi("ts", 0), gi("repeat", 0)).await,
            "reminders.remove" => self.reminder_remove(&gs("thread"), &gs("id")).await,
            "quick.list" => self.quick_list(a.get("refresh").and_then(Value::as_bool).unwrap_or(false)).await,
            "quick.save" => self.quick_save(gi("id", 0), &gs("keyword"), &gs("text")).await,
            "quick.remove" => self.quick_remove(gi("id", 0)).await,
            "tg.save" => Box::pin(self.tg_save(&gs("thread"), &gs("id"))).await,
            "sync.state" => Ok(self.sync_state()),
            "sync.now" => self.sync_now(),
            "sync.groups" => Box::pin(self.sync_groups(gi("max", 300))).await,
            "backup.get" => Ok(self.backup_state()),
            "backup.setToken" => self.backup_set_token(&gs("token")).await,
            "backup.findChat" => self.backup_find_chat().await,
            "backup.setMedia" => Ok(self.backup_set_media(a.get("media").and_then(Value::as_bool).unwrap_or(false))),
            "backup.media" => Box::pin(self.backup_media()).await,
            "backup.testFetch" => self.backup_test_fetch().await,
            "backup.setAuto" => Ok(self.backup_set_auto(a.get("auto").and_then(Value::as_bool).unwrap_or(false))),
            "backup.run" => Box::pin(self.backup_run()).await,
            "backup.restore" => Box::pin(self.backup_restore()).await,
            "cache.usage" => Ok(json!({"bytes": self.media.usage()})),
            "cache.clear" => {
                self.media.clear();
                Ok(json!({"bytes": self.media.usage()}))
            }
            _ => Err(CoreError::new("UNKNOWN_METHOD", format!("Lệnh không có: {method}"))),
        }
    }

    /// HTTP để tải ảnh: của phiên đang mở, hoặc HTTP trống (ảnh CDN không cần cookie) khi chưa đăng nhập.
    fn http(&self) -> R<rz_zalo::http::Http> {
        if let Ok(api) = self.api() {
            return Ok(api.http.clone());
        }
        let ua = self.cfg.user_agent.clone().unwrap_or_else(|| login::DEFAULT_USER_AGENT.to_string());
        rz_zalo::http::Http::new(&ua, Default::default()).map_err(CoreError::from)
    }

    fn qr_start(self: &Arc<Self>) -> R<Value> {
        if let Some(h) = self.st.lock().unwrap().qr.take() {
            h.abort();
        }
        let ua = self.cfg.user_agent.clone().unwrap_or_else(|| login::DEFAULT_USER_AGENT.to_string());
        let me = Arc::clone(self);
        let task = tokio::spawn(async move {
            let (tx, mut rx) = mpsc::unbounded_channel();
            let me2 = Arc::clone(&me);
            let fwd = tokio::spawn(async move {
                use base64::Engine;
                while let Some(e) = rx.recv().await {
                    match e {
                        QrEvent::Generated { image_b64, .. } => {
                            let png = base64::engine::general_purpose::STANDARD.decode(image_b64).unwrap_or_default();
                            let p = me2.cfg.cache_dir.join("login-qr.png");
                            let _ = std::fs::write(&p, &png);
                            me2.ev("auth.qr", json!({"state": "generated", "path": p.to_string_lossy()}));
                        }
                        QrEvent::Scanned { name, avatar } => me2.ev("auth.qr", json!({"state": "scanned", "name": name, "avatar": avatar})),
                        QrEvent::Expired => me2.ev("auth.qr", json!({"state": "expired"})),
                        QrEvent::Declined => me2.ev("auth.qr", json!({"state": "declined"})),
                    }
                }
            });
            let r = login::login_qr(&ua, tx).await;
            let _ = fwd.await;
            match r {
                Ok(cred) => {
                    me.log("đăng nhập QR được");
                    me.save_session(&cred);
                    // Tài khoản khác lần trước → xoá dữ liệu cũ
                    {
                        let mut st = me.st.lock().unwrap();
                        st.cred = Some(cred);
                        st.api = None;
                        st.dead = false;
                        st.duplicate = false;
                    }
                    me.ev("auth.qr", json!({"state": "done"}));
                    me.wake.notify_one();
                }
                Err(e) => {
                    me.log(&format!("đăng nhập QR lỗi: {e}"));
                    let ce: CoreError = e.into();
                    me.ev("auth.qr", json!({"state": "error", "code": ce.code, "msg": ce.msg}));
                }
            }
        });
        self.st.lock().unwrap().qr = Some(task.abort_handle());
        Ok(json!({}))
    }

    async fn logout(&self) -> R<Value> {
        let api = self.st.lock().unwrap().api.clone();
        if let Some(api) = api {
            let _ = tokio::time::timeout(Duration::from_secs(5), api.logout()).await;
        }
        let _ = std::fs::remove_file(self.cfg.data_dir.join("session.json"));
        {
            let mut st = self.st.lock().unwrap();
            st.cred = None;
            st.api = None;
            st.me = Value::Null;
            st.dead = false;
            st.duplicate = false;
            st.open_thread = None;
        }
        self.ws_send(WsCmd::Close);
        self.store.lock().unwrap().wipe();
        self.media.clear();
        self.cloud_synced.lock().unwrap().clear();
        self.wake.notify_one();
        self.ev("auth.state", self.auth_state());
        Ok(json!({}))
    }

    async fn history(&self, thread: &str, before_ts: i64, limit: i64) -> R<Value> {
        let (group, gid) = parse_key(thread).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
        let limit = limit.clamp(1, 200);
        let mut msgs = self.store.lock().unwrap().history_enriched(thread, before_ts, limit);
        let mut more = msgs.len() as i64 >= limit;
        if group {
            // Nhóm có lịch sử trên máy chủ: lần đầu mở trong phiên chạy → lấy mới nhất; cuộn lên hết tin trên máy → lấy cũ hơn
            let first = before_ts == 0 && self.cloud_synced.lock().unwrap().insert(thread.to_string());
            let need_old = before_ts > 0 && (msgs.len() as i64) < limit;
            // Con trỏ trang của máy chủ (lastMsgId + isOld lần trước) — kv "cm:<khoá>"; hết tin thì "end"
            let cursor = self.store.lock().unwrap().kv_get(&format!("cm:{thread}"));
            let ended = need_old && cursor.as_deref() == Some("end");
            if let (true, false, Ok(api)) = (first || need_old, ended, self.api()) {
                let (last, is_old) = match (need_old, cursor.as_deref().and_then(|c| c.split_once('|'))) {
                    (true, Some((id, old))) => (Some(id.to_string()), old == "1"),
                    (true, None) => (self.store.lock().unwrap().oldest_msg_id(thread), false),
                    _ => (None, false),
                };
                match api.group_cloud_messages(gid, last.as_deref(), is_old).await {
                    Ok(v) => {
                        let next = s(&v, "lastMsgId");
                        let cur = if n(&v, "hasMore") == 0 || next.is_empty() { "end".to_string() } else { format!("{next}|{}", n(&v, "isOld")) };
                        self.store.lock().unwrap().kv_set(&format!("cm:{thread}"), &cur);
                        let list = v.get("groupMsgs").and_then(Value::as_array).cloned().unwrap_or_default();
                        self.log(&format!("lịch sử nhóm từ máy chủ: {} tin (hasMore {})", list.len(), n(&v, "hasMore")));
                        let me = api.info.uid.clone();
                        {
                            let mut st = self.store.lock().unwrap();
                            for raw in &list {
                                if let Some(nm) = msg::normalize(raw, &me, true) {
                                    if nm.undo.is_none() {
                                        if !nm.out {
                                            st.hint_user_name(&nm.from, &s(raw, "dName"));
                                        }
                                        st.put_msg(&nm, raw);
                                    }
                                }
                            }
                            // Tin cũ tải về không tính là chưa đọc khi đang mở chat
                            if first {
                                let ts = st.thread(thread)["ts"].as_i64().unwrap_or(0);
                                if self.st.lock().unwrap().open_thread.as_deref() == Some(thread) {
                                    st.mark_read(thread, ts);
                                }
                            }
                        }
                        msgs = self.store.lock().unwrap().history_enriched(thread, before_ts, limit);
                        more = msgs.len() as i64 >= limit || n(&v, "hasMore") != 0;
                    }
                    Err(e) if e.zalo_code == Some(-69) => {
                        self.store.lock().unwrap().kv_set(&format!("cm:{thread}"), "end");
                        more = false;
                    }
                    Err(e) => self.log(&format!("lịch sử nhóm lỗi: {e}")),
                }
            }
        }
        Ok(json!({"msgs": msgs, "more": more}))
    }

    fn send_text(self: &Arc<Self>, thread: &str, text: &str, reply_to: Option<&str>, mentions: Option<&Value>) -> R<Value> {
        let text = text.trim_end().to_string();
        if text.trim().is_empty() {
            return Err(CoreError::new("BAD_ARGS", "Tin nhắn trống"));
        }
        let (group, tid) = parse_key(thread).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
        let tid = tid.to_string();
        let me = self.me_uid();
        let cid = self.next_cid();
        let quote = reply_to.and_then(|id| {
            let raw = self.store.lock().unwrap().raw_msg(thread, id)?;
            let from = s(&raw, "uidFrom");
            Some(Quote {
                uid_from: if from == "0" { me.clone() } else { from },
                msg_id: s(&raw, "msgId"),
                cli_msg_id: s(&raw, "cliMsgId"),
                msg_type: s(&raw, "msgType"),
                ts: n(&raw, "ts"),
                ttl: n(&raw, "ttl"),
                content: raw.get("content").cloned().unwrap_or(Value::Null),
                property_ext: raw.get("propertyExt").cloned().unwrap_or(Value::Null),
            })
        });
        let mentions: Vec<rz_zalo::Mention> = mentions
            .and_then(Value::as_array)
            .map(|a| a.iter().map(|m| rz_zalo::Mention { pos: n(m, "pos") as usize, len: n(m, "len") as usize, uid: s(m, "uid") }).collect())
            .unwrap_or_default();
        let mut dto = json!({"id": format!("l{cid}"), "cid": cid.to_string(), "thread": thread, "from": me, "out": true, "ts": cid,
                             "type": "webchat", "kind": "text", "text": text, "status": "sending"});
        if let Some(q) = &quote {
            let qdto = self.store.lock().unwrap().dto(thread, &q.msg_id);
            let qtext = qdto.as_ref().map(msg::preview).unwrap_or_default();
            let qname = qdto.as_ref().and_then(|d| d.get("name").and_then(Value::as_str).map(str::to_string)).unwrap_or_default();
            dto["quote"] = json!({"from": q.uid_from, "name": qname, "text": qtext, "id": q.msg_id, "cid": q.cli_msg_id});
        }
        self.store.lock().unwrap().put_pending(thread, &cid.to_string(), cid as i64, &me, &dto);
        self.ev("msg.new", json!({"thread": thread, "msg": dto}));
        self.ev("threads.upsert", json!({"threads": [self.store.lock().unwrap().thread(thread)]}));
        let core = Arc::clone(self);
        let thread_s = thread.to_string();
        tokio::spawn(async move {
            let r = match core.api() {
                Ok(api) => api.send_text(if group { Thread::Group } else { Thread::User }, &tid, &text, quote.as_ref(), &mentions, cid).await.map_err(CoreError::from),
                Err(e) => Err(e),
            };
            match r {
                Ok(v) => {
                    let mid = s(&v, "msgId");
                    let upd = core.store.lock().unwrap().confirm_pending(&thread_s, &cid.to_string(), &mid);
                    if let Some(m) = upd {
                        core.ev("msg.update", json!({"thread": thread_s, "msg": m, "old_id": format!("l{cid}")}));
                        core.ev("threads.upsert", json!({"threads": [core.store.lock().unwrap().thread(&thread_s)]}));
                    }
                }
                Err(e) => {
                    core.log(&format!("gửi tin lỗi: {} {}", e.code, e.msg));
                    if let Some(m) = core.store.lock().unwrap().fail_pending(&thread_s, &cid.to_string()) {
                        core.ev("msg.update", json!({"thread": thread_s, "msg": m, "err": e.to_json()}));
                    }
                }
            }
        });
        Ok(dto)
    }

    /// Gửi sticker: hiện ngay bằng tin tạm (như tin chữ), gửi ở nền.
    fn send_sticker(self: &Arc<Self>, thread: &str, id: i64, cat: i64, kind: i64) -> R<Value> {
        let (group, tid) = parse_key(thread).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
        if id <= 0 {
            return Err(CoreError::new("BAD_ARGS", "Thiếu mã sticker"));
        }
        let tid = tid.to_string();
        let me = self.me_uid();
        let cid = self.next_cid();
        let dto = json!({"id": format!("l{cid}"), "cid": cid.to_string(), "thread": thread, "from": me, "out": true, "ts": cid,
                         "type": "chat.sticker", "kind": "sticker", "text": "[Sticker]", "status": "sending",
                         "media": {"id": id, "cat": cat, "type": kind}});
        self.remember_sticker(id, cat, kind);
        self.store.lock().unwrap().put_pending(thread, &cid.to_string(), cid as i64, &me, &dto);
        self.ev("msg.new", json!({"thread": thread, "msg": dto}));
        self.ev("threads.upsert", json!({"threads": [self.store.lock().unwrap().thread(thread)]}));
        let core = Arc::clone(self);
        let thread_s = thread.to_string();
        tokio::spawn(async move {
            let r = match core.api() {
                Ok(api) => api.send_sticker(if group { Thread::Group } else { Thread::User }, &tid, id, cat, kind, cid).await.map_err(CoreError::from),
                Err(e) => Err(e),
            };
            match r {
                Ok(v) => {
                    if let Some(m) = core.store.lock().unwrap().confirm_pending(&thread_s, &cid.to_string(), &s(&v, "msgId")) {
                        core.ev("msg.update", json!({"thread": thread_s, "msg": m, "old_id": format!("l{cid}")}));
                    }
                }
                Err(e) => {
                    core.log(&format!("gửi sticker lỗi: {} {}", e.code, e.msg));
                    if let Some(m) = core.store.lock().unwrap().fail_pending(&thread_s, &cid.to_string()) {
                        core.ev("msg.update", json!({"thread": thread_s, "msg": m, "err": e.to_json()}));
                    }
                }
            }
        });
        Ok(dto)
    }

    /// Nhớ sticker vừa gửi / nhận: «Gần đây» (40) và các bộ đã gặp (12) — Zalo Web không có API «bộ sticker của tôi».
    fn remember_sticker(&self, id: i64, cat: i64, kind: i64) {
        if id <= 0 {
            return;
        }
        let st = self.store.lock().unwrap();
        let mut recent: Vec<Value> = st.kv_get("stickers.recent").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        recent.retain(|x| n(x, "id") != id);
        recent.insert(0, json!({"id": id, "cat": cat, "type": kind}));
        recent.truncate(40);
        st.kv_set("stickers.recent", &Value::Array(recent).to_string());
        if cat > 0 {
            let mut cats: Vec<Value> = st.kv_get("stickers.cats").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
            cats.retain(|x| n(x, "cat") != cat);
            cats.insert(0, json!({"cat": cat, "id": id, "type": kind}));
            cats.truncate(12);
            st.kv_set("stickers.cats", &Value::Array(cats).to_string());
        }
    }

    /// Danh sách sticker (tìm / gợi ý / cả bộ) → `[{id, cat, type, url?}]`; ghi sẵn URL ảnh vào kv nếu có.
    fn sticker_items(&self, list: &[Value]) -> Vec<Value> {
        let st = self.store.lock().unwrap();
        let mut out = Vec::new();
        for x in list {
            let id = if n(x, "sticker_id") > 0 { n(x, "sticker_id") } else { n(x, "id") };
            if id <= 0 {
                continue;
            }
            let cat = if n(x, "cate_id") > 0 { n(x, "cate_id") } else { n(x, "cateId") };
            let url = ["stickerUrl", "stickerWebpUrl", "stickerSpriteUrl"].iter().map(|k| s(x, k)).find(|u| !u.is_empty());
            let mut v = json!({"id": id, "cat": cat, "type": n(x, "type")});
            if let Some(u) = url {
                st.kv_set(&format!("st:{id}"), &u);
                v["url"] = json!(u);
            }
            out.push(v);
        }
        out
    }

    async fn sticker_search(&self, q: &str) -> R<Value> {
        let q = q.trim();
        if q.is_empty() {
            return Ok(json!([]));
        }
        let api = self.api()?;
        let mut items = match api.sticker_search(q).await {
            Ok(Value::Array(a)) => self.sticker_items(&a),
            Ok(v) => self.sticker_items(v.get("stickers").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])),
            Err(e) => {
                self.log(&format!("tìm sticker lỗi: {e}"));
                Vec::new()
            }
        };
        if items.is_empty() {
            if let Ok(v) = api.sticker_suggest(q).await {
                items = self.sticker_items(v.get("sugg_sticker").and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]));
            }
        }
        self.log(&format!("tìm sticker: {} kết quả", items.len()));
        Ok(Value::Array(items))
    }

    /// Chi tiết một sticker: ảnh tĩnh, dải khung (sticker động), WebP, số khung, thời lượng (ms).
    async fn sticker_info(&self, id: i64) -> R<Value> {
        let key = format!("stinfo:{id}");
        if let Some(v) = self.store.lock().unwrap().kv_get(&key).and_then(|s| serde_json::from_str::<Value>(&s).ok()) {
            return Ok(v);
        }
        let v = self.api()?.sticker_detail(id).await?;
        let info = json!({"id": id, "cat": n(&v, "cateId"), "type": n(&v, "type"), "url": s(&v, "stickerUrl"), "sprite": s(&v, "stickerSpriteUrl"),
                          "webp": s(&v, "stickerWebpUrl"), "frames": n(&v, "totalFrames"), "duration": n(&v, "duration")});
        let st = self.store.lock().unwrap();
        st.kv_set(&key, &info.to_string());
        if !s(&info, "url").is_empty() {
            st.kv_set(&format!("st:{id}"), &s(&info, "url"));
        }
        Ok(info)
    }

    async fn sticker_category(&self, cat: i64) -> R<Value> {
        let key = format!("stcat:{cat}");
        if let Some(v) = self.store.lock().unwrap().kv_get(&key).and_then(|s| serde_json::from_str::<Value>(&s).ok()) {
            return Ok(v);
        }
        let v = self.api()?.sticker_category(cat).await?;
        let list = match &v {
            Value::Array(a) => a.clone(),
            other => other.get("stickers").and_then(Value::as_array).cloned().unwrap_or_default(),
        };
        let items = Value::Array(self.sticker_items(&list));
        self.store.lock().unwrap().kv_set(&key, &items.to_string());
        Ok(items)
    }

    /// Ảnh sticker: tĩnh (`url`) + dải khung (`sprite`: PNG ngang, mỗi khung vuông = cao, số khung = rộng / cao). Địa chỉ suy
    /// thẳng từ mã (như `sticker_detail` trả — kiểm 17/11/2026) → khỏi gọi API cho từng sticker trong bảng.
    async fn sticker_url(&self, id: i64) -> R<Value> {
        if id <= 0 {
            return Err(CoreError::new("BAD_ARGS", "Thiếu mã sticker"));
        }
        let url = self
            .store
            .lock()
            .unwrap()
            .kv_get(&format!("st:{id}"))
            .unwrap_or_else(|| format!("https://zalo-api.zadn.vn/api/emoticon/sticker/webpc?eid={id}&size=130"));
        let sprite = format!("https://zalo-api.zadn.vn/api/emoticon/sprite?eid={id}&size=130");
        // Nhịp khung (ms): từ chi tiết đã đệm nếu có
        let info: Option<Value> = self.store.lock().unwrap().kv_get(&format!("stinfo:{id}")).and_then(|s| serde_json::from_str(&s).ok());
        let mut v = json!({"url": url, "sprite": sprite});
        if let Some(i) = info {
            v["frames"] = json!(n(&i, "frames"));
            v["duration"] = json!(n(&i, "duration"));
        }
        Ok(v)
    }
}
