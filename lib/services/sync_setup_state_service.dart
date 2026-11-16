import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/utils/logger.dart';

/// Discrete steps a user passes through when setting up cloud sync.
///
/// The setup flow MUST land in [SyncSetupStep.complete] before sync is
/// considered active. Any intermediate state means the user abandoned
/// (or crashed) mid-setup, in which case the next launch resumes from
/// the last persisted step rather than silently dropping the user into
/// a half-configured state.
enum SyncSetupStep {
  /// User has not started sync setup.
  notStarted,

  /// User signed in but has not yet entered a master password.
  signedIn,

  /// Master password chosen and salt persisted; recovery key generated
  /// but NOT yet acknowledged by the user.
  passwordChosen,

  /// User has copied / printed / downloaded the recovery key.
  recoverySaved,

  /// User has passed the recovery-key challenge confirmation.
  recoveryConfirmed,

  /// First push to the server succeeded; sync is fully active.
  complete,
}

/// Persistent, crash-safe state machine for cloud sync first-time setup.
///
/// All intermediate state is stored in the OS-backed secure storage so
/// it survives app restarts, force-quits, and crashes. The user can
/// only "complete" setup by calling [markComplete] AFTER the recovery
/// key has been acknowledged AND the first encrypted blob has been
/// successfully pushed to the server. Until then [isSyncActive] returns
/// false and the UI must show the resume-setup banner.
///
/// Design rules:
/// 1. We never persist the master password.
/// 2. We never persist the recovery key.
/// 3. We persist only the salt (for resumption) and the current step.
/// 4. The "complete" flag is the ONLY thing that gates sync being on.
/// 5. Calling [reset] from any state nukes all setup state - used by
///    "I lost my key, restart setup" and after sign-out.
class SyncSetupStateService {
  final FlutterSecureStorage _storage;

  static const _kStep = 'sync_setup_step';
  static const _kStartedAt = 'sync_setup_started_at';
  static const _kSaltB64 = 'sync_setup_salt_b64';
  static const _kRecoverySaltB64 = 'sync_setup_recovery_salt_b64';
  static const _kComplete = 'sync_setup_complete'; // 'true' iff fully done
  static const _kVersion = 'sync_setup_state_version';
  static const _kSchemaVersion = '1';

  SyncSetupStateService(this._storage);

