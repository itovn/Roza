//! Mã hoá của Zalo Web (chuyển từ zca-js `src/utils.ts`, MIT — xem LICENSE-zca-js).
//!
//! - Tham số / kết quả API: AES-CBC, IV toàn số 0, đệm PKCS#7, base64. Khoá phiên `zpw_enk` (base64) có sau khi đăng nhập.
//! - Lúc đăng nhập (`getLoginInfo`): khoá AES-256 là **chuỗi** 32 ký tự (byte UTF-8) suy từ `zcid` (`ParamsEncryptor`).
//! - Chữ ký `signkey` = MD5("zsecure" + loại + giá trị các tham số xếp theo tên).
//! - Sự kiện WebSocket: `encrypt` 0 = JSON, 1 = base64 + zlib, 2 = AES-GCM + zlib, 3 = AES-GCM (khoá `cipher_key` máy chủ gửi
//!   lúc mở kết nối).

use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use aes_gcm::aead::{Aead, KeyInit, Payload};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use md5::{Digest, Md5};
use rand::Rng;
use serde_json::Value;
use std::io::Read;

use crate::Error;

pub fn md5_hex(data: &[u8]) -> String {
    hex(&Md5::digest(data))
}

pub fn hex(b: &[u8]) -> String {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(b.len() * 2);
    for &x in b {
        s.push(H[(x >> 4) as usize] as char);
        s.push(H[(x & 15) as usize] as char);
    }
    s
}

const IV0: [u8; 16] = [0; 16];

/// AES-CBC (IV 0, PKCS#7) theo độ dài khoá: 16 / 24 / 32 byte.
pub fn aes_cbc_encrypt(key: &[u8], data: &[u8]) -> Result<Vec<u8>, Error> {
    Ok(match key.len() {
        16 => cbc::Encryptor::<aes::Aes128>::new_from_slices(key, &IV0).unwrap().encrypt_padded_vec_mut::<Pkcs7>(data),
        24 => cbc::Encryptor::<aes::Aes192>::new_from_slices(key, &IV0).unwrap().encrypt_padded_vec_mut::<Pkcs7>(data),
        32 => cbc::Encryptor::<aes::Aes256>::new_from_slices(key, &IV0).unwrap().encrypt_padded_vec_mut::<Pkcs7>(data),
        n => return Err(Error::crypto(format!("khoá AES {n} byte"))),
    })
}

pub fn aes_cbc_decrypt(key: &[u8], data: &[u8]) -> Result<Vec<u8>, Error> {
    let r = match key.len() {
        16 => cbc::Decryptor::<aes::Aes128>::new_from_slices(key, &IV0).unwrap().decrypt_padded_vec_mut::<Pkcs7>(data),
        24 => cbc::Decryptor::<aes::Aes192>::new_from_slices(key, &IV0).unwrap().decrypt_padded_vec_mut::<Pkcs7>(data),
        32 => cbc::Decryptor::<aes::Aes256>::new_from_slices(key, &IV0).unwrap().decrypt_padded_vec_mut::<Pkcs7>(data),
        n => return Err(Error::crypto(format!("khoá AES {n} byte"))),
    };
    r.map_err(|_| Error::crypto("giải mã AES: sai đệm"))
}

/// `decodeURIComponent` (chỉ phần %XX — dữ liệu là base64 nên không có ký tự nhiều byte).
pub fn url_decode(s: &str) -> String {
    percent_encoding::percent_decode_str(s).decode_utf8_lossy().into_owned()
}

/// Mã hoá tham số API bằng khoá phiên (`zpw_enk`, base64) → base64.
pub fn encode_aes(secret_b64: &str, plain: &str) -> Result<String, Error> {
    let key = B64.decode(secret_b64.trim()).map_err(|_| Error::crypto("khoá phiên không phải base64"))?;
    Ok(B64.encode(aes_cbc_encrypt(&key, plain.as_bytes())?))
}

