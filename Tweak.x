#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

@interface SSAuthenticationContext : NSObject
@property (nonatomic, readonly) NSString *reason;
@property (nonatomic, assign) NSInteger promptStyle;
@end

@interface AuthorizeMachineOperation : NSObject
@property (nonatomic, assign) NSInteger promptStyle;
@property (nonatomic, readonly) id requiredUniqueIdentifier;
- (id)_newAuthenticationContext;
@end

@interface AuthenticateOperation : NSObject
@property (nonatomic, readonly) SSAuthenticationContext *authenticationContext;
@property (nonatomic, assign) BOOL success;
@property (nonatomic, retain) NSError *error;
- (id)_account;
- (id)initWithAuthenticationContext:(id)context;
- (void)run;
- (void)setAuthenticateResponseWithAccount:(id)account type:(NSInteger)type;
@end

static NSMutableSet *gTrackedUniqueIdentifiers = nil;
static BOOL gIsLegacyCFVersion = NO;
static char kRefetchBypassAssociatedKey;
static BOOL HasRefetchMarkerOrTrackedUID(id obj);

%group AuthorizeMachineHook
%hook AuthorizeMachineOperation

- (id)_newAuthenticationContext {
    id context = %orig;

    NSString *reason = nil;
    if ([context respondsToSelector:@selector(reason)]) {
        reason = [((SSAuthenticationContext *)context) reason];
    }

    if ([reason isEqualToString:@"refetch"]) {
        if ([self respondsToSelector:@selector(setPromptStyle:)]) {
            [self setPromptStyle:1000];
        }

        if (!gIsLegacyCFVersion) {
            if ([self respondsToSelector:@selector(requiredUniqueIdentifier)]) {
                id uid = [self requiredUniqueIdentifier];
                if (uid != nil && gTrackedUniqueIdentifiers != nil) {
                    @synchronized (gTrackedUniqueIdentifiers) {
                        [gTrackedUniqueIdentifiers addObject:[uid description]];
                    }
                }
            }

            objc_setAssociatedObject(
                self,
                &kRefetchBypassAssociatedKey,
                @YES,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }
    }

    return context;
}

%end
%end // AuthorizeMachineHook

%group AuthenticateOperationHook
%hook AuthenticateOperation

- (id)initWithAuthenticationContext:(id)context {
    BOOL shouldMark = HasRefetchMarkerOrTrackedUID(context);
    id initializedSelf = %orig;

    if (shouldMark && initializedSelf != nil) {
        objc_setAssociatedObject(
            initializedSelf,
            &kRefetchBypassAssociatedKey,
            @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );

        id authContext = [initializedSelf authenticationContext];
        if (authContext != nil) {
            objc_setAssociatedObject(
                authContext,
                &kRefetchBypassAssociatedKey,
                @YES,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }
    }

    return initializedSelf;
}

- (void)run {
    id context = [self authenticationContext];

    NSInteger contextPromptStyle = -1;
    if (context != nil && [context respondsToSelector:@selector(promptStyle)]) {
        contextPromptStyle = [((SSAuthenticationContext *)context) promptStyle];
    }

    BOOL matched = HasRefetchMarkerOrTrackedUID(self);
    if (!matched) {
        matched = HasRefetchMarkerOrTrackedUID(context);
    }

    if (matched && contextPromptStyle == 1000) {
        id account = [self _account];
        if (account == nil) {
            [self setAuthenticateResponseWithAccount:nil type:3];
            [self setError:nil];
            [self setSuccess:YES];
            return;
        }
    }

    %orig;
}

%end
%end // AuthenticateOperationHook

static BOOL HasRefetchMarkerOrTrackedUID(id obj) {
    if (obj == nil) {
        return NO;
    }

    NSNumber *markedFlag = objc_getAssociatedObject(obj, &kRefetchBypassAssociatedKey);
    if ([markedFlag boolValue]) {
        return YES;
    }

    if (![obj respondsToSelector:@selector(promptStyle)]) {
        return NO;
    }

    NSInteger promptStyle = [((AuthorizeMachineOperation *)obj) promptStyle];
    if (promptStyle != 1000) {
        return NO;
    }

    if (![obj respondsToSelector:@selector(requiredUniqueIdentifier)]) {
        return NO;
    }

    id uid = [((AuthorizeMachineOperation *)obj) requiredUniqueIdentifier];
    if (uid == nil) {
        return NO;
    }

    BOOL isTracked = NO;
    if (gTrackedUniqueIdentifiers != nil) {
        @synchronized (gTrackedUniqueIdentifiers) {
            isTracked = [gTrackedUniqueIdentifiers containsObject:[uid description]];
        }
    }

    return isTracked;
}

%ctor {
    @autoreleasepool {
        gIsLegacyCFVersion = (kCFCoreFoundationVersionNumber <= 793.0);

        if (!gIsLegacyCFVersion) {
            gTrackedUniqueIdentifiers = [[NSMutableSet alloc] init];
        }

        Class authMachineCls = objc_getClass("AuthorizeMachineOperation");
        if (authMachineCls != Nil &&
            class_getInstanceMethod(authMachineCls, @selector(_newAuthenticationContext)) != NULL) {
            %init(AuthorizeMachineHook);
        }

        if (!gIsLegacyCFVersion) {
            Class authOpCls = objc_getClass("AuthenticateOperation");
            if (authOpCls != Nil &&
                class_getInstanceMethod(authOpCls, @selector(_account)) != NULL &&
                class_getInstanceMethod(authOpCls, @selector(initWithAuthenticationContext:)) != NULL &&
                class_getInstanceMethod(authOpCls, @selector(run)) != NULL) {
                %init(AuthenticateOperationHook);
            }
        }
    }
}
