//! Gửi ảnh / tệp / video / tin thoại (chuyển từ uploadAttachment + sendMessage có đính kèm + sendVideo + sendVoice của zca-js).
//!
//! - Tin hiện ngay bằng tin tạm `l<cid>` (ảnh / ảnh bìa đọc từ tệp trên máy), sự kiện `msg.progress` theo từng phần tải lên.
//! - Tải lên tuần tự từng phần cỡ `chunk_size_file`, đọc tệp theo khúc (không nạp cả video vào RAM — iPad 1 chỉ 256 MB), MD5
//!   tính dần.
//! - Ảnh: phần cuối trả photoId + địa chỉ → `photo_original/send`. Tệp / video / thoại: phần cuối trả fileId; địa chỉ tệp máy chủ
//!   báo sau qua WebSocket (điều khiển `file_done`) → `asyncfile/msg` (tệp) / `forward` msgType 5 (video) / 3 (thoại).

use std::io::Read;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use md5::{Digest, Md5};
use rz_zalo::{Api, Thread};
use serde_json::{json, Value};
use tokio::sync::oneshot;

use crate::msg::{parse_key, s};
use crate::{Core, CoreError, R};

pub(crate) enum FileWait {
    Waiting(oneshot::Sender<String>),
    Done(String),
}

pub(crate) enum MediaJob {
    Photo { path: String, w: u32, h: u32 },
    File { path: String, name: String },
    Video { path: String, thumb: String, w: u32, h: u32, dur: u64 },
    Voice { path: String, dur: u64 },
}

/// Kết quả tải lên: phần trả lời cuối, cỡ tệp, MD5 (hex).
struct Uploaded {
    last: Value,
    size: u64,
    md5: String,
}

impl Core {
    /// Máy chủ báo tệp đã xử lý xong (`file_done`); có thể tới trước khi HTTP trả lời phần cuối → giữ lại cho người chờ sau.
    pub(crate) fn file_done(&self, file_id: String, url: String) {
        if file_id.is_empty() {
            return;
        }
        let mut m = self.files.lock().unwrap();
        match m.remove(&file_id) {
            Some(FileWait::Waiting(tx)) => {
                let _ = tx.send(url);
            }
            _ => {
                if m.len() > 64 {
                    m.retain(|_, v| matches!(v, FileWait::Waiting(_)));
                }
                m.insert(file_id, FileWait::Done(url));
            }
        }
    }

    async fn wait_file(&self, file_id: &str, secs: u64) -> R<String> {
        let rx = {
            let mut m = self.files.lock().unwrap();
            match m.remove(file_id) {
                Some(FileWait::Done(u)) => return Ok(u),
                _ => {
                    let (tx, rx) = oneshot::channel();
                    m.insert(file_id.to_string(), FileWait::Waiting(tx));
                    rx
                }
            }
        };
        match tokio::time::timeout(Duration::from_secs(secs), rx).await {
            Ok(Ok(u)) if !u.is_empty() => Ok(u),
            _ => {
                self.files.lock().unwrap().remove(file_id);
                Err(CoreError::new("TIMEOUT", "Máy chủ Zalo chưa xử lý xong tệp. Thử gửi lại."))
            }
        }
    }

    /// Tải tệp lên từng phần; `on_progress(0…1)` sau mỗi phần.
    #[allow(clippy::too_many_arguments)]
    async fn upload(&self, api: &Api, thread: Thread, tid: &str, path: &Path, name: &str, photo: bool, on_progress: &(dyn Fn(f64) + Send + Sync)) -> R<Uploaded> {
        let size = std::fs::metadata(path).map_err(|e| CoreError::new("IO", format!("Không đọc được tệp: {e}")))?.len();
        if size == 0 {
            return Err(CoreError::new("BAD_ARGS", "Tệp rỗng"));
        }
        if size > api.max_file_size() {
            return Err(CoreError::new("TOO_BIG", format!("Tệp quá lớn (tối đa {} MB)", api.max_file_size() / 1048576)));
        }
        let chunk = api.chunk_size();
        let total = size.div_ceil(chunk as u64) as u32;
        let client_id = self.next_cid();
        let mut f = std::fs::File::open(path).map_err(|e| CoreError::new("IO", format!("Không mở được tệp: {e}")))?;
        let mut md5 = Md5::new();
        let mut buf = vec![0u8; chunk];
        let mut last = Value::Null;
        for i in 1..=total {
            let mut n = 0;
            while n < chunk {
                let r = f.read(&mut buf[n..]).map_err(|e| CoreError::new("IO", format!("Đọc tệp: {e}")))?;
                if r == 0 {
                    break;
                }
                n += r;
            }
            md5.update(&buf[..n]);
            let mut tries = 0;
            last = loop {
                match api.upload_chunk(thread, tid, photo, name, size, client_id, i, total, &buf[..n]).await {
                    Ok(v) => break v,
                    Err(e) if tries < 2 && matches!(e.code, "NETWORK" | "TIMEOUT") => {
                        tries += 1;
                        tokio::time::sleep(Duration::from_secs(2)).await;
                    }
                    Err(e) => return Err(e.into()),
                }
            };
            on_progress(i as f64 / total as f64);
        }
        if s(&last, "fileId") == "-1" || s(&last, "photoId") == "-1" {
            return Err(CoreError::new("ZALO", "Máy chủ Zalo từ chối tệp"));
        }
        Ok(Uploaded { last, size, md5: rz_zalo::crypto::hex(&md5.finalize()) })
    }

