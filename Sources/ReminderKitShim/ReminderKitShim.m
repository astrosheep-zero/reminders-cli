#import "ReminderKitShim.h"
#import <objc/message.h>
#import <EventKit/EventKit.h>

NSErrorDomain const RNErrorDomain = @"RemindersPOC.Native";
static NSString * const RNFailureName = @"RNFailure";

static void Refuse(RNErrorCode code, NSString *message) {
    @throw [NSException exceptionWithName:RNFailureName reason:message userInfo:@{@"code": @(code)}];
}
static id Required(id value, NSString *operation) {
    if (!value) Refuse(RNErrorBackend, [operation stringByAppendingString:@" returned no value"]);
    return value;
}
id RNGuard(id (^body)(void), NSError **error) {
    if (error) *error = nil;
    @try { return Required(body(), @"Native operation"); }
    @catch (NSException *exception) {
        RNErrorCode code = [exception.name isEqual:RNFailureName]
            ? [exception.userInfo[@"code"] integerValue] : RNErrorUnsupported;
        if (error) *error = [NSError errorWithDomain:RNErrorDomain code:code userInfo:@{
            NSLocalizedDescriptionKey: exception.reason ?: exception.name,
            @"exception": exception.name,
            @"affectedIDs": exception.userInfo[@"affectedIDs"] ?: @[]
        }];
        return nil;
    }
}

NSInteger RNAuthorizationStatus(void) {
    @try { return [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder]; }
    @catch (__unused NSException *exception) { return -1; }
}
BOOL RNRequestAuthorization(NSError **error) {
    NSNumber *granted = RNGuard(^id {
        EKEventStore *store = [EKEventStore new];
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block BOOL allowed = NO;
        __block NSError *authorizationError = nil;
        [store requestFullAccessToRemindersWithCompletion:^(BOOL success, NSError *failure) {
            allowed = success; authorizationError = failure; dispatch_semaphore_signal(finished);
        }];
        if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 110 * NSEC_PER_SEC)) != 0)
            Refuse(RNErrorPermission, @"Reminders authorization request timed out");
        if (authorizationError) Refuse(RNErrorPermission, authorizationError.localizedDescription);
        return @(allowed);
    }, error);
    return granted.boolValue;
}

// ABI-specific sends. A void return must never be passed through an object-return
// function pointer under ARC. Scalars are NSInteger/NSUInteger, BOOL or double.
static SEL Selector(const char *name) { return sel_registerName(name); }
static id O(id target, const char *name) {
    Required(target, [NSString stringWithUTF8String:name]);
    return ((id (*)(id, SEL))objc_msgSend)(target, Selector(name));
}
static id O1(id target, const char *name, id a) {
    Required(target, [NSString stringWithUTF8String:name]);
    return ((id (*)(id, SEL, id))objc_msgSend)(target, Selector(name), a);
}
static id O2(id target, const char *name, id a, id b) {
    Required(target, [NSString stringWithUTF8String:name]);
    return ((id (*)(id, SEL, id, id))objc_msgSend)(target, Selector(name), a, b);
}
static id O3(id target, const char *name, id a, id b, id c) {
    Required(target, [NSString stringWithUTF8String:name]);
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)(target, Selector(name), a, b, c);
}
static void V(id target, const char *name) {
    Required(target, [NSString stringWithUTF8String:name]);
    ((void (*)(id, SEL))objc_msgSend)(target, Selector(name));
}
static void V1(id target, const char *name, id a) {
    Required(target, [NSString stringWithUTF8String:name]);
    ((void (*)(id, SEL, id))objc_msgSend)(target, Selector(name), a);
}
static void V2(id target, const char *name, id a, id b) {
    Required(target, [NSString stringWithUTF8String:name]);
    ((void (*)(id, SEL, id, id))objc_msgSend)(target, Selector(name), a, b);
}
static NSInteger I(id target, const char *name) {
    Required(target, [NSString stringWithUTF8String:name]);
    return ((NSInteger (*)(id, SEL))objc_msgSend)(target, Selector(name));
}
static BOOL B(id target, const char *name) {
    Required(target, [NSString stringWithUTF8String:name]);
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, Selector(name));
}
static double D(id target, const char *name) {
    Required(target, [NSString stringWithUTF8String:name]);
    return ((double (*)(id, SEL))objc_msgSend)(target, Selector(name));
}
static void SI(id target, const char *name, NSInteger value) {
    Required(target, [NSString stringWithUTF8String:name]);
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, Selector(name), value);
}
static void SB(id target, const char *name, BOOL value) {
    Required(target, [NSString stringWithUTF8String:name]);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, Selector(name), value);
}
static void SD(id target, const char *name, double value) {
    Required(target, [NSString stringWithUTF8String:name]);
    ((void (*)(id, SEL, double))objc_msgSend)(target, Selector(name), value);
}
static Class C(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) Refuse(RNErrorUnsupported, [@"Missing native class " stringByAppendingString:name]);
    return cls;
}
static id NativeResult(id result, NSError *error, NSString *operation) {
    if (error) Refuse(RNErrorBackend, [NSString stringWithFormat:@"%@: %@ (%@/%ld)", operation,
        error.localizedDescription, error.domain, (long)error.code]);
    return Required(result, operation);
}
static id Fetch(id target, const char *name) {
    NSError *error = nil;
    id result = ((id (*)(id, SEL, NSError **))objc_msgSend)(Required(target, @"Fetch receiver"), Selector(name), &error);
    return NativeResult(result, error, [NSString stringWithUTF8String:name]);
}
static id Fetch1(id target, const char *name, id argument) {
    NSError *error = nil;
    id result = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(Required(target, @"Fetch receiver"), Selector(name), argument, &error);
    return NativeResult(result, error, [NSString stringWithUTF8String:name]);
}
static NSString *ID(id objectID) {
    if (!objectID) return nil;
    return Required([O(objectID, "uuid") UUIDString], @"Object identifier");
}
static NSString *ObjectID(id object) { return ID(O(object, "objectID")); }
static void Put(NSMutableDictionary *dictionary, NSString *key, id value) {
    if (value) dictionary[key] = value;
}
static id Nullable(id value) { return value == NSNull.null ? nil : value; }
static BOOL SameID(NSString *a, NSString *b) { return a && b && [a caseInsensitiveCompare:b] == NSOrderedSame; }
static id Color(NSDictionary *spec) {
    if (!spec) return nil;
    if (!spec[@"name"]) return Required(O1(C(@"REMColor"), "colorWithHexString:", spec[@"hex"]), @"Color");
    return Required(O2([C(@"REMColor") alloc], "initWithCKSymbolicColorName:hexString:", spec[@"name"], spec[@"hex"]), @"Color");
}
static id Badge(NSString *value) {
    if (!value.length) return nil;
    const char *initializer = [value canBeConvertedToEncoding:NSASCIIStringEncoding] ? "initWithEmblem:" : "initWithEmoji:";
    return Required(O1([C(@"REMListBadge") alloc], initializer, value), @"List badge");
}
static NSDictionary *ColorValue(id value) {
    if (!value) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    Put(out, @"name", O(value, "ckSymbolicColorName"));
    Put(out, @"hex", O(value, "hexString"));
    return out;
}

