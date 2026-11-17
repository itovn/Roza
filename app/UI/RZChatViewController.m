#import "RZChatViewController.h"
#import "RZCore.h"
#import "RZImages.h"
#import "RZKit.h"
#import "RZLog.h"
#import "RZPhotoViewController.h"
#import "RZStickerPanel.h"
#import "RZStickerView.h"
#import "RZAttach.h"
#import "RZFileBrowserViewController.h"
#import "RZOpener.h"
#import "RZMediaSaver.h"
#import "RZVoice.h"
#import "RZTheme.h"

#pragma mark - Bố cục một tin

// Cờ của một hàng (tính theo tin trước / sau)
enum {
    RZFirst = 1,     // tin đầu của cụm (cùng người, cách nhau < 5 phút)
    RZLast = 2,      // tin cuối của cụm (hiện giờ)
    RZShowName = 4,  // nhóm: hiện tên người gửi
    RZSeen = 8,      // tin mình gửi cuối cùng đã được xem
    RZGroup = 16,
};

typedef struct {
    CGFloat height;
    CGRect bubble, name, quote, body, time, seen, reacts, avatar;
    BOOL bare;    // không có bong bóng (sticker)
    BOOL system;  // tin hệ thống (giữa màn, nền xám)
} RZGeo;

static UIFont *RZTextFont(void) {
    static UIFont *f;
    if (!f) f = [UIFont systemFontOfSize:16];
    return f;
}

static NSString *RZReactGlyph(NSString *icon) {
    static NSDictionary *m;
    if (!m) m = @{@"/-heart": @"❤", @"/-strong": @"👍", @":>": @"😆", @":o": @"😮", @":-((": @"😭", @":-h": @"😡"};
    return [m objectForKey:icon] ?: @"👍";
}

static NSString *RZReactText(NSDictionary *reacts) {
    if (![reacts isKindOfClass:[NSDictionary class]] || !reacts.count) return nil;
    NSMutableDictionary *cnt = [NSMutableDictionary dictionary];
    for (NSString *icon in reacts.allValues) {
        NSString *g = RZReactGlyph(icon);
        [cnt setObject:@([[cnt objectForKey:g] integerValue] + 1) forKey:g];
    }
    NSMutableString *s = [NSMutableString string];
    for (NSString *g in cnt) [s appendString:g];
    if (reacts.count > 1) [s appendFormat:@" %lu", (unsigned long)reacts.count];
    return s;
}

/// Chữ hiện trong bong bóng (tin chữ, hoặc tóm tắt cho loại chưa xem được trong app).
static NSString *RZBodyText(NSDictionary *m) {
    NSString *kind = RZStr([m objectForKey:@"kind"]);
    NSString *text = RZStr([m objectForKey:@"text"]) ?: @"";
    NSDictionary *media = [m objectForKey:@"media"];
    if ([kind isEqualToString:@"file"]) {
        long long size = RZLL([media objectForKey:@"size"]);
        NSString *sz = size > 1024 * 1024 ? [NSString stringWithFormat:@"%.1f MB", size / 1048576.0] : [NSString stringWithFormat:@"%lld KB", size / 1024];
        return [NSString stringWithFormat:@"📄 %@\n%@", RZStr([media objectForKey:@"name"]) ?: @"Tệp", sz];
    }
    if ([kind isEqualToString:@"voice"]) {
        long long d = RZLL([media objectForKey:@"dur"]) / 1000;
        if ([[m objectForKey:@"playing"] boolValue]) return [NSString stringWithFormat:@"🔊 Đang phát… %lld:%02lld", d / 60, d % 60];
        return [NSString stringWithFormat:@"🎤 Tin nhắn thoại %lld:%02lld", d / 60, d % 60];
    }
    if ([kind isEqualToString:@"video"]) return @"🎬 Video";
    if ([kind isEqualToString:@"link"]) {
        NSString *url = RZStr([media objectForKey:@"url"]) ?: @"";
        NSString *title = RZStr([media objectForKey:@"title"]) ?: @"";
        if (title.length && ![title isEqualToString:url]) return [NSString stringWithFormat:@"%@\n%@", title, url];
        return url.length ? url : text;
    }
    return text;
}

static BOOL RZIsImage(NSString *kind) {
    // Video hiện bằng ảnh bìa (+ nút phát)
    return [kind isEqualToString:@"photo"] || [kind isEqualToString:@"gif"] || [kind isEqualToString:@"video"];
}

static CGSize RZPhotoSize(NSDictionary *m, CGFloat maxW) {
    NSDictionary *media = [m objectForKey:@"media"];
    CGFloat w = RZLL([media objectForKey:@"w"]), h = RZLL([media objectForKey:@"h"]);
    CGFloat dw = MIN(maxW, 220);
    if (w <= 0 || h <= 0) return CGSizeMake(dw, dw * 0.75);
    CGFloat dh = dw * h / w;
    if (dh > 280) {
        dh = 280;
        dw = MAX(90, dh * w / h);
    }
    return CGSizeMake(dw, MAX(80, dh));
}

static RZGeo RZLayout(NSDictionary *m, CGFloat W, int flags) {
    RZGeo g;
    memset(&g, 0, sizeof g);
    NSString *kind = RZStr([m objectForKey:@"kind"]);
    BOOL out = [[m objectForKey:@"out"] boolValue];
    CGFloat top = (flags & RZFirst) ? 6 : 1;
    if ([kind isEqualToString:@"system"]) {
        g.system = YES;
        CGSize ts = [RZBodyText(m) sizeWithFont:[UIFont systemFontOfSize:13] constrainedToSize:CGSizeMake(W - 60, 1000) lineBreakMode:RZBreakWord];
        g.body = CGRectMake((W - ts.width) / 2, top + 6, ceilf(ts.width), ceilf(ts.height));
        g.bubble = CGRectInset(g.body, -10, -4);
        g.height = CGRectGetMaxY(g.bubble) + 6;
        return g;
    }
    BOOL groupIn = (flags & RZGroup) && !out;
    CGFloat avW = groupIn ? 34 + 6 : 0;
    CGFloat maxBubble = MIN(floorf(W * 0.74), 300);
    if (groupIn) maxBubble = MIN(maxBubble, W - 8 - avW - 40);
    CGFloat padH = 12, padV = 8;
    CGFloat inner = maxBubble - padH * 2;
    CGFloat y = padV;
    CGFloat contentW = 0;
    if (flags & RZShowName) {
        g.name = CGRectMake(padH, y, inner, 16);
        y += 18;
        contentW = MIN(inner, [RZStr([m objectForKey:@"name"]) sizeWithFont:[UIFont boldSystemFontOfSize:13]].width);
    }
    NSDictionary *q = [m objectForKey:@"quote"];
    if ([q isKindOfClass:[NSDictionary class]]) {
        g.quote = CGRectMake(padH, y, inner, 38);
        y += 42;
        contentW = inner;
    }
    if ([kind isEqualToString:@"sticker"]) {
        g.bare = YES;
        g.body = CGRectMake(0, 0, 130, 130);
        y = 130;
        contentW = 130;
    } else if (RZIsImage(kind)) {
        CGSize ps = RZPhotoSize(m, maxBubble - 8);
        g.body = CGRectMake(4, y == padV ? 4 : y, ps.width, ps.height);
        y = CGRectGetMaxY(g.body) + 4;
        contentW = MAX(contentW, ps.width - padH * 2 + 8);
    } else {
        NSString *txt = RZBodyText(m);
        UIFont *f = RZTextFont();
        if ([kind isEqualToString:@"recall"]) f = [UIFont italicSystemFontOfSize:15];
        CGSize ts = [txt sizeWithFont:f constrainedToSize:CGSizeMake(inner, 100000) lineBreakMode:RZBreakWord];
        g.body = CGRectMake(padH, y, ceilf(ts.width), ceilf(ts.height));
        y += ceilf(ts.height);
        contentW = MAX(contentW, ceilf(ts.width));
    }
    if ((flags & RZLast) && !g.bare) {
        CGFloat tw = out ? 56 : 36;
        g.time = CGRectMake(padH, y + 2, MAX(contentW, tw), 14);
        if (RZIsImage(kind)) g.time.origin.y = y;
        y += 16;
        contentW = MAX(contentW, tw);
    } else if (!g.bare) {
        y += padV;
    }
    CGFloat bw = g.bare ? 130 : MIN(maxBubble, contentW + padH * 2);
    if (RZIsImage(kind) && !g.name.size.width && !g.quote.size.width) bw = g.body.size.width + 8;
    CGFloat bh = g.bare ? 130 : y + ((flags & RZLast) ? 4 : 0);
    if (RZIsImage(kind) && !(flags & RZLast)) bh = CGRectGetMaxY(g.body) + 4;
    CGFloat bx = out ? W - 8 - bw : 8 + avW;
    g.bubble = CGRectMake(bx, top, bw, bh);
    // Đổi các khung con sang toạ độ của ô
    g.name = g.name.size.width ? CGRectOffset(CGRectMake(g.name.origin.x, g.name.origin.y, bw - padH * 2, 16), bx, top) : CGRectZero;
    g.quote = g.quote.size.width ? CGRectOffset(CGRectMake(g.quote.origin.x, g.quote.origin.y, bw - padH * 2, 38), bx, top) : CGRectZero;
    g.body = CGRectOffset(g.body, bx, top);
    g.time = g.time.size.width ? CGRectOffset(CGRectMake(padH, g.time.origin.y, bw - padH * 2, 14), bx, top) : CGRectZero;
    if (groupIn && (flags & RZFirst)) g.avatar = CGRectMake(8, top, 34, 34);
    CGFloat bottom = CGRectGetMaxY(g.bubble);
    if (RZReactText([m objectForKey:@"reacts"])) {
        g.reacts = CGRectMake(out ? CGRectGetMaxX(g.bubble) - 60 : bx + 8, bottom - 6, 52, 20);
        bottom = CGRectGetMaxY(g.reacts);
    }
    if (flags & RZSeen) {
        g.seen = CGRectMake(W - 8 - 80, bottom + 2, 80, 14);
        bottom = CGRectGetMaxY(g.seen);
    }
    g.height = bottom + 3;
    return g;
}

