#import <UIKit/UIKit.h>

/// Tin mới khi app ở nền — như GMBackground của GramMini (D17):
/// - Mức 1: xuống nền thì xin thêm thời gian chạy (~10 phút) — kết nối vẫn mở, tin mới thành thông báo.
/// - Mức 2: chế độ nền «voip» — socket WebSocket lõi mở tới Zalo (sự kiện `net.socket`) được bọc CFStream + đánh dấu VoIP; app đã
///   bị treo thì iOS đánh thức khi có dữ liệu về. Cứ 10 phút (`setKeepAliveTimeout`) lõi ping (`net.check`) cho kết nối khỏi chết;
///   iOS tự mở lại app ở nền sau khi khởi động máy.
/// - Thông báo: tên chat (nhóm: «người gửi @ nhóm»), nội dung (tắt xem trước thì «Tin nhắn mới»), âm thanh, số chưa đọc trên biểu
///   tượng. Bỏ qua chat tắt tiếng (trừ khi bị nhắc @), tin cũ hơn 6 giờ (lấy bù sau khi mất kết nối lâu).
/// - iOS 5 / 6 chỉ hiện thông báo của app có mục «Thông báo»: app ở /Applications cần tweak RZNotify (GramMini D18) + đăng ký.
@interface RZBackground : NSObject
+ (instancetype)shared;
- (void)start;
- (void)didEnterBackground;
- (void)willEnterForeground;
@end

/// Khoá cài đặt (NSUserDefaults, mặc định bật).
extern NSString *const RZPrefNotify, *const RZPrefPreview, *const RZPrefSound, *const RZPrefBadge;
BOOL RZPref(NSString *key);
