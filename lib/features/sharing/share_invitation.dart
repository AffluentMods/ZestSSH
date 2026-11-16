/// Session sharing (3.0): the two signed messages that say who is on each
/// end of a share. The channel (share_channel.dart) keeps a live view
/// secret; these keep it between the right people.
///
/// The invitation is made by the person who shares a session (the host),
/// one for each person invited. It names the share, the Orchard and Crate it
/// is in, who it is from and who it is for, how the session is shared, and
/// for a live view the host's two one-time public keys. It is signed with
/// the host's account key and sealed to the invited person's account key, so
/// ZestSSH Cloud, which carries it, can neither read it (which host, which
/// tmux session) nor make one, nor pass one person's to another.
///
/// The join is made by the invited person's device when it starts watching:
/// it names the same share, carries the hash of the invitation it answers
/// and the viewer's two one-time public values, and is signed with the
/// viewer's account key.
///
/// Each side checks the other's signature against the keys it has pinned for
/// that member (the ones compared by fingerprint, or followed since), and
/// against the Orchard's signed record: both must be able to open the Crate
/// now. Both messages then go into the channel's key schedule, so the keys
/// of a live view belong to exactly these two messages.
///
/// The bytes: fields one after the other, each with its length in front (4
/// bytes, big endian) or of fixed width, so no two different messages are
/// the same bytes. What is signed is what travels: nothing is re-encoded on
/// the way, and a message that does not parse to the last byte is refused.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/sharing/share_channel.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/teams/crypto/user_keypair.dart';

const String kShareInviteLabel = 'zestssh.share.invite.v1';
const String kShareJoinLabel = 'zestssh.share.join.v1';

/// The most people one session is shared with. ZestSSH Cloud holds to the
/// same number (ZestSSH Cloud's src/lib/session_shares.js).
const int kShareMaxPeople = 8;

/// The longest a share lasts, and so the longest an invitation is good for.
const int kShareLifetimeSeconds = 12 * 60 * 60;

/// The most a sealed invitation may be (the server's limit).
const int kShareSealedMax = 4096;

final Ed25519 _ed25519 = Ed25519();

final RegExp _id = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// A tmux session name the app will pass to tmux on the host: letters,
/// digits, dash and underscore only, so a name from someone else can never
/// be more than a name.
final RegExp kShareTmuxName = RegExp(r'^[A-Za-z0-9_-]{1,32}$');

/// How a session is shared.
enum ShareMode {
  /// The others watch the host's terminal through the encrypted stream.
  live,

  /// The others connect to the host themselves and attach to the same tmux
  /// session.
  tmux,
}

/// Why a device will not act on an invitation or a join.
enum ShareProblem {
  /// Not bytes of the right shape.
  malformed,

  /// It names another share, Orchard, Crate, sender or receiver than the
  /// one it arrived as.
  mismatch,

  /// Its time is over.
  expired,

  /// The sender is not a member who can open the Crate now.
  senderNoAccess,

  /// This device's account cannot open the Crate now.
  noAccess,

  /// This device has no keys pinned for the sender, or they replaced their
  /// keys since they were compared: compare them first.
  keysChanged,

  /// The signature is not by the sender's pinned keys.
  notSigned,
}

/// The keys this device trusts for a member, as a share needs them.
class ShareParty {
  const ShareParty({
    required this.uid,
    required this.keyVersion,
    required this.signingKey,
    required this.encryptionKey,
    this.keysChanged = false,
  });

  final String uid;
  final int keyVersion;
  final Uint8List signingKey;
  final Uint8List encryptionKey;

  /// Their keys changed since this device's person compared them (or new
  /// keys wait to be compared): nothing is shared with them, and nothing of
  /// theirs is joined, until they are compared again.
  final bool keysChanged;
}

