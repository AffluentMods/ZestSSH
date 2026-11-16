import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/ui/screens/security/pin_setup_screen.dart';
import 'package:zestssh/ui/screens/security/security_actions.dart';
import 'package:zestssh/ui/screens/security/security_lock_screen.dart';
import 'package:zestssh/ui/screens/security/vault_lock_setup_screen.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// What the PIN and encryption screens say when something fails (3.0):
/// a sentence, and what stands behind it as details to copy. The
/// raw error stood after a colon in the message, and on the lock screen as
/// the PIN field's error, as if a right PIN were wrong. Their prompts and
/// confirmations are the app's own dialogs.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final copied = <String>[];

  setUp(() {
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      },
    );
    ReportScrub.clearFolders();
    Redactor.instance
      ..clearNames()
      ..salt = 'a test'
      ..enabled = false;
    ErrorReport.app = 'ZestSSH 3.0.0 (build 256)';
    ErrorReport.system = () => 'windows 11';
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    ErrorReport.app = 'ZestSSH';
    ErrorReport.system = ErrorReport.systemLabel;
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget Function(BuildContext context, WidgetRef ref) build, {
    required _Lock lock,
    required _Locks Function(Ref ref) locks,
    Map<String, Object> prefs = const {},
    AppDatabase? db,
    _Vault? vault,
    ProfileController? profiles,
  }) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(p),
      securityLockServiceProvider.overrideWithValue(lock),
      isAppLockedProvider.overrideWith(locks),
      vaultSlotServiceProvider.overrideWithValue(vault ?? _Vault()),
      if (db != null) databaseProvider.overrideWithValue(db),
      if (profiles != null) profileControllerProvider.overrideWithValue(profiles),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Consumer(builder: (context, ref, _) => build(context, ref))),
      ),
    ));
    await tester.pump();
    return container;
  }

  group('The security settings\' actions', () {
    testWidgets('turning encryption off asks for the PIN in the app\'s own dialog, and a failure says so plainly',
        (tester) async {
      final lock = _Lock();
      late SecurityActions actions;
      final c = await pump(tester, (context, ref) {
        actions = SecurityActions(context, ref);
        return const SizedBox();
      }, lock: lock, locks: (ref) => _Locks(ref, failWith: StateError('the vault key would not unwrap')));
      final done = actions.disableEncryption();
      await tester.pumpAndSettle();
      expect(find.text(l10n.secSetTurnOffEncryptionTitle), findsOneWidget);
      final field = find.descendant(of: find.byType(ZestTextField), matching: find.byType(TextField));
      final input = tester.widget<TextField>(field);
      expect(input.keyboardType, TextInputType.number);
      expect(input.obscureText, isTrue);
      await tester.enterText(field, '12a34');
      expect(tester.widget<TextField>(field).controller!.text, '1234', reason: 'digits only');
      await tester.tap(find.text(l10n.secSetTurnOff));
      await tester.pumpAndSettle();
      expect(await done, isFalse);
      expect(lock.verified, ['1234']);
      final n = c.read(notificationCenterProvider).history.single;
      expect(n.title, l10n.secSetEncryptionNotTurnedOff);
      expect(n.details, contains('Bad state: the vault key would not unwrap'));
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('a PIN prompt cancelled, or left empty, changes nothing', (tester) async {
      final lock = _Lock();
      late SecurityActions actions;
      await pump(tester, (context, ref) {
        actions = SecurityActions(context, ref);
        return const SizedBox();
      }, lock: lock, locks: (ref) => _Locks(ref));
      var pin = actions.promptForPin(title: 'T', body: 'B', confirmLabel: 'Go');
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(await pin, isNull);
      pin = actions.promptForPin(title: 'T', body: 'B', confirmLabel: 'Go');
      await tester.pumpAndSettle();
      await tester.enterText(find.descendant(of: find.byType(ZestTextField), matching: find.byType(TextField)), ' ');
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(await pin, isNull);
    });

    testWidgets('binding to the hardware is asked about in the app\'s own dialog, and a failure says so plainly',
        (tester) async {
      final lock = _Lock();
      late SecurityActions actions;
      final c = await pump(tester, (context, ref) {
        actions = SecurityActions(context, ref);
        return const SizedBox();
      }, lock: lock, locks: (ref) => _Locks(ref, failWith: StateError('the hardware refused')));
      var done = actions.setHardwareBinding(true);
      await tester.pumpAndSettle();
      expect(find.byType(ZestConfirmDialog), findsOneWidget);
      // What it does in the body; what would lose the data in its one amber
      // sentence (the whole dialog was yellow; the dialog rules, 3.4).
      final risk = Platform.isWindows ? l10n.secBindRiskWindows : l10n.secBindRiskMobile;
      expect(find.descendant(of: find.byKey(const ValueKey('zest-callout')), matching: find.text(risk)), findsOneWidget);
      expect(find.text(Platform.isWindows ? l10n.secBindWhatWindows : l10n.secBindWhatMobile), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(await done, isFalse);
      expect(c.read(notificationCenterProvider).history, isEmpty, reason: 'nothing was tried');

      done = actions.setHardwareBinding(true);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.secSetBind));
      await tester.pumpAndSettle();
      expect(await done, isFalse);
      final n = c.read(notificationCenterProvider).history.single;
      expect(n.title, l10n.secSetHwBindingNotChanged);
      expect(n.details, contains('Bad state: the hardware refused'));
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('forgetting the trusted host keys is asked about in the app\'s own dialog', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      late SecurityActions actions;
      await pump(tester, (context, ref) {
        actions = SecurityActions(context, ref);
        return const SizedBox();
      }, lock: _Lock(), locks: (ref) => _Locks(ref), db: db);
      var done = actions.clearKnownHosts();
      await tester.pumpAndSettle();
      expect(find.byType(ZestConfirmDialog), findsOneWidget);
      expect(find.text(l10n.secSetClearKeysDialogTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(await done, isFalse);
      done = actions.clearKnownHosts();
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.commonClearAll));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => done), isTrue);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('Turning the encrypting lock on', () {
    testWidgets('a failure says so plainly, with its details to copy; a slip of the PIN has none', (tester) async {
      await pump(tester, (context, ref) => const VaultLockSetupScreen(),
          lock: _Lock(), locks: (ref) => _Locks(ref, failWith: StateError('no room in the keychain')));
      await tester.enterText(find.byType(TextField).first, '1234');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
      expect(find.text(l10n.vaultLockSetupNotTurnedOn), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('vault-setup-copy-details')));
      await tester.pump();
      expect(copied.single, contains('What: ${l10n.vaultLockSetupNotTurnedOn}'));
      expect(copied.single, contains('Where: Turning on the encrypting lock'));
      expect(copied.single, contains('Error: Bad state: no room in the keychain'));
      await tester.pump(const Duration(seconds: 3));

      // A PIN too short says so, with no details of the failure before it.
      await tester.enterText(find.byType(TextField).first, '12');
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
      expect(find.text(l10n.vaultLockSetupErrorPinTooShort), findsOneWidget);
      expect(find.byKey(const ValueKey('vault-setup-copy-details')), findsNothing);
    });
  });

  group('Setting the PIN', () {
    testWidgets('a PIN that could not be saved says so plainly, with its details to copy', (tester) async {
      final lock = _Lock()..setPinError = StateError('the keychain is locked');
      await pump(tester, (context, ref) => const PinSetupScreen(), lock: lock, locks: (ref) => _Locks(ref));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '2468');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '2468');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text(l10n.pinSetupNotSaved), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pin-setup-copy-details')));
      await tester.pump();
      expect(copied.single, contains('What: ${l10n.pinSetupNotSaved}'));
      expect(copied.single, contains('Where: Saving the PIN'));
      expect(copied.single, contains('Error: Bad state: the keychain is locked'));
      await tester.pump(const Duration(seconds: 3));

      // Back to the first step: no details there.
      await tester.tap(find.text(l10n.back));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pin-setup-copy-details')), findsNothing);
      await tester.enterText(find.byType(TextField).first, '2468');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Two PINs that differ say so, with no details of the failure before.
      await tester.enterText(find.byType(TextField).first, '1357');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text(l10n.pinSetupPinsDoNotMatch), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-setup-copy-details')), findsNothing);
    });
  });

  group('The lock screen', () {
    testWidgets('a right PIN whose data would not open says so apart from the PIN, with its details', (tester) async {
      final lock = _Lock();
      final locks = <_Locks>[];
      await pump(tester, (context, ref) => const SecurityLockScreen(),
          lock: lock,
          locks: (ref) => _Locks(ref, failWith: StateError('file is not a database'))..also(locks),
          prefs: {'security_lock_enabled': true, 'encrypting_lock_enabled': true});
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '1234');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final panel = find.byKey(const ValueKey('lock-open-failure'));
      expect(panel, findsOneWidget);
      expect(find.descendant(of: panel, matching: find.text(l10n.securityLockDataNotOpened)), findsOneWidget);
      expect(find.byKey(const ValueKey('lock-message')), findsNothing, reason: 'the PIN was right');
      expect(find.byKey(const ValueKey('lock-open-other')), findsNothing, reason: 'on a phone there is no other');
      await tester.tap(find.descendant(of: panel, matching: find.byType(CopyDetailsButton)));
      await tester.pump();
      expect(copied.single, contains('What: ${l10n.securityLockDataNotOpened}'));
      expect(copied.single, contains('Where: Opening the data after unlocking'));
      expect(copied.single, contains('Error: Bad state: file is not a database'));
      await tester.pump(const Duration(seconds: 3));

      // A wrong PIN next: the panel goes, the line under the PIN box says it, with
      // the tries left before the wait (one wrong of ten so far).
      lock.pinRight = false;
      await tester.enterText(find.byType(TextField).first, '9999');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(tester.widget<Text>(find.byKey(const ValueKey('lock-message'))).data, l10n.lockWrongPinTries(9, 30));
    });

    testWidgets('a profile that does not open offers another where there is one, and the next right PIN opens that', (tester) async {
      final profiles = _Profiles();
      await pump(tester, (context, ref) => const SecurityLockScreen(),
          lock: _Lock(),
          locks: (ref) => _Locks(ref, failWith: StateError('file is not a database')),
          profiles: profiles,
          prefs: {'security_lock_enabled': true, 'encrypting_lock_enabled': true});
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '1234');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final other = find.byKey(const ValueKey('lock-open-other'));
      expect(find.descendant(of: other, matching: find.text(l10n.databaseErrorOpenOther)), findsOneWidget);
      await tester.tap(other);
      await tester.pumpAndSettle();
      expect(profiles.asked, 1);
      expect(find.byKey(const ValueKey('lock-open-failure')), findsNothing, reason: 'the PIN is asked for again');
    });

    for (final (words, failure) in <(String, Object)>[
      ('a file something holds', const FileSystemException('held')),
      ('a database that is busy', StateError('SqliteException(5): database is locked')),
    ]) {
      testWidgets('$words may pass by itself: it says so, and nothing is offered to set aside', (tester) async {
        await pump(tester, (context, ref) => const SecurityLockScreen(),
            lock: _Lock(),
            locks: (ref) => _Locks(ref, failWith: failure),
            profiles: _Profiles(),
            prefs: {'security_lock_enabled': true, 'encrypting_lock_enabled': true});
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '1234');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('lock-open-failure')), findsOneWidget);
        expect(find.byKey(const ValueKey('lock-set-aside')), findsNothing);
      });
    }

    testWidgets('what does not open can be set aside, after saying what that does', (tester) async {
      final profiles = _Profiles();
      await pump(tester, (context, ref) => const SecurityLockScreen(),
          lock: _Lock(),
          locks: (ref) => _Locks(ref, failWith: StateError('file is not a database')),
          profiles: profiles,
          prefs: {'security_lock_enabled': true, 'encrypting_lock_enabled': true});
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '1234');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('lock-set-aside')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.databaseErrorSetAsideBody), findsOneWidget);
      expect(profiles.setAside, 0, reason: 'not before it is said');
      await tester.tap(find.text(l10n.databaseErrorSetAside).last);
      await tester.pumpAndSettle();
      expect(profiles.setAside, 1);
      expect(find.byKey(const ValueKey('lock-open-failure')), findsNothing);
    });

    testWidgets("a PIN change left half done asks for the PIN before in the app's own dialog, and what fails after says so",
        (tester) async {
      final vault = _Vault();
      await pump(tester, (context, ref) => const SecurityLockScreen(),
          lock: _Lock(),
          locks: (ref) => _Locks(ref, failWith: StateError('file is not a database'), vaultLockedFirst: true),
          vault: vault,
          prefs: {'security_lock_enabled': true, 'encrypting_lock_enabled': true});
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '1234');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text(l10n.securityLockFinishPinChangeTitle), findsOneWidget);
      final field = find.descendant(of: find.byType(ZestTextField), matching: find.byType(TextField));
      expect(tester.widget<TextField>(field).keyboardType, TextInputType.number);
      await tester.enterText(field, '9876');
      await tester.tap(find.text(l10n.lockUnlock).last);
      await tester.pumpAndSettle();
      expect(vault.unlockedWith, ['9876']);
      expect(vault.changedTo, ['1234']);
      final panel = find.byKey(const ValueKey('lock-open-failure'));
      expect(panel, findsOneWidget);
      await tester.tap(find.descendant(of: panel, matching: find.byType(CopyDetailsButton)));
      await tester.pump();
      expect(copied.single, contains('Error: Bad state: file is not a database'));
      await tester.pump(const Duration(seconds: 3));
    });
  });
}

