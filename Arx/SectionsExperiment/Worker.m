#import "Worker.h"
#import "ExactReader.h"
#import "Diagnostic.h"
#if !defined(ARX_SECTION_READER_FIXTURES)
#import <EventKit/EventKit.h>
#endif
#include <signal.h>
#include <unistd.h>

static void deadline(int number) { (void)number; _exit(124); }
static BOOL text(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 256;
}
static int output(NSDictionary *result, int status) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
    // Labels are local selection data only. Section-read output is fixed and tiny.
    if (!data || data.length > ([result[@"state"] isEqual:@"labels"] ? 16384u : 2048u)) return 70;
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
static int refused(NSString *reason) {
    return output(@{ @"state": @"unknown", @"reason": reason }, 77);
}
@implementation ARXSectionWorker
+ (int)run {
    signal(SIGALRM, deadline);
    alarm(10);
    @autoreleasepool {
        @try {
            unsigned char bytes[4097]; size_t count = 0; ssize_t n = 0;
            while (count < sizeof(bytes) && (n = read(STDIN_FILENO, bytes + count, sizeof(bytes) - count)) > 0)
                count += (size_t)n;
            if (n < 0 || count == 0 || count > 4096) return 64;
            id input = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:count] options:0 error:NULL];
            if (![input isKindOfClass:NSDictionary.class] || !text(input[@"action"])) return 64;
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
#if defined(ARX_SECTION_READER_FIXTURES)
            return output(@{ @"state": @"unknown", @"reason": @"fixture_no_provider" }, 69);
#else
            // No requestFullAccess, TCC prompt, service, new identity or entitlement.
            if ([EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder] != EKAuthorizationStatusFullAccess)
                return refused(@"existing_permission_unavailable");
            EKEventStore *store = [EKEventStore new];
            if ([action isEqual:@"labels"]) {
                NSArray<EKCalendar *> *calendars = [store calendarsForEntityType:EKEntityTypeReminder];
                if (calendars.count > 100) return refused(@"label_bound_exceeded");
                NSMutableArray *rows = [NSMutableArray new];
                for (EKCalendar *calendar in calendars) {
                    if (!text(calendar.calendarIdentifier) || !text(calendar.source.sourceIdentifier) ||
                        !text(calendar.title) || !text(calendar.source.title)) return refused(@"labels_unverified");
                    [rows addObject:@{ @"id": calendar.calendarIdentifier, @"sourceID": calendar.source.sourceIdentifier,
                        @"title": calendar.title, @"sourceTitle": calendar.source.title }];
                }
                return output(@{ @"state": @"labels", @"reason": @"local_selection_only", @"lists": rows }, 0);
            }
            EKCalendar *calendar = [store calendarWithIdentifier:input[@"listID"]];
            if (!calendar || ![calendar.title isEqual:@"Arx Test A"] ||
                ![calendar.calendarIdentifier isEqual:input[@"listID"]] ||
                ![calendar.source.sourceIdentifier isEqual:input[@"sourceID"]]) return refused(@"identity_unverified");
            if ([action isEqual:@"locate"]) {
                NSPredicate *predicate = [store predicateForRemindersInCalendars:@[calendar]];
                if (!predicate) return refused(@"selection_unavailable");
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                __block NSArray<EKReminder *> *rows = nil;
                [store fetchRemindersMatchingPredicate:predicate completion:^(NSArray<EKReminder *> *found) {
                    rows = found;
                    dispatch_semaphore_signal(done);
                }];
                if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) != 0)
                    return refused(@"selection_timeout");
                // Do not inspect or output ANY reminder's fields until the exact
                // selected scratch list has exactly one object. Never fetch other lists.
                if (rows.count != 1) return refused(@"selection_not_exactly_one");
                EKReminder *only = rows.firstObject;
                if (![only.calendar.calendarIdentifier isEqual:input[@"listID"]] ||
                    ![only.calendar.source.sourceIdentifier isEqual:input[@"sourceID"]] ||
                    !text(only.calendarItemIdentifier) || !text(only.title)) return refused(@"identity_unverified");
                return output(@{ @"state": @"item", @"reason": @"local_selection_only",
                    @"item": @{ @"id": only.calendarItemIdentifier, @"title": only.title } }, 0);
            }
            EKCalendarItem *item = [store calendarItemWithIdentifier:input[@"reminderID"]];
            if (![item isKindOfClass:EKReminder.class]) return refused(@"identity_unverified");
            NSBundle *kit = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKit.framework"];
            if (![kit load]) return refused(@"private_framework_unavailable");
            // This scope is generated by the local selection UI, not network input
            // or an Arx client grant. The worker cannot listen or start sharing.
            NSDictionary *grant = @{ @"read": @YES, @"sourceID": input[@"sourceID"],
                @"listID": input[@"listID"], @"reminderID": input[@"reminderID"] };
            NSDictionary *result = [[ARXExactSectionReader new] readRequest:input grant:grant calendar:calendar reminder:item];
            NSDictionary *diagnostic = ARXSectionDiagnostic(result);
            return output(diagnostic, [diagnostic[@"sectionMatched"] isEqual:@YES] ? 0 : 69);
#endif
        } @catch (NSException *exception) {
            (void)exception;
            return refused(@"private_api_exception");
        }
    }
}
@end
