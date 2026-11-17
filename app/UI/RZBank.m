#import "RZCore.h"
#import "RZExtras.h"
#import "RZImages.h"
#import "RZKit.h"
#import "RZTheme.h"

#pragma mark - Thẻ mã VietQR

static void RZDrawText(NSString *t, CGRect r, UIFont *f, UIColor *c) {
    if (!t.length) return;
    [c set];
    [t drawInRect:r withFont:f lineBreakMode:RZBreakWord alignment:RZAlignCenter];
}

static CGFloat RZTextH(NSString *t, UIFont *f, CGFloat w) {
    if (!t.length) return 0;
    return ceilf([t sizeWithFont:f constrainedToSize:CGSizeMake(w, 400) lineBreakMode:RZBreakWord].height);
}

UIImage *RZVietQRCard(NSDictionary *qr, NSDictionary *info) {
    NSInteger n = (NSInteger)RZLL([qr objectForKey:@"size"]);
    NSString *bits = RZStr([qr objectForKey:@"bits"]);
    if (n < 21 || (NSInteger)bits.length < n * n) return nil;
    const CGFloat W = 300, pad = 18, tw = W - pad * 2;
    NSString *bank = RZStr([info objectForKey:@"bank"]);
    NSString *number = RZStr([info objectForKey:@"number"]);
    NSString *holder = RZStr([info objectForKey:@"holder"]);
    long long amount = RZLL([info objectForKey:@"amount"]);
    NSString *note = RZStr([info objectForKey:@"note"]);
    UIFont *fBank = [UIFont boldSystemFontOfSize:15], *fNum = [UIFont boldSystemFontOfSize:21], *fHolder = [UIFont systemFontOfSize:14];
    UIFont *fAmount = [UIFont boldSystemFontOfSize:19], *fNote = [UIFont systemFontOfSize:13], *fFoot = [UIFont systemFontOfSize:11];
    NSString *amountText = amount > 0 ? [NSString stringWithFormat:@"%@ đ", RZMoney(amount)] : nil;
    NSString *noteText = note.length ? [NSString stringWithFormat:@"Nội dung: %@", note] : nil;
    NSString *foot = amount > 0 ? @"Quét bằng app ngân hàng bất kỳ để chuyển đúng số tiền" : @"Quét bằng app ngân hàng bất kỳ để chuyển khoản";
    CGFloat qrSide = 216;
    CGFloat y0 = 54 + 16;
    CGFloat h = y0 + qrSide + 14 + RZTextH(bank, fBank, tw) + 4 + RZTextH(number, fNum, tw) + 2 + RZTextH(holder, fHolder, tw);
    if (amountText) h += 10 + RZTextH(amountText, fAmount, tw);
    if (noteText) h += 4 + RZTextH(noteText, fNote, tw);
    h += 16 + RZTextH(foot, fFoot, tw) + 14;
    CGSize size = CGSizeMake(W, ceilf(h));
    UIGraphicsBeginImageContextWithOptions(size, YES, 2);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] set];
    CGContextFillRect(ctx, CGRectMake(0, 0, size.width, size.height));
    // Đầu thẻ
    [RZHex(0x1E5BA8) set];
    CGContextFillRect(ctx, CGRectMake(0, 0, W, 54));
    RZDrawText(@"Mã QR chuyển khoản", CGRectMake(pad, 9, tw, 22), [UIFont boldSystemFontOfSize:17], [UIColor whiteColor]);
    RZDrawText(@"VietQR · Napas 247", CGRectMake(pad, 31, tw, 16), [UIFont systemFontOfSize:12], [UIColor colorWithWhite:1 alpha:0.85]);
    // Mã QR (chừa lề trắng 4 ô), ô vuông thẳng theo điểm ảnh ×2
    NSInteger total = n + 8;
    CGFloat cell = floorf(qrSide * 2 / total) / 2;
    CGFloat side = cell * total;
    CGFloat ox = floorf((W - side) / 2) + cell * 4, oy = y0 + floorf((qrSide - side) / 2) + cell * 4;
    [[UIColor blackColor] set];
    const char *b = [bits UTF8String];
    for (NSInteger r = 0; r < n; r++)
        for (NSInteger c = 0; c < n; c++)
            if (b[r * n + c] == '1') CGContextFillRect(ctx, CGRectMake(ox + c * cell, oy + r * cell, cell, cell));
    // Chữ
    CGFloat y = y0 + qrSide + 14;
    CGFloat hh = RZTextH(bank, fBank, tw);
    RZDrawText(bank, CGRectMake(pad, y, tw, hh), fBank, RZHex(0x2F3E50));
    y += hh + 4;
    hh = RZTextH(number, fNum, tw);
    RZDrawText(number, CGRectMake(pad, y, tw, hh), fNum, RZHex(0x111111));
    y += hh + 2;
    hh = RZTextH(holder, fHolder, tw);
    RZDrawText(holder, CGRectMake(pad, y, tw, hh), fHolder, RZHex(0x4C566C));
    y += hh;
    if (amountText) {
        y += 10;
        hh = RZTextH(amountText, fAmount, tw);
        RZDrawText(amountText, CGRectMake(pad, y, tw, hh), fAmount, RZHex(0xD0342C));
        y += hh;
    }
    if (noteText) {
        y += 4;
        hh = RZTextH(noteText, fNote, tw);
        RZDrawText(noteText, CGRectMake(pad, y, tw, hh), fNote, RZHex(0x5F6F80));
        y += hh;
    }
    y += 16;
    [RZHex(0xE3E7EB) set];
    CGContextFillRect(ctx, CGRectMake(pad, y - 8, tw, 1));
    RZDrawText(foot, CGRectMake(pad, y, tw, RZTextH(foot, fFoot, tw)), fFoot, RZHex(0x8E979D));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

