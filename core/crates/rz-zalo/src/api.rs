//! Các lệnh API HTTP của Zalo Web (chuyển từ zca-js `apis/*.ts`, MIT). Mỗi lệnh: tham số JSON → mã hoá bằng khoá phiên →
//! `params=` (GET trong URL hoặc POST dạng form) → kết quả `{error_code, data}` với `data` mã hoá → JSON.

use serde_json::{json, Map, Value};

use crate::crypto;
use crate::http::{make_url, Body, Http};
use crate::login::LoginInfo;
use crate::{now_ms, Error};

/// Loại cuộc trò chuyện.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Thread {
    User,
    Group,
}

/// Trích dẫn khi trả lời một tin (`SendMessageQuote`).
#[derive(Clone, Debug)]
pub struct Quote {
    pub uid_from: String,
    pub msg_id: String,
    pub cli_msg_id: String,
    pub msg_type: String,
    pub ts: i64,
    pub ttl: i64,
    /// Nội dung gốc: chuỗi (tin chữ) hoặc đối tượng (ảnh, tệp…).
    pub content: Value,
    pub property_ext: Value,
}

/// Một người được nhắc (@) trong tin nhóm: vị trí / độ dài theo UTF-16.
#[derive(Clone, Debug)]
pub struct Mention {
    pub pos: usize,
    pub len: usize,
    pub uid: String,
}

/// Thông tin tin nhắn để báo đã xem / đã nhận.
#[derive(Clone, Debug)]
pub struct MsgRef {
    pub msg_id: String,
    pub cli_msg_id: String,
    pub uid_from: String,
    pub id_to: String,
    pub msg_type: String,
}

#[derive(Clone)]
pub struct Api {
    pub info: LoginInfo,
    pub http: Http,
}

/// Thân multipart/form-data một trường tệp (như gói form-data của zca-js) → (boundary, thân).
pub fn multipart_file(field: &str, file_name: &str, data: &[u8]) -> (String, Vec<u8>) {
    multipart_file_typed(field, file_name, "application/octet-stream", data)
}

pub fn multipart_file_typed(field: &str, file_name: &str, content_type: &str, data: &[u8]) -> (String, Vec<u8>) {
    let boundary = format!("----------------------------{}", crate::crypto::random_hex(24, 24));
    let safe_name = file_name.replace(['"', '\r', '\n'], "_");
    let mut body = Vec::with_capacity(data.len() + 256);
    body.extend_from_slice(
        format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{safe_name}\"\r\nContent-Type: {content_type}\r\n\r\n").as_bytes(),
    );
    body.extend_from_slice(data);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    (boundary, body)
}

/// `getClientMessageType`.
pub fn client_msg_type(t: &str) -> i64 {
    match t {
        "webchat" => 1,
        "chat.voice" => 31,
        "chat.photo" => 32,
        "chat.sticker" => 36,
        "chat.doodle" => 37,
        "chat.recommended" | "chat.link" => 38,
        "chat.video.msg" => 44,
        "share.file" => 46,
        "chat.gif" => 49,
        "chat.location.new" => 43,
        _ => 1,
    }
}

impl Api {
    pub fn new(info: LoginInfo, http: Http) -> Self {
        Self { info, http }
    }

    pub fn uid(&self) -> &str {
        &self.info.uid
    }

    fn ver(&self) -> Option<(u32, u32)> {
        Some((self.info.api_type, self.info.api_version))
    }

    /// URL của một dịch vụ: `<máy chủ dịch vụ><path>?<extra>&zpw_ver&zpw_type`.
    pub fn service_url(&self, service: &str, path: &str, extra: &[(&str, String)]) -> Result<String, Error> {
        let base = self.info.service(service).ok_or_else(|| Error::protocol(format!("Thiếu máy chủ dịch vụ «{service}»")))?;
        Ok(make_url(&format!("{base}{path}"), extra, self.ver()))
    }

    fn enc(&self, params: &Value) -> Result<String, Error> {
        crypto::encode_aes(&self.info.secret_key, &params.to_string())
    }

