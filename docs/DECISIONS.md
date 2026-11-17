# Roza — Các quyết định kỹ thuật

Thiết kế đầy đủ: [THIET-KE.md](THIET-KE.md).

## D1. Client dày: lõi Rust nói giao thức Zalo Web ngay trên máy — 17/11/2026

- Không server; phiên (cookie + imei + user agent) và tin nhắn chỉ nằm trên máy.
- Giao thức lấy từ zca-js (MIT) và **chuyển sang Rust** (`core/crates/rz-zalo`), không chạy JS: iOS 5 / 6 không có Node, không có
  JavaScriptCore công khai (iOS 7+). Giữ tên hàm / đường dẫn API như zca-js để dò theo khi zca-js sửa.
- Giấy phép MIT của zca-js giữ ở `core/crates/rz-zalo/LICENSE-zca-js`.

## D2. Tên app / gói / bundle id: Roza — 17/11/2026

- Anh chốt: tên app và tên gói là **Roza**. Bundle id `vn.roza.app` (theo kiểu `vn.grammini.app`).
- Biểu tượng tự vẽ (`tools/icon/make_icons.py`): nền hồng đỏ, bong bóng chat trắng có bông hồng cách điệu — khác hẳn nhận diện
  Zalo (bong bóng xanh chữ «Zalo»), tránh người dùng tưởng là app chính thức.

## D3. Giao diện theo bố cục Zalo 4.8, ảnh tự vẽ — 17/11/2026

- IPA Zalo 4.8.2 (`Tham_Khao/ipa`, không lên git — có `iTunesMetadata.plist` của người mua, tệp chạy có bản quyền) chỉ dùng để
  xem bố cục: 5 thẻ dưới, thanh trên xanh `#2190bf`, Roboto, danh sách / bong bóng. Ảnh trong IPA là PNG kiểu Apple (CgBI) — chỉ
  giải ra thư mục tạm để xem, không chép vào dự án.
- Roza: 4 thẻ (Tin nhắn · Danh bạ · Nhóm · Thêm — «Nhật ký» chưa có API trong zca-js), thanh trên xanh loang tự vẽ, thanh dưới
  trắng, biểu tượng thẻ / nút vẽ bằng CoreGraphics (`RZTheme`).

## D4. TLS, WebSocket, tải ảnh đều qua lõi (rustls + ring vá) — 17/11/2026

- reqwest 0.12 (`rustls-tls-webpki-roots`, `gzip`) cho HTTP; WebSocket: tự mở TCP → tokio-rustls (provider ring) → bắt tay bằng
  `tokio_tungstenite::client_async` (tắt tính năng TLS của tungstenite để khỏi kéo aws-lc-rs). Không gửi
  `permessage-deflate` (tungstenite không hỗ trợ) → máy chủ gửi khung không nén.
- Phiên bản crate trùng GramMini (Cargo.lock chép sang làm gốc): ring 0.17.14 → `vendor-ring.sh` / `cargo-ios6.sh` dùng nguyên.
  Kiểm: tệp chạy có 185 ký hiệu `ring_core_0_17_14_*`, liên kết không thiếu hàm hợp ngữ.
- Cookie tự quản (`rz-zalo/src/cookies.rs`) thay tough-cookie: tự theo `Location` như `request()` của zca-js (giữ cookie từng
  bước của đăng nhập QR), lưu JSON trong `session.json`.
- Thử trên PC 17/11: luồng QR tới bước sinh mã chạy được (trang login → logininfo → verify-client → generate → ảnh QR 16,8 KB).

## D5. `std::fs::remove_dir_all` gọi hàm iOS 8 → tự viết `rm_tree` — 17/11/2026

- `symlist.py` trên bản dựng đầu: `_openat`, `_unlinkat`, `_fdopendir` (iOS 8+) — từ `remove_dir_all` của std (xoá bộ đệm). Cùng
  loại với `fstatat` của GramMini D15. Thay bằng `media::rm_tree` (lstat / opendir / unlink / rmdir).
- Sau sửa: `cbsymcheck` trên iPhone 5 (iOS 6.1.4) và iPad 1 (iOS 5.1.1): 323 / 323 ký hiệu có, thiếu 0.
- Quy tắc: không dùng `remove_dir_all`, `DirEntry::metadata`; chạy `tools-local/symcheck.sh iphone ipad1` sau mỗi lần thêm crate.

