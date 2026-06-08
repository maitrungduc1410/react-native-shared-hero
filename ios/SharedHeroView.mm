#import "SharedHeroView.h"

#import <React/RCTConversions.h>

#import <react/renderer/components/SharedHeroViewSpec/ComponentDescriptors.h>
#import <react/renderer/components/SharedHeroViewSpec/EventEmitters.h>
#import <react/renderer/components/SharedHeroViewSpec/Props.h>
#import <react/renderer/components/SharedHeroViewSpec/RCTComponentViewHelpers.h>

#import "RCTFabricComponentsPlugins.h"

// Swift-generated header from the SharedHero module. Provides
// SharedHeroViewImpl and SharedHeroConfig.
#import "SharedHero-Swift.h"

using namespace facebook::react;

@interface SharedHeroView () <RCTSharedHeroViewViewProtocol>
@end

@implementation SharedHeroView {
  SharedHeroViewImpl *_impl;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<SharedHeroViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const SharedHeroViewProps>();
    _props = defaultProps;

    _impl = [[SharedHeroViewImpl alloc] init];
    // Keep contentView pinned to self.bounds so children get a usable
    // coordinate system as the view resizes.
    _impl.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    __weak SharedHeroView *weakSelf = self;
    _impl.onTransitionStart = ^(NSString *heroId, NSString *heroNamespace) {
      SharedHeroView *strongSelf = weakSelf;
      if (!strongSelf || !strongSelf->_eventEmitter) {
        return;
      }
      auto emitter = std::static_pointer_cast<const SharedHeroViewEventEmitter>(strongSelf->_eventEmitter);
      emitter->onTransitionStart({
        .id = std::string([heroId UTF8String]),
        .ns = std::string([heroNamespace UTF8String]),
      });
    };
    _impl.onTransitionEnd = ^(NSString *heroId, NSString *heroNamespace) {
      SharedHeroView *strongSelf = weakSelf;
      if (!strongSelf || !strongSelf->_eventEmitter) {
        return;
      }
      auto emitter = std::static_pointer_cast<const SharedHeroViewEventEmitter>(strongSelf->_eventEmitter);
      emitter->onTransitionEnd({
        .id = std::string([heroId UTF8String]),
        .ns = std::string([heroNamespace UTF8String]),
      });
    };

    self.contentView = _impl.contentView;
  }
  return self;
}

- (void)willMoveToWindow:(UIWindow *)newWindow
{
  [super willMoveToWindow:newWindow];
  if (newWindow == nil && self.window != nil) {
    // Snapshot the source NOW, while the view is still in a window, so the
    // registry's back-flight path doesn't lose its source if the host
    // navigator unmounts us before the destination twin re-attaches.
    [_impl prepareToLeaveWindow];
  }
}

- (void)didMoveToWindow
{
  [super didMoveToWindow];
  [_impl didMoveToWindow:self.window];
}

// Fabric's default RCTViewComponentView mounts children directly into `self`,
// which means they would NOT live inside `_impl.contentView` — and our
// `setHiddenForFlight` (which toggles `contentView.isHidden`) plus our
// `captureSnapshot` (which renders `contentView`) would both operate on an
// empty container. Routing mounts through `_impl.contentView` makes the
// React child the actual hero content, so hiding it / snapshotting it
// produces the expected result.
- (void)mountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                          index:(NSInteger)index
{
  [_impl.contentView insertSubview:childComponentView atIndex:index];
}

- (void)unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView
                            index:(NSInteger)index
{
  [childComponentView removeFromSuperview];
}

- (void)prepareForRecycle
{
  [_impl prepareForRecycle];
  [super prepareForRecycle];
}

- (void)updateLayoutMetrics:(LayoutMetrics const &)layoutMetrics
           oldLayoutMetrics:(LayoutMetrics const &)oldLayoutMetrics
{
  [super updateLayoutMetrics:layoutMetrics oldLayoutMetrics:oldLayoutMetrics];
  [_impl didUpdateLayoutMetrics];
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &newProps = *std::static_pointer_cast<SharedHeroViewProps const>(props);

  SharedHeroConfig *cfg = _impl.config;
  cfg.heroId = [NSString stringWithUTF8String:newProps.heroId.c_str()];
  cfg.heroNamespace = newProps.heroNamespace.empty()
    ? @"default"
    : [NSString stringWithUTF8String:newProps.heroNamespace.c_str()];
  cfg.mode = newProps.mode.empty()
    ? @"snapshot"
    : [NSString stringWithUTF8String:newProps.mode.c_str()];
  cfg.duration = newProps.duration > 0 ? newProps.duration : 320;
  cfg.springDamping = newProps.springDamping;
  cfg.springStiffness = newProps.springStiffness;
  cfg.springMass = newProps.springMass;
  cfg.fadeMode = newProps.fadeMode.empty()
    ? @"cross"
    : [NSString stringWithUTF8String:newProps.fadeMode.c_str()];
  cfg.easing = newProps.easing.empty()
    ? @"standard"
    : [NSString stringWithUTF8String:newProps.easing.c_str()];
  cfg.motionPath = newProps.motionPath.empty()
    ? @"linear"
    : [NSString stringWithUTF8String:newProps.motionPath.c_str()];
  cfg.enabled = newProps.enabled;
  cfg.returnFlightEnabled = newProps.returnFlightEnabled;

  [_impl didUpdateConfig];

  [super updateProps:props oldProps:oldProps];
}

@end

Class<RCTComponentViewProtocol> SharedHeroViewCls(void)
{
  return SharedHeroView.class;
}
