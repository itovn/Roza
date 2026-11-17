# Roza

App nhắn tin Zalo **không chính thức** cho **iPhone / iPad chạy iOS 5 và iOS 6 đã jailbreak**: bố cục theo Zalo 4.8 (thời iOS 6),
lõi **Rust** nói chuyện thẳng với máy chủ Zalo bằng giao thức Zalo Web (chuyển từ thư viện
[zca-js](https://github.com/RFS-ADRENO/zca-js), MIT), vỏ **Objective-C / UIKit** dựng bằng Theos. Không cần server riêng — phiên
đăng nhập và tin nhắn chỉ nằm trên máy. Một gói `.deb` chạy cả iOS 5 và 6.

> Roza dùng giao thức của Zalo Web nhưng **không phải** sản phẩm của Zalo / VNG. Tên, biểu tượng, ảnh giao diện đều tự vẽ.

## Máy chạy được

iOS 5.0 – 6.1.x, đã jailbreak: iPhone 4 / 4S / 5, iPad 1 – 4 / mini 1, iPod touch 4 / 5. Đã chạy thử trên iPhone 5 (iOS 6.1.4),
iPad mini 1 (iOS 6.1.3) và iPad 1 (iOS 5.1.1); kiểm ký hiệu bản 1.2.0: 428 / 428, thiếu 0. Trên iPad: màn chia đôi — danh
sách bên trái, cuộc trò chuyện bên phải (từ bản 1.1.0).

## Cài đặt

Cydia → Nguồn → Sửa → Thêm: **`https://itovn.github.io/Roza/cydia/`** → cài **Roza** (cần MobileSubstrate; lần đầu respring để có
mục Thông báo). Hướng dẫn chi tiết: **[itovn.github.io/Roza](https://itovn.github.io/Roza/)**. Tệp `.deb`: [Releases](https://github.com/itovn/Roza/releases).
Đã cài rồi thì lên bản mới bằng Cydia → Thay đổi → Làm mới.

## Có gì (bản 1.2.0)

- Đăng nhập bằng **mã QR** (quét bằng app Zalo trên điện thoại khác, như Zalo Web).
- Thẻ **Tin nhắn / Danh bạ / Nhóm / Thêm**; ô tìm kiếm trên thanh trên; danh sách chat có ghim, tắt thông báo, số chưa đọc,
  «đang soạn tin…».
- Chat riêng và nhóm: tin chữ, trả lời (trích dẫn), thu hồi, xoá ở phía mình, thả cảm xúc, «Đã xem», tải lịch sử nhóm khi cuộn lên.
- **Sticker** (cả sticker động), tìm sticker; **gửi ảnh, video, tệp, tin nhắn thoại** (ghi âm); xem ảnh, phát video / thoại.
- **Lưu về máy** ảnh / video (vào Ảnh), tệp (Tài liệu/Roza), «Mở bằng app khác…».
- **Thông báo tin mới** khi app ở nền (socket VoIP như GramMini + tweak RZNotify để có mục trong Cài đặt → Thông báo).
- **Chế độ tối**.
- **Sao lưu lên Telegram** (bot riêng của bạn, không kèm phiên đăng nhập), kể cả ảnh / video / tệp; khôi phục trên máy mới.
- **Đồng bộ** với Zalo trên điện thoại / PC: lấy lại tin bị lỡ, tải lịch sử nhóm.
- **Trò chuyện ẩn** (PIN 4 số, đồng bộ với Zalo trên điện thoại).
- **Nhắc hẹn** trong chat (đồng bộ với Zalo, thông báo đúng giờ), **tin nhắn nhanh** (gõ «/»), **danh thiếp**, **vị trí** (bản đồ
  OpenStreetMap), **tài khoản ngân hàng** + **mã QR chuyển khoản** (VietQR — app ngân hàng nào cũng quét được).
- **Lưu vào Telegram**: chạm giữ một tin → gửi vào chat với bot của bạn (tệp gốc).
- **Tên gợi nhớ** cho bất kỳ ai (cả người chưa kết bạn), đồng bộ với điện thoại.
- Tự nối lại khi rớt mạng; báo khi Zalo Web đang mở ở nơi khác (nút «Dùng ở đây»).

## Dựng từ mã nguồn

Máy Ubuntu có [Theos](https://theos.dev) (SDK iPhoneOS 9.3) và Rust nightly (`rust-src`) — cùng bộ dựng với GramMini:

```sh
bash tools/build-app.sh                 # bản thử → app/packages/*.deb
bash tools/build-app.sh FINALPACKAGE=1  # bản phát hành
```

Lõi dựng cho armv7 Cortex-A8 bằng target tự định nghĩa (`tools/rust/armv7-apple-ios6.json`, `-Z build-std`); `ring` (TLS của
rustls) được vá cho ARM 32-bit của Apple (`tools/rust/vendor-ring.sh`). Chạy thử lõi trên PC:

```sh
cd core
cargo test
cargo run -p rz-cli -- qr            # đăng nhập bằng QR, lưu phiên vào keys/rz-session.json
cargo run -p rz-cli -- me | friends | groups | listen 30
cargo run -p rz-cli -- quick | aliases | banks   # thử API chỉ bằng HTTP; chạy không tham số để xem mọi lệnh
```

## Tài liệu

| Tệp | Nội dung |
| --- | --- |
| [docs/THIET-KE.md](docs/THIET-KE.md) | Thiết kế: kiến trúc, giao thức Zalo Web, lõi Rust, app iOS |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Các quyết định kỹ thuật và kết quả kiểm chứng |
| [docs/FFI.md](docs/FFI.md) | Hợp đồng lệnh / sự kiện giữa app và lõi |
| [docs/PROGRESS.md](docs/PROGRESS.md) | Nhật ký tiến độ, việc tiếp theo |

## Giấy phép

[GPL-3.0](LICENSE) (dùng lại bộ dựng / lớp tương thích iOS 5–6 của GramMini). `core/crates/rz-zalo` chuyển từ zca-js — giữ thông
báo giấy phép MIT của zca-js ở `core/crates/rz-zalo/LICENSE-zca-js`.
