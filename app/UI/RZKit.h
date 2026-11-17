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
/// Hộp nhập một dòng chữ: `value` có sẵn, `kb` kiểu bàn phím. done(chữ) khi bấm «OK» (chữ có thể rỗng).
void RZAskText(NSString *title, NSString *msg, NSString *value, NSString *placeholder, UIKeyboardType kb, void (^done)(NSString *text));
/// Đặt / đổi / bỏ (để trống) tên gợi nhớ của `uid` — cả người chưa kết bạn; đồng bộ với Zalo trên điện thoại.
/// done(tên đang hiện sau khi đổi) khi xong.
void RZEditAlias(NSString *uid, NSString *shown, void (^done)(NSString *name));
/// Số tiền có dấu chấm ngăn nghìn: 150000 → «150.000».
NSString *RZMoney(long long amount);
/// Nhãn một dòng (cỡ chữ, màu).
UILabel *RZLabel(CGFloat size, BOOL bold, UIColor *color);
/// Bỏ dấu tiếng Việt + chữ thường (tìm kiếm, xếp theo chữ cái).
NSString *RZFold(NSString *s);
/// Mở cuộc trò chuyện (`u<uid>` / `g<gid>`) trên thanh điều hướng `nav`.
void RZOpenChat(UINavigationController *nav, NSString *thread, NSString *name, NSString *avatar);
