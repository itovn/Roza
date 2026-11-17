//! Giao thức Zalo Web cho Roza — chuyển từ [zca-js](https://github.com/RFS-ADRENO/zca-js) (MIT, © RFS-ADRENO, truong9c2208,
//! JustKemForFun — xem `LICENSE-zca-js`) sang Rust để chạy ngay trên iPhone / iPad iOS 5 / 6 (không có Node.js, không có
//! JavaScriptCore công khai, TLS của hệ thống quá cũ).
//!
//! - [`login`]: đăng nhập QR, đăng nhập lại bằng cookie (khoá phiên `zpw_enk`).
//! - [`api`]: các lệnh HTTP (gửi tin, đã xem, bạn bè, nhóm…).
//! - [`listen`]: WebSocket nhận tin / sự kiện.
//! - [`crypto`], [`cookies`], [`http`], [`text`]: phần nền.

pub mod api;
pub mod cookies;
pub mod crypto;
mod error;
pub mod http;
pub mod listen;
pub mod login;
pub mod text;

pub use api::{Api, Mention, MsgRef, Quote, Thread};
pub use error::Error;
pub use login::{Credentials, LoginInfo, QrEvent};

/// Giờ Unix (ms).
pub fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}