#pragma mark - Chọn ngân hàng

@interface RZBankPickerViewController () <UISearchBarDelegate>
@property (nonatomic, strong) NSArray *all, *shown;
@property (nonatomic, strong) UISearchBar *search;
@end

@implementation RZBankPickerViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = @"Chọn ngân hàng";
        _all = _shown = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 54;
    RZStyleTable(self.tableView);
    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.search.placeholder = @"Tìm ngân hàng (vd. vcb, techcom)";
    self.search.delegate = self;
    self.search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableHeaderView = self.search;
    if (self.navigationController.viewControllers.count == 1)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
                                                                                              action:@selector(close)];
    [RZCore call:@"bank.list" args:nil done:^(id ok, NSDictionary *err) {
        if (err) {
            RZAlert(@"Chưa lấy được danh sách ngân hàng", RZErrorText(err));
            return;
        }
        self.all = [ok isKindOfClass:[NSArray class]] ? ok : @[];
        [self filter];
    }];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)filter {
    NSString *q = RZFold(self.search.text);
    if (!q.length) {
        self.shown = self.all;
    } else {
        NSMutableArray *a = [NSMutableArray array];
        for (NSDictionary *b in self.all) {
            NSString *hay = RZFold([NSString stringWithFormat:@"%@ %@ %@ %@", RZStr([b objectForKey:@"name"]), RZStr([b objectForKey:@"full"]),
                                                             RZStr([b objectForKey:@"key"]), RZStr([b objectForKey:@"bin"])]);
            if ([hay rangeOfString:q].location != NSNotFound) [a addObject:b];
        }
        self.shown = a;
    }
    [self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)t {
    [self filter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"b"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"b"];
        RZStyleCell(c);
    }
    NSDictionary *b = [self.shown objectAtIndex:ip.row];
    c.textLabel.text = RZStr([b objectForKey:@"name"]);
    c.detailTextLabel.text = RZStr([b objectForKey:@"full"]);
    NSString *logo = RZStr([b objectForKey:@"logo"]);
    // Ô ảnh cỡ cố định (logo về sau mới có) để chữ không xô lệch
    static UIImage *blank;
    if (!blank) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(36, 36), NO, 0);
        blank = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    CGFloat px = 36 * [UIScreen mainScreen].scale;
    c.imageView.image = [RZImages cached:logo maxPixel:px round:NO] ?: blank;
    if (logo.length && c.imageView.image == blank) {
        __weak UITableViewCell *wc = c;
        [RZImages image:logo kind:@"thumb" maxPixel:px done:^(UIImage *im) {
            NSIndexPath *now = [tv indexPathForCell:wc];
            if (im && now && now.row < (NSInteger)self.shown.count &&
                [RZStr([[self.shown objectAtIndex:now.row] objectForKey:@"logo"]) isEqualToString:logo]) {
                wc.imageView.image = im;
                [wc setNeedsLayout];
            }
        }];
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *b = [self.shown objectAtIndex:ip.row];
    void (^pick)(NSDictionary *) = self.onPick;
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
        if (pick) pick(b);
    } else {
        [self dismissViewControllerAnimated:YES completion:^{
            if (pick) pick(b);
        }];
    }
}

