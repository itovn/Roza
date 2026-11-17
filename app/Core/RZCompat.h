#import <Foundation/Foundation.h>

/// Máy đang chạy iOS 5 (app dựng cho iOS 5.0 trở lên: hàm / lớp của iOS 6 phải hỏi trước khi dùng — xem CBCompat.m)
BOOL RZOldIOS(void);

/// Bao đoạn mã dùng API iOS 6 đã hỏi lúc chạy (NSClassFromString / respondsToSelector): app dựng với
/// -Werror=unguarded-availability nên chỗ nào dùng API mới hơn iOS 5.0 mà không bao là lỗi lúc dựng.
#define RZ_IOS6_BEGIN _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wunguarded-availability\"")
#define RZ_IOS6_END _Pragma("clang diagnostic pop")