#pragma mark - Ô tin nhắn

@interface RZMsgCell : UITableViewCell
@property (nonatomic, strong) NSDictionary *msg;
@property (nonatomic, assign) int flags;
@property (nonatomic, strong) UIImageView *bubble, *photo, *avatar, *statusIcon;
@property (nonatomic, strong) UILabel *nameLabel, *body, *time, *seen, *reacts, *quoteName, *quoteText;
@property (nonatomic, strong) UIView *quoteBar;
@property (nonatomic, strong) RZStickerView *sticker;
@property (nonatomic, strong) UIImageView *playIcon;
@property (nonatomic, copy) NSString *photoURL;
@end

@implementation RZMsgCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        UIView *cv = self.contentView;
        _avatar = [[UIImageView alloc] init];
        [cv addSubview:_avatar];
        _bubble = [[UIImageView alloc] init];
        [cv addSubview:_bubble];
        _playIcon = [[UIImageView alloc] initWithImage:[RZTheme icon:@"play" color:[UIColor whiteColor] size:44]];
        _playIcon.hidden = YES;
        _sticker = [[RZStickerView alloc] initWithFrame:CGRectMake(0, 0, 130, 130)];
        _sticker.hidden = YES;
        [cv addSubview:_sticker];
        _photo = [[UIImageView alloc] init];
        _photo.contentMode = UIViewContentModeScaleAspectFill;
        _photo.clipsToBounds = YES;
        _photo.layer.cornerRadius = 10;
        _photo.backgroundColor = RZHex(RZDark() ? 0x2A3238 : 0xCAD5DD);
        [cv addSubview:_photo];
        _nameLabel = RZLabel(13, YES, RZHex(0xD2691E));
        [cv addSubview:_nameLabel];
        _quoteBar = [[UIView alloc] init];
        _quoteBar.backgroundColor = RZBlue();
        [cv addSubview:_quoteBar];
        _quoteName = RZLabel(12, YES, RZText());
        [cv addSubview:_quoteName];
        _quoteText = RZLabel(13, NO, RZTextGray());
        [cv addSubview:_quoteText];
        _body = RZLabel(16, NO, RZText());
        _body.numberOfLines = 0;
        _body.lineBreakMode = RZBreakWord;
        [cv addSubview:_body];
        _time = RZLabel(11, NO, RZTextGray());
        [cv addSubview:_time];
        _statusIcon = [[UIImageView alloc] init];
        [cv addSubview:_statusIcon];
        _seen = RZLabel(11, NO, RZTextGray());
        _seen.textAlignment = RZAlignRight;
        _seen.text = @"Đã xem";
        [cv addSubview:_seen];
        _reacts = RZLabel(12, NO, RZText());
        _reacts.textAlignment = RZAlignCenter;
        _reacts.backgroundColor = RZCellBg();
        _reacts.layer.cornerRadius = 10;
        _reacts.layer.borderColor = RZLine().CGColor;
        _reacts.layer.borderWidth = 1;
        [cv addSubview:_reacts];
    }
    return self;
}

