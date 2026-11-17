#import "SectionReader.h"
#include <stdio.h>
#include <stdlib.h>

static NSString *const L = @"11111111-1111-4111-8111-111111111111";
static NSString *const R = @"22222222-2222-4222-8222-222222222222";
static NSString *const S = @"33333333-3333-4333-8333-333333333333";
static NSString *const OTHER = @"44444444-4444-4444-8444-444444444444";
static unsigned checks;
static void check(BOOL passed, const char *label) {
    ++checks;
    if (!passed) { fprintf(stderr, "FAIL: %s\n", label); exit(1); }
}
static NSDictionary *request(void) {
    return @{ @"listID": L, @"reminderID": R, @"expectedListName": @"Synthetic list", @"expectedReminderTitle": @"Synthetic reminder" };
}
static NSDictionary *grant(void) { return @{ @"read": @YES, @"listIDs": @[L] }; }

@interface FixtureProvider : NSObject <ARXSectionReadProvider, ARXSectionReadSession>
@property(nonatomic) unsigned sessions;
@property(nonatomic) unsigned listReads;
@property(nonatomic) unsigned reminderReads;
@property(nonatomic) unsigned membershipReads;
@property(nonatomic) BOOL throwsOnSession;
@property(nonatomic) BOOL throwsOnMembership;
@property(nonatomic) BOOL unavailable;
@property(nonatomic, strong) NSDictionary *list;
@property(nonatomic, strong) NSDictionary *reminder;
@property(nonatomic, strong) NSDictionary *membership;
@end
@implementation FixtureProvider
- (id<ARXSectionReadSession>)newReadSession {
    ++self.sessions;
    if (self.throwsOnSession) [NSException raise:@"FixtureException" format:@"PRIVATE_MARKER_MUST_NOT_ESCAPE"];
    return self.unavailable ? nil : self;
}
- (NSDictionary *)listWithUUID:(NSString *)uuid { check([uuid isEqual:L], "list scope"); ++self.listReads; return self.list; }
- (NSDictionary *)reminderWithUUID:(NSString *)uuid { check([uuid isEqual:R], "reminder scope"); ++self.reminderReads; return self.reminder; }
- (NSDictionary *)membershipForReminderUUID:(NSString *)uuid {
    check([uuid isEqual:R], "membership scope"); ++self.membershipReads;
    if (self.throwsOnMembership) [NSException raise:@"FixtureException" format:@"PRIVATE_MARKER_MUST_NOT_ESCAPE"];
    return self.membership;
}
@end
static FixtureProvider *provider(void) {
    FixtureProvider *p = [FixtureProvider new];
    p.list = @{ @"id": L, @"name": @"Synthetic list" };
    p.reminder = @{ @"id": R, @"title": @"Synthetic reminder", @"listID": L };
    p.membership = @{ @"state": @"section", @"sectionID": S, @"listID": L };
    return p;
}
static NSDictionary *run(FixtureProvider *p, NSDictionary *q, NSDictionary *g) {
    return [[[ARXSectionReader alloc] initWithProvider:p] readRequest:q grant:g];
}
static void state(NSDictionary *result, NSString *expected) {
    check([result[@"state"] isEqual:expected], "result state");
    check(![[result description] containsString:@"PRIVATE_MARKER"], "no exception/private data in result");
}

