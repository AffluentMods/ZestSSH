import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/type_name.dart';

// Two-step sign-in and passkeys on ZestSSH Cloud (3.3; the two-step
// contract, sections 3, 6 and 7, which win over the earlier ones). Every
// route the app uses, in one client:
//
//   signed in    GET    /account/two-step                  the state
//                POST   /account/two-step/changed          after Firebase
//                DELETE /account/two-step                  turn it all off
//                DELETE /account/two-step/authenticator    the authenticator
//                DELETE /account/two-step/passkeys         the passkeys, for an
//                                                          authenticator app
//                POST   /account/passkeys/options          to make a passkey
//                POST   /account/passkeys                  keep it
//                GET    /account/passkeys                  the list
//                PATCH  /account/passkeys/:id              rename one
//                DELETE /account/passkeys/:id              remove one
//                DELETE /account/lockout-recovery          "This wasn't me"
//                PUT    /account/recovery-proof            at unlock
//                POST   /auth/session/upgrade              a computer's session
//   no sign-in   POST   /auth/passkey/challenge, /verify   the passkey step
//                POST   /auth/lockout-recovery, /confirm, /complete
//                POST   /auth/handoff/redeem               a computer's ID token
//
// What these answers carry (a bridge code, an ID token, a challenge, a
// recovery ticket) is sent with Cache-Control: no-store, and this client
// keeps it that way: nothing is cached, nothing is written anywhere by it,
// and no error of it says more than a status and a code. The one thing kept
// on the device is a recovery ticket, in secure storage, by the recovery
// itself (lib/services/account/lockout_recovery.dart).
//
// One or the other: Firebase holds one TOTP
// factor per account, and the passkeys' bridge is one, so an account uses
// passkeys or the authenticator app, with its backup codes either way. The
// first passkey of an account with the authenticator app is refused (409
// authenticator-app-on) unless the request replaces it; the passkeys go
// before an authenticator app is set up in their place.

/// A refusal of ZestSSH Cloud on a two-step, passkey, recovery or hand-off
/// route: its status and code (the reason too, where it gives one), how long
/// it asks to wait, and what a recovery's refusals add. Never what the body
/// said in words, and never a secret.
class TwoStepRefusal implements Exception, HasTypeName {
  const TwoStepRefusal(
    this.status, {
    this.code,
    this.reason,
    this.retryAfter,
    this.triesLeft,
    this.completesAt,
  });

  final int status;
  final String? code;

  /// Why, where the server says it ('second-step-required').
  final String? reason;

  /// How long to wait (Retry-After), where it says.
  final Duration? retryAfter;

  /// Tries of the sync password left for a recovery (recovery-proof-invalid).
  final int? triesLeft;

  /// When a waiting recovery can be completed (recovery-not-yet).
  final DateTime? completesAt;

  /// The server wants a sign-in from the last few minutes first; with
  /// [needsSecondStep], one that passed the second step.
  bool get needsRecentSignIn => code == 'recent-sign-in-required';

  bool get needsSecondStep => reason == 'second-step-required';

  /// A computer's change needs a fresh ID token, handed over by the browser.
  bool get needsIdToken => code == 'id-token-required';

  /// This device was signed out.
  bool get signedOut => code == 'session-revoked';

  /// The account has the authenticator app: a passkey would replace it (one
  /// or the other), which the person is asked first.
  bool get authenticatorOn => code == 'authenticator-app-on';

  /// The authenticator app went for a passkey that then did not come: the
  /// account has no second step now.
  bool get authenticatorLost => code == 'authenticator-removed-passkey-failed';

  /// The route is not on this server: one from before 3.3.
  bool get routeMissing => status == 404 && code == null;

  /// What a person can quote to support: the code, with its reason.
  String get shownCode {
    final c = code;
    if (c == null) return 'HTTP $status';
    return reason == null ? c : '$c ($reason)';
  }

  @override
  String toString() =>
      'Two-step: HTTP $status${code == null ? '' : ' $code'}${reason == null ? '' : ' ($reason)'}';

  @override
  String get typeName => 'TwoStepRefusal';
}

/// The seconds or the date a Retry-After header gives, as a wait; null when
/// there is none or it cannot be read.
Duration? retryAfterOf(String? value, {DateTime? now}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  final seconds = int.tryParse(text);
  if (seconds != null) return seconds < 0 ? null : Duration(seconds: seconds);
  try {
    final at = HttpDate.parse(text);
    final left = at.difference(now ?? DateTime.now());
    return left.isNegative ? Duration.zero : left;
  } catch (_) {
    return null;
  }
}

