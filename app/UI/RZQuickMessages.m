#import "RZCore.h"
#import "RZExtras.h"
#import "RZKit.h"
#import "RZTheme.h"

#pragma mark - Thêm / sửa

@interface RZQuickEditViewController : UIViewController <UITextFieldDelegate>
- (instancetype)initWithItem:(NSDictionary *)item done:(void (^)(NSArray *list))done;
@end

@interface RZQuickEditViewController ()
@property (nonatomic, strong) NSDictionary *item;
@property (nonatomic, copy) void (^done)(NSArray *);
@property (nonatomic, strong) UITextField *keyword;
@property (nonatomic, strong) UITextView *text;
@end

@implementation RZQuickEditViewController

- (instancetype)initWithItem:(NSDictionary *)item done:(void (^)(NSArray *))done {
    if ((self = [super init])) {
        _item = item;
        _done = [done copy];
        self.title = item ? @"Sửa tin nhắn nhanh" : @"Tin nhắn nhanh mới";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (UIView *)box:(CGRect)f {
    UIView *b = [[UIView alloc] initWithFrame:f];
    b.backgroundColor = RZCellBg();
    b.layer.cornerRadius = 9;
    b.layer.borderColor = RZLine().CGColor;
    b.layer.borderWidth = 1;
    b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:b];
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = RZBg();
    CGFloat W = self.view.bounds.size.width;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Lưu" style:UIBarButtonItemStyleDone target:self
                                                                             action:@selector(save)];
    UILabel *l1 = RZLabel(13, NO, RZTextGray());
    l1.text = @"Phím tắt (gõ «/» + phím tắt trong ô nhập tin để chèn)";
    l1.frame = CGRectMake(16, 10, W - 32, 18);
    l1.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:l1];
    UIView *b1 = [self box:CGRectMake(10, 30, W - 20, 44)];
    UILabel *slash = RZLabel(18, YES, RZTextGray());
    slash.text = @"/";
    slash.frame = CGRectMake(12, 12, 12, 20);
    [b1 addSubview:slash];
    self.keyword = [[UITextField alloc] initWithFrame:CGRectMake(26, 0, b1.bounds.size.width - 36, 44)];
    self.keyword.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.keyword.placeholder = @"vd. chao";
    self.keyword.textColor = RZText();
    self.keyword.font = [UIFont systemFontOfSize:17];
    self.keyword.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    self.keyword.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.keyword.autocorrectionType = UITextAutocorrectionTypeNo;
    self.keyword.returnKeyType = UIReturnKeyNext;
    self.keyword.delegate = self;
    if (RZDark()) self.keyword.keyboardAppearance = UIKeyboardAppearanceAlert;
    self.keyword.text = RZStr([self.item objectForKey:@"keyword"]);
    [b1 addSubview:self.keyword];
    UILabel *l2 = RZLabel(13, NO, RZTextGray());
    l2.text = @"Nội dung";
    l2.frame = CGRectMake(16, 84, W - 32, 18);
    l2.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:l2];
    UIView *b2 = [self box:CGRectMake(10, 104, W - 20, 120)];
    self.text = [[UITextView alloc] initWithFrame:CGRectInset(b2.bounds, 4, 4)];
    self.text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.text.backgroundColor = [UIColor clearColor];
    self.text.textColor = RZText();
    self.text.font = [UIFont systemFontOfSize:16];
    if (RZDark()) self.text.keyboardAppearance = UIKeyboardAppearanceAlert;
    self.text.text = RZStr([self.item objectForKey:@"text"]);
    [b2 addSubview:self.text];
    if (self.item) [self.text becomeFirstResponder];
    else [self.keyword becomeFirstResponder];
}

- (BOOL)textFieldShouldReturn:(UITextField *)f {
    [self.text becomeFirstResponder];
    return NO;
}

- (void)save {
    NSString *k = [self.keyword.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *t = [self.text.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!k.length || !t.length) {
        RZAlert(@"Nhập phím tắt và nội dung", nil);
        return;
    }
    self.navigationItem.rightBarButtonItem.enabled = NO;
    NSDictionary *args = @{@"id": @(RZLL([self.item objectForKey:@"id"])), @"keyword": k, @"text": t};
    [RZCore call:@"quick.save" args:args done:^(id ok, NSDictionary *err) {
        self.navigationItem.rightBarButtonItem.enabled = YES;
        if (err) {
            RZAlert(@"Chưa lưu được", RZErrorText(err));
            return;
        }
        if (self.done) self.done([ok isKindOfClass:[NSArray class]] ? ok : nil);
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

@end

#pragma mark - Danh sách

@interface RZQuickMessagesViewController ()
@property (nonatomic, strong) NSArray *list;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation RZQuickMessagesViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = @"Tin nhắn nhanh";
        self.hidesBottomBarWhenPushed = YES;
        _list = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RZStyleTable(self.tableView);
    self.tableView.rowHeight = 60;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self
                                                                                           action:@selector(create)];
    [RZCore call:@"quick.list" args:@{@"refresh": @YES} done:^(id ok, NSDictionary *err) {
        self.loaded = YES;
        if (err) RZAlert(@"Chưa tải được tin nhắn nhanh", RZErrorText(err));
        if ([ok isKindOfClass:[NSArray class]]) self.list = ok;
        [self.tableView reloadData];
    }];
}

- (void)create {
    [self edit:nil];
}

- (void)edit:(NSDictionary *)item {
    __weak RZQuickMessagesViewController *ws = self;
    RZQuickEditViewController *e = [[RZQuickEditViewController alloc] initWithItem:item done:^(NSArray *list) {
        if (list) {
            ws.list = list;
            [ws.tableView reloadData];
        }
    }];
    [self.navigationController pushViewController:e animated:YES];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.list.count;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (!self.loaded) return nil;
    return self.list.count ? @"Trong ô nhập tin, gõ «/» để chọn tin nhắn nhanh. Đồng bộ với Zalo trên điện thoại."
                           : @"Chưa có tin nhắn nhanh. Bấm + để thêm câu hay dùng (vd. «/stk» → số tài khoản), rồi gõ «/» trong ô nhập tin để chèn.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"q"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"q"];
        RZStyleCell(c);
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *q = [self.list objectAtIndex:ip.row];
    c.textLabel.text = [@"/" stringByAppendingString:RZStr([q objectForKey:@"keyword"]) ?: @""];
    c.detailTextLabel.text = [RZStr([q objectForKey:@"text"]) stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    [self edit:[self.list objectAtIndex:ip.row]];
}

- (NSString *)tableView:(UITableView *)tv titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)ip {
    return @"Xoá";
}

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *q = [self.list objectAtIndex:ip.row];
    [RZCore call:@"quick.remove" args:@{@"id": @(RZLL([q objectForKey:@"id"]))} done:^(id ok, NSDictionary *err) {
        if (err) {
            RZAlert(@"Chưa xoá được", RZErrorText(err));
            return;
        }
        if ([ok isKindOfClass:[NSArray class]]) self.list = ok;
        [self.tableView reloadData];
    }];
}

@end
