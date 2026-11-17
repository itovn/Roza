#import "RZTheme.h"

UIColor *RZHex(unsigned c) {
    return [UIColor colorWithRed:((c >> 16) & 255) / 255.0 green:((c >> 8) & 255) / 255.0 blue:(c & 255) / 255.0 alpha:1];
}

static int gDark = -1;  // -1 chưa đọc

BOOL RZDark(void) {
    if (gDark < 0) gDark = [[NSUserDefaults standardUserDefaults] boolForKey:@"RZDarkMode"] ? 1 : 0;
    return gDark == 1;
}

#define RZPICK(light, dark) RZHex(RZDark() ? (dark) : (light))

UIColor *RZBlue(void) { return RZPICK(0x1E8FCF, 0x3BA3E3); }
UIColor *RZText(void) { return RZPICK(0x111111, 0xE4E8EB); }
UIColor *RZTextGray(void) { return RZPICK(0x8A9399, 0x8B959D); }
UIColor *RZLine(void) { return RZPICK(0xDDE2E6, 0x2A3238); }
UIColor *RZBg(void) { return RZPICK(0xFFFFFF, 0x14181C); }
UIColor *RZCellBg(void) { return RZPICK(0xFFFFFF, 0x1B2025); }
UIColor *RZCellHi(void) { return RZPICK(0xE8F1F8, 0x27313B); }
UIColor *RZBarBg(void) { return RZPICK(0xF4F6F8, 0x1A1F24); }
UIColor *RZBarLine(void) { return RZPICK(0xCBD2D8, 0x2C343B); }
UIColor *RZChatBg(void) { return RZPICK(0xE3EBF1, 0x0F1418); }

void RZStyleTable(UITableView *tv) {
    tv.separatorColor = RZLine();
    if (tv.style == UITableViewStyleGrouped) {
        // iOS 5 / 6: bảng nhóm có nền sọc riêng (backgroundView) — chế độ tối thì bỏ, dùng màu phẳng
        if (RZDark()) {
            tv.backgroundView = nil;
            tv.backgroundColor = RZHex(0x101418);
        }
    } else {
        tv.backgroundColor = RZBg();
    }
}

void RZStyleCell(UITableViewCell *c) {
    c.backgroundColor = RZCellBg();
    c.textLabel.textColor = RZText();
    c.textLabel.backgroundColor = [UIColor clearColor];
    c.detailTextLabel.textColor = RZTextGray();
    c.detailTextLabel.backgroundColor = [UIColor clearColor];
    if (RZDark()) {
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = RZCellHi();
        c.selectedBackgroundView = sel;
    }
}

static NSDateFormatter *RZFmt(NSString *f) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSDateFormatter *d = [cache objectForKey:f];
    if (!d) {
        d = [[NSDateFormatter alloc] init];
        d.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"vi_VN"];
        d.dateFormat = f;
        [cache setObject:d forKey:f];
    }
    return d;
}

static NSDate *RZDate(long long ms) {
    return [NSDate dateWithTimeIntervalSince1970:ms / 1000.0];
}

static long long RZDayIndex(long long ms) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit fromDate:RZDate(ms)];
    return (long long)c.year * 10000 + c.month * 100 + c.day;
}

BOOL RZSameDay(long long a, long long b) {
    return RZDayIndex(a) == RZDayIndex(b);
}

static NSInteger RZDaysAgo(long long ms) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *d0 = nil, *d1 = nil;
    [cal rangeOfUnit:NSDayCalendarUnit startDate:&d0 interval:NULL forDate:RZDate(ms)];
    [cal rangeOfUnit:NSDayCalendarUnit startDate:&d1 interval:NULL forDate:[NSDate date]];
    return [[cal components:NSDayCalendarUnit fromDate:d0 toDate:d1 options:0] day];
}

NSString *RZTimeHM(long long ms) {
    return [RZFmt(@"HH:mm") stringFromDate:RZDate(ms)];
}

