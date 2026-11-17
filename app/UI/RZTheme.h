#import <UIKit/UIKit.h>

// SDK 9.3 gắn nhãn «iOS 6» cho NSTextAlignment / NSLineBreakMode (cả tên hằng) → dựng với -Werror=unguarded-availability
// thì dùng số (trùng giá trị UITextAlignment / UILineBreakMode của iOS 5) — GramMini D13.
#define RZAlignLeft 0
#define RZAlignCenter 1
#define RZAlignRight 2
#define RZBreakWord 0
#define RZBreakTail 4
#define RZMiddleTruncation 5

UIColor *RZHex(unsigned rgb);
/// Chế độ tối (iOS 5 / 6 không có chế độ tối hệ thống — app tự làm như GramMini D22). Chốt lúc `RZTheme apply`; đổi thì dựng lại
/// cây màn (RZAppDelegate reloadTheme) vì appearance proxy / ảnh tự vẽ chỉ vào view tạo sau.
BOOL RZDark(void);
/// Màu theo vai trò (mỗi màu có bản sáng / tối).
UIColor *RZBlue(void);      // xanh chủ đạo: nút, biểu tượng thẻ đang chọn, chữ nhấn
UIColor *RZText(void);      // chữ chính
UIColor *RZTextGray(void);  // chữ phụ (giờ, xem trước)
UIColor *RZLine(void);      // vạch kẻ
UIColor *RZBg(void);        // nền bảng / màn
UIColor *RZCellBg(void);    // nền ô
UIColor *RZCellHi(void);    // nền ô đang chạm
UIColor *RZBarBg(void);     // nền ô nhập tin, bảng sticker, đầu mục
UIColor *RZBarLine(void);   // viền trên của ô nhập / bảng sticker
UIColor *RZChatBg(void);    // nền màn chat
/// Áp màu sáng / tối cho bảng + ô mặc định của UIKit (danh bạ, nhóm, thêm).
void RZStyleTable(UITableView *tv);
void RZStyleCell(UITableViewCell *c);

/// Giờ ngắn cho danh sách chat: «10:42» (hôm nay), «Hôm qua», «T2» (trong tuần), «12/11» (cũ hơn).
NSString *RZTimeShort(long long ms);
/// Giờ trong bong bóng: «10:42».
NSString *RZTimeHM(long long ms);
/// Dải ngày trong màn chat: «Hôm nay», «Hôm qua», «Thứ Hai, 12/11/2026».
NSString *RZDayTitle(long long ms);
BOOL RZSameDay(long long a, long long b);

/// Ảnh / biểu tượng tự vẽ (CoreGraphics), đệm theo tên.
@interface RZTheme : NSObject
/// Đặt giao diện chung (appearance proxy của iOS 5): thanh trên, thanh dưới, ô tìm — theo chế độ sáng / tối đã lưu.
+ (void)apply;
/// Đổi chế độ (lưu lại, xoá ảnh tự vẽ đã đệm). Sau đó gọi `apply` và dựng lại các màn.
+ (void)setDark:(BOOL)dark;
/// Biểu tượng thẻ: 0 Tin nhắn, 1 Danh bạ, 2 Nhóm, 3 Thêm.
+ (UIImage *)tabIcon:(NSInteger)index selected:(BOOL)selected;
/// Bong bóng co giãn: mình gửi / người khác gửi; `tail` = có đuôi (tin đầu của một cụm).
+ (UIImage *)bubbleOut:(BOOL)outgoing tail:(BOOL)tail;
/// Nền ô nhập tin (bo tròn, viền xám).
+ (UIImage *)inputField;
/// Nền ô chữ của thanh tìm kiếm đặt trên thanh trên (bo tròn, kính mờ nhẹ theo chế độ sáng / tối).
+ (UIImage *)searchField;
/// Ảnh 1 × 1 trong suốt (bỏ nền mặc định của UISearchBar / UITabBar).
+ (UIImage *)clearImage;
/// Biểu tượng nhỏ: «send», «sticker», «photo», «camera», «search», «compose», «chevron», «check», «check2», «clock», «warn»,
/// «mute», «pin», «group», «qr».
+ (UIImage *)icon:(NSString *)name color:(UIColor *)color size:(CGFloat)size;
/// Huy hiệu số chưa đọc (đỏ, chữ trắng).
+ (UIImage *)badge:(NSInteger)count;
/// Cỡ tệp dạng chữ («850 KB», «12,4 MB»).
+ (NSString *)sizeText:(double)bytes;
/// Thông báo ngắn nổi giữa `view`, tự tắt sau 2 giây.
+ (void)toast:(NSString *)text in:(UIView *)view;
/// Biểu tượng thư mục / tệp (theo đuôi) cho trình chọn tệp.
+ (UIImage *)folderIcon;
+ (UIImage *)fileIcon:(NSString *)ext;
@end
