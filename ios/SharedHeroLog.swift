import os

/// Diagnostic logging for the shared-hero subsystem.
///
/// We use `os.Logger` rather than `NSLog` because `NSLog` is *not* stripped in
/// release builds — it would spam end-users' system logs in production. The
/// `heroLog` wrapper below compiles the call (and the message construction)
/// out entirely outside of DEBUG, so traces cost nothing when shipping.
///
/// Each value pairs an `os.Logger` (so logs are filterable by subsystem +
/// category in Console.app) with a short `tag` that `heroLog` prepends to the
/// message, restoring the inline `[SharedHeroXxx]` prefix that Xcode's plain
/// console shows at a glance.
struct HeroLog {
  fileprivate let logger: Logger
  fileprivate let tag: String

  private init(category: String, tag: String) {
    self.logger = Logger(subsystem: "com.sharedhero", category: category)
    self.tag = tag
  }

  static let interactive = HeroLog(category: "interactive", tag: "SharedHeroInteractive")
  static let stackPop = HeroLog(category: "stackPop", tag: "SharedHeroStackPop")
  static let registry = HeroLog(category: "registry", tag: "SharedHeroRegistry")
  static let impl = HeroLog(category: "impl", tag: "SharedHeroImpl")
  static let chain = HeroLog(category: "chain", tag: "SharedHeroChain")
  static let overlay = HeroLog(category: "overlay", tag: "SharedHeroOverlay")
  static let flight = HeroLog(category: "flight", tag: "SharedHeroFlight")
}

/// `@autoclosure` + `#if DEBUG` means the interpolated message is never even
/// built in release — the whole call disappears. `privacy: .public` keeps the
/// interpolated values readable in Console/Xcode during development (os.Logger
/// otherwise redacts dynamic values as `<private>`).
@inline(__always)
func heroLog(_ log: HeroLog, _ message: @autoclosure () -> String) {
  #if DEBUG
  // Build the full string first: the os.Logger interpolation captures its
  // argument in an *escaping* context, which a non-escaping autoclosure
  // parameter can't be passed into directly.
  let text = "[\(log.tag)] " + message()
  log.logger.debug("\(text, privacy: .public)")
  #endif
}
