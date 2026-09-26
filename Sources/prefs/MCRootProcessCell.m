#import "MCPrefsClasses.h"

@implementation MCRootProcessCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier specifier:specifier];
    if (self) {
        self.detailTextLabel.numberOfLines = 2;
        self.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        self.textLabel.adjustsFontForContentSizeCategory = YES;
        self.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        self.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        self.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    NSString *subtitle = [specifier propertyForKey:@"subtitle"] ?: @"";
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:subtitle];
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration
        configurationWithPointSize:self.detailTextLabel.font.pointSize weight:UIImageSymbolWeightSemibold];
    NSArray<NSString *> *markers = @[@"✅", @"❌", @"➖"];
    NSArray<NSString *> *names = @[@"checkmark.circle.fill", @"xmark.circle.fill", @"minus.circle.fill"];
    NSArray<UIColor *> *colors = @[UIColor.systemGreenColor, UIColor.systemRedColor, UIColor.secondaryLabelColor];
    for (NSUInteger i = 0; i < markers.count; i++) {
        UIImage *symbol = [[UIImage systemImageNamed:names[i] withConfiguration:config]
            imageWithTintColor:colors[i] renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (!symbol) continue;
        NSTextAttachment *check = [NSTextAttachment new];
        check.image = symbol;
        check.bounds = CGRectMake(0, -2, symbol.size.width, symbol.size.height);
        NSAttributedString *icon = [NSAttributedString attributedStringWithAttachment:check];
        NSRange range;
        while ((range = [text.string rangeOfString:markers[i]]).location != NSNotFound)
            [text replaceCharactersInRange:range withAttributedString:icon];
    }
    self.detailTextLabel.attributedText = text;
    self.accessoryType = UITableViewCellAccessoryDetailButton;
}

@end
