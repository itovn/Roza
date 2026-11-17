//! rz-cli — chạy thử lõi Roza trên PC (Windows / Linux) hoặc trên máy iOS qua SSH.
//!
//!   rz-cli qr [tệp.png]          đăng nhập bằng mã QR (quét bằng app Zalo trên điện thoại), lưu phiên vào --session
//!   rz-cli me                    đăng nhập lại bằng phiên đã lưu, in thông tin tài khoản
//!   rz-cli friends | groups      danh sách bạn / nhóm
//!   rz-cli listen [giây]         mở WebSocket, xin tin cũ, in sự kiện (không in nội dung tin — chỉ loại + độ dài)
//!   rz-cli send <uid> <chữ>      gửi tin chữ cho một người (chỉ dùng để thử với tài khoản của chính mình / tài khoản phụ)
//!
//! Tuỳ chọn: --session <tệp> (mặc định keys/rz-session.json). Một phiên chỉ nên dùng ở một nơi — Zalo Web chỉ giữ một kết nối.

use std::path::PathBuf;
use std::time::Duration;

use rz_zalo::listen::{self, WsCmd, WsEvent};
use rz_zalo::login::{self, Credentials, QrEvent};
use rz_zalo::{Api, Thread};
use serde_json::Value;
use tokio::sync::mpsc;

type R<T> = Result<T, Box<dyn std::error::Error>>;

fn session_path(args: &mut Vec<String>) -> PathBuf {
    if let Some(i) = args.iter().position(|a| a == "--session") {
        if i + 1 < args.len() {
            let p = PathBuf::from(args.remove(i + 1));
            args.remove(i);
            return p;
        }
    }
    PathBuf::from("../keys/rz-session.json")
}

