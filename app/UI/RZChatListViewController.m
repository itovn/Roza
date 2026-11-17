#import "RZChatListViewController.h"
#import "RZAppDelegate.h"
#import "RZContactsViewController.h"
#import "RZHiddenListViewController.h"
#import "RZCore.h"
#import "RZImages.h"
#import "RZKit.h"
#import "RZTheme.h"

#pragma mark - Ô

@interface RZThreadContent : UIView
@property (nonatomic, weak) RZThreadCell *cell;
@end

@implementation RZThreadCell {
    RZThreadContent *_content;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        _content = [[RZThreadContent alloc] initWithFrame:self.contentView.bounds];
        _content.cell = self;
        _content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _content.backgroundColor = RZCellBg();
        _content.contentMode = UIViewContentModeRedraw;
        [self.contentView addSubview:_content];
    }
    return self;
}

- (void)setThread:(NSDictionary *)t {
    _thread = t;
    [_content setNeedsDisplay];
}

- (void)setAvatar:(UIImage *)a {
    _avatar = a;
    [_content setNeedsDisplay];
}

- (void)setTyping:(NSString *)typing {
    _typing = [typing copy];
    [_content setNeedsDisplay];
}

- (void)setHighlighted:(BOOL)h animated:(BOOL)animated {
    [super setHighlighted:h animated:animated];
    _content.backgroundColor = h ? RZCellHi() : RZCellBg();
}

- (void)setSelected:(BOOL)s animated:(BOOL)animated {
    [super setSelected:s animated:animated];
    _content.backgroundColor = s ? RZCellHi() : RZCellBg();
}

@end

@implementation RZThreadContent

- (void)drawRect:(CGRect)rect {
    NSDictionary *t = self.cell.thread;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat av = 52, pad = 12;
    UIImage *img = self.cell.avatar;
    if (!img) img = [RZImages placeholderForName:RZStr([t objectForKey:@"name"]) key:RZStr([t objectForKey:@"key"]) size:av];
    [img drawInRect:CGRectMake(pad, (H - av) / 2, av, av)];
    BOOL pinned = [[t objectForKey:@"pinned"] boolValue];
    BOOL muted = [[t objectForKey:@"muted"] boolValue];
    NSInteger unread = [[t objectForKey:@"unread"] integerValue];
    CGFloat x = pad + av + 12;
    // Giờ
    NSString *time = RZTimeShort(RZLL([t objectForKey:@"ts"]));
    UIFont *tf = [UIFont systemFontOfSize:12];
    CGSize ts = [time sizeWithFont:tf];
    [(unread > 0 ? RZBlue() : RZTextGray()) set];
    [time drawAtPoint:CGPointMake(W - pad - ts.width, 14) withFont:tf];
    // Tên
    NSString *name = RZStr([t objectForKey:@"name"]);
    if (!name.length) name = [[t objectForKey:@"group"] boolValue] ? @"Nhóm" : @"Người dùng Zalo";
    CGFloat nameW = W - x - pad - ts.width - 8;
    CGFloat iconsW = 0;
    if ([[t objectForKey:@"group"] boolValue]) {
        [[RZTheme icon:@"group" color:RZHex(0x8E979D) size:16] drawAtPoint:CGPointMake(x, 14)];
        x += 19;
        nameW -= 19;
    }
    if (muted) iconsW += 18;
    UIFont *nf = [UIFont boldSystemFontOfSize:16];
    [RZText() set];
    CGSize ns = [name sizeWithFont:nf forWidth:nameW - iconsW lineBreakMode:4];
    [name drawAtPoint:CGPointMake(x, 11) forWidth:nameW - iconsW withFont:nf lineBreakMode:4];
    if (muted) [[RZTheme icon:@"mute" color:RZHex(0xA3ABB1) size:14] drawAtPoint:CGPointMake(x + ns.width + 4, 14)];
    // Xem trước / đang soạn
    x = pad + av + 12;
    CGFloat right = W - pad;
    if (unread > 0) {
        UIImage *b = [RZTheme badge:unread];
        if (muted) {
            [RZHex(0xB6BDC2) setFill];
            CGContextFillEllipseInRect(UIGraphicsGetCurrentContext(), CGRectMake(right - 10, 42, 10, 10));
            right -= 16;
        } else {
            [b drawAtPoint:CGPointMake(right - b.size.width, 38)];
            right -= b.size.width + 6;
        }
    } else if (pinned) {
        [[RZTheme icon:@"pin" color:RZHex(0xA3ABB1) size:14] drawAtPoint:CGPointMake(right - 14, 40)];
        right -= 20;
    }
    NSString *prev = self.cell.typing.length ? self.cell.typing : RZStr([t objectForKey:@"preview"]);
    NSString *status = RZStr([t objectForKey:@"status"]);
    if (!self.cell.typing.length && [status isEqualToString:@"failed"]) prev = [@"⚠ " stringByAppendingString:prev ?: @""];
    UIFont *pf = unread > 0 ? [UIFont boldSystemFontOfSize:14] : [UIFont systemFontOfSize:14];
    [(self.cell.typing.length ? RZBlue() : (unread > 0 ? RZText() : RZTextGray())) set];
    [prev drawAtPoint:CGPointMake(x, 37) forWidth:right - x withFont:pf lineBreakMode:4];
    // Vạch kẻ
    [RZLine() setFill];
    UIRectFill(CGRectMake(pad + av + 12, H - 0.5, W, 0.5));
}

