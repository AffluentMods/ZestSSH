import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
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
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_confirm.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_dialogs.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_section.dart';
import 'package:zestssh/ui/screens/profile/widgets/two_step_words.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';

import '../helpers/soft_passkeys.dart';

/// Two-step sign-in on the account's Security section (3.3): the state as
/// ZestSSH Cloud says it, a recovery someone asked for with This wasn't me,
/// passkeys added (the device's own ceremony; the first one turns two-step
/// sign-in on, and the device signs in again with it before the recovery
/// codes), renamed and removed, the authenticator, turning it all off; how
/// many devices each change signed out; every error with its code and Copy
/// details; a computer's fresh ID token from the browser where a change
/// needs one. One or the other: Firebase holds
/// one TOTP factor per account, which the played Firebase and ZestSSH Cloud
/// below hold to, so an account has passkeys or the authenticator app, and
/// replacing one with the other is asked first.
void main() {
  setUpAll(initializeDateFormatting);
  final l10n = lookupAppLocalizations(const Locale('en'));

  late _Cloud cloud;
  late _Confirm confirm;
  late ScriptedPasskeys passkeys;
  late _Firebase firebase;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    firebase = _Firebase();
    cloud = _Cloud(firebase);
    confirm = _Confirm();
    passkeys = ScriptedPasskeys();
  });

  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    bool phone = true,
    bool signedIn = true,
    PasskeyWay way = PasskeyWay.here,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = MockClient(cloud.answer);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: 'uid-1', email: 'sam@example.com')),
        signsInWithFirebaseProvider.overrideWithValue(phone),
        passkeyWayProvider.overrideWith((ref) async => way),
        passkeyPlatformProvider.overrideWithValue(passkeys),
        twoStepConfirmProvider.overrideWithValue(confirm),
        authenticatorEnrollerProvider.overrideWithValue(() => phone ? firebase : null),
        twoStepApiProvider.overrideWithValue(
            TwoStepApi(client: client, baseUrl: 'https://cloud.test/v1', bearer: () async => 'tok')),
        recoveryCodesApiProvider.overrideWithValue(
            RecoveryCodesApi(client: client, baseUrl: 'https://cloud.test/v1', bearer: () async => 'tok')),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: TwoStepSection(signedIn: signedIn))),
      ),
    ));
    await settle(tester);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await tester.ensureVisible(f);
    await tester.tap(f);
    await settle(tester);
  }

  /// Presses the confirmation's button that reads [label].
  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await settle(tester);
  }

  testWidgets('the account as ZestSSH Cloud says it: passkeys by name, kind, sync and day, never when last used',
      (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'passkeys': 2, 'recovery_codes': 8};
    cloud.passkeys = [
      _passkey('a', 'Passkey on Android', synced: true),
      _passkey('b', 'YubiKey', kind: 'security-key'),
    ];
    await pump(tester);
    expect(find.text(l10n.twoStepSectionOnDesc), findsOneWidget);
    expect(find.text('Passkey on Android'), findsOneWidget);
    expect(find.text('YubiKey'), findsOneWidget);
    expect(find.text('Passkey · Synced · Added October 30, 2026'), findsOneWidget);
    expect(find.text('Security key · Stays on the key · Added October 30, 2026'), findsOneWidget);
    expect(find.text(l10n.authenticatorInsteadDesc), findsOneWidget, reason: 'one or the other');
    expect(find.text(l10n.twoStepRule), findsOneWidget);
    expect(find.text(l10n.twoStepCodesRowDescAny(8)), findsOneWidget);
    expect(find.textContaining('ast used'), findsNothing);
    expect(find.byKey(const ValueKey('lockout-waiting-banner')), findsNothing);
  });

  testWidgets("a recovery someone asked for shows first; This wasn't me ends it at once, with no new sign-in",
      (tester) async {
    cloud.state = {
      ...cloud.state,
      'on': true,
      'authenticator': true,
      'lockout_recovery': {'requested_at': '2026-10-30T09:00:00.000Z', 'completes_at': '2026-11-06T09:00:00.000Z'},
    };
    await pump(tester);
    final banner = find.byKey(const ValueKey('lockout-waiting-banner'));
    expect(banner, findsOneWidget);
    expect(find.descendant(of: banner, matching: find.textContaining('sam@example.com')), findsOneWidget);
    expect(find.descendant(of: banner, matching: find.textContaining('November 6, 2026')), findsOneWidget);
    await tapKey(tester, 'lockout-not-me');
    expect(cloud.calls, contains('DELETE /v1/account/lockout-recovery'));
    expect(confirm.recentCalls, 0, reason: 'cancelling needs no new sign-in');
    expect(find.byKey(const ValueKey('lockout-waiting-banner')), findsNothing);
    expect(find.text(l10n.lockoutCancelled), findsOneWidget);
  });

  testWidgets('the live line says the security changed: read again, and a waiting recovery shows', (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'authenticator': true};
    await pump(tester);
    final reads = cloud.calls.where((c) => c == 'GET /v1/account/two-step').length;
    cloud.state = {
      ...cloud.state,
      'lockout_recovery': {'requested_at': '2026-10-30T09:00:00.000Z', 'completes_at': '2026-11-06T09:00:00.000Z'},
    };
    securityNudges.add(null);
    await settle(tester);
    expect(cloud.calls.where((c) => c == 'GET /v1/account/two-step').length, reads + 1);
    expect(find.byKey(const ValueKey('lockout-waiting-banner')), findsOneWidget);
  });

  testWidgets('a passkey added beside others: a name offered, the device\'s ceremony, how many were signed out',
      (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'passkeys': 1};
    cloud.passkeys = [_passkey('a', 'Passkey on Android')];
    cloud.signedOut = 2;
    await pump(tester);
    await tapKey(tester, 'passkey-add');
    final field = find.byType(TextField);
    expect(tester.widget<TextField>(field).controller!.text, defaultPasskeyName(l10n));
    await tester.enterText(field, 'Work laptop');
    await press(tester, l10n.passkeyAddContinue);
    expect(passkeys.created.single['challenge'], 'Y2g');
    expect(cloud.added.single['name'], 'Work laptop');
    expect(cloud.added.single.containsKey('id_token'), isFalse, reason: 'the bridge is there already');
    expect(find.text('Work laptop'), findsOneWidget);
    expect(find.textContaining(l10n.passkeyAdded('Work laptop')), findsOneWidget);
    expect(find.textContaining(l10n.twoStepSignedOutOthers(2)), findsOneWidget);
  });

  testWidgets('the first passkey on a phone: said first; the phone signs in again with it, then the recovery codes',
      (tester) async {
    await pump(tester);
    expect(find.text(l10n.twoStepSectionOffDesc), findsOneWidget);
    await tapKey(tester, 'passkey-add');
    expect(find.text(l10n.twoStepFirstStepBody), findsOneWidget);
    await press(tester, l10n.profileContinue);
    await press(tester, l10n.passkeyAddContinue);
    expect(confirm.recentCalls, 1, reason: 'the bridge wants a sign-in from the last five minutes');
    expect(cloud.added, hasLength(1));
    // Two-step sign-in is on now, and this phone's sign-in never passed it.
    expect(find.text(l10n.twoStepFirstStepSignInAgain), findsOneWidget);
    await press(tester, l10n.profileContinue);
    expect(confirm.recentCalls, 2);
    expect(cloud.calls, contains('POST /v1/account/recovery-codes'));
    expect(find.byType(RecoveryCodesDialog), findsOneWidget);
    expect(find.text('abcde-fghj0'), findsOneWidget);
  });

  testWidgets('the system\'s passkey window closed: nothing added, said as no error', (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'passkeys': 1};
    cloud.passkeys = [_passkey('a', 'Passkey on Android')];
    passkeys.onCreate = (_) async => throw const PasskeyCancelled();
    await pump(tester);
    await tapKey(tester, 'passkey-add');
    await press(tester, l10n.passkeyAddContinue);
    expect(cloud.added, isEmpty);
    expect(find.text(l10n.passkeyAddCancelled), findsOneWidget);
    expect(find.byKey(const ValueKey('two-step-problem')), findsNothing);
  });

  testWidgets('every error says what happened, what to do, its code and Copy details', (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'passkeys': 1};
    cloud.passkeys = [_passkey('a', 'Passkey on Android')];
    cloud.refuseAdd = {'code': 'passkey-exists'};
    await pump(tester);
    await tapKey(tester, 'passkey-add');
    await press(tester, l10n.passkeyAddContinue);
    final box = find.byKey(const ValueKey('two-step-problem'));
    expect(find.descendant(of: box, matching: find.text(l10n.passkeyExists)), findsOneWidget);
    expect(find.descendant(of: box, matching: find.text(l10n.twoStepErrorCode('passkey-exists'))), findsOneWidget);
    expect(find.descendant(of: box, matching: find.byType(CopyDetailsButton)), findsOneWidget);
  });

  testWidgets('removing the last second step says so first; a sign-in too old is confirmed and it is tried again',
      (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'passkeys': 1};
    cloud.passkeys = [_passkey('a', 'Passkey on Android')];
    cloud.recentFirst = true;
    await pump(tester);
    await tapKey(tester, 'passkey-remove-a');
    expect(find.text(l10n.passkeyRemoveLastBody), findsOneWidget);
    await press(tester, l10n.passkeyRemove);
    expect(confirm.recentCalls, 1);
    expect(cloud.calls.where((c) => c == 'DELETE /v1/account/passkeys/a'), hasLength(2));
    expect(find.textContaining(l10n.passkeyRemovedOff('Passkey on Android')), findsOneWidget);
    expect(find.textContaining(l10n.passkeyStaysElsewhere), findsOneWidget);
    expect(find.text(l10n.twoStepSectionOffDesc), findsOneWidget);
  });

  testWidgets('renaming a passkey', (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'passkeys': 1};
    cloud.passkeys = [_passkey('a', 'Passkey on Android')];
    await pump(tester);
    await tapKey(tester, 'passkey-rename-a');
    await tester.enterText(find.byType(TextField), 'Old phone');
    await press(tester, l10n.passkeyRename);
    expect(find.text('Old phone'), findsOneWidget);
    expect(find.textContaining(l10n.passkeyRenamed('Old phone')), findsOneWidget);
  });

  testWidgets('a computer removing the authenticator, its only second step: said first, the browser opens, says so '
      'first, and its ID token goes with the change', (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'authenticator': true};
    cloud.recentFirst = true;
    await pump(tester, phone: false);
    await tapKey(tester, 'authenticator-remove');
    expect(find.text(l10n.authenticatorRemoveLastBody), findsOneWidget);
    await press(tester, l10n.authenticatorRemove);
    expect(find.text(l10n.twoStepBrowserOpens), findsOneWidget);
    await press(tester, l10n.profileContinue);
    expect(confirm.idTokenCalls, [true], reason: "the computer's session traded for the browser's sign-in");
    expect(cloud.authenticatorBodies.last, {'id_token': 'handed-id-token'});
    expect(find.textContaining(l10n.authenticatorRemovedOff), findsOneWidget);
  });

  testWidgets('a computer: the authenticator is set up on zestssh.com; Linux and the Mac add passkeys in the browser',
      (tester) async {
    await pump(tester, phone: false, way: PasskeyWay.browser);
    expect(find.byKey(const ValueKey('authenticator-web')), findsOneWidget);
    expect(find.byKey(const ValueKey('authenticator-set-up')), findsNothing);
    expect(find.text(l10n.passkeysBrowserDesc), findsOneWidget);
    // The first passkey, added in the browser, signed this computer's own
    // sign-in out: it signs in again.
    await tapKey(tester, 'passkey-add');
    await press(tester, l10n.profileContinue);
    expect(find.text(l10n.twoStepBrowserOpens), findsOneWidget);
    await press(tester, l10n.profileContinue);
    expect(confirm.browserAdds, 1);
    expect(find.text(l10n.twoStepBrowserFirstStepBody), findsOneWidget);
    await press(tester, l10n.profileContinue);
    expect(confirm.recentCalls, 1);
    expect(find.textContaining(l10n.passkeyBrowserAdded), findsOneWidget);
  });

  testWidgets('turning it all off says what goes', (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'passkeys': 1};
    cloud.passkeys = [_passkey('a', 'Passkey on Android')];
    cloud.signedOut = 1;
    await pump(tester);
    await tapKey(tester, 'two-step-turn-off');
    expect(find.text(l10n.twoStepTurnOffAllBody), findsOneWidget);
    await press(tester, l10n.twoStepTurnOff);
    expect(cloud.calls, contains('DELETE /v1/account/two-step'));
    expect(find.textContaining(l10n.twoStepSignedOutOthers(1)), findsOneWidget);
    expect(find.text('Passkey on Android'), findsNothing);
  });

  testWidgets('a phone without passkeys of its own lists them and can remove one, but adds none', (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'passkeys': 1};
    cloud.passkeys = [_passkey('a', 'Security key', kind: 'security-key')];
    await pump(tester, way: PasskeyWay.none);
    expect(find.text(l10n.passkeysCannotAddHere), findsOneWidget);
    expect(find.byKey(const ValueKey('passkey-add')), findsNothing);
    expect(find.byKey(const ValueKey('passkey-remove-a')), findsOneWidget);
  });

  // ── One or the other ──────────────────────────────────────────────────

  testWidgets('a passkey on an account with the authenticator app asks first, with why; kept, nothing changes; '
      'replaced, ZestSSH Cloud is asked to replace it and the section says so', (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'authenticator': true, 'recovery_codes': 10};
    firebase.factors = ['Authenticator app'];
    cloud.signedOut = 1;
    await pump(tester);
    expect(find.text(l10n.passkeysInsteadDesc), findsOneWidget);
    await tapKey(tester, 'passkey-add');
    expect(find.text(l10n.passkeyReplaceAuthenticatorTitle), findsOneWidget);
    expect(find.text(l10n.passkeyReplaceAuthenticatorBody), findsOneWidget);
    await press(tester, l10n.cancel);
    expect(cloud.calls, isNot(contains('POST /v1/account/passkeys/options')));
    expect(find.textContaining(l10n.twoStepNothingChanged), findsOneWidget);

    await tapKey(tester, 'passkey-add');
    await press(tester, l10n.passkeyReplaceAuthenticatorConfirm);
    await press(tester, l10n.passkeyAddContinue);
    expect(cloud.optionBodies.single, {'replace_authenticator': true});
    expect(cloud.added.single['replace_authenticator'], isTrue);
    expect(firebase.factors, ['Passkey'], reason: 'the authenticator went, the bridge came');
    expect(find.textContaining(l10n.passkeyReplacedAuthenticator(defaultPasskeyName(l10n))), findsOneWidget);
    expect(find.textContaining(l10n.twoStepSignedOutOthers(1)), findsOneWidget);
    expect(find.text(l10n.authenticatorOnDesc), findsNothing);
  });

  testWidgets('an authenticator app the section did not know of: ZestSSH Cloud refuses, the person is asked, and it '
      'is sent again replacing it', (tester) async {
    cloud.state = {...cloud.state, 'on': true};
    firebase.factors = ['Authenticator app'];
    cloud.authenticatorUntold = true;
    await pump(tester);
    await tapKey(tester, 'passkey-add');
    await press(tester, l10n.passkeyAddContinue);
    expect(find.text(l10n.passkeyReplaceAuthenticatorTitle), findsOneWidget);
    await press(tester, l10n.passkeyReplaceAuthenticatorConfirm);
    expect(cloud.optionBodies, [<String, dynamic>{}, {'replace_authenticator': true}]);
    expect(cloud.added.single['replace_authenticator'], isTrue);
    expect(find.byKey(const ValueKey('two-step-problem')), findsNothing);
  });

  testWidgets('the authenticator app gone and the passkey not come: said with what to do, ZS-1312 and Copy details',
      (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'authenticator': true};
    firebase.factors = ['Authenticator app'];
    cloud.loseOnReplace = true;
    await pump(tester);
    await tapKey(tester, 'passkey-add');
    await press(tester, l10n.passkeyReplaceAuthenticatorConfirm);
    await press(tester, l10n.passkeyAddContinue);
    final box = find.byKey(const ValueKey('two-step-problem'));
    expect(find.descendant(of: box, matching: find.text(l10n.twoStepAuthenticatorLost)), findsOneWidget);
    expect(
        find.descendant(
            of: box, matching: find.text(l10n.twoStepErrorCode('ZS-1312 (authenticator-removed-passkey-failed)'))),
        findsOneWidget);
    expect(find.descendant(of: box, matching: find.byType(CopyDetailsButton)), findsOneWidget);
    expect(find.text(l10n.twoStepSectionOffDesc), findsOneWidget, reason: 'read again: two-step sign-in is off');
  });

  testWidgets('a phone sets the authenticator app up in the place of its passkeys, Firebase full only at the finish: '
      'asked first; a wrong code changes nothing; the right one, and the passkeys go just before Firebase takes it',
      (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'passkeys': 1, 'recovery_codes': 10};
    cloud.passkeys = [_passkey('a', 'Passkey on Android')];
    firebase.factors = ['Passkey'];
    firebase.limitAt = 'finalize';
    await pump(tester);
    expect(find.text(l10n.authenticatorInsteadDesc), findsOneWidget);
    await tapKey(tester, 'authenticator-set-up');
    expect(find.text(l10n.authenticatorReplacePasskeysTitle), findsOneWidget);
    await press(tester, l10n.authenticatorReplacePasskeysConfirm);
    expect(confirm.recentCalls, 1);
    expect(find.byKey(const ValueKey('two-step-setup-passkeys-stay')), findsOneWidget);
    expect(firebase.calls, ['start'], reason: 'begun while the passkeys are there');

    await tester.enterText(find.byKey(const ValueKey('two-step-setup-code')), firebase.wrongCode());
    await tester.pump();
    await press(tester, l10n.authenticatorReplaceVerify);
    expect(find.text(l10n.twoStepErrorWrongCode), findsOneWidget);
    expect(cloud.calls, isNot(contains('DELETE /v1/account/two-step/passkeys')));
    expect(firebase.factors, ['Passkey'], reason: 'two-step sign-in stays on');

    await tester.enterText(find.byKey(const ValueKey('two-step-setup-code')), firebase.codeNow());
    await tester.pump();
    await press(tester, l10n.authenticatorReplaceVerify);
    expect(firebase.factors, ['Authenticator app']);
    final removed = cloud.calls.indexOf('DELETE /v1/account/two-step/passkeys');
    expect(removed, greaterThanOrEqualTo(0));
    expect(cloud.calls.indexOf('POST /v1/account/two-step/changed'), greaterThan(removed));
    expect(firebase.calls, ['start', 'enroll']);
    expect(find.textContaining(l10n.authenticatorReplacedPasskeys), findsOneWidget);
    expect(find.text('Passkey on Android'), findsNothing);
    expect(find.text(l10n.authenticatorOnDesc), findsOneWidget);
  });

  testWidgets('Firebase full at the start: the passkeys go first only once the person agrees that two-step sign-in '
      'is off until the end; stopped there, it is off, said with ZS-1312', (tester) async {
    cloud.state = {...cloud.state, 'on': true, 'passkeys': 1, 'recovery_codes': 10};
    cloud.passkeys = [_passkey('a', 'Passkey on Android')];
    firebase.factors = ['Passkey'];
    firebase.limitAt = 'start';
    await pump(tester);
    await tapKey(tester, 'authenticator-set-up');
    await press(tester, l10n.authenticatorReplacePasskeysConfirm);
    expect(find.text(l10n.authenticatorPasskeysFirstTitle), findsOneWidget);
    expect(find.text(l10n.authenticatorPasskeysFirstBody), findsOneWidget);
    await press(tester, l10n.cancel);
    expect(cloud.calls, isNot(contains('DELETE /v1/account/two-step/passkeys')));
    expect(firebase.factors, ['Passkey']);
    expect(find.textContaining(l10n.twoStepNothingChanged), findsOneWidget);

    await tapKey(tester, 'authenticator-set-up');
    await press(tester, l10n.authenticatorReplacePasskeysConfirm);
    await press(tester, l10n.authenticatorPasskeysFirstConfirm);
    expect(cloud.calls, contains('DELETE /v1/account/two-step/passkeys'));
    expect(find.text(l10n.twoStepGapNote), findsOneWidget);
    await tapKey(tester, 'two-step-setup-cancel');
    final box = find.byKey(const ValueKey('two-step-problem'));
    expect(find.descendant(of: box, matching: find.text(l10n.twoStepLeftOff)), findsOneWidget);
    expect(find.descendant(of: box, matching: find.text(l10n.twoStepErrorCode('ZS-1312'))), findsOneWidget);
    expect(find.text(l10n.twoStepSectionOffDesc), findsOneWidget, reason: 'read again: two-step sign-in is off');
  });

  testWidgets('signed out: the way to recover an account whose second step is lost, and one that waits here',
      (tester) async {
    await pump(tester, signedIn: false);
    expect(find.byKey(const ValueKey('lockout-start')), findsOneWidget);
    expect(find.text(l10n.lockoutLinkDesc), findsOneWidget);

    await LockoutRecoveryStore(const FlutterSecureStorage()).save(
        WaitingLockout(email: 'sam@example.com', ticket: 't', completesAt: DateTime(2026, 11, 6)));
    await tester.pumpWidget(const SizedBox());
    await pump(tester, signedIn: false);
    expect(find.byKey(const ValueKey('lockout-here')), findsOneWidget);
    expect(find.textContaining('November 6, 2026'), findsOneWidget);
  });
}

