#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSErrorDomain const RNErrorDomain;
typedef NS_ERROR_ENUM(RNErrorDomain, RNErrorCode) {
    RNErrorUnsupported = 1, RNErrorBackend = 2, RNErrorNotFound = 3,
    RNErrorInvalidInput = 4, RNErrorOutcomeUnknown = 5, RNErrorPermission = 6
};

/// Shared exception fence, also usable for public-framework authorization calls.
/// Returning nil without an NSError is converted to a backend failure.
FOUNDATION_EXPORT id _Nullable RNGuard(id _Nullable (^body)(void), NSError **error);
FOUNDATION_EXPORT NSInteger RNAuthorizationStatus(void);
FOUNDATION_EXPORT BOOL RNRequestAuthorization(NSError **error);
/// Closed feature names only; validates class/method ABI without opening a store.
FOUNDATION_EXPORT BOOL RNPreflight(NSArray<NSString *> *features, NSError **error);

/// All private framework objects remain inside this class. Payloads contain only
/// Foundation values; keys are an internal Native translation protocol, not CLI API.
@interface RNBridge : NSObject
+ (nullable instancetype)openWithError:(NSError **)error;
/// Foundation UUID receipt captured only from this save request's tracked changes.
@property (nonatomic, readonly, copy) NSArray<NSString *> *lastSavedReminderIDs;
/// IDs added to this request during save, excluding every preexisting tracked item.
@property (nonatomic, readonly, copy) NSArray<NSString *> *lastIntroducedReminderIDs;
- (nullable NSArray<NSDictionary<NSString *, id> *> *)listsWithError:(NSError **)error;
- (nullable NSArray<NSDictionary<NSString *, id> *> *)groupsWithError:(NSError **)error;
- (nullable NSArray<NSDictionary<NSString *, id> *> *)tagCountsWithError:(NSError **)error;
- (nullable NSString *)defaultListWithError:(NSError **)error;
- (BOOL)validateRecoveryForList:(NSString *)listID error:(NSError **)error;
- (BOOL)validateSmartListCreationWithError:(NSError **)error;
- (nullable NSArray<NSDictionary<NSString *, id> *> *)sectionsInList:(NSString *)listID error:(NSError **)error;
/// Successful miss returns NSNull; all failures return nil plus error.
- (nullable id)reminder:(NSString *)identifier concealed:(BOOL)concealed error:(NSError **)error;
- (nullable NSArray<NSDictionary<NSString *, id> *> *)remindersInList:(NSString *)listID error:(NSError **)error;
- (nullable NSArray<NSDictionary<NSString *, id> *> *)smartListsWithError:(NSError **)error;
- (nullable NSArray<NSString *> *)contentsOfSmartList:(NSString *)identifier includeCompleted:(BOOL)completed error:(NSError **)error;
- (nullable NSArray<NSDictionary<NSString *, id> *> *)templatesWithError:(NSError **)error;

- (nullable NSString *)createReminderInList:(NSString *)listID title:(NSString *)title changes:(NSDictionary *)changes error:(NSError **)error;
- (BOOL)updateReminder:(NSString *)identifier changes:(NSDictionary *)changes error:(NSError **)error;
- (BOOL)softDeleteReminders:(NSArray<NSString *> *)identifiers error:(NSError **)error;
- (BOOL)restoreReminders:(NSArray<NSString *> *)identifiers toList:(NSString *)listID error:(NSError **)error;
- (nullable NSString *)createList:(NSString *)name changes:(NSDictionary *)changes error:(NSError **)error;
- (BOOL)updateList:(NSString *)identifier changes:(NSDictionary *)changes error:(NSError **)error;
- (BOOL)deleteList:(NSString *)identifier error:(NSError **)error;
- (nullable NSString *)createGroup:(NSString *)name error:(NSError **)error;
- (BOOL)renameGroup:(NSString *)identifier name:(NSString *)name error:(NSError **)error;
- (BOOL)deleteGroup:(NSString *)identifier error:(NSError **)error;
- (nullable NSString *)createSection:(NSString *)name list:(NSString *)listID error:(NSError **)error;
- (BOOL)updateSection:(NSString *)identifier list:(NSString *)listID changes:(NSDictionary *)changes error:(NSError **)error;
- (BOOL)deleteSection:(NSString *)identifier list:(NSString *)listID error:(NSError **)error;
- (nullable NSString *)createSmartList:(NSString *)name changes:(NSDictionary *)changes error:(NSError **)error;
- (BOOL)updateSmartList:(NSString *)identifier changes:(NSDictionary *)changes error:(NSError **)error;
- (BOOL)deleteSmartList:(NSString *)identifier error:(NSError **)error;
- (nullable NSString *)createTemplate:(NSString *)name list:(NSString *)listID includeCompleted:(BOOL)completed error:(NSError **)error;
- (nullable NSString *)useTemplate:(NSString *)identifier name:(nullable NSString *)name error:(NSError **)error;
- (BOOL)deleteTemplate:(NSString *)identifier error:(NSError **)error;
- (nullable NSNumber *)replaceTag:(NSString *)name replacement:(nullable NSString *)replacement error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
