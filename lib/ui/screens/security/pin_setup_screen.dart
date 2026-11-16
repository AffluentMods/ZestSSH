import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show Assertiveness;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart' show zestAnnounce;
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/pin_strength.dart';
import 'package:zestssh/ui/widgets/button_box.dart';

/// Screen for setting up or changing the security PIN.
///
/// Two-step flow: Enter PIN → Confirm PIN, with smooth animated
/// transitions and proper keyboard-safe scrolling.
class PinSetupScreen extends ConsumerStatefulWidget {
  const PinSetupScreen({super.key});

  /// Show as a dialog on desktop (>600px) or push a route on mobile.
  static Future<void> showAdaptive(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width > 600;
    if (isWide) {
      return showDialog(
        context: context,
        builder: (ctx) => Dialog(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 400,
                maxHeight: 520,
              ),
              child: const PinSetupScreen(),
            ),
          ),
        ),
      );
    } else {
      return context.push(Routes.pinSetup);
    }
  }

  @override
  ConsumerState<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends ConsumerState<PinSetupScreen> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  final _currentController = TextEditingController();
  final _pinFocus = FocusNode();
  final _confirmFocus = FocusNode();
  String? _error;

  /// A PIN that could not be saved: what was said, and its report for Copy
  /// details (3.0: the raw error stood in the message). Its
  /// details stand beside that message only.
  ({String message, String report})? _failure;
  bool _isStep2 = false;
  bool _isSaving = false;
  bool _useBiometric = false;
  bool _isSuccess = false;

  /// What a screen reader was last told: an error under the field, or the
  /// PIN saved, said once when it appears (4.0 accessibility pass; the error
  /// was read only when the field was found again).
  Object? _said;

  void _sayChanges(AppLocalizations l10n) {
    final now = _isSuccess ? l10n.pinSetupSuccessTitle : _error;
    if (now == _said) return;
    _said = now;
    if (now == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) zestAnnounce(context, now, assertiveness: _isSuccess ? Assertiveness.polite : Assertiveness.assertive);
    });
  }

  /// Whether this device offers a usable device-auth factor (Windows Hello on
  /// a PC with a TPM + Hello set up, Touch ID on a Mac, fingerprint / Face ID
  /// on mobile). The opt-in toggle is only shown when this is true, so we never
  /// offer a factor the device cannot perform.
  bool _biometricAvailable = false;

  /// Platform name for that factor, so the copy reads 'Windows Hello' on a PC
  /// and 'Touch ID' on a Mac instead of the mobile-only 'fingerprint or
  /// Face ID'.
  String get _biometricFactor {
    final l10n = AppLocalizations.of(context)!;
    if (Platform.isWindows) return l10n.pinSetupBiometricFactorWindowsHello;
    if (Platform.isMacOS) return l10n.pinSetupBiometricFactorTouchId;
    return l10n.pinSetupBiometricFactorGeneric;
  }

  /// Whether a PIN already exists (null while loading). Changing or replacing
  /// an existing PIN requires proving knowledge of the CURRENT one first, or a
  /// stranger at an unlocked phone could silently swap the PIN and lock the
  /// owner out (and, with the encrypting lock, own the vault).
  bool? _needsCurrentPin;
  bool _currentVerified = false;
  bool _verifyingCurrent = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
    _checkExistingPin();
  }

  Future<void> _checkExistingPin() async {
    final has =
        await ref.read(securityLockServiceProvider).hasPinConfigured();
    // The current-PIN gate exists to stop someone at an unlocked session
    // silently swapping an ACTIVE PIN. When App Lock is off there is nothing
    // to protect, so setting one up must be a fresh setup: never gate it
    // behind an old, possibly forgotten PIN. (Turning the lock off clears the
    // stored PIN, so normally none exists here; this also rescues anyone left
    // with a stale one from before that fix.)
    final lockOn = ref.read(settingsServiceProvider).securityLockEnabled;
    if (mounted) setState(() => _needsCurrentPin = has && lockOn);
  }

  Future<void> _verifyCurrent() async {
    if (_verifyingCurrent) return;
    final l10n = AppLocalizations.of(context)!;
    final service = ref.read(securityLockServiceProvider);
    if (service.isLockedOut) {
      setState(() => _error =
          l10n.pinSetupLockoutError(service.remainingLockoutSeconds));
      return;
    }
    if (_currentController.text.length < 4) {
      setState(() => _error = l10n.pinSetupEnterCurrentPin);
      return;
    }
    setState(() {
      _verifyingCurrent = true;
      _error = null;
    });
    final ok = await service.verifyPin(_currentController.text);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _currentVerified = true;
        _verifyingCurrent = false;
        _error = null;
      });
    } else {
      setState(() {
        _verifyingCurrent = false;
        _error = service.isLockedOut
            ? l10n.pinSetupLockoutError(service.remainingLockoutSeconds)
            : l10n.pinSetupIncorrectPin;
        _currentController.clear();
      });
    }
  }

  /// Whether "Encrypt data at rest" is on. Then only the PIN can open the
  /// data (the lock screen never offers the device's own unlock in that
  /// state), so the factor is not offered here either, and one line says why
  /// (3.0 docs check: it was offered, and the success said "Your PIN and
  /// Windows Hello are now active" for a factor that would never be asked).
  bool get _encryptedAtRest =>
      ref.read(settingsServiceProvider).encryptingLockEnabled;

  Future<void> _checkBiometric() async {
    // Record availability (gates the toggle) and default the factor ON when the
    // device supports one and the data is not encrypted at rest.
    final service = ref.read(securityLockServiceProvider);
    final available = await service.isBiometricAvailable();
    if (mounted) {
      setState(() {
        _biometricAvailable = available;
        _useBiometric = available && !_encryptedAtRest;
      });
    }
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    _currentController.dispose();
    _pinFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    _sayChanges(l10n);
    final motion = MediaQuery.disableAnimationsOf(context) ? Duration.zero : null;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.pinSetupTitle)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: AnimatedSwitcher(
            duration: motion ?? const Duration(milliseconds: 400),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _isSuccess
                ? _buildSuccessState()
                : _needsCurrentPin == null
                    ? const Padding(
                        key: ValueKey('pin_gate_loading'),
                        padding: EdgeInsets.all(48),
                        child: CircularProgressIndicator(),
                      )
                    : (_needsCurrentPin! && !_currentVerified)
                        ? _buildCurrentPinGate()
                        : _buildPinEntry(),
          ),
        ),
      ),
    );
  }

  /// Step 0 when a PIN already exists: prove knowledge of the current PIN
  /// before being allowed to set a new one.
  Widget _buildCurrentPinGate() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      key: const ValueKey('current_pin_gate'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.lock, size: 48, color: AppColors.accentInk),
        const SizedBox(height: 16),
        Text(
          l10n.pinSetupConfirmCurrentTitle,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.pinSetupConfirmCurrentSubtitle,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: 240,
          child: TextField(
            controller: _currentController,
            keyboardType: TextInputType.number,
            obscureText: true,
            autofocus: true,
            textAlign: TextAlign.center,
            maxLength: 32,
            decoration: InputDecoration(
              counterText: '',
              errorText: _error,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (_) => _verifyCurrent(),
          ),
        ),
        const SizedBox(height: 20),
        ButtonBox(
          width: 200,
          height: 44,
          child: FilledButton(
            onPressed: _verifyingCurrent ? null : _verifyCurrent,
            child: _verifyingCurrent
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.pinSetupContinue),
          ),
        ),
      ],
    );
  }

  Widget _buildPinEntry() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      key: ValueKey('pin_entry_$_isStep2'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // The lock on both steps, as on the current PIN's: Lucide's "pin" is a
        // push pin, which reads as pinning something, not as a PIN (seen on a
        // test device).
        Icon(LucideIcons.lock, size: 48, color: AppColors.accentInk),
        const SizedBox(height: 24),

        // Title
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            _isStep2 ? l10n.pinSetupConfirmPinTitle : l10n.pinSetupChoosePinTitle,
            key: ValueKey('title_$_isStep2'),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 8),

        // Subtitle
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(
            _isStep2
                ? l10n.pinSetupConfirmPinSubtitle
                : l10n.pinSetupChoosePinSubtitle,
            key: ValueKey('sub_$_isStep2'),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 32),

        // Step indicator: "Step 1 of 2" to a screen reader (it heard "1",
        // "2", with nothing saying which was the step it was on).
        Semantics(
          label: l10n.syncStepIndicator(_isStep2 ? 2 : 1, 2),
          excludeSemantics: true,
          child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const _StepDot(isActive: true, label: '1'),
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 40,
              height: 2,
              color: _isStep2
                  ? AppColors.brandOrange
                  : AppColors.divider,
            ),
            _StepDot(isActive: _isStep2, label: '2'),
          ],
        ),
        ),
        const SizedBox(height: 24),

        // PIN input
        SizedBox(
          width: 200,
          child: TextField(
            // A field of its own for each step, so nothing of the first
            // shows in the second.
            key: ValueKey(_isStep2 ? 'pin-setup-confirm' : 'pin-setup-pin'),
            controller: _isStep2 ? _confirmController : _pinController,
            focusNode: _isStep2 ? _confirmFocus : _pinFocus,
            keyboardType: TextInputType.number,
            obscureText: true,
            textAlign: TextAlign.center,
            maxLength: 32,
            autofocus: true,
            style: const TextStyle(fontSize: 24, letterSpacing: 8),
            decoration: InputDecoration(
              // No dots in the empty confirm field: four of them read as the
              // PIN from the first step, already typed in (as the screenshot
              // tests showed).
              hintText: _isStep2 ? null : '••••',
              counterText: '',
              errorText: _error,
            ),
            onSubmitted: (_) => _isStep2 ? _save() : _goToStep2(),
          ),
        ),
        if (_failure != null && _failure!.message == _error)
          CopyDetailsButton(key: const ValueKey('pin-setup-copy-details'), detail: _failure!.report),
        const SizedBox(height: 24),

        // Device-auth toggle (step 1 only), shown only when the device offers
        // one, and labelled for the platform (Windows Hello / Touch ID / ...).
        if (!_isStep2 && _biometricAvailable && _encryptedAtRest) ...[
          Text(
            l10n.docCheckPinFactorOffEncrypted(_biometricFactor),
            key: const ValueKey('pin-setup-factor-off-encrypted'),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 16),
        ] else if (!_isStep2 && _biometricAvailable) ...[
          SwitchListTile(
            title: Text(l10n.pinSetupAlsoEnableFactor(_biometricFactor)),
            subtitle: Text(l10n.pinSetupUnlockWithFactor(_biometricFactor)),
            value: _useBiometric,
            onChanged: (v) => setState(() => _useBiometric = v),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 16),
        ],

        // Action buttons
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isStep2)
              TextButton(
                onPressed: _goBackToStep1,
                child: Text(l10n.back),
              ),
            if (_isStep2) const SizedBox(width: 12),
            FilledButton(
              onPressed: _isSaving
                  ? null
                  : (_isStep2 ? _save : _goToStep2),
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_isStep2 ? l10n.pinSetupConfirmAndEnable : l10n.next),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSuccessState() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      key: const ValueKey('success'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: AppColors.success.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(
            LucideIcons.checkCircle2,
            size: 56,
            color: AppColors.success,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          l10n.pinSetupSuccessTitle,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          _useBiometric && !_encryptedAtRest
              ? l10n.pinSetupSuccessWithFactor(_biometricFactor)
              : l10n.pinSetupSuccessPinOnly,
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 32),
        FilledButton(
          onPressed: () => context.pop(),
          child: Text(l10n.done),
        ),
      ],
    );
  }

  void _goToStep2() {
    final l10n = AppLocalizations.of(context)!;
    if (_pinController.text.length < 4) {
      setState(() => _error = l10n.pinSetupMinLength);
      return;
    }
    if (isTrivialPin(_pinController.text)) {
      setState(() => _error = l10n.pinSetupTrivialPin);
      return;
    }
    setState(() {
      _error = null;
      _isStep2 = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _confirmFocus.requestFocus();
    });
  }

  void _goBackToStep1() {
    setState(() {
      _isStep2 = false;
      _error = null;
      _confirmController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pinFocus.requestFocus();
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (_confirmController.text != _pinController.text) {
      setState(() {
        _error = l10n.pinSetupPinsDoNotMatch;
        _confirmController.clear();
      });
      return;
    }

    setState(() => _isSaving = true);

    try {
      final lockService = ref.read(securityLockServiceProvider);
      final updater = ref.read(settingsUpdaterProvider);

      // Encrypting lock ON: the PIN is not just a gate, it wraps the DB key.
      // Re-wrap the vault's PIN slot to the new PIN BEFORE swapping the hash,
      // using the current PIN the gate step verified - otherwise the hash and
      // the vault desync and the correct new PIN fails to open the data
      // ("Could not open your data: VaultLockedException"). A crash between
      // the two writes is healed by the lock screen's previous-PIN migration.
      final vault = ref.read(vaultSlotServiceProvider);
      if (await vault.isEnabled()) {
        final vaultKey =
            await vault.unlockVaultKey(pin: _currentController.text);
        await vault.changePin(vaultKey, _pinController.text);
      }

      await lockService.setPin(_pinController.text);

      SecurityLockMethod method;
      if (_useBiometric && !_encryptedAtRest) {
        method = SecurityLockMethod.both;
      } else {
        method = SecurityLockMethod.pin;
      }
      await lockService.setLockMethod(method);

      // Use the updater so the reactive provider is updated immediately
      await updater.setSecurityLockEnabled(true);

      ref.invalidate(lockMethodProvider);
      ref.invalidate(hasPinConfiguredProvider);

      if (mounted) {
        setState(() {
          _isSaving = false;
          _isSuccess = true;
        });
      }
    } catch (e, stack) {
      if (mounted) {
        setState(() {
          _error = l10n.pinSetupNotSaved;
          _failure = (
            message: l10n.pinSetupNotSaved,
            report: ErrorReport.build(what: l10n.pinSetupNotSaved, where: 'Saving the PIN', error: e, stack: stack),
          );
          _isSaving = false;
        });
      }
    }
  }
}

// ─── Step dot indicator ────────────────────────────────────────

class _StepDot extends StatelessWidget {
  final bool isActive;
  final String label;

  const _StepDot({required this.isActive, required this.label});

  @override
  Widget build(BuildContext context) {
    // 28 across for a number 12 high, and as much wider as the number grows
    // with the text (a fixed 28 cut it from 1.5 times the text size).
    final side = MediaQuery.textScalerOf(context).scale(12) * 28 / 12;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: side,
      height: side,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isActive ? AppColors.brandOrange : AppColors.surfaceLight,
        border: Border.all(
          color: isActive ? AppColors.brandOrange : AppColors.divider,
          width: 2,
        ),
      ),
      child: Center(
        child: Text(
          label,
          style: TextStyle(
            // Dark on the accent, as every label on it (white was 2:1).
            color: isActive ? ZestTokens.onBrand : AppColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
