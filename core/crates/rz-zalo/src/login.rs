//! Đăng nhập Zalo Web (chuyển từ zca-js `apis/loginQR.ts`, `apis/login.ts`, `apiVersion.ts`, `zalo.ts`).
//!
//! 1. **QR**: id.zalo.me sinh mã QR → người dùng quét bằng app Zalo trên điện thoại khác → xác nhận → có cookie của tài khoản.
//! 2. **Phiên** (mỗi lần mở app): cookie + imei + user agent → `getLoginInfo` (tham số mã hoá bằng `ParamsEncryptor`) → khoá phiên
//!    `zpw_enk`, uid, bản đồ máy chủ dịch vụ, địa chỉ WebSocket; `getServerInfo` → cài đặt (ping, cỡ tệp…).

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::mpsc;

use crate::cookies::CookieJar;
use crate::crypto::{self, ParamsEncryptor};
use crate::http::{make_url, Http};
use crate::{now_ms, Error};

/// API type / version mặc định (zca-js `DEFAULT_API_TYPE` / `DEFAULT_API_VERSION`) — dùng khi không đọc được từ chat.zalo.me.
pub const DEFAULT_API_TYPE: u32 = 30;
pub const DEFAULT_API_VERSION: u32 = 695;

/// User agent mặc định: Zalo Web chỉ nhận trình duyệt máy tính (zca-js dùng Firefox trên Windows).
pub const DEFAULT_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0";

/// Thông tin cần để đăng nhập lại không phải quét QR (lưu ra tệp phiên 0600).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Credentials {
    pub imei: String,
    pub user_agent: String,
    #[serde(default = "vi")]
    pub language: String,
    pub cookies: CookieJar,
    #[serde(default)]
    pub api_type: Option<u32>,
    #[serde(default)]
    pub api_version: Option<u32>,
    /// Lần đọc phiên bản API gần nhất (ms) — đọc lại sau 3 ngày.
    #[serde(default)]
    pub api_checked_ms: u64,
}

fn vi() -> String {
    "vi".into()
}

/// Kết quả đăng nhập: đủ để gọi API và mở WebSocket.
#[derive(Clone, Debug)]
pub struct LoginInfo {
    pub uid: String,
    /// Khoá phiên (base64) mã hoá tham số / kết quả API.
    pub secret_key: String,
    pub imei: String,
    pub api_type: u32,
    pub api_version: u32,
    /// `zpw_service_map_v3`: tên dịch vụ → danh sách máy chủ.
    pub service_map: Value,
    pub ws_urls: Vec<String>,
    /// Cài đặt của máy chủ (`settings` / `setttings`).
    pub settings: Value,
    pub extra_ver: Value,
    /// Nguyên dữ liệu getLoginInfo (tên, ảnh… nếu có).
    pub raw: Value,
}

impl LoginInfo {
    /// Máy chủ đầu tiên của một dịch vụ.
    pub fn service(&self, name: &str) -> Option<String> {
        self.service_map.get(name)?.get(0)?.as_str().map(str::to_string)
    }
    pub fn ping_interval_ms(&self) -> u64 {
        self.settings
            .pointer("/features/socket/ping_interval")
            .and_then(Value::as_u64)
            .filter(|&v| v >= 5_000)
            .unwrap_or(20_000)
    }
}

/// Sự kiện trong lúc đăng nhập bằng QR.
#[derive(Clone, Debug)]
pub enum QrEvent {
    /// Ảnh QR (PNG, base64 — không có tiền tố data:) + mã.
    Generated { image_b64: String, code: String },
    /// Đã quét trên điện thoại, chờ xác nhận.
    Scanned { name: String, avatar: String },
    Expired,
    Declined,
}

fn login_page_headers() -> Vec<(&'static str, String)> {
    vec![
        ("accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".into()),
        ("accept-language", "vi-VN,vi;q=0.9,en-US;q=0.6,en;q=0.5".into()),
        ("referer", "https://chat.zalo.me/".into()),
    ]
}

fn id_headers(referer: &str) -> Vec<(&'static str, String)> {
    vec![
        ("accept", "*/*".into()),
        ("accept-language", "vi-VN,vi;q=0.9,en-US;q=0.6,en;q=0.5".into()),
        ("referer", referer.into()),
    ]
}

