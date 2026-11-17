//! Tải ảnh / ảnh đại diện / sticker / tệp qua lõi (rustls) rồi để trong bộ đệm: iOS 5 / 6 không mở được HTTPS hiện nay của CDN Zalo.
//! WebP (iOS 5 / 6 không đọc được) đổi sang PNG. Tên tệp = MD5(URL) + đuôi; tải song song cùng một URL thì chờ chung.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rz_zalo::crypto::md5_hex;
use rz_zalo::http::Http;
use tokio::sync::watch;

use crate::CoreError;

pub struct Media {
    dir: PathBuf,
    inflight: Mutex<HashMap<String, watch::Receiver<Option<Result<PathBuf, String>>>>>,
}

/// Loại tệp → thư mục con + giới hạn kích thước.
fn kind_info(kind: &str) -> (&'static str, usize) {
    match kind {
        "avatar" => ("avatars", 2 << 20),
        "thumb" | "sticker" => ("thumbs", 4 << 20),
        "photo" => ("photos", 25 << 20),
        "voice" => ("voice", 20 << 20),
        _ => ("files", 200 << 20),
    }
}

fn ext_for(url: &str, data: &[u8]) -> &'static str {
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "jpg"
    } else if data.starts_with(b"\x89PNG") {
        "png"
    } else if data.starts_with(b"GIF8") {
        "gif"
    } else if data.len() > 12 && &data[4..8] == b"ftyp" {
        "mp4"
    } else {
        let u = url.split('?').next().unwrap_or("").to_ascii_lowercase();
        for e in ["mp3", "m4a", "aac", "amr", "pdf", "doc", "docx", "xls", "xlsx", "zip", "txt", "mp4"] {
            if u.ends_with(&format!(".{e}")) {
                return e;
            }
        }
        "bin"
    }
}

impl Media {
    pub fn new(cache_dir: &Path) -> Self {
        Self { dir: cache_dir.to_path_buf(), inflight: Mutex::new(HashMap::new()) }
    }

    /// Đường dẫn đã có trong bộ đệm (không tải).
    pub fn cached(&self, url: &str, kind: &str) -> Option<PathBuf> {
        self.cached_ext(url, kind, "")
    }

    /// Như `cached`, thử thêm đuôi gợi ý (tệp đính kèm: đuôi theo tên tệp — QuickLook cần đuôi đúng).
    pub fn cached_ext(&self, url: &str, kind: &str, hint: &str) -> Option<PathBuf> {
        let (sub, _) = kind_info(kind);
        let base = self.dir.join(sub).join(md5_hex(url.as_bytes()));
        if !hint.is_empty() {
            let p = base.with_extension(hint);
            if p.exists() {
                return Some(p);
            }
        }
        for e in ["jpg", "png", "gif", "mp4", "m4a", "aac", "mp3", "amr", "pdf", "doc", "docx", "xls", "xlsx", "zip", "txt", "bin"] {
            let p = base.with_extension(e);
            if p.exists() {
                return Some(p);
            }
        }
        None
    }

    /// Tải (hoặc lấy từ bộ đệm) → đường dẫn tệp.
    pub async fn fetch(self: &Arc<Self>, http: &Http, url: &str, kind: &str) -> Result<PathBuf, CoreError> {
        self.fetch_ext(http, url, kind, "").await
    }

    pub async fn fetch_ext(self: &Arc<Self>, http: &Http, url: &str, kind: &str, hint: &str) -> Result<PathBuf, CoreError> {
        if url.is_empty() || !(url.starts_with("http://") || url.starts_with("https://")) {
            return Err(CoreError::new("BAD_URL", "Địa chỉ tệp không hợp lệ"));
        }
        if let Some(p) = self.cached_ext(url, kind, hint) {
            return Ok(p);
        }
        let key = format!("{kind}|{url}");
        let (mine, mut rx) = {
            let mut m = self.inflight.lock().unwrap();
            if let Some(rx) = m.get(&key) {
                (None, rx.clone())
            } else {
                let (tx, rx) = watch::channel(None);
                m.insert(key.clone(), rx.clone());
                (Some(tx), rx)
            }
        };
        if let Some(tx) = mine {
            let r = self.download(http, url, kind, hint).await.map_err(|e| e.msg);
            let _ = tx.send(Some(r.clone()));
            self.inflight.lock().unwrap().remove(&key);
            return r.map_err(|m| CoreError::new("DOWNLOAD", m));
        }
        loop {
            if let Some(r) = rx.borrow().clone() {
                return r.map_err(|m| CoreError::new("DOWNLOAD", m));
            }
            if rx.changed().await.is_err() {
                return self.cached_ext(url, kind, hint).ok_or_else(|| CoreError::new("DOWNLOAD", "Tải tệp bị huỷ"));
            }
        }
    }

