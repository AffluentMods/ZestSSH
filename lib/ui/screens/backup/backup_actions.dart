import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart';
import 'package:zestssh/features/hosts/host_share_file.dart';
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/auto_backup_service.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/backup/restore_preview.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/utils/error_kind.dart' show errorKind;
import 'package:zestssh/utils/logger.dart';

/// Full-backup export / import, extracted from the Profile screen so BOTH the
/// Profile panel and Settings > Data > Export/Import can drive the SAME flow.
///
/// These are LOCAL operations - they do not require sign-in or Cloud Sync. The
/// user can export a `.zest` backup and restore it entirely offline.

/// "I understand": the box ticked before something risky is done.
class _Understand extends StatelessWidget {
  const _Understand({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    // The box and its words close together, the whole line a target.
    return MergeSemantics(
      child: InkWell(
        key: const ValueKey('backup-unprotected-understand'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(label, style: TextStyle(fontSize: 13, height: 1.4, color: AppColors.v3TextSecondary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Checkbox-gated confirmation for an unprotected import: the warning in its
/// amber sentence, and the main button, in the footer, off until the person
/// ticks "I understand" (the dialog rules of 3.4: it was a button in the
/// body, under a yellow tile).
Future<bool?> _confirmUnprotected(
  BuildContext context, {
  required String title,
  required String body,
  required String checkboxLabel,
  required String confirmLabel,
}) {
  final l10n = AppLocalizations.of(context)!;
  final checked = ValueNotifier<bool>(false);
  return showZestModal<bool>(
    context: context,
    size: ZestModalSize.compact,
    child: ValueListenableBuilder<bool>(
      valueListenable: checked,
      builder: (ctx, on, _) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.warning,
        icon: LucideIcons.upload,
        title: title,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ZestCallout(body),
            const SizedBox(height: 8),
            _Understand(label: checkboxLabel, value: on, onChanged: (v) => checked.value = v),
          ],
        ),
        secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(ctx).pop(false)),
        primaryKey: const ValueKey('backup-unprotected-go'),
        primaryAction: (label: confirmLabel, icon: null, onPressed: on ? () => Navigator.of(ctx).pop(true) : null),
      ),
    ),
  );
}

/// Sets how often a backup is made by itself ([interval]: off, daily or
/// weekly), from Settings or Profile alike. On, with no backup password kept,
/// it asks for one first, and is left as it was if none is given. (3.0, UI
/// step 12: from Profile it never asked, so no automatic backup was ever
/// made, and nothing said why; Settings asked only when it was off before.)
Future<bool> setAutoBackupInterval(BuildContext context, WidgetRef ref, String interval) async {
  if (interval != 'off') {
    final storage = ref.read(secureStorageProvider);
    // (Whether one is kept: a sealed one is kept, so it is not opened here.)
    final kept = await storage.read(key: AutoBackupService.passwordKey);
    if (kept == null || kept.isEmpty) {
      if (!context.mounted) return false;
      final password = await askAutoBackupPassword(context);
      if (password == null) return false;
      // Sealed while the encrypting lock is on (SecretSeal).
      await AutoBackupService.keepPassword(storage, ref.read(databaseSessionProvider), password);
    }
  }
  await ref.read(settingsUpdaterProvider).setAutoBackupInterval(interval);
  return true;
}

/// Asks for the password automatic backups are encrypted with, twice, in the
/// app's own dialog (it was a plain one); null when it is not given.
Future<String?> askAutoBackupPassword(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return askNewPassword(
    context,
    title: l10n.settingsMobAutoBackupPassword,
    body: l10n.settingsMobAutoBackupPasswordDesc,
    label: l10n.settingsMobPassword,
    hint: l10n.settingsMobAtLeast12Chars,
    againLabel: l10n.settingsMobConfirmPassword,
    mismatch: l10n.settingsMobPasswordsDontMatch,
    action: l10n.settingsMobSetPassword,
    tooShort: l10n.accountBackupPasswordTooShort,
    keys: 'auto-backup-password',
  );
}

/// Asks for a NEW password that something is then encrypted with, in two
/// fields, so that a slip of the keyboard cannot make a file nobody can open
/// (the rule for an export, a backup, anything locked
/// with a password chosen there). The password has at least
/// [BackupService.minBackupPasswordLength] characters. Returns it, or null
/// when it was cancelled. [keys] names the fields for tests: `<keys>`,
/// `<keys>-again` and `<keys>-set` (the main button, in the footer).
Future<String?> askNewPassword(
  BuildContext context, {
  required String title,
  required String body,
  required String label,
  required String againLabel,
  required String mismatch,
  required String action,
  required String Function(int least) tooShort,
  String? hint,
  IconData icon = LucideIcons.keyRound,
  String keys = 'new-password',
}) {
  return showZestModal<String>(
    context: context,
    size: ZestModalSize.compact,
    child: _NewPasswordDialog(
      title: title,
      body: body,
      icon: icon,
      action: action,
      fields: (
        label: label,
        hint: hint,
        againLabel: againLabel,
        mismatch: mismatch,
        tooShort: tooShort,
        keys: keys,
      ),
    ),
  );
}

/// What the two fields of a new password say, and the keys tests find them
/// by.
typedef NewPasswordWords = ({
  String label,
  String? hint,
  String againLabel,
  String mismatch,
  String Function(int least) tooShort,
  String keys,
});

/// A new password, typed twice: at least
/// [BackupService.minBackupPasswordLength] characters, and the same in both.
/// Inside a [Form], which checks them. Its fields are keyed `<keys>` and
/// `<keys>-again` ([NewPasswordWords.keys]); Enter in the second calls
/// [onSubmit]. (A dialog that asks for one in place, as the stale-sync
/// question does, puts these in its own body.)
class NewPasswordFields extends StatefulWidget {
  const NewPasswordFields({super.key, required this.password, required this.again, required this.words, required this.onSubmit});

  final TextEditingController password;
  final TextEditingController again;
  final NewPasswordWords words;
  final VoidCallback onSubmit;

  @override
  State<NewPasswordFields> createState() => _NewPasswordFieldsState();
}

class _NewPasswordFieldsState extends State<NewPasswordFields> {
  var _obscured = true;
  final _againFocus = FocusNode();

  @override
  void dispose() {
    _againFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final w = widget.words;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: ValueKey(w.keys),
          controller: widget.password,
          obscureText: _obscured,
          autofocus: true,
          textInputAction: TextInputAction.next,
          onFieldSubmitted: (_) => _againFocus.requestFocus(),
          decoration: InputDecoration(
            labelText: w.label,
            hintText: w.hint,
            suffixIcon: IconButton(
              icon: Icon(_obscured ? LucideIcons.eye : LucideIcons.eyeOff),
              tooltip: _obscured ? l10n.settingsMobShow : l10n.settingsMobHide,
              onPressed: () => setState(() => _obscured = !_obscured),
            ),
          ),
          validator: (v) => (v ?? '').length < BackupService.minBackupPasswordLength
              ? w.tooShort(BackupService.minBackupPasswordLength)
              : null,
        ),
        const SizedBox(height: 10),
        TextFormField(
          key: ValueKey('${w.keys}-again'),
          controller: widget.again,
          focusNode: _againFocus,
          obscureText: _obscured,
          decoration: InputDecoration(labelText: w.againLabel),
          validator: (v) => v != widget.password.text ? w.mismatch : null,
          onFieldSubmitted: (_) => widget.onSubmit(),
        ),
      ],
    );
  }
}

class _NewPasswordDialog extends StatefulWidget {
  const _NewPasswordDialog({
    required this.title,
    required this.body,
    required this.icon,
    required this.action,
    required this.fields,
  });

