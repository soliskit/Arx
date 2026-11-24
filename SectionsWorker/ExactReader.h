#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// No store factory. Native preparation accepts exact EventKit objects only.
// The fixture build cannot construct an EventKit store or inspect private ivars.
@interface ARXExactSectionReader : NSObject
// Request/grant contain exact sourceID/listID/reminderID strings, read == YES.
// Single-read requests also carry expectedSection and answer a match boolean,
// never raw IDs. Batch requests omit it and answer the bounded verified name;
// the caller attaches the worker-verified reminderID after diagnosis.
// Native callers must resolve only these exact objects after authorization.
// Fixtures use synthetic objects; no caller-supplied "verified" binding exists.
- (NSDictionary *)readRequest:(NSDictionary *)request grant:(NSDictionary *)grant
                    calendar:(id)calendar reminder:(id)reminder;
@end

NS_ASSUME_NONNULL_END