## D6. Lưu tin trên máy bằng SQLite (rusqlite bundled) — 17/11/2026

- Zalo Web không có API tải lịch sử chat riêng; chỉ có đồng bộ lúc mở WebSocket (510 / 511 — tin gần đây) và lịch sử nhóm
  (`/api/cm/getrecentv2`). Lõi giữ mọi tin nhận được (`roza.db`: `msgs`, `threads`, `users`, `groups`, `kv`).
- Tin mình gửi: hiện ngay với id tạm `l<cliMsgId>` (🕓); HTTP trả `msgId` hoặc WebSocket đẩy bản thật (cùng cliMsgId) → thay
  bằng tin thật, app nhận `msg.update` kèm `old_id`. Lỗi → `status: failed` (⚠, chạm để gửi lại / xoá).
- Đồng bộ lúc mở kết nối: xin 510 / 511 với `lastId` = msgId lớn nhất đã có; còn tin mới thì xin tiếp (≤ 8 lượt / kết nối).
- `librz_ffi.a` (kèm SQLite C dựng bằng clang của Theos) 7,5 MB; tệp chạy app 5,4 MB; `.deb` 3,2 MB.

## D7. Một Zalo Web mỗi tài khoản — 17/11/2026

- Máy chủ gửi cmd 3000 rồi đóng WebSocket khi có kết nối web khác (chat.zalo.me ở máy tính, hoặc `rz-cli` dùng cùng phiên). Roza
  không tự nối lại (hai bên sẽ đá nhau mãi) → trạng thái `duplicate`, dải vàng «Dùng ở đây» trên danh sách chat.
- Quy tắc thử: `rz-cli` dùng phiên riêng (`keys/rz-session.json`), không chép phiên giữa máy (như GramMini D24).

## D8. Mã đóng WebSocket và thử lại — 17/11/2026

- 1000 tự đóng; 1006 / không phản hồi 3 nhịp ping → nối lại sau 2 / 5 / 10 / 20 / 45 giây; chưa mở được (chưa có cipher key) thì
  đổi sang máy chủ WebSocket kế tiếp trong `zpw_ws`; mở lỗi ≥ 2 lần hoặc 3003 (bị đá) → đăng nhập lại để lấy khoá + địa chỉ mới.
- `getLoginInfo` trả lỗi phiên (AUTH) → dời `session.json` thành `session.dead-<giờ>.json`, app về màn đăng nhập QR.

## D9. Sticker: bảng chọn + sticker động bằng dải khung — 17/11/2026

- Zalo Web không có API «bộ sticker của tôi» → bảng sticker gồm «Gần đây» (gửi / nhận, lưu kv), các bộ đã gặp (`stickers.category`),
  «Tìm» (chữ gợi ý + «Khác…» bằng hộp nhập — ô tìm trong bảng sẽ bật bàn phím che bảng).
- Địa chỉ ảnh suy thẳng từ mã (`…/emoticon/sticker/webpc?eid=<id>&size=130`, dải khung `…/emoticon/sprite?eid=<id>&size=130`) — bỏ
  một lần gọi `sticker_detail` cho mỗi sticker (trước: 5–6 s mỗi ô của bảng).
- Sticker động: dải khung PNG ngang, khung vuông 130 px, số khung = rộng / cao; `duration` = ms mỗi khung. `RZStickerView` cắt sẵn
  từng khung ở hàng nền (không dùng ảnh rộng > 2048 px — GPU A4), đồng hồ ở chế độ mặc định của run loop đổi `layer.contents`.
  Khác GramMini (dừng sau 5 lượt vì Lottie / WebM vẽ tốn CPU): ở đây mỗi nhịp chỉ đổi contents → lặp liên tục như app Zalo; đứng khi
  cuộn / rời màn / app ở nền. Kiểm trên iPhone 5: ba ảnh chụp liên tiếp khác nhau đúng vùng sticker.

## D10. Chế độ tối — 17/11/2026

- Như GramMini D22: màu theo vai trò trong `RZTheme` (cặp sáng / tối: chữ, nền, ô, vạch, thanh nhập, nền chat, bong bóng), ảnh tự
  vẽ đệm theo chế độ; đổi trong Thêm → «Chế độ tối» → `RZAppDelegate setDarkMode:` dựng lại các thẻ, giữ thẻ đang chọn.
