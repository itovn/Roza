# Roza — Phương án thiết kế (17/11/2026, cập nhật theo bản 1.2.0)

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
7. **iPad: màn chia đôi** (`UISplitViewController` làm gốc cửa sổ — iOS 5 / 6 bắt buộc): cột trái là bộ thẻ như iPhone, cột phải
   là chat (D20).
8. **Dịch vụ Apple đã tắt trên iOS 5 / 6 thì tự làm qua lõi**: bản đồ = ô OpenStreetMap + địa chỉ tra bằng Nominatim, tải bằng TLS
   của lõi (D21).

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
- **API thêm cho bản 1.2.0** (dò bằng `rz-cli`, chỉ HTTP): tên gợi nhớ (dịch vụ `alias`: `/api/alias/list|update|remove`), nhắc hẹn
  (`group_board`: `/api/board/oneone/*` cho chat riêng, `/api/board/topic/createv2|updatev2|remove` + `listReminder` cho nhóm),
  tin nhắn nhanh (`quick_message`), ngân hàng (`zimsg`: `/api/transfer/conf` danh sách ngân hàng, `list|create|delete` tài khoản đã
  lưu, `card` gửi thẻ), mã QR cá nhân cho danh thiếp (`friend`: `/api/friend/mget-qr`). Dạng các tin mới: DECISIONS D21.

---

## 2. Kiến trúc

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ App Objective-C / UIKit (Theos, armv7, dựng cho iOS 5.0)                │
│  Đăng nhập QR · 4 thẻ (Tin nhắn · Danh bạ · Nhóm · Thêm) · Chat · Ảnh   │
│  Bản đồ · Ngân hàng / VietQR · Nhắc hẹn · Tin nhắn nhanh · Sao lưu      │
│  iPad: màn chia đôi (UISplitViewController, D20)                        │
│  RZBackground: socket VoIP → thông báo; nhắc hẹn (UILocalNotification)  │
└──────────┬────────────────────────────────────────────────────▲─────────┘
   rz_call (JSON, chạy nền)                                     │ sự kiện JSON
┌──────────▼────────────────────────────────────────────────────┴─────────┐
│ librz_ffi.a (Rust, armv7 Cortex-A8, build-std, panic=abort)             │
│  rz-ffi → rz-core: phiên, vòng kết nối (tự nối lại, đổi máy chủ),       │
│           Store (SQLite), Media (tải + đệm, WebP → PNG), lệnh,          │
│           đồng bộ, gửi tệp, sao lưu Telegram, VietQR, ô bản đồ          │
│         → rz-zalo: crypto · cookies · http (reqwest/rustls) ·           │
│           login (QR, cookie) · api · listen (WebSocket) · text          │
└──────────┬──────────────────────────────────────────────────────────────┘
           │ HTTPS + WSS (TLS của lõi)
           ▼
   id.zalo.me · wpa.chat.zalo.me · *.chat.zalo.me · CDN ảnh / tệp
   api.telegram.org (sao lưu) · tile / nominatim.openstreetmap.org (bản đồ)