@end

#pragma mark - Gửi tài khoản / mã QR chuyển khoản

@interface RZBankFormViewController () <UITextFieldDelegate>
@property (nonatomic, copy) NSString *thread;
@property (nonatomic, assign) BOOL qr;
@property (nonatomic, strong) NSArray *saved;  // tài khoản đã lưu trong Zalo
@property (nonatomic, strong) NSDictionary *bank;
@property (nonatomic, strong) UITextField *number, *holder, *amount, *note;
@property (nonatomic, strong) UISwitch *save;
@property (nonatomic, strong) UITableViewCell *bankCell, *numberCell, *holderCell, *amountCell, *noteCell, *saveCell;
@property (nonatomic, weak) UIViewController *presenter;
@end

@implementation RZBankFormViewController

- (instancetype)initWithThread:(NSString *)thread qr:(BOOL)qr {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _thread = [thread copy];
        _qr = qr;
        _saved = @[];
        self.title = qr ? @"Mã QR chuyển khoản" : @"Gửi tài khoản ngân hàng";
    }
    return self;
}

- (UITextField *)fieldWithPlaceholder:(NSString *)ph keyboard:(UIKeyboardType)kb caps:(UITextAutocapitalizationType)caps {
    UITextField *f = [[UITextField alloc] initWithFrame:CGRectZero];
    f.placeholder = ph;
    f.keyboardType = kb;
    f.autocapitalizationType = caps;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.textColor = RZText();
    f.font = [UIFont systemFontOfSize:16];
    f.textAlignment = RZAlignRight;
    f.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    f.delegate = self;
    if (RZDark()) f.keyboardAppearance = UIKeyboardAppearanceAlert;
    return f;
}