- Bảng nhóm iOS 5 / 6 có nền sọc (backgroundView) → bỏ khi tối; đầu mục danh bạ và chân mục «Thêm» tự vẽ (mặc định có bóng chữ
  trắng). Ô nhập tối dùng `UIKeyboardAppearanceAlert`. Màn đăng nhập giữ nền xanh, xem ảnh giữ nền đen.

## D11. Gửi ảnh / tệp / video / tin thoại — 17/11/2026

- Chuyển từ uploadAttachment + sendMessage (đính kèm) + sendVideo + sendVoice của zca-js: tải lên từng phần (`chunk_size_file`) —
  ảnh `photo_original/upload` → `photo_original/send`; tệp / video / thoại `asyncfile/upload` → chờ `file_done` (WebSocket cmd 601,
  có thể tới trước khi HTTP trả lời phần cuối — lõi giữ lại) → tệp `asyncfile/msg`, video `forward` msgType 5 (+ ảnh bìa `upthumb`),
  thoại `forward` msgType 3 (m4a).
- Lõi đọc tệp theo khúc + MD5 dần (không nạp cả video vào RAM), thử lại 2 lần mỗi phần khi lỗi mạng; tin tạm hiện ngay, `msg.progress`.
- App: nút «+» (Chụp ảnh / Ảnh / Video / Tệp trong máy), nút micro (ô trống) ↔ gửi (có chữ), bảng ghi âm giữ-để-nói (AAC 22 kHz
  mono 32 kbit/s), ảnh thu ≤ 1280 px, video nén bằng `RZVideoCompressor` (GramMini D16), trình chọn tệp `RZFileBrowserViewController`
  (GramMini D16). Mở: video `MPMoviePlayerViewController`, tệp `QLPreviewController` (lõi tải với đuôi theo tên tệp), thoại
  `AVAudioPlayer` (Playback → loa ngoài).
- Thử trên iPhone 5 vào «Cloud của tôi»: ảnh 168 ms, tệp 116 ms, thoại 155 ms, video 259 ms (tệp nhỏ); anh gửi thoại + tệp bằng tay.

## D12. Sao lưu lên Telegram (Bot API), không kèm phiên — 17/11/2026

- Anh chọn: Telegram trước; **không** kèm phiên đăng nhập Zalo (khôi phục xong quét QR lại). Bot do anh tạo ở @BotFather; token ở
  `backup.json` (0600, ngoài CSDL → không nằm trong bản sao lưu).
- Sao lưu: `VACUUM INTO` (bản chụp nhất quán khi đang chạy) → gzip → `sendDocument` → **ghim** tin. Khôi phục trên máy mới (không biết
  mã tệp, Bot API không cho đọc lịch sử chat): `getChat` → tin đang ghim → `getFile` → tải (Bot API cho tải ≤ 20 MB) → kiểm đầu
  «SQLite format 3» → thay `roza.db` (đóng CSDL bằng bản trong RAM, xoá -wal / -shm, đổi tên, mở lại). Tự sao lưu mỗi ngày (30 s sau
  khi đăng nhập, nếu bản trước quá 24 giờ). Nhà mạng chặn Telegram thì báo rõ.

## D13. Đồng bộ trực tiếp với phiên PC / điện thoại — 17/11/2026

- Anh chọn hoàn thiện phần trực tiếp (không dò giao thức «đồng bộ tin nhắn» riêng của Zalo PC). Đã có: tin mới gửi / nhận ở máy
  khác về Roza khi đang nối; nối lại thì xin tin bị lỡ (510 / 511 với lastId = msgId lớn nhất); lịch sử nhóm từ máy chủ.
- Thêm: mình nhắn từ điện thoại / PC → chat đó coi như đã đọc; sự kiện «đã xem» trỏ vào tin **của người khác** = chính mình đọc ở máy
  khác → xoá số chưa đọc (trỏ vào tin của mình = người kia đã xem → «Đã xem»).

## D14. Biểu tượng theo logo anh thiết kế — 17/11/2026

- `Tham_Khao/logo/logo1.png` (không lên git): cắt ô biểu tượng (x 845–1910, y 155–1258), góc ngoài trong suốt → `tools/icon/roza-logo-1024.png`
  (lên git); `make_icons.py` dựng các cỡ + ảnh khởi động (nền xanh than như ảnh logo). Đổi biểu tượng trên máy cần respring (GramMini D23).
