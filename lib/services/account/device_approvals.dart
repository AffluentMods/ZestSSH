import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/teams/crypto/fingerprint_words.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/type_name.dart';

/// Approving a new device from one you already use (3.0):
/// the new device gets the account's sync key without anyone typing the
/// sync password, and ZestSSH Cloud, which relays every step, never can open
/// it (ZestSSH Cloud's routes/device_approvals.js).
///
/// 1. The new device makes a one-time X25519 key pair and a random nonce and
///    sends only a commitment to them, with its name.
/// 2. A device that already holds the key reads the commitment and answers
///    with its own one-time key and nonce.
/// 3. The new device reveals its key and nonce; the approving device checks
///    them against the commitment it read before answering.
/// 4. Both show the same three words, worked out from the commitment and
///    both devices' keys and nonces. Because the new device committed first
///    and the approving device answered before the reveal, a server playing
///    both sides gets one guess at making the words match: 1 in 2^33.
/// 5. The person approves on the device that holds the key; the sync key is
///    sealed to the new device's one-time key, sent through the server, and
///    collected once.

/// The label every commitment starts with.
const kDeviceApprovalLabel = 'zestssh-device-approval-v1';

const _wordsLabel = 'zestssh-device-approval-words-v1';
const _sealLabel = 'zestssh-device-approval-seal-v1';

/// How many words both screens show (one guess, 33 bits).
const kDeviceApprovalWordCount = 3;

final _x25519 = X25519();
final _aes = AesGcm.with256bits();
final _random = Random.secure();

Uint8List _randomBytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));

/// SHA-256 of the label, then [publicKey] (32 bytes), then [nonce] (32
/// bytes): what the new device sends first. The server checks the reveal
/// against it with the same bytes (lib/device_approvals.js matchesCommitment).
Uint8List approvalCommitment(List<int> publicKey, List<int> nonce) =>
    Uint8List.fromList(crypto.sha256.convert([...utf8.encode(kDeviceApprovalLabel), ...publicKey, ...nonce]).bytes);

/// The words both devices show: SHA-256 of their label, the commitment, the
/// approving device's key and nonce, then the new device's, read as
/// [kDeviceApprovalWordCount] words of the fingerprint list.
List<String> approvalWords({
  required List<int> commitment,
  required List<int> approverKey,
  required List<int> approverNonce,
  required List<int> newKey,
  required List<int> newNonce,
}) {
  final digest = crypto.sha256.convert([
    ...utf8.encode(_wordsLabel),
    ...commitment,
    ...approverKey,
    ...approverNonce,
    ...newKey,
    ...newNonce,
  ]);
  return fingerprintWords(digest.bytes, count: kDeviceApprovalWordCount);
}

/// base64url without padding, the one spelling the server accepts.
String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// [text] as base64url without padding, or null when it is anything else.
/// Bytes kept as standard base64 (the sync salt on this device), or as
/// base64url; null when neither.
Uint8List? fromB64urlOrStandard(String? text) {
  if (text == null || text.isEmpty) return null;
  try {
    return base64Decode(text);
  } on FormatException {
    return fromB64url(text);
  }
}

Uint8List? fromB64url(Object? text) {
  if (text is! String || !RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(text)) return null;
  try {
    final padded = text.padRight((text.length + 3) & ~3, '=');
    final bytes = base64Url.decode(padded);
    return b64url(bytes) == text ? Uint8List.fromList(bytes) : null;
  } on FormatException {
    return null;
  }
}

/// The AES-256 key both sides derive for request [requestId]: HKDF-SHA256
/// over the X25519 secret of [mine] and [theirs], salted with the
/// commitment, naming the request and both one-time keys.
Future<SecretKey> _sealKey({
  required SimpleKeyPair mine,
  required List<int> theirs,
  required List<int> commitment,
  required String requestId,
  required List<int> approverKey,
  required List<int> newKey,
}) async {
  final shared = await _x25519.sharedSecretKey(
    keyPair: mine,
    remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
  );
  final secret = await shared.extractBytes();
  // A key of low order gives an all-zero secret: refuse it.
  if (secret.every((b) => b == 0)) throw const DeviceApprovalException(0, 'bad-key');
  return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(secret),
    nonce: commitment,
    info: [...utf8.encode(_sealLabel), ...utf8.encode(requestId), ...approverKey, ...newKey],
  );
}

