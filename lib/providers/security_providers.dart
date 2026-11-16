import 'dart:async';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/away_for_sign_in.dart';
import 'package:zestssh/services/clipboard_manager.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/utils/secret_clipboard.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/providers/profile_providers.dart';

// ── App lock state ───────────────────────────────────────────────

/// Whether the app is currently locked and needs authentication.
final isAppLockedProvider =
    StateNotifierProvider<AppLockNotifier, bool>((ref) {
  return AppLockNotifier(ref);
});

/// Manages the app lock state, including auto-lock on background.
class AppLockNotifier extends StateNotifier<bool> {
  final Ref _ref;
  DateTime? _lastBackgrounded;

  AppLockNotifier(this._ref) : super(true) {
    // Start locked (safe default) - _init will unlock if security is disabled.
    _init();
  }

  Future<void> _init() async {
    final settings = _ref.read(settingsServiceProvider);
    if (!settings.securityLockEnabled) {
      state = false;
      return;
    }

    // If security is enabled, stay locked until user authenticates
    final lockService = _ref.read(securityLockServiceProvider);
    final method = await lockService.getLockMethod();
    if (method == SecurityLockMethod.none) {
      state = false;
    }
    // Otherwise remain locked (state is already true from constructor)
  }

  /// Mark the app as going to background.
  void onAppBackgrounded() {
    _lastBackgrounded = DateTime.now();
    AppLogger.info('App backgrounded');
  }

  /// Check if we should re-lock after returning from background.
  Future<void> onAppResumed() => _resumeCheck = _checkOnResume();

  Future<void>? _resumeCheck;

  /// Done once the check of the last return from the background is (the
  /// lock engaged or not): what is to happen only in an unlocked app as it
  /// is back (a terminal's keyboard up again) waits for it.
  Future<void> get resumeChecked => (_resumeCheck ?? Future<void>.value()).catchError((Object _) {});

  Future<void> _checkOnResume() async {
    final settings = _ref.read(settingsServiceProvider);
    if (!settings.securityLockEnabled) return;

    final lockService = _ref.read(securityLockServiceProvider);
    final timeoutMinutes = await lockService.getAutoLockTimeout();
    final method = await lockService.getLockMethod();

    if (method == SecurityLockMethod.none) return;

    if (_lastBackgrounded == null) return;

    if (timeoutMinutes < 0) return; // "Never" - stay unlocked until app exit.
    // Away for a sign-in this app opened: a code, a mail link, a company's page.
    if (AwayForSignIn.covers(_lastBackgrounded!, DateTime.now())) return;
    final elapsed = DateTime.now().difference(_lastBackgrounded!);
    if (timeoutMinutes == 0 || elapsed.inMinutes >= timeoutMinutes) {
      await lock(AppLockReason(AppLockCause.away, timeoutMinutes));
      AppLogger.info('App re-locked after ${elapsed.inSeconds}s');
    }
  }

  /// Unlock the app after successful authentication (UI-only lock: the
  /// encrypting lock is OFF, so the database is already open). For the
  /// encrypting lock, use [unlockVault] instead.
  void unlock() {
    state = false;
    _lastBackgrounded = null;
    AppLogger.info('App unlocked');
  }

  /// Unlock the ENCRYPTING lock (1.8 vault): unwrap the DB key with the supplied
  /// secret (any one of PIN / master password / recovery key), open the
  /// database session, then flip to unlocked. Throws [VaultLockedException] on a
  /// wrong secret and [Exception] on an open/migration failure - the caller
  /// (the lock screen) surfaces both and never flips the lock off.
  Future<void> unlockVault({
    String? pin,
    String? masterPassword,
    String? recoveryKey,
  }) async {
    final vault = _ref.read(vaultSlotServiceProvider);
    // Hardware layer on: fetch the Keystore/Secure-Enclave key first, which
    // shows the OS device-auth prompt. Cancelling it throws and the app stays
    // locked - by design, the hardware key is REQUIRED to decrypt.
    List<int>? hardwareKey;
    if (await vault.isHardwareBound()) {
      hardwareKey = await _ref.read(hardwareVaultServiceProvider).read();
    }
    if (Profiles.on) {
      final manager = ProfileManager.instance!;
      // The vault key stays in memory while the app is unlocked: making a
      // profile, opening one after a sign-in and opening guest data all need it.
      manager.vaultKey = await vault.unlockVaultKey(pin: pin, masterPassword: masterPassword, recoveryKey: recoveryKey);
      manager.hardwareKey = hardwareKey;
      final settingsBefore = manager.settingsOf;
      final AppDatabase db;
      try {
        db = await manager.openCurrent();
      } catch (e) {
        await DatabaseSessionNotifier.afterFailedOpen(e);
        await manager.locked();
        rethrow;
      }
      // The first open, or another profile than the one before the lock: what
      // was built for no one, or for someone else, is built again.
      if (manager.settingsOf != settingsBefore) {
        await TerminalThemes.loadCustomThemes(_ref.read(sharedPreferencesProvider));
        refreshPersonState(_ref.container);
      }
      _ref.read(databaseSessionProvider.notifier).seed(db);
      state = false;
      _lastBackgrounded = null;
      AppLogger.info('App unlocked (encrypting lock, DB opened)');
      return;
    }
    final dbKeyHex = await vault.unlockDbKeyHex(
      pin: pin,
      masterPassword: masterPassword,
      recoveryKey: recoveryKey,
      hardwareKey: hardwareKey,
    );
    // Opens + runs migrations; throws on failure BEFORE the session flips ready.
    await _ref.read(databaseSessionProvider.notifier).open(dbKeyHex);
    state = false;
    _lastBackgrounded = null;
    AppLogger.info('App unlocked (encrypting lock, DB opened)');
  }

