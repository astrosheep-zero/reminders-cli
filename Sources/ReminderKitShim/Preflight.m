#import "ReminderKitShim.h"
#import <objc/runtime.h>

// A closed set of operation capabilities. No caller can supply a selector or class.
// Storage targets below are deliberate: ReminderKit forwards many change-item
// accessors, so respondsToSelector: alone would incorrectly reject working APIs.
static void Unsupported(NSString *message) {
    @throw [NSException exceptionWithName:@"RNFailure" reason:message userInfo:@{@"code": @(RNErrorUnsupported)}];
}
static void MethodABI(NSString *className, NSString *selector, BOOL classMethod, NSString *result, NSArray<NSString *> *arguments) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selector);
    Method method = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!method) Unsupported([NSString stringWithFormat:@"Native API unavailable: %@.%@", className, selector]);
    char *returnType = method_copyReturnType(method);
    BOOL valid = returnType && [result isEqualToString:@(returnType)] && method_getNumberOfArguments(method) == arguments.count + 2;
    free(returnType);
    for (NSUInteger i = 0; valid && i < arguments.count; i++) {
        char *argument = method_copyArgumentType(method, (unsigned)i + 2);
        valid = argument && [arguments[i] isEqualToString:@(argument)];
        free(argument);
    }
    if (!valid) Unsupported([NSString stringWithFormat:@"Native ABI changed: %@.%@", className, selector]);
}
static void Instance(NSString *className, NSString *selector, NSString *result, NSArray<NSString *> *arguments) {
    MethodABI(className, selector, NO, result, arguments);
}
static void Factory(NSString *className, NSString *selector, NSArray<NSString *> *arguments) {
    MethodABI(className, selector, YES, @"@", arguments);
}