- Anh chọn bản **kính mờ hồng** (`tools/icon/make_glass_icon.py` → `roza-glass-rose-1024.png`) trong 4 bản ở `so-sanh-icon.png`;
  `make_icons.py` dựng các cỡ + ảnh khởi động nền tím hồng; postinst xoá IconsCache của vn.roza.app.

## D15. Ô tìm kiếm lên thanh trên; bẫy `UISearchBar.keyboardAppearance` (iOS 7+) — 17/11/2026

- Anh yêu cầu: bỏ chữ «Roza» ở thanh trên danh sách chat, đưa ô tìm kiếm lên đó cạnh nút tin nhắn mới. Trạng thái kết nối chuyển vào
  dòng gợi ý của ô tìm («Đang kết nối…», «Chờ mạng…»); nút quay lại của màn chat ghi «Tin nhắn».
- Bản đầu crash ngay lúc mở ở chế độ tối (không có báo cáo crash): gán `keyboardAppearance` cho UISearchBar — UISearchBar chỉ nhận đủ
  UITextInputTraits từ iOS 7; SDK 9.3 không gắn nhãn phiên bản nên `-Werror=unguarded-availability` và symcheck (chỉ tra hàm C / lớp)
  đều không bắt được. Sửa: gán cho UITextField bên trong. Quy tắc: thuộc tính / hàm ObjC mới dùng trên lớp UIKit thì tra tài liệu
  phiên bản (hoặc `respondsToSelector:`), đừng tin bản dựng sạch.
- Thử sao lưu thật (bot thử riêng): 22 tin → 21 KB nén, 4,8 s, đã ghim trong chat (khôi phục chưa chạy thử — thay dữ liệu
  thật, chờ anh đồng ý).

## D16. Khôi phục được cả ảnh / video / tệp / thoại trong chat — 17/11/2026

- Anh muốn khôi phục Roza (máy mới / cài lại) thì tệp trong chat vẫn mở được trong Roza, kể cả khi địa chỉ trên máy chủ Zalo hết hạn.
- Sao lưu (bật «Sao lưu cả ảnh, video, tệp»): trước khi chụp CSDL, lõi chép dần các tệp chưa có trong sổ lên chat với bot (mới nhất
  trước; tệp mình gửi từ máy này đọc thẳng tệp gốc). Tệp chia phần ≤ 19 MB — Bot API chỉ cho bot tải về ≤ 20 MB / tệp, chia phần thì
  tệp to cỡ nào cũng khôi phục được. Gửi kèm `disable_content_type_detection` (không thì mp4 / gif thành video / animation — lần đầu
  1 tệp «không trả mã tệp»), đọc mã ở mọi dạng; 429 thì chờ `retry_after`; ~1,1 s / tin.
- Sổ `media_bk` (địa chỉ Zalo → các phần file_id; ảnh: cả hd / thường / thu nhỏ cùng trỏ một bản) nằm **trong** `roza.db` → đi theo bản
  sao lưu. Chép tệp trước, chụp CSDL sau → bản sao lưu có sổ mới nhất.
- Khôi phục: chỉ khôi phục CSDL; tệp lấy lại khi cần — `media.fetch` tải từ Zalo trước, lỗi / hết hạn mà có trong sổ thì lấy từ
  Telegram (ghép phần) vào đúng chỗ bộ đệm → giao diện không đổi gì. Máy mới phải nối lại cùng bot (token) để đọc được.
- Thử trên iPhone 5: 8 tệp (370 KB) chép xong; `backup.testFetch` lấy lại video thử từ Telegram: 51 676 byte = đúng cỡ gốc, 4 s.

## D17. Thông báo tin mới như GramMini (VoIP + tweak RZNotify); lưu về máy; màn Đồng bộ — 17/11/2026

