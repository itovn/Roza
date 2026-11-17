#import "RZSyncViewController.h"
#import "RZCore.h"
#import "RZKit.h"
#import "RZTheme.h"

@interface RZSyncViewController ()
@property (nonatomic, strong) NSDictionary *state;
@property (nonatomic, copy) NSString *groupsText;  // tiến độ tải lịch sử nhóm
@property (nonatomic, assign) BOOL syncing, loadingGroups;
@end

@implementation RZSyncViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.title = @"Đồng bộ tin nhắn";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RZStyleTable(self.tableView);
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onEvent:) name:RZCoreEventNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reload {
    [RZCore call:@"sync.state" args:nil done:^(id ok, NSDictionary *err) {
        if ([ok isKindOfClass:[NSDictionary class]]) self.state = ok;
        [self.tableView reloadData];
    }];
}

- (void)onEvent:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = RZStr([ev objectForKey:@"e"]);
    if ([e isEqualToString:@"sync.progress"]) {
        self.groupsText = [NSString stringWithFormat:@"Đang tải lịch sử nhóm %lld / %lld — %lld tin mới…", RZLL([ev objectForKey:@"done"]),
                                                     RZLL([ev objectForKey:@"total"]), RZLL([ev objectForKey:@"msgs"])];
        [self.tableView reloadData];
    } else if ([e isEqualToString:@"sync.done"] || [e isEqualToString:@"net.state"]) {
        if ([e isEqualToString:@"sync.done"]) self.syncing = NO;
        [self reload];
    }
}

- (NSString *)netText {
    NSString *net = RZStr([self.state objectForKey:@"net"]);
    if ([net isEqualToString:@"online"]) return @"Đang bật";
    if ([net isEqualToString:@"duplicate"]) return @"Zalo Web mở ở nơi khác";
    if ([net isEqualToString:@"connecting"]) return @"Đang kết nối…";
    return @"Chờ mạng…";
}

- (NSString *)whenText:(long long)ms {
    return ms > 0 ? [NSString stringWithFormat:@"%@ %@", RZDayTitle(ms), RZTimeHM(ms)] : @"chưa có";
}

#pragma mark - Bảng

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return 1;
}

- (NSString *)footerText:(NSInteger)s {
    switch (s) {
        case 0:
            return @"Tin anh gửi / nhận ở điện thoại hoặc Zalo PC tự hiện trên Roza khi Roza đang kết nối. Đọc hoặc trả lời một chat ở máy "
                   @"khác thì Roza cũng bỏ số chưa đọc của chat đó.";
        case 1:
            return self.syncing ? @"Đang hỏi máy chủ Zalo…"
                                : [NSString stringWithFormat:@"Hỏi máy chủ Zalo các tin gần đây và tin bị lỡ lúc Roza tắt / mất mạng. Lần gần nhất: %@.",
                                                             [self whenText:RZLL([self.state objectForKey:@"last_ms"])]];
        case 2:
            if (self.loadingGroups && self.groupsText) return self.groupsText;
            return [NSString stringWithFormat:@"Tải tối đa 300 tin gần nhất của mỗi nhóm từ máy chủ Zalo. Lần gần nhất: %@.",
                                              [self whenText:RZLL([self.state objectForKey:@"groups_ms"])]];
        default:
            return @"Lịch sử chat riêng cũ (trước khi đăng nhập Roza) chỉ nằm trên điện thoại: Zalo chưa cho Zalo Web tải về, nên Roza chưa "
                   @"lấy được. Muốn giữ tin trên Roza khi đổi máy, dùng Thêm → Sao lưu (Telegram).";
    }
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, 60)];
    UILabel *l = RZLabel(13, NO, RZTextGray());
    l.numberOfLines = 0;
    l.lineBreakMode = RZBreakWord;
    l.text = [self footerText:s];
    CGSize ts = [l.text sizeWithFont:l.font constrainedToSize:CGSizeMake(tv.bounds.size.width - 40, 400) lineBreakMode:RZBreakWord];
    l.frame = CGRectMake(20, 6, tv.bounds.size.width - 40, ts.height);
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [v addSubview:l];
    return v;
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    CGSize ts = [[self footerText:s] sizeWithFont:[UIFont systemFontOfSize:13] constrainedToSize:CGSizeMake(tv.bounds.size.width - 40, 400)
                                     lineBreakMode:RZBreakWord];
    return ts.height + 16;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    RZStyleCell(c);
    switch (ip.section) {
        case 0:
            c.textLabel.text = @"Đồng bộ trực tiếp";
            c.detailTextLabel.text = [self netText];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        case 1:
            c.textLabel.text = self.syncing ? @"Đang đồng bộ…" : @"Lấy lại tin bị lỡ";
            c.textLabel.textColor = self.syncing ? RZTextGray() : RZBlue();
            break;
        case 2:
            c.textLabel.text = self.loadingGroups ? @"Đang tải…" : @"Tải lịch sử tất cả nhóm";
            c.textLabel.textColor = self.loadingGroups ? RZTextGray() : RZBlue();
            break;
        default:
            c.textLabel.text = @"Tin nhắn trên máy";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%lld tin · %lld chat", RZLL([self.state objectForKey:@"msgs"]),
                                                                RZLL([self.state objectForKey:@"threads"])];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1 && !self.syncing) {
        self.syncing = YES;
        [self.tableView reloadData];
        [RZCore call:@"sync.now" args:nil done:^(id ok, NSDictionary *err) {
            if (err) {
                self.syncing = NO;
                RZAlert(@"Chưa đồng bộ được", RZErrorText(err));
            }
            // Kết quả về qua sự kiện sync.done; máy chủ không có gì thì 10 giây sau thôi chờ
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self.syncing = NO;
                [self reload];
            });
            [self.tableView reloadData];
        }];
    } else if (ip.section == 2 && !self.loadingGroups) {
        self.loadingGroups = YES;
        self.groupsText = nil;
        [self.tableView reloadData];
        [RZCore call:@"sync.groups" args:@{@"max": @300} done:^(id ok, NSDictionary *err) {
            self.loadingGroups = NO;
            if (err) {
                RZAlert(@"Chưa tải được", RZErrorText(err));
            } else {
                // Từng nhóm: bao nhiêu tin, hay vì sao máy chủ không cho
                NSMutableString *t = [NSMutableString stringWithFormat:@"%lld tin mới.\n", RZLL([ok objectForKey:@"msgs"])];
                for (NSDictionary *d in [ok objectForKey:@"details"]) {
                    NSString *name = RZStr([d objectForKey:@"name"]);
                    if (!name.length) name = @"Nhóm";
                    long long got = RZLL([d objectForKey:@"got"]), fresh = RZLL([d objectForKey:@"new"]);
                    NSString *why;
                    if (got > 0) why = fresh > 0 ? [NSString stringWithFormat:@"%lld tin (%lld mới)", got, fresh] : [NSString stringWithFormat:@"%lld tin (đã có đủ)", got];
                    else if ([[d objectForKey:@"filtered"] boolValue] && [[d objectForKey:@"allow"] isKindOfClass:[NSNumber class]] && ![[d objectForKey:@"allow"] boolValue])
                        why = @"nhóm không cho thành viên mới xem tin cũ";
                    else if ([[d objectForKey:@"filtered"] boolValue]) why = @"máy chủ Zalo không trả lịch sử (nhóm chưa có tin, hoặc Zalo hạn chế Zalo Web)";
                    else why = @"chưa có tin";
                    [t appendFormat:@"\n• %@: %@", name, why];
                }
                RZAlert(@"Lịch sử nhóm", t);
            }
            [self reload];
        }];
    }
}

@end
