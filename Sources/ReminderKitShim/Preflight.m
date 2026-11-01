#import "ReminderKitShim.h"
#import <objc/runtime.h>

// Closed capability -> ABI table. Each signature is: Class selector return arguments...
// A leading + denotes a factory. Storage targets are intentional: forwarded change-item
// accessors do not reliably respond to respondsToSelector:. No caller supplies a selector.
static void Unsupported(NSString *message) {
    @throw [NSException exceptionWithName:@"RNFailure" reason:message userInfo:@{@"code": @(RNErrorUnsupported)}];
}
static void CheckSignature(NSString *signature) {
    NSArray *parts = [signature componentsSeparatedByString:@" "];
    NSString *className = parts[0], *selector = parts[1], *result = parts[2];
    BOOL factory = [className hasPrefix:@"+"];
    Class cls = NSClassFromString(factory ? [className substringFromIndex:1] : className);
    Method method = factory ? class_getClassMethod(cls, NSSelectorFromString(selector)) : class_getInstanceMethod(cls, NSSelectorFromString(selector));
    if (!method) Unsupported([NSString stringWithFormat:@"Native API unavailable: %@.%@", className, selector]);
    char *returnType = method_copyReturnType(method);
    BOOL valid = returnType && [result isEqualToString:@(returnType)] && method_getNumberOfArguments(method) == parts.count - 1;
    free(returnType);
    for (NSUInteger i = 3; valid && i < parts.count; i++) {
        char *argument = method_copyArgumentType(method, (unsigned)i - 1);
        valid = argument && [parts[i] isEqualToString:@(argument)];
        free(argument);
    }
    if (!valid) Unsupported([NSString stringWithFormat:@"Native ABI changed: %@.%@", className, selector]);
}
static void CheckSignatures(NSString *signatures) {
    for (NSString *signature in [signatures componentsSeparatedByString:@"; "]) CheckSignature(signature);
}