- Thông báo: `RZBackground` (chép từ GMBackground — GramMini D17): xin thêm thời gian khi xuống nền; lõi báo fd socket WebSocket
  (`net.socket`, móc trong `listen::run`) → bọc CFStream + `kCFStreamNetworkServiceTypeVoIP`, bọc lại sau mỗi lần có dữ liệu;
  `setKeepAliveTimeout:600` → `net.check` (ping ngay, chết thì nối lại); `UIBackgroundModes = voip`. Thông báo từ sự kiện `notify`
  của lõi (chỉ khi app ở nền thật; bỏ chat tắt tiếng trừ khi bị @nhắc; bỏ tin cũ > 6 giờ); cài đặt Thêm → Thông báo (hiện / xem trước
  / âm thanh / số trên biểu tượng). Tweak `tweak/RZNotify` (chép GMNotify — GramMini D18) cho app ở /Applications có mục «Thông báo»;
  gói phụ thuộc mobilesubstrate; lần đầu cần respring.
- Lưu về máy (`RZMediaSaver`, theo GMMediaSaver — GramMini D25): ảnh / GIF bản gốc qua ALAssetsLibrary (giữ dữ liệu, GIF vẫn động),
  video vào Ảnh, tệp / thoại vào Tài liệu/Roza + «Mở bằng app khác…» (UIDocumentInteractionController).
- Đồng bộ (D13): màn Thêm → Đồng bộ tin nhắn — trạng thái trực tiếp, «Lấy lại tin bị lỡ» (`sync.now`: 21 tin riêng + 2 tin nhóm máy
  chủ đẩy lại, 0 mới — không sót), «Tải lịch sử tất cả nhóm» (`sync.groups`: máy chủ trả 0 tin cho cả 4 nhóm — cần xem thêm).
- Bài học: sửa tệp bằng Python ở chế độ văn bản trên Windows đổi LF → CRLF → `control` / `postinst` hỏng (dpkg-deb từ chối). Đã đổi
  lại 28 tệp, thêm `.gitattributes` (eol=lf).
- Khôi phục thật (D12) đã thử: chép dự phòng `roza.db*` → sao lưu 24 tin → khôi phục 24 tin, đủ 5 chat / 5 bạn / 4 nhóm / 8 tệp.

## D18. Trò chuyện ẩn kiểu Zalo (PIN đồng bộ với điện thoại) — 17/11/2026

- Anh thấy còn thiếu «ẩn trò chuyện / xem trò chuyện ẩn». Zalo lưu danh sách ẩn + PIN (MD5 của 4 chữ số) trên máy chủ:
  `/api/hiddenconvers/get-all`, `add-remove`, `update-pin` (theo zca-js). Lõi đọc khi đăng nhập / làm mới (`sync_hidden`) → cột
  `secret` trong `threads`; danh sách chat thường bỏ các chat ẩn; trò chuyện ẩn trên điện thoại cũng ẩn trong Roza và ngược lại.
- Ẩn: vuốt trái trên một chat → «Ẩn» (chưa có PIN thì đặt PIN, nhập hai lần). Xem: gõ đúng PIN vào ô tìm kiếm (như app Zalo), hoặc
  Thêm → Trò chuyện ẩn → nhập PIN. Trong danh sách ẩn vuốt «Bỏ ẩn». PIN so ở máy (MD5) — không gửi mã rõ đi đâu.
- Thông báo của chat ẩn không lộ tên / nội dung: «Roza: Bạn có tin nhắn mới».
- Thử trên iPhone 5: đọc được 1 chat ẩn + PIN đã đặt từ điện thoại (`count = 1`, `has_pin = 1`). Không tự ẩn / đặt PIN thử trên tài
  khoản thật (thay đổi tài khoản của anh).
- Lịch sử nhóm (D13, còn mở): `getCloudMessage` phân trang bằng `lastMsgId` + `isOld` (getoldv2), `-69` = hết. Hai nhóm vẫn trả
  `isFiltered = 1` dù `enableMsgHistory = 1` — máy chủ chỉ cho Zalo Web xem lịch sử nhóm trong một số điều kiện; màn Đồng bộ ghi rõ
  lý do từng nhóm.

## D19. Bản 1.0.0: thử trên iPad, nguồn Cydia, trang giới thiệu — 17/11/2026

- iPad mini 1 (iOS 6.1.3) và iPad 1 (iOS 5.1.1): chép phiên từ iPhone để thử nhanh (không phải quét QR) — vào trong ~1,3 s. Giao
  diện iPhone phóng to (chưa có bố cục riêng cho iPad).
