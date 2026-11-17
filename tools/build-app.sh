#!/usr/bin/env bash
# Dựng app Roza (.deb) trên máy Ubuntu có Theos + Rust nightly: lõi Rust (crate rz-ffi) → librz_ffi.a, rồi make package.
#   bash tools/build-app.sh                    bản thử
#   bash tools/build-app.sh FINALPACKAGE=1     bản phát hành
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${CARGO_TARGET_DIR:-$(cd "$ROOT/.." && pwd)/target-ios}"
cd "$ROOT/core"
CARGO_TARGET_DIR="$OUT" bash "$ROOT/tools/rust/cargo-ios6.sh" build --release -p rz-ffi
ls -la "$OUT/armv7-apple-ios6/release/librz_ffi.a"
cd "$ROOT/app"
export THEOS="${THEOS:-$HOME/theos}"
rm -f packages/*.deb
make package CORE_LIB_DIR="$OUT/armv7-apple-ios6/release" "$@"
ls -la packages/*.deb
