//! HTTP của lõi (thay `request()` của zca-js): reqwest + rustls, cookie tự quản, tự theo chuyển hướng (`Location`) như zca-js —
//! giữ cookie của từng bước (đăng nhập QR đi qua nhiều lần chuyển hướng giữa id.zalo.me và chat.zalo.me).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderName, HeaderValue, LOCATION, SET_COOKIE};
use reqwest::Method;
use url::Url;

use crate::cookies::CookieJar;
use crate::Error;

pub const ORIGIN: &str = "https://chat.zalo.me";
pub const REFERER: &str = "https://chat.zalo.me/";

#[derive(Clone)]
pub struct Http {
    client: reqwest::Client,
    pub jar: Arc<Mutex<CookieJar>>,
    pub user_agent: String,
}

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
    pub url: Url,
}

impl Response {
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
    pub fn json(&self) -> Result<serde_json::Value, Error> {
        serde_json::from_slice(&self.body).map_err(|_| {
            let head: String = self.text().chars().take(120).collect();
            Error::protocol(format!("Máy chủ trả dữ liệu không phải JSON (HTTP {}): {head}", self.status))
        })
    }
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

/// Thân yêu cầu.
pub enum Body {
    None,
    Form(Vec<(String, String)>),
    Multipart { boundary: String, data: Vec<u8> },
    Raw { content_type: String, data: Vec<u8> },
}

impl Http {
    pub fn new(user_agent: &str, jar: CookieJar) -> Result<Self, Error> {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(60))
            .pool_idle_timeout(Duration::from_secs(50))
            .pool_max_idle_per_host(2)
            .build()
            .map_err(|e| Error::network(format!("Không tạo được HTTP: {e}")))?;
        Ok(Self { client, jar: Arc::new(Mutex::new(jar)), user_agent: user_agent.to_string() })
    }

    pub fn jar_snapshot(&self) -> CookieJar {
        self.jar.lock().unwrap().clone()
    }

    /// Header mặc định của API Zalo Web (`getDefaultHeaders`).
    pub fn api_headers(&self) -> Vec<(&'static str, String)> {
        vec![
            ("accept", "application/json, text/plain, */*".into()),
            ("accept-language", "vi-VN,vi;q=0.9,en-US;q=0.6,en;q=0.5".into()),
            ("origin", ORIGIN.into()),
            ("referer", REFERER.into()),
        ]
    }

    /// Gửi yêu cầu, nhận cookie, theo `Location` (GET, Referer id.zalo.me — như zca-js). `headers` thêm vào / đè header mặc định.
    pub async fn request(&self, method: Method, url: &str, headers: &[(&str, String)], body: Body, timeout: Option<Duration>) -> Result<Response, Error> {
        let mut url = Url::parse(url).map_err(|_| Error::protocol(format!("URL hỏng: {url}")))?;
        let mut method = method;
        let mut body = body;
        let mut extra: Vec<(String, String)> = headers.iter().map(|(k, v)| (k.to_ascii_lowercase(), v.clone())).collect();
        for _hop in 0..10 {
            let mut h = HeaderMap::new();
            h.insert("user-agent", hv(&self.user_agent));
            let cookie = self.jar.lock().unwrap().header_for_url(&url);
            if !cookie.is_empty() {
                h.insert("cookie", hv(&cookie));
            }
            for (k, v) in &extra {
                if let Ok(name) = HeaderName::from_bytes(k.as_bytes()) {
                    h.insert(name, hv(v));
                }
            }
            let mut rb = self.client.request(method.clone(), url.clone()).headers(h);
            if let Some(t) = timeout {
                rb = rb.timeout(t);
            }
            rb = match &body {
                Body::None => rb,
                Body::Form(f) => rb.header("content-type", "application/x-www-form-urlencoded").body(form_encode(f)),
                Body::Multipart { boundary, data } => {
                    rb.header("content-type", format!("multipart/form-data; boundary={boundary}")).body(data.clone())
                }
                Body::Raw { content_type, data } => rb.header("content-type", content_type.as_str()).body(data.clone()),
            };
            let resp = rb.send().await?;
            let status = resp.status().as_u16();
            {
                let mut jar = self.jar.lock().unwrap();
                for v in resp.headers().get_all(SET_COOKIE) {
                    if let Ok(s) = v.to_str() {
                        jar.set_from_header(s, url.host_str().unwrap_or(""), url.path());
                    }
                }
            }
            let location = resp.headers().get(LOCATION).and_then(|v| v.to_str().ok()).map(str::to_string);
            if let Some(loc) = location {
                if let Ok(next) = url.join(&loc) {
                    url = next;
                    method = Method::GET;
                    body = Body::None;
                    extra.retain(|(k, _)| k != "referer" && k != "content-type");
                    extra.push(("referer".into(), "https://id.zalo.me/".into()));
                    continue;
                }
            }
            let body = resp.bytes().await?.to_vec();
            return Ok(Response { status, body, url });
        }
        Err(Error::protocol("Chuyển hướng quá nhiều lần"))
    }

