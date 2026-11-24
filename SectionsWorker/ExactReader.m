#import "ExactReader.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include "gates.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if !defined(ARX_SECTION_READER_FIXTURES)
#import <EventKit/EventKit.h>
#endif

// Same fixed-marker discipline as Worker.m: raw complete lines, in program
// order, before the result; reached-only semantics; lost writes are ignored.
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
// Structured error detail: allowlisted domain/exception names or the fixed
// token "other". Never a raw domain, name or any free text.
static NSString *domainToken(NSString *domain) {
    return [@[@"EKErrorDomain", @"NSCocoaErrorDomain"] containsObject:domain] ? domain : @"other";
}
static NSString *exceptionToken(NSString *name) {
    return [@[@"NSInvalidArgumentException", @"NSInternalInconsistencyException",
              @"NSRangeException", @"NSGenericException"] containsObject:name] ? name : @"other";
}

static NSDictionary *unknown(NSString *reason) {
    return @{ @"state": @"unknown", @"reason": reason };
}
static NSString *text(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 256 ? value : nil;
}
static BOOL objectMethod(id object, NSString *name, NSUInteger count, BOOL errorOut) {
    Method method = class_getInstanceMethod(object_getClass(object), NSSelectorFromString(name));
    if (!method || method_getNumberOfArguments(method) != count + 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && strcmp(type, "@") == 0;
    free(type);
    for (NSUInteger i = 0; i < count; ++i) {
        type = method_copyArgumentType(method, (unsigned)i + 2);
        valid = valid && type && strcmp(type, errorOut && i + 1 == count ? "^@" : "@") == 0;
        free(type);
    }
    return valid;
}
static id get(id object, NSString *name) {
    if (!object || !objectMethod(object, name, 0, NO)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}
static BOOL exactText(id a, id b) {
    return text(a) && text(b) && [a isEqual:b];
}
static BOOL eventKitBound(id calendar, id reminder, NSDictionary *request) {
    id parent = get(reminder, @"calendar");
    return exactText(get(get(calendar, @"source"), @"sourceIdentifier"), request[@"sourceID"]) &&
        exactText(get(calendar, @"calendarIdentifier"), request[@"listID"]) &&
        exactText(get(reminder, @"calendarItemIdentifier"), request[@"reminderID"]) &&
        exactText(get(parent, @"calendarIdentifier"), request[@"listID"]) &&
        exactText(get(get(parent, @"source"), @"sourceIdentifier"), request[@"sourceID"]);
}
static NSString *identifier(id object, NSString *entity) {
    id identifier = get(object, @"remObjectID");
    id url = get(identifier, @"urlRepresentation");
    if (![url isKindOfClass:NSURL.class]) return nil;
    NSString *value = [url absoluteString];
    NSString *prefix = [NSString stringWithFormat:@"x-apple-reminderkit://%@/", entity];
    if (![value hasPrefix:prefix] || value.length > 100) return nil;
    NSString *uuid = [value substringFromIndex:prefix.length];
    return arx_uuid(uuid.UTF8String) ? value : nil;
}
static id backing(id object, NSString *className) {
#if defined(ARX_SECTION_READER_FIXTURES)
    // Synthetic-only seam; excluded from the native binary.
    (void)className;
    return get(object, @"fixturePrivateObject");
#else
    id frozen = get(object, @"backingObject");
    if (!frozen) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(frozen), "_remObject");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    // An ivar with this name but a primitive/struct encoding is NOT an object.
    if (!type || type[0] != '@') return nil;
    id value = object_getIvar(frozen, ivar);
    Class expected = NSClassFromString(className);
    return expected && [value isKindOfClass:expected] ? value : nil;
#endif
}
static id storeFor(id reminder) {
#if defined(ARX_SECTION_READER_FIXTURES)
    return get(reminder, @"fixtureStore");
#else
    Ivar ivar = class_getInstanceVariable(object_getClass(reminder), "_store");
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    id store = type && type[0] == '@' ? object_getIvar(reminder, ivar) : nil;
    // Both routes are observed upstream. Neither constructs a default store.
    if (!store) store = get(reminder, @"store");
    Class expected = NSClassFromString(@"REMStore");
    return expected && [store isKindOfClass:expected] ? store : nil;
#endif
}
// Working-reference route (apple-reminders-mcp Sections.swift): a FRESH
// REMStore from the ReminderKit framework, never a store recovered from
// EventKit internals. dlopen only when the class is not already loaded.
static id freshStore(void) {
#if defined(ARX_SECTION_READER_FIXTURES)
    return nil;
#else
    if (!NSClassFromString(@"REMStore"))
        dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_LAZY);
    Class cls = NSClassFromString(@"REMStore");
    id allocated = cls ? [cls alloc] : nil;
    if (!objectMethod(allocated, @"init", 0, NO)) return nil;
    return [allocated init];
#endif
}
// Working-reference route: construct a REMObjectID from the ALREADY VERIFIED
// reminder UUID (bound to EventKit/private identity above) instead of passing
// a private remObjectID object whose class/selector may have drifted.
// itemID is the verified x-apple-reminderkit://REMCDReminder/<uuid> string.
#if !defined(ARX_SECTION_READER_FIXTURES)
static id constructedReminderID(NSString *itemID) {
    NSString *prefix = @"x-apple-reminderkit://REMCDReminder/";
    if (![itemID hasPrefix:prefix]) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:[itemID substringFromIndex:prefix.length]];
    if (!uuid) return nil;
    Class cls = NSClassFromString(@"REMObjectID");
    SEL sel = NSSelectorFromString(@"objectIDWithUUID:entityName:");
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id, id))objc_msgSend)(cls, sel, uuid, @"REMCDReminder");
}
#endif
static id fetchID(id item, NSString *itemID) {
#if defined(ARX_SECTION_READER_FIXTURES)
    (void)itemID;
    return get(item, @"remObjectID");
#else
    (void)item;
    return constructedReminderID(itemID);
#endif
}
@interface NSObject (ARXExactViewInitializer)
- (instancetype)initWithStore:(id)store;
@end

