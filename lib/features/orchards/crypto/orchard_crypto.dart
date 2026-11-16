/// The cryptography of Orchards and Crates (3.0), built on an
/// account's keys (account_keys.dart) and the sealed box and DEK wrap of
/// user_keypair.dart.
///
///   * An Orchard's key and each Crate's key are random 32-byte keys, one per
///     generation, sealed to each member's account key under a context that
///     names what they are: the Orchard, the Crate and the generation. A
///     server holding several can never hand one out as another.
///   * Every sealed copy is signed by the account that sealed it. Anyone who
///     knows an account's public key, the server included, can seal a key to
///     it, so a device takes a copy only when an account it trusts for that
///     Orchard signed it: a server cannot slip in a key of its own and read
///     what is written with it.
///   * Every generation of a key has a commitment (an HKDF of the key under
///     its own label) in the signed record entry that made it. A device
///     opens a copy only when the key in it matches, so neither the server
///     nor any member, one who left included, can pass off a key of their
///     own, whoever sealed the copy. The commitment reveals nothing of the
///     key.
///   * An Orchard's name is encrypted under its Orchard key, a Crate's name
///     under its Crate key, and a role's name (the Orchard's record)
///     under the Orchard key. So is the note of a request for access,
///     bound to the member who asks.
///   * Every record names the entry of the Orchard's record its author had
///     read (its number and hash), so a reader checks the author's access as
///     of then, and notices a server that shows it a different record.
///   * Every item is one record: AES-256-GCM under its Crate's key, bound to
///     the Orchard, the Crate, the item's id and the key generation, so a
///     record cannot be moved to another item or Crate, or presented under
///     another key, without failing to open. The author is named inside.
///   * Every record is signed with its author's Ed25519 account key over the
///     same binding and the encrypted bytes, so no one without that key, the
///     server included, can forge or alter an edit.
///   * An item's id on the server is derived from its kind and its local key
///     under a key only the Crate's members hold, so every device names one
///     item the same way and the ids tell the server nothing.
///
/// Pure Dart on the `cryptography` and `crypto` packages, no Flutter or app
/// imports, so it is testable on its own.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/teams/crypto/user_keypair.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/utils/type_name.dart';

/// Labels: bump the version suffix if a construction ever changes, so old
/// and new bytes can never be confused.
const String _orchardKeyContext = 'zestssh.orchard-key.v1';
const String _crateKeyContext = 'zestssh.crate-key.v1';
const String _orchardNamePurpose = 'zestssh.orchard-name.v1';
const String _crateNamePurpose = 'zestssh.crate-name.v1';
const String _roleNamePurpose = 'zestssh.role-name.v1';
const String _accessNotePurpose = 'zestssh.access-note.v1';
const String _activityPurpose = 'zestssh.activity.v1';
const String _sessionLogPurpose = 'zestssh.session-log.v1';
const String _unwatchedPurpose = 'zestssh.unwatched.v1';
const String _itemPurpose = 'zestssh.crate-item.v1';
const String _itemSignatureLabel = 'zestssh.crate-item.sig.v1';
const String _itemIdsLabel = 'zestssh.crate-item-ids.v1';
const String _keyCopySignatureLabel = 'zestssh.key-copy.sig.v1';
const String _keyCommitLabel = 'zestssh.key-commit.v1';

final Ed25519 _ed25519 = Ed25519();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

/// A fresh random 32-byte Orchard or Crate key from the platform CSPRNG.
Uint8List newSpaceKey() {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
}

// ── Keys ────────────────────────────────────────────────────────────────

/// An Orchard's key for one generation, sealed to a member's X25519 key.
Future<Uint8List> sealOrchardKey(
  List<int> recipientPublicKey,
  List<int> orchardKey, {
  required String orchardId,
  required int generation,
}) {
  _requireKey(orchardKey);
  return sealTo(recipientPublicKey, orchardKey,
      context: '$_orchardKeyContext|$orchardId|$generation');
}

/// Reverse [sealOrchardKey]. Throws [SecretBoxAuthenticationError] if the
/// box is not this Orchard's key of this generation sealed to [me].
Future<Uint8List> openOrchardKey(
  UserKeyPair me,
  List<int> sealed, {
  required String orchardId,
  required int generation,
}) async {
  final key = await openSealed(me, sealed,
      context: '$_orchardKeyContext|$orchardId|$generation');
  _requireKey(key);
  return key;
}

/// A Crate's key for one generation, sealed to a member's X25519 key.
Future<Uint8List> sealCrateKey(
  List<int> recipientPublicKey,
  List<int> crateKey, {
  required String orchardId,
  required String crateId,
  required int generation,
}) {
  _requireKey(crateKey);
  return sealTo(recipientPublicKey, crateKey,
      context: '$_crateKeyContext|$orchardId|$crateId|$generation');
}