Map<String, Object?> _passkey(String id, String name, {String kind = 'passkey', bool synced = false}) => {
      'id': id,
      'name': name,
      'created_at': '2026-10-30T12:00:00.000Z',
      'transports': ['internal'],
      'synced': synced,
      'kind': kind,
    };

/// ZestSSH Cloud, as much of it as the section asks, holding to one or the
/// other with the played [firebase].
class _Cloud {
  _Cloud(this.firebase);

  final _Firebase firebase;

  Map<String, Object?> state = {
    'on': false,
    'authenticator': false,
    'passkeys': 0,
    'recovery_codes': 0,
    'passkeys_available': true,
    'recovery_proof': false,
    'lockout_recovery': null,
  };
  List<Map<String, Object?>> passkeys = [];
  int signedOut = 0;

  /// The first change is refused for a sign-in that is too old.
  bool recentFirst = false;
  Map<String, Object?>? refuseAdd;

  /// The account has the authenticator app, and the section was not told.
  bool authenticatorUntold = false;

  /// Replacing the authenticator app leaves the account with neither.
  bool loseOnReplace = false;

  final calls = <String>[];
  final optionBodies = <Map<String, dynamic>>[];
  final added = <Map<String, dynamic>>[];
  final authenticatorBodies = <Object?>[];

