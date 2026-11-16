import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/ui/screens/security/lock_art.dart';
import 'package:zestssh/ui/screens/security/lock_curtain.dart';
import 'package:zestssh/ui/screens/security/security_lock_screen.dart';

/// A lock whose PIN is 1234.
class _Lock implements SecurityLockService {
  @override
  bool get isLockedOut => false;
  @override
  int get remainingLockoutSeconds => 0;
  @override
  int get failedAttempts => 0;
  @override
  int get maxAttempts => 10;
  @override
  Future<bool> verifyPin(String pin) async => pin == '1234';
  @override
  Future<SecurityLockMethod> getLockMethod() async => SecurityLockMethod.pin;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vault implements VaultSlotService {
  @override
  Future<bool> isEnabled() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The app's lock, open to begin with.
class _Open extends AppLockNotifier {
  _Open(super.ref) {
    state = false;
  }
}

/// The app as the router builds it: the lock's backdrop while the lock screen is
/// up, the app otherwise; with a button that counts its taps and one that locks
/// it as its person would.
class _App extends ConsumerWidget {
  const _App(this.taps);

  final List<String> taps;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(lockScreenUpProvider)) return const LockBackdrop();
    return Scaffold(
      body: Column(children: [
        TextButton(onPressed: () => taps.add('app'), child: const Text('the app')),
        TextButton(onPressed: () => LockCurtain.lockByYou(ref), child: const Text('lock it')),
      ]),
    );
  }
}