/// A computer with another profile to open.
class _Profiles implements ProfileController {
  int asked = 0;

  @override
  bool get canOpenOther => true;

  @override
  bool get canSetAside => true;

  @override
  Future<void> openOtherAfterFailure() async => asked++;

  int setAside = 0;

  @override
  Future<void> setAsideAfterFailure() async => setAside++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The PIN as a test sets it: right or wrong, saved or not.
class _Lock implements SecurityLockService {
  bool pinRight = true;
  Object? setPinError;
  final verified = <String>[];

  @override
  bool get isLockedOut => false;
  @override
  int get remainingLockoutSeconds => 0;
  @override
  int get failedAttempts => pinRight ? 0 : 1;
  @override
  int get maxAttempts => 10;
  @override
  Future<bool> verifyPin(String pin) async {
    verified.add(pin);
    return pinRight;
  }

  @override
  Future<bool> hasPinConfigured() async => true;
  @override
  Future<void> setPin(String pin) async {
    if (setPinError != null) throw setPinError!;
  }

  @override
  Future<void> setLockMethod(SecurityLockMethod method) async {}
  @override
  Future<SecurityLockMethod> getLockMethod() async => SecurityLockMethod.pin;
  @override
  Future<bool> isBiometricAvailable() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The app's lock, whose layers fail as a test says.
class _Locks extends AppLockNotifier {
  _Locks(super.ref, {this.failWith, this.vaultLockedFirst = false});

