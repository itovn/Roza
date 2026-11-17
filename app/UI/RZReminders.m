#import "RZCore.h"
#import "RZExtras.h"
#import "RZKit.h"
#import "RZTheme.h"

static NSString *RZRepeatText(NSInteger r) {
    switch (r) {
        case 1: return @"Hằng ngày";
        case 2: return @"Hằng tuần";
        case 3: return @"Hằng tháng";
        default: return @"";
    }
}

static NSString *RZReminderTime(long long ms) {
    static NSDateFormatter *f;
    if (!f) {
        f = [[NSDateFormatter alloc] init];
        f.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"vi_VN"];
        f.dateFormat = @"EEEE, dd/MM/yyyy 'lúc' HH:mm";
    }
    return ms > 0 ? [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:ms / 1000.0]] : @"";
}

void RZCancelReminder(NSString *rid) {
    if (!rid.length) return;
    UIApplication *app = [UIApplication sharedApplication];
    for (UILocalNotification *ln in app.scheduledLocalNotifications)
        if ([RZStr([ln.userInfo objectForKey:@"reminder"]) isEqualToString:rid]) [app cancelLocalNotification:ln];
}

void RZScheduleReminder(NSDictionary *r, NSString *thread, NSString *chatName) {
    NSString *rid = RZStr([r objectForKey:@"id"]);
    long long ts = RZLL([r objectForKey:@"ts"]);
    if (!rid.length || ts <= 0) return;
    RZCancelReminder(rid);
    NSInteger repeat = (NSInteger)RZLL([r objectForKey:@"repeat"]);
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:ts / 1000.0];
    if (repeat > 0) {
        // Lặp lại: dời tới lần kế tiếp còn ở phía trước
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDateComponents *step = [[NSDateComponents alloc] init];
        if (repeat == 1) step.day = 1;
        else if (repeat == 2) step.day = 7;
        else step.month = 1;
        for (int i = 0; i < 2000 && [d timeIntervalSinceNow] < 0; i++) d = [cal dateByAddingComponents:step toDate:d options:0];
    }
    if ([d timeIntervalSinceNow] < 0) return;
    NSString *title = RZStr([r objectForKey:@"title"]);
    UILocalNotification *ln = [[UILocalNotification alloc] init];
    ln.fireDate = d;
    ln.timeZone = [NSTimeZone defaultTimeZone];
    ln.alertBody = chatName.length ? [NSString stringWithFormat:@"⏰ %@ — %@", title, chatName] : [NSString stringWithFormat:@"⏰ %@", title];
    ln.alertAction = @"Xem";
    ln.soundName = UILocalNotificationDefaultSoundName;
    ln.userInfo = @{@"thread": thread ?: @"", @"name": chatName ?: @"", @"reminder": rid};
    if (repeat == 1) ln.repeatInterval = NSDayCalendarUnit;
    else if (repeat == 2) ln.repeatInterval = NSWeekCalendarUnit;
    else if (repeat == 3) ln.repeatInterval = NSMonthCalendarUnit;
    [[UIApplication sharedApplication] scheduleLocalNotification:ln];
}

#pragma mark - Tạo / sửa

@interface RZReminderEditViewController : UIViewController <UITextFieldDelegate>
- (instancetype)initWithThread:(NSString *)thread name:(NSString *)name reminder:(NSDictionary *)r done:(void (^)(NSArray *list))done;
@end

@interface RZReminderEditViewController ()
@property (nonatomic, copy) NSString *thread, *chatName;
@property (nonatomic, strong) NSDictionary *reminder;
@property (nonatomic, copy) void (^done)(NSArray *);
@property (nonatomic, strong) UITextField *titleField;
@property (nonatomic, strong) UISegmentedControl *repeat;
@property (nonatomic, strong) UIDatePicker *picker;
@property (nonatomic, strong) UIButton *removeBtn;
@end

@implementation RZReminderEditViewController

