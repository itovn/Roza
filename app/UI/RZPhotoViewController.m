#import "RZPhotoViewController.h"
#import "RZImages.h"
#import "RZKit.h"
#import "RZMediaSaver.h"

@interface RZPhotoViewController () <UIScrollViewDelegate>
@property (nonatomic, copy) NSString *url, *thumb;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIActivityIndicatorView *spin;
@end

@implementation RZPhotoViewController

- (instancetype)initWithURL:(NSString *)url thumb:(NSString *)thumb {
    if ((self = [super init])) {
        _url = [url copy];
        _thumb = [thumb copy];
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        self.wantsFullScreenLayout = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scroll.delegate = self;
    self.scroll.maximumZoomScale = 4;
    self.scroll.showsHorizontalScrollIndicator = NO;
    self.scroll.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scroll];
    self.imageView = [[UIImageView alloc] initWithFrame:self.scroll.bounds];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.scroll addSubview:self.imageView];
    self.spin = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.spin.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2);
    self.spin.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin |
                                 UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:self.spin];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(close)];
    [self.view addGestureRecognizer:tap];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(more:)];
    [self.view addGestureRecognizer:lp];
    CGFloat scale = [UIScreen mainScreen].scale;
    CGFloat px = MAX(self.view.bounds.size.width, self.view.bounds.size.height) * scale;
    UIImage *t = [RZImages cached:self.thumb maxPixel:220 * scale round:NO];
    if (t) self.imageView.image = t;
    [self.spin startAnimating];
    __weak RZPhotoViewController *ws = self;
    [RZImages image:self.url kind:@"photo" maxPixel:MIN(px, 2048) done:^(UIImage *img) {
        [ws.spin stopAnimating];
        ws.imageView.image = img;
    }];
    [self performSelector:@selector(stopSpin) withObject:nil afterDelay:30];
}

- (void)stopSpin {
    [self.spin stopAnimating];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)sv {
    return self.imageView;
}

- (void)close {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)more:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || !self.imageView.image) return;
    RZSheet *s = [[RZSheet alloc] initWithTitle:nil];
    // Lưu bản gốc (không phải ảnh đã thu nhỏ để hiện)
    [s add:@"Lưu ảnh gốc vào Thư viện ảnh" action:^{
        [RZMediaSaver savePhotoURL:self.url from:self];
    }];
    [s showIn:self.view];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o {
    return YES;
}

@end
