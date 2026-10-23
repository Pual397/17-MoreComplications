#import <Foundation/Foundation.h>
#import <rootless.h>
#import <objc/runtime.h>
#import "Tweak.h"

#define BUNDLE_ID @"xyz.skitty.morecomplications"
#define ELEMENTS_PER_ROW 4
#define MC_EPSILON 0.5

static NSMutableDictionary *settings;
static BOOL enabled = YES;
static int rows = 2;

#pragma mark - logging

// Hooks that landed are logged once, so "install the tweak and check Console"
// is enough to tell which OS path is in use.
static void MCLogOnce(NSString *message) {
	static NSMutableSet *seen = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		seen = [NSMutableSet new];
	});
	@synchronized (seen) {
		if ([seen containsObject:message]) return;
		[seen addObject:message];
	}
	NSLog(@"[MoreComplications] %@", message);
}

#pragma mark - helpers

static Class MCProviderClass(void) {
	return objc_getClass("CSGraphicComplicationLayoutProvider");
}

static double MCSpacing(void) {
	Class provider = MCProviderClass();
	if (!provider) return 0;
	double spacing = [provider complicationEdgeInset];
	if (spacing <= 0 && [provider respondsToSelector:@selector(interComplicationSpacing)]) {
		spacing = [provider interComplicationSpacing];
	}
	return spacing;
}

// Container size for a single original row, i.e. the size the OS would have
// used if there were only one row of complications.
static CGSize MCRowContainerSize(CGSize containerSize, int rowCount) {
	CGSize size = containerSize;
	double spacing = MCSpacing();
	size.height -= spacing * (rowCount - 1);
	if (rowCount > 0) size.height /= rowCount;
	return size;
}

// Greedy packing: every element goes into the first row that still has room.
static NSArray<NSArray *> *MCGroupElements(NSArray *elements, int rowCount) {
	NSMutableArray<NSMutableArray *> *groups = [NSMutableArray arrayWithCapacity:rowCount];
	NSMutableArray<NSNumber *> *widths = [NSMutableArray arrayWithCapacity:rowCount];
	for (int i = 0; i < rowCount; i++) {
		[groups addObject:[NSMutableArray array]];
		[widths addObject:@0];
	}

	for (CSComplicationLayoutElement *element in elements) {
		// An element without gridWidth is treated as a full row of its own.
		long long width = [element respondsToSelector:@selector(gridWidth)] ? [element gridWidth] : ELEMENTS_PER_ROW;
		for (int i = 0; i < rowCount; i++) {
			long long used = [widths[i] longLongValue];
			if (used + width <= ELEMENTS_PER_ROW) {
				widths[i] = @(used + width);
				[groups[i] addObject:element];
				break;
			}
		}
	}
	return groups;
}

// True when every frame sits on the same baseline, which is exactly the
// situation this tweak replaces with several rows. Anything already laid out
// over several rows (or a sidebar column) is left untouched, which also makes
// the transformation idempotent if several hooks see the same call.
static BOOL MCFramesAreSingleRow(NSDictionary *frames) {
	if (![frames isKindOfClass:[NSDictionary class]] || frames.count == 0) return NO;

	BOOL first = YES;
	CGFloat baseY = 0;
	for (id key in frames) {
		id value = frames[key];
		if (![value isKindOfClass:[NSValue class]]) return NO;
		CGRect frame = [(NSValue *)value CGRectValue];
		if (first) {
			baseY = frame.origin.y;
			first = NO;
		} else if (fabs(frame.origin.y - baseY) > MC_EPSILON) {
			return NO;
		}
	}
	return YES;
}

static void MCMergeFrames(NSMutableDictionary *merged, NSDictionary *frames, CGFloat yOffset) {
	if (![frames isKindOfClass:[NSDictionary class]]) return;

	for (id key in frames) {
		id value = frames[key];
		if (![value isKindOfClass:[NSValue class]]) continue;
		CGRect frame = [(NSValue *)value CGRectValue];
		frame.origin.y += yOffset;
		merged[key] = [NSValue valueWithCGRect:frame];
	}
}

