#import <UIKit/UIKit.h>

/// Mở video / tệp trong tin: lõi tải về (TLS của lõi — iOS 6 không tự tải được CDN Zalo), rồi phát video bằng
/// MPMoviePlayerViewController (H.264 MP4) hoặc xem tệp bằng QLPreviewController (pdf, doc, xls, ảnh, txt…; iOS 4+).
/// `status(chữ)` báo đang tải (nil = xong).
@interface RZOpener : NSObject
+ (void)openVideo:(NSDictionary *)msg from:(UIViewController *)vc status:(void (^)(NSString *text))status;
+ (void)openFile:(NSDictionary *)msg from:(UIViewController *)vc status:(void (^)(NSString *text))status;
@end