    async fn download(&self, http: &Http, url: &str, kind: &str, hint: &str) -> Result<PathBuf, CoreError> {
        let (sub, max) = kind_info(kind);
        let mut data = http.download(url, max).await.map_err(|e| CoreError::new("DOWNLOAD", e.msg))?;
        if data.len() > 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WEBP" {
            data = tokio::task::spawn_blocking(move || webp_to_png(&data)).await.ok().flatten().ok_or_else(|| CoreError::new("DECODE", "Không đọc được ảnh WebP"))?;
        }
        let dir = self.dir.join(sub);
        let _ = std::fs::create_dir_all(&dir);
        let sniff = ext_for(url, &data);
        // Ảnh nhận theo nội dung; tệp khác: đuôi gợi ý (tên tệp) nếu nội dung không tự nói
        let ext = if !hint.is_empty() && (sniff == "bin" || kind == "file") && hint.chars().all(|c| c.is_ascii_alphanumeric()) && hint.len() <= 8 {
            hint.to_ascii_lowercase()
        } else {
            sniff.to_string()
        };
        let path = dir.join(md5_hex(url.as_bytes())).with_extension(ext);
        let tmp = path.with_extension(format!("{}.part", crate::now_ms()));
        std::fs::write(&tmp, &data).map_err(|e| CoreError::new("IO", format!("Ghi tệp: {e}")))?;
        std::fs::rename(&tmp, &path).map_err(|e| CoreError::new("IO", format!("Ghi tệp: {e}")))?;
        Ok(path)
    }

    /// Đặt dữ liệu lấy từ nơi khác (bản sao lưu Telegram) vào bộ đệm, đúng chỗ `cached_ext` sẽ tìm.
    pub fn put_bytes(&self, url: &str, kind: &str, hint: &str, data: &[u8]) -> Result<PathBuf, CoreError> {
        let (sub, _) = kind_info(kind);
        let dir = self.dir.join(sub);
        let _ = std::fs::create_dir_all(&dir);
        let sniff = ext_for(url, data);
        let ext = if !hint.is_empty() && (sniff == "bin" || kind == "file") && hint.chars().all(|c| c.is_ascii_alphanumeric()) && hint.len() <= 8 {
            hint.to_ascii_lowercase()
        } else {
            sniff.to_string()
        };
        let path = dir.join(md5_hex(url.as_bytes())).with_extension(ext);
        let tmp = path.with_extension(format!("{}.part", crate::now_ms()));
        std::fs::write(&tmp, data).map_err(|e| CoreError::new("IO", format!("Ghi tệp: {e}")))?;
        std::fs::rename(&tmp, &path).map_err(|e| CoreError::new("IO", format!("Ghi tệp: {e}")))?;
        Ok(path)
    }

    /// Dung lượng bộ đệm (byte).
    pub fn usage(&self) -> u64 {
        fn walk(p: &Path) -> u64 {
            let Ok(rd) = std::fs::read_dir(p) else { return 0 };
            rd.filter_map(|e| e.ok())
                .map(|e| {
                    let path = e.path();
                    // std::fs::metadata (không dùng DirEntry::metadata — gọi fstatat, iOS 8+)
                    match std::fs::metadata(&path) {
                        Ok(m) if m.is_dir() => walk(&path),
                        Ok(m) => m.len(),
                        Err(_) => 0,
                    }
                })
                .sum()
        }
        walk(&self.dir)
    }

    pub fn clear(&self) {
        for sub in ["avatars", "thumbs", "photos", "voice", "files"] {
            rm_tree(&self.dir.join(sub));
        }
    }
}

/// Xoá cả thư mục. Không dùng `std::fs::remove_dir_all`: bản của std trên Apple gọi openat / unlinkat / fdopendir (iOS 8+) →
/// dyld iOS 5 / 6 dừng app (như fstatat ở GramMini D15). Ở đây chỉ opendir / lstat / unlink / rmdir.
pub fn rm_tree(p: &Path) {
    let Ok(meta) = std::fs::symlink_metadata(p) else { return };
    if meta.is_dir() {
        if let Ok(rd) = std::fs::read_dir(p) {
            for e in rd.flatten() {
                rm_tree(&e.path());
            }
        }
        let _ = std::fs::remove_dir(p);
    } else {
        let _ = std::fs::remove_file(p);
    }
}

fn webp_to_png(data: &[u8]) -> Option<Vec<u8>> {
    let mut dec = image_webp::WebPDecoder::new(std::io::Cursor::new(data)).ok()?;
    let (w, h) = dec.dimensions();
    let alpha = dec.has_alpha();
    let mut buf = vec![0u8; dec.output_buffer_size()?];
    dec.read_image(&mut buf).ok()?;
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, w, h);
        enc.set_color(if alpha { png::ColorType::Rgba } else { png::ColorType::Rgb });
        enc.set_depth(png::BitDepth::Eight);
        let mut wr = enc.write_header().ok()?;
        wr.write_image_data(&buf).ok()?;
    }
    Some(out)
}