- (void)configure:(NSDictionary *)m flags:(int)flags width:(CGFloat)W {
    self.msg = m;
    self.flags = flags;
    RZGeo g = RZLayout(m, W, flags);
    NSString *kind = RZStr([m objectForKey:@"kind"]);
    BOOL out = [[m objectForKey:@"out"] boolValue];
    // Bong bóng
    self.bubble.hidden = g.bare;
    if (g.system) {
        self.bubble.image = nil;
        self.bubble.backgroundColor = RZDark() ? [UIColor colorWithWhite:1 alpha:0.1] : [UIColor colorWithWhite:0 alpha:0.12];
        self.bubble.layer.cornerRadius = 10;
    } else {
        self.bubble.backgroundColor = nil;
        self.bubble.layer.cornerRadius = 0;
        self.bubble.image = [RZTheme bubbleOut:out tail:(flags & RZFirst) != 0];
    }
    self.bubble.frame = g.bubble;
    // Tên
    self.nameLabel.hidden = CGRectIsEmpty(g.name);
    self.nameLabel.frame = g.name;
    self.nameLabel.text = RZStr([m objectForKey:@"name"]);
    // Trích dẫn
    NSDictionary *q = [m objectForKey:@"quote"];
    BOOL hasQ = !CGRectIsEmpty(g.quote);
    self.quoteBar.hidden = self.quoteName.hidden = self.quoteText.hidden = !hasQ;
    if (hasQ) {
        self.quoteBar.frame = CGRectMake(g.quote.origin.x, g.quote.origin.y + 2, 2, g.quote.size.height - 4);
        self.quoteName.frame = CGRectMake(g.quote.origin.x + 8, g.quote.origin.y, g.quote.size.width - 8, 17);
        self.quoteText.frame = CGRectMake(g.quote.origin.x + 8, g.quote.origin.y + 18, g.quote.size.width - 8, 18);
        NSString *qn = RZStr([q objectForKey:@"name"]);
        self.quoteName.text = qn.length ? qn : @"Trả lời";
        self.quoteText.text = RZStr([q objectForKey:@"text"]);
    }
    // Nội dung
    BOOL isSticker = [kind isEqualToString:@"sticker"];
    BOOL img = RZIsImage(kind) || isSticker;
    self.photo.hidden = !img || isSticker;
    self.body.hidden = img;
    self.sticker.hidden = !isSticker;
    if (isSticker) {
        self.sticker.frame = g.body;
        [self.sticker showSticker:RZLL([[m objectForKey:@"media"] objectForKey:@"id"])];
    } else {
        [self.sticker stop];
    }
    self.playIcon.hidden = ![kind isEqualToString:@"video"];
    if (img && !isSticker) {
        self.photo.frame = g.body;
        self.photo.backgroundColor = [kind isEqualToString:@"sticker"] ? [UIColor clearColor] : RZHex(RZDark() ? 0x2A3238 : 0xCAD5DD);
        self.photo.contentMode = [kind isEqualToString:@"sticker"] ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleAspectFill;
        [self loadImage:m];
        if (!self.playIcon.hidden) {
            [self.contentView addSubview:self.playIcon];
            self.playIcon.center = CGPointMake(CGRectGetMidX(g.body), CGRectGetMidY(g.body));
        }
    } else {
        self.body.frame = g.body;
        self.body.text = RZBodyText(m);
        BOOL recall = [kind isEqualToString:@"recall"];
        self.body.font = g.system ? [UIFont systemFontOfSize:13] : (recall ? [UIFont italicSystemFontOfSize:15] : RZTextFont());
        self.body.textColor = g.system ? [UIColor whiteColor] : (recall ? RZTextGray() : RZText());
        self.body.textAlignment = g.system ? RZAlignCenter : RZAlignLeft;
        if (g.system) self.body.textColor = RZHex(RZDark() ? 0xA9B3BA : 0x4A555C);
    }
    // Giờ + trạng thái
    self.time.hidden = CGRectIsEmpty(g.time);
    self.statusIcon.hidden = YES;
    if (!self.time.hidden) {
        NSNumber *pg = [m objectForKey:@"p"];
        BOOL sending = [RZStr([m objectForKey:@"status"]) isEqualToString:@"sending"];
        self.time.text = sending && pg ? [NSString stringWithFormat:@"%d%%", (int)([pg doubleValue] * 100)] : RZTimeHM(RZLL([m objectForKey:@"ts"]));
        self.time.frame = g.time;
        self.time.textAlignment = out ? RZAlignRight : RZAlignLeft;
        if (RZIsImage(kind)) {
            self.time.textColor = [UIColor whiteColor];
            self.time.shadowColor = [UIColor colorWithWhite:0 alpha:0.6];
            self.time.shadowOffset = CGSizeMake(0, 1);
            self.time.frame = CGRectMake(g.body.origin.x + 6, CGRectGetMaxY(g.body) - 18, g.body.size.width - 12, 14);
        } else {
            self.time.textColor = RZTextGray();
            self.time.shadowColor = nil;
        }
        if (out) {
            NSString *st = RZStr([m objectForKey:@"status"]);
            UIImage *ic = nil;
            if ([st isEqualToString:@"sending"]) ic = [RZTheme icon:@"clock" color:RZTextGray() size:13];
            else if ([st isEqualToString:@"failed"]) ic = [RZTheme icon:@"warn" color:RZHex(0xE5534B) size:14];
            else ic = [RZTheme icon:@"check" color:RZBlue() size:13];
            self.statusIcon.image = ic;
            self.statusIcon.hidden = NO;
            CGRect tf = self.time.frame;
            self.statusIcon.frame = CGRectMake(CGRectGetMaxX(tf) - 14, tf.origin.y, 14, 14);
            tf.size.width -= 17;
            self.time.frame = tf;
        }
    }
    // Ảnh đại diện (nhóm, tin người khác, đầu cụm)
    self.avatar.hidden = CGRectIsEmpty(g.avatar);
    if (!self.avatar.hidden) {
        self.avatar.frame = g.avatar;
        NSString *url = RZStr([m objectForKey:@"avatar"]);
        self.avatar.image = [RZImages placeholderForName:RZStr([m objectForKey:@"name"]) key:RZStr([m objectForKey:@"from"]) size:34];
        if (url.length) {
            __weak RZMsgCell *ws = self;
            NSDictionary *mm = m;
            [RZImages avatar:url size:34 done:^(UIImage *im) {
                if (ws.msg == mm) ws.avatar.image = im;
            }];
        }
    }
    // Cảm xúc, đã xem
    NSString *rt = RZReactText([m objectForKey:@"reacts"]);
    self.reacts.hidden = rt == nil;
    if (rt) {
        self.reacts.text = rt;
        CGFloat w = [rt sizeWithFont:self.reacts.font].width + 14;
        CGRect r = g.reacts;
        if (out) r.origin.x = CGRectGetMaxX(g.bubble) - w - 6;
        r.size.width = w;
        self.reacts.frame = r;
    }
    self.seen.hidden = CGRectIsEmpty(g.seen);
    self.seen.frame = g.seen;
}

- (void)loadImage:(NSDictionary *)m {
    NSString *kind = RZStr([m objectForKey:@"kind"]);
    NSDictionary *media = [m objectForKey:@"media"];
    CGFloat px = self.photo.bounds.size.width * [UIScreen mainScreen].scale;
    if ([kind isEqualToString:@"sticker"]) {
        NSString *sid = RZStr([media objectForKey:@"id"]);
        self.photoURL = [@"sticker:" stringByAppendingString:sid ?: @""];
        self.photo.image = nil;
        NSString *tag = self.photoURL;
        __weak RZMsgCell *ws = self;
        [RZCore call:@"sticker.url" args:@{@"id": @([sid longLongValue])} done:^(id ok, NSDictionary *err) {
            NSString *url = RZStr([ok objectForKey:@"url"]);
            if (!url.length || ![ws.photoURL isEqualToString:tag]) return;
            [RZImages image:url kind:@"sticker" maxPixel:px done:^(UIImage *im) {
                if ([ws.photoURL isEqualToString:tag]) ws.photo.image = im;
            }];
        }];
        return;
    }
    BOOL vid = [kind isEqualToString:@"video"];
    NSString *url = RZStr([media objectForKey:vid ? @"thumb_local" : @"local"]);
    if (url.length && ![[NSFileManager defaultManager] fileExistsAtPath:url]) url = nil;
    if (!url.length) url = RZStr([media objectForKey:@"thumb"]);
    if (!url.length && !vid) url = RZStr([media objectForKey:@"normal"]);
    if (!url.length && !vid) url = RZStr([media objectForKey:@"url"]);
    self.photoURL = url;
    self.photo.image = [RZImages cached:url maxPixel:px round:NO];
    if (self.photo.image || !url.length) return;
    __weak RZMsgCell *ws = self;
    [RZImages image:url kind:@"thumb" maxPixel:px done:^(UIImage *im) {
        if ([ws.photoURL isEqualToString:url]) ws.photo.image = im;
    }];
}

@end

#pragma mark - Dải ngày

@interface RZDayCell : UITableViewCell
@property (nonatomic, strong) UILabel *label;
@end

@implementation RZDayCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        _label = RZLabel(12, NO, [UIColor whiteColor]);
        _label.textAlignment = RZAlignCenter;
        _label.backgroundColor = RZDark() ? [UIColor colorWithWhite:1 alpha:0.14] : [UIColor colorWithWhite:0 alpha:0.22];
        _label.layer.cornerRadius = 10;
        [self.contentView addSubview:_label];
    }
    return self;
}
- (void)setText:(NSString *)t width:(CGFloat)W {
    self.label.text = t;
    CGFloat w = [t sizeWithFont:self.label.font].width + 20;
    self.label.frame = CGRectMake((W - w) / 2, 8, w, 20);
}
@end

#pragma mark - Màn chat

