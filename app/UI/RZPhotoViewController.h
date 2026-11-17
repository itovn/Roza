#import <UIKit/UIKit.h>

/// Xem ảnh toàn màn hình: phóng to (UIScrollView), chạm để đóng, giữ để lưu vào Thư viện ảnh.
@interface RZPhotoViewController : UIViewController
- (instancetype)initWithURL:(NSString *)url thumb:(NSString *)thumb;
@end