/// A lock-out recovery of the account that waits (the contract, section
/// 6.5): every signed-in device shows it, with "This wasn't me".
class WaitingRecovery {
  const WaitingRecovery({this.requestedAt, required this.completesAt});

  /// When it was asked for.
  final DateTime? requestedAt;

  /// From when whoever asked can complete it.
  final DateTime completesAt;
}

/// Two-step sign-in as ZestSSH Cloud holds it for the account (GET
/// /v1/account/two-step), kept in line with Firebase.
class TwoStepState {
  const TwoStepState({
    required this.on,
    this.known = true,
    this.authenticator = false,
    this.passkeys = 0,
    this.recoveryCodes = 0,
    this.passkeysAvailable = false,
    this.recoveryProof = false,
    this.lockoutRecovery,
    this.older = false,
  });

  factory TwoStepState.fromJson(Map<String, dynamic> j) {
    int count(Object? v) => v is int && v >= 0 ? v : 0;
    final waiting = j['lockout_recovery'];
    WaitingRecovery? recovery;
    if (waiting is Map) {
      final completes = _time(waiting['completes_at']);
      if (completes != null) {
        recovery = WaitingRecovery(requestedAt: _time(waiting['requested_at']), completesAt: completes);
      }
    }
    return TwoStepState(
      on: j['on'] == true,
      authenticator: j['authenticator'] == true,
      passkeys: count(j['passkeys']),
      recoveryCodes: count(j['recovery_codes']),
      passkeysAvailable: j['passkeys_available'] == true,
      recoveryProof: j['recovery_proof'] == true,
      lockoutRecovery: recovery,
    );
  }

  /// Whether the account has any second step.
  final bool on;

  /// False only from a server before 3.3 that could not ask Firebase.
  final bool known;

  /// Whether it has the authenticator app.
  final bool authenticator;

  /// How many passkeys it has.
  final int passkeys;

  /// How many unused recovery codes it holds.
  final int recoveryCodes;

  /// Whether ZestSSH Cloud has passkeys on.
  final bool passkeysAvailable;

  /// Whether the account registered its recovery proof.
  final bool recoveryProof;

  /// A recovery of the account that waits, or null.
  final WaitingRecovery? lockoutRecovery;

  /// From a server before 3.3 (GET /v1/account/recovery-codes): it knows no
  /// passkeys, and the authenticator is all there is.
  final bool older;

  /// How many second steps the account has: removing the last turns
  /// two-step sign-in off.
  int get factors => (authenticator ? 1 : 0) + passkeys;

  TwoStepState withoutRecovery() => TwoStepState(
        on: on,
        known: known,
        authenticator: authenticator,
        passkeys: passkeys,
        recoveryCodes: recoveryCodes,
        passkeysAvailable: passkeysAvailable,
        recoveryProof: recoveryProof,
        older: older,
      );
}

/// What a change answers: the state after it, how many of the account's
/// other devices it signed out, and whether the account was emailed.
class TwoStepChange {
  const TwoStepChange(this.state, {this.signedOut = 0, this.notified = false});

  factory TwoStepChange.fromJson(Map<String, dynamic> body, {Map<String, dynamic>? state}) {
    final n = body['signed_out'];
    return TwoStepChange(
      TwoStepState.fromJson(state ?? body),
      signedOut: n is int && n > 0 ? n : 0,
      notified: body['notified'] == true,
    );
  }

  final TwoStepState state;
  final int signedOut;
  final bool notified;
}

/// What kind of passkey it is, as ZestSSH Cloud tells them apart.
enum PasskeyKind {
  /// A passkey of a password manager or a phone, most often synced.
  passkey,

  /// A security key (USB, NFC).
  securityKey,

  /// Built into one device (Windows Hello, a phone's own).
  platform,
}

/// One of the account's passkeys. There is no "last used": no activity
/// times are kept.
class PasskeyItem {
  const PasskeyItem({
    required this.id,
    required this.name,
    this.createdAt,
    this.transports = const [],
    this.synced = false,
    this.kind = PasskeyKind.passkey,
  });

