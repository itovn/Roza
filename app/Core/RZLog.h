#import <Foundation/Foundation.h>

/// Nhật ký của app: NSLog + tệp <dữ liệu>/app.log (giữ ~1 MB). Không ghi nội dung tin nhắn / số điện thoại.
void RZLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
/// Thư mục dữ liệu của app: ~/Library/Roza (app ở /Applications không có sandbox → /var/mobile/Library/Roza).
NSString *RZDataDir(void);
long long RZNowMs(void);
/// Đánh dấu tệp đệm vừa dùng (đổi thời điểm sửa — lõi xoá tệp lâu không dùng trước); chỉ ghi khi lần trước đã quá 1 giờ.
void RZTouchFile(NSString *path);
