// RZNotify — chạy trong SpringBoard. Xem Makefile / docs/DECISIONS.md D18.
// SpringBoard iOS 5 / 6 lập danh sách app được có mục «Thông báo» từ app bên thứ ba đã đăng ký push / dùng thông báo cục bộ
// (-[SBRemoteNotificationServer _allPushRegisteredThirdPartyBundleIDs], -[SBPushStore allLocalNotificationEnabledBundleIDs],
// -[SBPushStore allNotificationEnabledBundleIDs]). Móc các hàm đó (tra lúc chạy — thiếu hàm nào thì bỏ qua) để thêm Roza.
// Không đổi quyền: người dùng vẫn cho / không cho phép như mọi app, chỉnh trong Cài đặt → Thông báo.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *const kBundle = @"vn.roza.app";

static void rz_log(NSString *s) {
    NSLog(@"RZNotify: %@", s);
    NSString *path = @"/var/mobile/Library/Roza/rznotify.log";
    NSString *line = [NSString stringWithFormat:@"%.0f %@\n", [[NSDate date] timeIntervalSince1970], s];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static id rz_add(id r) {
    if ([r isKindOfClass:[NSSet class]]) return [r containsObject:kBundle] ? r : [r setByAddingObject:kBundle];
    if ([r isKindOfClass:[NSArray class]]) return [r containsObject:kBundle] ? r : [r arrayByAddingObject:kBundle];
    return r;
}

static void rz_hook(const char *cls, NSString *selName) {
    Class c = objc_getClass(cls);
    SEL sel = NSSelectorFromString(selName);
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;
    if (!m) return;
    IMP orig = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^id(id me) {
        id r = ((id (*)(id, SEL))orig)(me, sel);
        return rz_add(r);
    });
    method_setImplementation(m, repl);
    rz_log([NSString stringWithFormat:@"đã móc -[%s %@]", cls, selName]);
}

__attribute__((constructor)) static void rz_init_notify(void) {
    if (!objc_getClass("SpringBoard")) return;
    @autoreleasepool {
        for (NSString *sel in @[@"_allPushRegisteredThirdPartyBundleIDs", @"allLocalNotificationEnabledBundleIDs",
                                @"allNotificationEnabledBundleIDs"]) {
            rz_hook("SBRemoteNotificationServer", sel);
            rz_hook("SBPushStore", sel);
        }
    }
}
