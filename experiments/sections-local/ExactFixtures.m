#import "Diagnostic.h"
#import "ExactReader.h"
#include <stdio.h>

// Foundation-only objects. This binary does not link EventKit, load ReminderKit,
// instantiate a store, inspect ivars, request permission or call native factories.
@interface Node : NSObject
@property(nonatomic, strong) id source;
@property(nonatomic, strong) id sourceIdentifier;
@property(nonatomic, strong) id calendarIdentifier;
@property(nonatomic, strong) id calendarItemIdentifier;
@property(nonatomic, strong) id calendar;
@property(nonatomic, strong) id fixturePrivateObject;
@property(nonatomic, strong) id fixtureStore;
@property(nonatomic, strong) id fixtureView;
@property(nonatomic, strong) id remObjectID;
@property(nonatomic, strong) id urlRepresentation;
@property(nonatomic, strong) id list;
@property(nonatomic, strong) id account;
@property(nonatomic, strong) id section;
@property(nonatomic, strong) id displayName;
@property(nonatomic) BOOL throws;
@property(nonatomic) BOOL returnsError;
@property(nonatomic) BOOL returnsNoMembership;
@property(nonatomic) NSUInteger calls;
@property(nonatomic) NSUInteger backingReads;
@property(nonatomic) BOOL staleBacking;
@property(nonatomic, strong) id mutateItem;
@property(nonatomic, strong) id replacementList;
@end
@implementation Node
@synthesize fixturePrivateObject = _fixturePrivateObject;
- (id)fixturePrivateObject {
    self.backingReads += 1;
    return self.staleBacking && self.backingReads > 1 ? nil : _fixturePrivateObject;
}
- (id)fetchListSectionWithReminderID:(id)identifier error:(NSError **)error {
    self.calls += 1;
    if (self.mutateItem) [self.mutateItem setList:self.replacementList];
    if (self.throws) [NSException raise:@"PRIVATE-SENSITIVE" format:@"hidden secret"];
    if (self.returnsError) *error = [NSError errorWithDomain:@"PRIVATE-SENSITIVE" code:1 userInfo:nil];
    if (self.returnsNoMembership) *error = [NSError errorWithDomain:@"com.apple.reminderkit" code:-3009 userInfo:nil];
    if (!identifier) return nil;
    return self.section;
}
@end
@interface WrongABI : NSObject
@end
@implementation WrongABI
- (NSInteger)fetchListSectionWithReminderID:(id)identifier error:(NSError **)error {
    (void)identifier; (void)error;
    [NSException raise:@"ShouldNotCall" format:@"bad ABI was invoked"];
    return 0;
}
@end
static Node *identity(NSString *entity, NSString *uuid) {
    Node *n = [Node new]; n.remObjectID = [Node new];
    [n.remObjectID setUrlRepresentation:[NSURL URLWithString:[NSString stringWithFormat:
        @"x-apple-reminderkit://%@/%@", entity, uuid]]];
    return n;
}
static NSUInteger assertions = 0;
static void expect(BOOL value, const char *name) {
    assertions += 1;
    if (!value) { fprintf(stderr, "FAIL: %s\n", name); exit(1); }
}
int main(void) {
    @autoreleasepool {
        NSDictionary *request = @{ @"sourceID": @"EK-account-only", @"listID": @"EK-list-not-private-UUID",
                                    @"reminderID": @"EK-item-not-private-UUID", @"expectedSection": @"Scratch section" };
        NSMutableDictionary *grant = [request mutableCopy]; grant[@"read"] = @YES;
        Node *source = [Node new]; source.sourceIdentifier = request[@"sourceID"];
        Node *calendar = [Node new]; calendar.source = source; calendar.calendarIdentifier = request[@"listID"];
        Node *reminder = [Node new]; reminder.calendar = calendar; reminder.calendarItemIdentifier = request[@"reminderID"];
        Node *account = identity(@"REMCDAccount", @"00000000-0000-0000-0000-000000000001");
        Node *list = identity(@"REMCDList", @"00000000-0000-0000-0000-000000000002"); list.account = account;
        Node *item = identity(@"REMCDReminder", @"00000000-0000-0000-0000-000000000003"); item.list = list; item.account = account;
        Node *section = identity(@"REMCDListSection", @"00000000-0000-0000-0000-000000000004"); section.list = list; section.displayName = @"Scratch section";
        Node *view = [Node new]; view.section = section;
        Node *store = [Node new]; store.fixtureView = view; item.fixtureStore = store;
        calendar.fixturePrivateObject = list; reminder.fixturePrivateObject = item;
        ARXExactSectionReader *reader = [ARXExactSectionReader new];
#define READ() [reader readRequest:request grant:grant calendar:calendar reminder:reminder]
#define UNKNOWN(label) do { NSUInteger before = view.calls; NSDictionary *r = READ(); \
    expect([r[@"state"] isEqual:@"unknown"], label); expect(view.calls == before, "no membership before binding"); } while (0)
        NSDictionary *positive = READ();
        expect([positive[@"state"] isEqual:@"section"], "exact-object binding accepts different namespaces");
        expect(view.calls == 1, "one bounded membership fetch");
        expect(positive.count == 5 && !positive[@"sourceID"] && !positive[@"accountID"] && !positive[@"sectionID"] && [positive[@"sectionMatched"] isEqual:@YES] && [positive[@"expectedSection"] isEqual:@"Scratch section"] && [positive[@"actualSection"] isEqual:@"Scratch section"], "fixed sanitized fields plus approved names");
        for (NSString *key in @[@"sourceID", @"listID", @"reminderID", @"read"]) {
            id original = grant[key];
            for (id bad in @[[NSNull null], @NO, @"wrong", @42, @[]]) {
                grant[key] = bad; UNKNOWN("denied grant");
            }
            [grant removeObjectForKey:key]; UNKNOWN("missing grant"); grant[key] = original;
        }
        for (NSString *key in @[@"sourceIdentifier", @"calendarIdentifier", @"calendarItemIdentifier"]) {
            Node *target = [key isEqual:@"sourceIdentifier"] ? source : ([key isEqual:@"calendarIdentifier"] ? calendar : reminder);
            id original = [target valueForKey:key];
            for (id bad in @[[NSNull null], @"wrong", @42, @[]]) {
                [target setValue:bad forKey:key]; UNKNOWN("wrong EventKit identity");
            }
            [target setValue:original forKey:key];
        }
        Node *otherSource = [Node new]; otherSource.sourceIdentifier = @"other-account";
        Node *otherCalendar = [Node new]; otherCalendar.source = otherSource; otherCalendar.calendarIdentifier = request[@"listID"];
        reminder.calendar = otherCalendar; UNKNOWN("same list id wrong EventKit account"); reminder.calendar = calendar;
        calendar.fixturePrivateObject = nil; UNKNOWN("missing exact list backing"); calendar.fixturePrivateObject = list;
        reminder.fixturePrivateObject = nil; UNKNOWN("missing exact reminder backing"); reminder.fixturePrivateObject = item;
        Node *otherList = identity(@"REMCDList", @"00000000-0000-0000-0000-000000000005"); otherList.account = account;
        item.list = otherList; UNKNOWN("wrong private parent"); item.list = list;
        Node *sameListWrongAccount = identity(@"REMCDList", @"00000000-0000-0000-0000-000000000002");
        sameListWrongAccount.account = identity(@"REMCDAccount", @"00000000-0000-0000-0000-000000000006");
        item.list = sameListWrongAccount; UNKNOWN("same list id wrong private account"); item.list = list;
        item.account = sameListWrongAccount.account; UNKNOWN("reminder account mismatch"); item.account = account;
        id saved = list.account; list.account = nil; UNKNOWN("absent account binding"); list.account = saved;
        saved = item.remObjectID;
        item.remObjectID = identity(@"REMCDList", @"00000000-0000-0000-0000-000000000003").remObjectID;
        UNKNOWN("wrong private entity"); item.remObjectID = saved;
        calendar.backingReads = 0; calendar.staleBacking = YES;
        UNKNOWN("stale exact backing before membership"); calendar.staleBacking = NO;
        view.mutateItem = item; view.replacementList = otherList;
        expect([READ()[@"state"] isEqual:@"unknown"], "parent changes during membership read");
        view.mutateItem = nil; item.list = list;
        saved = item.fixtureStore; item.fixtureStore = nil; UNKNOWN("no store fallback"); item.fixtureStore = saved;
        store.fixtureView = [NSObject new]; UNKNOWN("missing membership selector");
        store.fixtureView = [WrongABI new]; UNKNOWN("wrong membership ABI"); store.fixtureView = view;
        section.list = otherList;
        NSDictionary *outsideList = READ();
        expect([outsideList[@"state"] isEqual:@"unknown"] && [outsideList[@"reason"] isEqual:@"membership_section_identity"],
            "section outside exact list; site named");
        section.list = list; section.displayName = @"Scratch section";
        section.list = sameListWrongAccount;
        NSDictionary *wrongAccount = READ();
        expect([wrongAccount[@"state"] isEqual:@"unknown"] && [wrongAccount[@"reason"] isEqual:@"membership_section_identity"],
            "section wrong account; site named");
        section.list = list; section.displayName = @"Scratch section";
        section.displayName = @"wrong section";
        expect([READ()[@"sectionMatched"] isEqual:@NO], "section mismatch is not success");
        section.displayName = nil;
        NSDictionary *unnamed = READ();
        expect([unnamed[@"state"] isEqual:@"unknown"] && [unnamed[@"reason"] isEqual:@"membership_unnamed"],
            "unnamed section never positive; site named");
        section.displayName = @"Scratch section";
        view.section = nil;
        NSDictionary *nilResult = READ();
        expect([nilResult[@"state"] isEqual:@"unknown"] && [nilResult[@"reason"] isEqual:@"membership_nil_no_error"],
            "nil never none; site named");
        view.section = section;
        view.returnsError = YES; NSDictionary *errored = READ();
        expect([errored[@"state"] isEqual:@"unknown"] && [errored[@"reason"] isEqual:@"membership_error"] && [errored[@"errorDomain"] isEqual:@"other"] && [errored[@"errorCode"] isEqual:@1], "error never positive; site named, structured detail only"); view.returnsError = NO;
        view.returnsNoMembership = YES; NSDictionary *noMembership = READ();
        expect([noMembership[@"state"] isEqual:@"no_section"] && [noMembership[@"reason"] isEqual:@"membership_none_3009"],
            "provider -3009 is a confirmed no-section; site named");
        expect(noMembership.count == 2, "no-section carries state and reason only"); view.returnsNoMembership = NO;
        view.throws = YES; NSDictionary *failure = READ();
        expect([failure[@"reason"] isEqual:@"private_api_exception"] && failure.count == 3 && [failure[@"exceptionName"] isEqual:@"other"], "exception sanitized");
        expect(![[failure description] containsString:@"PRIVATE-SENSITIVE"], "no exception disclosure"); view.throws = NO;
        expect([READ()[@"state"] isEqual:@"section"], "fresh read recovers after exception");
        for (NSString *reason in @[@"denied", @"identity_unverified", @"membership_unverified", @"membership_nil_no_error",
                                   @"membership_error", @"membership_section_identity",
                                   @"membership_unnamed", @"private_api_exception", @"store_unavailable",
                                   @"view_init_unavailable", @"fetch_selector_unavailable", @"id_construction_unavailable"]) {
            NSDictionary *r = ARXSectionDiagnostic(@{@"state": @"unknown", @"reason": reason, @"private": @"PRIVATE-SENSITIVE"});
            expect([r[@"reason"] isEqual:reason] && r.count == 3, "fixed refusal preserved");
            expect(![[r description] containsString:@"PRIVATE-SENSITIVE"], "diagnostic excludes private fields");
        }
        expect([ARXSectionDiagnostic(@{@"state": @"unknown", @"reason": @"unavailable"})[@"reason"] isEqual:@"membership_api_unavailable"], "API absence distinct");
        NSDictionary *noneClean = ARXSectionDiagnostic(@{@"state": @"no_section", @"reason": @"membership_none_3009", @"private": @"PRIVATE-SENSITIVE"});
        expect([noneClean[@"state"] isEqual:@"no_section"] && [noneClean[@"reason"] isEqual:@"membership_none_3009"] && noneClean.count == 3,
            "no-section diagnostic preserved with fixed fields");
        expect(![[noneClean description] containsString:@"PRIVATE-SENSITIVE"], "no-section excludes private fields");
        expect([ARXSectionDiagnostic(@{@"state": @"no_section", @"reason": @"PRIVATE-SENSITIVE"})[@"reason"] isEqual:@"worker_unavailable"],
            "untrusted no-section reason refused");
        expect([ARXSectionDiagnostic(@{@"state": @"section", @"sectionMatched": @NO})[@"reason"] isEqual:@"section_name_mismatch"], "mismatch distinct");
        expect([ARXSectionDiagnostic(positive)[@"sectionMatched"] isEqual:@YES], "positive preserved");
        expect(ARXSectionDiagnostic(positive).count == 5, "approved names preserved");
        for (NSString *sub in @[@"identity_list_unverified", @"identity_source_unverified", @"identity_title_unverified"]) {
            expect([ARXSectionDiagnostic(@{@"state": @"unknown", @"reason": sub})[@"reason"] isEqual:sub], "identity sub-reason preserved");
        }
        NSDictionary *withDomain = ARXSectionDiagnostic(@{@"state": @"unknown", @"reason": @"membership_error",
            @"errorDomain": @"EKErrorDomain", @"errorCode": @42});
        expect([withDomain[@"errorDomain"] isEqual:@"EKErrorDomain"] && [withDomain[@"errorCode"] isEqual:@42], "allowlisted domain and code preserved");
        expect(ARXSectionDiagnostic(@{@"state": @"unknown", @"reason": @"membership_error",
            @"errorDomain": @"PRIVATE-SENSITIVE", @"errorCode": @1})[@"errorDomain"] == nil, "unrecognized domain dropped");
        expect(ARXSectionDiagnostic(@{@"state": @"unknown", @"reason": @"private_api_exception",
            @"exceptionName": @"PRIVATE-SENSITIVE"})[@"exceptionName"] == nil, "unrecognized exception dropped");
        expect(ARXSectionDiagnostic(@{@"state": @"section", @"sectionMatched": @YES,
            @"expectedSection": @"EXP"})[@"actualSection"] == nil, "partial names dropped");
        NSMutableString *longName = [NSMutableString stringWithCapacity:300];
        for (int i = 0; i < 257; i++) [longName appendString:@"x"];
        expect(ARXSectionDiagnostic(@{@"state": @"section", @"sectionMatched": @YES,
            @"expectedSection": longName, @"actualSection": @"EXP"})[@"expectedSection"] == nil, "oversized names dropped");
        for (id bad in @[@{}, @{@"state": @"unknown", @"reason": @"PRIVATE-SENSITIVE"}, @{@"state": @"section", @"sectionMatched": @"PRIVATE-SENSITIVE"}]) {
            NSDictionary *r = ARXSectionDiagnostic(bad);
            expect([r[@"reason"] isEqual:@"worker_unavailable"], "malformed diagnostic refused");
            expect(![[r description] containsString:@"PRIVATE-SENSITIVE"], "untrusted reason not echoed");
        }
        printf("Exact binding synthetic assertions: %lu PASS\n", (unsigned long)assertions);
    }
}
