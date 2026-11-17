#import <UIKit/UIKit.h>

/// Chọn tệp trong bộ nhớ máy để gửi (máy JB iOS 5 / 6 không có app Tệp / UIDocumentPicker). Trang đầu: các vị trí hay dùng
/// (Tài liệu, Tải về, Ảnh DCIM, Ghi âm, tài liệu của các app — hiện tên app thay mã UUID, thư mục người dùng, toàn bộ máy);
/// rồi duyệt thư mục (thư mục trước, tệp sau; tên, cỡ, ngày). Chạm tệp → hỏi lại → đóng màn rồi gọi `onPick`.
@interface RZFileBrowserViewController : UITableViewController
/// `path` nil = trang vị trí.
- (instancetype)initWithPath:(NSString *)path title:(NSString *)title;
@property (nonatomic, copy) void (^onPick)(NSString *path);
/// Gỡ lỗi: chạm hàng; mở thẳng một thư mục.
- (void)debugTapSection:(NSInteger)section row:(NSInteger)row;
- (void)debugOpenPath:(NSString *)path;
@end
