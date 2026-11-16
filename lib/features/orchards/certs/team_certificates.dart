/// Certificates from a Crate's authority (3.0).
///
/// A Crate's owners can give it a certificate authority: its hosts trust the
/// authority (sshd's TrustedUserCAKeys), and each member's device connects
/// with an SSH key of its own that never leaves it, and a short-lived
/// certificate the authority signed for that key. Nothing that opens those
/// hosts is kept in the Crate for anyone to take away.
///
/// A device asks for a certificate with a request signed by the account's
/// keys, so the server cannot ask in anyone's name: an owner's device
/// checks the signature against the keys the record holds for the member,
/// and the member's access in the record, before it signs anything. The
/// member's device checks what comes back: signed by the authority the
/// record names, for its own key.
///
/// The request bytes must match the server's (ZestSSH Cloud's
/// src/lib/team_certificates.js); a shared test vector holds them together.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/services/ssh_cert/ssh_cert_signer.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';
import 'package:zestssh/services/ssh_cert/ssh_wire.dart';

const String kCertRequestLabel = 'zestssh.cert-request.v1';

/// How far from now a request's time may be when the server takes it.
const int kCertRequestWindowSeconds = 600;

/// How long a request waits for an owner's device: the server lists
/// unsigned requests for a day, and an owner's device signs none older.
const int kCertRequestLifetimeSeconds = 86400;

/// How far back a certificate starts, for hosts whose clocks run a little
/// behind (within the server's ten minutes either way).
const int kCertBackdateSeconds = 300;

final Ed25519 _ed25519 = Ed25519();

/// The exact bytes a certificate request's signature covers: in [orchardId]'s
/// [crateId], request [requestId] by [uid] with their keys at [keyVersion],
/// for the Ed25519 SSH key [sshPublicKey] (32 bytes), at [requestedAt] (unix
/// seconds).
Uint8List certRequestMessage({
  required String orchardId,
  required String crateId,
  required String requestId,
  required String uid,
  required int keyVersion,
  required List<int> sshPublicKey,
  required int requestedAt,
}) {
  return Uint8List.fromList([
    ..._lp(utf8.encode(kCertRequestLabel)),
    ..._lp(utf8.encode(orchardId)),
    ..._lp(utf8.encode(crateId)),
    ..._lp(utf8.encode(requestId)),
    ..._lp(utf8.encode(uid)),
    ..._u32(keyVersion),
    ..._lp(sshPublicKey),
    ..._u64(requestedAt),
  ]);
}

/// A device's request for a certificate for its SSH key, as the server keeps
/// it until an owner's device signs it.
class CertRequest {
  const CertRequest({
    required this.id,
    required this.uid,
    required this.keyVersion,
    required this.sshPublicKey,
    required this.requestedAt,
    required this.signature,
    this.deviceKey,
    this.deviceSignature,
  });

  final String id;

  /// The member asking.
  final String uid;

  /// The version of the member's keys the request is signed with.
  final int keyVersion;

  /// The device's Ed25519 SSH public key (32 bytes).
  final Uint8List sshPublicKey;

  /// Unix seconds.
  final int requestedAt;
  final Uint8List signature;

  /// The device that asks (its own signing key, 32 bytes) and its signature
  /// over [certDeviceMessage] of this request (trusted devices): both or
  /// neither. Where an Orchard lets in approved devices only, an owner's
  /// device signs only for a device the record lists for the member.
  final Uint8List? deviceKey;
  final Uint8List? deviceSignature;