  factory PasskeyItem.fromJson(Map<String, dynamic> j) => PasskeyItem(
        id: j['id'] as String,
        name: j['name'] is String ? j['name'] as String : '',
        createdAt: _time(j['created_at']),
        transports: [for (final t in (j['transports'] is List ? j['transports'] as List : const [])) if (t is String) t],
        synced: j['synced'] == true,
        kind: switch (j['kind']) {
          'security-key' => PasskeyKind.securityKey,
          'platform' => PasskeyKind.platform,
          _ => PasskeyKind.passkey,
        },
      );

  /// The credential's id, base64url.
  final String id;
  final String name;
  final DateTime? createdAt;
  final List<String> transports;

  /// Backed up, as a synced passkey is.
  final bool synced;
  final PasskeyKind kind;
}

/// A passkey kept: it, and the account's state after it.
class PasskeyAdded {
  const PasskeyAdded(this.passkey, this.change);

  final PasskeyItem passkey;
  final TwoStepChange change;
}

/// What a verified passkey releases at sign-in: the bridge's enrollment id,
/// and its code for this one sign-in, which goes straight to Firebase. It is
/// never kept, shown or logged: nothing of it is in [toString].
class BridgeRelease {
  const BridgeRelease(this.enrollmentId, this.code);

  final String enrollmentId;
  final String code;

  @override
  String toString() => 'BridgeRelease';
}

/// What proving the sync password needs to complete a recovery: the
/// server's challenge, and the sync password's salt and Argon2 settings
/// (no secret: a pull hands them out too).
class RecoveryProofAsk {
  const RecoveryProofAsk({required this.challenge, required this.salt, this.argon2Params, this.accountUid});

  factory RecoveryProofAsk.fromJson(Map<String, dynamic> j) {
    final params = j['argon2_params'];
    final uid = j['firebase_uid'];
    return RecoveryProofAsk(
      challenge: j['challenge'] as String,
      salt: base64Decode(j['salt'] as String),
      argon2Params: params is Map<String, dynamic> ? params : null,
      accountUid: uid is String && uid.isNotEmpty ? uid : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'challenge': challenge,
        'salt': base64Encode(salt),
        'argon2_params': ?argon2Params,
        'firebase_uid': ?accountUid,
      };

  final String challenge;
  final Uint8List salt;
  final Map<String, dynamic>? argon2Params;

  /// The account's id, where the server says it: the proof signs it. (The
  /// server of 30 October 2026 says none; the device then signs with the id
  /// it knows for the address.)
  final String? accountUid;
}

/// A recovery that waits: its ticket (kept until it is done or cancelled),
/// from when it can be completed, and what proving the sync password needs
/// (null where the account has no synced data or registered no proof).
class LockoutTicket {
  const LockoutTicket({required this.ticket, required this.completesAt, this.proof});

  final String ticket;
  final DateTime completesAt;
  final RecoveryProofAsk? proof;

  @override
  String toString() => 'LockoutTicket(completes ${completesAt.toIso8601String()})';
}

/// Goes up whenever ZestSSH Cloud says on the live line that the account's
/// security changed (`{type: 'security'}`): whatever shows its two-step
/// sign-in reads it again, and a waiting recovery shows at once.
final StreamController<void> securityNudges = StreamController<void>.broadcast();

/// ZestSSH Cloud's two-step, passkey, lock-out recovery and hand-off
/// routes, always on the hosted server whatever sync backend is in use.
class TwoStepApi {
  TwoStepApi({http.Client? client, String? baseUrl, this.bearer, this.reportSignOut = true})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? _defaultBase;

  static String get _defaultBase => kZestApiBase;

  static const _timeout = Duration(seconds: 30);

  final http.Client _client;
  final String _base;

  /// The account's sign-in: a fresh Firebase ID token on a phone, the
  /// session token on a computer. Not needed by the routes without one.
  final Future<String?> Function()? bearer;

  /// Whether an answer that this device was signed out is said as one
  /// ([reportIfSessionRevoked]): it is, with the device's own sign-in.
  final bool reportSignOut;

  /// The same routes with [token] as the sign-in: a computer's ID token from
  /// the browser, for a change Firebase itself is asked to make. Its answers
  /// say nothing of whether this device is signed out.
  TwoStepApi withBearer(String token) =>
      TwoStepApi(client: _client, baseUrl: _base, bearer: () async => token, reportSignOut: false);

