#import "RZCore.h"
#import "RZLog.h"
#import <UIKit/UIKit.h>
#include <string.h>

// core/crates/rz-ffi/src/lib.rs
typedef void (*rz_cb)(const char *json, void *ctx);
extern int rz_init(const char *config_json, rz_cb on_event, void *ctx);
extern void rz_call(const char *request_json, rz_cb on_result, void *ctx);

NSString *const RZCoreEventNotification = @"RZCoreEvent";

typedef void (^RZDone)(id ok, NSDictionary *err);

static NSString *RZJSONString(id obj) {
    NSData *d = obj ? [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL] : nil;
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

static id RZParse(const char *json) {
    if (!json) return nil;
    NSData *d = [NSData dataWithBytes:json length:strlen(json)];
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
}

NSString *RZStr(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return nil;
}

long long RZLL(id v) {
    if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) return [v longLongValue];
    return 0;
}

NSString *RZCut(NSString *s, NSUInteger max) {
    if (s.length <= max) return s;
    // Ký tự (ghép) chứa đơn vị thứ `max`: bắt đầu đúng ở `max` → cắt tại đó; vắt qua mốc → lùi về trước nó
    NSUInteger end = [s rangeOfComposedCharacterSequenceAtIndex:max].location;
    return [RZValidUTF16([s substringToIndex:end]) stringByAppendingString:@"…"];
}

NSString *RZValidUTF16(NSString *s) {
    if (!s.length || [s UTF8String]) return s;
    NSUInteger n = s.length;
    unichar *buf = malloc(n * sizeof(unichar));
    if (!buf) return @"";
    [s getCharacters:buf range:NSMakeRange(0, n)];
    for (NSUInteger i = 0; i < n; i++) {
        if (CFStringIsSurrogateHighCharacter(buf[i]) && i + 1 < n && CFStringIsSurrogateLowCharacter(buf[i + 1])) {
            i++;
            continue;
        }
        if (CFStringIsSurrogateHighCharacter(buf[i]) || CFStringIsSurrogateLowCharacter(buf[i])) buf[i] = 0xFFFD;
    }
    NSString *r = [[NSString alloc] initWithCharacters:buf length:n];
    free(buf);
    return r;
}

NSString *RZCacheDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/Roza"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return dir;
}

// Luồng của lõi; chuỗi chỉ dùng được trong lúc gọi → phân tích ngay rồi chuyển về luồng chính.
static void RZOnEvent(const char *json, void *ctx) {
    NSDictionary *ev = RZParse(json);
    if (![ev isKindOfClass:[NSDictionary class]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:RZCoreEventNotification object:nil userInfo:ev];
    });
}

static void RZOnResult(const char *json, void *ctx) {
    NSDictionary *r = RZParse(json);
    NSArray *h = (__bridge_transfer NSArray *)ctx;  // @[done, tên lệnh, lúc gọi]
    dispatch_async(dispatch_get_main_queue(), ^{
        RZDone done = [h objectAtIndex:0];
        long long ms = RZNowMs() - [[h objectAtIndex:2] longLongValue];
        id err = [r isKindOfClass:[NSDictionary class]] ? [r objectForKey:@"err"] : @{@"code": @"BAD_JSON", @"msg": @"Lõi trả kết quả không đọc được"};
        if ([err isKindOfClass:[NSDictionary class]]) {
            RZLog(@"[lõi] %@ lỗi %@ sau %lld ms", [h objectAtIndex:1], [err objectForKey:@"code"], ms);
            done(nil, err);
        } else {
            if (ms > 1500) RZLog(@"[lõi] %@ chậm: %lld ms", [h objectAtIndex:1], ms);
            id ok = [r objectForKey:@"ok"];
            done(ok == [NSNull null] ? nil : ok, nil);
        }
    });
}

NSString *RZErrorText(NSDictionary *err) {
    NSString *msg = [err objectForKey:@"msg"];
    return [msg isKindOfClass:[NSString class]] && msg.length ? msg : @"Có lỗi.";
}

@implementation RZCore

+ (BOOL)start {
    static int result = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *cfg = @{@"data_dir": RZDataDir(), @"cache_dir": RZCacheDir()};
        long long t = RZNowMs();
        result = rz_init(RZJSONString(cfg).UTF8String, RZOnEvent, NULL);
        RZLog(@"[lõi] rz_init → %d sau %lld ms", result, RZNowMs() - t);
    });
    return result == 0;
}

+ (void)call:(NSString *)method args:(NSDictionary *)args done:(void (^)(id, NSDictionary *))done {
    NSArray *h = @[done ? [done copy] : [^(id ok, NSDictionary *err) {} copy], method, @(RZNowMs())];
    NSDictionary *req = @{@"m": method, @"a": args ?: @{}};
    rz_call(RZJSONString(req).UTF8String, RZOnResult, (__bridge_retained void *)h);
}

@end
