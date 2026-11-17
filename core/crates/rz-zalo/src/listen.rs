//! Kết nối WebSocket nhận tin (chuyển từ zca-js `apis/listen.ts`, MIT).
//!
//! Khung nhị phân: `[version u8][cmd u16 LE][subCmd u8]` + JSON. Lúc mở, máy chủ gửi (1, 1, 1) kèm `key` (cipher key AES-GCM
//! cho dữ liệu sự kiện) → bắt đầu ping (1, 2, 1) theo `ping_interval` của máy chủ. Một hàm `run` = một kết nối; lõi tự nối lại
//! (đợi theo `retries`, đổi máy chủ theo `rotate_error_codes`).

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_rustls::rustls;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::Message;

use crate::crypto::decode_event_data;
use crate::http::{make_url, Http};
use crate::login::LoginInfo;
use crate::{now_ms, Error};

/// Sự kiện từ WebSocket (dữ liệu đã giải mã, chưa đổi kiểu — lõi tự đọc).
#[derive(Debug, Clone)]
pub enum WsEvent {
    /// Đã mở và nhận cipher key.
    Ready,
    /// Tin mới: `group` = tin nhóm (cmd 521); tin riêng (501 / 551). Có cả tin thu hồi (`content.deleteMsg`).
    Messages { group: bool, msgs: Vec<Value> },
    /// Tin cũ trả lời `request_old` (510 / 511).
    OldMessages { group: bool, msgs: Vec<Value> },
    /// Sự kiện điều khiển (601): tải tệp xong, sự kiện nhóm, sự kiện bạn bè.
    Controls(Vec<Value>),
    /// Cảm xúc (612) mới; `old` = 610 / 611.
    Reactions { reacts: Vec<Value>, group_reacts: Vec<Value>, old: bool },
    /// Đang soạn tin (602): `[{act: typing|gtyping, data}]` (data đã đọc thành đối tượng).
    Typing(Vec<Value>),
    /// Đã nhận / đã xem: chat riêng (502) / nhóm (522).
    Seen { group: bool, delivered: Vec<Value>, seen: Vec<Value> },
    /// Máy chủ báo có kết nối khác (Zalo Web mở ở nơi khác) — kết nối này bị đóng.
    Duplicate,
    /// Khung chưa xử lý (để ghi nhật ký).
    Other { cmd: u16, sub: u8 },
}

/// Lệnh gửi vào kết nối đang mở.
#[derive(Debug)]
pub enum WsCmd {
    /// Xin tin cũ (đồng bộ lúc mở): `last_id` = tin mới nhất đã có (None = từ đầu cửa sổ của máy chủ).
    RequestOld { group: bool, last_id: Option<String> },
    RequestOldReactions { group: bool, last_id: Option<String> },
    /// Gửi ping ngay (app vừa được iOS đánh thức / giữ kết nối 10 phút): socket chết thì lỗi → đóng → lõi nối lại.
    Ping,
    Close,
}

/// Kết nối đóng: mã đóng của WebSocket (1000 tự đóng, 1006 rớt mạng, 3000 trùng kết nối, 3003 bị đá) + lý do.
#[derive(Debug, Clone)]
pub struct Closed {
    pub code: u16,
    pub reason: String,
    /// Đã từng mở được (nhận cipher key) — để lõi đặt lại bộ đếm thử lại.
    pub was_ready: bool,
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    static CFG: std::sync::OnceLock<Arc<rustls::ClientConfig>> = std::sync::OnceLock::new();
    CFG.get_or_init(|| {
        let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
        let cfg = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .expect("tls versions")
            .with_root_certificates(roots)
            .with_no_client_auth();
        Arc::new(cfg)
    })
    .clone()
}

fn header(version: u8, cmd: u16, sub: u8) -> [u8; 4] {
    let c = cmd.to_le_bytes();
    [version, c[0], c[1], sub]
}

fn frame(cmd: u16, sub: u8, data: &Value) -> Vec<u8> {
    let mut v = header(1, cmd, sub).to_vec();
    v.extend_from_slice(data.to_string().as_bytes());
    v
}