  /// A request as the server lists it; null when malformed.
  static CertRequest? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id'];
    final uid = raw['uid'];
    final keyVersion = raw['key_version'];
    final key = raw['ssh_public_key'];
    final at = raw['requested_at'];
    final signature = raw['signature'];
    if (id is! String || uid is! String || keyVersion is! int || key is! String || at is! int || signature is! String) {
      return null;
    }
    // A device and its signature come together, or not at all.
    final device = raw['device'];
    final deviceSig = raw['device_sig'];
    if ((device == null) != (deviceSig == null)) return null;
    final deviceKey = deviceKeyBytes(device);
    if (device != null && (deviceKey == null || deviceSig is! String)) return null;
    try {
      return CertRequest(
        id: id,
        uid: uid,
        keyVersion: keyVersion,
        sshPublicKey: base64Decode(key),
        requestedAt: at,
        signature: base64Decode(signature),
        deviceKey: deviceKey,
        deviceSignature: deviceSig is String ? base64Decode(deviceSig) : null,
      );
    } on FormatException {
      return null;
    }
  }

  /// What the device sends (the server knows who asks).
  Map<String, Object?> toJson() => {
        'id': id,
        'ssh_public_key': base64Encode(sshPublicKey),
        'requested_at': requestedAt,
        'key_version': keyVersion,
        'signature': base64Encode(signature),
        if (deviceKey != null) 'device': deviceKeyText(deviceKey!),
        if (deviceSignature != null) 'device_sig': base64Encode(deviceSignature!),
      };

  Uint8List message({required String orchardId, required String crateId}) => certRequestMessage(
        orchardId: orchardId,
        crateId: crateId,
        requestId: id,
        uid: uid,
        keyVersion: keyVersion,
        sshPublicKey: sshPublicKey,
        requestedAt: requestedAt,
      );
}

