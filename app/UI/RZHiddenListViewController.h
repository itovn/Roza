#import <UIKit/UIKit.h>

/// Thêm → Trò chuyện ẩn: hỏi mã PIN (4 số, đồng bộ với Zalo trên điện thoại), rồi liệt kê các trò chuyện ẩn; chạm để mở, vuốt «Bỏ ẩn».
/// Chưa có PIN thì đặt PIN mới. Cũng mở được bằng cách gõ đúng PIN vào ô tìm kiếm của danh sách chat (như app Zalo).
@interface RZHiddenListViewController : UITableViewController
- (instancetype)initWithThreads:(NSArray *)threads;
@end

/// Ẩn một trò chuyện (kiểu Zalo): chưa có PIN thì hỏi đặt PIN 4 số (nhập hai lần) rồi ẩn. done(YES) khi đã ẩn.
void RZHideThread(NSString *thread, void (^done)(BOOL ok));
/// Hỏi PIN rồi mở màn Trò chuyện ẩn trên `nav`.
void RZOpenHidden(UINavigationController *nav);
