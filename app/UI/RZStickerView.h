#import <UIKit/UIKit.h>

/// Sticker Zalo, kể cả sticker động. Hiện ảnh tĩnh trước; lõi tải dải khung (`sprite`: PNG ngang, mỗi khung vuông 130 px, số khung
/// = rộng / cao), app cắt sẵn thành từng khung ở hàng nền (không dùng thẳng ảnh rộng 1560+ px: GPU A4 chỉ nhận tới 2048 px), rồi
/// đổi `layer.contents` theo nhịp `duration` (ms / khung). Như GMLottieView của GramMini: đồng hồ ở chế độ mặc định của run loop
/// (đứng khi cuộn), dừng khi rời cửa sổ / app xuống nền. Lặp liên tục như app Zalo — khác GramMini (dừng sau 5 lượt vì vẽ
/// Lottie / WebM tốn CPU mỗi khung): ở đây khung đã cắt sẵn, mỗi nhịp chỉ đổi layer.contents.
@interface RZStickerView : UIView
- (void)showSticker:(long long)stickerId;
- (void)stop;
@property (nonatomic, readonly) long long stickerId;
@end