    /// Đọc kết quả (`handleZaloResponse`): `encrypted` = `data` là chuỗi mã hoá.
    fn resolve(&self, r: crate::http::Response, encrypted: bool) -> Result<Value, Error> {
        if !r.ok() {
            return Err(Error::network(format!("Máy chủ Zalo trả HTTP {}", r.status)));
        }
        let v = r.json()?;
        let ec = v.get("error_code").and_then(Value::as_i64).unwrap_or(0);
        if ec != 0 {
            return Err(Error::zalo(ec, v.get("error_message").and_then(Value::as_str).unwrap_or("Lỗi máy chủ Zalo")));
        }
        let d = if encrypted {
            let s = v.get("data").and_then(Value::as_str).ok_or_else(|| Error::protocol("Kết quả thiếu dữ liệu mã hoá"))?;
            let plain = crypto::decode_aes(&self.info.secret_key, s)?;
            serde_json::from_str::<Value>(&plain).map_err(|_| Error::protocol("Kết quả giải mã không phải JSON"))?
        } else {
            v
        };
        let ec = d.get("error_code").and_then(Value::as_i64).unwrap_or(0);
        if ec != 0 {
            return Err(Error::zalo(ec, d.get("error_message").and_then(Value::as_str).unwrap_or("Lỗi máy chủ Zalo")));
        }
        let mut data = d.get("data").cloned().unwrap_or(Value::Null);
        // Vài lệnh trả `data` là chuỗi JSON
        if let Value::String(s) = &data {
            if let Ok(p) = serde_json::from_str::<Value>(s) {
                if p.is_object() || p.is_array() {
                    data = p;
                }
            }
        }
        Ok(data)
    }

    /// GET với `params=<mã hoá>` trong URL.
    pub async fn get_enc(&self, service: &str, path: &str, params: Value) -> Result<Value, Error> {
        let url = self.service_url(service, path, &[("params", self.enc(&params)?)])?;
        let r = self.http.get(&url, &self.http.api_headers()).await?;
        self.resolve(r, true)
    }

    /// GET không tham số.
    pub async fn get_plain(&self, service: &str, path: &str) -> Result<Value, Error> {
        let url = self.service_url(service, path, &[])?;
        let r = self.http.get(&url, &self.http.api_headers()).await?;
        self.resolve(r, true)
    }

    /// POST form `params=<mã hoá>`; `extra` thêm vào URL (vd. nretry=0).
    pub async fn post_enc(&self, service: &str, path: &str, extra: &[(&str, String)], params: Value) -> Result<Value, Error> {
        let url = self.service_url(service, path, extra)?;
        let r = self
            .http
            .request(reqwest::Method::POST, &url, &self.http.api_headers(), Body::Form(vec![("params".into(), self.enc(&params)?)]), None)
            .await?;
        self.resolve(r, true)
    }

    // ───── Tài khoản, bạn bè, nhóm ─────

    /// `fetchAccountInfo` → `{profile: User}`.
    pub async fn account_info(&self) -> Result<Value, Error> {
        self.get_plain("profile", "/api/social/profile/me-v2").await
    }

    /// `getAllFriends` → `[User]`.
    pub async fn friends(&self, avatar_size: u32) -> Result<Value, Error> {
        self.get_enc(
            "profile",
            "/api/social/friend/getfriends",
            json!({"incInvalid": 1, "page": 1, "count": 20000, "avatar_size": avatar_size, "actiontime": 0, "imei": self.info.imei}),
        )
        .await
    }

    /// `getAllGroups` → `{version, gridVerMap: {grid: ver}}`.
    pub async fn groups(&self) -> Result<Value, Error> {
        self.get_plain("group_poll", "/api/group/getlg/v4").await
    }

    /// `getGroupInfo` → `{gridInfoMap: {grid: GroupInfo}}` (tối đa ~50 nhóm một lần).
    pub async fn group_info(&self, ids: &[String]) -> Result<Value, Error> {
        let map: Map<String, Value> = ids.iter().map(|id| (id.clone(), json!(0))).collect();
        self.post_enc("group", "/api/group/getmg-v2", &[], json!({"gridVerMap": Value::Object(map).to_string()})).await
    }

