#import "RZContactsViewController.h"
#import "RZAppDelegate.h"
#import "RZCore.h"
#import "RZImages.h"
#import "RZKit.h"
#import "RZTheme.h"

@interface RZContactsViewController () <UISearchBarDelegate, UIAlertViewDelegate>
@property (nonatomic, assign) BOOL picker;
@property (nonatomic, copy) void (^onPick)(NSDictionary *user);
@property (nonatomic, strong) NSArray *all;
@property (nonatomic, strong) NSArray *sections;  // @[@{title, rows}]
@property (nonatomic, strong) UISearchBar *search;
@end

@implementation RZContactsViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = @"Danh bạ";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Danh bạ" image:nil tag:1];
        [self.tabBarItem setFinishedSelectedImage:[RZTheme tabIcon:1 selected:YES] withFinishedUnselectedImage:[RZTheme tabIcon:1 selected:NO]];
        _all = @[];
        _sections = @[];
    }
    return self;
}

- (instancetype)initPicker {
    if ((self = [self init])) {
        _picker = YES;
        self.title = @"Tin nhắn mới";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (instancetype)initChooserWithTitle:(NSString *)title onPick:(void (^)(NSDictionary *user))onPick {
    if ((self = [self init])) {
        _picker = YES;
        _onPick = [onPick copy];
        self.title = title;
    }
    return self;
}

- (void)cancelChooser {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 60;
    if (self.onPick)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
                                                                                              action:@selector(cancelChooser)];
    // Chạm giữ một người → đặt tên gợi nhớ (đồng bộ với Zalo trên điện thoại)
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    [self.tableView addGestureRecognizer:lp];
    RZStyleTable(self.tableView);
    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.search.placeholder = @"Tìm bạn";
    self.search.delegate = self;
    self.search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.tableView.tableHeaderView = self.search;
    if (!self.picker) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Tìm SĐT" style:UIBarButtonItemStyleBordered
                                                                                 target:self action:@selector(findPhone)];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onEvent:) name:RZCoreEventNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSIndexPath *sel = self.tableView.indexPathForSelectedRow;
    if (sel) [self.tableView deselectRowAtIndexPath:sel animated:animated];
}

- (void)onEvent:(NSNotification *)n {
    if ([RZStr([n.userInfo objectForKey:@"e"]) isEqualToString:@"contacts.changed"]) [self reload];
}

- (void)reload {
    [RZCore call:@"contacts.list" args:nil done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        self.all = ok;
        [self rebuild];
    }];
}

- (void)rebuild {
    NSString *q = RZFold(self.search.text);
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    for (NSDictionary *u in self.all) {
        NSString *folded = RZFold(RZStr([u objectForKey:@"name"]));
        if (q.length && [folded rangeOfString:q].location == NSNotFound) continue;
        NSString *letter = folded.length ? [[folded substringToIndex:1] uppercaseString] : @"#";
        unichar c = [letter characterAtIndex:0];
        if (c < 'A' || c > 'Z') letter = @"#";
        NSMutableArray *a = [groups objectForKey:letter];
        if (!a) {
            a = [NSMutableArray array];
            [groups setObject:a forKey:letter];
        }
        [a addObject:u];
    }
    NSArray *keys = [groups.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        if ([a isEqualToString:@"#"]) return NSOrderedDescending;
        if ([b isEqualToString:@"#"]) return NSOrderedAscending;
        return [a compare:b];
    }];
    NSMutableArray *secs = [NSMutableArray array];
    for (NSString *k in keys) {
        NSArray *rows = [[groups objectForKey:k] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [RZFold(RZStr([a objectForKey:@"name"])) compare:RZFold(RZStr([b objectForKey:@"name"]))];
        }];
        [secs addObject:@{@"title": k, @"rows": rows}];
    }
    self.sections = secs;
    [self.tableView reloadData];
}

- (void)findPhone {
    UIAlertView *av = [[UIAlertView alloc] initWithTitle:@"Tìm bạn bằng số điện thoại" message:nil delegate:self cancelButtonTitle:@"Huỷ"
                                       otherButtonTitles:@"Tìm", nil];
    av.alertViewStyle = UIAlertViewStylePlainTextInput;
    [av textFieldAtIndex:0].keyboardType = UIKeyboardTypePhonePad;
    [av textFieldAtIndex:0].placeholder = @"0912 345 678";
    [av show];
}

