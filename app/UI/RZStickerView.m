#import "RZStickerView.h"
#import "RZCore.h"
#import "RZImages.h"
#import "RZLog.h"
#import <ImageIO/ImageIO.h>

/// Khung đã cắt của từng sticker: mã → @{frames: [UIImage], ms}. Một sticker 12 khung 130 px ≈ 0,8 MB.
static NSCache *RZFrameCache(void) {
    static NSCache *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [[NSCache alloc] init];
        BOOL lowRam = [NSProcessInfo processInfo].physicalMemory < 300ull * 1024 * 1024;
        c.totalCostLimit = (lowRam ? 6 : 16) * 1024 * 1024;
    });
    return c;
}

static dispatch_queue_t RZFrameQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("rz.sticker.frames", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(q, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    });
    return q;
}

/// Cắt dải khung ngang thành từng khung vuông (vẽ lại ra bitmap riêng — khỏi giữ ảnh rộng trong bộ nhớ đồ hoạ).
static NSArray *RZSliceSprite(NSString *path) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return nil;
    CGImageRef full = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!full) return nil;
    size_t w = CGImageGetWidth(full), h = CGImageGetHeight(full);
    size_t n = h ? w / h : 0;
    NSMutableArray *frames = nil;
    if (n >= 2 && n <= 120) {
        frames = [NSMutableArray arrayWithCapacity:n];
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        for (size_t i = 0; i < n; i++) {
            CGImageRef part = CGImageCreateWithImageInRect(full, CGRectMake(i * h, 0, h, h));
            if (!part) break;
            CGContextRef ctx = CGBitmapContextCreate(NULL, h, h, 8, h * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            if (ctx) {
                CGContextDrawImage(ctx, CGRectMake(0, 0, h, h), part);
                CGImageRef img = CGBitmapContextCreateImage(ctx);
                if (img) {
                    [frames addObject:[UIImage imageWithCGImage:img]];
                    CGImageRelease(img);
                }
                CGContextRelease(ctx);
            }
            CGImageRelease(part);
        }
        CGColorSpaceRelease(cs);
    }
    CGImageRelease(full);
    return frames.count >= 2 ? frames : nil;
}


@implementation RZStickerView {
    NSArray *_frames;
    NSUInteger _idx;
    double _ms;
    NSTimer *_timer;
    NSUInteger _gen;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.layer.contentsGravity = kCAGravityResizeAspect;
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)stop {
    _gen++;
    [_timer invalidate];
    _timer = nil;
    _frames = nil;
    _stickerId = 0;
    self.layer.contents = nil;
}

- (void)setStill:(UIImage *)img {
    if (!_frames && img) self.layer.contents = (__bridge id)img.CGImage;
}

- (void)showSticker:(long long)sid {
    if (sid == _stickerId && (_frames || self.layer.contents)) {
        [self updateTimer];
        return;
    }
    [self stop];
    _stickerId = sid;
    if (sid <= 0) return;
    NSUInteger gen = _gen;
    NSDictionary *hit = [RZFrameCache() objectForKey:@(sid)];
    if (hit) {
        [self startFrames:[hit objectForKey:@"frames"] ms:[[hit objectForKey:@"ms"] doubleValue]];
        return;
    }
    CGFloat px = MAX(self.bounds.size.width, 64) * [UIScreen mainScreen].scale;
    __weak RZStickerView *ws = self;
    [RZCore call:@"sticker.url" args:@{@"id": @(sid)} done:^(id ok, NSDictionary *err) {
        RZStickerView *me = ws;
        if (!me || gen != me->_gen) return;
        NSString *url = RZStr([ok objectForKey:@"url"]);
        NSString *sprite = RZStr([ok objectForKey:@"sprite"]);
        double ms = RZLL([ok objectForKey:@"duration"]);
        UIImage *still = [RZImages cached:url maxPixel:px round:NO];
        if (still) [me setStill:still];
        else if (url.length)
            [RZImages image:url kind:@"sticker" maxPixel:px done:^(UIImage *img) {
                RZStickerView *m2 = ws;
                if (m2 && gen == m2->_gen) [m2 setStill:img];
            }];
        if (!sprite.length) return;
        if (ms <= 0) {
            // Nhịp khung chưa đệm → hỏi chi tiết một lần (lõi đệm lại)
            [RZCore call:@"sticker.info" args:@{@"id": @(sid)} done:^(id info, NSDictionary *e2) {
                RZStickerView *m2 = ws;
                double d = RZLL([info objectForKey:@"duration"]);
                if (m2 && gen == m2->_gen && d > 0) [m2 setFrameMs:d];
            }];
        }
        [RZCore call:@"media.fetch" args:@{@"url": sprite, @"kind": @"sticker"} done:^(id f, NSDictionary *e3) {
            NSString *path = RZStr([f objectForKey:@"path"]);
            if (!path.length) return;
            dispatch_async(RZFrameQueue(), ^{
                NSArray *frames = RZSliceSprite(path);
                dispatch_async(dispatch_get_main_queue(), ^{
                    RZStickerView *m2 = ws;
                    if (!frames) return;  // sticker tĩnh (dải chỉ một khung)
                    double fms = ms > 0 ? ms : 90;
                    UIImage *f0 = [frames objectAtIndex:0];
                    NSUInteger cost = (NSUInteger)(frames.count * f0.size.width * f0.size.height * 4);
                    [RZFrameCache() setObject:@{@"frames": frames, @"ms": @(fms)} forKey:@(sid) cost:cost];
                    if (m2 && gen == m2->_gen) [m2 startFrames:frames ms:fms];
                });
            });
        }];
    }];
}

- (void)setFrameMs:(double)ms {
    _ms = MIN(MAX(ms, 40), 400);
    NSDictionary *hit = [RZFrameCache() objectForKey:@(_stickerId)];
    if (hit) [RZFrameCache() setObject:@{@"frames": [hit objectForKey:@"frames"], @"ms": @(_ms)} forKey:@(_stickerId)];
    if (_timer) {
        [_timer invalidate];
        _timer = nil;
        [self updateTimer];
    }
}

- (void)startFrames:(NSArray *)frames ms:(double)ms {
    _frames = frames;
    _ms = MIN(MAX(ms, 40), 400);
    _idx = 0;
    self.layer.contents = (__bridge id)((UIImage *)[frames objectAtIndex:0]).CGImage;
    [self updateTimer];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateTimer];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self updateTimer];
}

- (void)updateTimer {
    BOOL want = _frames.count > 1 && self.window && !self.hidden;
    if (want && !_timer) {
        // Chế độ mặc định của run loop: đứng khi đang cuộn bảng
        _timer = [NSTimer scheduledTimerWithTimeInterval:_ms / 1000.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    } else if (!want && _timer) {
        [_timer invalidate];
        _timer = nil;
    }
}

- (void)tick {
    if (!self.window || [UIApplication sharedApplication].applicationState != UIApplicationStateActive || !_frames.count) return;
    _idx = (_idx + 1) % _frames.count;
    self.layer.contents = (__bridge id)((UIImage *)[_frames objectAtIndex:_idx]).CGImage;
}

@end