/// Reverse [sealCrateKey]. Throws [SecretBoxAuthenticationError] if the box
/// is not this Crate's key of this generation sealed to [me].
Future<Uint8List> openCrateKey(
  UserKeyPair me,
  List<int> sealed, {
  required String orchardId,
  required String crateId,
  required int generation,
}) async {
  final key = await openSealed(me, sealed,
      context: '$_crateKeyContext|$orchardId|$crateId|$generation');
  _requireKey(key);
  return key;
}

/// The commitment to generation [generation] of the Orchard's key (null
/// [crateId]) or a Crate's: HKDF-SHA256 of the key over its own label and
/// what the key is. The record entry that makes the generation carries it
/// (create, crate.add, key.rotate), and a device checks every key it opens
/// against it ([keyMatchesCommitment]).
Future<Uint8List> keyCommitment(
  List<int> key, {
  required String orchardId,
  String? crateId,
  required int generation,
}) async {
  _requireKey(key);
  final generationBytes = ByteData(4)..setUint32(0, generation);
  final out = await _hkdf.deriveKey(
    secretKey: SecretKey(key),
    nonce: const <int>[],
    info: [
      ..._lp(utf8.encode(_keyCommitLabel)),
      ..._lp(utf8.encode(orchardId)),
      ..._lp(utf8.encode(crateId ?? '')),
      ...generationBytes.buffer.asUint8List(),
    ],
  );
  return Uint8List.fromList(await out.extractBytes());
}

/// Whether [key] is the key [commitment] was made from, compared in
/// constant time. False for a missing commitment.
Future<bool> keyMatchesCommitment(
  List<int> key,
  List<int>? commitment, {
  required String orchardId,
  String? crateId,
  required int generation,
}) async {
  if (commitment == null || commitment.length != 32 || key.length != 32) return false;
  final mine = await keyCommitment(key, orchardId: orchardId, crateId: crateId, generation: generation);
  var diff = 0;
  for (var i = 0; i < 32; i++) {
    diff |= mine[i] ^ commitment[i];
  }
  return diff == 0;
}

/// What a sealed key copy is, who it is for and who sealed it: the accounts
/// and the versions of their keys that sealed, received and signed it.
class KeyCopyPlace {
  const KeyCopyPlace({
    required this.orchardId,
    this.crateId,
    required this.generation,
    required this.recipient,
    required this.recipientKeyVersion,
    required this.sealer,
    required this.sealerKeyVersion,
  });

  final String orchardId;

  /// The Crate whose key this is; null for the Orchard's own key.
  final String? crateId;
  final int generation;

  /// The account the copy is sealed to, and the version of its keys.
  final String recipient;
  final int recipientKeyVersion;

  /// The account that sealed and signed the copy, and the version of its
  /// keys that signed.
  final String sealer;
  final int sealerKeyVersion;
}

/// The bytes a key copy's signature covers: whose key it is (the Orchard's
/// or a Crate's) and which generation, who it is sealed to, who sealed it,
/// and the sealed bytes. Every field is length-prefixed or fixed-width. The
/// server checks the same bytes (ZestSSH Cloud's src/lib/key_copies.js).
Uint8List keyCopySignatureMessage(KeyCopyPlace place, List<int> sealed) {
  Uint8List u32(int value) {
    final out = ByteData(4)..setUint32(0, value);
    return out.buffer.asUint8List();
  }

  return Uint8List.fromList([
    ..._lp(utf8.encode(_keyCopySignatureLabel)),
    ..._lp(utf8.encode(place.crateId == null ? 'orchard' : 'crate')),
    ..._lp(utf8.encode(place.orchardId)),
    ..._lp(utf8.encode(place.crateId ?? '')),
    ...u32(place.generation),
    ..._lp(utf8.encode(place.recipient)),
    ...u32(place.recipientKeyVersion),
    ..._lp(utf8.encode(place.sealer)),
    ...u32(place.sealerKeyVersion),
    ..._lp(sealed),
  ]);
}

/// Signs a sealed key copy with the sealer's account key.
Future<Uint8List> signKeyCopy(AccountKeys sealer, KeyCopyPlace place, List<int> sealed) {
  if (place.sealerKeyVersion != sealer.version) {
    throw ArgumentError('The copy names another version of the sealer\'s keys');
  }
  return sealer.sign(keyCopySignatureMessage(place, sealed));
}

