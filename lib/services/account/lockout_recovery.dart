import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/services/account/recovery_proof.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/sync_service.dart';

// Lock-out recovery (the two-step contract, sections 6.5 and 7.5 to 7.6): a
// person who lost every second step and every recovery code asks, from the
// sign-in screen, to recover their account. ZestSSH Cloud emails a code for
// that ask alone (its ask id stays in memory, with the screen that asked);
// the code confirmed, the recovery waits seven days, and every signed-in
// device of the account shows it with "This wasn't me". Then it is
// completed: with the sync password proved (the recovery proof,
// lib/services/account/recovery_proof.dart) the account keeps its data;
// without it the account is reset. Nobody is signed in by any of it: two-step
// sign-in goes off, and the person signs in with the first step alone.
//
// The ticket that completes it is kept in secure storage until the recovery
// is done or cancelled, never in a log, and never shown, sealed while the
// encrypting lock is on: every screen that uses it is behind that lock (a
// person who lost their second steps still opens the app with its PIN). On a
// computer it stays in the profile open when it was asked for (guest data, for
// a person signed out), sealed by that profile's seal whatever the lock, like
// every other per-account secret; a sign-in screen has a profile open too.

/// A recovery this device asked for, waiting for its day.
class WaitingLockout {
  const WaitingLockout({
    required this.email,
    required this.ticket,
    required this.completesAt,
    this.proof,
  });

  factory WaitingLockout.fromJson(Map<String, dynamic> j) {
    final proof = j['proof'];
    return WaitingLockout(
      email: j['email'] as String,
      ticket: j['ticket'] as String,
      completesAt: DateTime.parse(j['completes_at'] as String).toLocal(),
      proof: proof is Map<String, dynamic> ? RecoveryProofAsk.fromJson(proof) : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'email': email,
        'ticket': ticket,
        'completes_at': completesAt.toUtc().toIso8601String(),
        if (proof != null) 'proof': proof!.toJson(),
      };

  /// The address it was asked for.
  final String email;

  /// What completes it.
  final String ticket;

  /// From when it can be completed.
  final DateTime completesAt;

  /// What proving the sync password needs, or null where only a reset is
  /// possible (no synced data, or no recovery proof registered).
  final RecoveryProofAsk? proof;

  /// Whether its day has come at [now].
  bool dueAt(DateTime now) => !now.isBefore(completesAt);

  @override
  String toString() => 'WaitingLockout(completes ${completesAt.toIso8601String()})';
}

/// Where the recovery this device waits for is kept, and which account a
/// recovery proof was registered for here (a recovery completed on this
/// device signs for that account).
class LockoutRecoveryStore {
  LockoutRecoveryStore(this._storage);

  static const accountsKey = 'recovery_proof_accounts_v1';

  final FlutterSecureStorage _storage;

  /// The recovery waiting here, or null. One sealed while the app is locked is
  /// read at the unlock: never taken for none, which would ask for it anew.
  Future<WaitingLockout?> read() async {
    try {
      final raw = await AccountSecret.lockoutRecovery.readOnceOpen(_storage);
      if (raw == null || raw.isEmpty) return null;
      final json = jsonDecode(raw);
      return json is Map<String, dynamic> ? WaitingLockout.fromJson(json) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(WaitingLockout waiting) => AccountSecret.lockoutRecovery.write(_storage, jsonEncode(waiting.toJson()));

  /// The recovery is done, cancelled or gone: its ticket goes.
  Future<void> clear() => AccountSecret.lockoutRecovery.delete(_storage);

  /// The Firebase id of the account at [email] this device registered a
  /// recovery proof for, or null.
  Future<String?> accountFor(String email) async {
    final all = await _accounts();
    return all[_key(email)];
  }

  /// Notes that this device registered a recovery proof for [email]'s
  /// account [firebaseUid]. Throws where what is kept could not be read (3.3.2:
  /// on a Mac, macOS did not let ZestSSH read it): writing then would put this
  /// one account over every other account noted.
  Future<void> rememberAccount(String email, String firebaseUid) async {
    if (email.trim().isEmpty || firebaseUid.isEmpty) return;
    final all = await _accounts(strict: true);
    if (all[_key(email)] == firebaseUid) return;
    all[_key(email)] = firebaseUid;
    await _storage.write(key: accountsKey, value: jsonEncode(all));
  }

  /// The accounts noted. One that cannot be read is none, but where [strict] a
  /// keychain that could not be read throws: what was not read is never taken for
  /// nothing by what writes after it.
  Future<Map<String, String>> _accounts({bool strict = false}) async {
    final String? raw;
    try {
      raw = await _storage.read(key: accountsKey);
    } catch (_) {
      if (strict) rethrow;
      return {};
    }
    try {
      final json = raw == null ? null : jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  static String _key(String email) => email.trim().toLowerCase();
}

/// The proof that completes [waiting] keeping the data, from the sync
/// [password]: the sync password's key derived with the salt and settings
/// ZestSSH Cloud handed out, exactly as the sync unlock derives it
/// (SyncService.deriveKey), and the server's challenge signed by its
/// recovery proof key for the account [firebaseUid]. Null where the
/// recovery cannot be proved (only a reset is left).
Future<String?> proveSyncPassword({
  required WaitingLockout waiting,
  required String password,
  required String firebaseUid,
}) async {
  final proof = waiting.proof;
  if (proof == null) return null;
  final mek = await SyncService.deriveKey(password, proof.salt, params: proof.argon2Params);
  return signRecoveryProof(mek, firebaseUid, proof.challenge);
}

/// What completes a recovery for: kept the data, or reset the account.
enum LockoutCompletion { withData, reset }
