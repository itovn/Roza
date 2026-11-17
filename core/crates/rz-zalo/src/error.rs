use std::fmt;

/// Lỗi của lớp giao thức. `code`: mã ngắn cho app (NETWORK, AUTH, ZALO, PROTOCOL, CRYPTO, …); `zalo_code`: `error_code` của
/// máy chủ Zalo nếu có.
#[derive(Clone, Debug)]
pub struct Error {
    pub code: &'static str,
    pub msg: String,
    pub zalo_code: Option<i64>,
}

impl Error {
    pub fn new(code: &'static str, msg: impl Into<String>) -> Self {
        Self { code, msg: msg.into(), zalo_code: None }
    }
    pub fn network(msg: impl Into<String>) -> Self {
        Self::new("NETWORK", msg)
    }
    pub fn protocol(msg: impl Into<String>) -> Self {
        Self::new("PROTOCOL", msg)
    }
    pub fn crypto(msg: impl Into<String>) -> Self {
        Self::new("CRYPTO", msg)
    }
    pub fn auth(msg: impl Into<String>) -> Self {
        Self::new("AUTH", msg)
    }
    pub fn zalo(code: i64, msg: impl Into<String>) -> Self {
        // Mã phiên hết hạn / bị đăng xuất của Zalo Web
        let c = if matches!(code, -1100 | -1101 | -1102 | -1103 | -1104 | -1105 | 102 | -5) { "AUTH" } else { "ZALO" };
        Self { code: c, msg: msg.into(), zalo_code: Some(code) }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.zalo_code {
            Some(z) => write!(f, "{} ({}): {}", self.code, z, self.msg),
            None => write!(f, "{}: {}", self.code, self.msg),
        }
    }
}

impl std::error::Error for Error {}

impl From<reqwest::Error> for Error {
    fn from(e: reqwest::Error) -> Self {
        if e.is_timeout() {
            Self::new("TIMEOUT", "Hết thời gian chờ máy chủ Zalo")
        } else {
            Self::network(format!("Mạng: {e}"))
        }
    }
}
