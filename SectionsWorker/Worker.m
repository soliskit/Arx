#import "Worker.h"
#import "ExactReader.h"
#import "Diagnostic.h"
#if !defined(ARX_SECTION_READER_FIXTURES)
#import "ArxSectionsBuildStamp.h"
#else
#define ARX_SECTIONS_SOURCE_REVISION @"fixture"
#define ARX_SECTIONS_SOURCE_MANIFEST @"fixture"
#define ARX_SECTIONS_REQUIRES_ATTRIBUTION 0
#endif
#if !defined(ARX_SECTION_READER_FIXTURES)
#import <EventKit/EventKit.h>
#endif
#include <signal.h>
#include <string.h>
#include <unistd.h>

static void deadline(int number) { (void)number; _exit(124); }
static BOOL text(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 256;
}
// Fixed before/after operation markers: each is one raw write of a complete
// newline-terminated line, emitted in program order, always before the result
// JSON. A marker proves only that execution REACHED that point - never that an
// operation entered a private call or completed. A lost write must not kill
// the run, so marker write failures are ignored and the parent treats a
// missing marker as missing.
static void marker(NSString *operation, BOOL after) {
    NSString *line = [NSString stringWithFormat:@"stage=%@.%@\n", operation, after ? @"after" : @"before"];
    const char *p = line.UTF8String;
    size_t remaining = strlen(p);
    while (remaining) {
        ssize_t count = write(STDOUT_FILENO, p, remaining);
        if (count <= 0) return;
        remaining -= (size_t)count;
        p += count;
    }
}
static int writeData(NSData *data, int status) {
    const unsigned char *p = data.bytes;
    size_t remaining = data.length;
    while (remaining) {
        ssize_t count = write(STDOUT_FILENO, p, remaining);
        if (count <= 0) return 74;
        remaining -= (size_t)count;
        p += count;
    }
    return status;
}
// This process handles one request, then exits. The nonce binds only that
// exchange; it grants no permission and is not a source/build identity.
static NSString *requestNonce;
static int output(NSDictionary *result, int status) {
    if (requestNonce) {
        NSMutableDictionary *bound = [result mutableCopy];
        bound[@"requestNonce"] = requestNonce;
        bound[@"sourceRevision"] = ARX_SECTIONS_SOURCE_REVISION;
        bound[@"sourceManifest"] = ARX_SECTIONS_SOURCE_MANIFEST;
        result = bound;
    }
    marker(@"reply.encode", NO);
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
    if (!data) return 70;
    // reply.encode.after fires after serialization and BEFORE the write loop,
    // so the result JSON is always the trailing blob of the stream.
    marker(@"reply.encode", YES);
    // Labels are local selection data only. Section-read output is fixed and tiny.
    if (data.length > ([result[@"state"] isEqual:@"labels"] ? 16384u : 2048u)) {
        // A labels payload over the bound used to die here as a bare exit 70,
        // which the parent could only report as worker result unavailable.
        // Emit the fixed refusal instead so the stop names itself. The nested
        // refusal skips encode markers (already emitted above) so the marker
        // stream never carries a duplicate.
        if ([result[@"state"] isEqual:@"labels"]) {
            NSData *fallback = [NSJSONSerialization dataWithJSONObject:
                (requestNonce ? @{ @"state": @"unknown", @"reason": @"labels_too_large", @"requestNonce": requestNonce,
                    @"sourceRevision": ARX_SECTIONS_SOURCE_REVISION,
                    @"sourceManifest": ARX_SECTIONS_SOURCE_MANIFEST }
                    : @{ @"state": @"unknown", @"reason": @"labels_too_large" })
                options:NSJSONWritingSortedKeys error:NULL];
            return fallback ? writeData(fallback, 77) : 70;
        }
        return 70;
    }
    return writeData(data, status);
}
// Fixed-refusal helper, called only from the real-reader branch below; the
// fixture build compiles that branch out, so the guard keeps -Werror
// -Wunused-function clean in both configurations. Same treatment as
// permissionDetail.
#if !defined(ARX_SECTION_READER_FIXTURES)
static int refused(NSString *reason) {
    return output(@{ @"state": @"unknown", @"reason": reason }, 77);
}
#endif
// Fixed permission-status tokens only; the raw enum never crosses the stream.
#if !defined(ARX_SECTION_READER_FIXTURES)
static NSString *permissionDetail(EKAuthorizationStatus status) {
    switch (status) {
        case EKAuthorizationStatusNotDetermined: return @"status_not_determined";
        case EKAuthorizationStatusRestricted: return @"status_restricted";
        case EKAuthorizationStatusDenied: return @"status_denied";
        default: return @"status_other";
    }
}
#endif
@implementation ARXSectionWorker
+ (NSString *)sourceRevision { return ARX_SECTIONS_SOURCE_REVISION; }
+ (NSString *)sourceManifest { return ARX_SECTIONS_SOURCE_MANIFEST; }
+ (BOOL)requiresAttribution { return ARX_SECTIONS_REQUIRES_ATTRIBUTION != 0; }
+ (int)run {
    signal(SIGALRM, deadline);
    alarm(10);
    @autoreleasepool {
        @try {
            marker(@"input.read", NO);
            unsigned char bytes[4097]; size_t count = 0; ssize_t n = 0;
            while (count < sizeof(bytes) && (n = read(STDIN_FILENO, bytes + count, sizeof(bytes) - count)) > 0)
                count += (size_t)n;
            if (n < 0 || count == 0 || count > 4096) return 64;
            id input = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:count] options:0 error:NULL];
            if (![input isKindOfClass:NSDictionary.class] || !text(input[@"action"])) return 64;
            if (input[@"requestNonce"]) {
                id candidate = input[@"requestNonce"];
                if (![candidate isKindOfClass:NSString.class]) return 64;
                NSUUID *nonce = [[NSUUID alloc] initWithUUIDString:candidate];
                if (!nonce || ![nonce.UUIDString isEqual:candidate]) return 64;
                requestNonce = [candidate copy];
            }
            NSString *action = input[@"action"];
            if (![@[@"labels", @"locate", @"read"] containsObject:action]) return 64;
            if (![action isEqual:@"labels"]) {
                if (!text(input[@"sourceID"]) || !text(input[@"listID"]) ||
                    ![input[@"scratchConfirmed"] isEqual:@"yes"]) return 64;
            }
            if ([action isEqual:@"read"]) {
                for (NSString *key in @[@"sourceID", @"listID", @"reminderID", @"expectedSection"])
                    if (!text(input[key])) return 64;
            }
            marker(@"input.read", YES);
#if defined(ARX_SECTION_READER_FIXTURES)
            return output(@{ @"state": @"unknown", @"reason": @"fixture_no_provider" }, 69);
#else
            // Synthetic same-app mode: this argument refuses before any EventKit
            // store, existing permission state or private provider is touched.
            if ([NSProcessInfo.processInfo.arguments containsObject:@"--sections-local-fixtures"])
                return output(@{ @"state": @"unknown", @"reason": @"fixture_no_provider" }, 69);
            // No requestFullAccess, TCC prompt, service, new identity or entitlement.
            marker(@"permission.check", NO);
            EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
            marker(@"permission.check", YES);
            if (status != EKAuthorizationStatusFullAccess)
                return output(@{ @"state": @"unknown", @"reason": @"existing_permission_unavailable",
                    @"detail": permissionDetail(status) }, 77);
            marker(@"store.create", NO);
            EKEventStore *store = [EKEventStore new];
            marker(@"store.create", YES);
            if ([action isEqual:@"labels"]) {
                marker(@"lists.enumerate", NO);
                NSArray<EKCalendar *> *calendars = [store calendarsForEntityType:EKEntityTypeReminder];
                marker(@"lists.enumerate", YES);
                marker(@"labels.validate", NO);
                if (calendars.count > 100) return refused(@"label_bound_exceeded");
                NSMutableArray *rows = [NSMutableArray new];
                for (EKCalendar *calendar in calendars) {
                    if (!text(calendar.calendarIdentifier) || !text(calendar.source.sourceIdentifier) ||
                        !text(calendar.title) || !text(calendar.source.title)) return refused(@"labels_unverified");
                    [rows addObject:@{ @"id": calendar.calendarIdentifier, @"sourceID": calendar.source.sourceIdentifier,
                        @"title": calendar.title, @"sourceTitle": calendar.source.title }];
                }
                marker(@"labels.validate", YES);
                return output(@{ @"state": @"labels", @"reason": @"local_selection_only", @"lists": rows }, 0);
            }
            marker(@"calendar.bind", NO);
            EKCalendar *calendar = [store calendarWithIdentifier:input[@"listID"]];
            marker(@"calendar.bind", YES);
            // The failed identity check names its own fixed sub-reason.
            if (!calendar || !text(calendar.calendarIdentifier) ||
                ![calendar.calendarIdentifier isEqual:input[@"listID"]]) return refused(@"identity_list_unverified");
            if (!text(calendar.source.sourceIdentifier) ||
                ![calendar.source.sourceIdentifier isEqual:input[@"sourceID"]]) return refused(@"identity_source_unverified");
            if (![calendar.title isEqual:@"Arx Test A"]) return refused(@"identity_title_unverified");
            if ([action isEqual:@"locate"]) {
                marker(@"predicate.create", NO);
                NSPredicate *predicate = [store predicateForRemindersInCalendars:@[calendar]];
                marker(@"predicate.create", YES);
                if (!predicate) return refused(@"selection_unavailable");
                marker(@"reminders.fetch", NO);
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                __block NSArray<EKReminder *> *rows = nil;
                [store fetchRemindersMatchingPredicate:predicate completion:^(NSArray<EKReminder *> *found) {
                    rows = found;
                    dispatch_semaphore_signal(done);
                }];
                BOOL timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) != 0;
                marker(@"reminders.fetch", YES);
                if (timedOut) return refused(@"selection_timeout");
                marker(@"row.check", NO);
                // Do not inspect or output ANY reminder's fields until the exact
                // selected scratch list has exactly one object. Never fetch other lists.
                if (rows.count != 1) return refused(@"selection_not_exactly_one");
                EKReminder *only = rows.firstObject;
                if (![only.calendar.calendarIdentifier isEqual:input[@"listID"]]) return refused(@"identity_list_unverified");
                if (![only.calendar.source.sourceIdentifier isEqual:input[@"sourceID"]]) return refused(@"identity_source_unverified");
                if (!text(only.calendarItemIdentifier) || !text(only.title)) return refused(@"identity_title_unverified");
                marker(@"row.check", YES);
                return output(@{ @"state": @"item", @"reason": @"local_selection_only",
                    @"item": @{ @"id": only.calendarItemIdentifier, @"title": only.title } }, 0);
            }
            EKCalendarItem *item = [store calendarItemWithIdentifier:input[@"reminderID"]];
            if (![item isKindOfClass:EKReminder.class]) return refused(@"identity_unverified");
            marker(@"framework.load", NO);
            NSBundle *kit = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKit.framework"];
            BOOL loaded = [kit load];
            marker(@"framework.load", YES);
            if (!loaded) return refused(@"private_framework_unavailable");
            // This scope is generated by the local selection UI, not network input
            // or an Arx client grant. The worker cannot listen or start sharing.
            NSDictionary *grant = @{ @"read": @YES, @"sourceID": input[@"sourceID"],
                @"listID": input[@"listID"], @"reminderID": input[@"reminderID"] };
            NSDictionary *result = [[ARXExactSectionReader new] readRequest:input grant:grant calendar:calendar reminder:item];
            NSDictionary *diagnostic = ARXSectionDiagnostic(result);
            return output(diagnostic, [diagnostic[@"sectionMatched"] isEqual:@YES] ? 0 : 69);
#endif
        } @catch (NSException *exception) {
            // Fixed token only: an unrecognized exception name becomes "other"
            // and the name text itself never crosses the stream.
            NSArray *known = @[@"NSInvalidArgumentException", @"NSInternalInconsistencyException",
                               @"NSRangeException", @"NSGenericException"];
            NSString *name = [known containsObject:exception.name] ? exception.name : @"other";
            return output(@{ @"state": @"unknown", @"reason": @"private_api_exception",
                @"exceptionName": name }, 77);
        }
    }
}
@end