```

Tweak `tweak/RZNotify` (cùng gói): thêm Roza vào Cài đặt → Thông báo (như GramMini D18).

| Crate | Việc |
| --- | --- |
| `rz-zalo` | Giao thức (chuyển từ zca-js): `crypto`, `cookies` (hộp cookie tự quản, lưu JSON), `http` (tự theo chuyển hướng giữ cookie), `login`, `api`, `listen`; `text` (bỏ dấu tiếng Việt, vd. tên chủ tài khoản) |
| `rz-core` | `Core`: phiên, vòng kết nối + đồng bộ, xử lý sự kiện → kho, lệnh cho app; `store` (SQLite: msgs, threads, users + tên gợi nhớ, groups, kv); `msg` (tin Zalo → DTO sẵn hiển thị); `media`; `upload` (gửi ảnh / video / tệp / thoại); `sync` (lấy lại tin bị lỡ, tải lịch sử nhóm); `backup` (sao lưu / khôi phục qua bot Telegram, lưu một tin vào Telegram); `extras` (danh thiếp, ngân hàng, nhắc hẹn, tin nhắn nhanh, ô bản đồ + địa chỉ); `vietqr` (dựng mã VietQR, đọc thẻ tài khoản) |
| `rz-ffi` | `rz_init` / `rz_call` (staticlib) |
| `rz-cli` | Chạy thử trên PC: `qr`, `me`, `friends`, `groups`, `listen`, `send`; thử API chỉ bằng HTTP (không mở WebSocket nên không đá kết nối của máy đang dùng phiên): `cloud`, `banks`, `bankcard`, `card`, `reminders`, `remind`, `unremind`, `quick`, `aliases`, `userinfo` |

Dữ liệu: `~/Library/Roza` (`session.json`, `roza.db`, `core.log`, `app.log`); bộ đệm `~/Library/Caches/Roza` (ảnh đại diện, ảnh,
sticker, ô bản đồ `osm/`).

---

## 3. App iOS

| Màn | Có gì |
| --- | --- |
| Đăng nhập | mã QR (lõi lưu PNG), các bước «quét bằng Zalo trên điện thoại», trạng thái đã quét / hết hạn / từ chối, «Lấy mã mới»; iPad: khối giữa màn, mã QR 300 điểm, xoay mọi chiều |
| Tin nhắn | ô vẽ gọn bằng `drawRect:` (ảnh đại diện tròn, tên, xem trước «Bạn: …» / «Tên: …», giờ, huy hiệu đỏ, tắt tiếng, ghim), tìm theo tên (bỏ dấu), vuốt để ẩn, trò chuyện ẩn (PIN), trạng thái kết nối trên thanh trên |
| Chat | bong bóng gom cụm (5 phút, cùng người), dải ngày, tên + ảnh người gửi (nhóm), trích dẫn, ảnh / sticker (cả sticker động) / video / tệp / thoại, «Đã xem», cảm xúc, ô nhập tự giãn; giữ tin → Trả lời / Thả cảm xúc / Sao chép / Thu hồi / Xoá ở phía tôi / Lưu vào Telegram (thẻ ngân hàng thêm «Chép số tài khoản»), tin lỗi → Gửi lại; nút đính kèm → Chụp ảnh, Ảnh trong máy, Tệp trong máy, Vị trí, Danh thiếp, Tài khoản ngân hàng, Mã QR chuyển khoản, Nhắc hẹn, Tin nhắn nhanh; gõ «/» → gợi ý tin nhắn nhanh; chạm tiêu đề → Đặt tên gợi nhớ, Nhắc hẹn; dòng dưới tiêu đề: số thành viên (nhóm) / lần truy cập cuối |
| Danh bạ | bạn bè theo chữ cái (A–Z, #), chỉ mục bên phải, tìm SĐT, chạm giữ → đặt tên gợi nhớ; cũng là màn chọn người khi gửi danh thiếp |
| Nhóm | các nhóm, số thành viên, nhóm có tin mới lên trước |
| Thêm | tài khoản, kết nối (kết nối lại), Đồng bộ tin nhắn, Sao lưu (Telegram), Thông báo, Chế độ tối, Trò chuyện ẩn, Tin nhắn nhanh, bộ nhớ đệm (xoá), giới thiệu («không chính thức»), đăng xuất |
| Bản đồ (`RZLocation.m`) | ghép ô OpenStreetMap (kéo, nút + / −, mức 3–18), ghim, «© OpenStreetMap»; chọn vị trí để gửi (vị trí hiện tại qua CLLocationManager, địa chỉ tra Nominatim); xem vị trí từ đường dẫn bản đồ trong chat |
| Ngân hàng (`RZBank.m`) | chọn ngân hàng (danh sách của Zalo), tài khoản đã lưu trong Zalo, gửi thẻ tài khoản, thẻ mã QR chuyển khoản (số tiền, nội dung) tự vẽ rồi gửi như ảnh |
| Nhắc hẹn (`RZReminders.m`) | danh sách theo chat, tạo / sửa / xoá, lặp ngày / tuần / tháng, thông báo trên máy đúng giờ |
| Tin nhắn nhanh (`RZQuickMessages.m`) | danh sách, thêm / sửa / xoá (đồng bộ với Zalo trên điện thoại) |
| iPad | `UISplitViewController`: cột trái là bộ thẻ (rộng 320), cột phải là chat hoặc màn trống «Chọn một cuộc trò chuyện»; mọi chỗ mở chat đi qua `RZOpenChat` |

Tương thích iOS 5 (từ GramMini): `RZCompat` (subscripting, `NSIndexPath.item`, xoay màn iOS 5, giữ view khi thiếu bộ nhớ),
`RZShims.c` (`clock_gettime`, `__exp10`, `__sincos*_stret`, `CCRandomGenerateBytes`, `dirfd`…), `-Werror=unguarded-availability`,
hằng căn lề bằng số (`RZAlignCenter`…).

---

## 4. Các bản đã phát hành, việc còn lại

- **1.0.0**: đăng nhập QR; chat chữ, trả lời, thu hồi, xoá ở phía mình, cảm xúc, «Đã xem»; sticker (cả sticker động); gửi ảnh /
  video / tệp / tin thoại; lưu về máy; thông báo nền (VoIP + tweak RZNotify — GramMini D17 / D18); chế độ tối; sao lưu Telegram;
  đồng bộ với Zalo trên điện thoại / PC; trò chuyện ẩn; nguồn Cydia + trang giới thiệu (D19).
- **1.1.0**: giao diện iPad chia đôi (D20).
- **1.2.0**: nhắc hẹn, vị trí (bản đồ OSM), tin nhắn nhanh, danh thiếp, tài khoản ngân hàng + mã QR chuyển khoản (VietQR), lưu tin
  vào Telegram, tên gợi nhớ; người chưa kết bạn hiện đúng tên; sửa app mở ở nền bị treo lúc đang kết nối (D21).
- **1.2.1**: chữ thông báo không còn bị cắt giữa emoji — trước đây có thể làm SpringBoard iOS 6 sập, máy vào safe mode (D23).
- **Chưa làm**: màn thông tin nhóm (danh sách thành viên), tắt thông báo / ghim chat từ app (lõi đã có `threads.mute`), tìm tin
  trong chat, tạo nhóm, lời mời kết bạn, khoá app; sao lưu Google Drive; lịch sử một số nhóm máy chủ không cho Zalo Web xem
  (`isFiltered`).

## 5. Rủi ro

| Rủi ro | Giảm thế nào |
| --- | --- |
| Zalo đổi giao thức Web (zca-js sửa thường xuyên) | `rz-zalo` tách riêng, giữ tên hàm theo zca-js để dò theo commit của zca-js; tự đọc `apiVersion` từ chat.zalo.me (3 ngày một lần) |
| Tài khoản bị hạn chế vì client không chính thức | Dùng tài khoản phụ khi thử; không gửi dồn; user agent trình duyệt máy tính như zca-js |
| Chỉ một Zalo Web cùng lúc | Báo rõ + «Dùng ở đây»; không tự giành lại |
| Lịch sử chat riêng chỉ có từ lúc đăng nhập | Ghi rõ trong Giới thiệu; lõi giữ mọi tin nhận được |
| API iOS 7+ lọt vào bản dựng (vd. `openat` từ `remove_dir_all`) | `symcheck` trên máy iOS 5 và 6 sau mỗi lần dựng (DECISIONS D5) |
| Chính sách dùng ô bản đồ / Nominatim của OpenStreetMap | User-Agent riêng nêu tên app, ô đã tải giữ trên máy, chỉ tải ô đang xem; tra địa chỉ khi bản đồ đứng yên 0,8 s; ghi «© OpenStreetMap» |
| Cydia trên iOS 5 / 6 hiện chữ có dấu trong mô tả gói thành «?» | `Description` viết không dấu; `tools/update-cydia-repo.sh` dừng nếu `Packages` còn ký tự ngoài ASCII (DECISIONS D22) |