  Uri _url(String path) => Uri.parse('$_base$path');

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = bearer == null ? null : await bearer!();
    if (token == null) throw const TwoStepRefusal(401, code: 'signed-out');
    return {
      'Authorization': 'Bearer $token',
      ...DeviceSessionHeader.headers,
      if (json) 'Content-Type': 'application/json',
    };
  }

  /// An authenticated request; its JSON body, or a [TwoStepRefusal].
  Future<Map<String, dynamic>> _signedIn(String method, String path, {Object? body, Set<int> ok = const {200}}) async {
    final request = http.Request(method, _url(path))..headers.addAll(await _headers(json: body != null));
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await _client.send(request).timeout(_timeout)).timeout(_timeout);
    if (reportSignOut) reportIfSessionRevoked(response);
    return _answer(response, ok);
  }

  /// A request without a sign-in; its JSON body, or a [TwoStepRefusal].
  Future<Map<String, dynamic>> _open(String path, Object body, {Set<int> ok = const {200}}) async {
    final response = await _client
        .post(_url(path), headers: const {'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(_timeout);
    return _answer(response, ok);
  }

  static Map<String, dynamic> _answer(http.Response response, Set<int> ok) {
    final body = _decode(response.body);
    if (ok.contains(response.statusCode)) return body;
    final code = body['code'];
    final reason = body['reason'];
    final tries = body['tries_left'];
    throw TwoStepRefusal(
      response.statusCode,
      code: code is String && code.isNotEmpty ? code : null,
      reason: reason is String && reason.isNotEmpty ? reason : null,
      retryAfter: retryAfterOf(response.headers['retry-after']),
      triesLeft: tries is int ? tries : null,
      completesAt: _time(body['completes_at']),
    );
  }

  // ── The account's two-step sign-in ─────────────────────────────────

  /// What it is now. A server from before 3.3 answers 404 here: what its
  /// recovery codes route says stands in (no passkeys then).
  Future<TwoStepState> state() async {
    try {
      return TwoStepState.fromJson(await _signedIn('GET', '/account/two-step'));
    } on TwoStepRefusal catch (e) {
      if (!e.routeMissing) rethrow;
    }
    final old = await _signedIn('GET', '/account/recovery-codes');
    final on = old['two_step'];
    final count = old['count'];
    return TwoStepState(
      on: on == true,
      known: on is bool,
      authenticator: on == true,
      recoveryCodes: count is int && count >= 0 ? count : 0,
      older: true,
    );
  }

  /// Says the authenticator was set up or removed with Firebase on this
  /// device, at once: ZestSSH Cloud reads the factors, signs out the devices
  /// that need to sign in again and emails the account. Needs a recent
  /// sign-in.
  Future<TwoStepChange> changed() async => TwoStepChange.fromJson(await _signedIn('POST', '/account/two-step/changed'));

  /// Turns two-step sign-in off: every factor, passkey and recovery code
  /// goes. Needs a recent sign-in with the second step.
  Future<TwoStepChange> turnOff() async => TwoStepChange.fromJson(await _signedIn('DELETE', '/account/two-step'));

  /// Removes the authenticator app. Where a second step of another kind
  /// stays, Firebase is asked with a fresh ID token: a phone's own sign-in, a
  /// computer's [idToken] from the browser. Needs a recent sign-in with the
  /// second step.
  Future<TwoStepChange> removeAuthenticator({String? idToken}) async => TwoStepChange.fromJson(
      await _signedIn('DELETE', '/account/two-step/authenticator', body: idToken == null ? null : {'id_token': idToken}));

  /// Removes every passkey and their bridge, so that the authenticator app
  /// can be set up in their place with Firebase (one or the other). The
  /// backup codes stay, and two-step sign-in stays on until the app is set up
  /// (and [changed] said); should it not be, the next read turns it off.
  /// Beside a second step of another kind, a computer gives a fresh
  /// [idToken]. Needs a recent sign-in with the second step.
  Future<TwoStepChange> removePasskeysForAuthenticator({String? idToken}) async => TwoStepChange.fromJson(
      await _signedIn('DELETE', '/account/two-step/passkeys', body: idToken == null ? null : {'id_token': idToken}));

  // ── Passkeys ───────────────────────────────────────────────────────

  // ── "Confirm it's you" with a passkey (from a security review) ──

  /// What the device needs to confirm it is the person with a passkey
  /// (WebAuthn's request options, asking it to verify them). Its challenge is
  /// good once, for this device, for two minutes.
  Future<Map<String, Object?>> stepUpOptions() async =>
      Map<String, Object?>.from(await _signedIn('POST', '/account/passkeys/step-up/options', body: const <String, Object?>{}));

  /// Checks the passkey's [response]: this device counts as having just shown
  /// it is the person, for what asks for a recent sign-in. When it was noted,
  /// by ZestSSH Cloud's clock.
  Future<DateTime?> stepUpVerify(Map<String, Object?> response) async =>
      _time((await _signedIn('POST', '/account/passkeys/step-up/verify', body: {'response': response}))['confirmed_at']);

  /// What the device needs to make a passkey (WebAuthn's creation options).
  /// Its challenge is good once, for five minutes. An account with the
  /// authenticator app is refused ([TwoStepRefusal.authenticatorOn]) unless
  /// the person chose to [replaceAuthenticator] with this passkey.
  Future<Map<String, Object?>> passkeyOptions({bool replaceAuthenticator = false}) async =>
      Map<String, Object?>.from(await _signedIn('POST', '/account/passkeys/options',
          body: replaceAuthenticator ? const {'replace_authenticator': true} : const <String, Object?>{}));

  /// Keeps the passkey the device made ([response]) as [name]. The
  /// account's first passkey needs a fresh ID token, for the bridge ZestSSH
  /// Cloud enrols: a phone's own sign-in, or a computer's [idToken]. With
  /// [replaceAuthenticator], the account's authenticator app goes for it.
  Future<PasskeyAdded> addPasskey({
    required Map<String, Object?> response,
    required String name,
    String? idToken,
    bool replaceAuthenticator = false,
  }) async {
    final body = await _signedIn(
      'POST',
      '/account/passkeys',
      body: {
        'response': response,
        'name': name,
        'id_token': ?idToken,
        if (replaceAuthenticator) 'replace_authenticator': true,
      },
      ok: const {201},
    );
    final state = body['two_step'];
    return PasskeyAdded(
      PasskeyItem.fromJson(body['passkey'] as Map<String, dynamic>),
      TwoStepChange.fromJson(body, state: state is Map<String, dynamic> ? state : const {}),
    );
  }

  /// The account's passkeys, oldest first.
  Future<List<PasskeyItem>> passkeys() async {
    final list = (await _signedIn('GET', '/account/passkeys'))['passkeys'];
    return [
      for (final p in list is List ? list : const [])
        if (p is Map<String, dynamic> && p['id'] is String) PasskeyItem.fromJson(p),
    ];
  }

  /// Renames the passkey [id]. Needs a recent sign-in.
  Future<PasskeyItem> renamePasskey(String id, String name) async =>
      PasskeyItem.fromJson(await _signedIn('PATCH', '/account/passkeys/${Uri.encodeComponent(id)}', body: {'name': name}));

  /// Removes the passkey [id]; the last one takes the bridge with it, and the
  /// last second step two-step sign-in. A computer removing the last passkey
  /// beside the authenticator gives a fresh [idToken]. Needs a recent
  /// sign-in with the second step.
  Future<TwoStepChange> removePasskey(String id, {String? idToken}) async {
    final body = await _signedIn('DELETE', '/account/passkeys/${Uri.encodeComponent(id)}',
        body: idToken == null ? null : {'id_token': idToken});
    final state = body['two_step'];
    return TwoStepChange.fromJson(body, state: state is Map<String, dynamic> ? state : const {});
  }

  // ── The passkey step at sign-in (no sign-in) ───────────────────────

  /// ZestSSH Cloud's challenge for the account whose bridge [enrollmentId]
  /// is (the Passkey hint's uid), with the address where one is known.
  /// Lives two minutes.
  Future<Map<String, Object?>> passkeyChallenge({required String enrollmentId, String? email}) async =>
      Map<String, Object?>.from(await _open('/auth/passkey/challenge', {
        'enrollment_id': enrollmentId,
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      }));

  /// Checks the passkey's [response]: the bridge's code for this one
  /// sign-in, to hand straight to Firebase.
  Future<BridgeRelease> passkeyVerify({required Map<String, Object?> response, String? email}) async {
    final body = await _open('/auth/passkey/verify', {
      'response': response,
      if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
    });
    final id = body['enrollment_id'];
    final code = body['code'];
    if (id is! String || code is! String || id.isEmpty || code.isEmpty) {
      throw const TwoStepRefusal(502, code: 'two-step-unavailable');
    }
    return BridgeRelease(id, code);
  }

  // ── Lock-out recovery ──────────────────────────────────────────────

  /// Asks to recover the account at [email]: a code goes to the address
  /// where it can be recovered. The answer is the same for every address:
  /// an ask id, which goes with the code, kept in memory by the asker.
  Future<String> askLockoutRecovery(String email) async {
    final body = await _open('/auth/lockout-recovery', {'email': email.trim()}, ok: const {202, 200});
    final id = body['ask_id'];
    if (id is! String || id.isEmpty) throw const TwoStepRefusal(502, code: 'two-step-unavailable');
    return id;
  }

  /// The emailed [code] of the ask [askId]: the recovery waits seven days.
  Future<LockoutTicket> confirmLockoutRecovery({
    required String email,
    required String askId,
    required String code,
  }) async {
    final body = await _open('/auth/lockout-recovery/confirm', {
      'email': email.trim(),
      'ask_id': askId,
      'code': code.replaceAll(RegExp(r'[\s-]'), ''),
    });
    final ticket = body['ticket'];
    final completes = _time(body['completes_at']);
    if (ticket is! String || ticket.isEmpty || completes == null) {
      throw const TwoStepRefusal(502, code: 'two-step-unavailable');
    }
    final proof = body['proof'];
    return LockoutTicket(
      ticket: ticket,
      completesAt: completes,
      proof: proof is Map<String, dynamic> ? RecoveryProofAsk.fromJson(proof) : null,
    );
  }

  /// Completes a waiting recovery from its day: with [proof] (the recovery
  /// proof's signature, base64url) the data stays; with [reset] the account
  /// is reset. Returns whether the data was kept.
  Future<bool> completeLockoutRecovery({
    required String email,
    required String ticket,
    String? proof,
    bool reset = false,
  }) async {
    final body = await _open('/auth/lockout-recovery/complete', {
      'email': email.trim(),
      'ticket': ticket,
      'proof': ?proof,
      if (reset) 'reset': true,
    });
    return body['with_data'] == true;
  }

  /// "This wasn't me": cancels a waiting recovery of the account, at once
  /// and with no new sign-in. Returns whether one was waiting.
  Future<bool> cancelLockoutRecovery() async =>
      (await _signedIn('DELETE', '/account/lockout-recovery'))['cancelled'] == true;

  /// Registers the account's recovery proof at unlock: its [publicKey] and
  /// [signature] (base64url), and [passwordHash] as a sync push sends it,
  /// which proves the sync password. Returns whether the key was new.
  Future<bool> registerRecoveryProof({
    required String publicKey,
    required String signature,
    required String passwordHash,
  }) async {
    final body = await _signedIn('PUT', '/account/recovery-proof',
        body: {'public_key': publicKey, 'signature': signature, 'password_hash': passwordHash});
    return body['changed'] == true;
  }

  // ── A computer's sign-in ───────────────────────────────────────────

  /// Trades the browser's hand-off [code] and this app's [verifier] for the
  /// fresh ID token, within two minutes. Kept in memory, for one change. Asked
  /// with this device's own sign-in: a code alone is no use to whoever else
  /// caught it.
  Future<String> redeemHandoff({required String code, required String verifier}) async {
    final body = await _signedIn('POST', '/auth/handoff/redeem', body: {'code': code, 'verifier': verifier});
    final token = body['id_token'];
    if (token is! String || token.isEmpty) throw const TwoStepRefusal(502, code: 'two-step-unavailable');
    return token;
  }

  /// Trades this computer's session for the same session with the second
  /// step, with a sign-in that passed it: a Firebase [idToken], or a browser
  /// sign-in's [code] and [verifier]. Its new session token.
  Future<String> upgradeSession({String? idToken, String? code, String? verifier}) async {
    final body = await _signedIn('POST', '/auth/session/upgrade',
        body: idToken != null ? {'id_token': idToken} : {'code': code, 'verifier': verifier});
    final token = body['session_token'];
    if (token is! String || token.isEmpty) throw const TwoStepRefusal(502, code: 'two-step-unavailable');
    return token;
  }
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

Map<String, dynamic> _decode(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : const {};
  } catch (_) {
    return const {};
  }
}