/// These synthetic object classes exercise the ACTUAL guarded ObjC call path,
/// without loading ReminderKit, instantiating REMStore or requesting permission.
@interface FixtureID : NSObject
@property(nonatomic, strong) NSURL *url;
+ (id)objectIDWithURL:(NSURL *)url;
- (id)urlRepresentation;
@end
@implementation FixtureID
+ (id)objectIDWithURL:(NSURL *)url { FixtureID *i = [FixtureID new]; i.url = url; return i; }
- (id)urlRepresentation { return self.url; }
@end
@interface FixtureObject : NSObject
@property(nonatomic, strong) id objectID;
@property(nonatomic, strong) id list;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *titleAsString;
@end
@implementation FixtureObject
@end
@interface FixtureStore : NSObject
@property(nonatomic, strong) FixtureObject *list;
@property(nonatomic, strong) FixtureObject *reminder;
@property(nonatomic) BOOL error;
- (id)fetchListWithObjectID:(id)identifier error:(NSError **)error;
- (id)fetchReminderWithObjectID:(id)identifier error:(NSError **)error;
@end
@implementation FixtureStore
- (id)fetchListWithObjectID:(id)identifier error:(NSError **)error {
    check([[[identifier urlRepresentation] absoluteString] hasSuffix:L], "exact private list lookup");
    if (self.error) *error = [NSError errorWithDomain:@"Fixture" code:1 userInfo:nil];
    return self.list;
}
- (id)fetchReminderWithObjectID:(id)identifier error:(NSError **)error {
    check([[[identifier urlRepresentation] absoluteString] hasSuffix:R], "exact private reminder lookup");
    return self.reminder;
}
@end
@interface FixtureView : NSObject
@property(nonatomic, strong) FixtureObject *section;
@property(nonatomic) BOOL error;
@property(nonatomic) BOOL throwException;
- (id)fetchListSectionWithReminderID:(id)identifier error:(NSError **)error;
@end
@implementation FixtureView
- (id)fetchListSectionWithReminderID:(id)identifier error:(NSError **)error {
    check([[[identifier urlRepresentation] absoluteString] hasSuffix:R], "exact membership lookup");
    if (self.throwException) [NSException raise:@"FixtureException" format:@"PRIVATE_MARKER_MUST_NOT_ESCAPE"];
    if (self.error) *error = [NSError errorWithDomain:@"Fixture" code:2 userInfo:nil];
    return self.section;
}
@end
@interface WrongABIView : NSObject
- (NSInteger)fetchListSectionWithReminderID:(id)identifier error:(NSError **)error;
@end
@implementation WrongABIView
- (NSInteger)fetchListSectionWithReminderID:(id)identifier error:(NSError **)error {
    (void)identifier; (void)error;
    check(NO, "wrong ABI must never be invoked"); return 42;
}
@end
extern id<ARXSectionReadSession> ARXFixturePrivateSession(id, id, Class);
@interface SessionProvider : NSObject <ARXSectionReadProvider>
@property(nonatomic, strong) id store;
@property(nonatomic, strong) id view;
@end
@implementation SessionProvider
- (id<ARXSectionReadSession>)newReadSession { return ARXFixturePrivateSession(self.store, self.view, FixtureID.class); }
@end
static FixtureObject *object(NSString *uuid, NSString *entity) {
    FixtureObject *o = [FixtureObject new];
    o.objectID = [FixtureID objectIDWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"x-apple-reminderkit://%@/%@", entity, uuid]]];
    return o;
}
int main(void) {
    @autoreleasepool {
        FixtureProvider *p = provider();
        state(run(p, request(), grant()), @"section");
        check(p.sessions == 1 && p.membershipReads == 1, "one fresh session per read");
        (void)run(p, request(), grant()); check(p.sessions == 2, "second read obtains another session");
        NSArray *badIDs = @[@"", @"1", @"../bad", @"11111111-1111-4111-8111-111111111111?x=1",
          @"x-apple-reminderkit://REMCDReminder/11111111-1111-4111-8111-111111111111",
          @"x-apple-reminderkit://REMCDList/11111111-1111-4111-8111-111111111111/extra", @42, NSNull.null];
        for (id bad in badIDs) {
            p = provider(); NSMutableDictionary *q = [request() mutableCopy]; q[@"listID"] = bad;
            state(run(p, q, grant()), @"unknown"); check(p.sessions == 0, "deny before store/session");
        }
        p = provider(); state(run(p, request(), @{ @"read": @NO, @"listIDs": @[L] }), @"unknown"); check(p.sessions == 0, "no read right no session");
        p = provider(); state(run(p, request(), @{ @"read": @YES, @"listIDs": @[OTHER] }), @"unknown"); check(p.sessions == 0, "unselected list no session");
        for (NSString *field in @[@"id", @"name"]) {
            p = provider(); NSMutableDictionary *l = [p.list mutableCopy]; l[field] = OTHER; p.list = l;
            state(run(p, request(), grant()), @"unknown"); check(p.reminderReads == 0, "bad list stops reminder fetch");
        }
        for (NSString *field in @[@"id", @"title", @"listID"]) {
            p = provider(); NSMutableDictionary *r = [p.reminder mutableCopy]; r[field] = OTHER; p.reminder = r;
            state(run(p, request(), grant()), @"unknown"); check(p.membershipReads == 0, "bad reminder stops membership lookup");
        }
        p = provider(); p.membership = nil; state(run(p, request(), grant()), @"unknown");
        p.membership = @{ @"state": @"none" }; state(run(p, request(), grant()), @"none");
        p.membership = @{ @"state": @"section", @"sectionID": S, @"listID": OTHER }; state(run(p, request(), grant()), @"unknown");
        p.membership = @{ @"state": @"section", @"sectionID": L, @"listID": L }; state(run(p, request(), grant()), @"section"); // Equal UUIDs alone do not imply same entity.
        p = provider(); p.throwsOnSession = YES; state(run(p, request(), grant()), @"unknown");
        p = provider(); p.throwsOnMembership = YES; state(run(p, request(), grant()), @"unknown");
        p = provider(); p.unavailable = YES; state(run(p, request(), grant()), @"unknown");
        NSMutableDictionary *q = [request() mutableCopy]; q[@"listID"] = [@"x-apple-reminderkit://REMCDList/" stringByAppendingString:L];
        p = provider(); state(run(p, q, @{ @"read": @YES, @"listIDs": @[q[@"listID"]] }), @"section");
        state(run(p, q, grant()), @"unknown"); // exact grant identifier, not normalized alias.

        FixtureStore *store = [FixtureStore new];
        store.list = object(L, @"REMCDList"); store.list.name = @"Synthetic list";
        store.reminder = object(R, @"REMCDReminder"); store.reminder.titleAsString = @"Synthetic reminder"; store.reminder.list = store.list;
        FixtureView *view = [FixtureView new]; view.section = object(S, @"REMCDListSection"); view.section.list = store.list;
        SessionProvider *sp = [SessionProvider new]; sp.store = store; sp.view = view;
        ARXSectionReader *reader = [[ARXSectionReader alloc] initWithProvider:sp];
        state([reader readRequest:request() grant:grant()], @"section");
        view.section = nil; state([reader readRequest:request() grant:grant()], @"unknown"); // nil without error is not none.
        view.error = YES; state([reader readRequest:request() grant:grant()], @"unknown");
        view.error = NO; view.throwException = YES; state([reader readRequest:request() grant:grant()], @"unknown");
        sp.view = [WrongABIView new]; state([reader readRequest:request() grant:grant()], @"unknown");
        sp.view = [NSObject new]; state([reader readRequest:request() grant:grant()], @"unknown");
        sp.view = view; store.error = YES; state([reader readRequest:request() grant:grant()], @"unknown");
        puts("PASS synthetic reader fixture and guarded-call cases; no native store opened");
        printf("Assertions: %u\n", checks);
    }
    return 0;
}
