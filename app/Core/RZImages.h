#import <UIKit/UIKit.h>

/// Ảnh: lõi tải về đĩa (`media.fetch` — HTTPS của CDN Zalo iOS 6 không tự mở được), giải mã + thu nhỏ đúng cỡ bằng ImageIO ở
/// hàng nền ưu tiên thấp (A4 một nhân: giải mã nhiều ảnh cùng lúc làm treo luồng chính), bộ đệm RAM nhỏ. done() luôn trên luồng
/// chính; ảnh đã có trong bộ đệm thì gọi ngay. Lỗi thì không gọi done.
@interface RZImages : NSObject
/// Ảnh đại diện tròn cỡ `size` điểm.
+ (void)avatar:(NSString *)url size:(CGFloat)size done:(void (^)(UIImage *img))done;
/// Ảnh trong tin / sticker: maxPixel = cạnh dài nhất (pixel). kind: thumb | photo | sticker.
+ (void)image:(NSString *)url kind:(NSString *)kind maxPixel:(CGFloat)maxPixel done:(void (^)(UIImage *img))done;
+ (UIImage *)cached:(NSString *)url maxPixel:(CGFloat)maxPixel round:(BOOL)round;
/// Ảnh đại diện mặc định: vòng màu theo mã + chữ cái đầu của tên (như app Zalo khi chưa có ảnh).
+ (UIImage *)placeholderForName:(NSString *)name key:(NSString *)key size:(CGFloat)size;
+ (void)purge;
@end