const REF_PC: &str = "https://id.zalo.me/account?continue=https%3A%2F%2Fzalo.me%2Fpc";
const REF_CHAT: &str = "https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F";

fn f(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

/// Đăng nhập bằng QR. Gửi các bước qua `events`; trả về cookie của tài khoản (chưa gọi getLoginInfo). Mã hết hạn sau 100 giây
/// → báo `Expired` rồi trả lỗi `QR_EXPIRED` (app hỏi «Lấy mã mới»).
pub async fn login_qr(user_agent: &str, events: mpsc::UnboundedSender<QrEvent>) -> Result<Credentials, Error> {
    let http = Http::new(user_agent, CookieJar::default())?;
    let page = http.get("https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F", &login_page_headers()).await?;
    let html = page.text();
    let re = regex_lite::Regex::new(r"https://stc-zlogin\.zdn\.vn/main-([\d.]+)\.js").unwrap();
    let version = re
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .ok_or_else(|| Error::protocol("Không đọc được phiên bản trang đăng nhập Zalo"))?;

    let _ = http.post_form("https://id.zalo.me/account/logininfo", &id_headers(REF_PC), f(&[("continue", "https://zalo.me/pc"), ("v", &version)])).await?;
    let _ = http
        .post_form("https://id.zalo.me/account/verify-client", &id_headers(REF_PC), f(&[("type", "device"), ("continue", "https://zalo.me/pc"), ("v", &version)]))
        .await?;
    let gen = http
        .post_form("https://id.zalo.me/account/authen/qr/generate", &id_headers(REF_PC), f(&[("continue", "https://zalo.me/pc"), ("v", &version)]))
        .await?
        .json()?;
    let data = gen.get("data").filter(|d| d.is_object()).ok_or_else(|| {
        Error::protocol(format!("Không tạo được mã QR: {}", gen.get("error_message").and_then(Value::as_str).unwrap_or("?")))
    })?;
    let code = data.get("code").and_then(Value::as_str).unwrap_or("").to_string();
    let image = data.get("image").and_then(Value::as_str).unwrap_or("");
    let image_b64 = image.trim_start_matches("data:image/png;base64,").to_string();
    let _ = events.send(QrEvent::Generated { image_b64, code: code.clone() });

    let deadline = tokio::time::Instant::now() + Duration::from_secs(100);
    let wait = async {
        // Chờ quét (máy chủ giữ yêu cầu; error_code 8 = chưa có gì, hỏi lại)
        let scan = poll_until(&http, "https://id.zalo.me/account/authen/qr/waiting-scan", f(&[("code", &code), ("continue", "https://chat.zalo.me/"), ("v", &version)])).await?;
        let sd = scan.get("data").cloned().unwrap_or(Value::Null);
        if !sd.is_object() {
            return Err(Error::protocol(format!("Quét QR: {}", scan.get("error_message").and_then(Value::as_str).unwrap_or("không rõ"))));
        }
        let _ = events.send(QrEvent::Scanned {
            name: sd.get("display_name").and_then(Value::as_str).unwrap_or("").into(),
            avatar: sd.get("avatar").and_then(Value::as_str).unwrap_or("").into(),
        });
        let confirm = poll_until(
            &http,
            "https://id.zalo.me/account/authen/qr/waiting-confirm",
            f(&[("code", &code), ("gToken", ""), ("gAction", "CONFIRM_QR"), ("continue", "https://chat.zalo.me/"), ("v", &version)]),
        )
        .await?;
        Ok::<Value, Error>(confirm)
    };
    let confirm = match tokio::time::timeout_at(deadline, wait).await {
        Ok(r) => r?,
        Err(_) => {
            let _ = events.send(QrEvent::Expired);
            return Err(Error::new("QR_EXPIRED", "Mã QR đã hết hạn"));
        }
    };
    let ec = confirm.get("error_code").and_then(Value::as_i64).unwrap_or(-1);
    if ec == -13 {
        let _ = events.send(QrEvent::Declined);
        return Err(Error::new("QR_DECLINED", "Đăng nhập bị từ chối trên điện thoại"));
    }
    if ec != 0 {
        return Err(Error::zalo(ec, confirm.get("error_message").and_then(Value::as_str).unwrap_or("Xác nhận QR thất bại")));
    }
    // Lấy cookie phiên của chat.zalo.me (đi qua chuyển hướng)
    let _ = http.get("https://id.zalo.me/account/checksession?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html", &login_page_headers()).await?;
    let ui = http.get("https://jr.chat.zalo.me/jr/userinfo", &id_headers("https://chat.zalo.me/")).await?.json()?;
    if ui.pointer("/data/logged").and_then(Value::as_bool) != Some(true) {
        return Err(Error::auth("Zalo chưa nhận phiên đăng nhập"));
    }
    let mut jar = http.jar_snapshot();
    jar.purge();
    Ok(Credentials {
        imei: crypto::zalo_uuid(user_agent),
        user_agent: user_agent.to_string(),
        language: "vi".into(),
        cookies: jar,
        api_type: None,
        api_version: None,
        api_checked_ms: 0,
    })
}

async fn poll_until(http: &Http, url: &str, form: Vec<(String, String)>) -> Result<Value, Error> {
    loop {
        let r = http
            .request(reqwest::Method::POST, url, &id_headers(REF_CHAT), crate::http::Body::Form(form.clone()), Some(Duration::from_secs(70)))
            .await;
        let v = match r {
            Ok(r) => r.json()?,
            Err(e) if e.code == "TIMEOUT" => continue,
            Err(e) => return Err(e),
        };
        if v.get("error_code").and_then(Value::as_i64) == Some(8) {
            continue;
        }
        return Ok(v);
    }
}

/// Đọc API type / version Zalo Web đang dùng (tải trang chat.zalo.me rồi gói JS cấu hình). Không được thì None.
pub async fn fetch_api_version(http: &Http) -> Option<(u32, u32)> {
    let html = http.get("https://chat.zalo.me/", &login_page_headers()).await.ok()?.text();
    let bundle = regex_lite::Regex::new(r#"__ZaBUNDLENAME__\s*=\s*['"](\w+)['"]"#)
        .unwrap()
        .captures(&html)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| "WEB".into());
    let re = regex_lite::Regex::new(r#"<script[^>]+src=["']([^"']+\.js)["']"#).unwrap();
    let base = url::Url::parse("https://chat.zalo.me/").ok()?;
    let mut urls: Vec<String> = re
        .captures_iter(&html)
        .filter_map(|c| base.join(c.get(1)?.as_str()).ok())
        .filter(|u| u.host_str().map_or(false, |h| h.starts_with("zalo-chat-static.")))
        .map(|u| u.to_string())
        .collect();
    // Cấu hình hiện nằm ở default-embed-render.<hash>.js → thử trước
    urls.sort_by_key(|u| !u.contains("/default-embed-render."));
    let ver_re = regex_lite::Regex::new(r"\bapiVersion:(\d+)").unwrap();
    let type_re = regex_lite::Regex::new(r#"\bapiType:(?:"embed"===__ZaBUNDLENAME__\?(\d+):(\d+)|(\d+))"#).unwrap();
    for u in urls.iter().take(6) {
        let Ok(r) = http.get(u, &[("accept", "*/*".into())]).await else { continue };
        let s = r.text();
        let (Some(v), Some(t)) = (ver_re.captures(&s), type_re.captures(&s)) else { continue };
        let ver: u32 = v.get(1)?.as_str().parse().ok()?;
        let ty: u32 = match (t.get(1), t.get(2), t.get(3)) {
            (_, _, Some(lit)) => lit.as_str().parse().ok()?,
            (Some(e), Some(d), _) => if bundle.eq_ignore_ascii_case("embed") { e } else { d }.as_str().parse().ok()?,
            _ => continue,
        };
        if ver > 0 && ty > 0 {
            return Some((ty, ver));
        }
    }
    None
}

/// Đăng nhập bằng cookie (mỗi lần mở app). Cập nhật `cred` (cookie mới, phiên bản API) — người gọi lưu lại.
pub async fn login_cookie(cred: &mut Credentials) -> Result<(LoginInfo, Http), Error> {
    let http = Http::new(&cred.user_agent, cred.cookies.clone())?;
    let now = now_ms();
    if cred.api_type.is_none() || cred.api_version.is_none() || now.saturating_sub(cred.api_checked_ms) > 3 * 86_400_000 {
        if let Ok(Some((t, v))) = tokio::time::timeout(Duration::from_secs(25), fetch_api_version(&http)).await {
            cred.api_type = Some(t);
            cred.api_version = Some(v);
            cred.api_checked_ms = now;
        }
    }
    let api_type = cred.api_type.unwrap_or(DEFAULT_API_TYPE);
    let api_version = cred.api_version.unwrap_or(DEFAULT_API_VERSION);

    // getLoginInfo: tham số mã hoá bằng khoá suy từ zcid
    let enc = ParamsEncryptor::new(api_type, &cred.imei, now)?;
    let data = json!({"computer_name": "Web", "imei": cred.imei, "language": cred.language, "ts": now}).to_string();
    let enc_data = enc.encode(&data)?;
    let mut params: Vec<(&str, String)> = vec![
        ("zcid", enc.zcid.clone()),
        ("zcid_ext", enc.zcid_ext.clone()),
        ("enc_ver", "v2".into()),
        ("params", enc_data),
        ("type", api_type.to_string()),
        ("client_version", api_version.to_string()),
    ];
    let sign = crypto::sign_key("getlogininfo", &params);
    params.push(("signkey", sign));
    params.push(("nretry", "0".into()));
    let url = make_url("https://wpa.chat.zalo.me/api/login/getLoginInfo", &params, Some((api_type, api_version)));
    let r = http.get(&url, &http.api_headers()).await?;
    if !r.ok() {
        return Err(Error::network(format!("getLoginInfo: HTTP {}", r.status)));
    }
    let v = r.json()?;
    let ec = v.get("error_code").and_then(Value::as_i64).unwrap_or(0);
    let enc_resp = v.get("data").and_then(Value::as_str);
    let Some(enc_resp) = enc_resp else {
        let msg = v.get("error_message").and_then(Value::as_str).unwrap_or("Phiên đăng nhập không còn hiệu lực");
        return Err(if ec != 0 { Error::zalo(ec, msg) } else { Error::auth(msg) });
    };
    let dec: Value = serde_json::from_str(&crypto::decode_aes_str_key(&enc.encrypt_key, enc_resp)?)
        .map_err(|_| Error::protocol("getLoginInfo: kết quả không phải JSON"))?;
    let dec_ec = dec.get("error_code").and_then(Value::as_i64).unwrap_or(0);
    let info = dec.get("data").cloned().unwrap_or(Value::Null);
    let secret = info.get("zpw_enk").and_then(Value::as_str).unwrap_or("").to_string();
    let uid = info.get("uid").map(|u| match u {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    });
    if dec_ec != 0 || secret.is_empty() || uid.is_none() {
        let msg = dec.get("error_message").and_then(Value::as_str).unwrap_or("Phiên đăng nhập không còn hiệu lực");
        return Err(if dec_ec != 0 { Error::zalo(dec_ec, msg) } else { Error::auth(msg) });
    }

    // getServerInfo: không mã hoá, chỉ ký
    let si_params: Vec<(&str, String)> = vec![
        ("imei", cred.imei.clone()),
        ("type", api_type.to_string()),
        ("client_version", api_version.to_string()),
        ("computer_name", "Web".into()),
    ];
    let mut si_url_params = si_params.clone();
    si_url_params.push(("signkey", crypto::sign_key("getserverinfo", &si_params)));
    let url = make_url("https://wpa.chat.zalo.me/api/login/getServerInfo", &si_url_params, None);
    let si = http.get(&url, &http.api_headers()).await?.json()?;
    let sd = si.get("data").cloned().filter(|d| d.is_object()).ok_or_else(|| {
        Error::protocol(format!("getServerInfo: {}", si.get("error_message").and_then(Value::as_str).unwrap_or("không có dữ liệu")))
    })?;
    let settings = sd.get("setttings").or_else(|| sd.get("settings")).cloned().unwrap_or(Value::Null);

    let ws_urls = info
        .get("zpw_ws")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();
    let mut jar = http.jar_snapshot();
    jar.purge();
    cred.cookies = jar;
    Ok((
        LoginInfo {
            uid: uid.unwrap(),
            secret_key: secret,
            imei: cred.imei.clone(),
            api_type,
            api_version,
            service_map: info.get("zpw_service_map_v3").cloned().unwrap_or(Value::Null),
            ws_urls,
            settings,
            extra_ver: sd.get("extra_ver").cloned().unwrap_or(Value::Null),
            raw: info,
        },
        http,
    ))
}