  final String title;
  final String body;
  final IconData icon;
  final String action;
  final NewPasswordWords fields;

  @override
  State<_NewPasswordDialog> createState() => _NewPasswordDialogState();
}

class _NewPasswordDialogState extends State<_NewPasswordDialog> {
  final _password = TextEditingController();
  final _again = TextEditingController();
  final _form = GlobalKey<FormState>();
  var _closing = false;

  @override
  void dispose() {
    _password.dispose();
    _again.dispose();
    super.dispose();
  }

  void _submit() {
    if (_closing || !_form.currentState!.validate()) return;
    _closing = true;
    Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: widget.icon,
      title: widget.title,
      body: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.body, style: const TextStyle(fontSize: 13, height: 1.45)),
            const SizedBox(height: 14),
            NewPasswordFields(password: _password, again: _again, words: widget.fields, onSubmit: _submit),
          ],
        ),
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      // The main button in the footer, as every dialog's (it stood in the body).
      primaryKey: ValueKey('${widget.fields.keys}-set'),
      primaryAction: (label: widget.action, icon: null, onPressed: _submit),
    );
  }
}

/// Export every saved record to a `.zest` file. Works signed-out.
///
/// One dialog, changed in place (the dialog rules of 3.4: Export, then
/// "Export without a password?", was a second pop-up, and the file was a
/// third): the password, typed twice; "No password", a quiet link, turns it
/// to the export without one, which says what that means in its amber
/// sentence and is a red "Export unencrypted" once "I understand" is ticked;
/// then the same dialog says where the file went.
Future<void> runBackupExport(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  // An export writes real keys and passwords to a file: reveal gate (spec 5).
  if (!await confirmRevealWhileRecording(context, ref)) return;
  if (!context.mounted) return;
  final service = ref.read(backupServiceProvider);
  final dialog = GlobalKey<_ExportBackupDialogState>();
  final failed = await showZestModal<BackupResult>(
    context: context,
    size: ZestModalSize.compact,
    // Not closed while the file is being written.
    onDismissAttempt: () async => !(dialog.currentState?.busy ?? false),
    child: _ExportBackupDialog(
      key: dialog,
      // A blank password is only ever the export without one, asked for and
      // ticked; a password that is given has at least the minimum length.
      export: (password) => service.exportBackup(password, allowUnencrypted: password.isEmpty),
    ),
  );
  if (failed == null || !context.mounted) return;
  showTopSnackBar(
    context,
    l10n.settingsExportFailed(failed.error ?? ''),
    isError: true,
    details: failed.detail,
  );
}

