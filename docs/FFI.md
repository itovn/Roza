# Roza — Hợp đồng giữa app (Objective-C) và lõi Rust

Lõi: `core/crates/rz-ffi` → `librz_ffi.a` (dịch vụ ở `core/crates/rz-core/src/lib.rs`). App: `app/Core/RZCore.m`.

## Hàm C

```c
typedef void (*rz_cb)(const char *json, void *ctx);
int  rz_init(const char *config_json, rz_cb on_event, void *ctx);
void rz_call(const char *request_json, rz_cb on_result, void *ctx);
```

- `rz_init` — một lần lúc mở app. `config_json`: `{"data_dir", "cache_dir", "user_agent"?}`. Trả 0 = được; 1 = cấu hình sai;
  3 = không mở được dữ liệu; 4 = đã mở. Không đụng mạng; lõi tự đăng nhập lại ở nền rồi đẩy `auth.state`.
- `rz_call` — chạy nền. `request_json`: `{"m": "<nhóm.lệnh>", "a": {…}}`. `on_result` gọi **đúng một lần** với `{"ok": …}` hoặc
  `{"err": {"code", "msg"}}`. Mã lỗi: `AUTH`, `NETWORK`, `TIMEOUT`, `ZALO`, `PROTOCOL`, `BAD_ARGS`, `NOT_FOUND`, …
- Callback chạy trên luồng của lõi; chuỗi chỉ dùng được trong lúc gọi.

## Khoá cuộc trò chuyện

`u<uid>` (người), `g<grid>` (nhóm). Mã của Zalo là chuỗi số — giữ dạng chuỗi.

## Kiểu dữ liệu

**Thread** (danh sách chat): `{key, group, id, name, avatar, ts (ms), unread, pinned, muted, preview, members?, seen?, status?}`

**Msg**: `{id, cid, thread, from, out, ts (ms), type (msgType của Zalo), kind, text, name (tên người gửi), avatar? (nhóm),
media?, quote?: {from, name, text, id, cid}, mentions?: [{uid, pos, len}], reacts?: {uid: icon}, status?: sending|sent|failed}`

`kind`: `text`, `photo` (`media: {url, normal, thumb, w, h}`), `gif`, `sticker` (`{id, cat, type}`), `voice` (`{url, dur}`),
`video` (`{url, thumb, dur, w, h}`), `file` (`{name, url, size, ext}`), `link` (`{url, title, desc, thumb}`), `contact`,
`location`, `poll`, `system`, `recall`, `other`. Tin mình gửi chưa có msgId: `id = "l<cid>"`.

## Lệnh

