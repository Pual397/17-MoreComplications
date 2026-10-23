#import "MCSettingsController.h"
#import "Preferences.h"
#import <rootless.h>
#import <spawn.h>
extern char **environ;

@interface MCSettingsController ()
@property (nonatomic, assign) CGFloat mc_keyboardHeight;
@end

@implementation MCSettingsController

#pragma mark - Keyboard

- (void)viewDidLoad {
	[super viewDidLoad];

	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserver:self
	           selector:@selector(mc_keyboardWillChange:)
	               name:UIKeyboardWillChangeFrameNotification
	             object:nil];
	[center addObserver:self
	           selector:@selector(mc_keyboardWillChange:)
	               name:UIKeyboardDidShowNotification
	             object:nil];
	[center addObserver:self
	           selector:@selector(mc_keyboardWillHide:)
	               name:UIKeyboardWillHideNotification
	             object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];

	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[self mc_resetShift];
}

- (UITableView *)mc_table {
	UIView *view = self.view;
	return [view isKindOfClass:[UITableView class]] ? (UITableView *)view : [self valueForKey:@"_table"];
}

- (UIView *)mc_firstResponderIn:(UIView *)view {
	if (view.isFirstResponder) return view;

	for (UIView *subview in view.subviews) {
		UIView *found = [self mc_firstResponderIn:subview];
		if (found) return found;
	}
	return nil;
}

- (void)mc_resetShift {
	UITableView *table = [self mc_table];
	if (table.transform.a != 1.0 || table.transform.ty != 0.0) {
		table.transform = CGAffineTransformIdentity;
	}
}

// The table cannot be scrolled reliably here: SPSettingsController rewrites its
// contentInset on every scroll. Translating the whole page instead always works
// and is undone as soon as the keyboard goes away.
- (void)mc_shiftForKeyboardHeight:(CGFloat)keyboardHeight {
	UITableView *table = [self mc_table];
	if (!table) return;

	table.transform = CGAffineTransformIdentity;
	if (keyboardHeight <= 0) return;

	UIView *responder = [self mc_firstResponderIn:table];
	if (!responder) return;

	UIWindow *window = table.window ?: responder.window;
	if (!window) return;

	CGRect fieldInWindow = [responder convertRect:responder.bounds toView:window];
	CGFloat keyboardTop = CGRectGetHeight(window.bounds) - keyboardHeight;
	CGFloat overlap = CGRectGetMaxY(fieldInWindow) + 12.0 - keyboardTop;
	if (overlap <= 0.0) return;

	[UIView animateWithDuration:0.25
	                 animations:^{
		table.transform = CGAffineTransformMakeTranslation(0, -overlap);
	}];
}

- (void)mc_keyboardWillChange:(NSNotification *)note {
	NSDictionary *info = note.userInfo;
	CGRect frame = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
	CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;

	CGFloat height = MAX(0.0, screenHeight - CGRectGetMinY(frame));
	if (height <= 0.0) {
		height = self.mc_keyboardHeight;
	}
	self.mc_keyboardHeight = height;

	[self mc_shiftForKeyboardHeight:height];
}

- (void)mc_keyboardWillHide:(NSNotification *)note {
	self.mc_keyboardHeight = 0.0;
	[UIView animateWithDuration:0.25
	                 animations:^{
		[self mc_resetShift];
	}];
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