    /// `getUserInfo` → `{changed_profiles: {uid: User}}`.
    pub async fn user_info(&self, ids: &[String], avatar_size: u32) -> Result<Value, Error> {
        let list: Vec<String> = ids.iter().map(|id| if id.contains('_') { id.clone() } else { format!("{id}_0") }).collect();
        let phonebook = self.info.extra_ver.get("phonebook").cloned().unwrap_or(json!(0));
        self.post_enc(
            "profile",
            "/api/social/friend/getprofiles/v2",
            &[],
            json!({"phonebook_version": phonebook, "friend_pversion_map": list, "avatar_size": avatar_size,
                   "language": "vi", "show_online_status": 1, "imei": self.info.imei}),
        )
        .await
    }

    /// `getPinConversations` → `{conversations: ["u123", "g456"], version}`.
    pub async fn pinned(&self) -> Result<Value, Error> {
        self.get_enc("conversation", "/api/pinconvers/list", json!({"imei": self.info.imei})).await
    }

    /// `getFriendOnlines` → `{onlines: [{userId, status}]}`.
    pub async fn friend_onlines(&self) -> Result<Value, Error> {
        self.get_enc("profile", "/api/social/friend/onlines", json!({"imei": self.info.imei})).await
    }

    /// `lastOnline` → `{lastOnline (giây), settings: {show_online_status}}`.
    pub async fn last_online(&self, uid: &str) -> Result<Value, Error> {
        self.get_enc("profile", "/api/social/profile/lastOnline", json!({"uid": uid, "conv_type": 1, "imei": self.info.imei})).await
    }

    /// `getMute` → danh sách cuộc trò chuyện tắt thông báo.
    pub async fn mutes(&self) -> Result<Value, Error> {
        self.get_enc("profile", "/api/social/profile/getmute", json!({"imei": self.info.imei})).await
    }

    /// `keepAlive` (kết quả không mã hoá).
    pub async fn keep_alive(&self) -> Result<Value, Error> {
        let url = self.service_url("chat", "/keepalive", &[("params", self.enc(&json!({"imei": self.info.imei}))?)])?;
        let r = self.http.get(&url, &self.http.api_headers()).await?;
        self.resolve(r, false)
    }

    /// `findUser` (theo số điện thoại).
    pub async fn find_user(&self, phone: &str) -> Result<Value, Error> {
        let mut p = phone.trim().replace([' ', '.', '-'], "");
        if p.starts_with('0') {
            p = format!("84{}", &p[1..]);
        }
        if p.starts_with('+') {
            p.remove(0);
        }
        self.get_enc(
            "friend",
            "/api/friend/profile/get",
            json!({"phone": p, "avatar_size": 240, "language": "vi", "imei": self.info.imei, "reqSrc": 40}),
        )
        .await
    }

    // ───── Tin nhắn ─────