- **Một phiên Zalo Web chỉ một kết nối**: app có `UIBackgroundModes = voip` nên iOS **tự mở lại** app sau khi bị tắt → hai máy dùng
  chung phiên sẽ đá kết nối của nhau (mã 3000, «Dùng ở đây»). Thử xong thì xoá phiên trên iPad (chỉ xoá tệp trên máy — không gọi
  đăng xuất, đăng xuất sẽ huỷ luôn phiên của iPhone). Chụp ảnh trên máy phụ: tạm chặn `wpa.chat.zalo.me` trong `/etc/hosts`.
- Bản phát hành `FINALPACKAGE=1`: không có `Debug/` (không còn lớp RZDebug, không đọc `Roza-cmd.txt`), `.deb` 3,2 MB; `cbsymcheck`
  412 / 412 trên iPad 1 iOS 5.1.1 và iPad mini 1 iOS 6.1.3; mở được trên iPad 1.
- Trang giới thiệu + nguồn Cydia trên nhánh `gh-pages` của itovn/Roza (giống GramMini): https://itovn.github.io/Roza/ và
  https://itovn.github.io/Roza/cydia/ (`tools/update-cydia-repo.sh`). Đường dẫn GitHub Pages phân biệt hoa thường → tên repo là
  «Roza» (github.com/itovn/roza vẫn mở được).
- Ảnh trên trang: không lộ tên, số điện thoại, bạn bè, nhóm; mã QR làm mờ; xoá nút AssistiveTouch khỏi ảnh chụp.

## D20. Giao diện iPad: màn chia đôi (UISplitViewController) — 17/11/2026

- Anh yêu cầu làm giao diện riêng cho iPad. iPad: gốc cửa sổ là `UISplitViewController` (iOS 5 / 6 bắt buộc làm gốc) — bên trái
  nguyên bộ thẻ như iPhone (rộng 320), bên phải `UINavigationController` chứa cuộc trò chuyện; chưa mở chat thì màn trống «Chọn
  một cuộc trò chuyện». Delegate `shouldHideViewController` → NO: luôn hiện cả hai cột, cả chiều dọc (như app Tin nhắn trên iPad).
- Mọi chỗ mở chat đi qua `RZOpenChat` → iPad thay chat bên phải (`setViewControllers`), không đẩy vào cột trái; chat đang mở thì
  chỉ quay về màn chat. Danh sách chat tô hàng của chat đang mở (`RZOpenThreadChanged`); Danh bạ / Nhóm bỏ chọn sau khi mở.
  Ẩn trò chuyện đang mở bên phải → đóng về màn trống (`RZCloseChat`). Đổi chế độ sáng / tối dựng lại giao diện → mở lại chat cũ.
- Màn chat theo bề rộng mới khi xoay (bên phải 703 ↔ 447): `viewWillLayoutSubviews` xếp lại ô nhập, tính lại cỡ bong bóng
  (`reloadData`, giữ cuộn cuối); bảng sticker xếp lại lưới theo bề rộng. Lỗi bắt được khi thử: khung tiêu đề hai dòng co giãn theo
  thanh trên → xoay dọc co về 0, mất tiêu đề → khung giữ bề rộng (iPad 320), chỉ căn giữa.
- Đăng nhập trên iPad: khối nội dung đặt giữa màn (giữ giữa khi xoay), mã QR 300 điểm, cho xoay mọi chiều.
- Thử: iPad mini 1 (iOS 6.1.3) ngang + dọc, sticker, chế độ tối, Danh bạ, Thêm; iPad 1 (iOS 5.1.1) dọc. Dữ liệu thử chép từ iPhone,
  chặn `wpa.chat.zalo.me` để không đá phiên của iPhone; thử xong xoá phiên trên iPad, gỡ chặn. `cbsymcheck` 418 / 418.
  Lệnh thử mới (bản debug): `orient 1|2|3|4` (API riêng UIDevice), `close`. iPad 1 không xoay được bằng lệnh (khoá xoay?) — chiều
  ngang trên iOS 5 chưa thử lại.

## D21. Nhắc hẹn, vị trí, tin nhắn nhanh, ngân hàng + VietQR, danh thiếp, lưu Telegram, tên gợi nhớ — 17/11/2026

- Anh yêu cầu thêm: nhắc hẹn, vị trí, tin nhắn nhanh, chuyển khoản, danh thiếp, «Save to Cloud Telegram», gửi số tài khoản; rồi
  thêm: đặt tên riêng cho một tài khoản bất kỳ, và lỗi chat với người chưa kết bạn chỉ hiện «Người dùng Zalo».
