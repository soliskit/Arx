#import "ExactReader.h"
#if !defined(ARX_SECTION_READER_FIXTURES)
#import <EventKit/EventKit.h>
#endif
#include <signal.h>
#include <unistd.h>

// Compile/sign only in preparation. Never run this executable in hosted checks.
// Process-wide deadline includes stdin, EventKit resolution and private calls.
// Timeout/crash/nonzero exit must be reported as unknown, never "none".
static void timeoutExit(int signalNumber) {
    (void)signalNumber;
    _exit(124);
}
int main(void) {
    signal(SIGALRM, timeoutExit);
    alarm(10);
    @autoreleasepool {
        @try {
            unsigned char bytes[4097];
            size_t count = 0;
            ssize_t n = 0;
            while (count < sizeof(bytes) && (n = read(STDIN_FILENO, bytes + count, sizeof(bytes) - count)) > 0)
                count += (size_t)n;
            if (n < 0 || count == 0 || count > 4096) return 64;
            id input = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:count]
                                                       options:0 error:NULL];
            if (![input isKindOfClass:NSDictionary.class] ||
                ![input[@"request"] isKindOfClass:NSDictionary.class] ||
                ![input[@"grant"] isKindOfClass:NSDictionary.class]) return 64;
            NSDictionary *request = input[@"request"];
            NSDictionary *grant = input[@"grant"];
            // Reject all nonexact scope before constructing even an EventKit store.
            if (![grant[@"read"] isKindOfClass:NSNumber.class] || ![grant[@"read"] isEqual:@YES]) return 77;
            for (NSString *key in @[@"sourceID", @"listID", @"reminderID"]) {
                id value = request[key];
                if (![value isKindOfClass:NSString.class] || [value length] == 0 ||
                    [value length] > 256 || ![value isEqual:grant[key]]) return 77;
            }
#if defined(ARX_SECTION_READER_FIXTURES)
            // Exercise only the transport bounds. No native provider is linked.
            NSDictionary *result = @{ @"state": @"unknown", @"reason": @"fixture_no_provider" };
#else
            // No permission prompt and no requestFullAccess call.
            if ([EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder] != EKAuthorizationStatusFullAccess)
                return 77;
            EKEventStore *store = [EKEventStore new];
            EKCalendar *calendar = [store calendarWithIdentifier:request[@"listID"]];
            if (!calendar || ![calendar.calendarIdentifier isEqual:request[@"listID"]] ||
                ![calendar.source.sourceIdentifier isEqual:request[@"sourceID"]]) return 77;
            EKCalendarItem *item = [store calendarItemWithIdentifier:request[@"reminderID"]];
            NSDictionary *result = [[[ARXExactSectionReader alloc] init]
                readRequest:request grant:grant calendar:calendar reminder:item];
#endif
            NSData *output = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
            if (!output || output.length > 2048) return 70;
            const unsigned char *p = output.bytes;
            size_t remaining = output.length;
            while (remaining) {
                ssize_t written = write(STDOUT_FILENO, p, remaining);
                if (written <= 0) return 74;
                p += written;
                remaining -= (size_t)written;
            }
            return [result[@"state"] isEqual:@"section"] ? 0 : 69;
        } @catch (NSException *exception) {
            (void)exception;
            return 70;
        }
    }
}
