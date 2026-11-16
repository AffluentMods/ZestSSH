// Real Argon2id key derivation on the Account page (the weakest profile
// deriveKey accepts), which can take half a minute a key on a busy machine.
@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_section.dart';

import '../helpers/memory_store_backend.dart';
import '../helpers/recovery_proof_spy.dart';

/// The Security card's ask for the sync password (3.3.1).
/// A recovery of an account that lost every second step keeps
/// its synced data only with the account's recovery proof, which a device
/// registers where it proves a typed sync password; a device that updated
/// syncs with the key it keeps and is never asked again, so most accounts had
/// none. Where ZestSSH Cloud says the account has none, two-step sign-in is
/// on and this device syncs to ZestSSH Cloud, the card asks once, with the
/// reason: Type it proves the password through the Account page's own unlock
/// and registers the proof; Not now ends it on this device.
void main() {
  setUpAll(initializeDateFormatting);
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const ask = ValueKey('recovery-proof-ask');

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Settles until [done], for steps that derive a key (real time).
  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    final clock = Stopwatch()..start();
    while (!done() && clock.elapsed < const Duration(minutes: 3)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f);
    await tester.tap(f);
    await settle(tester);
  }

  group('the two-step section', () {
    late _Cloud cloud;
    late SharedPreferences prefs;

    /// How often Type it asked for the password, and what each answered.
    late int proved;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      cloud = _Cloud();
      proved = 0;
    });

    /// The section as the Account page shows it, signed in with two-step
    /// sign-in on and no recovery proof, on a device that syncs to ZestSSH
    /// Cloud: each argument turns one of those off. [answer] is what the
    /// sync password's proof answers; [registers], whether it registers the
    /// proof with ZestSSH Cloud.
    Future<void> pump(
      WidgetTester tester, {
      bool signedIn = true,
      bool syncsToCloud = true,
      Map<String, Object> savedPrefs = const {},
      bool answer = true,
      bool registers = true,
    }) async {
      SharedPreferences.setMockInitialValues(savedPrefs);
      prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<bool> prove() async {
        proved++;
        if (answer && registers) cloud.state = {...cloud.state, 'recovery_proof': true};
        return answer;
      }

      final client = MockClient(cloud.answer);
      await tester.pumpWidget(ProviderScope(
        // A new scope each time: the section is built again from nothing.
        key: UniqueKey(),
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
          currentUserProvider.overrideWith((_) => const UserProfile(uid: 'uid-1', email: 'sam@example.com')),
          signsInWithFirebaseProvider.overrideWithValue(true),
          passkeyWayProvider.overrideWith((ref) async => PasskeyWay.none),
          twoStepApiProvider.overrideWithValue(
              TwoStepApi(client: client, baseUrl: 'https://cloud.test/v1', bearer: () async => 'tok')),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SingleChildScrollView(
              child: TwoStepSection(signedIn: signedIn, proveSyncPassword: syncsToCloud ? prove : null),
            ),
          ),
        ),
      ));
      await settle(tester);
    }

    /// Every condition holds: the row asks, with its reason, Type it and Not now.
    Future<void> expectAsked(WidgetTester tester) async {
      await pump(tester);
      final row = find.byKey(ask);
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(l10n.recoveryProofAskTitle)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(l10n.recoveryProofAskBody)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(l10n.recoveryProofAskAction)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(l10n.notNow)), findsOneWidget);
    }

    testWidgets('signed out: nothing is asked', (tester) async {
      await expectAsked(tester);
      await pump(tester, signedIn: false);
      expect(find.byKey(ask), findsNothing);
    });

    testWidgets('two-step sign-in off: nothing is asked', (tester) async {
      await expectAsked(tester);
      cloud.state = {...cloud.state, 'on': false, 'authenticator': false, 'recovery_codes': 0};
      await pump(tester);
      expect(find.text(l10n.twoStepSectionOffDesc), findsOneWidget);
      expect(find.byKey(ask), findsNothing);
    });

    testWidgets('ZestSSH Cloud has the recovery proof: nothing is asked', (tester) async {
      await expectAsked(tester);
      cloud.state = {...cloud.state, 'recovery_proof': true};
      await pump(tester);
      expect(find.text(l10n.twoStepSectionOnDesc), findsOneWidget);
      expect(find.byKey(ask), findsNothing);
    });

    testWidgets('sync not on ZestSSH Cloud on this device: nothing is asked', (tester) async {
      await expectAsked(tester);
      await pump(tester, syncsToCloud: false);
      expect(find.text(l10n.twoStepSectionOnDesc), findsOneWidget);
      expect(find.byKey(ask), findsNothing);
    });

    testWidgets('Not now said before on this device: nothing is asked', (tester) async {
      await expectAsked(tester);
      await pump(tester, savedPrefs: {'recovery_proof_ask_dismissed': true});
      expect(find.text(l10n.twoStepSectionOnDesc), findsOneWidget);
      expect(find.byKey(ask), findsNothing);
    });

    testWidgets('a server before 3.3, which keeps no recovery proof: nothing is asked', (tester) async {
      await expectAsked(tester);
      cloud.older = true;
      await pump(tester);
      expect(find.byKey(const ValueKey('authenticator-remove')), findsOneWidget, reason: 'the older card');
      expect(find.byKey(ask), findsNothing);
    });

    testWidgets('Not now: the row goes, for good on this device, and nothing is asked', (tester) async {
      await expectAsked(tester);
      await tapKey(tester, 'recovery-proof-not-now');
      expect(find.byKey(ask), findsNothing);
      expect(prefs.getBool('recovery_proof_ask_dismissed'), isTrue);
      expect(proved, 0);
      // The next time the page is opened, still nothing.
      await pump(tester, savedPrefs: {'recovery_proof_ask_dismissed': prefs.getBool('recovery_proof_ask_dismissed')!});
      expect(find.byKey(ask), findsNothing);
      expect(find.byKey(const ValueKey('two-step-codes')), findsOneWidget);
    });

    testWidgets('Type it: once proved and the proof is there, the row goes and says so', (tester) async {
      await expectAsked(tester);
      final reads = cloud.reads;
      await tapKey(tester, 'recovery-proof-type');
      expect(proved, 1);
      expect(cloud.reads, greaterThan(reads), reason: 'what ZestSSH Cloud holds now is read');
      expect(find.byKey(ask), findsNothing);
      expect(find.text(l10n.recoveryProofAskDone), findsOneWidget);
      expect(find.byKey(const ValueKey('two-step-problem')), findsNothing);
    });

    testWidgets('Type it, proved, and ZestSSH Cloud still holds no proof: said, and the row stays', (tester) async {
      await pump(tester, registers: false);
      await tapKey(tester, 'recovery-proof-type');
      expect(proved, 1);
      expect(find.text(l10n.recoveryProofAskNotKept), findsOneWidget);
      expect(find.byKey(const ValueKey('two-step-problem')), findsOneWidget, reason: 'with Copy details');
      expect(find.byKey(ask), findsOneWidget);
    });

    testWidgets('Type it, then backed out or a wrong password: the row stays, and the section adds nothing',
        (tester) async {
      await pump(tester, answer: false);
      await tapKey(tester, 'recovery-proof-type');
      expect(proved, 1);
      expect(find.byKey(ask), findsOneWidget);
      expect(find.byKey(const ValueKey('two-step-notice')), findsNothing);
      expect(find.byKey(const ValueKey('two-step-problem')), findsNothing);
      expect(prefs.getBool('recovery_proof_ask_dismissed'), isNull, reason: 'asked again next time');
    });
  });

  group('the Account page', () {
    const params = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
    const password = 'correct horse battery staple';
    late Uint8List salt;
    late SecretKey dek;
    late SecretKey mek;
    late Uint8List verHash;

    setUpAll(() async {
      salt = SyncService.generateSalt();
      dek = SyncService.generateDek();
      mek = await SyncService.deriveKey(password, salt, params: params);
      verHash = await SyncService.computeVerificationHash(mek);
    });

    late _Cloud cloud;
    late _ProofToCloud proof;

    /// Whether [message] shows, on screen or as a desktop notification.
    bool shows(WidgetTester tester, String message) {
      if (find.text(message).evaluate().isNotEmpty) return true;
      final container = ProviderScope.containerOf(tester.element(find.byType(Navigator).first));
      return container.read(notificationCenterProvider).history.any((n) => n.title == message || n.body == message);
    }

    /// The Account page of an account with two-step sign-in on and no
    /// recovery proof, with sync set up here on ZestSSH Cloud ([hosted]: a
    /// store of the person's own where false; [setUp] and [juiced] turn the
    /// setup and the hosting off).
    Future<void> pumpAccount(WidgetTester tester, {bool hosted = true, bool setUp = true, bool juiced = true}) async {
      FlutterSecureStorage.setMockInitialValues({
        if (setUp) 'sync_setup_complete': 'true',
        'sync_dek': base64Encode(await tester.runAsync(dek.extractBytes) as List<int>),
        'sync_verification_hash': base64Encode(verHash),
        'sync_argon2_params': jsonEncode(params),
        'sync_salt': base64Encode(salt),
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final settings = SettingsService(prefs);
      final backend = MemoryStoreBackend(MemoryStore());
      await tester.runAsync(() async {
        const storage = FlutterSecureStorage();
        final v = await backend.push(
          data: await memoryDataService(db, storage, settings).gatherAll(),
          dek: dek,
          salt: salt,
          verificationHash: verHash,
          wrappedDekPassword: await SyncService.wrapDek(dek, mek),
          createOnly: true,
          argon2Params: params,
        );
        await settings.setSyncServerVersion(v.version);
      });
      cloud = _Cloud();
      proof = _ProofToCloud(cloud);
      final client = MockClient(cloud.answer);
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        key: UniqueKey(),
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          treeDatabaseProvider.overrideWithValue(db),
          currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'you@example.com')),
          recordingModeProvider.overrideWith((ref) => false),
          syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 5, 12))),
          syncIsBringYourOwnProvider.overrideWithValue(!hosted),
          isCloudSyncProvider.overrideWith((ref) => _Juiced(juiced)),
          syncBackendProvider.overrideWithValue(backend),
          recoveryProofServiceProvider.overrideWithValue(proof),
          autoSyncServiceProvider.overrideWith((ref) => AutoSyncService(
                syncDataService: ref.watch(syncDataServiceProvider),
                settingsService: ref.watch(settingsServiceProvider),
                secureStorage: ref.watch(secureStorageProvider),
                resolveBackend: () => backend,
              )),
          signsInWithFirebaseProvider.overrideWithValue(true),
          passkeyWayProvider.overrideWith((ref) async => PasskeyWay.none),
          twoStepApiProvider.overrideWithValue(
              TwoStepApi(client: client, baseUrl: 'https://cloud.test/v1', bearer: () async => 'tok')),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: SingleChildScrollView(child: ProfileScreen(embedded: true))),
        ),
      ));
      await settle(tester, rounds: 12);
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 5));
    }

    /// Types [typed] into the sync password dialog Type it opened.
    Future<void> typePassword(WidgetTester tester, String typed) async {
      await tapKey(tester, 'recovery-proof-type');
      final dialog = find.byType(Dialog);
      expect(find.descendant(of: dialog, matching: find.text(l10n.recoveryProofAskTitle)), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text(l10n.recoveryProofAskBody)), findsOneWidget);
      await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), typed);
      await tester.pump();
      await tester.tap(find.descendant(of: dialog, matching: find.text(l10n.profileContinue)));
    }

    testWidgets('Type it asks for the sync password; the right one registers its proof, and the row goes',
        (tester) async {
      await pumpAccount(tester);
      expect(find.byKey(ask), findsOneWidget);
      await typePassword(tester, password);
      await settleUntil(tester, () => find.text(l10n.recoveryProofAskDone).evaluate().isNotEmpty);

      expect(proof.asked, hasLength(1), reason: 'registered once, with the key of the password typed');
      expect(await tester.runAsync(proof.asked.single.extractBytes), await tester.runAsync(mek.extractBytes));
      expect(find.text(l10n.recoveryProofAskDone), findsOneWidget);
      expect(find.byKey(ask), findsNothing);
      await finish(tester);
    });

    testWidgets('a wrong sync password: said as Sync now says it, nothing registered, and the row stays',
        (tester) async {
      await pumpAccount(tester);
      await typePassword(tester, 'not the password');
      await settleUntil(tester, () => shows(tester, l10n.profileIncorrectSyncPassword));

      expect(shows(tester, l10n.profileIncorrectSyncPassword), isTrue);
      expect(proof.asked, isEmpty);
      expect(cloud.state['recovery_proof'], isFalse);
      expect(find.byKey(ask), findsOneWidget);
      await finish(tester);
    });

    testWidgets("sync to a store of the person's own: nothing is asked (no proof keeps data there)", (tester) async {
      await pumpAccount(tester);
      expect(find.byKey(ask), findsOneWidget);
      await pumpAccount(tester, hosted: false);
      expect(find.text(l10n.accountMasterPassword), findsWidgets, reason: 'sync is set up');
      expect(find.byKey(ask), findsNothing);
      await finish(tester);
    });

    testWidgets('sync not set up on this device: nothing is asked', (tester) async {
      await pumpAccount(tester);
      expect(find.byKey(ask), findsOneWidget);
      await pumpAccount(tester, setUp: false);
      expect(find.byKey(const ValueKey('two-step-status')), findsOneWidget);
      expect(find.byKey(ask), findsNothing);
      await finish(tester);
    });

    testWidgets('sync on ZestSSH Cloud not on (no hosting): nothing is asked', (tester) async {
      await pumpAccount(tester);
      expect(find.byKey(ask), findsOneWidget);
      await pumpAccount(tester, juiced: false);
      expect(find.byKey(const ValueKey('two-step-status')), findsOneWidget);
      expect(find.byKey(ask), findsNothing);
      await finish(tester);
    });
  });

  test('one word for each idea: the recovery and the sync password, as the recovery itself says them', () {
    // The recovery, as its own words name it in each language.
    const recovery = {
      'en': 'recovery',
      'de': 'wiederherstellung',
      'es': 'recuperación',
      'fr': 'récupération',
      'it': 'recupero',
      'pt': 'recuperação',
      'zh': '恢复',
      'ja': '復旧',
      'ko': '복구',
      'ru': 'восстановлени',
      'hi': 'रिकवरी',
      'ar': 'الاسترداد',
    };
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      final word = recovery[locale.languageCode]!;
      final syncPassword = t.lockoutSyncPasswordLabel.toLowerCase();
      expect(t.lockoutNoProofBody.toLowerCase(), contains(word), reason: '$locale: the recovery names itself so');
      for (final s in [t.recoveryProofAskTitle, t.recoveryProofAskBody]) {
        expect(s.toLowerCase(), contains(word), reason: '$locale: $s');
      }
      for (final s in [t.recoveryProofAskBody, t.recoveryProofAskNotKept]) {
        expect(s.toLowerCase(), contains(syncPassword), reason: '$locale: $s');
      }
      if (locale.languageCode != 'en') {
        expect(t.recoveryProofAskBody, isNot(l10n.recoveryProofAskBody), reason: '$locale');
      }
    }
  });
}