@end

#pragma mark - Danh sách

@interface RZChatListViewController () <UISearchBarDelegate>
@property (nonatomic, strong) NSArray *threads;
@property (nonatomic, strong) NSArray *shown;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) NSMutableDictionary *typing;  // khoá → tên người đang soạn
@property (nonatomic, strong) UIView *banner;
@property (nonatomic, copy) NSString *net;
@property (nonatomic, strong) NSArray *hiddenShown;  // trò chuyện ẩn đang hiện (đã gõ đúng PIN vào ô tìm)
@end

@implementation RZChatListViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = @"Tin nhắn";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Tin nhắn" image:nil tag:0];
        [self.tabBarItem setFinishedSelectedImage:[RZTheme tabIcon:0 selected:YES] withFinishedUnselectedImage:[RZTheme tabIcon:0 selected:NO]];
        _threads = @[];
        _shown = @[];
        _typing = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 72;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    RZStyleTable(self.tableView);
    // Ô tìm kiếm nằm ngay trên thanh trên (thay chữ tiêu đề), cạnh nút tin nhắn mới — anh duyệt 17/11/2026
    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width - 60, 44)];
    self.search.placeholder = @"Tìm bạn bè, tin nhắn…";
    self.search.delegate = self;
    self.search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.search setBackgroundImage:[RZTheme clearImage]];  // bỏ nền xám của UISearchBar → lộ nền thanh trên
    [self.search setSearchFieldBackgroundImage:[RZTheme searchField] forState:UIControlStateNormal];
    // iOS 5 / 6: ô chữ là con trực tiếp. Không gán keyboardAppearance cho UISearchBar: chỉ có từ iOS 7 (UISearchBar nhận đủ
    // UITextInputTraits từ iOS 7) → iOS 6 crash «unrecognized selector» ngay lúc mở (17/11/2026); SDK 9.3 không ghi nhãn nên
    // -Werror=unguarded-availability không bắt được. Gán cho UITextField bên trong (có từ iOS 2).
    for (UIView *v in self.search.subviews)
        if ([v isKindOfClass:[UITextField class]]) {
            ((UITextField *)v).textColor = RZText();
            if (RZDark()) ((UITextField *)v).keyboardAppearance = UIKeyboardAppearanceAlert;
        }
    self.navigationItem.titleView = self.search;
    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Tin nhắn" style:UIBarButtonItemStyleBordered target:nil action:nil];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[RZTheme icon:@"compose" color:[UIColor whiteColor] size:20]
                                                                              style:UIBarButtonItemStylePlain target:self action:@selector(compose)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onEvent:) name:RZCoreEventNotification object:nil];
    // iPad: tô hàng của cuộc trò chuyện đang mở bên phải
    self.clearsSelectionOnViewWillAppear = !RZPad();
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(markOpenThread) name:RZOpenThreadChanged object:nil];
    [self reload];
    [RZCore call:@"net.state" args:nil done:^(id ok, NSDictionary *err) {
        [self setNetState:RZStr([ok objectForKey:@"state"])];
    }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (RZPad()) {
        [self markOpenThread];
        return;
    }
    NSIndexPath *sel = self.tableView.indexPathForSelectedRow;
    if (sel) [self.tableView deselectRowAtIndexPath:sel animated:animated];
}

/// iPad: chọn (tô) hàng của chat đang mở bên phải, bỏ chọn nếu không có.
- (void)markOpenThread {
    if (!RZPad() || !self.isViewLoaded) return;
    NSString *open = RZOpenThread();
    NSIndexPath *want = nil;
    for (NSUInteger i = 0; open && i < self.shown.count; i++)
        if ([RZStr([[self.shown objectAtIndex:i] objectForKey:@"key"]) isEqualToString:open]) {
            want = [NSIndexPath indexPathForRow:i inSection:0];
            break;
        }
    NSIndexPath *cur = self.tableView.indexPathForSelectedRow;
    if (cur && ![cur isEqual:want]) [self.tableView deselectRowAtIndexPath:cur animated:NO];
    if (want && ![cur isEqual:want]) [self.tableView selectRowAtIndexPath:want animated:NO scrollPosition:UITableViewScrollPositionNone];
}

