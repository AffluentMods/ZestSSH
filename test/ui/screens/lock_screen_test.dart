import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart' show BiometricType;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/ui/screens/security/security_lock_screen.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// A lock whose PIN is 1234, whose wrong PINs are counted as the real one counts
/// them (a wait from the tenth), whose wait the test counts down itself, and whose
/// system prompt stays up until the test answers it.
class _Lock implements SecurityLockService {
  _Lock({this.method = SecurityLockMethod.pin});

  SecurityLockMethod method;
  int failed = 0;
  int waitLeft = 0;
  final tried = <String>[];
  final prompts = <Completer<BiometricAuthOutcome>>[];

  @override
  bool get isLockedOut => waitLeft > 0;
  @override
  int get remainingLockoutSeconds => waitLeft;
  @override
  int get failedAttempts => failed;
  @override
  int get maxAttempts => 10;
  @override
  Future<bool> verifyPin(String pin) async {
    tried.add(pin);
    if (waitLeft > 0) return false;
    if (pin == '1234') {
      failed = 0;
      return true;
    }
    failed++;
    waitLeft = SecurityLockService.waitAfter(failed);
    return false;
  }

  @override
  Future<SecurityLockMethod> getLockMethod() async => method;
  @override
  Future<bool> hasPinConfigured() async => true;
  @override
  Future<bool> isBiometricAvailable() async => true;
  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => const [BiometricType.face];
  @override
  Future<BiometricAuthOutcome> authenticateWithBiometric({String? reason}) {
    final prompt = Completer<BiometricAuthOutcome>();
    prompts.add(prompt);
    return prompt.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vault implements VaultSlotService {
  @override
  Future<bool> isEnabled() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The app's lock, locked for [reason].
class _Locked extends AppLockNotifier {
  _Locked(super.ref, this.reason);

  final AppLockReason reason;

  @override
  AppLockReason get why => reason;
}

/// Sessions, some connected.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref, Map<String, SessionState> sessions) {
    state = sessions;
  }
}

/// The 4.0 lock screen's flows: one PIN
/// box with its arrow, why it locked, the tries left before the wait and the wait
/// itself, the system's unlock (a button on a computer that never opens by itself;
/// on a phone the prompt opens by itself, with a key on the app's own number pad),
/// the encrypting lock's line, the keyboard on a computer, the sessions line, and
/// what a screen reader and a phone's haptics are told.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final said = <String>[];
  final buzzes = <String>[];

