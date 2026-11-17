#!/usr/bin/env bash
# Chép ring (thư viện mã hoá của rustls / reqwest) vào vendor/ và vá cho ARM 32-bit của Apple (iOS 6, armv7):
#  1. build.rs: thêm kiểu assembly "ios32" (bộ dịch arm-xlate.pl của ring vẫn hỗ trợ) — bản crates.io chỉ có ARM 32-bit cho Linux
#     → thiếu 17 hàm assembly (SHA-256/512, ChaCha20, AES vpaes/bsaes, GHASH, nhân Montgomery) lúc liên kết.
#  2. Sinh sẵn các tệp *-ios32.S vào pregenerated/ (bản đóng gói của ring không chạy perl lúc dựng).
#  3. poly1305 bản NEON (poly1305_arm_asm.S) chỉ có cho ELF → trên Apple ARM 32-bit dùng bản thường (BoringSSL cũng bỏ Apple ở đây).
# Dùng: bash tools/rust/vendor-ring.sh [phiên bản ring]  → vendor/ring-<bản>; crate dùng nó qua [patch.crates-io].
set -euo pipefail
VER="${1:-0.17.14}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$(ls -d "$HOME"/.cargo/registry/src/*/ring-"$VER" | head -1)"
# GramMini: thư mục đích ngoài src (src bị xoá mỗi lần sync) — RING_DST, mặc định <repo>/vendor
DST="${RING_DST:-$ROOT/vendor}/ring-$VER"
[[ -d "$SRC" ]] || { echo "chưa có ring-$VER trong ~/.cargo/registry — chạy cargo fetch trước"; exit 1; }

rm -rf "$DST"
mkdir -p "$(dirname "$DST")"
cp -r "$SRC" "$DST"
cd "$DST"

python3 - <<'EOF'
import re
p = "build.rs"
s = open(p).read()
anchor = '''        perlasm_format: "ios64",
    },
'''
assert anchor in s, "không thấy mục ios64 trong build.rs"
s = s.replace(anchor, anchor + '''    // cbtv-legacy: ARM 32-bit của Apple (iOS 6 armv7)
    AsmTarget {
        oss: APPLE_ABI,
        arch: ARM,
        perlasm_format: "ios32",
    },
''', 1)
open(p, "w").write(s)

n = 0
for p in ("src/aead/poly1305.rs", "src/aead/poly1305/ffi_arm_neon.rs"):
    s = open(p).read()
    k = 0
    for old, new in (('cfg(all(target_arch = "arm", target_endian = "little"))',
                      'cfg(all(target_arch = "arm", target_endian = "little", not(target_vendor = "apple")))'),):
        k += s.count(old)
        s = s.replace(old, new)
    assert k > 0, "không thấy cfg ARM trong " + p
    open(p, "w").write(s)
    n += k

# target.h (lấy từ BoringSSL) tắt hẳn assembly ARM 32-bit trên Apple («iOS 10 là bản cuối còn 32-bit») → các tệp *-ios32.S
# dựng ra rỗng mà phần Rust vẫn gọi hàm assembly. iOS 6 cần lại assembly này.
p = "include/ring-core/target.h"
s = open(p).read()
old = """#if defined(OPENSSL_APPLE) && defined(OPENSSL_ARM)
#define OPENSSL_ASM_INCOMPATIBLE
#endif"""
assert old in s, "không thấy khối tắt assembly Apple ARM trong target.h"
open(p, "w").write(s.replace(old, "// cbtv-legacy: bỏ khối tắt assembly ARM 32-bit trên Apple (cần cho iOS 6 armv7)"))
print("vá build.rs (ios32), poly1305 (%d chỗ), target.h" % n)
EOF

# Sinh assembly ios32 cho các tệp perl ARM (danh sách RING_SRCS mục &[ARM] trong build.rs)
for pl in crypto/fipsmodule/aes/asm/bsaes-armv7.pl crypto/fipsmodule/aes/asm/ghash-armv4.pl \
          crypto/fipsmodule/aes/asm/vpaes-armv7.pl crypto/fipsmodule/bn/asm/armv4-mont.pl \
          crypto/chacha/asm/chacha-armv4.pl crypto/fipsmodule/sha/asm/sha256-armv4.pl \
          crypto/fipsmodule/sha/asm/sha512-armv4.pl; do
    stem="$(basename "$pl" .pl)"
    perl "$pl" ios32 "pregenerated/$stem-ios32.S"
done
ls pregenerated/*-ios32.S
