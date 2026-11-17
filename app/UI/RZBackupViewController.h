#import <UIKit/UIKit.h>

/// Thêm → Sao lưu: sao lưu dữ liệu Roza (tin nhắn, danh bạ, nhóm, sticker gần đây — không gồm phiên đăng nhập, ảnh đệm) vào chat với
/// bot Telegram của người dùng (tạo ở @BotFather). Khôi phục từ bản đang ghim trong chat đó. Lõi: lệnh `backup.*` (docs/FFI.md).
@interface RZBackupViewController : UITableViewController
@end