/// The lock screen's doors over the app (4.0):
/// while locked nothing of the app is built under them; once the check
/// passes they split along the seam and slide apart onto the app in under half a
/// second, a key or a click skipping it, a fade with reduce motion; the person's
/// lock closes them over the app first, and a lock that comes by itself shuts them
/// at once.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<ProviderContainer> pump(WidgetTester tester, List<String> taps,
      {bool open = false, bool lockOn = true, bool still = false}) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'security_lock_enabled': lockOn});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      securityLockServiceProvider.overrideWithValue(_Lock()),
      vaultSlotServiceProvider.overrideWithValue(_Vault()),
      dbReadyProvider.overrideWithValue(true),
      if (open) isAppLockedProvider.overrideWith(_Open.new),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: still),
          child: LockCurtain(child: child!),
        ),
        home: _App(taps),
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

  final doors = find.byWidgetPredicate((w) => w is ClipPath && w.clipper is LockDoorClipper);

  /// How far each door stands off its place, left and right.
  (double, double) apart(WidgetTester tester) {
    final offsets = [
      for (final door in doors.evaluate())
        (door.findAncestorWidgetOfExactType<Transform>()!).transform.getTranslation().x,
    ];
    return (offsets.first, offsets.last);
  }

  Future<void> unlockWithPin(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), '1234');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
  }

  testWidgets('locked: the lock screen on the shut doors, and nothing of the app under them', (tester) async {
    final taps = <String>[];
    await pump(tester, taps);
    expect(find.text(l10n.lockTitle), findsOneWidget);
    expect(find.byType(SecurityLockScreen), findsOneWidget, reason: 'one lock screen: the backdrop under it draws none');
    expect(find.byType(LockBackdrop), findsOneWidget);
    expect(find.text('the app'), findsNothing, reason: 'nothing of the app is built before the check');
    expect(doors, findsNWidgets(2));
    expect(apart(tester), (0.0, 0.0), reason: 'shut');
    await takeDown(tester);
  });

  testWidgets('the check passes: the doors split along the seam and slide apart onto the app, in under half a second',
      (tester) async {
    final taps = <String>[];
    final c = await pump(tester, taps);
    await unlockWithPin(tester);
    expect(c.read(isAppLockedProvider), isFalse);
    expect(find.text('the app'), findsOneWidget, reason: 'built under the doors once the check passed');
    expect(apart(tester), (0.0, 0.0), reason: 'the doors move only after the lock screen fades');
    await tester.pump(const Duration(milliseconds: 300));
    final (left, right) = apart(tester);
    expect(left, lessThan(0), reason: 'the left door goes left');
    expect(right, greaterThan(0), reason: 'the right door goes right');
    // A click on the app while they move does not reach it.
    await tester.tap(find.text('the app'), warnIfMissed: false);
    expect(taps, isEmpty);
    await takeDown(tester);
  });

  testWidgets('the doors are gone within half a second, and the app takes clicks again', (tester) async {
    final taps = <String>[];
    await pump(tester, taps);
    await unlockWithPin(tester);
    await tester.pump(const Duration(milliseconds: 250));
    expect(doors, findsNWidgets(2));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(doors, findsNothing, reason: 'open within 500 ms');
    expect(kLockOpenTime, lessThan(const Duration(milliseconds: 500)));
    await tester.tap(find.text('the app'));
    expect(taps, ['app']);
    await takeDown(tester);
  });

  testWidgets('a key or a click skips the motion', (tester) async {
    for (final skip in ['key', 'click']) {
      final taps = <String>[];
      await pump(tester, taps);
      await unlockWithPin(tester);
      await tester.pump(const Duration(milliseconds: 50));
      expect(doors, findsNWidgets(2));
      if (skip == 'key') {
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
      } else {
        await tester.tapAt(const Offset(600, 700), kind: PointerDeviceKind.mouse);
      }
      await tester.pump();
      await tester.pump();
      expect(doors, findsNothing, reason: 'skipped by a $skip');
      expect(taps, isEmpty, reason: 'the click that skipped reached nothing');
      await takeDown(tester);
    }
  });

  testWidgets('with reduce motion the doors do not move: a short fade', (tester) async {
    final taps = <String>[];
    await pump(tester, taps, still: true);
    await unlockWithPin(tester);
    await tester.pump(const Duration(milliseconds: 90));
    expect(apart(tester), (0.0, 0.0));
    final layer = tester.widget<Opacity>(find.ancestor(of: doors.first, matching: find.byType(Opacity)).first);
    expect(layer.opacity, inExclusiveRange(0, 1), reason: 'fading');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(doors, findsNothing, reason: 'gone in 180 ms');
    await takeDown(tester);
  });

  testWidgets('Lock ZestSSH: the doors close over the app, which takes nothing meanwhile, and it locks behind them',
      (tester) async {
    final taps = <String>[];
    final c = await pump(tester, taps, open: true);
    expect(find.text('the app'), findsOneWidget);
    expect(doors, findsNothing);
    await tester.tap(find.text('lock it'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(c.read(isAppLockedProvider), isFalse, reason: 'not before the doors meet');
    final (left, right) = apart(tester);
    expect(left, lessThan(0));
    expect(right, greaterThan(0));
    await tester.tap(find.text('the app'), warnIfMissed: false);
    expect(taps, isEmpty, reason: 'the app takes nothing while the doors close');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump();
    expect(c.read(isAppLockedProvider), isTrue);
    expect(c.read(isAppLockedProvider.notifier).why, AppLockReason.byYou);
    expect(find.text('the app'), findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.lockReasonByYou), findsOneWidget);
    expect(apart(tester), (0.0, 0.0));
    await takeDown(tester);
  });

  testWidgets('a lock that comes by itself shuts the doors at once, with its reason', (tester) async {
    final taps = <String>[];
    final c = await pump(tester, taps, open: true);
    await c.read(isAppLockedProvider.notifier).lock(const AppLockReason(AppLockCause.idle, 5));
    await tester.pump();
    expect(find.text('the app'), findsNothing);
    expect(doors, findsNWidgets(2));
    expect(apart(tester), (0.0, 0.0), reason: 'shut at once: the app is not shown on the way');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.lockReasonIdle(5)), findsOneWidget);
    await takeDown(tester);
  });

  testWidgets('with the app lock off, Lock ZestSSH does nothing', (tester) async {
    final taps = <String>[];
    final c = await pump(tester, taps, lockOn: false);
    expect(find.text('the app'), findsOneWidget);
    await tester.tap(find.text('lock it'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.read(isAppLockedProvider), isFalse);
    expect(doors, findsNothing);
    await takeDown(tester);
  });

  testWidgets('the lock route with no curtain over it shows the lock screen itself', (tester) async {
    SharedPreferences.setMockInitialValues({'security_lock_enabled': true});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        securityLockServiceProvider.overrideWithValue(_Lock()),
        vaultSlotServiceProvider.overrideWithValue(_Vault()),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LockBackdrop(),
      ),
    ));
    await tester.pump();
    expect(find.byType(SecurityLockScreen), findsOneWidget);
    await takeDown(tester);
  });
}