@interface RZChatViewController () <UITableViewDataSource, UITableViewDelegate, UITextViewDelegate>
@property (nonatomic, copy) NSString *thread;
@property (nonatomic, copy) NSString *name, *avatarURL;
@property (nonatomic, strong) NSMutableArray *msgs;  // cũ → mới
@property (nonatomic, strong) NSArray *rows;         // @{t: day|msg, m, f}
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIView *inputBar, *replyBar;
@property (nonatomic, strong) UIImageView *fieldBg;
@property (nonatomic, strong) UITextView *field;
@property (nonatomic, strong) UILabel *placeholder, *replyLabel;
@property (nonatomic, strong) UIButton *sendBtn, *stickerBtn;
@property (nonatomic, strong) RZStickerPanel *stickers;
@property (nonatomic, strong) RZVoicePanel *voice;
@property (nonatomic, strong) UIView *activePanel;
@property (nonatomic, strong) UIButton *attachBtn;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) BOOL panelShown;
@property (nonatomic, strong) UILabel *titleLabel, *subtitleLabel;
@property (nonatomic, copy) NSString *subtitle, *seenId;
@property (nonatomic, strong) NSDictionary *replyTo;
@property (nonatomic, assign) BOOL loading, more, group;
@property (nonatomic, assign) CGFloat keyboardH;
@property (nonatomic, assign) long long lastTypingSent;
@end

@implementation RZChatViewController

- (instancetype)initWithThread:(NSString *)thread name:(NSString *)name avatar:(NSString *)avatar {
    if ((self = [super init])) {
        _thread = [thread copy];
        _name = name.length ? [name copy] : ([thread hasPrefix:@"g"] ? @"Nhóm" : @"Người dùng Zalo");
        _avatarURL = [avatar copy];
        _group = [thread hasPrefix:@"g"];
        _msgs = [NSMutableArray array];
        _rows = @[];
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = RZChatBg();
    CGRect b = self.view.bounds;
    // Tiêu đề hai dòng
    UIView *tv = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 44)];
    self.titleLabel = RZLabel(17, YES, [UIColor whiteColor]);
    self.titleLabel.textAlignment = RZAlignCenter;
    self.titleLabel.frame = CGRectMake(0, 3, 200, 22);
    self.titleLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.25];
    self.titleLabel.shadowOffset = CGSizeMake(0, -1);
    self.titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.titleLabel.text = self.name;
    [tv addSubview:self.titleLabel];
    self.subtitleLabel = RZLabel(12, NO, [UIColor colorWithWhite:1 alpha:0.85]);
    self.subtitleLabel.textAlignment = RZAlignCenter;
    self.subtitleLabel.frame = CGRectMake(0, 24, 200, 16);
    self.subtitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [tv addSubview:self.subtitleLabel];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.navigationItem.titleView = tv;

    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, b.size.height - 50) style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    [self.table addGestureRecognizer:lp];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)];
    tap.cancelsTouchesInView = NO;
    [self.table addGestureRecognizer:tap];

    [self buildInputBar];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onEvent:) name:RZCoreEventNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(voiceChanged) name:RZVoicePlayerChanged object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboard:) name:UIKeyboardWillHideNotification object:nil];

    [self loadInitial];
    [self loadSubtitle];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [RZCore call:@"messages.open" args:@{@"thread": self.thread} done:^(id ok, NSDictionary *err) {
        if ([[ok objectForKey:@"seen"] boolValue]) {
            NSDictionary *last = [self lastOutgoing];
            if (last) {
                self.seenId = RZStr([last objectForKey:@"id"]);
                [self rebuildRows];
                [self.table reloadData];
            }
        }
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.field resignFirstResponder];
    [RZCore call:@"messages.close" args:@{@"thread": self.thread} done:nil];
}

- (void)loadSubtitle {
    NSString *tid = [self.thread substringFromIndex:1];
    if (self.group) {
        [RZCore call:@"group.info" args:@{@"gid": tid} done:^(id ok, NSDictionary *err) {
            long long n = RZLL([ok objectForKey:@"members"]);
            if (RZStr([ok objectForKey:@"name"]).length) {
                self.name = RZStr([ok objectForKey:@"name"]);
                self.titleLabel.text = self.name;
            }
            self.subtitle = n > 0 ? [NSString stringWithFormat:@"%lld thành viên", n] : @"";
            self.subtitleLabel.text = self.subtitle;
        }];
    } else {
        [RZCore call:@"user.lastOnline" args:@{@"uid": tid} done:^(id ok, NSDictionary *err) {
            long long last = RZLL([ok objectForKey:@"last"]);
            if (last <= 0) return;
            if (last > 100000000000LL) last /= 1000;
            long long ago = (long long)[[NSDate date] timeIntervalSince1970] - last;
            NSString *s;
            if (ago < 120) s = @"Vừa truy cập";
            else if (ago < 3600) s = [NSString stringWithFormat:@"Truy cập %lld phút trước", ago / 60];
            else if (ago < 86400) s = [NSString stringWithFormat:@"Truy cập %lld giờ trước", ago / 3600];
            else s = [NSString stringWithFormat:@"Truy cập %lld ngày trước", ago / 86400];
            self.subtitle = s;
            self.subtitleLabel.text = s;
        }];
    }
}

#pragma mark - Ô nhập

- (void)buildInputBar {
    CGRect b = self.view.bounds;
    self.inputBar = [[UIView alloc] initWithFrame:CGRectMake(0, b.size.height - 50, b.size.width, 50)];
    self.inputBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.inputBar.backgroundColor = RZBarBg();
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, b.size.width, 1)];
    line.backgroundColor = RZBarLine();
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.inputBar addSubview:line];
    self.stickerBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.stickerBtn.frame = CGRectMake(2, 3, 42, 44);
    self.stickerBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [self.stickerBtn setImage:[RZTheme icon:@"sticker" color:RZHex(0x7D868C) size:26] forState:UIControlStateNormal];
    [self.stickerBtn setImage:[RZTheme icon:@"sticker" color:RZBlue() size:26] forState:UIControlStateSelected];
    [self.stickerBtn addTarget:self action:@selector(toggleStickers) forControlEvents:UIControlEventTouchUpInside];
    [self.inputBar addSubview:self.stickerBtn];
    self.attachBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.attachBtn.frame = CGRectMake(40, 3, 36, 44);
    self.attachBtn.autoresizingMask = UIViewAutoresizingFlexibleTopMargin;
    [self.attachBtn setImage:[RZTheme icon:@"plus" color:RZHex(0x7D868C) size:24] forState:UIControlStateNormal];
    [self.attachBtn addTarget:self action:@selector(attach) forControlEvents:UIControlEventTouchUpInside];
    [self.inputBar addSubview:self.attachBtn];
    self.fieldBg = [[UIImageView alloc] initWithImage:[RZTheme inputField]];
    self.fieldBg.frame = CGRectMake(78, 8, b.size.width - 78 - 52, 34);
    self.fieldBg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.inputBar addSubview:self.fieldBg];
    self.field = [[UITextView alloc] initWithFrame:CGRectMake(84, 9, b.size.width - 84 - 56, 32)];
    self.field.font = [UIFont systemFontOfSize:16];
    self.field.textColor = RZText();
    if (RZDark()) self.field.keyboardAppearance = UIKeyboardAppearanceAlert;  // bàn phím tối (iOS 5 / 6)
    self.field.backgroundColor = [UIColor clearColor];
    self.field.delegate = self;
    self.field.scrollsToTop = NO;
    self.field.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.field.contentInset = UIEdgeInsetsMake(-4, 0, -4, 0);
    [self.inputBar addSubview:self.field];
    self.placeholder = RZLabel(16, NO, RZHex(0xA9B1B7));
    self.placeholder.text = @"Tin nhắn";
    self.placeholder.frame = CGRectMake(92, 15, 160, 20);
    self.placeholder.userInteractionEnabled = NO;
    [self.inputBar addSubview:self.placeholder];
    self.sendBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.sendBtn.frame = CGRectMake(b.size.width - 48, 3, 44, 44);
    self.sendBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    [self.sendBtn setImage:[RZTheme icon:@"send" color:RZBlue() size:26] forState:UIControlStateNormal];
    [self.sendBtn setImage:[RZTheme icon:@"send" color:RZHex(0xB8C2C9) size:26] forState:UIControlStateDisabled];
    [self.sendBtn setImage:[RZTheme icon:@"mic" color:RZHex(0x7D868C) size:26] forState:UIControlStateNormal];
    [self.sendBtn setImage:[RZTheme icon:@"mic" color:RZBlue() size:26] forState:UIControlStateSelected];
    [self.sendBtn addTarget:self action:@selector(sendOrVoice) forControlEvents:UIControlEventTouchUpInside];
    [self.inputBar addSubview:self.sendBtn];
    [self.view addSubview:self.inputBar];
}