BOOL RNPreflight(NSArray<NSString *> *features, NSError **error) {
    return RNGuard(^id {
        NSError *loadError = nil;
        if (![[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKit.framework"] loadAndReturnError:&loadError])
            Unsupported(loadError.localizedDescription ?: @"ReminderKit unavailable");
        Instance(@"REMStore", @"initUserInteractive:", @"@", @[@"B"]);
        Instance(@"REMListSectionsDataView", @"initWithStore:", @"@", @[@"@"]);
        Instance(@"REMTemplatesDataView", @"initWithStore:", @"@", @[@"@"]);
        Factory(@"REMReminder", @"objectIDWithUUID:", @[@"@"]);
        Factory(@"REMReminderFetchOptions", @"fetchOptionsIncludingDueDateDeltaAlerts", @[]);
        Factory(@"REMReminderFetchOptions", @"fetchOptionsIncludingConcealed", @[]);
        Instance(@"REMSaveRequest", @"initWithStore:", @"@", @[@"@"]);
        Instance(@"REMSaveRequest", @"saveSynchronouslyWithError:", @"B", @[@"^@"]);
        Instance(@"REMSaveRequest", @"trackedReminderChangeItems", @"@", @[]);
        for (NSString *feature in features) {
            if ([feature isEqual:@"reminder.create"]) {
                Instance(@"REMSaveRequest", @"addReminderWithTitle:toListChangeItem:", @"@", @[@"@", @"@"]);
            } else if ([feature isEqual:@"reminder.update"]) {
                Instance(@"REMSaveRequest", @"updateReminder:", @"@", @[@"@"]);
            } else if ([feature isEqual:@"reminder.delete"]) {
                Instance(@"REMReminderChangeItem", @"removeFromList", @"v", @[]);
            } else if ([feature isEqual:@"reminder.restore"]) {
                Instance(@"REMListChangeItem", @"undeleteRemindersWithoutUndoWithIDs:", @"v", @[@"@"]);
                Instance(@"REMStore", @"fetchReminderIncludingMarkedForDeleteWithObjectID:error:", @"@", @[@"@", @"^@"]);
                Instance(@"REMReminderStorage", @"setListID:", @"v", @[@"@"]);
                Instance(@"REMReminderSubtaskContextChangeItem", @"addReminderChangeItem:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"title"]) {
                Instance(@"REMReminderChangeItem", @"setTitleAsString:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"notes"]) {
                Instance(@"REMReminderChangeItem", @"setNotesAsString:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"due"]) {
                Instance(@"REMReminderChangeItem", @"setDueDateComponentsWithAlarmsIfNeeded:", @"v", @[@"@"]);
                Instance(@"REMReminderChangeItem", @"setDueDateComponents:", @"v", @[@"@"]);
                Instance(@"REMReminderChangeItem", @"removeAlarm:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"start"]) {
                Instance(@"REMReminderStorage", @"setStartDateComponents:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"priority"]) {
                Instance(@"REMReminderStorage", @"setPriority:", @"v", @[@"Q"]);
            } else if ([feature isEqual:@"flagged"]) {
                Instance(@"REMReminderStorage", @"setFlagged:", @"v", @[@"q"]);
            } else if ([feature isEqual:@"urgent"]) {
                Instance(@"REMReminderUrgentAlarmContextChangeItem", @"setIsUrgentStateEnabledForCurrentUser:", @"v", @[@"B"]);
            } else if ([feature isEqual:@"completed"]) {
                Instance(@"REMReminderChangeItem", @"setCompleted:", @"v", @[@"B"]);
                Instance(@"REMSaveRequest", @"setCloneCompletedRecurrentRemindersAtSave:", @"v", @[@"B"]);
            } else if ([feature isEqual:@"repeat"]) {
                Instance(@"REMReminderChangeItem", @"removeAllRecurrenceRules", @"v", @[]);
                Instance(@"REMReminderChangeItem", @"addRecurrenceRuleWithFrequency:interval:daysOfTheWeek:daysOfTheMonth:monthsOfTheYear:weeksOfTheYear:daysOfTheYear:setPositions:end:", @"@", @[@"q", @"q", @"@", @"@", @"@", @"@", @"@", @"@", @"@"]);
                Factory(@"REMRecurrenceDayOfWeek", @"dayOfWeek:weekNumber:", @[@"q", @"q"]);
                Factory(@"REMRecurrenceEnd", @"recurrenceEndWithEndDate:", @[@"@"]);
                Factory(@"REMRecurrenceEnd", @"recurrenceEndWithOccurrenceCount:", @[@"Q"]);
            } else if ([feature isEqual:@"early"]) {
                Instance(@"REMDueDateDeltaInterval", @"initWithUnit:count:", @"@", @[@"q", @"q"]);
                Instance(@"REMReminderDueDateDeltaAlertContextChangeItem", @"addDueDateDeltaAlertWithDueDateDelta:", @"@", @[@"@"]);
                Instance(@"REMReminderDueDateDeltaAlertContextChangeItem", @"removeAllFetchedDueDateDeltaAlerts", @"v", @[]);
            } else if ([feature isEqual:@"tags"]) {
                Instance(@"REMReminderHashtagContextChangeItem", @"addHashtagWithType:name:", @"@", @[@"q", @"@"]);
                Instance(@"REMReminderHashtagContextChangeItem", @"removeAllHashtags", @"v", @[]);
                Instance(@"REMReminderHashtagContextChangeItem", @"removeHashtag:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"location"]) {
                Instance(@"REMAlarmLocationTrigger", @"initWithStructuredLocation:proximity:", @"@", @[@"@", @"q"]);
                Instance(@"REMAlarmVehicleTrigger", @"initWithEvent:", @"@", @[@"q"]);
                Instance(@"REMStructuredLocation", @"initWithTitle:", @"@", @[@"@"]);
                for (NSString *selector in @[@"setLatitude:", @"setLongitude:", @"setRadius:"]) Instance(@"REMStructuredLocation", selector, @"v", @[@"d"]);
                Instance(@"REMReminderChangeItem", @"addAlarmWithTrigger:", @"@", @[@"@"]);
            } else if ([feature isEqual:@"contact"]) {
                Instance(@"REMContactRepresentation", @"initWithPhones:emails:", @"@", @[@"@", @"@"]);
                Instance(@"REMReminderStorage", @"setContactHandles:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"url"]) {
                Instance(@"REMReminderAttachmentContextChangeItem", @"setURLAttachmentWithURL:", @"@", @[@"@"]);
                Instance(@"REMReminderAttachmentContextChangeItem", @"removeURLAttachments", @"v", @[]);
            } else if ([feature isEqual:@"addImages"]) {
                Instance(@"REMReminderAttachmentContextChangeItem", @"addImageAttachmentWithURL:width:height:error:", @"@", @[@"@", @"Q", @"Q", @"^@"]);
            } else if ([feature isEqual:@"removeImages"]) {
                Instance(@"REMReminderAttachmentContextChangeItem", @"removeAttachment:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"assigneeID"]) {
                Instance(@"REMReminderAssignmentContextChangeItem", @"addAssignmentWithAssignee:originator:status:", @"@", @[@"@", @"@", @"q"]);
                Instance(@"REMReminderAssignmentContextChangeItem", @"removeAllAssignments", @"v", @[]);
            } else if ([feature isEqual:@"listID"] || [feature isEqual:@"parentID"]) {
                Instance(@"REMListChangeItem", @"addReminderChangeItem:", @"v", @[@"@"]);
                Instance(@"REMReminderSubtaskContextChangeItem", @"addReminderChangeItem:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"position"]) {
                for (NSString *cls in @[@"REMListChangeItem", @"REMReminderSubtaskContextChangeItem"]) {
                    Instance(cls, @"insertReminderChangeItem:afterReminderChangeItem:", @"v", @[@"@", @"@"]);
                    Instance(cls, @"insertReminderChangeItem:beforeReminderChangeItem:", @"v", @[@"@", @"@"]);
                }
            } else if ([feature isEqual:@"sectionID"]) {
                Instance(@"REMMembership", @"initWithMemberIdentifier:groupIdentifier:isObsolete:modifiedOn:", @"@", @[@"@", @"@", @"B", @"@"]);
                Instance(@"REMMemberships", @"initWithMembershipByMemberIdentifier:", @"@", @[@"@"]);
                Instance(@"REMListSectionContextChangeItem", @"setUnsavedMembershipsOfRemindersInSections:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"list.create"]) {
                Instance(@"REMSaveRequest", @"addListWithName:toAccountChangeItem:listObjectID:", @"@", @[@"@", @"@", @"@"]);
            } else if ([feature isEqual:@"list.update"]) {
                Instance(@"REMSaveRequest", @"updateList:", @"@", @[@"@"]);
                Instance(@"REMListStorage", @"setName:", @"v", @[@"@"]);
                Instance(@"REMListStorage", @"setSortingStyle:", @"v", @[@"@"]);
                Instance(@"REMListChangeItem", @"setIsPinned:", @"v", @[@"B"]);
                Instance(@"REMListGroceryContextChangeItem", @"setShouldCategorizeGroceryItems:", @"v", @[@"B"]);
                Instance(@"REMListGroceryContextChangeItem", @"setGroceryLocaleID:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"list.delete"] || [feature isEqual:@"group.delete"]) {
                Instance(@"REMListChangeItem", @"removeFromParent", @"v", @[]);
            } else if ([feature isEqual:@"group.create"]) {
                Instance(@"REMSaveRequest", @"addGroupWithName:toAccountGroupContextChangeItem:", @"@", @[@"@", @"@"]);
            } else if ([feature isEqual:@"group.rename"]) {
                Instance(@"REMListStorage", @"setName:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"section.create"]) {
                Instance(@"REMSaveRequest", @"addListSectionWithDisplayName:toListSectionContextChangeItem:", @"@", @[@"@", @"@"]);
            } else if ([feature isEqual:@"section.rename"]) {
                Instance(@"REMListSectionStorage", @"setDisplayName:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"section.move"]) {
                Instance(@"REMListSectionContextChangeItem", @"setUnsavedSectionIDsOrdering:", @"v", @[@"@"]);
                Instance(@"REMListSectionContextChangeItem", @"setShouldUpdateSectionsOrdering:", @"v", @[@"B"]);
            } else if ([feature isEqual:@"section.delete"]) {
                Instance(@"REMListSectionChangeItem", @"removeFromList", @"v", @[]);
            } else if ([feature isEqual:@"smart.create"]) {
                Instance(@"REMSaveRequest", @"addCustomSmartListWithName:toAccountChangeItem:smartListObjectID:", @"@", @[@"@", @"@", @"@"]);
            } else if ([feature isEqual:@"smart.update"]) {
                Instance(@"REMSmartListStorage", @"setFilterData:", @"v", @[@"@"]);
                Instance(@"REMSmartListCustomContextChangeItem", @"setName:", @"v", @[@"@"]);
                Instance(@"REMSmartListStorage", @"setMinimumSupportedVersion:", @"v", @[@"q"]);
                Instance(@"REMSmartListStorage", @"setEffectiveMinimumSupportedVersion:", @"v", @[@"q"]);
            } else if ([feature isEqual:@"smart.delete"]) {
                Instance(@"REMSmartListChangeItem", @"removeFromParentWithAccountChangeItem:", @"v", @[@"@"]);
            } else if ([feature isEqual:@"smart.find"]) {
                if (![[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/ReminderKitInternal.framework"] load]) Unsupported(@"Native smart-list evaluator unavailable");
                Instance(@"REMRemindersListDataView_CustomSmartListInvocation", @"initWithFetchResultTokenToDiffAgainst:", @"@", @[@"@"]);
                Instance(@"REMStore", @"resultFromPerformingSwiftInvocation:parametersData:storages:error:", @"@", @[@"@", @"@", @"@", @"^@"]);
            } else if ([feature isEqual:@"template.create"]) {
                Instance(@"REMTemplateConfiguration", @"initWithSourceListID:shouldSaveCompleted:", @"@", @[@"@", @"B"]);
                Instance(@"REMSaveRequest", @"addTemplateWithName:configuration:toAccountChangeItem:", @"@", @[@"@", @"@", @"@"]);
            } else if ([feature isEqual:@"template.use"]) {
                Instance(@"REMSaveRequest", @"addListUsingTemplate:toAccountChangeItem:", @"@", @[@"@", @"@"]);
            } else if ([feature isEqual:@"template.delete"]) {
                Instance(@"REMTemplateChangeItem", @"removeFromParentAccount", @"v", @[]);
            } else if ([feature isEqual:@"appearance"]) {
                Factory(@"REMColor", @"colorWithHexString:", @[@"@"]);
                Instance(@"REMColor", @"initWithCKSymbolicColorName:hexString:", @"@", @[@"@", @"@"]);
                Instance(@"REMListBadge", @"initWithEmblem:", @"@", @[@"@"]);
                Instance(@"REMListBadge", @"initWithEmoji:", @"@", @[@"@"]);
            } else { Unsupported([@"Unknown native capability token: " stringByAppendingString:feature]); }
        }
        return @YES;
    }, error) != nil;
}
