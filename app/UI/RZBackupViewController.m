#import "RZBackupViewController.h"
#import "RZCore.h"
#import "RZKit.h"
#import "RZTheme.h"

@interface RZBackupViewController () <UIAlertViewDelegate>
@property (nonatomic, strong) NSDictionary *state;
@property (nonatomic, assign) BOOL busy;
@property (nonatomic, copy) NSString *busyText;
@end

@implementation RZBackupViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.title = @"Sao lưu";
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

- (void)onEvent:(NSNotification *)n {
    if (![RZStr([n.userInfo objectForKey:@"e"]) isEqualToString:@"backup.progress"] || !self.busy) return;
    long long done = RZLL([n.userInfo objectForKey:@"done"]), total = RZLL([n.userInfo objectForKey:@"total"]);
    self.busyText = total > 0 ? [NSString stringWithFormat:@"Đang chép ảnh / video / tệp: %lld / %lld…", done, total] : @"Đang sao lưu…";
    [self.tableView reloadData];
}

- (void)reload {
    [RZCore call:@"backup.get" args:nil done:^(id ok, NSDictionary *err) {
        if ([ok isKindOfClass:[NSDictionary class]]) self.state = ok;
        [self.tableView reloadData];
    }];
}

- (BOOL)linked {
    return [[self.state objectForKey:@"has_token"] boolValue] && RZLL([self.state objectForKey:@"chat_id"]) != 0;
}

- (void)setBusy:(BOOL)busy text:(NSString *)text {
    self.busy = busy;
    self.busyText = text;
    [self.tableView reloadData];
}

#pragma mark - Bảng

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 2 ? 1 : (s == 1 ? 3 : 2);
}

