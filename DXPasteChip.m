#import "DXPasteChip.h"
#import "common.h"
#import "DXShared.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@class UIKeyboardDockView;
// MUBX.xm's handle on the visible keyboard dock; its window is the full-screen
// text-effects window the chip is pinned into.
extern UIKeyboardDockView *dockView;

static const CGFloat DXChipWidth = 64.0;
static const CGFloat DXChipHeight = 78.0;
static const CGFloat DXChipEdgeInset = 8.0;
static const CGFloat DXChipThumbnailMaxPixels = 240.0;
// Preview cap in characters; the label itself truncates visually at 3 lines.
static const NSUInteger DXChipPreviewMaxLength = 120;
static const NSTimeInterval DXChipLifetime = 3.0;
static const NSTimeInterval DXChipPollInterval = 1.0;
// Reads that hit the paste-permission prompt come back empty; retry the same
// generation on the next ticks before giving up on it.
static const NSUInteger DXChipMaxDecodeAttempts = 3;

#pragma mark - Chip view

@interface DXPasteChipView : UIView
@property(nonatomic, strong) UIImageView *thumbnailView;
@property(nonatomic, strong) UILabel *previewLabel;
@property(nonatomic, strong) UIButton *closeButton;
// Text mode swaps the 48pt thumbnail for a few lines of clipboard preview in
// the same slot; both chips keep the image chip's size.
@property(nonatomic, assign, getter=isTextMode) BOOL textMode;
@end

@implementation DXPasteChipView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;

    self.layer.cornerRadius = 12.0;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.22;
    self.layer.shadowRadius = 8.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 2.0);
    self.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
        return trait.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.12 alpha:0.98]
            : [UIColor colorWithWhite:1.0 alpha:0.98];
    }];

    _thumbnailView = [[UIImageView alloc] initWithFrame:CGRectMake(8.0, 8.0, 48.0, 48.0)];
    _thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
    _thumbnailView.clipsToBounds = YES;
    _thumbnailView.layer.cornerRadius = 8.0;
    [self addSubview:_thumbnailView];

    _previewLabel = [[UILabel alloc] initWithFrame:CGRectMake(8.0, 8.0, 48.0, 48.0)];
    _previewLabel.font = [UIFont systemFontOfSize:10.0];
    _previewLabel.textColor = [UIColor labelColor];
    _previewLabel.numberOfLines = 4;
    _previewLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _previewLabel.hidden = YES;
    [self addSubview:_previewLabel];

    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 58.0, CGRectGetWidth(frame), 14.0)];
    caption.text = LOCALIZED(@"PASTE_CHIP_ACTION");
    caption.font = [UIFont systemFontOfSize:10.0];
    caption.textColor = [UIColor secondaryLabelColor];
    caption.textAlignment = NSTextAlignmentCenter;
    caption.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self addSubview:caption];

    // The badge overhangs the top-right corner; the chip must not clip it.
    _closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _closeButton.frame = CGRectMake(CGRectGetWidth(frame) - 13.0, -6.0, 18.0, 18.0);
    _closeButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    _closeButton.layer.cornerRadius = 9.0;
    _closeButton.titleLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
    [_closeButton setTitle:@"✕" forState:UIControlStateNormal];
    [_closeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [self addSubview:_closeButton];

    self.isAccessibilityElement = YES;
    self.accessibilityLabel = caption.text;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    return self;
}

// One pass positions every subview for the current mode; text preview lives
// in the same 48pt slot as the thumbnail, so both chips share one size.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    BOOL textMode = self.isTextMode;
    CGFloat side = 48.0;
    CGFloat slotX = round((width - side) / 2.0);
    self.thumbnailView.frame = CGRectMake(slotX, 8.0, side, side);
    self.thumbnailView.hidden = textMode;
    self.previewLabel.frame = CGRectMake(slotX, 8.0, side, side);
    self.previewLabel.hidden = !textMode;
    self.closeButton.frame = CGRectMake(width - 13.0, -6.0, 18.0, 18.0);
}