@implementation RNBridge {
    id _store;
    id _sectionView;
    BOOL _saveAttempted;
    NSMutableDictionary *_activeCache;
    NSMutableDictionary *_concealedCache;
    NSArray *_listsCache;
    NSArray<NSString *> *_lastSavedReminderIDs;
    NSArray<NSString *> *_lastIntroducedReminderIDs;
}
+ (instancetype)openWithError:(NSError **)error {
    return RNGuard(^id {
        NSError *loadError = nil;
        NSBundle *bundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKit.framework"];
        if (![bundle loadAndReturnError:&loadError]) Refuse(RNErrorUnsupported, loadError.localizedDescription ?: @"ReminderKit unavailable");
        RNBridge *bridge = [RNBridge new];
        bridge->_store = Required(((id (*)(id, SEL, BOOL))objc_msgSend)([C(@"REMStore") alloc], Selector("initUserInteractive:"), YES), @"Open store");
        bridge->_sectionView = Required(O1([C(@"REMListSectionsDataView") alloc], "initWithStore:", bridge->_store), @"Sections view");
        C(@"REMSaveRequest");
        return bridge;
    }, error);
}
- (id)guard:(id (^)(void))body error:(NSError **)error {
    _saveAttempted = NO;
    _lastSavedReminderIDs = @[];
    _lastIntroducedReminderIDs = @[];
    _activeCache = [NSMutableDictionary dictionary];
    _concealedCache = [NSMutableDictionary dictionary];
    _listsCache = nil;
    id result = RNGuard(^id {
        @try { return body(); }
        @catch (NSException *exception) {
            if (self->_saveAttempted) @throw [NSException exceptionWithName:RNFailureName
                reason:[@"Native save may have changed data: " stringByAppendingString:exception.reason ?: exception.name]
                userInfo:@{@"code": @(RNErrorOutcomeUnknown), @"affectedIDs": self->_lastSavedReminderIDs ?: @[]}];
            @throw;
        }
    }, error);
    _activeCache = nil; _concealedCache = nil; _listsCache = nil;
    return result;
}
- (id)request { return Required(O1([C(@"REMSaveRequest") alloc], "initWithStore:", _store), @"Save request"); }
- (NSArray<NSString *> *)lastSavedReminderIDs { return _lastSavedReminderIDs ?: @[]; }
- (NSArray<NSString *> *)lastIntroducedReminderIDs { return _lastIntroducedReminderIDs ?: @[]; }
- (NSArray<NSString *> *)trackedReminderIDs:(id)request {
    NSDictionary *changes = Required(O(request, "trackedReminderChangeItems"), @"Native tracked reminder changes");
    if (![changes isKindOfClass:NSDictionary.class]) Refuse(RNErrorBackend, @"Tracked native reminder changes are not a dictionary");
    NSMutableSet *identifiers = [NSMutableSet set];
    for (id change in changes.allValues) [identifiers addObject:Required(ObjectID(change), @"Tracked reminder ID")];
    return [identifiers.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
- (void)commit:(id)request {
    _lastSavedReminderIDs = [self trackedReminderIDs:request];
    _saveAttempted = YES; // Includes throws and false-without-error, not just NSError.
    NSError *error = nil;
    BOOL saved = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(Required(request, @"Save request"), Selector("saveSynchronouslyWithError:"), &error);
    if (!saved || error) Refuse(RNErrorOutcomeUnknown, error.localizedDescription ?: @"Native save did not confirm acceptance");
    NSMutableSet *after = [NSMutableSet setWithArray:[self trackedReminderIDs:request]];
    NSMutableSet *introduced = [after mutableCopy];
    [introduced minusSet:[NSSet setWithArray:_lastSavedReminderIDs]];
    _lastIntroducedReminderIDs = [introduced.allObjects sortedArrayUsingSelector:@selector(compare:)];
    [after addObjectsFromArray:_lastSavedReminderIDs];
    _lastSavedReminderIDs = [after.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
- (NSArray *)rawLists {
    if (!_listsCache) _listsCache = Fetch(_store, "fetchEligibleDefaultListsWithError:");
    return _listsCache;
}
- (NSArray *)rawGroups {
    NSMutableArray *values = [NSMutableArray array];
    ((void (*)(id, SEL, void (^)(id, BOOL *)))objc_msgSend)(_store, Selector("enumerateAllGroupsAndListsWithBlock:"), ^(id item, BOOL *stop) {
        if (B(item, "isGroup")) [values addObject:item];
    });
    return values;
}
- (id)find:(NSString *)identifier in:(NSArray *)objects {
    if (![[NSUUID alloc] initWithUUIDString:identifier]) Refuse(RNErrorInvalidInput, @"Native identifiers must be UUIDs");
    for (id object in objects) if (SameID(ObjectID(object), identifier)) return object;
    Refuse(RNErrorNotFound, [@"Object not found: " stringByAppendingString:identifier]);
    return nil;
}
- (id)list:(NSString *)identifier { return [self find:identifier in:[self rawLists]]; }
- (id)group:(NSString *)identifier { return [self find:identifier in:[self rawGroups]]; }
- (id)account { return Required(O(Fetch(_store, "fetchDefaultListWithError:"), "account"), @"Default account"); }
- (id)reminderObjectID:(NSString *)identifier {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    if (!uuid) Refuse(RNErrorInvalidInput, @"Invalid reminder UUID");
    return Required(O1(C(@"REMReminder"), "objectIDWithUUID:", uuid), @"Reminder object ID");
}
- (id)rawReminder:(NSString *)identifier concealed:(BOOL)concealed {
    NSMutableDictionary *cache = concealed ? _concealedCache : _activeCache;
    id cached = cache[identifier.uppercaseString];
    if (cached) return cached == NSNull.null ? nil : cached;
    id options = O(C(@"REMReminderFetchOptions"), concealed ? "fetchOptionsIncludingConcealed" : "fetchOptionsIncludingDueDateDeltaAlerts");
    NSError *error = nil;
    NSDictionary *values = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(_store,
        Selector("fetchRemindersWithObjectIDs:fetchOptions:error:"), @[[self reminderObjectID:identifier]], Required(options, @"Fetch options"), &error);
    NativeResult(values, error, @"Fetch reminder by ID");
    for (id value in values.allValues) if (SameID(ObjectID(value), identifier)) {
        cache[identifier.uppercaseString] = value;
        return value;
    }
    cache[identifier.uppercaseString] = NSNull.null;
    return nil; // Successful fetch with no object is distinct from an error.
}
- (BOOL)isConcealed:(id)object {
    if (!O(object, "listID")) return YES;
    id parentID = O(object, "parentReminderID");
    if (!parentID) return NO;
    id parent = [self rawReminder:ID(parentID) concealed:YES];
    if (!parent) Refuse(RNErrorBackend, @"Reminder has an unavailable parent; deletion state cannot be determined");
    return O(parent, "listID") == nil;
}
- (id)existingReminder:(NSString *)identifier {
    id object = [self rawReminder:identifier concealed:NO];
    if (!object || [self isConcealed:object]) Refuse(RNErrorNotFound, @"Active reminder not found");
    return object;
}
- (NSArray *)rawReminders:(id)list {
    return Fetch1(_store, "fetchRemindersForEventKitBridgingWithListIDs:error:", @[Required(O(list, "objectID"), @"List ID")]);
}
- (NSArray *)rawSections:(id)list { return Fetch1(_store, "fetchListSectionsWithListObjectID:error:", O(list, "objectID")); }
- (id)section:(NSString *)identifier list:(id)list { return [self find:identifier in:[self rawSections:list]]; }
- (NSArray *)rawSmartLists { return Fetch(_store, "fetchCustomSmartListsWithError:"); }
- (NSArray *)rawTemplates {
    id view = Required(O1([C(@"REMTemplatesDataView") alloc], "initWithStore:", _store), @"Templates view");
    return Fetch1(view, "fetchTemplatesInAccount:error:", [self account]);
}
- (NSArray *)sectionValues:(id)list {
    NSMutableArray *result = [NSMutableArray array];
    NSArray *sections = [self rawSections:list];
    for (NSUInteger index = 0; index < sections.count; index++) {
        id section = sections[index];
        NSMutableDictionary *value = [@{@"id": Required(ObjectID(section), @"Section ID"),
            @"name": Required(O(section, "displayName"), @"Section name"), @"listID": ObjectID(list)} mutableCopy];
        if (index > 0) value[@"position"] = @{@"id": ObjectID(sections[index - 1]), @"after": @YES};
        else if (sections.count > 1) value[@"position"] = @{@"id": ObjectID(sections[1]), @"after": @NO};
        [result addObject:value];
    }
    return result;
}
- (NSArray *)sharees:(id)list {
    NSMutableArray *values = [NSMutableArray array];
    id context = O(list, "shareeContext");
    if (!context) return values; // An unshared list legitimately has no sharee context.
    for (id sharee in Required(O(context, "sharees"), @"Shared-list members")) {
        NSString *name = O(sharee, "formattedName") ?: O(sharee, "displayName") ?: O(sharee, "address") ?: @"";
        NSString *me = O(O(list, "storage"), "currentUserShareParticipantID");
        [values addObject:@{@"id": ObjectID(sharee), @"name": name, @"status": @(I(sharee, "status")), @"me": @(SameID(ObjectID(sharee), me))}];
    }
    return values;
}
- (NSDictionary *)listValue:(id)list {
    NSMutableDictionary *result = [@{
        @"id": ObjectID(list), @"name": Required(O(O(list, "storage"), "name"), @"List name"),
        @"shared": @(B(list, "isShared")), @"pinned": @(B(list, "isPinned")),
        @"groceries": @(B(O(list, "storage"), "shouldCategorizeGroceryItems")),
        @"sections": [self sectionValues:list], @"members": [self sharees:list]
    } mutableCopy];
    id parent = O(list, "parentList");
    Put(result, @"groupID", parent ? ObjectID(parent) : nil);
    Put(result, @"color", ColorValue(O(list, "color")));
    Put(result, @"icon", O(list, "badgeEmblem"));
    Put(result, @"sorting", O(O(list, "storage"), "sortingStyle"));
    return result;
}
- (NSArray *)listsWithError:(NSError **)error {
    return [self guard:^id {
        NSMutableArray *result = [NSMutableArray array];
        for (id list in [self rawLists]) if (!B(list, "isGroup")) [result addObject:[self listValue:list]];
        return result;
    } error:error];
}
- (NSArray *)groupsWithError:(NSError **)error {
    return [self guard:^id {
        NSMutableArray *result = [NSMutableArray array];
        for (id group in [self rawGroups]) [result addObject:@{@"id": ObjectID(group), @"name": Required(O(O(group, "storage"), "name"), @"Group name")}];
        return result;
    } error:error];
}
- (NSArray *)tagCountsWithError:(NSError **)error {
    return [self guard:^id {
        // A requested tag catalog may scan raw rows. It never hydrates dates,
        // recurrence, attachments, locations, or full reminder value models.
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        for (id list in [self rawLists]) for (id reminder in [self rawReminders:list]) {
            NSMutableSet *names = [NSMutableSet set];
            for (id tag in O(reminder, "hashtags") ?: @[]) [names addObject:Required(O(tag, "name"), @"Tag name")];
            BOOL completed = B(reminder, "isCompleted");
            for (NSString *name in names) {
                NSArray *previous = counts[name] ?: @[@0, @0];
                counts[name] = @[@([previous[0] integerValue] + (completed ? 0 : 1)), @([previous[1] integerValue] + 1)];
            }
        }
        NSMutableArray *values = [NSMutableArray array];
        for (NSString *name in [counts.allKeys sortedArrayUsingSelector:@selector(compare:)]) [values addObject:@{
            @"name": name, @"openCount": counts[name][0], @"totalCount": counts[name][1]}];
        return values;
    } error:error];
}
- (BOOL)validateRecoveryForList:(NSString *)listID error:(NSError **)error {
    return [self guard:^id {
        id account = Required(O([self list:listID], "account"), @"Recovery account");
        if (!B(O(account, "capabilities"), "supportsRecentlyDeletedList")) Refuse(RNErrorUnsupported, @"Target account does not support Recently Deleted");
        return @YES;
    } error:error] != nil;
}
- (BOOL)validateSmartListCreationWithError:(NSError **)error {
    return [self guard:^id {
        if (!B(O([self account], "capabilities"), "supportsCustomSmartLists")) Refuse(RNErrorUnsupported, @"Default account does not support custom smart lists");
        return @YES;
    } error:error] != nil;
}
- (NSString *)defaultListWithError:(NSError **)error {
    return [self guard:^id { return ObjectID(Fetch(self->_store, "fetchDefaultListWithError:")); } error:error];
}
- (NSArray *)sectionsInList:(NSString *)listID error:(NSError **)error {
    return [self guard:^id { return [self sectionValues:[self list:listID]]; } error:error];
}

static NSDictionary *RuleValue(id rule) {
    NSMutableDictionary *value = [@{@"frequency": @(I(rule, "frequency")), @"interval": @(I(rule, "interval"))} mutableCopy];
    NSMutableArray *days = [NSMutableArray array];
    for (id day in O(rule, "daysOfTheWeek") ?: @[]) [days addObject:@[@(I(day, "dayOfTheWeek")), @(I(day, "weekNumber"))]];
    value[@"weekdays"] = days;
    for (NSString *key in @[@"daysOfTheMonth", @"monthsOfTheYear", @"weeksOfTheYear", @"daysOfTheYear", @"setPositions"])
        Put(value, key, O(rule, key.UTF8String));
    id end = O(rule, "recurrenceEnd");
    if (end) {
        if (B(end, "usesEndDate")) Put(value, @"endDate", O(end, "endDate"));
        else value[@"count"] = @(I(end, "occurrenceCount"));
    }
    return value;
}
static NSDictionary *PlaceValue(id trigger) {
    if ([trigger isKindOfClass:C(@"REMAlarmVehicleTrigger")]) return @{@"vehicle": @(I(trigger, "event"))};
    if (![trigger isKindOfClass:C(@"REMAlarmLocationTrigger")]) return nil;
    id place = Required(O(trigger, "structuredLocation"), @"Location alarm place");
    NSMutableDictionary *value = [@{@"proximity": @(I(trigger, "proximity")), @"title": O(place, "title") ?: @"",
        @"latitude": @(D(place, "latitude")), @"longitude": @(D(place, "longitude")), @"radius": @(D(place, "radius"))} mutableCopy];
    Put(value, @"address", O(place, "address"));
    return value;
}
- (NSString *)sectionIDForReminder:(id)reminder {
    NSError *error = nil;
    id section = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(_sectionView, Selector("fetchListSectionWithReminderID:error:"), O(reminder, "objectID"), &error);
    if (error) Refuse(RNErrorBackend, error.localizedDescription);
    return section ? ObjectID(section) : nil;
}
- (NSDictionary *)positionForReminder:(id)reminder sectionID:(NSString *)sectionID {
    id list = [self list:ID(O(reminder, "listID"))];
    id order = Required(O(list, "reminderIDsOrdering"), @"Native reminder manual order");
    NSArray *identifiers = [order isKindOfClass:NSOrderedSet.class] ? [order array] : order;
    if (![identifiers isKindOfClass:NSArray.class]) Refuse(RNErrorBackend, @"Invalid reminder manual ordering representation");
    NSString *current = ObjectID(reminder), *parent = ID(O(reminder, "parentReminderID"));
    NSMutableArray *siblings = [NSMutableArray array];
    for (id objectID in identifiers) {
        NSString *identifier = ID(objectID);
        id candidate = SameID(identifier, current) ? reminder : [self rawReminder:identifier concealed:NO];
        if (!candidate || [self isConcealed:candidate]) continue;
        NSString *candidateParent = ID(O(candidate, "parentReminderID"));
        NSString *candidateSection = [self sectionIDForReminder:candidate];
        if (((parent == nil && candidateParent == nil) || SameID(parent, candidateParent)) &&
            ((sectionID == nil && candidateSection == nil) || SameID(sectionID, candidateSection))) [siblings addObject:identifier];
    }
    NSUInteger index = [siblings indexOfObjectPassingTest:^BOOL(NSString *value, NSUInteger index, BOOL *stop) { return SameID(value, current); }];
    if (index == NSNotFound) {
        // New/automatically sorted items can legitimately have no manual-order
        // record. Do not manufacture a neighbor from a different ordering mode.
        return nil;
    }
    if (index > 0) return @{@"id": siblings[index - 1], @"after": @YES};
    if (siblings.count > 1) return @{@"id": siblings[1], @"after": @NO};
    return nil;
}
- (NSDictionary *)reminderValue:(id)reminder concealed:(BOOL)concealed {
    NSMutableDictionary *result = [@{@"id": ObjectID(reminder), @"title": Required(O(reminder, "titleAsString"), @"Reminder title"),
        @"completed": @(B(reminder, "isCompleted")), @"flagged": @(I(reminder, "flagged")), @"priority": @(I(reminder, "priority"))} mutableCopy];
    Put(result, @"listID", ID(O(reminder, "listID")));
    Put(result, @"parentID", ID(O(reminder, "parentReminderID")));
    NSMutableArray *children = [NSMutableArray array];
    id subtaskContext = O(reminder, "subtaskContext");
    // A subtask has no subtask context. A top-level object's child fetch must
    // succeed; failure is never confused with an empty child collection.
    if (subtaskContext) {
        NSArray *objects = concealed
            ? Fetch1(subtaskContext, "fetchRemindersWithFetchOptions:error:", O(C(@"REMReminderFetchOptions"), "fetchOptionsIncludingConcealed"))
            : Fetch(subtaskContext, "fetchRemindersWithError:");
        for (id child in objects) [children addObject:Required(ObjectID(child), @"Child reminder ID")];
    }
    result[@"childIDs"] = children;
    if (concealed) return result;
    for (NSString *key in @[@"notesAsString", @"dueDateComponents", @"startDateComponents", @"completionDate", @"creationDate", @"lastModifiedDate"])
        Put(result, key, O(reminder, key.UTF8String));
    result[@"urgent"] = @(B(reminder, "isUrgentStateEnabledForCurrentUser"));
    NSMutableArray *tags = [NSMutableArray array];
    for (id tag in O(reminder, "hashtags") ?: @[]) [tags addObject:Required(O(tag, "name"), @"Tag name")];
    result[@"tags"] = [tags sortedArrayUsingSelector:@selector(compare:)];
    NSArray *rules = O(reminder, "recurrenceRules") ?: @[];
    if (rules.count > 1) Refuse(RNErrorUnsupported, @"Multiple native recurrence rules cannot be represented without loss");
    if (rules.count) result[@"repeat"] = RuleValue(rules.firstObject);
    NSMutableArray *alarms = [NSMutableArray array];
    NSMutableArray *places = [NSMutableArray array];
    for (id alarm in O(reminder, "alarms") ?: @[]) {
        if (B(alarm, "isSnooze")) continue;
        id trigger = Required(O(alarm, "trigger"), @"Alarm trigger");
        NSDictionary *place = PlaceValue(trigger);
        if (place) [places addObject:place];
        else if ([trigger isKindOfClass:C(@"REMAlarmDateTrigger")]) [alarms addObject:Required(O(trigger, "dateComponents"), @"Date alarm")];
        else Refuse(RNErrorUnsupported, [@"Unrepresentable alarm type " stringByAppendingString:NSStringFromClass([trigger class])]);
    }
    result[@"alarms"] = alarms;
    if (places.count > 1) Refuse(RNErrorUnsupported, @"Multiple location/vehicle alarms cannot be represented without loss");
    if (places.count) result[@"location"] = places.firstObject;
    id contact = O(reminder, "contactHandles");
    if (contact) result[@"contact"] = @{@"phones": O(contact, "phones") ?: @[], @"emails": O(contact, "emails") ?: @[]};
    id attachments = O(reminder, "attachmentContext");
    NSMutableArray *urls = [NSMutableArray array], *images = [NSMutableArray array];
    if (attachments) {
        for (id attachment in O(attachments, "urlAttachments") ?: @[]) [urls addObject:Required([O(attachment, "url") absoluteString], @"URL attachment")];
        for (id image in O(attachments, "imageAttachments") ?: @[]) {
            NSURL *url = Required(O(image, "fileURL"), @"Native image URL (image may not be downloaded)");
            NSNumber *size = nil; NSError *fileError = nil;
            if (![url getResourceValue:&size forKey:NSURLFileSizeKey error:&fileError]) Refuse(RNErrorBackend, fileError.localizedDescription ?: @"Image size unavailable");
            if (size.unsignedLongLongValue > 16 * 1024 * 1024) Refuse(RNErrorUnsupported, @"Native image exceeds 16 MiB transport limit");
            NSData *bytes = [NSData dataWithContentsOfURL:url options:0 error:&fileError];
            NativeResult(bytes, fileError, @"Read native image attachment");
            [images addObject:@{@"id": ObjectID(image), @"type": Required(O(image, "uti"), @"Image content type"),
                @"width": @(I(image, "width")), @"height": @(I(image, "height")), @"size": @(bytes.length),
                @"fileName": url.lastPathComponent, @"data": bytes, @"sourceURL": url}];
        }
    }
    result[@"urls"] = urls; result[@"images"] = images;
    id assignments = O(reminder, "assignmentContext");
    id assignment = assignments ? O(assignments, "currentAssignment") : nil;
    if (assignment) Put(result, @"assigneeID", ID(O(assignment, "assigneeID")));
    id earlyContext = O(reminder, "dueDateDeltaAlertContext");
    NSMutableArray *early = [NSMutableArray array];
    if (earlyContext) for (id alert in O(earlyContext, "dueDateDeltaAlerts") ?: @[]) {
        id delta = Required(O(alert, "dueDateDelta"), @"Early reminder interval");
        [early addObject:@[@(I(delta, "unit")), @(I(delta, "count"))]];
    }
    result[@"early"] = early;
    // nil with no error means no section, not a failed fetch.
    NSString *sectionID = [self sectionIDForReminder:reminder];
    Put(result, @"sectionID", sectionID);
    Put(result, @"position", [self positionForReminder:reminder sectionID:sectionID]);
    return result;
}
- (id)reminder:(NSString *)identifier concealed:(BOOL)concealed error:(NSError **)error {
    // NSNull means a successful by-ID miss; nil is exclusively failure.
    return [self guard:^id {
        id object = [self rawReminder:identifier concealed:concealed];
        if (!object) return NSNull.null;
        BOOL hidden = [self rawReminder:identifier concealed:NO] == nil || [self isConcealed:object];
        if (hidden != concealed) return NSNull.null;
        return [self reminderValue:object concealed:concealed];
    } error:error];
}
- (NSArray *)remindersInList:(NSString *)listID error:(NSError **)error {
    return [self guard:^id {
        NSMutableArray *values = [NSMutableArray array];
        for (id reminder in [self rawReminders:[self list:listID]]) {
            // Bridge list fetches omit early alerts. Fetch each ID with full options,
            // otherwise visible version tokens would omit an editable field.
            [values addObject:[self reminderValue:[self existingReminder:ObjectID(reminder)] concealed:NO]];
        }
        return values;
    } error:error];
}
- (NSArray *)smartListsWithError:(NSError **)error {
    return [self guard:^id {
        NSMutableArray *values = [NSMutableArray array];
        for (id smart in [self rawSmartLists]) {
            id context = Required(O(smart, "customContext"), @"Custom smart-list context");
            NSMutableDictionary *value = [@{@"id": ObjectID(smart), @"name": Required(O(context, "name"), @"Smart-list name"),
                @"filterData": Required(O(smart, "filterData"), @"Smart-list filter")} mutableCopy];
            Put(value, @"color", ColorValue(O(context, "color")));
            id badge = O(context, "badge");
            if (badge) Put(value, @"icon", O(badge, "rawValue"));
            [values addObject:value];
        }
        return values;
    } error:error];
}
- (NSArray *)contentsOfSmartList:(NSString *)identifier includeCompleted:(BOOL)completed error:(NSError **)error {
    return [self guard:^id {
        NSError *loadError = nil;
        if (![[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKitInternal.framework"] loadAndReturnError:&loadError])
            Refuse(RNErrorUnsupported, loadError.localizedDescription ?: @"Native smart-list evaluator unavailable");
        id smart = [self find:identifier in:[self rawSmartLists]];
        NSDictionary *parameters = @{@"smartList": @{@"objectIDUUID": ObjectID(smart)}, @"sortingStyle": @{@"base": @"default"},
            @"showCompleted": @{@"base": completed ? @"on" : @"off"}, @"countCompleted": @NO,
            @"remindersPrefetch": @{@"base": @"none"}, @"fetchSubtasks": @"off", @"shouldFetchManualOrderingID": @NO};
        NSError *error = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:parameters format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
        NativeResult(data, error, @"Encode native smart-list request");
        id account = Required(O(smart, "account"), @"Smart-list account");
        NSDictionary *storages = @{O(smart, "objectID"): Required(O(smart, "storage"), @"Smart-list storage"),
            O(account, "objectID"): Required(O(account, "storage"), @"Account storage")};
        id invocation = Required(O1([C(@"REMRemindersListDataView_CustomSmartListInvocation") alloc], "initWithFetchResultTokenToDiffAgainst:", nil), @"Smart-list invocation");
        id reply = ((id (*)(id, SEL, id, id, id, NSError **))objc_msgSend)(self->_store,
            Selector("resultFromPerformingSwiftInvocation:parametersData:storages:error:"), invocation, data, storages, &error);
        NativeResult(reply, error, @"Evaluate native smart list");
        NSDictionary *decoded = [NSPropertyListSerialization propertyListWithData:Required(O(reply, "resultData"), @"Smart-list result") options:0 format:nil error:&error];
        NativeResult(decoded, error, @"Decode smart-list result");
        NSArray *rows = [decoded[@"model"] isKindOfClass:NSDictionary.class] ? decoded[@"model"][@"reminders"] : nil;
        if (![rows isKindOfClass:NSArray.class]) Refuse(RNErrorBackend, @"Native smart-list response has no reminder rows");
        NSMutableArray *ids = [NSMutableArray array];
        for (NSDictionary *row in rows) {
            NSString *uuid = [row isKindOfClass:NSDictionary.class] && [row[@"objectID"] isKindOfClass:NSDictionary.class] ? row[@"objectID"][@"uuid"] : nil;
            if (![uuid isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:uuid]) Refuse(RNErrorBackend, @"Malformed native smart-list row");
            [ids addObject:uuid.uppercaseString];
        }
        return ids;
    } error:error];
}
- (NSArray *)templatesWithError:(NSError **)error {
    return [self guard:^id {
        NSMutableArray *values = [NSMutableArray array];
        for (id item in [self rawTemplates]) {
            NSMutableDictionary *value = [@{@"id": ObjectID(item), @"name": Required(O(item, "name"), @"Template name")} mutableCopy];
            Put(value, @"color", ColorValue(O(item, "color"))); Put(value, @"icon", O(item, "badgeEmblem"));
            [values addObject:value];
        }
        return values;
    } error:error];
}

- (void)applyList:(NSDictionary *)fields change:(id)change request:(id)request account:(id)account {
    if (fields[@"name"]) V1(O(change, "storage"), "setName:", fields[@"name"]);
    if (fields[@"color"]) V1(change, "setColor:", Color(Nullable(fields[@"color"])));
    if (fields[@"icon"]) V1(O(change, "appearanceContext"), "setBadge:", Badge(Nullable(fields[@"icon"])));
    if (fields[@"pinned"]) SB(change, "setIsPinned:", [fields[@"pinned"] boolValue]);
    if (fields[@"groceries"]) {
        id grocery = Required(O(change, "groceryContextChangeItem"), @"Groceries context");
        if ([fields[@"groceries"] boolValue] && !O(grocery, "groceryLocaleID")) V1(grocery, "setGroceryLocaleID:", NSLocale.currentLocale.localeIdentifier);
        SB(grocery, "setShouldCategorizeGroceryItems:", [fields[@"groceries"] boolValue]);
    }
    if (fields[@"sorting"]) V1(O(change, "storage"), "setSortingStyle:", fields[@"sorting"]);
    if (fields[@"groupID"]) {
        id group = Nullable(fields[@"groupID"]);
        id container = group ? O(O1(request, "updateList:", [self group:group]), "sublistContext") : O1(request, "updateAccount:", account);
        V1(container, "addListChangeItem:", change);
    }
    NSDictionary *position = fields[@"position"];
    if (position) {
        id neighbor = [self list:position[@"id"]];
        id parent = O(neighbor, "parentList");
        id container = parent ? O(O1(request, "updateList:", parent), "sublistContext") : O1(request, "updateAccount:", account);
        V2(container, [position[@"after"] boolValue] ? "insertListChangeItem:afterListChangeItem:" : "insertListChangeItem:beforeListChangeItem:", change, O1(request, "updateList:", neighbor));
    }
}
- (NSString *)createList:(NSString *)name changes:(NSDictionary *)changes error:(NSError **)error {
    return [self guard:^id {
        id request = [self request], account = [self account];
        id change = Required(O3(request, "addListWithName:toAccountChangeItem:listObjectID:", name, O1(request, "updateAccount:", account), nil), @"Create list");
        [self applyList:changes change:change request:request account:account];
        NSString *identifier = Required(ObjectID(change), @"Created list ID");
        [self commit:request]; return identifier;
    } error:error];
}
- (BOOL)updateList:(NSString *)identifier changes:(NSDictionary *)changes error:(NSError **)error {
    return [self guard:^id {
        id list = [self list:identifier], request = [self request];
        [self applyList:changes change:Required(O1(request, "updateList:", list), @"List change") request:request account:O(list, "account")];
        [self commit:request]; return @YES;
    } error:error] != nil;
}
- (BOOL)deleteList:(NSString *)identifier error:(NSError **)error {
    return [self guard:^id {
        id list = [self list:identifier], request = [self request];
        V(O1(request, "updateList:", list), "removeFromParent");
        [self commit:request]; return @YES;
    } error:error] != nil;
}
- (NSString *)createGroup:(NSString *)name error:(NSError **)error {
    return [self guard:^id {
        id request = [self request];
        id group = Required(O2(request, "addGroupWithName:toAccountGroupContextChangeItem:", name, O(O1(request, "updateAccount:", [self account]), "groupContext")), @"Create group");
        NSString *identifier = Required(ObjectID(group), @"Created group ID");
        [self commit:request]; return identifier;
    } error:error];
}
- (BOOL)renameGroup:(NSString *)identifier name:(NSString *)name error:(NSError **)error {
    return [self guard:^id {
        id group = [self group:identifier], request = [self request];
        V1(O(O1(request, "updateList:", group), "storage"), "setName:", name);
        [self commit:request]; return @YES;
    } error:error] != nil;
}
- (BOOL)deleteGroup:(NSString *)identifier error:(NSError **)error {
    return [self guard:^id {
        id group = [self group:identifier], request = [self request];
        V(O1(request, "updateList:", group), "removeFromParent");
        [self commit:request]; return @YES;
    } error:error] != nil;
}
- (NSString *)createSection:(NSString *)name list:(NSString *)listID error:(NSError **)error {
    return [self guard:^id {
        id list = [self list:listID], request = [self request];
        id section = Required(O2(request, "addListSectionWithDisplayName:toListSectionContextChangeItem:", name, O(O1(request, "updateList:", list), "sectionsContextChangeItem")), @"Create section");
        NSString *identifier = Required(ObjectID(section), @"Created section ID");
        [self commit:request]; return identifier;
    } error:error];
}
- (BOOL)updateSection:(NSString *)identifier list:(NSString *)listID changes:(NSDictionary *)changes error:(NSError **)error {
    return [self guard:^id {
        id list = [self list:listID], section = [self section:identifier list:list], request = [self request];
        if (changes[@"name"]) V1(O1(request, "updateListSection:", section), "setDisplayName:", changes[@"name"]);
        NSDictionary *position = changes[@"position"];
        if (position) {
            NSMutableArray *order = [NSMutableArray array];
            id anchor = [self section:position[@"id"] list:list];
            if (SameID(identifier, ObjectID(anchor))) Refuse(RNErrorInvalidInput, @"A section cannot be its own neighbor");
            for (id item in [self rawSections:list]) if (!SameID(ObjectID(item), identifier)) [order addObject:O(item, "objectID")];
            NSUInteger index = [order indexOfObject:O(anchor, "objectID")];
            if (index == NSNotFound) Refuse(RNErrorInvalidInput, @"Section anchor absent from ordering");
            [order insertObject:O(section, "objectID") atIndex:index + ([position[@"after"] boolValue] ? 1 : 0)];
            id context = O(O1(request, "updateList:", list), "sectionsContextChangeItem");
            V1(context, "setUnsavedSectionIDsOrdering:", order); SB(context, "setShouldUpdateSectionsOrdering:", YES);
        }
        [self commit:request]; return @YES;
    } error:error] != nil;
}
- (BOOL)deleteSection:(NSString *)identifier list:(NSString *)listID error:(NSError **)error {
    return [self guard:^id {
        id section = [self section:identifier list:[self list:listID]], request = [self request];
        V(O1(request, "updateListSection:", section), "removeFromList");
        [self commit:request]; return @YES;
    } error:error] != nil;
}
- (void)applySmart:(NSDictionary *)fields change:(id)change {
    id context = Required(O(change, "customContext"), @"Custom smart-list context");
    if (fields[@"name"]) V1(context, "setName:", fields[@"name"]);
    if (fields[@"color"]) V1(context, "setColor:", Color(Nullable(fields[@"color"])));
    if (fields[@"icon"]) V1(context, "setBadge:", Badge(Nullable(fields[@"icon"])));
    if (fields[@"filterData"]) {
        V1(change, "setFilterData:", fields[@"filterData"]);
        id storage = O(change, "storage");
        if (I(storage, "minimumSupportedVersion") < 20220430) SI(storage, "setMinimumSupportedVersion:", 20220430);
        if (I(storage, "effectiveMinimumSupportedVersion") < 20220430) SI(storage, "setEffectiveMinimumSupportedVersion:", 20220430);
    }
}
- (NSString *)createSmartList:(NSString *)name changes:(NSDictionary *)changes error:(NSError **)error {
    return [self guard:^id {
        id request = [self request];
        id change = Required(O3(request, "addCustomSmartListWithName:toAccountChangeItem:smartListObjectID:", name, O1(request, "updateAccount:", [self account]), nil), @"Create smart list");
        [self applySmart:changes change:change];
        NSString *identifier = Required(ObjectID(change), @"Created smart-list ID");
        [self commit:request]; return identifier;
    } error:error];
}
- (BOOL)updateSmartList:(NSString *)identifier changes:(NSDictionary *)changes error:(NSError **)error {
    return [self guard:^id {
        id smart = [self find:identifier in:[self rawSmartLists]], request = [self request];
        [self applySmart:changes change:O1(request, "updateSmartList:", smart)];
        [self commit:request]; return @YES;
    } error:error] != nil;
}
- (BOOL)deleteSmartList:(NSString *)identifier error:(NSError **)error {
    return [self guard:^id {
        id smart = [self find:identifier in:[self rawSmartLists]], request = [self request];
        V1(O1(request, "updateSmartList:", smart), "removeFromParentWithAccountChangeItem:", O1(request, "updateAccount:", Required(O(smart, "account"), @"Smart-list account")));
        [self commit:request]; return @YES;
    } error:error] != nil;
}
- (NSString *)createTemplate:(NSString *)name list:(NSString *)listID includeCompleted:(BOOL)completed error:(NSError **)error {
    return [self guard:^id {
        id list = [self list:listID], request = [self request];
        id configuration = Required(((id (*)(id, SEL, id, BOOL))objc_msgSend)([C(@"REMTemplateConfiguration") alloc], Selector("initWithSourceListID:shouldSaveCompleted:"), O(list, "objectID"), completed), @"Template configuration");
        id item = Required(O3(request, "addTemplateWithName:configuration:toAccountChangeItem:", name, configuration, O1(request, "updateAccount:", O(list, "account"))), @"Create template");
        NSString *identifier = Required(ObjectID(item), @"Created template ID");
        [self commit:request]; return identifier;
    } error:error];
}
- (NSString *)useTemplate:(NSString *)identifier name:(NSString *)name error:(NSError **)error {
    return [self guard:^id {
        id item = [self find:identifier in:[self rawTemplates]], request = [self request];
        id change = Required(O2(request, "addListUsingTemplate:toAccountChangeItem:", item, O1(request, "updateAccount:", [self account])), @"Instantiate template");
        if (name) V1(O(change, "storage"), "setName:", name);
        NSString *created = Required(ObjectID(change), @"Instantiated list ID");
        [self commit:request]; return created;
    } error:error];
}
- (BOOL)deleteTemplate:(NSString *)identifier error:(NSError **)error {
    return [self guard:^id {
        id item = [self find:identifier in:[self rawTemplates]], request = [self request];
        V(O1(request, "updateTemplate:", item), "removeFromParentAccount");
        [self commit:request]; return @YES;
    } error:error] != nil;
}

- (void)setSection:(id)sectionID change:(id)change list:(id)list request:(id)request {
    id section = sectionID ? [self section:sectionID list:list] : list;
    id context = O(O1(request, "updateList:", list), "sectionsContextChangeItem");
    id existing = O(context, "unsavedMembershipsOfRemindersInSections");
    NSMutableDictionary *members = [NSMutableDictionary dictionary];
    if (existing) [members addEntriesFromDictionary:O(existing, "membershipByMemberIdentifier") ?: @{}];
    NSUUID *memberUUID = O(O(change, "objectID"), "uuid");
    NSUUID *groupUUID = O(O(section, "objectID"), "uuid"); // Never nil: nil traps in native code.
    members[Required(memberUUID, @"Section member UUID")] = Required(((id (*)(id, SEL, id, id, BOOL, id))objc_msgSend)([C(@"REMMembership") alloc],
        Selector("initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:"), memberUUID, Required(groupUUID, @"Section group UUID"), NO, NSDate.date), @"Section membership");
    V1(context, "setUnsavedMembershipsOfRemindersInSections:", O1([C(@"REMMemberships") alloc], "initWithMembershipByMemberIdentifier:", members));
}
- (void)setRepeat:(id)spec change:(id)change {
    V(change, "removeAllRecurrenceRules");
    if (!spec) return;
    NSMutableArray *weekdays = [NSMutableArray array];
    for (NSArray *pair in spec[@"weekdays"] ?: @[]) [weekdays addObject:Required(((id (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(C(@"REMRecurrenceDayOfWeek"), Selector("dayOfWeek:weekNumber:"), [pair[0] integerValue], [pair[1] integerValue]), @"Recurrence weekday")];
    id end = nil;
    if (spec[@"endDate"]) end = O1(C(@"REMRecurrenceEnd"), "recurrenceEndWithEndDate:", spec[@"endDate"]);
    if (spec[@"count"]) end = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(C(@"REMRecurrenceEnd"), Selector("recurrenceEndWithOccurrenceCount:"), [spec[@"count"] unsignedIntegerValue]);
    Required(((id (*)(id, SEL, NSInteger, NSInteger, id, id, id, id, id, id, id))objc_msgSend)(change,
        Selector("addRecurrenceRuleWithFrequency:interval:daysOfTheWeek:daysOfTheMonth:monthsOfTheYear:weeksOfTheYear:daysOfTheYear:setPositions:end:"),
        [spec[@"frequency"] integerValue], [spec[@"interval"] integerValue], weekdays.count ? weekdays : nil,
        [spec[@"daysOfTheMonth"] count] ? spec[@"daysOfTheMonth"] : nil, [spec[@"monthsOfTheYear"] count] ? spec[@"monthsOfTheYear"] : nil, nil, nil, nil, end), @"Add recurrence rule");
}
- (void)applyReminder:(NSDictionary *)fields change:(id)change list:(id)list request:(id)request {
    if (fields[@"title"]) V1(change, "setTitleAsString:", fields[@"title"]);
    if (fields[@"notes"]) V1(change, "setNotesAsString:", Nullable(fields[@"notes"]));
    if (fields[@"priority"]) {
        NSUInteger priority = [fields[@"priority"] unsignedIntegerValue];
        if (priority != 0 && priority != 1 && priority != 5 && priority != 9) Refuse(RNErrorInvalidInput, @"Invalid native priority");
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(change, Selector("setPriority:"), priority);
    }
    if (fields[@"flagged"]) SI(change, "setFlagged:", [fields[@"flagged"] boolValue] ? 1 : 0);
    if (fields[@"urgent"]) SB(O(change, "urgentAlarmContext"), "setIsUrgentStateEnabledForCurrentUser:", [fields[@"urgent"] boolValue]);
    if (fields[@"due"]) {
        // Only remove date triggers: changing a due date must not erase location alarms.
        for (id alarm in [O(change, "alarms") copy] ?: @[]) if ([O(alarm, "trigger") isKindOfClass:C(@"REMAlarmDateTrigger")]) V1(change, "removeAlarm:", alarm);
        id due = Nullable(fields[@"due"]);
        V1(change, due ? "setDueDateComponentsWithAlarmsIfNeeded:" : "setDueDateComponents:", due);
    }
    if (fields[@"start"]) V1(change, "setStartDateComponents:", Nullable(fields[@"start"]));
    if (fields[@"repeat"]) [self setRepeat:Nullable(fields[@"repeat"]) change:change];
    if (fields[@"tags"]) {
        id context = O(change, "hashtagContext"); V(context, "removeAllHashtags");
        for (NSString *tag in fields[@"tags"]) Required(((id (*)(id, SEL, NSInteger, id))objc_msgSend)(context, Selector("addHashtagWithType:name:"), 0, tag), @"Add tag");
    }
    id target = fields[@"listID"] ? [self list:fields[@"listID"]] : list;
    if (fields[@"listID"] && !SameID(ObjectID(target), ObjectID(list))) V1(O1(request, "updateList:", target), "addReminderChangeItem:", change);
    if (fields[@"parentID"]) {
        id parentID = Nullable(fields[@"parentID"]);
        id parent = parentID ? [self existingReminder:parentID] : nil;
        if (parent && !SameID(ID(O(parent, "listID")), ObjectID(target))) Refuse(RNErrorInvalidInput, @"Parent must be in target list");
        if (parent && O(parent, "parentReminderID")) Refuse(RNErrorInvalidInput, @"Subtasks cannot contain subtasks");
        if (SameID(parentID, ObjectID(change))) Refuse(RNErrorInvalidInput, @"Self parenting is forbidden");
        id container = parent ? O(O1(request, "updateReminder:", parent), "subtaskContext") : O1(request, "updateList:", target);
        V1(container, "addReminderChangeItem:", change);
    }
    if (fields[@"sectionID"]) [self setSection:Nullable(fields[@"sectionID"]) change:change list:target request:request];
    if (fields[@"early"]) {
        id context = O(change, "dueDateDeltaAlertContext"); V(context, "removeAllFetchedDueDateDeltaAlerts");
        for (NSArray *pair in fields[@"early"]) {
            NSInteger unit = [pair[0] integerValue];
            if (unit < 0 || unit > 4) Refuse(RNErrorInvalidInput, @"Invalid early-alert unit");
            id delta = Required(((id (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)([C(@"REMDueDateDeltaInterval") alloc], Selector("initWithUnit:count:"), unit, [pair[1] integerValue]), @"Early-alert interval");
            Required(O1(context, "addDueDateDeltaAlertWithDueDateDelta:", delta), @"Add early alert");
        }
    }
    if (fields[@"location"]) {
        for (id alarm in [O(change, "alarms") copy] ?: @[]) if (PlaceValue(O(alarm, "trigger"))) V1(change, "removeAlarm:", alarm);
        NSDictionary *place = Nullable(fields[@"location"]);
        if (place) {
            id trigger;
            if (place[@"vehicle"]) {
                NSInteger event = [place[@"vehicle"] integerValue];
                if (event != 1 && event != 2) Refuse(RNErrorInvalidInput, @"Invalid vehicle event");
                trigger = ((id (*)(id, SEL, NSInteger))objc_msgSend)([C(@"REMAlarmVehicleTrigger") alloc], Selector("initWithEvent:"), event);
            } else {
                NSInteger proximity = [place[@"proximity"] integerValue];
                if (proximity != 1 && proximity != 2) Refuse(RNErrorInvalidInput, @"Invalid location proximity");
                id location = Required(O1([C(@"REMStructuredLocation") alloc], "initWithTitle:", place[@"title"]), @"Structured location");
                SD(location, "setLatitude:", [place[@"latitude"] doubleValue]); SD(location, "setLongitude:", [place[@"longitude"] doubleValue]); SD(location, "setRadius:", [place[@"radius"] doubleValue]);
                V1(location, "setAddress:", place[@"address"]);
                trigger = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)([C(@"REMAlarmLocationTrigger") alloc], Selector("initWithStructuredLocation:proximity:"), location, proximity);
            }
            Required(O1(change, "addAlarmWithTrigger:", Required(trigger, @"Location trigger")), @"Add location alarm");
        }
    }
    if (fields[@"contact"]) {
        NSDictionary *contact = Nullable(fields[@"contact"]);
        V1(change, "setContactHandles:", contact ? O2([C(@"REMContactRepresentation") alloc], "initWithPhones:emails:", contact[@"phones"], contact[@"emails"]) : nil);
    }
    if (fields[@"url"]) {
        id context = O(change, "attachmentContext"); V(context, "removeURLAttachments");
        if (Nullable(fields[@"url"])) Required(O1(context, "setURLAttachmentWithURL:", [NSURL URLWithString:fields[@"url"]]), @"Set URL attachment");
    }
    if (fields[@"removeImages"]) {
        id context = O(change, "attachmentContext");
        for (NSString *identifier in fields[@"removeImages"]) {
            id image = [self find:identifier in:O(context, "imageAttachments") ?: @[]];
            V1(context, "removeAttachment:", image);
        }
    }
    for (NSDictionary *image in fields[@"addImages"] ?: @[]) {
        NSError *error = nil;
        id attached = ((id (*)(id, SEL, id, NSUInteger, NSUInteger, NSError **))objc_msgSend)(O(change, "attachmentContext"),
            Selector("addImageAttachmentWithURL:width:height:error:"), image[@"url"], [image[@"width"] unsignedIntegerValue], [image[@"height"] unsignedIntegerValue], &error);
        NativeResult(attached, error, @"Attach staged image");
    }
    if (fields[@"assigneeID"]) {
        id context = O(change, "assignmentContext"); V(context, "removeAllAssignments");
        NSString *assigneeID = Nullable(fields[@"assigneeID"]);
        if (assigneeID) {
            NSArray *members = [self sharees:target]; BOOL joined = NO;
            for (NSDictionary *member in members) if (SameID(member[@"id"], assigneeID) && [member[@"status"] integerValue] == 1) joined = YES;
            if (!joined) Refuse(RNErrorInvalidInput, @"Assignee must be an already joined list member");
            NSString *originator = Required(O(O(target, "storage"), "currentUserShareParticipantID"), @"Current shared-list participant");
            NSArray *sharees = Required(O(O(target, "shareeContext"), "sharees"), @"Shared-list members");
            id assignee = [self find:assigneeID in:sharees], sender = [self find:originator in:sharees];
            Required(((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(context, Selector("addAssignmentWithAssignee:originator:status:"), assignee, sender, 0), @"Assign reminder");
        }
    }
    NSDictionary *position = fields[@"position"];
    if (position) {
        id neighbor = [self existingReminder:position[@"id"]];
        if (!SameID(ID(O(neighbor, "listID")), ObjectID(target)) || SameID(ObjectID(neighbor), ObjectID(change))) Refuse(RNErrorInvalidInput, @"Invalid reminder neighbor");
        id parentID = O(neighbor, "parentReminderID");
        id container = parentID ? O(O1(request, "updateReminder:", [self existingReminder:ID(parentID)]), "subtaskContext") : O1(request, "updateList:", target);
        V2(container, [position[@"after"] boolValue] ? "insertReminderChangeItem:afterReminderChangeItem:" : "insertReminderChangeItem:beforeReminderChangeItem:", change, O1(request, "updateReminder:", neighbor));
    }
    if (fields[@"completed"]) {
        SB(request, "setCloneCompletedRecurrentRemindersAtSave:", YES);
        SB(change, "setCompleted:", [fields[@"completed"] boolValue]);
    }
}
- (NSString *)createReminderInList:(NSString *)listID title:(NSString *)title changes:(NSDictionary *)changes error:(NSError **)error {
    return [self guard:^id {
        id list = [self list:listID], request = [self request];
        id change = Required(O2(request, "addReminderWithTitle:toListChangeItem:", title, O1(request, "updateList:", list)), @"Create reminder");
        [self applyReminder:changes change:change list:list request:request];
        NSString *identifier = Required(ObjectID(change), @"Created reminder ID");
        [self commit:request]; return identifier;
    } error:error];
}
- (BOOL)updateReminder:(NSString *)identifier changes:(NSDictionary *)changes error:(NSError **)error {
    return [self guard:^id {
        id reminder = [self existingReminder:identifier], list = [self list:ID(O(reminder, "listID"))], request = [self request];
        if (changes[@"listID"] && !SameID(changes[@"listID"], ObjectID(list))) {
            id context = O(reminder, "subtaskContext");
            NSArray *children = context ? Fetch(context, "fetchRemindersWithError:") : @[];
            if (children.count) Refuse(RNErrorInvalidInput, @"Cannot move a parent with children");
        }
        [self applyReminder:changes change:O1(request, "updateReminder:", reminder) list:list request:request];
        [self commit:request]; return @YES;
    } error:error] != nil;
}
- (BOOL)softDeleteReminders:(NSArray<NSString *> *)identifiers error:(NSError **)error {
    return [self guard:^id {
        id request = [self request];
        for (NSString *identifier in identifiers) V(O1(request, "updateReminder:", [self existingReminder:identifier]), "removeFromList");
        if (identifiers.count) [self commit:request]; return @YES;
    } error:error] != nil;
}
- (BOOL)restoreReminders:(NSArray<NSString *> *)identifiers toList:(NSString *)listID error:(NSError **)error {
    return [self guard:^id {
        id list = [self list:listID], request = [self request];
        if (!identifiers.count) Refuse(RNErrorInvalidInput, @"Restore requires a root ID");
        NSString *rootID = identifiers.firstObject;
        id root = [self rawReminder:rootID concealed:YES];
        if (!root || ([self rawReminder:rootID concealed:NO] != nil && ![self isConcealed:root])) Refuse(RNErrorNotFound, @"Restorable reminder not found");
        NSString *parentID = ID(O(root, "parentReminderID"));
        id parent = parentID ? [self existingReminder:parentID] : nil;
        if (parent && (!SameID(ID(O(parent, "listID")), listID) || O(parent, "parentReminderID") || identifiers.count > 1))
            Refuse(RNErrorInvalidInput, @"Restored subtask needs an active top-level parent in the target list and no children");
        NSMutableSet *seen = [NSMutableSet setWithObject:rootID.uppercaseString];
        for (NSString *identifier in [identifiers subarrayWithRange:NSMakeRange(1, identifiers.count - 1)]) {
            if ([seen containsObject:identifier.uppercaseString]) Refuse(RNErrorInvalidInput, @"Duplicate restore ID");
            [seen addObject:identifier.uppercaseString];
            // Deleted children can retain an obsolete listID. Fetch including
            // marked-for-delete and explicitly move their storage in this save.
            id child = Fetch1(self->_store, "fetchReminderIncludingMarkedForDeleteWithObjectID:error:", [self reminderObjectID:identifier]);
            if (!SameID(ID(O(child, "parentReminderID")), rootID)) Refuse(RNErrorInvalidInput, @"Known child no longer belongs to the restored root");
            V1(O1(request, "updateReminder:", child), "setListID:", O(list, "objectID"));
        }
        V1(O1(request, "updateList:", list), "undeleteRemindersWithoutUndoWithIDs:", @[[self reminderObjectID:rootID]]);
        if (parent) V1(O(O1(request, "updateReminder:", parent), "subtaskContext"), "addReminderChangeItem:", O1(request, "updateReminder:", root));
        [self commit:request]; return @YES;
    } error:error] != nil;
}
- (NSNumber *)replaceTag:(NSString *)name replacement:(NSString *)replacement error:(NSError **)error {
    return [self guard:^id {
        id request = [self request]; NSInteger count = 0;
        for (id list in [self rawLists]) for (id reminder in [self rawReminders:list]) {
            NSMutableArray *matches = [NSMutableArray array]; BOOL already = NO;
            for (id tag in O(reminder, "hashtags") ?: @[]) {
                NSString *value = Required(O(tag, "name"), @"Tag name");
                if ([value caseInsensitiveCompare:name] == NSOrderedSame) [matches addObject:tag];
                else if (replacement && [value caseInsensitiveCompare:replacement] == NSOrderedSame) already = YES;
            }
            if (!matches.count) continue;
            id context = O(O1(request, "updateReminder:", reminder), "hashtagContext");
            for (id tag in matches) V1(context, "removeHashtag:", tag);
            if (replacement && !already) Required(((id (*)(id, SEL, NSInteger, id))objc_msgSend)(context, Selector("addHashtagWithType:name:"), 0, replacement), @"Replace tag");
            count++;
        }
        if (count) [self commit:request]; return @(count);
    } error:error];
}
@end