- Anh chọn: **chuyển khoản = mã VietQR** (ZaloPay không có API cho Zalo Web, iOS 6 không có app ZaloPay); **lưu Telegram = chat với
  bot sao lưu** (không đăng nhập Telegram).
- Dạng tin thật (gửi thử vào «Cloud của tôi» bằng `rz-cli`, chỉ HTTP — không mở WebSocket nên không đá kết nối của iPhone):
  danh thiếp `chat.recommended` (`params` = chính uid, kiểu số — bản trước đọc sai); thẻ ngân hàng `chat.webcontent` /
  `zinstant.bankcard` — dữ liệu nằm trong mẫu zinstant (gzip, FlatBuffers) tải từ `data_url`: chuỗi VietQR trong nút «Lưu tài
  khoản», chủ tài khoản đứng trước số tài khoản, tên ngân hàng ngay sau (`vietqr::bank_card`); nhắc hẹn `chat.ecard` (dữ liệu
  `params.actions[].data` lồng hai lớp chuỗi JSON); dòng «X tạo nhắc hẹn mới…» là `webchat` + `msginfo.actionlist` → tin hệ thống.
  Danh sách nhắc hẹn rỗng thì máy chủ trả lỗi -1. Tin cũ đọc lại một lần theo loại mới (`Store::renormalize`, kv `renorm=2`).
- VietQR tự dựng (chuẩn EMVCo / NAPAS, CRC-16/CCITT-FALSE) + crate `qrcode` (Rust thuần) → ma trận; app vẽ thẻ (ngân hàng, số TK,
  chủ TK, số tiền, nội dung) rồi gửi như ảnh, kèm một tin chữ để người nhận chép số tài khoản.
- Bản đồ: MapKit trên iOS 5 / 6 chỉ còn lưới trống (máy chủ ô của Apple / Google cho iOS cũ đã tắt) → tự ghép ô OpenStreetMap,
  lõi tải (TLS của iOS 6 không vào được), User-Agent nêu tên app, ghi «© OpenStreetMap»; địa chỉ tra bằng Nominatim (tiếng
  Việt). Gửi vị trí = tin chữ «📍 địa chỉ» + đường dẫn Google Maps (Zalo Web không có API gửi tin vị trí; Zalo nào cũng mở được);
  chạm vào đường dẫn bản đồ trong chat → xem trên bản đồ.
- Người lạ không tên: `contacts.find` lưu sai tên trường (`uid` / `display_name` / `zalo_name` của API tìm theo số, khác
  getUserInfo) và chat do mình nhắn trước không bao giờ hỏi getUserInfo (tin của mình về qua HTTP, bỏ qua bước tra người).
  Sửa: lưu đúng tên trường; mở chat 1-1 chưa có thông tin → tra ngay; sau đăng nhập tra mọi chat 1-1 còn thiếu. getUserInfo trả đủ
  tên + ảnh cho người lạ (đã thử).
- Tên gợi nhớ: `/api/alias/*` (đồng bộ với điện thoại), cột `users.alias`; tên hiện = gợi nhớ > tên hiển thị > tên Zalo, cả tên
  người gửi trong nhóm. Đặt: chạm tiêu đề màn chat → «Đặt tên gợi nhớ…», hoặc chạm giữ một người trong Danh bạ.
- Nhắc hẹn: thông báo trên máy (UILocalNotification, lặp ngày / tuần / tháng) cho nhắc hẹn mình tạo và nhắc hẹn nhận được; mở app
  không xoá các thông báo đã hẹn giờ này.
- Chạy nền: iOS mở lại app VoIP ở nền (sau khi bị tắt / khởi động lại) mà không gọi applicationDidEnterBackground → app treo giữa
  lúc «đang kết nối» (nhật ký iPhone kẹt từ 16:13). Sửa: mở ở nền thì xin thời gian chạy nền + giữ kết nối ngay.
- Thử trên iPad mini 1 (phiên chép từ iPhone, iPhone tạm bị ngắt): bong bóng 4 loại mới, thẻ ngân hàng tự đọc, màn mã QR, gửi mã QR
  chuyển khoản (ảnh + chữ), gợi ý «/», nhắc hẹn, bản đồ OSM, tra địa chỉ, lưu Telegram (chữ + ảnh). `cbsymcheck` 432 / 432.
