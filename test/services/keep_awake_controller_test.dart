import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/keep_awake_controller.dart';

/// The keep-awake rule and its wiring. No wakelock plugin exists under test,
/// so every push fails with MissingPluginException; the controller must
/// swallow that and still track the state it asked for.

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void set(Map<String, SessionState> sessions) => state = sessions;
}

const _connected = SessionState(status: SessionStatus.connected);
const _connecting = SessionState(status: SessionStatus.connecting);
const _disconnected = SessionState(status: SessionStatus.disconnected);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rule: held only when the setting is on and a session is connected',
      () {
    expect(KeepAwakeController.shouldHold(true, {'a': _connected}), isTrue);
    expect(
      KeepAwakeController.shouldHold(true, {'a': _connecting, 'b': _connected}),
      isTrue,
    );
    expect(KeepAwakeController.shouldHold(false, {'a': _connected}), isFalse);
    expect(KeepAwakeController.shouldHold(true, {'a': _connecting}), isFalse);
    expect(KeepAwakeController.shouldHold(true, {'a': _disconnected}), isFalse);
    expect(KeepAwakeController.shouldHold(true, {}), isFalse);
  });

  test('controller follows the setting and the session map', () async {
    final container = ProviderContainer(overrides: [
      keepScreenAwakeProvider.overrideWith((ref) => true),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(container.dispose);

    final controller = container.read(keepAwakeControllerProvider);
    final sessions =
        container.read(activeSessionsProvider.notifier) as _Sessions;
    expect(controller.isHeld, isFalse, reason: 'no session yet');

    sessions.set({'a': _connecting});
    expect(controller.isHeld, isFalse, reason: 'connecting does not count');

    sessions.set({'a': _connected});
    expect(controller.isHeld, isTrue);

    container.read(keepScreenAwakeProvider.notifier).state = false;
    expect(controller.isHeld, isFalse, reason: 'setting off releases');

    container.read(keepScreenAwakeProvider.notifier).state = true;
    expect(controller.isHeld, isTrue);

    sessions.set({'a': _disconnected});
    expect(controller.isHeld, isFalse, reason: 'last session ended');

    // Let the failed plugin pushes settle so nothing throws after the test.
    await Future<void>.delayed(Duration.zero);
  });
}
