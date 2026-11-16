/// Invite codes: a code that invites whoever
/// holds it into a team (one person, or as a team code several), made on the
/// maker's device. ZestSSH Cloud never sees the code, and a code for one
/// person checks both sides' keys, so nobody compares fingerprints; the maker
/// still lets the person in.
///
///   * The code: ZEST- and five groups of four characters from the
///     unambiguous alphabet of the server's codes (no 0, O, 1 or I), 5 bits
///     each, 100 bits in all, from the platform CSPRNG. Its normal form is
///     upper case with no spaces or dashes, ZEST in front
///     ([normalJoinCode]); a link carries it after `#` (a fragment, which a
///     browser never sends to the website).
///   * From the normal form (its UTF-8 bytes) HKDF-SHA256, with no salt,
///     derives three keys under their own labels ([joinCodeKeys]): a 16-byte
///     lookup id (`zestssh.join-code.lookup.v1`), the only thing the server
///     is given to find the invitation by; a 32-byte MAC key
///     (`zestssh.join-code.mac.v1`); and a 32-byte key for what the person
///     is shown before joining (`zestssh.join-code.offer.v1`).
///   * The maker's tag: HMAC-SHA256 under the MAC key over [ownerTranscript]
///     (its label, the team, the invitation, the lookup id, the maker's
///     published keys with their version, and the offer: role, extra Crates
///     and end date). The person's device checks it before showing anything
///     as the team's, so a server cannot pass off another team, another
///     maker's keys or another offer.
///   * The person's tag: HMAC-SHA256 under the same key over
///     [joinerTranscript] (another label, the same ids, the maker's keys and
///     the person's own published keys). The maker's device checks it, so a
///     server cannot pass off other keys as theirs: for a code made for one
///     person, that check takes the place of comparing fingerprints. A team
///     code goes to several people, any of whom could tag keys with it, so
///     its uses are compared as an invitation to an address is.
///   * Every field is length-prefixed (uint32 big-endian), a key version is
///     4 bytes big-endian, the extra Crates are canonical JSON (keys sorted,
///     each Crate's switches sorted), the end date its decimal seconds or
///     empty. Tags are compared in constant time.
///   * What the person is shown (the team's name, the role's name, the
///     vaults and their levels; [JoinOffer]) is AES-256-GCM under the offer
///     key, bound to the team and the invitation. The code itself is kept
///     for the maker's other devices only sealed to the maker's own account
///     key, with how many people it is for and the digest of its offer,
///     signed by the maker ([sealMadeJoinCode]).
///
/// Pure Dart on the `cryptography` package, no Flutter or app imports.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/teams/crypto/user_keypair.dart';

/// The alphabet of codes (the server's, lib/redemption.js): no 0, O, 1 or I.
const String kJoinCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const String _prefix = 'ZEST';
const int _groups = 5;
const int _group = 4;
const int kJoinCodeChars = _groups * _group;

/// Where a code's link points (the website's join page reads the fragment;
/// the app opens zestssh://join#CODE and zestssh://join?code=CODE).
String get kJoinLinkBase => kZestJoinLinkBase;

const String _lookupLabel = 'zestssh.join-code.lookup.v1';
const String _macLabel = 'zestssh.join-code.mac.v1';
const String _offerLabel = 'zestssh.join-code.offer.v1';
const String _ownerLabel = 'zestssh.join-code.owner.v1';
const String _joinerLabel = 'zestssh.join-code.joiner.v1';
const String _madeSealLabel = 'zestssh.join-code.made.v2';
const String _madeSigLabel = 'zestssh.join-code.made-by.v1';

final _body = RegExp('^[$kJoinCodeAlphabet]{$kJoinCodeChars}\$');

/// A new code in its normal form (ZEST and 20 characters), from the
/// platform CSPRNG. 256 is a multiple of 32, so each byte modulo 32 is
/// unbiased.
String newJoinCode({Random? random}) {
  final rng = random ?? Random.secure();
  final out = StringBuffer(_prefix);
  for (var i = 0; i < kJoinCodeChars; i++) {
    out.write(kJoinCodeAlphabet[rng.nextInt(256) % kJoinCodeAlphabet.length]);
  }
  return out.toString();
}

/// [raw] in a code's normal form (ZEST and 20 characters), or null when it
/// is not one: any case, spaces and dashes anywhere, ZEST in front or not.
String? normalJoinCode(String raw) {
  if (raw.length > 80) return null;
  var s = raw.toUpperCase().replaceAll(RegExp(r'[\s\-]'), '');
  if (s.length == _prefix.length + kJoinCodeChars && s.startsWith(_prefix)) s = s.substring(_prefix.length);
  return _body.hasMatch(s) ? '$_prefix$s' : null;
}