NSString *RZTimeShort(long long ms) {
    if (ms <= 0) return @"";
    NSInteger ago = RZDaysAgo(ms);
    if (ago <= 0) return RZTimeHM(ms);
    if (ago == 1) return @"Hôm qua";
    if (ago < 7) {
        NSInteger wd = [[[NSCalendar currentCalendar] components:NSWeekdayCalendarUnit fromDate:RZDate(ms)] weekday];
        return wd == 1 ? @"CN" : [NSString stringWithFormat:@"T%ld", (long)wd];
    }
    return [RZFmt(@"dd/MM") stringFromDate:RZDate(ms)];
}

NSString *RZDayTitle(long long ms) {
    NSInteger ago = RZDaysAgo(ms);
    if (ago == 0) return @"Hôm nay";
    if (ago == 1) return @"Hôm qua";
    static NSArray *days;
    if (!days) days = @[@"Chủ Nhật", @"Thứ Hai", @"Thứ Ba", @"Thứ Tư", @"Thứ Năm", @"Thứ Sáu", @"Thứ Bảy"];
    NSInteger wd = [[[NSCalendar currentCalendar] components:NSWeekdayCalendarUnit fromDate:RZDate(ms)] weekday];
    return [NSString stringWithFormat:@"%@, %@", [days objectAtIndex:(wd - 1) % 7], [RZFmt(@"dd/MM/yyyy") stringFromDate:RZDate(ms)]];
}

@implementation RZTheme

static NSMutableDictionary *gImgs;

+ (UIImage *)cached:(NSString *)key draw:(UIImage * (^)(void))draw {
    if (!gImgs) gImgs = [NSMutableDictionary dictionary];
    UIImage *img = [gImgs objectForKey:key];
    if (!img) {
        img = draw();
        if (img) [gImgs setObject:img forKey:key];
    }
    return img;
}

+ (UIImage *)navBackground {
    return [self cached:@"nav" draw:^UIImage * {
        CGSize s = CGSizeMake(8, 44);
        UIGraphicsBeginImageContextWithOptions(s, YES, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat light[] = {0.18, 0.62, 0.86, 1, 0.10, 0.52, 0.78, 1};
        CGFloat dark[] = {0.13, 0.18, 0.23, 1, 0.08, 0.11, 0.14, 1};
        CGFloat locs[] = {0, 1};
        CGGradientRef g = CGGradientCreateWithColorComponents(cs, RZDark() ? dark : light, locs, 2);
        CGContextDrawLinearGradient(ctx, g, CGPointZero, CGPointMake(0, s.height), 0);
        CGGradientRelease(g);
        CGColorSpaceRelease(cs);
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:RZDark() ? 0.08 : 0.25].CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, s.width, 1));
        CGContextSetFillColorWithColor(ctx, RZHex(RZDark() ? 0x05080A : 0x0D5E8E).CGColor);
        CGContextFillRect(ctx, CGRectMake(0, s.height - 1, s.width, 1));
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [img resizableImageWithCapInsets:UIEdgeInsetsMake(2, 2, 2, 2)];
    }];
}

+ (UIImage *)tabBackground {
    return [self cached:@"tabbg" draw:^UIImage * {
        CGSize s = CGSizeMake(8, 49);
        UIGraphicsBeginImageContextWithOptions(s, YES, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(ctx, RZHex(RZDark() ? 0x161A1E : 0xF8F9FA).CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, s.width, s.height));
        CGContextSetFillColorWithColor(ctx, RZHex(RZDark() ? 0x2A3238 : 0xC9D0D6).CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, s.width, 1));
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [img resizableImageWithCapInsets:UIEdgeInsetsMake(2, 2, 2, 2)];
    }];
}