/// What an invitation says.
class ShareInvitation {
  ShareInvitation({
    required this.shareId,
    required this.orchardId,
    required this.crateId,
    required this.fromUid,
    required this.fromKeyVersion,
    required this.toUid,
    required this.mode,
    required this.connectionId,
    required this.expiresAt,
    this.tmuxSession = '',
    this.remoteUser = '',
    this.keyboard = false,
    this.mayEnd = false,
    this.offer,
  }) {
    if (!_id.hasMatch(shareId) || !_id.hasMatch(orchardId) || !_id.hasMatch(crateId)) {
      throw const FormatException('not an id');
    }
    // A host's key in the Crate is whatever the device that made it chose
    // (not always a UUID): the invited device only ever looks it up in its
    // own copy of the Crate.
    if (!_isUid(connectionId) || connectionId.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
      throw const FormatException('not a host');
    }
    if (!_isUid(fromUid) || !_isUid(toUid) || fromUid == toUid) {
      throw const FormatException('not two accounts');
    }
    if (fromKeyVersion < 1 || fromKeyVersion > 1000000) throw const FormatException('not a key version');
    if (expiresAt < 1 || expiresAt > 0xffffffff) throw const FormatException('not a time');
    if (utf8.encode(remoteUser).length > 64) throw const FormatException('not a user name');
    // Whoever may end a session watches it and never types into it.
    if (keyboard && mayEnd) throw const FormatException('not one part in a live view');
    switch (mode) {
      case ShareMode.live:
        if (offer == null || tmuxSession.isNotEmpty) throw const FormatException('not a live view');
      case ShareMode.tmux:
        if (offer != null || keyboard || mayEnd || !kShareTmuxName.hasMatch(tmuxSession)) {
          throw const FormatException('not a shared tmux session');
        }
    }
  }

  final String shareId;
  final String orchardId;
  final String crateId;

  /// The host: who shares, and with which version of their keys they signed.
  final String fromUid;
  final int fromKeyVersion;

  /// Who is invited.
  final String toUid;
  final ShareMode mode;

  /// The host in the Crate the session is on: its key there, the same on
  /// every member's device.
  final String connectionId;

  /// The tmux session to attach to (tmux only).
  final String tmuxSession;

  /// The user name the host signed in to the machine as. A shared tmux
  /// session is one user's: someone who signs in as another will not find
  /// it, and the app says so. Shown, never used to connect.
  final String remoteUser;

  /// Whether the viewer may ask for the keyboard (live only).
  final bool keyboard;

  /// Whether the viewer may end the session (live only; session moderation).
  /// Never together with [keyboard]: someone invited watches, may be
  /// handed the keyboard, or may end the session.
  final bool mayEnd;

  /// The host's one-time keys for this viewer (live only).
  final ShareOffer? offer;

  /// When the invitation stops being good, in seconds since the epoch.
  final int expiresAt;

  /// The exact bytes the host signs.
  Uint8List message() {
    final out = BytesBuilder(copy: false)
      ..add(_lp(utf8.encode(kShareInviteLabel)))
      ..add(_lp(utf8.encode(shareId)))
      ..add(_lp(utf8.encode(orchardId)))
      ..add(_lp(utf8.encode(crateId)))
      ..add(_lp(utf8.encode(fromUid)))
      ..add(_u32(fromKeyVersion))
      ..add(_lp(utf8.encode(toUid)))
      ..addByte(mode == ShareMode.live ? 1 : 2)
      ..add(_lp(utf8.encode(connectionId)))
      ..add(_lp(utf8.encode(tmuxSession)))
      ..add(_lp(utf8.encode(remoteUser)))
      // The part they have: 0 watches, 1 may be handed the keyboard, 2 may
      // end the session.
      ..addByte(keyboard
          ? 1
          : mayEnd
              ? 2
              : 0)
      ..add(_lp(offer?.x25519Key ?? const <int>[]))
      ..add(_lp(offer?.kemKey ?? const <int>[]))
      ..add(_u64(expiresAt));
    return out.toBytes();
  }