/// A normal-form code as it is shown and typed: ZEST-XXXX-XXXX-XXXX-XXXX-XXXX.
String writtenJoinCode(String normal) {
  final body = normal.startsWith(_prefix) ? normal.substring(_prefix.length) : normal;
  final parts = [for (var i = 0; i < body.length; i += _group) body.substring(i, min(i + _group, body.length))];
  return '$_prefix-${parts.join('-')}';
}

/// The first two groups and an ellipsis (ZEST-4F7Q-…), where a code is named
/// after it was used.
String shortJoinCode(String normal) {
  final written = writtenJoinCode(normal);
  return '${written.substring(0, min(written.length, 9))}…';
}

/// The link a code is shared as: the code after `#`, so the website never
/// receives it.
String joinCodeLink(String normal) => '$kJoinLinkBase#${writtenJoinCode(normal)}';

/// The code in what was typed, pasted or scanned: the code itself, its
/// link (the build's own [kJoinLinkBase]: https://zestssh.com/join#CODE in
/// the release, none in a build that names no join links), or the app's own
/// (zestssh://join#CODE, zestssh://join?code=CODE). Null for anything else.
String? joinCodeFromText(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text.length > 300) return null;
  final direct = normalJoinCode(text);
  if (direct != null) return direct;
  final uri = Uri.tryParse(text);
  if (uri == null) return null;
  final base = Uri.tryParse(kJoinLinkBase);
  final web = base != null &&
      base.host.isNotEmpty &&
      uri.scheme == 'https' &&
      base.scheme == 'https' &&
      uri.host == base.host &&
      uri.path == base.path;
  final app = uri.scheme == 'zestssh' && (uri.host + uri.path) == 'join';
  if (!web && !app) return null;
  if (uri.fragment.isNotEmpty) {
    final fromFragment = normalJoinCode(Uri.decodeComponent(uri.fragment));
    if (fromFragment != null) return fromFragment;
  }
  final q = uri.queryParameters['code'];
  return q == null ? null : normalJoinCode(q);
}

/// The keys a code gives: what the server finds it by, and the two it never
/// sees.
class JoinCodeKeys {
  const JoinCodeKeys({required this.lookupId, required this.macKey, required this.offerKey});

  /// 16 bytes; the server is given these, as 32 lower-case hex digits.
  final Uint8List lookupId;
  final Uint8List macKey;
  final Uint8List offerKey;

  String get lookupHex => _hex(lookupId);
}

/// [JoinCodeKeys] of a normal-form code.
Future<JoinCodeKeys> joinCodeKeys(String normal) async {
  if (normalJoinCode(normal) != normal) throw ArgumentError('not a code in its normal form');
  final ikm = utf8.encode(normal);
  return JoinCodeKeys(
    lookupId: await _derive(ikm, _lookupLabel, 16),
    macKey: await _derive(ikm, _macLabel, 32),
    offerKey: await _derive(ikm, _offerLabel, 32),
  );
}

Future<Uint8List> _derive(List<int> ikm, String label, int length) async {
  final out = await Hkdf(hmac: Hmac.sha256(), outputLength: length)
      .deriveKey(secretKey: SecretKey(ikm), nonce: const <int>[], info: utf8.encode(label));
  return Uint8List.fromList(await out.extractBytes());
}

/// An account's published keys as a tag names them.
class JoinCodeParty {
  const JoinCodeParty({
    required this.uid,
    required this.keyVersion,
    required this.signingKey,
    required this.encryptionKey,
  });

  final String uid;
  final int keyVersion;

  /// Ed25519, 32 bytes.
  final List<int> signingKey;

  /// X25519, 32 bytes.
  final List<int> encryptionKey;

  List<int> _bytes() => [
        ..._lp(utf8.encode(uid)),
        ..._u32(keyVersion),
        ..._lp(signingKey),
        ..._lp(encryptionKey),
      ];
}

/// What the maker's tag is over.
Uint8List ownerTranscript({
  required String orchardId,
  required String inviteId,
  required List<int> lookupId,
  required JoinCodeParty maker,
  required String role,
  required Map<String, Set<String>> grants,
  required int? endsAt,
}) =>
    Uint8List.fromList([
      ..._lp(utf8.encode(_ownerLabel)),
      ..._lp(utf8.encode(orchardId)),
      ..._lp(utf8.encode(inviteId)),
      ..._lp(lookupId),
      ...maker._bytes(),
      ..._lp(utf8.encode(role)),
      ..._lp(utf8.encode(canonicalGrants(grants))),
      ..._lp(utf8.encode(endsAt == null ? '' : '$endsAt')),
    ]);