// `call` lays out a subset of the elements with the original implementation and
// returns either a frames dictionary (iOS 16) or a CSComplicationLayout (iOS 17).
static NSDictionary *MCExpandedFrames(NSArray *elements,
                                      CGSize containerSize,
                                      NSDictionary *originalFrames,
                                      id (^call)(NSArray *subset, CGSize size)) {
	if (!enabled || rows <= 1) return nil;
	if (!MCFramesAreSingleRow(originalFrames)) return nil;

	CGSize rowSize = MCRowContainerSize(containerSize, rows);
	if (rowSize.height <= 0 || rowSize.width <= 0) return nil;

	NSArray<NSArray *> *groups = MCGroupElements(elements, rows);
	NSMutableDictionary *merged = [NSMutableDictionary dictionary];
	double spacing = MCSpacing();

	for (NSUInteger i = 0; i < groups.count; i++) {
		NSArray *group = groups[i];
		if (group.count == 0) continue;

		id result = call(group, rowSize);
		NSDictionary *frames = nil;
		// Look the class up by name: the tweak does not link CoverSheetKit, so a
		// direct reference to CSComplicationLayout would be an undefined symbol.
		Class layoutClass = objc_getClass("CSComplicationLayout");
		if (layoutClass && [result isKindOfClass:layoutClass]) {
			frames = [(CSComplicationLayout *)result framesByElement];
		} else if ([result isKindOfClass:[NSDictionary class]]) {
			frames = result;
		}
		MCMergeFrames(merged, frames, i * (rowSize.height + spacing));
	}

	if (merged.count == 0) return nil;

	// Never drop an element: keep the original frame for anything unplaced.
	for (id key in originalFrames) {
		if (!merged[key]) merged[key] = originalFrames[key];
	}
	return [merged copy];
}

static CSComplicationLayout *MCLayoutWithFrames(NSDictionary *frames, long long insertionIndex) {
	Class layoutClass = objc_getClass("CSComplicationLayout");
	if (!layoutClass) return nil;

	id layout = [[layoutClass alloc] _initWithFramesByElement:frames
	                                 draggedItemInsertionIndex:insertionIndex];
	return [layout isKindOfClass:layoutClass] ? layout : nil;
}

#pragma mark - hooks

%hook CSGraphicComplicationLayoutProvider

// iOS 16: raise the element limit.
+ (bool)canAddElement:(CSComplicationLayoutElement *)element toElements:(NSArray<CSComplicationLayoutElement *> *)elements {
	if (!enabled || rows <= 1 || !element) return %orig;

	long long totalWidth = 0;
	for (CSComplicationLayoutElement *existing in elements) {
		if (![existing respondsToSelector:@selector(gridWidth)]) return %orig;
		totalWidth += [existing gridWidth];
	}
	if (![element respondsToSelector:@selector(gridWidth)]) return %orig;

	if (totalWidth + [element gridWidth] <= (long long)rows * ELEMENTS_PER_ROW) {
		MCLogOnce(@"canAddElement:toElements: hooked");
		return true;
	}
	return %orig;
}

// iOS 17: the same limit, now aware of the layout style.
// Only ever widen the limit here, never tighten what the OS allows.
+ (bool)canAddElement:(CSComplicationLayoutElement *)element toElements:(NSArray<CSComplicationLayoutElement *> *)elements layoutStyle:(long long)layoutStyle {
	if (!enabled || rows <= 1 || !element) return %orig;

	long long totalWidth = 0;
	for (CSComplicationLayoutElement *existing in elements) {
		totalWidth += [existing gridWidth];
	}

	if (totalWidth + [element gridWidth] <= (long long)rows * ELEMENTS_PER_ROW) {
		MCLogOnce(@"canAddElement:toElements:layoutStyle: hooked");
		return true;
	}
	return %orig;
}

// Grow the complication container so the extra rows have room.
+ (double)complicationContainerHeight {
	double height = %orig;
	if (!enabled || rows <= 1 || height <= 0) return height;

	double spacing = MCSpacing();
	return height * rows + spacing * (rows - 1);
}

// iOS 16 layout: a plain element -> NSValue(CGRect) dictionary.
+ (NSDictionary<CSComplicationLayoutElement *, NSValue *> *)_framesForLayoutElements:(NSArray<CSComplicationLayoutElement *> *)elements containerSize:(CGSize)containerSize {
	NSDictionary *original = %orig;

	NSDictionary *expanded = MCExpandedFrames(elements, containerSize, original, ^id(NSArray *subset, CGSize size) {
		return %orig(subset, size);
	});
	if (expanded) {
		MCLogOnce(@"iOS 16 frames path hooked");
		return expanded;
	}
	return original;
}

