#import "RZImages.h"
#import "RZCore.h"
#import "RZLog.h"
#import <ImageIO/ImageIO.h>

static NSCache *gCache;
static dispatch_queue_t gQueue;
static NSMutableDictionary *gWaiting;  // khoá → [done…] (gộp yêu cầu trùng)

@implementation RZImages

+ (void)initialize {
    if (self != [RZImages class]) return;
    gCache = [[NSCache alloc] init];
    BOOL lowRam = [NSProcessInfo processInfo].physicalMemory < 300ull * 1024 * 1024;
    gCache.totalCostLimit = (lowRam ? 8 : 24) * 1024 * 1024;
    gQueue = dispatch_queue_create("rz.images", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(gQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0));
    gWaiting = [NSMutableDictionary dictionary];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(purge)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}

+ (void)purge {
    [gCache removeAllObjects];
}

static UIImage *RZDecode(NSString *path, CGFloat maxPixel, BOOL round) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    NSDictionary *opt = @{
        (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @((int)maxPixel),
    };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opt);
    CFRelease(src);
    if (!cg) return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    UIImage *img = [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
    BOOL alpha = CGImageGetAlphaInfo(cg) != kCGImageAlphaNone && CGImageGetAlphaInfo(cg) != kCGImageAlphaNoneSkipLast &&
                 CGImageGetAlphaInfo(cg) != kCGImageAlphaNoneSkipFirst;
    CGImageRelease(cg);
    if (round) {
        CGFloat s = MIN(img.size.width, img.size.height);
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(s, s), NO, scale);
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, s, s)] addClip];
        [img drawInRect:CGRectMake((s - img.size.width) / 2, (s - img.size.height) / 2, img.size.width, img.size.height)];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    } else {
        // Vẽ sẵn ra bitmap (khỏi giải mã lần nữa trên luồng chính khi hiện)
        UIGraphicsBeginImageContextWithOptions(img.size, !alpha, scale);
        [img drawAtPoint:CGPointZero];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    return img;
}

static NSUInteger RZCost(UIImage *img) {
    return (NSUInteger)(img.size.width * img.size.height * img.scale * img.scale * 4);
}

static NSString *RZKey(NSString *url, CGFloat px, BOOL round) {
    return [NSString stringWithFormat:@"%@|%d|%d", url, (int)px, round];
}

+ (UIImage *)cached:(NSString *)url maxPixel:(CGFloat)maxPixel round:(BOOL)round {
    return url.length ? [gCache objectForKey:RZKey(url, maxPixel, round)] : nil;
}

+ (void)load:(NSString *)url kind:(NSString *)kind maxPixel:(CGFloat)px round:(BOOL)round done:(void (^)(UIImage *))done {
    if (!url.length || !done) return;
    NSString *key = RZKey(url, px, round);
    UIImage *hit = [gCache objectForKey:key];
    if (hit) {
        done(hit);
        return;
    }
    NSMutableArray *waiting = [gWaiting objectForKey:key];
    if (waiting) {
        [waiting addObject:[done copy]];
        return;
    }
    waiting = [NSMutableArray arrayWithObject:[done copy]];
    [gWaiting setObject:waiting forKey:key];
    void (^finish)(UIImage *) = ^(UIImage *img) {
        NSArray *list = [gWaiting objectForKey:key];
        [gWaiting removeObjectForKey:key];
        if (!img) return;
        [gCache setObject:img forKey:key cost:RZCost(img)];
        for (void (^d)(UIImage *) in list) d(img);
    };
    // Tệp trên máy (ảnh / ảnh bìa mình vừa gửi): giải mã luôn, khỏi qua lõi
    if ([url hasPrefix:@"/"]) {
        dispatch_async(gQueue, ^{
            UIImage *img = RZDecode(url, px, round);
            dispatch_async(dispatch_get_main_queue(), ^{
                finish(img);
            });
        });
        return;
    }
    [RZCore call:@"media.fetch" args:@{@"url": url, @"kind": kind} done:^(id ok, NSDictionary *err) {
        NSString *path = RZStr([ok objectForKey:@"path"]);
        if (!path.length) {
            finish(nil);
            return;
        }
        dispatch_async(gQueue, ^{
            UIImage *img = RZDecode(path, px, round);
            dispatch_async(dispatch_get_main_queue(), ^{
                finish(img);
            });
        });
    }];
}

+ (void)avatar:(NSString *)url size:(CGFloat)size done:(void (^)(UIImage *))done {
    [self load:url kind:@"avatar" maxPixel:size * [UIScreen mainScreen].scale round:YES done:done];
}

+ (void)image:(NSString *)url kind:(NSString *)kind maxPixel:(CGFloat)maxPixel done:(void (^)(UIImage *))done {
    [self load:url kind:kind maxPixel:maxPixel round:NO done:done];
}

+ (UIImage *)placeholderForName:(NSString *)name key:(NSString *)key size:(CGFloat)size {
    NSString *ck = [NSString stringWithFormat:@"ph|%@|%@|%d", key, name, (int)size];
    UIImage *hit = [gCache objectForKey:ck];
    if (hit) return hit;
    static const unsigned colors[] = {0x4A90E2, 0x50B848, 0xF5A623, 0x9B59B6, 0xE5534B, 0x1ABC9C, 0x3F7CC8, 0xE67E22};
    unsigned h = 0;
    for (NSUInteger i = 0; i < key.length; i++) h = h * 31 + [key characterAtIndex:i];
    unsigned c = colors[h % 8];
    UIColor *col = [UIColor colorWithRed:((c >> 16) & 255) / 255.0 green:((c >> 8) & 255) / 255.0 blue:(c & 255) / 255.0 alpha:1];
    // Chữ cái đầu của hai từ cuối (tên người Việt: tên ở cuối)
    NSArray *words = [[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] componentsSeparatedByString:@" "];
    NSMutableString *ini = [NSMutableString string];
    // Chỉ lấy chữ / số (tên nhóm như «Lớp A-1 (2026)» không được ra «(2»); bỏ từ không có chữ cái
    NSMutableArray *ws = [NSMutableArray array];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSString *w in words) {
        if ([w rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound) continue;
        NSRange r = [w rangeOfCharacterFromSet:alnum];
        if (r.location != NSNotFound) [ws addObject:[w substringWithRange:[w rangeOfComposedCharacterSequenceAtIndex:r.location]]];
    }
    if (ws.count >= 2) [ini appendString:[ws objectAtIndex:ws.count - 2]];
    if (ws.count >= 1) [ini appendString:[ws lastObject]];
    NSString *txt = ini.uppercaseString;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, col.CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, size, size));
    [[UIColor whiteColor] set];
    UIFont *f = [UIFont boldSystemFontOfSize:size * 0.36];
    CGSize ts = [txt sizeWithFont:f];
    [txt drawAtPoint:CGPointMake((size - ts.width) / 2, (size - ts.height) / 2) withFont:f];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (img) [gCache setObject:img forKey:ck cost:RZCost(img)];
    return img;
}

@end
