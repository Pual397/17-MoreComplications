#import "MCTextFieldCell.h"
#import <Preferences/PSSpecifier.h>

// A full-width text field row. PSTextFieldSpecifier only drew its label on some
// bootstraps, so this cell owns a real UITextField and writes straight to the
// preference domain.

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

@interface MCTextFieldCell () <UITextFieldDelegate>
@end

@implementation MCTextFieldCell {
	UITextField *_textField;
	UITapGestureRecognizer *_dismissTap;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
	self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier specifier:specifier];
	if (self) {
		self.selectionStyle = UITableViewCellSelectionStyleNone;

		// The whole row is the input, so the base class label is dropped.
		self.textLabel.text = @"";
		self.detailTextLabel.text = @"";

		_textField = [[UITextField alloc] init];
		_textField.textAlignment = NSTextAlignmentLeft;
		_textField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
		_textField.autocorrectionType = UITextAutocorrectionTypeNo;
		_textField.spellCheckingType = UITextSpellCheckingTypeNo;
		_textField.returnKeyType = UIReturnKeyDone;
		_textField.clearButtonMode = UITextFieldViewModeWhileEditing;
		_textField.font = [UIFont systemFontOfSize:17];
		_textField.adjustsFontSizeToFitWidth = YES;
		_textField.minimumFontSize = 12;
		_textField.delegate = self;
		if (@available(iOS 13.0, *)) {
			_textField.textColor = [UIColor labelColor];
		} else {
			_textField.textColor = [UIColor darkTextColor];
		}

		NSString *placeholder = [specifier propertyForKey:@"placeholder"];
		_textField.placeholder = placeholder.length ? placeholder : @"2C 1J";
		_textField.text = MCReadPreference(specifier);
		_textField.accessibilityLabel = [specifier propertyForKey:@"label"] ?: @"布局";

		// A visible Done button above the keyboard, so the keyboard can always be
		// dismissed even if the return key is not handled by the host app.
		UIToolbar *toolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
		UIBarButtonItem *flexible = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
		                                                                          target:nil
		                                                                          action:nil];
		UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
		                                                                      target:self
		                                                                      action:@selector(dismissKeyboard)];
		toolbar.items = @[flexible, done];
		[toolbar sizeToFit];
		_textField.inputAccessoryView = toolbar;

		[_textField addTarget:self action:@selector(textDidChange:) forControlEvents:UIControlEventEditingChanged];
		[self.contentView addSubview:_textField];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];

	CGRect bounds = self.contentView.bounds;
	_textField.frame = CGRectMake(16.0, 0.0, bounds.size.width - 32.0, bounds.size.height);
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
	[super refreshCellContentsWithSpecifier:specifier];
	self.textLabel.text = @"";
	self.detailTextLabel.text = @"";
	if (!_textField.isFirstResponder) {
		_textField.text = MCReadPreference(specifier);
	}
}

- (void)didMoveToWindow {
	[super didMoveToWindow];
	if (_dismissTap || self.window == nil) return;

	// Tapping anywhere else also drops the keyboard.
	UIView *view = self.superview;
	while (view && ![view isKindOfClass:[UITableView class]]) {
		view = view.superview;
	}
	if (view) {
		_dismissTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
		_dismissTap.cancelsTouchesInView = NO;
		[view addGestureRecognizer:_dismissTap];
	}
}

- (void)textDidChange:(UITextField *)textField {
	MCWritePreference([self specifier], textField.text ?: @"");
}

- (void)dismissKeyboard {
	[_textField resignFirstResponder];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	[textField resignFirstResponder];
	return YES;
}

- (void)dealloc {
	[_textField removeTarget:self action:@selector(textDidChange:) forControlEvents:UIControlEventEditingChanged];
	if (_dismissTap) {
		[_dismissTap.view removeGestureRecognizer:_dismissTap];
	}
}

@end
