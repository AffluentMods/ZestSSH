import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/utils/type_name.dart';

/// ZestSSH Cloud refused something about a locked copy: its [code], and its
/// HTTP [status].
class LockedCopyRefused implements Exception, HasTypeName {
  const LockedCopyRefused(this.status, this.code);

  final int status;
  final String code;

  @override
  String toString() => 'LockedCopyRefused($status, $code)';

  @override
  String get typeName => 'LockedCopyRefused';
}

/// A copy of the account's as ZestSSH Cloud lists it: what a person tells
/// their computers apart by, and no more.
class LockedCopyInfo {
  const LockedCopyInfo({required this.id, required this.platform, required this.madeOn});

  final String id;
  final String platform;
  final String madeOn;
}

/// What waits for an account, as numbers: the light check of another signed-in
/// account (the design's; nothing reads it yet).
class WaitingCounts {
  const WaitingCounts({this.invitations = 0, this.reviews = 0, this.accessRequests = 0, this.deviceApprovals = 0});

  final int invitations;
  final int reviews;
  final int accessRequests;
  final int deviceApprovals;

  int get total => invitations + reviews + accessRequests + deviceApprovals;
}

/// The secret of a locked copy at ZestSSH Cloud: `/v1/account/locked-copies`.
/// The server never sees a profile's key, only a secret that opens one copy on
/// one device. Each call carries the bearer it is given: during a sign-in the
/// session is not in the profile yet.
class LockedCopiesApi {
  LockedCopiesApi({http.Client? client, String? baseUrl})
      : _client = client,
        _base = baseUrl ?? _defaultBase;

  static String get _defaultBase => kZestApiBase;
  static const _timeout = Duration(seconds: 20);

  final http.Client? _client;
  final String _base;

  http.Client get _http => _client ?? PinnedHttpClient.client;

  /// [onScreen]: [bearer] is the account on screen's, whose session this
  /// device's registration is. Another account's bearer goes without it: the
  /// registration names a session of another account, and ZestSSH Cloud
  /// refused the call as one from a device signed out (found in a security
  /// review).
  Map<String, String> _headers(String bearer, {bool onScreen = true}) => {
        'Authorization': 'Bearer $bearer',
        if (onScreen) ...DeviceSessionHeader.headers else DeviceSessionHeader.knowsName: DeviceSessionHeader.knows,
        'Content-Type': 'application/json',
      };

  Never _refused(http.Response r) {
    String code = 'unknown';
    try {
      final body = jsonDecode(r.body);
      if (body is Map && body['code'] is String) code = body['code'] as String;
    } catch (_) {/* no words of its own */}
    throw LockedCopyRefused(r.statusCode, code);
  }

  /// Keeps [secret] as the copy [id]'s: the same id twice is one store, so an
  /// answer that was lost can be asked again.
  Future<void> store({required String bearer, required String id, required List<int> secret}) async {
    final r = await _http
        .post(Uri.parse('$_base/account/locked-copies'),
            headers: _headers(bearer),
            body: jsonEncode({'id': id, 'secret': _b64(secret), 'platform': Platform.operatingSystem}))
        .timeout(_timeout);
    if (r.statusCode != 200) _refused(r);
  }

