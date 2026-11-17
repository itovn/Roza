#import "RZAppDelegate.h"
#import "RZBackground.h"
#import "RZChatListViewController.h"
#import "RZContactsViewController.h"
#import "RZCore.h"
#import "RZGroupsViewController.h"
#import "RZKit.h"
#import "RZLog.h"
#import "RZLoginViewController.h"
#import "RZMoreViewController.h"
#import "RZTheme.h"
#ifdef DEBUG
#import "RZDebug.h"
#endif

@interface RZAppDelegate ()
@property (nonatomic, assign) int shown;  // 0 chưa hiện gì, 1 đăng nhập, 2 các thẻ
@property (nonatomic, strong) UITabBarController *tabs;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@end

@implementation RZAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    RZLog(@"Roza mở (iOS %@)", [UIDevice currentDevice].systemVersion);
    self.bgTask = UIBackgroundTaskInvalid;
    [RZTheme apply];
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = RZBg();
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onEvent:) name:RZCoreEventNotification object:nil];
    if (![RZCore start]) {
        UIViewController *vc = [[UIViewController alloc] init];
        self.window.rootViewController = vc;
        [self.window makeKeyAndVisible];
        RZAlert(@"Không mở được dữ liệu", @"Roza không mở được thư mục dữ liệu trên máy.");
        return YES;
    }
    // Hiện màn trống trong lúc hỏi trạng thái đăng nhập (lõi trả ngay, không đụng mạng)
    UIViewController *blank = [[UIViewController alloc] init];
    blank.view.backgroundColor = RZHex(0x1E8FCF);
    self.window.rootViewController = blank;
    [self.window makeKeyAndVisible];
    [RZCore call:@"auth.state" args:nil done:^(id ok, NSDictionary *err) {
        [self showAuthorized:[[ok objectForKey:@"authorized"] boolValue]];
    }];
    // Thông báo cục bộ (tin mới khi app ở nền): iOS 5 / 6 chỉ hiện cho app đã đăng ký thông báo
    [[RZBackground shared] start];
#ifdef DEBUG
    [RZDebug start];
#endif
    UILocalNotification *ln = [opts objectForKey:UIApplicationLaunchOptionsLocalNotificationKey];
    if (ln) [self performSelector:@selector(openFromNotification:) withObject:ln afterDelay:0.8];
    return YES;
}

- (void)showAuthorized:(BOOL)authorized {
    int want = authorized ? 2 : 1;
    if (self.shown == want) return;
    self.shown = want;
    if (!authorized) {
        self.tabs = nil;
        self.window.rootViewController = [[RZLoginViewController alloc] init];
        [self fixRotation];
        return;
    }
    NSMutableArray *navs = [NSMutableArray array];
    for (UIViewController *vc in @[[[RZChatListViewController alloc] init], [[RZContactsViewController alloc] init],
                                   [[RZGroupsViewController alloc] init], [[RZMoreViewController alloc] init]]) {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.tabBarItem = vc.tabBarItem;
        [navs addObject:nav];
    }
    self.tabs = [[UITabBarController alloc] init];
    self.tabs.viewControllers = navs;
    self.window.rootViewController = self.tabs;
    [self fixRotation];
}

/// iOS 5: thay rootViewController lúc máy đang nằm ngang (iPad) thì view mới đã xoay nhưng giữ khung dọc (rộng 768 thay vì 1024 —
/// thử trên iPad 1 iOS 5.1.1, 17/11/2026) → bảo iOS xoay lại theo máy rồi đặt khung đầy cửa sổ.
- (void)fixRotation {
    [UIViewController attemptRotationToDeviceOrientation];
    UIView *v = self.window.rootViewController.view;
    UIInterfaceOrientation o = [UIApplication sharedApplication].statusBarOrientation;
    CGRect b = [UIScreen mainScreen].applicationFrame;  // tính theo dọc (iOS 5 / 6)
    if (UIInterfaceOrientationIsLandscape(o) && v.bounds.size.width < v.bounds.size.height) {
        v.bounds = CGRectMake(0, 0, b.size.height, b.size.width);
        [v setNeedsLayout];
    }
}

- (void)setDarkMode:(BOOL)dark {
    if (dark == RZDark()) return;
    NSUInteger tab = self.tabs ? self.tabs.selectedIndex : 0;
    [RZTheme setDark:dark];
    [RZTheme apply];
    self.window.backgroundColor = RZBg();
    if (self.shown == 2) {
        self.shown = 0;
        [self showAuthorized:YES];
        self.tabs.selectedIndex = tab;
    }
    RZLog(@"chế độ %@", dark ? @"tối" : @"sáng");
}

- (void)onEvent:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = RZStr([ev objectForKey:@"e"]);
    if ([e isEqualToString:@"auth.state"]) {
        BOOL auth = [[ev objectForKey:@"authorized"] boolValue];
        if (!auth && [[ev objectForKey:@"dead"] boolValue] && self.shown == 2)
            RZAlert(@"Cần đăng nhập lại", @"Phiên Zalo Web của Roza đã hết hạn hoặc bị đăng xuất từ điện thoại.");
        [self showAuthorized:auth];
    }
}

- (void)application:(UIApplication *)app didReceiveLocalNotification:(UILocalNotification *)ln {
    // iOS gọi cả khi app còn ở nền — chỉ mở chat khi người dùng chạm thông báo (app đang Inactive)
    if (app.applicationState == UIApplicationStateInactive) [self openFromNotification:ln];
}

- (void)openFromNotification:(UILocalNotification *)ln {
    NSString *thread = RZStr([ln.userInfo objectForKey:@"thread"]);
    if (!thread.length || !self.tabs) return;
    self.tabs.selectedIndex = 0;
    UINavigationController *nav = [self.tabs.viewControllers objectAtIndex:0];
    [nav popToRootViewControllerAnimated:NO];
    RZOpenChat(nav, thread, RZStr([ln.userInfo objectForKey:@"name"]), nil);
}

- (void)applicationDidEnterBackground:(UIApplication *)app {
    // Giữ kết nối ở nền (thời gian chạy thêm + socket VoIP + giữ kết nối 10 phút) → tin mới thành thông báo
    [[RZBackground shared] didEnterBackground];
}

- (void)applicationWillEnterForeground:(UIApplication *)app {
    [[RZBackground shared] willEnterForeground];
    [RZCore call:@"net.state" args:nil done:^(id ok, NSDictionary *err) {
        NSString *s = RZStr([ok objectForKey:@"state"]);
        if ([s isEqualToString:@"offline"]) [RZCore call:@"net.reconnect" args:nil done:nil];
    }];
}

- (void)application:(UIApplication *)app didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)token {
}

- (void)application:(UIApplication *)app didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
}

@end