- (CGFloat)inputHeight {
    CGFloat h = self.field.contentSize.height;
    CGFloat line = self.field.font.lineHeight;
    h = MIN(MAX(h - 8, line), line * 5);
    return ceilf(h) + 26;
}

- (void)layoutInput:(BOOL)animated {
    CGRect b = self.view.bounds;
    CGFloat ih = [self inputHeight];
    CGFloat replyH = self.replyBar ? 40 : 0;
    void (^apply)(void) = ^{
        if (self.panelShown) self.activePanel.frame = CGRectMake(0, b.size.height - self.keyboardH, b.size.width, self.keyboardH);
        self.inputBar.frame = CGRectMake(0, b.size.height - self.keyboardH - ih, b.size.width, ih);
        if (self.replyBar) self.replyBar.frame = CGRectMake(0, self.inputBar.frame.origin.y - replyH, b.size.width, replyH);
        self.table.frame = CGRectMake(0, 0, b.size.width, b.size.height - self.keyboardH - ih - replyH);
    };
    if (animated) [UIView animateWithDuration:0.2 animations:apply];
    else apply();
}

- (void)textViewDidChange:(UITextView *)tv {
    NSString *t = [tv.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.placeholder.hidden = tv.text.length > 0;
    [self.sendBtn setImage:t.length ? [RZTheme icon:@"send" color:RZBlue() size:26] : [RZTheme icon:@"mic" color:RZHex(0x7D868C) size:26]
                  forState:UIControlStateNormal];
    BOOL bottom = [self nearBottom];
    [self layoutInput:NO];
    if (bottom) [self scrollToBottom:NO];
    long long now = RZNowMs();
    if (t.length && now - self.lastTypingSent > 4000) {
        self.lastTypingSent = now;
        [RZCore call:@"messages.typing" args:@{@"thread": self.thread} done:nil];
    }
}

- (void)keyboard:(NSNotification *)n {
    NSDictionary *info = n.userInfo;
    CGRect kb = [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    kb = [self.view convertRect:kb fromView:nil];
    BOOL show = [n.name isEqualToString:UIKeyboardWillShowNotification];
    if (!show && self.panelShown) return;  // bàn phím ẩn vì đang chuyển sang bảng sticker
    if (show && self.panelShown) [self hidePanel];
    BOOL bottom = [self nearBottom];
    self.keyboardH = show ? MAX(0, self.view.bounds.size.height - kb.origin.y) : 0;
    double dur = [[info objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:dur animations:^{
        [self layoutInput:NO];
        if (bottom) [self scrollToBottom:NO];
    }];
}

- (void)send {
    NSString *t = [self.field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return;
    NSMutableDictionary *a = [@{@"thread": self.thread, @"text": t} mutableCopy];
    NSString *reply = RZStr([self.replyTo objectForKey:@"id"]);
    if (reply.length && ![reply hasPrefix:@"l"]) [a setObject:reply forKey:@"reply_to"];
    self.field.text = @"";
    [self textViewDidChange:self.field];
    [self cancelReply];
    [RZCore call:@"messages.send" args:a done:^(id ok, NSDictionary *err) {
        if (err) RZAlert(@"Không gửi được", RZErrorText(err));
    }];
}

#pragma mark - Bảng thay bàn phím (sticker / ghi âm)

- (void)showPanel:(UIView *)panel {
    if (self.panelShown && self.activePanel == panel) {
        [self.field becomeFirstResponder];  // bàn phím hiện → keyboard: ẩn bảng
        return;
    }
    CGRect b = self.view.bounds;
    CGFloat h = b.size.height > 700 ? 264 : 216;
    if (self.panelShown && self.activePanel != panel) {
        self.activePanel.frame = CGRectMake(0, b.size.height, b.size.width, self.activePanel.bounds.size.height);
    }
    if (!panel.superview) {
        panel.frame = CGRectMake(0, b.size.height, b.size.width, h);
        panel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [self.view addSubview:panel];
    }
    self.activePanel = panel;
    self.panelShown = YES;
    self.stickerBtn.selected = panel == self.stickers;
    self.sendBtn.selected = panel == self.voice;
    BOOL bottom = [self nearBottom];
    [self.field resignFirstResponder];
    self.keyboardH = h;
    [UIView animateWithDuration:0.25 animations:^{
        [self layoutInput:NO];
        if (bottom) [self scrollToBottom:NO];
    }];
}

- (void)toggleStickers {
    if (!self.stickers) {
        self.stickers = [[RZStickerPanel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 216)];
        __weak RZChatViewController *ws = self;
        self.stickers.onPick = ^(NSDictionary *st) {
            [ws sendSticker:st];
        };
    } else if (!(self.panelShown && self.activePanel == self.stickers)) {
        [self.stickers reload];
    }
    [self showPanel:self.stickers];
}

- (void)toggleVoice {
    if (!self.voice) {
        self.voice = [[RZVoicePanel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 216)];
        __weak RZChatViewController *ws = self;
        self.voice.onRecorded = ^(NSString *path, long long ms) {
            [ws sendMedia:@"messages.sendVoice" args:@{@"path": path, @"dur": @(ms)}];
        };
    }
    [self showPanel:self.voice];
}

- (void)hidePanel {
    self.panelShown = NO;
    self.stickerBtn.selected = NO;
    self.sendBtn.selected = NO;
    CGRect b = self.view.bounds;
    UIView *p = self.activePanel;
    [UIView animateWithDuration:0.25 animations:^{
        p.frame = CGRectMake(0, b.size.height, b.size.width, p.bounds.size.height);
    }];
}

- (void)sendOrVoice {
    NSString *t = [self.field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length) [self send];
    else [self toggleVoice];
}

#pragma mark - Đính kèm

- (void)attach {
    RZSheet *s = [[RZSheet alloc] initWithTitle:nil];
    __weak RZChatViewController *ws = self;
    void (^status)(NSString *) = ^(NSString *t) {
        [ws showStatus:t];
    };
    void (^done)(NSString *, NSDictionary *) = ^(NSString *method, NSDictionary *args) {
        [ws sendMedia:method args:args];
    };
    if ([RZAttach hasCamera]) {
        [s add:@"Chụp ảnh" action:^{
            [RZAttach pickFrom:ws anchor:ws.attachBtn camera:YES video:NO status:status done:done];
        }];
    }
    [s add:@"Ảnh trong máy" action:^{
        [RZAttach pickFrom:ws anchor:ws.attachBtn camera:NO video:NO status:status done:done];
    }];
    [s add:@"Video trong máy" action:^{
        [RZAttach pickFrom:ws anchor:ws.attachBtn camera:NO video:YES status:status done:done];
    }];
    [s add:@"Tệp trong máy" action:^{
        RZFileBrowserViewController *fb = [[RZFileBrowserViewController alloc] initWithPath:nil title:@"Gửi tệp"];
        fb.onPick = ^(NSString *path) {
            [ws sendMedia:@"messages.sendFile" args:@{@"path": path}];
        };
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fb];
        [ws presentViewController:nav animated:YES completion:nil];
    }];
    [s showIn:self.view];
}

- (void)sendMedia:(NSString *)method args:(NSDictionary *)args {
    NSMutableDictionary *a = [args mutableCopy];
    [a setObject:self.thread forKey:@"thread"];
    [RZCore call:method args:a done:^(id ok, NSDictionary *err) {
        if (err) RZAlert(@"Không gửi được", RZErrorText(err));
    }];
}

/// Nhãn trạng thái nổi trên đầu bảng tin (đang nén video, đang tải tệp…); nil = ẩn.
- (void)showStatus:(NSString *)text {
    if (!self.statusLabel) {
        self.statusLabel = RZLabel(13, YES, [UIColor whiteColor]);
        self.statusLabel.textAlignment = RZAlignCenter;
        self.statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        self.statusLabel.layer.cornerRadius = 12;
        self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        [self.view addSubview:self.statusLabel];
    }
    self.statusLabel.hidden = text == nil;
    if (!text) return;
    self.statusLabel.text = text;
    CGFloat w = [text sizeWithFont:self.statusLabel.font].width + 28;
    self.statusLabel.frame = CGRectMake((self.view.bounds.size.width - w) / 2, 8, w, 24);
    [self.view bringSubviewToFront:self.statusLabel];
}

- (void)playVoice:(NSDictionary *)m {
    NSDictionary *media = [m objectForKey:@"media"];
    NSString *key = RZStr([m objectForKey:@"id"]) ?: @"";
    NSString *local = RZStr([media objectForKey:@"local"]);
    if (local.length && [[NSFileManager defaultManager] fileExistsAtPath:local]) {
        [[RZVoicePlayer shared] toggle:local key:key];
        return;
    }
    NSString *url = RZStr([media objectForKey:@"url"]);
    if (!url.length) return;
    [self showStatus:@"Đang tải tin thoại…"];
    [RZCore call:@"media.fetch" args:@{@"url": url, @"kind": @"voice", @"ext": @"m4a"} done:^(id ok, NSDictionary *err) {
        [self showStatus:nil];
        NSString *path = RZStr([ok objectForKey:@"path"]);
        if (path.length) [[RZVoicePlayer shared] toggle:path key:key];
        else RZAlert(@"Không tải được", RZErrorText(err));
    }];
}

- (void)voiceChanged {
    [self rebuildRows];
    [self.table reloadData];
}


- (void)sendSticker:(NSDictionary *)st {
    NSDictionary *a = @{@"thread": self.thread, @"id": @(RZLL([st objectForKey:@"id"])), @"cat": @(RZLL([st objectForKey:@"cat"])),
                        @"type": @(RZLL([st objectForKey:@"type"]) ?: 7)};
    [RZCore call:@"messages.sendSticker" args:a done:^(id ok, NSDictionary *err) {
        if (err) RZAlert(@"Không gửi được sticker", RZErrorText(err));
    }];
}

#pragma mark - Trả lời

- (void)startReply:(NSDictionary *)m {
    self.replyTo = m;
    if (!self.replyBar) {
        self.replyBar = [[UIView alloc] init];
        self.replyBar.backgroundColor = RZBarBg();
        self.replyBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(10, 6, 3, 28)];
        bar.backgroundColor = RZBlue();
        [self.replyBar addSubview:bar];
        self.replyLabel = RZLabel(13, NO, RZText());
        self.replyLabel.numberOfLines = 2;
        self.replyLabel.frame = CGRectMake(20, 2, self.view.bounds.size.width - 70, 36);
        self.replyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self.replyBar addSubview:self.replyLabel];
        UIButton *x = [UIButton buttonWithType:UIButtonTypeCustom];
        [x setTitle:@"✕" forState:UIControlStateNormal];
        [x setTitleColor:RZTextGray() forState:UIControlStateNormal];
        x.frame = CGRectMake(self.view.bounds.size.width - 44, 0, 40, 40);
        x.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [x addTarget:self action:@selector(cancelReply) forControlEvents:UIControlEventTouchUpInside];
        [self.replyBar addSubview:x];
        [self.view addSubview:self.replyBar];
    }
    NSString *who = [[m objectForKey:@"out"] boolValue] ? @"chính mình" : (RZStr([m objectForKey:@"name"]).length ? RZStr([m objectForKey:@"name"]) : self.name);
    self.replyLabel.text = [NSString stringWithFormat:@"Trả lời %@\n%@", who, RZBodyText(m)];
    [self layoutInput:YES];
    [self.field becomeFirstResponder];
}

- (void)cancelReply {
    self.replyTo = nil;
    [self.replyBar removeFromSuperview];
    self.replyBar = nil;
    [self layoutInput:YES];
}

#pragma mark - Dữ liệu

- (void)loadInitial {
    self.loading = YES;
    [RZCore call:@"messages.history" args:@{@"thread": self.thread, @"limit": @40} done:^(id ok, NSDictionary *err) {
        self.loading = NO;
        NSArray *list = [ok objectForKey:@"msgs"];
        if (![list isKindOfClass:[NSArray class]]) return;
        [self.msgs setArray:list];
        self.more = [[ok objectForKey:@"more"] boolValue];
        [self rebuildRows];
        [self.table reloadData];
        [self scrollToBottom:NO];
    }];
}

- (void)loadOlder {
    if (self.loading || !self.more || !self.msgs.count) return;
    self.loading = YES;
    long long before = RZLL([[self.msgs objectAtIndex:0] objectForKey:@"ts"]);
    [RZCore call:@"messages.history" args:@{@"thread": self.thread, @"limit": @40, @"before_ts": @(before)} done:^(id ok, NSDictionary *err) {
        self.loading = NO;
        NSArray *list = [ok objectForKey:@"msgs"];
        self.more = [[ok objectForKey:@"more"] boolValue] && list.count > 0;
        if (![list isKindOfClass:[NSArray class]] || !list.count) return;
        CGFloat oldH = self.table.contentSize.height, oldY = self.table.contentOffset.y;
        NSMutableArray *add = [NSMutableArray array];
        for (NSDictionary *m in list)
            if ([self indexOfId:RZStr([m objectForKey:@"id"])] == NSNotFound) [add addObject:m];
        [self.msgs insertObjects:add atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, add.count)]];
        [self rebuildRows];
        [self.table reloadData];
        [self.table layoutIfNeeded];
        self.table.contentOffset = CGPointMake(0, oldY + self.table.contentSize.height - oldH);
    }];
}

