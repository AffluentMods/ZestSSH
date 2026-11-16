import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';

/// What ZestSSH Cloud holds for the signed-in account.
class ServerAccountKeys {
  const ServerAccountKeys({required this.uid, this.published});

  /// The account id the server knows this sign-in as: the id a self-signature
  /// must cover.
  final String uid;

  /// Its published keys, or null when there are none yet.
  final PublishedAccountKeys? published;
}

/// Another device published different keys first.
class AccountKeysConflict implements Exception, HasTypeName {
  const AccountKeysConflict(this.existing);

  /// The keys that won, when the server said.
  final PublishedAccountKeys? existing;

  @override
  String get typeName => 'AccountKeysConflict';

  @override
  String toString() => typeName;
}

/// One Orchard or Crate key copy the account holds, sealed to its next keys
/// and signed with them, for a replacement (3.0).
class ResealedKeyCopy {
  const ResealedKeyCopy({
    required this.orchardId,
    this.crateId,
    required this.generation,
    required this.sealed,
    required this.signature,
  });

  final String orchardId;

  /// Null for the Orchard's own key.
  final String? crateId;
  final int generation;
  final Uint8List sealed;
  final Uint8List signature;
}

/// Replacing keys needs a sign-in from the last few minutes: new keys change
/// what teammates trust.
class AccountKeysNeedRecentSignIn implements Exception, HasTypeName {
  const AccountKeysNeedRecentSignIn();

  @override
  String toString() => 'AccountKeysNeedRecentSignIn';

  @override
  String get typeName => 'AccountKeysNeedRecentSignIn';
}

/// The last entry of an Orchard's record, as the server names it when a
/// replacement did not bring a member.keys entry for every Orchard the
/// account is in: the entry's number and hash.
typedef RecordHeadJson = ({int seq, Uint8List hash});

/// A replacement must bring a member.keys entry for each Orchard in [heads],
/// following the entry named there (a suspended member cannot read its
/// Orchard's record, so the server names it). Nothing was replaced.
class AccountKeysRecordsNeeded implements Exception, HasTypeName {
  const AccountKeysRecordsNeeded(this.heads);

  final Map<String, RecordHeadJson> heads;

  @override
  String toString() => 'AccountKeysRecordsNeeded(${heads.keys.join(', ')})';

  @override
  String get typeName => 'AccountKeysRecordsNeeded';
}

/// This device holds the account's published keys: nothing to start over
/// from. A device that holds them replaces them instead, which teammates
/// follow without comparing again.
class AccountKeysStillHere implements Exception, HasTypeName {
  const AccountKeysStillHere();

  @override
  String toString() => 'AccountKeysStillHere';

  @override
  String get typeName => 'AccountKeysStillHere';
}

/// A replacement found things changed meanwhile: the keys were replaced on
/// another device (`version-conflict`), the account's key copies changed, a
/// new Crate or a rotation (`copies-changed`), or an Orchard's record moved
/// on before the new keys went into it (`record-moved`). Nothing was
/// replaced.
class AccountKeysReplaceConflict implements Exception, HasTypeName {
  const AccountKeysReplaceConflict(this.code);

  final String code;

  bool get copiesChanged => code == 'copies-changed';

  @override
  String toString() => 'AccountKeysReplaceConflict($code)';

  @override
  String get typeName => 'AccountKeysReplaceConflict';
}

/// ZestSSH Cloud's account-keys endpoints (ZestSSH Cloud's routes/keys.js),
/// always on the hosted server whatever sync backend is in use, with the
/// account's own sign-in (never a custom sync server's token).
class AccountKeysApi {
  AccountKeysApi({
    http.Client? client,
    String? baseUrl,
    required this.bearer,
  })  : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? _defaultBase;

  static String get _defaultBase => kZestApiBase;

  final http.Client _client;
  final String _base;

  /// The account's bearer: the Firebase ID token on phones, the session
  /// token on desktop. Null when signed out.
  final Future<String?> Function() bearer;

