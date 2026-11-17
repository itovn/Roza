#import "RZOpener.h"
#import "RZCore.h"
#import "RZKit.h"
#import "RZLog.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuickLook/QuickLook.h>

@interface RZPreviewSource : NSObject <QLPreviewControllerDataSource, QLPreviewControllerDelegate>
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) RZPreviewSource *selfRef;
@end

@implementation RZPreviewSource
- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)c {
    return 1;
}
- (id<QLPreviewItem>)previewController:(QLPreviewController *)c previewItemAtIndex:(NSInteger)i {
    return self.url;
}
- (void)previewControllerDidDismiss:(QLPreviewController *)c {
    self.selfRef = nil;
}
@end

@implementation RZOpener

/// Tệp mình vừa gửi từ máy còn đường dẫn gốc (`local`) → mở luôn, khỏi tải.
static NSString *RZLocalPath(NSDictionary *media) {
    NSString *p = RZStr([media objectForKey:@"local"]);
    return p.length && [[NSFileManager defaultManager] fileExistsAtPath:p] ? p : nil;
}

+ (void)fetch:(NSDictionary *)msg kind:(NSString *)kind status:(void (^)(NSString *))status done:(void (^)(NSString *path))done {
    NSDictionary *media = [msg objectForKey:@"media"];
    NSString *local = RZLocalPath(media);
    if (local) {
        done(local);
        return;
    }
    NSString *url = RZStr([media objectForKey:@"url"]);
    if (!url.length) {
        RZAlert(@"Không mở được", @"Tin này không có địa chỉ tệp.");
        return;
    }
    NSString *ext = RZStr([media objectForKey:@"ext"]);
    if (!ext.length) ext = [RZStr([media objectForKey:@"name"]) pathExtension];
    if (status) status(@"Đang tải…");
    [RZCore call:@"media.fetch" args:@{@"url": url, @"kind": kind, @"ext": ext ?: @""} done:^(id ok, NSDictionary *err) {
        if (status) status(nil);
        NSString *path = RZStr([ok objectForKey:@"path"]);
        if (!path.length) {
            RZAlert(@"Không tải được", err ? RZErrorText(err) : @"Có lỗi khi tải tệp.");
            return;
        }
        done(path);
    }];
}

+ (void)openVideo:(NSDictionary *)msg from:(UIViewController *)vc status:(void (^)(NSString *))status {
    [self fetch:msg kind:@"file" status:status done:^(NSString *path) {
        MPMoviePlayerViewController *p = [[MPMoviePlayerViewController alloc] initWithContentURL:[NSURL fileURLWithPath:path]];
        [vc presentMoviePlayerViewControllerAnimated:p];
    }];
}

+ (void)openFile:(NSDictionary *)msg from:(UIViewController *)vc status:(void (^)(NSString *))status {
    [self fetch:msg kind:@"file" status:status done:^(NSString *path) {
        NSURL *u = [NSURL fileURLWithPath:path];
        if (![QLPreviewController canPreviewItem:u]) {
            RZAlert(@"Không xem được trên máy", [NSString stringWithFormat:@"Đã tải về:\n%@", path]);
            [UIPasteboard generalPasteboard].string = path;
            return;
        }
        RZPreviewSource *src = [[RZPreviewSource alloc] init];
        src.url = u;
        src.selfRef = src;
        QLPreviewController *q = [[QLPreviewController alloc] init];
        q.dataSource = src;
        q.delegate = src;
        [vc presentViewController:q animated:YES completion:nil];
    }];
}

@end
