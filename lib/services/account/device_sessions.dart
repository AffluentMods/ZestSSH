import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/secret_seal.dart';

/// Signed-in devices (3.0): this device's place in the
/// account's device list on ZestSSH Cloud (ZestSSH Cloud's routes/sessions.js).
///
/// A desktop signed in through the browser holds a session token that names
/// its session. A device signed in with Firebase directly (phones, tablets, a
/// Mac that uses Firebase) registers itself once and sends the registration
/// with every request to ZestSSH Cloud ([DeviceSessionHeader]), so signing it
/// out from another device takes effect at once.

/// What this device says about itself in the list: its platform, nothing
/// else. No hostname, model, OS version or app version: with when each
/// device signed in, enough for its owner to tell devices apart.
class DeviceLabels {
  const DeviceLabels({this.platform});

  /// windows, macos, linux, android or ios.
  final String? platform;

  Map<String, dynamic> toJson() => {
        if (platform != null) 'platform': platform,
      };

  static DeviceLabels forThisDevice() =>
      DeviceLabels(platform: devicePlatform(Platform.operatingSystem));
}

const _platforms = {'windows', 'macos', 'linux', 'android', 'ios'};

/// The platform name the server accepts, or null.
String? devicePlatform(String os) => _platforms.contains(os) ? os : null;

/// One signed-in device, as the server lists it.
class DeviceSessionInfo {
  const DeviceSessionInfo({
    required this.id,
    required this.kind,
    this.platform,
    this.createdAt,
    this.current = false,
  });

  factory DeviceSessionInfo.fromJson(Map<String, dynamic> json) {
    DateTime? time(Object? v) =>
        v is String ? DateTime.tryParse(v)?.toLocal() : null;
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    return DeviceSessionInfo(
      id: json['id'] as String,
      kind: text(json['kind']) ?? 'session_token',
      platform: text(json['platform']),
      createdAt: time(json['created_at']),
      current: json['current'] == true,
    );
  }

  final String id;

  /// session_token (a browser sign-in) or registration (signed in with
  /// Firebase directly).
  final String kind;
  final String? platform;

  /// When it signed in. Nothing records when a device is used: ZestSSH
  /// keeps no activity log.
  final DateTime? createdAt;

  /// This is the device asking.
  final bool current;

  bool get isPhone => platform == 'android' || platform == 'ios';
}

/// An answer from the device endpoints that is not a success.
class DeviceSessionsException implements Exception, HasTypeName {
  const DeviceSessionsException(this.status, [this.code]);

  final int status;
  final String? code;

  /// The server wants a sign-in from the last few minutes first.
  bool get needsRecentSignIn => code == 'recent-sign-in-required';

  /// This device itself was signed out.
  bool get signedOut => code == 'session-revoked';

  /// Every device was signed out, but Google sign-in could not be revoked.
  bool get identityRevokeFailed => code == 'identity-revoke-failed';

  @override
  String toString() => 'Signed-in devices: HTTP $status ${code ?? ''}'.trim();

  @override
  String get typeName => 'DeviceSessionsException';
}

/// The registration a device signed in with Firebase sends with its requests
/// to ZestSSH Cloud. Session tokens carry their session and send none.
class DeviceSessionHeader {
  DeviceSessionHeader._();

  static const name = 'X-ZestSSH-Session';

  /// This device's registration, or null: the token it was given when it
  /// registered, which proves that a request comes from this device (its
  /// bare id, which anybody of the account can list, proves nothing), or the
  /// id where the server gave no token.
  static String? current;

  /// What this app can tell its person about, sent with every request:
  /// ZestSSH Cloud refuses a device past the seven it syncs for one person
  /// only to an app that says it can explain that (apps from before 3.0
  /// cannot, and are let be).
  static const knowsName = 'X-ZestSSH-Knows';
  static const knows = 'cloud-device-limit';

  /// The headers for a request to ZestSSH Cloud: this device's registration
  /// where it has one, and what the app can tell its person about.
  static Map<String, String> get headers {
    final id = current;
    return {knowsName: knows, name: ?id};
  }
}

