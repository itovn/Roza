# Roza — Nhật ký tiến độ

## 17/11/2026 — Khởi tạo, bản 0.1.0 dựng được

**Lõi Rust**

- `rz-zalo` (chuyển từ zca-js 2.3.0, commit `1e1c503`): mã hoá (khớp từng byte với bản JS — `tools/zca-vectors.mjs`), cookie,
  HTTP, đăng nhập QR + cookie, đọc apiVersion từ chat.zalo.me, ~25 lệnh API, WebSocket. 10 phép thử.
- `rz-core`: phiên, vòng kết nối tự nối lại, đồng bộ tin cũ, kho SQLite, tin tạm → thật, thu hồi, cảm xúc, đã xem, tải ảnh qua
  lõi. 3 phép thử.
- `rz-ffi`, `rz-cli`.
- Trên PC: đăng nhập QR chạy tới bước có mã QR thật từ id.zalo.me (bước quét / xác nhận cần điện thoại).
- armv7 iOS 6: `librz_ffi.a` 7,5 MB (kèm SQLite).

**App** (Theos, 0 lỗi với `-Werror=unguarded-availability`): đăng nhập QR, 4 thẻ, danh sách chat, màn chat, danh bạ, nhóm, thêm,
xem ảnh; biểu tượng + ảnh khởi động tự vẽ. `.deb` 3,2 MB. `cbsymcheck`: iPhone 5 iOS 6.1.4 và iPad 1 iOS 5.1.1 — 323 / 323, thiếu 0
(sau khi bỏ `remove_dir_all` — D5).

**Chưa thử trên máy thật / tài khoản thật**: đăng nhập trọn vẹn (cần anh quét QR), WebSocket, gửi / nhận tin, giao diện.

## Việc tiếp theo

1. Cài lên iPhone 5 (`bash tools-local/deploy.sh iphone`), anh quét QR bằng tài khoản phụ → thử nhận / gửi / đồng bộ, ghi thời gian
   đăng nhập + RAM trên iPad 1.
2. Hoặc thử trước trên PC: `cargo run -p rz-cli -- qr` → `listen 60` (dùng phiên riêng cho PC — D7).
3. Gửi ảnh, bảng sticker, nghe tin thoại, mở tệp (0.2).
4. Thông báo nền đầy đủ: VoIP socket + tweak mục «Thông báo» (lấy từ GramMini D17 / D18, thêm `vn.roza.app`).

## 17/11/2026 (chiều) — Thử trên iPhone 5, sticker, chế độ tối, gửi đa phương tiện

- Đăng nhập QR trên iPhone 5 (anh quét): đăng nhập lại 0,3–3,7 s, WebSocket online, 5 bạn / 4 nhóm; anh nhắn tin được.
- Bảng sticker + sticker động (D9), chế độ tối (D10), gửi ảnh / tệp / video / tin thoại + nghe thoại, xem video / tệp (D11).
- Bản debug có lệnh thử qua SSH (`app/Debug/RZDebug.h`).

Còn mở (chờ anh chọn): sao lưu dữ liệu (Google Drive / Telegram); đồng bộ tin nhắn với phiên PC / điện thoại.

## 17/11/2026 (tối) — Anh thử trên iPhone 5: thông báo, lưu về máy

- Khôi phục thật: 24 tin → 24 tin, đủ chat / bạn / nhóm / sổ tệp (D12, D17).
- Thông báo tin mới (VoIP + tweak RZNotify, sau respring): anh xác nhận có thông báo.
- Lưu ảnh / video / tệp từ chat về máy: anh xác nhận chạy.
- Biểu tượng chính thức: kính mờ hồng (D14).

Còn mở: «Tải lịch sử tất cả nhóm» trả 0 tin cho 4 nhóm (xem lại getCloudMessage); bản phát hành (FINALPACKAGE) + nguồn Cydia;
thử trên iPad mini 1 / iPad 1; commit git.

## 17/11/2026 (đêm) — Trò chuyện ẩn, thử iPad, bản 1.0.0, GitHub + Cydia