- (UITableViewCell *)fieldCell:(NSString *)label field:(UITextField *)f {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    RZStyleCell(c);
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.textLabel.text = label;
    f.frame = CGRectMake(130, 6, c.contentView.bounds.size.width - 140, 32);
    f.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [c.contentView addSubview:f];
    return c;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RZStyleTable(self.tableView);
    self.presenter = self.navigationController.presentingViewController;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
                                                                                          action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Gửi" style:UIBarButtonItemStyleDone target:self
                                                                             action:@selector(send)];
    self.bankCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    RZStyleCell(self.bankCell);
    self.bankCell.textLabel.text = @"Ngân hàng";
    self.bankCell.detailTextLabel.text = @"Chọn";
    self.bankCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    self.number = [self fieldWithPlaceholder:@"Số tài khoản" keyboard:UIKeyboardTypeNumbersAndPunctuation caps:UITextAutocapitalizationTypeAllCharacters];
    self.numberCell = [self fieldCell:@"Số tài khoản" field:self.number];
    self.holder = [self fieldWithPlaceholder:@"Tên chủ tài khoản" keyboard:UIKeyboardTypeDefault caps:UITextAutocapitalizationTypeAllCharacters];
    self.holderCell = [self fieldCell:@"Chủ tài khoản" field:self.holder];
    self.amount = [self fieldWithPlaceholder:@"Không bắt buộc" keyboard:UIKeyboardTypeNumberPad caps:UITextAutocapitalizationTypeNone];
    self.amountCell = [self fieldCell:@"Số tiền (đ)" field:self.amount];
    [self.amount addTarget:self action:@selector(amountChanged) forControlEvents:UIControlEventEditingChanged];
    self.note = [self fieldWithPlaceholder:@"Không bắt buộc" keyboard:UIKeyboardTypeDefault caps:UITextAutocapitalizationTypeSentences];
    self.noteCell = [self fieldCell:@"Nội dung" field:self.note];
    self.saveCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    RZStyleCell(self.saveCell);
    self.saveCell.selectionStyle = UITableViewCellSelectionStyleNone;
    self.saveCell.textLabel.text = @"Lưu vào Zalo của tôi";
    self.save = [[UISwitch alloc] init];
    self.save.on = YES;
    self.saveCell.accessoryView = self.save;
    [RZCore call:@"bank.accounts" args:nil done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]] || ![ok count]) return;
        self.saved = ok;
        [self.tableView reloadData];
        // Có tài khoản mặc định → điền sẵn (gửi tài khoản của mình là việc thường gặp nhất)
        for (NSDictionary *a in self.saved)
            if ([[a objectForKey:@"default"] boolValue]) {
                [self fill:a];
                break;
            }
    }];
    [RZCore call:@"bank.list" args:nil done:nil];  // tải sẵn danh sách ngân hàng
}

- (void)close {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)amountChanged {
    // Hiện số tiền có dấu chấm ngăn nghìn
    NSString *digits = [[self.amount.text componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]]
        componentsJoinedByString:@""];
    if (digits.length > 12) digits = [digits substringToIndex:12];
    self.amount.text = digits.length ? RZMoney([digits longLongValue]) : @"";
}

- (long long)amountValue {
    NSString *digits = [[self.amount.text componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]]
        componentsJoinedByString:@""];
    return [digits longLongValue];
}

- (void)fill:(NSDictionary *)a {
    NSString *bankName = RZStr([a objectForKey:@"bank"]);
    long long bin = RZLL([a objectForKey:@"bin"]);
    self.bank = @{@"bin": @(bin), @"name": bankName.length ? bankName : [NSString stringWithFormat:@"BIN %lld", bin]};
    // Tên ngắn theo danh sách ngân hàng
    [RZCore call:@"bank.list" args:nil done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        for (NSDictionary *b in ok)
            if (RZLL([b objectForKey:@"bin"]) == bin) {
                self.bank = b;
                self.bankCell.detailTextLabel.text = RZStr([b objectForKey:@"name"]);
                [self.bankCell setNeedsLayout];
            }
    }];
    self.bankCell.detailTextLabel.text = RZStr([self.bank objectForKey:@"name"]);
    self.number.text = RZStr([a objectForKey:@"number"]);
    self.holder.text = RZStr([a objectForKey:@"holder"]);
    self.save.on = NO;  // đã có trong Zalo
}

#pragma mark Bảng

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return self.qr ? 4 : 3;
}

