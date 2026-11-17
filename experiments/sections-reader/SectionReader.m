#import "SectionReader.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include "gates.h"
#include <stdlib.h>

/// Declaring the init-family method preserves ARC receiver-consumed/+1 rules.
/// Runtime signature checks still gate the private initializer before invocation.
@interface NSObject (ARXSectionStoreInitializer)
- (instancetype)initWithStore:(id)store;
@end

static NSDictionary *unknown(NSString *reason) {
    return @{ @"state": @"unknown", @"reason": reason };
}

static NSString *string(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

/// No suffix stripping, name lookup, percent decoding, query or fragment aliases.
static NSString *uuidFor(id raw, NSString *entity) {
    NSString *value = string(raw);
    if (!value || value.length > 96) return nil;
    NSString *prefix = [NSString stringWithFormat:@"x-apple-reminderkit://%@/", entity];
    NSString *candidate = [value hasPrefix:prefix] ? [value substringFromIndex:prefix.length] : value;
    if (!arx_uuid(candidate.UTF8String)) return nil;
    return candidate.uppercaseString;
}

static NSDictionary *dictionary(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

@implementation ARXSectionReader {
    id<ARXSectionReadProvider> _provider;
}
- (instancetype)initWithProvider:(id<ARXSectionReadProvider>)provider {
    if ((self = [super init])) _provider = provider;
    return self;
}
- (NSDictionary *)readRequest:(NSDictionary *)request grant:(NSDictionary *)grant {
    @try {
        request = dictionary(request);
        grant = dictionary(grant);
        if (!request || !grant) return unknown(@"invalid_request");
        NSString *list = uuidFor(request[@"listID"], @"REMCDList");
        NSString *reminder = uuidFor(request[@"reminderID"], @"REMCDReminder");
        NSString *name = string(request[@"expectedListName"]);
        NSString *title = string(request[@"expectedReminderTitle"]);
        NSArray *granted = [grant[@"listIDs"] isKindOfClass:NSArray.class] ? grant[@"listIDs"] : nil;
        // Only exact caller-provided grant identifiers, never normalized aliases.
        BOOL read = [grant[@"read"] isKindOfClass:NSNumber.class] && [grant[@"read"] isEqual:@YES];
        BOOL inGrant = string(request[@"listID"]) && [granted containsObject:request[@"listID"]];
        if (!arx_read_allowed(read, inGrant, list != nil, reminder != nil) ||
            name.length == 0 || name.length > 1024 || title.length == 0 || title.length > 1024)
            return unknown(@"denied");
        id<ARXSectionReadSession> session = [_provider newReadSession];
        if (!session) return unknown(@"unavailable");
        NSDictionary *l = dictionary([session listWithUUID:list]);
        if (!l || ![uuidFor(l[@"id"], @"REMCDList") isEqual:list] || ![string(l[@"name"]) isEqual:name])
            return unknown(@"identity_unverified");
        NSDictionary *r = dictionary([session reminderWithUUID:reminder]);
        if (!r || !arx_identity_bound(
            [uuidFor(l[@"id"], @"REMCDList") isEqual:list], [string(l[@"name"]) isEqual:name],
            [uuidFor(r[@"id"], @"REMCDReminder") isEqual:reminder], [string(r[@"title"]) isEqual:title],
            [uuidFor(r[@"listID"], @"REMCDList") isEqual:list])) return unknown(@"identity_unverified");
        NSDictionary *m = dictionary([session membershipForReminderUUID:reminder]);
        if (!m) return unknown(@"membership_unverified");
        if ([m[@"state"] isEqual:@"none"]) return @{ @"state": @"none", @"reason": @"provider_verified_none" };
        NSString *section = uuidFor(m[@"sectionID"], @"REMCDListSection");
        NSString *parent = uuidFor(m[@"listID"], @"REMCDList");
        if (![m[@"state"] isEqual:@"section"] ||
            !arx_section_bound(section != nil, parent != nil, [parent isEqual:list]))
            return unknown(@"membership_unverified");
        return @{ @"state": @"section", @"reason": @"exact_objects_read", @"sectionID": section };
    } @catch (NSException *exception) {
        (void)exception;
        // Never return exception names, descriptions, values or unrelated data.
        return unknown(@"private_api_exception");
    }
}
@end

/// The private call ABI is accepted only when metadata declares the object-return
/// signature used here. No guessed argument layouts or forwarded invocations.
static BOOL objectMethod(id target, NSString *name, NSUInteger count, BOOL errorOut) {
    SEL selector = NSSelectorFromString(name);
    Class cls = object_getClass(target);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != count + 2) return NO;
    char *result = method_copyReturnType(method);
    BOOL valid = result && strcmp(result, "@") == 0;
    free(result);
    for (NSUInteger index = 0; index < count; ++index) {
        char *type = method_copyArgumentType(method, (unsigned)index + 2);
        valid = valid && type && strcmp(type, errorOut && index + 1 == count ? "^@" : "@") == 0;
        free(type);
    }
    return valid;
}
static id get(id target, NSString *name) {
    if (!objectMethod(target, name, 0, NO)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(name));
}
static id sendObject(id target, NSString *name, id argument) {
    if (!objectMethod(target, name, 1, NO)) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(name), argument);
}
static id fetch(id target, NSString *name, id argument) {
    if (!objectMethod(target, name, 2, YES)) return nil;
    NSError *error = nil;
    id value = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(target, NSSelectorFromString(name), argument, &error);
    return error ? nil : value;
}
static NSString *objectUUID(id object, NSString *entity) {
    id identifier = get(object, @"objectID");
    id url = get(identifier, @"urlRepresentation");
    if (![url isKindOfClass:NSURL.class]) return nil;
    // Return actual object identifiers only, never invent an identity from a name.
    return uuidFor([url absoluteString], entity);
}

