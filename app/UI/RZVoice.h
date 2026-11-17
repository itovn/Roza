#import <UIKit/UIKit.h>

/// Bảng ghi âm (thay chỗ bàn phím, như bảng sticker): giữ nút để nói, thả để gửi, kéo ra ngoài nút để huỷ. Ghi AAC (m4a)
/// 22,05 kHz một kênh ~32 kbit/s — Zalo gửi tin thoại dạng m4a (`sendVoice`). Ngắn hơn 1 giây thì bỏ.
@interface RZVoicePanel : UIView
@property (nonatomic, copy) void (^onRecorded)(NSString *path, long long durationMs);
@end

/// Phát tin thoại (m4a / aac / mp3 — AVAudioPlayer đọc được trên iOS 5 / 6) ra loa ngoài. Một tin một lúc.
@interface RZVoicePlayer : NSObject
+ (instancetype)shared;
/// Phát tệp; đang phát chính mã đó thì dừng. Đổi trạng thái → RZVoicePlayerChanged.
- (void)toggle:(NSString *)path key:(NSString *)key;
- (void)stop;
@property (nonatomic, readonly, copy) NSString *playingKey;
@end

extern NSString *const RZVoicePlayerChanged;