  /// Reads [message]. Throws [FormatException] for anything that is not
  /// exactly an invitation.
  static ShareInvitation parse(List<int> message) {
    final r = _Reader(message);
    if (r.text() != kShareInviteLabel) throw const FormatException('not an invitation');
    final shareId = r.text();
    final orchardId = r.text();
    final crateId = r.text();
    final fromUid = r.text();
    final fromKeyVersion = r.u32();
    final toUid = r.text();
    final mode = switch (r.byte()) {
      1 => ShareMode.live,
      2 => ShareMode.tmux,
      _ => throw const FormatException('not a way of sharing'),
    };
    final connectionId = r.text();
    final tmuxSession = r.text();
    final remoteUser = r.text();
    final part = r.byte();
    if (part > 2) throw const FormatException('not a part in a live view');
    final x25519 = r.bytes();
    final kem = r.bytes();
    final expiresAt = r.u64();
    r.end();
    final ShareOffer? offer;
    if (x25519.isEmpty && kem.isEmpty) {
      offer = null;
    } else {
      try {
        offer = ShareOffer(x25519Key: x25519, kemKey: kem);
      } on ArgumentError {
        throw const FormatException('not the keys of a live view');
      }
    }
    return ShareInvitation(
      shareId: shareId,
      orchardId: orchardId,
      crateId: crateId,
      fromUid: fromUid,
      fromKeyVersion: fromKeyVersion,
      toUid: toUid,
      mode: mode,
      connectionId: connectionId,
      tmuxSession: tmuxSession,
      remoteUser: remoteUser,
      keyboard: part == 1,
      mayEnd: part == 2,
      offer: offer,
      expiresAt: expiresAt,
    );
  }
}

/// An invitation with the host's signature: what is sealed and sent.
class SignedShareInvitation {
  SignedShareInvitation._(this.invitation, this.wire);

  final ShareInvitation invitation;

  /// The signed message with its length in front, then the 64-byte
  /// signature: what travels, and what the channel's keys are bound to.
  final Uint8List wire;

  static Future<SignedShareInvitation> sign(ShareInvitation invitation, AccountKeys keys) async {
    if (keys.version != invitation.fromKeyVersion) {
      throw ArgumentError('the invitation names another version of the keys');
    }
    final message = invitation.message();
    return SignedShareInvitation._(
        invitation, Uint8List.fromList([..._lp(message), ...await keys.sign(message)]));
  }

  /// Reads [wire]. Throws [FormatException]. Says nothing yet about who
  /// signed it: see [signedBy].
  static SignedShareInvitation decode(List<int> wire) {
    final (message, _) = _split(wire);
    return SignedShareInvitation._(ShareInvitation.parse(message), Uint8List.fromList(wire));
  }

  /// Whether the signature is by [signingKey] (Ed25519, 32 bytes).
  Future<bool> signedBy(List<int> signingKey) => _verify(wire, signingKey);

  /// SHA-256 of [wire]: how a join names the invitation it answers.
  Uint8List get digest => Uint8List.fromList(hash.sha256.convert(wire).bytes);

  /// Sealed to the invited person's account key (X25519, 32 bytes), for
  /// this share and nothing else.
  Future<Uint8List> sealTo(List<int> encryptionKey) =>
      _seal(encryptionKey, wire, shareId: invitation.shareId);

  /// Opens what [sealTo] made, with the invited person's own keys, as the
  /// invitation to [shareId] (the one the server listed it under). Throws
  /// [FormatException] when it does not open or is not an invitation.
  static Future<SignedShareInvitation> open(
    List<int> sealed,
    UserKeyPair mine, {
    required String shareId,
  }) async {
    if (!_id.hasMatch(shareId) || sealed.length > kShareSealedMax) {
      throw const FormatException('not a sealed invitation');
    }
    final Uint8List wire;
    try {
      wire = await openSealed(mine, sealed, context: _sealContext(shareId));
    } on SecretBoxAuthenticationError {
      throw const FormatException('the invitation does not open');
    } on ArgumentError {
      throw const FormatException('not a sealed invitation');
    }
    return decode(wire);
  }
}

String _sealContext(String shareId) => '$kShareInviteLabel $shareId';

Future<Uint8List> _seal(List<int> encryptionKey, List<int> wire, {required String shareId}) =>
    sealTo(encryptionKey, wire, context: _sealContext(shareId));

/// What a join says.
class ShareJoinRequest {
  ShareJoinRequest({
    required this.shareId,
    required this.viewerUid,
    required this.viewerKeyVersion,
    required this.invitationDigest,
    required this.join,
  }) {
    if (!_id.hasMatch(shareId)) throw const FormatException('not an id');
    if (!_isUid(viewerUid)) throw const FormatException('not an account');
    if (viewerKeyVersion < 1 || viewerKeyVersion > 1000000) throw const FormatException('not a key version');
    if (invitationDigest.length != 32) throw const FormatException('not the hash of an invitation');
  }