| Lệnh | Tham số | Kết quả |
| --- | --- | --- |
| `auth.state` | — | `{authorized, me?: {uid, name, avatar, phone, …}, dead?}` |
| `auth.qrStart` | — | `{}`; tiến trình qua sự kiện `auth.qr` |
| `auth.qrCancel` | — | `{}` |
| `auth.logout` | — | `{}` — xoá phiên, kho tin, bộ đệm |
| `net.state` | — | `{state: idle\|connecting\|online\|offline\|duplicate}` |
| `net.reconnect` | — | `{}` — nối lại ngay (cả khi đang `duplicate` = «Dùng ở đây») |
| `threads.list` | `limit` (300) | `[Thread]` |
| `threads.get` | `thread` | `Thread` |
| `threads.hide` | `thread` | `{}` — ẩn khỏi danh sách (tin mới thì hiện lại) |
| `threads.mute` | `thread`, `mute`, `duration`? (giây, −1 mãi) | `{muted}` |
| `messages.history` | `thread`, `limit` (40), `before_ts`? | `{msgs: [Msg] cũ → mới, more}` — nhóm: lần đầu mở / cuộn hết thì tải từ máy chủ |
| `messages.open` | `thread` | `Thread` — đánh dấu đã đọc, báo đã xem, tin đến khi đang mở tự báo đã xem |
| `messages.close` | `thread` | `{}` |
| `messages.send` | `thread`, `text`, `reply_to`? (msgId), `mentions`? | `Msg` (tạm, `status: sending`) |
| `messages.retry` | `thread`, `cid` | `Msg` |
| `messages.sendSticker` | `thread`, `id`, `cat`, `type` | `{id, cid}` |
| `messages.typing` | `thread` | `{}` |
| `messages.recall` | `thread`, `id` | `Msg` (đã thu hồi) |
| `messages.delete` | `thread`, `id` | `{}` — xoá ở phía mình |
| `messages.react` | `thread`, `id`, `icon` (`/-heart`, `/-strong`, `:>`, `:o`, `:-((`, `:-h`) | `{}` |
| `messages.sendPhoto` | `thread`, `path` (JPEG trên máy), `w`, `h` | `Msg` tạm; tiến độ `msg.progress` |
| `messages.sendFile` | `thread`, `path`, `name`? | `Msg` tạm (chờ `file_done` của máy chủ ≤ 180 s) |
| `messages.sendVideo` | `thread`, `path` (MP4), `thumb` (JPEG), `w`, `h`, `dur` (ms) | `Msg` tạm |
| `messages.sendVoice` | `thread`, `path` (m4a), `dur` (ms) | `Msg` tạm |
| `stickers.recent` / `stickers.cats` | — | `[{id, cat, type}]` sticker gần đây / các bộ đã gặp |
| `stickers.search` | `q` | `[{id, cat, type, url?}]` |
| `stickers.category` | `cat` | `[{id, cat, type, url}]` cả bộ |
| `sticker.info` | `id` | `{url, sprite, webp, frames, duration (ms / khung)}` |
| `backup.get` | — | `{has_token, bot, chat_id, chat, auto, last_ms, last_size}` |
| `backup.setToken` / `backup.findChat` / `backup.setAuto` | `token` / — / `auto` | như `backup.get` |
| `backup.run` | — | `{count, size, state}` — gửi + ghim vào chat với bot |
| `backup.restore` | — | `{count}` — thay CSDL bằng bản đang ghim |
| `backup.setMedia` / `backup.media` / `backup.testFetch` | `media` / — / — | sao lưu cả tệp trong chat (D16) |
| `sync.state` / `sync.now` / `sync.groups` | — / — / `max` (300) | trạng thái đồng bộ, lấy lại tin bị lỡ, tải lịch sử nhóm (D13) |
| `hidden.state` | — | `{has_pin, count}` — PIN trò chuyện ẩn (đồng bộ với Zalo trên điện thoại) |
| `hidden.unlock` | `pin` | `[Thread]` trò chuyện ẩn, hoặc lỗi `PIN` |
| `hidden.setPin` | `pin` (4 số) | `{}` — đặt PIN mới (lưu lên máy chủ, MD5) |
| `hidden.set` | `thread`, `hidden` | `{hidden}` — ẩn / bỏ ẩn (cần PIN trước, lỗi `NO_PIN`) |
| `hidden.sync` | — | `{}` — đọc lại danh sách ẩn + PIN từ máy chủ |
| `alias.set` | `uid`, `alias` (rỗng = bỏ) | `User` — tên gợi nhớ (cả người chưa kết bạn), đồng bộ với điện thoại |
| `user.info` | `uid` | `{uid, name, alias, real_name, zname, avatar, phone, friend}` |
| `card.send` | `thread`, `uid`, `phone`? | `{msgId}` — gửi danh thiếp |
| `bank.list` | — | `[{bin, name, full, logo, key}]` ngân hàng (giữ 7 ngày) |
| `bank.accounts` / `bank.addAccount` / `bank.removeAccount` | — / `bin, number, holder` / `id, default` | `[{id, bin, number, holder, default, bank}]` tài khoản đã lưu trong Zalo |
| `bank.sendCard` | `thread`, `bin`, `number`, `holder` | `{}` — thẻ tài khoản (Zalo hiện thẻ có VietQR) |
| `bank.resolve` | `thread`, `id` | `Msg` — đọc thẻ tài khoản trong chat (tải mẫu zinstant) → `media.{bin, number, holder, bank}` |
| `vietqr.make` | `bin`, `number`, `amount`?, `note`? | `{payload, size, bits}` — mã VietQR (app tự vẽ) |
| `reminders.list` / `reminders.save` / `reminders.remove` | `thread` / `thread, id?, title, emoji?, ts, repeat` / `thread, id` | `[{id, title, emoji, ts, repeat, creator}]` |
| `quick.list` / `quick.save` / `quick.remove` | `refresh`? / `id?, keyword, text` / `id` | `[{id, keyword, text}]` tin nhắn nhanh |
| `tg.save` | `thread`, `id` | `{chat, bot}` — lưu tin vào chat với bot sao lưu (lỗi `NO_BOT`) |
| `map.tile` / `map.address` | `z, x, y` / `lat, lng` | `{path}` ô OpenStreetMap / `{address}` (Nominatim) |
| `contacts.list` / `contacts.refresh` | — | `[{uid, name, avatar}]` |
| `contacts.find` | `phone` | `{uid, name, zname, avatar}` |
| `groups.list` / `groups.refresh` | — | `[{gid, name, avatar, members, ts}]` |
| `user.info` | `uid` | `{uid, name, zname, avatar, phone, friend, …}` |
| `user.lastOnline` | `uid` | `{last (giây), show}` |
| `group.info` | `gid` | `{gid, name, avatar, members, desc, creator, admins, member_ids}` |
| `media.fetch` | `url`, `kind`: avatar\|thumb\|photo\|sticker\|voice\|file, `ext`? (đuôi gợi ý) | `{path}` — tải qua lõi (TLS của lõi), WebP → PNG |
| `media.cached` | `url`, `kind` | `{path \| null}` |
| `sticker.url` | `id` | `{url, sprite, frames?, duration?}` — suy từ mã, không gọi API |
| `cache.usage` / `cache.clear` | — | `{bytes}` |

## Sự kiện

| Sự kiện | Dữ liệu |
| --- | --- |
| `auth.state` | như lệnh `auth.state` |
| `auth.qr` | `{state: generated (path) \| scanned (name, avatar) \| expired \| declined \| done \| error (code, msg)}` |
| `net.state` | `{state}` |
| `threads.changed` | — (tải lại danh sách) |
| `threads.upsert` | `{threads: [Thread]}` |
| `contacts.changed` | — |
| `msg.new` | `{thread, msg}` |
| `msg.update` | `{thread, msg, old_id?, err?}` |
| `msg.delete` | `{thread, id}` |
| `msg.seen` | `{thread, id, uids}` |
| `typing` | `{thread, uid, name}` |
| `group.event` | `{thread, act}` |
| `msg.progress` | `{thread, id, p}` — tiến độ tải lên (0…1) |
| `notify` | `{thread, from, name, group, sender, text, muted}` — tin mới không phải của mình, chat không đang mở |
