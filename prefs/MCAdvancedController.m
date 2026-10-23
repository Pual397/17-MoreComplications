#import "MCAdvancedController.h"

// Plain settings page for the advanced options.
//
// PSChildPaneSpecifier did not open on every bootstrap, so the main page links
// here with PSLinkCell + detail + isController instead — the same mechanism
// that gets from Settings into MCSettingsController.
@implementation MCAdvancedController {
	NSMutableArray *_advancedSpecifiers;
}

- (NSMutableArray *)specifiers {
	if (!_advancedSpecifiers) {
		_advancedSpecifiers = [self loadSpecifiersFromPlistName:@"Advanced" target:self];
	}
	return _advancedSpecifiers;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"高级选项";
}

@end
