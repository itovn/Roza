//! Hộp cookie tối giản (thay tough-cookie của zca-js): đủ cho id.zalo.me / *.chat.zalo.me. Lưu được ra JSON (phiên đăng nhập =
//! cookie + imei + user agent).

use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Cookie {
    pub name: String,
    pub value: String,
    /// Tên miền, không có dấu chấm đầu.
    pub domain: String,
    /// Chỉ gửi cho đúng máy chủ đã đặt (không có thuộc tính Domain).
    #[serde(default)]
    pub host_only: bool,
    #[serde(default = "root_path")]
    pub path: String,
    /// Hết hạn (Unix giây); None = cookie phiên.
    #[serde(default)]
    pub expires: Option<i64>,
    #[serde(default)]
    pub secure: bool,
}

fn root_path() -> String {
    "/".into()
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CookieJar {
    pub cookies: Vec<Cookie>,
}

impl CookieJar {
    /// Nhận một dòng `Set-Cookie` từ `host` (đường dẫn yêu cầu `req_path`).
    pub fn set_from_header(&mut self, header: &str, host: &str, req_path: &str) {
        let mut parts = header.split(';');
        let Some(nv) = parts.next() else { return };
        let Some((name, value)) = nv.split_once('=') else { return };
        let name = name.trim();
        if name.is_empty() {
            return;
        }
        let mut c = Cookie {
            name: name.to_string(),
            value: value.trim().trim_matches('"').to_string(),
            domain: host.to_ascii_lowercase(),
            host_only: true,
            path: default_path(req_path),
            expires: None,
            secure: false,
        };
        let mut max_age: Option<i64> = None;
        for attr in parts {
            let (k, v) = match attr.split_once('=') {
                Some((k, v)) => (k.trim().to_ascii_lowercase(), v.trim()),
                None => (attr.trim().to_ascii_lowercase(), ""),
            };
            match k.as_str() {
                "domain" if !v.is_empty() => {
                    let d = v.trim_start_matches('.').to_ascii_lowercase();
                    // Chỉ nhận tên miền cha của máy chủ đang trả lời
                    if host_matches(host, &d) {
                        c.domain = d;
                        c.host_only = false;
                    } else {
                        return;
                    }
                }
                "path" if v.starts_with('/') => c.path = v.to_string(),
                "expires" => {
                    if let Some(t) = parse_http_date(v) {
                        c.expires = Some(t);
                    }
                }
                "max-age" => max_age = v.parse().ok(),
                "secure" => c.secure = true,
                _ => {}
            }
        }
        if let Some(m) = max_age {
            c.expires = Some(now() + m);
        }
        self.cookies.retain(|o| !(o.name == c.name && o.domain == c.domain && o.path == c.path));
        if c.expires.map_or(true, |t| t > now()) {
            self.cookies.push(c);
        }
    }

    /// Chuỗi header `Cookie` cho một yêu cầu tới `host` / `path`.
    pub fn header_for(&self, host: &str, path: &str, https: bool) -> String {
        let t = now();
        let host = host.to_ascii_lowercase();
        let mut v: Vec<&Cookie> = self
            .cookies
            .iter()
            .filter(|c| {
                (if c.host_only { host == c.domain } else { host_matches(&host, &c.domain) })
                    && path_matches(path, &c.path)
                    && (https || !c.secure)
                    && c.expires.map_or(true, |e| e > t)
            })
            .collect();
        // Đường dẫn dài hơn đứng trước (như trình duyệt)
        v.sort_by(|a, b| b.path.len().cmp(&a.path.len()));
        v.iter().map(|c| format!("{}={}", c.name, c.value)).collect::<Vec<_>>().join("; ")
    }

    pub fn header_for_url(&self, url: &url::Url) -> String {
        self.header_for(url.host_str().unwrap_or(""), url.path(), url.scheme() == "https" || url.scheme() == "wss")
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.cookies.iter().find(|c| c.name == name).map(|c| c.value.as_str())
    }

    /// Bỏ cookie đã hết hạn.
    pub fn purge(&mut self) {
        let t = now();
        self.cookies.retain(|c| c.expires.map_or(true, |e| e > t));
    }
}

fn host_matches(host: &str, domain: &str) -> bool {
    let host = host.to_ascii_lowercase();
    host == domain || (host.len() > domain.len() && host.ends_with(domain) && host.as_bytes()[host.len() - domain.len() - 1] == b'.')
}

fn path_matches(req: &str, cookie: &str) -> bool {
    let req = if req.is_empty() { "/" } else { req };
    req == cookie || (req.starts_with(cookie) && (cookie.ends_with('/') || req.as_bytes().get(cookie.len()) == Some(&b'/')))
}

fn default_path(req_path: &str) -> String {
    match req_path.rfind('/') {
        Some(0) | None => "/".into(),
        Some(i) => req_path[..i].to_string(),
    }
}

/// Ngày kiểu HTTP: "Wed, 18 Mar 2026 10:00:00 GMT" (cả dạng có gạch "18-Mar-2026").
fn parse_http_date(s: &str) -> Option<i64> {
    let s = s.replace('-', " ");
    let mut day = None;
    let mut mon = None;
    let mut year = None;
    let mut hms = None;
    for tok in s.split(|c: char| c == ' ' || c == ',').filter(|t| !t.is_empty()) {
        if tok.contains(':') {
            let p: Vec<i64> = tok.split(':').filter_map(|x| x.parse().ok()).collect();
            if p.len() == 3 {
                hms = Some((p[0], p[1], p[2]));
            }
        } else if let Ok(n) = tok.parse::<i64>() {
            if tok.len() <= 2 && day.is_none() {
                day = Some(n);
            } else {
                year = Some(if n < 100 { n + 2000 } else { n });
            }
        } else {
            const M: [&str; 12] = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
            let t = tok.to_ascii_lowercase();
            if let Some(i) = M.iter().position(|m| t.starts_with(m)) {
                mon = Some(i as i64 + 1);
            }
        }
    }
    let (d, m, y, (hh, mm, ss)) = (day?, mon?, year?, hms.unwrap_or((0, 0, 0)));
    Some(days_from_civil(y, m, d) * 86400 + hh * 3600 + mm * 60 + ss)
}

/// Số ngày từ 1970-01-01 (thuật toán của Howard Hinnant).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn domain_and_path() {
        let mut j = CookieJar::default();
        j.set_from_header("zpw_sek=abc; Domain=.zalo.me; Path=/; Expires=Wed, 18 Mar 2099 10:00:00 GMT; Secure; HttpOnly", "id.zalo.me", "/account");
        j.set_from_header("zpsid=x1; Path=/account", "id.zalo.me", "/account/logininfo");
        j.set_from_header("other=1; Domain=evil.com", "id.zalo.me", "/");
        assert_eq!(j.cookies.len(), 2);
        assert_eq!(j.header_for("chat.zalo.me", "/", true), "zpw_sek=abc");
        assert_eq!(j.header_for("id.zalo.me", "/account/x", true), "zpsid=x1; zpw_sek=abc");
        assert_eq!(j.header_for("id.zalo.me", "/accounts", true), "zpw_sek=abc");
        assert_eq!(j.header_for("chat.zalo.me", "/", false), "");
    }

    #[test]
    fn expired_removes() {
        let mut j = CookieJar::default();
        j.set_from_header("a=1; Domain=zalo.me", "zalo.me", "/");
        j.set_from_header("a=; Domain=zalo.me; Max-Age=0", "zalo.me", "/");
        assert!(j.cookies.is_empty());
    }

    #[test]
    fn http_date() {
        assert_eq!(parse_http_date("Thu, 01 Jan 1970 00:00:10 GMT"), Some(10));
        assert_eq!(parse_http_date("Wed, 18-Mar-2026 10:00:00 GMT"), Some(1773828000));
    }
}