// 0 tài khoản đã lưu · 1 tài khoản · 2 chuyển khoản (chỉ mã QR) · cuối: lưu
- (NSInteger)section:(NSInteger)s {
    return (!self.qr && s >= 2) ? s + 1 : s;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch ([self section:s]) {
        case 0: return self.saved.count;
        case 1: return 3;
        case 2: return 2;
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch ([self section:s]) {
        case 0: return self.saved.count ? @"Tài khoản đã lưu trong Zalo" : nil;
        case 1: return @"Tài khoản nhận tiền";
        case 2: return @"Chuyển khoản";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    NSInteger k = [self section:s];
    if (k == 2) return @"Người nhận quét mã bằng app ngân hàng bất kỳ: số tài khoản, số tiền và nội dung được điền sẵn.";
    if (k == 3) return self.qr ? @"Gửi ảnh mã QR kèm một tin nhắn ghi số tài khoản để người nhận chép được."
                               : @"Người nhận thấy thẻ tài khoản có mã QR (trên Roza và Zalo).";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch ([self section:ip.section]) {
        case 0: {
            UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"s"];
            if (!c) {
                c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"s"];
                RZStyleCell(c);
            }
            NSDictionary *a = [self.saved objectAtIndex:ip.row];
            NSString *bank = RZStr([a objectForKey:@"bank"]);
            c.textLabel.text = [NSString stringWithFormat:@"%@%@", RZStr([a objectForKey:@"number"]), [[a objectForKey:@"default"] boolValue] ? @"  · mặc định" : @""];
            c.detailTextLabel.text = bank.length ? [NSString stringWithFormat:@"%@ · %@", RZStr([a objectForKey:@"holder"]), bank] : RZStr([a objectForKey:@"holder"]);
            return c;
        }
        case 1: return ip.row == 0 ? self.bankCell : (ip.row == 1 ? self.numberCell : self.holderCell);
        case 2: return ip.row == 0 ? self.amountCell : self.noteCell;
        default: return self.saveCell;
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSInteger k = [self section:ip.section];
    if (k == 0) {
        [self fill:[self.saved objectAtIndex:ip.row]];
    } else if (k == 1 && ip.row == 0) {
        [self.view endEditing:YES];
        RZBankPickerViewController *p = [[RZBankPickerViewController alloc] init];
        __weak RZBankFormViewController *ws = self;
        p.onPick = ^(NSDictionary *b) {
            ws.bank = b;
            ws.bankCell.detailTextLabel.text = RZStr([b objectForKey:@"name"]);
            [ws.bankCell setNeedsLayout];
            [ws.number becomeFirstResponder];
        };
        [self.navigationController pushViewController:p animated:YES];
    }
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return [self section:ip.section] == 0;
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"Xoá";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *a = [self.saved objectAtIndex:ip.row];
    [RZCore call:@"bank.removeAccount" args:@{@"id": @(RZLL([a objectForKey:@"id"])), @"default": [a objectForKey:@"default"] ?: @NO}
            done:^(id ok, NSDictionary *err) {
                if (err) {
                    RZAlert(@"Chưa xoá được", RZErrorText(err));
                    return;
                }
                self.saved = [ok isKindOfClass:[NSArray class]] ? ok : @[];
                [self.tableView reloadData];
            }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)f {
    if (f == self.number) [self.holder becomeFirstResponder];
    else if (f == self.holder && self.qr) [self.amount becomeFirstResponder];
    else if (f == self.amount) [self.note becomeFirstResponder];
    else [f resignFirstResponder];
    return NO;
}

#pragma mark Gửi

#ifdef DEBUG
- (void)debugFill:(NSArray *)p {
    long long bin = [[p objectAtIndex:0] longLongValue];
    self.number.text = [p objectAtIndex:1];
    self.holder.text = p.count > 2 ? [p objectAtIndex:2] : @"";
    self.amount.text = p.count > 3 ? [p objectAtIndex:3] : @"";
    self.note.text = p.count > 4 ? [[p subarrayWithRange:NSMakeRange(4, p.count - 4)] componentsJoinedByString:@" "] : @"";
    self.save.on = NO;
    [RZCore call:@"bank.list" args:nil done:^(id ok, NSDictionary *err) {
        for (NSDictionary *b in ([ok isKindOfClass:[NSArray class]] ? ok : @[]))
            if (RZLL([b objectForKey:@"bin"]) == bin) self.bank = b;
        if (!self.bank) self.bank = @{@"bin": @(bin), @"name": @"", @"full": @""};
        self.bankCell.detailTextLabel.text = RZStr([self.bank objectForKey:@"name"]);
        [self.tableView reloadData];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self send];
        });
    }];
}
#endif