  /// The account's published keys. Null when signed out; throws on a
  /// network or server error.
  Future<ServerAccountKeys?> mine() async {
    final token = await bearer();
    if (token == null) return null;
    final response = await _client.get(
      Uri.parse('$_base/keys/me'),
      headers: {'Authorization': 'Bearer $token', ...DeviceSessionHeader.headers},
    ).timeout(const Duration(seconds: 30));
    reportIfSessionRevoked(response);
    final body = _decode(response.body);
    final uid = body['uid'];
    if (uid is! String || uid.isEmpty) {
      throw StateError('Account keys: HTTP ${response.statusCode}');
    }
    if (response.statusCode == 404 && body['code'] == 'no-keys') {
      return ServerAccountKeys(uid: uid);
    }
    if (response.statusCode != 200) {
      throw StateError('Account keys: HTTP ${response.statusCode}');
    }
    return ServerAccountKeys(
      uid: uid,
      published: PublishedAccountKeys.fromJson(uid, body),
    );
  }

  /// Publishes the account's first keys. Throws [AccountKeysConflict] when
  /// another device published different ones first.
  Future<void> publish(PublishedAccountKeys keys) async {
    final token = await bearer();
    if (token == null) throw StateError('Signed out');
    final response = await _client
        .post(
          Uri.parse('$_base/keys'),
          headers: {
            'Authorization': 'Bearer $token',
            ...DeviceSessionHeader.headers,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(keys.toJson()),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 200 || response.statusCode == 201) return;
    final body = _decode(response.body);
    if (response.statusCode == 409 && body['code'] == 'keys-exist') {
      final existing = body['keys'];
      throw AccountKeysConflict(existing is Map<String, dynamic>
          ? PublishedAccountKeys.fromJson(keys.uid, existing)
          : null);
    }
    throw StateError('Publishing account keys: HTTP ${response.statusCode} '
        '${body['code'] ?? ''}');
  }

  /// Replaces the account's keys with [next], their very next version, and in
  /// the same step every key copy the account holds with [copies] (each
  /// re-sealed to [next] and signed with it). [endorsement] is the current
  /// keys' signature over [next], when this device still has them; an
  /// account in any Orchard must bring it, and [records], a member.keys
  /// entry for each Orchard's record (JSON, by Orchard id). Throws
  /// [AccountKeysNeedRecentSignIn], [AccountKeysRecordsNeeded] or
  /// [AccountKeysReplaceConflict]; on any failure nothing changed on the
  /// server.
  Future<void> replace(
    PublishedAccountKeys next, {
    Uint8List? endorsement,
    required List<ResealedKeyCopy> copies,
    Map<String, Map<String, dynamic>> records = const {},
  }) async {
    final token = await bearer();
    if (token == null) throw StateError('Signed out');
    Map<String, dynamic> copyJson(ResealedKeyCopy c, String idField, String id) => {
          idField: id,
          'generation': c.generation,
          'sealed': base64Encode(c.sealed),
          'signature': base64Encode(c.signature),
        };
    final body = {
      ...next.toJson(),
      if (endorsement != null) 'endorsement': base64Encode(endorsement),
      'copies': {
        'orchards': [
          for (final c in copies)
            if (c.crateId == null) copyJson(c, 'orchard_id', c.orchardId),
        ],
        'crates': [
          for (final c in copies)
            if (c.crateId != null) copyJson(c, 'crate_id', c.crateId!),
        ],
      },
      if (records.isNotEmpty) 'records': records,
    };
    final response = await _client
        .put(
          Uri.parse('$_base/keys'),
          headers: {
            'Authorization': 'Bearer $token',
            ...DeviceSessionHeader.headers,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 60));
    reportIfSessionRevoked(response);
    if (response.statusCode == 200) return;
    final answer = _decode(response.body);
    final code = answer['code'];
    if (response.statusCode == 403 && code == 'recent-sign-in-required') {
      throw const AccountKeysNeedRecentSignIn();
    }
    if (response.statusCode == 409 && code == 'records-changed') {
      final heads = <String, RecordHeadJson>{};
      final listed = answer['heads'];
      if (listed is List) {
        for (final h in listed) {
          if (h is Map<String, dynamic> && h['orchard_id'] is String && h['seq'] is int && h['head'] is String) {
            try {
              heads[h['orchard_id'] as String] = (seq: h['seq'] as int, hash: base64Decode(h['head'] as String));
            } on FormatException {
              // Left out: the retry is refused again, and said so.
            }
          }
        }
      }
      throw AccountKeysRecordsNeeded(heads);
    }
    if (response.statusCode == 409 &&
        (code == 'version-conflict' || code == 'copies-changed' || code == 'record-moved')) {
      throw AccountKeysReplaceConflict(code as String);
    }
    throw StateError('Replacing account keys: HTTP ${response.statusCode} ${code ?? ''}');
  }

  /// Starts the account over with [next], the version after its published
  /// keys, when those were lost with every device that held them (3.0):
  /// nothing vouches for [next], every key copy sealed to the old keys
  /// goes, and each of the account's Orchards waits for team recovery or a
  /// new invitation. Throws [AccountKeysNeedRecentSignIn], and
  /// [AccountKeysReplaceConflict] ('version-conflict') when the keys moved
  /// on meanwhile; on any failure nothing changed on the server.
  Future<void> reset(PublishedAccountKeys next) async {
    final token = await bearer();
    if (token == null) throw StateError('Signed out');
    final response = await _client
        .post(
          Uri.parse('$_base/keys/reset'),
          headers: {
            'Authorization': 'Bearer $token',
            ...DeviceSessionHeader.headers,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(next.toJson()),
        )
        .timeout(const Duration(seconds: 30));
    reportIfSessionRevoked(response);
    if (response.statusCode == 200) return;
    final answer = _decode(response.body);
    final code = answer['code'];
    if (response.statusCode == 403 && code == 'recent-sign-in-required') {
      throw const AccountKeysNeedRecentSignIn();
    }
    if (response.statusCode == 409 && code == 'version-conflict') {
      throw const AccountKeysReplaceConflict('version-conflict');
    }
    throw StateError('Starting over with new keys: HTTP ${response.statusCode} ${code ?? ''}');
  }

  static Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }
}

/// How far this device trusts the keys it holds for an account.
enum StoredKeyState {
  /// Made here, not published yet.
  pending,

