#import "RZStickerPanel.h"
#import "RZCore.h"
#import "RZImages.h"
#import "RZKit.h"
#import "RZTheme.h"

/// Ảnh một sticker: URL có sẵn trong danh sách (cả bộ / tìm) hoặc hỏi lõi (`sticker.url`).
static void RZStickerImage(NSDictionary *st, CGFloat px, void (^done)(UIImage *)) {
    NSString *url = RZStr([st objectForKey:@"url"]);
    void (^load)(NSString *) = ^(NSString *u) {
        if (u.length) [RZImages image:u kind:@"sticker" maxPixel:px done:done];
    };
    if (url.length) {
        load(url);
        return;
    }
    [RZCore call:@"sticker.url" args:@{@"id": @(RZLL([st objectForKey:@"id"]))} done:^(id ok, NSDictionary *err) {
        load(RZStr([ok objectForKey:@"url"]));
    }];
}

@interface RZStickerPanel () <UIAlertViewDelegate>
@property (nonatomic, strong) UIScrollView *tabsBar, *grid;
@property (nonatomic, strong) NSArray *cats;           // @[@{cat, id, type}]
@property (nonatomic, assign) NSInteger tab;           // 0 Gần đây, 1…n bộ, n+1 Tìm
@property (nonatomic, strong) NSArray *items;          // sticker đang hiện
@property (nonatomic, strong) UILabel *empty;
@property (nonatomic, assign) NSUInteger gen;          // bỏ kết quả cũ khi đổi thẻ
@property (nonatomic, copy) NSString *query;
@end

@implementation RZStickerPanel

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = RZBarBg();
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 1)];
        line.backgroundColor = RZBarLine();
        line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:line];
        _tabsBar = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 1, frame.size.width, 38)];
        _tabsBar.showsHorizontalScrollIndicator = NO;
        _tabsBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _tabsBar.backgroundColor = RZCellBg();
        [self addSubview:_tabsBar];
        _grid = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 39, frame.size.width, frame.size.height - 39)];
        _grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _grid.alwaysBounceVertical = YES;
        [self addSubview:_grid];
        _empty = RZLabel(14, NO, RZTextGray());
        _empty.numberOfLines = 0;
        _empty.lineBreakMode = RZBreakWord;
        _empty.textAlignment = RZAlignCenter;
        _empty.frame = CGRectMake(20, 20, frame.size.width - 40, 80);
        _empty.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [_grid addSubview:_empty];
        _cats = @[];
        _items = @[];
        [self reload];
    }
    return self;
}

- (void)reload {
    [RZCore call:@"stickers.cats" args:nil done:^(id ok, NSDictionary *err) {
        self.cats = [ok isKindOfClass:[NSArray class]] ? ok : @[];
        [self buildTabs];
        if (self.tab > (NSInteger)self.cats.count + 1) self.tab = 0;
        [self showTab:self.tab];
    }];
}

- (void)buildTabs {
    for (UIView *v in self.tabsBar.subviews) [v removeFromSuperview];
    CGFloat x = 0, h = self.tabsBar.bounds.size.height;
    NSInteger n = (NSInteger)self.cats.count + 2;
    for (NSInteger i = 0; i < n; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i;
        CGFloat w = 48;
        if (i == 0) {
            [b setImage:[RZTheme icon:@"clock" color:RZHex(0x7D868C) size:22] forState:UIControlStateNormal];
        } else if (i == n - 1) {
            [b setImage:[RZTheme icon:@"search" color:RZHex(0x7D868C) size:22] forState:UIControlStateNormal];
        } else {
            NSDictionary *c = [self.cats objectAtIndex:i - 1];
            __weak UIButton *wb = b;
            RZStickerImage(c, 30 * [UIScreen mainScreen].scale, ^(UIImage *img) {
                [wb setImage:img forState:UIControlStateNormal];
            });
            b.imageEdgeInsets = UIEdgeInsetsMake(5, 10, 5, 10);
            b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        }
        b.frame = CGRectMake(x, 0, w, h);
        b.backgroundColor = i == self.tab ? RZCellHi() : [UIColor clearColor];
        [b addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.tabsBar addSubview:b];
        x += w;
    }
    self.tabsBar.contentSize = CGSizeMake(x, h);
}

- (void)tabTapped:(UIButton *)b {
    [self selectTab:b.tag];
}

- (void)selectTab:(NSInteger)t {
    self.tab = t;
    for (UIView *v in self.tabsBar.subviews) v.backgroundColor = v.tag == self.tab ? RZCellHi() : [UIColor clearColor];
    [self showTab:self.tab];
}

#ifdef DEBUG
- (void)debugSearch:(NSString *)q {
    [self selectTab:(NSInteger)self.cats.count + 1];
    [self search:q];
}

- (void)debugPick:(NSInteger)i {
    if (i >= 0 && i < (NSInteger)self.items.count && self.onPick) self.onPick([self.items objectAtIndex:i]);
}

- (NSUInteger)debugCount {
    return self.items.count;
}
#endif

- (void)showTab:(NSInteger)t {
    NSUInteger gen = ++self.gen;
    NSInteger n = (NSInteger)self.cats.count + 2;
    [self setItems:@[] note:@"Đang tải…"];
    if (t == 0) {
        [RZCore call:@"stickers.recent" args:nil done:^(id ok, NSDictionary *err) {
            if (gen != self.gen) return;
            NSArray *a = [ok isKindOfClass:[NSArray class]] ? ok : @[];
            if (!a.count) {
                // Chưa gửi / nhận sticker nào → mở luôn phần gợi ý từ khoá
                [self selectTab:(NSInteger)self.cats.count + 1];
                return;
            }
            [self setItems:a note:nil];
        }];
    } else if (t == n - 1) {
        [self showSearch];
    } else {
        NSDictionary *c = [self.cats objectAtIndex:t - 1];
        [RZCore call:@"stickers.category" args:@{@"cat": @(RZLL([c objectForKey:@"cat"]))} done:^(id ok, NSDictionary *err) {
            if (gen != self.gen) return;
            NSArray *a = [ok isKindOfClass:[NSArray class]] ? ok : @[];
            [self setItems:a note:err ? RZErrorText(err) : (a.count ? nil : @"Bộ sticker trống")];
        }];
    }
}