- (NSUInteger)indexOfId:(NSString *)mid {
    if (!mid.length) return NSNotFound;
    for (NSUInteger i = self.msgs.count; i > 0; i--)
        if ([RZStr([[self.msgs objectAtIndex:i - 1] objectForKey:@"id"]) isEqualToString:mid]) return i - 1;
    return NSNotFound;
}

- (NSDictionary *)lastOutgoing {
    for (NSDictionary *m in [self.msgs reverseObjectEnumerator])
        if ([[m objectForKey:@"out"] boolValue]) return m;
    return nil;
}

static BOOL RZSameCluster(NSDictionary *a, NSDictionary *b) {
    if (!a || !b) return NO;
    if ([RZStr([a objectForKey:@"kind"]) isEqualToString:@"system"] || [RZStr([b objectForKey:@"kind"]) isEqualToString:@"system"]) return NO;
    if (![RZStr([a objectForKey:@"from"]) isEqualToString:RZStr([b objectForKey:@"from"])]) return NO;
    long long ta = RZLL([a objectForKey:@"ts"]), tb = RZLL([b objectForKey:@"ts"]);
    return llabs(tb - ta) < 5 * 60 * 1000 && RZSameDay(ta, tb);
}

- (void)rebuildRows {
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:self.msgs.count + 8];
    NSDictionary *lastOut = [self lastOutgoing];
    BOOL seenLast = self.seenId.length && lastOut && [RZStr([lastOut objectForKey:@"id"]) length] &&
                    ![RZStr([lastOut objectForKey:@"id"]) hasPrefix:@"l"] &&
                    [RZStr([lastOut objectForKey:@"id"]) longLongValue] <= [self.seenId longLongValue];
    for (NSUInteger i = 0; i < self.msgs.count; i++) {
        NSDictionary *m = [self.msgs objectAtIndex:i];
        NSDictionary *prev = i > 0 ? [self.msgs objectAtIndex:i - 1] : nil;
        NSDictionary *next = i + 1 < self.msgs.count ? [self.msgs objectAtIndex:i + 1] : nil;
        long long ts = RZLL([m objectForKey:@"ts"]);
        if (!prev || !RZSameDay(RZLL([prev objectForKey:@"ts"]), ts)) [rows addObject:@{@"t": @"day", @"ts": @(ts)}];
        int f = 0;
        BOOL out = [[m objectForKey:@"out"] boolValue];
        if (!RZSameCluster(prev, m)) f |= RZFirst;
        if (!RZSameCluster(m, next)) f |= RZLast;
        if (self.group) {
            f |= RZGroup;
            if (!out && (f & RZFirst)) f |= RZShowName;
        }
        if (seenLast && m == lastOut) f |= RZSeen;
        [rows addObject:@{@"t": @"msg", @"m": m, @"f": @(f)}];
    }
    self.rows = rows;
}

