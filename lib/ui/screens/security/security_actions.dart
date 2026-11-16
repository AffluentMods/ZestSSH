import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/security/pin_setup_screen.dart';
import 'package:zestssh/ui/screens/security/vault_lock_setup_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/l10n_global.dart';

/// What the hardware behind "Hardware-backed encryption" is called on this
/// system, and the words of its row and of the question before binding: the
/// TPM on Windows, the Secure Enclave on a Mac (4.0), the phone's secure
/// hardware otherwise. One place, so the phone's settings, a computer's
/// settings and the question say the same of the same machine. [os] is
/// [Platform.operatingSystem] unless a test names another.
({String name, String notAvailable, String subtitle, String what, String risk}) hardwareTexts(
  AppLocalizations l10n, {
  String? os,
}) {
  switch (os ?? Platform.operatingSystem) {
    case 'windows':
      return (
        name: l10n.secSetHwNameTpm,
        notAvailable: l10n.secSetHwNotAvailableWindows,
        subtitle: l10n.secSetHwBindSubtitleWindows(l10n.secSetHwNameTpm),
        what: l10n.secBindWhatWindows,
        risk: l10n.secBindRiskWindows,
      );
    case 'macos':
      return (
        name: l10n.secSetHwNameMac,
        notAvailable: l10n.secSetHwNotAvailableMac,
        // No added device authentication on a computer: the Windows sentence.
        subtitle: l10n.secSetHwBindSubtitleWindows(l10n.secSetHwNameMac),
        what: l10n.secBindWhatMac,
        risk: l10n.secBindRiskMac,
      );
    default:
      return (
        name: l10n.secSetHwNameSecureHardware,
        notAvailable: l10n.secSetHwNotAvailableMobile,
        subtitle: l10n.secSetHwBindSubtitleMobile(l10n.secSetHwNameSecureHardware),
        what: l10n.secBindWhatMobile,
        risk: l10n.secBindRiskMobile,
      );
  }
}