- (void)send {
    [self.view endEditing:YES];
    long long bin = RZLL([self.bank objectForKey:@"bin"]);
    NSString *number = [[self.number.text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] componentsJoinedByString:@""];
    NSString *holder = [self.holder.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    if (bin <= 0) {
        RZAlert(@"Chọn ngân hàng", nil);
        return;
    }
    if (number.length < 4) {
        RZAlert(@"Nhập số tài khoản", nil);
        return;
    }
    self.navigationItem.rightBarButtonItem.enabled = NO;
    if (self.save.on)
        [RZCore call:@"bank.addAccount" args:@{@"bin": @(bin), @"number": number, @"holder": holder} done:nil];
    if (!self.qr) {
        [RZCore call:@"bank.sendCard" args:@{@"thread": self.thread, @"bin": @(bin), @"number": number, @"holder": holder}
                done:^(id ok, NSDictionary *err) {
                    self.navigationItem.rightBarButtonItem.enabled = YES;
                    if (err) {
                        RZAlert(@"Chưa gửi được", RZErrorText(err));
                        return;
                    }
                    [self close];
                }];
        return;
    }
    long long amount = [self amountValue];
    NSString *note = [self.note.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";
    NSString *bankName = RZStr([self.bank objectForKey:@"full"]);
    if (!bankName.length) bankName = RZStr([self.bank objectForKey:@"name"]);
    [RZCore call:@"vietqr.make" args:@{@"bin": @(bin), @"number": number, @"amount": @(amount), @"note": note} done:^(id qr, NSDictionary *err) {
        if (err) {
            self.navigationItem.rightBarButtonItem.enabled = YES;
            RZAlert(@"Chưa tạo được mã QR", RZErrorText(err));
            return;
        }
        NSDictionary *info = @{@"bank": bankName, @"number": number, @"holder": holder.uppercaseString, @"amount": @(amount), @"note": note};
        UIImage *img = RZVietQRCard(qr, info);
        NSString *path = [RZCacheDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"vietqr-%lld.jpg", (long long)([[NSDate date] timeIntervalSince1970] * 1000)]];
        if (!img || ![UIImageJPEGRepresentation(img, 0.92) writeToFile:path atomically:YES]) {
            self.navigationItem.rightBarButtonItem.enabled = YES;
            RZAlert(@"Chưa tạo được ảnh mã QR", nil);
            return;
        }
        NSString *thread = self.thread;
        CGSize px = CGSizeMake(img.size.width * img.scale, img.size.height * img.scale);
        [RZCore call:@"messages.sendPhoto" args:@{@"thread": thread, @"path": path, @"w": @((int)px.width), @"h": @((int)px.height)}
                done:^(id ok, NSDictionary *err2) {
                    if (err2) RZAlert(@"Chưa gửi được ảnh mã QR", RZErrorText(err2));
                }];
        // Kèm tin chữ: người nhận chép được số tài khoản
        NSMutableString *t = [NSMutableString stringWithFormat:@"🏦 %@\nSố TK: %@", bankName, number];
        if (holder.length) [t appendFormat:@"\nChủ TK: %@", holder.uppercaseString];
        if (amount > 0) [t appendFormat:@"\nSố tiền: %@ đ", RZMoney(amount)];
        if (note.length) [t appendFormat:@"\nNội dung: %@", note];
        [RZCore call:@"messages.send" args:@{@"thread": thread, @"text": t} done:nil];
        [self close];
    }];
}

@end

#pragma mark - Xem thẻ tài khoản

@interface RZBankCardViewController ()
@property (nonatomic, strong) NSDictionary *card;
@property (nonatomic, assign) long long amount;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView *qrView;
@property (nonatomic, strong) NSArray *buttons;
@end

@implementation RZBankCardViewController

- (instancetype)initWithCard:(NSDictionary *)media {
    if ((self = [super init])) {
        _card = media;
        self.title = @"Tài khoản ngân hàng";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (UIButton *)button:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:b];
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = RZBg();
    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];
    self.qrView = [[UIImageView alloc] init];
    self.qrView.layer.cornerRadius = 10;
    self.qrView.layer.masksToBounds = YES;
    self.qrView.layer.borderColor = RZLine().CGColor;
    self.qrView.layer.borderWidth = 1;
    [self.scroll addSubview:self.qrView];
    self.buttons = @[[self button:@"Chép số tài khoản" action:@selector(copyNumber)], [self button:@"Nhập số tiền…" action:@selector(askAmount)],
                     [self button:@"Lưu ảnh mã QR vào máy" action:@selector(saveImage)]];
    [self render];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    CGFloat W = self.view.bounds.size.width;
    UIImage *img = self.qrView.image;
    CGFloat iw = MIN(300, W - 40), ih = img ? iw * img.size.height / img.size.width : iw * 1.4;
    self.qrView.frame = CGRectMake(floorf((W - iw) / 2), 16, iw, ih);
    CGFloat y = CGRectGetMaxY(self.qrView.frame) + 16;
    for (UIButton *b in self.buttons) {
        b.frame = CGRectMake(floorf((W - iw) / 2), y, iw, 44);
        y += 52;
    }
    self.scroll.contentSize = CGSizeMake(W, y + 12);
}

