import Cocoa
import FlutterMacOS

/// Relative mouse on a remote screen (4.0), the Mac's part, on the
/// channel zestssh/pointer_capture and its events
/// (lib/features/screens/view/screen_pointer_hold.dart), as
/// windows/runner/pointer_hold.cpp is on Windows.
///
/// For a game or a 3D program on a remote screen the Mac's pointer is held:
/// it stays where it is (the mouse is taken off it) and is hidden, and what
/// the mouse does is read as movement and handed to the app, which sends it
/// to the remote. Its buttons go on reaching the picture under it.
///
/// A held pointer is a pointer the person cannot use, so the way out comes
/// first. It lets go by itself, without the app asking, when:
///  - the window is no longer the key window, the app is no longer in front,
///    the window closes, is minimised or resized, the displays change, the
///    Space changes, or another person's session takes the screen;
///  - the app has not said it is still there ("renew") for two seconds. That
///    is watched on a queue of its own, since an app that says nothing is
///    most often an app whose main thread is stuck: the watch puts the mouse
///    back on the pointer and shows it, and the rest (the app told) happens
///    when the main thread is back.
///
/// The movement is the system's own (NSEvent's deltas), so it carries the
/// Mac's pointer acceleration. Not tried on a Mac yet when this was written.
final class PointerCaptureChannel: NSObject, FlutterStreamHandler {
  static let name = "zestssh/pointer_capture"
  static let eventsName = "zestssh/pointer_capture/events"

  /// The app must renew this often, or the pointer is freed.
  private static let renewWithin: TimeInterval = 2
  /// Movement is handed on at most this often; what is left when the mouse
  /// stops goes with the timer.
  private static let sendEvery: TimeInterval = 0.004
  private static let flushEvery: TimeInterval = 0.010
  /// The most that waits to be handed on.
  private static let mostWaiting: Double = 16_777_216

  private let window: () -> NSWindow?
  private var methods: FlutterMethodChannel?
  private var events: FlutterEventChannel?
  private var sink: FlutterEventSink?

  // The main thread only.
  private var held = false
  private var monitor: Any?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var flushTimer: Timer?
  private var dx = 0.0
  private var dy = 0.0
  private var lastSent: TimeInterval = 0
  private var tookMouseMoves = false

  // The watch: these three behind the lock.
  private let lock = NSLock()
  private var watched = false
  private var lastRenew: TimeInterval = 0
  private var freed = false
  private var watch: DispatchSourceTimer?

  init(messenger: FlutterBinaryMessenger, window: @escaping () -> NSWindow?) {
    self.window = window
    super.init()
    let methods = FlutterMethodChannel(name: Self.name, binaryMessenger: messenger)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "available":
        result(true)
      case "start":
        result(self.start())
      case "stop":
        self.letGo(byItself: false)
        result(nil)
      case "renew":
        self.renew()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.methods = methods
    let events = FlutterEventChannel(name: Self.eventsName, binaryMessenger: messenger)
    events.setStreamHandler(self)
    self.events = events
  }

  deinit {
    watch?.cancel()
  }

