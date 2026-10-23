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

// Per-row layout, parsed from e.g. "2C 1J" (row 1: two elements centered,
// row 2: one element justified between both edges). L/R apply to single
// elements that should hug one edge.
typedef NS_ENUM(int, MCAlignment) {
	MCAlignmentCenter = 0,
	MCAlignmentJustify,
	MCAlignmentLeft,
	MCAlignmentRight,
};

static NSArray<NSNumber *> *rowBreaks = nil;  // 每行最多几个组件，例如 [2, 1]
static NSArray<NSNumber *> *rowAligns = nil;  // 每行对齐方式，例如 [J, C]

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

// MARK: - row layout

static int MCEffectiveRows(void) {
	int count = rows;
	if ((int)rowBreaks.count > count) count = (int)rowBreaks.count;
	if ((int)rowAligns.count > count) count = (int)rowAligns.count;
	if (count < 1) count = 1;
	return count;
}

// 一行一个 token，形如 "2C 1J"：数量 + 对齐（C 居中 / J 两端 / L 左 / R 右）。
// 解析后拆成 rowBreaks（每行最多几个）和 rowAligns（每行对齐方式）两份数据，
// 后面的分行、对齐逻辑只认这两份数据。
static void MCParseRowLayout(NSString *string) {
	rowBreaks = nil;
	rowAligns = nil;
	if (![string isKindOfClass:[NSString class]] || string.length == 0) return;

	NSMutableArray<NSNumber *> *counts = [NSMutableArray array];
	NSMutableArray<NSNumber *> *aligns = [NSMutableArray array];
	NSArray *tokens = [string componentsSeparatedByCharactersInSet:
	                   [NSCharacterSet characterSetWithCharactersInString:@" ,;\t\n"]];

	for (NSString *token in tokens) {
		NSString *trimmed = [[token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] uppercaseString];
		if (trimmed.length == 0) continue;

		NSUInteger digits = 0;
		while (digits < trimmed.length && isdigit((int)[trimmed characterAtIndex:digits])) digits++;

		int count = 1;
		if (digits > 0) {
			count = [[trimmed substringToIndex:digits] intValue];
			if (count <= 0) count = 1;
		}

		MCAlignment align = MCAlignmentCenter;
		if (digits < trimmed.length) {
			unichar letter = [trimmed characterAtIndex:digits];
			if (letter == 'J') align = MCAlignmentJustify;
			else if (letter == 'L') align = MCAlignmentLeft;
			else if (letter == 'R') align = MCAlignmentRight;
		}

		[counts addObject:@(count)];
		[aligns addObject:@(align)];
		if (counts.count >= 8) break;  // sanity cap
	}

	rowBreaks = counts.count ? counts : nil;
	rowAligns = aligns.count ? aligns : nil;
}

static MCAlignment MCAlignmentForRow(NSUInteger index) {
	if (index < rowAligns.count) return (MCAlignment)[rowAligns[index] intValue];
	return MCAlignmentCenter;
}

// Packs elements by the system's own capacity (4 grid units per row), adding
// rows until `maxRows` is reached. Anything that still does not fit is left
// unplaced; MCExpandedFrames keeps its original frame in that case.
static void MCAppendAutoRows(NSMutableArray<NSMutableArray *> *groups, NSArray *elements, NSUInteger maxRows) {
	if (elements.count == 0 || groups.count >= maxRows) return;

	[groups addObject:[NSMutableArray array]];
	NSUInteger row = groups.count - 1;
	long long used = 0;

	for (id element in elements) {
		long long width = [element respondsToSelector:@selector(gridWidth)] ? [element gridWidth] : ELEMENTS_PER_ROW;
		if (used + width > ELEMENTS_PER_ROW) {
			if (groups.count >= maxRows) break;
			[groups addObject:[NSMutableArray array]];
			row = groups.count - 1;
			used = 0;
		}
		[groups[row] addObject:element];
		used += width;
	}
}

// Rows listed in "每行数量" take exactly that many elements, in the order the OS
// hands them over; whatever is left keeps packing automatically.
static NSArray<NSArray *> *MCGroupElementsConfigured(NSArray *elements, int rowCount) {
	NSMutableArray<NSMutableArray *> *groups = [NSMutableArray array];
	NSUInteger maxRows = (NSUInteger)MAX(rowCount, 1);

	if (rowBreaks.count == 0) {
		MCAppendAutoRows(groups, elements, maxRows);
		return groups;
	}

	NSUInteger index = 0;
	for (NSUInteger row = 0; row < rowBreaks.count && row < maxRows && index < elements.count; row++) {
		[groups addObject:[NSMutableArray array]];
		NSUInteger take = (NSUInteger)[rowBreaks[row] intValue];
		for (NSUInteger k = 0; k < take && index < elements.count; k++, index++) {
			[groups[row] addObject:elements[index]];
		}
	}

	if (index < elements.count) {
		MCAppendAutoRows(groups, [elements subarrayWithRange:NSMakeRange(index, elements.count - index)], maxRows);
	}
	return groups;
}