    pub async fn get(&self, url: &str, headers: &[(&str, String)]) -> Result<Response, Error> {
        self.request(Method::GET, url, headers, Body::None, None).await
    }

    pub async fn post_form(&self, url: &str, headers: &[(&str, String)], form: Vec<(String, String)>) -> Result<Response, Error> {
        self.request(Method::POST, url, headers, Body::Form(form), None).await
    }

    /// Tải nguyên tệp (ảnh, ảnh đại diện…) — không gửi cookie riêng của API, chỉ cookie theo tên miền như trình duyệt.
    pub async fn download(&self, url: &str, max_bytes: usize) -> Result<Vec<u8>, Error> {
        let u = Url::parse(url).map_err(|_| Error::protocol(format!("URL hỏng: {url}")))?;
        let mut rb = self.client.get(u.clone()).header("user-agent", &self.user_agent).header("referer", REFERER);
        let cookie = self.jar.lock().unwrap().header_for_url(&u);
        if !cookie.is_empty() {
            rb = rb.header("cookie", cookie);
        }
        let mut resp = rb.send().await?;
        // Theo tối đa vài lần chuyển hướng (CDN ảnh)
        for _ in 0..5 {
            if !resp.status().is_redirection() {
                break;
            }
            let Some(loc) = resp.headers().get(LOCATION).and_then(|v| v.to_str().ok()).and_then(|l| u.join(l).ok()) else { break };
            resp = self.client.get(loc).header("user-agent", &self.user_agent).send().await?;
        }
        if !resp.status().is_success() {
            return Err(Error::network(format!("Tải tệp: HTTP {}", resp.status().as_u16())));
        }
        let mut out = Vec::new();
        while let Some(chunk) = resp.chunk().await? {
            out.extend_from_slice(&chunk);
            if out.len() > max_bytes {
                return Err(Error::network("Tệp quá lớn"));
            }
        }
        Ok(out)
    }
}

fn hv(s: &str) -> HeaderValue {
    HeaderValue::from_str(s).unwrap_or_else(|_| HeaderValue::from_static(""))
}

pub fn form_encode(f: &[(String, String)]) -> String {
    let mut s = url::form_urlencoded::Serializer::new(String::new());
    for (k, v) in f {
        s.append_pair(k, v);
    }
    s.finish()
}

/// `makeURL`: thêm tham số vào URL; `api_version` thì thêm `zpw_ver` / `zpw_type` nếu chưa có.
pub fn make_url(base: &str, params: &[(&str, String)], api_version: Option<(u32, u32)>) -> String {
    let Ok(mut u) = Url::parse(base) else { return base.to_string() };
    {
        let mut q = u.query_pairs_mut();
        for (k, v) in params {
            q.append_pair(k, v);
        }
    }
    if let Some((ty, ver)) = api_version {
        let has = |k: &str| u.query_pairs().any(|(n, _)| n == k);
        let (hv, ht) = (has("zpw_ver"), has("zpw_type"));
        let mut q = u.query_pairs_mut();
        if !hv {
            q.append_pair("zpw_ver", &ver.to_string());
        }
        if !ht {
            q.append_pair("zpw_type", &ty.to_string());
        }
    }
    u.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn make_url_adds_version_once() {
        let u = make_url("https://a.zalo.me/api/x?zpw_ver=1", &[("params", "a+b/c=".into())], Some((30, 695)));
        assert_eq!(u, "https://a.zalo.me/api/x?zpw_ver=1&params=a%2Bb%2Fc%3D&zpw_type=30");
    }
}
