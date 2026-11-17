#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Entry point is called before SwiftUI/BridgeViewModel construction, only for
// --sections-local-worker. Same app executable and existing signing settings.
@interface ARXSectionWorker : NSObject
+ (int)run;
@end
NS_ASSUME_NONNULL_END