  /// Turn ON hardware binding (mobile): generate a device-auth-gated key in the
  /// Keystore / Secure Enclave (this shows the OS auth prompt) and wrap the
  /// vault's DB-key blob under it. From then on, unlocking requires the PIN AND
  /// this device's hardware - an extracted storage image is useless off-device.
  Future<void> enableHardwareBinding() async {
    final hwKey =
        await _ref.read(hardwareVaultServiceProvider).generateAndStore();
    if (Profiles.on) {
      final manager = ProfileManager.instance!;
      await manager.vault.enableHardware(manager.list.withKeyHere, hwKey);
      manager.hardwareKey = hwKey;
    } else {
      await _ref.read(vaultSlotServiceProvider).enableHardwareLayer(hwKey);
    }
    AppLogger.warning('SECURITY: hardware binding ENABLED');
  }

  /// Turn OFF hardware binding: read the hardware key (device-auth prompt),
  /// restore the PIN-only wrap, then delete the hardware key.
  Future<void> disableHardwareBinding() async {
    final hw = _ref.read(hardwareVaultServiceProvider);
    final hwKey = await hw.read();
    if (Profiles.on) {
      final manager = ProfileManager.instance!;
      await manager.vault.disableHardware(manager.list.withKeyHere, hwKey);
      manager.hardwareKey = null;
    } else {
      await _ref.read(vaultSlotServiceProvider).disableHardwareLayer(hwKey);
    }
    await hw.delete();
    AppLogger.warning('SECURITY: hardware binding DISABLED');
  }

  /// Turn ON the encrypting lock: wrap the current DB key behind the PIN, delete
  /// the plaintext key, and persist the flags. PIN-ONLY by design - there is no
  /// separate recovery key. Recovery is your `.zest` backup (offline) or Cloud
  /// Sync (restore on a fresh install); forget the PIN with neither and the
  /// local data is gone. The database stays open for this session; it opens via
  /// the vault on the next launch / unlock.
  Future<void> enableEncryptingLock({required String pin}) async {
    if (Profiles.on) {
      // Every profile's wrapped copy first, then the slots, and only then the
      // plain keys go (ProfileVault.turnOn).
      final manager = ProfileManager.instance!;
      final keys = <String, String>{};
      for (final id in manager.list.withKeyHere) {
        keys[id] = await manager.keyHexOf(manager.list.byId(id)!);
      }
      manager.vaultKey = await manager.vault.turnOn(keys: keys, slots: _ref.read(vaultSlotServiceProvider), pin: pin);
      await manager.dropKeychainCopies();
    } else {
      final dbKeyHex = await AppDatabase.exportDbKeyHexForVault();
      await _ref.read(vaultSlotServiceProvider).enableLock(
            dbKeyHex: dbKeyHex,
            pin: pin,
          );
      // The database stays open: its key is behind the PIN alone now, and a
      // wipe in this run turns the lock off with it.
      _ref.read(databaseSessionProvider.notifier).lockTurnedOn(dbKeyHex);
    }
    // The PIN is checked against the vault from now on, and its cheaper hash
    // is not kept beside it (SecurityLockService.verifyPin).
    await _ref.read(securityLockServiceProvider).pinKeptByVault();
    final settings = _ref.read(settingsServiceProvider);
    await settings.setEncryptingLockEnabled(true);
    await settings.setSecurityLockEnabled(true);
    // The secrets in the system's storage (your keys' private keys and
    // passwords, sync's key, your account's keys, the Orchards' database keys)
    // sealed under a key kept in the database: with its key behind the PIN, so
    // are they (SecretSeal). They were left as they were.
    await sealSecretsAtRest(_ref.read(treeDatabaseProvider), _ref.read(secureStorageProvider));
    AppLogger.warning('SECURITY: encrypting app lock ENABLED (DB key wrapped)');
  }

