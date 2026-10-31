#import "DXPJavaScriptTestController.h"
#import "../DXJavaScriptEngine.h"
#import "../common.h"

@interface DXPJavaScriptTestController ()
@property (nonatomic, strong) UITextView *input;
@property (nonatomic, strong) UITextView *output;
@property (nonatomic, strong) DXJavaScriptEngine *engine;
@end
@implementation DXPJavaScriptTestController
- (NSString *)label:(NSString *)key {
    return NSLocalizedStringFromTableInBundle(key, nil, [NSBundle bundleWithPath:bundlePath], nil);
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self label:@"JS_TEST"];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-12]
    ]];
    UILabel *hint = [UILabel new]; hint.text = [self label:@"JS_TEST_HINT"]; hint.numberOfLines = 0;
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    [stack addArrangedSubview:hint];
    self.input = [UITextView new]; self.input.text = @"Hello MUBX";
    self.input.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.input.font = [UIFont systemFontOfSize:16];
    [self.input.heightAnchor constraintEqualToConstant:90].active = YES;
    [stack addArrangedSubview:self.input];
    UIButton *run = [UIButton buttonWithType:UIButtonTypeSystem];
    [run setTitle:[self label:@"JS_RUN"] forState:UIControlStateNormal];
    [run addTarget:self action:@selector(run) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:run];
    self.output = [UITextView new]; self.output.editable = NO;
    self.output.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    [stack addArrangedSubview:self.output];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop target:self action:@selector(stop)];
}
- (void)append:(NSString *)text {
    NSString *combined = [self.output.text stringByAppendingFormat:@"%@\n", text];
    self.output.text = combined.length > 32768 ? [combined substringFromIndex:combined.length - 32768] : combined;
}
- (void)stop { [self.engine cancel]; self.engine = nil; }
- (void)run {
    [self stop]; [self.view endEditing:YES]; self.output.text = @"";
    self.engine = [DXJavaScriptEngine new];
    __weak typeof(self) weakSelf = self;
    self.engine.logHandler = ^(NSString *message) { [weakSelf append:message]; };
    self.engine.actionHandler = ^(NSDictionary *action) {
        [weakSelf append:[NSString stringWithFormat:@"[preview] %@: %@", action[@"type"], action[@"content"]]];
        // Mirror the host's terminal navigation semantics without actually opening.
        [weakSelf stop];
    };
    self.engine.resultHandler = ^(NSArray *actions, NSError *error) {
        typeof(self) view = weakSelf;
        if (!view) return;
        if (error) { [view append:error.localizedDescription]; [view stop]; return; }
        if (!actions.count) { [view append:@"null / undefined"]; [view stop]; return; }
        if (actions.count == 1) { [view preview:actions.firstObject]; return; }
        UIAlertController *menu = [UIAlertController alertControllerWithTitle:[view label:@"JS_RESULT"] message:nil preferredStyle:UIAlertControllerStyleAlert];
        for (NSDictionary *action in actions) {
            [menu addAction:[UIAlertAction actionWithTitle:[action[@"title"] length] ? action[@"title"] : @"∅"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *item) { [weakSelf preview:action]; }]];
        }
        [menu addAction:[UIAlertAction actionWithTitle:[view label:@"ANSWER_CANCEL"] style:UIAlertActionStyleCancel
            handler:^(__unused UIAlertAction *item) { [weakSelf stop]; }]];
        [view presentViewController:menu animated:YES completion:nil];
    };
    [self.engine runSource:self.source input:self.input.text ?: @""];
}
- (void)preview:(NSDictionary *)action {
    if ([action[@"type"] isEqual:@"function"]) {
        [self.engine callFunction:action[@"content"] arguments:action[@"args"]];
    } else {
        [self append:[NSString stringWithFormat:@"[%@]\n%@", action[@"type"], action[@"content"]]];
        [self stop];
    }
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self stop]; }
- (void)dealloc { [_engine cancel]; }
@end
