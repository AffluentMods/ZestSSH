import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/profile/recovery_kit.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/utils/file_manager.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/secret_clipboard.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';

/// Why the recovery key screen is shown.
enum RecoveryKeyMode {
  /// During cloud-sync setup, as one step of it.
  setup,

  /// From Account and security, to make a new key (3.0). The setup
  /// steps are not touched.
  replace,
}

/// Displays a newly generated recovery key and requires the user to save it
/// (copy, download as .txt, or print) before confirming.
///
/// Shown once during cloud-sync setup, or when the person makes a new one.
/// The key is never persisted on device - the user must save it
/// externally.
class RecoveryKeyScreen extends ConsumerStatefulWidget {
  const RecoveryKeyScreen({super.key, this.mode = RecoveryKeyMode.setup});

  final RecoveryKeyMode mode;

  @override
  ConsumerState<RecoveryKeyScreen> createState() => _RecoveryKeyScreenState();
}

class _RecoveryKeyScreenState extends ConsumerState<RecoveryKeyScreen> {
  late final String _recoveryKey;

  /// When the key was made: the kit says so.
  final DateTime _madeAt = DateTime.now();

  // The user must save via at least one method before confirming.
  bool _hasCopied = false;
  bool _hasDownloaded = false;
  bool _hasPrinted = false;

  bool get _hasSaved => _hasCopied || _hasDownloaded || _hasPrinted;

  /// Auto-clears the copied recovery key from the OS clipboard after a delay -
  /// the key is master-password-equivalent, so it must not linger.

  @override
  void initState() {
    super.initState();
    _recoveryKey = RecoveryKeyService.generateRecoveryKey();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ResponsiveScaffold(
      title: l10n.recoveryKeyTitle,
      maxWidth: 520,
      body: _buildBody(l10n),
    );
  }

  static TextStyle _keyStyle = TextStyle(
    fontFamily: 'JetBrainsMono',
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.0,
    height: 1.9,
    color: AppColors.onSurface,
  );

