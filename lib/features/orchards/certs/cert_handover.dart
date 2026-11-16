/// A certificate handed from an owner's device to a member's with nothing of
/// ZestSSH Cloud in between (3.0; so that a
/// team reaches its hosts while the service is away, an owner's
/// device may hand a certificate over directly).
///
/// For a certificate the service only ever carried two things: a member's
/// request to an owner's device, and the certificate back. Both can go any
/// other way, as a code shown on one screen to the other's camera, or as a
/// line of text sent by whatever still works. Neither holds anything secret.
/// The request is signed with the member's keys, so nobody asks in their
/// name. The certificate is signed by the Crate's authority for the one
/// device key the request named: it is of no use on any other device, and
/// cannot be altered on the way.
///
/// What is in the two texts, and how they read what comes back from a chat
/// or a mail (lines broken, words around them), is here; who may sign what
/// is the service's business (orchard_certificates.dart).
///
/// An offline pass goes the same way (rules/offline_pass.dart): a member's
/// request to an owner's device, and the pass back, as two more texts of
/// the same make.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/rules/offline_pass.dart';

/// What a request handed over starts with. The number is the version of
/// what follows; a text of another version is not read.
const String kHandedRequestPrefix = 'zestssh-cert-ask:1:';

/// What a certificate handed over starts with.
const String kHandedCertificatePrefix = 'zestssh-cert-give:1:';

/// What a request for an offline pass starts with.
const String kHandedPassRequestPrefix = 'zestssh-pass-ask:1:';

/// What an offline pass handed over starts with.
const String kHandedPassPrefix = 'zestssh-pass-give:1:';

/// The longest text that is looked at: what a person pastes may hold more
/// than the request, and nothing ours is anywhere near this long.
const int kHandedTextMax = 16384;

/// The longest certificate that is read. One of ours is a few hundred bytes.
const int kHandedCertificateMax = 4096;

/// The longest name of an Orchard, a Crate, a request or an account read.
const int _idMax = 128;

/// What a text handed over is, as far as its first words say: a request
/// for a certificate, a certificate, a request for an offline pass, or a
/// pass.
enum HandedKind {
  request(kHandedRequestPrefix),
  certificate(kHandedCertificatePrefix),
  passRequest(kHandedPassRequestPrefix),
  pass(kHandedPassPrefix);

  const HandedKind(this.prefix);

  /// What a text of this kind starts with.
  final String prefix;
}

/// What [text] holds of the things that are handed over (the first of them
/// found in it), or null when it holds none. Says nothing of whether it
/// reads.
HandedKind? handedKindOf(String text) {
  HandedKind? found;
  var first = -1;
  for (final kind in HandedKind.values) {
    final at = text.indexOf(kind.prefix);
    if (at >= 0 && (first < 0 || at < first)) {
      first = at;
      found = kind;
    }
  }
  return found;
}

/// A member's request for a certificate as it is handed to an owner's
/// device: which Crate of which Orchard, and the request itself, signed
/// with the member's keys as any request is.
class HandedRequest {
  const HandedRequest({required this.orchardId, required this.crateId, required this.request});

  final String orchardId;
  final String crateId;
  final CertRequest request;

  /// The line of text, and what the code on screen holds.
  String toText() {
    final r = request;
    final out = BytesBuilder(copy: false)
      ..add(_text(orchardId))
      ..add(_text(crateId))
      ..add(_text(r.id))
      ..add(_text(r.uid))
      ..add(_u32(r.keyVersion))
      ..add(_u64(r.requestedAt))
      ..add(_bytes(r.sshPublicKey))
      ..add(_bytes(r.signature))
      ..add(_bytes(r.deviceKey ?? const []))
      ..add(_bytes(r.deviceSignature ?? const []));
    return '$kHandedRequestPrefix${_encode(out.takeBytes())}';
  }

  /// The request in [text], or null when there is none that reads. The
  /// text may have been through a chat or a mail: broken into lines, with
  /// words before and after it.
  static HandedRequest? fromText(String text) {
    final r = _Reader.of(text, kHandedRequestPrefix);
    if (r == null) return null;
    final orchardId = r.text();
    final crateId = r.text();
    final id = r.text();
    final uid = r.text();
    final keyVersion = r.u32();
    final requestedAt = r.u64();
    final sshPublicKey = r.bytes(32);
    final signature = r.bytes(64);
    final deviceKey = r.bytes(32, orNone: true);
    final deviceSignature = r.bytes(64, orNone: true);
    if (r.failed ||
        orchardId == null ||
        crateId == null ||
        id == null ||
        uid == null ||
        keyVersion == null ||
        requestedAt == null ||
        sshPublicKey == null ||
        signature == null ||
        deviceKey == null ||
        deviceSignature == null) {
      return null;
    }
    // A device and its signature come together, or not at all.
    if (deviceKey.isEmpty != deviceSignature.isEmpty) return null;
    return HandedRequest(
      orchardId: orchardId,
      crateId: crateId,
      request: CertRequest(
        id: id,
        uid: uid,
        keyVersion: keyVersion,
        sshPublicKey: sshPublicKey,
        requestedAt: requestedAt,
        signature: signature,
        deviceKey: deviceKey.isEmpty ? null : deviceKey,
        deviceSignature: deviceSignature.isEmpty ? null : deviceSignature,
      ),
    );
  }
}