/// Mở một kết nối tới `ws_url` và chạy tới khi đóng. Sự kiện đẩy qua `events`; lệnh nhận từ `cmds`.
/// `on_socket(fd)`: gọi khi đã mở TCP (app iOS bọc socket bằng CFStream VoIP để được đánh thức khi có dữ liệu — GramMini D17).
pub async fn run(
    info: &LoginInfo,
    http: &Http,
    ws_url: &str,
    events: &mpsc::UnboundedSender<WsEvent>,
    cmds: &mut mpsc::UnboundedReceiver<WsCmd>,
    on_socket: &(dyn Fn(i64) + Send + Sync),
) -> Result<Closed, Error> {
    let url = make_url(ws_url, &[("t", now_ms().to_string())], Some((info.api_type, info.api_version)));
    let parsed = url::Url::parse(&url).map_err(|_| Error::protocol("Địa chỉ WebSocket hỏng"))?;
    let host = parsed.host_str().ok_or_else(|| Error::protocol("Địa chỉ WebSocket thiếu máy chủ"))?.to_string();
    let port = parsed.port_or_known_default().unwrap_or(443);

    let mut req = url.as_str().into_client_request().map_err(|e| Error::protocol(format!("WebSocket: {e}")))?;
    {
        let h = req.headers_mut();
        let cookie = http.jar.lock().unwrap().header_for("chat.zalo.me", "/", true);
        let hv = |s: &str| HeaderValue::from_str(s).unwrap_or_else(|_| HeaderValue::from_static(""));
        h.insert("origin", hv("https://chat.zalo.me"));
        h.insert("user-agent", hv(&http.user_agent));
        h.insert("cookie", hv(&cookie));
        h.insert("accept-language", hv("vi-VN,vi;q=0.9,en-US;q=0.6"));
        h.insert("cache-control", hv("no-cache"));
        h.insert("pragma", hv("no-cache"));
    }

    let tcp = tokio::time::timeout(Duration::from_secs(15), TcpStream::connect((host.as_str(), port)))
        .await
        .map_err(|_| Error::new("TIMEOUT", "Hết thời gian kết nối WebSocket"))?
        .map_err(|e| Error::network(format!("WebSocket: {e}")))?;
    let _ = tcp.set_nodelay(true);
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        on_socket(tcp.as_raw_fd() as i64);
    }
    #[cfg(not(unix))]
    let _ = on_socket;
    let name = rustls::pki_types::ServerName::try_from(host.clone()).map_err(|_| Error::protocol("Tên máy chủ WebSocket hỏng"))?;
    let tls = tokio::time::timeout(Duration::from_secs(15), tokio_rustls::TlsConnector::from(tls_config()).connect(name, tcp))
        .await
        .map_err(|_| Error::new("TIMEOUT", "Hết thời gian bắt tay TLS"))?
        .map_err(|e| Error::network(format!("TLS: {e}")))?;
    let (ws, _resp) = tokio::time::timeout(Duration::from_secs(15), tokio_tungstenite::client_async(req, tls))
        .await
        .map_err(|_| Error::new("TIMEOUT", "Hết thời gian mở WebSocket"))?
        .map_err(|e| Error::network(format!("Mở WebSocket: {e}")))?;
    let (mut tx, mut rx) = ws.split();

    let ping_every = Duration::from_millis(info.ping_interval_ms());
    let mut ping = tokio::time::interval_at(tokio::time::Instant::now() + ping_every, ping_every);
    let mut cipher_key: Option<String> = None;
    let mut req_id: u64 = 0;
    let mut ready = false;
    // Không nhận gì trong 3 lần ping → coi như mất kết nối (mạng di động hay «treo» TCP im lặng)
    let mut last_rx = tokio::time::Instant::now();

    loop {
        tokio::select! {
            m = rx.next() => {
                let Some(m) = m else { return Ok(Closed { code: 1006, reason: "đóng".into(), was_ready: ready }) };
                let m = match m {
                    Ok(m) => m,
                    Err(e) => return Ok(Closed { code: 1006, reason: e.to_string(), was_ready: ready }),
                };
                last_rx = tokio::time::Instant::now();
                let data: Vec<u8> = match m {
                    Message::Binary(b) => b.to_vec(),
                    Message::Text(t) => t.as_bytes().to_vec(),
                    Message::Close(c) => {
                        let (code, reason) = c.map(|c| (u16::from(c.code), c.reason.to_string())).unwrap_or((1005, String::new()));
                        return Ok(Closed { code, reason, was_ready: ready });
                    }
                    _ => continue,
                };
                if data.len() < 4 {
                    continue;
                }
                let (version, cmd, sub) = (data[0], u16::from_le_bytes([data[1], data[2]]), data[3]);
                let body = &data[4..];
                if body.is_empty() {
                    continue;
                }
                let Ok(parsed) = serde_json::from_slice::<Value>(body) else { continue };
                if version == 1 && cmd == 1 && sub == 1 {
                    if let Some(k) = parsed.get("key").and_then(Value::as_str) {
                        cipher_key = Some(k.to_string());
                        ready = true;
                        let _ = events.send(WsEvent::Ready);
                    }
                    continue;
                }
                if version == 1 && cmd == 3000 && sub == 0 {
                    let _ = events.send(WsEvent::Duplicate);
                    let _ = tx.send(Message::Close(Some(CloseFrame { code: CloseCode::Library(3000), reason: "".into() }))).await;
                    return Ok(Closed { code: 3000, reason: "Zalo Web đang mở ở nơi khác".into(), was_ready: ready });
                }
                let needs_decode = matches!((cmd, sub), (501 | 551 | 521 | 601 | 602 | 502 | 522, 0) | (510 | 511, 1) | (610 | 611 | 612, _));
                if !needs_decode {
                    let _ = events.send(WsEvent::Other { cmd, sub });
                    continue;
                }
                let d = match decode_event_data(&parsed, cipher_key.as_deref()) {
                    Ok(d) => d.get("data").cloned().unwrap_or(Value::Null),
                    Err(_) => continue,
                };
                let arr = |k: &str| d.get(k).and_then(Value::as_array).cloned().unwrap_or_default();
                let ev = match (cmd, sub) {
                    (501 | 551, 0) => WsEvent::Messages { group: false, msgs: arr("msgs") },
                    (521, 0) => WsEvent::Messages { group: true, msgs: arr("groupMsgs") },
                    (510, 1) => WsEvent::OldMessages { group: false, msgs: arr("msgs") },
                    (511, 1) => WsEvent::OldMessages { group: true, msgs: arr("groupMsgs") },
                    (601, 0) => WsEvent::Controls(arr("controls")),
                    (602, 0) => {
                        let acts = arr("actions")
                            .into_iter()
                            .filter(|a| a.get("act_type").and_then(Value::as_str) == Some("typing"))
                            .map(|a| {
                                let raw = a.get("data").and_then(Value::as_str).unwrap_or("");
                                let data: Value = serde_json::from_str(&format!("{{{raw}}}")).unwrap_or(Value::Null);
                                json!({"act": a.get("act").cloned().unwrap_or(Value::Null), "data": data})
                            })
                            .collect();
                        WsEvent::Typing(acts)
                    }
                    (502, 0) => WsEvent::Seen { group: false, delivered: arr("delivereds"), seen: arr("seens") },
                    (522, 0) => WsEvent::Seen { group: true, delivered: arr("delivereds"), seen: arr("groupSeens") },
                    (612, _) => WsEvent::Reactions { reacts: arr("reacts"), group_reacts: arr("reactGroups"), old: false },
                    (610, _) => WsEvent::Reactions { reacts: arr("reacts"), group_reacts: vec![], old: true },
                    (611, _) => WsEvent::Reactions { reacts: vec![], group_reacts: arr("reactGroups"), old: true },
                    _ => WsEvent::Other { cmd, sub },
                };
                let _ = events.send(ev);
            }
            c = cmds.recv() => {
                match c {
                    None | Some(WsCmd::Close) => {
                        let _ = tx.send(Message::Close(Some(CloseFrame { code: CloseCode::Normal, reason: "".into() }))).await;
                        return Ok(Closed { code: 1000, reason: "đóng".into(), was_ready: ready });
                    }
                    Some(WsCmd::RequestOld { group, last_id }) => {
                        let data = json!({"first": true, "lastId": last_id, "preIds": [], "req_id": format!("req_{req_id}")});
                        req_id += 1;
                        let _ = tx.send(Message::Binary(frame(if group { 511 } else { 510 }, 1, &data).into())).await;
                    }
                    Some(WsCmd::Ping) => {
                        if ready && tx.send(Message::Binary(frame(2, 1, &json!({"eventId": now_ms()})).into())).await.is_err() {
                            return Ok(Closed { code: 1006, reason: "gửi ping lỗi".into(), was_ready: ready });
                        }
                    }
                    Some(WsCmd::RequestOldReactions { group, last_id }) => {
                        let data = json!({"first": true, "lastId": last_id, "preIds": [], "req_id": format!("req_{req_id}")});
                        req_id += 1;
                        let _ = tx.send(Message::Binary(frame(if group { 611 } else { 610 }, 1, &data).into())).await;
                    }
                }
            }
            _ = ping.tick() => {
                if last_rx.elapsed() > ping_every * 3 + Duration::from_secs(10) {
                    return Ok(Closed { code: 1006, reason: "không có phản hồi".into(), was_ready: ready });
                }
                if ready {
                    let data = json!({"eventId": now_ms()});
                    if tx.send(Message::Binary(frame(2, 1, &data).into())).await.is_err() {
                        return Ok(Closed { code: 1006, reason: "gửi ping lỗi".into(), was_ready: ready });
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_layout() {
        assert_eq!(header(1, 510, 1), [1, 0xfe, 0x01, 1]);
        let f = frame(2, 1, &json!({"eventId": 5}));
        assert_eq!(&f[..4], &[1, 2, 0, 1]);
        assert_eq!(&f[4..], br#"{"eventId":5}"#);
    }
}