- (BOOL)nearBottom {
    UITableView *t = self.table;
    return t.contentOffset.y + t.bounds.size.height >= t.contentSize.height - 80;
}

- (void)scrollToBottom:(BOOL)animated {
    if (!self.rows.count) return;
    [self.table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:self.rows.count - 1 inSection:0]
                      atScrollPosition:UITableViewScrollPositionBottom animated:animated];
}

/// Gắn ảnh đại diện / tên của người gửi (nhóm) vào tin, lấy từ lõi khi cần.
- (void)decorate:(NSDictionary *)m done:(void (^)(NSDictionary *))done {
    done(m);
}

- (void)onEvent:(NSNotification *)n {
    NSDictionary *ev = n.userInfo;
    NSString *e = RZStr([ev objectForKey:@"e"]);
    if (![RZStr([ev objectForKey:@"thread"]) isEqualToString:self.thread]) return;
    if ([e isEqualToString:@"msg.new"]) {
        NSDictionary *m = [ev objectForKey:@"msg"];
        if ([self indexOfId:RZStr([m objectForKey:@"id"])] != NSNotFound) return;
        BOOL bottom = [self nearBottom] || [[m objectForKey:@"out"] boolValue];
        // Chèn theo giờ (tin đến muộn khi đồng bộ)
        NSUInteger at = self.msgs.count;
        long long ts = RZLL([m objectForKey:@"ts"]);
        while (at > 0 && RZLL([[self.msgs objectAtIndex:at - 1] objectForKey:@"ts"]) > ts) at--;
        [self.msgs insertObject:m atIndex:at];
        [self rebuildRows];
        [self.table reloadData];
        if (bottom) [self scrollToBottom:YES];
    } else if ([e isEqualToString:@"msg.update"]) {
        NSDictionary *m = [ev objectForKey:@"msg"];
        NSString *old = RZStr([ev objectForKey:@"old_id"]);
        NSUInteger i = [self indexOfId:old.length ? old : RZStr([m objectForKey:@"id"])];
        if (i == NSNotFound && old.length) i = [self indexOfId:RZStr([m objectForKey:@"id"])];
        if (i == NSNotFound) return;
        [self.msgs replaceObjectAtIndex:i withObject:m];
        // Hai bản cùng id (tin thật về qua WebSocket trước khi HTTP trả lời) → bỏ bản trùng
        NSString *mid = RZStr([m objectForKey:@"id"]);
        for (NSUInteger k = self.msgs.count; k > 0; k--)
            if (k - 1 != i && [RZStr([[self.msgs objectAtIndex:k - 1] objectForKey:@"id"]) isEqualToString:mid]) {
                [self.msgs removeObjectAtIndex:k - 1];
                break;
            }
        [self rebuildRows];
        [self.table reloadData];
        NSDictionary *errd = [ev objectForKey:@"err"];
        if ([errd isKindOfClass:[NSDictionary class]]) RZLog(@"gửi lỗi: %@", [errd objectForKey:@"code"]);
    } else if ([e isEqualToString:@"msg.delete"]) {
        NSUInteger i = [self indexOfId:RZStr([ev objectForKey:@"id"])];
        if (i == NSNotFound) return;
        [self.msgs removeObjectAtIndex:i];
        [self rebuildRows];
        [self.table reloadData];
    } else if ([e isEqualToString:@"msg.progress"]) {
        NSUInteger i = [self indexOfId:RZStr([ev objectForKey:@"id"])];
        if (i == NSNotFound) return;
        NSMutableDictionary *m = [[self.msgs objectAtIndex:i] mutableCopy];
        [m setObject:[ev objectForKey:@"p"] ?: @0 forKey:@"p"];
        [self.msgs replaceObjectAtIndex:i withObject:m];
        [self rebuildRows];
        [self.table reloadData];
    } else if ([e isEqualToString:@"msg.seen"]) {
        self.seenId = RZStr([ev objectForKey:@"id"]);
        BOOL bottom = [self nearBottom];
        [self rebuildRows];
        [self.table reloadData];
        if (bottom) [self scrollToBottom:YES];
    } else if ([e isEqualToString:@"typing"]) {
        NSString *who = RZStr([ev objectForKey:@"name"]);
        self.subtitleLabel.text = self.group && who.length ? [NSString stringWithFormat:@"%@ đang soạn tin…", who] : @"Đang soạn tin…";
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(clearTyping) object:nil];
        [self performSelector:@selector(clearTyping) withObject:nil afterDelay:6];
    }
}

- (void)clearTyping {
    self.subtitleLabel.text = self.subtitle;
}