- Trò chuyện ẩn kiểu Zalo, PIN đồng bộ với điện thoại (D18).
- iPad mini 1 / iPad 1: chạy, giao diện iPhone phóng to (D19).
- Bản phát hành 1.0.0, nguồn Cydia <https://itovn.github.io/Roza/cydia/>, mã nguồn <https://github.com/itovn/Roza> (D19).

Còn mở: bố cục riêng cho iPad (UISplitViewController); lịch sử nhóm bị `isFiltered`; Google Drive (sao lưu).

## 17/11/2026 (khuya) — Giao diện iPad

- Màn chia đôi trên iPad: danh sách bên trái, chat bên phải, cả dọc và ngang; đăng nhập căn giữa (D20). Phát hành bản 1.1.0.

## 17/11/2026 (khuya, tiếp) — Bảy tính năng mới, tên gợi nhớ, sửa tên người lạ

- Nhắc hẹn, vị trí (bản đồ OSM), tin nhắn nhanh (gõ «/»), mã QR chuyển khoản (VietQR), gửi tài khoản ngân hàng, danh thiếp, lưu vào
  Telegram; tên gợi nhớ; người chưa kết bạn hiện đúng tên; sửa app mở ở nền bị treo khi đang kết nối (D21).
- Phát hành bản 1.2.0: GitHub Release + nguồn Cydia (giữ 1.0.0 / 1.1.0 / 1.2.0), trang giới thiệu có mục «Nhắc hẹn, vị trí,
  chuyển khoản…». `cbsymcheck` bản phát hành 428 / 428 trên iPhone 5, iPad mini 1, iPad 1; cài và mở được trên hai iPad.

## 17/11/2026 (khuya, sau 1.2.0) — Mô tả gói không dấu, cập nhật tài liệu

- Cydia trên iOS 5 / 6 hiện chữ có dấu trong mô tả gói thành «?» → `app/control` viết không dấu; tệp `Packages` của nguồn Cydia
  sửa cho cả ba bản (gh-pages `8296699`). `tools/update-cydia-repo.sh` lấy mô tả từ `app/control` cho mọi bản và dừng nếu
  `Packages` còn ký tự ngoài ASCII — chạy thử trên máy dựng: dựng lại ra đúng `Packages` đang chạy (cùng MD5) (D22).
- Tài liệu theo bản 1.2.0: THIET-KE (kiến trúc, màn hình, các bản đã phát hành), FFI (`net.check`, sự kiện `net.socket` /
  `sync.*` / `backup.progress`, loại tin `bank` / `reminder`), README.

Còn mở:

- Chưa thử trên máy: đặt tên gợi nhớ thật (sẽ đổi dữ liệu tài khoản của anh), gửi vị trí trọn một vòng, bố cục các màn mới trên
  iPhone (320 điểm).
- Lịch sử một số nhóm bị máy chủ lọc (`isFiltered`); sao lưu Google Drive.
- Chưa làm: thông tin nhóm (thành viên), tắt thông báo / ghim từ app, tìm tin trong chat, tạo nhóm, lời mời kết bạn, khoá app.

## 21/11/2026 — Bản 1.2.1: thông báo không làm SpringBoard sập

- iPhone 5 vào safe mode vì một thông báo có nửa emoji (do GramMini cắt xem trước 180 đơn vị UTF-16). Roza có cùng dòng cắt chữ →
  sửa bằng `RZCut()` / `RZValidUTF16()` cho thông báo tin mới, nhắc hẹn, nhãn tin nhắn nhanh (D23). Phát hành 1.2.1.
- Phát hành 1.2.1: GitHub Release + nguồn Cydia (giữ 1.1.0 / 1.2.0 / 1.2.1), trang mô tả + trang giới thiệu. `cbsymcheck` bản
  phát hành 428 / 428 trên iPhone 5 (iOS 6.1.4) và iPad 1 (iOS 5.1.1); cài lên iPad 1 — mở được. Tải lại: GitHub = Cydia (cùng
  SHA-256 `84cd40e6857f9e537226deb4308302c26dd93393d4019ad688ed7e30f688177c`).