/// Goes up by one whenever ZestSSH Cloud says this device was signed out
/// from elsewhere. The app signs out here in response.
final ValueNotifier<int> sessionRevokedSignal = ValueNotifier<int>(0);

/// The reason ZestSSH Cloud gives with a sign-out that turning two-step
/// sign-in on caused: the sessions that never passed it are signed out.
const kSignedOutForTwoStep = 'second-step-required';

/// Why this device signs out when ZestSSH Cloud answers that the company
/// sign-in it used is gone (its team deleted, or an owner turned
/// it off): every call is refused from then on, so the app says so plainly
/// and signs that account out, instead of failing on every screen.
const kSignedOutSsoRemoved = 'sso-removed';

/// The reasons ZestSSH Cloud gives with a sign-out that a change to the
/// account's security caused (the two-step contract, section 6.1;
/// ZestSSH Cloud's lib/sessions.js): a way to pass two-step sign-in was
/// removed, two-step sign-in was turned off, a recovery code was used, the
/// account was recovered after it lost its sign-in, or its password or
/// sign-in changed. Every device but the one that made the change goes.
const kSignedOutFactorRemoved = 'factor-removed';
const kSignedOutTwoStepOff = 'two-step-off';
const kSignedOutRecoveryCodeUsed = 'recovery-code-used';
const kSignedOutAccountRecovered = 'account-recovered';
const kSignedOutPasswordChanged = 'password-changed';

/// Why ZestSSH Cloud last said this device was signed out: one of the
/// reasons above, [kSignedOutForTwoStep] or [kSignedOutSsoRemoved], or null
/// for a sign-out from another device. The notice says it (found in a security
/// review): a sign-out caused by two-step sign-in being turned
/// on read like an attack.
String? sessionRevokedReason;

/// A change this device makes to the account's sign-in, during which ZestSSH
/// Cloud may sign out the sign-in it is replacing: the first second step of
/// an account signs out every sign-in that never passed one, this device's
/// own among them, until it signs in again with it a moment later. A "signed
/// out" heard meanwhile is looked at once the change is over, with the
/// sign-in the device has then ([stillSignedInHere]), instead of signing the
/// device out (and its sync off) halfway through.
abstract final class SignInChange {
  static int _running = 0;
  static Completer<void>? _over;

  /// Whether one is under way.
  static bool get running => _running > 0;

  /// Runs [change] as one.
  static Future<T> during<T>(Future<T> Function() change) async {
    _running++;
    _over ??= Completer<void>();
    try {
      return await change();
    } finally {
      _running--;
      if (_running == 0) {
        final over = _over;
        _over = null;
        over?.complete();
      }
    }
  }

  /// Done at once while none runs, else when the one under way is over.
  static Future<void> settled() => _over?.future ?? Future<void>.value();
}

/// Goes up by one whenever ZestSSH Cloud says this computer's sign-in ran
/// out (30 days without use): nothing is signed out, and the app offers to
/// sign in again where it is, keeping sync (found in a security
/// review). The answer said only "Invalid token" before, and the advice was to
/// sign out, which turned sync off.
final ValueNotifier<int> sessionExpiredSignal = ValueNotifier<int>(0);

/// Checks an answer from ZestSSH Cloud for "this device was signed out" and
/// raises [sessionRevokedSignal]. Returns whether it was. A sign-in that ran
/// out raises [sessionExpiredSignal] instead, and is not a sign-out. A
/// company sign-in that is gone ([kSignedOutSsoRemoved]) signs out too.
bool reportIfSessionRevoked(http.Response response) {
  if (response.statusCode == 403 && _code(response.body) == kSignedOutSsoRemoved) {
    sessionRevokedReason = kSignedOutSsoRemoved;
    sessionRevokedSignal.value++;
    return true;
  }
  if (response.statusCode != 401) return false;
  final code = _code(response.body);
  if (code == 'session-expired') {
    sessionExpiredSignal.value++;
    return false;
  }
  if (code != 'session-revoked') return false;
  final reason = _decode(response.body)['reason'];
  sessionRevokedReason = reason is String ? reason : null;
  sessionRevokedSignal.value++;
  return true;
}