    /// Gửi tin chữ (`sendMessage` không đính kèm) → `{msgId}`. `client_id` = mã tạm của tin (ms), dùng làm cliMsgId.
    pub async fn send_text(
        &self,
        thread: Thread,
        thread_id: &str,
        text: &str,
        quote: Option<&Quote>,
        mentions: &[Mention],
        client_id: u64,
    ) -> Result<Value, Error> {
        let is_group = thread == Thread::Group;
        let mut p = Map::new();
        p.insert("message".into(), json!(text));
        p.insert("clientId".into(), json!(client_id));
        let mention_info: Vec<Value> = if is_group {
            mentions
                .iter()
                .filter(|m| m.len > 0 && !m.uid.is_empty())
                .map(|m| json!({"pos": m.pos, "uid": m.uid, "len": m.len, "type": if m.uid == "-1" { 1 } else { 0 }}))
                .collect()
        } else {
            Vec::new()
        };
        if !mention_info.is_empty() {
            p.insert("mentionInfo".into(), json!(Value::Array(mention_info.clone()).to_string()));
        }
        if is_group {
            p.insert("visibility".into(), json!(0));
            p.insert("grid".into(), json!(thread_id));
        } else {
            p.insert("imei".into(), json!(self.info.imei));
            p.insert("toid".into(), json!(thread_id));
        }
        p.insert("ttl".into(), json!(0));
        if let Some(q) = quote {
            p.insert("qmsgOwner".into(), json!(q.uid_from));
            p.insert("qmsgId".into(), json!(q.msg_id));
            p.insert("qmsgCliId".into(), json!(q.cli_msg_id));
            p.insert("qmsgType".into(), json!(client_msg_type(&q.msg_type)));
            p.insert("qmsgTs".into(), json!(q.ts));
            p.insert(
                "qmsg".into(),
                match &q.content {
                    Value::String(s) => json!(s),
                    _ => json!(""),
                },
            );
            if is_group {
                let attach = match &q.content {
                    Value::String(_) => q.property_ext.clone(),
                    Value::Object(o) => {
                        let mut a = o.clone();
                        a.insert("thumbUrl".into(), o.get("thumb").cloned().unwrap_or(Value::Null));
                        a.insert("oriUrl".into(), o.get("href").cloned().unwrap_or(Value::Null));
                        a.insert("normalUrl".into(), o.get("href").cloned().unwrap_or(Value::Null));
                        Value::Object(a)
                    }
                    _ => Value::Null,
                };
                p.insert("qmsgAttach".into(), json!(attach.to_string()));
            }
            p.insert("qmsgTTL".into(), json!(q.ttl));
        }
        let path = match (is_group, quote.is_some(), !mention_info.is_empty()) {
            (false, false, _) => "/api/message/sms",
            (false, true, _) => "/api/message/quote",
            (true, true, _) => "/api/group/quote",
            (true, false, true) => "/api/group/mention",
            (true, false, false) => "/api/group/sendmsg",
        };
        let service = if is_group { "group" } else { "chat" };
        self.post_enc(service, path, &[("nretry", "0".into())], Value::Object(p)).await
    }

    /// Gửi sticker → `{msgId}`.
    pub async fn send_sticker(&self, thread: Thread, thread_id: &str, id: i64, cate_id: i64, kind: i64, client_id: u64) -> Result<Value, Error> {
        let mut p = json!({"stickerId": id, "cateId": cate_id, "type": kind, "clientId": client_id, "imei": self.info.imei, "zsource": 101});
        let (service, path) = match thread {
            Thread::User => {
                p["toid"] = json!(thread_id);
                ("chat", "/api/message/sticker")
            }
            Thread::Group => {
                p["grid"] = json!(thread_id);
                ("group", "/api/group/sticker")
            }
        };
        self.post_enc(service, path, &[("nretry", "0".into())], p).await
    }

    /// Tìm sticker theo từ khoá (`searchSticker`) → `[{type, cate_id, sticker_id}]`.
    pub async fn sticker_search(&self, keyword: &str) -> Result<Value, Error> {
        self.get_enc("sticker", "/api/message/sticker/search", json!({"keyword": keyword, "limit": 50, "srcType": 0, "imei": self.info.imei})).await
    }

    /// Gợi ý sticker theo từ khoá (`getStickers`) → `{sugg_sticker: [{type, cate_id, sticker_id}]}`.
    pub async fn sticker_suggest(&self, keyword: &str) -> Result<Value, Error> {
        self.get_enc("sticker", "/api/message/sticker/suggest/stickers", json!({"keyword": keyword, "gif": 1, "guggy": 0, "imei": self.info.imei})).await
    }

    /// Cả bộ sticker (`getStickerCategoryDetail`) → `[StickerDetail]`.
    pub async fn sticker_category(&self, cate_id: i64) -> Result<Value, Error> {
        self.get_enc("sticker", "/api/message/sticker/category/sticker_detail", json!({"cid": cate_id})).await
    }

    /// Một sticker (`getStickersDetail`) → `StickerDetail {id, cateId, type, stickerUrl, stickerSpriteUrl, stickerWebpUrl, …}`.
    pub async fn sticker_detail(&self, sticker_id: i64) -> Result<Value, Error> {
        self.get_enc("sticker", "/api/message/sticker/sticker_detail", json!({"sid": sticker_id})).await
    }

    // ───── Trò chuyện ẩn (getHiddenConversations / setHiddenConversations / updateHiddenConversPin của zca-js) ─────