- (void)alertView:(UIAlertView *)av didDismissWithButtonIndex:(NSInteger)i {
    if (i == av.cancelButtonIndex) return;
    NSString *phone = [av textFieldAtIndex:0].text;
    if (!phone.length) return;
    [RZCore call:@"contacts.find" args:@{@"phone": phone} done:^(id ok, NSDictionary *err) {
        NSString *uid = RZStr([ok objectForKey:@"uid"]);
        if (err || !uid.length) {
            RZAlert(@"Không tìm thấy", err ? RZErrorText(err) : @"Số điện thoại chưa đăng ký Zalo hoặc không cho tìm kiếm.");
            return;
        }
        NSString *name = RZStr([ok objectForKey:@"name"]);
        if (!name.length) name = RZStr([ok objectForKey:@"zname"]);
        RZOpenChat(self.navigationController, [@"u" stringByAppendingString:uid], name, RZStr([ok objectForKey:@"avatar"]));
    }];
}

#pragma mark - Bảng

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return [[[self.sections objectAtIndex:s] objectForKey:@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return [[self.sections objectAtIndex:s] objectForKey:@"title"];
}

/// Đầu mục chữ cái tự vẽ (đầu mục mặc định của iOS 6 là dải xám sáng — lệch với chế độ tối).
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, 22)];
    v.backgroundColor = RZBarBg();
    UILabel *l = RZLabel(14, YES, RZTextGray());
    l.frame = CGRectMake(12, 0, tv.bounds.size.width - 40, 22);
    l.text = [[self.sections objectAtIndex:s] objectForKey:@"title"];
    [v addSubview:l];
    return v;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 22;
}

- (NSArray *)sectionIndexTitlesForTableView:(UITableView *)tv {
    if (self.search.text.length) return nil;
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *s in self.sections) [a addObject:[s objectForKey:@"title"]];
    return a;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"u"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"u"];
        c.textLabel.font = [UIFont systemFontOfSize:17];
        RZStyleCell(c);
    }
    NSDictionary *u = [[[self.sections objectAtIndex:ip.section] objectForKey:@"rows"] objectAtIndex:ip.row];
    NSString *name = RZStr([u objectForKey:@"name"]);
    NSString *url = RZStr([u objectForKey:@"avatar"]);
    c.textLabel.text = name;
    UIImage *img = [RZImages cached:url maxPixel:44 * [UIScreen mainScreen].scale round:YES];
    c.imageView.image = img ?: [RZImages placeholderForName:name key:RZStr([u objectForKey:@"uid"]) size:44];
    if (!img && url.length) {
        __weak UITableViewCell *wc = c;
        [RZImages avatar:url size:44 done:^(UIImage *im) {
            if ([wc.textLabel.text isEqualToString:name]) {
                wc.imageView.image = im;
                [wc setNeedsLayout];
            }
        }];
    }
    return c;
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || self.onPick) return;
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:[g locationInView:self.tableView]];
    if (!ip || ip.section >= (NSInteger)self.sections.count) return;
    NSDictionary *u = [[[self.sections objectAtIndex:ip.section] objectForKey:@"rows"] objectAtIndex:ip.row];
    RZEditAlias(RZStr([u objectForKey:@"uid"]), RZStr([u objectForKey:@"name"]), nil);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *u = [[[self.sections objectAtIndex:ip.section] objectForKey:@"rows"] objectAtIndex:ip.row];
    [self.search resignFirstResponder];
    if (self.onPick) {
        void (^pick)(NSDictionary *) = self.onPick;
        [self dismissViewControllerAnimated:YES completion:^{
            pick(u);
        }];
        return;
    }
    NSString *thread = [@"u" stringByAppendingString:RZStr([u objectForKey:@"uid"]) ?: @""];
    UINavigationController *nav = self.navigationController;
    if (RZPad()) [tv deselectRowAtIndexPath:ip animated:YES];  // iPad: chat mở bên phải, danh bạ vẫn hiện
    if (self.picker) [nav popViewControllerAnimated:RZPad()];
    RZOpenChat(nav, thread, RZStr([u objectForKey:@"name"]), RZStr([u objectForKey:@"avatar"]));
}

- (void)searchBar:(UISearchBar *)sb textDidChange:(NSString *)t {
    [self rebuild];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)sb {
    [sb resignFirstResponder];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv {
    [self.search resignFirstResponder];
}

@end
