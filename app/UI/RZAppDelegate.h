#import <UIKit/UIKit.h>

@interface RZAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
/// Đổi chế độ sáng / tối: lưu, đặt lại giao diện chung, dựng lại các thẻ (appearance proxy chỉ vào view tạo sau), giữ thẻ đang chọn.
- (void)setDarkMode:(BOOL)dark;
@end