/// Whether [request]'s signature is by the key [signingKey], for exactly
/// that request in [orchardId]'s [crateId].
Future<bool> verifyCertRequest(
  List<int> signingKey,
  CertRequest request, {
  required String orchardId,
  required String crateId,
}) async {
  if (request.signature.length != 64 || signingKey.length != 32 || request.sshPublicKey.length != 32) return false;
  try {
    return await _ed25519.verify(
      request.message(orchardId: orchardId, crateId: crateId),
      signature: Signature(request.signature, publicKey: SimplePublicKey(signingKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

/// Why an owner's device will not sign a request ([certRequestRefusal]).
enum CertRequestRefusal {
  /// The Crate has no certificate authority, or it is off.
  noAuthority('no certificate authority'),

  /// Whoever asks is not in the record, or not active in it.
  notAMember('not a member'),

  /// They cannot open the Crate now.
  noAccess('no access to the Crate'),

  /// The request is signed with keys the record no longer has as theirs.
  notCurrentKeys('not their current keys'),

  /// It was made more than a day ago, or is dated ahead of this clock.
  notRecent('not asked in the last day'),

  /// Their role signs in as nobody on the Crate's hosts.
  noUserNames('the role signs in as nobody'),

  /// The signature is not theirs for this request.
  notSignedByMember('not signed by the member'),

  /// Approved devices only, and the request names none the record lists.
  deviceNotApproved('not from an approved device'),

  /// Approved devices only, and the device it names did not sign it.
  notSignedByDevice('not signed by that device');

  const CertRequestRefusal(this.words);

  /// What the log says.
  final String words;
}

/// Why an owner's device will not sign [request] in [record]'s [crateId] at
/// [nowSeconds] ([orchardId] the record's Orchard), or null when it will: the
/// Crate's authority on, the member in the record with access to the Crate
/// now, their current keys signing exactly this request, asked within the
/// last day, and their role signing in as someone. Where the Orchard lets
/// in approved devices only, also: asked by a device the record lists
/// for the member, which signed the request itself. The server says the
/// same, and this device does not take its word for it.
Future<CertRequestRefusal?> certRequestRefusal(
  OrchardRecord record,
  CertRequest request, {
  required String orchardId,
  required String crateId,
  required int nowSeconds,
}) async {
  final ca = record.crates[crateId]?.ca;
  if (ca == null || !ca.on) return CertRequestRefusal.noAuthority;
  final member = record.members[request.uid];
  if (member == null || member.status != MemberStatus.active) return CertRequestRefusal.notAMember;
  if (!(record.entitlementsAt(nowSeconds)[request.uid]?.contains(crateId) ?? false)) {
    return CertRequestRefusal.noAccess;
  }
  final keys = member.keys[request.keyVersion];
  if (keys == null || request.keyVersion != member.currentKeys.version) return CertRequestRefusal.notCurrentKeys;
  if (request.requestedAt > nowSeconds + kCertRequestWindowSeconds ||
      request.requestedAt < nowSeconds - kCertRequestLifetimeSeconds) {
    return CertRequestRefusal.notRecent;
  }
  if ((ca.principals[member.role] ?? const []).isEmpty) return CertRequestRefusal.noUserNames;
  if (!await verifyCertRequest(keys.signingKey, request, orchardId: orchardId, crateId: crateId)) {
    return CertRequestRefusal.notSignedByMember;
  }
  if (record.rules.trustedDevices) {
    final device = request.deviceKey;
    final signature = request.deviceSignature;
    if (device == null || signature == null || !record.devicesOf(request.uid).contains(deviceKeyText(device))) {
      return CertRequestRefusal.deviceNotApproved;
    }
    final signed = certDeviceMessage(request.message(orchardId: orchardId, crateId: crateId));
    if (!await verifyDeviceSignature(device, signed, signature)) return CertRequestRefusal.notSignedByDevice;
  }
  return null;
}

/// [certRequestRefusal] in the words the log uses, or null when an owner's
/// device signs the request.
Future<String?> certRequestProblem(
  OrchardRecord record,
  CertRequest request, {
  required String orchardId,
  required String crateId,
  required int nowSeconds,
}) async =>
    (await certRequestRefusal(record, request, orchardId: orchardId, crateId: crateId, nowSeconds: nowSeconds))?.words;

/// The extensions a certificate carries for someone with [switches] in the
/// Crate: a terminal always, forwarding only with the Crate's switches for
/// it, so the hosts hold to them too.
Map<String, Uint8List> certExtensions(Set<String> switches) => {
      'permit-pty': Uint8List(0),
      'permit-user-rc': Uint8List(0),
      if (switches.contains(CrateSwitches.forward)) 'permit-port-forwarding': Uint8List(0),
      if (switches.contains(CrateSwitches.agent)) 'permit-agent-forwarding': Uint8List(0),
    };

/// The SSH wire form of the Ed25519 public key [raw] (32 bytes).
Uint8List ed25519PublicBlob(List<int> raw) =>
    Uint8List.fromList([..._lp(utf8.encode('ssh-ed25519')), ..._lp(raw)]);

/// A certificate for [request]'s key, signed by the authority [ca] (its
/// Ed25519 key pair): user names [principals], [extensions], lasting
/// [ttlMinutes] from [nowSeconds] (starting a few minutes before), named
/// [keyId] in the hosts' logs.
Uint8List issueTeamCertificate({
  required SSHKeyPair ca,
  required CertRequest request,
  required List<String> principals,
  required Map<String, Uint8List> extensions,
  required int ttlMinutes,
  required int nowSeconds,
  required String keyId,
  int? notAfter,
}) {
  DateTime at(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  // No longer than the access it rests on lasts by itself ([notAfter]: the
  // member's end date, or the time a Crate was given until).
  final ends = nowSeconds + ttlMinutes * 60;
  return SshCertSigner.issue(
    params: SshCertIssueParams(
      subjectPublicKeyBlob: ed25519PublicBlob(request.sshPublicKey),
      subjectAlgorithm: SshCertAlgorithm.ed25519,
      serial: randomCertSerial(),
      type: SshCertType.user,
      keyId: keyId,
      principals: principals,
      validAfter: at(nowSeconds - kCertBackdateSeconds),
      validBefore: at(notAfter != null && notAfter < ends ? notAfter : ends),
      extensions: extensions,
    ),
    caKey: ca,
  );
}

/// A random 63-bit serial.
int randomCertSerial([Random? random]) {
  final r = random ?? Random.secure();
  return (r.nextInt(1 << 31) << 32) | r.nextInt(1 << 32);
}

/// [blob] as a user certificate signed by the Ed25519 authority [caPublicKey]
/// for the Ed25519 key [subject] (both 32 bytes), or null when it is anything
/// else: another authority's, another key's, a host certificate, not
/// Ed25519, or a signature that does not check.
Future<SshCertificate?> readTeamCertificate(
  Uint8List blob, {
  required List<int> caPublicKey,
  required List<int> subject,
}) async {
  final SshCertificate cert;
  try {
    cert = SshCertificate.parse(blob);
  } on FormatException {
    return null;
  } catch (_) {
    return null;
  }
  if (cert.algorithm != SshCertAlgorithm.ed25519 || cert.type != SshCertType.user) return null;
  if (!_eq(cert.keyParts, _lp(subject))) return null;
  if (!_eq(cert.signatureKey, ed25519PublicBlob(caPublicKey))) return null;
  final Uint8List sig;
  try {
    final r = SshWireReader(cert.signature);
    if (r.readUtf8String(maxLength: 64) != 'ssh-ed25519') return null;
    sig = r.readString(maxLength: 128);
    if (!r.isExhausted || sig.length != 64) return null;
  } on FormatException {
    return null;
  }
  try {
    final ok = await _ed25519.verify(
      cert.toBeSigned,
      signature: Signature(sig, publicKey: SimplePublicKey(caPublicKey, type: KeyPairType.ed25519)),
    );
    return ok ? cert : null;
  } catch (_) {
    return null;
  }
}

/// The Crates in [orchardId] whose authority needs a new key, from the
/// record's [entries]: since its current key was made, someone who could
/// open the Crate that keeps it stopped being able to (left, was suspended,
/// no longer reaches it) or recovered their account with new keys after
/// losing their devices. They may still hold the key, and hosts trust
/// whatever it signs until they stop trusting it: only a new key ends that.
Future<Set<String>> authoritiesNeedingNewKey(String orchardId, Iterable<RecordEntry> entries) async {
  final r = OrchardRecord(orchardId);
  final due = <String>{};
  for (final e in entries) {
    final holders = <String, Set<String>>{};
    final generations = <String, int>{};
    for (final c in r.crates.values) {
      final ca = c.ca;
      if (ca == null) continue;
      holders[c.id] = _holders(r, ca.keyCrate);
      generations[c.id] = ca.generation;
    }
    await r.append(e, trusted: true);
    for (final c in r.crates.values) {
      final ca = c.ca;
      if (ca == null) continue;
      if (generations[c.id] != ca.generation) {
        due.remove(c.id);
        continue;
      }
      final before = holders[c.id] ?? const <String>{};
      final after = _holders(r, ca.keyCrate);
      if (before.any((uid) => !after.contains(uid))) due.add(c.id);
      if (e.type == RecordTypes.memberRecover && before.contains(e.body['uid'])) due.add(c.id);
    }
  }
  return due;
}

/// Who can open [crateId] in [r] now.
Set<String> _holders(OrchardRecord r, String crateId) => {
      for (final m in r.members.values)
        if (r.switchesOf(m.uid, crateId).isNotEmpty) m.uid,
    };

/// The user names in [input] (separated by spaces or commas), sorted and
/// without repeats; null when one is not a user name a certificate can carry
/// ([kCaPrincipal]) or there are more than [kMaxCaPrincipals].
List<String>? parseCertUserNames(String input) {
  final names = {
    for (final n in input.split(RegExp(r'[\s,]+')))
      if (n.isNotEmpty) n,
  }.toList()
    ..sort();
  if (names.length > kMaxCaPrincipals || !names.every(kCaPrincipal.hasMatch)) return null;
  return names;
}

/// What a host runs, as root, to trust an authority whose key is [keyLine]
/// (`ssh-ed25519 <base64> <comment>`): the key goes into the file sshd's
/// TrustedUserCAKeys already names, or a new one ZestSSH's drop-in names
/// when there is none, so an authority the host already trusts keeps
/// working. [oldKeyLines] (earlier keys of the same authority) leave it.
/// Checks sshd's configuration before reloading, and says so when sshd does
/// not read /etc/ssh/sshd_config.d.
String certHostSetupScript({required String keyLine, List<String> oldKeyLines = const []}) {
  String quoted(String s) => "'${s.replaceAll("'", "'\\''")}'";
  final lines = <String>[
    'set -e',
    'KEY=${quoted(keyLine)}',
    "CUR=\$(sshd -T 2>/dev/null | awk 'tolower(\$1)==\"trustedusercakeys\" {print \$2}')",
    'if [ -n "\$CUR" ] && [ "\$CUR" != none ]; then',
    '  FILE="\$CUR"',
    'else',
    '  FILE=/etc/ssh/zestssh_user_ca.pub',
    '  mkdir -p /etc/ssh/sshd_config.d',
    '  echo "TrustedUserCAKeys \$FILE" > /etc/ssh/sshd_config.d/10-zestssh.conf',
    'fi',
    'touch "\$FILE"',
    'if [ -s "\$FILE" ] && [ "\$(tail -c1 "\$FILE" | wc -l)" -eq 0 ]; then echo >> "\$FILE"; fi',
    'grep -qxF "\$KEY" "\$FILE" || echo "\$KEY" >> "\$FILE"',
    for (final old in oldKeyLines) ...[
      'OLD=${quoted(old.trim().split(RegExp(r'\s+')).take(2).join(' '))}',
      'grep -vF "\$OLD" "\$FILE" > "\$FILE.new" || true',
      'mv "\$FILE.new" "\$FILE"',
    ],
    'chmod 644 "\$FILE"',
    'sshd -t',
    'sshd -T | grep -qix "trustedusercakeys \$FILE" || echo "sshd does not read /etc/ssh/sshd_config.d: add \\"TrustedUserCAKeys \$FILE\\" to /etc/ssh/sshd_config"',
    'systemctl reload ssh 2>/dev/null || systemctl reload sshd',
  ];
  return '${lines.join('\n')}\n';
}

/// The OpenSSH public key line of the Ed25519 key [raw], with [comment].
String ed25519KeyLine(List<int> raw, String comment) =>
    'ssh-ed25519 ${base64Encode(ed25519PublicBlob(raw))} $comment'.trim();

/// A device's own SSH key for an Orchard's certificates: Ed25519, made on
/// the device and never sent anywhere; only its public half is.
class TeamDeviceKey {
  TeamDeviceKey._(this.seed, this.publicKey);

  /// The 32-byte private seed.
  final Uint8List seed;

  /// The 32-byte public key.
  final Uint8List publicKey;

  static Future<TeamDeviceKey> generate() async {
    final pair = await _ed25519.newKeyPair();
    final seed = Uint8List.fromList(await pair.extractPrivateKeyBytes());
    final public = Uint8List.fromList((await pair.extractPublicKey()).bytes);
    return TeamDeviceKey._(seed, public);
  }

  /// The key from [seed], its public half worked out again (so a stored key
  /// cannot pair a seed with someone else's public key).
  static Future<TeamDeviceKey> fromSeed(List<int> seed) async {
    if (seed.length != 32) throw const FormatException('Not an Ed25519 seed');
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    final public = Uint8List.fromList((await pair.extractPublicKey()).bytes);
    return TeamDeviceKey._(Uint8List.fromList(seed), public);
  }

  /// As an SSH key pair, for connecting.
  SSHKeyPair get keyPair =>
      OpenSSHEd25519KeyPair(publicKey, Uint8List.fromList([...seed, ...publicKey]), 'zestssh team device key');
}

/// An Ed25519 key pair from its 32-byte [seed]: an authority's key as its
/// key Crate keeps it.
Future<SSHKeyPair> ed25519KeyPairFromSeed(List<int> seed, {String comment = ''}) async {
  final key = await TeamDeviceKey.fromSeed(seed);
  return OpenSSHEd25519KeyPair(key.publicKey, Uint8List.fromList([...key.seed, ...key.publicKey]), comment);
}

/// Length-prefixed (uint32 big-endian), so fields never run together.
List<int> _lp(List<int> bytes) => [..._u32(bytes.length), ...bytes];

List<int> _u32(int value) => [(value >> 24) & 0xff, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff];

List<int> _u64(int value) => [..._u32((value >> 32) & 0xffffffff), ..._u32(value & 0xffffffff)];

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
