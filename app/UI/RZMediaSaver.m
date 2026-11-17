#import "RZMediaSaver.h"
#import "RZCore.h"
#import "RZKit.h"
#import "RZLog.h"
#import "RZTheme.h"
#import <AssetsLibrary/AssetsLibrary.h>

@interface RZMediaSaver () <UIDocumentInteractionControllerDelegate>
@property (nonatomic, strong) UIDocumentInteractionController *doc;
@end

static ALAssetsLibrary *RZLibrary(void) {
    static ALAssetsLibrary *lib;  // phải sống tới khi khối hoàn tất được gọi
    if (!lib) lib = [[ALAssetsLibrary alloc] init];
    return lib;
}

@implementation RZMediaSaver

+ (instancetype)shared {
    static RZMediaSaver *s;
    if (!s) s = [[RZMediaSaver alloc] init];
    return s;
}

+ (BOOL)canSave:(NSDictionary *)msg {
    NSString *kind = RZStr([msg objectForKey:@"kind"]);
    return [@[@"photo", @"gif", @"video", @"file", @"voice"] containsObject:kind ?: @""] && ![RZStr([msg objectForKey:@"id"]) hasPrefix:@"l"];
}

/// Địa chỉ / loại bộ đệm / đuôi gợi ý của tệp gốc trong tin.
+ (void)source:(NSDictionary *)m url:(NSString **)url kind:(NSString **)kind ext:(NSString **)ext {
    NSDictionary *media = [m objectForKey:@"media"];
    NSString *k = RZStr([m objectForKey:@"kind"]);
    *url = RZStr([media objectForKey:@"url"]);
    *ext = @"";
    if ([k isEqualToString:@"photo"] || [k isEqualToString:@"gif"]) {
        if (!(*url).length) *url = RZStr([media objectForKey:@"normal"]);
        *kind = @"photo";
    } else if ([k isEqualToString:@"video"]) {
        *kind = @"file";
        *ext = @"mp4";
    } else if ([k isEqualToString:@"voice"]) {
        *kind = @"voice";
        *ext = @"m4a";
    } else {
        *kind = @"file";
        *ext = RZStr([media objectForKey:@"ext"]) ?: [RZStr([media objectForKey:@"name"]) pathExtension];
    }
}

/// Tệp gốc trên máy: tệp mình vừa gửi từ máy này (`local`) hoặc tải qua lõi.
+ (void)fetch:(NSDictionary *)m view:(UIView *)view done:(void (^)(NSString *path))done {
    NSString *local = RZStr([[m objectForKey:@"media"] objectForKey:@"local"]);
    if (local.length && [[NSFileManager defaultManager] fileExistsAtPath:local]) {
        done(local);
        return;
    }
    NSString *url, *kind, *ext;
    [self source:m url:&url kind:&kind ext:&ext];
    if (!url.length) {
        [RZTheme toast:@"Tin này không có tệp để lưu" in:view];
        return;
    }
    [RZTheme toast:@"Đang tải về…" in:view];
    [RZCore call:@"media.fetch" args:@{@"url": url, @"kind": kind, @"ext": ext ?: @""} done:^(id ok, NSDictionary *err) {
        NSString *path = RZStr([ok objectForKey:@"path"]);
        if (!path.length) {
            [RZTheme toast:err ? RZErrorText(err) : @"Không tải được tệp" in:view];
            return;
        }
        done(path);
    }];
}

+ (void)save:(NSDictionary *)m from:(UIViewController *)vc {
    UIView *view = vc.view;
    NSString *k = RZStr([m objectForKey:@"kind"]);
    [self fetch:m view:view done:^(NSString *path) {
        if ([k isEqualToString:@"photo"] || [k isEqualToString:@"gif"]) [self saveImageFile:path in:view];
        else if ([k isEqualToString:@"video"]) [self saveVideoFile:path in:view];
        else [self saveToDocuments:path name:RZStr([[m objectForKey:@"media"] objectForKey:@"name"]) msg:m from:vc];
    }];
}

+ (void)savePhotoURL:(NSString *)url from:(UIViewController *)vc {
    UIView *view = vc.view;
    if (!url.length) return;
    [RZTheme toast:@"Đang lưu ảnh…" in:view];
    [RZCore call:@"media.fetch" args:@{@"url": url, @"kind": @"photo"} done:^(id ok, NSDictionary *err) {
        NSString *path = RZStr([ok objectForKey:@"path"]);
        if (path.length) [self saveImageFile:path in:view];
        else [RZTheme toast:err ? RZErrorText(err) : @"Không tải được ảnh" in:view];
    }];
}

