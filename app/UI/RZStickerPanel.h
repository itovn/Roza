#import <UIKit/UIKit.h>

/// Bảng sticker (thay chỗ bàn phím, cao 216): thẻ «Gần đây», các bộ sticker đã gặp, «Tìm» (chữ gợi ý + «Khác…»). Chạm sticker
/// → `onPick(@{id, cat, type})`. Zalo Web không có API «bộ sticker của tôi» nên bộ = các bộ đã gửi / nhận.
@interface RZStickerPanel : UIView
@property (nonatomic, copy) void (^onPick)(NSDictionary *sticker);
/// Tải lại «Gần đây» / danh sách bộ (sau khi gửi hoặc nhận sticker).
- (void)reload;
@end
