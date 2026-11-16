//
//  GooglePhotosCloudViewer.mm
//  Google Photos iOS Cloud-Only Fast-Load Tweak / Dylib
//
//  Purpose:
//  Allows Google Photos iOS to function as a fast remote cloud viewer
//  when iOS Photo Library permissions are intentionally denied/withheld.
//  - Unblocks Onboarding deadlock after tapping "Continue without backup".
//  - Unblocks Envelope (Album) Sync from being held hostage by PreInitialSync.
//  - Prevents Local Deduplication Promise from stalling thumbnail rendering.
//  - Instantly populates Android-synced cloud albums in Collections & Albums views.
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define LOG(fmt, ...) NSLog(@"[GooglePhotosCloudViewer] " fmt, ##__VA_ARGS__)

#pragma mark - Swizzle Helper

static void SwizzleInstanceMethod(Class cls, SEL sel, IMP newImp, IMP *origImp) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        if (origImp) {
            *origImp = method_getImplementation(m);
        }
        method_setImplementation(m, newImp);
        LOG("Successfully hooked -[%s %s]", class_getName(cls), sel_getName(sel));
    } else {
        LOG("Method -[%s %s] not found", class_getName(cls), sel_getName(sel));
    }
}

#pragma mark - Hook: PHSRootViewController & Onboarding Dismissal Unblocking

static BOOL g_forceOOBFinished = NO;

static BOOL (*orig_root_displayingOOB)(id self, SEL _cmd);
static BOOL hook_root_displayingOOB(id self, SEL _cmd) {
    if (g_forceOOBFinished) {
        return NO;
    }
    if (orig_root_displayingOOB) {
        return orig_root_displayingOOB(self, _cmd);
    }
    return NO;
}

static void (*orig_root_checkAndRequestPhotoLibraryAccessIfNeeded)(id self, SEL _cmd);
static void hook_root_checkAndRequestPhotoLibraryAccessIfNeeded(id self, SEL _cmd) {
    LOG("Suppressed checkAndRequestPhotoLibraryAccessIfNeeded (running in cloud viewer mode)");
    // No-op: do not prompt or wait for Apple Photo Library permissions
}

static void (*orig_enableAutoBackup_rejectAutoBackupAndDismiss)(id self, SEL _cmd);
static void hook_enableAutoBackup_rejectAutoBackupAndDismiss(id self, SEL _cmd) {
    LOG("rejectAutoBackupAndDismiss intercepted (User tapped 'Continue without backup')");
    g_forceOOBFinished = YES;

    if (orig_enableAutoBackup_rejectAutoBackupAndDismiss) {
        orig_enableAutoBackup_rejectAutoBackupAndDismiss(self, _cmd);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                    window = ((UIWindowScene *)scene).windows.firstObject;
                    if (window) break;
                }
            }
        }
        if (!window) {
            window = [UIApplication sharedApplication].keyWindow;
        }

        UIViewController *rootVC = window.rootViewController;
        if (rootVC && [rootVC isKindOfClass:NSClassFromString(@"PHSRootViewController")]) {
            LOG("Transitioning PHSRootViewController to main tab bar post-dismissal...");
            SEL compSel = NSSelectorFromString(@"onboardingDidCompleteWithState:postOnboardingBehavior:");
            if ([rootVC respondsToSelector:compSel]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(rootVC, compSel, nil, nil);
            }

            SEL setupSel = NSSelectorFromString(@"setupTabBarControllerWithAccount:destination:");
            if ([rootVC respondsToSelector:setupSel]) {
                id account = nil;
                @try {
                    account = [rootVC valueForKey:@"viewingAccount"];
                } @catch (NSException *e) {}
                if (account) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(rootVC, setupSel, account, nil);
                }
            }
        }
    });
}

#pragma mark - Hook: PHSExtendedCollectionStore (Envelope Sync Unblocking)

static id (*orig_store_initWithStoreHelper_serverPhotosPartiallyRestored)(id self, SEL _cmd, id helper, BOOL restored);
static id hook_store_initWithStoreHelper_serverPhotosPartiallyRestored(id self, SEL _cmd, id helper, BOOL restored) {
    id instance = orig_store_initWithStoreHelper_serverPhotosPartiallyRestored(self, _cmd, helper, restored);
    if (instance) {
        LOG("PHSExtendedCollectionStore initialized. Kicking off immediate envelope sync...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            SEL syncSel = NSSelectorFromString(@"startEnvelopeSyncAfterPreInitialSyncComplete:");
            if ([instance respondsToSelector:syncSel]) {
                LOG("Calling startEnvelopeSyncAfterPreInitialSyncComplete:YES");
                ((void (*)(id, SEL, BOOL))objc_msgSend)(instance, syncSel, YES);
            }
            SEL reasonSel = NSSelectorFromString(@"startSyncWithReason:");
            if ([instance respondsToSelector:reasonSel]) {
                LOG("Calling startSyncWithReason:CloudViewerStart");
                ((void (*)(id, SEL, id))objc_msgSend)(instance, reasonSel, @"CloudViewerStart");
            }
        });
    }
    return instance;
}

