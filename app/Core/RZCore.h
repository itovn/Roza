#import <Foundation/Foundation.h>

/// Lõi Rust (core/crates/rz-ffi → librz_ffi.a). Lệnh dạng «nhóm.lệnh» + tham số JSON — xem docs/FFI.md.
@interface RZCore : NSObject
/// Mở lõi một lần lúc mở app (thư mục dữ liệu RZDataDir(), bộ đệm ~/Library/Caches/Roza).
+ (BOOL)start;
/// Gọi lệnh chạy nền; done(ok, err) trên luồng chính. err: @{code, msg} hoặc nil.
+ (void)call:(NSString *)method args:(NSDictionary *)args done:(void (^)(id ok, NSDictionary *err))done;
@end

/// Sự kiện lõi đẩy lên (tin mới, đã xem, trạng thái mạng / đăng nhập…): userInfo = @{@"e": tên, …}. Phát trên luồng chính.
extern NSString *const RZCoreEventNotification;

/// Câu báo lỗi để hiện cho người dùng.
NSString *RZErrorText(NSDictionary *err);
/// Thư mục bộ đệm (ảnh, tệp): ~/Library/Caches/Roza.
NSString *RZCacheDir(void);
/// Giá trị JSON: NSNull → nil; kiểu sai → nil.
NSString *RZStr(id v);
long long RZLL(id v);
/// Cắt chữ còn tối đa `max` đơn vị UTF-16 + «…», không cắt giữa một ký tự ghép (emoji = 2 đơn vị, chữ có dấu tổ hợp…).
/// Nửa emoji làm `UTF8String` trả về NULL — SpringBoard iOS 6 sập (vào safe mode) khi lưu thông báo có chữ như vậy (D23).
NSString *RZCut(NSString *s, NSUInteger max);
/// Chữ đổi được sang UTF-8: thay nửa cặp surrogate còn sót bằng U+FFFD (chữ hợp lệ thì trả lại nguyên).
NSString *RZValidUTF16(NSString *s);