  http.Response json(int status, Object body) => http.Response(jsonEncode(body), status);

  Map<String, Object?> withCount() => {...state, 'passkeys': passkeys.length};

  Future<http.Response> answer(http.Request r) async {
    final path = r.url.path;
    calls.add('${r.method} $path');
    bool tooOld() {
      if (!recentFirst) return false;
      recentFirst = false;
      return true;
    }

    // One or the other: the first passkey of an account with the
    // authenticator app, unless asked to replace it (routes/passkeys.js).
    bool besideAuthenticator(Map<String, dynamic> body) =>
        (firebase.played ? firebase.factors.contains('Authenticator app') : state['authenticator'] == true) &&
        passkeys.isEmpty &&
        body['replace_authenticator'] != true;

    switch ((r.method, path)) {
      case ('GET', '/v1/account/two-step'):
        // Brought in line with Firebase, as every read is.
        if (firebase.played && firebase.factors.isEmpty && state['on'] == true) {
          state = {...state, 'on': false, 'authenticator': false, 'passkeys': 0, 'recovery_codes': 0};
        }
        return json(200, state);
      case ('GET', '/v1/account/passkeys'):
        return json(200, {'passkeys': passkeys});
      case ('POST', '/v1/account/passkeys/options'):
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        optionBodies.add(body);
        if (besideAuthenticator(body)) return json(409, {'code': 'authenticator-app-on'});
        return json(200, {'challenge': 'Y2g', 'rp': {'id': 'zestssh.com', 'name': 'ZestSSH'}});
      case ('POST', '/v1/account/passkeys'):
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        if (refuseAdd != null) return json(409, refuseAdd!);
        if (besideAuthenticator(body)) return json(409, {'code': 'authenticator-app-on'});
        if (body['replace_authenticator'] == true && passkeys.isEmpty) {
          firebase.factors.remove('Authenticator app');
          if (loseOnReplace) {
            state = {...state, 'on': false, 'authenticator': false, 'recovery_codes': 0};
            return json(502, {'code': 'authenticator-removed-passkey-failed', 'two_step': state});
          }
        }
        firebase.factors.add('Passkey');
        added.add(body);
        final item = _passkey('new-${added.length}', body['name'] as String);
        passkeys = [...passkeys, item];
        state = {...withCount(), 'on': true, 'authenticator': false};
        return json(201, {'passkey': item, 'two_step': state, 'signed_out': signedOut, 'notified': true});
      case ('DELETE', '/v1/account/two-step/passkeys'):
        firebase.factors.remove('Passkey');
        passkeys = [];
        state = {...withCount(), 'authenticator': false};
        return json(200, {...state, 'signed_out': 1, 'notified': true});
      case ('POST', '/v1/account/two-step/changed'):
        state = {
          ...withCount(),
          'on': firebase.factors.isNotEmpty,
          'authenticator': firebase.factors.contains('Authenticator app'),
        };
        return json(200, {...state, 'two_step': state['on'], 'signed_out': 0, 'notified': true});
      case ('POST', '/v1/account/recovery-codes'):
        return json(201, {'codes': [for (var i = 0; i < 10; i++) 'abcde-fghj$i']});
      case ('DELETE', '/v1/account/lockout-recovery'):
        state = {...state, 'lockout_recovery': null};
        return json(200, {'cancelled': true});
      case ('DELETE', '/v1/account/two-step'):
        passkeys = [];
        state = {...withCount(), 'on': false, 'authenticator': false, 'recovery_codes': 0};
        return json(200, {...state, 'signed_out': signedOut, 'notified': true});
      case ('DELETE', '/v1/account/two-step/authenticator'):
        authenticatorBodies.add(r.body.isEmpty ? null : jsonDecode(r.body));
        if (tooOld()) return json(403, {'code': 'recent-sign-in-required', 'reason': 'second-step-required'});
        state = {...withCount(), 'authenticator': false, 'on': passkeys.isNotEmpty};
        return json(200, {...state, 'signed_out': signedOut});
    }
    if (path.startsWith('/v1/account/passkeys/')) {
      final id = Uri.decodeComponent(path.split('/').last);
      if (r.method == 'PATCH') {
        final name = (jsonDecode(r.body) as Map<String, dynamic>)['name'] as String;
        passkeys = [for (final p in passkeys) p['id'] == id ? {...p, 'name': name} : p];
        return json(200, passkeys.firstWhere((p) => p['id'] == id));
      }
      if (r.method == 'DELETE') {
        if (tooOld()) return json(403, {'code': 'recent-sign-in-required', 'reason': 'second-step-required'});
        passkeys = [for (final p in passkeys) if (p['id'] != id) p];
        final on = passkeys.isNotEmpty || state['authenticator'] == true;
        state = {...withCount(), 'on': on};
        return json(200, {'two_step': state, 'signed_out': signedOut, 'notified': true});
      }
    }
    return json(404, {'error': 'not here'});
  }
}

