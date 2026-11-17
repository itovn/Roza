#import <CoreLocation/CoreLocation.h>
#import "RZCompat.h"
#import "RZCore.h"
#import "RZExtras.h"
#import "RZKit.h"
#import "RZTheme.h"

// Bản đồ: MapKit trên iOS 5 / 6 không còn máy chủ ô (chỉ hiện lưới trống — thử iPad mini 1, 17/11/2026) → tự ghép ô
// OpenStreetMap do lõi tải (lệnh map.tile), địa chỉ tra bằng Nominatim của OSM (map.address).

NSString *RZLocationText(double lat, double lng, NSString *address) {
    NSString *place = address.length ? address : [NSString stringWithFormat:@"%.5f, %.5f", lat, lng];
    return [NSString stringWithFormat:@"📍 %@\nhttps://maps.google.com/maps?q=%.6f,%.6f", place, lat, lng];
}

BOOL RZParseMapURL(NSString *url, double *lat, double *lng) {
    if (!url.length) return NO;
    if ([url rangeOfString:@"maps.google."].location == NSNotFound && [url rangeOfString:@"google.com/maps"].location == NSNotFound &&
        [url rangeOfString:@"maps.apple.com"].location == NSNotFound && [url rangeOfString:@"openstreetmap.org"].location == NSNotFound)
        return NO;
    for (NSString *key in @[@"q=", @"ll=", @"@", @"mlat="]) {
        NSRange r = [url rangeOfString:key];
        if (r.location == NSNotFound) continue;
        NSScanner *sc = [NSScanner scannerWithString:[url substringFromIndex:NSMaxRange(r)]];
        double a = 0, b = 0;
        BOOL ok = [sc scanDouble:&a];
        if (ok && ![sc scanString:@"," intoString:NULL]) ok = [sc scanString:@"&mlon=" intoString:NULL];
        if (ok && [sc scanDouble:&b] && fabs(a) <= 90 && fabs(b) <= 180 && (a != 0 || b != 0)) {
            if (lat) *lat = a;
            if (lng) *lng = b;
            return YES;
        }
    }
    return NO;
}

/// Ghim đỏ; mũi ghim ở giữa cạnh dưới ảnh.
static UIImage *RZPinImage(void) {
    static UIImage *img;
    if (img) return img;
    CGSize s = CGSizeMake(24, 40);
    UIGraphicsBeginImageContextWithOptions(s, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 2, [UIColor colorWithWhite:0 alpha:0.4].CGColor);
    [RZHex(0x5A6670) set];
    CGContextFillRect(ctx, CGRectMake(11, 14, 2, 24));
    [RZHex(0xE0352B) set];
    CGContextFillEllipseInRect(ctx, CGRectMake(3, 1, 18, 18));
    [[UIColor colorWithWhite:1 alpha:0.6] set];
    CGContextFillEllipseInRect(ctx, CGRectMake(8, 5, 6, 6));
    img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

#pragma mark - Bản đồ ô OpenStreetMap

/// Bản đồ ô OSM: tâm (vĩ độ, kinh độ), mức phóng 3–18, kéo để di chuyển. Ghim cố định ở giữa.
@interface RZOSMView : UIView
@property (nonatomic, assign) double lat, lng;
@property (nonatomic, assign) NSInteger zoom;
@property (nonatomic, copy) void (^onMove)(double lat, double lng);  // sau khi kéo / phóng xong
- (void)centerLat:(double)lat lng:(double)lng;
@end

@interface RZOSMView ()
@property (nonatomic, strong) NSMutableDictionary *tiles;  // "z/x/y" → UIImageView
@property (nonatomic, strong) UIView *layer0;
@property (nonatomic, strong) UIImageView *pin;
@property (nonatomic, strong) UILabel *credit;
@end

@implementation RZOSMView

static double RZWorld(NSInteger z) {
    return 256.0 * (double)(1 << z);
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.clipsToBounds = YES;
        self.backgroundColor = RZHex(0xE8E4DC);
        _zoom = 16;
        _tiles = [NSMutableDictionary dictionary];
        _layer0 = [[UIView alloc] initWithFrame:self.bounds];
        _layer0.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_layer0];
        _pin = [[UIImageView alloc] initWithImage:RZPinImage()];
        [self addSubview:_pin];
        _credit = RZLabel(10, NO, RZHex(0x333333));
        _credit.text = @" © OpenStreetMap ";
        _credit.backgroundColor = [UIColor colorWithWhite:1 alpha:0.75];
        [_credit sizeToFit];
        [self addSubview:_credit];
        for (int i = 0; i < 2; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeRoundedRect];
            [b setTitle:i == 0 ? @"+" : @"−" forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont boldSystemFontOfSize:22];
            b.tag = i == 0 ? 1 : -1;
            [b addTarget:self action:@selector(zoomTap:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:b];
        }
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    }
    return self;
}