/// ZestSSH Cloud's two-step routes, as far as the section reads them.
class _Cloud {
  Map<String, Object?> state = {
    'on': true,
    'authenticator': true,
    'passkeys': 0,
    'recovery_codes': 8,
    'passkeys_available': true,
    'recovery_proof': false,
    'lockout_recovery': null,
  };

  /// A server before 3.3: no GET /v1/account/two-step.
  bool older = false;

  int reads = 0;

  http.Response json(int status, Object body) => http.Response(jsonEncode(body), status);

  Future<http.Response> answer(http.Request r) async {
    switch ((r.method, r.url.path)) {
      case ('GET', '/v1/account/two-step'):
        reads++;
        if (older) return json(404, {'error': 'Not found'});
        return json(200, state);
      case ('GET', '/v1/account/recovery-codes'):
        return json(200, {'two_step': state['on'], 'count': state['recovery_codes']});
      case ('GET', '/v1/account/passkeys'):
        return json(200, {'passkeys': const []});
    }
    return json(404, {'error': 'Not found'});
  }
}

/// The recovery proof's registration: noted, and ZestSSH Cloud then holds a
/// proof, as it does once one is registered.
class _ProofToCloud extends RecoveryProofSpy {
  _ProofToCloud(this.cloud);

  final _Cloud cloud;

  @override
  Future<void> register(SecretKey mek) async {
    await super.register(mek);
    cloud.state = {...cloud.state, 'recovery_proof': true};
  }
}

class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced(super.on);

  @override
  Future<void> refresh() async {}

  @override
  void signedOut() => state = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