/// Whether [signature] is the Ed25519 signature of [sealerSigningKey] over
/// the copy.
Future<bool> verifyKeyCopy(
  List<int> sealerSigningKey,
  KeyCopyPlace place,
  List<int> sealed,
  List<int> signature,
) async {
  if (sealerSigningKey.length != 32 || signature.length != 64) return false;
  return _ed25519.verify(
    keyCopySignatureMessage(place, sealed),
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(sealerSigningKey, type: KeyPairType.ed25519),
    ),
  );
}

// ── Names ───────────────────────────────────────────────────────────────

/// An Orchard's name, encrypted under its key of [generation].
Future<Uint8List> encryptOrchardName(
  String name,
  List<int> orchardKey, {
  required String orchardId,
  required int generation,
}) =>
    wrapUnderDek(_nameBytes(name), orchardKey,
        purpose: '$_orchardNamePurpose|$orchardId|$generation');

/// Reverse [encryptOrchardName]. Throws [SecretBoxAuthenticationError] or
/// [FormatException].
Future<String> decryptOrchardName(
  List<int> encrypted,
  List<int> orchardKey, {
  required String orchardId,
  required int generation,
}) async =>
    _nameFrom(await unwrapUnderDek(encrypted, orchardKey,
        purpose: '$_orchardNamePurpose|$orchardId|$generation'));

/// A Crate's name, encrypted under its key of [generation].
Future<Uint8List> encryptCrateName(
  String name,
  List<int> crateKey, {
  required String orchardId,
  required String crateId,
  required int generation,
}) =>
    wrapUnderDek(_nameBytes(name), crateKey,
        purpose: '$_crateNamePurpose|$orchardId|$crateId|$generation');

/// Reverse [encryptCrateName]. Throws [SecretBoxAuthenticationError] or
/// [FormatException].
Future<String> decryptCrateName(
  List<int> encrypted,
  List<int> crateKey, {
  required String orchardId,
  required String crateId,
  required int generation,
}) async =>
    _nameFrom(await unwrapUnderDek(encrypted, crateKey,
        purpose: '$_crateNamePurpose|$orchardId|$crateId|$generation'));

/// A role's name, encrypted under the Orchard's key of [generation].
/// The record carries it as base64.
Future<Uint8List> encryptRoleName(
  String name,
  List<int> orchardKey, {
  required String orchardId,
  required String roleId,
  required int generation,
}) =>
    wrapUnderDek(_nameBytes(name), orchardKey,
        purpose: '$_roleNamePurpose|$orchardId|$roleId|$generation');

/// Reverse [encryptRoleName]. Throws [SecretBoxAuthenticationError] or
/// [FormatException].
Future<String> decryptRoleName(
  List<int> encrypted,
  List<int> orchardKey, {
  required String orchardId,
  required String roleId,
  required int generation,
}) async =>
    _nameFrom(await unwrapUnderDek(encrypted, orchardKey,
        purpose: '$_roleNamePurpose|$orchardId|$roleId|$generation'));

/// The longest note of a request for access, in characters. Encrypted,
/// it stays under the server's 1 KB limit in any script.
const int kMaxAccessNoteLength = 200;

/// What a member says they need, with a request for access: encrypted
/// under the Orchard's key of [generation], which every member holds and the
/// server does not, and bound to the Orchard and to [uid], who asks, so the
/// server can neither read a note nor pass it off as someone else's.
Future<Uint8List> encryptAccessNote(
  String note,
  List<int> orchardKey, {
  required String orchardId,
  required String uid,
  required int generation,
}) {
  final trimmed = note.trim();
  final bytes = utf8.encode(jsonEncode({'v': 1, 'note': trimmed}));
  // (The bytes too: characters a note has no use for take six each.)
  if (trimmed.isEmpty || trimmed.runes.length > kMaxAccessNoteLength || bytes.length > 900) {
    throw ArgumentError('A note is 1 to $kMaxAccessNoteLength characters');
  }
  return wrapUnderDek(bytes, orchardKey, purpose: '$_accessNotePurpose|$orchardId|$uid|$generation');
}

/// Reverse [encryptAccessNote]. Throws [SecretBoxAuthenticationError] or
/// [FormatException].
Future<String> decryptAccessNote(
  List<int> encrypted,
  List<int> orchardKey, {
  required String orchardId,
  required String uid,
  required int generation,
}) async {
  final decoded = jsonDecode(utf8.decode(
      await unwrapUnderDek(encrypted, orchardKey, purpose: '$_accessNotePurpose|$orchardId|$uid|$generation')));
  if (decoded is! Map || decoded['v'] != 1 || decoded['note'] is! String) {
    throw const FormatException('Not a note');
  }
  return decoded['note'] as String;
}