BOOL RNPreflight(NSArray<NSString *> *features, NSError **error) {
    return RNGuard(^id {
        NSError *loadError = nil;
        if (![[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKit.framework"] loadAndReturnError:&loadError])
            Unsupported(loadError.localizedDescription ?: @"ReminderKit unavailable");
        CheckSignatures(@"REMStore initUserInteractive: @ B; REMListSectionsDataView initWithStore: @ @; REMTemplatesDataView initWithStore: @ @; "
            "+REMReminder objectIDWithUUID: @ @; +REMReminderFetchOptions fetchOptionsIncludingDueDateDeltaAlerts @; +REMReminderFetchOptions fetchOptionsIncludingConcealed @; +REMReminderFetchOptions defaultFetchOptions @; "
            "REMStore fetchRemindersWithObjectIDs:fetchOptions:error: @ @ @ ^@; "
            "REMSaveRequest initWithStore: @ @; REMSaveRequest saveSynchronouslyWithError: B ^@; REMSaveRequest trackedReminderChangeItems @; REMSaveRequestTrackedValueContainer valueWithoutPerformingCopy @");
        NSDictionary<NSString *, NSString *> *table = @{
            @"reminder.find": @"REMSiriSearchDataView_RemindersByCriteriaInvocation initWithFetchResultTokenToDiffAgainst: @ @; REMStore resultFromPerformingSwiftInvocation:parametersData:storages:error: @ @ @ @ ^@; REMStoreSwiftInvocationResult resultData @; REMStore fetchRemindersWithObjectIDs:fetchOptions:error: @ @ @ ^@",
            @"reminder.list": @"REMRemindersDataView initWithStore: @ @; REMRemindersDataView fetchRemindersWithListID:includingSubtasks:includingCompleted:error: @ @ B B ^@",
            @"reminder.title": @"+REMReminderPredicateDescriptor predicateDescriptorForRemindersWithTitleEquals: @ @; REMStore fetchRemindersMatchingPredicateDescriptor:sortDescriptors:options:error: @ @ @ @ ^@",
            @"tags.read": @"REMHashtagLabelDataView_AllHashtagLabelsInvocation initWithFetchResultTokenToDiffAgainst: @ @; REMHashtagLabelDataView_ReminderIDsIncludeExcludeOperationInvocation initWithFetchResultTokenToDiffAgainst: @ @; REMHashtagLabelDataView_HashtagIDsWithHashtagLabelNamesInvocation initWithFetchResultTokenToDiffAgainst: @ @; REMStore resultFromPerformingSwiftInvocation:parametersData:storages:error: @ @ @ @ ^@; REMStoreSwiftInvocationResult resultData @",
            @"reminder.create": @"REMSaveRequest addReminderWithTitle:toListChangeItem: @ @ @",
            @"reminder.update": @"REMSaveRequest updateReminder: @ @",
            @"reminder.delete": @"REMReminderChangeItem removeFromList v",
            @"reminder.restore": @"REMListChangeItem undeleteRemindersWithoutUndoWithIDs: v @; REMStore fetchReminderIncludingMarkedForDeleteWithObjectID:error: @ @ ^@; "
                "REMReminderStorage setListID: v @; REMReminderSubtaskContextChangeItem addReminderChangeItem: v @",
            @"title": @"REMReminderChangeItem setTitleAsString: v @",
            @"notes": @"REMReminderChangeItem setNotesAsString: v @",
            @"due": @"REMReminderChangeItem setDueDateComponentsWithAlarmsIfNeeded: v @; REMReminderChangeItem setDueDateComponents: v @; REMReminderChangeItem removeAlarm: v @",
            @"start": @"REMReminderStorage setStartDateComponents: v @",
            @"priority": @"REMReminderStorage setPriority: v Q",
            @"flagged": @"REMReminderStorage setFlagged: v q",
            @"urgent": @"REMReminderUrgentAlarmContextChangeItem setIsUrgentStateEnabledForCurrentUser: v B",
            @"completed": @"REMReminderChangeItem setCompleted: v B; REMSaveRequest setCloneCompletedRecurrentRemindersAtSave: v B",
            @"repeat": @"REMReminderChangeItem removeAllRecurrenceRules v; "
                "REMReminderChangeItem addRecurrenceRuleWithFrequency:interval:daysOfTheWeek:daysOfTheMonth:monthsOfTheYear:weeksOfTheYear:daysOfTheYear:setPositions:end: @ q q @ @ @ @ @ @ @; "
                "+REMRecurrenceDayOfWeek dayOfWeek:weekNumber: @ q q; +REMRecurrenceEnd recurrenceEndWithEndDate: @ @; +REMRecurrenceEnd recurrenceEndWithOccurrenceCount: @ Q",
            @"early": @"REMDueDateDeltaInterval initWithUnit:count: @ q q; REMReminderDueDateDeltaAlertContextChangeItem addDueDateDeltaAlertWithDueDateDelta: @ @; REMReminderDueDateDeltaAlertContextChangeItem removeAllFetchedDueDateDeltaAlerts v",
            @"tags": @"REMReminderHashtagContextChangeItem addHashtagWithType:name: @ q @; REMReminderHashtagContextChangeItem removeAllHashtags v; REMReminderHashtagContextChangeItem removeHashtag: v @",
            @"location": @"REMAlarmLocationTrigger initWithStructuredLocation:proximity: @ @ q; REMAlarmVehicleTrigger initWithEvent: @ q; REMStructuredLocation initWithTitle: @ @; "
                "REMStructuredLocation setLatitude: v d; REMStructuredLocation setLongitude: v d; REMStructuredLocation setRadius: v d; REMReminderChangeItem addAlarmWithTrigger: @ @",
            @"contact": @"REMContactRepresentation initWithPhones:emails: @ @ @; REMReminderStorage setContactHandles: v @",
            @"url": @"REMReminderAttachmentContextChangeItem setURLAttachmentWithURL: @ @; REMReminderAttachmentContextChangeItem removeURLAttachments v",
            @"addImages": @"REMReminderAttachmentContextChangeItem addImageAttachmentWithURL:width:height:error: @ @ Q Q ^@",
            @"removeImages": @"REMReminderAttachmentContextChangeItem removeAttachment: v @",
            @"assigneeID": @"REMReminderAssignmentContextChangeItem addAssignmentWithAssignee:originator:status: @ @ @ q; REMReminderAssignmentContextChangeItem removeAllAssignments v",
            @"listID": @"REMListChangeItem addReminderChangeItem: v @; REMReminderSubtaskContextChangeItem addReminderChangeItem: v @",
            @"position": @"REMListChangeItem insertReminderChangeItem:afterReminderChangeItem: v @ @; REMListChangeItem insertReminderChangeItem:beforeReminderChangeItem: v @ @; "
                "REMReminderSubtaskContextChangeItem insertReminderChangeItem:afterReminderChangeItem: v @ @; REMReminderSubtaskContextChangeItem insertReminderChangeItem:beforeReminderChangeItem: v @ @",
            @"sectionID": @"REMMembership initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn: @ @ @ B @; REMMemberships initWithMembershipByMemberIdentifier: @ @; REMListSectionContextChangeItem setUnsavedMembershipsOfRemindersInSections: v @",
            @"list.create": @"REMSaveRequest addListWithName:toAccountChangeItem:listObjectID: @ @ @ @",
            @"list.update": @"REMSaveRequest updateList: @ @; REMListStorage setName: v @; REMListStorage setSortingStyle: v @; REMListChangeItem setIsPinned: v B; "
                "REMListGroceryContextChangeItem setShouldCategorizeGroceryItems: v B; REMListGroceryContextChangeItem setGroceryLocaleID: v @",
            @"list.delete": @"REMListChangeItem removeFromParent v",
            @"group.create": @"REMSaveRequest addGroupWithName:toAccountGroupContextChangeItem: @ @ @",
            @"group.rename": @"REMListStorage setName: v @",
            @"section.create": @"REMSaveRequest addListSectionWithDisplayName:toListSectionContextChangeItem: @ @ @",
            @"section.rename": @"REMListSectionStorage setDisplayName: v @",
            @"section.move": @"REMListSectionContextChangeItem setUnsavedSectionIDsOrdering: v @; REMListSectionContextChangeItem setShouldUpdateSectionsOrdering: v B",
            @"section.delete": @"REMListSectionChangeItem removeFromList v",
            @"smart.create": @"REMSaveRequest addCustomSmartListWithName:toAccountChangeItem:smartListObjectID: @ @ @ @",
            @"smart.update": @"REMSmartListStorage setFilterData: v @; REMSmartListCustomContextChangeItem setName: v @; REMSmartListCustomContextChangeItem setColor: v @; REMSmartListCustomContextChangeItem setBadge: v @; REMSmartListStorage setMinimumSupportedVersion: v q; REMSmartListStorage setEffectiveMinimumSupportedVersion: v q",
            @"smart.delete": @"REMSmartListChangeItem removeFromParentWithAccountChangeItem: v @",
            @"smart.find": @"REMRemindersListDataView_CustomSmartListInvocation initWithFetchResultTokenToDiffAgainst: @ @; REMStore resultFromPerformingSwiftInvocation:parametersData:storages:error: @ @ @ @ ^@",
            @"template.create": @"REMTemplateConfiguration initWithSourceListID:shouldSaveCompleted: @ @ B; REMSaveRequest addTemplateWithName:configuration:toAccountChangeItem: @ @ @ @",
            @"template.use": @"REMSaveRequest addListUsingTemplate:toAccountChangeItem: @ @ @",
            @"template.delete": @"REMTemplateChangeItem removeFromParentAccount v",
            @"appearance": @"+REMColor colorWithHexString: @ @; REMColor initWithCKSymbolicColorName:hexString: @ @ @; REMListBadge initWithEmblem: @ @; REMListBadge initWithEmoji: @ @"
        };
        for (NSString *feature in features) {
            NSString *key = @{@"parentID": @"listID", @"group.delete": @"list.delete"}[feature] ?: feature;
            NSString *signatures = table[key];
            if (!signatures) Unsupported([@"Unknown native capability token: " stringByAppendingString:feature]);
            if (([key isEqual:@"smart.find"] || [key isEqual:@"reminder.find"] || [key isEqual:@"tags.read"]) && ![[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKitInternal.framework"] load])
                Unsupported(@"Native query evaluator unavailable");
            CheckSignatures(signatures);
        }
        return @YES;
    }, error) != nil;
}