List<int> _aad(String requestId) => utf8.encode('$kDeviceApprovalLabel:$requestId');

/// The new device's side of opening what the approving device sealed: its
/// one-time [keys] and public [newKey], the approving device's key.
Future<Uint8List> _openHandover({
  required SimpleKeyPair keys,
  required List<int> newKey,
  required List<int> approverKey,
  required List<int> commitment,
  required String requestId,
  required List<int> sealed,
}) async {
  final key = await _sealKey(
    mine: keys,
    theirs: approverKey,
    commitment: commitment,
    requestId: requestId,
    approverKey: approverKey,
    newKey: newKey,
  );
  return _open(key, requestId, sealed);
}

/// The seal key as a device with the one-time private key [seed] derives
/// it: for the known-answer test only.
@visibleForTesting
Future<List<int>> approvalSealKeyForTest({
  required List<int> seed,
  required List<int> theirs,
  required List<int> commitment,
  required String requestId,
  required List<int> approverKey,
  required List<int> newKey,
}) async {
  final key = await _sealKey(
    mine: await _x25519.newKeyPairFromSeed(seed),
    theirs: theirs,
    commitment: commitment,
    requestId: requestId,
    approverKey: approverKey,
    newKey: newKey,
  );
  return key.extractBytes();
}

/// What a new device with the one-time private key [newSeed] opens, by the
/// same steps as [ApprovalAsk.awaitHandover]: for the known-answer test only.
@visibleForTesting
Future<Uint8List> openHandoverForTest({
  required List<int> newSeed,
  required List<int> approverKey,
  required List<int> commitment,
  required String requestId,
  required List<int> sealed,
}) async {
  final keys = await _x25519.newKeyPairFromSeed(newSeed);
  return _openHandover(
    keys: keys,
    newKey: (await keys.extractPublicKey()).bytes,
    approverKey: approverKey,
    commitment: commitment,
    requestId: requestId,
    sealed: sealed,
  );
}

/// [plain] sealed for request [requestId]: nonce (12), tag (16), then the
/// ciphertext, AES-256-GCM.
Future<Uint8List> _seal(SecretKey key, String requestId, List<int> plain) async {
  final box = await _aes.encrypt(plain, secretKey: key, aad: _aad(requestId));
  return Uint8List.fromList([...box.nonce, ...box.mac.bytes, ...box.cipherText]);
}

Future<Uint8List> _open(SecretKey key, String requestId, List<int> sealed) async {
  if (sealed.length < 29) throw const DeviceApprovalException(0, 'bad-seal');
  try {
    final plain = await _aes.decrypt(
      SecretBox(sealed.sublist(28), nonce: sealed.sublist(0, 12), mac: Mac(sealed.sublist(12, 28))),
      secretKey: key,
      aad: _aad(requestId),
    );
    return Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    throw const DeviceApprovalException(0, 'bad-seal');
  }
}

// ── What is handed over ─────────────────────────────────────────────────

/// What the approving device hands the new one: the account's sync key and
/// what goes with it, exactly what typing the sync password would give the
/// new device (the data key, the push check, the key derivation's settings
/// and salt).
class SyncHandover {
  const SyncHandover({
    required this.dek,
    required this.verificationHash,
    required this.argon2Params,
    required this.salt,
  });

  final Uint8List dek;
  final Uint8List verificationHash;
  final Map<String, dynamic> argon2Params;
  final Uint8List salt;

  List<int> toBytes() => utf8.encode(jsonEncode({
        'v': 1,
        'dek': b64url(dek),
        'verification_hash': b64url(verificationHash),
        'argon2_params': argon2Params,
        'salt': b64url(salt),
      }));

  /// Throws [DeviceApprovalException] ('bad-seal') for anything that is not
  /// a handover of this version.
  static SyncHandover fromBytes(List<int> bytes) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      json = null;
    }
    if (json is! Map<String, dynamic> || json['v'] != 1) throw const DeviceApprovalException(0, 'bad-seal');
    final dek = fromB64url(json['dek']);
    final hash = fromB64url(json['verification_hash']);
    final salt = fromB64url(json['salt']);
    final params = json['argon2_params'];
    if (dek == null || dek.length != 32 || hash == null || hash.isEmpty || salt == null || salt.isEmpty ||
        params is! Map<String, dynamic>) {
      throw const DeviceApprovalException(0, 'bad-seal');
    }
    return SyncHandover(dek: dek, verificationHash: hash, argon2Params: params, salt: salt);
  }
}