- (void)reload {
    [RZCore call:@"threads.list" args:@{@"limit": @300} done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        self.threads = ok;
        [self applyFilter];
    }];
}

- (void)applyFilter {
    NSString *q = RZFold(self.search.text);
    if (self.hiddenShown && q.length == 4) {
        self.shown = self.hiddenShown;
        [self.tableView reloadData];
        [self markOpenThread];
        return;
    }
    self.hiddenShown = nil;
    if (!q.length) {
        self.shown = self.threads;
    } else {
        NSMutableArray *a = [NSMutableArray array];
        for (NSDictionary *t in self.threads)
            if ([RZFold(RZStr([t objectForKey:@"name"])) rangeOfString:q].location != NSNotFound) [a addObject:t];
        self.shown = a;
    }
    [self.tableView reloadData];
    [self markOpenThread];
    [self updateBadge];
}

- (void)updateBadge {
    NSInteger n = 0;
    for (NSDictionary *t in self.threads)
        if (![[t objectForKey:@"muted"] boolValue] && [[t objectForKey:@"unread"] integerValue] > 0) n++;
    self.navigationController.tabBarItem.badgeValue = n > 0 ? [NSString stringWithFormat:@"%ld", (long)n] : nil;
    [UIApplication sharedApplication].applicationIconBadgeNumber = n;
}

- (void)setNetState:(NSString *)s {
    self.net = s;
    // Không còn chữ tiêu đề → trạng thái kết nối hiện ở dòng gợi ý của ô tìm kiếm
    if ([s isEqualToString:@"connecting"]) self.search.placeholder = @"Đang kết nối…";
    else if ([s isEqualToString:@"offline"]) self.search.placeholder = @"Chờ mạng…";
    else self.search.placeholder = @"Tìm bạn bè, tin nhắn…";
    [self showDuplicateBanner:[s isEqualToString:@"duplicate"]];
}

/// Zalo chỉ cho một Zalo Web mở cùng lúc: mở chat.zalo.me ở máy khác thì kết nối của Roza bị đóng.
- (void)showDuplicateBanner:(BOOL)show {
    if (!show) {
        if (self.banner) {
            self.tableView.tableHeaderView = nil;
            self.banner = nil;
        }
        return;
    }
    if (self.banner) return;
    CGFloat w = self.view.bounds.size.width;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 64)];
    UIView *b = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 64)];
    b.backgroundColor = RZHex(RZDark() ? 0x3A3220 : 0xFFF4D6);
    b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *l = RZLabel(13, NO, RZHex(RZDark() ? 0xE8D7A0 : 0x6B5300));
    l.numberOfLines = 2;
    l.lineBreakMode = RZBreakWord;
    l.text = @"Zalo Web đang mở ở nơi khác nên Roza tạm ngắt kết nối.";
    l.frame = CGRectMake(12, 8, w - 120, 48);
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [b addSubview:l];
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    [btn setTitle:@"Dùng ở đây" forState:UIControlStateNormal];
    btn.frame = CGRectMake(w - 104, 15, 94, 34);
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [btn addTarget:self action:@selector(takeOver) forControlEvents:UIControlEventTouchUpInside];
    [b addSubview:btn];
    [box addSubview:b];
    self.banner = box;
    self.tableView.tableHeaderView = box;
}

- (void)takeOver {
    [RZCore call:@"net.reconnect" args:nil done:nil];
}

- (void)compose {
    RZContactsViewController *c = [[RZContactsViewController alloc] initPicker];
    [self.navigationController pushViewController:c animated:YES];
}