/// What the person's tag is over.
Uint8List joinerTranscript({
  required String orchardId,
  required String inviteId,
  required List<int> lookupId,
  required JoinCodeParty maker,
  required JoinCodeParty joiner,
}) =>
    Uint8List.fromList([
      ..._lp(utf8.encode(_joinerLabel)),
      ..._lp(utf8.encode(orchardId)),
      ..._lp(utf8.encode(inviteId)),
      ..._lp(lookupId),
      ...maker._bytes(),
      ...joiner._bytes(),
    ]);

/// Extra Crates as the tags name them: `{"crate":["switch",...],...}`, Crates
/// and switches sorted, no spaces.
String canonicalGrants(Map<String, Set<String>> grants) {
  final ids = grants.keys.toList()..sort();
  return '{${[
    for (final id in ids) '${jsonEncode(id)}:${jsonEncode((grants[id]!.toList()..sort()))}',
  ].join(',')}}';
}

/// HMAC-SHA256 of [transcript] under [macKey].
Future<Uint8List> joinCodeTag(List<int> macKey, List<int> transcript) async {
  final mac = await Hmac.sha256().calculateMac(transcript, secretKey: SecretKey(macKey));
  return Uint8List.fromList(mac.bytes);
}

/// Whether [tag] is [joinCodeTag] of [transcript], compared in constant time.
Future<bool> joinCodeTagMatches(List<int> macKey, List<int> transcript, List<int>? tag) async {
  if (tag == null || tag.length != 32) return false;
  final expected = await joinCodeTag(macKey, transcript);
  var diff = 0;
  for (var i = 0; i < 32; i++) {
    diff |= expected[i] ^ tag[i];
  }
  return diff == 0;
}

/// A vault as the person is shown it before joining.
class JoinOfferVault {
  const JoinOfferVault(this.name, this.level);

  final String name;

  /// 'connect', 'use', 'edit' or 'manage'.
  final String level;
}

/// What the person is shown before joining, in words the server cannot
/// read: the team's name, the role's, and the vaults with their levels.
class JoinOffer {
  const JoinOffer({required this.team, required this.role, this.vaults = const []});

  final String team;
  final String role;
  final List<JoinOfferVault> vaults;

  Map<String, Object?> toJson() => {
        'v': 1,
        'team': team,
        'role': role,
        'vaults': [for (final v in vaults) {'name': v.name, 'level': v.level}],
      };

  static JoinOffer fromJson(Object? raw) {
    if (raw is! Map || raw['v'] != 1 || raw['team'] is! String || raw['role'] is! String) {
      throw const FormatException('Not an invite code offer');
    }
    final vaults = raw['vaults'];
    return JoinOffer(
      team: raw['team'] as String,
      role: raw['role'] as String,
      vaults: [
        if (vaults is List)
          for (final v in vaults)
            if (v is Map && v['name'] is String && v['level'] is String)
              JoinOfferVault(v['name'] as String, v['level'] as String),
      ],
    );
  }
}

/// [offer] under [offerKey], bound to the team and the invitation.
Future<Uint8List> sealJoinOffer(JoinOffer offer, List<int> offerKey,
        {required String orchardId, required String inviteId}) =>
    wrapUnderDek(utf8.encode(jsonEncode(offer.toJson())), offerKey,
        purpose: '$_offerLabel|$orchardId|$inviteId');

/// Reverse [sealJoinOffer]. Throws [SecretBoxAuthenticationError] or
/// [FormatException].
Future<JoinOffer> openJoinOffer(List<int> sealed, List<int> offerKey,
        {required String orchardId, required String inviteId}) async =>
    JoinOffer.fromJson(jsonDecode(utf8.decode(
        await unwrapUnderDek(sealed, offerKey, purpose: '$_offerLabel|$orchardId|$inviteId'))));

/// A code as its maker made it, from the copy kept for the maker's devices
/// ([sealMadeJoinCode]), its maker's signature checked: the code, how many
/// people it was made for, and what it offers (as a digest).
class MadeJoinCode {
  const MadeJoinCode({required this.code, required this.usesMax, required this.offerDigest});

  final String code;

  /// 1 for a code for one person; more for a team code, which everyone it
  /// went to holds, so its tags cannot tell whose keys a use names.
  final int usesMax;

  /// [joinOfferDigest] of what it was made to offer.
  final Uint8List offerDigest;

  /// Whether [role], [grants] and [endsAt] are what it was made to offer.
  Future<bool> offers({required String role, required Map<String, Set<String>> grants, required int? endsAt}) async {
    final digest = await joinOfferDigest(role: role, grants: grants, endsAt: endsAt);
    var diff = digest.length ^ offerDigest.length;
    for (var i = 0; i < digest.length && i < offerDigest.length; i++) {
      diff |= digest[i] ^ offerDigest[i];
    }
    return diff == 0;
  }
}