- (void)setThumbnailImage:(UIImage *)image {
    self.thumbnailView.image = image;
}

@end

#pragma mark - Caret tracking

// The selector is added to UIResponder itself, so the first object on the
// responder chain -- the process' current first responder -- is the first one
// to answer sendAction:to:nil and records itself. This finds the app's text
// input even though the chip lives in the keyboard's own window.
static __weak UIResponder *DXPasteChipCapturedResponder = nil;

@interface UIResponder (DXPasteChipCaret)
@end

@implementation UIResponder (DXPasteChipCaret)
- (void)dxpasteChip_captureFirstResponder:(id)sender {
    (void)sender;
    DXPasteChipCapturedResponder = self;
}
@end

#pragma mark - Controller

@interface DXPasteChipController () <UIGestureRecognizerDelegate>
@end

@implementation DXPasteChipController {
    NSTimer *_pollTimer;
    NSTimer *_dismissTimer;
    // Newest pasteboard generation this process already surfaced or skipped,
    // so each copied image produces exactly one 3-second appearance per app.
    NSUInteger _lastHandledChangeCount;
    // NO until this process has observed the pasteboard once. Images already
    // sitting on the clipboard (copied before this app launched) are
    // pre-existing, not a new copy, and must never pop the chip.
    BOOL _hasObservedPasteboard;
    // Generation currently being decoded (or awaiting a retry tick), how many
    // attempts it has burned, and 0 when nothing is in flight. A generation
    // only becomes _lastHandledChangeCount once a thumbnail actually decoded.
    NSUInteger _pendingChangeCount;
    NSUInteger _pendingAttempts;
    CGRect _keyboardScreenFrame;
    BOOL _hasKeyboardFrame;
    __weak DXPasteChipView *_chip;
    __weak UIWindow *_hostWindow;
}

+ (instancetype)sharedController {
    static DXPasteChipController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
    });
    return controller;
}

+ (BOOL)isAllowedInCurrentApp {
    if (!preferencesBool(kEnabledkey, YES) || !preferencesBool(kPasteImageChipKey, YES)) return NO;
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    if (bundleID.length == 0) return NO;
    // 生效应用 allowlist: an array of enabled bundle IDs (AltList multi-select
    // page, 3.5.2+) — legacy format was a bundleID→@YES dictionary; both count.
    id allowlist = [DXPrefsManager sharedInstance].prefs[kPasteImageChipAppsKey];
    if ([allowlist isKindOfClass:[NSArray class]]) return [allowlist containsObject:bundleID];
    if ([allowlist isKindOfClass:[NSDictionary class]]) return [allowlist[bundleID] boolValue];
    return NO;
}

- (BOOL)isFeatureEnabled {
    return [self.class isAllowedInCurrentApp];
}

#pragma mark Keyboard lifecycle

- (void)keyboardDidShow:(NSNotification *)notification {
    if (!self.isFeatureEnabled) return;
    _keyboardScreenFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    _hasKeyboardFrame = !CGRectIsEmpty(_keyboardScreenFrame);
    _hostWindow = dockView.window;
    if (!_pollTimer) {
        _pollTimer = [NSTimer timerWithTimeInterval:DXChipPollInterval
                                             target:self
                                           selector:@selector(pollTick:)
                                           userInfo:nil
                                            repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_pollTimer forMode:NSRunLoopCommonModes];
    }
    // Clipboard state matters the moment the keyboard appears (image copied in
    // another app); changeCount/hasImages are metadata reads and never prompt.
    [self pollTick:nil];
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    if (!self.isFeatureEnabled) return;
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (!frameValue) return;
    _keyboardScreenFrame = [frameValue CGRectValue];
    _hasKeyboardFrame = !CGRectIsEmpty(_keyboardScreenFrame);
    // Quicktype collapse, accessory swaps and rotation all move the keyboard
    // top; keep a visible chip glued to the caret instead of the old frame.
    DXPasteChipView *chip = _chip;
    if (chip && chip.superview && chip.window) {
        [self layoutChip:chip inWindow:chip.window width:CGRectGetWidth(chip.bounds)];
    }
}