/// Whether ZestSSH Cloud still knows this device as signed in, asked with
/// what the device signs in with now: false only where it says the device
/// is signed out, or the device has nothing to sign in with.
///
/// An answer of "signed out" can be to a request made with a sign-in this
/// device has since replaced: signing in again to confirm it is you ends the
/// session it replaces, and what was on its way with the old one (the
/// team's live line above all) came back "signed out", which signed the app
/// out right after the person had signed in.
/// A device that cannot ask now is taken as still signed in: the next
/// answer from ZestSSH Cloud says it again where it is so.
Future<bool> stillSignedInHere(DeviceSessionsApi api) async {
  try {
    await api.current();
    return true;
  } on DeviceSessionsException catch (e) {
    return !(e.signedOut || e.code == 'signed-out' || e.code == kSignedOutSsoRemoved);
  } catch (_) {
    return true;
  }
}

String? _code(String body) {
  final code = _decode(body)['code'];
  return code is String ? code : null;
}

Map<String, dynamic> _decode(String body) {
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, dynamic> ? decoded : const {};
  } catch (_) {
    return const {};
  }
}

/// ZestSSH Cloud's device endpoints, always on the hosted server whatever
/// sync backend is in use, with the account's own sign-in.
class DeviceSessionsApi {
  DeviceSessionsApi({
    http.Client? client,
    String? baseUrl,
    required this.bearer,
    this.onScreen = true,
  })  : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? _defaultBase;

  /// Whether [bearer] is the account on screen's, whose session this device's
  /// registration is: only then is the registration sent.
  final bool onScreen;

  static String get _defaultBase => kZestApiBase;

  static const _timeout = Duration(seconds: 30);

  final http.Client _client;
  final String _base;