    /// `{pin: md5(mã 4 số) | "", threads: [{thread_id, is_group}]}` — đồng bộ với điện thoại.
    pub async fn hidden_list(&self) -> Result<Value, Error> {
        self.get_enc("conversation", "/api/hiddenconvers/get-all", json!({"imei": self.info.imei})).await
    }

    pub async fn set_hidden(&self, hidden: bool, thread: Thread, ids: &[String]) -> Result<Value, Error> {
        let g = if thread == Thread::Group { 1 } else { 0 };
        let list = Value::Array(ids.iter().map(|id| json!({"thread_id": id, "is_group": g})).collect()).to_string();
        let (add, del) = if hidden { ("add_threads", "del_threads") } else { ("del_threads", "add_threads") };
        self.post_enc("conversation", "/api/hiddenconvers/add-remove", &[], json!({add: list, del: "[]", "imei": self.info.imei})).await
    }

    /// Đặt / đổi mã PIN (4 số) của trò chuyện ẩn — máy chủ giữ MD5.
    pub async fn set_hidden_pin(&self, pin: &str) -> Result<Value, Error> {
        let md5 = crate::crypto::md5_hex(pin.as_bytes());
        self.get_enc("conversation", "/api/hiddenconvers/update-pin", json!({"new_pin": md5, "imei": self.info.imei})).await
    }

    // ───── Đính kèm (uploadAttachment / sendMessage có đính kèm / sendVideo / sendVoice của zca-js) ─────

    /// Cỡ một phần khi tải lên (`settings.features.sharefile.chunk_size_file`).
    pub fn chunk_size(&self) -> usize {
        self.info.settings.pointer("/features/sharefile/chunk_size_file").and_then(Value::as_u64).filter(|&v| v >= 65536).unwrap_or(1 << 20) as usize
    }

    /// Dung lượng tối đa một tệp (byte) — `max_size_share_file_v3` (MB).
    pub fn max_file_size(&self) -> u64 {
        self.info.settings.pointer("/features/sharefile/max_size_share_file_v3").and_then(Value::as_u64).unwrap_or(1024) * 1024 * 1024
    }

    /// Tải một phần tệp lên. `photo` = ảnh (`photo_original/upload` → photoId, normalUrl, hdUrl, thumbUrl); không thì tệp / video /
    /// tin thoại (`asyncfile/upload` → fileId; địa chỉ tệp đến sau qua WebSocket: điều khiển `file_done`).
    #[allow(clippy::too_many_arguments)]
    pub async fn upload_chunk(
        &self,
        thread: Thread,
        thread_id: &str,
        photo: bool,
        file_name: &str,
        total_size: u64,
        client_id: u64,
        chunk_id: u32,
        total_chunk: u32,
        data: &[u8],
    ) -> Result<Value, Error> {
        let mut p = json!({"totalChunk": total_chunk, "fileName": file_name, "clientId": client_id, "totalSize": total_size,
                           "imei": self.info.imei, "isE2EE": 0, "jxl": 0, "chunkId": chunk_id});
        let dir = match thread {
            Thread::User => {
                p["toid"] = json!(thread_id);
                "message"
            }
            Thread::Group => {
                p["grid"] = json!(thread_id);
                "group"
            }
        };
        let kind = if photo { "photo_original/upload" } else { "asyncfile/upload" };
        let ty = if thread == Thread::Group { "11" } else { "2" };
        let url = self.service_url("file", &format!("/api/{dir}/{kind}"), &[("type", ty.into()), ("params", self.enc(&p)?)])?;
        let (boundary, body) = multipart_file("chunkContent", file_name, data);
        let r = self.http.request(reqwest::Method::POST, &url, &self.http.api_headers(), Body::Multipart { boundary, data: body }, None).await?;
        self.resolve(r, true)
    }

