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
