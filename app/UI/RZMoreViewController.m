#import "RZMoreViewController.h"
#import "RZAppDelegate.h"
#import "RZBackupViewController.h"
#import "RZSyncViewController.h"
#import "RZNotifySettingsViewController.h"
#import "RZHiddenListViewController.h"
#import "RZExtras.h"
#import "RZCore.h"
#import "RZImages.h"
#import "RZKit.h"
#import "RZTheme.h"

@interface RZMoreViewController ()
@property (nonatomic, strong) NSDictionary *me;
@property (nonatomic, copy) NSString *net;
@property (nonatomic, assign) long long cacheBytes;
@property (nonatomic, strong) UIImage *avatar;
@end

@implementation RZMoreViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.title = @"Thêm";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Thêm" image:nil tag:3];
        [self.tabBarItem setFinishedSelectedImage:[RZTheme tabIcon:3 selected:YES] withFinishedUnselectedImage:[RZTheme tabIcon:3 selected:NO]];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RZStyleTable(self.tableView);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onEvent:) name:RZCoreEventNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [RZCore call:@"auth.state" args:nil done:^(id ok, NSDictionary *err) {
        self.me = [ok objectForKey:@"me"];
        [self loadAvatar];
        [self.tableView reloadData];
    }];
    [RZCore call:@"net.state" args:nil done:^(id ok, NSDictionary *err) {
        self.net = RZStr([ok objectForKey:@"state"]);
        [self.tableView reloadData];
    }];
    [RZCore call:@"cache.usage" args:nil done:^(id ok, NSDictionary *err) {
        self.cacheBytes = RZLL([ok objectForKey:@"bytes"]);
        [self.tableView reloadData];
    }];
}

- (void)loadAvatar {
    NSString *url = RZStr([self.me objectForKey:@"avatar"]);
    if (!url.length) return;
    [RZImages avatar:url size:56 done:^(UIImage *img) {
        self.avatar = img;
        [self.tableView reloadData];
    }];
}

- (void)onEvent:(NSNotification *)n {
    NSString *e = RZStr([n.userInfo objectForKey:@"e"]);
    if ([e isEqualToString:@"net.state"]) {
        self.net = RZStr([n.userInfo objectForKey:@"state"]);
        [self.tableView reloadData];
    } else if ([e isEqualToString:@"auth.state"]) {
        self.me = [n.userInfo objectForKey:@"me"];
        [self loadAvatar];
        [self.tableView reloadData];
    }
}

- (NSString *)netText {
    NSDictionary *m = @{@"online": @"Đã kết nối", @"connecting": @"Đang kết nối…", @"offline": @"Chờ mạng…",
                        @"duplicate": @"Zalo Web đang mở ở nơi khác", @"idle": @"Chưa đăng nhập"};
    return [m objectForKey:self.net ?: @""] ?: @"—";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 1 ? 4 : (s == 2 ? 5 : 1);
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 ? 72 : 44;
}

- (NSString *)footerText:(NSInteger)s {
    if (s != 2) return nil;
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [NSString stringWithFormat:@"Roza %@ — ứng dụng không chính thức, đăng nhập như Zalo Web. Không phải sản phẩm của Zalo / VNG.", v];
}