// ── The server ──────────────────────────────────────────────────────────

/// An answer from the approval endpoints that is not a success.
class DeviceApprovalException implements Exception, HasTypeName {
  const DeviceApprovalException(this.status, [this.code]);

  final int status;
  final String? code;

  /// The request lapsed, was cancelled or collected, or is not this
  /// account's: it is over.
  bool get ended => status == 404;

  /// The server wants a sign-in from the last few minutes first.
  bool get needsRecentSignIn => code == 'recent-sign-in-required';

  /// The new device's reveal did not match its commitment (the request
  /// ended), or this device found the same.
  bool get mismatch => code == 'commitment-mismatch';

  /// This device already has an open request.
  bool get busy => code == 'busy';

  @override
  String toString() => 'Device approval: HTTP $status ${code ?? ''}'.trim();

  @override
  String get typeName => 'DeviceApprovalException';
}

/// A request as a device reads it.
class DeviceApprovalRequest {
  const DeviceApprovalRequest({
    required this.id,
    required this.role,
    required this.stage,
    required this.name,
    required this.expiresIn,
    this.commitment,
    this.approverKey,
    this.approverNonce,
    this.newKey,
    this.newNonce,
  });

  static DeviceApprovalRequest? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final id = json['id'];
    final role = json['role'];
    final stage = json['stage'];
    if (id is! String || role is! String || stage is! String) return null;
    final name = json['name'];
    final expires = json['expires_in'];
    return DeviceApprovalRequest(
      id: id,
      role: role,
      stage: stage,
      name: name is String ? name : '',
      expiresIn: expires is int ? expires : 0,
      commitment: fromB64url(json['commitment']),
      approverKey: fromB64url(json['approver_public_key']),
      approverNonce: fromB64url(json['approver_nonce']),
      newKey: fromB64url(json['new_public_key']),
      newNonce: fromB64url(json['new_nonce']),
    );
  }

  final String id;

  /// 'new' (this device asked), 'approver' (this device answered) or 'open'
  /// (another device asks; nobody answered yet).
  final String role;

  /// 'created', 'responded', 'revealed' or 'sealed'.
  final String stage;

  /// The name the new device gave itself. Nothing checks it: it names the
  /// request, and proves nothing.
  final String name;

  /// Seconds until it lapses.
  final int expiresIn;

  final Uint8List? commitment;
  final Uint8List? approverKey;
  final Uint8List? approverNonce;
  final Uint8List? newKey;
  final Uint8List? newNonce;
}

/// ZestSSH Cloud's approval endpoints, with the account's own sign-in.
class DeviceApprovalsApi {
  DeviceApprovalsApi({
    http.Client? client,
    String? baseUrl,
    required this.bearer,
    Map<String, String> Function()? sessionHeaders,
  })  : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? _defaultBase,
        _sessionHeaders = sessionHeaders ?? (() => DeviceSessionHeader.headers);

  static String get _defaultBase => kZestApiBase;

  static const _timeout = Duration(seconds: 30);

  final http.Client _client;
  final String _base;

  /// The account's bearer (the Firebase ID token, else the session token).
  final Future<String?> Function() bearer;

  /// This device's registration, for a device signed in with Firebase.
  final Map<String, String> Function() _sessionHeaders;

  Uri _uri([String path = '']) => Uri.parse('$_base/account/device-approvals$path');