- (void)centerLat:(double)lat lng:(double)lng {
    self.lat = MAX(-85, MIN(85, lat));
    self.lng = lng;
    [self setNeedsLayout];
}

- (CGPoint)worldPoint {
    double w = RZWorld(self.zoom);
    double r = self.lat * M_PI / 180;
    return CGPointMake((self.lng + 180) / 360 * w, (1 - log(tan(r) + 1 / cos(r)) / M_PI) / 2 * w);
}

- (void)setWorldPoint:(CGPoint)p {
    double w = RZWorld(self.zoom);
    double x = fmod(fmod(p.x, w) + w, w), y = MAX(0, MIN(w, p.y));
    self.lng = x / w * 360 - 180;
    self.lat = atan(sinh(M_PI * (1 - 2 * y / w))) * 180 / M_PI;
}

- (void)zoomTap:(UIButton *)b {
    NSInteger z = MAX(3, MIN(18, self.zoom + b.tag));
    if (z == self.zoom) return;
    self.zoom = z;
    [self setNeedsLayout];
    if (self.onMove) self.onMove(self.lat, self.lng);
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self];
    [g setTranslation:CGPointZero inView:self];
    CGPoint p = [self worldPoint];
    [self setWorldPoint:CGPointMake(p.x - d.x, p.y - d.y)];
    [self setNeedsLayout];
    if (g.state == UIGestureRecognizerStateEnded && self.onMove) self.onMove(self.lat, self.lng);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    CGPoint c = [self worldPoint];
    double left = c.x - s.width / 2, top = c.y - s.height / 2;
    NSInteger n = 1 << self.zoom;
    NSMutableSet *want = [NSMutableSet set];
    for (NSInteger ty = (NSInteger)floor(top / 256); ty * 256 < top + s.height; ty++) {
        if (ty < 0 || ty >= n) continue;
        for (NSInteger tx = (NSInteger)floor(left / 256); tx * 256 < left + s.width; tx++) {
            NSInteger wx = ((tx % n) + n) % n;  // vòng qua kinh tuyến 180
            NSString *key = [NSString stringWithFormat:@"%ld/%ld/%ld/%ld", (long)self.zoom, (long)wx, (long)ty, (long)tx];
            [want addObject:key];
            UIImageView *iv = [self.tiles objectForKey:key];
            if (!iv) {
                iv = [[UIImageView alloc] init];
                [self.tiles setObject:iv forKey:key];
                [self.layer0 addSubview:iv];
                [self loadTile:iv z:self.zoom x:wx y:ty key:key];
            }
            iv.frame = CGRectMake(floor(tx * 256 - left), floor(ty * 256 - top), 256, 256);
        }
    }
    for (NSString *key in self.tiles.allKeys)
        if (![want containsObject:key]) {
            [[self.tiles objectForKey:key] removeFromSuperview];
            [self.tiles removeObjectForKey:key];
        }
    self.pin.center = CGPointMake(floorf(s.width / 2), floorf(s.height / 2) - self.pin.bounds.size.height / 2 + 2);
    self.credit.frame = CGRectMake(s.width - self.credit.bounds.size.width - 4, s.height - self.credit.bounds.size.height - 4,
                                   self.credit.bounds.size.width, self.credit.bounds.size.height);
    CGFloat by = 10;
    for (UIView *v in self.subviews)
        if ([v isKindOfClass:[UIButton class]]) {
            v.frame = CGRectMake(s.width - 52, by, 42, 42);
            by += 50;
        }
}

