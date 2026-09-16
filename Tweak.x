#import "YTVolumeHUD.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// YouTube Settings Headers
@interface YTSettingsCell : UITableViewCell
@end

@interface YTSettingsSectionItem : NSObject
+ (instancetype)switchItemWithTitle:(NSString *)title
                   titleDescription:(NSString *)titleDescription
            accessibilityIdentifier:(NSString *)accessibilityIdentifier
                           switchOn:(BOOL)switchOn
                        switchBlock:(BOOL (^)(YTSettingsCell *cell,
                                              BOOL enabled))switchBlock
                      settingItemId:(int)settingItemId;
@end

@interface YTSettingsViewController : UIViewController
- (void)setSectionItems:(NSMutableArray<YTSettingsSectionItem *> *)items
            forCategory:(NSUInteger)category
                  title:(NSString *)title
titleDescription:(NSString *)titleDescription
       headerHidden:(BOOL)headerHidden;
- (void)setSectionItems:(NSMutableArray<YTSettingsSectionItem *> *)items
            forCategory:(NSUInteger)category
                  title:(NSString *)title
                   icon:(id)icon
titleDescription:(NSString *)titleDescription
       headerHidden:(BOOL)headerHidden;
@end

@interface YTSettingsGroupData : NSObject
@property(nonatomic, assign) NSInteger type;
- (NSArray<NSNumber *> *)orderedCategories;
@end

@interface YTAppSettingsPresentationData : NSObject
+ (NSArray<NSNumber *> *)settingsCategoryOrder;
@end

@interface YTSettingsSectionItemManager : NSObject
- (void)updateVolumeBoostYTSectionWithEntry:(id)entry;
@end

static const NSInteger TweakSection = 'ndyt';
static NSString *const kVolumeBoostYTEnabledKey = @"VolumeBoostYTEnabled";

// Logs are written both to NSLog (visible in Flex/syslog tools) and to a small
// file that can be pulled from the injected app's environment.
static NSString *const kVolumeBoostYTLogPath = @"/tmp/VolumeBoostYT.log";

static void VolumeBoostYTLog(NSString *format, ...) {
  va_list arguments;
  va_start(arguments, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
  va_end(arguments);

  NSString *line = [NSString stringWithFormat:@"[%@] [VolumeBoostYT] %@\n",
                                              [NSDate date], message];
  NSLog(@"[VolumeBoostYT] %@", message);

  @synchronized([NSObject class]) {
    @try {
      if (![[NSFileManager defaultManager] fileExistsAtPath:kVolumeBoostYTLogPath]) {
        [[NSFileManager defaultManager] createFileAtPath:kVolumeBoostYTLogPath
                                                contents:nil
                                              attributes:nil];
      }
      NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kVolumeBoostYTLogPath];
      if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle synchronizeFile];
        [handle closeFile];
      }
    } @catch (NSException *exception) {
      NSLog(@"[VolumeBoostYT] Could not write %@: %@", kVolumeBoostYTLogPath, exception);
    }
  }
}

static BOOL IsVolumeBoostYTEnabled() {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kVolumeBoostYTEnabledKey] == nil) {
    return YES;
  }
  return [defaults boolForKey:kVolumeBoostYTEnabledKey];
}

#define ENABLE_VOLUME_PERSISTENCE 0

#if ENABLE_VOLUME_PERSISTENCE
static NSString *const kCustomYouTubeVolumeScalarKey =
    @"CustomYouTubeVolumeScalar";
#else
static float currentVolumeMultiplier = 1.0f;
#endif

static NSHashTable *activeRenderers = nil;

static void RegisterRenderer(id renderer) {
  if (!activeRenderers) {
    activeRenderers = [NSHashTable weakObjectsHashTable];
  }
  if (renderer) {
    [activeRenderers addObject:renderer];
  }
}

static float GetCustomVolumeMultiplier() {
#if ENABLE_VOLUME_PERSISTENCE
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if ([defaults objectForKey:kCustomYouTubeVolumeScalarKey] == nil) {
    return 1.0f;
  }
  return [defaults floatForKey:kCustomYouTubeVolumeScalarKey];
#else
  return currentVolumeMultiplier;
#endif
}

static float GetLogarithmicAudioMultiplier() {
  float m = GetCustomVolumeMultiplier();
  if (m <= 1.0f) {
    return m;
  }
  return powf(200.0f, (m - 1.0f) / 19.0f);
}