    /// Gửi ảnh đã tải lên (`photo_original/send`). `up` = kết quả phần cuối của upload_chunk.
    #[allow(clippy::too_many_arguments)]
    pub async fn send_photo(&self, thread: Thread, thread_id: &str, up: &Value, width: u32, height: u32, size: u64, desc: &str, client_id: u64) -> Result<Value, Error> {
        let g = thread == Thread::Group;
        let normal = up.get("normalUrl").cloned().unwrap_or(Value::Null);
        let mut p = json!({
            "photoId": up.get("photoId").cloned().unwrap_or(Value::Null), "clientId": client_id.to_string(), "desc": desc,
            "width": width, "height": height, "rawUrl": normal, "hdUrl": up.get("hdUrl").cloned().unwrap_or(Value::Null),
            "thumbUrl": up.get("thumbUrl").cloned().unwrap_or(Value::Null), "hdSize": size.to_string(), "zsource": -1, "ttl": 0,
            "jcp": "{\"convertible\":\"jxl\"}",
        });
        if g {
            p["grid"] = json!(thread_id);
            p["oriUrl"] = normal;
        } else {
            p["toid"] = json!(thread_id);
            p["normalUrl"] = normal;
        }
        let dir = if g { "group" } else { "message" };
        self.post_enc("file", &format!("/api/{dir}/photo_original/send"), &[("nretry", "0".into())], p).await
    }

    /// Gửi tệp đã tải lên (`asyncfile/msg`) — hiện như tệp đính kèm.
    #[allow(clippy::too_many_arguments)]
    pub async fn send_file_msg(&self, thread: Thread, thread_id: &str, file_id: &str, file_url: &str, checksum: &str, file_name: &str, total_size: u64, client_id: u64) -> Result<Value, Error> {
        let ext = file_name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
        let mut p = json!({
            "fileId": file_id, "checksum": checksum, "checksumSha": "", "extention": ext, "totalSize": total_size, "fileName": file_name,
            "clientId": client_id, "fType": 1, "fileCount": 0, "fdata": "{}", "fileUrl": file_url, "zsource": -1, "ttl": 0,
        });
        let dir = match thread {
            Thread::User => {
                p["toid"] = json!(thread_id);
                "message"
            }
            Thread::Group => {
                p["grid"] = json!(thread_id);
                "group"
            }
        };
        self.post_enc("file", &format!("/api/{dir}/asyncfile/msg"), &[("nretry", "0".into())], p).await
    }

    /// Tải ảnh bìa (video) lên (`upthumb`) → `{url, hdUrl, …}`.
    pub async fn upload_thumb(&self, jpeg: &[u8]) -> Result<Value, Error> {
        let p = json!({"clientId": now_ms(), "imei": self.info.imei});
        let url = self.service_url("file", "/api/message/upthumb", &[("params", self.enc(&p)?)])?;
        let (boundary, body) = multipart_file_typed("fileContent", "blob", "image/png", jpeg);
        let r = self.http.request(reqwest::Method::POST, &url, &self.http.api_headers(), Body::Multipart { boundary, data: body }, None).await?;
        self.resolve(r, true)
    }

    async fn forward(&self, thread: Thread, thread_id: &str, msg_type: i64, zsource: i64, msg_info: Value, client_id: u64) -> Result<Value, Error> {
        let mut p = json!({"clientId": client_id.to_string(), "ttl": 0, "zsource": zsource, "msgType": msg_type,
                           "msgInfo": msg_info.to_string(), "imei": self.info.imei});
        let dir = match thread {
            Thread::User => {
                p["toId"] = json!(thread_id);
                "message"
            }
            Thread::Group => {
                p["grid"] = json!(thread_id);
                p["visibility"] = json!(0);
                "group"
            }
        };
        self.post_enc("file", &format!("/api/{dir}/forward"), &[], p).await
    }

    /// Gửi video đã tải lên (`sendVideo`: msgType 5) — phát được ngay trong chat.
    #[allow(clippy::too_many_arguments)]
    pub async fn send_video(&self, thread: Thread, thread_id: &str, video_url: &str, thumb_url: &str, duration_ms: u64, width: u32, height: u32, size: u64, client_id: u64) -> Result<Value, Error> {
        let info = json!({
            "videoUrl": video_url, "thumbUrl": thumb_url, "duration": duration_ms, "width": width, "height": height, "fileSize": size,
            "properties": {"color": -1, "size": -1, "type": 1003, "subType": 0, "ext": {"sSrcType": -1, "sSrcStr": "", "msg_warning_type": 0}},
            "title": "",
        });
        self.forward(thread, thread_id, 5, 704, info, client_id).await
    }