+ (UIImage *)clearImage {
    return [self cached:@"clear" draw:^UIImage * {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(1, 1), NO, 0);
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

+ (void)setDark:(BOOL)dark {
    [[NSUserDefaults standardUserDefaults] setBool:dark forKey:@"RZDarkMode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    gDark = dark ? 1 : 0;
    [gImgs removeAllObjects];  // ảnh tự vẽ đã đệm theo chế độ cũ
}

+ (void)apply {
    UINavigationBar *nb = [UINavigationBar appearance];
    [nb setBackgroundImage:[self navBackground] forBarMetrics:UIBarMetricsDefault];
    nb.tintColor = RZHex(RZDark() ? 0x26323C : 0x1A7FBA);
    [nb setTitleTextAttributes:@{
        UITextAttributeTextColor: [UIColor whiteColor],
        UITextAttributeTextShadowColor: [UIColor colorWithWhite:0 alpha:0.25],
        UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, -1)],
        UITextAttributeFont: [UIFont boldSystemFontOfSize:18],
    }];
    UITabBar *tb = [UITabBar appearance];
    tb.backgroundImage = [self tabBackground];
    tb.selectionIndicatorImage = [self clearImage];
    UITabBarItem *ti = [UITabBarItem appearance];
    [ti setTitleTextAttributes:@{UITextAttributeTextColor: RZHex(RZDark() ? 0x7A848B : 0x7D868C), UITextAttributeTextShadowColor: [UIColor clearColor],
                                 UITextAttributeFont: [UIFont systemFontOfSize:10]}
                      forState:UIControlStateNormal];
    [ti setTitleTextAttributes:@{UITextAttributeTextColor: RZBlue(), UITextAttributeTextShadowColor: [UIColor clearColor],
                                 UITextAttributeFont: [UIFont boldSystemFontOfSize:10]}
                      forState:UIControlStateSelected];
    [[UISearchBar appearance] setTintColor:RZHex(RZDark() ? 0x2A3238 : 0xC8CED3)];
}

#pragma mark - Biểu tượng

static void RZPerson(CGContextRef ctx, CGFloat cx, CGFloat top, CGFloat w) {
    CGFloat head = w * 0.42;
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - head / 2, top, head, head));
    CGFloat bodyTop = top + head * 1.05;
    CGRect body = CGRectMake(cx - w / 2, bodyTop, w, w * 0.62);
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:body byRoundingCorners:UIRectCornerTopLeft | UIRectCornerTopRight
                                                  cornerRadii:CGSizeMake(w / 2, w / 2)];
    CGContextAddPath(ctx, p.CGPath);
    CGContextFillPath(ctx);
}

static void RZBubblePath(CGContextRef ctx, CGRect r) {
    CGFloat rad = r.size.height * 0.42;
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:rad];
    // Đuôi dưới trái
    [p moveToPoint:CGPointMake(r.origin.x + r.size.width * 0.22, CGRectGetMaxY(r) - 2)];
    [p addLineToPoint:CGPointMake(r.origin.x + r.size.width * 0.12, CGRectGetMaxY(r) + r.size.height * 0.28)];
    [p addLineToPoint:CGPointMake(r.origin.x + r.size.width * 0.42, CGRectGetMaxY(r) - 2)];
    [p closePath];
    CGContextAddPath(ctx, p.CGPath);
}

