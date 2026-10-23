#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// iOS 16 + iOS 17 surface of the Lock Screen complication layout provider.
// Methods declared here that do not exist on the running OS simply never get
// hooked, so one binary covers both layouts.

@interface CSGraphicComplicationLayoutProvider : NSObject

// geometry (iOS 16 + 17)
+ (double)complicationEdgeInset;
+ (double)interComplicationSpacing;
+ (double)complicationContainerHeight;
+ (double)complicationHeight;

// how many elements the editor lets you add (iOS 16)
+ (bool)canAddElement:(id)element toElements:(NSArray *)elements;
// how many elements the editor lets you add (iOS 17, layout-style aware)
+ (bool)canAddElement:(id)element toElements:(NSArray *)elements layoutStyle:(long long)layoutStyle;

// frame computation, iOS 16
+ (NSDictionary *)_framesForLayoutElements:(NSArray *)elements containerSize:(CGSize)containerSize;

// frame computation, iOS 17
+ (NSDictionary *)_framesForLayoutElements:(NSArray *)elements
                               layoutStyle:(long long)layoutStyle
                             containerSize:(CGSize)containerSize;
+ (NSDictionary *)_rowFramesForLayoutElements:(NSArray *)elements containerSize:(CGSize)containerSize;

// layout objects, iOS 17 (what callers actually use there)
+ (id)complicationLayoutForElements:(NSArray *)elements
                     containerSize:(CGSize)containerSize;
+ (id)complicationLayoutForElements:(NSArray *)elements
                     containerSize:(CGSize)containerSize
                    draggedElement:(id)draggedElement
           draggedElementPosition:(CGPoint)draggedElementPosition;
+ (id)complicationLayoutForElements:(NSArray *)elements
                       layoutStyle:(long long)layoutStyle
                     containerSize:(CGSize)containerSize;
+ (id)complicationLayoutForElements:(NSArray *)elements
                       layoutStyle:(long long)layoutStyle
                     containerSize:(CGSize)containerSize
                    draggedElement:(id)draggedElement
           draggedElementPosition:(CGPoint)draggedElementPosition;

@end

@interface CSComplicationLayoutElement : NSObject <NSCopying>
@property (nonatomic, readonly) long long gridWidth;
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly) unsigned long long complicationFamily;
@end

// iOS 17 replacement for a bare frames dictionary: it wraps the same
// element -> NSValue(CGRect) mapping.
@interface CSComplicationLayout : NSObject
@property (nonatomic, readonly) long long draggedItemInsertionIndex;
@property (nonatomic, readonly) NSDictionary *framesByElement;
- (instancetype)_initWithFramesByElement:(NSDictionary *)framesByElement
                 draggedItemInsertionIndex:(long long)draggedItemInsertionIndex;
@end

@interface NSValue (WhyArentTheseDefinedAlready)
+ (NSValue *)valueWithCGRect:(CGRect)rect;
- (CGRect)CGRectValue;
@end

typedef CGRect NSRect;