/// One thing a member did with a Crate's item, sealed with the
/// Orchard's key of [generation] for its owners to read: the server cannot.
/// [event] is its JSON, which names the member.
Future<Uint8List> sealActivity(
  Map<String, Object?> event,
  List<int> orchardKey, {
  required String orchardId,
  required int generation,
}) =>
    wrapUnderDek(utf8.encode(jsonEncode(event)), orchardKey,
        purpose: '$_activityPurpose|$orchardId|$generation');

/// Reverse [sealActivity]. Throws [SecretBoxAuthenticationError] or
/// [FormatException].
Future<Map<String, Object?>> openActivity(
  List<int> sealed,
  List<int> orchardKey, {
  required String orchardId,
  required int generation,
}) async {
  final decoded = jsonDecode(utf8.decode(
      await unwrapUnderDek(sealed, orchardKey, purpose: '$_activityPurpose|$orchardId|$generation')));
  if (decoded is! Map<String, Object?>) throw const FormatException('Not an activity event');
  return decoded;
}

/// What a device reports of a session to a watched Crate's host that went
/// on with nobody watching (3.0, the outage work): [report] is its JSON,
/// sealed with the Crate's key of [generation] for those who hold it, and
/// bound to the Orchard, the Crate, whoever reports ([uid]) and the time the
/// report names ([at]), so that nobody, the server included, can read it or
/// pass it off as someone else's or as one about another time.
Future<Uint8List> sealUnwatchedReport(
  Map<String, Object?> report,
  List<int> crateKey, {
  required String orchardId,
  required String crateId,
  required String uid,
  required int at,
  required int generation,
}) =>
    wrapUnderDek(utf8.encode(jsonEncode(report)), crateKey,
        purpose: _unwatchedBinding(orchardId, crateId, uid, at, generation));

/// What a report of a session with nobody watching is sealed to, beside the
/// Crate's key: one written for another Orchard, Crate, person, time or key
/// does not open as this one.
String _unwatchedBinding(String orchardId, String crateId, String uid, int at, int generation) =>
    '$_unwatchedPurpose|$orchardId|$crateId|$uid|$at|$generation';

/// Reverse [sealUnwatchedReport]. Throws [SecretBoxAuthenticationError] or
/// [FormatException].
Future<Map<String, Object?>> openUnwatchedReport(
  List<int> sealed,
  List<int> crateKey, {
  required String orchardId,
  required String crateId,
  required String uid,
  required int at,
  required int generation,
}) async {
  final decoded = jsonDecode(utf8.decode(
      await unwrapUnderDek(sealed, crateKey, purpose: _unwatchedBinding(orchardId, crateId, uid, at, generation))));
  if (decoded is! Map<String, Object?>) throw const FormatException('Not a report');
  return decoded;
}

/// One part of a team session log: its header ([part] 0) or the
/// [part]th chunk of its output, sealed with the Crate's key of
/// [generation] and bound to the Orchard, the Crate, the log and the part,
/// so the server can neither read one nor pass it off as another.
Future<Uint8List> sealSessionLogPart(
  List<int> bytes,
  List<int> crateKey, {
  required String orchardId,
  required String crateId,
  required String logId,
  required int part,
  required int generation,
}) =>
    wrapUnderDek(bytes, crateKey, purpose: '$_sessionLogPurpose|$orchardId|$crateId|$logId|$part|$generation');

/// Reverse [sealSessionLogPart]. Throws [SecretBoxAuthenticationError] or
/// [FormatException].
Future<Uint8List> openSessionLogPart(
  List<int> sealed,
  List<int> crateKey, {
  required String orchardId,
  required String crateId,
  required String logId,
  required int part,
  required int generation,
}) async =>
    Uint8List.fromList(await unwrapUnderDek(sealed, crateKey,
        purpose: '$_sessionLogPurpose|$orchardId|$crateId|$logId|$part|$generation'));

/// The longest name, in UTF-8 bytes. Encrypted, it stays well under the
/// server's 1 KB limit.
const int kMaxSpaceNameBytes = 200;

List<int> _nameBytes(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty || utf8.encode(trimmed).length > kMaxSpaceNameBytes) {
    throw ArgumentError('A name is 1 to $kMaxSpaceNameBytes bytes');
  }
  return utf8.encode(jsonEncode({'v': 1, 'name': trimmed}));
}

String _nameFrom(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map || decoded['v'] != 1 || decoded['name'] is! String) {
    throw const FormatException('Not an encrypted name');
  }
  return decoded['name'] as String;
}