#pragma mark - Bảng

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.rows.count;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r = [self.rows objectAtIndex:ip.row];
    if ([[r objectForKey:@"t"] isEqualToString:@"day"]) return 36;
    return RZLayout([r objectForKey:@"m"], tv.bounds.size.width, [[r objectForKey:@"f"] intValue]).height;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r = [self.rows objectAtIndex:ip.row];
    if ([[r objectForKey:@"t"] isEqualToString:@"day"]) {
        RZDayCell *c = (RZDayCell *)[tv dequeueReusableCellWithIdentifier:@"d"];
        if (!c) c = [[RZDayCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"d"];
        [c setText:RZDayTitle(RZLL([r objectForKey:@"ts"])) width:tv.bounds.size.width];
        return c;
    }
    RZMsgCell *c = (RZMsgCell *)[tv dequeueReusableCellWithIdentifier:@"m"];
    if (!c) c = [[RZMsgCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"m"];
    NSDictionary *m = [r objectForKey:@"m"];
    int f = [[r objectForKey:@"f"] intValue];
    NSString *playing = [RZVoicePlayer shared].playingKey;
    if (playing && [RZStr([m objectForKey:@"id"]) isEqualToString:playing]) {
        NSMutableDictionary *mm = [m mutableCopy];
        [mm setObject:@YES forKey:@"playing"];
        m = mm;
    }
    if ((f & RZGroup) && ![[m objectForKey:@"out"] boolValue] && !RZStr([m objectForKey:@"name"]).length) {
        // Tên người gửi chưa có trong tin (lịch sử nhóm) → để lõi tra sau; tạm dùng mã
        NSMutableDictionary *mm = [m mutableCopy];
        [mm setObject:@"Thành viên" forKey:@"name"];
        m = mm;
    }
    [c configure:m flags:f width:tv.bounds.size.width];
    return c;
}

- (void)scrollViewDidScroll:(UIScrollView *)sv {
    if (sv.contentOffset.y < 120 && sv.isDragging) [self loadOlder];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)sv {
    [self.field resignFirstResponder];
}

#pragma mark - Chạm

- (NSDictionary *)msgAt:(CGPoint)p cell:(RZMsgCell **)outCell {
    NSIndexPath *ip = [self.table indexPathForRowAtPoint:p];
    if (!ip) return nil;
    NSDictionary *r = [self.rows objectAtIndex:ip.row];
    if (![[r objectForKey:@"t"] isEqualToString:@"msg"]) return nil;
    RZMsgCell *c = (RZMsgCell *)[self.table cellForRowAtIndexPath:ip];
    if (![c isKindOfClass:[RZMsgCell class]]) return nil;
    CGPoint inCell = [self.table convertPoint:p toView:c.contentView];
    CGRect hit = c.bubble.hidden ? (c.sticker.hidden ? c.photo.frame : c.sticker.frame) : CGRectUnion(c.bubble.frame, c.photo.hidden ? c.bubble.frame : c.photo.frame);
    if (!CGRectContainsPoint(CGRectInset(hit, -4, -4), inCell)) return nil;
    if (outCell) *outCell = c;
    return [r objectForKey:@"m"];
}

- (void)tap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    NSDictionary *m = [self msgAt:[g locationInView:self.table] cell:NULL];
    if (!m) {
        [self.field resignFirstResponder];
        if (self.panelShown) {
            [self hidePanel];
            self.keyboardH = 0;
            [UIView animateWithDuration:0.25 animations:^{
                [self layoutInput:NO];
            }];
        }
        return;
    }
    NSString *kind = RZStr([m objectForKey:@"kind"]);
    NSDictionary *media = [m objectForKey:@"media"];
    if ([RZStr([m objectForKey:@"status"]) isEqualToString:@"failed"]) {
        RZSheet *s = [[RZSheet alloc] initWithTitle:@"Tin nhắn chưa gửi được"];
        [s add:@"Gửi lại" action:^{
            [RZCore call:@"messages.retry" args:@{@"thread": self.thread, @"cid": RZStr([m objectForKey:@"cid"]) ?: @""} done:nil];
        }];
        [s addDestructive:@"Xoá" action:^{
            [RZCore call:@"messages.delete" args:@{@"thread": self.thread, @"id": RZStr([m objectForKey:@"id"]) ?: @""} done:nil];
        }];
        [s showIn:self.view];
        return;
    }
    __weak RZChatViewController *ws = self;
    if ([kind isEqualToString:@"video"]) {
        [RZOpener openVideo:m from:self status:^(NSString *t) {
            [ws showStatus:t];
        }];
        return;
    }
    if ([kind isEqualToString:@"file"]) {
        [RZOpener openFile:m from:self status:^(NSString *t) {
            [ws showStatus:t];
        }];
        return;
    }
    if ([kind isEqualToString:@"voice"]) {
        [self playVoice:m];
        return;
    }
    if (RZIsImage(kind)) {
        NSString *url = RZStr([media objectForKey:@"url"]);
        if (!url.length) url = RZStr([media objectForKey:@"normal"]);
        RZPhotoViewController *pv = [[RZPhotoViewController alloc] initWithURL:url thumb:RZStr([media objectForKey:@"thumb"])];
        [self presentViewController:pv animated:YES completion:nil];
        return;
    }
    NSString *url = nil;
    if ([kind isEqualToString:@"link"]) url = RZStr([media objectForKey:@"url"]);
    if (!url.length) {
        NSString *text = RZStr([m objectForKey:@"text"]);
        NSDataDetector *dd = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];
        NSTextCheckingResult *r = text.length ? [dd firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
        url = r.URL.absoluteString;
    }
    if (url.length) {
        RZSheet *s = [[RZSheet alloc] initWithTitle:url];
        [s add:@"Mở trong Safari" action:^{
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]];
        }];
        [s add:@"Sao chép liên kết" action:^{
            [UIPasteboard generalPasteboard].string = url;
        }];
        [s showIn:self.view];
    }
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    NSDictionary *m = [self msgAt:[g locationInView:self.table] cell:NULL];
    if (!m) return;
    NSString *kind = RZStr([m objectForKey:@"kind"]);
    NSString *mid = RZStr([m objectForKey:@"id"]) ?: @"";
    BOOL pending = [mid hasPrefix:@"l"];
    BOOL out = [[m objectForKey:@"out"] boolValue];
    if ([kind isEqualToString:@"recall"] || [kind isEqualToString:@"system"]) return;
    [self.field resignFirstResponder];
    RZSheet *s = [[RZSheet alloc] initWithTitle:nil];
    if (!pending) {
        [s add:@"Trả lời" action:^{
            [self startReply:m];
        }];
        [s add:@"Thả cảm xúc…" action:^{
            [self reactSheet:m];
        }];
    }
    if ([RZMediaSaver canSave:m]) {
        [s add:@"Lưu về máy" action:^{
            [RZMediaSaver save:m from:self];
        }];
        if ([kind isEqualToString:@"file"]) {
            [s add:@"Mở bằng app khác…" action:^{
                [RZMediaSaver openIn:m from:self anchor:self.inputBar];
            }];
        }
    }
    NSString *text = RZBodyText(m);
    if (text.length && !RZIsImage(kind) && ![@[@"file", @"voice"] containsObject:kind]) {
        [s add:@"Sao chép" action:^{
            [UIPasteboard generalPasteboard].string = text;
        }];
    }
    if (out && !pending) {
        [s add:@"Thu hồi" action:^{
            [RZCore call:@"messages.recall" args:@{@"thread": self.thread, @"id": mid} done:^(id ok, NSDictionary *err) {
                if (err) RZAlert(@"Không thu hồi được", RZErrorText(err));
            }];
        }];
    }
    [s addDestructive:@"Xoá ở phía tôi" action:^{
        [RZCore call:@"messages.delete" args:@{@"thread": self.thread, @"id": mid} done:^(id ok, NSDictionary *err) {
            if (err) RZAlert(@"Không xoá được", RZErrorText(err));
        }];
    }];
    [s showIn:self.view];
}

#ifdef DEBUG
// Lệnh thử qua SSH (Debug/RZDebug.m)
- (void)debugType:(NSString *)text {
    self.field.text = text;
    [self textViewDidChange:self.field];
}

- (void)debugSend {
    [self send];
}

- (void)debugStickers {
    [self toggleStickers];
}

- (RZStickerPanel *)debugPanel {
    return self.stickers;
}

- (NSString *)debugDump {
    NSMutableDictionary *kinds = [NSMutableDictionary dictionary];
    NSUInteger out = 0, pending = 0;
    for (NSDictionary *m in self.msgs) {
        NSString *k = RZStr([m objectForKey:@"kind"]) ?: @"?";
        [kinds setObject:@([[kinds objectForKey:k] integerValue] + 1) forKey:k];
        if ([[m objectForKey:@"out"] boolValue]) out++;
        if ([RZStr([m objectForKey:@"id"]) hasPrefix:@"l"]) pending++;
    }
    return [NSString stringWithFormat:@"%@: %lu tin (%lu của mình, %lu đang gửi), %lu hàng, loại %@, đã xem %@", [self.thread substringToIndex:1],
                                      (unsigned long)self.msgs.count, (unsigned long)out, (unsigned long)pending, (unsigned long)self.rows.count,
                                      kinds, self.seenId.length ? @"có" : @"không"];
}
#endif

- (void)reactSheet:(NSDictionary *)m {
    RZSheet *s = [[RZSheet alloc] initWithTitle:@"Thả cảm xúc"];
    NSArray *icons = @[@"/-heart", @"/-strong", @":>", @":o", @":-((", @":-h"];
    NSArray *names = @[@"❤ Tim", @"👍 Thích", @"😆 Haha", @"😮 Ngạc nhiên", @"😭 Buồn", @"😡 Giận"];
    for (NSUInteger i = 0; i < icons.count; i++) {
        NSString *icon = [icons objectAtIndex:i];
        [s add:[names objectAtIndex:i] action:^{
            [RZCore call:@"messages.react" args:@{@"thread": self.thread, @"id": RZStr([m objectForKey:@"id"]) ?: @"", @"icon": icon} done:^(id ok, NSDictionary *err) {
                if (err) RZAlert(@"Không thả được cảm xúc", RZErrorText(err));
            }];
        }];
    }
    [s showIn:self.view];
}

@end