static void NotifyVolumeChange() {
  for (id renderer in [activeRenderers allObjects]) {
    if ([renderer respondsToSelector:@selector(setVolume:)]) {
      [renderer setVolume:1.0f];
    }
  }
}

static void SetCustomVolumeMultiplier(float multiplier) {
  if (multiplier < 0.0f)
    multiplier = 0.0f;
  if (multiplier > 20.0f)
    multiplier = 20.0f;

#if ENABLE_VOLUME_PERSISTENCE
  [[NSUserDefaults standardUserDefaults]
      setFloat:multiplier
        forKey:kCustomYouTubeVolumeScalarKey];
  [[NSUserDefaults standardUserDefaults] synchronize];
#else
  currentVolumeMultiplier = multiplier;
#endif

  NotifyVolumeChange();
}

%hook AVPlayer
- (instancetype)init {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}
- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume = volume * GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVAudioPlayerNode
- (instancetype)init {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}
- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume = volume * GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVAudioPlayer
- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)outError {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}
- (instancetype)initWithData:(NSData *)data error:(NSError **)outError {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}
- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume = volume * GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook AVSampleBufferAudioRenderer
- (instancetype)init {
  id orig = %orig;
  RegisterRenderer(orig);
  return orig;
}
- (void)setVolume:(float)volume {
  RegisterRenderer(self);
  if (IsVolumeBoostYTEnabled()) {
    volume = volume * GetLogarithmicAudioMultiplier();
  }
  %orig(volume);
}
%end

%hook IVSPlayer
- (instancetype)init {
  id orig = %orig;
  VolumeBoostYTLog(@"IVSPlayer initialized: %@", orig);
  return orig;
}
- (void)setVolume:(float)volume {
  VolumeBoostYTLog(@"Twitch IVSPlayer setVolume: %.4f (enabled=%@, multiplier=%.2f)",
                   volume,
                   IsVolumeBoostYTEnabled() ? @"YES" : @"NO",
                   GetCustomVolumeMultiplier());
  %orig(volume);
}
%end

static float gestureStartMultiplier = 1.0f;
static BOOL possibleVolumeGesture = NO;
static BOOL isTrackingVolumeGesture = NO;
static CGPoint initialTouchPoint;

%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
  if (!IsVolumeBoostYTEnabled()) {
    %orig(event);
    return;
  }

  if (self.screen != [UIScreen mainScreen]) {
    %orig(event);
    return;
  }

  NSSet<UITouch *> *touches = [event allTouches];
  if (touches.count == 0) {
    %orig(event);
    return;
  }

  UITouch *touch = [touches anyObject];
  CGPoint location = [touch locationInView:self];

  switch (touch.phase) {
  case UITouchPhaseBegan: {
    CGFloat screenWidth = self.bounds.size.width;
    if (location.x >= screenWidth - 25.0f) {
      possibleVolumeGesture = YES;
      isTrackingVolumeGesture = NO;
      initialTouchPoint = location;
      return;
    }
    break;
  }
  case UITouchPhaseMoved: {
    if (possibleVolumeGesture) {
      CGFloat dx = initialTouchPoint.x - location.x;
      CGFloat dy = fabs(location.y - initialTouchPoint.y);

      if (dx > 15.0f && dx > dy) {
        isTrackingVolumeGesture = YES;
        possibleVolumeGesture = NO;
        initialTouchPoint = location;
        gestureStartMultiplier = GetCustomVolumeMultiplier();
        [[YTVolumeHUD sharedHUD] showWithValue:gestureStartMultiplier];
        return;
      } else if (dy > 20.0f || dx < -10.0f) {
        possibleVolumeGesture = NO;
      } else {
        return;
      }
    }

    if (isTrackingVolumeGesture) {
      CGFloat translationY = location.y - initialTouchPoint.y;
      float deltaMultiplier = -translationY / 30.0f;
      float newMultiplier = gestureStartMultiplier + deltaMultiplier;

      if (newMultiplier < 0.0f)
        newMultiplier = 0.0f;
      if (newMultiplier > 20.0f)
        newMultiplier = 20.0f;

      SetCustomVolumeMultiplier(newMultiplier);
      [[YTVolumeHUD sharedHUD] showWithValue:newMultiplier];
      return;
    }
    break;
  }
  case UITouchPhaseEnded:
  case UITouchPhaseCancelled: {
    if (possibleVolumeGesture) {
      possibleVolumeGesture = NO;
      return;
    }
    if (isTrackingVolumeGesture) {
      isTrackingVolumeGesture = NO;
      [[YTVolumeHUD sharedHUD] performSelector:@selector(hide)
                                    withObject:nil
                                    afterDelay:1.0];
      return;
    }
    break;
  }
  default:
    break;
  }

  %orig(event);
}
%end