    /// Gửi một tin đa phương tiện: hiện ngay bằng tin tạm, tải lên + gửi ở nền.
    pub(crate) fn send_media(self: &Arc<Self>, thread: &str, job: MediaJob) -> R<Value> {
        let (group, tid) = parse_key(thread).ok_or_else(|| CoreError::new("BAD_ARGS", "Sai mã cuộc trò chuyện"))?;
        let path = match &job {
            MediaJob::Photo { path, .. } | MediaJob::File { path, .. } | MediaJob::Video { path, .. } | MediaJob::Voice { path, .. } => path.clone(),
        };
        let size = std::fs::metadata(&path).map_err(|_| CoreError::new("IO", "Không tìm thấy tệp cần gửi"))?.len();
        let me = self.me_uid();
        let cid = self.next_cid();
        let (kind, ty, text, media) = match &job {
            MediaJob::Photo { path, w, h } => ("photo", "chat.photo", "[Hình ảnh]".to_string(), json!({"local": path, "w": w, "h": h})),
            MediaJob::File { path, name } => {
                let n = if name.is_empty() { Path::new(path).file_name().map(|x| x.to_string_lossy().into_owned()).unwrap_or_default() } else { name.clone() };
                ("file", "share.file", format!("[Tệp] {n}"), json!({"name": n, "size": size, "local": path}))
            }
            MediaJob::Video { thumb, w, h, dur, .. } => ("video", "chat.video.msg", "[Video]".to_string(), json!({"thumb_local": thumb, "w": w, "h": h, "dur": dur, "local": path})),
            MediaJob::Voice { dur, path } => ("voice", "chat.voice", "[Tin nhắn thoại]".to_string(), json!({"dur": dur, "local": path})),
        };
        let dto = json!({"id": format!("l{cid}"), "cid": cid.to_string(), "thread": thread, "from": me, "out": true, "ts": cid,
                         "type": ty, "kind": kind, "text": text, "status": "sending", "media": media});
        self.store.lock().unwrap().put_pending(thread, &cid.to_string(), cid as i64, &me, &dto);
        self.ev("msg.new", json!({"thread": thread, "msg": dto}));
        self.ev("threads.upsert", json!({"threads": [self.store.lock().unwrap().thread(thread)]}));
        let core = Arc::clone(self);
        let thread_s = thread.to_string();
        let tid = tid.to_string();
        let th = if group { Thread::Group } else { Thread::User };
        tokio::spawn(async move {
            let t0 = crate::now_ms();
            let r = Box::pin(core.media_job(th, &tid, &thread_s, cid, job)).await;
            match r {
                Ok(v) => {
                    core.log(&format!("gửi {kind} được sau {} ms", crate::now_ms() - t0));
                    if let Some(m) = core.store.lock().unwrap().confirm_pending(&thread_s, &cid.to_string(), &s(&v, "msgId")) {
                        core.ev("msg.update", json!({"thread": thread_s, "msg": m, "old_id": format!("l{cid}")}));
                    }
                }
                Err(e) => {
                    core.log(&format!("gửi {kind} lỗi: {} {}", e.code, e.msg));
                    if let Some(m) = core.store.lock().unwrap().fail_pending(&thread_s, &cid.to_string()) {
                        core.ev("msg.update", json!({"thread": thread_s, "msg": m, "err": e.to_json()}));
                    }
                }
            }
        });
        Ok(dto)
    }

    async fn media_job(self: &Arc<Self>, th: Thread, tid: &str, thread: &str, cid: u64, job: MediaJob) -> R<Value> {
        let api = self.api()?;
        let me = Arc::clone(self);
        let lid = format!("l{cid}");
        let th_s = thread.to_string();
        let progress = move |p: f64| {
            me.ev("msg.progress", json!({"thread": th_s, "id": lid, "p": (p * 100.0).round() / 100.0}));
        };
        let file_name = |p: &str| Path::new(p).file_name().map(|x| x.to_string_lossy().into_owned()).unwrap_or_else(|| "file".into());
        match job {
            MediaJob::Photo { path, w, h } => {
                let name = file_name(&path);
                let up = self.upload(&api, th, tid, Path::new(&path), &name, true, &progress).await?;
                Ok(api.send_photo(th, tid, &up.last, w, h, up.size, "", cid).await?)
            }
            MediaJob::File { path, name } => {
                let name = if name.is_empty() { file_name(&path) } else { name };
                let up = self.upload(&api, th, tid, Path::new(&path), &name, false, &progress).await?;
                let fid = s(&up.last, "fileId");
                let url = self.wait_file(&fid, 180).await?;
                Ok(api.send_file_msg(th, tid, &fid, &url, &up.md5, &name, up.size, cid).await?)
            }
            MediaJob::Video { path, thumb, w, h, dur } => {
                let name = file_name(&path);
                let up = self.upload(&api, th, tid, Path::new(&path), &name, false, &progress).await?;
                let fid = s(&up.last, "fileId");
                let url = self.wait_file(&fid, 300).await?;
                let jpeg = std::fs::read(&thumb).unwrap_or_default();
                let thumb_url = if jpeg.is_empty() {
                    String::new()
                } else {
                    let t = api.upload_thumb(&jpeg).await?;
                    let u = s(&t, "url");
                    if u.is_empty() { s(&t, "hdUrl") } else { u }
                };
                Ok(api.send_video(th, tid, &url, &thumb_url, dur, w.max(1), h.max(1), up.size, cid).await?)
            }
            MediaJob::Voice { path, .. } => {
                let name = file_name(&path);
                let up = self.upload(&api, th, tid, Path::new(&path), &name, false, &progress).await?;
                let fid = s(&up.last, "fileId");
                let url = self.wait_file(&fid, 120).await?;
                Ok(api.send_voice(th, tid, &url, up.size, cid).await?)
            }
        }
    }
}
