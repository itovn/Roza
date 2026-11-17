#import <UIKit/UIKit.h>

/// Thẻ «Danh bạ»: bạn bè Zalo xếp theo chữ cái (bỏ dấu), tìm theo tên, tìm người bằng số điện thoại. `initPicker`: chọn người
/// để bắt đầu trò chuyện (nút soạn tin ở danh sách chat).
@interface RZContactsViewController : UITableViewController
- (instancetype)initPicker;
@end