  /// The account's bearer: the Firebase ID token when signed in with
  /// Firebase, else the session token. Null when signed out.
  final Future<String?> Function() bearer;

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await bearer();
    if (token == null) throw const DeviceSessionsException(401, 'signed-out');
    return {
      'Authorization': 'Bearer $token',
      if (onScreen) ...DeviceSessionHeader.headers else DeviceSessionHeader.knowsName: DeviceSessionHeader.knows,
      if (json) 'Content-Type': 'application/json',
    };
  }

  Future<http.Response> _send(
      Future<http.Response> Function(Map<String, String> headers) send,
      {bool json = false}) async {
    final response = await send(await _headers(json: json)).timeout(_timeout);
    reportIfSessionRevoked(response);
    return response;
  }

  DeviceSessionsException _error(http.Response r) =>
      DeviceSessionsException(r.statusCode, _code(r.body));

  /// The account's signed-in devices, the asking one marked current.
  Future<List<DeviceSessionInfo>> list() async {
    final r = await _send(
        (h) => _client.get(Uri.parse('$_base/sessions'), headers: h));
    if (r.statusCode != 200) throw _error(r);
    final sessions = _decode(r.body)['sessions'];
    return [
      for (final s in sessions is List ? sessions : const [])
        if (s is Map<String, dynamic> && s['id'] is String)
          DeviceSessionInfo.fromJson(s),
    ];
  }

  /// Registers a device signed in with Firebase: its id, and the token that
  /// says from then on that a request comes from this device (null from a
  /// server from before tokens). It says that it keeps the token
  /// (token_only): the server then takes the registration's bare id, which
  /// anybody of the account can list, for no device at all.
  Future<({String id, String? token})> register(DeviceLabels labels) async {
    final r = await _send(
      (h) => _client.post(Uri.parse('$_base/sessions'),
          headers: h, body: jsonEncode({...labels.toJson(), 'token_only': true})),
      json: true,
    );
    final body = _decode(r.body);
    final id = body['id'];
    if (r.statusCode != 201 || id is! String) throw _error(r);
    final token = body['token'];
    return (id: id, token: token is String && token.startsWith('$id.') ? token : null);
  }

  /// This device's session id, or null when its sign-in has none: a session
  /// token from before sessions existed, or a device not registered yet.
  Future<String?> current() async {
    final r = await _send(
        (h) => _client.get(Uri.parse('$_base/sessions/current'), headers: h));
    if (r.statusCode == 404 && _code(r.body) == 'no-session') return null;
    final id = _decode(r.body)['id'];
    if (r.statusCode != 200 || id is! String) throw _error(r);
    return id;
  }

  /// Updates this device's labels, and says whether the request proved which
  /// device it comes from: null where the server does not say (one from
  /// before tokens).
  Future<bool?> label(DeviceLabels labels) async {
    final r = await _send(
      (h) => _client.put(Uri.parse('$_base/sessions/current'),
          headers: h, body: jsonEncode(labels.toJson())),
      json: true,
    );
    if (r.statusCode != 200) throw _error(r);
    final bound = _decode(r.body)['bound'];
    return bound is bool ? bound : null;
  }

  /// Signs one device out. Another device needs a recent sign-in
  /// ([DeviceSessionsException.needsRecentSignIn]); this one never does.
  /// With [as], the request names that session instead of this device's
  /// own (a registration this device made before, signing itself out), and
  /// what it is answered says nothing of whether this device is signed out.
  Future<void> signOut(String id, {String? as}) async {
    final uri = Uri.parse('$_base/sessions/${Uri.encodeComponent(id)}');
    if (as == null) {
      final r = await _send((h) => _client.delete(uri, headers: h));
      if (r.statusCode != 200) throw _error(r);
      return;
    }
    final headers = {...await _headers(), DeviceSessionHeader.name: as};
    final r = await _client.delete(uri, headers: headers).timeout(_timeout);
    if (r.statusCode != 200) throw _error(r);
  }

  /// Ends the session the bearer is: one this device no longer uses (another
  /// account's, or one a new sign-in replaced). Nothing is reported, unlike the
  /// calls above: what the answer says is about that session, never about the account
  /// on screen, which must not be signed out for it.
  Future<void> endOwnSession() async {
    final headers = await _headers();
    final r = await _client.get(Uri.parse('$_base/sessions/current'), headers: headers).timeout(_timeout);
    if (r.statusCode != 200) return;
    final id = _decode(r.body)['id'];
    if (id is! String) return;
    await _client.delete(Uri.parse('$_base/sessions/${Uri.encodeComponent(id)}'), headers: headers).timeout(_timeout);
  }

  /// Signs every device out, this one included. Returns how many sessions
  /// went. Needs a recent sign-in.
  Future<int> signOutEverywhere() async {
    final r = await _send((h) =>
        _client.post(Uri.parse('$_base/sessions/revoke-all'), headers: h));
    if (r.statusCode != 200) throw _error(r);
    final n = _decode(r.body)['signed_out'];
    return n is int ? n : 0;
  }

  /// A fresh session token for [token]. One from before sessions existed
  /// comes back naming a listed session.
  Future<String> refreshSessionToken(String token) async {
    final r = await _client.post(Uri.parse('$_base/auth/refresh'),
        headers: {'Authorization': 'Bearer $token'}).timeout(_timeout);
    reportIfSessionRevoked(r);
    final fresh = _decode(r.body)['session_token'];
    if (r.statusCode != 200 || fresh is! String) throw _error(r);
    return fresh;
  }
}

/// Where this device's registration is kept: which account it belongs to,
/// its id, and the token that proves it is this device ([token]: null where
/// the server gave none). [asked]: made by an app that asks for a token; a
/// registration kept from before tokens has an id alone and is made again.
class DeviceSessionStore {
  DeviceSessionStore(this._storage);

  static const storageKey = 'device_session_v1';

  final FlutterSecureStorage _storage;

