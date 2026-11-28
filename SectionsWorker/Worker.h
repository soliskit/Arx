#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Entry point for the bounded worker: the embedded ArxSectionsWorker helper's
// main, and the same-app --sections-local-worker dispatch kept for tests.
@interface ARXSectionWorker : NSObject
+ (int)run;
+ (NSString *)sourceRevision;
+ (NSString *)sourceManifest;
+ (BOOL)requiresAttribution;
@end
NS_ASSUME_NONNULL_END
