//! Đổi tin nhắn của Zalo (TMessage / TGroupMessage của zca-js) thành dạng sẵn hiển thị cho app (`Msg` → JSON, docs/FFI.md).

use serde_json::{json, Value};

/// Khoá cuộc trò chuyện: `u<uid>` (người) / `g<grid>` (nhóm).
pub fn thread_key(group: bool, id: &str) -> String {
    format!("{}{}", if group { 'g' } else { 'u' }, id)
}

/// Tách khoá → (nhóm?, id).
pub fn parse_key(key: &str) -> Option<(bool, &str)> {
    match key.as_bytes().first()? {
        b'u' => Some((false, &key[1..])),
        b'g' => Some((true, &key[1..])),
        _ => None,
    }
}

pub fn s(v: &Value, k: &str) -> String {
    match v.get(k) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

pub fn n(v: &Value, k: &str) -> i64 {
    match v.get(k) {
        Some(Value::Number(n)) => n.as_i64().unwrap_or_else(|| n.as_f64().unwrap_or(0.0) as i64),
        Some(Value::String(s)) => s.trim().parse().unwrap_or(0),
        _ => 0,
    }
}

/// `params` của nội dung đính kèm: chuỗi JSON hoặc đối tượng.
fn params(c: &Value) -> Value {
    match c.get("params") {
        Some(Value::String(p)) => serde_json::from_str(p).unwrap_or(Value::Null),
        Some(v @ Value::Object(_)) => v.clone(),
        _ => Value::Null,
    }
}

/// Tin đã chuẩn hoá + thông tin để lưu.
pub struct Norm {
    pub thread: String,
    pub id: String,
    pub cid: String,
    pub ts: i64,
    pub from: String,
    pub out: bool,
    /// JSON cho app.
    pub dto: Value,
    /// Tin thu hồi: (msgId, cliMsgId) của tin gốc.
    pub undo: Option<(String, String)>,
}

/// Chuẩn hoá một tin. `me` = uid của mình; `group` = tin nhóm.
pub fn normalize(raw: &Value, me: &str, group: bool) -> Option<Norm> {
    let from_raw = s(raw, "uidFrom");
    let to_raw = s(raw, "idTo");
    let out = from_raw == "0" || from_raw == me;
    let from = if from_raw == "0" { me.to_string() } else { from_raw.clone() };
    let tid = if group || out { if to_raw == "0" { me.to_string() } else { to_raw.clone() } } else { from_raw.clone() };
    if tid.is_empty() {
        return None;
    }
    let thread = thread_key(group, &tid);
    let id = s(raw, "msgId");
    let cid = s(raw, "cliMsgId");
    let ts = n(raw, "ts");
    let msg_type = s(raw, "msgType");
    let content = raw.get("content").cloned().unwrap_or(Value::Null);

    if let Value::Object(c) = &content {
        if c.contains_key("deleteMsg") {
            let oid = s(&content, "globalMsgId");
            let ocid = s(&content, "cliMsgId");
            return Some(Norm { thread, id, cid, ts, from, out, dto: Value::Null, undo: Some((oid, ocid)) });
        }
    }

    let (kind, text, media) = describe(&msg_type, &content);
    let mut dto = json!({
        "id": id, "cid": cid, "thread": thread, "from": from, "out": out, "ts": ts,
        "type": msg_type, "kind": kind, "text": text, "name": s(raw, "dName"),
    });
    if !media.is_null() {
        dto["media"] = media;
    }
    if let Some(q) = raw.get("quote").filter(|q| q.is_object()) {
        let qtext = {
            let m = s(q, "msg");
            if !m.is_empty() {
                m
            } else {
                attach_summary(q.get("attach"))
            }
        };
        dto["quote"] = json!({
            "from": s(q, "ownerId"), "name": s(q, "fromD"), "text": qtext,
            "id": s(q, "globalMsgId"), "cid": s(q, "cliMsgId"),
        });
    }
    if let Some(m) = raw.get("mentions").and_then(Value::as_array).filter(|a| !a.is_empty()) {
        dto["mentions"] = Value::Array(m.iter().map(|x| json!({"uid": s(x, "uid"), "pos": n(x, "pos"), "len": n(x, "len")})).collect());
    }
    if n(raw, "ttl") > 0 {
        dto["ttl"] = json!(n(raw, "ttl"));
    }
    Some(Norm { thread, id, cid, ts, from, out, dto, undo: None })
}

fn attach_summary(a: Option<&Value>) -> String {
    let Some(a) = a else { return String::new() };
    let v = match a {
        Value::String(s) => serde_json::from_str(s).unwrap_or(Value::Null),
        v => v.clone(),
    };
    let t = s(&v, "title");
    if !t.is_empty() { t } else { "[Đính kèm]".into() }
}

/// (kind, chữ / tóm tắt, media)
pub fn describe(msg_type: &str, c: &Value) -> (&'static str, String, Value) {
    if let Value::String(t) = c {
        return ("text", t.clone(), Value::Null);
    }
    let p = params(c);
    let title = s(c, "title");
    let desc = s(c, "description");
    let href = s(c, "href");
    let thumb = s(c, "thumb");
    match msg_type {
        // Dòng thông báo (vd. «X tạo nhắc hẹn mới …») — Zalo gửi kiểu webchat có action, hiện giữa màn như tin hệ thống
        "webchat" if s(c, "action") == "msginfo.actionlist" => ("system", if title.is_empty() { desc } else { title }, Value::Null),
        "webchat" => ("text", if title.is_empty() { desc } else { title }, Value::Null),
        "chat.photo" => {
            let hd = s(&p, "hd");
            let w = n(&p, "width");
            let h = n(&p, "height");
            ("photo", title, json!({"url": if hd.is_empty() { href.clone() } else { hd }, "normal": href, "thumb": thumb, "w": w, "h": h}))
        }
        "chat.doodle" => ("photo", "[Hình vẽ]".into(), json!({"url": href, "normal": href, "thumb": thumb, "w": n(&p, "width"), "h": n(&p, "height")})),
        "chat.gif" => ("gif", "[GIF]".into(), json!({"url": href, "thumb": thumb, "w": n(&p, "width"), "h": n(&p, "height")})),
        "chat.sticker" => ("sticker", "[Sticker]".into(), json!({"id": n(c, "id"), "cat": n(c, "catId"), "type": n(c, "type")})),
        "chat.voice" => ("voice", "[Tin nhắn thoại]".into(), json!({"url": href, "dur": n(&p, "duration")})),
        "chat.video.msg" => (
            "video",
            "[Video]".into(),
            json!({"url": href, "thumb": thumb, "dur": n(&p, "duration"), "w": n(&p, "video_width"), "h": n(&p, "video_height")}),
        ),
        "share.file" => {
            let size = n(&p, "fileSize");
            ("file", format!("[Tệp] {title}"), json!({"name": title, "url": href, "size": size, "ext": s(&p, "fileExt")}))
        }
        "chat.recommended" | "chat.link" => {
            let action = s(c, "action");
            if action.contains("user") {
                // danh thiếp: params là chính uid (số), hoặc đối tượng có uid
                let uid = match c.get("params") {
                    Some(Value::Number(x)) => x.to_string(),
                    Some(Value::String(x)) if x.chars().all(|ch| ch.is_ascii_digit()) && !x.is_empty() => x.clone(),
                    _ => s(&p, "uid"),
                };
                ("contact", format!("[Danh thiếp] {title}"), json!({"uid": uid, "name": title, "avatar": thumb, "phone": s(&p, "phone")}))
            } else {
                let text = if !href.is_empty() && !title.contains(&href) { title.clone() } else { title.clone() };
                ("link", if text.is_empty() { href.clone() } else { text }, json!({"url": href, "title": title, "desc": desc, "thumb": thumb}))
            }
        }
        "chat.location.new" => {
            let lat = p.get("latitude").and_then(Value::as_f64).unwrap_or(0.0);
            let lng = p.get("longitude").and_then(Value::as_f64).unwrap_or(0.0);
            ("location", format!("[Vị trí] {}", if title.is_empty() { desc.clone() } else { title.clone() }), json!({"lat": lat, "lng": lng, "title": title}))
        }
        "chat.todo" => {
            let t = p.pointer("/item/content").and_then(Value::as_str).unwrap_or("").to_string();
            ("text", if t.is_empty() { "[Công việc]".into() } else { format!("[Công việc] {t}") }, Value::Null)
        }
        "group.poll" => ("poll", format!("[Bình chọn] {title}"), Value::Null),
        "chat.ecard" => match reminder_of(c, &p) {
            Some((id, ts, rtitle, emoji, repeat)) => {
                let t = format!("{} {rtitle}", if emoji.is_empty() { "⏰".to_string() } else { emoji.clone() });
                ("reminder", if desc.is_empty() { t } else { format!("{t}
{desc}") }, json!({"id": id, "ts": ts, "title": rtitle, "emoji": emoji, "repeat": repeat, "when": desc}))
            }
            None => ("system", if desc.is_empty() { title } else { desc }, Value::Null),
        },
        // Thẻ tài khoản ngân hàng (sendBankCard): dữ liệu nằm trong mẫu zinstant tải riêng — lõi đọc khi cần (`bank.resolve`)
        "chat.webcontent" if s(c, "action") == "zinstant.bankcard" => (
            "bank",
            "[Tài khoản ngân hàng]".into(),
            json!({"data_url": p.pointer("/item/data_url").and_then(Value::as_str).unwrap_or(""),
                   "pc_url": p.pointer("/pcItem/data_url").and_then(Value::as_str).unwrap_or("")}),
        ),
        "chat.webcontent" => {
            let t = p.pointer("/customMsg/msg/vi").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| title.clone());
            ("other", if t.is_empty() { "[Tin nhắn chưa hỗ trợ]".into() } else { t }, Value::Null)
        }
        _ => {
            let t = if !title.is_empty() { title } else if !desc.is_empty() { desc } else { "[Tin nhắn chưa hỗ trợ]".into() };
            ("other", t, if href.is_empty() { Value::Null } else { json!({"url": href, "thumb": thumb}) })
        }
    }
}

/// Nhắc hẹn trong thẻ `chat.ecard`: (mã, giờ ms, nội dung, biểu tượng, lặp lại 0–3). Dữ liệu ở `params.actions[].data` (chuỗi JSON lồng hai lớp).
fn reminder_of(c: &Value, p: &Value) -> Option<(String, i64, String, String, i64)> {
    if !s(c, "href").contains("reminder") && !p.to_string().contains("reminderId") {
        return None;
    }
    for a in p.get("actions").and_then(Value::as_array).cloned().unwrap_or_default() {
        let outer: Value = match a.get("data") {
            Some(Value::String(d)) => serde_json::from_str(d).unwrap_or(Value::Null),
            Some(v) => v.clone(),
            None => continue,
        };
        let inner: Value = match outer.get("data") {
            Some(Value::String(d)) => serde_json::from_str(d).unwrap_or(Value::Null),
            Some(v) => v.clone(),
            None => outer.clone(),
        };
        let id = { let a = s(&inner, "reminderId"); if a.is_empty() { s(&inner, "topicId") } else { a } };
        if id.is_empty() {
            continue;
        }
        let ip = match inner.get("params") {
            Some(Value::String(x)) => serde_json::from_str(x).unwrap_or(Value::Null),
            Some(v) => v.clone(),
            None => Value::Null,
        };
        let mut title = s(&ip, "title");
        if title.is_empty() {
            title = s(p, "notifyTxt").trim_start_matches('⏰').trim().to_string();
        }
        return Some((id, n(&inner, "startTime"), title, s(&inner, "emoji"), n(&inner, "repeat")));
    }
    let t = s(p, "notifyTxt");
    if t.is_empty() {
        None
    } else {
        Some((String::new(), 0, t.trim_start_matches('⏰').trim().to_string(), "⏰".into(), 0))
    }
}

/// Câu xem trước ngắn cho danh sách chat.
pub fn preview(dto: &Value) -> String {
    let kind = dto.get("kind").and_then(Value::as_str).unwrap_or("");
    let text = dto.get("text").and_then(Value::as_str).unwrap_or("");
    let t = match kind {
        "photo" => "[Hình ảnh]".to_string(),
        "recall" => "Tin nhắn đã được thu hồi".to_string(),
        _ => text.replace('\n', " "),
    };
    t.chars().take(120).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_in_and_out() {
        let r = json!({"msgId": "10", "cliMsgId": "11", "uidFrom": "0", "idTo": "222", "ts": "1700000000000", "msgType": "webchat", "content": "chào"});
        let m = normalize(&r, "111", false).unwrap();
        assert_eq!(m.thread, "u222");
        assert!(m.out);
        assert_eq!(m.from, "111");
        assert_eq!(m.dto["text"], "chào");
        let r = json!({"msgId": "12", "cliMsgId": "13", "uidFrom": "222", "idTo": "0", "ts": 1700000000001u64, "msgType": "webchat", "content": "hi"});
        let m = normalize(&r, "111", false).unwrap();
        assert_eq!(m.thread, "u222");
        assert!(!m.out);
    }

    #[test]
    fn group_photo_and_undo() {
        let r = json!({"msgId": "1", "cliMsgId": "2", "uidFrom": "333", "idTo": "999", "ts": "5", "msgType": "chat.photo",
                        "content": {"href": "https://x/a.jpg", "thumb": "https://x/t.jpg", "params": "{\"width\":640,\"height\":480,\"hd\":\"https://x/hd.jpg\"}"}});
        let m = normalize(&r, "111", true).unwrap();
        assert_eq!(m.thread, "g999");
        assert_eq!(m.dto["kind"], "photo");
        assert_eq!(m.dto["media"]["url"], "https://x/hd.jpg");
        assert_eq!(m.dto["media"]["w"], 640);
        let u = json!({"msgId": "3", "cliMsgId": "4", "uidFrom": "333", "idTo": "999", "ts": "6", "msgType": "chat.undo",
                        "content": {"globalMsgId": 1, "cliMsgId": 2, "deleteMsg": 1}});
        let m = normalize(&u, "111", true).unwrap();
        assert_eq!(m.undo, Some(("1".into(), "2".into())));
    }

    /// Cấu trúc thật (gửi thử vào «Cloud của tôi», 17/11/2026).
    #[test]
    fn card_bank_reminder() {
        // Danh thiếp: params là chính uid (số)
        let c = json!({"msgId": "20", "cliMsgId": "21", "uidFrom": "0", "idTo": "555", "ts": "1", "msgType": "chat.recommended",
                       "content": {"action": "recommened.user", "params": 1234567890123456789u64, "title": "Lan",
                                   "thumb": "https://a/x.jpg", "description": "{\"qrCodeUrl\":\"https://q/1.jpg\"}", "href": "www.zaloapp.com"}});
        let m = normalize(&c, "111", false).unwrap();
        assert_eq!(m.dto["kind"], "contact");
        assert_eq!(m.dto["media"]["uid"], "1234567890123456789");
        assert_eq!(m.dto["media"]["name"], "Lan");
        // Thẻ ngân hàng: dữ liệu ở mẫu zinstant
        let b = json!({"msgId": "22", "cliMsgId": "23", "uidFrom": "0", "idTo": "555", "ts": "2", "msgType": "chat.webcontent",
                       "content": {"action": "zinstant.bankcard", "params": "{\"item\":{\"data_url\":\"https://zinst/a\"},\"pcItem\":{\"data_url\":\"https://zinst/b\"},\"customMsg\":{\"msg\":{\"vi\":\"[Tài khoản ngân hàng]\"}}}"}});
        let m = normalize(&b, "111", false).unwrap();
        assert_eq!(m.dto["kind"], "bank");
        assert_eq!(m.dto["media"]["data_url"], "https://zinst/a");
        // Nhắc hẹn: chat.ecard, dữ liệu lồng hai lớp chuỗi JSON
        let inner = json!({"reminderId": "2161", "startTime": 1794993163243u64, "params": {"title": "Họp"}, "emoji": "⏰", "repeat": 2}).to_string();
        let outer = json!({"act": "create_reminder11", "data": inner}).to_string();
        let params = json!({"notifyTxt": "⏰ Họp", "actions": [{"data": outer}]}).to_string();
        let e = json!({"msgId": "24", "cliMsgId": "25", "uidFrom": "0", "idTo": "555", "ts": "3", "msgType": "chat.ecard",
                       "content": {"action": "show.profile", "href": "https://res/reminder_2.png", "description": "Thứ Tư, 18 tháng 11 lúc 16:12",
                                   "params": params}});
        let m = normalize(&e, "111", false).unwrap();
        assert_eq!(m.dto["kind"], "reminder");
        assert_eq!(m.dto["media"]["id"], "2161");
        assert_eq!(m.dto["media"]["title"], "Họp");
        assert_eq!(m.dto["media"]["repeat"], 2);
        assert!(m.dto["text"].as_str().unwrap().starts_with("⏰ Họp"));
        // Dòng thông báo «… tạo nhắc hẹn mới …» → tin hệ thống
        let t = json!({"msgId": "26", "cliMsgId": "27", "uidFrom": "0", "idTo": "555", "ts": "4", "msgType": "webchat",
                       "content": {"action": "msginfo.actionlist", "title": "Lan tạo nhắc hẹn mới Họp - 16:12."}});
        assert_eq!(normalize(&t, "111", false).unwrap().dto["kind"], "system");
    }
}