  /// Came from another device through sync; trusted once they match what
  /// the server published.
  synced,

  /// Match the published keys. Only these travel in the sync payload.
  confirmed,

  /// Were confirmed, but the server now shows other keys: replaced on
  /// another device, or substituted. Kept, never deleted, not synced.
  superseded,
}

class StoredAccountKeys {
  const StoredAccountKeys(this.state, this.secret);

  final StoredKeyState state;

  /// [AccountKeys.toSecretJson].
  final Map<String, dynamic> secret;

  int get version => secret['version'] is int ? secret['version'] as int : 0;

  Map<String, dynamic> toJson() => {'state': state.name, 'secret': secret};

  static StoredAccountKeys? fromJson(Object? json) {
    if (json is! Map) return null;
    final state = StoredKeyState.values
        .where((s) => s.name == json['state'])
        .firstOrNull;
    final secret = json['secret'];
    if (state == null || secret is! Map) return null;
    return StoredAccountKeys(state, Map<String, dynamic>.from(secret));
  }
}

/// Account keys in the OS secure storage, one entry per account so two
/// ZestSSH accounts on one device never mix, and their place in the
/// end-to-end-encrypted sync payload.
class AccountKeyStore {
  AccountKeyStore(this._storage, {AppDatabase? Function()? tree}) : _tree = tree;

  final FlutterSecureStorage _storage;

  /// Your Tree's database, whose seal keeps the keys while the encrypting
  /// lock is on ([SecretSeal]); null while it is closed. None in a test that
  /// keeps them as they are.
  final AppDatabase? Function()? _tree;

  static const prefix = 'account_keys_v1_';

  /// Keys a replacement made, kept from BEFORE they are published until this
  /// device has switched to them: a replacement cut off after the server took
  /// the keys can never leave the account with keys no device holds.
  static const nextPrefix = 'account_keys_next_v1_';

  /// The keys a replacement retired on this device: set aside, never synced,
  /// never used to sign.
  static const previousPrefix = 'account_keys_prev_v1_';

  static final _uid = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  Future<StoredAccountKeys?> read(String uid) => _read('$prefix$uid');

  Future<void> write(String uid, StoredAccountKeys keys) => _write(prefix, uid, keys);

  Future<StoredAccountKeys?> readNext(String uid) => _read('$nextPrefix$uid');

  Future<void> writeNext(String uid, StoredAccountKeys keys) => _write(nextPrefix, uid, keys);