/// Giải kết quả API bằng khoá phiên (dữ liệu có thể đã mã hoá URL).
pub fn decode_aes(secret_b64: &str, data: &str) -> Result<String, Error> {
    let key = B64.decode(secret_b64.trim()).map_err(|_| Error::crypto("khoá phiên không phải base64"))?;
    let raw = B64.decode(url_decode(data).trim()).map_err(|_| Error::crypto("dữ liệu không phải base64"))?;
    String::from_utf8(aes_cbc_decrypt(&key, &raw)?).map_err(|_| Error::crypto("dữ liệu giải mã không phải UTF-8"))
}

/// AES với khoá là chuỗi (byte UTF-8 của chuỗi) — `ParamsEncryptor.encodeAES` / `decodeRespAES`.
pub fn encode_aes_str_key(key: &str, plain: &str, hex_out: bool, upper: bool) -> Result<String, Error> {
    let c = aes_cbc_encrypt(key.as_bytes(), plain.as_bytes())?;
    let s = if hex_out { hex(&c) } else { B64.encode(c) };
    Ok(if upper { s.to_uppercase() } else { s })
}

pub fn decode_aes_str_key(key: &str, data: &str) -> Result<String, Error> {
    let raw = B64.decode(url_decode(data).trim()).map_err(|_| Error::crypto("dữ liệu không phải base64"))?;
    String::from_utf8(aes_cbc_decrypt(key.as_bytes(), &raw)?).map_err(|_| Error::crypto("dữ liệu giải mã không phải UTF-8"))
}

/// `getSignKey(type, params)`: MD5("zsecure" + type + giá trị các tham số theo thứ tự tên). Giá trị chuỗi giữ nguyên, số in như JS.
pub fn sign_key(kind: &str, params: &[(&str, String)]) -> String {
    let mut p: Vec<&(&str, String)> = params.iter().collect();
    p.sort_by(|a, b| a.0.cmp(b.0));
    let mut a = String::from("zsecure");
    a.push_str(kind);
    for (_, v) in p {
        a.push_str(v);
    }
    md5_hex(a.as_bytes())
}

/// Bộ mã hoá tham số lúc đăng nhập (`ParamsEncryptor` của zca-js).
pub struct ParamsEncryptor {
    pub zcid: String,
    pub zcid_ext: String,
    pub encrypt_key: String,
}

impl ParamsEncryptor {
    pub fn new(api_type: u32, imei: &str, first_launch_ms: u64) -> Result<Self, Error> {
        Self::with_ext(api_type, imei, first_launch_ms, random_hex(6, 12))
    }

    /// Như `new` nhưng chỉ định `zcid_ext` (để thử).
    pub fn with_ext(api_type: u32, imei: &str, first_launch_ms: u64, zcid_ext: String) -> Result<Self, Error> {
        let msg = format!("{api_type},{imei},{first_launch_ms}");
        let zcid = encode_aes_str_key("3FC4F0D2AB50057BCE0D90D9187A22B1", &msg, true, true)?;
        let n = md5_hex(zcid_ext.as_bytes()).to_uppercase();
        let (n_even, _) = even_odd(&n);
        let (a, s) = even_odd(&zcid);
        let s_rev: Vec<char> = s.into_iter().rev().collect();
        if n_even.len() < 8 || a.len() < 12 || s_rev.len() < 12 {
            return Err(Error::crypto("createEncryptKey: chuỗi quá ngắn"));
        }
        let encrypt_key: String = n_even[..8].iter().chain(&a[..12]).chain(&s_rev[..12]).collect();
        Ok(Self { zcid, zcid_ext, encrypt_key })
    }

    /// Mã hoá dữ liệu đăng nhập (JSON) bằng khoá vừa suy → base64.
    pub fn encode(&self, plain: &str) -> Result<String, Error> {
        encode_aes_str_key(&self.encrypt_key, plain, false, false)
    }
}

