#import <UIKit/UIKit.h>

/// Bảng chọn (UIActionSheet) dùng block — iOS 5 / 6 chưa có UIAlertController.
@interface RZSheet : NSObject
- (instancetype)initWithTitle:(NSString *)title;
- (void)add:(NSString *)title action:(void (^)(void))action;
- (void)addDestructive:(NSString *)title action:(void (^)(void))action;
- (void)showIn:(UIView *)view;
@end

/// Hộp thoại (UIAlertView) dùng block.
void RZAlert(NSString *title, NSString *msg);
void RZConfirm(NSString *title, NSString *msg, NSString *ok, void (^action)(void));

/// Hộp nhập mã PIN 4 số (bàn phím số, che ký tự). done(mã) khi bấm «OK» với đúng 4 chữ số.
void RZAskPin(NSString *title, NSString *msg, void (^done)(NSString *pin));
/// Nhãn một dòng (cỡ chữ, màu).
UILabel *RZLabel(CGFloat size, BOOL bold, UIColor *color);
/// Bỏ dấu tiếng Việt + chữ thường (tìm kiếm, xếp theo chữ cái).
NSString *RZFold(NSString *s);
/// Mở cuộc trò chuyện (`u<uid>` / `g<gid>`) trên thanh điều hướng `nav`.
void RZOpenChat(UINavigationController *nav, NSString *thread, NSString *name, NSString *avatar);
