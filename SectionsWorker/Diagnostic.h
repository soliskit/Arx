#import <Foundation/Foundation.h>

// Fixed final fields only. Unknown or malformed results cannot carry private text.
static inline NSDictionary *ARXSectionDiagnostic(NSDictionary *result) {
    if ([result isKindOfClass:NSDictionary.class]) {
        if ([result[@"state"] isEqual:@"section"] &&
            [result[@"sectionMatched"] isKindOfClass:NSNumber.class]) {
            BOOL match = [result[@"sectionMatched"] isEqual:@YES];
            NSMutableDictionary *clean = [@{ @"state": match ? @"section" : @"unknown",
                @"reason": match ? @"exact_object_candidate" : @"section_name_mismatch",
                @"sectionMatched": @(match) } mutableCopy];
            // Owner-approved disposable-scope names, bounded plain text only.
            // The returned name is verified to the selected list/account by the
            // reader but may be a pre-existing section in that list.
            NSString *expected = result[@"expectedSection"];
            NSString *actual = result[@"actualSection"];
            if ([expected isKindOfClass:NSString.class] && expected.length > 0 && expected.length <= 256 &&
                [actual isKindOfClass:NSString.class] && actual.length > 0 && actual.length <= 256) {
                clean[@"expectedSection"] = expected;
                clean[@"actualSection"] = actual;
            }
            return clean;
        }
        NSString *reason = result[@"reason"];
        // Confirmed no-section positive: fixed fields only, never private text.
        if ([result[@"state"] isEqual:@"no_section"] &&
            [result[@"reason"] isEqual:@"membership_none_3009"]) {
            return @{ @"state": @"no_section", @"reason": @"membership_none_3009",
                @"sectionMatched": @NO };
        }
        if ([result[@"state"] isEqual:@"unknown"] && [reason isKindOfClass:NSString.class]) {
            if ([reason isEqual:@"unavailable"]) reason = @"membership_api_unavailable";
            if ([@[@"denied", @"identity_unverified", @"identity_list_unverified",
                   @"identity_source_unverified", @"identity_title_unverified",
                   @"membership_api_unavailable", @"membership_unverified", @"membership_nil_no_error",
                   @"membership_error", @"membership_section_identity", @"membership_unnamed",
                   @"store_unavailable", @"view_init_unavailable",
                   @"fetch_selector_unavailable", @"id_construction_unavailable",
                   @"private_api_exception"] containsObject:reason]) {
                NSMutableDictionary *clean =
                    [@{ @"state": @"unknown", @"reason": reason, @"sectionMatched": @NO } mutableCopy];
                // Structured error detail only: allowlisted domain/exception
                // names or the fixed token "other", and an integer code.
                NSString *domain = result[@"errorDomain"];
                if (domain != nil &&
                    [@[@"EKErrorDomain", @"NSCocoaErrorDomain", @"other"] containsObject:domain]) {
                    clean[@"errorDomain"] = domain;
                    NSNumber *code = result[@"errorCode"];
                    if ([code isKindOfClass:NSNumber.class]) clean[@"errorCode"] = code;
                }
                NSString *exception = result[@"exceptionName"];
                if (exception != nil &&
                    [@[@"NSInvalidArgumentException", @"NSInternalInconsistencyException",
                       @"NSRangeException", @"NSGenericException", @"other"] containsObject:exception])
                    clean[@"exceptionName"] = exception;
                return clean;
            }
        }
    }
    return @{ @"state": @"unknown", @"reason": @"worker_unavailable", @"sectionMatched": @NO };
}
