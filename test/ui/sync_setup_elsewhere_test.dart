import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';
import 'package:zestssh/ui/screens/sync/sync_setup_elsewhere.dart';

/// A store that is asked what it holds.
class _Store extends Fake implements SyncBackend {
  _Store(this.status, {this.unreachable = false});

  final SyncStatus status;
  final bool unreachable;
  int asked = 0;

  @override
  Future<SyncStatus> getStatus() async {
    asked++;
    if (unreachable) throw const SocketException('Connection refused');
    return status;
  }
}

const _vault = SyncStatus(hasData: true, version: 3, blobSize: 2048);
const _nothing = SyncStatus(hasData: false, version: 0, blobSize: 0);
const _refused = SyncConflictException(serverVersion: -1, expectedVersion: -1);

/// Setup stepping aside for a vault another of the account's devices created
/// while this one was being set up (3.0): its first write is refused, nothing
/// was created, and the person joins what is there, told that the recovery
/// key they were just shown opens nothing.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const storage = FlutterSecureStorage();

  group('whether a vault was created meanwhile', () {
    test('a write refused because something is there, and a vault is there: that vault', () async {
      final store = _Store(_vault);
      expect(await vaultSetUpMeanwhile(store, _refused), same(_vault));
      expect(store.asked, 1);
    });

    test('a server from before it refused such a write says the keys are not the account\'s: that vault too',
        () async {
      final store = _Store(_vault);
      expect(await vaultSetUpMeanwhile(store, const SyncKeysMismatchException('not the keys of the account')),
          same(_vault));
    });

    test('refused, and no vault is there: it was something else', () async {
      expect(await vaultSetUpMeanwhile(_Store(_nothing), _refused), isNull);
    });

    test('a failure of another kind is no sign of a vault, and the store is not asked', () async {
      for (final failure in <Object>[
        const SyncException('Push failed: the server is busy'),
        const SyncSetupRequiredException('set sync up again'),
        const SocketException('Connection refused'),
        StateError('no'),
      ]) {
        final store = _Store(_vault);
        expect(await vaultSetUpMeanwhile(store, failure), isNull, reason: '$failure');
        expect(store.asked, 0, reason: '$failure');
      }
    });

    test('refused, and the store cannot be asked: what the write failed with stands', () async {
      final store = _Store(_vault, unreachable: true);
      expect(await vaultSetUpMeanwhile(store, _refused), isNull);
      expect(store.asked, 1);
    });
  });

  group('stepping aside', () {
    late SyncSetupStateService setup;
    late SyncStatusNotifier syncing;

    /// A setup that has come as far as its first write: a password chosen, a
    /// recovery key saved and confirmed, and sync shown as running.
    Future<void> atTheFirstWrite(WidgetTester tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      setup = SyncSetupStateService(storage);
      await tester.runAsync(() async {
        await setup.beginSetup();
        await setup.markPasswordChosen(salt: List<int>.filled(32, 7));
        await setup.markRecoverySaved(recoverySalt: List<int>.filled(32, 9));
        await setup.markRecoveryConfirmed();
      });
      syncing = SyncStatusNotifier()..setSyncing(true);
      addTearDown(syncing.dispose);
    }

    /// Steps aside for [refusal] from a screen, and returns what came back
    /// (in a list, empty until it has).
    Future<List<SyncStatus?>> stepAside(WidgetTester tester, SyncBackend store, Object refusal,
        {Locale locale = const Locale('en')}) async {
      final came = <SyncStatus?>[];
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  came.add(await stepAsideIfSetUpElsewhere(
                    context,
                    backend: store,
                    setup: setup,
                    syncing: syncing,
                    refusal: refusal,
                  ));
                },
                child: const Text('first write refused'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('first write refused'));
      // The store and the device's storage answer outside the test's clock.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      return came;
    }

    Future<SyncSetupSnapshot> kept(WidgetTester tester) async => (await tester.runAsync(setup.snapshot))!;

    testWidgets('a vault was created meanwhile: the person is told, and what this run kept is forgotten',
        (tester) async {
      await atTheFirstWrite(tester);
      final came = await stepAside(tester, _Store(_vault), _refused);

      // Said, and waiting to be read: nothing has come back yet.
      expect(came, isEmpty);
      expect(find.text(l10n.syncSetupElsewhereTitle), findsOneWidget);
      expect(find.text(l10n.syncSetupElsewhereBody), findsOneWidget);
      expect(find.text(l10n.syncSetupElsewhereKey), findsOneWidget, reason: 'the recovery key shown opens nothing');
      expect(find.text(l10n.syncSetupElsewhereNext), findsOneWidget);
      expect(find.text(l10n.cancel), findsNothing, reason: 'there is nothing to cancel');

      // Forgotten before it is said: closing the app on this dialog leaves
      // no half-made setup behind.
      final snapshot = await kept(tester);
      expect(snapshot.step, SyncSetupStep.notStarted);
      expect(snapshot.hasSalt, isFalse);
      expect(snapshot.hasRecoverySalt, isFalse);
      expect(snapshot.isComplete, isFalse);
      expect(syncing.state.isSyncing, isFalse, reason: 'sync is not shown as running behind the dialog');
      expect(syncing.state.error, isNull, reason: 'it is no error of this device');

      await tester.tap(find.text(l10n.profileContinue));
      await tester.pumpAndSettle();
      expect(came, [same(_vault)], reason: 'the vault to join');
      expect(find.text(l10n.syncSetupElsewhereTitle), findsNothing);
    });

    testWidgets('closed with its X, it still gives the vault to join', (tester) async {
      await atTheFirstWrite(tester);
      final came = await stepAside(tester, _Store(_vault), _refused);
      Navigator.of(tester.element(find.text(l10n.syncSetupElsewhereTitle))).pop();
      await tester.pumpAndSettle();
      expect(came, [same(_vault)]);
    });

    testWidgets('another kind of failure: nothing is said and nothing is forgotten', (tester) async {
      await atTheFirstWrite(tester);
      final store = _Store(_vault);
      final came = await stepAside(tester, store, const SyncException('Push failed: the server is busy'));

      expect(came, [null]);
      expect(find.text(l10n.syncSetupElsewhereTitle), findsNothing);
      final snapshot = await kept(tester);
      expect(snapshot.step, SyncSetupStep.recoveryConfirmed);
      expect(snapshot.hasSalt, isTrue);
      expect(snapshot.hasRecoverySalt, isTrue);
      expect(syncing.state.isSyncing, isTrue, reason: 'the caller says what failed');
    });

    testWidgets('refused with no vault there: nothing is said and nothing is forgotten', (tester) async {
      await atTheFirstWrite(tester);
      final came = await stepAside(tester, _Store(_nothing), _refused);

      expect(came, [null]);
      expect(find.text(l10n.syncSetupElsewhereTitle), findsNothing);
      expect((await kept(tester)).step, SyncSetupStep.recoveryConfirmed);
      expect(syncing.state.isSyncing, isTrue);
    });

    testWidgets('it is said in the language of the app', (tester) async {
      await atTheFirstWrite(tester);
      final de = lookupAppLocalizations(const Locale('de'));
      await stepAside(tester, _Store(_vault), _refused, locale: const Locale('de'));
      expect(find.text(de.syncSetupElsewhereTitle), findsOneWidget);
      expect(find.text(de.syncSetupElsewhereKey), findsOneWidget);
      expect(find.text(l10n.syncSetupElsewhereTitle), findsNothing);
    });
  });

  test('every language says it, in its own words', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final l = lookupAppLocalizations(locale);
      for (final say in <String Function(AppLocalizations)>[
        (x) => x.syncSetupElsewhereTitle,
        (x) => x.syncSetupElsewhereBody,
        (x) => x.syncSetupElsewhereKey,
        (x) => x.syncSetupElsewhereNext,
      ]) {
        expect(say(l).trim(), isNotEmpty, reason: '$locale');
        expect(say(l), isNot(say(l10n)), reason: '$locale');
      }
    }
    expect(l10n.syncSetupElsewhereKey, contains('opens nothing'));
    expect(l10n.syncSetupElsewhereBody, contains('Nothing was created'));
  });

  group('what a failed setup is said to have failed with', () {
    test('the words of the store, without their full stop, and what stands behind them', () {
      const failure = SyncException('Your sync storage is full.', detail: 'HTTP 507 Insufficient Storage');
      expect(setupFailureSaid(failure), 'Your sync storage is full');
      expect(setupFailureDetails(failure), 'HTTP 507 Insufficient Storage');
      expect(l10n.profileSetupFailedResume(setupFailureSaid(failure)), isNot(contains('..')));
    });

    test('words that end without a full stop are left as they are', () {
      expect(setupFailureSaid(const SyncException('Push failed: HTTP 500')), 'Push failed: HTTP 500');
      expect(setupFailureSaid(const SyncException('容量已满。')), '容量已满');
    });

    test('only the last full stop goes: a sentence before it keeps its own', () {
      expect(setupFailureSaid(const SyncException('The store said no. Try again later. ')),
          'The store said no. Try again later');
    });

    test('a store that says nothing more: what was thrown stands behind the notice', () {
      const failure = SyncException('Push failed: HTTP 500');
      expect(setupFailureDetails(failure), failure.toString());
    });

    test('the network is said for what it is, never as the exception thrown', () {
      const failure = SocketException('Connection refused', osError: OSError('Connection refused', 111));
      final said = setupFailureSaid(failure);
      expect(said, isNot(contains('SocketException')));
      expect(said, isNot(contains('errno')));
      expect(said.trim(), isNotEmpty);
      expect(said.endsWith('.'), isFalse);
      expect(setupFailureDetails(failure), contains('Connection refused'));
    });
  });

  test('setup steps aside before it says its first write failed, and never says a raw exception', () {
    final source = File('lib/ui/screens/profile/profile_screen.dart').readAsStringSync().replaceAll('\r\n', '\n');
    final wizard = source.substring(
      source.indexOf('Future<void> _runSyncSetupWizard('),
      source.indexOf('Future<void> _joinExistingSync('),
    );
    final aside = wizard.indexOf('stepAsideIfSetUpElsewhere(');
    final join = wizard.indexOf('await _joinExistingSync(theirs);');
    final failed = wizard.indexOf("AppLogger.error('Initial sync push failed during setup', e);");
    expect(aside, greaterThan(0));
    expect(join, greaterThan(aside), reason: 'the vault that is there is joined');
    expect(failed, greaterThan(join), reason: 'a failure is said only when it was no vault');
    expect(wizard.substring(join, failed), contains('return;'), reason: 'joined, the failure is not said too');
    expect(wizard, contains('createOnly: true,'), reason: 'the first write asks to be made only where nothing is');
    expect(wizard, contains('l10n.profileSetupFailedResume(setupFailureSaid(e))'));
    expect(wizard, contains('details: setupFailureDetails(e),'));
    expect(wizard, isNot(contains('e.toString()')));
  });
}
