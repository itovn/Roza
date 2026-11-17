//! Kho trên máy (SQLite, `rusqlite` bundled — không dùng sqlite 3.7 của iOS 5 / 6): tin nhắn, cuộc trò chuyện, người, nhóm.
//!
//! Zalo Web không cho tải lại lịch sử chat riêng từ máy chủ (chỉ đồng bộ cửa sổ tin gần đây lúc mở kết nối; nhóm thì có «cloud
//! message») → tin nào đã nhận là lõi giữ lại ở đây.

use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use crate::msg::{self, Norm};

pub struct Store {
    db: Connection,
}

const SCHEMA: &str = "
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
CREATE TABLE IF NOT EXISTS msgs(
    thread TEXT NOT NULL,
    id TEXT NOT NULL,
    cid TEXT NOT NULL,
    ts INTEGER NOT NULL,
    sender TEXT NOT NULL,
    out INTEGER NOT NULL,
    dto TEXT NOT NULL,
    raw TEXT,
    PRIMARY KEY(thread, id)
);
CREATE INDEX IF NOT EXISTS msgs_ts ON msgs(thread, ts);
CREATE INDEX IF NOT EXISTS msgs_cid ON msgs(thread, cid);
CREATE TABLE IF NOT EXISTS threads(
    key TEXT PRIMARY KEY,
    last_ts INTEGER NOT NULL DEFAULT 0,
    last_id TEXT,
    unread INTEGER NOT NULL DEFAULT 0,
    read_ts INTEGER NOT NULL DEFAULT 0,
    pinned INTEGER NOT NULL DEFAULT 0,
    muted INTEGER NOT NULL DEFAULT 0,
    hidden INTEGER NOT NULL DEFAULT 0,
    seen_id TEXT
);
CREATE TABLE IF NOT EXISTS users(
    uid TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    zname TEXT NOT NULL DEFAULT '',
    avatar TEXT NOT NULL DEFAULT '',
    phone TEXT NOT NULL DEFAULT '',
    friend INTEGER NOT NULL DEFAULT 0,
    json TEXT,
    updated INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS groups(
    gid TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    avatar TEXT NOT NULL DEFAULT '',
    members INTEGER NOT NULL DEFAULT 0,
    member_ids TEXT,
    json TEXT,
    updated INTEGER NOT NULL DEFAULT 0,
    left_group INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT NOT NULL);
-- Sổ sao lưu tệp (ảnh / video / tệp / thoại) lên Telegram: địa chỉ Zalo → các phần (file_id, mỗi phần ≤ 19 MB). Nằm trong CSDL nên
-- đi theo bản sao lưu: khôi phục xong, địa chỉ Zalo hết hạn thì lõi lấy lại từ Telegram (backup.rs).
CREATE TABLE IF NOT EXISTS media_bk(url TEXT PRIMARY KEY, kind TEXT NOT NULL, parts TEXT NOT NULL, size INTEGER NOT NULL, ts INTEGER NOT NULL);
";

type Res<T> = Result<T, String>;

fn e(x: rusqlite::Error) -> String {
    format!("SQLite: {x}")
}

/// Cột thêm sau (CSDL cũ / bản sao lưu cũ). Lỗi «duplicate column» khi đã có thì bỏ qua.
fn migrate(db: &Connection) {
    // trò chuyện ẩn của Zalo (có PIN, đồng bộ với điện thoại)
    let _ = db.execute("ALTER TABLE threads ADD COLUMN secret INTEGER NOT NULL DEFAULT 0", []);
    // tên gợi nhớ mình đặt cho người khác (đồng bộ với Zalo trên điện thoại)
    let _ = db.execute("ALTER TABLE users ADD COLUMN alias TEXT NOT NULL DEFAULT ''", []);
}

/// Tên hiện: tên gợi nhớ > tên hiển thị > tên Zalo.
fn pick_name(alias: &str, name: &str, zname: &str) -> String {
    [alias, name, zname].into_iter().find(|x| !x.trim().is_empty()).unwrap_or("").to_string()
}

impl Store {
    pub fn open(path: &Path) -> Res<Self> {
        let db = Connection::open(path).map_err(e)?;
        db.execute_batch(SCHEMA).map_err(e)?;
        migrate(&db);
        Ok(Self { db })
    }

    /// CSDL tạm trong RAM (lúc thay tệp khi khôi phục).
    pub fn memory() -> Res<Self> {
        let db = Connection::open_in_memory().map_err(e)?;
        db.execute_batch(SCHEMA).map_err(e)?;
        migrate(&db);
        Ok(Self { db })
    }

    /// Bản chụp nhất quán của CSDL ra tệp (`VACUUM INTO`, SQLite ≥ 3.27 — bản dựng kèm là 3.4x).
    pub fn snapshot(&self, path: &Path) -> Res<()> {
        let _ = std::fs::remove_file(path);
        self.db.execute("VACUUM INTO ?1", [path.to_string_lossy()]).map(|_| ()).map_err(e)
    }

    /// Các phần Telegram của một tệp đã sao lưu (theo địa chỉ Zalo).
    pub fn media_bk_parts(&self, url: &str) -> Option<Vec<String>> {
        let s: String = self.db.query_row("SELECT parts FROM media_bk WHERE url = ?1", [url], |r| r.get(0)).optional().ok()??;
        serde_json::from_str(&s).ok()
    }

    /// Ghi sổ: mọi địa chỉ trong `urls` (ảnh: hd / thường / thu nhỏ) cùng trỏ tới các phần đã chép.
    pub fn media_bk_put(&self, urls: &[String], kind: &str, parts: &[String], size: u64) {
        let p = serde_json::to_string(parts).unwrap_or_default();
        let now = crate::now_ms() as i64;
        for u in urls.iter().filter(|u| !u.is_empty()) {
            let _ = self.db.execute(
                "INSERT OR REPLACE INTO media_bk(url, kind, parts, size, ts) VALUES(?1, ?2, ?3, ?4, ?5)",
                params![u, kind, p, size as i64, now],
            );
        }
    }

    pub fn media_bk_last(&self) -> Option<(String, String)> {
        self.db.query_row("SELECT url, kind FROM media_bk ORDER BY ts DESC LIMIT 1", [], |r| Ok((r.get(0)?, r.get(1)?))).optional().ok()?
    }

    pub fn media_bk_stats(&self) -> (i64, i64) {
        self.db
            .query_row("SELECT COUNT(DISTINCT parts), COALESCE(SUM(size), 0) FROM (SELECT parts, MAX(size) AS size FROM media_bk GROUP BY parts)", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap_or((0, 0))
    }

    /// Tin có ảnh / video / tệp / thoại (mới nhất trước): (khoá chat, giờ, DTO).
    pub fn media_msgs(&self, limit: i64) -> Vec<(String, i64, Value)> {
        let mut st = match self.db.prepare(
            "SELECT thread, ts, dto FROM msgs WHERE id NOT LIKE 'l%' AND (dto LIKE '%\"kind\":\"photo\"%' OR dto LIKE '%\"kind\":\"gif\"%'
               OR dto LIKE '%\"kind\":\"video\"%' OR dto LIKE '%\"kind\":\"file\"%' OR dto LIKE '%\"kind\":\"voice\"%') ORDER BY ts DESC LIMIT ?1",
        ) {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        st.query_map([limit], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?)))
            .map(|it| it.filter_map(|x| x.ok()).filter_map(|(t, ts, d)| serde_json::from_str(&d).ok().map(|v| (t, ts, v))).collect())
            .unwrap_or_default()
    }

    /// Tổng tin chưa đọc của các chat không tắt tiếng (số trên biểu tượng app).
    pub fn unread_total(&self) -> i64 {
        self.db.query_row("SELECT COALESCE(SUM(unread), 0) FROM threads WHERE muted = 0 AND hidden = 0", [], |r| r.get(0)).unwrap_or(0)
    }

    pub fn msg_total(&self) -> i64 {
        self.db.query_row("SELECT COUNT(*) FROM msgs", [], |r| r.get(0)).unwrap_or(0)
    }

    pub fn kv_get(&self, k: &str) -> Option<String> {
        self.db.query_row("SELECT v FROM kv WHERE k = ?1", [k], |r| r.get(0)).optional().ok().flatten()
    }

    pub fn kv_set(&self, k: &str, v: &str) {
        let _ = self.db.execute("INSERT INTO kv(k, v) VALUES(?1, ?2) ON CONFLICT(k) DO UPDATE SET v = excluded.v", params![k, v]);
    }

    // ───── Tin nhắn ─────

    /// Lưu một tin (thay tin tạm cùng cliMsgId nếu có). Trả true nếu là tin mới (chưa có trong kho).
    pub fn put_msg(&mut self, m: &Norm, raw: &Value) -> bool {
        self.put_msg2(m, raw).0
    }

    /// Như `put_msg`, trả thêm id tạm ("l<cid>") đã được thay bằng tin thật (tin mình gửi từ máy này).
    pub fn put_msg2(&mut self, m: &Norm, raw: &Value) -> (bool, Option<String>) {
        let tx = match self.db.transaction() {
            Ok(t) => t,
            Err(_) => return (false, None),
        };
        let lid = format!("l{}", m.cid);
        let replaced = tx.execute("DELETE FROM msgs WHERE thread = ?1 AND id = ?2", params![m.thread, lid]).unwrap_or(0) > 0;
        let existed: bool = tx
            .query_row("SELECT 1 FROM msgs WHERE thread = ?1 AND id = ?2", params![m.thread, m.id], |_| Ok(()))
            .optional()
            .ok()
            .flatten()
            .is_some();
        let r = tx.execute(
            "INSERT INTO msgs(thread, id, cid, ts, sender, out, dto, raw) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(thread, id) DO UPDATE SET dto = excluded.dto, raw = excluded.raw, ts = excluded.ts",
            params![m.thread, m.id, m.cid, m.ts, m.from, m.out as i64, m.dto.to_string(), raw.to_string()],
        );
        if r.is_err() {
            return (false, None);
        }
        let _ = tx.execute(
            "INSERT INTO threads(key, last_ts, last_id) VALUES(?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET last_ts = MAX(last_ts, excluded.last_ts),
                last_id = CASE WHEN excluded.last_ts >= last_ts OR last_id = ?4 THEN excluded.last_id ELSE last_id END, hidden = 0",
            params![m.thread, m.ts, m.id, lid],
        );
        if !existed && !m.out {
            let _ = tx.execute("UPDATE threads SET unread = unread + 1 WHERE key = ?1 AND read_ts < ?2", params![m.thread, m.ts]);
        }
        let _ = tx.commit();
        (!existed, if replaced { Some(lid) } else { None })
    }

    /// Ghi lại DTO của một tin (cảm xúc…).
    /// Đọc lại (từ `raw`) các tin đã lưu bằng cách đọc của bản cũ — loại tin mới nhận ra sau này: danh thiếp, thẻ ngân hàng,
    /// nhắc hẹn, dòng thông báo. Giữ cảm xúc / trạng thái đã có. Trả số tin đã đổi.
    pub fn renormalize(&mut self, me: &str) -> usize {
        let rows: Vec<(String, String, String, String)> = {
            let mut st = match self.db.prepare(
                "SELECT thread, id, raw, dto FROM msgs WHERE raw IS NOT NULL AND
                 json_extract(raw, '$.msgType') IN ('chat.recommended', 'chat.webcontent', 'chat.ecard', 'webchat')
                 AND (json_extract(raw, '$.msgType') != 'webchat' OR json_type(raw, '$.content') = 'object')",
            ) {
                Ok(s) => s,
                Err(_) => return 0,
            };
            st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
                .map(|it| it.filter_map(|x| x.ok()).collect())
                .unwrap_or_default()
        };
        let mut changed = 0;
        for (thread, id, raw, dto) in rows {
            let (Ok(raw), Ok(old)) = (serde_json::from_str::<Value>(&raw), serde_json::from_str::<Value>(&dto)) else { continue };
            let Some(n) = msg::normalize(&raw, me, thread.starts_with('g')) else { continue };
            if n.dto.is_null() || (n.dto["kind"] == old["kind"] && n.dto["media"] == old["media"] && n.dto["text"] == old["text"]) {
                continue;
            }
            let mut d = n.dto;
            for k in ["reacts", "status", "seen", "quote", "name"] {
                if let Some(v) = old.get(k).filter(|v| !v.is_null()) {
                    d[k] = v.clone();
                }
            }
            self.update_dto(&thread, &id, &d);
            changed += 1;
        }
        changed
    }

    pub fn update_dto(&mut self, thread: &str, id: &str, dto: &Value) {
        let _ = self.db.execute("UPDATE msgs SET dto = ?3 WHERE thread = ?1 AND id = ?2", params![thread, id, dto.to_string()]);
    }

    pub fn dto(&self, thread: &str, id: &str) -> Option<Value> {
        let s: String = self.db.query_row("SELECT dto FROM msgs WHERE thread = ?1 AND id = ?2", params![thread, id], |r| r.get(0)).optional().ok()??;
        serde_json::from_str(&s).ok()
    }

    /// Tin tạm của mình (đang gửi): id "l<cid>".
    pub fn put_pending(&mut self, thread: &str, cid: &str, ts: i64, me: &str, dto: &Value) {
        let id = format!("l{cid}");
        let _ = self.db.execute(
            "INSERT OR REPLACE INTO msgs(thread, id, cid, ts, sender, out, dto, raw) VALUES(?1, ?2, ?3, ?4, ?5, 1, ?6, NULL)",
            params![thread, id, cid, ts, me, dto.to_string()],
        );
        let _ = self.db.execute(
            "INSERT INTO threads(key, last_ts, last_id) VALUES(?1, ?2, ?3)
             ON CONFLICT(key) DO UPDATE SET last_ts = MAX(last_ts, excluded.last_ts), last_id = excluded.last_id, hidden = 0",
            params![thread, ts, id],
        );
    }

    /// Đổi tin tạm thành tin đã gửi (có msgId) — nếu WebSocket chưa kịp đẩy tin thật về.
    pub fn confirm_pending(&mut self, thread: &str, cid: &str, msg_id: &str) -> Option<Value> {
        let lid = format!("l{cid}");
        let dto: String = self.db.query_row("SELECT dto FROM msgs WHERE thread = ?1 AND id = ?2", params![thread, lid], |r| r.get(0)).optional().ok()??;
        let mut v: Value = serde_json::from_str(&dto).ok()?;
        v["id"] = json!(msg_id);
        v["status"] = json!("sent");
        let exists = self.db.query_row("SELECT 1 FROM msgs WHERE thread = ?1 AND id = ?2", params![thread, msg_id], |_| Ok(())).optional().ok()?.is_some();
        if exists {
            let _ = self.db.execute("DELETE FROM msgs WHERE thread = ?1 AND id = ?2", params![thread, lid]);
        } else {
            let _ = self.db.execute("UPDATE msgs SET id = ?3, dto = ?4 WHERE thread = ?1 AND id = ?2", params![thread, lid, msg_id, v.to_string()]);
            let _ = self.db.execute("UPDATE threads SET last_id = ?2 WHERE key = ?1 AND last_id = ?3", params![thread, msg_id, lid]);
        }
        Some(v)
    }

    pub fn fail_pending(&mut self, thread: &str, cid: &str) -> Option<Value> {
        let lid = format!("l{cid}");
        let dto: String = self.db.query_row("SELECT dto FROM msgs WHERE thread = ?1 AND id = ?2", params![thread, lid], |r| r.get(0)).optional().ok()??;
        let mut v: Value = serde_json::from_str(&dto).ok()?;
        v["status"] = json!("failed");
        let _ = self.db.execute("UPDATE msgs SET dto = ?3 WHERE thread = ?1 AND id = ?2", params![thread, lid, v.to_string()]);
        Some(v)
    }

    /// Đánh dấu tin bị thu hồi (theo msgId hoặc cliMsgId). Trả DTO mới nếu có tin đó.
    pub fn recall(&mut self, thread: &str, id: &str, cid: &str) -> Option<Value> {
        let row: Option<(String, String)> = self
            .db
            .query_row(
                "SELECT id, dto FROM msgs WHERE thread = ?1 AND (id = ?2 OR (?3 != '' AND cid = ?3)) LIMIT 1",
                params![thread, id, cid],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .ok()
            .flatten();
        let (rid, dto) = row?;
        let mut v: Value = serde_json::from_str(&dto).ok()?;
        v["kind"] = json!("recall");
        v["text"] = json!("Tin nhắn đã được thu hồi");
        if let Some(o) = v.as_object_mut() {
            o.remove("media");
            o.remove("quote");
        }
        let _ = self.db.execute("UPDATE msgs SET dto = ?3, raw = NULL WHERE thread = ?1 AND id = ?2", params![thread, rid, v.to_string()]);
        Some(v)
    }

    pub fn delete_msg(&mut self, thread: &str, id: &str) {
        let _ = self.db.execute("DELETE FROM msgs WHERE thread = ?1 AND id = ?2", params![thread, id]);
        self.fix_last(thread);
    }

    fn fix_last(&mut self, thread: &str) {
        let last: Option<(i64, String)> = self
            .db
            .query_row("SELECT ts, id FROM msgs WHERE thread = ?1 ORDER BY ts DESC LIMIT 1", [thread], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()
            .ok()
            .flatten();
        if let Some((ts, id)) = last {
            let _ = self.db.execute("UPDATE threads SET last_ts = ?2, last_id = ?3 WHERE key = ?1", params![thread, ts, id]);
        }
    }

    /// Tin của một cuộc trò chuyện, cũ hơn `before_ts` (0 = mới nhất), trả theo thứ tự cũ → mới.
    pub fn history(&self, thread: &str, before_ts: i64, limit: i64) -> Vec<Value> {
        let mut st = match self.db.prepare("SELECT dto FROM msgs WHERE thread = ?1 AND (?2 = 0 OR ts < ?2) ORDER BY ts DESC, id DESC LIMIT ?3") {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        let mut v: Vec<Value> = st
            .query_map(params![thread, before_ts, limit], |r| r.get::<_, String>(0))
            .map(|it| it.filter_map(|x| x.ok()).filter_map(|s| serde_json::from_str(&s).ok()).collect())
            .unwrap_or_default();
        v.reverse();
        v
    }

    /// Tin nhóm của người khác: gắn ảnh đại diện + tên người gửi (từ bảng người) để app hiện cạnh bong bóng.
    pub fn enrich(&self, v: &mut Value) {
        let group = v.get("thread").and_then(Value::as_str).map_or(false, |t| t.starts_with('g'));
        if !group || v.get("out").and_then(Value::as_bool) == Some(true) {
            return;
        }
        let from = v.get("from").and_then(Value::as_str).unwrap_or("").to_string();
        let (name, avatar) = self.user_brief(&from);
        if !avatar.is_empty() {
            v["avatar"] = json!(avatar);
        }
        // Tên gợi nhớ (mình đặt) thay tên người gửi tự đặt, như app Zalo
        let alias = self.alias(&from);
        if !alias.is_empty() {
            v["name"] = json!(alias);
        } else if v.get("name").and_then(Value::as_str).map_or(true, str::is_empty) && !name.is_empty() {
            v["name"] = json!(name);
        }
    }

    pub fn history_enriched(&self, thread: &str, before_ts: i64, limit: i64) -> Vec<Value> {
        let mut v = self.history(thread, before_ts, limit);
        if thread.starts_with('g') {
            for m in v.iter_mut() {
                self.enrich(m);
            }
        }
        v
    }

    /// Nguyên bản Zalo của một tin (để trả lời / báo đã xem).
    pub fn raw_msg(&self, thread: &str, id: &str) -> Option<Value> {
        let s: Option<String> = self.db.query_row("SELECT raw FROM msgs WHERE thread = ?1 AND id = ?2", params![thread, id], |r| r.get(0)).optional().ok()??;
        serde_json::from_str(&s?).ok()
    }

    /// Tin của người khác chưa báo đã xem (mới nhất trước, tối đa 50) — nguyên bản Zalo.
    pub fn unseen_incoming(&self, thread: &str, after_ts: i64) -> Vec<Value> {
        let mut st = match self.db.prepare("SELECT raw FROM msgs WHERE thread = ?1 AND out = 0 AND ts > ?2 AND raw IS NOT NULL ORDER BY ts DESC LIMIT 50") {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        st.query_map(params![thread, after_ts], |r| r.get::<_, String>(0))
            .map(|it| it.filter_map(|x| x.ok()).filter_map(|s| serde_json::from_str(&s).ok()).collect())
            .unwrap_or_default()
    }

    /// msgId lớn nhất đã có của chat riêng / nhóm (đồng bộ tin cũ lúc mở kết nối).
    pub fn max_msg_id(&self, group: bool) -> Option<String> {
        let pat = if group { "g%" } else { "u%" };
        self.db
            .query_row(
                "SELECT id FROM msgs WHERE thread LIKE ?1 AND id NOT LIKE 'l%' ORDER BY length(id) DESC, id DESC LIMIT 1",
                [pat],
                |r| r.get(0),
            )
            .optional()
            .ok()
            .flatten()
    }

    pub fn oldest_msg_id(&self, thread: &str) -> Option<String> {
        self.db
            .query_row("SELECT id FROM msgs WHERE thread = ?1 AND id NOT LIKE 'l%' ORDER BY ts ASC LIMIT 1", [thread], |r| r.get(0))
            .optional()
            .ok()
            .flatten()
    }

    pub fn msg_count(&self, thread: &str) -> i64 {
        self.db.query_row("SELECT COUNT(*) FROM msgs WHERE thread = ?1", [thread], |r| r.get(0)).unwrap_or(0)
    }

    // ───── Cuộc trò chuyện ─────

    pub fn mark_read(&mut self, thread: &str, ts: i64) {
        let _ = self.db.execute(
            "INSERT INTO threads(key, read_ts) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET unread = 0, read_ts = MAX(read_ts, excluded.read_ts)",
            params![thread, ts],
        );
    }

    pub fn set_seen(&mut self, thread: &str, msg_id: &str) {
        let _ = self.db.execute("UPDATE threads SET seen_id = ?2 WHERE key = ?1", params![thread, msg_id]);
    }

    pub fn set_pinned(&mut self, keys: &[String]) {
        let _ = self.db.execute("UPDATE threads SET pinned = 0", []);
        for (i, k) in keys.iter().enumerate() {
            let _ = self.db.execute(
                "INSERT INTO threads(key, pinned) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET pinned = excluded.pinned",
                params![k, (keys.len() - i) as i64],
            );
        }
    }

    pub fn set_muted(&mut self, keys: &[String]) {
        let _ = self.db.execute("UPDATE threads SET muted = 0", []);
        for k in keys {
            let _ = self.db.execute("INSERT INTO threads(key, muted) VALUES(?1, 1) ON CONFLICT(key) DO UPDATE SET muted = 1", [k]);
        }
    }

    pub fn set_thread_flag(&mut self, key: &str, col: &str, v: i64) {
        if !matches!(col, "muted" | "hidden" | "pinned") {
            return;
        }
        let sql = format!("INSERT INTO threads(key, {col}) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET {col} = excluded.{col}");
        let _ = self.db.execute(&sql, params![key, v]);
    }

    /// Danh sách cuộc trò chuyện đã sẵn hiển thị (ghim trước, rồi mới nhất trước) — không gồm trò chuyện ẩn.
    pub fn threads(&self, limit: i64) -> Vec<Value> {
        self.threads_where(limit, false)
    }

    /// Trò chuyện ẩn (đã mở bằng PIN).
    pub fn secret_threads(&self) -> Vec<Value> {
        self.threads_where(10000, true)
    }

    pub fn set_secret(&mut self, keys: &[String]) {
        let _ = self.db.execute("UPDATE threads SET secret = 0", []);
        for k in keys {
            let _ = self.db.execute("INSERT INTO threads(key, secret) VALUES(?1, 1) ON CONFLICT(key) DO UPDATE SET secret = 1", [k]);
        }
    }

    pub fn set_secret_one(&mut self, key: &str, on: bool) {
        let _ = self.db.execute(
            "INSERT INTO threads(key, secret) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET secret = excluded.secret",
            params![key, on as i64],
        );
    }

    pub fn is_secret(&self, key: &str) -> bool {
        self.db.query_row("SELECT secret FROM threads WHERE key = ?1", [key], |r| r.get::<_, i64>(0)).map(|v| v != 0).unwrap_or(false)
    }

    fn threads_where(&self, limit: i64, secret: bool) -> Vec<Value> {
        let sql = format!(
            "SELECT t.key, t.last_ts, t.unread, t.pinned, t.muted, m.dto, t.seen_id, t.last_id
             FROM threads t LEFT JOIN msgs m ON m.thread = t.key AND m.id = t.last_id
             WHERE t.hidden = 0 AND t.secret = {} AND (t.last_ts > 0 OR t.pinned > 0 OR t.secret = 1)
             ORDER BY t.pinned DESC, t.last_ts DESC LIMIT ?1",
            secret as i64
        );
        let mut st = match self.db.prepare(&sql) {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        let rows: Vec<(String, i64, i64, i64, i64, Option<String>, Option<String>, Option<String>)> = st
            .query_map([limit], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?)))
            .map(|it| it.filter_map(|x| x.ok()).collect())
            .unwrap_or_default();
        rows.into_iter().map(|(key, ts, unread, pinned, muted, dto, seen, last_id)| self.thread_dto(&key, ts, unread, pinned, muted, dto, seen, last_id)).collect()
    }

    pub fn thread(&self, key: &str) -> Value {
        let row = self
            .db
            .query_row(
                "SELECT t.last_ts, t.unread, t.pinned, t.muted, m.dto, t.seen_id, t.last_id FROM threads t
                 LEFT JOIN msgs m ON m.thread = t.key AND m.id = t.last_id WHERE t.key = ?1",
                [key],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?)),
            )
            .optional()
            .ok()
            .flatten();
        match row {
            Some((ts, unread, pinned, muted, dto, seen, last_id)) => self.thread_dto(key, ts, unread, pinned, muted, dto, seen, last_id),
            None => self.thread_dto(key, 0, 0, 0, 0, None, None, None),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn thread_dto(&self, key: &str, ts: i64, unread: i64, pinned: i64, muted: i64, dto: Option<String>, seen: Option<String>, last_id: Option<String>) -> Value {
        let last: Value = dto.and_then(|d| serde_json::from_str(&d).ok()).unwrap_or(Value::Null);
        let (group, id) = msg::parse_key(key).unwrap_or((false, ""));
        let (name, avatar, members) = if group {
            self.group_brief(id)
        } else {
            let (n, a) = self.user_brief(id);
            (n, a, 0)
        };
        let mut preview = if last.is_null() { String::new() } else { msg::preview(&last) };
        if group && !last.is_null() && last.get("kind").and_then(Value::as_str) != Some("system") {
            let from = last.get("from").and_then(Value::as_str).unwrap_or("");
            let out = last.get("out").and_then(Value::as_bool).unwrap_or(false);
            let who = if out {
                "Bạn".to_string()
            } else {
                let n = last.get("name").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string).unwrap_or_else(|| self.user_brief(from).0);
                n.split_whitespace().last().unwrap_or("").to_string()
            };
            if !who.is_empty() {
                preview = format!("{who}: {preview}");
            }
        } else if !group && last.get("out").and_then(Value::as_bool) == Some(true) {
            preview = format!("Bạn: {preview}");
        }
        let mut v = json!({
            "key": key, "group": group, "id": id, "name": name, "avatar": avatar, "ts": ts, "unread": unread,
            "pinned": pinned > 0, "muted": muted > 0, "preview": preview,
        });
        if group {
            v["members"] = json!(members);
        }
        if let (Some(s), Some(l)) = (seen, last_id) {
            if s == l && last.get("out").and_then(Value::as_bool) == Some(true) {
                v["seen"] = json!(true);
            }
        }
        if let Some(st) = last.get("status") {
            v["status"] = st.clone();
        }
        v
    }

    // ───── Người, nhóm ─────

    pub fn put_user(&mut self, u: &Value, friend: Option<bool>) {
        let uid = msg::s(u, "userId");
        if uid.is_empty() {
            return;
        }
        let name = msg::s(u, "displayName");
        let zname = msg::s(u, "zaloName");
        let avatar = msg::s(u, "avatar");
        let phone = msg::s(u, "phoneNumber");
        let _ = self.db.execute(
            "INSERT INTO users(uid, name, zname, avatar, phone, friend, json, updated) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, strftime('%s','now'))
             ON CONFLICT(uid) DO UPDATE SET name = CASE WHEN excluded.name != '' THEN excluded.name ELSE name END,
               zname = CASE WHEN excluded.zname != '' THEN excluded.zname ELSE zname END,
               avatar = CASE WHEN excluded.avatar != '' THEN excluded.avatar ELSE avatar END,
               phone = CASE WHEN excluded.phone != '' THEN excluded.phone ELSE phone END,
               friend = CASE WHEN ?8 THEN excluded.friend ELSE friend END, json = excluded.json, updated = excluded.updated",
            params![uid, name, zname, avatar, phone, friend.unwrap_or(false) as i64, u.to_string(), friend.is_some()],
        );
    }

    /// Tên gợi nhớ mình đặt cho `uid` ("" nếu chưa đặt).
    pub fn alias(&self, uid: &str) -> String {
        self.db.query_row("SELECT alias FROM users WHERE uid = ?1", [uid], |r| r.get::<_, String>(0)).optional().ok().flatten().unwrap_or_default()
    }

    /// Đặt / bỏ (alias rỗng) tên gợi nhớ của một người.
    pub fn set_alias(&mut self, uid: &str, alias: &str) {
        let _ = self.db.execute(
            "INSERT INTO users(uid, alias) VALUES(?1, ?2) ON CONFLICT(uid) DO UPDATE SET alias = excluded.alias",
            params![uid, alias.trim()],
        );
    }

    /// Thay toàn bộ tên gợi nhớ bằng danh sách từ máy chủ (đồng bộ với Zalo trên điện thoại).
    pub fn set_aliases(&mut self, items: &[(String, String)]) {
        let _ = self.db.execute("UPDATE users SET alias = '' WHERE alias != ''", []);
        for (uid, alias) in items {
            self.set_alias(uid, alias);
        }
    }

    /// Người 1-1 có cuộc trò chuyện mà chưa có thông tin (vd. mình nhắn trước cho người lạ) — cần hỏi getUserInfo.
    pub fn thread_users_missing(&self) -> Vec<String> {
        let mut st = match self.db.prepare(
            "SELECT substr(t.key, 2) FROM threads t LEFT JOIN users u ON u.uid = substr(t.key, 2)
             WHERE t.key LIKE 'u%' AND (u.uid IS NULL OR (u.name = '' AND u.zname = '') OR u.avatar = '')",
        ) {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        st.query_map([], |r| r.get::<_, String>(0)).map(|it| it.filter_map(|x| x.ok()).collect()).unwrap_or_default()
    }

    /// Ghi tên tạm (từ dName của tin) cho người chưa có.
    pub fn hint_user_name(&mut self, uid: &str, name: &str) {
        if uid.is_empty() || name.is_empty() {
            return;
        }
        let _ = self.db.execute("INSERT INTO users(uid, name) VALUES(?1, ?2) ON CONFLICT(uid) DO UPDATE SET name = CASE WHEN name = '' THEN excluded.name ELSE name END", params![uid, name]);
    }

    pub fn clear_friends(&mut self) {
        let _ = self.db.execute("UPDATE users SET friend = 0", []);
    }

    pub fn user_brief(&self, uid: &str) -> (String, String) {
        self.db
            .query_row("SELECT name, zname, avatar, alias FROM users WHERE uid = ?1", [uid], |r| {
                let n: String = r.get(0)?;
                let z: String = r.get(1)?;
                let a: String = r.get(3)?;
                Ok((pick_name(&a, &n, &z), r.get::<_, String>(2)?))
            })
            .optional()
            .ok()
            .flatten()
            .unwrap_or_default()
    }

    pub fn user(&self, uid: &str) -> Option<Value> {
        self.db
            .query_row("SELECT name, zname, avatar, phone, friend, json, alias FROM users WHERE uid = ?1", [uid], |r| {
                let mut v: Value = r.get::<_, Option<String>>(5)?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(json!({}));
                let n: String = r.get(0)?;
                let z: String = r.get(1)?;
                let a: String = r.get(6)?;
                v["uid"] = json!(uid);
                v["name"] = json!(pick_name(&a, &n, &z));
                v["alias"] = json!(a);
                // tên thật (không tính tên gợi nhớ) — để hiện «Tên Zalo: …» khi đã đặt tên gợi nhớ
                v["real_name"] = json!(if n.is_empty() { z.clone() } else { n });
                v["zname"] = json!(z);
                v["avatar"] = json!(r.get::<_, String>(2)?);
                v["phone"] = json!(r.get::<_, String>(3)?);
                v["friend"] = json!(r.get::<_, i64>(4)? != 0);
                Ok(v)
            })
            .optional()
            .ok()
            .flatten()
    }

    /// Người chưa có tên (cần hỏi getUserInfo).
    pub fn users_missing(&self, uids: &[String]) -> Vec<String> {
        uids.iter().filter(|u| self.user_brief(u).0.is_empty()).cloned().collect()
    }

    pub fn friends(&self) -> Vec<Value> {
        let mut st = match self.db.prepare("SELECT uid, name, zname, avatar, alias FROM users WHERE friend = 1 ORDER BY name COLLATE NOCASE") {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        st.query_map([], |r| {
            let n: String = r.get(1)?;
            let z: String = r.get(2)?;
            let a: String = r.get(4)?;
            Ok(json!({"uid": r.get::<_, String>(0)?, "name": pick_name(&a, &n, &z), "avatar": r.get::<_, String>(3)?}))
        })
        .map(|it| it.filter_map(|x| x.ok()).collect())
        .unwrap_or_default()
    }

    pub fn put_group(&mut self, gid: &str, g: &Value) {
        let name = msg::s(g, "name");
        let avatar = {
            let a = msg::s(g, "avt");
            if a.is_empty() { msg::s(g, "fullAvt") } else { a }
        };
        let members = msg::n(g, "totalMember");
        let ids = g.get("memberIds").or_else(|| g.get("memVerList")).map(|v| v.to_string());
        let _ = self.db.execute(
            "INSERT INTO groups(gid, name, avatar, members, member_ids, json, updated, left_group) VALUES(?1, ?2, ?3, ?4, ?5, ?6, strftime('%s','now'), 0)
             ON CONFLICT(gid) DO UPDATE SET name = excluded.name, avatar = excluded.avatar, members = excluded.members,
               member_ids = COALESCE(excluded.member_ids, member_ids), json = excluded.json, updated = excluded.updated, left_group = 0",
            params![gid, name, avatar, members, ids, g.to_string()],
        );
    }

    pub fn set_groups_present(&mut self, gids: &[String]) {
        let _ = self.db.execute("UPDATE groups SET left_group = 1", []);
        for g in gids {
            let _ = self.db.execute("INSERT INTO groups(gid) VALUES(?1) ON CONFLICT(gid) DO UPDATE SET left_group = 0", [g]);
        }
    }

    pub fn groups_missing(&self) -> Vec<String> {
        let mut st = match self.db.prepare("SELECT gid FROM groups WHERE left_group = 0 AND name = ''") {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        st.query_map([], |r| r.get(0)).map(|it| it.filter_map(|x| x.ok()).collect()).unwrap_or_default()
    }

    pub fn group_brief(&self, gid: &str) -> (String, String, i64) {
        self.db
            .query_row("SELECT name, avatar, members FROM groups WHERE gid = ?1", [gid], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .optional()
            .ok()
            .flatten()
            .unwrap_or_default()
    }

    pub fn group(&self, gid: &str) -> Option<Value> {
        self.db
            .query_row("SELECT name, avatar, members, json FROM groups WHERE gid = ?1", [gid], |r| {
                let raw: Value = r.get::<_, Option<String>>(3)?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(json!({}));
                Ok(json!({
                    "gid": gid, "name": r.get::<_, String>(0)?, "avatar": r.get::<_, String>(1)?, "members": r.get::<_, i64>(2)?,
                    "desc": raw.get("desc").cloned().unwrap_or(Value::Null),
                    "creator": raw.get("creatorId").cloned().unwrap_or(Value::Null),
                    "admins": raw.get("adminIds").cloned().unwrap_or(json!([])),
                    "member_ids": raw.get("memberIds").cloned().unwrap_or(json!([])),
                    // Cài đặt nhóm «Cho phép thành viên mới đọc tin nhắn gần nhất» (0 = máy chủ lọc lịch sử — isFiltered)
                    "history": raw.pointer("/setting/enableMsgHistory").cloned().unwrap_or(Value::Null),
                }))
            })
            .optional()
            .ok()
            .flatten()
    }

    pub fn groups(&self) -> Vec<Value> {
        let mut st = match self.db.prepare(
            "SELECT g.gid, g.name, g.avatar, g.members, COALESCE(t.last_ts, 0) AS ts FROM groups g LEFT JOIN threads t ON t.key = 'g' || g.gid
             WHERE g.left_group = 0 ORDER BY ts DESC, g.name COLLATE NOCASE",
        ) {
            Ok(s) => s,
            Err(_) => return vec![],
        };
        st.query_map([], |r| {
            Ok(json!({"gid": r.get::<_, String>(0)?, "name": r.get::<_, String>(1)?, "avatar": r.get::<_, String>(2)?,
                      "members": r.get::<_, i64>(3)?, "ts": r.get::<_, i64>(4)?}))
        })
        .map(|it| it.filter_map(|x| x.ok()).collect())
        .unwrap_or_default()
    }

    /// Xoá toàn bộ dữ liệu (đăng xuất).
    pub fn wipe(&mut self) {
        let _ = self.db.execute_batch("DELETE FROM msgs; DELETE FROM threads; DELETE FROM users; DELETE FROM groups; DELETE FROM kv;");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> Store {
        let p = std::env::temp_dir().join(format!("rz-store-{}.db", rand_id()));
        let _ = std::fs::remove_file(&p);
        Store::open(&p).unwrap()
    }

    fn rand_id() -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as u64
    }

    #[test]
    fn messages_threads_unread() {
        let mut st = tmp();
        st.put_user(&json!({"userId": "222", "displayName": "Lan Anh", "avatar": "https://a/1.jpg"}), Some(true));
        let r1 = json!({"msgId": "100", "cliMsgId": "1", "uidFrom": "222", "idTo": "0", "ts": "1000", "msgType": "webchat", "content": "chào"});
        let m1 = msg::normalize(&r1, "111", false).unwrap();
        assert!(st.put_msg(&m1, &r1));
        assert!(!st.put_msg(&m1, &r1));
        let t = st.threads(10);
        assert_eq!(t.len(), 1);
        assert_eq!(t[0]["name"], "Lan Anh");
        assert_eq!(t[0]["unread"], 1);
        assert_eq!(t[0]["preview"], "chào");
        st.mark_read("u222", 1000);
        assert_eq!(st.threads(10)[0]["unread"], 0);
        // Tin mình gửi: tạm → thật
        let dto = json!({"id": "l5", "cid": "5", "thread": "u222", "out": true, "kind": "text", "text": "ừ", "ts": 2000, "status": "sending"});
        st.put_pending("u222", "5", 2000, "111", &dto);
        assert_eq!(st.history("u222", 0, 10).len(), 2);
        let v = st.confirm_pending("u222", "5", "101").unwrap();
        assert_eq!(v["id"], "101");
        let r2 = json!({"msgId": "101", "cliMsgId": "5", "uidFrom": "0", "idTo": "222", "ts": "2001", "msgType": "webchat", "content": "ừ"});
        st.put_msg(&msg::normalize(&r2, "111", false).unwrap(), &r2);
        let h = st.history("u222", 0, 10);
        assert_eq!(h.len(), 2);
        assert_eq!(st.threads(10)[0]["preview"], "Bạn: ừ");
        assert_eq!(st.max_msg_id(false).as_deref(), Some("101"));
        // Thu hồi
        let v = st.recall("u222", "100", "1").unwrap();
        assert_eq!(v["kind"], "recall");
    }
}