+ (UIImage *)tabIcon:(NSInteger)index selected:(BOOL)selected {
    NSString *key = [NSString stringWithFormat:@"tab%ld%d", (long)index, selected];
    return [self cached:key draw:^UIImage * {
        CGFloat S = 30;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(S, S), NO, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        UIColor *c = selected ? RZBlue() : RZHex(RZDark() ? 0x7A848B : 0x8E979D);
        CGContextSetFillColorWithColor(ctx, c.CGColor);
        CGContextSetStrokeColorWithColor(ctx, c.CGColor);
        CGContextSetLineWidth(ctx, 2);
        switch (index) {
            case 0: {  // Tin nhắn: bong bóng có ba chấm
                RZBubblePath(ctx, CGRectMake(3, 5, 24, 17));
                CGContextFillPath(ctx);
                CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
                for (int i = 0; i < 3; i++) CGContextFillEllipseInRect(ctx, CGRectMake(8.5 + i * 5, 12, 3, 3));
                break;
            }
            case 1: {  // Danh bạ: một người trong thẻ
                CGContextStrokeRect(ctx, CGRectMake(4, 4, 22, 23));
                RZPerson(ctx, 15, 8, 13);
                break;
            }
            case 2: {  // Nhóm: hai người
                CGContextSetFillColorWithColor(ctx, [c colorWithAlphaComponent:0.55].CGColor);
                RZPerson(ctx, 20, 6, 12);
                CGContextSetFillColorWithColor(ctx, c.CGColor);
                RZPerson(ctx, 12, 9, 15);
                break;
            }
            default: {  // Thêm: lưới 3 × 3 chấm tròn
                for (int r = 0; r < 3; r++)
                    for (int k = 0; k < 3; k++) CGContextFillEllipseInRect(ctx, CGRectMake(5 + k * 8, 5 + r * 8, 5, 5));
                break;
            }
        }
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

+ (UIImage *)bubbleOut:(BOOL)outgoing tail:(BOOL)tail {
    NSString *key = [NSString stringWithFormat:@"bub%d%d", outgoing, tail];
    return [self cached:key draw:^UIImage * {
        // 40 × 34 điểm, đuôi rộng 6 ở góc dưới; vùng co giãn ở giữa
        CGFloat W = 40, H = 34, T = 6;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(W, H), NO, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGRect r = outgoing ? CGRectMake(0.5, 0.5, W - T - 1, H - 1) : CGRectMake(T + 0.5, 0.5, W - T - 1, H - 1);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:12];
        if (tail) {
            UIBezierPath *t = [UIBezierPath bezierPath];
            if (outgoing) {
                [t moveToPoint:CGPointMake(CGRectGetMaxX(r) - 8, CGRectGetMaxY(r) - 14)];
                [t addQuadCurveToPoint:CGPointMake(W - 0.5, CGRectGetMaxY(r)) controlPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r) - 2)];
                [t addLineToPoint:CGPointMake(CGRectGetMaxX(r) - 12, CGRectGetMaxY(r))];
            } else {
                [t moveToPoint:CGPointMake(r.origin.x + 8, CGRectGetMaxY(r) - 14)];
                [t addQuadCurveToPoint:CGPointMake(0.5, CGRectGetMaxY(r)) controlPoint:CGPointMake(r.origin.x, CGRectGetMaxY(r) - 2)];
                [t addLineToPoint:CGPointMake(r.origin.x + 12, CGRectGetMaxY(r))];
            }
            [t closePath];
            [p appendPath:t];
        }
        UIColor *fill = RZHex(RZDark() ? (outgoing ? 0x1D4E6E : 0x252C32) : (outgoing ? 0xD4ECFB : 0xFFFFFF));
        UIColor *stroke = RZHex(RZDark() ? (outgoing ? 0x2A6488 : 0x323B43) : (outgoing ? 0xA9D2EC : 0xCDD5DB));
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeMake(0, 0.5), 0.5, [UIColor colorWithWhite:0 alpha:0.12].CGColor);
        [fill setFill];
        [p fill];
        CGContextRestoreGState(ctx);
        [stroke setStroke];
        p.lineWidth = 0.5;
        [p stroke];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        UIEdgeInsets caps = outgoing ? UIEdgeInsetsMake(14, 14, 16, 20) : UIEdgeInsetsMake(14, 20, 16, 14);
        return [img resizableImageWithCapInsets:caps];
    }];
}

+ (UIImage *)inputField {
    return [self cached:@"input" draw:^UIImage * {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(36, 34), NO, 0);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, 35, 33) cornerRadius:16];
        [RZHex(RZDark() ? 0x22282D : 0xFFFFFF) setFill];
        [p fill];
        [RZHex(RZDark() ? 0x343D44 : 0xC3CBD1) setStroke];
        p.lineWidth = 1;
        [p stroke];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [img resizableImageWithCapInsets:UIEdgeInsetsMake(16, 17, 16, 17)];
    }];
}

+ (UIImage *)searchField {
    return [self cached:@"searchfield" draw:^UIImage * {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(30, 30), NO, 0);
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.5, 0.5, 29, 29) cornerRadius:14.5];
        // Trên nền thanh trên (xanh / xanh than): trắng đục ở chế độ sáng, kính tối bán trong ở chế độ tối
        [(RZDark() ? [UIColor colorWithWhite:1 alpha:0.12] : [UIColor colorWithWhite:1 alpha:0.95]) setFill];
        [p fill];
        [(RZDark() ? [UIColor colorWithWhite:1 alpha:0.18] : [UIColor colorWithWhite:0 alpha:0.12]) setStroke];
        p.lineWidth = 1;
        [p stroke];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [img resizableImageWithCapInsets:UIEdgeInsetsMake(14, 14, 14, 14)];
    }];
}