  Future<Map<String, dynamic>> _call(String method, String path, [Map<String, Object?>? body]) async {
    final token = await bearer();
    if (token == null) throw const DeviceApprovalException(401, 'signed-out');
    final request = http.Request(method, _uri(path))
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        ..._sessionHeaders(),
        if (body != null) 'Content-Type': 'application/json',
      });
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await _client.send(request).timeout(_timeout));
    reportIfSessionRevoked(response);
    Map<String, dynamic> decoded;
    try {
      final d = jsonDecode(response.body);
      decoded = d is Map<String, dynamic> ? d : const {};
    } catch (_) {
      decoded = const {};
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      final code = decoded['code'];
      throw DeviceApprovalException(response.statusCode, code is String ? code : null);
    }
    return decoded;
  }

  /// Asks, as the new device. Replaces this device's open request.
  Future<DeviceApprovalRequest> create({required List<int> commitment, required String name}) async {
    final r = DeviceApprovalRequest.fromJson(
        await _call('POST', '', {'commitment': b64url(commitment), 'name': name}));
    if (r == null) throw const DeviceApprovalException(0, 'bad-answer');
    return r;
  }

  /// The requests this device takes part in, and those it could answer.
  Future<List<DeviceApprovalRequest>> list() async {
    final requests = (await _call('GET', ''))['requests'];
    return [
      for (final r in requests is List ? requests : const [])
        ?DeviceApprovalRequest.fromJson(r),
    ];
  }

  Future<DeviceApprovalRequest> get(String id) async {
    final r = DeviceApprovalRequest.fromJson(await _call('GET', '/${Uri.encodeComponent(id)}'));
    if (r == null) throw const DeviceApprovalException(0, 'bad-answer');
    return r;
  }

  // The steps below answer with a map nobody reads; each is awaited so the
  // Future really is a Future<void> (a catchError handler on it may return
  // nothing).

  Future<void> respond(String id, {required List<int> publicKey, required List<int> nonce}) async {
    await _call('POST', '/${Uri.encodeComponent(id)}/respond', {'public_key': b64url(publicKey), 'nonce': b64url(nonce)});
  }

  Future<void> reveal(String id, {required List<int> publicKey, required List<int> nonce}) async {
    await _call('POST', '/${Uri.encodeComponent(id)}/reveal', {'public_key': b64url(publicKey), 'nonce': b64url(nonce)});
  }

  Future<void> seal(String id, List<int> sealed) async {
    await _call('POST', '/${Uri.encodeComponent(id)}/seal', {'sealed': b64url(sealed)});
  }

  /// The sealed key, once; collecting it ends the request.
  Future<Uint8List> receive(String id) async {
    final sealed = fromB64url((await _call('POST', '/${Uri.encodeComponent(id)}/receive'))['sealed']);
    if (sealed == null || sealed.isEmpty) throw const DeviceApprovalException(0, 'bad-answer');
    return sealed;
  }

  /// Ends the request, from either side.
  Future<void> cancel(String id) async {
    await _call('DELETE', '/${Uri.encodeComponent(id)}');
  }
}

// ── The two sides ───────────────────────────────────────────────────────

/// How often a side looks for the other's step.
const kDeviceApprovalPoll = Duration(seconds: 2);

/// The new device's side.
class ApprovalAsk {
  ApprovalAsk._(this.api, this.request, this._keys, this._publicKey, this._nonce, this.commitment);

  final DeviceApprovalsApi api;
  final DeviceApprovalRequest request;
  final SimpleKeyPair _keys;
  final List<int> _publicKey;
  final Uint8List _nonce;
  final Uint8List commitment;
  List<int>? _approverKey;

  String get id => request.id;

  /// Makes this device's one-time key and nonce and asks with the
  /// commitment to them, under [name].
  static Future<ApprovalAsk> start(DeviceApprovalsApi api, {required String name}) async {
    final keys = await _x25519.newKeyPair();
    final publicKey = (await keys.extractPublicKey()).bytes;
    final nonce = _randomBytes(32);
    final commitment = approvalCommitment(publicKey, nonce);
    final request = await api.create(commitment: commitment, name: name);
    return ApprovalAsk._(api, request, keys, publicKey, nonce, commitment);
  }

  /// Waits for another device to answer, reveals this device's key and
  /// nonce, and returns the words both screens show. Throws
  /// [DeviceApprovalException] (ended) when the request is over first.
  Future<List<String>> awaitApprover({Future<void> Function(Duration)? wait}) async {
    final sleep = wait ?? Future<void>.delayed;
    while (true) {
      final r = await api.get(id);
      final key = r.approverKey;
      final nonce = r.approverNonce;
      if (key != null && nonce != null && key.length == 32 && nonce.length == 32) {
        await api.reveal(id, publicKey: _publicKey, nonce: _nonce);
        _approverKey = key;
        return approvalWords(
          commitment: commitment,
          approverKey: key,
          approverNonce: nonce,
          newKey: _publicKey,
          newNonce: _nonce,
        );
      }
      await sleep(kDeviceApprovalPoll);
    }
  }