%group YouTubeSettings

%hook YTSettingsGroupData

- (NSArray<NSNumber *> *)orderedCategories {
  if (self.type != 1)
    return %orig;

  if (class_getClassMethod(objc_getClass("YTSettingsGroupData"),
                           @selector(tweaks))) {
    return %orig;
  }

  NSArray<NSNumber *> *categories = %orig;
  NSMutableArray<NSNumber *> *mutableCategories = [categories mutableCopy];
  if (mutableCategories) {
    [mutableCategories insertObject:@(TweakSection) atIndex:0];
    return [mutableCategories copy];
  }
  return categories;
}

+ (NSMutableArray<NSNumber *> *)tweaks {
  NSMutableArray<NSNumber *> *tweaks = %orig;
  if (tweaks && ![tweaks containsObject:@(TweakSection)]) {
    [tweaks addObject:@(TweakSection)];
  }
  return tweaks;
}

%end

%hook YTAppSettingsPresentationData

+ (NSArray<NSNumber *> *)settingsCategoryOrder {
  NSArray<NSNumber *> *order = %orig;
  NSUInteger insertIndex = [order indexOfObject:@(1)];

  if (insertIndex != NSNotFound) {
    NSMutableArray<NSNumber *> *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(TweakSection) atIndex:insertIndex + 1];
    return mutableOrder.copy;
  }

  return order ?: %orig;
}

%end

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)updateVolumeBoostYTSectionWithEntry:(id)entry {
  NSMutableArray<YTSettingsSectionItem *> *sectionItems =
      [NSMutableArray array];
  Class YTSettingsSectionItemClass = %c(YTSettingsSectionItem);

  if (!YTSettingsSectionItemClass)
    return;

  YTSettingsViewController *settingsViewController =
      [self valueForKey:@"_settingsViewControllerDelegate"];

  YTSettingsSectionItem *enableTweak = [YTSettingsSectionItemClass
          switchItemWithTitle:@"Enable VolumeBoostYT"
             titleDescription:@"Allow custom right-edge pan volume gesture"
         accessibilityIdentifier:nil
                     switchOn:IsVolumeBoostYTEnabled()
                  switchBlock:^BOOL(YTSettingsCell *cell, BOOL enabled) {
                    [[NSUserDefaults standardUserDefaults]
                        setBool:enabled
                         forKey:kVolumeBoostYTEnabledKey];
                    [[NSUserDefaults standardUserDefaults] synchronize];

                    if (!enabled) {
                      SetCustomVolumeMultiplier(1.0f);
                    }
                    NotifyVolumeChange();
                    return YES;
                  }
                settingItemId:0];
  [sectionItems addObject:enableTweak];

  if ([settingsViewController
          respondsToSelector:@selector
          (setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:TweakSection
                                      title:@"VolumeBoostYT"
                                       icon:nil
                           titleDescription:nil
                               headerHidden:NO];
  } else if ([settingsViewController
                 respondsToSelector:@selector
                 (setSectionItems:forCategory:title:titleDescription:headerHidden:)]) {
    [settingsViewController setSectionItems:sectionItems
                                forCategory:TweakSection
                                      title:@"VolumeBoostYT"
                           titleDescription:nil
                               headerHidden:NO];
  }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
  if (category == TweakSection) {
    [self updateVolumeBoostYTSectionWithEntry:entry];
    return;
  }
  %orig;
}

%end

%end

%ctor {
  NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
  VolumeBoostYTLog(@"Loaded in %@ (%@); IVSPlayer class=%@",
                   bundleID ?: @"<unknown>",
                   [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"<unknown>",
                   NSClassFromString(@"IVSPlayer") ? @"FOUND" : @"NOT FOUND");

  if ([bundleID isEqualToString:@"com.apple.springboard"]) {
    return;
  }

  if (NSClassFromString(@"YTSettingsGroupData")) {
    %init(YouTubeSettings);
  }

  %init;
}