// Places one row's frames: y offset for the row, x per alignment.
// C keeps the OS' own centered spacing, L/R shift the whole row to an edge,
// J spreads the free space so the first element hugs the left edge and the
// last one hugs the right edge.
static void MCMergeRowAligned(NSMutableDictionary *merged,
                              NSDictionary *rowFrames,
                              CGFloat yOffset,
                              CGFloat containerWidth,
                              MCAlignment alignment) {
	if (![rowFrames isKindOfClass:[NSDictionary class]] || rowFrames.count == 0) return;

	NSArray *keys = [[rowFrames allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
		CGFloat xa = [(NSValue *)rowFrames[a] CGRectValue].origin.x;
		CGFloat xb = [(NSValue *)rowFrames[b] CGRectValue].origin.x;
		if (xa < xb) return NSOrderedAscending;
		if (xa > xb) return NSOrderedDescending;
		return NSOrderedSame;
	}];

	CGFloat total = 0;
	CGFloat minX = CGFLOAT_MAX;
	CGFloat maxX = -CGFLOAT_MAX;
	for (id key in keys) {
		CGRect frame = [(NSValue *)rowFrames[key] CGRectValue];
		total += frame.size.width;
		minX = MIN(minX, frame.origin.x);
		maxX = MAX(maxX, CGRectGetMaxX(frame));
	}
	NSUInteger count = keys.count;

	if (alignment == MCAlignmentJustify && count < 2) alignment = MCAlignmentCenter;

	if (alignment == MCAlignmentJustify && total <= containerWidth) {
		CGFloat gap = (containerWidth - total) / (CGFloat)(count - 1);
		CGFloat cursor = 0;
		for (id key in keys) {
			CGRect frame = [(NSValue *)rowFrames[key] CGRectValue];
			frame.origin.x = cursor;
			frame.origin.y += yOffset;
			merged[key] = [NSValue valueWithCGRect:frame];
			cursor += frame.size.width + gap;
		}
		return;
	}

	CGFloat dx = 0;
	if (alignment == MCAlignmentLeft) dx = -minX;
	else if (alignment == MCAlignmentRight) dx = containerWidth - maxX;

	for (id key in keys) {
		CGRect frame = [(NSValue *)rowFrames[key] CGRectValue];
		frame.origin.x += dx;
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
	int rowCount = MCEffectiveRows();
	if (!enabled || rowCount <= 1) return nil;
	if (!MCFramesAreSingleRow(originalFrames)) return nil;

	CGSize rowSize = MCRowContainerSize(containerSize, rowCount);
	if (rowSize.height <= 0 || rowSize.width <= 0) return nil;

	NSArray<NSArray *> *groups = MCGroupElementsConfigured(elements, rowCount);
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
		MCMergeRowAligned(merged, frames, i * (rowSize.height + spacing), containerSize.width, MCAlignmentForRow(i));
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
	if (!enabled || MCEffectiveRows() <= 1 || !element) return %orig;

	long long totalWidth = 0;
	for (CSComplicationLayoutElement *existing in elements) {
		if (![existing respondsToSelector:@selector(gridWidth)]) return %orig;
		totalWidth += [existing gridWidth];
	}	if (![element respondsToSelector:@selector(gridWidth)]) return %orig;

	if (totalWidth + [element gridWidth] <= (long long)MCEffectiveRows() * ELEMENTS_PER_ROW) {
		MCLogOnce(@"canAddElement:toElements: hooked");
		return true;
	}
	return %orig;
}

// iOS 17: the same limit, now aware of the layout style.
// Only ever widen the limit here, never tighten what the OS allows.
+ (bool)canAddElement:(CSComplicationLayoutElement *)element toElements:(NSArray<CSComplicationLayoutElement *> *)elements layoutStyle:(long long)layoutStyle {
	if (!enabled || MCEffectiveRows() <= 1 || !element) return %orig;

	long long totalWidth = 0;
	for (CSComplicationLayoutElement *existing in elements) {
		totalWidth += [existing gridWidth];
	}

	if (totalWidth + [element gridWidth] <= (long long)MCEffectiveRows() * ELEMENTS_PER_ROW) {
		MCLogOnce(@"canAddElement:toElements:layoutStyle: hooked");
		return true;
	}
	return %orig;
}

// Grow the complication container so the extra rows have room.
+ (double)complicationContainerHeight {
	double height = %orig;
	int rowCount = MCEffectiveRows();
	if (!enabled || rowCount <= 1 || height <= 0) return height;

	double spacing = MCSpacing();
	return height * rowCount + spacing * (rowCount - 1);
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
	if (rows > 4) rows = 4;

	rowBreaks = nil;
	rowAligns = nil;
	MCParseRowLayout([settings objectForKey:@"rowLayout"]);

	if (rowBreaks.count > 0) {
		NSLog(@"[MoreComplications] layout=%@ breaks=%@ aligns=%@ rows=%d",
		      [settings objectForKey:@"rowLayout"], rowBreaks, rowAligns, rows);
	}
}

static void PreferencesChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
  refreshPrefs();
}

%ctor {
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback) PreferencesChangedCallback, (CFStringRef)[NSString stringWithFormat:@"%@.prefschanged", BUNDLE_ID], NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	refreshPrefs();
	NSLog(@"[MoreComplications] loaded on iOS %@ (rows=%d, enabled=%d)", [[NSProcessInfo processInfo] operatingSystemVersionString], rows, enabled);
}
