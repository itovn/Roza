#!/usr/bin/env bash
# Tạo / cập nhật nguồn Cydia (APT phẳng) trong thư mục cydia/ của trang giới thiệu (nhánh gh-pages của itovn/Roza):
#   bash tools/update-cydia-repo.sh <thư mục trang>/cydia <tệp .deb mới>…
# Chép .deb vào cydia/debs (giữ 3 bản mới nhất), tạo Packages(.gz/.bz2) bằng dpkg-scanpackages (thêm Depiction / Homepage nếu
# gói chưa có) và Release (MD5 + SHA256).
# Nguồn trong Cydia: https://itovn.github.io/Roza/cydia/  (dòng APT: deb https://itovn.github.io/Roza/cydia/ ./)
# Cần dpkg-dev (dpkg-scanpackages), gzip, bzip2 — chạy trên máy Linux dựng.
set -euo pipefail
REPO="${1:?thư mục cydia/}"
shift
SITE="https://itovn.github.io/Roza"
mkdir -p "$REPO/debs"
for d in "$@"; do
    cp "$d" "$REPO/debs/"
done
cd "$REPO"
# Giữ 3 bản mới nhất (theo số bản trong tên tệp)
ls debs/*.deb | sort -V | head -n -3 | xargs -r rm -f
dpkg-scanpackages -m debs /dev/null 2>/dev/null |
    awk -v dep="Depiction: $SITE/cydia/depiction.html" -v home="Homepage: $SITE/" '
        /^Depiction: / { hasdep = 1 } /^Homepage: / { hashome = 1 }
        /^$/ { if (!hasdep) print dep; if (!hashome) print home; hasdep = hashome = 0; print; next }
        { print }' > Packages
gzip -9nc Packages > Packages.gz
bzip2 -9c Packages > Packages.bz2
{
    cat <<'EOF'
Origin: Roza
Label: Roza
Suite: stable
Version: 1.0
Codename: ios6
Architectures: iphoneos-arm
Components: main
Description: Roza — Zalo cho iPhone / iPad iOS 5 / iOS 6 đã jailbreak — https://itovn.github.io/Roza/
EOF
    echo "MD5Sum:"
    for f in Packages Packages.gz Packages.bz2; do echo " $(md5sum "$f" | cut -d' ' -f1) $(stat -c %s "$f") $f"; done
    echo "SHA256:"
    for f in Packages Packages.gz Packages.bz2; do echo " $(sha256sum "$f" | cut -d' ' -f1) $(stat -c %s "$f") $f"; done
} > Release
echo "Nguồn Cydia: $(grep -c '^Package:' Packages) gói"
grep -E '^(Package|Version|Filename|Size|Depiction):' Packages