  // MARK: The events

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    // Nobody listens any more (the app let go, or its code started over): a
    // pointer nobody listens to is not held.
    letGo(byItself: false)
    sink = nil
    return nil
  }

  // MARK: Holding

  private static func now() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }

  private func inFront(_ window: NSWindow) -> Bool {
    NSApp.isActive && window.isKeyWindow && !window.isMiniaturized
  }

  private func start() -> Bool {
    if held {
      return true
    }
    guard let window = window(), inFront(window), let view = window.contentView else {
      return false
    }
    // Only a pointer that is over the window: its buttons must go on
    // reaching the picture.
    let at = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    guard view.bounds.contains(at) else {
      return false
    }
    // The mouse off the pointer: the pointer stays where it is, and the
    // mouse's movement still comes as events.
    guard CGAssociateMouseAndMouseCursorPosition(0) == .success else {
      return false
    }
    guard CGDisplayHideCursor(CGMainDisplayID()) == .success else {
      _ = CGAssociateMouseAndMouseCursorPosition(1)
      return false
    }
    held = true
    dx = 0
    dy = 0
    lastSent = Self.now()
    if !window.acceptsMouseMovedEvents {
      window.acceptsMouseMovedEvents = true
      tookMouseMoves = true
    }

    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    ) { [weak self] event in
      self?.moved(Double(event.deltaX), Double(event.deltaY))
      return event
    }

    let timer = Timer(timeInterval: Self.flushEvery, repeats: true) { [weak self] _ in
      self?.flush()
    }
    RunLoop.main.add(timer, forMode: .common)
    flushTimer = timer

    let center = NotificationCenter.default
    let workspace = NSWorkspace.shared.notificationCenter
    let ways: [(NotificationCenter, Notification.Name, Any?)] = [
      (center, NSWindow.didResignKeyNotification, window),
      (center, NSWindow.willCloseNotification, window),
      (center, NSWindow.willMiniaturizeNotification, window),
      (center, NSWindow.willStartLiveResizeNotification, window),
      (center, NSApplication.didResignActiveNotification, nil),
      (center, NSApplication.didChangeScreenParametersNotification, nil),
      (workspace, NSWorkspace.activeSpaceDidChangeNotification, nil),
      (workspace, NSWorkspace.sessionDidResignActiveNotification, nil),
    ]
    for (source, name, object) in ways {
      let observer = source.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        self?.letGo(byItself: true)
      }
      observers.append((source, observer))
    }

    lock.lock()
    watched = true
    freed = false
    lastRenew = Self.now()
    lock.unlock()
    startWatch()
    return true
  }

  private func renew() {
    guard held else {
      return
    }
    guard let window = window(), inFront(window) else {
      letGo(byItself: true)
      return
    }
    lock.lock()
    let wasFreed = freed
    if !wasFreed {
      lastRenew = Self.now()
    }
    lock.unlock()
    if wasFreed {
      // Too late: the watch freed the pointer. The rest is done here.
      letGo(byItself: true)
    }
  }

  private func letGo(byItself: Bool) {
    guard held else {
      return
    }
    held = false
    lock.lock()
    watched = false
    let wasFreed = freed
    freed = false
    lock.unlock()

    if let monitor = monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
    flushTimer?.invalidate()
    flushTimer = nil
    for (source, observer) in observers {
      source.removeObserver(observer)
    }
    observers = []
    if !wasFreed {
      // The watch did these already where it freed the pointer; shown and
      // hidden are counted, so not a second time.
      _ = CGAssociateMouseAndMouseCursorPosition(1)
      _ = CGDisplayShowCursor(CGMainDisplayID())
    }
    if tookMouseMoves {
      window()?.acceptsMouseMovedEvents = false
      tookMouseMoves = false
    }
    dx = 0
    dy = 0
    if byItself {
      sink?("lost")
    }
  }

  // MARK: Movement

  private func moved(_ byX: Double, _ byY: Double) {
    guard held, byX.isFinite, byY.isFinite else {
      return
    }
    dx = min(max(dx + byX, -Self.mostWaiting), Self.mostWaiting)
    dy = min(max(dy + byY, -Self.mostWaiting), Self.mostWaiting)
    if Self.now() - lastSent >= Self.sendEvery {
      flush()
    }
  }

  private func flush() {
    guard held else {
      return
    }
    // Whole counts go; the part of a count that is left waits for the next.
    let wholeX = dx.rounded(.towardZero)
    let wholeY = dy.rounded(.towardZero)
    if wholeX == 0 && wholeY == 0 {
      return
    }
    dx -= wholeX
    dy -= wholeY
    lastSent = Self.now()
    sink?([Int(wholeX), Int(wholeY)])
  }

  // MARK: The watch

  private func startWatch() {
    if watch != nil {
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
    timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
    timer.setEventHandler { [weak self] in
      guard let self = self else {
        return
      }
      self.lock.lock()
      let expired = self.watched && !self.freed && Self.now() - self.lastRenew > Self.renewWithin
      if expired {
        self.freed = true
      }
      self.lock.unlock()
      guard expired else {
        return
      }
      // The app said nothing for too long. The pointer is the person's again
      // now, whatever the main thread is doing; the rest is for when that
      // thread is back.
      _ = CGAssociateMouseAndMouseCursorPosition(1)
      _ = CGDisplayShowCursor(CGMainDisplayID())
      DispatchQueue.main.async { [weak self] in
        guard let self = self else {
          return
        }
        self.lock.lock()
        let still = self.freed
        self.lock.unlock()
        // A hold that ended meanwhile, or a new one: nothing to do.
        if still {
          self.letGo(byItself: true)
        }
      }
    }
    timer.resume()
    watch = timer
  }
}