+ (void)saveImageFile:(NSString *)path in:(UIView *)view {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) {
        [RZTheme toast:@"Không đọc được ảnh" in:view];
        return;
    }
    [RZLibrary() writeImageDataToSavedPhotosAlbum:data metadata:nil completionBlock:^(NSURL *assetURL, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self report:err what:@"ảnh" in:view];
        });
    }];
}

+ (void)saveVideoFile:(NSString *)path in:(UIView *)view {
    if (!UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path)) {
        [RZTheme toast:@"iOS không lưu được loại video này vào Ảnh" in:view];
        return;
    }
    [RZLibrary() writeVideoAtPathToSavedPhotosAlbum:[NSURL fileURLWithPath:path] completionBlock:^(NSURL *assetURL, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self report:err what:@"video" in:view];
        });
    }];
}

+ (void)report:(NSError *)err what:(NSString *)what in:(UIView *)view {
    if (!err) {
        RZLog(@"đã lưu %@ vào Thư viện ảnh", what);
        [RZTheme toast:[NSString stringWithFormat:@"Đã lưu %@ vào Ảnh", what] in:view];
        return;
    }
    RZLog(@"lưu %@ lỗi: %ld", what, (long)err.code);
    // -3310 / -3311: máy / người dùng không cho app truy cập Ảnh
    if (err.code == -3310 || err.code == -3311) {
        RZAlert(@"Chưa được phép lưu vào Ảnh", @"Bật trong Cài đặt → Quyền riêng tư → Ảnh → Roza rồi thử lại.");
        return;
    }
    [RZTheme toast:[NSString stringWithFormat:@"Không lưu được %@", what] in:view];
}

/// Tệp / tin thoại → Tài liệu/Roza (tên trùng thì thêm « (2)», « (3)»…).
+ (void)saveToDocuments:(NSString *)path name:(NSString *)name msg:(NSDictionary *)m from:(UIViewController *)vc {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = @"/var/mobile/Documents/Roza";
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    if (!name.length) name = [NSString stringWithFormat:@"%@.%@", RZStr([m objectForKey:@"id"]) ?: @"tep", path.pathExtension];
    name = [[name stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@":" withString:@"_"];
    NSString *dst = [dir stringByAppendingPathComponent:name];
    for (int i = 2; [fm fileExistsAtPath:dst] && i < 1000; i++) {
        NSString *base = [name stringByDeletingPathExtension], *ext = name.pathExtension;
        NSString *n = [NSString stringWithFormat:@"%@ (%d)%@%@", base, i, ext.length ? @"." : @"", ext];
        dst = [dir stringByAppendingPathComponent:n];
    }
    NSError *err = nil;
    if (![fm copyItemAtPath:path toPath:dst error:&err]) {
        [RZTheme toast:@"Không lưu được tệp" in:vc.view];
        return;
    }
    RZLog(@"đã lưu tệp vào Tài liệu/Roza");
    [RZTheme toast:[NSString stringWithFormat:@"Đã lưu vào Tài liệu/Roza/%@", dst.lastPathComponent] in:vc.view];
}

+ (void)openIn:(NSDictionary *)m from:(UIViewController *)vc anchor:(UIView *)anchor {
    [self fetch:m view:vc.view done:^(NSString *path) {
        // Tên tệp đúng (có đuôi) để app khác nhận ra loại — bộ đệm đặt tên theo mã
        NSString *name = RZStr([[m objectForKey:@"media"] objectForKey:@"name"]);
        NSString *use = path;
        if (name.length) {
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[name stringByReplacingOccurrencesOfString:@"/" withString:@"_"]];
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
            if ([[NSFileManager defaultManager] copyItemAtPath:path toPath:tmp error:NULL]) use = tmp;
        }
        RZMediaSaver *s = [self shared];
        s.doc = [UIDocumentInteractionController interactionControllerWithURL:[NSURL fileURLWithPath:use]];
        s.doc.delegate = s;
        UIView *v = anchor ?: vc.view;
        if (![s.doc presentOpenInMenuFromRect:v.bounds inView:v animated:YES])
            RZAlert(@"Không có app nào mở được tệp này", @"Đã có thể lưu tệp vào Tài liệu/Roza bằng «Lưu về máy».");
    }];
}

@end