/// The steps that leave the app, played: each goes through.
class _Confirm extends TwoStepConfirm {
  int recentCalls = 0;
  final idTokenCalls = <bool>[];
  int browserAdds = 0;

  @override
  Future<bool> recent(BuildContext context, WidgetRef ref) async {
    recentCalls++;
    return true;
  }

  @override
  Future<String?> idToken(BuildContext context, WidgetRef ref, {bool upgrade = false}) async {
    idTokenCalls.add(upgrade);
    return 'handed-id-token';
  }

  @override
  Future<bool> addPasskeyInBrowser(BuildContext context, WidgetRef ref) async {
    browserAdds++;
    return true;
  }
}

/// Firebase's side of the authenticator app, played: one TOTP factor per
/// account, as Firebase holds it ('Authenticator app' or the 'Passkey'
/// bridge), refused at the start of an enrolment or only at its finish
/// ([limitAt]) with Firebase's own code.
class _Firebase implements AuthenticatorEnroller {
  List<String> _factors = [];

  /// Whether a test set what Firebase holds: ZestSSH Cloud then goes by it.
  bool played = false;

  List<String> get factors => _factors;
  set factors(List<String> held) {
    _factors = [...held];
    played = true;
  }

  String limitAt = 'start';
  final calls = <String>[];

