//! Danh thiếp, tài khoản ngân hàng + mã VietQR chuyển khoản, nhắc hẹn, tin nhắn nhanh.
//! Danh sách ngân hàng và tin nhắn nhanh giữ một bản trong CSDL (`kv`) để dùng khi mất mạng.

use rz_zalo::Thread;
use serde_json::{json, Value};

use crate::msg::{n, parse_key, s};
use crate::{now_ms, vietqr, Core, CoreError, R};

fn thread_of(key: &str) -> R<(Thread, String)> {
    let (group, id) = parse_key(key).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
    Ok((if group { Thread::Group } else { Thread::User }, id.to_string()))
}

/// Mảng trong kết quả: chính nó, hoặc trường `data` / `list` / `items` / `banks` / `accounts`.
fn as_list(v: &Value) -> Vec<Value> {
    if let Some(a) = v.as_array() {
        return a.clone();
    }
    for k in ["data", "list", "items", "banks", "accounts", "bank_accounts"] {
        if let Some(a) = v.get(k).and_then(Value::as_array) {
            return a.clone();
        }
    }
    Vec::new()
}

const DAY_MS: u64 = 24 * 3600 * 1000;

impl Core {
    fn kv_json(&self, k: &str) -> Option<Value> {
        self.store.lock().unwrap().kv_get(k).and_then(|s| serde_json::from_str(&s).ok())
    }

    fn kv_put_json(&self, k: &str, v: &Value) {
        let st = self.store.lock().unwrap();
        st.kv_set(k, &v.to_string());
        st.kv_set(&format!("{k}.ts"), &now_ms().to_string());
    }

    fn kv_age_ms(&self, k: &str) -> u64 {
        let ts = self.store.lock().unwrap().kv_get(&format!("{k}.ts")).and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
        now_ms().saturating_sub(ts)
    }

    // ───── Danh thiếp ─────

    pub(crate) async fn card_send(&self, thread: &str, uid: &str, phone: &str) -> R<Value> {
        let (t, id) = thread_of(thread)?;
        if uid.is_empty() {
            return Err(CoreError::new("BAD_ARGS", "Thiếu người cần gửi danh thiếp"));
        }
        let v = self.api()?.send_card(t, &id, uid, phone, self.next_cid()).await?;
        Ok(json!({"msgId": s(&v, "msgId")}))
    }

    // ───── Ngân hàng ─────

    /// `[{bin, name (tên ngắn), full, logo}]` — giữ một tuần trong CSDL.
    pub(crate) async fn bank_list(&self) -> R<Value> {
        let cached = self.kv_json("bank.list");
        if let Some(c) = &cached {
            if self.kv_age_ms("bank.list") < 7 * DAY_MS && c.as_array().is_some_and(|a| !a.is_empty()) {
                return Ok(c.clone());
            }
        }
        let fresh = async {
            let v = self.api()?.bank_list().await?;
            let list: Vec<Value> = as_list(&v)
                .iter()
                .filter(|b| n(b, "bin") > 0)
                .map(|b| {
                    let short = s(b, "short_name");
                    json!({"bin": n(b, "bin"), "name": if short.is_empty() { s(b, "name") } else { short }, "full": s(b, "name"),
                           "logo": s(b, "logo"), "key": s(b, "search_key_word")})
                })
                .collect();
            Ok::<Value, CoreError>(Value::Array(list))
        }
        .await;
        match fresh {
            Ok(list) if list.as_array().is_some_and(|a| !a.is_empty()) => {
                self.kv_put_json("bank.list", &list);
                Ok(list)
            }
            Ok(_) => cached.ok_or_else(|| CoreError::new("NETWORK", "Không lấy được danh sách ngân hàng")),
            Err(e) => cached.ok_or(e),
        }
    }

    /// Tài khoản ngân hàng đã lưu trong Zalo: `[{id, bin, number, holder, default}]`.
    pub(crate) async fn bank_accounts(&self) -> R<Value> {
        let v = self.api()?.bank_accounts().await?;
        let list: Vec<Value> = as_list(&v)
            .iter()
            .map(|a| {
                json!({"id": n(a, "id").max(n(a, "account_id")), "bin": n(a, "bin"), "number": s(a, "bank_number"),
                       "holder": s(a, "holder_name"), "default": a.get("is_default").or(a.get("default")).and_then(Value::as_bool).unwrap_or(false),
                       "bank": s(a, "bank_name")})
            })
            .collect();
        Ok(Value::Array(list))
    }

