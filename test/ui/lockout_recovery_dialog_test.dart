import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/services/account/lockout_recovery.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/profile/widgets/lockout_recovery_dialog.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_words.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Recovering an account that lost every second step and every recovery
/// code (3.3; the two-step contract, sections 6.5 and 7.5 to 7.6): the
/// address and the emailed code of this ask, the seven days, then the sync
/// password proved (tries left said, and past the last only a reset) or a
/// reset said plainly first; a recovery that is gone forgotten with its
/// ticket.
void main() {
  setUpAll(initializeDateFormatting);
  final l10n = lookupAppLocalizations(const Locale('en'));
  // The days a wait ends, ahead of whenever the test runs (they were fixed
  // dates, 6 and 7 November 2026, which had passed by the time it ran next).
  final today = DateTime.now().toUtc();
  final waitEnds = DateTime.utc(today.year, today.month, today.day + 3, 9);
  final notYetUntil = DateTime.utc(today.year, today.month, today.day + 4, 9);
  final storage = const FlutterSecureStorage();

  late List<http.Request> sent;
  late List<http.Response> answers;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    sent = [];
    answers = [];
  });

  http.Response json(int status, Object body) => http.Response(jsonEncode(body), status);

  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester tester, {String? email = 'sam@example.com', UserProfile? signedIn}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        currentUserProvider.overrideWith((_) => signedIn),
        twoStepApiProvider.overrideWithValue(TwoStepApi(
          baseUrl: 'https://cloud.test/v1',
          bearer: () async => null,
          client: MockClient((request) async {
            sent.add(request);
            return answers.removeAt(0);
          }),
        )),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showLockoutRecovery(context, email: email), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  Map<String, dynamic> bodyOf(http.Request r) => jsonDecode(r.body) as Map<String, dynamic>;

  testWidgets('asks with the address, takes the emailed code of this ask, keeps the ticket, and says until when',
      (tester) async {
    answers = [
      json(202, {'sent': true, 'ask_id': 'YXNrLWlk'}),
      json(400, {'code': 'recovery-code-invalid'}),
      json(200, {'ticket': 'dGlja2V0', 'completes_at': waitEnds.toIso8601String(), 'proof': null}),
    ];
    await pump(tester);
    expect(find.text(l10n.lockoutIntro), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('lockout-email'))).controller!.text, 'sam@example.com');
    await tester.tap(find.byKey(const ValueKey('lockout-send')));
    await settle(tester);
    expect(bodyOf(sent.single), {'email': 'sam@example.com'});
    expect(sent.single.headers.containsKey('Authorization'), isFalse, reason: 'nobody is signed in');
    expect(find.text(l10n.lockoutCodeSent('sam@example.com')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('lockout-code')), '1234 5678');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lockout-confirm')));
    await settle(tester);
    expect(bodyOf(sent[1]), {'email': 'sam@example.com', 'ask_id': 'YXNrLWlk', 'code': '12345678'});
    expect(find.text(l10n.lockoutCodeInvalid), findsOneWidget);
    expect(find.text(l10n.twoStepErrorCode('recovery-code-invalid')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lockout-confirm')));
    await settle(tester);
    expect(find.byKey(const ValueKey('lockout-waiting')), findsOneWidget);
    expect(find.text(l10n.lockoutWaitingSelfBody('sam@example.com', dayWords(l10n, waitEnds))),
        findsOneWidget);
    final kept = (await LockoutRecoveryStore(storage).read())!;
    expect((kept.email, kept.ticket, kept.proof), ('sam@example.com', 'dGlja2V0', null));
  });

  testWidgets('a recovery that waits here opens at its stage; Forget asks first, and the ticket goes', (tester) async {
    await LockoutRecoveryStore(storage).save(WaitingLockout(
        email: 'sam@example.com', ticket: 'dGlja2V0', completesAt: DateTime.now().add(const Duration(days: 3))));
    await pump(tester, email: null);
    expect(find.byKey(const ValueKey('lockout-waiting')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lockout-forget')));
    await settle(tester);
    expect(find.text(l10n.lockoutForgetBody), findsOneWidget);
    // Asked in the same dialog, not a second one over it (the dialog rules,
    // 3.4), and Cancel there goes back to where it was.
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    await tester.tap(find.text(l10n.cancel));
    await settle(tester);
    expect(find.byKey(const ValueKey('lockout-waiting')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lockout-forget')));
    await settle(tester);
    await tester.tap(find.text(l10n.lockoutForget).last);
    await settle(tester);
    expect(await LockoutRecoveryStore(storage).read(), isNull);
    expect(find.byKey(const ValueKey('lockout-recovery')), findsNothing);
    expect(sent, isEmpty, reason: 'forgetting it here is this device\'s alone');
  });

  testWidgets('on its day, with nothing to prove: what a reset loses, said plainly first, then the reset',
      (tester) async {
    await LockoutRecoveryStore(storage).save(WaitingLockout(
        email: 'sam@example.com', ticket: 'dGlja2V0', completesAt: DateTime.now().subtract(const Duration(hours: 1))));
    answers = [json(200, {'recovered': true, 'with_data': false})];
    await pump(tester, email: null);
    expect(find.byKey(const ValueKey('lockout-reset-only')), findsOneWidget);
    expect(find.text(l10n.lockoutNoProofBody), findsOneWidget);
    for (final line in [l10n.lockoutResetLosesData, l10n.lockoutResetLosesTeams, l10n.lockoutResetLosesDevices]) {
      expect(find.text(line), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('lockout-reset')));
    await settle(tester);
    expect(find.text(l10n.lockoutResetTitle), findsOneWidget);
    expect(find.byType(ZestDialogShell), findsOneWidget, reason: 'asked in place, not in a dialog over it');
    expect(sent, isEmpty, reason: 'nothing before the yes');
    await tester.tap(find.text(l10n.lockoutResetConfirm).last);
    await settle(tester);
    expect(bodyOf(sent.single), {'email': 'sam@example.com', 'ticket': 'dGlja2V0', 'reset': true});
    expect(find.byKey(const ValueKey('lockout-done')), findsOneWidget);
    expect(find.text(l10n.lockoutDoneReset), findsOneWidget);
    expect(await LockoutRecoveryStore(storage).read(), isNull);
  });

  // Found in a security review: the ticket kept here
  // may have been left days ago on a computer someone else now uses.
  testWidgets('a ticket too old to reset with: the address is shown again with a new code, then the reset goes on',
      (tester) async {
    final past = DateTime.now().toUtc().subtract(const Duration(hours: 1));
    await LockoutRecoveryStore(storage).save(WaitingLockout(email: 'sam@example.com', ticket: 'b2xk', completesAt: past));
    answers = [
      json(409, {'code': 'recovery-confirm-again'}),
      json(202, {'sent': true, 'ask_id': 'YXNrLWlk'}),
      json(200, {'ticket': 'bmV3', 'completes_at': past.toIso8601String(), 'proof': null}),
      json(200, {'recovered': true, 'with_data': false}),
    ];
    await pump(tester, email: null);
    await tester.tap(find.byKey(const ValueKey('lockout-reset')));
    await settle(tester);
    await tester.tap(find.text(l10n.lockoutResetConfirm).last);
    await settle(tester);
    expect(bodyOf(sent[0]), {'email': 'sam@example.com', 'ticket': 'b2xk', 'reset': true});
    expect(bodyOf(sent[1]), {'email': 'sam@example.com'}, reason: 'a new code is asked for');
    expect(find.text(l10n.lockoutResetCodeSent('sam@example.com')), findsOneWidget);
    expect(find.byKey(const ValueKey('lockout-done')), findsNothing, reason: 'nothing is reset with the old ticket');

    await tester.enterText(find.byKey(const ValueKey('lockout-code')), '12345678');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('lockout-confirm')));
    await settle(tester);
    expect(bodyOf(sent[2]), {'email': 'sam@example.com', 'ask_id': 'YXNrLWlk', 'code': '12345678'});
    expect(bodyOf(sent[3]), {'email': 'sam@example.com', 'ticket': 'bmV3', 'reset': true},
        reason: 'the reset the person confirmed goes on with the new ticket');
    expect(find.byKey(const ValueKey('lockout-done')), findsOneWidget);
    expect(await LockoutRecoveryStore(storage).read(), isNull);
  });

  testWidgets('with the sync password: a wrong one says the tries left, and past the last only a reset is left',
      (tester) async {
    const params = {'version': 1, 'memory': 65536, 'iterations': 3, 'parallelism': 4};
    await LockoutRecoveryStore(storage).save(WaitingLockout(
      email: 'sam@example.com',
      ticket: 'dGlja2V0',
      completesAt: DateTime.now().subtract(const Duration(hours: 1)),
      proof: RecoveryProofAsk(challenge: 'Y2hhbGxlbmdl', salt: SyncService.generateSalt(), argon2Params: params),
    ));
    await LockoutRecoveryStore(storage).rememberAccount('sam@example.com', 'uid-1');
    answers = [
      json(400, {'code': 'recovery-proof-invalid', 'tries_left': 9}),
      json(409, {'code': 'recovery-proof-closed'}),
    ];
    await pump(tester, email: null);
    expect(find.text(l10n.lockoutDueBodyProof('sam@example.com')), findsOneWidget);

    Future<void> keep() async {
      await tester.enterText(find.byKey(const ValueKey('lockout-sync-password')), 'not the password');
      await settle(tester, rounds: 2);
      await tester.tap(find.byKey(const ValueKey('lockout-keep-data')));
      // The sync password's key takes a moment to work out.
      for (var i = 0; i < 60 && find.byKey(const ValueKey('lockout-problem')).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settle(tester);
    }

    await keep();
    final proof = bodyOf(sent.single);
    expect(proof.keys, unorderedEquals(['email', 'ticket', 'proof']));
    expect(base64Url.decode(base64Url.normalize(proof['proof'] as String)), hasLength(64), reason: 'an Ed25519 signature');
    expect(find.text(l10n.lockoutProofInvalid(9)), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await pump(tester, email: null);
    await keep();
    expect(find.byKey(const ValueKey('lockout-reset-only')), findsOneWidget);
    expect(find.text(l10n.lockoutProofClosed), findsWidgets);
    expect(find.byKey(const ValueKey('lockout-sync-password')), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('this device cannot sign for the account: it says so, and offers the reset', (tester) async {
    await LockoutRecoveryStore(storage).save(WaitingLockout(
      email: 'sam@example.com',
      ticket: 'dGlja2V0',
      completesAt: DateTime.now().subtract(const Duration(hours: 1)),
      proof: RecoveryProofAsk(challenge: 'Y2g', salt: SyncService.generateSalt()),
    ));
    await pump(tester, email: null);
    expect(find.text(l10n.lockoutCannotProveHere), findsOneWidget);
    expect(find.byKey(const ValueKey('lockout-reset')), findsOneWidget);
  });

  testWidgets('the account signed in here is the one it signs for', (tester) async {
    await LockoutRecoveryStore(storage).save(WaitingLockout(
      email: 'Sam@Example.com',
      ticket: 'dGlja2V0',
      completesAt: DateTime.now().subtract(const Duration(hours: 1)),
      proof: RecoveryProofAsk(challenge: 'Y2g', salt: SyncService.generateSalt()),
    ));
    await pump(tester, email: null, signedIn: const UserProfile(uid: 'uid-1', email: 'sam@example.com'));
    expect(find.byKey(const ValueKey('lockout-sync-password')), findsOneWidget);
  });

  testWidgets('a recovery that is gone (cancelled from a signed-in device): said, its ticket forgotten, ask again',
      (tester) async {
    await LockoutRecoveryStore(storage).save(WaitingLockout(
        email: 'sam@example.com', ticket: 'dGlja2V0', completesAt: DateTime.now().subtract(const Duration(hours: 1))));
    answers = [json(400, {'code': 'recovery-ticket-invalid'})];
    await pump(tester, email: null);
    await tester.tap(find.byKey(const ValueKey('lockout-reset')));
    await settle(tester);
    await tester.tap(find.text(l10n.lockoutResetConfirm).last);
    await settle(tester);
    expect(find.text(l10n.lockoutTicketInvalid), findsOneWidget);
    expect(find.byKey(const ValueKey('lockout-email')), findsOneWidget, reason: 'back at asking');
    expect(await LockoutRecoveryStore(storage).read(), isNull);
  });

  testWidgets('not yet: the day is said, and kept', (tester) async {
    await LockoutRecoveryStore(storage).save(WaitingLockout(
        email: 'sam@example.com', ticket: 'dGlja2V0', completesAt: DateTime.now().subtract(const Duration(hours: 1))));
    answers = [json(409, {'code': 'recovery-not-yet', 'completes_at': notYetUntil.toIso8601String()})];
    await pump(tester, email: null);
    await tester.tap(find.byKey(const ValueKey('lockout-reset')));
    await settle(tester);
    await tester.tap(find.text(l10n.lockoutResetConfirm).last);
    await settle(tester);
    expect(find.text(l10n.lockoutNotYet(dayWords(l10n, notYetUntil))), findsOneWidget);
    expect(find.byKey(const ValueKey('lockout-waiting')), findsOneWidget);
    expect((await LockoutRecoveryStore(storage).read())!.completesAt.toUtc(), notYetUntil);
  });
}
