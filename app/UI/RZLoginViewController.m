#import "RZLoginViewController.h"
#import "RZCore.h"
#import "RZImages.h"
#import "RZKit.h"
#import "RZTheme.h"

@interface RZLoginViewController ()
@property (nonatomic, strong) UIImageView *qr;
@property (nonatomic, strong) UIView *qrCard, *dim;
@property (nonatomic, strong) UILabel *status, *steps;
@property (nonatomic, strong) UIButton *retry;
@property (nonatomic, strong) UIActivityIndicatorView *spin;
@end

@implementation RZLoginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    CGRect b = self.view.bounds;
    CGFloat W = b.size.width;
    self.view.backgroundColor = RZHex(0x1E8FCF);
    // Nền loang nhẹ (vẽ một lần)
    UIImageView *bg = [[UIImageView alloc] initWithFrame:b];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.image = [self backgroundImage:b.size];
    [self.view addSubview:bg];

    UILabel *logo = RZLabel(40, YES, [UIColor whiteColor]);
    logo.text = @"Roza";
    logo.textAlignment = RZAlignCenter;
    logo.shadowColor = [UIColor colorWithWhite:0 alpha:0.2];
    logo.shadowOffset = CGSizeMake(0, 1);
    logo.frame = CGRectMake(0, b.size.height > 500 ? 40 : 18, W, 48);
    logo.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:logo];
    UILabel *sub = RZLabel(14, NO, [UIColor colorWithWhite:1 alpha:0.85]);
    sub.text = @"Nhắn tin Zalo trên iPhone đời cũ";
    sub.textAlignment = RZAlignCenter;
    sub.frame = CGRectMake(0, CGRectGetMaxY(logo.frame), W, 20);
    sub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:sub];

    CGFloat card = 236;
    self.qrCard = [[UIView alloc] initWithFrame:CGRectMake((W - card) / 2, CGRectGetMaxY(sub.frame) + 18, card, card)];
    self.qrCard.backgroundColor = [UIColor whiteColor];
    self.qrCard.layer.cornerRadius = 12;
    self.qrCard.layer.shadowColor = [UIColor blackColor].CGColor;
    self.qrCard.layer.shadowOpacity = 0.25;
    self.qrCard.layer.shadowOffset = CGSizeMake(0, 2);
    self.qrCard.layer.shadowRadius = 6;
    self.qrCard.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:self.qrCard];
    self.qr = [[UIImageView alloc] initWithFrame:CGRectInset(self.qrCard.bounds, 10, 10)];
    self.qr.layer.magnificationFilter = kCAFilterNearest;
    [self.qrCard addSubview:self.qr];
    self.dim = [[UIView alloc] initWithFrame:self.qrCard.bounds];
    self.dim.backgroundColor = [UIColor colorWithWhite:1 alpha:0.9];
    self.dim.layer.cornerRadius = 12;
    self.dim.hidden = YES;
    [self.qrCard addSubview:self.dim];
    self.spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spin.center = CGPointMake(card / 2, card / 2);
    [self.qrCard addSubview:self.spin];
    self.retry = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    [self.retry setTitle:@"Lấy mã mới" forState:UIControlStateNormal];
    self.retry.frame = CGRectMake((card - 130) / 2, (card - 40) / 2, 130, 40);
    [self.retry addTarget:self action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
    self.retry.hidden = YES;
    [self.qrCard addSubview:self.retry];

    self.status = RZLabel(16, YES, [UIColor whiteColor]);
    self.status.textAlignment = RZAlignCenter;
    self.status.numberOfLines = 2;
    self.status.lineBreakMode = RZBreakWord;
    self.status.frame = CGRectMake(16, CGRectGetMaxY(self.qrCard.frame) + 12, W - 32, 42);
    self.status.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.status];
    self.steps = RZLabel(13, NO, [UIColor colorWithWhite:1 alpha:0.9]);
    self.steps.numberOfLines = 0;
    self.steps.lineBreakMode = RZBreakWord;
    self.steps.text = @"1. Mở app Zalo trên điện thoại khác\n2. Bấm nút quét mã QR (góc trên)\n3. Quét mã này rồi bấm «Đăng nhập»";
    self.steps.frame = CGRectMake(30, CGRectGetMaxY(self.status.frame) + 4, W - 60, 60);
    self.steps.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:self.steps];
    UILabel *note = RZLabel(11, NO, [UIColor colorWithWhite:1 alpha:0.7]);
    note.numberOfLines = 3;
    note.lineBreakMode = RZBreakWord;
    note.textAlignment = RZAlignCenter;
    note.text = @"Roza là ứng dụng không chính thức, đăng nhập như Zalo Web. Phiên đăng nhập chỉ lưu trên máy này.";
    note.frame = CGRectMake(16, b.size.height - 44, W - 32, 36);
    note.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [self.view addSubview:note];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onEvent:) name:RZCoreEventNotification object:nil];
    [self start];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIImage *)backgroundImage:(CGSize)s {
    UIGraphicsBeginImageContextWithOptions(s, YES, 1);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[] = {0.20, 0.66, 0.90, 1, 0.07, 0.45, 0.74, 1};
    CGFloat locs[] = {0, 1};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
    CGContextDrawRadialGradient(ctx, g, CGPointMake(s.width / 2, s.height * 0.35), 0, CGPointMake(s.width / 2, s.height * 0.35),
                                MAX(s.width, s.height) * 0.8, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGColorSpaceRelease(cs);
    // Vài bong bóng mờ trang trí
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.06].CGColor);
    CGRect circles[] = {{{-40, 60}, {160, 160}}, {{s.width - 90, 20}, {140, 140}}, {{s.width - 140, s.height - 200}, {220, 220}},
                        {{20, s.height - 140}, {90, 90}}};
    for (int i = 0; i < 4; i++) CGContextFillEllipseInRect(ctx, circles[i]);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)start {
    self.retry.hidden = YES;
    self.dim.hidden = YES;
    self.qr.image = nil;
    [self.spin startAnimating];
    self.status.text = @"Đang lấy mã QR…";
    [RZCore call:@"auth.qrStart" args:nil done:^(id ok, NSDictionary *err) {
        if (err) [self failed:RZErrorText(err)];
    }];
}

