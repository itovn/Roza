//! Đồng bộ tin nhắn với phiên điện thoại / PC (cùng tài khoản) — những gì giao thức Zalo Web cho làm (DECISIONS D13, D17):
//!
//! - Trực tiếp: tin gửi / nhận ở máy khác về Roza khi đang nối (WebSocket); đọc / trả lời ở máy khác → bỏ số chưa đọc.
//! - `sync.now`: xin máy chủ đẩy lại tin gần đây + tin bị lỡ (cmd 510 / 511: từ tin mới nhất đã có, và cửa sổ gần đây).
//! - `sync.groups`: lịch sử nhóm từ máy chủ («cloud message») cho mọi nhóm, lùi dần tới `max` tin mỗi nhóm.
//! - Lịch sử chat riêng cũ chỉ nằm trên điện thoại: Zalo Web chưa có lệnh tải về (zca-js không có) — không làm được ở đây.

use std::sync::Arc;

use rz_zalo::listen::WsCmd;
use serde_json::{json, Value};

use crate::msg::{self, n, s};
use crate::{now_ms, Core, CoreError, R};

impl Core {
    pub(crate) fn sync_state(&self) -> Value {
        let st = self.store.lock().unwrap();
        let last: u64 = st.kv_get("sync.last").and_then(|v| v.parse().ok()).unwrap_or(0);
        let groups: u64 = st.kv_get("sync.groups").and_then(|v| v.parse().ok()).unwrap_or(0);
        json!({"net": self.st.lock().unwrap().net, "last_ms": last, "groups_ms": groups, "msgs": st.msg_total(),
               "threads": st.threads(100000).len()})
    }

    /// Xin máy chủ đẩy lại tin (kết quả về qua sự kiện WebSocket → `threads.changed`).
    pub(crate) fn sync_now(&self) -> R<Value> {
        if self.ws_tx.lock().unwrap().is_none() {
            return Err(CoreError::new("NETWORK", "Chưa kết nối được Zalo — chờ mạng rồi thử lại."));
        }
        let (u, g) = {
            let st = self.store.lock().unwrap();
            (st.max_msg_id(false), st.max_msg_id(true))
        };
        for (group, last) in [(false, u), (true, g)] {
            self.ws_send(WsCmd::RequestOld { group, last_id: last });
            // Cửa sổ tin gần đây của máy chủ (khi có tin cũ hơn tin mới nhất trên máy mà máy chưa có)
            self.ws_send(WsCmd::RequestOld { group, last_id: None });
        }
        self.log("đồng bộ: xin máy chủ đẩy lại tin");
        Ok(json!({"started": true}))
    }

    /// Lịch sử mọi nhóm từ máy chủ, lùi dần tới `max` tin mỗi nhóm. Sự kiện `sync.progress {done, total, msgs}`.
    pub(crate) async fn sync_groups(self: &Arc<Self>, max: i64) -> R<Value> {
        let api = self.api()?;
        let gids: Vec<String> = self.store.lock().unwrap().groups().iter().map(|g| s(g, "gid")).filter(|g| !g.is_empty()).collect();
        let total = gids.len();
        let me = api.info.uid.clone();
        let (mut added, mut done) = (0i64, 0usize);
        // Kết quả từng nhóm cho app: tên, số tin máy chủ trả, số tin mới, máy chủ có lọc không, cài đặt cho xem lịch sử
        let mut details: Vec<Value> = Vec::new();
        self.ev("sync.progress", json!({"done": 0, "total": total, "msgs": 0}));
        for gid in gids {
            let thread = msg::thread_key(true, &gid);
            let mut last: Option<String> = None;
            let mut is_old = false;
            let mut got = 0i64;
            let mut filtered = false;
            let added_before = added;
            for page in 0..12 {
                let v = match api.group_cloud_messages(&gid, last.as_deref(), is_old).await {
                    Ok(v) => v,
                    Err(e) => {
                        if e.zalo_code != Some(-69) {
                            self.log(&format!("lịch sử nhóm {}: trang {page} lỗi: {e}", done + 1));
                        }
                        break;
                    }
                };
                let list = v.get("groupMsgs").and_then(Value::as_array).cloned().unwrap_or_default();
                // Chẩn đoán (không ghi nội dung tin): số tin + các cờ của máy chủ
                self.log(&format!(
                    "lịch sử nhóm {} (enableMsgHistory {}): trang {page}: {} tin, hasMore {}, isOld {}, isFiltered {}, byPhase {}, byTimeJoin {}, tsJoin {}, error {}",
                    done + 1,
                    self.store.lock().unwrap().group(&gid).map(|g| g["history"].to_string()).unwrap_or_default(),
                    list.len(),
                    n(&v, "hasMore"),
                    n(&v, "isOld"),
                    n(&v, "isFiltered"),
                    n(&v, "isFilteredByPhase"),
                    n(&v, "isFilteredByTimeJoin"),
                    if n(&v, "tsJoinGroup") > 0 { "có" } else { "không" },
                    n(&v, "error")
                ));
                let next = s(&v, "lastMsgId");
                if list.is_empty() {
                    filtered = n(&v, "isFiltered") != 0;
                    break;
                }
                {
                    let mut st = self.store.lock().unwrap();
                    for raw in &list {
                        if let Some(nm) = msg::normalize(raw, &me, true) {
                            if nm.undo.is_some() {
                                continue;
                            }
                            if !nm.out {
                                st.hint_user_name(&nm.from, &s(raw, "dName"));
                            }
                            if st.put_msg(&nm, raw) {
                                added += 1;
                            }
                        }
                    }
                    // Tin cũ tải về không tính là chưa đọc
                    let ts = st.thread(&thread)["ts"].as_i64().unwrap_or(0);
                    st.mark_read(&thread, ts);
                }
                got += list.len() as i64;
                if got >= max || n(&v, "hasMore") == 0 || next.is_empty() || last.as_deref() == Some(next.as_str()) {
                    break;
                }
                last = Some(next);
                is_old = n(&v, "isOld") != 0;
            }
            self.cloud_synced.lock().unwrap().insert(thread);
            let (name, allow) = {
                let st = self.store.lock().unwrap();
                (st.group_brief(&gid).0, st.group(&gid).map(|g| g["history"].clone()).unwrap_or(Value::Null))
            };
            details.push(json!({"name": name, "got": got, "new": added - added_before, "filtered": filtered && got == 0, "allow": allow}));
            done += 1;
            self.ev("sync.progress", json!({"done": done, "total": total, "msgs": added}));
        }
        self.store.lock().unwrap().kv_set("sync.groups", &now_ms().to_string());
        self.log(&format!("đồng bộ nhóm: {total} nhóm, {added} tin mới"));
        self.ev("threads.changed", json!({}));
        Ok(json!({"groups": total, "msgs": added, "details": details}))
    }
}