+ (UIImage *)badge:(NSInteger)count {
    NSString *txt = count > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];
    return [self cached:[@"badge" stringByAppendingString:txt] draw:^UIImage * {
        UIFont *f = [UIFont boldSystemFontOfSize:12];
        CGSize ts = [txt sizeWithFont:f];
        CGFloat h = 20, w = MAX(h, ts.width + 12);
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(w, h), NO, 0);
        [RZHex(0xF0453A) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, w, h) cornerRadius:h / 2] fill];
        [[UIColor whiteColor] set];
        [txt drawAtPoint:CGPointMake((w - ts.width) / 2, (h - ts.height) / 2) withFont:f];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

+ (NSString *)sizeText:(double)b {
    if (b < 1024) return [NSString stringWithFormat:@"%d B", (int)b];
    if (b < 1048576) return [NSString stringWithFormat:@"%d KB", (int)(b / 1024)];
    NSString *s = [NSString stringWithFormat:@"%.1f %@", b < 1073741824.0 ? b / 1048576 : b / 1073741824.0, b < 1073741824.0 ? @"MB" : @"GB"];
    return [s stringByReplacingOccurrencesOfString:@"." withString:@","];
}

+ (void)toast:(NSString *)text in:(UIView *)view {
    if (!view || !text.length) return;
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont boldSystemFontOfSize:14];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    l.textAlignment = RZAlignCenter;
    l.numberOfLines = 0;
    l.layer.cornerRadius = 10;
    l.text = text;
    CGSize ts = [text sizeWithFont:l.font constrainedToSize:CGSizeMake(view.bounds.size.width - 80, 200) lineBreakMode:RZBreakWord];
    l.frame = CGRectMake((view.bounds.size.width - ts.width - 30) / 2, (view.bounds.size.height - ts.height - 20) / 2, ts.width + 30, ts.height + 20);
    l.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                         UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [view addSubview:l];
    [UIView animateWithDuration:0.3 delay:2 options:0 animations:^{
        l.alpha = 0;
    } completion:^(BOOL done) {
        [l removeFromSuperview];
    }];
}

+ (UIImage *)folderIcon {
    return [self cached:@"folder" draw:^UIImage * {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(36, 36), NO, 0);
        [RZHex(0xE8B64C) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 8, 14, 6) cornerRadius:2] fill];
        [RZHex(0xF4C95D) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 11, 30, 19) cornerRadius:3] fill];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

+ (UIImage *)fileIcon:(NSString *)ext {
    NSString *e = ext.length ? ext.uppercaseString : @"";
    if (e.length > 4) e = [e substringToIndex:4];
    return [self cached:[@"file|" stringByAppendingString:e] draw:^UIImage * {
        NSString *l = e.lowercaseString;
        unsigned c = 0x8A9399;
        if ([@[@"pdf"] containsObject:l]) c = 0xE5534B;
        else if ([@[@"doc", @"docx", @"txt", @"rtf"] containsObject:l]) c = 0x3F7CC8;
        else if ([@[@"xls", @"xlsx", @"csv"] containsObject:l]) c = 0x2E9E5B;
        else if ([@[@"ppt", @"pptx"] containsObject:l]) c = 0xE67E22;
        else if ([@[@"jpg", @"jpeg", @"png", @"gif", @"mp4", @"mov", @"m4v"] containsObject:l]) c = 0x9B59B6;
        else if ([@[@"zip", @"rar", @"7z"] containsObject:l]) c = 0x8E6E53;
        else if ([@[@"mp3", @"m4a", @"aac", @"wav", @"amr"] containsObject:l]) c = 0x1ABC9C;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(36, 36), NO, 0);
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(7, 2)];
        [p addLineToPoint:CGPointMake(23, 2)];
        [p addLineToPoint:CGPointMake(30, 9)];
        [p addLineToPoint:CGPointMake(30, 34)];
        [p addLineToPoint:CGPointMake(7, 34)];
        [p closePath];
        [RZHex(RZDark() ? 0x2A3238 : 0xF2F4F6) setFill];
        [p fill];
        [RZHex(0xB8C2C9) setStroke];
        p.lineWidth = 1;
        [p stroke];
        [RZHex(c) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(3, 18, 26, 11) cornerRadius:2] fill];
        if (e.length) {
            [[UIColor whiteColor] set];
            UIFont *f = [UIFont boldSystemFontOfSize:8];
            CGSize ts = [e sizeWithFont:f];
            [e drawAtPoint:CGPointMake(3 + (26 - ts.width) / 2, 18 + (11 - ts.height) / 2) withFont:f];
        }
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

