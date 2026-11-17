//! Mã VietQR (chuẩn EMVCo của NAPAS) để chuyển khoản: ngân hàng (mã BIN) + số tài khoản (+ số tiền, nội dung). App ngân hàng
//! nào ở Việt Nam cũng quét được. Lõi dựng chuỗi mã và ma trận QR; app tự vẽ thẻ (tên ngân hàng, số tài khoản, số tiền) quanh mã.

use qrcode::{Color, EcLevel, QrCode};
use serde_json::{json, Value};

/// Chuỗi VietQR. `amount` = 0 → mã tĩnh (người chuyển tự nhập số tiền).
pub fn payload(bin: &str, account: &str, amount: u64, note: &str) -> String {
    let bene = tlv("00", bin) + &tlv("01", account);
    let merchant = tlv("00", "A000000727") + &tlv("01", &bene) + &tlv("02", "QRIBFTTA");
    let mut s = tlv("00", "01") + &tlv("01", if amount > 0 { "12" } else { "11" }) + &tlv("38", &merchant) + &tlv("53", "704");
    if amount > 0 {
        s += &tlv("54", &amount.to_string());
    }
    s += &tlv("58", "VN");
    let note = clean_note(note);
    if !note.is_empty() {
        s += &tlv("62", &tlv("08", &note));
    }
    s += "6304";
    let crc = crc16(s.as_bytes());
    s + &format!("{crc:04X}")
}

/// Ma trận QR của `data`: `{size, bits}` — `bits` là chuỗi '1' (ô đen) / '0', hàng nối hàng.
pub fn matrix(data: &str) -> Option<Value> {
    let code = QrCode::with_error_correction_level(data.as_bytes(), EcLevel::M).ok()?;
    let bits: String = code.to_colors().iter().map(|c| if *c == Color::Dark { '1' } else { '0' }).collect();
    Some(json!({"size": code.width(), "bits": bits}))
}

/// Số tài khoản hợp lệ: 4–19 chữ / số (VietQR cho cả tài khoản số đẹp có chữ).
pub fn valid_account(a: &str) -> bool {
    (4..=19).contains(&a.len()) && a.chars().all(|c| c.is_ascii_alphanumeric())
}

/// Nội dung chuyển khoản: bỏ dấu, chỉ chữ / số / khoảng trắng, tối đa 50 ký tự (ngân hàng không nhận ký tự lạ).
fn clean_note(note: &str) -> String {
    let s: String = rz_zalo::text::fold_vi(note).chars().map(|c| if c.is_ascii_alphanumeric() { c } else { ' ' }).collect();
    s.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(50).collect()
}

/// Đọc chuỗi VietQR → (BIN ngân hàng, số tài khoản).
pub fn parse_payload(p: &str) -> Option<(String, String)> {
    let top = tlv_map(p)?;
    let merchant = tlv_map(top.get("38")?)?;
    let bene = tlv_map(merchant.get("01")?)?;
    Some((bene.get("00")?.clone(), bene.get("01")?.clone()))
}

fn tlv_map(s: &str) -> Option<std::collections::HashMap<String, String>> {
    if !s.is_ascii() {
        return None;
    }
    let mut m = std::collections::HashMap::new();
    let mut i = 0;
    while i + 4 <= s.len() {
        let id = &s[i..i + 2];
        let len: usize = s[i + 2..i + 4].parse().ok()?;
        if i + 4 + len > s.len() {
            break;
        }
        m.insert(id.to_string(), s[i + 4..i + 4 + len].to_string());
        i += 4 + len;
    }
    if m.is_empty() { None } else { Some(m) }
}

/// Các chuỗi trong dữ liệu FlatBuffers (mẫu zinstant của Zalo): [độ dài u32 LE][byte UTF-8][0].
pub fn fb_strings(d: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 4 <= d.len() {
        let len = u32::from_le_bytes([d[i], d[i + 1], d[i + 2], d[i + 3]]) as usize;
        if (2..=8192).contains(&len) && i + 4 + len < d.len() && d[i + 4 + len] == 0 {
            if let Ok(t) = std::str::from_utf8(&d[i + 4..i + 4 + len]) {
                if !t.chars().any(|c| c.is_control() && !matches!(c, '\n' | '\t')) {
                    out.push(t.to_string());
                    i += 4 + len + 1;
                    continue;
                }
            }
        }
        i += 1;
    }
    out
}