  Future<void> deleteNext(String uid) => _storage.delete(key: '$nextPrefix$uid');

  Future<StoredAccountKeys?> readPrevious(String uid) => _read('$previousPrefix$uid');

  Future<void> writePrevious(String uid, StoredAccountKeys keys) =>
      _write(previousPrefix, uid, keys);

  /// Every key this device holds for the account: current, next and retired.
  Future<void> delete(String uid) async {
    await _storage.delete(key: '$prefix$uid');
    await _storage.delete(key: '$nextPrefix$uid');
    await _storage.delete(key: '$previousPrefix$uid');
  }

  Future<StoredAccountKeys?> _read(String key) async {
    final raw = await openKept(_tree?.call(), key, await _storage.read(key: key));
    if (raw == null) return null;
    try {
      return StoredAccountKeys.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String prefix, String uid, StoredAccountKeys keys) async {
    if (!_uid.hasMatch(uid)) throw ArgumentError('Not an account id');
    final slot = '$prefix$uid';
    await _storage.write(key: slot, value: await keepSealed(_tree?.call(), slot, jsonEncode(keys.toJson())));
  }

  /// Whether keys here wait on the server's word: keys that arrived through
  /// sync or were made here and are not confirmed yet, keys set aside
  /// because the server showed others, or a replacement not finished.
  Future<bool> needsAttention() async {
    for (final name in await keychainStoreNames(_storage)) {
      if (name.startsWith(nextPrefix)) return true;
      if (!name.startsWith(prefix)) continue;
      final stored = await _read(name);
      if (stored != null && stored.state != StoredKeyState.confirmed) return true;
    }
    return false;
  }

  /// The account id of a computer's session saved before it kept the
  /// account's id (lib/app.dart): which keys are its own it cannot tell.
  static const unknownAccount = 'desktop-session';

  /// The confirmed keys of [account], the account signed in, for its sync
  /// payload and backups: none when signed out (null). A device keeps the
  /// keys of every account signed in on it, and each went into the payload
  /// of whichever was signed in, so into its cloud copy and its other
  /// devices (found in a whitepaper check). A computer whose session
  /// is [unknownAccount] sends none: it sent every account's, so one account's
  /// team keys reached another account's sync data before; the
  /// session's own token names its account now (sessionAccountUid).
  Future<Map<String, dynamic>> exportForSync({required String? account}) async {
    if (account == null || account == unknownAccount) return {};
    final uids = (await keychainStoreNames(_storage))
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .where((uid) => uid == account)
        .toList()
      ..sort();
    final out = <String, dynamic>{};
    for (final uid in uids) {
      final stored = await read(uid);
      if (stored != null && stored.state == StoredKeyState.confirmed) {
        out[uid] = stored.secret;
      }
    }
    return out;
  }

  /// Keys another device synced. Stored as [StoredKeyState.synced], to be
  /// trusted once they match what the server published, unless this device
  /// already holds the same keys or confirmed ones at least as new. Returns
  /// how many were stored. Signed in as [account], only that account's are
  /// taken (an older device sent every account's it held); signed out, or
  /// [unknownAccount], all are, as a backup restored before signing in
  /// needs them, and none is trusted before it matches the server.
  Future<int> importFromSync(Object? raw, {String? account}) async {
    if (raw is! Map) return 0;
    // On a computer a backup restores into the profile on screen, and guest
    // data takes in no account's team keys.
    if (Profiles.on && (account == null || account == unknownAccount)) return 0;
    final only = account == null || account == unknownAccount ? null : account;
    var stored = 0;
    for (final entry in raw.entries) {
      final uid = entry.key;
      final value = entry.value;
      if (uid is! String || !_uid.hasMatch(uid) || value is! Map) continue;
      if (only != null && uid != only) continue;
      final secret = Map<String, dynamic>.from(value);
      try {
        await AccountKeys.fromSecretJson(secret);
      } on FormatException {
        continue;
      }
      final incomingVersion = secret['version'] as int;
      final local = await read(uid);
      if (local != null) {
        if (jsonEncode(local.secret) == jsonEncode(secret)) continue;
        if (local.state == StoredKeyState.confirmed &&
            local.version >= incomingVersion) {
          continue;
        }
        if (local.state == StoredKeyState.superseded &&
            local.version > incomingVersion) {
          continue;
        }
      }
      await write(uid, StoredAccountKeys(StoredKeyState.synced, secret));
      stored++;
    }
    return stored;
  }
}

/// This device holds no usable account keys: signed out, or the keys have
/// not arrived yet from the device that made them.
class AccountKeysNotReady implements Exception, HasTypeName {
  const AccountKeysNotReady();

