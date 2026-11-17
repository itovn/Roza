#import <UIKit/UIKit.h>

/// Chọn ảnh / video để gửi: thư viện ảnh hoặc máy ảnh (UIImagePickerController; iPad iOS 5 / 6: thư viện bắt buộc mở trong
/// popover). Ảnh: xoay đúng chiều, thu về cạnh dài ≤ 1280 px, JPEG 0,85. Video: nén H.264 ≤ 640 px (RZVideoCompressor — lấy từ
/// GramMini), ảnh bìa (AVAssetImageGenerator), thời lượng, cỡ. Xong gọi `done(lệnh, tham số)` để màn chat gửi qua lõi
/// (`messages.sendPhoto` / `messages.sendVideo`); huỷ thì không gọi. `status(chữ)` báo tiến độ nén (nil = xong).
@interface RZAttach : NSObject
+ (BOOL)hasCamera;
+ (void)pickFrom:(UIViewController *)vc anchor:(UIView *)anchor camera:(BOOL)camera video:(BOOL)video
          status:(void (^)(NSString *text))status done:(void (^)(NSString *method, NSDictionary *args))done;
@end
