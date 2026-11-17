# Roza — Phương án thiết kế (17/11/2026)

App nhắn tin Zalo (client không chính thức) cho **iOS 5 / iOS 6 đã jailbreak**, lõi **Rust**, vỏ **Objective-C / UIKit**. Cùng
khuôn với GramMini (Telegram): một gói `.deb`, lõi tĩnh `librz_ffi.a`, cầu JSON.

| Nguồn | Lấy gì |
| --- | --- |
| `E:\DEV_CODE\GramMini` | Bộ dựng Rust cho armv7 iOS 5 / 6 (target JSON, build-std, ring vá, mio đánh thức bằng pipe), cầu FFI JSON, shim C / lớp tương thích iOS 5, công cụ máy dựng / máy thử (sync, deploy, symcheck), bài học D1–D27 |
| [zca-js](https://github.com/RFS-ADRENO/zca-js) (MIT) | Giao thức Zalo Web: mã hoá tham số, đăng nhập QR / cookie, bản đồ dịch vụ, các API HTTP, WebSocket nhận tin — **chuyển sang Rust** (`core/crates/rz-zalo`) |
| IPA Zalo 4.8.2 (`Tham_Khao/`, không lên git) | Chỉ tham khảo bố cục: 5 thẻ (Tin nhắn · Danh bạ · Nhóm trò chuyện · Nhật ký · Thêm), thanh trên xanh `#2190bf`, danh sách / bong bóng. **Không chép ảnh, logo, mã** |

---

## 0. Tóm tắt quyết định

1. **Client dày, không server**: lõi Rust trên máy nói chuyện thẳng với máy chủ Zalo (giao thức Zalo Web). Phiên = cookie + imei +
   user agent, chỉ nằm trên máy (`session.json`, 0600).
2. **zca-js chuyển sang Rust, không chạy JS**: iOS 5 / 6 không có Node, JavaScriptCore chỉ công khai từ iOS 7; nhúng QuickJS thì
   vẫn phải tự làm mạng / mã hoá / WebSocket. Lõi Rust dùng lại bộ dựng đã chạy của GramMini.
3. **TLS trong lõi** (rustls + ring đã vá + chứng chỉ gốc Mozilla): TLS / chứng chỉ gốc của iOS 6 không vào được máy chủ Zalo hiện
   nay. Cả HTTP (reqwest) lẫn WebSocket (tokio-tungstenite trên tokio-rustls) và tải ảnh CDN đều đi qua lõi.
4. **Lưu tin trên máy (SQLite bundled)**: Zalo Web không cho tải lại lịch sử chat riêng từ máy chủ; chỉ đồng bộ cửa sổ tin gần đây
   lúc mở WebSocket (cmd 510 / 511) và lịch sử nhóm («cloud message»). Tin nào nhận được là lõi giữ.
5. **Giao diện theo bố cục Zalo 4.8, ảnh tự vẽ** (CoreGraphics lúc chạy), tên / biểu tượng Roza (nền hồng, bong bóng + hoa hồng) —
   không dùng nhận diện của Zalo.
6. **Bundle id `vn.roza.app`**, gói `.deb` tên Roza (anh chốt tên app và tên gói là Roza).

---

## 1. Giao thức Zalo Web (tóm tắt từ zca-js)

```text
Đăng nhập QR (id.zalo.me)                     Đăng nhập lại mỗi lần mở (wpa.chat.zalo.me)
 GET  /account?continue=…  → bản trang login    getLoginInfo?zcid&zcid_ext&enc_ver=v2&params=<AES>&type&client_version&signkey
 POST /account/logininfo, /verify-client           → data (AES, khoá suy từ zcid) → zpw_enk (khoá phiên), uid,
 POST /authen/qr/generate  → ảnh QR + code            zpw_service_map_v3 (dịch vụ → máy chủ), zpw_ws (WebSocket)
 POST /authen/qr/waiting-scan   (hỏi dài, mã 8)   getServerInfo?imei&type&client_version&computer_name&signkey
 POST /authen/qr/waiting-confirm (−13 = từ chối)     → settings (ping_interval, retries, …), extra_ver
 GET  /account/checksession → cookie chat.zalo.me
```

- **Mã hoá tham số API**: JSON → AES-CBC (IV 0, PKCS#7, khoá = base64 `zpw_enk`) → `params=`; kết quả `{error_code, data}` với
  `data` mã hoá cùng cách. Lúc đăng nhập: `zcid` = AES-256(khoá cố định, "type,imei,ts") hex hoa; khoá = ghép ký tự chẵn / lẻ của
  MD5(zcid_ext) và zcid. `signkey` = MD5("zsecure" + loại + giá trị tham số xếp theo tên). Đã đối chiếu từng byte với bản JS
  (`tools/zca-vectors.mjs`).
- **WebSocket** (`wss://ws*-msg.chat.zalo.me`): khung `[ver][cmd u16 LE][sub]` + JSON. (1,1,1) trả `key` (AES-GCM cho dữ liệu
  sự kiện) → ping (1,2,1) theo `ping_interval`. Sự kiện: 501 / 551 tin riêng, 521 tin nhóm, 510 / 511 tin cũ (trả lời yêu cầu đồng
  bộ), 601 điều khiển (nhóm, bạn bè, tải tệp xong), 602 đang soạn, 502 / 522 đã nhận / đã xem, 610–612 cảm xúc, 3000 = có kết nối
  khác. Dữ liệu sự kiện: `encrypt` 0 JSON, 1 base64+zlib, 2 AES-GCM+zlib, 3 AES-GCM.
- **Một phiên web**: mở chat.zalo.me ở nơi khác → máy chủ gửi 3000 rồi đóng kết nối của Roza. Roza không tự giành lại (tránh hai
  bên đá nhau) — hiện dải «Dùng ở đây».

---

## 2. Kiến trúc

```text
┌───────────────────────────────────────────────────────────────┐
│ App Objective-C / UIKit (Theos, armv7, dựng cho iOS 5.0)         │
│  Đăng nhập QR · Tin nhắn · Danh bạ · Nhóm · Thêm · Màn chat · Ảnh │
└──────────┬───────────────────────────────────────▲─────────────┘
   rz_call (JSON, chạy nền)                         │ sự kiện JSON
┌──────────▼───────────────────────────────────────┴─────────────┐
│ librz_ffi.a (Rust, armv7 Cortex-A8, build-std, panic=abort)       │
│  rz-ffi → rz-core: phiên, vòng kết nối (tự nối lại, đổi máy chủ), │
│           Store (SQLite), Media (tải + đệm, WebP → PNG), lệnh      │
│         → rz-zalo: crypto · cookies · http (reqwest/rustls) ·     │
│           login (QR, cookie) · api · listen (WebSocket)           │
└──────────┬────────────────────────────────────────────────────┘
           │ HTTPS + WSS (TLS của lõi)
           ▼
   id.zalo.me · wpa.chat.zalo.me · *.chat.zalo.me · CDN ảnh
```

| Crate | Việc |
| --- | --- |
| `rz-zalo` | Giao thức (chuyển từ zca-js): `crypto`, `cookies` (hộp cookie tự quản, lưu JSON), `http` (tự theo chuyển hướng giữ cookie), `login`, `api`, `listen` |
| `rz-core` | `Core`: phiên, vòng kết nối + đồng bộ, xử lý sự kiện → kho, lệnh cho app; `store` (SQLite: msgs, threads, users, groups, kv); `msg` (tin Zalo → DTO sẵn hiển thị); `media` |
| `rz-ffi` | `rz_init` / `rz_call` (staticlib) |
| `rz-cli` | Chạy thử trên PC: `qr`, `me`, `friends`, `groups`, `listen`, `send` |

Dữ liệu: `~/Library/Roza` (`session.json`, `roza.db`, `core.log`, `app.log`); bộ đệm `~/Library/Caches/Roza` (ảnh đại diện, ảnh,
sticker).

---

## 3. App iOS

| Màn | Có gì |
| --- | --- |
| Đăng nhập | mã QR (lõi lưu PNG), các bước «quét bằng Zalo trên điện thoại», trạng thái đã quét / hết hạn / từ chối, «Lấy mã mới» |
| Tin nhắn | ô vẽ gọn bằng `drawRect:` (ảnh đại diện tròn, tên, xem trước «Bạn: …» / «Tên: …», giờ, huy hiệu đỏ, tắt tiếng, ghim), tìm theo tên (bỏ dấu), vuốt để ẩn, trạng thái kết nối trên thanh trên |
| Chat | bong bóng gom cụm (5 phút, cùng người), dải ngày, tên + ảnh người gửi (nhóm), trích dẫn, ảnh / sticker, «Đã xem», cảm xúc, ô nhập tự giãn, giữ → Trả lời / Thả cảm xúc / Sao chép / Thu hồi / Xoá ở phía tôi, tin lỗi → Gửi lại |
| Danh bạ | bạn bè theo chữ cái (A–Z, #), chỉ mục bên phải, tìm SĐT |
| Nhóm | các nhóm, số thành viên, nhóm có tin mới lên trước |
| Thêm | tài khoản, kết nối (kết nối lại), bộ nhớ đệm (xoá), giới thiệu («không chính thức»), đăng xuất |

Tương thích iOS 5 (từ GramMini): `RZCompat` (subscripting, `NSIndexPath.item`, xoay màn iOS 5, giữ view khi thiếu bộ nhớ),
`RZShims.c` (`clock_gettime`, `__exp10`, `__sincos*_stret`, `CCRandomGenerateBytes`, `dirfd`…), `-Werror=unguarded-availability`,
hằng căn lề bằng số (`RZAlignCenter`…).

---

## 4. Lộ trình

- **0.1 (đã dựng)**: đăng nhập QR, danh sách chat / danh bạ / nhóm, chat chữ + trả lời + thu hồi + cảm xúc + đã xem, xem ảnh /
  sticker, thông báo nền mức 1.
- **0.2**: gửi ảnh (upload `photo_original/send`), gửi sticker (bảng sticker), nghe tin thoại (AAC / AMR → lõi giải), mở tệp
  (QuickLook), danh thiếp, vị trí.
- **0.3**: thông tin chat / nhóm (thành viên, tắt thông báo, ghim), tìm tin trong chat, tạo nhóm, lời mời kết bạn.
- **1.0**: thông báo nền như GramMini (chế độ VoIP + tweak cho mục «Thông báo» — GramMini D17 / D18), khoá app, giao diện tối,
  OTA + nguồn Cydia.

## 5. Rủi ro

| Rủi ro | Giảm thế nào |
| --- | --- |
| Zalo đổi giao thức Web (zca-js sửa thường xuyên) | `rz-zalo` tách riêng, giữ tên hàm theo zca-js để dò theo commit của zca-js; tự đọc `apiVersion` từ chat.zalo.me (3 ngày một lần) |
| Tài khoản bị hạn chế vì client không chính thức | Dùng tài khoản phụ khi thử; không gửi dồn; user agent trình duyệt máy tính như zca-js |
| Chỉ một Zalo Web cùng lúc | Báo rõ + «Dùng ở đây»; không tự giành lại |
| Lịch sử chat riêng chỉ có từ lúc đăng nhập | Ghi rõ trong Giới thiệu; lõi giữ mọi tin nhận được |
| API iOS 7+ lọt vào bản dựng (vd. `openat` từ `remove_dir_all`) | `symcheck` trên máy iOS 5 và 6 sau mỗi lần dựng (DECISIONS D5) |
