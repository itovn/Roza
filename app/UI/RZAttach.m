#import "RZAttach.h"
#import "RZKit.h"
#import "RZLog.h"
#import "RZVideoCompressor.h"
#import <AVFoundation/AVFoundation.h>

@interface RZAttach () <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIPopoverControllerDelegate>
@property (nonatomic, strong) UIImagePickerController *picker;
@property (nonatomic, strong) UIPopoverController *popover;
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, copy) void (^status)(NSString *);
@property (nonatomic, copy) void (^done)(NSString *, NSDictionary *);
@property (nonatomic, strong) RZAttach *selfRef;  // giữ mình sống tới khi chọn xong
@end

static NSString *RZTempPath(NSString *ext) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"rz-%lld.%@", RZNowMs(), ext]];
}

@implementation RZAttach

+ (BOOL)hasCamera {
    return [UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera];
}

+ (void)pickFrom:(UIViewController *)vc anchor:(UIView *)anchor camera:(BOOL)camera video:(BOOL)video
          status:(void (^)(NSString *))status done:(void (^)(NSString *, NSDictionary *))done {
    RZAttach *a = [[RZAttach alloc] init];
    a.host = vc;
    a.status = status;
    a.done = done;
    a.selfRef = a;
    UIImagePickerController *p = [[UIImagePickerController alloc] init];
    p.sourceType = camera ? UIImagePickerControllerSourceTypeCamera : UIImagePickerControllerSourceTypePhotoLibrary;
    // Không dùng hằng kUTType… (MobileCoreServices xung đột header của Theos — GramMini D16)
    p.mediaTypes = @[video ? @"public.movie" : @"public.image"];
    if (video) {
        p.videoQuality = UIImagePickerControllerQualityTypeMedium;
        p.videoMaximumDuration = 600;
    }
    p.delegate = a;
    a.picker = p;
    BOOL pad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
    if (pad && !camera) {
        a.popover = [[UIPopoverController alloc] initWithContentViewController:p];
        a.popover.delegate = a;
        UIView *v = anchor ?: vc.view;
        [a.popover presentPopoverFromRect:v.bounds inView:v permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
    } else {
        [vc presentViewController:p animated:YES completion:nil];
    }
}

- (void)close {
    if (self.popover) [self.popover dismissPopoverAnimated:YES];
    else [self.picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)pc {
    self.selfRef = nil;
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)p {
    [self close];
    self.selfRef = nil;
}

- (void)imagePickerController:(UIImagePickerController *)p didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [self close];
    NSURL *movie = [info objectForKey:UIImagePickerControllerMediaURL];
    if (movie) [self handleVideo:movie];
    else [self handleImage:[info objectForKey:UIImagePickerControllerOriginalImage]];
}

/// Ảnh: vẽ lại theo đúng chiều (imageOrientation), thu nhỏ cạnh dài ≤ 1280, JPEG — ở hàng nền.
- (void)handleImage:(UIImage *)img {
    if (!img) {
        self.selfRef = nil;
        return;
    }
    if (self.status) self.status(@"Đang chuẩn bị ảnh…");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CGSize s = img.size;
        CGFloat k = MIN(1.0, 1280.0 / MAX(s.width, s.height));
        CGSize t = CGSizeMake(floorf(s.width * k), floorf(s.height * k));
        UIGraphicsBeginImageContextWithOptions(t, YES, 1);
        [img drawInRect:CGRectMake(0, 0, t.width, t.height)];
        UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSData *jpg = UIImageJPEGRepresentation(out, 0.85);
        NSString *path = RZTempPath(@"jpg");
        BOOL ok = [jpg writeToFile:path atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.status) self.status(nil);
            if (ok && self.done) self.done(@"messages.sendPhoto", @{@"path": path, @"w": @((int)t.width), @"h": @((int)t.height)});
            self.selfRef = nil;
        });
    });
}

- (void)handleVideo:(NSURL *)src {
    NSString *dst = RZTempPath(@"mp4");
    if (self.status) self.status(@"Đang nén video…");
    [RZVideoCompressor compress:src to:dst progress:^(double p) {
        if (self.status) self.status([NSString stringWithFormat:@"Đang nén video %d%%", (int)(p * 100)]);
    } done:^(NSError *err) {
        // Nén lỗi → gửi bản gốc (như GramMini D16)
        NSString *path = err ? src.path : dst;
        if (err) RZLog(@"nén video lỗi: %@ — gửi bản gốc", err.localizedDescription);
        [self finishVideo:path];
    }];
}

- (void)finishVideo:(NSString *)path {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        double secs = CMTimeGetSeconds(asset.duration);
        CGSize size = CGSizeMake(640, 360);
        NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count) {
            AVAssetTrack *tr = [tracks objectAtIndex:0];
            CGSize n = CGSizeApplyAffineTransform(tr.naturalSize, tr.preferredTransform);
            size = CGSizeMake(fabs(n.width), fabs(n.height));
        }
        AVAssetImageGenerator *gen = [[AVAssetImageGenerator alloc] initWithAsset:asset];
        gen.appliesPreferredTrackTransform = YES;
        gen.maximumSize = CGSizeMake(480, 480);
        CGImageRef cg = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(MIN(1.0, secs / 2), 600) actualTime:NULL error:NULL];
        NSString *thumb = @"";
        if (cg) {
            NSData *jpg = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.8);
            CGImageRelease(cg);
            thumb = RZTempPath(@"jpg");
            if (![jpg writeToFile:thumb atomically:YES]) thumb = @"";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.status) self.status(nil);
            if (self.done)
                self.done(@"messages.sendVideo", @{@"path": path, @"thumb": thumb, @"w": @((int)size.width), @"h": @((int)size.height),
                                                    @"dur": @((long long)(secs * 1000))});
            self.selfRef = nil;
        });
    });
}

@end
