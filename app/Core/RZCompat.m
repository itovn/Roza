// Chép từ Côn Bằng TV Legacy (app/Core/CBCompat.m), bỏ phần AVPlayerItem.
// Bù phần iOS 6 mà app dùng khi chạy trên iOS 5. Thêm lúc nạp app (+load, trước main), chỉ khi iOS thiếu — trên iOS 6 giữ
// nguyên hàm gốc của hệ thống.
//   • a[i] / d[k] (Objective-C subscripting): clang gọi objectAtIndexedSubscript: / objectForKeyedSubscript:… — có từ iOS 6;
//     Xcode thêm libarclite để bù khi dựng cho iOS 5, bộ dựng Theos trên Linux không có → tự bù ở đây.
//   • NSIndexPath item / indexPathForItem:inSection: (UIKit iOS 6) = row / indexPathForRow:inSection:.
//   • UILabel minimumScaleFactor (iOS 6) → minimumFontSize của iOS 5.
//   • Xoay màn hình: iOS 5 hỏi shouldAutorotateToInterfaceOrientation:, iOS 6 hỏi supportedInterfaceOrientations — màn nào
//     khai báo supportedInterfaceOrientations thì iOS 5 cũng theo đúng mặt nạ đó. Riêng màn trình bày đè lên (modal: trình phát, «Ai đang
//     xem?», miễn trừ) iOS 5 không theo hàm thay chung này — các màn đó tự khai báo shouldAutorotateToInterfaceOrientation:
//     (0.5.0 trên iPad 1: trình phát bị kéo về dọc); thanh điều hướng cũng tự khai báo (CBNavController).
//   • Thiếu bộ nhớ: iOS 5 gỡ view của các màn đang khuất (viewDidUnload) rồi dựng lại khi quay về — các màn của app dựng view
//     một lần trong viewDidLoad (đăng ký thông báo, tải dữ liệu…), dựng lại sẽ tải lại / đăng ký hai lần. iOS 6 không gỡ view
//     nữa → trên iOS 5 cũng giữ view cho các màn của app (ảnh bìa vẫn tự xoá khỏi bộ đệm khi thiếu bộ nhớ).
#import "RZCompat.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

BOOL RZOldIOS(void) {
    return NSFoundationVersionNumber < NSFoundationVersionNumber_iOS_6_0;
}

#pragma mark - Hàm thay

static id rz_arrayAt(NSArray *self, SEL _cmd, NSUInteger i) {
    return [self objectAtIndex:i];
}

static void rz_marraySet(NSMutableArray *self, SEL _cmd, id obj, NSUInteger i) {
    if (i == self.count) [self addObject:obj];
    else [self replaceObjectAtIndex:i withObject:obj];
}

static id rz_dictGet(NSDictionary *self, SEL _cmd, id key) {
    return [self objectForKey:key];
}

static void rz_mdictSet(NSMutableDictionary *self, SEL _cmd, id obj, id key) {
    if (obj) [self setObject:obj forKey:key];
    else [self removeObjectForKey:key];
}

static id rz_osetAt(NSOrderedSet *self, SEL _cmd, NSUInteger i) {
    return [self objectAtIndex:i];
}

static void rz_mosetSet(NSMutableOrderedSet *self, SEL _cmd, id obj, NSUInteger i) {
    if (i == self.count) [self addObject:obj];
    else [self replaceObjectAtIndex:i withObject:obj];
}

static NSInteger rz_ipItem(NSIndexPath *self, SEL _cmd) {
    return (NSInteger)[self indexAtPosition:1];
}

static NSIndexPath *rz_ipForItem(Class self, SEL _cmd, NSInteger item, NSInteger section) {
    return [NSIndexPath indexPathForRow:item inSection:section];
}

static const void *kRZScaleKey = &kRZScaleKey;

static void rz_setMinScale(UILabel *self, SEL _cmd, CGFloat f) {
    objc_setAssociatedObject(self, kRZScaleKey, @(f), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.minimumFontSize = MAX(6, floor(self.font.pointSize * f));
}

static CGFloat rz_minScale(UILabel *self, SEL _cmd) {
    return [objc_getAssociatedObject(self, kRZScaleKey) floatValue];
}

static IMP rz_origAutorotate;

static BOOL rz_autorotate(UIViewController *self, SEL _cmd, UIInterfaceOrientation o) {
    if ([self respondsToSelector:@selector(supportedInterfaceOrientations)]) {
        RZ_IOS6_BEGIN
        NSUInteger mask = [(id)self supportedInterfaceOrientations];
        RZ_IOS6_END
        return (mask & (1u << o)) != 0;
    }
    // Màn không khai báo: iPad mọi chiều, iPhone dọc (như iOS 6 với thanh điều hướng của app)
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) return YES;
    return ((BOOL (*)(id, SEL, UIInterfaceOrientation))rz_origAutorotate)(self, _cmd, o);
}

static IMP rz_origMemoryWarning;

static void rz_memoryWarning(UIViewController *self, SEL _cmd) {
    if ([NSStringFromClass([self class]) hasPrefix:@"RZ"]) return;  // màn của app: giữ view như iOS 6
    ((void (*)(id, SEL))rz_origMemoryWarning)(self, _cmd);
}

#pragma mark - Gắn

/// Thêm hàm cho lớp nếu lớp (kể cả lớp cha) chưa có. Chuỗi kiểu viết sẵn cho armv7 (NSUInteger = I, NSInteger = i,
/// CGFloat = f, BOOL = c) — app chỉ dựng armv7.
static void rz_add(Class cls, SEL sel, IMP imp, const char *types) {
    if (!cls || [cls instancesRespondToSelector:sel]) return;
    class_addMethod(cls, sel, imp, types);
}

@interface RZCompat : NSObject
@end

@implementation RZCompat

+ (void)load {
    if (!RZOldIOS()) return;
    @autoreleasepool {
        rz_add([NSArray class], @selector(objectAtIndexedSubscript:), (IMP)rz_arrayAt, "@@:I");
        rz_add([NSMutableArray class], @selector(setObject:atIndexedSubscript:), (IMP)rz_marraySet, "v@:@I");
        rz_add([NSDictionary class], @selector(objectForKeyedSubscript:), (IMP)rz_dictGet, "@@:@");
        rz_add([NSMutableDictionary class], @selector(setObject:forKeyedSubscript:), (IMP)rz_mdictSet, "v@:@@");
        rz_add([NSOrderedSet class], @selector(objectAtIndexedSubscript:), (IMP)rz_osetAt, "@@:I");
        rz_add([NSMutableOrderedSet class], @selector(setObject:atIndexedSubscript:), (IMP)rz_mosetSet, "v@:@I");

        rz_add([NSIndexPath class], @selector(item), (IMP)rz_ipItem, "i@:");
        rz_add(object_getClass([NSIndexPath class]), @selector(indexPathForItem:inSection:), (IMP)rz_ipForItem, "@#:ii");

        rz_add([UILabel class], @selector(setMinimumScaleFactor:), (IMP)rz_setMinScale, "v@:f");
        rz_add([UILabel class], @selector(minimumScaleFactor), (IMP)rz_minScale, "f@:");


        Method rot = class_getInstanceMethod([UIViewController class], @selector(shouldAutorotateToInterfaceOrientation:));
        if (rot) rz_origAutorotate = method_setImplementation(rot, (IMP)rz_autorotate);
        Method mem = class_getInstanceMethod([UIViewController class], @selector(didReceiveMemoryWarning));
        if (mem) rz_origMemoryWarning = method_setImplementation(mem, (IMP)rz_memoryWarning);
    }
}

@end
