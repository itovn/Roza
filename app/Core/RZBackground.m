#import "RZBackground.h"
#import "RZCore.h"
#import "RZLog.h"
#import "RZExtras.h"
#import <CFNetwork/CFNetwork.h>
#include <fcntl.h>

NSString *const RZPrefNotify = @"notify.on", *const RZPrefPreview = @"notify.preview", *const RZPrefSound = @"notify.sound",
                *const RZPrefBadge = @"notify.badge";

BOOL RZPref(NSString *key) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : YES;
}

/// Cặp CFStream bọc một socket của lõi (không tự đóng socket — lõi đóng).
@interface RZVoipSocket : NSObject {
@public
    CFReadStreamRef r;
    CFWriteStreamRef w;
}
@end

@implementation RZVoipSocket
- (void)dealloc {
    if (r) {
        CFReadStreamSetClient(r, kCFStreamEventNone, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(r, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFReadStreamClose(r);
        CFRelease(r);
    }
    if (w) {
        CFWriteStreamClose(w);
        CFRelease(w);
    }
}
@end

@interface RZBackground ()
- (void)rearm:(int)fd;
@end

static void RZVoipReadable(CFReadStreamRef stream, CFStreamEventType type, void *info) {
    // Không đọc ở đây (lõi đọc socket bằng tokio). CFStream chỉ báo «có dữ liệu» một lần rồi chờ chính nó đọc → bọc lại socket bằng
    // cặp CFStream mới (sau khi lõi đọc hết) để luôn có bộ theo dõi VoIP đang chờ — iOS đánh thức app qua đó (GramMini D17).
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) RZLog(@"socket VoIP: có dữ liệu (app ở nền)");
    [[RZBackground shared] rearm:(int)(intptr_t)info];
}

@implementation RZBackground {
    NSMutableDictionary *_sockets;  // fd → RZVoipSocket
    NSMutableSet *_rearming;
    UIBackgroundTaskIdentifier _task;
}

+ (instancetype)shared {
    static RZBackground *b;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        b = [[RZBackground alloc] init];
    });
    return b;
}

- (void)start {
    _sockets = [NSMutableDictionary dictionary];
    _rearming = [NSMutableSet set];
    _task = UIBackgroundTaskInvalid;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(event:) name:RZCoreEventNotification object:nil];
    // iOS 5 / 6 chỉ hiện thông báo của app đã «đăng ký thông báo» (có mục trong Cài đặt → Thông báo); lần đầu iOS hỏi quyền.
    // Mã thiết bị APNs nhận về không dùng (thông báo là UILocalNotification do app tự phát).
    [[UIApplication sharedApplication] registerForRemoteNotificationTypes:UIRemoteNotificationTypeAlert | UIRemoteNotificationTypeBadge |
                                                                          UIRemoteNotificationTypeSound];
}

#pragma mark Socket VoIP

- (void)rearm:(int)fd {
    NSNumber *key = @(fd);
    if ([_rearming containsObject:key]) return;
    [_rearming addObject:key];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self->_rearming removeObject:key];
        if ([self->_sockets objectForKey:key]) [self adoptSocket:fd quiet:YES];
        // App bị đánh thức ở nền: hỏi lõi ngay (lõi đang đọc tin về → thông báo)
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground)
            [RZCore call:@"net.check" args:nil done:nil];
    });
}

- (void)adoptSocket:(int)fd quiet:(BOOL)quiet {
    NSNumber *key = @(fd);
    [_sockets removeObjectForKey:key];  // fd dùng lại = socket cũ đã đóng
    for (NSNumber *k in _sockets.allKeys)
        if (fcntl(k.intValue, F_GETFD) == -1) [_sockets removeObjectForKey:k];
    if (fcntl(fd, F_GETFD) == -1) return;
    RZVoipSocket *s = [[RZVoipSocket alloc] init];
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, fd, &s->r, &s->w);
    if (!s->r || !s->w) {
        RZLog(@"socket VoIP: không bọc được fd %d", fd);
        return;
    }
    CFReadStreamSetProperty(s->r, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
    CFWriteStreamSetProperty(s->w, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanFalse);
    BOOL voip = CFReadStreamSetProperty(s->r, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP) &&
                CFWriteStreamSetProperty(s->w, kCFStreamNetworkServiceType, kCFStreamNetworkServiceTypeVoIP);
    CFStreamClientContext ctx = {0, (void *)(intptr_t)fd, NULL, NULL, NULL};
    CFReadStreamSetClient(s->r, kCFStreamEventHasBytesAvailable, RZVoipReadable, &ctx);
    CFReadStreamScheduleWithRunLoop(s->r, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    BOOL open = CFReadStreamOpen(s->r) && CFWriteStreamOpen(s->w);
    [_sockets setObject:s forKey:key];
    if (!quiet || !voip || !open)
        RZLog(@"socket VoIP: fd %d %@%@", fd, voip ? @"đã đánh dấu" : @"KHÔNG đánh dấu được", open ? @"" : @", mở lỗi");
}

#pragma mark Nền

- (void)didEnterBackground {
    UIApplication *app = [UIApplication sharedApplication];
    if (_task == UIBackgroundTaskInvalid) {
        _task = [app beginBackgroundTaskWithExpirationHandler:^{
            RZLog(@"hết thời gian chạy nền — app sẽ bị treo (socket VoIP đánh thức khi có tin)");
            [app endBackgroundTask:self->_task];
            self->_task = UIBackgroundTaskInvalid;
        }];
    }
    BOOL ka = [app setKeepAliveTimeout:600 handler:^{
        // iOS cho ~10 giây: ping máy chủ (kết nối chết thì lõi nối lại, lấy bù tin đã lỡ → thông báo)
        RZLog(@"giữ kết nối (10 phút một lần)");
        [RZCore call:@"net.check" args:nil done:nil];
    }];
    if (!ka) RZLog(@"setKeepAliveTimeout lỗi (thiếu UIBackgroundModes voip?)");
}

- (void)willEnterForeground {
    UIApplication *app = [UIApplication sharedApplication];
    if (_task != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:_task];
        _task = UIBackgroundTaskInvalid;
    }
    // Xoá thông báo cũ trong Trung tâm thông báo — nhưng giữ thông báo nhắc hẹn đã hẹn giờ (cancelAll xoá cả chúng)
    NSMutableArray *keep = [NSMutableArray array];
    for (UILocalNotification *ln in app.scheduledLocalNotifications)
        if ([ln.userInfo objectForKey:@"reminder"]) [keep addObject:ln];
    [app cancelAllLocalNotifications];
    for (UILocalNotification *ln in keep) [app scheduleLocalNotification:ln];
    [RZCore call:@"net.check" args:nil done:nil];
}

