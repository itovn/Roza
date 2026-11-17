//! Chữ tiếng Việt: bỏ dấu (tên chủ tài khoản ngân hàng, nội dung chuyển khoản chỉ nhận chữ không dấu).

/// Bỏ dấu tiếng Việt: «Nguyễn Văn Đức» → «Nguyen Van Duc» (nhận cả chữ dựng sẵn lẫn chữ tổ hợp).
pub fn fold_vi(s: &str) -> String {
    s.chars().filter(|c| !('\u{300}'..='\u{36f}').contains(c)).map(base_char).collect()
}

/// Bỏ dấu, viết hoa, gộp khoảng trắng — kiểu tên chủ tài khoản ngân hàng.
pub fn fold_upper(s: &str) -> String {
    fold_vi(s).split_whitespace().collect::<Vec<_>>().join(" ").to_uppercase()
}

fn base_char(c: char) -> char {
    const GROUPS: &[(&str, char)] = &[
        ("àáạảãâầấậẩẫăằắặẳẵ", 'a'),
        ("ÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴ", 'A'),
        ("èéẹẻẽêềếệểễ", 'e'),
        ("ÈÉẸẺẼÊỀẾỆỂỄ", 'E'),
        ("ìíịỉĩ", 'i'),
        ("ÌÍỊỈĨ", 'I'),
        ("òóọỏõôồốộổỗơờớợởỡ", 'o'),
        ("ÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠ", 'O'),
        ("ùúụủũưừứựửữ", 'u'),
        ("ÙÚỤỦŨƯỪỨỰỬỮ", 'U'),
        ("ỳýỵỷỹ", 'y'),
        ("ỲÝỴỶỸ", 'Y'),
        ("đ", 'd'),
        ("Đ", 'D'),
    ];
    if c.is_ascii() {
        return c;
    }
    for (set, b) in GROUPS {
        if set.contains(c) {
            return *b;
        }
    }
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fold() {
        assert_eq!(fold_vi("Nguyễn Văn Đức"), "Nguyen Van Duc");
        assert_eq!(fold_upper("  trần   thị  ánh "), "TRAN THI ANH");
        // chữ tổ hợp (e + dấu sắc rời)
        assert_eq!(fold_vi("Le\u{301}"), "Le");
    }
}
