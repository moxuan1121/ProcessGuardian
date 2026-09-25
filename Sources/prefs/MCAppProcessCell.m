/**
 * MCAppProcessCell.m —— 面板里复用的进程行。
 *
 * 候选列表的名称和标识分两行显示，保留系统分组列表的点按反馈。
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
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
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
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title subtitle:(NSString *)subtitle running:(BOOL)running {
    self.titleLabel.text = title.length ? title : @"(未命名)";
    self.subtitleLabel.text = subtitle;
    self.titleLabel.textColor = [UIColor labelColor];
    self.subtitleLabel.textColor = running ? [UIColor secondaryLabelColor]
                                           : [UIColor tertiaryLabelColor];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.alpha = 1.0;
}

@end