- (void)onEvent:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = RZStr([ev objectForKey:@"e"]);
    if ([e isEqualToString:@"threads.changed"] || [e isEqualToString:@"auth.state"]) {
        [self reload];
    } else if ([e isEqualToString:@"threads.upsert"]) {
        NSMutableArray *all = [self.threads mutableCopy];
        for (NSDictionary *t in [ev objectForKey:@"threads"]) {
            NSString *key = RZStr([t objectForKey:@"key"]);
            NSUInteger i = [all indexOfObjectPassingTest:^BOOL(NSDictionary *o, NSUInteger idx, BOOL *stop) {
                return [RZStr([o objectForKey:@"key"]) isEqualToString:key];
            }];
            if (i != NSNotFound) [all removeObjectAtIndex:i];
            // Chỗ mới: sau các chat ghim (trừ khi chính nó được ghim), theo giờ
            NSUInteger at = 0;
            BOOL pinned = [[t objectForKey:@"pinned"] boolValue];
            while (at < all.count) {
                NSDictionary *o = [all objectAtIndex:at];
                BOOL op = [[o objectForKey:@"pinned"] boolValue];
                if (op && !pinned) {
                    at++;
                    continue;
                }
                if (op == pinned && RZLL([o objectForKey:@"ts"]) > RZLL([t objectForKey:@"ts"])) {
                    at++;
                    continue;
                }
                break;
            }
            if (RZLL([t objectForKey:@"ts"]) > 0 || pinned) [all insertObject:t atIndex:at];
        }
        self.threads = all;
        [self applyFilter];
    } else if ([e isEqualToString:@"typing"]) {
        NSString *key = RZStr([ev objectForKey:@"thread"]);
        NSString *name = RZStr([ev objectForKey:@"name"]);
        BOOL group = [key hasPrefix:@"g"];
        NSString *txt = group && name.length ? [NSString stringWithFormat:@"%@ đang soạn tin…", [[name componentsSeparatedByString:@" "] lastObject]] : @"Đang soạn tin…";
        [self.typing setObject:txt forKey:key];
        [self refreshCellForKey:key];
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(clearTyping:) object:key];
        [self performSelector:@selector(clearTyping:) withObject:key afterDelay:6];
    } else if ([e isEqualToString:@"msg.new"]) {
        NSString *key = RZStr([ev objectForKey:@"thread"]);
        if ([self.typing objectForKey:key]) [self clearTyping:key];
    } else if ([e isEqualToString:@"net.state"]) {
        [self setNetState:RZStr([ev objectForKey:@"state"])];
    } else if ([e isEqualToString:@"msg.seen"]) {
        [self reload];
    }
}

- (void)clearTyping:(NSString *)key {
    [self.typing removeObjectForKey:key];
    [self refreshCellForKey:key];
}

- (void)refreshCellForKey:(NSString *)key {
    for (RZThreadCell *c in self.tableView.visibleCells)
        if ([RZStr([c.thread objectForKey:@"key"]) isEqualToString:key]) c.typing = [self.typing objectForKey:key];
}

#pragma mark - Bảng

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.shown.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    RZThreadCell *c = (RZThreadCell *)[tv dequeueReusableCellWithIdentifier:@"t"];
    if (!c) c = [[RZThreadCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"t"];
    NSDictionary *t = [self.shown objectAtIndex:ip.row];
    NSString *url = RZStr([t objectForKey:@"avatar"]);
    c.avatar = [RZImages cached:url maxPixel:52 * [UIScreen mainScreen].scale round:YES];
    c.thread = t;
    c.typing = [self.typing objectForKey:RZStr([t objectForKey:@"key"])];
    if (!c.avatar && url.length) {
        __weak RZThreadCell *wc = c;
        [RZImages avatar:url size:52 done:^(UIImage *img) {
            if ([RZStr([wc.thread objectForKey:@"avatar"]) isEqualToString:url]) wc.avatar = img;
        }];
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *t = [self.shown objectAtIndex:ip.row];
    [self.search resignFirstResponder];
    RZOpenChat(self.navigationController, RZStr([t objectForKey:@"key"]), RZStr([t objectForKey:@"name"]), RZStr([t objectForKey:@"avatar"]));
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return YES;
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return self.hiddenShown ? @"Bỏ ẩn" : @"Ẩn";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *t = [self.shown objectAtIndex:ip.row];
    if (self.hiddenShown) {
        // Đang xem trò chuyện ẩn → vuốt = bỏ ẩn
        [RZCore call:@"hidden.set" args:@{@"thread": RZStr([t objectForKey:@"key"]) ?: @"", @"hidden": @NO} done:^(id ok, NSDictionary *err) {
            if (err) RZAlert(@"Chưa bỏ ẩn được", RZErrorText(err));
            NSMutableArray *h = [self.hiddenShown mutableCopy];
            [h removeObject:t];
            self.hiddenShown = h;
            [self applyFilter];
        }];
        return;
    }
    RZHideThread(RZStr([t objectForKey:@"key"]), ^(BOOL ok) {
        if (!ok) return;
        NSMutableArray *all = [self.threads mutableCopy];
        [all removeObject:t];
        self.threads = all;
        [self applyFilter];
    });
}

#pragma mark - Tìm

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)text {
    self.hiddenShown = nil;
    [self applyFilter];
    // Như app Zalo: gõ đúng mã PIN (4 số) vào ô tìm kiếm → hiện trò chuyện ẩn
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (t.length == 4 && [t rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
        [RZCore call:@"hidden.unlock" args:@{@"pin": t} done:^(id ok, NSDictionary *err) {
            if (err || ![ok isKindOfClass:[NSArray class]] || ![self.search.text isEqualToString:text]) return;
            self.hiddenShown = ok;
            [self applyFilter];
        }];
    }
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)sb {
    [sb setShowsCancelButton:YES animated:YES];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)sb {
    sb.text = @"";
    [sb setShowsCancelButton:NO animated:YES];
    [sb resignFirstResponder];
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv {
    [self.search resignFirstResponder];
}

@end