@interface ARXPrivateSectionReadSession : NSObject <ARXSectionReadSession>
@property(nonatomic, strong) id store;
@property(nonatomic, strong) id view;
@property(nonatomic, strong) id reminder;
@property(nonatomic, assign) Class identifierClass;
@property(nonatomic, copy) NSString *reminderUUID;
@end

@implementation ARXPrivateSectionReadProvider
- (id<ARXSectionReadSession>)newReadSession {
#if defined(ARX_SECTION_READER_FIXTURES)
    [NSException raise:@"FixtureBoundary" format:@"Native factory is disabled in fixture executable"];
    return nil;
#else
    // Lazy and deliberately not invoked by fixture tests or the build workflow.
    NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKit.framework"];
    if (![bundle load]) return nil;
    Class storeClass = NSClassFromString(@"REMStore");
    Class viewClass = NSClassFromString(@"REMListSectionsDataView");
    if (!storeClass || !viewClass) return nil;
    id allocatedStore = [storeClass alloc];
    if (!objectMethod(allocatedStore, @"init", 0, NO)) return nil;
    id store = [allocatedStore init];
    if (!store) return nil;
    id allocatedView = [viewClass alloc];
    if (!objectMethod(allocatedView, @"initWithStore:", 1, NO)) return nil;
    id view = [allocatedView initWithStore:store];
    if (!view) return nil;
    ARXPrivateSectionReadSession *session = [ARXPrivateSectionReadSession new];
    session.store = store;
    session.view = view;
    session.identifierClass = NSClassFromString(@"REMObjectID");
    return session;
#endif
}
@end

@implementation ARXPrivateSectionReadSession
- (id)identifier:(NSString *)uuid entity:(NSString *)entity {
    // Construction route observed in upstream code, NOT a guarantee of EventKit
    // identity equivalence. Reader requires exact object/parent/name roundtrip.
    Class cls = self.identifierClass;
    NSString *text = [NSString stringWithFormat:@"x-apple-reminderkit://%@/%@", entity, uuid];
    return sendObject(cls, @"objectIDWithURL:", [NSURL URLWithString:text]);
}
- (NSDictionary *)listWithUUID:(NSString *)uuid {
    id identifier = [self identifier:uuid entity:@"REMCDList"];
    if (!identifier) return nil;
    id list = fetch(self.store, @"fetchListWithObjectID:error:", identifier);
    NSString *actual = objectUUID(list, @"REMCDList");
    NSString *name = string(get(list, @"name"));
    return actual && name ? @{ @"id": actual, @"name": name } : nil;
}
- (NSDictionary *)reminderWithUUID:(NSString *)uuid {
    id identifier = [self identifier:uuid entity:@"REMCDReminder"];
    if (!identifier) return nil;
    id reminder = fetch(self.store, @"fetchReminderWithObjectID:error:", identifier);
    NSString *actual = objectUUID(reminder, @"REMCDReminder");
    NSString *parent = objectUUID(get(reminder, @"list"), @"REMCDList");
    NSString *title = string(get(reminder, @"titleAsString"));
    if (!actual || !parent || !title) return nil;
    self.reminder = reminder;
    self.reminderUUID = actual;
    return @{ @"id": actual, @"listID": parent, @"title": title };
}
- (NSDictionary *)membershipForReminderUUID:(NSString *)uuid {
    if (![uuid isEqual:self.reminderUUID] || !self.reminder) return nil;
    id section = fetch(self.view, @"fetchListSectionWithReminderID:error:", get(self.reminder, @"objectID"));
    // The nil/no-error meaning is unproved; never promote nil to unsectioned.
    if (!section) return nil;
    NSString *actual = objectUUID(section, @"REMCDListSection");
    NSString *parent = objectUUID(get(section, @"list"), @"REMCDList");
    return actual && parent ? @{ @"state": @"section", @"sectionID": actual, @"listID": parent } : nil;
}
@end

#if defined(ARX_SECTION_READER_FIXTURES)
/// Compiled only into the synthetic executable, never a default-store factory.
id<ARXSectionReadSession> ARXFixturePrivateSession(id store, id view, Class identifierClass) {
    ARXPrivateSectionReadSession *session = [ARXPrivateSectionReadSession new];
    session.store = store;
    session.view = view;
    session.identifierClass = identifierClass;
    return session;
}
#endif
