import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/utils/logger.dart';

/// Holds the OS screen wakelock while a terminal session is live.
///
/// The rule: the wakelock is held exactly while the "Keep Screen Awake"
/// setting ([keepScreenAwakeProvider]) is on AND at least one session in
/// [activeSessionsProvider] is [SessionStatus.connected]. It is released as
/// soon as either side stops being true (the setting is switched off, or the
/// last connected session ends), so an idle app never stops the screen from
/// dimming. Connecting, reconnecting and errored sessions do not count.
///
/// One instance lives for the whole app: the provider is never disposed and
/// the root widget reads it once at startup, which wires the two listeners.
/// Nothing is gated by platform; wakelock_plus supports all five.
final keepAwakeControllerProvider = Provider<KeepAwakeController>((ref) {
  final controller = KeepAwakeController();
  ref.onDispose(controller.dispose);

  void apply() {
    controller.setShouldHold(KeepAwakeController.shouldHold(
      ref.read(keepScreenAwakeProvider),
      ref.read(activeSessionsProvider),
    ));
  }

  ref.listen<bool>(keepScreenAwakeProvider, (_, _) => apply());
  ref.listen<Map<String, SessionState>>(
    activeSessionsProvider,
    (_, _) => apply(),
  );
  apply();
  return controller;
});

/// Pushes the keep-awake rule to the platform wakelock. See
/// [keepAwakeControllerProvider] for the rule itself.
class KeepAwakeController {
  /// The pure rule, kept separate so it is testable without a plugin.
  static bool shouldHold(bool keepAwake, Map<String, SessionState> sessions) =>
      keepAwake &&
      sessions.values.any((s) => s.status == SessionStatus.connected);

  bool _held = false;

  /// Whether the controller is currently asking the OS to keep the screen on.
  bool get isHeld => _held;

  /// Applies [hold]; the plugin is only called on an actual transition.
  void setShouldHold(bool hold) {
    if (hold == _held) return;
    _held = hold;
    _push(hold);
  }

  /// Every plugin call is wrapped: a missing platform implementation (widget
  /// tests, an unsupported build) must never throw into the provider graph.
  Future<void> _push(bool hold) async {
    try {
      await WakelockPlus.toggle(enable: hold);
    } catch (e) {
      AppLogger.warning(
        'Keep screen awake: could not ${hold ? 'hold' : 'release'} '
        'the wakelock: $e',
      );
    }
  }

  void dispose() {
    setShouldHold(false);
  }
}