  setUp(() {
    said.clear();
    buzzes.clear();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (message) async {
      final m = message as Map;
      if (m['type'] == 'announce') said.add((m['data'] as Map)['message'] as String);
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') buzzes.add(call.arguments as String);
      return null;
    });
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    debugTouchLayout = null;
    debugDefaultTargetPlatformOverride = null;
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    _Lock lock, {
    Size size = const Size(1200, 800),
    FakeViewPadding padding = FakeViewPadding.zero,
    Map<String, Object> prefs = const {},
    AppLockReason? reason,
    Map<String, SessionState>? sessions,
    bool still = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'security_lock_enabled': true, ...prefs});
    FlutterSecureStorage.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(p),
      securityLockServiceProvider.overrideWithValue(lock),
      vaultSlotServiceProvider.overrideWithValue(_Vault()),
      if (reason != null) isAppLockedProvider.overrideWith((ref) => _Locked(ref, reason)),
      if (sessions != null) activeSessionsProvider.overrideWith((ref) => _Sessions(ref, sessions)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: still),
            child: const SecurityLockScreen(),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    return container;
  }

  Future<void> takeDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  String? line(WidgetTester tester) {
    final found = find.byKey(const ValueKey('lock-message'));
    return found.evaluate().isEmpty ? null : tester.widget<Text>(found).data;
  }

  Future<void> submit(WidgetTester tester, String pin) async {
    await tester.enterText(find.byType(TextField), pin);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();
  }

  /// The system's prompt answers, and what it changed is drawn.
  Future<void> answer(WidgetTester tester, Completer<BiometricAuthOutcome> prompt, BiometricAuthOutcome outcome) async {
    prompt.complete(outcome);
    await tester.pump();
    await tester.pump();
  }

  double shakeOffset(WidgetTester tester) {
    final box = find.byKey(const ValueKey('lock-pin-box'));
    final shake = find.descendant(of: box, matching: find.byType(Transform)).first;
    return tester.widget<Transform>(shake).transform.getTranslation().x;
  }

  group('a computer', () {
    testWidgets('the mark, "ZestSSH is locked", why, and one PIN box: a right PIN and Enter unlock', (tester) async {
      final lock = _Lock();
      final c = await pump(tester, lock);
      expect(find.text(l10n.lockTitle), findsOneWidget);
      expect(find.text(l10n.lockReasonStarted), findsOneWidget);
      expect(find.byType(Image), findsOneWidget, reason: "the app's mark");
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(l10n.lockUnlock), findsNothing, reason: 'no Unlock button beside Enter');
      expect(said, [l10n.lockAnnounceLocked]);
      await submit(tester, '1234');
      expect(lock.tried, ['1234']);
      expect(c.read(isAppLockedProvider), isFalse);
      expect(said.last, l10n.lockAnnounceUnlocked);
      await takeDown(tester);
    });

    testWidgets('the arrow in the box tries the PIN as Enter does, and is off while the box is empty', (tester) async {
      final lock = _Lock();
      final c = await pump(tester, lock);
      await tester.tap(find.byKey(const ValueKey('lock-go')));
      await tester.pump();
      expect(lock.tried, isEmpty, reason: 'nothing typed');
      await tester.enterText(find.byType(TextField), '1234');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lock-go')));
      await tester.pump();
      await tester.pump();
      expect(lock.tried, ['1234']);
      expect(c.read(isAppLockedProvider), isFalse);
      await takeDown(tester);
    });

    testWidgets('a wrong PIN shakes the box, says how many tries are left before the wait, and is announced',
        (tester) async {
      final lock = _Lock();
      final c = await pump(tester, lock);
      await submit(tester, '0000');
      expect(c.read(isAppLockedProvider), isTrue);
      expect(line(tester), l10n.lockWrongPinTries(9, 30));
      expect(said.last, l10n.lockWrongPinTries(9, 30));
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty, reason: 'the box is cleared');
      await tester.pump(const Duration(milliseconds: 60));
      expect(shakeOffset(tester), isNot(0), reason: 'shaking');
      await tester.pump(const Duration(milliseconds: 400));
      expect(shakeOffset(tester), 0, reason: 'still again');
      // Typing again takes the line away.
      await tester.enterText(find.byType(TextField), '1');
      await tester.pump();
      expect(line(tester), isNull);
      await takeDown(tester);
    });

    testWidgets('with reduce motion a wrong PIN does not shake the box', (tester) async {
      final lock = _Lock();
      await pump(tester, lock, still: true);
      await submit(tester, '0000');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(shakeOffset(tester), 0);
      }
      expect(line(tester), l10n.lockWrongPinTries(9, 30), reason: 'said all the same');
      await takeDown(tester);
    });

    testWidgets('a PIN under four digits is not tried', (tester) async {
      final lock = _Lock();
      await pump(tester, lock);
      await submit(tester, '12');
      expect(lock.tried, isEmpty);
      expect(line(tester), l10n.lockPinMinLength);
      await takeDown(tester);
    });

    testWidgets('the tenth wrong PIN: the wait counts down, the box is closed, the system unlock stays; once over, the line '
        'says the next wrong PIN starts another wait', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both)..failed = 9;
      await pump(tester, lock);
      await submit(tester, '0000');
      expect(line(tester), l10n.lockWaitOrMethod(30, 'Windows Hello'));
      expect(said.last, l10n.lockWaitOrMethod(30, 'Windows Hello'));
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse, reason: 'no PIN during the wait');

      lock.waitLeft = 29;
      await tester.pump(const Duration(seconds: 1));
      expect(line(tester), l10n.lockWaitOrMethod(29, 'Windows Hello'), reason: 'counted down');

      // Windows Hello is not part of the wait.
      await tester.tap(find.byKey(const ValueKey('lock-biometric')));
      await tester.pump();
      expect(lock.prompts, hasLength(1));
      await answer(tester, lock.prompts.single, BiometricAuthOutcome.failed);
      expect(line(tester), l10n.lockWaitOrMethod(29, 'Windows Hello'), reason: 'the wait is still what is said');

      lock.waitLeft = 0;
      await tester.pump(const Duration(seconds: 1));
      expect(line(tester), l10n.lockWaitOver(30));
      expect(said.last, l10n.lockWaitOver(30));
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      await takeDown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('a wait on a lock with no system unlock says only the wait', (tester) async {
      final lock = _Lock()..failed = 9;
      await pump(tester, lock);
      await submit(tester, '0000');
      expect(line(tester), l10n.lockWait(30));
      await takeDown(tester);
    });

    testWidgets('Windows Hello: a button with Ctrl+U, and never opened by the lock itself', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      final c = await pump(tester, lock);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(lock.prompts, isEmpty, reason: 'a computer never opens the prompt by itself');
      final button = find.byKey(const ValueKey('lock-biometric'));
      expect(find.descendant(of: button, matching: find.text(l10n.lockUnlockWith('Windows Hello'))), findsOneWidget);
      expect(find.descendant(of: button, matching: find.text('Ctrl+U')), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(lock.prompts, hasLength(1), reason: 'Ctrl+U asks');
      await answer(tester, lock.prompts.single, BiometricAuthOutcome.success);
      expect(c.read(isAppLockedProvider), isFalse);
      expect(said.last, l10n.lockAnnounceUnlocked);
      await takeDown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('a screen reader finds Windows Hello as a button, and presses it', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      final handle = tester.ensureSemantics();
      await pump(tester, lock);
      final button = find.semantics.byLabel(l10n.lockUnlockWith('Windows Hello'));
      expect(tester.getSemantics(find.byKey(const ValueKey('lock-biometric'))),
          matchesSemantics(label: l10n.lockUnlockWith('Windows Hello'), isButton: true, hasTapAction: true));
      tester.semantics.tap(button);
      await tester.pump();
      expect(lock.prompts, hasLength(1));
      handle.dispose();
      await takeDown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Touch ID on a Mac, with Cmd+U', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      await pump(tester, lock);
      expect(find.text(l10n.lockUnlockWith('Touch ID')), findsOneWidget);
      expect(find.text('⌘U'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(lock.prompts, isEmpty, reason: 'Control is not the Mac\'s');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(lock.prompts, hasLength(1));
      await answer(tester, lock.prompts.single, BiometricAuthOutcome.failed);
      expect(line(tester), l10n.lockMethodFailed('Touch ID'));
      expect(said.last, l10n.lockMethodFailed('Touch ID'));
      await takeDown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a system unlock that cannot be used now sends the person to the PIN', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      await pump(tester, lock);
      await tester.tap(find.byKey(const ValueKey('lock-biometric')));
      await tester.pump();
      await answer(tester, lock.prompts.single, BiometricAuthOutcome.lockedOut);
      expect(line(tester), l10n.lockMethodUnavailable('Windows Hello'));
      await takeDown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('a prompt that never answers never stops the PIN', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      final c = await pump(tester, lock);
      await tester.tap(find.byKey(const ValueKey('lock-biometric')));
      await tester.pump();
      expect(lock.prompts, hasLength(1));
      await submit(tester, '1234');
      expect(c.read(isAppLockedProvider), isFalse);
      await takeDown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('a digit typed anywhere goes into the PIN box, and Esc clears it', (tester) async {
      final lock = _Lock();
      await pump(tester, lock);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final field = find.byType(TextField);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit7, character: '7');
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '7');
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue, reason: 'the box takes the keyboard');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      await takeDown(tester);
    });

    testWidgets('number pad keys that type no digit say Num Lock is off', (tester) async {
      final lock = _Lock();
      await pump(tester, lock);
      await tester.sendKeyEvent(LogicalKeyboardKey.home, physicalKey: PhysicalKeyboardKey.numpad7);
      await tester.pump();
      expect(line(tester), l10n.lockNumLockOff);
      // A key of the rest of the keyboard says nothing of it.
      await tester.enterText(find.byType(TextField), '5');
      await tester.pump();
      expect(line(tester), isNull, reason: 'typing again takes it away');
      await takeDown(tester);
    });

    testWidgets('the encrypting lock offers no system unlock and says why in a line', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      await pump(tester, lock, prefs: {'encrypting_lock_enabled': true});
      expect(find.byKey(const ValueKey('lock-biometric')), findsNothing);
      expect(find.text(l10n.lockOnlyPinNote), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(lock.prompts, isEmpty);
      await takeDown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('a lock with no PIN: the system unlock alone, and the screen reader is told so', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.biometric);
      await pump(tester, lock);
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const ValueKey('lock-biometric')), findsOneWidget);
      expect(said, [l10n.lockAnnounceLockedMethod('Windows Hello')]);
      await tester.tap(find.byKey(const ValueKey('lock-biometric')));
      await tester.pump();
      await answer(tester, lock.prompts.single, BiometricAuthOutcome.failed);
      expect(line(tester), l10n.lockMethodFailedNoPin('Windows Hello'));
      await takeDown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  testWidgets('why it locked, as the line under the title says it', (tester) async {
    for (final (reason, words) in [
      (AppLockReason.started, l10n.lockReasonStarted),
      (AppLockReason.byYou, l10n.lockReasonByYou),
      (const AppLockReason(AppLockCause.idle, 5), l10n.lockReasonIdle(5)),
      (const AppLockReason(AppLockCause.idle, 1), 'Locked after 1 minute idle'),
      (const AppLockReason(AppLockCause.away, 10), l10n.lockReasonAway(10)),
      (const AppLockReason(AppLockCause.away, 0), l10n.lockReasonLeft),
      (AppLockReason.slept, l10n.lockReasonSlept),
      (AppLockReason.computerLocked, l10n.lockReasonComputerLocked),
    ]) {
      await pump(tester, _Lock(), reason: reason);
      expect(tester.widget<Text>(find.byKey(const ValueKey('lock-reason'))).data, words, reason: '$reason');
      await takeDown(tester);
    }
    expect(l10n.lockReasonIdle(5), 'Locked after 5 minutes idle');
  });

  group('the sessions still connected', () {
    final sessions = {
      'a': const SessionState(status: SessionStatus.connected, connectionLabel: 'web-01'),
      'b': const SessionState(status: SessionStatus.connected, connectionLabel: 'db-primary'),
      'c': const SessionState(status: SessionStatus.connecting, connectionLabel: 'staging-api'),
      'd': const SessionState(status: SessionStatus.disconnected, connectionLabel: 'pi-garden'),
    };

    testWidgets('off by default: nothing of them is shown', (tester) async {
      await pump(tester, _Lock(), sessions: sessions);
      expect(find.byKey(const ValueKey('lock-sessions')), findsNothing);
      await takeDown(tester);
    });

    testWidgets('on: how many are connected, and never their names', (tester) async {
      await pump(tester, _Lock(), sessions: sessions, prefs: {'lock_show_sessions': true});
      expect(find.text(l10n.lockSessionsConnected(2)), findsOneWidget);
      expect(l10n.lockSessionsConnected(2), '2 sessions still connected');
      for (final name in ['web-01', 'db-primary', 'staging-api', 'pi-garden']) {
        expect(find.textContaining(name), findsNothing);
      }
      await takeDown(tester);
    });

    testWidgets('on, with none connected: no line', (tester) async {
      await pump(tester, _Lock(), sessions: {}, prefs: {'lock_show_sessions': true});
      expect(find.byKey(const ValueKey('lock-sessions')), findsNothing);
      await takeDown(tester);
    });
  });

  group('a phone', () {
    setUp(() => debugTouchLayout = true);

    Future<void> press(WidgetTester tester, String keys) async {
      for (final k in keys.split('')) {
        await tester.tap(find.byKey(ValueKey('lock-key-$k')));
        await tester.pump();
      }
    }

    testWidgets("the app's own number pad types the PIN, with no system keyboard; keys 56 high at least", (tester) async {
      final lock = _Lock();
      final c = await pump(tester, lock, size: const Size(390, 844));
      expect(find.byType(TextField), findsNothing, reason: 'the system keyboard never slides up');
      for (final k in [...'0123456789'.split(''), 'delete']) {
        final size = tester.getSize(find.byKey(ValueKey('lock-key-$k')));
        expect(size.height, greaterThanOrEqualTo(56), reason: k);
        expect(size.width, greaterThanOrEqualTo(48), reason: k);
      }
      expect(find.byKey(const ValueKey('lock-key-biometric')), findsNothing, reason: 'a blank where there is none');
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(l10n.lockPinNothingTyped), findsOneWidget, reason: 'what a screen reader says');
      await press(tester, '12');
      expect(find.bySemanticsLabel(l10n.lockPinDigitsTyped(2)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lock-key-delete')));
      await tester.pump();
      expect(find.bySemanticsLabel(l10n.lockPinDigitsTyped(1)), findsOneWidget);
      await press(tester, '234');
      handle.dispose();
      await tester.tap(find.byKey(const ValueKey('lock-go')));
      await tester.pump();
      await tester.pump();
      expect(lock.tried, ['1234']);
      expect(c.read(isAppLockedProvider), isFalse);
      expect(buzzes, ['HapticFeedbackType.selectionClick'], reason: 'a tick on unlock');
      await takeDown(tester);
    });

    testWidgets('a screen reader presses the keys of the pad, the delete key and the arrow', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      final handle = tester.ensureSemantics();
      final c = await pump(tester, lock, size: const Size(390, 844), still: true);
      await answer(tester, lock.prompts.single, BiometricAuthOutcome.failed);
      for (final k in ['1', '2', '9']) {
        expect(tester.getSemantics(find.byKey(ValueKey('lock-key-$k'))),
            matchesSemantics(label: k, isButton: true, hasTapAction: true, hasEnabledState: true, isEnabled: true));
        tester.semantics.tap(find.semantics.byLabel(k));
        await tester.pump();
      }
      tester.semantics.tap(find.semantics.byLabel(l10n.lockDeleteDigit));
      await tester.pump();
      for (final k in ['3', '4']) {
        tester.semantics.tap(find.semantics.byLabel(k));
        await tester.pump();
      }
      expect(find.bySemanticsLabel(l10n.lockPinDigitsTyped(4)), findsOneWidget);
      tester.semantics.tap(find.semantics.byLabel(l10n.lockUnlock));
      await tester.pump();
      await tester.pump();
      expect(lock.tried, ['1234']);
      expect(c.read(isAppLockedProvider), isFalse);
      handle.dispose();
      await takeDown(tester);
    });

    testWidgets("a screen reader presses the pad's key for the face or fingerprint", (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      final handle = tester.ensureSemantics();
      await pump(tester, lock, size: const Size(390, 844), still: true);
      await answer(tester, lock.prompts.single, BiometricAuthOutcome.failed);
      tester.semantics.tap(find.semantics.byLabel(l10n.lockUseMethod(l10n.pinSetupBiometricFactorGeneric)));
      await tester.pump();
      expect(lock.prompts, hasLength(2));
      handle.dispose();
      await takeDown(tester);
    });

    testWidgets('a wrong PIN buzzes and says the tries left', (tester) async {
      final lock = _Lock();
      await pump(tester, lock, size: const Size(390, 844));
      await press(tester, '0000');
      await tester.tap(find.byKey(const ValueKey('lock-go')));
      await tester.pump();
      await tester.pump();
      expect(buzzes, ['HapticFeedbackType.heavyImpact']);
      expect(line(tester), l10n.lockWrongPinTries(9, 30));
      await takeDown(tester);
    });

    testWidgets('a keyboard on a tablet works the pad: digits, Backspace and Enter', (tester) async {
      final lock = _Lock();
      final c = await pump(tester, lock, size: const Size(390, 844));
      for (final (key, char) in [
        (LogicalKeyboardKey.digit1, '1'),
        (LogicalKeyboardKey.digit2, '2'),
        (LogicalKeyboardKey.digit9, '9'),
      ]) {
        await tester.sendKeyEvent(key, character: char);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3, character: '3');
      await tester.sendKeyEvent(LogicalKeyboardKey.digit4, character: '4');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(lock.tried, ['1234']);
      expect(c.read(isAppLockedProvider), isFalse);
      await takeDown(tester);
    });

    testWidgets('Face ID opens by itself as the lock comes up, and the key on the pad asks again', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      final c = await pump(tester, lock, size: const Size(390, 844), still: true);
      expect(lock.prompts, hasLength(1), reason: 'a phone opens it by itself');
      expect(find.text('Face ID'), findsOneWidget);
      await answer(tester, lock.prompts.single, BiometricAuthOutcome.failed);
      expect(line(tester), l10n.lockMethodFailed('Face ID'));
      expect(said.last, l10n.lockMethodFailed('Face ID'));
      final key = find.byKey(const ValueKey('lock-key-biometric'));
      expect(tester.getSemantics(key).label, l10n.lockUseMethod('Face ID'));
      await tester.tap(key);
      await tester.pump();
      expect(lock.prompts, hasLength(2));
      await answer(tester, lock.prompts.last, BiometricAuthOutcome.success);
      expect(c.read(isAppLockedProvider), isFalse);
      await takeDown(tester);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets("Android's face or fingerprint: named as such", (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      await pump(tester, lock, size: const Size(390, 844), still: true);
      expect(find.text(l10n.lockMethodGenericLabel), findsOneWidget);
      expect(lock.prompts, hasLength(1));
      await answer(tester, lock.prompts.single, BiometricAuthOutcome.failed);
      expect(line(tester), l10n.lockMethodFailed(l10n.pinSetupBiometricFactorGeneric));
      await takeDown(tester);
    });

    testWidgets('the encrypting lock: no prompt, no biometric key, and the line says why', (tester) async {
      final lock = _Lock(method: SecurityLockMethod.both);
      await pump(tester, lock, size: const Size(390, 844), prefs: {'encrypting_lock_enabled': true});
      expect(lock.prompts, isEmpty);
      expect(find.byKey(const ValueKey('lock-key-biometric')), findsNothing);
      expect(find.text(l10n.lockOnlyPinNote), findsOneWidget);
      await takeDown(tester);
    });

    testWidgets('a small phone, upright and on its side: the pad and the box clear of the bars', (tester) async {
      for (final (size, bars) in [
        (const Size(360, 640), const FakeViewPadding(top: 24, bottom: 48)),
        (const Size(640, 360), const FakeViewPadding(top: 24, right: 48)),
      ]) {
        final lock = _Lock(method: SecurityLockMethod.both);
        await pump(tester, lock, size: size, padding: bars, still: true);
        final bottom = size.height - bars.bottom;
        final right = size.width - bars.right;
        for (final key in ['lock-pin', 'lock-go', 'lock-key-1', 'lock-key-0', 'lock-key-delete', 'lock-key-biometric']) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          expect(rect.top, greaterThanOrEqualTo(bars.top), reason: '$key at $size');
          expect(rect.bottom, lessThanOrEqualTo(bottom), reason: '$key at $size');
          expect(rect.right, lessThanOrEqualTo(right), reason: '$key at $size');
        }
        await takeDown(tester);
      }
    });
  });
}
