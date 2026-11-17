#import <UIKit/UIKit.h>

/// Thẻ «Tin nhắn»: danh sách cuộc trò chuyện (ghim trước, mới nhất trước), tìm theo tên, trạng thái kết nối trên thanh trên.
@interface RZChatListViewController : UITableViewController
@end

/// Ô một cuộc trò chuyện: vẽ gọn trong drawRect: (kiểu «fast cell» thời iOS 5 — cuộn mượt trên A4).
@interface RZThreadCell : UITableViewCell
@property (nonatomic, strong) NSDictionary *thread;
@property (nonatomic, strong) UIImage *avatar;
@property (nonatomic, copy) NSString *typing;
@end
