#import <UIKit/UIKit.h>

/// Lưu ảnh / video / tệp / tin thoại của tin về máy (nhấn giữ tin → «Lưu về máy», màn xem ảnh). Như GMMediaSaver của GramMini (D25):
/// - ảnh / GIF: bản gốc lớn nhất, giữ nguyên dữ liệu (ALAssetsLibrary — GIF vẫn động, JPEG không bị nén lại) → Thư viện ảnh;
/// - video: Thư viện ảnh (iOS kiểm định dạng trước);
/// - tệp / tin thoại: chép vào Tài liệu/Roza (/var/mobile/Documents/Roza — Filza / iFile mở được), có «Mở bằng app khác…».
/// Lõi tải qua TLS của lõi (`media.fetch`) — kể cả lấy lại từ bản sao lưu Telegram khi địa chỉ Zalo đã hết hạn. Báo kết quả bằng
/// thông báo nhỏ trong `vc.view`.
@interface RZMediaSaver : NSObject
+ (BOOL)canSave:(NSDictionary *)msg;
+ (void)save:(NSDictionary *)msg from:(UIViewController *)vc;
/// Ảnh theo địa chỉ (màn xem ảnh).
+ (void)savePhotoURL:(NSString *)url from:(UIViewController *)vc;
/// Tệp: tải về rồi mở bảng «Mở bằng…» của iOS (UIDocumentInteractionController).
+ (void)openIn:(NSDictionary *)msg from:(UIViewController *)vc anchor:(UIView *)anchor;
@end