/// A certificate as an owner's device hands it back: for which request, in
/// which Crate of which Orchard, and the certificate.
class HandedCertificate {
  const HandedCertificate({
    required this.orchardId,
    required this.crateId,
    required this.requestId,
    required this.certificate,
  });

  final String orchardId;
  final String crateId;
  final String requestId;

  /// The certificate as OpenSSH writes one (the bytes, not the line).
  final Uint8List certificate;

  /// The line of text, and what the code on screen holds.
  String toText() {
    final out = BytesBuilder(copy: false)
      ..add(_text(orchardId))
      ..add(_text(crateId))
      ..add(_text(requestId))
      ..add(_bytes(certificate));
    return '$kHandedCertificatePrefix${_encode(out.takeBytes())}';
  }

  /// The certificate in [text], or null when there is none that reads.
  /// Whether it is one to keep is for whoever checks it against the
  /// record: this only reads.
  static HandedCertificate? fromText(String text) {
    final r = _Reader.of(text, kHandedCertificatePrefix);
    if (r == null) return null;
    final orchardId = r.text();
    final crateId = r.text();
    final requestId = r.text();
    final certificate = r.bytes(null, max: kHandedCertificateMax);
    if (r.failed || orchardId == null || crateId == null || requestId == null || certificate == null) return null;
    if (certificate.isEmpty) return null;
    return HandedCertificate(orchardId: orchardId, crateId: crateId, requestId: requestId, certificate: certificate);
  }
}

/// A member's request for an offline pass as it is handed to an owner's
/// device: for which Crate of which Orchard ([kAllOfOrchard] for all of
/// it), and the request itself, signed with the member's keys.
class HandedPassRequest {
  const HandedPassRequest({required this.orchardId, required this.crateId, required this.request});

  final String orchardId;
  final String crateId;
  final PassRequest request;

  /// The line of text, and what the code on screen holds.
  String toText() {
    final r = request;
    final out = BytesBuilder(copy: false)
      ..add(_text(orchardId))
      ..add(_text(crateId))
      ..add(_text(r.uid))
      ..add(_u32(r.keyVersion))
      ..add(_u64(r.askedAt))
      ..add(_bytes(r.deviceKey))
      ..add(_bytes(r.signature));
    return '$kHandedPassRequestPrefix${_encode(out.takeBytes())}';
  }

  /// The request in [text], or null when there is none that reads.
  static HandedPassRequest? fromText(String text) {
    final r = _Reader.of(text, kHandedPassRequestPrefix);
    if (r == null) return null;
    final orchardId = r.text();
    final crateId = r.text();
    final uid = r.text();
    final keyVersion = r.u32();
    final askedAt = r.u64();
    final deviceKey = r.bytes(32);
    final signature = r.bytes(64);
    if (r.failed ||
        orchardId == null ||
        crateId == null ||
        uid == null ||
        keyVersion == null ||
        askedAt == null ||
        deviceKey == null ||
        signature == null) {
      return null;
    }
    return HandedPassRequest(
      orchardId: orchardId,
      crateId: crateId,
      request: PassRequest(
          uid: uid, keyVersion: keyVersion, deviceKey: deviceKey, askedAt: askedAt, signature: signature),
    );
  }
}

/// An offline pass as an owner's device hands it back: for which Crate of
/// which Orchard ([kAllOfOrchard] for all of it), and the pass.
class HandedPass {
  const HandedPass({required this.orchardId, required this.crateId, required this.pass});

  final String orchardId;
  final String crateId;
  final OfflinePass pass;

  /// The line of text, and what the code on screen holds.
  String toText() {
    final p = pass;
    final out = BytesBuilder(copy: false)
      ..add(_text(orchardId))
      ..add(_text(crateId))
      ..add(_text(p.uid))
      ..add(_bytes(p.deviceKey))
      ..add(_u64(p.until))
      ..add(_u64(p.madeAt))
      ..add(_text(p.by))
      ..add(_u32(p.byKeyVersion))
      ..add(_bytes(p.signature));
    return '$kHandedPassPrefix${_encode(out.takeBytes())}';
  }

