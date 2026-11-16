import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/services/account/browser_handoff.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/lockout_recovery.dart';
import 'package:zestssh/services/account/passkey_step_up.dart';
import 'package:zestssh/services/account/recovery_proof.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/sign_in_code.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:cryptography/cryptography.dart';

import '../../helpers/soft_passkeys.dart';

/// Two-step sign-in with passkeys (3.3) against the REAL server routes
/// (ZestSSH Cloud's routes/two_step.js, routes/passkeys.js,
/// routes/lockout_recovery.js, routes/auth.js's hand-off and upgrade, the
/// auth middleware and its gate) on a real Postgres, with Firebase, Cloud
/// KMS and mail played by the stand-in, so both sides agree on paths,
/// fields, codes and what each change does. Passkeys are made and used by a
/// software authenticator with real Ed25519 signatures. Start the server
/// first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1). A Firebase ID token there is
/// `fb:<uid>:<authTime>:<iat>[:2fa]`; the account's address is
/// `<uid>@example.com`.
void main() {
  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final root = base.replaceFirst(RegExp(r'/v1$'), '');
  final client = http.Client();
  var serverUp = false;

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String firebaseToken(String uid, {bool secondStep = false}) =>
      'fb:$uid:${now()}:${now()}${secondStep ? ':2fa' : ''}';
  String fresh(String tag) => 'ts-${now()}-${Random().nextInt(1 << 30)}-$tag';

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/account/two-step')).timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    DeviceSessionHeader.current = null;
    sessionRevokedReason = null;
  });

  String skip() => 'app contract server not running at $base';

  TwoStepApi apiWith(Future<String?> Function() bearer) => TwoStepApi(client: client, baseUrl: base, bearer: bearer);

  /// What "Firebase" holds of [uid]'s second factors in the stand-in.
  Future<List<Map<String, dynamic>>> factorsOf(String uid) async {
    final r = await client.get(Uri.parse('$root/test/two-step/$uid'));
    return [for (final f in (jsonDecode(r.body) as Map<String, dynamic>)['factors'] as List) f as Map<String, dynamic>];
  }

  Future<void> setFactors(String uid, List<String> factors) async {
    final r = await client.put(Uri.parse('$root/test/two-step/$uid'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'factors': factors}));
    expect(r.statusCode, 200, reason: r.body);
  }

  /// The mail the server would have sent to [uid]'s address, newest last.
  Future<List<Map<String, dynamic>>> mailOf(String uid) async {
    final r = await client.get(Uri.parse('$root/test/mail?to=${Uri.encodeQueryComponent('$uid@example.com')}'));
    return [for (final m in (jsonDecode(r.body) as Map<String, dynamic>)['mail'] as List) m as Map<String, dynamic>];
  }

  /// A computer signs in the way the website does it for the app.
  Future<String> desktopSignIn(String uid, {bool secondStep = false}) async {
    final r = await client.post(Uri.parse('$base/auth/session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_token': firebaseToken(uid, secondStep: secondStep)}));
    expect(r.statusCode, 200, reason: r.body);
    return (jsonDecode(r.body) as Map<String, dynamic>)['session_token'] as String;
  }

  TypeMatcher<TwoStepRefusal> refused(String code, {int? status}) => isA<TwoStepRefusal>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.status, 'status', status ?? anything);

  test('a phone adds the first passkey (two-step sign-in turns on), signs in with it through the bridge, '
      'renames it and removes it (two-step sign-in turns off)', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('phone');
    var bearer = firebaseToken(uid);
    final api = apiWith(() async => bearer);

    var state = await api.state();
    expect(state.on, isFalse);
    expect(state.passkeysAvailable, isTrue);
    expect(state.lockoutRecovery, isNull);

    // The first passkey: the bridge is enrolled with the phone's own fresh
    // sign-in, its bearer.
    final soft = SoftPasskeys();
    final options = await api.passkeyOptions();
    expect(options['rp'], containsPair('id', 'zestssh.com'));
    final added = await api.addPasskey(response: await soft.create(options), name: 'Passkey on Android');
    expect(added.change.state.on, isTrue);
    expect(added.change.state.passkeys, 1);
    expect(added.passkey.name, 'Passkey on Android');
    expect(added.passkey.synced, isTrue);
    expect(added.passkey.createdAt, isNotNull);

    // Firebase holds the bridge, by its name, beside nothing else.
    final factors = await factorsOf(uid);
    final bridge = factors.singleWhere((f) => f['displayName'] == kBridgeFactorName);
    final bridgeId = bridge['uid'] as String;

    // The passkey step of a sign-in: by the bridge, the address optional.
    final challenge = await api.passkeyChallenge(enrollmentId: bridgeId, email: '$uid@example.com');
    expect(challenge['rpId'], 'zestssh.com');
    final released = await api.passkeyVerify(response: await soft.get(challenge));
    expect(released.enrollmentId, bridgeId);
    expect(released.code, matches(RegExp(r'^[0-9]{6}$')));
    expect('$released', isNot(contains(released.code)), reason: 'the code is never in a message or a log');

    // runPasskeyStep hands the code straight on, and only there.
    String? handed;
    await runPasskeyStep<void>(
      api: api,
      platform: soft,
      enrollmentId: bridgeId,
      finish: (id, code) async {
        expect(id, bridgeId);
        handed = code;
      },
    );
    expect(handed, matches(RegExp(r'^[0-9]{6}$')));

    // A wrong signature, and an answer from another site: one refusal for
    // every cause.
    for (final bend in ['signature', 'origin']) {
      final again = await api.passkeyChallenge(enrollmentId: bridgeId);
      soft.bend = bend;
      await expectLater(api.passkeyVerify(response: await soft.get(again)), throwsA(refused('passkey-failed', status: 401)));
    }

    // Firebase finishes the sign-in with the bridge's code: a second-step
    // sign-in from here on.
    bearer = firebaseToken(uid, secondStep: true);
    final list = await api.passkeys();
    expect(list.single.id, added.passkey.id);
    final renamed = await api.renamePasskey(list.single.id, 'Work phone');
    expect(renamed.name, 'Work phone');
    await expectLater(api.renamePasskey(list.single.id, ''), throwsA(refused('invalid-name', status: 400)));

    // The account's only second step: removing it turns two-step sign-in off.
    final removed = await api.removePasskey(list.single.id);
    expect(removed.state.on, isFalse);
    expect(removed.state.passkeys, 0);
    expect(await factorsOf(uid), isEmpty, reason: 'the bridge went with the last passkey');
    final mail = await mailOf(uid);
    expect(mail.map((m) => m['kind']), containsAll(['passkey-added', 'passkey-removed']));
  });

  test('Confirm it\'s you with a passkey: a computer signed in a while ago taps, and what asks for a recent '
      'sign-in goes ahead on that device alone; what changes how the account signs in still takes a sign-in', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('tap');
    final bearer = firebaseToken(uid);
    final phone = apiWith(() async => bearer);
    final soft = SoftPasskeys();

    // No passkey yet: nothing to tap, and worth offering.
    final before = PasskeyStepUp(api: () => phone, platform: soft);
    expect(await before.available(), isFalse);
    expect(await before.worthOffering(), isTrue);
    await phone.addPasskey(response: await soft.create(await phone.passkeyOptions()), name: 'Passkey');

    Future<String> signedInAWhileAgo() async {
      final r = await client.post(Uri.parse('$base/auth/session'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'id_token': 'fb:$uid:${now() - 1200}:${now()}:2fa'}));
      expect(r.statusCode, 200, reason: r.body);
      return (jsonDecode(r.body) as Map<String, dynamic>)['session_token'] as String;
    }

    final session = await signedInAWhileAgo();
    final other = await signedInAWhileAgo();
    final third = await signedInAWhileAgo();
    final api = apiWith(() async => session);
    DeviceSessionsApi devices(String token) => DeviceSessionsApi(client: client, baseUrl: base, bearer: () async => token);
    final sessionId = (await devices(session).current())!;
    final otherId = (await devices(other).current())!;
    final askedToSignIn = throwsA(isA<DeviceSessionsException>().having((e) => e.needsRecentSignIn, 'needsRecentSignIn', isTrue));

    // Twenty minutes on, signing a device out is asked for.
    await expectLater(devices(session).signOut(otherId), askedToSignIn);

    // The tap: what the device is asked, then its answer.
    final options = await api.stepUpOptions();
    expect(options['rpId'], 'zestssh.com');
    expect(options['userVerification'], 'required');
    expect(options['allowCredentials'], hasLength(1));
    final at = await api.stepUpVerify(await soft.get(options));
    expect(DateTime.now().difference(at!).inSeconds.abs(), lessThan(30));

    // The same through what the dialog uses.
    final stepUp = PasskeyStepUp(api: () => api, platform: soft);
    expect(await stepUp.available(), isTrue);
    expect(await stepUp.worthOffering(), isFalse);
    await stepUp.confirm();

    // It goes ahead here, and is still asked on a device that did not tap.
    await devices(session).signOut(otherId);
    await expectLater(devices(third).signOut(sessionId), askedToSignIn);

    // What changes how the account signs in takes a sign-in, tap or no tap.
    await expectLater(api.passkeyOptions(), throwsA(isA<TwoStepRefusal>().having((e) => e.needsRecentSignIn, 'needsRecentSignIn', isTrue)));

    // Spent: right or wrong, a challenge is good once.
    final spent = await soft.get(await api.stepUpOptions());
    await api.stepUpVerify(spent);
    await expectLater(api.stepUpVerify(spent), throwsA(refused('passkey-failed', status: 401)));
  });

  test('a passkey whose counter went back is refused as copied', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('cloned');
    final bearer = firebaseToken(uid);
    final api = apiWith(() async => bearer);
    final soft = SoftPasskeys(counter: 5, synced: false);
    await api.addPasskey(response: await soft.create(await api.passkeyOptions()), name: 'Security key');
    final bridgeId = (await factorsOf(uid)).singleWhere((f) => f['displayName'] == kBridgeFactorName)['uid'] as String;
    await api.passkeyVerify(response: await soft.get(await api.passkeyChallenge(enrollmentId: bridgeId)));
    soft.bend = 'counter-back';
    await expectLater(
      api.passkeyVerify(response: await soft.get(await api.passkeyChallenge(enrollmentId: bridgeId))),
      throwsA(refused('passkey-cloned', status: 401)),
    );
  });

  test('one or the other: a phone with the authenticator app is refused a passkey unless it replaces it; replaced, '
      'the app goes as the bridge comes; the passkeys go again for an app; turning off takes everything', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('both');
    await setFactors(uid, ['totp']);
    final bearer = firebaseToken(uid, secondStep: true);
    final api = apiWith(() async => bearer);

    var state = await api.state();
    expect(state.on, isTrue);
    expect(state.authenticator, isTrue);
    expect(state.passkeys, 0);

    // Firebase holds one TOTP factor per account, and the bridge is one.
    await expectLater(api.passkeyOptions(), throwsA(refused('authenticator-app-on', status: 409)));
    final soft = SoftPasskeys();
    final added = await api.addPasskey(
      response: await soft.create(await api.passkeyOptions(replaceAuthenticator: true)),
      name: 'Passkey on iPhone',
      replaceAuthenticator: true,
    );
    expect(added.change.state.authenticator, isFalse);
    expect(added.change.state.passkeys, 1);
    expect(added.change.state.factors, 1);
    expect([for (final f in await factorsOf(uid)) f['displayName']], [kBridgeFactorName]);
    // The person's own authenticator beside the bridge is refused, as Firebase refuses it.
    final beside = await client.put(Uri.parse('$root/test/two-step/$uid'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'factors': ['totp']}));
    expect(beside.statusCode, 409);

    // The authenticator app in the place of the passkeys: they go first (the
    // codes stay), then the app is set up with Firebase and ZestSSH Cloud told.
    final removed = await api.removePasskeysForAuthenticator();
    expect(removed.state.passkeys, 0);
    expect(removed.state.on, isTrue, reason: 'held on until the app is set up');
    expect(await factorsOf(uid), isEmpty);
    await setFactors(uid, ['totp']);
    final told = await api.changed();
    expect(told.state.on, isTrue);
    expect(told.state.authenticator, isTrue);
    expect([for (final m in await mailOf(uid)) m['kind']],
        containsAllInOrder(['authenticator-replaced', 'passkeys-replaced', 'authenticator-added']));

    final off = await api.turnOff();
    expect(off.state.on, isFalse);
    expect(off.state.passkeys, 0);
    expect(off.state.recoveryCodes, 0);
    expect(await factorsOf(uid), isEmpty);
  });

  test('a computer trades its session up with the browser\'s handed ID token, and replaces the authenticator '
      'with a Windows Hello passkey with it', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('computer');
    var session = await desktopSignIn(uid);
    final api = apiWith(() async => session);
    await setFactors(uid, ['totp']);

    // The website hands this app a fresh sign-in (purpose=id-token): a code
    // for its challenge, which only this app's secret trades.
    final secret = SignInCode.make();
    final handoff = await client.post(Uri.parse('$base/auth/handoff'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_token': firebaseToken(uid, secondStep: true), 'challenge': secret.challenge}));
    expect(handoff.statusCode, 200, reason: handoff.body);
    expect(handoff.headers['cache-control'], 'no-store');
    final code = (jsonDecode(handoff.body) as Map<String, dynamic>)['code'] as String;
    final idToken = await handedIdToken(
      api: api,
      accountUid: uid,
      handoff: () async => (code: code, verifier: secret.verifier, uid: uid),
      uidOf: (token) => token.split(':')[1],
    );
    expect(idToken, startsWith('fb:$uid:'));
    // Good once.
    await expectLater(api.redeemHandoff(code: code, verifier: secret.verifier), throwsA(refused('sign-in-code-invalid')));

    // The same session, now recent and with the second step.
    session = await api.upgradeSession(idToken: idToken);
    final state = await api.state();
    expect(state.authenticator, isTrue);

    // The account's first passkey, in the place of the authenticator (one or
    // the other): asked first, then its bridge is enrolled with the handed ID
    // token as the app goes.
    await expectLater(api.passkeyOptions(),
        throwsA(isA<TwoStepRefusal>().having((e) => e.authenticatorOn, 'authenticatorOn', isTrue)));
    final soft = SoftPasskeys(synced: false);
    final added = await api.addPasskey(
      response: await soft.create(await api.passkeyOptions(replaceAuthenticator: true)),
      name: 'Windows Hello',
      idToken: idToken,
      replaceAuthenticator: true,
    );
    expect(added.passkey.name, 'Windows Hello');
    expect(added.change.state.authenticator, isFalse);
    expect([for (final f in await factorsOf(uid)) f['displayName']], [kBridgeFactorName]);
    // The computer's own session, which made the change, stays.
    expect((await api.state()).passkeys, 1);
  });

  test('a handed ID token of another account is never used', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('mine');
    final other = fresh('theirs');
    final api = apiWith(() async => firebaseToken(uid));
    final secret = SignInCode.make();
    final handoff = await client.post(Uri.parse('$base/auth/handoff'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_token': firebaseToken(other), 'challenge': secret.challenge}));
    final code = (jsonDecode(handoff.body) as Map<String, dynamic>)['code'] as String;
    // The website says whose it is: not even traded.
    await expectLater(
      handedIdToken(
          api: api, accountUid: uid, handoff: () async => (code: code, verifier: secret.verifier, uid: other)),
      throwsA(isA<HandoffWrongAccount>()),
    );
    // Where it says nothing, the token itself does.
    await expectLater(
      handedIdToken(
        api: api,
        accountUid: uid,
        handoff: () async => (code: code, verifier: secret.verifier, uid: null),
        uidOf: (token) => token.split(':')[1],
      ),
      throwsA(isA<HandoffWrongAccount>()),
    );
  });

  test('a computer\'s first passkey made with the browser\'s ID token signs the computer\'s own session out, '
      'which says why', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('first');
    final session = await desktopSignIn(uid);
    final sessionApi = apiWith(() async => session);
    expect((await sessionApi.state()).on, isFalse);

    // The account has no second step, so the session cannot be traded up:
    // the handed ID token is this change's sign-in.
    final byToken = sessionApi.withBearer(firebaseToken(uid));
    final soft = SoftPasskeys();
    final added = await byToken.addPasskey(response: await soft.create(await byToken.passkeyOptions()), name: 'Windows Hello');
    expect(added.change.state.on, isTrue);
    expect(added.change.signedOut, greaterThanOrEqualTo(1), reason: 'this computer\'s session among them');

    await expectLater(sessionApi.state(), throwsA(refused('session-revoked', status: 401)));
    expect(sessionRevokedReason, kSignedOutForTwoStep, reason: 'the notice says two-step sign-in was turned on');
  });

  test('turning two-step sign-in off signs the other devices out, each told why', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('others');
    await setFactors(uid, ['totp']);
    final other = await desktopSignIn(uid, secondStep: true);
    final api = apiWith(() async => firebaseToken(uid, secondStep: true));
    final off = await api.turnOff();
    expect(off.signedOut, greaterThanOrEqualTo(1));
    await expectLater(apiWith(() async => other).state(), throwsA(refused('session-revoked')));
    expect(sessionRevokedReason, kSignedOutTwoStepOff);
  });

  test('lock-out recovery: an ask and its emailed code, This wasn\'t me, then a reset on the day', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('lockout');
    final email = '$uid@example.com';
    await setFactors(uid, ['totp']);
    final device = firebaseToken(uid, secondStep: true);
    final api = apiWith(() async => device);
    expect((await api.state()).on, isTrue);

    Future<String> codeOfLastMail() async {
      final mail = (await mailOf(uid)).where((m) => m['kind'] == 'recovery-confirm').toList();
      return mail.last['code'] as String;
    }

    // The same answer for every address: an ask id.
    final askId = await api.askLockoutRecovery(email);
    expect(askId, isNotEmpty);
    expect(await api.askLockoutRecovery('nobody-${now()}@example.com'), isNotEmpty);
    await expectLater(api.confirmLockoutRecovery(email: email, askId: askId, code: '0000 0000'),
        throwsA(refused('recovery-code-invalid', status: 400)));
    final code = await codeOfLastMail();
    final ticket = await api.confirmLockoutRecovery(email: email, askId: askId, code: '${code.substring(0, 4)} ${code.substring(4)}');
    expect(ticket.proof, isNull, reason: 'no synced data here: only a reset');
    expect(ticket.completesAt.difference(DateTime.now()).inDays, inInclusiveRange(6, 7));
    expect('$ticket', isNot(contains(ticket.ticket)));

    // Every signed-in device sees it, with This wasn't me.
    final waiting = (await api.state()).lockoutRecovery;
    expect(waiting, isNotNull);
    expect(waiting!.completesAt.difference(ticket.completesAt).inMinutes.abs(), lessThan(1));

    // Not before its day.
    await expectLater(
      api.completeLockoutRecovery(email: email, ticket: ticket.ticket, reset: true),
      throwsA(refused('recovery-not-yet', status: 409).having((e) => e.completesAt, 'completesAt', isNotNull)),
    );

    // This wasn't me: at once, with no new sign-in.
    expect(await api.cancelLockoutRecovery(), isTrue);
    expect((await api.state()).lockoutRecovery, isNull);
    expect(await api.cancelLockoutRecovery(), isFalse);
    await expectLater(api.completeLockoutRecovery(email: email, ticket: ticket.ticket, reset: true),
        throwsA(refused('recovery-ticket-invalid')));

    // Asked again; the day comes.
    final again = await api.askLockoutRecovery(email);
    final second = await api.confirmLockoutRecovery(email: email, askId: again, code: await codeOfLastMail());
    final day = await client.post(Uri.parse('$root/test/lockout/$uid/day-comes'));
    expect((jsonDecode(day.body) as Map<String, dynamic>)['found'], isTrue);

    // A proof where none is registered is a wrong one, and says how many
    // tries are left.
    await expectLater(
      api.completeLockoutRecovery(email: email, ticket: second.ticket, proof: b64uOf(List<int>.filled(64, 7))),
      throwsA(refused('recovery-proof-invalid', status: 400).having((e) => e.triesLeft, 'triesLeft', 9)),
    );

    // Without the proof: a reset. Every device is signed out, and says why.
    expect(await api.completeLockoutRecovery(email: email, ticket: second.ticket, reset: true), isFalse);
    expect(await factorsOf(uid), isEmpty);
    await expectLater(api.state(), throwsA(refused('session-revoked')));
    expect(sessionRevokedReason, kSignedOutAccountRecovered);
  });

  test('a recovery that keeps the data: the proof registered from the sync password, a wrong one refused, the right '
      'one signed on a device that was never the account\'s, the data kept', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('kept');
    final email = '$uid@example.com';
    await setFactors(uid, ['totp']);
    final device = firebaseToken(uid, secondStep: true);
    final api = apiWith(() async => device);
    expect((await api.state()).on, isTrue);

    // The account's sync, as a push leaves it, with the sync password's key.
    final params = SyncService.legacyArgon2Params;
    const password = 'correct horse battery staple';
    final salt = Uint8List.fromList(List<int>.generate(16, (i) => i * 7));
    final mek = await SyncService.deriveKey(password, salt, params: params);
    final seeded = await client.put(Uri.parse('$root/test/sync/$uid'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'salt': base64Encode(salt),
          'password_hash': base64Encode(await SyncService.computeVerificationHash(mek)),
          'argon2_params': params,
        }));
    expect(seeded.statusCode, 200, reason: seeded.body);

    // Registered at unlock, proving the sync password: the same key again
    // changes nothing, and a stale password is not taken.
    final remembered = <String>[];
    final service = RecoveryProofService(
      api: () => api,
      accountUid: () async => uid,
      hosted: () => true,
      remember: (u) async => remembered.add(u),
    );
    await service.register(mek);
    expect(remembered, [uid]);
    expect((await api.state()).recoveryProof, isTrue);
    final stale = await recoveryProofRegistration(SecretKey(List<int>.filled(32, 9)), uid);
    await expectLater(
      api.registerRecoveryProof(publicKey: stale.publicKey, signature: stale.signature, passwordHash: stale.passwordHash),
      throwsA(refused('verification-failed', status: 403)),
    );

    // Asked and confirmed: a new device learns all a proof needs, the account
    // included, and nothing that opens anything.
    final askId = await api.askLockoutRecovery(email);
    final mail = (await mailOf(uid)).where((m) => m['kind'] == 'recovery-confirm').last;
    final ticket = await api.confirmLockoutRecovery(email: email, askId: askId, code: mail['code'] as String);
    expect(ticket.proof, isNotNull);
    expect(ticket.proof!.accountUid, uid);
    expect(ticket.proof!.salt, salt);
    expect(ticket.proof!.argon2Params?['memory'], params['memory']);
    final day = await client.post(Uri.parse('$root/test/lockout/$uid/day-comes'));
    expect((jsonDecode(day.body) as Map<String, dynamic>)['found'], isTrue);

    final waiting = WaitingLockout(email: email, ticket: ticket.ticket, completesAt: ticket.completesAt, proof: ticket.proof);

    // A wrong sync password is a wrong proof, and one try less.
    final wrong = await proveSyncPassword(waiting: waiting, password: 'not it', firebaseUid: ticket.proof!.accountUid!);
    await expectLater(
      api.completeLockoutRecovery(email: email, ticket: ticket.ticket, proof: wrong),
      throwsA(refused('recovery-proof-invalid', status: 400).having((e) => e.triesLeft, 'triesLeft', 9)),
    );

    // The right one, derived as at unlock, is what the server verifies: the
    // data stays, every second step goes, every device is signed out.
    final right = await proveSyncPassword(waiting: waiting, password: password, firebaseUid: ticket.proof!.accountUid!);
    expect(await api.completeLockoutRecovery(email: email, ticket: ticket.ticket, proof: right), isTrue);
    expect(await factorsOf(uid), isEmpty);
    final kept = await client.get(Uri.parse('$root/test/sync/$uid'));
    expect((jsonDecode(kept.body) as Map<String, dynamic>)['kept'], isTrue, reason: 'the synced data stayed');
    await expectLater(api.state(), throwsA(refused('session-revoked')));
    expect(sessionRevokedReason, kSignedOutAccountRecovered);
  });

  test('the recovery proof is not kept for an account with no synced data, and registering it says nothing',
      () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = fresh('proof');
    final api = apiWith(() async => firebaseToken(uid));
    final mek = SecretKey(List<int>.generate(32, (i) => i));
    final proof = await recoveryProofRegistration(mek, uid);
    await expectLater(
      api.registerRecoveryProof(publicKey: proof.publicKey, signature: proof.signature, passwordHash: proof.passwordHash),
      throwsA(refused('recovery-proof-no-data', status: 409)),
    );
    var remembered = 0;
    final service = RecoveryProofService(
      api: () => api,
      accountUid: () async => uid,
      hosted: () => true,
      remember: (_) async => remembered++,
    );
    await service.register(mek);
    expect(remembered, 0, reason: 'nothing was registered');
    expect((await api.state()).recoveryProof, isFalse);
  });
}
