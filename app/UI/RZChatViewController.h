#import <UIKit/UIKit.h>

/// Màn chat của một cuộc trò chuyện (`u<uid>` / `g<gid>`).
@interface RZChatViewController : UIViewController
- (instancetype)initWithThread:(NSString *)thread name:(NSString *)name avatar:(NSString *)avatar;
@property (nonatomic, readonly, copy) NSString *thread;
/// Tên đang hiện trên thanh trên.
@property (nonatomic, readonly, copy) NSString *name;
@end