  Future<({String uid, String id, String? token, bool asked})?> read() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null) return null;
    final json = _decode(raw);
    final uid = json['uid'];
    final id = json['id'];
    if (uid is! String || id is! String) return null;
    final token = json['token'];
    return (uid: uid, id: id, token: token is String ? token : null, asked: json['v'] == 2);
  }

  Future<void> save(String uid, String id, {String? token}) => _storage.write(
      key: storageKey,
      value: jsonEncode({'uid': uid, 'id': id, 'token': ?token, 'v': 2}));

  Future<void> clear() => _storage.delete(key: storageKey);
}

/// Keeps this device listed: registers a device signed in with Firebase,
/// turns a session token from before sessions existed into a listed one, and
/// keeps the labels current. Everything is best effort and never throws.
/// When the person really signed in, as a session token says (its `authTime`,
/// which renewing it keeps), in seconds since the epoch; null where it does not
/// say. Read only to warn before a team's rule asks for a new sign-in: the server
/// checks every token.
int? sessionTokenSignedInAt(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final at = payload is Map ? payload['authTime'] : null;
    return at is int ? at : null;
  } catch (_) {
    return null;
  }
}

/// When a session token was made (its `iat`), or null for what is not a
/// ZestSSH Cloud token. Read only to know when to renew it: the server
/// checks every token.
DateTime? sessionTokenIssuedAt(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final iat = payload is Map ? payload['iat'] : null;
    return iat is int ? DateTime.fromMillisecondsSinceEpoch(iat * 1000, isUtc: true) : null;
  } catch (_) {
    return null;
  }
}

/// A renewal of the session, as it begins: the profile open then, and what keeps a
/// token there. The next person's profile may be open by the time the answer comes:
/// it is not theirs, and it is dropped.
class _RenewalStart {
  _RenewalStart(this._service)
      : _profile = Profiles.current?.id,
        _save = _service.saverForNow?.call() ?? _service.saveSessionToken;

  final DeviceSessionService _service;
  final String? _profile;
  final Future<void> Function(String token) _save;

  Future<void> renew(String token) async {
    final fresh = await _service.api.refreshSessionToken(token);
    if (Profiles.current?.id != _profile) {
      AppLogger.info('Signed-in devices: a renewed session outlived its profile, and was dropped');
      return;
    }
    await _save(fresh);
  }
}

class DeviceSessionService {
  DeviceSessionService({
    required this.api,
    required this.store,
    required this.firebaseUid,
    required this.sessionToken,
    required this.saveSessionToken,
    required this.labels,
    this.issuedAt = sessionTokenIssuedAt,
    this.now = DateTime.now,
    this.saverForNow,
  });

  final DeviceSessionsApi api;
  final DeviceSessionStore store;

  /// The Firebase account id when signed in with Firebase, else null.
  final String? Function() firebaseUid;

  /// The browser sign-in's session token, when there is one.
  final Future<String?> Function() sessionToken;
  final Future<void> Function(String token) saveSessionToken;
  final Future<DeviceLabels> Function() labels;

  /// What keeps a renewed token in the profile open as this is asked, and no other,
  /// whatever opens while the answer is on its way. Null: [saveSessionToken].
  final Future<void> Function(String token) Function()? saverForNow;

  /// When a session token was made, and the time now.
  final DateTime? Function(String token) issuedAt;
  final DateTime Function() now;

  Future<void>? _running;

  /// How old a computer's session token gets before it is renewed. It lives
  /// 30 days and was never renewed while in use, so a computer was signed
  /// out every month and its sync had to be set up again (found in a security
  /// review). A renewal is not a sign-in: ZestSSH Cloud keeps the
  /// time of the sign-in, which every recent-sign-in check and a team's
  /// "Sign in again" rule go by, and checks the account again, two-step
  /// included.
  static const renewAfter = Duration(days: 7);

  /// How often whether to renew is looked at, at most.
  static const renewCheckEvery = Duration(hours: 1);