/// SHA-256 of an offer as the maker's tag names it: role, extra Crates
/// (canonical JSON) and end date, each length-prefixed.
Future<Uint8List> joinOfferDigest(
    {required String role, required Map<String, Set<String>> grants, required int? endsAt}) async {
  final hash = await Sha256().hash([
    ..._lp(utf8.encode(role)),
    ..._lp(utf8.encode(canonicalGrants(grants))),
    ..._lp(utf8.encode(endsAt == null ? '' : '$endsAt')),
  ]);
  return Uint8List.fromList(hash.bytes);
}

/// What the maker signs of a code it made.
Uint8List _madeMessage(
        {required String orchardId,
        required String inviteId,
        required String code,
        required int usesMax,
        required List<int> offerDigest}) =>
    Uint8List.fromList([
      ..._lp(utf8.encode(_madeSigLabel)),
      ..._lp(utf8.encode(orchardId)),
      ..._lp(utf8.encode(inviteId)),
      ..._lp(utf8.encode(code)),
      ..._u32(usesMax),
      ..._lp(offerDigest),
    ]);

/// The code, for the maker's other devices to check whoever uses it: sealed
/// to the maker's own account key ([makerEncryptionKey]), with how many
/// people it is for and the digest of its offer, all signed by the maker
/// ([sign], the account's Ed25519 signature). Anyone can seal to a public key,
/// so the signature is what makes it the maker's: without it ZestSSH Cloud
/// could make up a code of its own, seal it to the maker and tag keys of its
/// own with it (found in a security review, with
/// another finding). Sealed under a label of its own: an older version's copy (the
/// code alone, unsigned) does not open as one ([openMadeJoinCode]).
Future<Uint8List> sealMadeJoinCode(
  String normal, {
  required List<int> makerEncryptionKey,
  required Future<Uint8List> Function(List<int> message) sign,
  required String orchardId,
  required String inviteId,
  required int usesMax,
  required String role,
  required Map<String, Set<String>> grants,
  required int? endsAt,
}) async {
  final offer = await joinOfferDigest(role: role, grants: grants, endsAt: endsAt);
  final signature = await sign(
      _madeMessage(orchardId: orchardId, inviteId: inviteId, code: normal, usesMax: usesMax, offerDigest: offer));
  final clear = utf8.encode(jsonEncode({
    'v': 2,
    'code': normal,
    'uses_max': usesMax,
    'offer': base64Encode(offer),
    'sig': base64Encode(signature),
  }));
  return sealTo(makerEncryptionKey, clear, context: '$_madeSealLabel|$orchardId|$inviteId');
}

/// Reverse [sealMadeJoinCode] with the maker's own keys ([me], and its
/// signing key [makerSigningKey]); null when it does not open for this
/// invitation, is not that shape, or the maker's signature does not hold.
Future<MadeJoinCode?> openMadeJoinCode(UserKeyPair me, List<int> makerSigningKey, List<int> sealed,
    {required String orchardId, required String inviteId}) async {
  try {
    final clear = await openSealed(me, sealed, context: '$_madeSealLabel|$orchardId|$inviteId');
    final raw = jsonDecode(utf8.decode(clear));
    if (raw is! Map || raw['v'] != 2) return null;
    final code = raw['code'];
    final usesMax = raw['uses_max'];
    final offer = raw['offer'];
    final sig = raw['sig'];
    if (code is! String || normalJoinCode(code) != code || usesMax is! int || usesMax < 1) return null;
    if (offer is! String || sig is! String) return null;
    final offerDigest = base64Decode(offer);
    final signature = base64Decode(sig);
    if (offerDigest.length != 32 || signature.length != 64) return null;
    final holds = await Ed25519().verify(
      _madeMessage(orchardId: orchardId, inviteId: inviteId, code: code, usesMax: usesMax, offerDigest: offerDigest),
      signature: Signature(signature, publicKey: SimplePublicKey(makerSigningKey, type: KeyPairType.ed25519)),
    );
    return holds ? MadeJoinCode(code: code, usesMax: usesMax, offerDigest: offerDigest) : null;
  } catch (_) {
    return null;
  }
}

List<int> _lp(List<int> bytes) {
  final out = Uint8List(4 + bytes.length);
  ByteData.sublistView(out, 0, 4).setUint32(0, bytes.length);
  out.setRange(4, out.length, bytes);
  return out;
}

List<int> _u32(int v) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, v);
  return out;
}

String _hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