- (void)failed:(NSString *)msg {
    [self.spin stopAnimating];
    self.dim.hidden = NO;
    self.retry.hidden = NO;
    self.status.text = msg;
}

- (void)onEvent:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    if (![RZStr([ev objectForKey:@"e"]) isEqualToString:@"auth.qr"]) return;
    NSString *st = RZStr([ev objectForKey:@"state"]);
    if ([st isEqualToString:@"generated"]) {
        [self.spin stopAnimating];
        NSData *d = [NSData dataWithContentsOfFile:RZStr([ev objectForKey:@"path"])];
        UIImage *img = d ? [UIImage imageWithData:d] : nil;
        self.qr.image = img;
        self.status.text = img ? @"Quét mã bằng Zalo trên điện thoại" : @"Không đọc được ảnh mã QR";
    } else if ([st isEqualToString:@"scanned"]) {
        self.dim.hidden = NO;
        NSString *name = RZStr([ev objectForKey:@"name"]);
        self.status.text = name.length ? [NSString stringWithFormat:@"%@ — bấm «Đăng nhập» trên điện thoại để xác nhận", name]
                                       : @"Đã quét — xác nhận trên điện thoại";
    } else if ([st isEqualToString:@"expired"]) {
        [self failed:@"Mã QR đã hết hạn"];
    } else if ([st isEqualToString:@"declined"]) {
        [self failed:@"Đăng nhập đã bị từ chối trên điện thoại"];
    } else if ([st isEqualToString:@"error"]) {
        if ([RZStr([ev objectForKey:@"code"]) isEqualToString:@"QR_EXPIRED"]) return;
        [self failed:RZStr([ev objectForKey:@"msg"]) ?: @"Không đăng nhập được"];
    } else if ([st isEqualToString:@"done"]) {
        self.dim.hidden = NO;
        [self.spin startAnimating];
        self.status.text = @"Đang đăng nhập…";
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o {
    return UIInterfaceOrientationIsPortrait(o);
}

@end