  @override
  String toString() => 'AccountKeysNotReady';

  @override
  String get typeName => 'AccountKeysNotReady';
}

/// Where the signed-in account's keys stand on this device.
enum AccountKeyStatus {
  /// This device holds the published keys.
  ready,

  /// Keys are published but this device does not have them yet: sync will
  /// bring them from the device that made them.
  waitingForAnotherDevice,

  /// The server shows keys this device did not make or receive (replaced on
  /// another device, or substituted). This device's keys are kept.
  changedElsewhere,

  /// Signed out, or the server's answer could not be trusted.
  unavailable,
}

/// Makes sure the signed-in account has keys, published once, and that this
/// device holds them (3.0).
///
/// The server is the arbiter of which keys are the account's: publishing is
/// create-only, so when two devices race the first one wins and the other
/// adopts the winner's keys once sync brings them. Keys this device once
/// confirmed are never deleted on the server's word; they are set aside.
class AccountKeyService {
  AccountKeyService({
    required this.api,
    required this.store,
    required this.onKeysChanged,
  });

  final AccountKeysApi api;
  final AccountKeyStore store;

  /// Called when this device's confirmed keys change, so sync carries them.
  final void Function() onKeysChanged;

  Future<AccountKeyStatus> ensureKeys() async {
    final server = await api.mine();
    if (server == null) return AccountKeyStatus.unavailable;
    final uid = server.uid;
    if (server.published != null) {
      await _finishReplacement(uid, server.published!);
      return _reconcile(uid, await store.read(uid), server.published!);
    }
    final local = await store.read(uid);

    // Nothing published yet: publish the first keys this device holds (they
    // are this account's own, from this device or through its encrypted
    // sync), or new ones.
    var keys = await _parse(local);
    if (keys == null || keys.version != 1) {
      keys = await AccountKeys.generate();
      await store.write(
          uid, StoredAccountKeys(StoredKeyState.pending, await keys.toSecretJson()));
    }
    try {
      await api.publish(await keys.publish(uid));
    } on AccountKeysConflict catch (e) {
      final winner = e.existing ?? (await api.mine())?.published;
      if (winner == null) return AccountKeyStatus.unavailable;
      return _reconcile(uid, await store.read(uid), winner);
    }
    await store.write(uid,
        StoredAccountKeys(StoredKeyState.confirmed, await keys.toSecretJson()));
    AppLogger.info('Account keys published (version ${keys.version})');
    onKeysChanged();
    return AccountKeyStatus.ready;
  }

  Future<AccountKeyStatus> _reconcile(
    String uid,
    StoredAccountKeys? local,
    PublishedAccountKeys published,
  ) async {
    if (!await published.verify()) {
      AppLogger.warning('Account keys: the published keys do not verify');
      return AccountKeyStatus.unavailable;
    }
    final keys = await _parse(local);
    if (keys != null && published.matches(keys)) {
      if (local!.state != StoredKeyState.confirmed) {
        await store.write(
            uid, StoredAccountKeys(StoredKeyState.confirmed, local.secret));
        onKeysChanged();
      }
      return AccountKeyStatus.ready;
    }
    if (local == null) return AccountKeyStatus.waitingForAnotherDevice;
    switch (local.state) {
      case StoredKeyState.pending:
      case StoredKeyState.synced:
        // Never published, or a stale copy whose source still has it.
        await store.delete(uid);
        return AccountKeyStatus.waitingForAnotherDevice;
      case StoredKeyState.confirmed:
        await store.write(
            uid, StoredAccountKeys(StoredKeyState.superseded, local.secret));
        onKeysChanged();
        AppLogger.warning(
            'Account keys: the server shows keys this device did not make');
        return AccountKeyStatus.changedElsewhere;
      case StoredKeyState.superseded:
        return AccountKeyStatus.changedElsewhere;
    }
  }

