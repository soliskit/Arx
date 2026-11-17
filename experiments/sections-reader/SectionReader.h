#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Test-only seam. Implementations must not enumerate stores or unrelated objects.
@protocol ARXSectionReadSession <NSObject>
- (nullable NSDictionary *)listWithUUID:(NSString *)uuid;
- (nullable NSDictionary *)reminderWithUUID:(NSString *)uuid;
/// nil means unknown, NOT unsectioned. Only an independently qualified provider
/// may return {state: none}; the private candidate never returns that state.
- (nullable NSDictionary *)membershipForReminderUUID:(NSString *)uuid;
@end

@protocol ARXSectionReadProvider <NSObject>
/// Each read gets a fresh provider session; never reuse writer objects.
- (nullable id<ARXSectionReadSession>)newReadSession;
@end

@interface ARXSectionReader : NSObject
- (instancetype)initWithProvider:(id<ARXSectionReadProvider>)provider;
/// Request: listID, reminderID, expectedListName, expectedReminderTitle.
/// Grant: read (NSNumber boolean), listIDs (array of exact EventKit identifiers).
/// Result: state section/none/unknown; fixed non-private reason; optional sectionID.
/// EventKit-to-private ID equivalence remains an experiment gate, not a guarantee.
- (NSDictionary *)readRequest:(NSDictionary *)request grant:(NSDictionary *)grant;
@end

/// Contains no executable entry point and is NOT wired into the app. Constructing
/// this object alone does not load ReminderKit or construct a Reminders store.
/// Calling newReadSession would access the default store and is NOT permitted by
/// this preparation's build/fixture workflow. Future real use needs its own scope.
@interface ARXPrivateSectionReadProvider : NSObject <ARXSectionReadProvider>
@end

NS_ASSUME_NONNULL_END