- (void)loadTile:(UIImageView *)iv z:(NSInteger)z x:(NSInteger)x y:(NSInteger)y key:(NSString *)key {
    __weak RZOSMView *ws = self;
    [RZCore call:@"map.tile" args:@{@"z": @(z), @"x": @(x), @"y": @(y)} done:^(id ok, NSDictionary *err) {
        NSString *path = RZStr([ok objectForKey:@"path"]);
        if (!path.length || [ws.tiles objectForKey:key] != iv) return;
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (img) iv.image = img;
    }];
}

@end

#pragma mark - Màn bản đồ

@interface RZMapViewController () <CLLocationManagerDelegate>
@property (nonatomic, strong) RZOSMView *map;
@property (nonatomic, strong) CLLocationManager *lm;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *titleLabel, *addrLabel;
@property (nonatomic, strong) UIButton *sendBtn;
@property (nonatomic, assign) double lat, lng;
@property (nonatomic, copy) NSString *placeTitle, *address;
@property (nonatomic, copy) void (^done)(double, double, NSString *);
@property (nonatomic, assign) BOOL picker, located;
@property (nonatomic, assign) NSUInteger lookupGen;
@end

@implementation RZMapViewController

- (instancetype)initWithLat:(double)lat lng:(double)lng title:(NSString *)title {
    if ((self = [super init])) {
        _lat = lat;
        _lng = lng;
        _placeTitle = [title copy];
        self.title = @"Vị trí";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (instancetype)initPickerWithDone:(void (^)(double, double, NSString *))done {
    if ((self = [super init])) {
        _picker = YES;
        _done = [done copy];
        _lat = 21.0285;  // chờ định vị: Hà Nội
        _lng = 105.8542;
        self.title = @"Gửi vị trí";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = RZBg();
    CGRect b = self.view.bounds;
    CGFloat panelH = self.picker ? 116 : 70;
    self.map = [[RZOSMView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height - panelH)];
    self.map.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.map.zoom = self.picker ? 15 : 16;
    [self.map centerLat:self.lat lng:self.lng];
    [self.view addSubview:self.map];
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height - panelH, b.size.width, panelH)];
    self.panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.panel.backgroundColor = RZBarBg();
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 1)];
    line.backgroundColor = RZBarLine();
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.panel addSubview:line];
    self.titleLabel = RZLabel(16, YES, RZText());
    self.titleLabel.frame = CGRectMake(14, 10, b.size.width - 28, 20);
    self.titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.panel addSubview:self.titleLabel];
    self.addrLabel = RZLabel(13, NO, RZTextGray());
    self.addrLabel.numberOfLines = 2;
    self.addrLabel.lineBreakMode = RZBreakWord;
    self.addrLabel.frame = CGRectMake(14, 31, b.size.width - 28, 34);
    self.addrLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.panel addSubview:self.addrLabel];
    [self.view addSubview:self.panel];
    __weak RZMapViewController *ws = self;
    if (self.picker) {
        self.titleLabel.text = @"Kéo bản đồ để chọn chỗ khác";
        self.addrLabel.text = @"Đang tìm vị trí của bạn…";
        self.sendBtn = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [self.sendBtn setTitle:@"Gửi vị trí này" forState:UIControlStateNormal];
        self.sendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        self.sendBtn.frame = CGRectMake(14, 68, b.size.width - 28, 40);
        self.sendBtn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self.sendBtn addTarget:self action:@selector(send) forControlEvents:UIControlEventTouchUpInside];
        [self.panel addSubview:self.sendBtn];
        self.map.onMove = ^(double lat, double lng) {
            ws.lat = lat;
            ws.lng = lng;
            ws.located = YES;  // người dùng đã tự chọn chỗ → không nhảy về vị trí GPS nữa
            [ws lookup];
        };
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Vị trí tôi" style:UIBarButtonItemStyleBordered
                                                                                 target:self action:@selector(locateMe)];
        [self locateMe];
    } else {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Mở…" style:UIBarButtonItemStyleBordered target:self
                                                                                 action:@selector(openSheet)];
        self.titleLabel.text = self.placeTitle.length ? self.placeTitle : @"Vị trí được chia sẻ";
        self.addrLabel.text = [NSString stringWithFormat:@"%.5f, %.5f", self.lat, self.lng];
        [self lookup];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.lm stopUpdatingLocation];
}