  /// Replaces the account's keys after a device was lost or taken (3.0):
  /// new keys, the next version, endorsed by the current ones,
  /// published together with every Orchard and Crate key copy the account
  /// holds, re-sealed to the new keys by [reseal]. The server takes all of it
  /// or none. Then this device switches to the new keys and sync carries them
  /// to the account's other devices; the old keys are set aside here.
  ///
  /// Throws [AccountKeysNotReady] when this device does not hold the
  /// account's current keys, [AccountKeysNeedRecentSignIn] when the person
  /// must sign in again first, and [AccountKeysReplaceConflict] when the keys
  /// or the copies changed meanwhile (try again). Returns the account id and
  /// the new keys.
  Future<({String uid, AccountKeys keys})> replaceKeys({
    required Future<List<ResealedKeyCopy>> Function(String uid, AccountKeys next) reseal,
    Future<Map<String, Map<String, dynamic>>> Function(String uid, AccountKeys next,
            PublishedAccountKeys published, Uint8List endorsement, Map<String, RecordHeadJson> heads)?
        records,
  }) async {
    // An attempt whose answer was lost may have gone through: then it is
    // finished here, never followed by a second replacement.
    final server = await api.mine();
    final shown = server?.published;
    if (server != null && shown != null) {
      final finished = await _finishReplacement(server.uid, shown);
      if (finished != null) return (uid: server.uid, keys: finished);
    }
    final ready = await readyKeys();
    if (ready == null) throw const AccountKeysNotReady();
    final uid = ready.uid;
    final current = ready.keys;
    // A replacement this device began and did not finish is carried on with
    // the same new keys: they may already be on the server.
    var next = await _parse(await store.readNext(uid));
    if (next == null || next.version != current.version + 1) {
      next = await AccountKeys.generate(version: current.version + 1);
      await store.writeNext(
          uid, StoredAccountKeys(StoredKeyState.pending, await next.toSecretJson()));
    }
    final published = await next.publish(uid);
    final endorsement = await current.endorse(published);
    final copies = await reseal(uid, next);
    // Every Orchard's record hears of the new keys in the same step:
    // those this device follows at their last entry here, and any other the
    // server names, at the entry it names.
    final noHeads = <String, RecordHeadJson>{};
    var entries = records == null ? const <String, Map<String, dynamic>>{} : await records(uid, next, published, endorsement, noHeads);
    try {
      await api.replace(published, endorsement: endorsement, copies: copies, records: entries);
    } on AccountKeysRecordsNeeded catch (e) {
      if (records == null || e.heads.isEmpty) rethrow;
      entries = await records(uid, next, published, endorsement, e.heads);
      await api.replace(published, endorsement: endorsement, copies: copies, records: entries);
    }
    await _switchTo(uid, next, retired: current);
    AppLogger.info('Account keys replaced (version ${next.version})');
    return (uid: uid, keys: next);
  }

  /// Starts the account over with new keys after the keys themselves were
  /// lost with every device that held them (3.0): the next version,
  /// published with nothing to vouch for it. Teammates see the change as
  /// unvouched, and each Orchard waits for two owners to recover the account
  /// (team recovery) or for a new invitation. Keys this device held for the
  /// account are set aside, never deleted.
  ///
  /// Throws [AccountKeysNotReady] when signed out or the account has no
  /// keys yet, [AccountKeysStillHere] when this device holds the published
  /// keys, [AccountKeysNeedRecentSignIn] when the person must sign in again
  /// first, and [AccountKeysReplaceConflict] when the keys moved on
  /// meanwhile. Returns the account id and the new keys.
  Future<({String uid, AccountKeys keys})> startOver() async {
    final server = await api.mine();
    final published = server?.published;
    if (server == null || published == null) throw const AccountKeysNotReady();
    final uid = server.uid;
    // A start-over whose answer was lost may have gone through.
    final finished = await _finishReplacement(uid, published);
    if (finished != null) return (uid: uid, keys: finished);
    final held = await _parse(await store.read(uid));
    if (held != null && published.matches(held)) throw const AccountKeysStillHere();
    // A start-over this device began and did not finish goes on with the
    // same new keys: they may already be on the server.
    var next = await _parse(await store.readNext(uid));
    if (next == null || next.version != published.version + 1) {
      next = await AccountKeys.generate(version: published.version + 1);
      await store.writeNext(
          uid, StoredAccountKeys(StoredKeyState.pending, await next.toSecretJson()));
    }
    await api.reset(await next.publish(uid));
    await _switchTo(uid, next, retired: held);
    AppLogger.info('Account keys: started over (version ${next.version})');
    return (uid: uid, keys: next);
  }