@implementation ARXExactSectionReader
- (NSDictionary *)readRequest:(NSDictionary *)request grant:(NSDictionary *)grant
                    calendar:(id)calendar reminder:(id)reminder {
    @try {
        if (![request isKindOfClass:NSDictionary.class] || ![grant isKindOfClass:NSDictionary.class] ||
            ![grant[@"read"] isKindOfClass:NSNumber.class] || ![grant[@"read"] isEqual:@YES])
            return unknown(@"denied");
        for (NSString *key in @[@"sourceID", @"listID", @"reminderID"]) {
            if (!exactText(request[key], grant[key])) return unknown(@"denied");
        }
        marker(@"objects.bind", NO);
#if !defined(ARX_SECTION_READER_FIXTURES)
        if (![calendar isKindOfClass:EKCalendar.class] || ![reminder isKindOfClass:EKReminder.class])
            return unknown(@"identity_unverified");
#endif
        // Identity comes from these exact EventKit objects, never a constructed
        // UUID or an equality between unrelated EventKit/private namespaces.
        if (!eventKitBound(calendar, reminder, request)) return unknown(@"identity_unverified");
        id list = backing(calendar, @"REMList");
        id item = backing(reminder, @"REMReminder");
        id parent = get(item, @"list");
        NSString *listID = identifier(list, @"REMCDList");
        NSString *itemID = identifier(item, @"REMCDReminder");
        NSString *accountID = identifier(get(list, @"account"), @"REMCDAccount");
        if (!listID || !itemID || !accountID ||
            !exactText(identifier(parent, @"REMCDList"), listID) ||
            !exactText(identifier(get(item, @"account"), @"REMCDAccount"), accountID) ||
            !exactText(identifier(get(parent, @"account"), @"REMCDAccount"), accountID))
            return unknown(@"identity_unverified");
        // Re-read provenance before any membership call. This does not prove
        // transaction isolation; runtime freshness remains an experiment gate.
        if (backing(calendar, @"REMList") != list || backing(reminder, @"REMReminder") != item ||
            !eventKitBound(calendar, reminder, request))
            return unknown(@"identity_unverified");
        marker(@"objects.bind", YES);
        // The section lookup covers exact-store resolution, the guarded view
        // and the single membership call. The after marker fires when the
        // call returns; it never proves the call completed a transaction.
        marker(@"membership.call", NO);
        id store = freshStore();
        if (!store) store = storeFor(item);
        if (!store) return unknown(@"store_unavailable");
        id view = nil;
#if defined(ARX_SECTION_READER_FIXTURES)
        view = get(store, @"fixtureView");
#else
        Class cls = NSClassFromString(@"REMListSectionsDataView");
        id allocated = cls ? [cls alloc] : nil;
        if (!objectMethod(allocated, @"initWithStore:", 1, NO)) return unknown(@"view_init_unavailable");
        view = [allocated initWithStore:store];
#endif
        NSString *selector = @"fetchListSectionWithReminderID:error:";
        if (!objectMethod(view, selector, 2, YES)) return unknown(@"fetch_selector_unavailable");
        id reminderObjectID = fetchID(item, itemID);
        if (!reminderObjectID) return unknown(@"id_construction_unavailable");
        NSError *error = nil;
        id section = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
            view, NSSelectorFromString(selector), reminderObjectID, &error);
        marker(@"membership.call", YES);
        // Working-reference semantics, narrowed by the lane's reviewed
        // discipline: an explicit provider -3009 (com.apple.reminderkit) is the
        // definitive "in no section" answer, a POSITIVE state. Nil-without-error
        // stays unknown ("nil never none"): absence of a signal is not a signal.
        if (error) {
            if ([error.domain isEqual:@"com.apple.reminderkit"] && error.code == -3009)
                return @{ @"state": @"no_section", @"reason": @"membership_none_3009" };
            return @{ @"state": @"unknown", @"reason": @"membership_error",
                @"errorDomain": domainToken(error.domain), @"errorCode": @(error.code) };
        }
        if (!section) return unknown(@"membership_nil_no_error");
        if (backing(calendar, @"REMList") != list || backing(reminder, @"REMReminder") != item ||
            !exactText(identifier(get(item, @"list"), @"REMCDList"), listID) ||
            !exactText(identifier(get(item, @"account"), @"REMCDAccount"), accountID) ||
            !exactText(identifier(get(get(item, @"list"), @"account"), @"REMCDAccount"), accountID) ||
            !eventKitBound(calendar, reminder, request))
            return unknown(@"identity_unverified");
        NSString *sectionID = identifier(section, @"REMCDListSection");
        id sectionParent = get(section, @"list");
        if (!sectionID || !exactText(identifier(sectionParent, @"REMCDList"), listID) ||
            !exactText(identifier(get(sectionParent, @"account"), @"REMCDAccount"), accountID))
            return unknown(@"membership_section_identity");
        NSString *actualName = text([section valueForKey:@"displayName"]);
        if (!actualName) return unknown(@"membership_unnamed");
        NSString *expected = text(request[@"expectedSection"]);
        if (!expected)
            // Batch name-reporting mode: the identity and membership
            // verification above is unchanged; the bounded plain-text name is
            // returned without a match boolean or any expected value.
            return @{ @"state": @"section", @"reason": @"exact_object_name",
                @"actualSection": actualName };
        // Disposable-scope capture: the expected and returned
        // names ride with the match boolean. The returned name is verified to
        // the selected list/account above but may be a pre-existing section.
        return @{ @"state": @"section", @"reason": @"exact_object_candidate",
            @"sectionMatched": @([actualName isEqual:expected]),
            @"expectedSection": expected, @"actualSection": actualName };
    } @catch (NSException *exception) {
        return @{ @"state": @"unknown", @"reason": @"private_api_exception",
            @"exceptionName": exceptionToken(exception.name) };
    }
}
@end