// iOS 17 layout: same thing plus a layout style. The single-row check inside
// MCExpandedFrames keeps sidebar layouts untouched.
+ (NSDictionary<CSComplicationLayoutElement *, NSValue *> *)_framesForLayoutElements:(NSArray<CSComplicationLayoutElement *> *)elements layoutStyle:(long long)layoutStyle containerSize:(CGSize)containerSize {
	NSDictionary *original = %orig;

	NSDictionary *expanded = MCExpandedFrames(elements, containerSize, original, ^id(NSArray *subset, CGSize size) {
		return %orig(subset, layoutStyle, size);
	});
	if (expanded) {
		MCLogOnce(@"iOS 17 frames path hooked");
		return expanded;
	}
	return original;
}

// iOS 17 main entry point: callers get a CSComplicationLayout back, so the
// frames have to be rewrapped instead of returned directly.
+ (id)complicationLayoutForElements:(NSArray<CSComplicationLayoutElement *> *)elements containerSize:(CGSize)containerSize {
	CSComplicationLayout *original = %orig;
	NSDictionary *originalFrames = [original framesByElement];

	NSDictionary *expanded = MCExpandedFrames(elements, containerSize, originalFrames, ^id(NSArray *subset, CGSize size) {
		return %orig(subset, size);
	});
	if (!expanded) return original;

	CSComplicationLayout *layout = MCLayoutWithFrames(expanded, [original draggedItemInsertionIndex]);
	if (layout) MCLogOnce(@"iOS 17 complicationLayout path hooked");
	return layout ?: original;
}

+ (id)complicationLayoutForElements:(NSArray<CSComplicationLayoutElement *> *)elements layoutStyle:(long long)layoutStyle containerSize:(CGSize)containerSize {
	CSComplicationLayout *original = %orig;
	NSDictionary *originalFrames = [original framesByElement];

	NSDictionary *expanded = MCExpandedFrames(elements, containerSize, originalFrames, ^id(NSArray *subset, CGSize size) {
		return %orig(subset, layoutStyle, size);
	});
	if (!expanded) return original;

	CSComplicationLayout *layout = MCLayoutWithFrames(expanded, [original draggedItemInsertionIndex]);
	if (layout) MCLogOnce(@"iOS 17 complicationLayout:layoutStyle: path hooked");
	return layout ?: original;
}

// Dragging keeps its native behaviour; the final layout is re-arranged by the
// hooks above once the drag ends.
+ (id)complicationLayoutForElements:(NSArray<CSComplicationLayoutElement *> *)elements containerSize:(CGSize)containerSize draggedElement:(id)draggedElement draggedElementPosition:(CGPoint)draggedElementPosition {
	return %orig;
}

+ (id)complicationLayoutForElements:(NSArray<CSComplicationLayoutElement *> *)elements layoutStyle:(long long)layoutStyle containerSize:(CGSize)containerSize draggedElement:(id)draggedElement draggedElementPosition:(CGPoint)draggedElementPosition {
	return %orig;
}

%end

#pragma mark - preferences

// Preference updates
void refreshPrefs() {
	CFArrayRef keyList = CFPreferencesCopyKeyList((CFStringRef)BUNDLE_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	if (keyList) {
		settings = (NSMutableDictionary *)CFBridgingRelease(CFPreferencesCopyMultiple(keyList, (CFStringRef)BUNDLE_ID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
		CFRelease(keyList);
	} else {
		settings = nil;
	}
	if (!settings) {
		NSString *settingsPath = ROOT_PATH_NS(@"/var/mobile/Library/Preferences/");
		settings = [[NSMutableDictionary alloc] initWithContentsOfFile:[NSString stringWithFormat:@"%@%@.plist", settingsPath, BUNDLE_ID]];
	}

	enabled = [([settings objectForKey:@"enabled"] ?: @(YES)) boolValue];
	rows = [([settings objectForKey:@"rows"] ?: @(2)) intValue];
	if (rows < 1) rows = 1;
	if (rows > 3) rows = 3;
}

static void PreferencesChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
  refreshPrefs();
}

%ctor {
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback) PreferencesChangedCallback, (CFStringRef)[NSString stringWithFormat:@"%@.prefschanged", BUNDLE_ID], NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	refreshPrefs();
	NSLog(@"[MoreComplications] loaded on iOS %@ (rows=%d, enabled=%d)", [[NSProcessInfo processInfo] operatingSystemVersionString], rows, enabled);
}
