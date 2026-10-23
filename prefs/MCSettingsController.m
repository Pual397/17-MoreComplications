#import "MCSettingsController.h"
#import "Preferences.h"
#import <rootless.h>
#import <spawn.h>
extern char **environ;

@interface MCSettingsController ()
@property (nonatomic, assign) CGFloat mc_keyboardInset;
@end

@implementation MCSettingsController

#pragma mark - Keyboard

- (void)viewDidLoad {
	[super viewDidLoad];

	[[NSNotificationCenter defaultCenter] addObserver:self
	                                         selector:@selector(mc_keyboardWillChange:)
	                                             name:UIKeyboardWillChangeFrameNotification
	                                           object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self
	                                         selector:@selector(mc_keyboardWillHide:)
	                                             name:UIKeyboardWillHideNotification
	                                           object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];

	[[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillChangeFrameNotification object:nil];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];

	self.mc_keyboardInset = 0.0;
	[self mc_applyKeyboardInset];
}

- (UITableView *)mc_table {
	return [self valueForKey:@"_table"];
}

// SPSettingsController rewrites contentInset inside layoutHeader (which runs on
// every scroll), so the keyboard inset is re-applied right after it.
- (void)layoutHeader {
	[super layoutHeader];
	[self mc_applyKeyboardInset];
}

- (void)mc_applyKeyboardInset {
	UITableView *table = [self mc_table];
	if (!table) return;

	UIEdgeInsets inset = table.contentInset;
	if (fabs(inset.bottom - self.mc_keyboardInset) < 0.5) return;

	inset.bottom = self.mc_keyboardInset;
	table.contentInset = inset;

	UIEdgeInsets indicator = table.scrollIndicatorInsets;
	indicator.bottom = self.mc_keyboardInset;
	table.scrollIndicatorInsets = indicator;
}

- (void)mc_keyboardWillChange:(NSNotification *)note {
	CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
	CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
	self.mc_keyboardInset = MAX(0.0, screenHeight - CGRectGetMinY(frame));

	[self mc_applyKeyboardInset];
	[self mc_scrollToFirstResponder];
}

- (void)mc_keyboardWillHide:(NSNotification *)note {
	self.mc_keyboardInset = 0.0;
	[self mc_applyKeyboardInset];
}

- (UIView *)mc_firstResponderIn:(UIView *)view {
	if (view.isFirstResponder) return view;

	for (UIView *subview in view.subviews) {
		UIView *found = [self mc_firstResponderIn:subview];
		if (found) return found;
	}
	return nil;
}

- (void)mc_scrollToFirstResponder {
	UITableView *table = [self mc_table];
	UIView *responder = [self mc_firstResponderIn:self.view];
	if (!table || !responder) return;

	UIView *cell = responder;
	while (cell && ![cell isKindOfClass:[UITableViewCell class]]) {
		cell = cell.superview;
	}
	if (!cell) return;

	NSIndexPath *indexPath = [table indexPathForCell:(UITableViewCell *)cell];
	if (indexPath) {
		[table scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
	}
}

#pragma mark - Actions

- (void)respring {
	// kill PostBoard too
	pid_t pid;
	const char *argv[] = {ROOT_PATH("/usr/bin/killall"), "-9", "PosterBoard", NULL};
	posix_spawn(&pid, argv[0], NULL, NULL, (char* const*)argv, environ);
	waitpid(pid, NULL, WEXITED);

	// respring
	SBSRelaunchAction *restartAction = [NSClassFromString(@"SBSRelaunchAction") actionWithReason:@"RestartRenderServer" options:SBSRelaunchOptionsFadeToBlack targetURL:[NSURL URLWithString:@"prefs:root=MoreComplications"]];
	NSSet *actions = [NSSet setWithObject:restartAction];
	FBSSystemService *frontBoardService = [NSClassFromString(@"FBSSystemService") sharedService];
	[frontBoardService sendActions:actions withResult:nil];
}

@end
