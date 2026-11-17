#import <Foundation/Foundation.h>

// Fixed final fields only. Unknown or malformed results cannot carry private text.
static inline NSDictionary *ARXSectionDiagnostic(NSDictionary *result) {
    if ([result isKindOfClass:NSDictionary.class]) {
        if ([result[@"state"] isEqual:@"section"] &&
            [result[@"sectionMatched"] isKindOfClass:NSNumber.class]) {
            BOOL match = [result[@"sectionMatched"] isEqual:@YES];
            return @{ @"state": match ? @"section" : @"unknown",
                @"reason": match ? @"exact_object_candidate" : @"section_name_mismatch",
                @"sectionMatched": @(match) };
        }
        NSString *reason = result[@"reason"];
        if ([result[@"state"] isEqual:@"unknown"] && [reason isKindOfClass:NSString.class]) {
            if ([reason isEqual:@"unavailable"]) reason = @"membership_api_unavailable";
            if ([@[@"denied", @"identity_unverified", @"membership_api_unavailable",
                   @"membership_unverified", @"private_api_exception"] containsObject:reason])
                return @{ @"state": @"unknown", @"reason": reason, @"sectionMatched": @NO };
        }
    }
    return @{ @"state": @"unknown", @"reason": @"worker_unavailable", @"sectionMatched": @NO };
}