  final String shareId;
  final String viewerUid;
  final int viewerKeyVersion;

  /// [SignedShareInvitation.digest] of the invitation this answers.
  final Uint8List invitationDigest;

  /// The viewer's one-time public key and the ML-KEM ciphertext.
  final ShareJoin join;

  Uint8List message() {
    final out = BytesBuilder(copy: false)
      ..add(_lp(utf8.encode(kShareJoinLabel)))
      ..add(_lp(utf8.encode(shareId)))
      ..add(_lp(utf8.encode(viewerUid)))
      ..add(_u32(viewerKeyVersion))
      ..add(_lp(invitationDigest))
      ..add(_lp(join.x25519Key))
      ..add(_lp(join.kemCiphertext));
    return out.toBytes();
  }

  static ShareJoinRequest parse(List<int> message) {
    final r = _Reader(message);
    if (r.text() != kShareJoinLabel) throw const FormatException('not a join');
    final shareId = r.text();
    final viewerUid = r.text();
    final viewerKeyVersion = r.u32();
    final digest = r.bytes();
    final x25519 = r.bytes();
    final ciphertext = r.bytes();
    r.end();
    final ShareJoin join;
    try {
      join = ShareJoin(x25519Key: x25519, kemCiphertext: ciphertext);
    } on ArgumentError {
      throw const FormatException('not the keys of a live view');
    }
    return ShareJoinRequest(
      shareId: shareId,
      viewerUid: viewerUid,
      viewerKeyVersion: viewerKeyVersion,
      invitationDigest: digest,
      join: join,
    );
  }
}

/// A join with the viewer's signature: what the viewer sends the host.
class SignedShareJoin {
  SignedShareJoin._(this.request, this.wire);

  final ShareJoinRequest request;
  final Uint8List wire;

  static Future<SignedShareJoin> sign(ShareJoinRequest request, AccountKeys keys) async {
    if (keys.version != request.viewerKeyVersion) {
      throw ArgumentError('the join names another version of the keys');
    }
    final message = request.message();
    return SignedShareJoin._(request, Uint8List.fromList([..._lp(message), ...await keys.sign(message)]));
  }

  static SignedShareJoin decode(List<int> wire) {
    final (message, _) = _split(wire);
    return SignedShareJoin._(ShareJoinRequest.parse(message), Uint8List.fromList(wire));
  }

  Future<bool> signedBy(List<int> signingKey) => _verify(wire, signingKey);
}

/// The longest a signed invitation or join is: nothing longer is parsed.
const int _wireMax = 4096;

/// [wire] as (message, signature). Throws [FormatException].
(Uint8List, Uint8List) _split(List<int> wire) {
  if (wire.length < 4 + 64 || wire.length > _wireMax) throw const FormatException('not a signed message');
  final bytes = wire is Uint8List ? wire : Uint8List.fromList(wire);
  final length = ByteData.sublistView(bytes).getUint32(0);
  if (length != bytes.length - 4 - 64) throw const FormatException('not a signed message');
  return (Uint8List.sublistView(bytes, 4, 4 + length), Uint8List.sublistView(bytes, 4 + length));
}

