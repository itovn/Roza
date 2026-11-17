#import "RZKit.h"
#import "RZAppDelegate.h"
#import "RZChatViewController.h"
#import "RZCore.h"
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

@interface RZTextBox : NSObject <UIAlertViewDelegate>
@property (nonatomic, copy) void (^done)(NSString *);
@property (nonatomic, strong) RZTextBox *selfRef;
@end

@implementation RZTextBox
- (void)alertView:(UIAlertView *)av didDismissWithButtonIndex:(NSInteger)i {
    NSString *t = [[av textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (i != av.cancelButtonIndex && self.done) self.done(t ?: @"");
    self.selfRef = nil;
}
@end

void RZAskText(NSString *title, NSString *msg, NSString *value, NSString *placeholder, UIKeyboardType kb, void (^done)(NSString *text)) {
    RZTextBox *box = [[RZTextBox alloc] init];
    box.done = done;
    box.selfRef = box;
    UIAlertView *av = [[UIAlertView alloc] initWithTitle:title message:msg delegate:box cancelButtonTitle:@"Huỷ" otherButtonTitles:@"OK", nil];
    av.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *f = [av textFieldAtIndex:0];
    f.text = value;
    f.placeholder = placeholder;
    f.keyboardType = kb;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    [av show];
}

void RZEditAlias(NSString *uid, NSString *shown, void (^done)(NSString *name)) {
    if (!uid.length) return;
    [RZCore call:@"user.info" args:@{@"uid": uid} done:^(id u, NSDictionary *err) {
        NSString *alias = RZStr([u objectForKey:@"alias"]) ?: @"";
        NSString *real = RZStr([u objectForKey:@"real_name"]);
        if (!real.length) real = alias.length ? @"" : shown;
        NSString *msg = real.length ? [NSString stringWithFormat:@"Tên Zalo: %@\nĐể trống để bỏ tên gợi nhớ.", real] : @"Để trống để bỏ tên gợi nhớ.";
        RZAskText(@"Đặt tên gợi nhớ", msg, alias, @"Tên gợi nhớ", UIKeyboardTypeDefault, ^(NSString *text) {
            [RZCore call:@"alias.set" args:@{@"uid": uid, @"alias": text ?: @""} done:^(id ok, NSDictionary *err2) {
                if (err2) {
                    RZAlert(@"Chưa đặt được tên gợi nhớ", RZErrorText(err2));
                    return;
                }
                NSString *name = RZStr([ok objectForKey:@"name"]);
                if (done) done(name.length ? name : (text.length ? text : real));
            }];
        });
    }];
}

NSString *RZMoney(long long amount) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"%lld", amount < 0 ? -amount : amount];
    for (NSInteger i = (NSInteger)s.length - 3; i > 0; i -= 3) [s insertString:@"." atIndex:(NSUInteger)i];
    if (amount < 0) [s insertString:@"-" atIndex:0];
    return s;
}

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
    if (!thread.length) return;
    UINavigationController *detail = RZDetailNav();
    if (detail) {
        // iPad: thay cuộc trò chuyện bên phải (đang mở đúng chat thì chỉ quay về màn chat)
        if ([RZOpenThread() isEqualToString:thread]) {
            [detail popToRootViewControllerAnimated:YES];
            return;
        }
        RZChatViewController *c = [[RZChatViewController alloc] initWithThread:thread name:name avatar:avatar];
        [detail setViewControllers:@[c] animated:NO];
        [[NSNotificationCenter defaultCenter] postNotificationName:RZOpenThreadChanged object:nil];
        return;
    }
    if (!nav) return;
    RZChatViewController *c = [[RZChatViewController alloc] initWithThread:thread name:name avatar:avatar];
    [nav pushViewController:c animated:YES];
}