  /// Turn OFF the encrypting lock: re-derive the DB key from [pin], restore it
  /// as the plaintext secure-storage key, and drop the vault. Requires the PIN
  /// so a stranger with an unlocked session can't silently strip the encryption.
  Future<void> disableEncryptingLock(String pin) async {
    final vault = _ref.read(vaultSlotServiceProvider);
    // Hardware layer on: unwrapping needs the Keystore/Secure-Enclave key
    // (device-auth prompt), and turning encryption off also removes it.
    final hardwareBound = await vault.isHardwareBound();
    List<int>? hardwareKey;
    if (hardwareBound) {
      hardwareKey = await _ref.read(hardwareVaultServiceProvider).read();
    }
    // The app lock's PIN first: once the vault is gone it is what the PIN is
    // checked against, so the app stopped in between still opens with it.
    if (Profiles.on) {
      // Every plain key first, then the vault (ProfileVault.turnOff).
      final manager = ProfileManager.instance!;
      final vaultKey = await vault.unlockVaultKey(pin: pin);
      await _ref.read(securityLockServiceProvider).keepPinForVaultOff(pin);
      await manager.vault.turnOff(profiles: manager.list.withKeyHere, vaultKey: vaultKey, hardwareKey: hardwareKey);
      manager.vaultKey = null;
      manager.hardwareKey = null;
    } else {
      final dbKeyHex = await vault.unlockDbKeyHex(pin: pin, hardwareKey: hardwareKey);
      await _ref.read(securityLockServiceProvider).keepPinForVaultOff(pin);
      await vault.disableLock(dbKeyHex);
      _ref.read(databaseSessionProvider.notifier).lockTurnedOff();
    }
    if (hardwareBound) {
      await _ref.read(hardwareVaultServiceProvider).delete();
    }
    // The app lock goes on asking for the PIN: with the vault gone, against
    // its hash again.
    await _ref.read(securityLockServiceProvider).setPin(pin);
    await _ref.read(settingsServiceProvider).setEncryptingLockEnabled(false);
    // A secret written from now on is kept as it was (the database's key is in
    // the same storage again), and so is every sealed one: a store that
    // cannot reach the database reads it again.
    final tree = _ref.read(databaseSessionProvider);
    if (tree != null) await unsealSecretsAtRest(tree, _ref.read(secureStorageProvider));
    AppLogger.warning('SECURITY: encrypting app lock DISABLED');
  }

  /// Lock the app now, for [why] (the lock screen says it): by its person unless said.
  Future<void> lock([AppLockReason why = AppLockReason.byYou]) { _noteWhy(why); return _engageLock(); }

  /// Shared lock teardown: clear the clipboard, drop the cached sync MEK, and -
  /// when the encrypting lock is on - CLOSE the database so data-at-rest is no
  /// longer decrypted while locked (this flips dbReady false and re-shows the
  /// unlock screen). Finally mark the app locked.
  Future<void> _engageLock() async {
    _ref.read(clipboardManagerProvider.notifier).clear();
    // A secret copied and still on the system's clipboard goes as well (only
    // the app's own history went).
    unawaited(SecretClipboard.clear());
    _ref.read(vaultSessionProvider.notifier).lock();
    if (_ref.read(settingsServiceProvider).encryptingLockEnabled) {
      // What is written waits for the unlock, and the keys in memory go.
      if (Profiles.on) await ProfileManager.instance?.locked();
      await _ref.read(databaseSessionProvider.notifier).close();
    }
    state = true;
  }

  // (Below the rest, so that no line docs/whitepaper/claims.yml cites moves.)

  /// Why the app last locked, for the line under the lock screen's title (4.0): since
  /// it started, until it is first unlocked.
  AppLockReason get why => _why;
  AppLockReason _why = AppLockReason.started;

  /// [why] is what the lock screen says. The first lock wins: one that comes while
  /// the app is locked already (the computer slept, and the return from the
  /// background then found it past its time) does not change what is said.
  void _noteWhy(AppLockReason why) {
    if (!state) _why = why;
  }
}

// ── Sync vault session (S2) ──────────────────────────────────────

