#import <UIKit/UIKit.h>

// Tính năng thêm của màn chat: tài khoản ngân hàng + mã QR chuyển khoản, nhắc hẹn, tin nhắn nhanh, vị trí.

#pragma mark - Ngân hàng (RZBank.m)

/// Chọn ngân hàng (danh sách của Zalo, tìm không dấu). Trình bày trong nav (có nút «Huỷ») hoặc đẩy vào nav.
@interface RZBankPickerViewController : UITableViewController
@property (nonatomic, copy) void (^onPick)(NSDictionary *bank);  // {bin, name, full, logo}
@end

/// Nhập tài khoản ngân hàng rồi gửi vào chat: `qr` = NO gửi thẻ tài khoản (Zalo hiện thẻ có mã VietQR); `qr` = YES tạo ảnh mã
/// QR chuyển khoản (có số tiền, nội dung) — người nhận quét bằng app ngân hàng bất kỳ.
@interface RZBankFormViewController : UITableViewController
- (instancetype)initWithThread:(NSString *)thread qr:(BOOL)qr;
#ifdef DEBUG
/// Thử: điền [bin, số TK, TÊN, số tiền, nội dung…] rồi gửi.
- (void)debugFill:(NSArray *)p;
#endif
@end

/// Xem thẻ tài khoản trong chat (`media`: bin, number, holder, bank): mã VietQR, nhập số tiền, chép số tài khoản, lưu ảnh mã.
@interface RZBankCardViewController : UIViewController
- (instancetype)initWithCard:(NSDictionary *)media;
@end

/// Vẽ thẻ mã VietQR → ảnh. `qr` = kết quả `vietqr.make` ({size, bits}); `info` = {bank, number, holder, amount, note}.
UIImage *RZVietQRCard(NSDictionary *qr, NSDictionary *info);

#pragma mark - Nhắc hẹn (RZReminders.m)

/// Nhắc hẹn của một cuộc trò chuyện (đồng bộ với Zalo — cả hai bên đều thấy): tạo, sửa, xoá; Roza hẹn thông báo trên máy.
@interface RZReminderListViewController : UITableViewController
- (instancetype)initWithThread:(NSString *)thread name:(NSString *)name;
@end

/// Hẹn thông báo trên máy cho một nhắc hẹn ({id, title, ts, repeat}) — thay thông báo cũ cùng mã. Bỏ qua nếu đã qua giờ.
void RZScheduleReminder(NSDictionary *r, NSString *thread, NSString *chatName);
/// Bỏ thông báo đã hẹn của nhắc hẹn `rid`.
void RZCancelReminder(NSString *rid);

#pragma mark - Tin nhắn nhanh (RZQuickMessages.m)

/// Tin nhắn nhanh (đồng bộ với Zalo trên điện thoại): thêm / sửa / xoá. Trong chat gõ «/» để chọn.
@interface RZQuickMessagesViewController : UITableViewController
@end

#pragma mark - Vị trí (RZLocation.m)

/// Bản đồ một vị trí (tin vị trí trong chat), có nút mở bằng app Bản đồ.
@interface RZMapViewController : UIViewController
- (instancetype)initWithLat:(double)lat lng:(double)lng title:(NSString *)title;
/// Chọn vị trí để gửi: bắt đầu ở vị trí hiện tại, kéo bản đồ để chọn chỗ khác. done(vĩ độ, kinh độ, địa chỉ).
- (instancetype)initPickerWithDone:(void (^)(double lat, double lng, NSString *address))done;
@end

/// Chữ gửi cho một vị trí: «📍 địa chỉ» + đường dẫn Google Maps (mở được trên mọi máy, cả Zalo trên điện thoại).
NSString *RZLocationText(double lat, double lng, NSString *address);
/// Đọc vĩ độ / kinh độ trong đường dẫn bản đồ (maps.google.com/maps?q=…, maps.apple.com/?ll=…). NO nếu không phải.
BOOL RZParseMapURL(NSString *url, double *lat, double *lng);