- (void)keyboardWillHide:(NSNotification *)notification {
    (void)notification;
    [_pollTimer invalidate];
    _pollTimer = nil;
    [self hideChipAnimated:NO];
}

#pragma mark Pasteboard watching

- (void)pollTick:(NSTimer *)timer {
    (void)timer;
    if (!self.isFeatureEnabled) {
        [_pollTimer invalidate];
        _pollTimer = nil;
        [self hideChipAnimated:NO];
        return;
    }

    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    NSUInteger changeCount = pasteboard.changeCount;
    if (!_hasObservedPasteboard) {
        // First observation in this process: whatever is on the clipboard now
        // was copied before this app could watch, so record it as the
        // baseline and stay quiet. Only later increments are new images.
        _hasObservedPasteboard = YES;
        _lastHandledChangeCount = changeCount;
        return;
    }
    if (changeCount == _lastHandledChangeCount) return;
    // Images win when a generation carries both; anything without a pasteable
    // representation (empty board, raw binary) is skipped permanently.
    BOOL wantsImage = pasteboard.hasImages;
    if (!wantsImage && !pasteboard.hasStrings) {
        _lastHandledChangeCount = changeCount;
        return;
    }
    if (changeCount == _pendingChangeCount) {
        if (++_pendingAttempts > DXChipMaxDecodeAttempts) {
            // The read kept coming back empty; drop this generation quietly.
            _lastHandledChangeCount = changeCount;
            _pendingChangeCount = 0;
            return;
        }
    } else {
        _pendingChangeCount = changeCount;
        _pendingAttempts = 1;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *thumbnail = nil;
        NSString *previewText = nil;
        @autoreleasepool {
            if (wantsImage) thumbnail = [self dxThumbnailImageFromPasteboard:pasteboard];
            else previewText = [self dxPreviewTextFromPasteboard:pasteboard];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.isFeatureEnabled) return;
            // A newer copy superseded this decode; its own callback will show.
            if (changeCount != self->_pendingChangeCount) return;
            if (!self->_pollTimer) return; // keyboard went away mid-decode
            BOOL decoded = wantsImage ? (thumbnail != nil) : (previewText.length > 0);
            if (!decoded) return; // paste-permission prompt raced the read; next tick retries
            self->_lastHandledChangeCount = changeCount;
            self->_pendingChangeCount = 0;
            if (wantsImage) [self showChipWithImage:thumbnail];
            else [self showChipWithPreviewText:previewText];
        });
    });
}

// Content read (hits the paste-permission prompt on iOS 16+; callers retry
// on nil). Whitespace runs collapse so multi-paragraph copies preview as one
// flowing block, and the cap cuts on a composed-character boundary.
- (NSString *)dxPreviewTextFromPasteboard:(UIPasteboard *)pasteboard {
    NSString *string = [pasteboard string];
    if (string.length == 0) return nil;
    string = [string stringByReplacingOccurrencesOfString:@"\\s+"
                                               withString:@" "
                                                  options:NSRegularExpressionSearch
                                                    range:NSMakeRange(0, string.length)];
    string = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (string.length == 0) return nil;
    if (string.length > DXChipPreviewMaxLength) {
        // Cap on composed-character boundaries so emoji and other surrogate
        // pairs never get split by the cut.
        NSMutableString *capped = [NSMutableString string];
        [string enumerateSubstringsInRange:NSMakeRange(0, string.length)
                                   options:NSStringEnumerationByComposedCharacterSequences
                                usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            (void)substringRange;
            (void)enclosingRange;
            if (capped.length + substring.length > DXChipPreviewMaxLength) {
                *stop = YES;
                return;
            }
            [capped appendString:substring];
        }];
        string = capped;
    }
    return string;
}