// ── Item ids ────────────────────────────────────────────────────────────

/// The key a Crate's item ids are derived under. It comes from the Crate's
/// FIRST key, so it never changes when the key is replaced, and only
/// the Crate's members can compute it.
Future<Uint8List> crateItemIdKey(
  List<int> firstCrateKey, {
  required String orchardId,
  required String crateId,
}) async {
  _requireKey(firstCrateKey);
  final key = await _hkdf.deriveKey(
    secretKey: SecretKey(firstCrateKey),
    nonce: const <int>[],
    info: [
      ..._lp(utf8.encode(_itemIdsLabel)),
      ..._lp(utf8.encode(orchardId)),
      ..._lp(utf8.encode(crateId)),
    ],
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// An item's id in a Crate: a UUID-shaped (version 8) HMAC-SHA256 of its
/// kind and its local key, so two devices that write the same item write to
/// the same id, and the server sees neither.
String crateItemId(List<int> idKey, {required String kind, required String key}) {
  _requireKey(idKey);
  final mac = hash.Hmac(hash.sha256, idKey)
      .convert([..._lp(utf8.encode(kind)), ..._lp(utf8.encode(key))]).bytes;
  final b = Uint8List.fromList(mac.sublist(0, 16));
  b[6] = (b[6] & 0x0f) | 0x80;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

// ── Records ─────────────────────────────────────────────────────────────

/// The newest record format this version reads and writes. A newer version
/// may write a newer format; this one still reads it when the record says
/// readers of this format can (`min_reader`, which defaults to the format
/// itself), and keeps the fields it does not know.
///
/// Format 2 (3.4) is a version that holds an FTPS host, or a TLS certificate a
/// team pinned for one ([itemRecordFormatOf]). Versions before 3.4 read format
/// 1 alone, and refuse the rest as they refuse a record that does not open
/// (counted, logged, and passed over): they never see such a host, so they
/// never take it for an SSH host (they read a protocol they do not know as
/// SSH), nor a certificate for a host key. Every other version is still
/// written in format 1, byte for byte as before, so every version reads it and
/// breaks a tie between two versions the same way ([ItemRecord.contentDigest]).
///
/// Format 3 (4.0) is a version that holds a remote screen (a VNC host,
/// [ConnectionProtocol.storedIsScreen]). 3.4 reads up to format 2 and refuses
/// it as it refuses a record that does not open; once it updates, it reads its
/// vaults again (CrateSyncEngine), and the screens come in. A screen's pinned
/// VeNCrypt certificate is a `hostkey` item of format 2, as FTPS's is.
///
/// Format 4 (4.0) is a version that holds an RDP host. A version that
/// has VNC and not RDP reads up to format 3 and refuses it the same way, so it
/// never holds an RDP host as something else; once it updates, it reads its
/// vaults again and the RDP hosts come in. An RDP host's pinned certificate
/// is a `hostkey` item of format 2, as a VNC screen's is.
const int kItemRecordFormat = 4;

/// The format a version of an item of [kind] with the rows [data] is written
/// in ([kItemRecordFormat]): 4 for an RDP host (`rdp`,
/// [ConnectionProtocol.kindClassRdp]); 3 for a host that is a VNC screen (`vnc`,
/// [ConnectionProtocol.kindClassScreen]); 2 for a host whose protocol is FTPS (`ftps` or
/// `ftpsImplicit`: [ConnectionProtocol.storedIsFtps]) and for a team's pin
/// that holds a TLS certificate (kind `hostkey`, kHostKeyKind, with a key of
/// the type `x509-sha256`, KnownHostsService.certificateKeyType); 1 for
/// anything else, a deletion among it (it holds no rows, and a version before
/// 3.4 that never had the item has nothing of it to delete).
int itemRecordFormatOf(String kind, Map<String, Object?>? data) {
  if (data == null) return 1;
  List<Object?> rows(String table) => data[table] is List ? data[table] as List : const [];
  if (kind == 'host') {
    for (final row in rows('connections')) {
      if (row is! Map) continue;
      final protocol = row['protocol']?.toString();
      final kindClass = ConnectionProtocol.kindClassOf(protocol);
      if (kindClass == ConnectionProtocol.kindClassRdp) return 4;
      if (kindClass == ConnectionProtocol.kindClassScreen) return 3;
      if (kindClass == ConnectionProtocol.kindClassFtps) return 2;
    }
  } else if (kind == 'hostkey') {
    for (final row in rows('team_host_keys')) {
      final keys = row is Map ? row['host_keys'] : null;
      if (keys is String && keys.contains('x509-sha256 ')) return 2;
    }
  }
  return 1;
}

/// The latest `edited_at` an item record may say: the last millisecond of the
/// year 9999, well inside what a [DateTime] holds.
const int kItemEditedAtMaxMs = 253402300799999;

/// The time of a change to an item whose version here says [held]: [now], or
/// just after [held] where that is not earlier, so the change is later than the
/// version it replaces (every device refuses an older one), and never past
/// [kItemEditedAtMaxMs]. One past it was a record every other device refused:
/// a member's version stamped at the bound froze the item for everyone, since
/// no later edit, deletion or restore reached anyone (found in a security
/// review). At the bound a change has the time of the version it
/// replaces, and the server's order of the two tells which is newer
/// (CrateSyncEngine).
int itemEditedAfter(int held, int now) {
  final next = now > held ? now : held + 1;
  return next > kItemEditedAtMaxMs ? kItemEditedAtMaxMs : next;
}

/// How deep lists and objects may nest in an item record. A version nests
/// five deep (the record, its rows by table, a table's rows, a row, a blob);
/// the rest is room for what a newer version adds.
const int kItemRecordMaxDepth = 32;

/// Whether [value] nests lists and objects deeper than [max], counting
/// [value] itself as one. Walked without recursion: a member's record nested
/// 20,000 deep (40 KB) threw a stack overflow at every reader that wrote it out
/// again, and stopped every member's team sync, in every vault (found in a security
/// review).
bool nestsDeeperThan(Object? value, int max) {
  final waiting = <(Object?, int)>[(value, 1)];
  while (waiting.isNotEmpty) {
    final (v, depth) = waiting.removeLast();
    final Iterable<Object?> inside;
    if (v is Map) {
      inside = v.values;
    } else if (v is List) {
      inside = v;
    } else {
      continue;
    }
    if (depth > max) return true;
    for (final x in inside) {
      if (x is Map || x is List) waiting.add((x, depth + 1));
    }
  }
  return false;
}

/// One version of an item, as its record carries it.
class ItemRecord {
  const ItemRecord({
    required this.kind,
    required this.key,
    required this.author,
    required this.authorKeyVersion,
    required this.editedAt,
    this.deleted = false,
    this.movedTo,
    this.data,
    this.recordSeq,
    this.recordHead,
    this.extra = const {},
  })  : assert(deleted || data != null, 'a live item carries its rows'),
        assert((recordSeq == null) == (recordHead == null), 'an anchor has both parts');

  /// 'host', 'key', 'group', 'snippet', 'category', 'forward', 'network' or
  /// 'trigger'.
  final String kind;

  /// The item's local key: its row id, or a snippet category's name.
  final String key;

  /// The account that wrote this version, and the version of the keys that
  /// signed it.
  final String author;
  final int authorKeyVersion;

  /// When the version was made, in epoch milliseconds by its author's clock.
  final int editedAt;

  final bool deleted;

  /// On a deletion that was a move: the Crate the item moved to. The item
  /// lives on there, so no device deletes its rows for it.
  final String? movedTo;

  /// The item's rows, table by table. Null when deleted.
  final Map<String, Object?>? data;

  /// The entry of the Orchard's record its author had read when writing it
  /// (its number and hash). Null only on versions written before the
  /// record.
  final int? recordSeq;
  final Uint8List? recordHead;

  /// Fields a newer version wrote that this one does not know. Written back
  /// untouched, so an older app never erases what a newer one added.
  final Map<String, Object?> extra;

  static const _knownFields = {
    'v',
    'min_reader',
    'kind',
    'key',
    'author',
    'author_key',
    'edited_at',
    'deleted',
    'moved_to',
    'data',
    'rec_seq',
    'rec_head',
  };

  /// The format this version is written in ([itemRecordFormatOf]).
  int get format => itemRecordFormatOf(kind, data);

  Map<String, Object?> toJson() => {
        ...extra,
        // The format that holds it ([itemRecordFormatOf]): a version before
        // 3.4 reads it where that is 1, and refuses it where it is 2.
        'v': format,
        'kind': kind,
        'key': key,
        'author': author,
        'author_key': authorKeyVersion,
        'edited_at': editedAt,
        'deleted': deleted,
        if (movedTo != null) 'moved_to': movedTo,
        if (data != null) 'data': data,
        if (recordSeq != null) 'rec_seq': recordSeq,
        if (recordHead != null) 'rec_head': base64Encode(recordHead!),
      };

  /// Throws [FormatException] on anything malformed, or on a newer format
  /// that says this version cannot read it. A record nested deeper than
  /// [kItemRecordMaxDepth] is malformed: what reads it writes it out again
  /// (its extras kept, the digest that breaks a tie), and that recurses.
  /// [readsFormat]: the newest format read, [kItemRecordFormat] but in a test
  /// that reads as a version before 3.4 did.
  static ItemRecord fromJson(Object? json, {int readsFormat = kItemRecordFormat}) {
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Not an item record');
    }
    if (nestsDeeperThan(json, kItemRecordMaxDepth)) {
      throw const FormatException('Not an item record');
    }
    final format = json['v'];
    final minReader = json['min_reader'] ?? format;
    if (format is! int || format < 1 || minReader is! int || minReader > readsFormat) {
      throw const FormatException('Not an item record this version can read');
    }
    final kind = json['kind'];
    final key = json['key'];
    final author = json['author'];
    final authorKey = json['author_key'];
    final editedAt = json['edited_at'];
    final deleted = json['deleted'];
    final movedTo = json['moved_to'];
    final data = json['data'];
    final recSeq = json['rec_seq'];
    final recHead = json['rec_head'];
    Uint8List? head;
    if (recHead is String) {
      try {
        head = base64Decode(recHead);
      } on FormatException {
        head = null;
      }
    }
    final anchored = recSeq != null || recHead != null;
    if (anchored && (recSeq is! int || recSeq < 1 || head == null || head.length != 32)) {
      throw const FormatException('Not an item record');
    }
    if (kind is! String ||
        kind.isEmpty ||
        key is! String ||
        key.isEmpty ||
        author is! String ||
        author.isEmpty ||
        authorKey is! int ||
        editedAt is! int ||
        // A time a date can hold (1970 to the year 9999, in milliseconds): one far
        // past it threw at every screen that shows when an item was changed, the
        // held-back row, the trash and the history among them (found in a
        // security review).
        editedAt < 0 ||
        editedAt > kItemEditedAtMaxMs ||
        deleted is! bool ||
        (movedTo != null && movedTo is! String) ||
        (movedTo != null && !deleted) ||
        (data != null && data is! Map<String, dynamic>) ||
        (data != null && deleted) ||
        (data == null && !deleted)) {
      throw const FormatException('Not an item record');
    }
    return ItemRecord(
      kind: kind,
      key: key,
      author: author,
      authorKeyVersion: authorKey,
      editedAt: editedAt,
      deleted: deleted,
      movedTo: movedTo as String?,
      data: data as Map<String, dynamic>?,
      recordSeq: anchored ? recSeq as int : null,
      recordHead: anchored ? head : null,
      extra: {
        for (final e in json.entries)
          if (!_knownFields.contains(e.key)) e.key: e.value,
      },
    );
  }

  /// SHA-256 of the version's content in a canonical form (sorted keys):
  /// the last tie-breaker between two versions made in the same millisecond,
  /// the same on every device.
  Uint8List get contentDigest => Uint8List.fromList(
      hash.sha256.convert(utf8.encode(_canonicalJson(toJson()))).bytes);
}

/// Whether version [a] beats version [b] of one item: the newer edit, then
/// the account id, then the content, so every device picks the same one.
bool versionWins(ItemRecord a, ItemRecord b) {
  if (a.editedAt != b.editedAt) return a.editedAt > b.editedAt;
  final byAuthor = a.author.compareTo(b.author);
  if (byAuthor != 0) return byAuthor > 0;
  final da = a.contentDigest;
  final db = b.contentDigest;
  for (var i = 0; i < da.length; i++) {
    if (da[i] != db[i]) return da[i] > db[i];
  }
  return false;
}

/// Where a record belongs: the binding its encryption and its signature
/// both carry.
class ItemPlace {
  const ItemPlace({
    required this.orchardId,
    required this.crateId,
    required this.itemId,
    required this.generation,
  });

  final String orchardId;
  final String crateId;
  final String itemId;
  final int generation;

  String get _purpose => '$_itemPurpose|$orchardId|$crateId|$itemId|$generation';
}

/// A record as the server stores it.
class SealedItem {
  const SealedItem({
    required this.itemId,
    required this.keyGeneration,
    required this.deleted,
    required this.record,
    required this.signature,
  });

  final String itemId;
  final int keyGeneration;
  final bool deleted;
  final Uint8List record;
  final Uint8List signature;
}

/// Encrypts [record] for [place] under the Crate key of that generation and
/// signs it with [signer], the author's account keys.
Future<SealedItem> sealItem(
  ItemRecord record, {
  required ItemPlace place,
  required List<int> crateKey,
  required AccountKeys signer,
}) async {
  final encrypted = await wrapUnderDek(
    utf8.encode(jsonEncode(record.toJson())),
    crateKey,
    purpose: place._purpose,
  );
  final signature = await signer.sign(
      itemSignatureMessage(place, deleted: record.deleted, record: encrypted));
  return SealedItem(
    itemId: place.itemId,
    keyGeneration: place.generation,
    deleted: record.deleted,
    record: encrypted,
    signature: signature,
  );
}

/// A record the app refuses: it does not open, names another item, or its
/// signature does not verify against its author's key.
class ItemRejected implements Exception, HasTypeName {
  const ItemRejected(this.reason);

  final String reason;

  @override
  String toString() => 'ItemRejected: $reason';

  @override
  String get typeName => 'ItemRejected';
}

/// An author's Ed25519 public key for a version of their account keys, or
/// null when this device does not know it.
typedef SigningKeyLookup = Future<List<int>?> Function(String uid, int keyVersion);

/// Opens a record from the server and checks it: it must open under the
/// Crate key for its place, name the item its id was derived from, agree
/// with the server on whether it is deleted, and carry a valid signature by
/// the author it names. Throws [ItemRejected]. [readsFormat]: as
/// [ItemRecord.fromJson].
Future<ItemRecord> openItem(
  SealedItem item, {
  required String orchardId,
  required String crateId,
  required List<int> crateKey,
  required List<int> idKey,
  required SigningKeyLookup signers,
  int readsFormat = kItemRecordFormat,
}) async {
  final place = ItemPlace(
    orchardId: orchardId,
    crateId: crateId,
    itemId: item.itemId,
    generation: item.keyGeneration,
  );
  final Uint8List clear;
  try {
    clear = await unwrapUnderDek(item.record, crateKey, purpose: place._purpose);
  } on SecretBoxAuthenticationError {
    throw const ItemRejected('does not open with the Crate key');
  } on ArgumentError {
    throw const ItemRejected('malformed record');
  }
  final ItemRecord record;
  try {
    record = ItemRecord.fromJson(jsonDecode(utf8.decode(clear)), readsFormat: readsFormat);
  } on FormatException {
    throw const ItemRejected('malformed record');
  }
  if (crateItemId(idKey, kind: record.kind, key: record.key) != item.itemId) {
    throw const ItemRejected('names another item');
  }
  if (record.deleted != item.deleted) {
    throw const ItemRejected('the server disagrees on whether it is deleted');
  }
  final signingKey = await signers(record.author, record.authorKeyVersion);
  if (signingKey == null || signingKey.length != 32) {
    throw const ItemRejected('unknown author');
  }
  final ok = item.signature.length == 64 &&
      await _ed25519.verify(
        itemSignatureMessage(place, deleted: item.deleted, record: item.record),
        signature: Signature(
          item.signature,
          publicKey: SimplePublicKey(signingKey, type: KeyPairType.ed25519),
        ),
      );
  if (!ok) throw const ItemRejected('signature does not verify');
  return record;
}

/// The exact bytes an item's signature covers: its place, whether it is
/// deleted, and the encrypted record. Every field is length-prefixed or
/// fixed-width, so no two different writes encode the same way.
Uint8List itemSignatureMessage(
  ItemPlace place, {
  required bool deleted,
  required List<int> record,
}) {
  final fixed = ByteData(5)
    ..setUint32(0, place.generation)
    ..setUint8(4, deleted ? 1 : 0);
  return Uint8List.fromList([
    ..._lp(utf8.encode(_itemSignatureLabel)),
    ..._lp(utf8.encode(place.orchardId)),
    ..._lp(utf8.encode(place.crateId)),
    ..._lp(utf8.encode(place.itemId)),
    ...fixed.buffer.asUint8List(),
    ..._lp(record),
  ]);
}

// ── Helpers ─────────────────────────────────────────────────────────────

/// JSON with its object keys sorted and no spaces, so the same value always
/// gives the same bytes: what item records and the Orchard's record sign.
String canonicalJson(Object? value) => _canonicalJson(value);

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    return '{${[
      for (final k in keys) '${jsonEncode(k)}:${_canonicalJson(value[k])}',
    ].join(',')}}';
  }
  if (value is List) return '[${value.map(_canonicalJson).join(',')}]';
  return jsonEncode(value);
}

void _requireKey(List<int> key) {
  if (key.length != 32) throw ArgumentError('a space key is 32 bytes');
}

/// Length-prefixed (uint32 big-endian) so adjacent fields never run into
/// each other.
List<int> _lp(List<int> bytes) {
  final out = Uint8List(4 + bytes.length);
  ByteData.sublistView(out, 0, 4).setUint32(0, bytes.length);
  out.setRange(4, out.length, bytes);
  return out;
}