/// Thẻ «Tìm»: các chữ gợi ý (khỏi bật bàn phím che bảng) + «Khác…» (hộp nhập).
- (void)showSearch {
    for (UIView *v in self.grid.subviews)
        if (v != self.empty) [v removeFromSuperview];
    self.empty.hidden = YES;
    NSArray *words = @[@"hi", @"haha", @"yêu", @"buồn", @"ok", @"cảm ơn", @"chúc ngủ ngon", @"giận", @"hihi", @"bye", @"Khác…"];
    CGFloat x = 10, y = 10, W = self.grid.bounds.size.width;
    UIFont *f = [UIFont systemFontOfSize:15];
    for (NSString *w in words) {
        CGFloat bw = [w sizeWithFont:f].width + 24;
        if (x + bw > W - 10) {
            x = 10;
            y += 40;
        }
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(x, y, bw, 32);
        b.titleLabel.font = f;
        [b setTitle:w forState:UIControlStateNormal];
        [b setTitleColor:RZBlue() forState:UIControlStateNormal];
        b.backgroundColor = RZCellBg();
        b.layer.cornerRadius = 16;
        b.layer.borderColor = RZBarLine().CGColor;
        b.layer.borderWidth = 1;
        [b addTarget:self action:@selector(word:) forControlEvents:UIControlEventTouchUpInside];
        [self.grid addSubview:b];
        x += bw + 8;
    }
    self.grid.contentSize = CGSizeMake(W, y + 50);
    self.grid.contentOffset = CGPointZero;
}

- (void)word:(UIButton *)b {
    NSString *w = [b titleForState:UIControlStateNormal];
    if ([w isEqualToString:@"Khác…"]) {
        UIAlertView *av = [[UIAlertView alloc] initWithTitle:@"Tìm sticker" message:nil delegate:self cancelButtonTitle:@"Huỷ" otherButtonTitles:@"Tìm", nil];
        av.alertViewStyle = UIAlertViewStylePlainTextInput;
        [av textFieldAtIndex:0].placeholder = @"vd. mèo, chào, sinh nhật";
        [av show];
        return;
    }
    [self search:w];
}

- (void)alertView:(UIAlertView *)av didDismissWithButtonIndex:(NSInteger)i {
    if (i != av.cancelButtonIndex) [self search:[av textFieldAtIndex:0].text];
}

- (void)search:(NSString *)q {
    q = [q stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return;
    NSUInteger gen = ++self.gen;
    [self setItems:@[] note:@"Đang tìm…"];
    [RZCore call:@"stickers.search" args:@{@"q": q} done:^(id ok, NSDictionary *err) {
        if (gen != self.gen) return;
        NSArray *a = [ok isKindOfClass:[NSArray class]] ? ok : @[];
        [self setItems:a note:err ? RZErrorText(err) : (a.count ? nil : [NSString stringWithFormat:@"Không có sticker cho «%@»", q])];
        if (a.count) [self addBackToWords];
    }];
}

- (void)addBackToWords {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:@"‹ Từ khoá khác" forState:UIControlStateNormal];
    [b setTitleColor:RZBlue() forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14];
    CGFloat h = self.grid.contentSize.height;
    b.frame = CGRectMake(10, h, 160, 36);
    [b addTarget:self action:@selector(showSearch) forControlEvents:UIControlEventTouchUpInside];
    [self.grid addSubview:b];
    self.grid.contentSize = CGSizeMake(self.grid.bounds.size.width, h + 44);
}

- (void)setItems:(NSArray *)items note:(NSString *)note {
    self.items = items;
    for (UIView *v in self.grid.subviews)
        if (v != self.empty) [v removeFromSuperview];
    self.empty.hidden = note == nil;
    self.empty.text = note;
    CGFloat W = self.grid.bounds.size.width;
    NSInteger cols = MAX(4, (NSInteger)(W / 80));
    CGFloat cw = W / cols, ch = 76;
    CGFloat px = 64 * [UIScreen mainScreen].scale;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *st = [items objectAtIndex:i];
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = (NSInteger)i;
        b.frame = CGRectMake((i % cols) * cw, (i / cols) * ch + 4, cw, ch);
        b.imageView.contentMode = UIViewContentModeScaleAspectFit;
        b.imageEdgeInsets = UIEdgeInsetsMake(6, (cw - 64) / 2, 6, (cw - 64) / 2);
        [b addTarget:self action:@selector(picked:) forControlEvents:UIControlEventTouchUpInside];
        [self.grid addSubview:b];
        __weak UIButton *wb = b;
        RZStickerImage(st, px, ^(UIImage *img) {
            [wb setImage:img forState:UIControlStateNormal];
        });
    }
    NSUInteger rows = (items.count + cols - 1) / cols;
    self.grid.contentSize = CGSizeMake(W, MAX(rows * ch + 8, note ? 100 : 0));
    self.grid.contentOffset = CGPointZero;
}

- (void)picked:(UIButton *)b {
    if (b.tag < 0 || b.tag >= (NSInteger)self.items.count) return;
    NSDictionary *st = [self.items objectAtIndex:b.tag];
    if (self.onPick) self.onPick(st);
}

@end