static id (*orig_store_initWithStoreHelper_serverPhotosPartiallyRestored_skipSchemaUpdates)(id self, SEL _cmd, id helper, BOOL restored, BOOL skip);
static id hook_store_initWithStoreHelper_serverPhotosPartiallyRestored_skipSchemaUpdates(id self, SEL _cmd, id helper, BOOL restored, BOOL skip) {
    id instance = orig_store_initWithStoreHelper_serverPhotosPartiallyRestored_skipSchemaUpdates(self, _cmd, helper, restored, skip);
    if (instance) {
        LOG("PHSExtendedCollectionStore (skipSchemaUpdates) initialized. Kicking off immediate envelope sync...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            SEL syncSel = NSSelectorFromString(@"startEnvelopeSyncAfterPreInitialSyncComplete:");
            if ([instance respondsToSelector:syncSel]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(instance, syncSel, YES);
            }
        });
    }
    return instance;
}

static void (*orig_store_startEnvelopeSyncAfterPreInitialSyncComplete)(id self, SEL _cmd, BOOL complete);
static void hook_store_startEnvelopeSyncAfterPreInitialSyncComplete(id self, SEL _cmd, BOOL complete) {
    LOG("Intercepted startEnvelopeSyncAfterPreInitialSyncComplete: (input was %d, enforcing YES)", complete);
    orig_store_startEnvelopeSyncAfterPreInitialSyncComplete(self, _cmd, YES);
}

#pragma mark - Hook: Initial Sync State Flags

static BOOL (*orig_extendedSync_initialSyncComplete)(id self, SEL _cmd);
static BOOL hook_extendedSync_initialSyncComplete(id self, SEL _cmd) {
    return YES;
}

static BOOL (*orig_userItems_hasInitialSyncCompleted)(id self, SEL _cmd);
static BOOL hook_userItems_hasInitialSyncCompleted(id self, SEL _cmd) {
    return YES;
}

static BOOL (*orig_settings_hasInitialSyncCompleted)(id self, SEL _cmd);
static BOOL hook_settings_hasInitialSyncCompleted(id self, SEL _cmd) {
    return YES;
}

static BOOL (*orig_settings_initialSyncComplete)(id self, SEL _cmd);
static BOOL hook_settings_initialSyncComplete(id self, SEL _cmd) {
    return YES;
}

#pragma mark - Hook: Local Deduplication Promise (Instant Thumbnail Loading)

static id (*orig_userItems_localDedupPromise)(id self, SEL _cmd);
static id hook_userItems_localDedupPromise(id self, SEL _cmd) {
    Class promiseCls = NSClassFromString(@"GPCPromise");
    if (promiseCls && [promiseCls respondsToSelector:@selector(resolvedPromiseWithValue:)]) {
        LOG("Returning immediately resolved empty dedup promise to prevent thumbnail stall");
        return [promiseCls performSelector:@selector(resolvedPromiseWithValue:) withObject:@{}];
    }
    if (orig_userItems_localDedupPromise) {
        return orig_userItems_localDedupPromise(self, _cmd);
    }
    return nil;
}

static id (*orig_userItems_localDedupKeysCompletePromiseAtomic)(id self, SEL _cmd);
static id hook_userItems_localDedupKeysCompletePromiseAtomic(id self, SEL _cmd) {
    Class promiseCls = NSClassFromString(@"GPCPromise");
    if (promiseCls && [promiseCls respondsToSelector:@selector(resolvedPromiseWithValue:)]) {
        return [promiseCls performSelector:@selector(resolvedPromiseWithValue:) withObject:@{}];
    }
    if (orig_userItems_localDedupKeysCompletePromiseAtomic) {
        return orig_userItems_localDedupKeysCompletePromiseAtomic(self, _cmd);
    }
    return nil;
}

#pragma mark - Entry Point Constructor

