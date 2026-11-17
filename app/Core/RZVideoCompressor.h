#import <Foundation/Foundation.h>

/// Nén video sang MP4: H.264 Baseline (cạnh dài ≤ 640, ~1,2 Mbit/s, giữ hướng xoay) + AAC 64 kbit/s / kênh, «moov» ở đầu
/// (xem được khi đang tải). Tự dựng bằng AVAssetReader / AVAssetWriter: AVAssetExportSession preset 640×480 / Medium trên
/// app này báo -11800 / -12780 với video có tiếng (preset Low thì được nhưng chỉ 192×144).
@interface RZVideoCompressor : NSObject
/// `progress` (0…1) và `done` (nil = xong) gọi trên luồng chính.
+ (void)compress:(NSURL *)src to:(NSString *)dst progress:(void (^)(double p))progress done:(void (^)(NSError *err))done;
@end
