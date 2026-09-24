#import "MCPrefsClasses.h"

@implementation MCRootProcessCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier specifier:specifier];
    if (self) {
        self.detailTextLabel.numberOfLines = 2;
        self.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        self.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.detailTextLabel.text = [specifier propertyForKey:@"subtitle"];
    self.accessoryType = UITableViewCellAccessoryDetailButton;
}

@end
