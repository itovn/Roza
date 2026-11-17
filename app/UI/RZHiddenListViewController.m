#import "RZHiddenListViewController.h"
#import "RZChatListViewController.h"
#import "RZCore.h"
#import "RZImages.h"
#import "RZKit.h"
#import "RZTheme.h"

void RZHideThread(NSString *thread, void (^done)(BOOL ok)) {
    void (^hide)(void) = ^{
        [RZCore call:@"hidden.set" args:@{@"thread": thread ?: @"", @"hidden": @YES} done:^(id ok, NSDictionary *err) {
            if (err) RZAlert(@"Chưa ẩn được", RZErrorText(err));
            if (done) done(err == nil);
        }];
    };
    [RZCore call:@"hidden.state" args:nil done:^(id ok, NSDictionary *err) {
        if ([[ok objectForKey:@"has_pin"] boolValue]) {
            hide();
            return;
        }
        // Chưa có PIN (cả trên điện thoại): đặt PIN mới, nhập hai lần
        RZAskPin(@"Đặt mã PIN cho trò chuyện ẩn", @"4 chữ số — dùng chung với Zalo trên điện thoại", ^(NSString *p1) {
            RZAskPin(@"Nhập lại mã PIN", nil, ^(NSString *p2) {
                if (![p1 isEqualToString:p2]) {
                    RZAlert(@"Hai lần nhập không khớp", @"Thử lại.");
                    if (done) done(NO);
                    return;
                }
                [RZCore call:@"hidden.setPin" args:@{@"pin": p1} done:^(id ok2, NSDictionary *err2) {
                    if (err2) {
                        RZAlert(@"Chưa đặt được mã PIN", RZErrorText(err2));
                        if (done) done(NO);
                    } else {
                        hide();
                    }
                }];
            });
        });
    }];
}

void RZOpenHidden(UINavigationController *nav) {
    [RZCore call:@"hidden.state" args:nil done:^(id ok, NSDictionary *err) {
        if (![[ok objectForKey:@"has_pin"] boolValue]) {
            RZAlert(@"Chưa có trò chuyện ẩn", @"Vuốt sang trái trên một trò chuyện trong danh sách → «Ẩn» để ẩn (lần đầu đặt mã PIN).");
            return;
        }
        RZAskPin(@"Trò chuyện ẩn", @"Nhập mã PIN", ^(NSString *pin) {
            [RZCore call:@"hidden.unlock" args:@{@"pin": pin} done:^(id list, NSDictionary *err2) {
                if (err2) {
                    RZAlert(@"Mã PIN không đúng", nil);
                    return;
                }
                [nav pushViewController:[[RZHiddenListViewController alloc] initWithThreads:list] animated:YES];
            }];
        });
    }];
}

@interface RZHiddenListViewController ()
@property (nonatomic, strong) NSMutableArray *threads;
@end

@implementation RZHiddenListViewController

- (instancetype)initWithThreads:(NSArray *)threads {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = @"Trò chuyện ẩn";
        self.hidesBottomBarWhenPushed = YES;
        _threads = [([threads isKindOfClass:[NSArray class]] ? threads : @[]) mutableCopy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 72;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    RZStyleTable(self.tableView);
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.threads.count;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return self.threads.count ? nil : @"Không có trò chuyện ẩn.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    RZThreadCell *c = (RZThreadCell *)[tv dequeueReusableCellWithIdentifier:@"h"];
    if (!c) c = [[RZThreadCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"h"];
    NSDictionary *t = [self.threads objectAtIndex:ip.row];
    NSString *url = RZStr([t objectForKey:@"avatar"]);
    c.avatar = [RZImages cached:url maxPixel:52 * [UIScreen mainScreen].scale round:YES];
    c.thread = t;
    if (!c.avatar && url.length) {
        __weak RZThreadCell *wc = c;
        [RZImages avatar:url size:52 done:^(UIImage *img) {
            if ([RZStr([wc.thread objectForKey:@"avatar"]) isEqualToString:url]) wc.avatar = img;
        }];
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *t = [self.threads objectAtIndex:ip.row];
    [tv deselectRowAtIndexPath:ip animated:YES];
    RZOpenChat(self.navigationController, RZStr([t objectForKey:@"key"]), RZStr([t objectForKey:@"name"]), RZStr([t objectForKey:@"avatar"]));
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"Bỏ ẩn";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *t = [self.threads objectAtIndex:ip.row];
    [RZCore call:@"hidden.set" args:@{@"thread": RZStr([t objectForKey:@"key"]) ?: @"", @"hidden": @NO} done:^(id ok, NSDictionary *err) {
        if (err) {
            RZAlert(@"Chưa bỏ ẩn được", RZErrorText(err));
            return;
        }
        NSUInteger i = [self.threads indexOfObject:t];
        if (i == NSNotFound) return;
        [self.threads removeObjectAtIndex:i];
        [self.tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:i inSection:0]] withRowAnimation:UITableViewRowAnimationFade];
    }];
}

@end