/// Chân mục tự vẽ: chân mặc định của iOS 5 / 6 có bóng chữ trắng — lệch với chế độ tối.
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    NSString *t = [self footerText:s];
    if (!t) return nil;
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, 60)];
    UILabel *l = RZLabel(13, NO, RZTextGray());
    l.numberOfLines = 0;
    l.lineBreakMode = RZBreakWord;
    l.textAlignment = RZAlignCenter;
    l.text = t;
    l.frame = CGRectMake(20, 6, tv.bounds.size.width - 40, 50);
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [v addSubview:l];
    return v;
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return [self footerText:s] ? 64 : 10;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c;
    if (ip.section == 0) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        RZStyleCell(c);
        NSString *name = RZStr([self.me objectForKey:@"name"]);
        c.textLabel.text = name.length ? name : @"Tài khoản Zalo";
        c.textLabel.font = [UIFont boldSystemFontOfSize:18];
        NSString *phone = RZStr([self.me objectForKey:@"phone"]);
        c.detailTextLabel.text = phone.length ? phone : [@"ID " stringByAppendingString:RZStr([self.me objectForKey:@"uid"]) ?: @""];
        c.imageView.image = self.avatar ?: [RZImages placeholderForName:name ?: @"?" key:RZStr([self.me objectForKey:@"uid"]) ?: @"" size:56];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    RZStyleCell(c);
    if (ip.section == 1) {
        if (ip.row == 0) {
            c.textLabel.text = @"Kết nối";
            c.detailTextLabel.text = [self netText];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 1) {
            c.textLabel.text = @"Bộ nhớ đệm (ảnh)";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%.1f MB", self.cacheBytes / 1048576.0];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (ip.row == 3) {
            c.textLabel.text = @"Thông báo";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            c.textLabel.text = @"Chế độ tối";
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = RZDark();
            [sw addTarget:self action:@selector(darkChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        }
    } else if (ip.section == 2) {
        NSArray *names = @[@"Đồng bộ tin nhắn", @"Sao lưu (Telegram)", @"Trò chuyện ẩn", @"Tin nhắn nhanh", @"Giới thiệu Roza"];
        c.textLabel.text = [names objectAtIndex:ip.row];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.textLabel.text = @"Đăng xuất";
        c.textLabel.textColor = RZHex(0xE5534B);
        c.textLabel.textAlignment = RZAlignCenter;
    }
    return c;
}

- (void)darkChanged:(UISwitch *)sw {
    BOOL on = sw.on;
    // Để công tắc chạy xong hiệu ứng rồi mới dựng lại các màn
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [(RZAppDelegate *)[UIApplication sharedApplication].delegate setDarkMode:on];
    });
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1 && ip.row == 0) {
        RZSheet *s = [[RZSheet alloc] initWithTitle:[self netText]];
        [s add:@"Kết nối lại" action:^{
            [RZCore call:@"net.reconnect" args:nil done:nil];
        }];
        [s showIn:self.tabBarController.view];
    } else if (ip.section == 1 && ip.row == 1) {
        RZConfirm(@"Xoá bộ nhớ đệm?", @"Ảnh đã tải sẽ được tải lại khi cần. Tin nhắn không bị xoá.", @"Xoá", ^{
            [RZCore call:@"cache.clear" args:nil done:^(id ok, NSDictionary *err) {
                self.cacheBytes = RZLL([ok objectForKey:@"bytes"]);
                [RZImages purge];
                [self.tableView reloadData];
            }];
        });
    } else if (ip.section == 1 && ip.row == 3) {
        [self.navigationController pushViewController:[[RZNotifySettingsViewController alloc] init] animated:YES];
    } else if (ip.section == 2 && ip.row == 0) {
        [self.navigationController pushViewController:[[RZSyncViewController alloc] init] animated:YES];
    } else if (ip.section == 2 && ip.row == 1) {
        [self.navigationController pushViewController:[[RZBackupViewController alloc] init] animated:YES];
    } else if (ip.section == 2 && ip.row == 2) {
        RZOpenHidden(self.navigationController);
    } else if (ip.section == 2 && ip.row == 3) {
        [self.navigationController pushViewController:[[RZQuickMessagesViewController alloc] init] animated:YES];
    } else if (ip.section == 2) {
        RZAlert(@"Roza",
                @"Ứng dụng nhắn tin Zalo không chính thức cho iPhone / iPad iOS 5 – 6.\n\nLõi Rust nói chuyện thẳng với máy chủ Zalo "
                @"(giao thức Zalo Web, chuyển từ thư viện zca-js — MIT). Tin nhắn chat riêng chỉ lưu trên máy này.\n\n"
                @"Roza không phải sản phẩm của Zalo / VNG.");
    } else if (ip.section == 3) {
        RZConfirm(@"Đăng xuất?", @"Tin nhắn đã lưu trên máy này sẽ bị xoá.", @"Đăng xuất", ^{
            [RZCore call:@"auth.logout" args:nil done:nil];
        });
    }
}

@end