- (void)render {
    NSString *number = RZStr([self.card objectForKey:@"number"]);
    [RZCore call:@"vietqr.make" args:@{@"bin": @(RZLL([self.card objectForKey:@"bin"])), @"number": number, @"amount": @(self.amount), @"note": @""}
            done:^(id qr, NSDictionary *err) {
                if (err) {
                    RZAlert(@"Chưa tạo được mã QR", RZErrorText(err));
                    return;
                }
                NSDictionary *info = @{@"bank": RZStr([self.card objectForKey:@"bank"]) ?: @"", @"number": number,
                                       @"holder": RZStr([self.card objectForKey:@"holder"]) ?: @"", @"amount": @(self.amount)};
                self.qrView.image = RZVietQRCard(qr, info);
                [self.view setNeedsLayout];
            }];
}

- (void)copyNumber {
    [UIPasteboard generalPasteboard].string = RZStr([self.card objectForKey:@"number"]);
    [RZTheme toast:@"Đã chép số tài khoản" in:self.view];
}

- (void)askAmount {
    RZAskText(@"Số tiền chuyển (đ)", @"Mã QR sẽ có sẵn số tiền này.", self.amount > 0 ? [NSString stringWithFormat:@"%lld", self.amount] : @"",
              @"vd. 150000", UIKeyboardTypeNumberPad, ^(NSString *text) {
                  NSString *digits = [[text componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]]
                      componentsJoinedByString:@""];
                  self.amount = [digits longLongValue];
                  [self render];
              });
}

- (void)saveImage {
    if (!self.qrView.image) return;
    UIImageWriteToSavedPhotosAlbum(self.qrView.image, self, @selector(image:didFinishSavingWithError:contextInfo:), NULL);
}

- (void)image:(UIImage *)img didFinishSavingWithError:(NSError *)err contextInfo:(void *)ctx {
    if (err) RZAlert(@"Chưa lưu được ảnh", @"Cho phép Roza truy cập Ảnh trong Cài đặt → Quyền riêng tư → Ảnh.");
    else [RZTheme toast:@"Đã lưu vào Ảnh" in:self.view];
}

@end