fn save(path: &PathBuf, cred: &Credentials) -> R<()> {
    if let Some(d) = path.parent() {
        std::fs::create_dir_all(d)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(cred)?)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

async fn open(path: &PathBuf) -> R<(Api, Credentials)> {
    let mut cred: Credentials = serde_json::from_slice(&std::fs::read(path).map_err(|e| format!("chưa có phiên ({}): {e} — chạy `rz-cli qr` trước", path.display()))?)?;
    let t = std::time::Instant::now();
    let (info, http) = login::login_cookie(&mut cred).await?;
    eprintln!("đăng nhập lại: uid {} — API type {} ver {} — {} ms", info.uid, info.api_type, info.api_version, t.elapsed().as_millis());
    save(path, &cred)?;
    Ok((Api::new(info, http), cred))
}

fn short(v: &Value) -> String {
    let s = v.to_string();
    if s.len() > 300 { format!("{}…", &s[..s.char_indices().nth(300).map(|x| x.0).unwrap_or(s.len())]) } else { s }
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> R<()> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let session = session_path(&mut args);
    let cmd = args.first().cloned().unwrap_or_default();
    match cmd.as_str() {
        "qr" => {
            let out = PathBuf::from(args.get(1).cloned().unwrap_or_else(|| "qr.png".into()));
            let (tx, mut rx) = mpsc::unbounded_channel();
            let out2 = out.clone();
            let printer = tokio::spawn(async move {
                use base64::Engine;
                while let Some(e) = rx.recv().await {
                    match e {
                        QrEvent::Generated { image_b64, .. } => {
                            let png = base64::engine::general_purpose::STANDARD.decode(image_b64).unwrap_or_default();
                            let _ = std::fs::write(&out2, &png);
                            eprintln!("mã QR ({} byte) → {} — mở app Zalo trên điện thoại → Quét mã QR", png.len(), out2.display());
                        }
                        QrEvent::Scanned { name, .. } => eprintln!("đã quét: {name} — xác nhận đăng nhập trên điện thoại"),
                        QrEvent::Expired => eprintln!("mã QR hết hạn"),
                        QrEvent::Declined => eprintln!("đã từ chối trên điện thoại"),
                    }
                }
            });
            let t = std::time::Instant::now();
            let mut cred = login::login_qr(login::DEFAULT_USER_AGENT, tx).await?;
            let _ = printer.await;
            eprintln!("có cookie sau {} s ({} cookie)", t.elapsed().as_secs(), cred.cookies.cookies.len());
            let (info, _http) = login::login_cookie(&mut cred).await?;
            save(&session, &cred)?;
            let _ = std::fs::remove_file(&out);
            eprintln!("đăng nhập được: uid {} — phiên lưu ở {}", info.uid, session.display());
        }
        "me" => {
            let (api, _) = open(&session).await?;
            let me = api.account_info().await?;
            let p = me.get("profile").cloned().unwrap_or(me);
            println!("{} — {}", p.get("displayName").and_then(Value::as_str).unwrap_or("?"), p.get("userId").and_then(Value::as_str).unwrap_or("?"));
            println!("dịch vụ: {}", api.info.service_map.as_object().map(|m| m.keys().cloned().collect::<Vec<_>>().join(", ")).unwrap_or_default());
            println!("websocket: {:?}", api.info.ws_urls);
            println!("ping: {} ms", api.info.ping_interval_ms());
        }
        "friends" => {
            let (api, _) = open(&session).await?;
            let f = api.friends(120).await?;
            let list = f.as_array().cloned().unwrap_or_default();
            println!("{} bạn", list.len());
            for u in list.iter().take(5) {
                println!("  {} {}", u.get("userId").and_then(Value::as_str).unwrap_or("?"), u.get("displayName").and_then(Value::as_str).unwrap_or("?"));
            }
        }
        "groups" => {
            let (api, _) = open(&session).await?;
            let g = api.groups().await?;
            let ids: Vec<String> = g.get("gridVerMap").and_then(Value::as_object).map(|m| m.keys().cloned().collect()).unwrap_or_default();
            println!("{} nhóm", ids.len());
            if !ids.is_empty() {
                let info = api.group_info(&ids[..ids.len().min(5)]).await?;
                for (id, gi) in info.get("gridInfoMap").and_then(Value::as_object).cloned().unwrap_or_default() {
                    println!("  {id} {} ({} thành viên)", gi.get("name").and_then(Value::as_str).unwrap_or("?"), gi.get("totalMember").unwrap_or(&Value::Null));
                }
            }
        }
        "listen" => {
            let secs: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(30);
            let (api, _) = open(&session).await?;
            let (etx, mut erx) = mpsc::unbounded_channel();
            let (ctx, mut crx) = mpsc::unbounded_channel();
            let info = api.info.clone();
            let http = api.http.clone();
            let url = info.ws_urls.first().cloned().ok_or("không có địa chỉ WebSocket")?;
            let ws = tokio::spawn(async move { listen::run(&info, &http, &url, &etx, &mut crx, &|_| {}).await });
            let deadline = tokio::time::Instant::now() + Duration::from_secs(secs);
            loop {
                let e = tokio::select! {
                    e = erx.recv() => e,
                    _ = tokio::time::sleep_until(deadline) => { let _ = ctx.send(WsCmd::Close); break; }
                };
                let Some(e) = e else { break };
                match e {
                    WsEvent::Ready => {
                        eprintln!("WebSocket sẵn sàng — xin tin cũ");
                        let _ = ctx.send(WsCmd::RequestOld { group: false, last_id: None });
                        let _ = ctx.send(WsCmd::RequestOld { group: true, last_id: None });
                    }
                    WsEvent::Messages { group, msgs } | WsEvent::OldMessages { group, msgs } => {
                        eprintln!("{} tin {} ", msgs.len(), if group { "nhóm" } else { "riêng" });
                        for m in msgs.iter().take(3) {
                            let t = m.get("msgType").and_then(Value::as_str).unwrap_or("?");
                            let len = m.get("content").map(|c| c.to_string().len()).unwrap_or(0);
                            eprintln!("   {t} ({len} byte) ts {}", m.get("ts").unwrap_or(&Value::Null));
                        }
                    }
                    other => eprintln!("{}", short(&Value::String(format!("{other:?}")))),
                }
            }
            eprintln!("đóng: {:?}", ws.await?);
        }
        "send" => {
            let (uid, text) = (args.get(1).ok_or("thiếu uid")?, args.get(2).ok_or("thiếu chữ")?);
            let (api, _) = open(&session).await?;
            let r = api.send_text(Thread::User, uid, text, None, &[], rz_zalo::now_ms()).await?;
            println!("{r}");
        }
        _ => {
            eprintln!("rz-cli qr [tệp.png] | me | friends | groups | listen [giây] | send <uid> <chữ>   [--session tệp]");
        }
    }
    Ok(())
}