enum _ExportStep { password, noPassword, done }

class _ExportBackupDialog extends StatefulWidget {
  const _ExportBackupDialog({super.key, required this.export});

  final Future<BackupResult> Function(String password) export;

  @override
  State<_ExportBackupDialog> createState() => _ExportBackupDialogState();
}

class _ExportBackupDialogState extends State<_ExportBackupDialog> {
  final _password = TextEditingController();
  final _again = TextEditingController();
  final _form = GlobalKey<FormState>();
  var _step = _ExportStep.password;
  var _understood = false;
  var _closing = false;
  BackupResult? _saved;
  var _encrypted = true;

  /// The file is being written: nothing closes the dialog meanwhile.
  bool busy = false;

  @override
  void dispose() {
    _password.dispose();
    _again.dispose();
    super.dispose();
  }

  void _close([BackupResult? failed]) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop(failed);
  }

  Future<void> _export(String password) async {
    if (busy || _closing) return;
    setState(() => busy = true);
    final result = await widget.export(password);
    if (!mounted) return;
    if (!result.success) {
      // Said where the export began, with what went wrong (as before).
      _close(result);
      return;
    }
    setState(() {
      busy = false;
      _saved = result;
      _encrypted = password.isNotEmpty;
      _step = _ExportStep.done;
    });
  }

  void _submitPassword() {
    if (_form.currentState!.validate()) _export(_password.text);
  }

  void _swap(_ExportStep to) => setState(() {
        _step = to;
        _understood = false;
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final saved = _saved;
    if (_step == _ExportStep.done && saved != null) {
      return fileSavedShell(
        context,
        title: l10n.accountBackupExported,
        subtitle: _encrypted
            ? l10n.backupExportedEncrypted(saved.recordCount)
            : l10n.backupExportedNotEncrypted(saved.recordCount),
        path: saved.filePath ?? '',
        onDone: _close,
      );
    }
    final plain = _step == _ExportStep.noPassword;
    final body = plain
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ZestCallout(l10n.backupNoPasswordBody),
              const SizedBox(height: 8),
              _Understand(
                label: l10n.backupNoPasswordUnderstand,
                value: _understood,
                onChanged: busy ? (_) {} : (v) => setState(() => _understood = v),
              ),
            ],
          )
        : Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NewPasswordFields(
                  password: _password,
                  again: _again,
                  onSubmit: _submitPassword,
                  words: (
                    label: l10n.accountBackupPassword,
                    hint: null,
                    againLabel: l10n.backupPasswordConfirmHint,
                    mismatch: l10n.backupPasswordMismatch,
                    tooShort: l10n.accountBackupPasswordTooShort,
                    keys: 'export-backup-password',
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  l10n.backupExportWhatsIn,
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextTertiary),
                ),
              ],
            ),
          );
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.download,
      title: l10n.backupExportTitle,
      subtitle: l10n.backupExportSubtitle,
      onClose: busy ? () {} : _close,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          if (busy) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.v3AccentPrimary),
                ),
                const SizedBox(width: 8),
                Text(l10n.staleReconcileExporting,
                    style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
              ],
            ),
          ],
        ],
      ),
      // The side option, a quiet link: never the easy way.
      tertiaryKey: ValueKey(plain ? 'export-backup-use-password' : 'export-backup-no-password'),
      tertiaryAction: (
        label: plain ? l10n.backupExportUsePassword : l10n.backupExportNoPassword,
        onPressed: busy ? null : () => _swap(plain ? _ExportStep.password : _ExportStep.noPassword),
      ),
      secondaryAction: (label: l10n.cancel, onPressed: busy ? null : _close),
      primaryKey: ValueKey(plain ? 'backup-unprotected-go' : 'export-backup-password-set'),
      // Without a password the file shows every key and password: red, and
      // it says so.
      primaryDanger: plain,
      primaryAction: (
        label: plain ? l10n.backupExportUnencryptedAction : l10n.accountExport,
        icon: null,
        onPressed: busy || (plain && !_understood)
            ? null
            : (plain ? () => _export('') : _submitPassword),
      ),
    );
  }
}

