#import "RZDebug.h"
#import "RZAppDelegate.h"
#import "RZChatViewController.h"
#import "RZCore.h"
#import "RZKit.h"
#import "RZLog.h"
#import "RZStickerPanel.h"
#import <UIKit/UIKit.h>

static NSString *const kCmdFile = @"/var/mobile/Documents/Roza-cmd.txt";

@interface RZChatViewController (Debug)
- (void)debugType:(NSString *)text;
- (void)debugSend;
- (void)debugStickers;
- (RZStickerPanel *)debugPanel;
- (void)sendMedia:(NSString *)method args:(NSDictionary *)args;
- (NSString *)debugDump;
- (void)debugUI:(NSString *)arg;
@end

@interface RZStickerPanel (Debug)
- (void)debugSearch:(NSString *)q;
- (void)debugPick:(NSInteger)i;
- (NSUInteger)debugCount;
@end

/// Tóm tắt kết quả: số phần tử / tên khoá — không ghi nội dung.
static NSString *RZSummary(id v) {
    if ([v isKindOfClass:[NSArray class]]) return [NSString stringWithFormat:@"[%lu mục]", (unsigned long)[v count]];
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in [[v allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            id x = [v objectForKey:k];
            if ([x isKindOfClass:[NSArray class]]) [parts addObject:[NSString stringWithFormat:@"%@[%lu]", k, (unsigned long)[x count]]];
            else if ([x isKindOfClass:[NSNumber class]]) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, x]];
            else [parts addObject:k];
        }
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
    }
    return v ? @"(giá trị)" : @"null";
}

@implementation RZDebug

+ (void)start {
    static NSTimer *timer;
    if (timer) return;
    timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    RZLog(@"[thử] đọc lệnh từ %@", kCmdFile);
}

+ (UITabBarController *)tabs {
    UIViewController *r = [UIApplication sharedApplication].keyWindow.rootViewController;
    if ([r isKindOfClass:[UISplitViewController class]] && ((UISplitViewController *)r).viewControllers.count)
        r = [((UISplitViewController *)r).viewControllers objectAtIndex:0];  // iPad: các thẻ ở bên trái
    return [r isKindOfClass:[UITabBarController class]] ? (UITabBarController *)r : nil;
}

/// Thanh điều hướng có màn chat: iPad = bên phải, iPhone = thẻ đang chọn.
+ (UINavigationController *)chatNav {
    return RZDetailNav() ?: [self nav];
}

+ (UINavigationController *)nav {
    UIViewController *v = [self tabs].selectedViewController;
    return [v isKindOfClass:[UINavigationController class]] ? (UINavigationController *)v : nil;
}

+ (void)poll {
    NSString *s = [NSString stringWithContentsOfFile:kCmdFile encoding:NSUTF8StringEncoding error:NULL];
    if (!s) return;
    [[NSFileManager defaultManager] removeItemAtPath:kCmdFile error:NULL];
    NSArray *lines = [s componentsSeparatedByString:@"\n"];
    NSTimeInterval delay = 0;
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) continue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self run:line];
        });
        delay += 1.2;
    }
}