+ (UIImage *)icon:(NSString *)name color:(UIColor *)color size:(CGFloat)S {
    CGFloat r, g, b, a;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) r = g = b = a = 0;
    NSString *key = [NSString stringWithFormat:@"ic|%@|%.2f%.2f%.2f%.2f|%d", name, r, g, b, a, (int)S];
    return [self cached:key draw:^UIImage * {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(S, S), NO, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextScaleCTM(ctx, S / 24.0, S / 24.0);  // vẽ trên lưới 24 × 24
        [color setFill];
        [color setStroke];
        CGContextSetLineWidth(ctx, 2);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        if ([name isEqualToString:@"send"]) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(3, 3)];
            [p addLineToPoint:CGPointMake(22, 12)];
            [p addLineToPoint:CGPointMake(3, 21)];
            [p addLineToPoint:CGPointMake(6, 12)];
            [p closePath];
            [p fill];
            [[UIColor whiteColor] setStroke];
            CGContextMoveToPoint(ctx, 6, 12);
            CGContextAddLineToPoint(ctx, 13, 12);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"sticker"]) {
            CGContextStrokeEllipseInRect(ctx, CGRectMake(3, 3, 18, 18));
            CGContextFillEllipseInRect(ctx, CGRectMake(8, 9, 2.6, 2.6));
            CGContextFillEllipseInRect(ctx, CGRectMake(13.4, 9, 2.6, 2.6));
            CGContextAddArc(ctx, 12, 13, 5, 0.15 * M_PI, 0.85 * M_PI, 0);
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"photo"]) {
            CGContextStrokeRect(ctx, CGRectMake(3, 5, 18, 14));
            UIBezierPath *m = [UIBezierPath bezierPath];
            [m moveToPoint:CGPointMake(4, 18)];
            [m addLineToPoint:CGPointMake(10, 11)];
            [m addLineToPoint:CGPointMake(14, 15)];
            [m addLineToPoint:CGPointMake(16, 13)];
            [m addLineToPoint:CGPointMake(20, 18)];
            [m closePath];
            [m fill];
            CGContextFillEllipseInRect(ctx, CGRectMake(15, 7.5, 3, 3));
        } else if ([name isEqualToString:@"search"]) {
            CGContextStrokeEllipseInRect(ctx, CGRectMake(4, 4, 12, 12));
            CGContextSetLineWidth(ctx, 2.5);
            CGContextMoveToPoint(ctx, 14.5, 14.5);
            CGContextAddLineToPoint(ctx, 20, 20);
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"compose"]) {
            CGContextStrokeRect(ctx, CGRectMake(3, 6, 14, 15));
            CGContextSetLineWidth(ctx, 2.5);
            CGContextMoveToPoint(ctx, 10, 14);
            CGContextAddLineToPoint(ctx, 20, 4);
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"chevron"]) {
            CGContextMoveToPoint(ctx, 9, 5);
            CGContextAddLineToPoint(ctx, 16, 12);
            CGContextAddLineToPoint(ctx, 9, 19);
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"check"] || [name isEqualToString:@"check2"]) {
            CGContextMoveToPoint(ctx, 3, 13);
            CGContextAddLineToPoint(ctx, 8, 18);
            CGContextAddLineToPoint(ctx, 17, 7);
            if ([name isEqualToString:@"check2"]) {
                CGContextMoveToPoint(ctx, 12, 17);
                CGContextAddLineToPoint(ctx, 13, 18);
                CGContextAddLineToPoint(ctx, 22, 7);
            }
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"clock"]) {
            CGContextStrokeEllipseInRect(ctx, CGRectMake(4, 4, 16, 16));
            CGContextMoveToPoint(ctx, 12, 7);
            CGContextAddLineToPoint(ctx, 12, 12);
            CGContextAddLineToPoint(ctx, 15, 14);
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"warn"]) {
            CGContextFillEllipseInRect(ctx, CGRectMake(2, 2, 20, 20));
            [[UIColor whiteColor] setFill];
            CGContextFillRect(ctx, CGRectMake(11, 6, 2.2, 8));
            CGContextFillEllipseInRect(ctx, CGRectMake(10.9, 16, 2.4, 2.4));
        } else if ([name isEqualToString:@"mute"]) {
            UIBezierPath *p = [UIBezierPath bezierPath];
            [p moveToPoint:CGPointMake(4, 9)];
            [p addLineToPoint:CGPointMake(8, 9)];
            [p addLineToPoint:CGPointMake(13, 4)];
            [p addLineToPoint:CGPointMake(13, 20)];
            [p addLineToPoint:CGPointMake(8, 15)];
            [p addLineToPoint:CGPointMake(4, 15)];
            [p closePath];
            [p fill];
            CGContextMoveToPoint(ctx, 16, 9);
            CGContextAddLineToPoint(ctx, 21, 15);
            CGContextMoveToPoint(ctx, 21, 9);
            CGContextAddLineToPoint(ctx, 16, 15);
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"pin"]) {
            CGContextFillEllipseInRect(ctx, CGRectMake(7, 3, 10, 10));
            CGContextMoveToPoint(ctx, 12, 12);
            CGContextAddLineToPoint(ctx, 12, 21);
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"group"]) {
            RZPerson(ctx, 15.5, 4, 10);
            RZPerson(ctx, 9, 7, 12);
        } else if ([name isEqualToString:@"play"]) {
            // Nút phát trên ảnh bìa video: đĩa tối bán trong + tam giác
            [[UIColor colorWithWhite:0 alpha:0.45] setFill];
            CGContextFillEllipseInRect(ctx, CGRectMake(1, 1, 22, 22));
            [color setFill];
            UIBezierPath *t = [UIBezierPath bezierPath];
            [t moveToPoint:CGPointMake(9.5, 7)];
            [t addLineToPoint:CGPointMake(17.5, 12)];
            [t addLineToPoint:CGPointMake(9.5, 17)];
            [t closePath];
            [t fill];
        } else if ([name isEqualToString:@"plus"]) {
            CGContextStrokeEllipseInRect(ctx, CGRectMake(3, 3, 18, 18));
            CGContextMoveToPoint(ctx, 12, 7.5);
            CGContextAddLineToPoint(ctx, 12, 16.5);
            CGContextMoveToPoint(ctx, 7.5, 12);
            CGContextAddLineToPoint(ctx, 16.5, 12);
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"mic"]) {
            UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(9, 3, 6, 11) cornerRadius:3];
            [body fill];
            CGContextAddArc(ctx, 12, 10.5, 6, 0, M_PI, 0);
            CGContextMoveToPoint(ctx, 12, 16.5);
            CGContextAddLineToPoint(ctx, 12, 20);
            CGContextMoveToPoint(ctx, 8.5, 20.5);
            CGContextAddLineToPoint(ctx, 15.5, 20.5);
            CGContextStrokePath(ctx);
        } else if ([name isEqualToString:@"qr"]) {
            for (int i = 0; i < 3; i++) {
                CGFloat x = i == 1 ? 14 : 3, y = i == 2 ? 14 : 3;
                CGContextStrokeRect(ctx, CGRectMake(x + 1, y + 1, 5, 5));
            }
            CGContextFillRect(ctx, CGRectMake(15, 15, 3, 3));
            CGContextFillRect(ctx, CGRectMake(19, 19, 3, 3));
            CGContextFillRect(ctx, CGRectMake(19, 14, 3, 3));
        }
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return img;
    }];
}

@end
