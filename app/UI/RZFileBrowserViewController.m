#import "RZFileBrowserViewController.h"
#import "RZLog.h"
#import "RZTheme.h"

static NSString *const kAppsMode = @"<apps>";

@interface RZFileBrowserViewController () <UIActionSheetDelegate>
@end

@implementation RZFileBrowserViewController {
    NSString *_path;     // nil = trang vị trí; kAppsMode = danh sách app có tài liệu
    NSArray *_items;     // @{name, path, dir, size?, date?, detail?}
    BOOL _loading;
    NSString *_note;     // chân trang: thư mục rỗng / không đọc được
    NSDictionary *_pending;
}

- (instancetype)initWithPath:(NSString *)path title:(NSString *)title {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _path = [path copy];
        self.title = title ?: @"Chọn tệp";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 56;
    RZStyleTable(self.tableView);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Huỷ" style:UIBarButtonItemStyleBordered
                                                                             target:self action:@selector(cancel)];
    [self load];
    [self updateFooter];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark Đọc thư mục

static NSDateFormatter *RZFileDateFmt(void) {
    static NSDateFormatter *f;
    if (!f) {
        f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"dd/MM/yy HH:mm";
    }
    return f;
}

/// Trang vị trí: chỉ những chỗ có thật trên máy.
+ (NSArray *)places {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray array];
    NSArray *cands = @[
        @[@"Tài liệu", @"/var/mobile/Documents"],
        @[@"Tải về", @"/var/mobile/Media/Downloads"],
        @[@"Ảnh, video (DCIM)", @"/var/mobile/Media/DCIM"],
        @[@"Ghi âm", @"/var/mobile/Media/Recordings"],
        @[@"Tài liệu của các app", kAppsMode],
        @[@"Thư mục người dùng", @"/var/mobile"],
        @[@"Toàn bộ máy", @"/"],
    ];
    for (NSArray *c in cands) {
        NSString *p = [c objectAtIndex:1];
        BOOL dir = NO;
        BOOL apps = [p isEqualToString:kAppsMode];
        if (apps || ([fm fileExistsAtPath:p isDirectory:&dir] && dir)) {
            [out addObject:@{@"name": [c objectAtIndex:0], @"path": p, @"dir": @YES,
                             @"detail": apps ? @"Documents của app đã cài" : p}];
        }
    }
    return out;
}

/// App (App Store, ở /var/mobile/Applications/<UUID>) có thư mục Documents không rỗng — hiện tên app.
+ (NSArray *)apps {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/Applications";
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL]) {
        NSString *home = [root stringByAppendingPathComponent:uuid];
        NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
        NSArray *inDocs = [fm contentsOfDirectoryAtPath:docs error:NULL];
        if (!inDocs.count) continue;
        NSString *name = nil;
        for (NSString *f in [fm contentsOfDirectoryAtPath:home error:NULL]) {
            if (![f hasSuffix:@".app"]) continue;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                                   [[home stringByAppendingPathComponent:f] stringByAppendingPathComponent:@"Info.plist"]];
            name = [info objectForKey:@"CFBundleDisplayName"] ?: [info objectForKey:@"CFBundleName"] ?: f.stringByDeletingPathExtension;
            break;
        }
        if (!name) continue;
        [out addObject:@{@"name": name, @"path": docs, @"dir": @YES,
                         @"detail": [NSString stringWithFormat:@"%lu mục", (unsigned long)inDocs.count]}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [[a objectForKey:@"name"] localizedCaseInsensitiveCompare:[b objectForKey:@"name"]];
    }];
    return out;
}

+ (NSArray *)listDirectory:(NSString *)path error:(NSError **)err {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:path error:err];
    if (!names) return nil;
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in names) {
        if ([n hasPrefix:@"."]) continue;
        NSString *full = [path stringByAppendingPathComponent:n];
        BOOL dir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&dir]) continue;  // liên kết hỏng
        NSDictionary *attr = [fm attributesOfItemAtPath:[full stringByResolvingSymlinksInPath] error:NULL];
        NSMutableDictionary *it = [@{@"name": n, @"path": full, @"dir": @(dir)} mutableCopy];
        if (!dir) [it setObject:@([attr fileSize]) forKey:@"size"];
        if ([attr fileModificationDate]) [it setObject:[attr fileModificationDate] forKey:@"date"];
        [out addObject:it];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL da = [[a objectForKey:@"dir"] boolValue], db = [[b objectForKey:@"dir"] boolValue];
        if (da != db) return da ? NSOrderedAscending : NSOrderedDescending;
        return [[a objectForKey:@"name"] localizedCaseInsensitiveCompare:[b objectForKey:@"name"]];
    }];
    return out;
}