#pragma mark Tin mới

- (void)event:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = RZStr([ev objectForKey:@"e"]);
    if ([e isEqualToString:@"net.socket"]) {
        [self adoptSocket:(int)RZLL([ev objectForKey:@"fd"]) quiet:NO];
        return;
    }
    if ([e isEqualToString:@"msg.new"]) {
        // Nhắc hẹn (mình hoặc người khác tạo, kể cả từ điện thoại) → hẹn thông báo trên máy đúng giờ
        NSDictionary *m = [ev objectForKey:@"msg"];
        if ([RZStr([m objectForKey:@"kind"]) isEqualToString:@"reminder"]) {
            NSDictionary *r = [m objectForKey:@"media"];
            if (RZStr([r objectForKey:@"id"]).length) RZScheduleReminder(r, RZStr([ev objectForKey:@"thread"]), nil);
        }
        return;
    }
    if (![e isEqualToString:@"notify"]) return;
    // Chỉ khi app ở nền thật — app «không hoạt động» vì đang có hộp hệ thống thì iOS giao thông báo ngay cho app ở trạng thái
    // Inactive, trông như người dùng vừa chạm vào → mở nhầm chat (GramMini D17)
    UIApplication *app = [UIApplication sharedApplication];
    if (app.applicationState != UIApplicationStateBackground) return;
    [self notifyFor:ev];
}

- (void)notifyFor:(NSDictionary *)ev {
    UIApplication *app = [UIApplication sharedApplication];
    long long unread = RZLL([ev objectForKey:@"unread_total"]);
    if (RZPref(RZPrefBadge)) app.applicationIconBadgeNumber = (NSInteger)unread;
    if (!RZPref(RZPrefNotify)) return;
    if ([[ev objectForKey:@"muted"] boolValue] && ![[ev objectForKey:@"mentioned"] boolValue]) return;
    long long ts = RZLL([ev objectForKey:@"ts"]);
    if (ts > 0 && [[NSDate date] timeIntervalSince1970] * 1000 - ts > 6 * 3600 * 1000.0) return;  // tin cũ lấy bù
    BOOL group = [[ev objectForKey:@"group"] boolValue];
    NSString *chat = RZStr([ev objectForKey:@"name"]);
    if (!chat.length) chat = group ? @"Nhóm" : @"Roza";
    NSString *sender = RZStr([ev objectForKey:@"sender"]);
    NSString *title = group && sender.length && ![sender isEqualToString:chat] ? [NSString stringWithFormat:@"%@ @ %@", sender, chat] : chat;
    NSString *body = RZPref(RZPrefPreview) ? RZStr([ev objectForKey:@"text"]) : @"Tin nhắn mới";
    if ([[ev objectForKey:@"secret"] boolValue]) {
        title = @"Roza";
        body = @"Bạn có tin nhắn mới";
    }
    if (!body.length) body = @"Tin nhắn mới";
    if (body.length > 180) body = [[body substringToIndex:180] stringByAppendingString:@"…"];
    UILocalNotification *ln = [[UILocalNotification alloc] init];
    ln.alertBody = [NSString stringWithFormat:@"%@: %@", title, body];
    ln.alertAction = @"Xem";
    ln.userInfo = @{@"thread": RZStr([ev objectForKey:@"thread"]) ?: @"", @"name": chat};
    if (RZPref(RZPrefSound)) ln.soundName = UILocalNotificationDefaultSoundName;
    if (RZPref(RZPrefBadge)) ln.applicationIconBadgeNumber = (NSInteger)unread;
    [app presentLocalNotificationNow:ln];
    RZLog(@"thông báo tin mới (%@)", group ? @"nhóm" : @"riêng");
}

@end
