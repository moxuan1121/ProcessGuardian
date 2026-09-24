/**
 * MCAppProcessCell.m —— 面板里复用的进程行。
 *
 * 不用 UITableViewCell 自带的 textLabel/detailTextLabel 布局，自己放两个 label：
 * 副标题要按「进程在不在运行」换色，而 detailTextLabel 的字体颜色只能整体跟随
 * cell 的 tintColor，做不到逐行区分。
 */
#import "MCPrefsClasses.h"

@interface MCAppProcessCell ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation MCAppProcessCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _subtitleLabel = [UILabel new];
        _subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _subtitleLabel.textColor = [UIColor secondaryLabelColor];
        _subtitleLabel.numberOfLines = 2;

        for (UIView *v in @[ _titleLabel, _subtitleLabel ]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],

            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
            [_subtitleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        ]];
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title subtitle:(NSString *)subtitle running:(BOOL)running {
    self.titleLabel.text = title.length ? title : @"(未命名)";
    self.subtitleLabel.text = subtitle;
    self.subtitleLabel.textColor = running ? [UIColor secondaryLabelColor]
                                           : [UIColor tertiaryLabelColor];
    self.alpha = running ? 1.0 : 0.6;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.alpha = 1.0;
}

@end