/// Thẻ tài khoản ngân hàng (mẫu zinstant `zinstant.bankcard` đã giải nén): `{bin, number, holder, bank, payload}`.
/// Chuỗi VietQR nằm trong nút «Lưu tài khoản» (`…?action=save&content=000201…`); tên chủ tài khoản đứng trước số tài khoản
/// (viết hoa), tên ngân hàng đứng ngay sau.
pub fn bank_card(data: &[u8]) -> Option<Value> {
    let strs = fb_strings(data);
    let payload = strs.iter().find_map(|x| {
        let start = x.find("000201")?;
        let p = &x[start..];
        Some(p.split(['&', '"', ' ']).next().unwrap_or(p).to_string())
    })?;
    let (bin, number) = parse_payload(&payload)?;
    let pos = strs.iter().position(|x| *x == number);
    let holder = pos
        .and_then(|i| (i.saturating_sub(4)..i).rev().map(|k| &strs[k]).find(|h| looks_like_holder(h)).cloned())
        .unwrap_or_default();
    let bank = pos
        .and_then(|i| strs.get(i + 1))
        .filter(|b| !b.starts_with("http") && !b.starts_with('[') && !b.starts_with('{') && b.chars().count() <= 80)
        .cloned()
        .unwrap_or_default();
    Some(json!({"bin": bin, "number": number, "holder": holder, "bank": bank, "payload": payload}))
}

fn looks_like_holder(s: &str) -> bool {
    let n = s.chars().count();
    (2..=70).contains(&n)
        && s.chars().any(char::is_alphabetic)
        && s.chars().all(|c| c.is_alphabetic() || c == ' ' || c == '.' || c == '-')
        && s == s.to_uppercase()
}

fn tlv(id: &str, v: &str) -> String {
    format!("{id}{:02}{v}", v.len())
}

/// CRC-16/CCITT-FALSE (đa thức 0x1021, khởi đầu 0xFFFF) — trường 63 của EMVCo.
fn crc16(data: &[u8]) -> u16 {
    let mut crc: u16 = 0xFFFF;
    for &b in data {
        crc ^= (b as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 { (crc << 1) ^ 0x1021 } else { crc << 1 };
        }
    }
    crc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc_check_value() {
        assert_eq!(crc16(b"123456789"), 0x29B1);
    }

    #[test]
    fn static_and_dynamic() {
        let s = payload("970436", "0011001234567", 0, "");
        assert!(s.starts_with("000201010211"));
        assert!(s.contains("0010A000000727"));
        assert!(s.contains("0006970436"));
        assert!(s.contains("01130011001234567"));
        assert!(s.contains("0208QRIBFTTA"));
        assert!(s.contains("5303704") && s.contains("5802VN"));
        // CRC khớp phần trước nó
        let (body, crc) = s.split_at(s.len() - 4);
        assert_eq!(format!("{:04X}", crc16(body.as_bytes())), crc);

        let d = payload("970436", "0011001234567", 150000, "Trả tiền ăn trưa!");
        assert!(d.starts_with("000201010212"));
        assert!(d.contains("5406150000"));
        assert!(d.contains("0816Tra tien an trua"));
    }

    #[test]
    fn qr_matrix() {
        let m = matrix(&payload("970436", "0011001234567", 0, "")).unwrap();
        let n = m["size"].as_u64().unwrap() as usize;
        assert!(n >= 21);
        assert_eq!(m["bits"].as_str().unwrap().len(), n * n);
    }

    /// Dựng dữ liệu kiểu FlatBuffers (độ dài u32 + chuỗi + 0, đệm 4 byte) cho thử nghiệm.
    fn fb(parts: &[&str]) -> Vec<u8> {
        let mut d = vec![7u8; 24];
        for p in parts {
            d.extend_from_slice(&(p.len() as u32).to_le_bytes());
            d.extend_from_slice(p.as_bytes());
            d.push(0);
            while d.len() % 4 != 0 {
                d.push(0);
            }
            d.extend_from_slice(&[1, 2, 3, 4]);
        }
        d
    }

    #[test]
    fn bank_card_template() {
        let qr = payload("970436", "0123456789", 0, "");
        let save = format!("https://bankcard-action.zalo.me?action=save&content={qr}");
        let d = fb(&["receiver_btn_transfer", "Lưu tài khoản", &save, "ROZA THU", "[\"pc\", \"web\"]", "0123456789",
                     "Ngân hàng Vietcombank", "https://res-zalo.zadn.vn/logo.png", "970436"]);
        let c = bank_card(&d).unwrap();
        assert_eq!(c["bin"], "970436");
        assert_eq!(c["number"], "0123456789");
        assert_eq!(c["holder"], "ROZA THU");
        assert_eq!(c["bank"], "Ngân hàng Vietcombank");
        assert_eq!(parse_payload(&qr), Some(("970436".into(), "0123456789".into())));
    }
}