- (NSString *)footerText:(NSInteger)s {
    if (s == 0)
        return @"Mở Telegram → @BotFather → /newbot để tạo bot riêng, chép token dán vào đây. Sau đó nhắn /start cho bot rồi bấm «Tìm chat». "
               @"Bản sao lưu gồm tin nhắn, danh bạ, nhóm — không gồm phiên đăng nhập Zalo và ảnh đã tải.";
    if (s == 1) {
        long long ms = RZLL([self.state objectForKey:@"last_ms"]);
        if (self.busy) return self.busyText;
        long long files = RZLL([self.state objectForKey:@"media_files"]);
        NSString *media = files > 0 ? [NSString stringWithFormat:@" Đã chép %lld ảnh / video / tệp (%@) — khôi phục xong, tệp nào trên Zalo đã hết hạn thì Roza tự lấy từ Telegram.",
                                                                files, [RZTheme sizeText:RZLL([self.state objectForKey:@"media_bytes"])]]
                                     : @" Bật «Sao lưu cả ảnh, video, tệp» để khôi phục được cả tệp trong chat (tệp lớn chia phần ≤ 19 MB).";
        if (ms <= 0) return [@"Chưa sao lưu lần nào." stringByAppendingString:media];
        return [[NSString stringWithFormat:@"Lần gần nhất: %@ %@ — %@ (đã nén).", RZDayTitle(ms), RZTimeHM(ms),
                                           [RZTheme sizeText:RZLL([self.state objectForKey:@"last_size"])]] stringByAppendingString:media];
    }
    return @"Lấy bản sao lưu đang ghim trong chat với bot, thay toàn bộ tin nhắn đang có trên máy này.";
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, 80)];
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
    if (ip.section == 0) {
        if (ip.row == 0) {
            c.textLabel.text = @"Bot Telegram";
            NSString *bot = RZStr([self.state objectForKey:@"bot"]);
            c.detailTextLabel.text = [[self.state objectForKey:@"has_token"] boolValue] ? [@"@" stringByAppendingString:bot ?: @""] : @"Nhập token";
        } else {
            c.textLabel.text = @"Chat sao lưu";
            NSString *chat = RZStr([self.state objectForKey:@"chat"]);
            c.detailTextLabel.text = RZLL([self.state objectForKey:@"chat_id"]) ? (chat.length ? chat : @"Đã nối") : @"Tìm chat";
        }
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.section == 1) {
        if (ip.row == 0) {
            c.textLabel.text = self.busy ? @"Đang làm…" : @"Sao lưu ngay";
            c.textLabel.textColor = [self linked] && !self.busy ? RZBlue() : RZTextGray();
        } else if (ip.row == 2) {
            c.textLabel.text = @"Sao lưu cả ảnh, video, tệp";
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [[self.state objectForKey:@"media"] boolValue];
            sw.enabled = [self linked];
            [sw addTarget:self action:@selector(mediaChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        } else {
            c.textLabel.text = @"Tự sao lưu mỗi ngày";
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [[self.state objectForKey:@"auto"] boolValue];
            sw.enabled = [self linked];
            [sw addTarget:self action:@selector(autoChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
        }
    } else {
        c.textLabel.text = @"Khôi phục từ bản mới nhất";
        c.textLabel.textColor = [self linked] && !self.busy ? RZHex(0xE5534B) : RZTextGray();
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.busy) return;
    if (ip.section == 0 && ip.row == 0) {
        UIAlertView *av = [[UIAlertView alloc] initWithTitle:@"Token bot Telegram" message:@"Dán token @BotFather gửi (dạng 123456789:AA…)"
                                                    delegate:self cancelButtonTitle:@"Huỷ" otherButtonTitles:@"Lưu", nil];
        av.alertViewStyle = UIAlertViewStylePlainTextInput;
        [av textFieldAtIndex:0].autocorrectionType = UITextAutocorrectionTypeNo;
        [av textFieldAtIndex:0].autocapitalizationType = UITextAutocapitalizationTypeNone;
        [av show];
    } else if (ip.section == 0 && ip.row == 1) {
        [self setBusy:YES text:@"Đang tìm chat…"];
        [RZCore call:@"backup.findChat" args:nil done:^(id ok, NSDictionary *err) {
            [self setBusy:NO text:nil];
            if (err) RZAlert(@"Chưa nối được", RZErrorText(err));
            else self.state = ok;
            [self.tableView reloadData];
        }];
    } else if (ip.section == 1 && ip.row == 0 && [self linked]) {
        [self setBusy:YES text:@"Đang sao lưu…"];
        [RZCore call:@"backup.run" args:nil done:^(id ok, NSDictionary *err) {
            [self setBusy:NO text:nil];
            if (err) {
                RZAlert(@"Không sao lưu được", RZErrorText(err));
                return;
            }
            self.state = [ok objectForKey:@"state"];
            [self.tableView reloadData];
            RZAlert(@"Đã sao lưu", [NSString stringWithFormat:@"%lld tin nhắn — %@, đã ghim trong chat với bot.", RZLL([ok objectForKey:@"count"]),
                                                               [RZTheme sizeText:RZLL([ok objectForKey:@"size"])]]);
        }];
    } else if (ip.section == 2 && [self linked]) {
        RZConfirm(@"Khôi phục?", @"Toàn bộ tin nhắn trên máy này sẽ được thay bằng bản sao lưu mới nhất.", @"Khôi phục", ^{
            [self setBusy:YES text:@"Đang khôi phục…"];
            [RZCore call:@"backup.restore" args:nil done:^(id ok, NSDictionary *err) {
                [self setBusy:NO text:nil];
                if (err) RZAlert(@"Không khôi phục được", RZErrorText(err));
                else RZAlert(@"Đã khôi phục", [NSString stringWithFormat:@"%lld tin nhắn.", RZLL([ok objectForKey:@"count"])]);
            }];
        });
    }
}

- (void)alertView:(UIAlertView *)av didDismissWithButtonIndex:(NSInteger)i {
    if (i == av.cancelButtonIndex) return;
    NSString *token = [[av textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!token.length) return;
    [self setBusy:YES text:@"Đang kiểm token…"];
    [RZCore call:@"backup.setToken" args:@{@"token": token} done:^(id ok, NSDictionary *err) {
        [self setBusy:NO text:nil];
        if (err) RZAlert(@"Token chưa đúng", RZErrorText(err));
        else self.state = ok;
        [self.tableView reloadData];
    }];
}

- (void)mediaChanged:(UISwitch *)sw {
    [RZCore call:@"backup.setMedia" args:@{@"media": @(sw.on)} done:^(id ok, NSDictionary *err) {
        if ([ok isKindOfClass:[NSDictionary class]]) self.state = ok;
        [self.tableView reloadData];
    }];
}

- (void)autoChanged:(UISwitch *)sw {
    [RZCore call:@"backup.setAuto" args:@{@"auto": @(sw.on)} done:^(id ok, NSDictionary *err) {
        if ([ok isKindOfClass:[NSDictionary class]]) self.state = ok;
    }];
}

@end
