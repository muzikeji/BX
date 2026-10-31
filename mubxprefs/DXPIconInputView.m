#import "DXPIconInputView.h"
#import "../DXHelper.h"

@implementation DXPIconInputView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0.0, 3.5, 29.0, 29.0)];
        _previewImageView.contentMode = UIViewContentModeScaleAspectFit;
        [self addSubview:_previewImageView];

        _textField = [[UITextField alloc] initWithFrame:CGRectMake(36.0, 0.0, 195.0, 36.0)];
        _textField.textAlignment = NSTextAlignmentRight;
        _textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        _textField.autocorrectionType = UITextAutocorrectionTypeNo;
        _textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [self addSubview:_textField];

        UIButton *browse = [UIButton buttonWithType:UIButtonTypeSystem];
        browse.frame = CGRectMake(231.0, 0.0, 36.0, 36.0);
        [browse setImage:[UIImage systemImageNamed:@"square.grid.2x2"]
            forState:UIControlStateNormal];
        browse.tintColor = UIColor.secondaryLabelColor;
        browse.accessibilityLabel = @"图标库";
        [browse addTarget:self action:@selector(browseTappedAction) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:browse];

        [_textField addTarget:self action:@selector(textFieldChanged:)
            forControlEvents:UIControlEventEditingChanged];
        [self refreshPreview];
    }
    return self;
}

- (void)browseTappedAction {
    if (self.browseTapped) self.browseTapped();
}

- (void)textFieldChanged:(UITextField *)sender {
    [self refreshPreview];
    if (self.textChanged) self.textChanged(sender.text ?: @"");
}

- (void)refreshPreview {
    NSString *icon = [self.textField.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    UIImage *image = icon.length ? [DXHelper imageForIconConfig:icon defaultSymbolName:@"link"] : nil;
    if (!image) image = [UIImage systemImageNamed:@"link"];
    self.previewImageView.image = image;
}

@end