/// The security flows behind the Security settings, shared by the mobile
/// Security screen and the desktop Security page so both offer the same
/// controls with the same PIN gates: turning the app lock off, encrypting
/// data at rest (and turning that off), binding the vault key to the
/// device's secure hardware, and clearing trusted host keys.
///
/// Every protection-stripping path requires the current PIN through the
/// throttled [SecurityLockService.verifyPin], so a stranger at an unlocked
/// session cannot silently remove a layer.
class SecurityActions {
  SecurityActions(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  AppLocalizations get _l10n => AppLocalizations.of(context)!;

  /// [details]: what failed, for Copy details (3.0: the raw
  /// error stood in the message).
  void _toast(String text, {bool error = false, String? details}) {
    if (!context.mounted) return;
    showTopSnackBar(context, text, isError: error, details: details);
  }

  /// The platform's full-disk encryption product name, for the desktop note.
  static String diskEncryptionName() {
    if (Platform.isMacOS) return 'FileVault';
    if (Platform.isLinux) return gl10n.diskEncryptionLuks;
    return 'BitLocker'; // Windows
  }

  /// Turn the app lock on (PIN setup) or off (PIN required). Returns whether
  /// anything changed.
  Future<bool> setAppLock(bool on) async {
    final l10n = _l10n;
    if (on) {
      await PinSetupScreen.showAdaptive(context);
      return ref.read(settingsServiceProvider).securityLockEnabled;
    }
    final pin = await promptForPin(
      title: l10n.secSetTurnOffAppLockTitle,
      body: l10n.secSetTurnOffAppLockBody,
      confirmLabel: l10n.secSetTurnOff,
    );
    if (pin == null) return false;
    if (!await _verifyPin(pin, wrongPinText: l10n.secSetAppLockUnchangedWrongPin)) {
      return false;
    }
    await ref.read(settingsServiceProvider).setSecurityLockEnabled(false);
    ref.read(securityLockEnabledProvider.notifier).state = false;
    ref.read(isAppLockedProvider.notifier).unlock();
    // Off means off: drop the stored PIN so turning App Lock back on later is a
    // clean fresh setup, never a demand for a PIN the user may have forgotten.
    // The PIN was just verified above; guarded on encryption purely as
    // insurance (the encrypting lock's key rides on the PIN, and the UI already
    // blocks turning the lock off while encryption is on).
    if (!ref.read(settingsServiceProvider).encryptingLockEnabled) {
      await ref.read(securityLockServiceProvider).clearLock();
    }
    return true;
  }

  /// Change the PIN (re-runs setup).
  Future<void> changePin() => PinSetupScreen.showAdaptive(context);

  /// Turn "Encrypt data at rest" on. Returns whether it is now on.
  Future<bool> enableEncryption() async {
    final ok = await VaultLockSetupScreen.show(context);
    if (ok == true) _toast(_l10n.secSetEncryptEnabled);
    return ok == true;
  }

  /// Turn "Encrypt data at rest" off: confirm the PIN, then restore the
  /// plaintext DB key.
  Future<bool> disableEncryption() async {
    final l10n = _l10n;
    final pin = await promptForPin(
      title: l10n.secSetTurnOffEncryptionTitle,
      body: l10n.secSetTurnOffEncryptionBody,
      confirmLabel: l10n.secSetTurnOff,
    );
    if (pin == null) return false;
    // Route through the throttled verifyPin FIRST, like the App-Lock-off and
    // unbind gates, so this protection-stripping path shares the same lockout
    // state machine instead of silently relying on the AES-GCM unwrap alone.
    if (!await _verifyPin(pin,
        wrongPinText: l10n.secSetEncryptionUnchangedWrongPin)) {
      return false;
    }
    try {
      await ref.read(isAppLockedProvider.notifier).disableEncryptingLock(pin);
      _toast(l10n.secSetEncryptDisabled);
      return true;
    } catch (e) {
      _toast(l10n.secSetEncryptionNotTurnedOff, error: true, details: '$e');
      return false;
    }
  }

  /// Hardware availability and whether the vault key is bound to it.
  Future<({bool available, bool bound})> hardwareState() async {
    final available = await ref.read(hardwareVaultServiceProvider).isAvailable();
    final bound = await ref.read(vaultSlotServiceProvider).isHardwareBound();
    return (available: available, bound: bound);
  }

  /// Bind the vault key to the device's secure hardware, or unbind it (PIN
  /// required). Returns whether anything changed.
  Future<bool> setHardwareBinding(bool enable) async {
    final l10n = _l10n;
    try {
      if (enable) {
        // Confirm the caveat before creating the hardware key.
        // What it does, and what would lose the data in its amber sentence
        // (the whole dialog was yellow; the dialog rules, 3.4).
        final ok = await ZestConfirmDialog.show(
          context,
          tone: ZestDialogTone.warning,
          title: l10n.secSetBindDialogTitle,
          body: hardwareTexts(l10n).what,
          warning: hardwareTexts(l10n).risk,
          confirmLabel: l10n.secSetBind,
        );
        if (ok != true) return false;
        await ref.read(isAppLockedProvider.notifier).enableHardwareBinding();
        _toast(l10n.secSetHwBindingEnabled);
        return true;
      }
      // Require the app PIN to unbind, mirroring encryption-off, so the OS
      // auth validity window right after an unlock can never let a stranger
      // at an unlocked session strip the hardware layer.
      final pin = await promptForPin(
        title: l10n.secSetUnbindDialogTitle,
        body: l10n.secSetUnbindDialogBody,
        confirmLabel: l10n.secSetUnbind,
      );
      if (pin == null) return false;
      if (!await _verifyPin(pin,
          wrongPinText: l10n.secSetHwBindingUnchangedWrongPin)) {
        return false;
      }
      await ref.read(isAppLockedProvider.notifier).disableHardwareBinding();
      _toast(l10n.secSetHwBindingDisabled);
      return true;
    } catch (e) {
      // Auth cancelled / hardware refused: nothing changed (the layer swaps
      // are crash-safe and keyed on completing the auth), just surface it.
      _toast(l10n.secSetHwBindingNotChanged, error: true, details: '$e');
      return false;
    }
  }

  /// Forget every trusted host key after a confirmation.
  Future<bool> clearKnownHosts() async {
    final l10n = _l10n;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.secSetClearKeysDialogTitle,
      body: l10n.secSetClearKeysDialogBody,
      confirmLabel: l10n.commonClearAll,
    );
    if (confirmed != true) return false;
    await ref.read(knownHostsDaoProvider).deleteAll();
    _toast(l10n.secSetTrustedKeysCleared);
    return true;
  }

  /// Throttled PIN check with the lockout message; false on a wrong PIN.
  Future<bool> _verifyPin(String pin, {required String wrongPinText}) async {
    final lock = ref.read(securityLockServiceProvider);
    if (lock.isLockedOut) {
      _toast(_l10n.secSetTooManyAttempts(lock.remainingLockoutSeconds),
          error: true);
      return false;
    }
    if (!await lock.verifyPin(pin)) {
      _toast(wrongPinText, error: true);
      return false;
    }
    return true;
  }

  /// Small modal PIN prompt used by the disable paths. Returns the entered
  /// PIN or null on cancel.
  Future<String?> promptForPin({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final pin = await showZestInputDialog(
      context: context,
      title: title,
      subtitle: body,
      icon: LucideIcons.pin,
      fieldLabel: _l10n.secSetPinLabel,
      confirmLabel: confirmLabel,
      obscureText: true,
      maxLength: 32,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    );
    // (Digits only: nothing to trim.)
    if (pin == null || pin.isEmpty) return null;
    return pin;
  }
}