  /// RFC 6238's SHA-1 secret, in base32.
  static const key = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

  bool get _full => factors.isNotEmpty;

  FirebaseAuthException get _limit => FirebaseAuthException(code: 'maximum-second-factor-count-exceeded');

  String codeNow() => totpCode(base32Bytes(key)!, DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ 30)!;

  /// A code that is none of the three Firebase would take now.
  String wrongCode() {
    final step = DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ 30;
    final taken = {for (final s in [step - 1, step, step + 1, step + 2]) totpCode(base32Bytes(key)!, s)};
    for (var i = 0;; i++) {
      final c = '$i'.padLeft(6, '0');
      if (!taken.contains(c)) return c;
    }
  }

  @override
  Future<AuthenticatorSetup> start() async {
    calls.add('start');
    if (limitAt == 'start' && _full) throw _limit;
    return AuthenticatorSetup(qrUrl: 'otpauth://totp/ZestSSH:sam@example.com?secret=$key&issuer=ZestSSH', key: key);
  }

  @override
  Future<void> finish(AuthenticatorSetup setup, String code) async {
    if (_full) throw _limit;
    if (!setup.codeMatches(code)) throw FirebaseAuthException(code: 'invalid-verification-code');
    calls.add('enroll');
    factors.add('Authenticator app');
  }
}
