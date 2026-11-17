//! Sao lưu dữ liệu Roza lên Telegram (Bot API của bot do người dùng tạo qua @BotFather).
//!
//! - Gồm: `roza.db` (tin nhắn, cuộc trò chuyện, người, nhóm, sticker gần đây…). **Không** gồm phiên đăng nhập Zalo
//!   (`session.json` — anh chốt 17/11/2026) và bộ đệm ảnh (tải lại được). Token bot ở `backup.json` (0600), ngoài CSDL.
//! - Sao lưu: `VACUUM INTO` (bản chụp nhất quán khi đang chạy) → gzip → `sendDocument` vào chat với bot → ghim tin đó.
//! - Khôi phục (máy mới không biết mã tệp): `getChat` → tin đang ghim → `getFile` → tải (Bot API cho tải ≤ 20 MB) → giải nén →
//!   kiểm đầu tệp SQLite → thay CSDL.
//! - Mã chat: người dùng nhắn /start cho bot → `getUpdates`.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::msg::{n, s};
use crate::store::Store;
use crate::{now_ms, Core, CoreError, R};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub(crate) struct BackupCfg {
    #[serde(default)]
    token: String,
    #[serde(default)]
    bot: String,
    #[serde(default)]
    chat_id: i64,
    #[serde(default)]
    chat_title: String,
    #[serde(default)]
    auto: bool,
    #[serde(default)]
    last_ms: u64,
    #[serde(default)]
    last_size: u64,
    /// Chép cả ảnh / video / tệp / thoại (từng phần ≤ 19 MB) trước khi chụp CSDL.
    #[serde(default)]
    media: bool,
}

/// Mỗi phần tệp gửi lên ≤ 19 MB: Bot API chỉ cho bot tải về tệp ≤ 20 MB (getFile) → khôi phục được tệp to cỡ nào cũng được.
const PART: usize = 19 * 1024 * 1024;

/// Gửi một tài liệu vào chat; Telegram báo 429 (gửi nhanh quá) thì chờ `retry_after` rồi gửi lại.
async fn tg_send_document(c: &reqwest::Client, token: &str, chat_id: i64, name: &str, caption: &str, data: &[u8]) -> R<Value> {
    for _ in 0..5 {
        let boundary = format!("----roza{}", rz_zalo::crypto::random_hex(20, 20));
        let mut body = Vec::with_capacity(data.len() + 1024);
        // disable_content_type_detection: giữ nguyên là tài liệu (không thì mp4 / gif thành video / animation)
        for (k, v) in [("chat_id", chat_id.to_string()), ("caption", caption.to_string()), ("disable_notification", "true".to_string()),
                       ("disable_content_type_detection", "true".to_string())] {
            if v.is_empty() {
                continue;
            }
            body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n").as_bytes());
        }
        let safe = name.replace(['"', '\r', '\n'], "_");
        body.extend_from_slice(
            format!("--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{safe}\"\r\nContent-Type: application/octet-stream\r\n\r\n")
                .as_bytes(),
        );
        body.extend_from_slice(data);
        body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
        let r = c
            .post(format!("https://api.telegram.org/bot{token}/sendDocument"))
            .header("content-type", format!("multipart/form-data; boundary={boundary}"))
            .body(body)
            .send()
            .await
            .map_err(net_err)?;
        let v: Value = r.json().await.map_err(|_| CoreError::new("BACKUP", "Telegram trả dữ liệu lạ"))?;
        if v.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(v.get("result").cloned().unwrap_or(Value::Null));
        }
        let wait = v.pointer("/parameters/retry_after").and_then(Value::as_u64);
        match wait {
            Some(w) => tokio::time::sleep(Duration::from_secs(w.min(60) + 1)).await,
            None => return Err(CoreError::new("BACKUP", format!("Telegram: {}", s(&v, "description")))),
        }
    }
    Err(CoreError::new("BACKUP", "Telegram bắt chờ quá lâu"))
}

