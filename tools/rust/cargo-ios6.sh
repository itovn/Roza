#!/usr/bin/env bash
# cargo cho iOS 5 / 6 (armv7, target tự định nghĩa armv7-apple-ios6.json — cortex-a8 để chạy cả A4: iPad 1, iPhone 4) trên máy
# Ubuntu có Theos + Rust nightly (rust-src). Chép từ Côn Bằng TV Legacy (tools/rust/cargo-ios6.sh), lõi dùng rustls (HTTPS + WebSocket tới máy chủ Zalo) →
# ring vá cho ARM 32-bit của Apple (vendor-ring.sh), để ngoài src (~/TestLab/Roza/vendor — src bị xoá mỗi lần sync).
#   bash tools/rust/cargo-ios6.sh build --release [-p <gói>] …     (chạy trong core/)
#   bash tools/rust/cargo-ios6.sh rustc --release -p <gói> --lib --crate-type staticlib
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
TC="$THEOS/toolchain/linux/iphone/bin"
SDKROOT="$THEOS/sdks/iPhoneOS9.3.sdk"
export SDKROOT
export IPHONEOS_DEPLOYMENT_TARGET=5.0
RING_BASE="${RING_BASE:-$(cd "$ROOT/.." && pwd)/vendor}"
RING="$RING_BASE/ring-0.17.14"
[[ -d "$RING" ]] || RING_DST="$RING_BASE" bash "$ROOT/tools/rust/vendor-ring.sh" >/dev/null
# Mã C trong các crate dựng bằng clang của Theos cho armv7 iOS 5 (Cortex-A8 trở lên)
export CC_armv7_apple_ios6="$TC/clang"
export CFLAGS_armv7_apple_ios6="-target armv7-apple-ios5.0 -isysroot $SDKROOT -mcpu=cortex-a8"
export AR_armv7_apple_ios6="$TC/llvm-ar"
# mio 1.x đánh thức tokio trên Apple bằng một lệnh kevent «EV_ADD|EV_ONESHOT + NOTE_TRIGGER»; nhân iOS 5 / 6 không kích sự
# kiện thêm kiểu đó → runtime ngủ tới khi có bộ hẹn giờ hết hạn (D8, D12; spike/02-kqueue). Đánh thức bằng pipe thì chạy.
# (Có --target nên RUSTFLAGS chỉ áp cho mã của máy iOS, không áp cho build script.)
export RUSTFLAGS="${RUSTFLAGS:-} --cfg mio_unsupported_force_waker_pipe"
. "$HOME/.cargo/env"
cmd="$1"
shift
exec cargo +nightly "$cmd" \
    -Z build-std=std,panic_abort \
    -Z json-target-spec \
    --target "$ROOT/tools/rust/armv7-apple-ios6.json" \
    --config "patch.crates-io.ring.path=\"$RING\"" \
    "$@"