fn even_odd(s: &str) -> (Vec<char>, Vec<char>) {
    let (mut e, mut o) = (Vec::new(), Vec::new());
    for (i, c) in s.chars().enumerate() {
        if i % 2 == 0 { e.push(c) } else { o.push(c) }
    }
    (e, o)
}

/// Chuỗi hex ngẫu nhiên dài [min, max] (`ParamsEncryptor.randomString`).
pub fn random_hex(min: usize, max: usize) -> String {
    let mut rng = rand::thread_rng();
    let n = rng.gen_range(min..=max);
    (0..n).map(|_| std::char::from_digit(rng.gen_range(0..16), 16).unwrap()).collect()
}

/// UUID v4 (chữ thường).
pub fn uuid_v4() -> String {
    let mut b = [0u8; 16];
    rand::thread_rng().fill(&mut b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = hex(&b);
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

/// `generateZaloUUID(userAgent)` — mã máy (imei) của phiên web: UUID + "-" + MD5(user agent).
pub fn zalo_uuid(user_agent: &str) -> String {
    format!("{}-{}", uuid_v4(), md5_hex(user_agent.as_bytes()))
}

/// Giải nén zlib / gzip / deflate thô (pako.inflate tự nhận dạng).
pub fn inflate(data: &[u8]) -> Result<Vec<u8>, Error> {
    let mut out = Vec::new();
    let ok = if data.len() >= 2 && data[0] == 0x1f && data[1] == 0x8b {
        flate2::read::GzDecoder::new(data).read_to_end(&mut out).is_ok()
    } else {
        flate2::read::ZlibDecoder::new(data).read_to_end(&mut out).is_ok()
    };
    if ok {
        return Ok(out);
    }
    out.clear();
    flate2::read::DeflateDecoder::new(data).read_to_end(&mut out).map_err(|_| Error::crypto("giải nén dữ liệu sự kiện"))?;
    Ok(out)
}

/// Giải dữ liệu một sự kiện WebSocket (`decodeEventData`): `{"data": "...", "encrypt": 0..3}` → JSON.
pub fn decode_event_data(parsed: &Value, cipher_key: Option<&str>) -> Result<Value, Error> {
    let data = parsed.get("data").and_then(Value::as_str).ok_or_else(|| Error::protocol("sự kiện: thiếu data"))?;
    let enc = parsed.get("encrypt").and_then(Value::as_i64).ok_or_else(|| Error::protocol("sự kiện: thiếu encrypt"))?;
    if enc == 0 {
        return serde_json::from_str(data).map_err(|_| Error::protocol("sự kiện: JSON hỏng"));
    }
    if !(1..=3).contains(&enc) {
        return Err(Error::protocol(format!("sự kiện: encrypt = {enc}")));
    }
    let src = if enc == 1 { data.to_string() } else { url_decode(data) };
    let buf = B64.decode(src.trim()).map_err(|_| Error::protocol("sự kiện: base64 hỏng"))?;
    let plain = if enc == 1 {
        buf
    } else {
        let key = cipher_key.ok_or_else(|| Error::protocol("sự kiện mã hoá nhưng chưa có cipher key"))?;
        let key = B64.decode(key.trim()).map_err(|_| Error::protocol("cipher key không phải base64"))?;
        if buf.len() < 48 {
            return Err(Error::protocol("sự kiện: dữ liệu quá ngắn"));
        }
        aes_gcm16_decrypt(&key, &buf[..16], &buf[16..32], &buf[32..])?
    };
    let bytes = if enc == 3 { plain } else { inflate(&plain)? };
    if bytes.is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_slice(&bytes).map_err(|_| Error::protocol("sự kiện: JSON hỏng sau khi giải mã"))
}

/// AES-GCM, IV 16 byte, thẻ 128 bit (thẻ nằm cuối `ct`).
fn aes_gcm16_decrypt(key: &[u8], iv: &[u8], aad: &[u8], ct: &[u8]) -> Result<Vec<u8>, Error> {
    use aes_gcm::aead::generic_array::{typenum::U16, GenericArray};
    let nonce = GenericArray::<u8, U16>::from_slice(iv);
    let payload = Payload { msg: ct, aad };
    let r = match key.len() {
        16 => aes_gcm::AesGcm::<aes::Aes128, U16>::new_from_slice(key).unwrap().decrypt(nonce, payload),
        32 => aes_gcm::AesGcm::<aes::Aes256, U16>::new_from_slice(key).unwrap().decrypt(nonce, payload),
        n => return Err(Error::crypto(format!("cipher key {n} byte"))),
    };
    r.map_err(|_| Error::crypto("giải mã AES-GCM thất bại"))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vectơ thử sinh bằng Node (node:crypto, cùng thuật toán với crypto-js trong zca-js) — xem tools/zca-vectors.mjs
    #[test]
    fn sign_key_sorted() {
        let p = [("imei", "abc".to_string()), ("type", "30".into()), ("client_version", "695".into()), ("computer_name", "Web".into())];
        assert_eq!(sign_key("getserverinfo", &p), md5_hex(b"zsecuregetserverinfo695Webabc30"));
    }

    #[test]
    fn aes_roundtrip() {
        let k = B64.encode([7u8; 32]);
        let e = encode_aes(&k, "{\"a\":1}").unwrap();
        assert_eq!(decode_aes(&k, &e).unwrap(), "{\"a\":1}");
        let e2 = percent_encoding::utf8_percent_encode(&e, percent_encoding::NON_ALPHANUMERIC).to_string();
        assert_eq!(decode_aes(&k, &e2).unwrap(), "{\"a\":1}");
    }

    #[test]
    fn encryptor_matches_zca_js() {
        // node tools/zca-vectors.mjs
        let p = ParamsEncryptor::with_ext(30, "imei-x", 1700000000000, "a1b2c3d4".into()).unwrap();
        assert_eq!(p.zcid, "4B24483CF41B7E2C66180976DE9AF8A264A4DB7299EEE5D7268AA95AFE51FBC8");
        assert_eq!(p.encrypt_key, "2C4316464243F17261078B1EA9A675E9");
        let data = serde_json::json!({"computer_name": "Web", "imei": "imei-x", "language": "vi", "ts": 1700000000000u64}).to_string();
        let enc = p.encode(&data).unwrap();
        assert_eq!(enc, "3OgAWTno3nsFq2yY7om+KxjCesM7P3Nv1t47+mo+UICyWrAHLTVSWJq6UhIgx/mjcQ8CWxM/gK4NUIMU1wbssXNAw9NkHWoeCgvqUpd/EqI=");
        let params = [
            ("zcid", p.zcid.clone()),
            ("zcid_ext", "a1b2c3d4".to_string()),
            ("enc_ver", "v2".into()),
            ("params", enc),
            ("type", "30".into()),
            ("client_version", "695".into()),
        ];
        assert_eq!(sign_key("getlogininfo", &params), "c5b39a2acbea7b191a1a5f74cb9f5d81");
        assert_eq!(encode_aes(&B64.encode([7u8; 32]), r#"{"imei":"imei-x"}"#).unwrap(), "ypgz6QNQ0bvdYmdvSZUCBBLBqzl/lH55nBTsczEGeSc=");
    }

    #[test]
    fn event_plain_and_zlib() {
        let v: Value = serde_json::json!({"data": "{\"x\":1}", "encrypt": 0});
        assert_eq!(decode_event_data(&v, None).unwrap()["x"], 1);
        let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        std::io::Write::write_all(&mut z, b"{\"y\":2}").unwrap();
        let v: Value = serde_json::json!({"data": B64.encode(z.finish().unwrap()), "encrypt": 1});
        assert_eq!(decode_event_data(&v, None).unwrap()["y"], 2);
    }

    #[test]
    fn uuid_shape() {
        let u = zalo_uuid("UA");
        assert_eq!(u.len(), 36 + 1 + 32);
        assert_eq!(&u[14..15], "4");
    }
}