    pub(crate) async fn bank_account_add(&self, bin: i64, number: &str, holder: &str) -> R<Value> {
        if bin <= 0 || !vietqr::valid_account(number) {
            return Err(CoreError::new("BAD_ARGS", "Số tài khoản gồm 4–19 chữ số"));
        }
        match self.api()?.bank_account_add(bin, number, holder).await {
            Ok(_) => {}
            Err(e) if e.zalo_code == Some(-263) => {}  // đã có
            Err(e) => return Err(e.into()),
        }
        self.bank_accounts().await
    }

    pub(crate) async fn bank_account_remove(&self, id: i64, is_default: bool) -> R<Value> {
        self.api()?.bank_account_remove(id, is_default).await?;
        self.bank_accounts().await
    }

    pub(crate) async fn bank_send_card(&self, thread: &str, bin: i64, number: &str, holder: &str) -> R<Value> {
        let (t, id) = thread_of(thread)?;
        if bin <= 0 || !vietqr::valid_account(number) {
            return Err(CoreError::new("BAD_ARGS", "Số tài khoản gồm 4–19 chữ số"));
        }
        self.api()?.send_bank_card(t, &id, bin, number, holder, self.next_cid()).await?;
        Ok(json!({}))
    }

    /// Thẻ ngân hàng trong chat: tải mẫu zinstant (gzip) → BIN, số tài khoản, chủ tài khoản, tên ngân hàng → ghi vào tin
    /// (`media`), báo `msg.update`. Đã đọc rồi thì trả luôn.
    pub(crate) async fn bank_resolve(&self, thread: &str, id: &str) -> R<Value> {
        let mut dto = self.store.lock().unwrap().dto(thread, id).ok_or_else(|| CoreError::new("NOT_FOUND", "Không tìm thấy tin"))?;
        if !s(&dto["media"], "number").is_empty() {
            return Ok(dto);
        }
        let urls = [s(&dto["media"], "data_url"), s(&dto["media"], "pc_url")];
        let mut card = None;
        for url in urls.iter().filter(|u| !u.is_empty()) {
            let zh = self.http()?;
            let Ok(path) = self.media.fetch_ext(&zh, url, "file", "zin").await else { continue };
            let raw = std::fs::read(&path).map_err(|x| CoreError::new("IO", x.to_string()))?;
            let data = {
                use std::io::Read;
                let mut out = Vec::new();
                match flate2::read::GzDecoder::new(&raw[..]).read_to_end(&mut out) {
                    Ok(_) => out,
                    Err(_) => raw,  // không nén
                }
            };
            card = vietqr::bank_card(&data);
            if card.is_some() {
                break;
            }
        }
        let mut card = card.ok_or_else(|| CoreError::new("BANK", "Không đọc được thẻ tài khoản"))?;
        if s(&card, "bank").is_empty() {
            // tên ngân hàng theo BIN
            let bin = n(&card, "bin");
            if let Ok(list) = self.bank_list().await {
                if let Some(b) = list.as_array().and_then(|a| a.iter().find(|b| n(b, "bin") == bin)) {
                    card["bank"] = json!(s(b, "name"));
                }
            }
        }
        for k in ["bin", "number", "holder", "bank", "payload"] {
            dto["media"][k] = card[k].clone();
        }
        let short = { let b = s(&card, "bank"); if b.is_empty() { "Tài khoản ngân hàng".to_string() } else { b } };
        dto["text"] = json!(format!("[Tài khoản ngân hàng] {short} {}", s(&card, "number")));
        self.store.lock().unwrap().update_dto(thread, id, &dto);
        self.ev("msg.update", json!({"thread": thread, "msg": dto}));
        Ok(dto)
    }

    /// Mã VietQR: `{payload, size, bits}` (app vẽ).
    pub(crate) fn vietqr_make(&self, bin: i64, number: &str, amount: i64, note: &str) -> R<Value> {
        if bin <= 0 || !vietqr::valid_account(number) {
            return Err(CoreError::new("BAD_ARGS", "Số tài khoản gồm 4–19 chữ số"));
        }
        if !(0..=999_999_999_999).contains(&amount) {
            return Err(CoreError::new("BAD_ARGS", "Số tiền không hợp lệ"));
        }
        let p = vietqr::payload(&bin.to_string(), number, amount as u64, note);
        let mut m = vietqr::matrix(&p).ok_or_else(|| CoreError::new("QR", "Không tạo được mã QR"))?;
        m["payload"] = json!(p);
        Ok(m)
    }