  /// Waits for the approving device to send the key, collects it and opens
  /// it. Throws [DeviceApprovalException] when the request is over first or
  /// what arrives does not open.
  Future<SyncHandover> awaitHandover({Future<void> Function(Duration)? wait}) async {
    final approverKey = _approverKey;
    if (approverKey == null) throw StateError('awaitApprover first');
    final sleep = wait ?? Future<void>.delayed;
    while ((await api.get(id)).stage != 'sealed') {
      await sleep(kDeviceApprovalPoll);
    }
    final sealed = await api.receive(id);
    return SyncHandover.fromBytes(await _openHandover(
      keys: _keys,
      newKey: _publicKey,
      approverKey: approverKey,
      commitment: commitment,
      requestId: id,
      sealed: sealed,
    ));
  }

  /// Ends the request.
  Future<void> cancel() => api.cancel(id);
}

/// The approving device's side.
class ApprovalGive {
  ApprovalGive._(this.api, this.request, this._keys, this._publicKey, this._nonce, this.commitment);

  final DeviceApprovalsApi api;

  /// The request as it was read before answering: its name and commitment.
  final DeviceApprovalRequest request;
  final SimpleKeyPair _keys;
  final List<int> _publicKey;
  final Uint8List _nonce;

  /// The commitment as it was read BEFORE this device answered: the reveal
  /// is checked against it, never against a later copy.
  final Uint8List commitment;
  Uint8List? _newKey;

  String get id => request.id;
  String get name => request.name;

  /// Reads request [id] and answers it with this device's one-time key and
  /// nonce. The server may want a recent sign-in first
  /// ([DeviceApprovalException.needsRecentSignIn]).
  static Future<ApprovalGive> answer(DeviceApprovalsApi api, String id) async {
    final request = await api.get(id);
    final commitment = request.commitment;
    if (commitment == null || commitment.length != 32) throw const DeviceApprovalException(0, 'bad-answer');
    final keys = await _x25519.newKeyPair();
    final publicKey = (await keys.extractPublicKey()).bytes;
    final nonce = _randomBytes(32);
    await api.respond(id, publicKey: publicKey, nonce: nonce);
    return ApprovalGive._(api, request, keys, publicKey, nonce, commitment);
  }

  /// Waits for the new device's reveal, checks it against the commitment
  /// and returns the words both screens show. A reveal that does not match
  /// ends the request and throws ([DeviceApprovalException.mismatch]).
  Future<List<String>> awaitReveal({Future<void> Function(Duration)? wait}) async {
    final sleep = wait ?? Future<void>.delayed;
    while (true) {
      final r = await api.get(id);
      final key = r.newKey;
      final nonce = r.newNonce;
      if (key != null && nonce != null) {
        if (key.length != 32 || nonce.length != 32 || !_same(approvalCommitment(key, nonce), commitment)) {
          try {
            await api.cancel(id);
          } catch (_) {/* ended either way */}
          throw const DeviceApprovalException(409, 'commitment-mismatch');
        }
        _newKey = key;
        return approvalWords(
          commitment: commitment,
          approverKey: _publicKey,
          approverNonce: _nonce,
          newKey: key,
          newNonce: nonce,
        );
      }
      await sleep(kDeviceApprovalPoll);
    }
  }

  /// The person saw the same words on both screens: seals [handover] to the
  /// new device's one-time key and sends it.
  Future<void> send(SyncHandover handover) async {
    final newKey = _newKey;
    if (newKey == null) throw StateError('awaitReveal first');
    final key = await _sealKey(
      mine: _keys,
      theirs: newKey,
      commitment: commitment,
      requestId: id,
      approverKey: _publicKey,
      newKey: newKey,
    );
    await api.seal(id, await _seal(key, id, handover.toBytes()));
  }

  /// Says no: ends the request.
  Future<void> refuse() => api.cancel(id);
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