    /// Gửi tin thoại đã tải lên (`sendVoice`: msgType 3, tệp m4a / AAC).
    pub async fn send_voice(&self, thread: Thread, thread_id: &str, voice_url: &str, size: u64, client_id: u64) -> Result<Value, Error> {
        let info = json!({"voiceUrl": voice_url, "m4aUrl": voice_url, "fileSize": size});
        self.forward(thread, thread_id, 3, -1, info, client_id).await
    }

    /// Thu hồi tin của mình (`undo`).
    pub async fn undo(&self, thread: Thread, thread_id: &str, msg_id: &str, cli_msg_id: &str) -> Result<Value, Error> {
        let mut p = json!({"msgId": msg_id, "clientId": now_ms(), "cliMsgIdUndo": cli_msg_id});
        let (service, path) = match thread {
            Thread::User => {
                p["toid"] = json!(thread_id);
                ("chat", "/api/message/undo")
            }
            Thread::Group => {
                p["grid"] = json!(thread_id);
                p["visibility"] = json!(0);
                p["imei"] = json!(self.info.imei);
                ("group", "/api/group/undomsg")
            }
        };
        self.post_enc(service, path, &[], p).await
    }

    /// Xoá tin (`deleteMessage`): `only_me` = chỉ ở phía mình (chat riêng chỉ có kiểu này); nhóm: quản trị xoá tin người khác.
    pub async fn delete_message(&self, thread: Thread, thread_id: &str, m: &MsgRef, only_me: bool) -> Result<Value, Error> {
        let key = if thread == Thread::Group { "grid" } else { "toid" };
        let mut p = json!({
            key: thread_id,
            "cliMsgId": now_ms(),
            "msgs": [{"cliMsgId": m.cli_msg_id, "globalMsgId": m.msg_id, "ownerId": m.uid_from, "destId": thread_id}],
            "onlyMe": if only_me { 1 } else { 0 },
        });
        if thread == Thread::User {
            p["imei"] = json!(self.info.imei);
        }
        let (service, path) = if thread == Thread::Group { ("group", "/api/group/deletemsg") } else { ("chat", "/api/message/delete") };
        self.post_enc(service, path, &[], p).await
    }

    fn msg_infos(&self, msgs: &[MsgRef]) -> Vec<Value> {
        msgs.iter()
            .map(|m| {
                json!({"cmi": m.cli_msg_id, "gmi": m.msg_id, "si": m.uid_from,
                       "di": if m.id_to == self.info.uid { "0" } else { m.id_to.as_str() },
                       "mt": m.msg_type, "st": 0, "at": 0, "cmd": 0, "ts": 0})
            })
            .collect()
    }

    /// Báo đã xem (`sendSeenEvent`, ≤ 50 tin cùng một cuộc trò chuyện, tin của người khác).
    pub async fn send_seen(&self, thread: Thread, thread_id: &str, msgs: &[MsgRef]) -> Result<Value, Error> {
        if msgs.is_empty() {
            return Ok(Value::Null);
        }
        let msgs = &msgs[msgs.len().saturating_sub(50)..];
        let infos = self.msg_infos(msgs);
        match thread {
            Thread::User => {
                let mi = json!({"data": infos, "senderId": thread_id});
                self.post_enc("chat", "/api/message/seenv2", &[("nretry", "0".into())], json!({"msgInfos": mi.to_string()})).await
            }
            Thread::Group => {
                let mi = json!({"data": infos, "grid": thread_id});
                self.post_enc("group", "/api/group/seenv2", &[("nretry", "0".into())], json!({"msgInfos": mi.to_string(), "imei": self.info.imei}))
                    .await
            }
        }
    }

    /// Báo đã nhận (`sendDeliveredEvent`).
    pub async fn send_delivered(&self, thread: Thread, msgs: &[MsgRef]) -> Result<Value, Error> {
        if msgs.is_empty() {
            return Ok(Value::Null);
        }
        let msgs = &msgs[msgs.len().saturating_sub(50)..];
        let infos = self.msg_infos(msgs);
        match thread {
            Thread::User => {
                let mi = json!({"seen": 0, "data": infos});
                self.post_enc("chat", "/api/message/deliveredv2", &[], json!({"msgInfos": mi.to_string()})).await
            }
            Thread::Group => {
                let mi = json!({"seen": 0, "data": infos, "grid": msgs[0].id_to});
                self.post_enc("group", "/api/group/deliveredv2", &[], json!({"msgInfos": mi.to_string(), "imei": self.info.imei})).await
            }
        }
    }

