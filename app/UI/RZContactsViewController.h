#import <UIKit/UIKit.h>

/// Thẻ «Danh bạ»: bạn bè Zalo xếp theo chữ cái (bỏ dấu), tìm theo tên, tìm người bằng số điện thoại. `initPicker`: chọn người
/// để bắt đầu trò chuyện (nút soạn tin ở danh sách chat).
@interface RZContactsViewController : UITableViewController
- (instancetype)initPicker;
/// Chọn một người (vd. gửi danh thiếp): chạm → onPick(@{uid, name, avatar}), không mở chat. Trình bày trong nav (có nút «Huỷ»).
- (instancetype)initChooserWithTitle:(NSString *)title onPick:(void (^)(NSDictionary *user))onPick;
@end