  /// When the server has the keys a replacement on this device made, switch
  /// to them (the replacement was cut off before it did) and return them;
  /// when it has keys of a later version than they are, they are of no use
  /// any more.
  Future<AccountKeys?> _finishReplacement(String uid, PublishedAccountKeys published) async {
    final stored = await store.readNext(uid);
    if (stored == null) return null;
    final next = await _parse(stored);
    if (next != null && published.matches(next)) {
      await _switchTo(uid, next, retired: await _parse(await store.read(uid)));
      AppLogger.info('Account keys: finished a replacement (version ${next.version})');
      return next;
    }
    if (next == null || published.version >= next.version) {
      await store.deleteNext(uid);
    }
    return null;
  }

  Future<void> _switchTo(String uid, AccountKeys next, {AccountKeys? retired}) async {
    if (retired != null && retired.version < next.version) {
      await store.writePrevious(
          uid, StoredAccountKeys(StoredKeyState.superseded, await retired.toSecretJson()));
    }
    await store.write(uid, StoredAccountKeys(StoredKeyState.confirmed, await next.toSecretJson()));
    await store.deleteNext(uid);
    onKeysChanged();
  }

  /// The signed-in account's id and keys, when this device holds the keys
  /// the server published for it and they verify; null otherwise (signed
  /// out, keys not here yet, or changed elsewhere). What Orchards sign and
  /// open keys with (3.0).
  Future<({String uid, AccountKeys keys})?> readyKeys() async {
    final server = await api.mine();
    final published = server?.published;
    if (server == null || published == null) return null;
    final local = await store.read(server.uid);
    final keys = await _parse(local);
    if (keys == null ||
        local!.state != StoredKeyState.confirmed ||
        !published.matches(keys) ||
        !await published.verify()) {
      return null;
    }
    return (uid: server.uid, keys: keys);
  }

  /// The keys this device holds for [uid] as the server last confirmed them,
  /// without asking it: for when it cannot be reached. Null when there are
  /// none, when they were never confirmed, or when the server has since
  /// shown others (they are kept as superseded then, and used for nothing).
  Future<AccountKeys?> confirmedKeysHere(String uid) async {
    final local = await store.read(uid);
    if (local == null || local.state != StoredKeyState.confirmed) return null;
    return _parse(local);
  }

  static Future<AccountKeys?> _parse(StoredAccountKeys? stored) async {
    if (stored == null) return null;
    try {
      return await AccountKeys.fromSecretJson(stored.secret);
    } on FormatException {
      return null;
    }
  }
}

/// Runs [AccountKeyService.ensureKeys] after successful syncs: every time
/// until the keys are ready, then at most every six hours. One at a time;
/// a failure is logged and retried after the next sync.
class AccountKeyChecker {
  AccountKeyChecker(this._service, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static const recheckAfter = Duration(hours: 6);

  final AccountKeyService _service;
  final DateTime Function() _clock;
  DateTime? _readyAt;
  bool _running = false;

  /// The outcome of the last check, null before the first.
  AccountKeyStatus? lastStatus;

  /// Checks again after the next sync, even within six hours: the Orchards
  /// heard that the account's keys changed.
  void recheckSoon() => _readyAt = null;

  Future<void> afterSync() async {
    if (_running) return;
    final readyAt = _readyAt;
    // Keys a sync just brought (another device replaced them) are checked
    // at once rather than hours later.
    if (readyAt != null &&
        _clock().difference(readyAt) < recheckAfter &&
        !await _service.store.needsAttention()) {
      return;
    }
    _running = true;
    try {
      final status = await _service.ensureKeys();
      lastStatus = status;
      _readyAt = status == AccountKeyStatus.ready ? _clock() : null;
    } catch (e) {
      AppLogger.warning('Account keys: $e');
    } finally {
      _running = false;
    }
  }
}
