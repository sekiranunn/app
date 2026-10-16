//
//  HomeBars.x
//  NeoFreeBird
//


#import <string.h>
#import "HookHelpers.h"


// MARK: - Hide custom timelines

@interface BHTPinnedTimelinePresentationState : NSObject
@property (nonatomic, weak) id repository;
@property (nonatomic, weak) id account;
@property (nonatomic, copy) NSArray* models;
@end

@implementation BHTPinnedTimelinePresentationState
@end

static const void* PinnedTimelinePresentationStateKey = &PinnedTimelinePresentationStateKey;

static NSHashTable* PinnedTimelineControllers(void) {
    static NSHashTable* controllers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controllers = [NSHashTable weakObjectsHashTable];
    });
    return controllers;
}

static id PinnedTimelineCurrentAccount(void) {
    Class hostClass = objc_getClass("T1HostViewController");
    if (![hostClass respondsToSelector:@selector(sharedHostViewController)]) {
        return nil;
    }
    id host = ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(sharedHostViewController));
    return [host respondsToSelector:@selector(currentAccount)]
        ? ((id (*)(id, SEL))objc_msgSend)(host, @selector(currentAccount)) : nil;
}

// Replay the display delegate only. updatePinnedTimelines: persists to the
// server, so a visibility preference must never call it to refresh the tabs.
void applyHideCustomTimelinesSetting(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ applyHideCustomTimelinesSetting(); });
        return;
    }

    id account = PinnedTimelineCurrentAccount();
    if (!account) {
        return;
    }
    BOOL hide = [BHTSettings boolForKey:@"hide_custom_timelines"];
    NSHashTable* fetchedRepositories =
        [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (id controller in [PinnedTimelineControllers() allObjects]) {
        BHTPinnedTimelinePresentationState* state =
            objc_getAssociatedObject(controller, PinnedTimelinePresentationStateKey);
        id repository = state.repository;
        if (!repository || state.account != account || !state.models) {
            continue;
        }

        // The hook below sends the real snapshot (including an empty one) to
        // %orig, substituting an empty display list only while hiding.
        ((void (*)(id, SEL, id, NSArray*))objc_msgSend)(
            controller, @selector(pinnedTimelinesRepository:didChangeWithPinnedTimelineModels:),
            repository, state.models);

        if (!hide && ![fetchedRepositories containsObject:repository] &&
            [repository respondsToSelector:@selector(fetchPinnedTimelinesWithThrottleEnabled:)]) {
            [fetchedRepositories addObject:repository];
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                repository, @selector(fetchPinnedTimelinesWithThrottleEnabled:), NO);
        }
    }
}

// The trailing accessory is only reconfigured while the strip is showing, so a
// button built before hiding mid-session survives; sync its visibility here. The
// property is a Swift lazy var whose storage ivar KVC can't see, hence the fallback.
static void SyncHomeAddTabButton(id container, BOOL hidden) {
    UIView* button = nil;

    @try {
        button = [container valueForKey:@"addTabButton"];
    } @catch (__unused NSException* exception) {
        unsigned int ivarCount = 0;
        Ivar* ivars = class_copyIvarList([container class], &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char* name = ivar_getName(ivars[i]);
            if (name && strstr(name, "addTabButton")) {
                button = object_getIvar(container, ivars[i]);
                break;
            }
        }
        free(ivars);
    }

    if ([button isKindOfClass:[UIView class]]) {
        button.hidden = hidden;
    }
}

// The repository publishes the pinned list through this single delegate call, so
// handing it an empty array hides the tabs without touching persisted state.
%hook _TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController

- (void)pinnedTimelinesRepository:(id)repository
    didChangeWithPinnedTimelineModels:(NSArray*)models {
    if ([models isKindOfClass:[NSArray class]]) {
        BHTPinnedTimelinePresentationState* state = [BHTPinnedTimelinePresentationState new];
        state.repository = repository;
        state.account = PinnedTimelineCurrentAccount();
        state.models = models;
        objc_setAssociatedObject(self, PinnedTimelinePresentationStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [PinnedTimelineControllers() addObject:self];
    } else {
        objc_setAssociatedObject(self, PinnedTimelinePresentationStateKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [PinnedTimelineControllers() removeObject:self];
    }
    BOOL hide = [BHTSettings boolForKey:@"hide_custom_timelines"];

    %orig(repository, hide ? @[] : models);
    SyncHomeAddTabButton(self, hide);
}

- (id)tfn_navigationBarAccessoryView {
    id accessoryView = %orig;
    SyncHomeAddTabButton(self, [BHTSettings boolForKey:@"hide_custom_timelines"]);
    return accessoryView;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SyncHomeAddTabButton(self, [BHTSettings boolForKey:@"hide_custom_timelines"]);
    attachNeoFreeBirdSettingsGesture((UIViewController*)self);
}

%end

// While hiding, the overridden pinned-tabs feature switches make the app compute
// an empty pinned list; freeze writes so it can't overwrite the real tabs.
%hook _TtC32TwitterHomeFeatureImplementation31CachedPinnedTimelinesRepository

- (void)updatePinnedTimelines:(id)timelines {
    if ([BHTSettings boolForKey:@"hide_custom_timelines"]) {
        return;
    }

    %orig;
}

%end

// MARK: - Force tweet images to full frame

%hook T1StandardStatusAttachmentViewAdapter

// attachmentType 2 = photos, displayType 1 = full frame
- (NSUInteger)displayType {
    if (self.attachmentType == 2) {
        return [BHTSettings boolForKey:@"force_tweet_full_frame"] ? 1 : %orig;
    }

    return %orig;
}

%end

// MARK: - Hide the Spaces bar

// The bar is still the repurposed Fleets line; both home timeline implementations
// share this visibility gate, re-evaluated on every content or settings update.
%hook T1FleetLineHeaderController

- (BOOL)_t1_shouldShowFleetLine {
    if ([BHTSettings boolForKey:@"hide_spaces"]) {
        return NO;
    }

    return %orig;
}

%end