/// Một tệp cần chép: địa chỉ nguồn, các địa chỉ cùng trỏ về nó (ảnh: hd / thường / thu nhỏ), loại bộ đệm, tên, tệp trên máy.
struct MediaEntry {
    src: String,
    keys: Vec<String>,
    kind: &'static str,
    name: String,
    hint: String,
    local: Option<String>,
}

fn media_entries(dto: &Value) -> Vec<MediaEntry> {
    let m = &dto["media"];
    let id = s(dto, "id");
    let local = |k: &str| Some(s(m, k)).filter(|p| !p.is_empty() && std::path::Path::new(p).exists());
    let mut out = Vec::new();
    match dto.get("kind").and_then(Value::as_str).unwrap_or("") {
        "photo" | "gif" => {
            let src = [s(m, "url"), s(m, "normal")].into_iter().find(|u| !u.is_empty()).unwrap_or_default();
            if !src.is_empty() {
                out.push(MediaEntry { keys: vec![s(m, "url"), s(m, "normal"), s(m, "thumb")], src, kind: "photo", name: format!("{id}.jpg"), hint: String::new(), local: local("local") });
            }
        }
        "video" => {
            let v = s(m, "url");
            if !v.is_empty() {
                out.push(MediaEntry { keys: vec![v.clone()], src: v, kind: "file", name: format!("{id}.mp4"), hint: "mp4".into(), local: local("local") });
            }
            let t = s(m, "thumb");
            if !t.is_empty() {
                out.push(MediaEntry { keys: vec![t.clone()], src: t, kind: "thumb", name: format!("{id}-anh-bia.jpg"), hint: String::new(), local: local("thumb_local") });
            }
        }
        "file" => {
            let u = s(m, "url");
            if !u.is_empty() {
                let name = { let n = s(m, "name"); if n.is_empty() { format!("{id}.bin") } else { n } };
                let hint = s(m, "ext");
                out.push(MediaEntry { keys: vec![u.clone()], src: u, kind: "file", name, hint, local: local("local") });
            }
        }
        "voice" => {
            let u = s(m, "url");
            if !u.is_empty() {
                out.push(MediaEntry { keys: vec![u.clone()], src: u, kind: "voice", name: format!("{id}.m4a"), hint: "m4a".into(), local: local("local") });
            }
        }
        _ => {}
    }
    out
}

fn client() -> R<reqwest::Client> {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(180))
        .build()
        .map_err(|e| CoreError::new("NETWORK", format!("HTTP: {e}")))
}

fn net_err(e: reqwest::Error) -> CoreError {
    CoreError::new("NETWORK", format!("Không vào được Telegram (nhà mạng có thể đang chặn): {e}"))
}

/// Gọi Bot API; lỗi Telegram (`ok: false`) → BACKUP.
async fn tg(c: &reqwest::Client, token: &str, method: &str, params: Value) -> R<Value> {
    let r = c.post(format!("https://api.telegram.org/bot{token}/{method}")).json(&params).send().await.map_err(net_err)?;
    tg_result(r).await
}

async fn tg_result(r: reqwest::Response) -> R<Value> {
    let v: Value = r.json().await.map_err(|_| CoreError::new("BACKUP", "Telegram trả dữ liệu lạ"))?;
    if v.get("ok").and_then(Value::as_bool) != Some(true) {
        let d = s(&v, "description");
        let msg = if d.contains("Unauthorized") { "Token bot không đúng".to_string() } else { format!("Telegram: {d}") };
        return Err(CoreError::new("BACKUP", msg));
    }
    Ok(v.get("result").cloned().unwrap_or(Value::Null))
}

impl Core {
    fn backup_path(&self) -> PathBuf {
        self.cfg.data_dir.join("backup.json")
    }