    /// Báo «đang soạn tin».
    pub async fn send_typing(&self, thread: Thread, thread_id: &str) -> Result<Value, Error> {
        match thread {
            Thread::User => self.post_enc("chat", "/api/message/typing", &[], json!({"toid": thread_id, "destType": 3, "imei": self.info.imei})).await,
            Thread::Group => self.post_enc("group", "/api/group/typing", &[], json!({"grid": thread_id, "imei": self.info.imei})).await,
        }
    }

    /// Lịch sử nhóm từ máy chủ (`getCloudMessage`): `last_msg_id` None = mới nhất; trang sau: `lastMsgId` + `isOld` của lần trả
    /// trước (isOld = 1 → kho tin cũ `getoldv2`). Máy chủ trả lỗi -69 = hết tin để tải.
    pub async fn group_cloud_messages(&self, group_id: &str, last_msg_id: Option<&str>, is_old: bool) -> Result<Value, Error> {
        let gid = group_id.trim_start_matches('g');
        let p = json!({
            "groupId": gid, "globalMsgId": last_msg_id.unwrap_or("0"), "count": 50, "msgIds": [], "imei": self.info.imei,
            "src": if last_msg_id.is_some() { 3 } else { 1 },
        });
        let path = if is_old { "/api/cm/getoldv2" } else { "/api/cm/getrecentv2" };
        let url = self.service_url("group_cloud_message", path, &[("params", self.enc(&p)?), ("nretry", "0".into())])?;
        let r = self.http.get(&url, &self.http.api_headers()).await?;
        self.resolve(r, true)
    }

    /// Thả cảm xúc (`addReaction`): `r_type` theo bảng của Zalo (thích 3, tim 5, haha 0, wow 32, khóc 2, giận 20); `icon` mã
    /// ký hiệu đi kèm (vd. "/-strong", "/-heart", ":>", ":o", ":-((", ":-h").
    pub async fn add_reaction(&self, thread: Thread, thread_id: &str, msg_id: &str, cli_msg_id: &str, r_type: i64, icon: &str) -> Result<Value, Error> {
        let msg = json!({"rMsg": [{"gMsgID": msg_id.parse::<i64>().unwrap_or(0), "cMsgID": cli_msg_id.parse::<i64>().unwrap_or(0), "msgType": 1}],
                          "rIcon": icon, "rType": r_type, "source": 6});
        let react = json!({"message": msg.to_string(), "clientId": now_ms()});
        let mut p = json!({"react_list": [react]});
        let path = match thread {
            Thread::User => {
                p["toid"] = json!(thread_id);
                "/api/message/reaction"
            }
            Thread::Group => {
                p["grid"] = json!(thread_id);
                p["imei"] = json!(self.info.imei);
                "/api/group/reaction"
            }
        };
        self.post_enc("reaction", path, &[], p).await
    }

    /// Tắt / bật thông báo của một cuộc trò chuyện (`setMute`): `duration` giây, -1 = mãi mãi.
    pub async fn set_mute(&self, thread: Thread, thread_id: &str, mute: bool, duration: i64) -> Result<Value, Error> {
        let p = json!({
            "toid": thread_id, "duration": if mute { duration } else { -1 }, "action": if mute { 1 } else { 3 },
            "startTime": now_ms() / 1000, "muteType": if thread == Thread::User { 1 } else { 2 }, "imei": self.info.imei,
        });
        self.post_enc("profile", "/api/social/profile/setmute", &[], p).await
    }

    /// Đăng xuất phiên web hiện tại (best-effort — Zalo Web chỉ xoá cookie phía máy).
    pub async fn logout(&self) -> Result<(), Error> {
        let _ = self.http.get("https://id.zalo.me/account/logout?continue=https%3A%2F%2Fchat.zalo.me%2F", &[]).await;
        Ok(())
    }
}