- (instancetype)initWithThread:(NSString *)thread name:(NSString *)name reminder:(NSDictionary *)r done:(void (^)(NSArray *))done {
    if ((self = [super init])) {
        _thread = [thread copy];
        _chatName = [name copy];
        _reminder = r;
        _done = [done copy];
        self.title = r ? @"Sửa nhắc hẹn" : @"Tạo nhắc hẹn";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = RZBg();
    CGFloat W = self.view.bounds.size.width;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Lưu" style:UIBarButtonItemStyleDone target:self
                                                                             action:@selector(save)];
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(10, 14, W - 20, 44)];
    box.backgroundColor = RZCellBg();
    box.layer.cornerRadius = 9;
    box.layer.borderColor = RZLine().CGColor;
    box.layer.borderWidth = 1;
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:box];
    self.titleField = [[UITextField alloc] initWithFrame:CGRectMake(12, 0, box.bounds.size.width - 24, 44)];
    self.titleField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.titleField.placeholder = @"Nội dung nhắc hẹn";
    self.titleField.textColor = RZText();
    self.titleField.font = [UIFont systemFontOfSize:17];
    self.titleField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    self.titleField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.titleField.returnKeyType = UIReturnKeyDone;
    self.titleField.delegate = self;
    if (RZDark()) self.titleField.keyboardAppearance = UIKeyboardAppearanceAlert;
    self.titleField.text = RZStr([self.reminder objectForKey:@"title"]);
    [box addSubview:self.titleField];
    self.repeat = [[UISegmentedControl alloc] initWithItems:@[@"Một lần", @"Hằng ngày", @"Hằng tuần", @"Hằng tháng"]];
    self.repeat.frame = CGRectMake(10, 70, W - 20, 34);
    self.repeat.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.repeat.segmentedControlStyle = UISegmentedControlStyleBar;
    self.repeat.selectedSegmentIndex = MIN(3, MAX(0, (NSInteger)RZLL([self.reminder objectForKey:@"repeat"])));
    [self.view addSubview:self.repeat];
    self.picker = [[UIDatePicker alloc] init];
    self.picker.datePickerMode = UIDatePickerModeDateAndTime;
    self.picker.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"vi_VN"];
    self.picker.minuteInterval = 1;
    CGRect pf = self.picker.frame;
    self.picker.frame = CGRectMake(floorf((W - MIN(W, 320)) / 2), 116, MIN(W, 320), pf.size.height);
    self.picker.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    long long ts = RZLL([self.reminder objectForKey:@"ts"]);
    // Mới: mặc định một giờ nữa, tròn phút
    NSTimeInterval t = ts > 0 ? ts / 1000.0 : floor(([[NSDate date] timeIntervalSince1970] + 3600) / 60) * 60;
    self.picker.date = [NSDate dateWithTimeIntervalSince1970:t];
    [self.view addSubview:self.picker];
    if (self.reminder) {
        self.removeBtn = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [self.removeBtn setTitle:@"Xoá nhắc hẹn" forState:UIControlStateNormal];
        [self.removeBtn setTitleColor:RZHex(0xD0342C) forState:UIControlStateNormal];
        self.removeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        self.removeBtn.frame = CGRectMake(10, CGRectGetMaxY(self.picker.frame) + 16, W - 20, 44);
        self.removeBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self.removeBtn addTarget:self action:@selector(remove) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.removeBtn];
    }
    if (!self.reminder) [self.titleField becomeFirstResponder];
}

- (BOOL)textFieldShouldReturn:(UITextField *)f {
    [f resignFirstResponder];
    return NO;
}

