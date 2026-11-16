import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';

/// Turns ON the encrypting app lock: the SQLCipher database key is wrapped
/// behind the PIN, so the database only decrypts after unlock.
///
/// PIN-ONLY by design: there is no separate recovery key. Recovery is your
/// encrypted `.zest` backup (offline) or Cloud Sync (restore on a new device).
/// Forget the PIN with neither and the local data is gone - which is the point
/// on a lost/stolen device. Confirm the current app-lock PIN to continue.
class VaultLockSetupScreen extends ConsumerStatefulWidget {
  const VaultLockSetupScreen({super.key});

  static Future<bool?> show(BuildContext context) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const VaultLockSetupScreen()),
    );
  }

  @override
  ConsumerState<VaultLockSetupScreen> createState() =>
      _VaultLockSetupScreenState();
}

class _VaultLockSetupScreenState extends ConsumerState<VaultLockSetupScreen> {
  final _pinController = TextEditingController();
  bool _understood = false;
  bool _busy = false;
  String? _error;

  /// A failure to turn the lock on: what was said, and its report for Copy
  /// details (3.0: the raw error stood in the message). Its
  /// details stand beside that message only.
  ({String message, String report})? _failure;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _enable() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    final pin = _pinController.text.trim();
    if (pin.length < 4) {
      setState(() => _error = l10n.vaultLockSetupErrorPinTooShort);
      return;
    }
    if (!_understood) {
      setState(() => _error = l10n.vaultLockSetupErrorConfirmRecovery);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final service = ref.read(securityLockServiceProvider);
    // The vault's PIN slot IS the app-lock PIN, so it must match the one set.
    if (!await service.hasPinConfigured()) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.vaultLockSetupErrorSetPinFirst;
      });
      return;
    }
    if (!await service.verifyPin(pin)) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // verifyPin also returns false while the brute-force lockout is
        // active, even for the CORRECT PIN - say so instead of the misleading
        // "not correct".
        _error = service.isLockedOut
            ? l10n.vaultLockSetupErrorLockedOut(service.remainingLockoutSeconds)
            : l10n.vaultLockSetupErrorPinIncorrect;
      });
      return;
    }
    try {
      await ref.read(isAppLockedProvider.notifier).enableEncryptingLock(pin: pin);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e, stack) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = l10n.vaultLockSetupNotTurnedOn;
          _failure = (
            message: l10n.vaultLockSetupNotTurnedOn,
            report: ErrorReport.build(
              what: l10n.vaultLockSetupNotTurnedOn,
              where: 'Turning on the encrypting lock',
              error: e,
              stack: stack,
            ),
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.vaultLockSetupTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.vaultLockSetupDescription,
                style: const TextStyle(height: 1.4),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: AppColors.error.withValues(alpha: 0.4)),
                ),
                child: Text(
                  l10n.vaultLockSetupWarning,
                  style: const TextStyle(
                      height: 1.4, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 20),
              Text(l10n.vaultLockSetupConfirmPrompt),
              const SizedBox(height: 12),
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                obscureText: true,
                autofocus: true,
                maxLength: 32,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: l10n.vaultLockSetupPinLabel,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _enable(),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _understood,
                onChanged: (v) => setState(() => _understood = v ?? false),
                title: Text(l10n.vaultLockSetupUnderstandCheckbox),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: AppColors.error)),
                if (_failure != null && _failure!.message == _error)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: CopyDetailsButton(
                      key: const ValueKey('vault-setup-copy-details'),
                      detail: _failure!.report,
                    ),
                  ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _enable,
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l10n.vaultLockSetupTurnOnButton),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