  Future<void>? _renewing;
  DateTime? _renewCheckedAt;

  /// Renews a computer's session token once it is [renewAfter] old: at the
  /// start, at sign-in, and when the app comes back to the front, at most
  /// every [renewCheckEvery]. One run at a time. One that fails is tried
  /// again later, and an answer that this device was signed out says so as
  /// every answer does.
  Future<void> renewIfOld() => _renewing ??= _renewIfOld().whenComplete(() => _renewing = null);

  Future<void> _renewIfOld() async {
    try {
      // A Firebase sign-in keeps itself fresh.
      if (firebaseUid() != null) return;
      final at = now();
      final checked = _renewCheckedAt;
      if (checked != null && at.difference(checked) < renewCheckEvery) return;
      _renewCheckedAt = at;
      // Before the token is read: it is this profile's, and so is what comes back.
      final started = _RenewalStart(this);
      final token = await sessionToken();
      if (token == null) return;
      final made = issuedAt(token);
      if (made == null || at.difference(made) < renewAfter) return;
      await started.renew(token);
      AppLogger.info('Signed-in devices: the session was renewed');
    } catch (e) {
      AppLogger.warning('Signed-in devices: the session was not renewed: $e');
    }
  }

  /// Makes sure this device is listed, with current labels. One run at a
  /// time; safe to call on every start and sign-in.
  Future<void> ensure() =>
      _running ??= _ensure().whenComplete(() => _running = null);

  Future<void> _ensure() async {
    // With the database closed what is kept reads as none, and that is no device
    // that was never listed: it would register again at every start.
    if (Profiles.on && SecretSeal.openTree == null) return;
    try {
      final uid = firebaseUid();
      if (uid != null) {
        await _ensureRegistration(uid);
      } else {
        DeviceSessionHeader.current = null;
        if (await sessionToken() != null) {
          await _ensureSessionToken();
          await renewIfOld();
        }
      }
    } catch (e) {
      AppLogger.warning('Signed-in devices: $e');
    }
  }

  Future<void> _ensureRegistration(String uid) async {
    final stored = await store.read();
    if (stored != null && stored.uid == uid && stored.asked) {
      DeviceSessionHeader.current = stored.token ?? stored.id;
      // Kept as it is unless the server says that what was sent proves
      // nothing: an id kept without a token, made where the server gave
      // none, once the server gives them.
      if (await api.label(await labels()) != false) return;
    }
    DeviceSessionHeader.current = null;
    final made = await api.register(await labels());
    await store.save(uid, made.id, token: made.token);
    DeviceSessionHeader.current = made.token ?? made.id;
    // A registration kept from an app from before tokens (an id alone,
    // which proves nothing of which device calls) is signed out now that
    // this device has one that does; it names itself by its id to do so.
    if (stored != null && stored.uid == uid) {
      try {
        await api.signOut(stored.id, as: stored.id);
      } catch (e) {
        AppLogger.warning('Signed-in devices: the registration from before was not signed out: $e');
      }
    }
  }

  Future<void> _ensureSessionToken() async {
    final started = _RenewalStart(this);
    if (await api.current() == null) {
      final token = await sessionToken();
      if (token == null) return;
      await started.renew(token);
    }
    await api.label(await labels());
  }

  /// Signs this device out on ZestSSH Cloud, best effort and briefly (an
  /// offline sign-out must not hang), then forgets its registration. Runs
  /// before the sign-in itself is dropped.
  Future<void> signOutHere({Duration within = const Duration(seconds: 6)}) async {
    try {
      await () async {
        final id = await api.current();
        if (id != null) await api.signOut(id);
      }()
          .timeout(within);
    } catch (e) {
      AppLogger.warning('Signed-in devices: signing out here: $e');
    }
    await forget();
  }

  /// Forgets this device's registration without asking the server.
  Future<void> forget() async {
    DeviceSessionHeader.current = null;
    try {
      await store.clear();
    } catch (_) {
      // Nothing to forget.
    }
  }
}
