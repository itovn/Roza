#import <Foundation/Foundation.h>

/// Chỉ có trong bản thử (DEBUG): đọc lệnh từ /var/mobile/Documents/Roza-cmd.txt (mỗi dòng một lệnh, đọc xong xoá tệp) để thử
/// app qua SSH — kèm `cbscreen` chụp màn hình. Kết quả ghi vào app.log («[thử] …») — chỉ số lượng / loại, không ghi nội dung tin.
///   call <lệnh> [json]   gọi lõi, ghi tóm tắt kết quả
///   tab <i>              chọn thẻ (0 Tin nhắn, 1 Danh bạ, 2 Nhóm, 3 Thêm)
///   open <khoá>          mở chat (u<uid> / g<gid>); «open cloud» = Cloud của tôi; «open row <n>» = hàng n của danh sách chat
///   back                 quay lại màn trước
///   dark 1|0             bật / tắt chế độ tối
///   type <chữ>           gõ vào ô nhập của chat đang mở
///   send                 bấm Gửi
///   stickers             bật / tắt bảng sticker
///   dump                 ghi số tin / loại tin của chat đang mở
@interface RZDebug : NSObject
+ (void)start;
@end