  /// Read the current setup step. Defaults to [SyncSetupStep.notStarted].
  Future<SyncSetupStep> currentStep() async {
    final raw = await _storage.read(key: _kStep);
    if (raw == null) return SyncSetupStep.notStarted;
    return SyncSetupStep.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => SyncSetupStep.notStarted,
    );
  }

  /// Whether sync is fully active. This is the ONLY source of truth the
  /// rest of the app should consult to decide whether to push/pull data.
  Future<bool> isSyncActive() async {
    final flag = await _storage.read(key: _kComplete);
    return flag == 'true';
  }

  /// Whether a setup flow is in progress (started but not yet complete).
  /// Used by the UI to show a "Resume sync setup" banner on launch.
  Future<bool> hasPendingSetup() async {
    final step = await currentStep();
    if (step == SyncSetupStep.notStarted) return false;
    final active = await isSyncActive();
    return !active;
  }

  /// Snapshot of all persisted state - useful for debug screens.
  Future<SyncSetupSnapshot> snapshot() async {
    return SyncSetupSnapshot(
      step: await currentStep(),
      startedAt: await _readStartedAt(),
      hasSalt: (await _storage.read(key: _kSaltB64)) != null,
      hasRecoverySalt: (await _storage.read(key: _kRecoverySaltB64)) != null,
      isComplete: await isSyncActive(),
    );
  }

  // ── Step transitions ─────────────────────────────────────────────

  /// Begin a new setup flow. Idempotent - calling twice keeps the
  /// existing started_at timestamp.
  Future<void> beginSetup() async {
    await _storage.write(key: _kVersion, value: _kSchemaVersion);
    final existing = await _readStartedAt();
    if (existing == null) {
      await _storage.write(
        key: _kStartedAt,
        value: DateTime.now().toUtc().toIso8601String(),
      );
    }
    await _writeStep(SyncSetupStep.signedIn);
  }

  /// Persist the salt the user's master password was bound to and
  /// advance to [SyncSetupStep.passwordChosen]. The password itself is
  /// NEVER persisted.
  Future<void> markPasswordChosen({required List<int> salt}) async {
    final step = await currentStep();
    if (step != SyncSetupStep.signedIn) {
      throw StateError(
        'markPasswordChosen called from invalid step: $step. '
        'Expected signedIn.',
      );
    }
    await _storage.write(key: _kSaltB64, value: base64Encode(salt));
    await _writeStep(SyncSetupStep.passwordChosen);
  }

  /// Persist the recovery salt and advance to [SyncSetupStep.recoverySaved].
  /// Called as soon as the recovery key has been displayed AND saved
  /// (copy / print / download), but BEFORE the challenge is passed.
  Future<void> markRecoverySaved({required List<int> recoverySalt}) async {
    final step = await currentStep();
    if (step != SyncSetupStep.passwordChosen) {
      throw StateError(
        'markRecoverySaved called from invalid step: $step. '
        'Expected passwordChosen.',
      );
    }
    await _storage.write(
      key: _kRecoverySaltB64,
      value: base64Encode(recoverySalt),
    );
    await _writeStep(SyncSetupStep.recoverySaved);
  }

  /// User passed the position-challenge confirming they actually wrote
  /// the recovery key down. Advance to [SyncSetupStep.recoveryConfirmed].
  Future<void> markRecoveryConfirmed() async {
    final step = await currentStep();
    if (step != SyncSetupStep.recoverySaved) {
      throw StateError(
        'markRecoveryConfirmed called from invalid step: $step. '
        'Expected recoverySaved.',
      );
    }
    await _writeStep(SyncSetupStep.recoveryConfirmed);
  }

  /// Atomically activate sync. This is the ONLY method that flips the
  /// `complete` flag. Callers MUST only invoke it after the first push
  /// has been ack'd by the server - otherwise on next launch the user
  /// would see "sync active" but the server has no blob.
  ///
  /// Throws [StateError] if the prior step is not [recoveryConfirmed].
  Future<void> markComplete() async {
    final step = await currentStep();
    if (step != SyncSetupStep.recoveryConfirmed) {
      throw StateError(
        'markComplete called from invalid step: $step. '
        'Recovery key must be confirmed before sync can be activated.',
      );
    }
    // Write complete flag FIRST so a crash between the two writes still
    // leaves us in a recoverable state.
    await _storage.write(key: _kComplete, value: 'true');
    await _writeStep(SyncSetupStep.complete);
    AppLogger.info('Cloud sync setup complete - sync is now active');
  }

  /// Activate sync when JOINING an existing server sync (a second device).
  ///
  /// Unlike [markComplete] (the CREATE path), a join does NOT mint a new
  /// password/recovery key - it verifies the existing master password
  /// against the server and pulls the existing DEK, so the recovery-key
  /// steps don't apply. Callers MUST only invoke this AFTER a successful
  /// verify + pull + decrypt + restore against the server blob. [salt] is
  /// the server's salt (so this device's future derivations match).
  Future<void> markCompleteViaJoin({required List<int> salt}) async {
    await _storage.write(key: _kVersion, value: _kSchemaVersion);
    await _storage.write(key: _kSaltB64, value: base64Encode(salt));
    await _storage.write(key: _kComplete, value: 'true');
    await _writeStep(SyncSetupStep.complete);
    AppLogger.info('Cloud sync joined an existing account - sync is now active');
  }

  /// Wipe all setup state. Called when the user signs out, restarts
  /// setup from scratch, or purges sync data. Safe to call from any
  /// state.
  Future<void> reset() async {
    await _storage.delete(key: _kStep);
    await _storage.delete(key: _kStartedAt);
    await _storage.delete(key: _kSaltB64);
    await _storage.delete(key: _kRecoverySaltB64);
    await _storage.delete(key: _kComplete);
    AppLogger.info('Cloud sync setup state reset');
  }

  /// Read the previously stored salt (for resuming an interrupted setup
  /// where the user already chose a password but the next step crashed).
  Future<List<int>?> readSalt() async {
    final raw = await _storage.read(key: _kSaltB64);
    if (raw == null) return null;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  /// Read the previously stored recovery salt.
  Future<List<int>?> readRecoverySalt() async {
    final raw = await _storage.read(key: _kRecoverySaltB64);
    if (raw == null) return null;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  // ── Internals ─────────────────────────────────────────────────────

  Future<void> _writeStep(SyncSetupStep step) async {
    await _storage.write(key: _kStep, value: step.name);
  }

  Future<DateTime?> _readStartedAt() async {
    final raw = await _storage.read(key: _kStartedAt);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }
}

/// Read-only snapshot of sync setup state.
class SyncSetupSnapshot {
  final SyncSetupStep step;
  final DateTime? startedAt;
  final bool hasSalt;
  final bool hasRecoverySalt;
  final bool isComplete;

  const SyncSetupSnapshot({
    required this.step,
    required this.startedAt,
    required this.hasSalt,
    required this.hasRecoverySalt,
    required this.isComplete,
  });

  bool get isInProgress => step != SyncSetupStep.notStarted && !isComplete;

  @override
  String toString() =>
      'SyncSetupSnapshot(step: $step, startedAt: $startedAt, '
      'hasSalt: $hasSalt, hasRecoverySalt: $hasRecoverySalt, '
      'isComplete: $isComplete)';
}