Future<bool> _verify(List<int> wire, List<int> signingKey) async {
  if (signingKey.length != 32) return false;
  try {
    final (message, signature) = _split(wire);
    return await _ed25519.verify(
      message,
      signature: Signature(signature, publicKey: SimplePublicKey(signingKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

bool _isUid(String v) {
  final length = utf8.encode(v).length;
  return length >= 1 && length <= 128;
}

/// Why the invited device ([me]) will not join [signed], which ZestSSH Cloud
/// listed as an invitation to [shareId] in [orchardId]'s [crateId] from
/// [fromUid], shared as [mode]; or null when it will. [record] is the
/// Orchard's record as this device has it, [host] the keys it has pinned for
/// the sender (null: none).
///
/// Everything the server said about the invitation is checked against what
/// the host signed, the host against the record (a member who can open the
/// Crate now) and the signature against the pinned keys: a server that made
/// an invitation up, changed one, or passed on someone else's is refused
/// here.
Future<ShareProblem?> shareInvitationProblem(
  SignedShareInvitation signed, {
  required String shareId,
  required String orchardId,
  required String crateId,
  required String fromUid,
  required ShareMode mode,
  required String me,
  required OrchardRecord record,
  required ShareParty? host,
  required int nowSeconds,
}) async {
  final i = signed.invitation;
  if (i.shareId != shareId ||
      i.orchardId != orchardId ||
      record.orchardId != orchardId ||
      i.crateId != crateId ||
      i.fromUid != fromUid ||
      i.mode != mode ||
      i.toUid != me) {
    return ShareProblem.mismatch;
  }
  // Good until its time, and never for longer than a share can last.
  if (i.expiresAt <= nowSeconds || i.expiresAt > nowSeconds + kShareLifetimeSeconds + 300) {
    return ShareProblem.expired;
  }
  final holders = record.entitlementsAt(nowSeconds);
  if (!(holders[fromUid]?.contains(crateId) ?? false)) return ShareProblem.senderNoAccess;
  if (!(holders[me]?.contains(crateId) ?? false)) return ShareProblem.noAccess;
  if (host == null || host.uid != fromUid || host.keysChanged || host.keyVersion != i.fromKeyVersion) {
    return ShareProblem.keysChanged;
  }
  if (!await signed.signedBy(host.signingKey)) return ShareProblem.notSigned;
  return null;
}

/// Why the host will not let the viewer who sent [signed] in, or null when
/// it will. [invitation] is the one the host made for that person, [record]
/// the Orchard's record as the host has it NOW (someone removed since they
/// were invited is refused), [viewer] the keys pinned for them.
Future<ShareProblem?> shareJoinProblem(
  SignedShareJoin signed, {
  required SignedShareInvitation invitation,
  required OrchardRecord record,
  required ShareParty? viewer,
  required int nowSeconds,
}) async {
  final j = signed.request;
  final i = invitation.invitation;
  if (j.shareId != i.shareId || j.viewerUid != i.toUid || !_same(j.invitationDigest, invitation.digest)) {
    return ShareProblem.mismatch;
  }
  if (i.expiresAt <= nowSeconds) return ShareProblem.expired;
  if (!(record.entitlementsAt(nowSeconds)[j.viewerUid]?.contains(i.crateId) ?? false)) {
    return ShareProblem.senderNoAccess;
  }
  if (viewer == null || viewer.uid != j.viewerUid || viewer.keysChanged || viewer.keyVersion != j.viewerKeyVersion) {
    return ShareProblem.keysChanged;
  }
  if (!await signed.signedBy(viewer.signingKey)) return ShareProblem.notSigned;
  return null;
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

List<int> _lp(List<int> bytes) {
  final out = Uint8List(4 + bytes.length);
  ByteData.sublistView(out, 0, 4).setUint32(0, bytes.length);
  out.setRange(4, out.length, bytes);
  return out;
}

List<int> _u32(int value) => (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

List<int> _u64(int value) => (ByteData(8)..setUint64(0, value)).buffer.asUint8List();

/// Reads the fields of a message in order; anything short, long or not
/// UTF-8 is a [FormatException].
class _Reader {
  _Reader(List<int> message) : _bytes = message is Uint8List ? message : Uint8List.fromList(message);

  final Uint8List _bytes;
  int _at = 0;

  Uint8List _take(int length) {
    if (length < 0 || _at + length > _bytes.length) throw const FormatException('a short message');
    final out = Uint8List.sublistView(_bytes, _at, _at + length);
    _at += length;
    return out;
  }

  int byte() => _take(1)[0];

  int u32() => ByteData.sublistView(_take(4)).getUint32(0);

  int u64() {
    final value = ByteData.sublistView(_take(8)).getUint64(0);
    if (value < 0) throw const FormatException('not a number');
    return value;
  }

  Uint8List bytes() => Uint8List.fromList(_take(u32()));

  String text() => utf8.decode(bytes());

  void end() {
    if (_at != _bytes.length) throw const FormatException('more than a message');
  }
}
