#import "RZGroupsViewController.h"
#import "RZAppDelegate.h"
#import "RZCore.h"
#import "RZImages.h"
#import "RZKit.h"
#import "RZTheme.h"

@interface RZGroupsViewController ()
@property (nonatomic, strong) NSArray *groups;
@end

@implementation RZGroupsViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        self.title = @"Nhóm";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Nhóm" image:nil tag:2];
        [self.tabBarItem setFinishedSelectedImage:[RZTheme tabIcon:2 selected:YES] withFinishedUnselectedImage:[RZTheme tabIcon:2 selected:NO]];
        _groups = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 64;
    RZStyleTable(self.tableView);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                           target:self action:@selector(refresh)];
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
    [self reload];
}

- (void)onEvent:(NSNotification *)n {
    NSString *e = RZStr([n.userInfo objectForKey:@"e"]);
    if ([e isEqualToString:@"contacts.changed"] || [e isEqualToString:@"group.event"]) [self reload];
}

- (void)reload {
    [RZCore call:@"groups.list" args:nil done:^(id ok, NSDictionary *err) {
        if (![ok isKindOfClass:[NSArray class]]) return;
        self.groups = ok;
        self.navigationItem.title = [NSString stringWithFormat:@"Nhóm (%lu)", (unsigned long)[ok count]];
        [self.tableView reloadData];
    }];
}

- (void)refresh {
    [RZCore call:@"groups.refresh" args:nil done:^(id ok, NSDictionary *err) {
        if (err) RZAlert(@"Không tải được", RZErrorText(err));
        if ([ok isKindOfClass:[NSArray class]]) {
            self.groups = ok;
            [self.tableView reloadData];
        }
    }];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.groups.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"g"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"g"];
        c.textLabel.font = [UIFont boldSystemFontOfSize:16];
        RZStyleCell(c);
    }
    NSDictionary *g = [self.groups objectAtIndex:ip.row];
    NSString *name = RZStr([g objectForKey:@"name"]);
    if (!name.length) name = @"Nhóm";
    NSString *url = RZStr([g objectForKey:@"avatar"]);
    c.textLabel.text = name;
    long long ts = RZLL([g objectForKey:@"ts"]);
    c.detailTextLabel.text = [NSString stringWithFormat:@"%lld thành viên%@", RZLL([g objectForKey:@"members"]),
                                                        ts > 0 ? [@" · " stringByAppendingString:RZTimeShort(ts)] : @""];
    UIImage *img = [RZImages cached:url maxPixel:48 * [UIScreen mainScreen].scale round:YES];
    c.imageView.image = img ?: [RZImages placeholderForName:name key:RZStr([g objectForKey:@"gid"]) size:48];
    if (!img && url.length) {
        __weak UITableViewCell *wc = c;
        [RZImages avatar:url size:48 done:^(UIImage *im) {
            if ([wc.textLabel.text isEqualToString:name]) {
                wc.imageView.image = im;
                [wc setNeedsLayout];
            }
        }];
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *g = [self.groups objectAtIndex:ip.row];
    if (RZPad()) [tv deselectRowAtIndexPath:ip animated:YES];  // iPad: chat mở bên phải, danh sách nhóm vẫn hiện
    RZOpenChat(self.navigationController, [@"g" stringByAppendingString:RZStr([g objectForKey:@"gid"]) ?: @""], RZStr([g objectForKey:@"name"]),
               RZStr([g objectForKey:@"avatar"]));
}

@end