/// Ephemeral in-memory cache of the derived sync **Master Encryption Key
/// (MEK)** so manual sync operations within a bounded window stop re-prompting
/// for the sync password.
///
/// SECURITY invariants:
/// - Holds only the DERIVED MEK, never the password itself.
/// - In-memory ONLY - never persisted. (The DEK that actually decrypts user
///   data is already at rest in OS secure storage for background sync, so this
///   RAM cache is not a new at-rest exposure.)
/// - A cached MEK is only ever REUSED behind the exact cryptographic
///   verification the prompt path performs (GCM DEK-unwrap / verifyPassword);
///   a stale or wrong-account key fails that check and falls back to a prompt.
/// - Cleared on: explicit lock, TTL expiry, app-lock engage/re-lock, sign-out,
///   account delete, sync disconnect / credential clear, and password change.
class VaultSessionState {
  const VaultSessionState({this.mek, this.expiresAt});

  /// The cached Master Encryption Key, or null when locked.
  final SecretKey? mek;

  /// Wall-clock instant the session expires, or null when locked.
  final DateTime? expiresAt;

  bool get isUnlocked =>
      mek != null && expiresAt != null && DateTime.now().isBefore(expiresAt!);

  /// Time left before auto-lock, clamped at zero; null when locked.
  Duration? get remaining {
    if (expiresAt == null) return null;
    final r = expiresAt!.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }
}

final vaultSessionProvider =
    StateNotifierProvider<VaultSessionNotifier, VaultSessionState>((ref) {
  return VaultSessionNotifier();
});

class VaultSessionNotifier extends StateNotifier<VaultSessionState> {
  VaultSessionNotifier() : super(const VaultSessionState());

  static const defaultTtl = Duration(minutes: 30);

  Timer? _expiryTimer;

  /// Cache a VERIFIED MEK for [ttl]. Callers MUST only pass a MEK that has
  /// already passed the account's crypto verification this session.
  void unlock(SecretKey mek, {Duration ttl = defaultTtl}) {
    _expiryTimer?.cancel();
    state = VaultSessionState(mek: mek, expiresAt: DateTime.now().add(ttl));
    _expiryTimer = Timer(ttl, lock);
  }

  /// The cached MEK if the session is currently unlocked, else null. Reading an
  /// expired session locks it as a side effect so state can never go stale.
  SecretKey? get mek {
    if (!state.isUnlocked) {
      if (state.mek != null || state.expiresAt != null) lock();
      return null;
    }
    return state.mek;
  }

  void lock() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (state.mek != null || state.expiresAt != null) {
      state = const VaultSessionState();
    }
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }
}

// ── Security lock method ─────────────────────────────────────────

/// The currently configured lock method.
final lockMethodProvider = FutureProvider<SecurityLockMethod>((ref) async {
  final service = ref.watch(securityLockServiceProvider);
  return service.getLockMethod();
});

/// Whether biometrics are available on this device.
final biometricAvailableProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(securityLockServiceProvider);
  return service.isBiometricAvailable();
});

/// The auto-lock idle timeout in minutes (0 = immediate, negative = never).
/// Invalidate after [SecurityLockService.setAutoLockTimeout] to refresh.
final autoLockTimeoutProvider = FutureProvider<int>((ref) async {
  final service = ref.watch(securityLockServiceProvider);
  return service.getAutoLockTimeout();
});

/// Whether a PIN has been configured.
final hasPinConfiguredProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(securityLockServiceProvider);
  return service.hasPinConfigured();
});

// ── Why the app locked (4.0) ─────────────────────────────────────

/// What locked the app, as the lock screen says it under its title.
enum AppLockCause {
  /// ZestSSH started with its lock on.
  started,

  /// Its person locked it (Lock ZestSSH).
  byYou,

  /// "Lock when idle": no key press or click in it for [AppLockReason.minutes].
  idle,

  /// Back from the background (another app, another window, the screen off)
  /// after the auto-lock time, [AppLockReason.minutes]: 0 is "Immediately".
  away,

  /// The computer slept ("Lock when the computer locks").
  slept,

  /// The computer's own lock screen came up ("Lock when the computer locks").
  computerLocked,
}

/// Why the app locked: what did it, and the minutes of the setting that did, where
/// one did ([AppLockCause.idle], [AppLockCause.away]).
class AppLockReason {
  const AppLockReason(this.cause, [this.minutes = 0]);

  final AppLockCause cause;
  final int minutes;

  static const started = AppLockReason(AppLockCause.started);
  static const byYou = AppLockReason(AppLockCause.byYou);
  static const slept = AppLockReason(AppLockCause.slept);
  static const computerLocked = AppLockReason(AppLockCause.computerLocked);

  @override
  bool operator ==(Object other) => other is AppLockReason && other.cause == cause && other.minutes == minutes;

  @override
  int get hashCode => Object.hash(cause, minutes);

  @override
  String toString() => 'AppLockReason(${cause.name}, $minutes)';
}