    pub(crate) fn backup_cfg(&self) -> BackupCfg {
        std::fs::read(self.backup_path()).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    fn save_backup_cfg(&self, c: &BackupCfg) {
        let p = self.backup_path();
        let tmp = p.with_extension("tmp");
        if std::fs::write(&tmp, serde_json::to_vec(c).unwrap_or_default()).is_ok() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
            }
            let _ = std::fs::rename(&tmp, &p);
        }
    }

    /// Trạng thái cho màn Sao lưu (không trả token).
    pub(crate) fn backup_state(&self) -> Value {
        let c = self.backup_cfg();
        let (files, bytes) = self.store.lock().unwrap().media_bk_stats();
        json!({"has_token": !c.token.is_empty(), "bot": c.bot, "chat_id": c.chat_id, "chat": c.chat_title, "auto": c.auto,
               "last_ms": c.last_ms, "last_size": c.last_size, "media": c.media, "media_files": files, "media_bytes": bytes})
    }

    pub(crate) fn backup_set_media(&self, media: bool) -> Value {
        let mut c = self.backup_cfg();
        c.media = media;
        self.save_backup_cfg(&c);
        self.backup_state()
    }

    /// Chép dần ảnh / video / tệp / thoại chưa có trong sổ lên chat với bot (mới nhất trước); ghi sổ `media_bk` sau mỗi tệp →
    /// đứt giữa chừng thì lần sau làm tiếp. Sự kiện `backup.progress {done, total}`.
    pub(crate) async fn backup_media(self: &Arc<Self>) -> R<Value> {
        let c = self.backup_cfg();
        if c.token.is_empty() || c.chat_id == 0 {
            return Err(CoreError::new("BAD_ARGS", "Chưa nối bot Telegram"));
        }
        let pending: Vec<(String, i64, MediaEntry)> = {
            let st = self.store.lock().unwrap();
            let mut seen = std::collections::HashSet::new();
            st.media_msgs(5000)
                .into_iter()
                .flat_map(|(t, ts, d)| media_entries(&d).into_iter().map(move |e| (t.clone(), ts, e)))
                .filter(|(_, _, e)| seen.insert(e.src.clone()) && st.media_bk_parts(&e.src).is_none())
                .collect()
        };
        let total = pending.len();
        let http = client()?;
        let (mut done, mut failed) = (0usize, 0usize);
        self.ev("backup.progress", json!({"done": 0, "total": total}));
        for (thread, ts, e) in pending {
            let r: R<()> = async {
                let data = match &e.local {
                    Some(p) => std::fs::read(p).map_err(|x| CoreError::new("IO", x.to_string()))?,
                    None => {
                        let zh = self.http()?;
                        let p = self.media.fetch_ext(&zh, &e.src, e.kind, &e.hint).await?;
                        std::fs::read(p).map_err(|x| CoreError::new("IO", x.to_string()))?
                    }
                };
                let chat = s(&self.store.lock().unwrap().thread(&thread), "name");
                let when = crate::msg::n(&json!({"t": ts}), "t") / 1000;
                let n = data.len().div_ceil(PART).max(1);
                let mut parts = Vec::with_capacity(n);
                for (i, chunk) in data.chunks(PART).enumerate() {
                    let name = if n == 1 { e.name.clone() } else { format!("{}.phan{}of{}", e.name, i + 1, n) };
                    let caption = if i == 0 { format!("Roza · {chat} · {when}") } else { String::new() };
                    let sent = tg_send_document(&http, &c.token, c.chat_id, &name, &caption, chunk).await?;
                    // Mã tệp ở đâu tuỳ Telegram xếp loại: tài liệu / video / âm thanh / ảnh động…
                    let fid = ["/document/file_id", "/video/file_id", "/audio/file_id", "/animation/file_id", "/voice/file_id"]
                        .iter()
                        .find_map(|k| sent.pointer(k).and_then(Value::as_str))
                        .unwrap_or("")
                        .to_string();
                    if fid.is_empty() {
                        return Err(CoreError::new("BACKUP", "Telegram không trả mã tệp"));
                    }
                    parts.push(fid);
                    tokio::time::sleep(Duration::from_millis(1100)).await;  // bot: ~1 tin / giây trong một chat
                }
                self.store.lock().unwrap().media_bk_put(&e.keys, e.kind, &parts, data.len() as u64);
                Ok(())
            }
            .await;
            match r {
                Ok(()) => done += 1,
                Err(x) => {
                    failed += 1;
                    self.log(&format!("chép tệp lỗi: {} {}", x.code, x.msg));
                    if x.code == "NETWORK" {
                        break;  // mất mạng / Telegram bị chặn → lần sau làm tiếp
                    }
                }
            }
            self.ev("backup.progress", json!({"done": done + failed, "total": total}));
        }
        self.log(&format!("chép tệp: {done} xong, {failed} lỗi / {total}"));
        Ok(json!({"done": done, "failed": failed, "total": total}))
    }

    /// Thử khôi phục: lấy từ Telegram tệp chép gần nhất (không đụng tin nhắn), báo cỡ + tệp đầu có đúng định dạng không.
    pub(crate) async fn backup_test_fetch(&self) -> R<Value> {
        let (url, kind) = self.store.lock().unwrap().media_bk_last().ok_or_else(|| CoreError::new("NOT_FOUND", "Chưa chép tệp nào"))?;
        let t = now_ms();
        let p = self.fetch_from_backup(&url, &kind, "").await?;
        let size = std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
        Ok(json!({"kind": kind, "size": size, "ms": now_ms() - t, "ext": p.extension().map(|e| e.to_string_lossy().into_owned())}))
    }

    /// Lấy lại một tệp từ bản sao lưu Telegram (ghép các phần) vào bộ đệm — khi địa chỉ Zalo đã hết hạn / lỗi.
    pub(crate) async fn fetch_from_backup(&self, url: &str, kind: &str, hint: &str) -> R<PathBuf> {
        let parts = self.store.lock().unwrap().media_bk_parts(url).ok_or_else(|| CoreError::new("NOT_FOUND", "Tệp chưa có trong bản sao lưu"))?;
        let c = self.backup_cfg();
        if c.token.is_empty() {
            return Err(CoreError::new("BAD_ARGS", "Chưa nối bot Telegram để lấy tệp đã sao lưu"));
        }
        let http = client()?;
        let mut data = Vec::new();
        for fid in parts {
            let f = tg(&http, &c.token, "getFile", json!({"file_id": fid})).await?;
            let u = format!("https://api.telegram.org/file/bot{}/{}", c.token, s(&f, "file_path"));
            data.extend_from_slice(&http.get(u).send().await.map_err(net_err)?.bytes().await.map_err(net_err)?);
        }
        self.log(&format!("lấy tệp từ bản sao lưu: {} byte", data.len()));
        self.media.put_bytes(url, kind, hint, &data)
    }

    pub(crate) async fn backup_set_token(&self, token: &str) -> R<Value> {
        let token = token.trim().to_string();
        if token.is_empty() || !token.contains(':') {
            return Err(CoreError::new("BAD_ARGS", "Token bot có dạng 123456789:AA…"));
        }
        let me = tg(&client()?, &token, "getMe", json!({})).await?;
        let mut c = self.backup_cfg();
        if c.token != token {
            c.chat_id = 0;
            c.chat_title.clear();
        }
        c.token = token;
        c.bot = s(&me, "username");
        self.save_backup_cfg(&c);
        Ok(self.backup_state())
    }

    /// Tìm chat với bot: tin mới nhất người dùng nhắn cho bot (/start).
    pub(crate) async fn backup_find_chat(&self) -> R<Value> {
        let mut c = self.backup_cfg();
        if c.token.is_empty() {
            return Err(CoreError::new("BAD_ARGS", "Chưa nhập token bot"));
        }
        let http = client()?;
        let ups = tg(&http, &c.token, "getUpdates", json!({"limit": 50, "timeout": 0})).await?;
        let chat = ups
            .as_array()
            .and_then(|a| a.iter().rev().find_map(|u| u.get("message").and_then(|m| m.get("chat")).cloned()))
            .ok_or_else(|| CoreError::new("BACKUP", "Chưa thấy tin nào. Mở Telegram, nhắn /start cho bot rồi thử lại."))?;
        c.chat_id = n(&chat, "id");
        c.chat_title = [s(&chat, "first_name"), s(&chat, "last_name"), s(&chat, "title")].iter().filter(|x| !x.is_empty()).cloned().collect::<Vec<_>>().join(" ");
        self.save_backup_cfg(&c);
        let _ = tg(&http, &c.token, "sendMessage", json!({"chat_id": c.chat_id, "text": "Roza: đã nối sao lưu với chat này."})).await;
        Ok(self.backup_state())
    }

    pub(crate) fn backup_set_auto(&self, auto: bool) -> Value {
        let mut c = self.backup_cfg();
        c.auto = auto;
        self.save_backup_cfg(&c);
        self.backup_state()
    }

    /// Sao lưu ngay: chụp CSDL → gzip → gửi + ghim.
    pub(crate) async fn backup_run(self: &Arc<Self>) -> R<Value> {
        if self.backup_cfg().token.is_empty() || self.backup_cfg().chat_id == 0 {
            return Err(CoreError::new("BAD_ARGS", "Chưa nối bot Telegram"));
        }
        // Chép tệp trước, chụp CSDL sau → bản sao lưu có sổ media_bk mới nhất
        let media = if self.backup_cfg().media { Some(Box::pin(self.backup_media()).await?) } else { None };
        let mut c = self.backup_cfg();
        let snap = self.cfg.data_dir.join(format!("backup-{}.db", now_ms()));
        let count = {
            let st = self.store.lock().unwrap();
            st.snapshot(&snap).map_err(|e| CoreError::new("IO", e))?;
            st.msg_total()
        };
        let raw = std::fs::read(&snap).map_err(|e| CoreError::new("IO", format!("Đọc bản chụp: {e}")));
        let _ = std::fs::remove_file(&snap);
        let raw = raw?;
        let gz = tokio::task::spawn_blocking(move || {
            let mut e = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
            e.write_all(&raw).and_then(|_| e.finish())
        })
        .await
        .map_err(|_| CoreError::new("IO", "Nén thất bại"))?
        .map_err(|e| CoreError::new("IO", format!("Nén: {e}")))?;
        if gz.len() > 49 * 1024 * 1024 {
            return Err(CoreError::new("TOO_BIG", "Bản sao lưu quá 50 MB (giới hạn của Bot API)"));
        }
        let size = gz.len() as u64;
        let name = format!("roza-backup-{}.db.gz", now_ms() / 1000);
        let me = self.st.lock().unwrap().me.clone();
        let who = s(&me, "name");
        let caption = format!("Roza — sao lưu {} tin nhắn{}{}. Khôi phục: Roza → Thêm → Sao lưu → Khôi phục.", count,
                              if who.is_empty() { "" } else { " của " }, who);
        let boundary = format!("----roza{}", rz_zalo::crypto::random_hex(20, 20));
        let mut body = Vec::with_capacity(gz.len() + 1024);
        for (k, v) in [("chat_id", c.chat_id.to_string()), ("caption", caption)] {
            body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n").as_bytes());
        }
        body.extend_from_slice(
            format!("--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{name}\"\r\nContent-Type: application/gzip\r\n\r\n").as_bytes(),
        );
        body.extend_from_slice(&gz);
        body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
        let http = client()?;
        let r = http
            .post(format!("https://api.telegram.org/bot{}/sendDocument", c.token))
            .header("content-type", format!("multipart/form-data; boundary={boundary}"))
            .body(body)
            .send()
            .await
            .map_err(net_err)?;
        let sent = tg_result(r).await?;
        let mid = n(&sent, "message_id");
        let _ = &media;
        // Ghim → máy mới tìm được bản mới nhất qua getChat (Bot API không cho đọc lịch sử chat)
        let _ = tg(&http, &c.token, "pinChatMessage", json!({"chat_id": c.chat_id, "message_id": mid, "disable_notification": true})).await;
        c.last_ms = now_ms();
        c.last_size = size;
        self.save_backup_cfg(&c);
        self.log(&format!("sao lưu: {count} tin, {size} byte nén"));
        Ok(json!({"count": count, "size": size, "media": media, "state": self.backup_state()}))
    }

    /// Khôi phục từ bản đang ghim trong chat với bot. Thay CSDL hiện tại.
    pub(crate) async fn backup_restore(self: &Arc<Self>) -> R<Value> {
        let c = self.backup_cfg();
        if c.token.is_empty() || c.chat_id == 0 {
            return Err(CoreError::new("BAD_ARGS", "Chưa nối bot Telegram"));
        }
        let http = client()?;
        let chat = tg(&http, &c.token, "getChat", json!({"chat_id": c.chat_id})).await?;
        let doc = chat.pointer("/pinned_message/document").cloned().ok_or_else(|| CoreError::new("BACKUP", "Chưa có bản sao lưu nào (không thấy tin đang ghim)."))?;
        if n(&doc, "file_size") > 20 * 1024 * 1024 {
            return Err(CoreError::new("TOO_BIG", "Bản sao lưu lớn hơn 20 MB — Bot API không cho tải về."));
        }
        let f = tg(&http, &c.token, "getFile", json!({"file_id": s(&doc, "file_id")})).await?;
        let url = format!("https://api.telegram.org/file/bot{}/{}", c.token, s(&f, "file_path"));
        let gz = http.get(url).send().await.map_err(net_err)?.bytes().await.map_err(net_err)?.to_vec();
        let raw = tokio::task::spawn_blocking(move || {
            let mut out = Vec::new();
            flate2::read::GzDecoder::new(&gz[..]).read_to_end(&mut out).map(|_| out)
        })
        .await
        .map_err(|_| CoreError::new("IO", "Giải nén thất bại"))?
        .map_err(|_| CoreError::new("BACKUP", "Tệp sao lưu hỏng (không giải nén được)"))?;
        if !raw.starts_with(b"SQLite format 3\0") {
            return Err(CoreError::new("BACKUP", "Tệp sao lưu không phải dữ liệu Roza"));
        }
        let db = self.cfg.data_dir.join("roza.db");
        let tmp = self.cfg.data_dir.join("roza.db.restore");
        std::fs::write(&tmp, &raw).map_err(|e| CoreError::new("IO", format!("Ghi tệp: {e}")))?;
        let count = {
            let mut st = self.store.lock().unwrap();
            // Đóng CSDL cũ (thay bằng CSDL trong RAM), thay tệp, mở lại
            *st = Store::memory().map_err(|e| CoreError::new("IO", e))?;
            for ext in ["db-wal", "db-shm"] {
                let _ = std::fs::remove_file(db.with_extension(ext));
            }
            std::fs::rename(&tmp, &db).map_err(|e| CoreError::new("IO", format!("Thay dữ liệu: {e}")))?;
            *st = Store::open(&db).map_err(|e| CoreError::new("IO", e))?;
            st.msg_total()
        };
        self.cloud_synced.lock().unwrap().clear();
        self.log(&format!("khôi phục: {count} tin"));
        self.ev("threads.changed", json!({}));
        self.ev("contacts.changed", json!({}));
        Ok(json!({"count": count}))
    }

    /// Tự sao lưu: sau khi đăng nhập, nếu bật và bản trước đã quá 24 giờ.
    pub(crate) async fn backup_auto(self: &Arc<Self>) {
        let c = self.backup_cfg();
        if !c.auto || c.token.is_empty() || c.chat_id == 0 || now_ms().saturating_sub(c.last_ms) < 86_400_000 {
            return;
        }
        if let Err(e) = Box::pin(self.backup_run()).await {
            self.log(&format!("tự sao lưu lỗi: {} {}", e.code, e.msg));
        }
    }
}
