#import "RZNotifySettingsViewController.h"
#import "RZBackground.h"
#import "RZKit.h"
#import "RZTheme.h"

@implementation RZNotifySettingsViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.title = @"Thông báo";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RZStyleTable(self.tableView);
}

static NSArray *RZNotifyRows(NSInteger section) {
    if (section == 0) return @[@[@"Hiện thông báo", RZPrefNotify], @[@"Xem trước nội dung", RZPrefPreview], @[@"Âm thanh", RZPrefSound]];
    return @[@[@"Số trên biểu tượng app", RZPrefBadge]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return RZNotifyRows(s).count;
}

- (NSString *)footerText:(NSInteger)s {
    if (s == 0) return @"Chat đã tắt thông báo thì không báo (trừ khi có người nhắc @ tới anh). Tắt «Xem trước» thì thông báo chỉ ghi «Tin nhắn mới».";
    return @"Roza giữ kết nối với Zalo khi chạy nền (chế độ VoIP của iOS) để báo tin mới. Tắt hẳn app khỏi thanh đa nhiệm thì có thể không "
           @"nhận thông báo tới khi mở lại. Lần đầu cài cần khởi động lại SpringBoard để Roza có mục trong Cài đặt → Thông báo.";
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
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    RZStyleCell(c);
    NSArray *row = [RZNotifyRows(ip.section) objectAtIndex:ip.row];
    c.textLabel.text = [row objectAtIndex:0];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = RZPref([row objectAtIndex:1]);
    sw.tag = ip.section * 10 + ip.row;
    [sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
}

- (void)toggled:(UISwitch *)sw {
    NSArray *row = [RZNotifyRows(sw.tag / 10) objectAtIndex:sw.tag % 10];
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:[row objectAtIndex:1]];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (!RZPref(RZPrefBadge)) [UIApplication sharedApplication].applicationIconBadgeNumber = 0;
}

@end