/// Restore records from a `.zest` file the user picks. Works signed-out.
Future<void> runBackupImport(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final pick = await FilePicker.platform.pickFiles(
    type: FileType.any,
    dialogTitle: l10n.settingsSelectZestFile,
  );
  if (pick == null || pick.files.isEmpty) return;
  final filePath = pick.files.single.path;
  if (filePath == null) return;
  // What the file is, whatever it is called: one for another import is said
  // so, and goes there.
  ImportFile? file;
  try {
    file = await readImportFile(filePath, rdp: ref.read(rdpOfferedProvider));
  } catch (e) {
    // Said below, by the restore that tries to read it.
    AppLogger.info('Restore: the file was not looked at (${errorKind(e)})');
  }
  if (!context.mounted) return;
  if (file != null) {
    if (await routeIfOtherFile(context, file,
        chosen: l10n.importKindBackup, takes: const {ImportKind.zestBackup, ImportKind.zestHost}, closes: false)) {
      return;
    }
    if (!context.mounted) return;
  }
  if (!filePath.endsWith('.zest') && file?.kind != ImportKind.zestBackup && file?.kind != ImportKind.zestHost) {
    showTopSnackBar(context, l10n.settingsSelectZestFile, isError: true);
    return;
  }
  await restoreBackupFile(context, filePath);
}

