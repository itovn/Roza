#import "RZVoice.h"
#import "RZKit.h"
#import "RZLog.h"
#import "RZTheme.h"
#import <AVFoundation/AVFoundation.h>

NSString *const RZVoicePlayerChanged = @"RZVoicePlayerChanged";

#pragma mark - Ghi âm

@interface RZVoicePanel ()
@property (nonatomic, strong) UIButton *mic;
@property (nonatomic, strong) UILabel *hint, *timeLabel;
@property (nonatomic, strong) AVAudioRecorder *recorder;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *path;
@end

@implementation RZVoicePanel

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = RZBarBg();
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 1)];
        line.backgroundColor = RZBarLine();
        line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:line];
        CGFloat W = frame.size.width, H = frame.size.height, d = 110;
        _timeLabel = RZLabel(22, YES, RZText());
        _timeLabel.textAlignment = RZAlignCenter;
        _timeLabel.frame = CGRectMake(0, 12, W, 28);
        _timeLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _timeLabel.text = @"0:00";
        [self addSubview:_timeLabel];
        _mic = [UIButton buttonWithType:UIButtonTypeCustom];
        _mic.frame = CGRectMake((W - d) / 2, (H - d) / 2 + 6, d, d);
        _mic.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        [_mic setImage:[self micImage:d active:NO] forState:UIControlStateNormal];
        [_mic setImage:[self micImage:d active:YES] forState:UIControlStateHighlighted];
        [_mic addTarget:self action:@selector(down) forControlEvents:UIControlEventTouchDown];
        [_mic addTarget:self action:@selector(upInside) forControlEvents:UIControlEventTouchUpInside];
        [_mic addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [_mic addTarget:self action:@selector(dragExit) forControlEvents:UIControlEventTouchDragExit];
        [_mic addTarget:self action:@selector(dragEnter) forControlEvents:UIControlEventTouchDragEnter];
        [self addSubview:_mic];
        _hint = RZLabel(13, NO, RZTextGray());
        _hint.textAlignment = RZAlignCenter;
        _hint.frame = CGRectMake(0, H - 28, W, 20);
        _hint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        _hint.text = @"Giữ để ghi âm · thả để gửi";
        [self addSubview:_hint];
    }
    return self;
}

- (UIImage *)micImage:(CGFloat)d active:(BOOL)active {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(d, d), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [(active ? RZHex(0xE5534B) : RZBlue()) setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, d, d));
    // Micro: thân bo tròn + chân đế
    [[UIColor whiteColor] setFill];
    [[UIColor whiteColor] setStroke];
    CGFloat w = d * 0.2, h = d * 0.34;
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake((d - w) / 2, d * 0.22, w, h) cornerRadius:w / 2] fill];
    UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:CGPointMake(d / 2, d * 0.44) radius:d * 0.17 startAngle:0 endAngle:M_PI clockwise:YES];
    arc.lineWidth = d * 0.035;
    [arc stroke];
    UIBezierPath *stem = [UIBezierPath bezierPath];
    [stem moveToPoint:CGPointMake(d / 2, d * 0.61)];
    [stem addLineToPoint:CGPointMake(d / 2, d * 0.72)];
    [stem moveToPoint:CGPointMake(d * 0.4, d * 0.72)];
    [stem addLineToPoint:CGPointMake(d * 0.6, d * 0.72)];
    stem.lineWidth = d * 0.035;
    stem.lineCapStyle = kCGLineCapRound;
    [stem stroke];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)down {
    [[RZVoicePlayer shared] stop];
    AVAudioSession *as = [AVAudioSession sharedInstance];
    [as setCategory:AVAudioSessionCategoryPlayAndRecord error:NULL];
    [as setActive:YES error:NULL];
    self.path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"rz-voice-%lld.m4a", RZNowMs()]];
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @22050.0,
        AVNumberOfChannelsKey: @1,
        AVEncoderBitRateKey: @32000,
    };
    NSError *err = nil;
    self.recorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:self.path] settings:settings error:&err];
    if (!self.recorder || ![self.recorder record]) {
        RZLog(@"ghi âm lỗi: %@", err.localizedDescription);
        self.hint.text = @"Không ghi âm được";
        self.recorder = nil;
        return;
    }
    self.hint.text = @"Thả để gửi · kéo ra ngoài để huỷ";
    self.hint.textColor = RZTextGray();
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self tick];
}

- (void)tick {
    NSTimeInterval t = self.recorder.currentTime;
    self.timeLabel.text = [NSString stringWithFormat:@"%d:%02d", (int)t / 60, (int)t % 60];
    if (t >= 300) [self upInside];  // tối đa 5 phút
}

- (void)dragExit {
    self.hint.text = @"Thả để huỷ";
    self.hint.textColor = RZHex(0xE5534B);
}

- (void)dragEnter {
    self.hint.text = @"Thả để gửi · kéo ra ngoài để huỷ";
    self.hint.textColor = RZTextGray();
}

- (void)finish:(BOOL)send {
    [self.timer invalidate];
    self.timer = nil;
    if (!self.recorder) return;
    NSTimeInterval t = self.recorder.currentTime;
    [self.recorder stop];
    self.recorder = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:NULL];
    self.timeLabel.text = @"0:00";
    self.hint.textColor = RZTextGray();
    if (send && t >= 1.0) {
        self.hint.text = @"Giữ để ghi âm · thả để gửi";
        if (self.onRecorded) self.onRecorded(self.path, (long long)(t * 1000));
    } else {
        self.hint.text = send ? @"Giữ lâu hơn để ghi âm" : @"Đã huỷ";
        [[NSFileManager defaultManager] removeItemAtPath:self.path error:NULL];
    }
}

- (void)upInside {
    [self finish:YES];
}

- (void)cancel {
    [self finish:NO];
}

- (void)willMoveToWindow:(UIView *)w {
    if (!w) [self finish:NO];
}

@end

#pragma mark - Phát

@interface RZVoicePlayer () <AVAudioPlayerDelegate>
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, copy) NSString *playingKey;
@end

@implementation RZVoicePlayer

+ (instancetype)shared {
    static RZVoicePlayer *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = [[RZVoicePlayer alloc] init];
    });
    return p;
}

- (void)toggle:(NSString *)path key:(NSString *)key {
    if ([key isEqualToString:self.playingKey]) {
        [self stop];
        return;
    }
    [self stop];
    // PlayAndRecord phát ra loa thoại → chỉ phát thì đặt Playback (ra loa ngoài)
    AVAudioSession *as = [AVAudioSession sharedInstance];
    [as setCategory:AVAudioSessionCategoryPlayback error:NULL];
    [as setActive:YES error:NULL];
    NSError *err = nil;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    self.player.delegate = self;
    if (!self.player || ![self.player play]) {
        RZLog(@"phát tin thoại lỗi: %@", err.localizedDescription);
        self.player = nil;
        RZAlert(@"Không phát được", @"Máy không đọc được định dạng tin thoại này.");
        return;
    }
    self.playingKey = key;
    [[NSNotificationCenter defaultCenter] postNotificationName:RZVoicePlayerChanged object:self];
}

- (void)stop {
    if (!self.player) return;
    [self.player stop];
    self.player = nil;
    self.playingKey = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:NULL];
    [[NSNotificationCenter defaultCenter] postNotificationName:RZVoicePlayerChanged object:self];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)ok {
    [self stop];
}

@end
