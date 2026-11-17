#import <UIKit/UIKit.h>

@interface RZAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
/// Đổi chế độ sáng / tối: lưu, đặt lại giao diện chung, dựng lại các thẻ (appearance proxy chỉ vào view tạo sau), giữ thẻ đang chọn.
- (void)setDarkMode:(BOOL)dark;
@end

/// Có màn chia đôi (iPad): bên trái các thẻ như iPhone, bên phải cuộc trò chuyện đang mở.
BOOL RZPad(void);
/// iPad: thanh điều hướng bên phải (cuộc trò chuyện); iPhone / chưa đăng nhập: nil.
UINavigationController *RZDetailNav(void);
/// iPad: mã cuộc trò chuyện đang mở bên phải (nil nếu chưa mở).
NSString *RZOpenThread(void);
/// iPad: nếu `thread` đang mở bên phải thì đóng, về màn trống (vd. vừa ẩn trò chuyện).
void RZCloseChat(NSString *thread);
/// Tên thông báo (NSNotificationCenter) khi cuộc trò chuyện bên phải đổi — danh sách chat tô lại hàng đang mở.
extern NSString *const RZOpenThreadChanged;