- (void)load {
    if (!_path) {
        _items = [RZFileBrowserViewController places];
        return;
    }
    _loading = YES;
    NSString *path = _path;
    // Thư mục lớn (DCIM cả nghìn ảnh): đọc ở hàng nền
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *err = nil;
        BOOL apps = [path isEqualToString:kAppsMode];
        NSArray *items = apps ? [RZFileBrowserViewController apps]
                                           : [RZFileBrowserViewController listDirectory:path error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            _loading = NO;
            _items = items ?: @[];
            _note = !items ? @"Không mở được thư mục này (không có quyền đọc)."
                    : items.count ? nil
                    : apps ? @"Chưa app nào có tài liệu." : @"Thư mục rỗng.";
            [self.tableView reloadData];
            [self updateFooter];
        });
    });
}

#pragma mark Bảng

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _items.count;
}

/// Chân bảng nhiều dòng (chân mục của bảng trơn chỉ hiện một dòng); không có chữ thì để khung rỗng — ẩn dòng kẻ thừa.
- (void)updateFooter {
    NSString *t = _loading ? @"Đang đọc…"
                  : _note ? _note
                  : !_path ? @"Chọn một tệp để gửi dạng tệp đính kèm (giữ nguyên chất lượng, tối đa 2 GB)."
                           : nil;
    CGFloat w = self.tableView.bounds.size.width;
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, t ? 64 : 0)];
    if (t) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, w - 32, 48)];
        l.text = t;
        l.numberOfLines = 0;
        l.textAlignment = RZAlignCenter;
        l.font = [UIFont systemFontOfSize:14];
        l.textColor = RZTextGray();
        l.backgroundColor = [UIColor clearColor];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [v addSubview:l];
    }
    self.tableView.tableFooterView = v;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"f"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"f"];
        RZStyleCell(c);
        c.detailTextLabel.textColor = RZTextGray();
        c.textLabel.lineBreakMode = RZMiddleTruncation;
    }
    NSDictionary *it = [_items objectAtIndex:ip.row];
    BOOL dir = [[it objectForKey:@"dir"] boolValue];
    NSString *name = [it objectForKey:@"name"];
    c.textLabel.text = name;
    c.imageView.image = dir ? [RZTheme folderIcon] : [RZTheme fileIcon:name.pathExtension];
    c.accessoryType = dir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    NSString *detail = [it objectForKey:@"detail"];
    if (!detail) {
        NSDate *d = [it objectForKey:@"date"];
        NSString *ds = d ? [RZFileDateFmt() stringFromDate:d] : @"";
        detail = dir ? ds : [NSString stringWithFormat:@"%@ · %@", [RZTheme sizeText:[[it objectForKey:@"size"] doubleValue]], ds];
    }
    c.detailTextLabel.text = detail;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *it = [_items objectAtIndex:ip.row];
    if ([[it objectForKey:@"dir"] boolValue]) {
        RZFileBrowserViewController *b = [[RZFileBrowserViewController alloc] initWithPath:[it objectForKey:@"path"]
                                                                                     title:[it objectForKey:@"name"]];
        b.onPick = self.onPick;
        [self.navigationController pushViewController:b animated:YES];
        return;
    }
    NSString *path = [it objectForKey:@"path"];
    double size = [[it objectForKey:@"size"] doubleValue];
    if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
        [RZTheme toast:@"Không đọc được tệp này." in:self.navigationController.view];
        return;
    }
    if (size <= 0) {
        [RZTheme toast:@"Tệp rỗng." in:self.navigationController.view];
        return;
    }
    if (size > 1024.0 * 1048576) {
        [RZTheme toast:@"Tệp quá 1 GB — Zalo không nhận." in:self.navigationController.view];
        return;
    }
    _pending = it;
    NSString *t = [NSString stringWithFormat:@"Gửi «%@» (%@)?", [it objectForKey:@"name"], [RZTheme sizeText:size]];
    UIActionSheet *s = [[UIActionSheet alloc] initWithTitle:t delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil
                                          otherButtonTitles:@"Gửi", nil];
    s.cancelButtonIndex = [s addButtonWithTitle:@"Huỷ"];
    [s showFromRect:[tableView rectForRowAtIndexPath:ip] inView:tableView animated:YES];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)i {
    NSDictionary *it = _pending;
    _pending = nil;
    if (i != 0 || !it) return;
    NSString *path = [it objectForKey:@"path"];
    void (^pick)(NSString *) = self.onPick;
    RZLog(@"chọn tệp để gửi: %@ byte", [it objectForKey:@"size"]);
    [self dismissViewControllerAnimated:YES completion:^{
        if (pick) pick(path);
    }];
}

#pragma mark Gỡ lỗi

- (void)debugTapSection:(NSInteger)section row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_items.count) return;
    [self tableView:self.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]];
}

- (void)debugOpenPath:(NSString *)path {
    RZFileBrowserViewController *b = [[RZFileBrowserViewController alloc] initWithPath:path title:path.lastPathComponent];
    b.onPick = self.onPick;
    [self.navigationController pushViewController:b animated:NO];
}

@end