  Widget _buildBody(AppLocalizations l10n) {
    // Recording mode: the key paints as bullets with a Reveal button that
    // runs the reveal gate (spec 5). The gate turns the mode off, and this
    // rebuilds with the real key.
    final recording = ref.watch(recordingModeProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Warning banner (amber) - the risk, stated plainly.
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.alertTriangle,
                    color: AppColors.warning, size: 18),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.recoveryKeyWarnTitle,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        l10n.recoveryKeyWarnBody,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.55,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          Text(
            l10n.recoveryKeyIntro,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: AppColors.textSecondary,
            ),
          ),
          if (widget.mode == RecoveryKeyMode.replace) ...[
            const SizedBox(height: 8),
            Text(
              l10n.recoveryReplaceScreenNote,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: 13),

          // The key itself.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.surfaceDark,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.divider),
            ),
            child: recording
                ? Row(
                    children: [
                      Expanded(
                        child: Text(Redactor.passwordMask, style: _keyStyle),
                      ),
                      TextButton.icon(
                        onPressed: _reveal,
                        icon: const Icon(LucideIcons.eye, size: 15),
                        label: Text(l10n.recModeRevealAction),
                      ),
                    ],
                  )
                : SelectableText(_recoveryKey, style: _keyStyle),
          ),
          if (recording) ...[
            const SizedBox(height: 6),
            Text(
              l10n.recModeHiddenSecret,
              style: TextStyle(
                fontSize: 11.5,
                color: AppColors.onSurfaceDim,
              ),
            ),
          ],

          const SizedBox(height: 12),

          // Save actions - Copy / Download .txt / Print.
          Row(
            children: [
              Expanded(
                child: _SaveButton(
                  icon: _hasCopied ? LucideIcons.check : LucideIcons.copy,
                  label: _hasCopied ? l10n.recoveryKeyCopied : l10n.recoveryKeyCopy,
                  done: _hasCopied,
                  onPressed: _copyKey,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SaveButton(
                  icon: _hasDownloaded
                      ? LucideIcons.check
                      : LucideIcons.download,
                  label: _hasDownloaded
                      ? l10n.recoveryKeyDownloaded
                      : l10n.recoveryKeyDownloadTxt,
                  done: _hasDownloaded,
                  onPressed: _downloadTxt,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _SaveButton(
                  icon: _hasPrinted ? LucideIcons.check : LucideIcons.printer,
                  label: _hasPrinted
                      ? l10n.recoveryKeyPrinted
                      : l10n.recoveryKeyPrint,
                  done: _hasPrinted,
                  onPressed: _printKey,
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // "I've saved it somewhere safe" → Confirm card.
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: BesideOrUnder(
              // The button under the words on a phone, where beside them it left them a few
              // letters a line.
              words: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.recoveryKeySavedConfirmTitle,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    l10n.recoveryKeySavedConfirmDesc,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      color: AppColors.onSurfaceDim,
                    ),
                  ),
                ],
              ),
              control: FilledButton(
                onPressed: _hasSaved ? _confirmAndContinue : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandOrange,
                  foregroundColor: AppColors.onBrand(AppColors.brandOrange),
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: const TextStyle(
                      fontFamily: 'GeistSans',
                      fontSize: 12.5, fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(_hasSaved
                    ? l10n.recoveryKeyConfirm
                    : l10n.recoveryKeySaveToContinue),
              ),
            ),
          ),

          const SizedBox(height: 11),
          Text(
            l10n.recoveryKeyOnlyHere,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.5,
              color: AppColors.onSurfaceDim,
            ),
          ),
        ],
      ),
    );
  }

  // ── Actions ─────────────────────────────────────────────────────

  /// Reveal the key while recording: the gate turns the mode off, and the
  /// plate rebuilds with the real value (or nothing happens on Cancel).
  Future<void> _reveal() => confirmRevealWhileRecording(context, ref);

  Future<void> _copyKey() async {
    final l10n = AppLocalizations.of(context)!;
    // A master-password-equivalent secret goes to the clipboard: reveal gate
    // (spec 5).
    if (!await confirmRevealWhileRecording(context, ref)) return;
    if (!mounted) return;
    try {
      // Master-password-equivalent secret: off the clipboard after 45s, the
      // screen closed or not, unless something else was copied over it.
      await SecretClipboard.copy(_recoveryKey);
      if (mounted) {
        setState(() => _hasCopied = true);
        showTopSnackBar(context, l10n.recoveryKeyCopiedAutoClear,
            isSuccess: true);
      }
      unawaited(_persistRecoverySaved());
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.recoveryKeyCopyFailed, isError: true, details: '$e');
      }
    }
  }

  /// The kit for this key, in the person's language.
  RecoveryKitText _kit(AppLocalizations l10n) => RecoveryKitText.of(
        l10n,
        key: _recoveryKey,
        account: ref.read(currentUserProvider)?.email,
        made: _madeAt,
      );

  Future<void> _downloadTxt() async {
    final l10n = AppLocalizations.of(context)!;
    // The file holds the real key: reveal gate (spec 5).
    if (!await confirmRevealWhileRecording(context, ref)) return;
    if (!mounted) return;
    final bytes = Uint8List.fromList(utf8.encode(recoveryKitPlainText(_kit(l10n))));
    const fileName = 'ZestSSH-Recovery-Kit.txt';

    // Mobile: route through the OS "Save as" picker (Storage Access Framework
    // on Android) so the file lands somewhere the user can actually find.
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final result = await FilePicker.platform.saveFile(
          dialogTitle: l10n.recoveryKitTitle,
          fileName: fileName,
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: ['txt'],
        );
        if (result == null) return; // cancelled
        if (mounted) {
          setState(() => _hasDownloaded = true);
          showTopSnackBar(context, l10n.recoveryKeyDownloaded,
              isSuccess: true);
        }
        unawaited(_persistRecoverySaved());
      } catch (e) {
        // In the app's words, with what was thrown to copy (it said "Save
        // failed:" and the raw error).
        if (mounted) {
          showTopSnackBar(context, l10n.recoveryKitNotSaved, isError: true, details: '$e');
        }
      }
      return;
    }

    // Desktop: the person chooses where (Downloads to start with), the file
    // is locked to the current user at once (it holds a secret equal to the
    // master password: a world-readable default, umask 022 -> 0644 on a
    // shared POSIX host, would expose the vault), and where it went is shown
    // with Copy path and Show in folder (3.0 UI).
    try {
      final dir = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      if (!mounted) return;
      final path = await FilePicker.platform.saveFile(
        dialogTitle: l10n.recoveryKitTitle,
        fileName: fileName,
        initialDirectory: dir.path,
        type: FileType.custom,
        allowedExtensions: ['txt'],
        lockParentWindow: true,
      );
      if (path == null) return; // cancelled
      final file = File(path);
      await file.writeAsBytes(bytes, flush: true);
      if (!await restrictFileToOwner(file)) {
        // Never leave an unsecured copy of the recovery key on disk. (It said
        // "Save failed: Exception: could not restrict...".)
        try {
          await file.delete();
        } catch (_) {}
        if (mounted) showTopSnackBar(context, l10n.recoveryKitNotPrivate, isError: true);
        return;
      }
      if (!mounted) return;
      setState(() => _hasDownloaded = true);
      unawaited(_persistRecoverySaved());
      await showFileSavedDialog(
        context,
        title: l10n.recoveryKeyDownloaded,
        message: l10n.recoveryKitSavedBody,
        path: file.path,
      );
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.recoveryKitNotSaved, isError: true, details: '$e');
      }
    }
  }

  Future<void> _printKey() async {
    final l10n = AppLocalizations.of(context)!;
    // The print preview paints the real key on screen: reveal gate (spec 5).
    if (!await confirmRevealWhileRecording(context, ref)) return;
    if (!mounted) return;
    try {
      // The page is drawn by the app, so it reads right in every language.
      final pdf = await recoveryKitPdf(_kit(l10n), title: l10n.recoveryKitTitle);
      // layoutPdf returns false when the user cancels the print dialog - only
      // count it as "saved" when a document was actually produced, otherwise
      // the Confirm gate would pass with no printout, file, or clipboard copy.
      final printed = await Printing.layoutPdf(
        onLayout: (_) async => pdf,
        name: l10n.recoveryKitTitle,
      );
      if (!printed) return;
      if (mounted) setState(() => _hasPrinted = true);
      unawaited(_persistRecoverySaved());
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.recoveryKitNotPrinted, isError: true, details: '$e');
      }
    }
  }

  Future<void> _persistRecoverySaved() async {
    // A replacement is not a setup step: the caller makes its own salt.
    if (widget.mode == RecoveryKeyMode.replace) return;
    // Persist a recovery salt the moment the user takes the first save action
    // so the setup state machine can resume from [SyncSetupStep.recoverySaved]
    // if the app crashes before the confirmation is recorded.
    try {
      final stateService = ref.read(syncSetupStateServiceProvider);
      final existing = await stateService.readRecoverySalt();
      if (existing == null) {
        final salt = RecoveryKeyService.generateRecoverySalt();
        await stateService.markRecoverySaved(recoverySalt: salt);
      } else {
        await stateService.markRecoverySaved(recoverySalt: existing);
      }
    } catch (_) {
      // Persistence failure must NOT block the user from saving the key - they
      // can still write it down and continue; the state machine re-prompts on
      // next launch.
    }
  }

  Future<void> _confirmAndContinue() async {
    if (widget.mode == RecoveryKeyMode.setup) {
      try {
        await ref.read(syncSetupStateServiceProvider).markRecoveryConfirmed();
      } catch (_) {
        // Non-fatal - caller still receives the key back.
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(_recoveryKey);
  }

}

/// A compact save-action button (Copy / Download .txt / Print). Turns green
/// once its action has completed.
class _SaveButton extends StatelessWidget {
  const _SaveButton({
    required this.icon,
    required this.label,
    required this.done,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool done;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = done ? AppColors.success : AppColors.onSurface;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 15, color: color),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color),
      ),
      style: OutlinedButton.styleFrom(
        side: BorderSide(
          color: done
              ? AppColors.success.withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.14),
        ),
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
