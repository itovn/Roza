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
        // ── Thử các API mới (chỉ HTTP, không mở WebSocket nên không đá kết nối của máy đang dùng phiên này) ──
        "cloud" => {
            let (api, _) = open(&session).await?;
            println!("{}", api.info.raw.get("send2me_id").and_then(Value::as_str).unwrap_or("?"));
        }
        "banks" => {
            let (api, _) = open(&session).await?;
            let v = api.bank_list().await?;
            let list = v.get("banks").and_then(Value::as_array).cloned().unwrap_or_default();
            println!("{} ngân hàng; khoá: {:?}", list.len(), v.as_object().map(|m| m.keys().cloned().collect::<Vec<_>>()));
            for b in list.iter().take(4) {
                println!("  {}", short(b));
            }
        }
        "bankcard" => {
            let (to, bin, num, holder) = (args.get(1).ok_or("thiếu uid")?, args.get(2).ok_or("thiếu BIN")?, args.get(3).ok_or("thiếu số TK")?, args.get(4).cloned().unwrap_or_default());
            let (api, _) = open(&session).await?;
            let r = api.send_bank_card(Thread::User, to, bin.parse()?, num, &holder, rz_zalo::now_ms()).await?;
            println!("{}", short(&r));
        }
        "card" => {
            let (to, uid) = (args.get(1).ok_or("thiếu uid nhận")?, args.get(2).ok_or("thiếu uid danh thiếp")?);
            let (api, _) = open(&session).await?;
            let r = api.send_card(Thread::User, to, uid, "", rz_zalo::now_ms()).await?;
            println!("{}", short(&r));
        }
        "reminders" => {
            let to = args.get(1).ok_or("thiếu uid")?;
            let (api, _) = open(&session).await?;
            let r = api.reminder_list(Thread::User, to, 1, 20).await?;
            println!("{}", short(&r));
        }
        "remind" => {
            let (to, title, mins) = (args.get(1).ok_or("thiếu uid")?, args.get(2).ok_or("thiếu nội dung")?, args.get(3).and_then(|m| m.parse::<u64>().ok()).unwrap_or(60));
            let (api, _) = open(&session).await?;
            let r = api.reminder_create(Thread::User, to, title, "", rz_zalo::now_ms() + mins * 60_000, 0).await?;
            println!("{}", short(&r));
        }
        "unremind" => {
            let (to, id) = (args.get(1).ok_or("thiếu uid")?, args.get(2).ok_or("thiếu mã nhắc hẹn")?);
            let (api, _) = open(&session).await?;
            println!("{}", short(&api.reminder_remove(Thread::User, to, id).await?));
        }
        "quick" => {
            let (api, _) = open(&session).await?;
            let v = api.quick_list().await?;
            println!("{} tin nhắn nhanh; khoá: {:?}", v.get("items").and_then(Value::as_array).map_or(0, |a| a.len()),
                     v.as_object().map(|m| m.keys().cloned().collect::<Vec<_>>()));
        }
        "aliases" => {
            let (api, _) = open(&session).await?;
            let v = api.alias_list(1, 100).await?;
            println!("{} tên gợi nhớ; khoá: {:?}", v.get("items").and_then(Value::as_array).map_or(0, |a| a.len()),
                     v.as_object().map(|m| m.keys().cloned().collect::<Vec<_>>()));
        }
        "userinfo" => {
            // In cấu trúc (khoá, có / không có tên) — không in tên
            let uid = args.get(1).ok_or("thiếu uid")?;
            let (api, _) = open(&session).await?;
            let v = api.user_info(&[uid.clone()], 120).await?;
            for k in ["changed_profiles", "unchanged_profiles"] {
                let m = v.get(k).and_then(Value::as_object).cloned().unwrap_or_default();
                println!("{k}: {} mục, khoá {:?}", m.len(), m.keys().map(|x| x.chars().take(6).collect::<String>()).collect::<Vec<_>>());
                for (_, p) in m {
                    println!("  userId {} · displayName {} · zaloName {} · avatar {}", p.get("userId").is_some(),
                             p.get("displayName").and_then(Value::as_str).map_or("không", |s| if s.is_empty() { "rỗng" } else { "có" }),
                             p.get("zaloName").and_then(Value::as_str).map_or("không", |s| if s.is_empty() { "rỗng" } else { "có" }),
                             p.get("avatar").and_then(Value::as_str).map_or("không", |s| if s.is_empty() { "rỗng" } else { "có" }));
                }
            }
        }
        _ => {
            eprintln!("rz-cli qr [tệp.png] | me | friends | groups | listen [giây] | send <uid> <chữ>   [--session tệp]");
            eprintln!("       cloud | banks | bankcard <uid> <bin> <số TK> [tên] | card <uid nhận> <uid> | reminders <uid> | remind <uid> <nội dung> [phút]");
            eprintln!("       unremind <uid> <mã> | quick | aliases | userinfo <uid>");
        }
    }
    Ok(())
}