+ (void)run:(NSString *)line {
    NSRange sp = [line rangeOfString:@" "];
    NSString *cmd = sp.location == NSNotFound ? line : [line substringToIndex:sp.location];
    NSString *arg = sp.location == NSNotFound ? @"" : [line substringFromIndex:sp.location + 1];
    RZLog(@"[thử] %@", cmd);
    if ([cmd isEqualToString:@"call"]) {
        NSRange sp2 = [arg rangeOfString:@" "];
        NSString *m = sp2.location == NSNotFound ? arg : [arg substringToIndex:sp2.location];
        NSDictionary *a = nil;
        if (sp2.location != NSNotFound) {
            NSData *d = [[arg substringFromIndex:sp2.location + 1] dataUsingEncoding:NSUTF8StringEncoding];
            a = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        }
        long long t = RZNowMs();
        [RZCore call:m args:a done:^(id ok, NSDictionary *err) {
            if (err) RZLog(@"[thử] %@ → lỗi %@: %@ (%lld ms)", m, [err objectForKey:@"code"], [err objectForKey:@"msg"], RZNowMs() - t);
            else if ([m hasPrefix:@"sticker"] || [m hasPrefix:@"media."]) {
                // Sticker / đường dẫn tệp đệm: không riêng tư → ghi nguyên (cắt 800 ký tự)
                NSData *d = ok ? [NSJSONSerialization dataWithJSONObject:ok options:0 error:NULL] : nil;
                NSString *js = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"null";
                if (js.length > 800) js = [js substringToIndex:800];
                RZLog(@"[thử] %@ → %@ (%lld ms)", m, js, RZNowMs() - t);
            } else RZLog(@"[thử] %@ → %@ (%lld ms)", m, RZSummary(ok), RZNowMs() - t);
        }];
    } else if ([cmd isEqualToString:@"tab"]) {
        [self tabs].selectedIndex = (NSUInteger)[arg integerValue];
    } else if ([cmd isEqualToString:@"open"]) {
        UINavigationController *nav = [self nav];
        if ([arg isEqualToString:@"cloud"]) {
            [RZCore call:@"auth.state" args:nil done:^(id ok, NSDictionary *err) {
                NSString *cloud = RZStr([[ok objectForKey:@"me"] objectForKey:@"cloud"]);
                RZLog(@"[thử] cloud %@", cloud.length ? @"có" : @"không có");
                if (cloud.length) RZOpenChat(nav, [@"u" stringByAppendingString:cloud], @"Cloud của tôi", nil);
            }];
        } else if ([arg hasPrefix:@"row "]) {
            NSInteger row = [[arg substringFromIndex:4] integerValue];
            UITableViewController *list = (UITableViewController *)[nav.viewControllers objectAtIndex:0];
            if ([list isKindOfClass:[UITableViewController class]] && row < [list.tableView numberOfRowsInSection:0]) {
                NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:0];
                [list.tableView selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
                [list tableView:list.tableView didSelectRowAtIndexPath:ip];
            }
        } else {
            RZOpenChat(nav, arg, nil, nil);
        }
    } else if ([cmd isEqualToString:@"frames"]) {
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        UIViewController *r = w.rootViewController;
        CGAffineTransform t = r.view.transform;
        RZLog(@"[thử] cửa sổ %@ | gốc %@ khung %@ bounds %@ xoay (%.0f %.0f %.0f %.0f) | thanh trạng thái %d, gốc %d, siêu view %@",
              NSStringFromCGRect(w.bounds), NSStringFromClass([r class]), NSStringFromCGRect(r.view.frame), NSStringFromCGRect(r.view.bounds),
              t.a, t.b, t.c, t.d, (int)[UIApplication sharedApplication].statusBarOrientation, (int)r.interfaceOrientation,
              NSStringFromClass([r.view.superview class]));
    } else if ([cmd isEqualToString:@"dark"]) {
        id d = [UIApplication sharedApplication].delegate;
        if ([d respondsToSelector:@selector(setDarkMode:)]) [d setDarkMode:[arg boolValue]];
    } else if ([cmd isEqualToString:@"back"]) {
        UINavigationController *d = RZDetailNav();
        if (d && d.viewControllers.count > 1) [d popViewControllerAnimated:YES];
        else [[self nav] popViewControllerAnimated:YES];
    } else if ([cmd isEqualToString:@"close"]) {
        RZCloseChat(RZOpenThread());  // iPad: về màn trống bên phải
    } else if ([cmd isEqualToString:@"orient"]) {
        // orient 1|2|3|4 (dọc, dọc ngược, ngang trái, ngang phải) — API riêng của UIDevice, chỉ có ở bản thử
        // iOS 5 cần setOrientation:animated: (setOrientation: không làm app xoay)
        UIDevice *dev = [UIDevice currentDevice];
        NSInteger o = [arg integerValue];
        BOOL anim = YES;
        SEL sel = NSSelectorFromString(@"setOrientation:animated:");
        if (![dev respondsToSelector:sel]) sel = NSSelectorFromString(@"setOrientation:");
        if ([dev respondsToSelector:sel]) {
            NSMethodSignature *sig = [dev methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.selector = sel;
            inv.target = dev;
            [inv setArgument:&o atIndex:2];
            if (sig.numberOfArguments > 3) [inv setArgument:&anim atIndex:3];
            [inv invoke];
        }
        [UIViewController attemptRotationToDeviceOrientation];
    } else {
        RZChatViewController *chat = (RZChatViewController *)[self chatNav].topViewController;
        // Màn khác đang đè lên chat (thẻ ngân hàng, nhắc hẹn…) → tìm màn chat trong ngăn
        if (![chat isKindOfClass:[RZChatViewController class]])
            for (UIViewController *v in [self chatNav].viewControllers.reverseObjectEnumerator)
                if ([v isKindOfClass:[RZChatViewController class]]) {
                    chat = (RZChatViewController *)v;
                    break;
                }
        if (![chat isKindOfClass:[RZChatViewController class]]) {
            RZLog(@"[thử] không có chat đang mở");
            return;
        }
        if ([cmd isEqualToString:@"type"]) [chat debugType:[arg stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"]];
        else if ([cmd isEqualToString:@"send"]) [chat debugSend];
        else if ([cmd isEqualToString:@"stickers"]) [chat debugStickers];
        else if ([cmd isEqualToString:@"media"]) {
            // media <lệnh> <json>: gửi tệp có sẵn trên máy vào chat đang mở (chỉ thử với Cloud của tôi)
            NSRange sp2 = [arg rangeOfString:@" "];
            NSString *m = sp2.location == NSNotFound ? arg : [arg substringToIndex:sp2.location];
            NSDictionary *a = sp2.location == NSNotFound ? @{} : [NSJSONSerialization JSONObjectWithData:[[arg substringFromIndex:sp2.location + 1] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            [chat sendMedia:m args:a ?: @{}];
        }
        else if ([cmd isEqualToString:@"stsearch"]) [[chat debugPanel] debugSearch:arg];
        else if ([cmd isEqualToString:@"stpick"]) [[chat debugPanel] debugPick:[arg integerValue]];
        else if ([cmd isEqualToString:@"stcount"]) RZLog(@"[thử] bảng sticker: %lu mục", (unsigned long)[[chat debugPanel] debugCount]);
        else if ([cmd isEqualToString:@"dump"]) RZLog(@"[thử] chat %@", [chat debugDump]);
        else if ([cmd isEqualToString:@"ui"]) [chat debugUI:arg];
        else RZLog(@"[thử] lệnh lạ: %@", cmd);
    }
}

@end
