#import "RZKit.h"
#import "RZChatViewController.h"
#import "RZTheme.h"

@interface RZSheet () <UIActionSheetDelegate>
@property (nonatomic, strong) UIActionSheet *sheet;
@property (nonatomic, strong) NSMutableArray *actions;
@property (nonatomic, strong) RZSheet *selfRef;  // giữ mình sống tới khi bảng đóng
@end

@implementation RZSheet

- (instancetype)initWithTitle:(NSString *)title {
    if ((self = [super init])) {
        _sheet = [[UIActionSheet alloc] initWithTitle:title delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
        _actions = [NSMutableArray array];
    }
    return self;
}

- (void)add:(NSString *)title action:(void (^)(void))action {
    [self.sheet addButtonWithTitle:title];
    [self.actions addObject:action ? [action copy] : [^{} copy]];
}

- (void)addDestructive:(NSString *)title action:(void (^)(void))action {
    [self add:title action:action];
    self.sheet.destructiveButtonIndex = (NSInteger)self.actions.count - 1;
}

- (void)showIn:(UIView *)view {
    [self.sheet addButtonWithTitle:@"Huỷ"];
    self.sheet.cancelButtonIndex = (NSInteger)self.actions.count;
    self.selfRef = self;
    [self.sheet showInView:view];
}

- (void)actionSheet:(UIActionSheet *)as didDismissWithButtonIndex:(NSInteger)i {
    if (i >= 0 && i < (NSInteger)self.actions.count) {
        void (^a)(void) = [self.actions objectAtIndex:i];
        a();
    }
    self.sheet.delegate = nil;
    self.selfRef = nil;
}

@end

@interface RZAlertBox : NSObject <UIAlertViewDelegate>
@property (nonatomic, copy) void (^action)(void);
@property (nonatomic, strong) RZAlertBox *selfRef;
@end

@implementation RZAlertBox
- (void)alertView:(UIAlertView *)av didDismissWithButtonIndex:(NSInteger)i {
    if (i != av.cancelButtonIndex && self.action) self.action();
    self.selfRef = nil;
}
@end

@interface RZPinBox : NSObject <UIAlertViewDelegate>
@property (nonatomic, copy) void (^done)(NSString *);
@property (nonatomic, strong) RZPinBox *selfRef;
@end

@implementation RZPinBox
- (void)alertView:(UIAlertView *)av didDismissWithButtonIndex:(NSInteger)i {
    NSString *pin = [av textFieldAtIndex:0].text;
    if (i != av.cancelButtonIndex && pin.length == 4 && self.done) self.done(pin);
    self.selfRef = nil;
}
@end

void RZAskPin(NSString *title, NSString *msg, void (^done)(NSString *pin)) {
    RZPinBox *box = [[RZPinBox alloc] init];
    box.done = done;
    box.selfRef = box;
    UIAlertView *av = [[UIAlertView alloc] initWithTitle:title message:msg delegate:box cancelButtonTitle:@"Huỷ" otherButtonTitles:@"OK", nil];
    av.alertViewStyle = UIAlertViewStyleSecureTextInput;
    [av textFieldAtIndex:0].keyboardType = UIKeyboardTypeNumberPad;
    [av textFieldAtIndex:0].placeholder = @"••••";
    [av show];
}

void RZAlert(NSString *title, NSString *msg) {
    [[[UIAlertView alloc] initWithTitle:title message:msg delegate:nil cancelButtonTitle:@"Đóng" otherButtonTitles:nil] show];
}

void RZConfirm(NSString *title, NSString *msg, NSString *ok, void (^action)(void)) {
    RZAlertBox *box = [[RZAlertBox alloc] init];
    box.action = action;
    box.selfRef = box;
    [[[UIAlertView alloc] initWithTitle:title message:msg delegate:box cancelButtonTitle:@"Huỷ" otherButtonTitles:ok, nil] show];
}

UILabel *RZLabel(CGFloat size, BOOL bold, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.textColor = color ?: RZText();
    l.backgroundColor = [UIColor clearColor];
    l.lineBreakMode = 4;  // cắt đuôi
    return l;
}

NSString *RZFold(NSString *s) {
    if (!s.length) return @"";
    NSMutableString *m = [s mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformStripCombiningMarks, NO);
    [m replaceOccurrencesOfString:@"đ" withString:@"d" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"Đ" withString:@"D" options:0 range:NSMakeRange(0, m.length)];
    return m.lowercaseString;
}

void RZOpenChat(UINavigationController *nav, NSString *thread, NSString *name, NSString *avatar) {
    if (!thread.length || !nav) return;
    RZChatViewController *c = [[RZChatViewController alloc] initWithThread:thread name:name avatar:avatar];
    [nav pushViewController:c animated:YES];
}