__attribute__((constructor))
static void initGooglePhotosCloudViewer(void) {
    @autoreleasepool {
        LOG("Initializing GooglePhotosCloudViewer dylib patch...");

        // 0. Hook Onboarding & Root Navigation to prevent freeze after 'Continue without backup'
        Class autoBackupVCCls = NSClassFromString(@"PHSEnableAutoBackupViewControllerV2");
        if (!autoBackupVCCls) {
            autoBackupVCCls = NSClassFromString(@"PHSEnableAutoBackupViewController");
        }
        if (autoBackupVCCls) {
            SwizzleInstanceMethod(autoBackupVCCls,
                                  NSSelectorFromString(@"rejectAutoBackupAndDismiss"),
                                  (IMP)hook_enableAutoBackup_rejectAutoBackupAndDismiss,
                                  (IMP *)&orig_enableAutoBackup_rejectAutoBackupAndDismiss);
        }

        Class rootVCCls = NSClassFromString(@"PHSRootViewController");
        if (rootVCCls) {
            SwizzleInstanceMethod(rootVCCls,
                                  NSSelectorFromString(@"displayingOOB"),
                                  (IMP)hook_root_displayingOOB,
                                  (IMP *)&orig_root_displayingOOB);

            SwizzleInstanceMethod(rootVCCls,
                                  NSSelectorFromString(@"checkAndRequestPhotoLibraryAccessIfNeeded"),
                                  (IMP)hook_root_checkAndRequestPhotoLibraryAccessIfNeeded,
                                  (IMP *)&orig_root_checkAndRequestPhotoLibraryAccessIfNeeded);
        }

        // 1. Hook PHSExtendedCollectionStore
        Class storeCls = NSClassFromString(@"PHSExtendedCollectionStore");
        if (storeCls) {
            SwizzleInstanceMethod(storeCls,
                                  NSSelectorFromString(@"initWithStoreHelper:serverPhotosPartiallyRestored:"),
                                  (IMP)hook_store_initWithStoreHelper_serverPhotosPartiallyRestored,
                                  (IMP *)&orig_store_initWithStoreHelper_serverPhotosPartiallyRestored);

            SwizzleInstanceMethod(storeCls,
                                  NSSelectorFromString(@"initWithStoreHelper:serverPhotosPartiallyRestored:skipSchemaUpdates:"),
                                  (IMP)hook_store_initWithStoreHelper_serverPhotosPartiallyRestored_skipSchemaUpdates,
                                  (IMP *)&orig_store_initWithStoreHelper_serverPhotosPartiallyRestored_skipSchemaUpdates);

            SwizzleInstanceMethod(storeCls,
                                  NSSelectorFromString(@"startEnvelopeSyncAfterPreInitialSyncComplete:"),
                                  (IMP)hook_store_startEnvelopeSyncAfterPreInitialSyncComplete,
                                  (IMP *)&orig_store_startEnvelopeSyncAfterPreInitialSyncComplete);
        } else {
            LOG("WARNING: PHSExtendedCollectionStore class not found yet");
        }

        // 2. Hook PHSExtendedCollectionSynchronizer
        Class extSyncCls = NSClassFromString(@"PHSExtendedCollectionSynchronizer");
        if (extSyncCls) {
            SwizzleInstanceMethod(extSyncCls,
                                  NSSelectorFromString(@"initialSyncComplete"),
                                  (IMP)hook_extendedSync_initialSyncComplete,
                                  (IMP *)&orig_extendedSync_initialSyncComplete);
        }

        // 3. Hook PHSUserItemsSynchronizer
        Class userItemsCls = NSClassFromString(@"PHSUserItemsSynchronizer");
        if (userItemsCls) {
            SwizzleInstanceMethod(userItemsCls,
                                  NSSelectorFromString(@"hasInitialSyncCompleted"),
                                  (IMP)hook_userItems_hasInitialSyncCompleted,
                                  (IMP *)&orig_userItems_hasInitialSyncCompleted);

            SwizzleInstanceMethod(userItemsCls,
                                  NSSelectorFromString(@"localDedupKeysCompletePromise"),
                                  (IMP)hook_userItems_localDedupPromise,
                                  (IMP *)&orig_userItems_localDedupPromise);

            SwizzleInstanceMethod(userItemsCls,
                                  NSSelectorFromString(@"localDedupKeysCompletePromiseAtomic"),
                                  (IMP)hook_userItems_localDedupKeysCompletePromiseAtomic,
                                  (IMP *)&orig_userItems_localDedupKeysCompletePromiseAtomic);
        }

        // 4. Hook PHSUserSettingsImpl / PHSUserSettings
        Class settingsCls = NSClassFromString(@"PHSUserSettingsImpl");
        if (settingsCls) {
            SwizzleInstanceMethod(settingsCls,
                                  NSSelectorFromString(@"hasInitialSyncCompleted"),
                                  (IMP)hook_settings_hasInitialSyncCompleted,
                                  (IMP *)&orig_settings_hasInitialSyncCompleted);

            SwizzleInstanceMethod(settingsCls,
                                  NSSelectorFromString(@"initialSyncComplete"),
                                  (IMP)hook_settings_initialSyncComplete,
                                  (IMP *)&orig_settings_initialSyncComplete);
        }

        LOG("GooglePhotosCloudViewer initialization complete.");
    }
}