- (void)save {
    NSString *title = [self.titleField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!title.length) {
        RZAlert(@"Nhập nội dung nhắc hẹn", nil);
        return;
    }
    NSInteger repeat = self.repeat.selectedSegmentIndex;
    long long ts = (long long)(floor([self.picker.date timeIntervalSince1970] / 60) * 60 * 1000);
    if (repeat == 0 && ts < (long long)([[NSDate date] timeIntervalSince1970] * 1000)) {
        RZAlert(@"Thời gian đã qua", @"Chọn thời gian ở phía trước.");
        return;
    }
    [self.titleField resignFirstResponder];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    NSDictionary *args = @{@"thread": self.thread, @"id": RZStr([self.reminder objectForKey:@"id"]) ?: @"", @"title": title, @"emoji": @"⏰",
                           @"ts": @(ts), @"repeat": @(repeat)};
    [RZCore call:@"reminders.save" args:args done:^(id ok, NSDictionary *err) {
        self.navigationItem.rightBarButtonItem.enabled = YES;
        if (err) {
            RZAlert(@"Chưa lưu được nhắc hẹn", RZErrorText(err));
            return;
        }
        if (self.done) self.done([ok isKindOfClass:[NSArray class]] ? ok : nil);
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

- (void)remove {
    NSString *rid = RZStr([self.reminder objectForKey:@"id"]);
    RZConfirm(@"Xoá nhắc hẹn này?", @"Cả hai bên sẽ không còn thấy nhắc hẹn.", @"Xoá", ^{
        [RZCore call:@"reminders.remove" args:@{@"thread": self.thread, @"id": rid ?: @""} done:^(id ok, NSDictionary *err) {
            if (err) {
                RZAlert(@"Chưa xoá được", RZErrorText(err));
                return;
            }
            RZCancelReminder(rid);
            if (self.done) self.done([ok isKindOfClass:[NSArray class]] ? ok : nil);
            [self.navigationController popViewControllerAnimated:YES];
        }];
    });
}

@end

#pragma mark - Danh sách

@interface RZReminderListViewController ()
@property (nonatomic, copy) NSString *thread, *chatName;
@property (nonatomic, strong) NSArray *list;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation RZReminderListViewController

- (instancetype)initWithThread:(NSString *)thread name:(NSString *)name {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _thread = [thread copy];
        _chatName = [name copy];
        _list = @[];
        self.title = @"Nhắc hẹn";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    RZStyleTable(self.tableView);
    self.tableView.rowHeight = 58;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self
                                                                                           action:@selector(create)];
    [self reload];
}

- (void)reload {
    [RZCore call:@"reminders.list" args:@{@"thread": self.thread} done:^(id ok, NSDictionary *err) {
        self.loaded = YES;
        if (err) {
            RZAlert(@"Chưa tải được nhắc hẹn", RZErrorText(err));
            [self.tableView reloadData];
            return;
        }
        [self apply:ok];
    }];
}

- (void)apply:(NSArray *)list {
    if (![list isKindOfClass:[NSArray class]]) return;
    self.list = list;
    for (NSDictionary *r in list) RZScheduleReminder(r, self.thread, self.chatName);
    [self.tableView reloadData];
}

- (void)create {
    [self edit:nil];
}

- (void)edit:(NSDictionary *)r {
    __weak RZReminderListViewController *ws = self;
    RZReminderEditViewController *e = [[RZReminderEditViewController alloc] initWithThread:self.thread name:self.chatName reminder:r
                                                                                     done:^(NSArray *list) {
                                                                                         if (list) [ws apply:list];
                                                                                         else [ws reload];
                                                                                     }];
    [self.navigationController pushViewController:e animated:YES];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.list.count;
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (!self.loaded) return @"Đang tải…";
    return self.list.count ? @"Nhắc hẹn đồng bộ với Zalo: người trong cuộc trò chuyện cũng thấy. Roza báo trên máy này đúng giờ hẹn."
                           : @"Chưa có nhắc hẹn. Bấm + để tạo — cả hai bên đều thấy và được nhắc đúng giờ.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"r"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"r"];
        RZStyleCell(c);
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *r = [self.list objectAtIndex:ip.row];
    NSString *emoji = RZStr([r objectForKey:@"emoji"]);
    c.textLabel.text = [NSString stringWithFormat:@"%@ %@", emoji.length ? emoji : @"⏰", RZStr([r objectForKey:@"title"])];
    long long ts = RZLL([r objectForKey:@"ts"]);
    NSString *rep = RZRepeatText((NSInteger)RZLL([r objectForKey:@"repeat"]));
    NSString *when = RZReminderTime(ts);
    BOOL past = ts > 0 && ts < [[NSDate date] timeIntervalSince1970] * 1000 && !rep.length;
    c.detailTextLabel.text = rep.length ? [NSString stringWithFormat:@"%@ · %@", when, rep] : (past ? [when stringByAppendingString:@" · đã qua"] : when);
    c.textLabel.textColor = past ? RZTextGray() : RZText();
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
    NSDictionary *r = [self.list objectAtIndex:ip.row];
    NSString *rid = RZStr([r objectForKey:@"id"]);
    [RZCore call:@"reminders.remove" args:@{@"thread": self.thread, @"id": rid ?: @""} done:^(id ok, NSDictionary *err) {
        if (err) {
            RZAlert(@"Chưa xoá được", RZErrorText(err));
            return;
        }
        RZCancelReminder(rid);
        [self apply:ok];
    }];
}

@end