  /// The pass in [text], or null when there is none that reads. Whether it
  /// is one to keep is for whoever checks it against the record: this only
  /// reads.
  static HandedPass? fromText(String text) {
    final r = _Reader.of(text, kHandedPassPrefix);
    if (r == null) return null;
    final orchardId = r.text();
    final crateId = r.text();
    final uid = r.text();
    final deviceKey = r.bytes(32);
    final until = r.u64();
    final madeAt = r.u64();
    final by = r.text();
    final byKeyVersion = r.u32();
    final signature = r.bytes(64);
    if (r.failed ||
        orchardId == null ||
        crateId == null ||
        uid == null ||
        deviceKey == null ||
        until == null ||
        madeAt == null ||
        by == null ||
        byKeyVersion == null ||
        signature == null) {
      return null;
    }
    return HandedPass(
      orchardId: orchardId,
      crateId: crateId,
      pass: OfflinePass(
        uid: uid,
        deviceKey: deviceKey,
        until: until,
        madeAt: madeAt,
        by: by,
        byKeyVersion: byKeyVersion,
        signature: signature,
      ),
    );
  }
}

String _encode(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');

List<int> _u16(int v) => [(v >> 8) & 0xff, v & 0xff];

List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

List<int> _u64(int v) => [..._u32(v ~/ 0x100000000), ..._u32(v % 0x100000000)];

/// [bytes] with their length before them (two bytes), so that fields never
/// run together.
List<int> _bytes(List<int> bytes) => [..._u16(bytes.length), ...bytes];

List<int> _text(String s) => _bytes(utf8.encode(s));

/// Reads the fields of a text handed over, in order. Once something does
/// not read, [failed] stays true and every later field reads as null.
class _Reader {
  _Reader(this._data);

  final Uint8List _data;
  int _at = 0;
  bool failed = false;

  /// A reader of what follows [prefix] in [text], or null when [text] has
  /// no such thing. What follows the prefix is taken as far as it goes on
  /// in the letters such a text is written in, across line breaks and
  /// spaces a chat or a mail put into it; whatever else comes after is not
  /// looked at, and neither is anything beyond the fields that are read.
  static _Reader? of(String text, String prefix) {
    if (text.length > kHandedTextMax) return null;
    final at = text.indexOf(prefix);
    if (at < 0) return null;
    final rest = text.substring(at + prefix.length).replaceAll(RegExp(r'\s+'), '');
    var body = RegExp(r'^[A-Za-z0-9_-]+').stringMatch(rest);
    if (body == null) return null;
    // A length no text of ours has: a letter too many came along.
    if (body.length % 4 == 1) body = body.substring(0, body.length - 1);
    try {
      return _Reader(base64Url.decode(base64Url.normalize(body)));
    } on FormatException {
      return null;
    }
  }

  int? _take(int n) {
    if (failed || _at + n > _data.length) {
      failed = true;
      return null;
    }
    final from = _at;
    _at += n;
    return from;
  }

  int? u32() {
    final from = _take(4);
    if (from == null) return null;
    return (_data[from] << 24) | (_data[from + 1] << 16) | (_data[from + 2] << 8) | _data[from + 3];
  }

  /// Eight bytes as a number, when it is one a time can be (below 2^53, so
  /// that it reads the same wherever the app runs).
  int? u64() {
    final high = u32();
    final low = u32();
    if (high == null || low == null) return null;
    if (high >= 0x200000) {
      failed = true;
      return null;
    }
    return high * 0x100000000 + low;
  }

  /// A field of bytes: of exactly [length] when given (or of none at all,
  /// with [orNone]), and of no more than [max].
  Uint8List? bytes(int? length, {bool orNone = false, int max = 1024}) {
    final head = _take(2);
    if (head == null) return null;
    final n = (_data[head] << 8) | _data[head + 1];
    final fits = length == null ? n <= max : (n == length || (orNone && n == 0));
    if (!fits) {
      failed = true;
      return null;
    }
    final from = _take(n);
    if (from == null) return null;
    return Uint8List.sublistView(_data, from, from + n);
  }

  /// A name: bytes that read as text, not empty and not long.
  String? text() {
    final raw = bytes(null, max: _idMax);
    if (raw == null) return null;
    if (raw.isEmpty) {
      failed = true;
      return null;
    }
    try {
      return utf8.decode(raw);
    } on FormatException {
      failed = true;
      return null;
    }
  }
}
