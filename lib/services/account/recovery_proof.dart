import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

// The recovery proof (the two-step contract, sections 6.5 and 7.4): proof of
// the sync password that reveals nothing of it. An account that lost every
// second step and every recovery code can be recovered after seven days;
// with this proof it keeps its synced data, without it the account is reset.
//
// The key: an Ed25519 key made from the sync password's key, the MEK the
// sync unlock derives (SyncService.deriveKey: Argon2id of the sync password
// with the account's own salt and settings). Its 32-byte seed is
// HKDF-SHA256 of the MEK, with no salt and the info `zestssh recovery proof
// v1`. The same password, salt and settings give the same key on every
// device, at an unlock and at a recovery, and the key tells nothing of the
// MEK: the MEK's other use (the verification hash a push sends, HKDF info
// `zestssh-sync-verification`) is independent of it, and nothing else is
// made with this label.
//
// At unlock the app registers its public half with ZestSSH Cloud, signing
// the register message with it and proving the sync password as a push does
// (password_hash). At a recovery the person types the sync password, the
// app derives the same key from the salt and settings the server hands out,
// and signs the server's challenge. Nothing here ever blocks an unlock: a
// registration that cannot be made is let be, and made at a later one.

/// The label the key is made under and every message starts with.
const kRecoveryProofLabel = 'zestssh recovery proof v1';

/// What a recovery proof signs (ZestSSH Cloud's lib/lockout_recovery.js
/// proofMessage): the label, what for ('register' or 'recover'), the
/// account's Firebase id, and the value: the public key (base64url) to
/// register it, the server's challenge as it gave it to recover.
List<int> recoveryProofMessage(String purpose, String firebaseUid, String value) =>
    utf8.encode('$kRecoveryProofLabel\n$purpose\n$firebaseUid\n$value');

/// [bytes] as base64url without padding, as ZestSSH Cloud reads them.
String b64uOf(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// The account's recovery proof key, from the sync password's key [mek].
Future<SimpleKeyPair> recoveryProofKey(SecretKey mek) async {
  final seed = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(await mek.extractBytes()),
    nonce: const <int>[],
    info: utf8.encode(kRecoveryProofLabel),
  );
  return Ed25519().newKeyPairFromSeed(await seed.extractBytes());
}

/// What registering the proof of [mek] for the account [firebaseUid] sends:
/// the public key and its signature of the register message (base64url),
/// and the verification hash a sync push sends as password_hash (standard
/// base64 of 32 bytes), which proves the sync password to ZestSSH Cloud.
Future<({String publicKey, String signature, String passwordHash})> recoveryProofRegistration(
    SecretKey mek, String firebaseUid) async {
  final key = await recoveryProofKey(mek);
  final publicKey = b64uOf((await key.extractPublicKey()).bytes);
  final signature = await Ed25519().sign(recoveryProofMessage('register', firebaseUid, publicKey), keyPair: key);
  return (
    publicKey: publicKey,
    signature: b64uOf(signature.bytes),
    passwordHash: base64Encode(await SyncService.computeVerificationHash(mek)),
  );
}

/// The proof that completes a recovery of [firebaseUid] keeping its data:
/// the signature of the server's [challenge] by the key of [mek]
/// (base64url).
Future<String> signRecoveryProof(SecretKey mek, String firebaseUid, String challenge) async {
  final key = await recoveryProofKey(mek);
  final signature = await Ed25519().sign(recoveryProofMessage('recover', firebaseUid, challenge), keyPair: key);
  return b64uOf(signature.bytes);
}

/// Registers the account's recovery proof whenever this device holds a
/// verified sync key: at the sync unlock, after setting sync up or joining
/// it, after the sync password changed. Only for sync on ZestSSH Cloud (the
/// data a proof keeps is there), quietly, and once per key in a run.
class RecoveryProofService {
  RecoveryProofService({
    required this.api,
    required this.accountUid,
    required this.hosted,
    this.remember,
  });

  final TwoStepApi Function() api;

  /// The signed-in account's Firebase id, or null.
  final Future<String?> Function() accountUid;

  /// Whether sync goes to ZestSSH Cloud.
  final bool Function() hosted;

  /// Keeps on this device which account it registered a proof for, so a
  /// recovery completed here can sign for it.
  final Future<void> Function(String firebaseUid)? remember;

  /// The public key registered in this run, by account.
  final _sent = <String, String>{};

  /// Registers the proof of [mek]. Never throws, never waits on anything
  /// the caller needs.
  Future<void> register(SecretKey mek) async {
    try {
      if (!hosted()) return;
      final uid = await accountUid();
      if (uid == null || uid.isEmpty || uid == 'desktop-session') return;
      final proof = await recoveryProofRegistration(mek, uid);
      if (_sent[uid] == proof.publicKey) return;
      final changed = await api().registerRecoveryProof(
        publicKey: proof.publicKey,
        signature: proof.signature,
        passwordHash: proof.passwordHash,
      );
      _sent[uid] = proof.publicKey;
      await remember?.call(uid);
      AppLogger.info('Recovery proof: ${changed ? 'registered' : 'already registered'}');
    } on TwoStepRefusal catch (e) {
      // recovery-proof-no-data: nothing is synced yet, so a proof has
      // nothing to keep (it is registered at an unlock after the first
      // sync). verification-failed: this is not the password the synced
      // data is locked with now (it changed elsewhere). Either way, later.
      AppLogger.info('Recovery proof: not registered (${e.code ?? 'HTTP ${e.status}'})');
    } catch (e) {
      AppLogger.info('Recovery proof: not registered (${errorKind(e)})');
    }
  }
}