/// Restores the backup at [filePath], asking for its password and saying what
/// it would do first. A host shared as a file is offered as that.
Future<void> restoreBackupFile(BuildContext context, String filePath) async {
  final l10n = AppLocalizations.of(context)!;
  // Read before the questions: the screen that asked may go while they are
  // answered.
  final container = ProviderScope.containerOf(context, listen: false);

  // Peek the version byte to decide whether to prompt for a password. Uses the
  // shared detector so it recognises BOTH encrypted formats.
  final bool needsPassword;
  final bool isUnencrypted;
  final bool isHostShare;
  try {
    // Larger than any backup (and any host shared as a file): refused before
    // it is read, not read whole into memory to look at its first bytes
    // (the restore's own check came only after this read).
    final size = await File(filePath).length();
    if (size > BackupService.maxBackupBytes) {
      if (context.mounted) {
        showTopSnackBar(context, l10n.settingsImportFailed(l10n.backupSvcFileTooLarge),
            isError: true, details: BackupService.tooLargeDetail(size));
      }
      return;
    }
    final bytes = await File(filePath).readAsBytes();
    // A host someone shared is a .zest file as well (3.0: it was said not to
    // be a backup, and could be opened nowhere).
    isHostShare = ConnectionShareService.isShareFile(bytes);
    // A file no password opens (not a backup, a newer one, cut short, its
    // header damaged) is said as what it is before a password is asked for
    // (3.4.2: it was asked for, and then called wrong).
    final cannotOpen = isHostShare ? null : BackupService.kindOf(bytes);
    if (cannotOpen != null) {
      if (context.mounted) {
        showTopSnackBar(context, l10n.settingsImportFailed(cannotOpen.said), isError: true, details: cannotOpen.detail);
      }
      return;
    }
    needsPassword = BackupService.isEncryptedBackup(bytes);
    // v2 = unencrypted JSON (also what "export without a password" writes).
    isUnencrypted = bytes.length >= 5 && bytes[4] == 2;
  } catch (e) {
    // Why, in the app's language, with what was thrown to copy (it said
    // "Failed:" and the raw error).
    if (context.mounted) {
      showTopSnackBar(
        context,
        l10n.settingsImportFailed(sftpErrorMessage(e, name: p.basename(filePath), op: SftpOp.download)),
        isError: true,
        details: '$e',
      );
    }
    return;
  }

  if (isHostShare) {
    if (context.mounted) await offerHostShareFromRestore(context, filePath);
    return;
  }

  if (isUnencrypted) {
    if (!context.mounted) return;
    final sure = await _confirmUnprotected(
      context,
      title: l10n.backupUnprotectedImportTitle,
      body: l10n.backupUnprotectedImportBody,
      checkboxLabel: l10n.backupUnprotectedImportUnderstand,
      confirmLabel: l10n.accountImportAction,
    );
    if (sure != true || !context.mounted) return;
  }

  final service = container.read(backupServiceProvider);
  // Loop so a wrong password re-prompts instead of stranding the user.
  String password = '';
  while (true) {
    if (needsPassword) {
      if (!context.mounted) return;
      final pw = await showZestInputDialog(
        context: context,
        title: l10n.accountImport,
        icon: LucideIcons.upload,
        fieldLabel: l10n.accountBackupPassword,
        hintText: l10n.accountBackupPassword,
        obscureText: true,
        confirmLabel: l10n.accountImportAction,
      );
      if (pw == null) return; // user cancelled
      password = pw;
    }
    if (!context.mounted) return;
    final result = await service.importBackup(filePath, password,
        allowLegacyUnencrypted: isUnencrypted,
        // What it would do is said before anything is written.
        confirm: (preview) async => context.mounted ? showRestorePreview(context, preview) : null);
    if (!context.mounted || result.cancelled) return;

    if (result.success) {
      showTopSnackBar(
        context,
        l10n.settingsBackupRestored(result.recordCount),
        isSuccess: true,
      );
      return;
    }
    final err = result.error ?? '';
    // Re-prompt on a password failure for an encrypted file; otherwise report.
    if (needsPassword && result.passwordWrong) {
      showTopSnackBar(context, l10n.settingsImportFailed(err), isError: true, details: result.detail);
      continue;
    }
    showTopSnackBar(context, l10n.settingsImportFailed(err), isError: true, details: result.detail);
    return;
  }
}