  final Object? failWith;

  /// The vault's slot is behind the PIN the first time (a PIN change left
  /// half done).
  bool vaultLockedFirst;

  void also(List<_Locks> list) => list.add(this);

  Future<void> _fail() async {
    if (failWith != null) throw failWith!;
  }

  @override
  Future<void> enableEncryptingLock({required String pin}) => _fail();
  @override
  Future<void> disableEncryptingLock(String pin) => _fail();
  @override
  Future<void> enableHardwareBinding() => _fail();
  @override
  Future<void> disableHardwareBinding() => _fail();
  @override
  Future<void> unlockVault({String? pin, String? masterPassword, String? recoveryKey}) async {
    if (vaultLockedFirst) {
      vaultLockedFirst = false;
      throw const VaultLockedException('the slot is behind');
    }
    await _fail();
  }
}

/// No vault on this device, or one whose key a test unlocks.
class _Vault implements VaultSlotService {
  final unlockedWith = <String>[];
  final changedTo = <String>[];

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<SecretKey> unlockVaultKey({String? pin, String? masterPassword, String? recoveryKey}) async {
    unlockedWith.add(pin!);
    return SecretKey(List.filled(32, 7));
  }

  @override
  Future<void> changePin(SecretKey vaultKey, String newPin) async => changedTo.add(newPin);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