// Thumbnail decode off the main thread: a pasted photo can be a 12MP HEIC and
// the keyboard process only ever needs a 48pt preview. Pasteboard content types
// are probed by concrete UTI (dataForPasteboardType: resolves conforming
// representations), with the typed `image` accessor as the last resort.
- (UIImage *)dxThumbnailImageFromPasteboard:(UIPasteboard *)pasteboard {
    NSArray<NSString *> *candidateTypes = @[@"public.png", @"public.jpeg", @"public.heic",
                                            @"public.tiff", @"com.apple.uikit.image"];
    for (NSString *type in candidateTypes) {
        NSData *data = [pasteboard dataForPasteboardType:type];
        if (data.length == 0) continue;
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!source) continue;
        NSDictionary *options = @{
            (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
            (__bridge id)kCGImageSourceCreateThumbnailWithTransform : @YES,
            (__bridge id)kCGImageSourceThumbnailMaxPixelSize : @(DXChipThumbnailMaxPixels),
        };
        CGImageRef thumbnailRef = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
        if (thumbnailRef) {
            UIImage *image = [UIImage imageWithCGImage:thumbnailRef];
            CGImageRelease(thumbnailRef);
            return image;
        }
    }
    return [pasteboard image];
}

#pragma mark Chip presentation

// The caret of the app's current text input, converted into the chip window's
// coordinates. CGRectZero when no caret is reachable (no text input, or a
// non-UITextInput responder owns the keyboard).
- (CGRect)caretRectInWindow:(UIWindow *)window {
    DXPasteChipCapturedResponder = nil;
    [UIApplication.sharedApplication sendAction:@selector(dxpasteChip_captureFirstResponder:)
                                          to:nil
                                        from:nil
                                    forEvent:nil];
    UIResponder *responder = DXPasteChipCapturedResponder;
    if (![responder isKindOfClass:UIView.class]) return CGRectZero;
    if (![responder conformsToProtocol:@protocol(UITextInput)]) return CGRectZero;
    id<UITextInput> textInput = (id<UITextInput>)responder;
    UITextRange *selection = textInput.selectedTextRange;
    if (!selection || !selection.start) return CGRectZero;
    CGRect caret = [textInput caretRectForPosition:selection.start];
    if (CGRectIsNull(caret) || CGRectGetHeight(caret) <= 0.0) return CGRectZero;
    return [(UIView *)responder convertRect:caret toView:window];
}

// Right screen edge, level with the caret; the keyboard frame only clamps.
// The remembered keyboard frame is rejected when it sits flush with the
// window bottom (a stale hidden-keyboard frame) -- trusting it used to drop
// the chip into the bottom-right corner instead of above the keyboard.
- (void)layoutChip:(DXPasteChipView *)chip inWindow:(UIWindow *)window width:(CGFloat)chipWidth {
    CGFloat windowWidth = CGRectGetWidth(window.bounds);
    CGFloat windowHeight = CGRectGetHeight(window.bounds);
    CGFloat chipX = windowWidth - DXChipEdgeInset - chipWidth;

    CGFloat keyboardTop = 0.0;
    BOOL hasKeyboardTop = NO;
    if (_hasKeyboardFrame) {
        CGRect keyboardFrame = [window convertRect:_keyboardScreenFrame
                                fromCoordinateSpace:window.screen.coordinateSpace];
        keyboardTop = CGRectGetMinY(keyboardFrame);
        hasKeyboardTop = keyboardTop > 0.0 && keyboardTop < windowHeight - 60.0;
    }

    CGFloat chipTop = 0.0;
    CGRect caretRect = [self caretRectInWindow:window];
    if (!CGRectIsNull(caretRect) && CGRectGetHeight(caretRect) > 0.0) {
        chipTop = round(CGRectGetMidY(caretRect) - DXChipHeight / 2.0);
        // Never drift under the status bar or dip onto the keyboard.
        chipTop = MAX(window.safeAreaInsets.top + 4.0, chipTop);
        if (hasKeyboardTop) chipTop = MIN(chipTop, keyboardTop - 4.0 - DXChipHeight);
    } else if (hasKeyboardTop) {
        chipTop = keyboardTop - 4.0 - DXChipHeight;
    } else if (dockView.window == window) {
        CGRect dockFrame = [dockView convertRect:dockView.bounds toView:window];
        chipTop = CGRectGetMinY(dockFrame) - 8.0 - DXChipHeight;
    } else {
        chipTop = windowHeight * 0.5;
    }
    chipTop = MAX(20.0, chipTop);
    chip.frame = CGRectMake(chipX, chipTop, chipWidth, DXChipHeight);
}