- (void)dealloc {
    self.lm.delegate = nil;
}

- (void)locateMe {
    if (!self.lm) {
        self.lm = [[CLLocationManager alloc] init];
        self.lm.delegate = self;
        self.lm.desiredAccuracy = kCLLocationAccuracyBest;
    }
    self.located = NO;
    [self.lm startUpdatingLocation];
}

/// Địa chỉ của điểm giữa bản đồ (chờ 0,8 giây sau lần kéo cuối — Nominatim chỉ cho ~1 lần / giây).
- (void)lookup {
    self.addrLabel.text = [NSString stringWithFormat:@"%.5f, %.5f", self.lat, self.lng];
    if (self.picker) self.address = nil;
    NSUInteger gen = ++self.lookupGen;
    double lat = self.lat, lng = self.lng;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != self.lookupGen) return;
        [RZCore call:@"map.address" args:@{@"lat": @(lat), @"lng": @(lng)} done:^(id ok, NSDictionary *err) {
            NSString *a = RZStr([ok objectForKey:@"address"]);
            if (gen != self.lookupGen || !a.length) return;
            self.address = a;
            self.addrLabel.text = a;
        }];
    });
}

- (void)gotLocation:(CLLocation *)loc {
    if (self.located || !loc) return;
    self.located = YES;
    [self.lm stopUpdatingLocation];
    self.lat = loc.coordinate.latitude;
    self.lng = loc.coordinate.longitude;
    self.map.zoom = 16;
    [self.map centerLat:self.lat lng:self.lng];
    [self lookup];
}

- (void)locationManager:(CLLocationManager *)m didUpdateLocations:(NSArray *)locations {
    [self gotLocation:[locations lastObject]];
}

- (void)locationManager:(CLLocationManager *)m didUpdateToLocation:(CLLocation *)loc fromLocation:(CLLocation *)old {
    [self gotLocation:loc];  // iOS 5
}

- (void)locationManager:(CLLocationManager *)m didFailWithError:(NSError *)err {
    if (err.code == kCLErrorDenied)
        self.addrLabel.text = @"Roza chưa được dùng định vị: bật trong Cài đặt → Quyền riêng tư → Dịch vụ định vị → Roza, hoặc kéo bản đồ để chọn.";
}

- (void)send {
    void (^done)(double, double, NSString *) = self.done;
    double lat = self.lat, lng = self.lng;
    NSString *addr = self.address;
    [self.navigationController popViewControllerAnimated:YES];
    if (done) done(lat, lng, addr);
}

- (void)openSheet {
    RZSheet *s = [[RZSheet alloc] initWithTitle:[NSString stringWithFormat:@"%.6f, %.6f", self.lat, self.lng]];
    double lat = self.lat, lng = self.lng;
    NSString *title = self.placeTitle;
    [s add:@"Chép toạ độ" action:^{
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%.6f, %.6f", lat, lng];
    }];
    [s add:@"Chép đường dẫn Google Maps" action:^{
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"https://maps.google.com/maps?q=%.6f,%.6f", lat, lng];
    }];
    [s add:@"Mở bằng app Bản đồ" action:^{
        NSString *q = [(title.length ? title : @"Vị trí") stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSString *u = RZOldIOS() ? [NSString stringWithFormat:@"http://maps.google.com/maps?q=%.6f,%.6f", lat, lng]
                                 : [NSString stringWithFormat:@"http://maps.apple.com/?ll=%.6f,%.6f&q=%@", lat, lng, q];
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:u]];
    }];
    [s showIn:self.view];
}

@end