    // ───── Bản đồ (ô OpenStreetMap) ─────

    /// Một ô bản đồ OpenStreetMap (256 × 256, PNG) → `{path}`, giữ trong bộ đệm. Bản đồ của MapKit trên iOS 5 / 6 không còn máy chủ
    /// ô; TLS của iOS 5 / 6 không vào được tile.openstreetmap.org → tải qua lõi. Theo quy định của OSM: User-Agent nêu tên app,
    /// tải ít (chỉ các ô đang xem, có đệm), app ghi «© OpenStreetMap».
    pub(crate) async fn map_tile(&self, z: i64, x: i64, y: i64) -> R<Value> {
        if !(1..=19).contains(&z) || x < 0 || y < 0 || x >= (1i64 << z) || y >= (1i64 << z) {
            return Err(CoreError::new("BAD_ARGS", "Ô bản đồ không hợp lệ"));
        }
        let path = self.cfg.cache_dir.join("osm").join(z.to_string()).join(x.to_string()).join(format!("{y}.png"));
        if path.exists() {
            return Ok(json!({"path": path.to_string_lossy()}));
        }
        let r = osm_client()?
            .get(format!("https://tile.openstreetmap.org/{z}/{x}/{y}.png"))
            .send()
            .await
            .map_err(|e| CoreError::new("NETWORK", format!("Không tải được bản đồ: {e}")))?;
        if !r.status().is_success() {
            return Err(CoreError::new("NETWORK", format!("Bản đồ: HTTP {}", r.status().as_u16())));
        }
        let data = r.bytes().await.map_err(|e| CoreError::new("NETWORK", format!("Không tải được bản đồ: {e}")))?;
        if let Some(d) = path.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, &data).and_then(|_| std::fs::rename(&tmp, &path)).map_err(|e| CoreError::new("IO", e.to_string()))?;
        Ok(json!({"path": path.to_string_lossy()}))
    }

    /// Địa chỉ của một toạ độ (Nominatim của OpenStreetMap, tiếng Việt) → `{address}` (rỗng nếu không có).
    pub(crate) async fn map_address(&self, lat: f64, lng: f64) -> R<Value> {
        if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lng) {
            return Err(CoreError::new("BAD_ARGS", "Toạ độ không hợp lệ"));
        }
        let url = format!("https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat={lat:.6}&lon={lng:.6}&zoom=18&accept-language=vi");
        let v: Value = osm_client()?
            .get(url)
            .send()
            .await
            .map_err(|e| CoreError::new("NETWORK", format!("Không tra được địa chỉ: {e}")))?
            .json()
            .await
            .map_err(|_| CoreError::new("NETWORK", "Địa chỉ: dữ liệu lạ"))?;
        // display_name đủ cả tỉnh / nước — giữ 4 phần đầu cho gọn
        let full = s(&v, "display_name");
        let short: Vec<&str> = full.split(", ").filter(|p| *p != "Việt Nam").take(4).collect();
        Ok(json!({"address": short.join(", ")}))
    }

    // ───── Nhắc hẹn ─────

    /// `[{id, title, emoji, ts, repeat, creator}]` mới → cũ.
    pub(crate) async fn reminders_list(&self, thread: &str) -> R<Value> {
        let (t, id) = thread_of(thread)?;
        let v = match self.api()?.reminder_list(t, &id, 1, 50).await {
            Ok(v) => v,
            Err(e) if e.zalo_code == Some(-1) => return Ok(json!([])),  // máy chủ báo -1 khi chưa có nhắc hẹn nào
            Err(e) => return Err(e.into()),
        };
        let mut list: Vec<Value> = as_list(&v)
            .iter()
            .map(|r| {
                // nhóm: params là chuỗi JSON; riêng: đối tượng
                let params = match r.get("params") {
                    Some(Value::String(p)) => serde_json::from_str::<Value>(p).unwrap_or(Value::Null),
                    Some(p) => p.clone(),
                    None => Value::Null,
                };
                let title = { let t = s(&params, "title"); if t.is_empty() { s(r, "title") } else { t } };
                let rid = { let a = s(r, "reminderId"); if a.is_empty() { s(r, "id") } else { a } };
                let rid = if rid.is_empty() { s(r, "topicId") } else { rid };
                let creator = { let c = s(r, "creatorUid"); if c.is_empty() { s(r, "creatorId") } else { c } };
                json!({"id": rid, "title": title, "emoji": s(r, "emoji"), "ts": n(r, "startTime"), "repeat": n(r, "repeat"), "creator": creator})
            })
            .filter(|r| !s(r, "id").is_empty())
            .collect();
        list.sort_by_key(|r| -n(r, "ts"));
        Ok(Value::Array(list))
    }

    pub(crate) async fn reminder_save(&self, thread: &str, id: &str, title: &str, emoji: &str, ts: i64, repeat: i64) -> R<Value> {
        let (t, tid) = thread_of(thread)?;
        let title = title.trim();
        if title.is_empty() {
            return Err(CoreError::new("BAD_ARGS", "Nhập nội dung nhắc hẹn"));
        }
        if ts <= 0 {
            return Err(CoreError::new("BAD_ARGS", "Chọn thời gian nhắc"));
        }
        let repeat = repeat.clamp(0, 3);
        let api = self.api()?;
        if id.is_empty() {
            api.reminder_create(t, &tid, title, emoji, ts as u64, repeat).await?;
        } else {
            api.reminder_edit(t, &tid, id, title, if emoji.is_empty() { "⏰" } else { emoji }, ts as u64, repeat).await?;
        }
        self.reminders_list(thread).await
    }

    pub(crate) async fn reminder_remove(&self, thread: &str, id: &str) -> R<Value> {
        let (t, tid) = thread_of(thread)?;
        self.api()?.reminder_remove(t, &tid, id).await?;
        self.reminders_list(thread).await
    }

    // ───── Tin nhắn nhanh ─────

    /// `[{id, keyword, text}]`. `refresh` = hỏi máy chủ; không thì bản trong CSDL (rỗng thì hỏi).
    pub(crate) async fn quick_list(&self, refresh: bool) -> R<Value> {
        let cached = self.kv_json("quick.list");
        if !refresh {
            if let Some(c) = &cached {
                if self.kv_age_ms("quick.list") < DAY_MS {
                    return Ok(c.clone());
                }
            }
        }
        let fresh = async {
            let v = self.api()?.quick_list().await?;
            let list: Vec<Value> = as_list(&v)
                .iter()
                .map(|q| json!({"id": n(q, "id"), "keyword": s(q, "keyword"), "text": q.pointer("/message/title").and_then(Value::as_str).unwrap_or("")}))
                .filter(|q| n(q, "id") != 0)
                .collect();
            Ok::<Value, CoreError>(Value::Array(list))
        }
        .await;
        match fresh {
            Ok(list) => {
                self.kv_put_json("quick.list", &list);
                Ok(list)
            }
            Err(e) => cached.ok_or(e),
        }
    }

    pub(crate) async fn quick_save(&self, id: i64, keyword: &str, text: &str) -> R<Value> {
        let keyword: String = keyword.trim().trim_start_matches('/').chars().filter(|c| !c.is_whitespace()).collect();
        if keyword.is_empty() || text.trim().is_empty() {
            return Err(CoreError::new("BAD_ARGS", "Nhập phím tắt và nội dung"));
        }
        let api = self.api()?;
        if id == 0 {
            api.quick_add(&keyword, text.trim()).await?;
        } else {
            api.quick_update(id, &keyword, text.trim()).await?;
        }
        self.quick_list(true).await
    }

    pub(crate) async fn quick_remove(&self, id: i64) -> R<Value> {
        self.api()?.quick_remove(&[id]).await?;
        self.quick_list(true).await
    }
}

/// HTTP cho OpenStreetMap (ô bản đồ, địa chỉ): User-Agent nêu tên app theo quy định của OSM.
fn osm_client() -> R<&'static reqwest::Client> {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    if let Some(c) = CLIENT.get() {
        return Ok(c);
    }
    let c = reqwest::Client::builder()
        .user_agent(concat!("Roza/", env!("CARGO_PKG_VERSION"), " (Zalo client for iOS 5/6; +https://github.com/itovn/Roza)"))
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| CoreError::new("NETWORK", format!("HTTP: {e}")))?;
    let _ = CLIENT.set(c);
    CLIENT.get().ok_or_else(|| CoreError::new("NETWORK", "HTTP"))
}
