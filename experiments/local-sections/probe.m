// Test-only: default-store access on a fresh hosted VM, never owner devices.
#import <AppKit/AppKit.h>
#import <EventKit/EventKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include "gates.h"

@interface NSObject (SectionExperiment)
+ (id)objectIDWithURL:(NSURL *)url;
- (id)initWithStore:(id)store;
- (id)fetchListWithObjectID:(id)objectID error:(NSError **)error;
- (id)fetchListSectionWithObjectID:(id)objectID error:(NSError **)error;
- (id)updateList:(id)list;
- (id)updateListSection:(id)section;
- (id)sectionsContextChangeItem;
- (id)addListSectionWithDisplayName:(NSString *)name toListSectionContextChangeItem:(id)context;
- (id)remObjectID;
- (id)name;
- (id)displayName;
- (id)urlRepresentation;
- (void)setUnsavedSectionIDsOrdering:(NSArray *)ordering;
- (void)setShouldUpdateSectionsOrdering:(BOOL)value;
- (void)removeFromList;
- (BOOL)saveSynchronouslyWithError:(NSError **)error;
@end

static NSMutableDictionary *evidence;
static void report(NSString *outcome) {
    evidence[@"outcome"] = outcome;
    NSData *data = [NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted error:NULL];
    if (!data || data.length > 8192) exit(2);
    fwrite(data.bytes, 1, data.length, stdout);
    puts("");
}
static BOOL localOnly(EKEventStore *store, EKSource **selected) {
    NSArray<EKSource *> *sources = store.sources;
    evidence[@"sourceCount"] = @(sources.count);
    if (sources.count == 0 || sources.count > 32) return NO;
    long types[32];
    NSUInteger localCount = 0;
    for (NSUInteger i = 0; i < sources.count; ++i) {
        types[i] = sources[i].sourceType == EKSourceTypeLocal ? 0 : 1;
        if (types[i] == 0) { *selected = sources[i]; ++localCount; }
    }
    evidence[@"localSourceCount"] = @(localCount);
    evidence[@"nonlocalOrUnknownSourceCount"] = @(sources.count - localCount);
    return local_sources_only(types, sources.count);
}
static BOOL has(id object, NSString *selector) {
    return object && [object respondsToSelector:NSSelectorFromString(selector)];
}
static BOOL exactList(EKCalendar *list, NSString *identifier, NSString *marker) {
    return list && [list.calendarIdentifier isEqualToString:identifier]
        && [list.title isEqualToString:marker] && list.source.sourceType == EKSourceTypeLocal;
}
static BOOL cleanupList(EKEventStore *store, NSString *identifier, NSString *marker, BOOL uncertain) {
    EKSource *source = nil;
    BOOL local = localOnly(store, &source);
    EKCalendar *list = [store calendarWithIdentifier:identifier];
    if (!may_clean_list(YES, [list.calendarIdentifier isEqualToString:identifier],
                        [list.title isEqualToString:marker], local, uncertain)) return NO;
    NSError *error = nil;
    if (![store removeCalendar:list commit:YES error:&error]) return NO;
    [store reset];
    return [store calendarWithIdentifier:identifier] == nil;
}
int main(void) {
    @autoreleasepool {
        evidence = [@{@"storeOpened": @NO, @"listSaved": @NO, @"sectionSaved": @NO,
                      @"sectionFreshRead": @NO, @"appleUIVerified": @NO,
                      @"cleanupVerified": @NO, @"writeUncertain": @NO} mutableCopy];
        // Require the documented hosted route, with no owner credentials supplied.
        NSDictionary *env = NSProcessInfo.processInfo.environment;
        if (![env[@"GITHUB_ACTIONS"] isEqualToString:@"true"] ||
            ![env[@"RUNNER_OS"] isEqualToString:@"macOS"] ||
            ![env[@"ARX_SECTIONS_EXPERIMENT"] isEqualToString:@"approved-once"]) {
            report(@"not_hosted_experiment"); return 1;
        }
        @try {
            NSBundle *kit = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKit.framework"];
            if (![kit load]) { report(@"framework_unavailable"); return 0; }
            Class remStore = NSClassFromString(@"REMStore");
            Class remID = NSClassFromString(@"REMObjectID");
            Class saveClass = NSClassFromString(@"REMSaveRequest");
            evidence[@"metadataAvailable"] = @(remStore && remID && saveClass);
            if (!remStore || !remID || !saveClass) { report(@"metadata_only_unavailable"); return 0; }
            // The public source-type enum establishes local-only account scope.
            // No calendar/reminder contents are enumerated, no database opened.
            EKEventStore *store = [EKEventStore new];
            evidence[@"storeOpened"] = @YES;
            dispatch_semaphore_t permission = dispatch_semaphore_create(0);
            __block BOOL granted = NO;
            [store requestFullAccessToRemindersWithCompletion:^(BOOL allowed, NSError *error) {
                (void)error; granted = allowed; dispatch_semaphore_signal(permission);
            }];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
            BOOL answered = NO;
            while (!(answered = dispatch_semaphore_wait(permission, DISPATCH_TIME_NOW) == 0) && deadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            if (!answered || !granted) { report(@"normal_permission_unavailable"); return 0; }
            EKSource *source = nil;
            if (!localOnly(store, &source)) { report(@"no_proven_local_only_source"); return 0; }
            // Launching Apple's UI is allowed only after the local-source gate.
            NSURL *app = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.apple.reminders"];
            evidence[@"appleUIAvailable"] = @(app != nil);
            if (app) [NSWorkspace.sharedWorkspace openApplicationAtURL:app configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
            NSString *marker = [@"ArxSectionExperiment-" stringByAppendingString:NSUUID.UUID.UUIDString];
            EKCalendar *calendar = [EKCalendar calendarForEntityType:EKEntityTypeReminder eventStore:store];
            calendar.title = marker;
            calendar.source = source;
            NSError *error = nil;
            if (![store saveCalendar:calendar commit:YES error:&error]) {
                evidence[@"writeUncertain"] = @YES;
                report(@"list_save_uncertain_no_retry"); return 0;
            }
            evidence[@"listSaved"] = @YES;
            NSString *identifier = calendar.calendarIdentifier;
            if (!identifier.length || !exactList(calendar, identifier, marker) || !calendar.allowsContentModifications) {
                report(@"list_identity_unverified_cleanup_unresolved"); return 0;
            }
            // No invented URL or UUID conversion: use a full returned private URL only.
            NSURL *url = [NSURL URLWithString:identifier];
            if (![url.scheme isEqualToString:@"x-apple-reminderkit"] ||
                ![url.host isEqualToString:@"REMCDList"] || !has(remID, @"objectIDWithURL:")) {
                evidence[@"cleanupVerified"] = @(cleanupList(store, identifier, marker, NO));
                report(@"eventkit_private_id_mapping_unproved"); return 0;
            }
            id privateStore = [remStore new];
            if (!has(privateStore, @"fetchListWithObjectID:error:")) {
                evidence[@"cleanupVerified"] = @(cleanupList(store, identifier, marker, NO));
                report(@"private_list_fetch_unavailable"); return 0;
            }
            id objectID = [remID objectIDWithURL:url];
            id privateList = objectID ? [privateStore fetchListWithObjectID:objectID error:&error] : nil;
            id save = has([saveClass alloc], @"initWithStore:") ? [[saveClass alloc] initWithStore:privateStore] : nil;
            BOOL markerMatches = has(privateList, @"name") && [[privateList name] isEqual:marker] &&
                has(privateList, @"remObjectID") && has([privateList remObjectID], @"urlRepresentation") &&
                [[[privateList remObjectID] urlRepresentation] isEqual:url];
            id change = has(save, @"updateList:") && markerMatches ? [save updateList:privateList] : nil;
            id context = has(change, @"sectionsContextChangeItem") ? [change sectionsContextChangeItem] : nil;
            BOOL methods = has(save, @"addListSectionWithDisplayName:toListSectionContextChangeItem:") &&
                has(save, @"saveSynchronouslyWithError:") && has(context, @"setUnsavedSectionIDsOrdering:") &&
                has(context, @"setShouldUpdateSectionsOrdering:") && has(privateStore, @"fetchListSectionWithObjectID:error:");
            if (!may_create_section(localOnly(store, &source), YES, objectID != nil, markerMatches, methods, NO)) {
                evidence[@"cleanupVerified"] = @(cleanupList(store, identifier, marker, NO));
                report(@"actual_section_methods_or_identity_unproved"); return 0;
            }
            id section = [save addListSectionWithDisplayName:marker toListSectionContextChangeItem:context];
            id sectionID = has(section, @"remObjectID") ? [section remObjectID] : nil;
            if (!sectionID) {
                evidence[@"cleanupVerified"] = @(cleanupList(store, identifier, marker, NO));
                report(@"section_preparation_refused"); return 0;
            }
            [context setUnsavedSectionIDsOrdering:@[sectionID]];
            [context setShouldUpdateSectionsOrdering:YES];
            if (![save saveSynchronouslyWithError:&error]) {
                evidence[@"writeUncertain"] = @YES;
                report(@"section_save_uncertain_cleanup_unresolved"); return 0;
            }
            evidence[@"sectionSaved"] = @YES;
            save = nil; privateStore = nil;
            privateStore = [remStore new];
            id fresh = [privateStore fetchListSectionWithObjectID:sectionID error:&error];
            BOOL verified = has(fresh, @"displayName") && [[fresh displayName] isEqual:marker];
            evidence[@"sectionFreshRead"] = @(verified);
            // No source-backed exact-object UI route exists for the private section ID.
            // Report unavailable rather than capturing unrelated sidebar content.
            evidence[@"appleUIResult"] = @"not_verified_exact_object_ui_route_unproved";
            id removal = verified ? [[saveClass alloc] initWithStore:privateStore] : nil;
            id removeChange = has(removal, @"updateListSection:") ? [removal updateListSection:fresh] : nil;
            if (!has(removeChange, @"removeFromList") || !localOnly(store, &source)) {
                report(@"section_cleanup_identity_or_method_unproved"); return 0;
            }
            [removeChange removeFromList];
            if (![removal saveSynchronouslyWithError:&error]) {
                evidence[@"writeUncertain"] = @YES;
                report(@"section_cleanup_uncertain_no_retry"); return 0;
            }
            privateStore = [remStore new];
            error = nil;
            if ([privateStore fetchListSectionWithObjectID:sectionID error:&error] || error) {
                report(@"section_cleanup_unverified_no_retry"); return 0;
            }
            evidence[@"cleanupVerified"] = @(cleanupList(store, identifier, marker, NO));
            report(@"local_section_saved_fresh_read_ui_unverified");
        } @catch (NSException *exception) {
            (void)exception;
            // Do not expose framework exceptions or blindly repeat a write/cleanup.
            report(@"runtime_exception_cleanup_unresolved"); return 1;
        }
    }
    return 0;
}