- (void)showChipWithImage:(UIImage *)thumbnail {
    [self presentChipWithImage:thumbnail previewText:nil];
}

- (void)showChipWithPreviewText:(NSString *)previewText {
    [self presentChipWithImage:nil previewText:previewText];
}

- (void)presentChipWithImage:(UIImage *)image previewText:(NSString *)previewText {
    [_dismissTimer invalidate];
    _dismissTimer = nil;

    UIWindow *window = _hostWindow ?: dockView.window;
    _hostWindow = window;
    if (!window) return;

    DXPasteChipView *chip = _chip;
    if (!chip || chip.superview != window) {
        [chip removeFromSuperview];
        chip = [[DXPasteChipView alloc] initWithFrame:CGRectMake(0.0, 0.0, DXChipWidth, DXChipHeight)];
        _chip = chip;
        [window addSubview:chip];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(chipTapped:)];
        tap.delegate = self;
        [chip addGestureRecognizer:tap];
        [chip.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    BOOL textMode = previewText.length > 0;
    chip.textMode = textMode;
    chip.thumbnailView.image = image;
    chip.previewLabel.text = previewText;

    // Anchor: pinned to the screen's right edge, vertically level with the
    // input caret (clamped above the keyboard), else just above the
    // keyboard's top edge. Both modes share the image chip's size.
    [self layoutChip:chip inWindow:window width:DXChipWidth];

    chip.transform = CGAffineTransformMakeScale(0.6, 0.6);
    chip.alpha = 0.0;
    [UIView animateWithDuration:0.18
                          delay:0.0
         options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
      animations:^{
          chip.alpha = 1.0;
          chip.transform = CGAffineTransformIdentity;
      }
      completion:nil];

    _dismissTimer = [NSTimer timerWithTimeInterval:DXChipLifetime
                                            target:self
                                          selector:@selector(autoDismiss)
                                          userInfo:nil
                                           repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:_dismissTimer forMode:NSRunLoopCommonModes];
}

- (void)hideChipAnimated:(BOOL)animated {
    [_dismissTimer invalidate];
    _dismissTimer = nil;
    DXPasteChipView *chip = _chip;
    if (!chip || !chip.superview) return;
    if (!animated) {
        [chip removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:0.16
                          delay:0.0
         options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState
      animations:^{
          chip.alpha = 0.0;
          chip.transform = CGAffineTransformMakeScale(0.7, 0.7);
      }
      completion:^(BOOL finished) {
          (void)finished;
          [chip removeFromSuperview];
      }];
}

- (void)autoDismiss {
    [self hideChipAnimated:YES];
}

#pragma mark Actions

- (void)chipTapped:(UITapGestureRecognizer *)gesture {
    (void)gesture;
    [self hideChipAnimated:YES];
    if (preferencesBool(kEnabledHaptickey, YES)) {
        UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [generator impactOccurred];
    }
    // paste: with a nil target rides the responder chain from the first
    // responder -- the same delivery path as the system callout menu's Paste,
    // so each app's own paste handling turns the image into a draft attachment.
    BOOL delivered = [UIApplication.sharedApplication sendAction:@selector(paste:) to:nil from:self forEvent:nil];
    if (!delivered) {
        NSLog(@"[MUBX] paste chip: no responder handled paste:");
    }
}

- (void)closeTapped {
    [self hideChipAnimated:YES];
}

#pragma mark UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    return touch.view != _chip.closeButton;
}

@end
