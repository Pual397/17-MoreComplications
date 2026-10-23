#import "MCTextFieldCell.h"
#import <Preferences/PSSpecifier.h>

// PSTextFieldSpecifier only drew its label on some bootstraps, so the layout
// field uses a cell that puts a real UITextField in the content view and writes
// straight to the preference domain.

static NSString *MCDefaultDomain(PSSpecifier *specifier) {
	NSString *domain = [specifier propertyForKey:@"defaults"];
	return domain.length ? domain : @"xyz.skitty.morecomplications";
}

static NSString *MCReadPreference(PSSpecifier *specifier) {
	NSString *key = [specifier propertyForKey:@"key"];
	if (key.length == 0) return @"";

	CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
	                                                    (__bridge CFStringRef)MCDefaultDomain(specifier));
	NSString *string = @"";
	if ([(__bridge id)value isKindOfClass:[NSString class]]) {
		string = [(__bridge id)value copy];
	}
	if (value) CFRelease(value);
	return string;
}

static void MCWritePreference(PSSpecifier *specifier, NSString *string) {
	NSString *key = [specifier propertyForKey:@"key"];
	if (key.length == 0) return;

	NSString *domain = MCDefaultDomain(specifier);
	CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)(string ?: @""),
	                         (__bridge CFStringRef)domain);
	CFPreferencesAppSynchronize((__bridge CFStringRef)domain);

	NSString *notification = [specifier propertyForKey:@"PostNotification"];
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
	                                     (__bridge CFStringRef)(notification.length ? notification : @"xyz.skitty.morecomplications.prefschanged"),
	                                     NULL, NULL, true);
}

@implementation MCTextFieldCell {
	UITextField *_textField;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
	self = [super initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseIdentifier specifier:specifier];
	if (self) {
		self.selectionStyle = UITableViewCellSelectionStyleNone;

		_textField = [[UITextField alloc] init];
		_textField.textAlignment = NSTextAlignmentRight;
		_textField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
		_textField.autocorrectionType = UITextAutocorrectionTypeNo;
		_textField.spellCheckingType = UITextSpellCheckingTypeNo;
		_textField.returnKeyType = UIReturnKeyDone;
		_textField.clearButtonMode = UITextFieldViewModeWhileEditing;
		_textField.font = [UIFont systemFontOfSize:17];
		_textField.adjustsFontSizeToFitWidth = YES;
		_textField.minimumFontSize = 12;
		if (@available(iOS 13.0, *)) {
			_textField.textColor = [UIColor labelColor];
		} else {
			_textField.textColor = [UIColor darkTextColor];
		}
		_textField.placeholder = [specifier propertyForKey:@"placeholder"] ?: @"";
		_textField.text = MCReadPreference(specifier);
		[_textField addTarget:self action:@selector(textDidChange:) forControlEvents:UIControlEventEditingChanged];
		[self.contentView addSubview:_textField];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];

	CGRect bounds = self.contentView.bounds;
	CGFloat width = MIN(bounds.size.width * 0.55, 220.0);
	_textField.frame = CGRectMake(bounds.size.width - width - 16.0, 0.0, width, bounds.size.height);
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
	[super refreshCellContentsWithSpecifier:specifier];
	if (!_textField.isFirstResponder) {
		_textField.text = MCReadPreference(specifier);
	}
}

- (void)textDidChange:(UITextField *)textField {
	MCWritePreference([self specifier], textField.text ?: @"");
}

- (void)dealloc {
	[_textField removeTarget:self action:@selector(textDidChange:) forControlEvents:UIControlEventEditingChanged];
}

@end