  /// The secret of the copy [id], after a sign-in from the last ten minutes.
  /// Throws [LockedCopyRefused] with `locked-copy-not-found` where it is gone.
  Future<Uint8List> handBack({required String bearer, required String id}) async {
    final r = await _http
        .post(Uri.parse('$_base/account/locked-copies/$id/hand-back'), headers: _headers(bearer))
        .timeout(_timeout);
    if (r.statusCode != 200) _refused(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return base64Url.decode(base64Url.normalize(body['secret'] as String));
  }

  Future<List<LockedCopyInfo>> list({required String bearer}) async {
    final r = await _http.get(Uri.parse('$_base/account/locked-copies'), headers: _headers(bearer)).timeout(_timeout);
    if (r.statusCode != 200) _refused(r);
    return [
      for (final c in (jsonDecode(r.body) as Map<String, dynamic>)['copies'] as List)
        LockedCopyInfo(id: c['id'] as String, platform: c['platform'] as String, madeOn: c['made_on'] as String),
    ];
  }

  /// Deletes the copy [id]: whether there was one. [onScreen] as for [_headers].
  Future<bool> delete({required String bearer, required String id, bool onScreen = true}) async {
    final r = await _http
        .delete(Uri.parse('$_base/account/locked-copies/$id'), headers: _headers(bearer, onScreen: onScreen))
        .timeout(_timeout);
    if (r.statusCode != 200) _refused(r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['deleted'] == true;
  }

  /// What waits for the account asking: numbers only.
  Future<WaitingCounts> waiting({required String bearer}) async {
    final r = await _http.get(Uri.parse('$_base/account/waiting'), headers: _headers(bearer)).timeout(_timeout);
    if (r.statusCode != 200) _refused(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return WaitingCounts(
      invitations: j['invitations'] as int? ?? 0,
      reviews: j['reviews'] as int? ?? 0,
      accessRequests: j['access_requests'] as int? ?? 0,
      deviceApprovals: j['device_approvals'] as int? ?? 0,
    );
  }

  static String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
}

/// A copy of a profile's key, wrapped with a secret ZestSSH Cloud keeps.
class LockedCopy {
  const LockedCopy({required this.id, required this.blob});

  factory LockedCopy.parse(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return LockedCopy(id: j['id'] as String, blob: j['blob'] as String);
  }

  String toText() => jsonEncode({'id': id, 'blob': blob});

  final String id;
  final String blob;
}

/// A secret that opens no copy: altered, or another copy's.
class LockedCopyDoesNotOpen implements Exception, HasTypeName {
  const LockedCopyDoesNotOpen();

  @override
  String toString() => 'LockedCopyDoesNotOpen';

  @override
  String get typeName => 'LockedCopyDoesNotOpen';
}

/// What lets a signed-out account's profile be locked, and opened again.
///
/// When a profile first signs in online the device makes a secret and wraps
/// the database's key with it ([KeychainNames.lockedCopyNext]), keeps the
/// secret sealed in the profile until ZestSSH Cloud confirms it holds it (sent
/// again with the same id if the answer was lost), checks it opens the wrapped
/// copy, and only then forgets it. From then on [KeychainNames.lockedCopy]
/// holds a copy ZestSSH Cloud can open, and signing out needs no server. A
/// sign-in fetches the secret; a new one replaces it at once, and the old one
/// is then deleted at ZestSSH Cloud.
class LockedCopies {
  LockedCopies(this._device);

  final FlutterSecureStorage _device;

  static final _aes = AesGcm.with256bits();

  String _name(String profile, String entry) => '${KeychainPrefix.of(profile)}$entry';

  static List<int> _boundTo(String profile, String copy) => utf8.encode('zestssh locked copy v1\n$profile\n$copy');

  /// The copy that can be opened with ZestSSH Cloud's secret, or null where
  /// ZestSSH Cloud has yet to confirm one: such a profile can only be hidden at
  /// sign-out.
  Future<LockedCopy?> confirmed(String profile) async {
    final raw = await _device.read(key: _name(profile, KeychainNames.lockedCopy));
    return raw == null ? null : LockedCopy.parse(raw);
  }

  /// ZestSSH Cloud holds the copy [copyId] of [profile] no more: what this
  /// computer kept of it opens nothing, and goes, so that the profile is only
  /// hidden at a sign-out and its next sign-in makes a new copy. A copy made
  /// since (another id) stays.
  Future<void> forgetGone(String profile, String copyId) async {
    if ((await confirmed(profile))?.id != copyId) return;
    await _device.delete(key: _name(profile, KeychainNames.lockedCopy));
  }

  /// The key the [secret] opens in [copy] of [profile]. Throws
  /// [LockedCopyDoesNotOpen] where it does not.
  Future<String> open(String profile, LockedCopy copy, List<int> secret) async {
    try {
      final bytes = base64.decode(copy.blob);
      final box = SecretBox.fromConcatenation(bytes,
          nonceLength: _aes.nonceLength, macLength: _aes.macAlgorithm.macLength, copy: false);
      return utf8.decode(await _aes.decrypt(box, secretKey: SecretKey(secret), aad: _boundTo(profile, copy.id)));
    } catch (_) {
      throw const LockedCopyDoesNotOpen();
    }
  }

  static Future<(LockedCopy, List<int>)> _make(String profile, String hex) async {
    final rng = Random.secure();
    final secret = List<int>.generate(32, (_) => rng.nextInt(256));
    final idBytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final id = base64Url.encode(idBytes).replaceAll('=', '');
    final box = await _aes.encrypt(utf8.encode(hex), secretKey: SecretKey(secret), aad: _boundTo(profile, id));
    return (LockedCopy(id: id, blob: base64.encode(box.concatenation())), secret);
  }

  /// Tells ZestSSH Cloud of a new copy of [hex], the key of [profile], and
  /// keeps it, and deletes what it replaces; run once the profile is open,
  /// after every sign-in and at each start until it has worked. [seal] is the
  /// open profile's. True when a copy is confirmed by the end. Whatever cannot
  /// reach ZestSSH Cloud is left to try again; nothing else changes.
  Future<bool> settle({
    required ActiveProfile profile,
    required String hex,
    required SecretSeal seal,
    required String bearer,
    required LockedCopiesApi api,
    bool replace = false,
    bool signedInNow = false,
  }) async {
    final id = profile.id;
    await _takeOrphans(profile, seal);
    final current = await confirmed(id);
    var (next, secret) = await _pending(profile, seal);
    if (next == null || secret == null) {
      if (current != null && !replace) {
        // Deleted at ZestSSH Cloud only with a sign-in from the last ten minutes,
        // so at a sign-in: at any other start it would be refused, and what is
        // retired waits for the next one.
        if (signedInNow) await flushRetired(profile: profile, seal: seal, bearer: bearer, api: api);
        return true;
      }
      final made = await _make(id, hex);
      next = made.$1;
      secret = made.$2;
      // The secret first: a copy no secret opens is worth nothing, and one
      // without a copy is made again.
      final secretName = _name(id, KeychainNames.lockedCopySecret);
      await _device.write(
          key: secretName, value: await seal.seal(secretName, jsonEncode({'id': next.id, 'secret': base64.encode(secret)})));
      await _device.write(key: _name(id, KeychainNames.lockedCopyNext), value: next.toText());
    }
    // It must open before anything depends on it.
    if (await open(id, next, secret) != hex) {
      await _forgetPending(id);
      throw const LockedCopyDoesNotOpen();
    }
    await _storeMakingRoom(api, profile: profile, seal: seal, bearer: bearer, next: next, secret: secret);
    await _device.write(key: _name(id, KeychainNames.lockedCopy), value: next.toText());
    // Read back before anything depends on it: with it lost, deleting the copy it
    // replaces would delete the only way in there is. The pending one stays, and
    // the next try goes on from it.
    if (await _device.read(key: _name(id, KeychainNames.lockedCopy)) != next.toText()) {
      throw const LockedCopyDoesNotOpen();
    }
    if (current != null && current.id != next.id) await _retire(profile, seal, current.id);
    await _forgetPending(id);
    if (replace || signedInNow) await flushRetired(profile: profile, seal: seal, bearer: bearer, api: api);
    return true;
  }

  /// [next] told to ZestSSH Cloud. An account that holds as many as it may makes
  /// room with what this device has retired, and asks once more.
  Future<void> _storeMakingRoom(
    LockedCopiesApi api, {
    required ActiveProfile profile,
    required SecretSeal seal,
    required String bearer,
    required LockedCopy next,
    required List<int> secret,
  }) async {
    try {
      await api.store(bearer: bearer, id: next.id, secret: secret);
    } on LockedCopyRefused catch (e) {
      if (e.code != 'locked-copies-full') rethrow;
      await flushRetired(profile: profile, seal: seal, bearer: bearer, api: api);
      await api.store(bearer: bearer, id: next.id, secret: secret);
    }
  }

  /// The database of [profile] was made anew, with a new key (a Reset): what
  /// wrapped the old one opens nothing now, and read at a sign-in would only fail,
  /// at every sign-in, for good. They go, and the next sign-in makes a new copy.
  /// The id of the one ZestSSH Cloud holds is kept as it is, as it is no secret and
  /// the seal is gone with the old database: the next [settle] retires it.
  Future<void> forgetForNewKey(String profile) async {
    final copy = await confirmed(profile);
    if (copy != null) await _device.write(key: _name(profile, KeychainNames.lockedCopyOrphan), value: copy.id);
    for (final name in [
      KeychainNames.lockedCopy,
      KeychainNames.lockedCopyNext,
      KeychainNames.lockedCopySecret,
      KeychainNames.lockedCopiesRetired,
    ]) {
      await _device.delete(key: _name(profile, name));
    }
  }

  Future<void> _takeOrphans(ActiveProfile profile, SecretSeal seal) async {
    final name = _name(profile.id, KeychainNames.lockedCopyOrphan);
    final orphan = await _device.read(key: name);
    if (orphan == null) return;
    await _retire(profile, seal, orphan);
    await _device.delete(key: name);
  }

  Future<(LockedCopy?, List<int>?)> _pending(ActiveProfile profile, SecretSeal seal) async {
    final id = profile.id;
    final rawNext = await _device.read(key: _name(id, KeychainNames.lockedCopyNext));
    final secretName = _name(id, KeychainNames.lockedCopySecret);
    final rawSecret = await _device.read(key: secretName);
    if (rawNext == null || rawSecret == null) return (null, null);
    try {
      final next = LockedCopy.parse(rawNext);
      final j = jsonDecode(await seal.open(secretName, rawSecret)) as Map<String, dynamic>;
      if (j['id'] != next.id) return (null, null);
      return (next, base64.decode(j['secret'] as String));
    } catch (_) {
      return (null, null);
    }
  }

  Future<void> _forgetPending(String id) async {
    await _device.delete(key: _name(id, KeychainNames.lockedCopySecret));
    await _device.delete(key: _name(id, KeychainNames.lockedCopyNext));
  }

  Future<void> _retire(ActiveProfile profile, SecretSeal seal, String copyId) async {
    final ids = {...await _retired(profile, seal), copyId};
    final name = _name(profile.id, KeychainNames.lockedCopiesRetired);
    await _device.write(key: name, value: await seal.seal(name, jsonEncode(ids.toList())));
  }

  Future<Set<String>> _retired(ActiveProfile profile, SecretSeal seal) async {
    final name = _name(profile.id, KeychainNames.lockedCopiesRetired);
    final raw = await _device.read(key: name);
    if (raw == null) return {};
    try {
      return {for (final id in jsonDecode(await seal.open(name, raw)) as List) id as String};
    } catch (_) {
      return {};
    }
  }

  /// Deletes at ZestSSH Cloud what this device no longer needs. A refusal
  /// leaves it for later: the secret opens nothing here any more.
  Future<void> flushRetired({
    required ActiveProfile profile,
    required SecretSeal seal,
    required String bearer,
    required LockedCopiesApi api,
  }) async {
    final ids = await _retired(profile, seal);
    if (ids.isEmpty) return;
    final left = <String>{};
    for (final id in ids) {
      try {
        await api.delete(bearer: bearer, id: id);
      } catch (_) {
        left.add(id);
      }
    }
    final name = _name(profile.id, KeychainNames.lockedCopiesRetired);
    if (left.isEmpty) {
      await _device.delete(key: name);
    } else if (left.length != ids.length) {
      await _device.write(key: name, value: await seal.seal(name, jsonEncode(left.toList())));
    }
  }
}
