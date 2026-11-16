import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/key_agent.dart';
import 'package:zestssh/features/keys/key_export_save.dart';
import 'package:zestssh/services/local_state_store.dart' show localStateStoreProvider;
import 'package:zestssh/features/keys/key_passphrase.dart';
import 'package:zestssh/features/orchards/activity/activity_notes.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show ActivityKind;
import 'package:zestssh/features/orchards/rules/reveal_gate.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/core_providers.dart' show secureStorageProvider;
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/services/key_import_service.dart' show isSecurityKeyFile;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/platform_utils.dart' show isDesktopPlatform;

// The Keys page's actions on a key's private part (3.0):
// Add to agent, Export and its passphrase.
// Each first passes the gates the old editor's export passes: a team key
// whose secrets stay where they are (at Connect) is not opened here, a team
// whose rules forbid exports keeps its keys in the vault, and a vault that
// asks again asks first (confirmItIsYou). Recording mode asks before a file
// that holds a real key is written.

/// Whether [key]'s private key may be opened here now; [leavesVault]: it
/// goes out of the app (an export, the system's agent). Says why not.
Future<bool> mayUseKeySecretNow(BuildContext context, WidgetRef ref, Identity key, {required bool leavesVault}) async {
  final l10n = AppLocalizations.of(context)!;
  if (leavesVault && !mayExportKeysScreenSpace(ref, watch: false)) {
    showTopSnackBar(context, l10n.keysAgentTeamNotAllowed, isError: true);
    return false;
  }
  if (!await mayRevealKeyNow(ref, key.id)) {
    if (context.mounted) showTopSnackBar(context, l10n.orchardWriteNotAllowed, isError: true);
    return false;
  }
  if (await revealAsksAgainNow(ref, key.id)) {
    if (!context.mounted || !await confirmItIsYou(context, ref)) return false;
  }
  return context.mounted;
}

/// Finds out whether [key] has a passphrase (its PROTECTION row's Check):
/// its private key is read for that alone, and what it is is kept on the
/// device ([KeyPassphraseFlags]).
Future<void> checkKeyPassphrase(BuildContext context, WidgetRef ref, Identity key) async {
  if (!await mayUseKeySecretNow(context, ref, key, leavesVault: false)) return;
  final kept = await ref.read(keyPassphraseServiceProvider).keptKeyOf(key);
  await ref.read(keyPassphraseFlagsProvider).rememberOf(key.id, kept.pem);
  ref.invalidate(keyPassphraseStatesProvider);
}

/// A note in a dialog's body: an icon and its words, in [color].
class KeyDialogNote extends StatelessWidget {
  const KeyDialogNote({super.key, required this.icon, required this.text, this.color, this.details});

  final IconData icon;
  final String text;
  final Color? color;

  /// What failed, behind Copy details.
  final String? details;

  @override
  Widget build(BuildContext context) {
    final c = color ?? ZestTokens.textTertiary;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 14, color: c)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: c)),
                if (details != null) CopyDetailsButton(detail: details!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A new passphrase, typed twice ([NewPassphraseFields.matches]).
class NewPassphraseFields extends StatelessWidget {
  const NewPassphraseFields({
    super.key,
    required this.first,
    required this.second,
    required this.showMismatch,
    this.onChanged,
    this.autofocus = true,
    this.keyPrefix = 'keys-passphrase',
  });

  final TextEditingController first;
  final TextEditingController second;
  final bool showMismatch;
  final VoidCallback? onChanged;
  final bool autofocus;
  final String keyPrefix;

  /// Both typed, and the same.
  static bool matches(TextEditingController a, TextEditingController b) => a.text.isNotEmpty && a.text == b.text;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestTextField(
          key: ValueKey('$keyPrefix-new'),
          controller: first,
          label: l10n.keysActNewPassphrase,
          obscureText: true,
          autofocus: autofocus,
          onChanged: (_) => onChanged?.call(),
        ),
        const SizedBox(height: 12),
        ZestTextField(
          key: ValueKey('$keyPrefix-again'),
          controller: second,
          label: l10n.keysActTypeAgain,
          obscureText: true,
          autofocus: false,
          onChanged: (_) => onChanged?.call(),
          errorText: showMismatch ? l10n.keysActMismatch : null,
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Add to agent
// ══════════════════════════════════════════════════════════════════

/// Gives [key] to the computer's SSH agent, after the gates
/// ([mayUseKeySecretNow]). Not on a phone (no system agent).
Future<void> showAddToAgent(BuildContext context, WidgetRef ref, Identity key) async {
  if (ref.read(systemAgentProvider) == null) return;
  if (!await mayUseKeySecretNow(context, ref, key, leavesVault: true) || !context.mounted) return;
  await showZestModal<void>(context: context, size: ZestModalSize.standard, child: AddToAgentDialog(keyToAdd: key));
}

class AddToAgentDialog extends ConsumerStatefulWidget {
  const AddToAgentDialog({super.key, required this.keyToAdd, this.windows});

  final Identity keyToAdd;

  /// Whether the agent is Windows' (which keeps keys until removed); the
  /// device's own where not given (tests).
  final bool? windows;

  @override
  ConsumerState<AddToAgentDialog> createState() => _AddToAgentDialogState();
}

class _AddToAgentDialogState extends ConsumerState<AddToAgentDialog> {
  var _lifetime = AgentKeyLifetime.untilAgentEnds;
  final _passphrase = TextEditingController();
  var _askPassphrase = false;
  var _busy = false;
  String? _error;
  String? _errorDetails;
  String? _passphraseError;

  bool get _windows => widget.windows ?? Platform.isWindows;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  String _label(AppLocalizations l10n, AgentKeyLifetime l) => switch (l) {
        AgentKeyLifetime.untilAgentEnds => _windows ? l10n.keysAgentUntilRemoved : l10n.keysAgentUntilSignOut,
        AgentKeyLifetime.oneHour => l10n.keysAgentOneHour,
        AgentKeyLifetime.eightHours => l10n.keysAgentEightHours,
      };

  Future<void> _add() async {
    final l10n = AppLocalizations.of(context)!;
    final agent = ref.read(systemAgentProvider);
    if (agent == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _errorDetails = null;
      _passphraseError = null;
    });
    final key = widget.keyToAdd;
    try {
      final kept = await ref.read(keyPassphraseServiceProvider).keptKeyOf(key);
      final typed = _passphrase.text;
      // Taken back when this profile closes for another's, unless it was
      // in the agent already.
      await giveKeyToAgent(agent, ref.read(localStateStoreProvider), key, kept.pem,
          passphrase: typed.isNotEmpty ? typed : kept.kept,
          lifetime: _lifetime,
          keychain: ref.read(secureStorageProvider));
      // The key is what the agent holds now: kept on the device as sealed
      // or not, since it was read.
      await ref.read(keyPassphraseFlagsProvider).rememberOf(key.id, kept.pem);
      ref.invalidate(systemAgentKeysProvider);
      ref.invalidate(keyPassphraseStatesProvider);
      if (!mounted) return;
      final name = Redactable.keyName(key.label).displayIn(ref);
      Navigator.of(context).pop();
      showTopSnackBar(context, l10n.keysAgentAdded(name), isSuccess: true);
    } on AgentAddFailed catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        switch (e.why) {
          case AgentAddRefusal.needsPassphrase:
            _askPassphrase = true;
          case AgentAddRefusal.wrongPassphrase:
            _askPassphrase = true;
            _passphraseError = l10n.keysActWrongPassphrase;
          case AgentAddRefusal.noAgent:
            _error = l10n.keysAgentNoAgent;
          case AgentAddRefusal.pipeNotYours:
            _error = ErrorCodes.withCode(l10n.agentPipeNotYours, ErrorCodes.agentPipeNotYours);
          case AgentAddRefusal.refused:
            _error = _lifetime.lifetime == null
                ? l10n.keysAgentRefused
                : l10n.keysAgentRefusedTimeLimit(_label(l10n, AgentKeyLifetime.untilAgentEnds));
          case AgentAddRefusal.noKey:
            _error = l10n.keysActNoPrivateKey;
        }
        if (_error != null) {
          _errorDetails = ErrorReport.build(what: _error!, where: 'Keys, Add to agent', error: e.cause ?? e);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.keysAgentRefused;
        _errorDetails = ErrorReport.build(what: _error!, where: 'Keys, Add to agent', error: e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = Redactable.keyName(widget.keyToAdd.label).displayIn(ref);
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.cpu,
      title: l10n.keysAgentAddTitle,
      subtitle: l10n.keysAgentAddSubtitle(name),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestFieldLabel(l10n.keysAgentKeepIt),
          const SizedBox(height: 6),
          ZestSelect<AgentKeyLifetime>(
            key: const ValueKey('keys-agent-lifetime'),
            value: _lifetime,
            items: [for (final l in AgentKeyLifetime.values) ZestSelectItem(l, _label(l10n, l))],
            onChanged: _busy ? null : (l) => setState(() => _lifetime = l),
          ),
          if (_windows && _lifetime == AgentKeyLifetime.untilAgentEnds) ...[
            const SizedBox(height: 8),
            KeyDialogNote(icon: LucideIcons.info, text: l10n.keysAgentWindowsNote),
          ],
          if (_askPassphrase) ...[
            const SizedBox(height: 14),
            KeyDialogNote(icon: LucideIcons.lock, text: l10n.keysAgentNeedsPassphrase),
            const SizedBox(height: 8),
            ZestTextField(
              key: const ValueKey('keys-agent-passphrase'),
              controller: _passphrase,
              label: l10n.identityPassphrase,
              obscureText: true,
              errorText: _passphraseError,
              onSubmit: _busy ? null : _add,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            KeyDialogNote(
              key: const ValueKey('keys-agent-error'),
              icon: LucideIcons.alertTriangle,
              text: _error!,
              color: ZestTokens.statusCritical,
              details: _errorDetails,
            ),
          ],
        ],
      ),
      primaryKey: const ValueKey('keys-agent-add'),
      primaryAction: (label: l10n.keysAgentAddButton, icon: LucideIcons.plus, onPressed: _busy ? null : _add),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Export
// ══════════════════════════════════════════════════════════════════

/// What an export writes.
enum KeyExportFiles { both, privateOnly, publicOnly }

/// The exported private key file's passphrase.
enum KeyExportProtection { asKept, newPassphrase, none }

/// Exports [key] as OpenSSH files, after the gates ([mayUseKeySecretNow]).
/// On a computer they are saved where the person says in the system's save
/// dialog ([saveKeyFilesOnComputer]; [pick] stands in for the dialog in a
/// test); on a phone or a tablet they go to the share sheet. [onComputer]
/// says which, for a test; [onWrite] writes the files in place of both.
Future<void> showKeyExport(
  BuildContext context,
  WidgetRef ref,
  Identity key, {
  KeyExportWriter? onWrite,
  bool? onComputer,
  KeySavePicker? pick,
}) async {
  if (!await mayUseKeySecretNow(context, ref, key, leavesVault: true) || !context.mounted) return;
  await showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: KeyExportDialog(keyToExport: key, onWrite: onWrite, onComputer: onComputer, pick: pick),
  );
}

/// Writes exported files: each a name and what it holds; [written] is
/// called once they are written.
typedef KeyExportWriter = Future<void> Function(Map<String, List<int>> files, {String? subject, void Function()? written});

/// The file names an export writes for [key]: its name made safe for a
/// file, its kind, and `.pub` for its public key.
({String private, String public}) keyExportFileNames(Identity key) {
  final safe = key.label.trim().replaceAll(RegExp(r'[^\w\-]'), '_');
  final kind = (key.keyType ?? '').toLowerCase();
  final suffix = kind.contains('ed25519')
      ? 'ed25519'
      : kind.contains('ecdsa') || kind.contains('nistp')
          ? 'ecdsa'
          : kind.contains('rsa')
              ? 'rsa'
              : 'key';
  final base = '${safe.isEmpty ? 'key' : safe}_$suffix';
  return (private: base, public: '$base.pub');
}

class KeyExportDialog extends ConsumerStatefulWidget {
  const KeyExportDialog({super.key, required this.keyToExport, this.onWrite, this.onComputer, this.pick});

  final Identity keyToExport;
  final KeyExportWriter? onWrite;

  /// Whether the files are saved through a save dialog (a computer) or
  /// handed to the share sheet (a phone, a tablet); the device's own where
  /// null.
  final bool? onComputer;

  /// What asks where the file goes on a computer; the system's save dialog
  /// where null.
  final KeySavePicker? pick;

  @override
  ConsumerState<KeyExportDialog> createState() => _KeyExportDialogState();
}

class _KeyExportDialogState extends ConsumerState<KeyExportDialog> {
  var _files = KeyExportFiles.both;
  var _protection = KeyExportProtection.asKept;
  final _new = TextEditingController();
  final _again = TextEditingController();
  final _current = TextEditingController();
  var _askCurrent = false;
  var _busy = false;
  var _triedMismatch = false;
  String? _currentError;
  String? _error;
  String? _errorDetails;

  /// Whether the key is a security key's key file, which holds no secret
  /// (only the key handle and the public key) and signs in only with the
  /// security key itself: it gets a note that says so, not the private key's
  /// warnings. Read from the key file once the dialog is open (the gates
  /// before it have let its secret be used).
  var _securityKey = false;

  @override
  void initState() {
    super.initState();
    unawaited(_readWhatKind());
  }

  Future<void> _readWhatKind() async {
    final key = widget.keyToExport;
    if (key.authMethod != 'publicKey' || key.usesAgent) return;
    try {
      final pem = (await ref.read(keyPassphraseServiceProvider).keptKeyOf(key)).pem;
      if (!mounted || pem == null || pem.isEmpty) return;
      final securityKey = isSecurityKeyFile(pem);
      if (securityKey != _securityKey) setState(() => _securityKey = securityKey);
    } catch (_) {
      // Not read: the private key's warnings stay, the safe side.
    }
  }

  @override
  void dispose() {
    _new.dispose();
    _again.dispose();
    _current.dispose();
    super.dispose();
  }

  bool get _private => _files != KeyExportFiles.publicOnly;

  bool get _ready =>
      !_busy && (!_private || _protection != KeyExportProtection.newPassphrase || NewPassphraseFields.matches(_new, _again));

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context)!;
    if (_private && _protection == KeyExportProtection.newPassphrase && !NewPassphraseFields.matches(_new, _again)) {
      setState(() => _triedMismatch = true);
      return;
    }
    // A file that holds the real key, while recording: asked first.
    if (!await confirmRevealWhileRecording(context, ref) || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _errorDetails = null;
      _currentError = null;
    });
    final key = widget.keyToExport;
    final names = keyExportFileNames(key);
    try {
      final files = <String, List<int>>{};
      if (_private) {
        final kept = await ref.read(keyPassphraseServiceProvider).keptKeyOf(key);
        final pem = kept.pem;
        if (pem == null || pem.isEmpty) throw const PassphraseChangeFailed(PassphraseChangeRefusal.noKey);
        final String out;
        if (_protection == KeyExportProtection.asKept) {
          out = pem;
        } else {
          final sealed = pemIsSealed(pem) ?? false;
          final typed = _current.text;
          final opener = sealed ? (typed.isNotEmpty ? typed : kept.kept) : null;
          if (sealed && (opener == null || opener.isEmpty)) {
            throw const PassphraseChangeFailed(PassphraseChangeRefusal.needsCurrent);
          }
          out = await resealPrivateKey(
            pem,
            current: opener,
            next: _protection == KeyExportProtection.newPassphrase ? _new.text : null,
          );
        }
        files[names.private] = utf8.encode(out.endsWith('\n') ? out : '$out\n');
      }
      if (_files != KeyExportFiles.privateOnly) {
        final line = await ref.read(identityCrudProvider).publicLineOf(key);
        if (line != null && line.isNotEmpty) files[names.public] = utf8.encode('$line\n');
      }
      if (files.isEmpty) throw StateError(l10n.zestKeysNoPublicKey);
      if (!mounted) return;
      if (_private) {
        unawaited(noteScreenActivity(ref, ActivityKind.export, itemKind: 'key', itemKey: key.id, name: key.label));
      }
      // A computer saves them where the person says, and says where they
      // went; the share sheet is a phone's (on Linux it throws for
      // files, on Windows the files were deleted under the Share window).
      if (widget.onWrite == null && (widget.onComputer ?? isDesktopPlatform)) {
        final saved = await saveKeyFilesOnComputer(
          files,
          pick: widget.pick ?? pickKeyFileWithSaveDialog,
          title: l10n.keysExportSaveDialog,
        );
        if (!mounted) return;
        if (saved == null) {
          // Cancelled in the save dialog: nothing written, the question stays.
          setState(() => _busy = false);
          return;
        }
        final navigator = Navigator.of(context);
        navigator.pop();
        await showFileSavedDialog(
          navigator.context,
          title: l10n.keysExportSavedTitle,
          message: saved.length > 1
              ? l10n.keysExportSavedBesideBody(saved[1].split(Platform.pathSeparator).last)
              : _private
                  ? (_securityKey ? l10n.identityExportSecurityKeyNote : l10n.keysExportPrivateWarning)
                  : l10n.keysExportSavedPublicBody,
          path: saved.first,
        );
        return;
      }
      final write = widget.onWrite ?? ConnectionShareService.shareFiles;
      final pop = Navigator.of(context);
      final shown = context;
      await write(
        files,
        subject: l10n.identityEditShareSubject(key.label),
        written: () {
          if (!shown.mounted) return;
          final list = files.keys.toList();
          showTopSnackBar(
            shown,
            list.length == 1
                ? l10n.identityEditExportedFileMessage(list.first)
                : l10n.identityEditExportedFilesMessage(list[0], list[1]),
            isSuccess: true,
            duration: const Duration(seconds: 4),
          );
        },
      );
      if (mounted) pop.pop();
    } on PassphraseChangeFailed catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        switch (e.why) {
          case PassphraseChangeRefusal.needsCurrent:
            _askCurrent = true;
          case PassphraseChangeRefusal.wrongCurrent:
            _askCurrent = true;
            _currentError = l10n.keysActWrongPassphrase;
          case PassphraseChangeRefusal.noKey:
            _error = l10n.keysActNoPrivateKey;
            _errorDetails = ErrorReport.build(what: _error!, where: 'Keys, Export', error: e.cause ?? e);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.keysExportFailed;
        _errorDetails = ErrorReport.build(what: _error!, where: 'Keys, Export', error: e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = Redactable.keyName(widget.keyToExport.label).displayIn(ref);
    final hasPrivate = widget.keyToExport.authMethod == 'publicKey' && !widget.keyToExport.usesAgent;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.download,
      title: l10n.keysExportTitle,
      subtitle: l10n.keysExportSubtitle(name),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestFieldLabel(l10n.keysExportWhat),
          const SizedBox(height: 6),
          ZestSelect<KeyExportFiles>(
            key: const ValueKey('keys-export-files'),
            value: hasPrivate ? _files : KeyExportFiles.publicOnly,
            items: [
              if (hasPrivate) ZestSelectItem(KeyExportFiles.both, l10n.keysExportBoth),
              if (hasPrivate) ZestSelectItem(KeyExportFiles.privateOnly, l10n.keysExportPrivateOnly),
              ZestSelectItem(KeyExportFiles.publicOnly, l10n.keysExportPublicOnly),
            ],
            onChanged: _busy || !hasPrivate ? null : (f) => setState(() => _files = f),
          ),
          if (_private && hasPrivate) ...[
            const SizedBox(height: 14),
            ZestFieldLabel(l10n.keysExportProtection),
            const SizedBox(height: 6),
            ZestSelect<KeyExportProtection>(
              key: const ValueKey('keys-export-protection'),
              value: _protection,
              items: [
                ZestSelectItem(KeyExportProtection.asKept, l10n.keysExportAsKept),
                ZestSelectItem(KeyExportProtection.newPassphrase, l10n.keysExportNewPassphrase),
                ZestSelectItem(KeyExportProtection.none, l10n.keysExportNoPassphrase),
              ],
              onChanged: _busy ? null : (p) => setState(() => _protection = p),
            ),
            if (_protection == KeyExportProtection.newPassphrase) ...[
              const SizedBox(height: 12),
              NewPassphraseFields(
                first: _new,
                second: _again,
                keyPrefix: 'keys-export-passphrase',
                showMismatch: _again.text.isNotEmpty && _new.text != _again.text || _triedMismatch && !NewPassphraseFields.matches(_new, _again),
                onChanged: () => setState(() {}),
              ),
            ],
            if (_askCurrent && _protection != KeyExportProtection.asKept) ...[
              const SizedBox(height: 12),
              ZestTextField(
                key: const ValueKey('keys-export-current'),
                controller: _current,
                label: l10n.keysActCurrentPassphrase,
                obscureText: true,
                errorText: _currentError,
              ),
            ],
            const SizedBox(height: 12),
            if (_securityKey)
              KeyDialogNote(
                key: const ValueKey('keys-export-security-key-note'),
                icon: LucideIcons.info,
                text: l10n.identityExportSecurityKeyNote,
              )
            else
              KeyDialogNote(
                key: const ValueKey('keys-export-private-warning'),
                icon: LucideIcons.shieldAlert,
                text: l10n.keysExportPrivateWarning,
                color: ZestTokens.statusWarning,
              ),
            // (A security key's file written open still signs in with nothing but the security key.)
            if (_protection == KeyExportProtection.none && !_securityKey)
              KeyDialogNote(
                key: const ValueKey('keys-export-open-warning'),
                icon: LucideIcons.alertTriangle,
                text: l10n.keysExportOpenWarning,
                color: ZestTokens.statusWarning,
              ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            KeyDialogNote(
              key: const ValueKey('keys-export-error'),
              icon: LucideIcons.alertTriangle,
              text: _error!,
              color: ZestTokens.statusCritical,
              details: _errorDetails,
            ),
          ],
        ],
      ),
      primaryKey: const ValueKey('keys-export-go'),
      primaryAction: (label: l10n.settingsExportLabel, icon: LucideIcons.download, onPressed: _ready ? _export : null),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Passphrase: add, change, remove
// ══════════════════════════════════════════════════════════════════

/// What the passphrase dialog does.
enum KeyPassphraseMode { add, change, remove }

/// Adds, changes or takes off [key]'s passphrase, after the gates (a key
/// this account may change, whose secrets it may open).
Future<void> showKeyPassphrase(BuildContext context, WidgetRef ref, Identity key, KeyPassphraseMode mode) async {
  if (!mayChangeItem(ref, 'key', key.id, watch: false)) {
    showTopSnackBar(context, AppLocalizations.of(context)!.orchardWriteNotAllowed, isError: true);
    return;
  }
  if (!await mayUseKeySecretNow(context, ref, key, leavesVault: false) || !context.mounted) return;
  await showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: KeyPassphraseDialog(keyToChange: key, mode: mode),
  );
}

class KeyPassphraseDialog extends ConsumerStatefulWidget {
  const KeyPassphraseDialog({super.key, required this.keyToChange, required this.mode});

  final Identity keyToChange;
  final KeyPassphraseMode mode;

  @override
  ConsumerState<KeyPassphraseDialog> createState() => _KeyPassphraseDialogState();
}

class _KeyPassphraseDialogState extends ConsumerState<KeyPassphraseDialog> {
  final _new = TextEditingController();
  final _again = TextEditingController();
  final _current = TextEditingController();
  late KeyPassphraseMode _mode = widget.mode;

  /// Read as the dialog opens: whether the key is sealed, and whether a
  /// passphrase is kept with it (which opens it, so none is asked for).
  bool? _sealed;
  bool _keptOne = false;
  bool _keep = true;
  var _busy = false;
  var _triedMismatch = false;
  String? _currentError;
  String? _error;
  String? _errorDetails;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final kept = await ref.read(keyPassphraseServiceProvider).keptKeyOf(widget.keyToChange);
    if (!mounted) return;
    final sealed = pemIsSealed(kept.pem);
    if (sealed != null) await ref.read(keyPassphraseFlagsProvider).rememberOf(widget.keyToChange.id, kept.pem);
    if (!mounted) return;
    setState(() {
      _sealed = sealed;
      _keptOne = kept.kept != null && kept.kept!.isNotEmpty;
      // As connecting is now: a passphrase kept where one was, or for a
      // key that had none (as a key imported with its passphrase keeps it).
      _keep = sealed != true || _keptOne;
      // What the device thought may be out of date (a key changed on
      // another device): the dialog does what the key needs.
      if (sealed == true && _mode == KeyPassphraseMode.add) _mode = KeyPassphraseMode.change;
      if (sealed == false && _mode != KeyPassphraseMode.add) _mode = KeyPassphraseMode.add;
      if (sealed == null) {
        _error = AppLocalizations.of(context)!.keysActNoPrivateKey;
      }
    });
    ref.invalidate(keyPassphraseStatesProvider);
  }

  @override
  void dispose() {
    _new.dispose();
    _again.dispose();
    _current.dispose();
    super.dispose();
  }

  bool get _needsCurrent => _sealed == true && !_keptOne;

  bool get _ready =>
      !_busy &&
      _sealed != null &&
      (!_needsCurrent || _current.text.isNotEmpty) &&
      (_mode == KeyPassphraseMode.remove || NewPassphraseFields.matches(_new, _again));

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (_mode != KeyPassphraseMode.remove && !NewPassphraseFields.matches(_new, _again)) {
      setState(() => _triedMismatch = true);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _errorDetails = null;
      _currentError = null;
    });
    try {
      await ref.read(keyPassphraseServiceProvider).change(
            widget.keyToChange,
            current: _current.text.isEmpty ? null : _current.text,
            next: _mode == KeyPassphraseMode.remove ? null : _new.text,
            keepWithKey: _keep,
          );
      if (!mounted) return;
      final said = switch (_mode) {
        KeyPassphraseMode.add => l10n.keysPassAdded,
        KeyPassphraseMode.change => l10n.keysPassChanged,
        KeyPassphraseMode.remove => l10n.keysPassRemoved,
      };
      Navigator.of(context).pop();
      showTopSnackBar(context, said, isSuccess: true);
    } on PassphraseChangeFailed catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        switch (e.why) {
          case PassphraseChangeRefusal.needsCurrent:
            _keptOne = false;
          case PassphraseChangeRefusal.wrongCurrent:
            // A kept passphrase that no longer opens the key: asked for.
            _keptOne = false;
            _currentError = l10n.keysActWrongPassphrase;
          case PassphraseChangeRefusal.noKey:
            _error = l10n.keysActNoPrivateKey;
            _errorDetails = ErrorReport.build(what: l10n.keysPassFailed, where: 'Keys, passphrase', error: e.cause ?? e);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.keysPassFailed;
        _errorDetails = ErrorReport.build(what: _error!, where: 'Keys, passphrase', error: e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = Redactable.keyName(widget.keyToChange.label).displayIn(ref);
    final (title, button) = switch (_mode) {
      KeyPassphraseMode.add => (l10n.keysPassAddTitle, l10n.keysPassAddButton),
      KeyPassphraseMode.change => (l10n.keysPassChangeTitle, l10n.keysPassChangeButton),
      KeyPassphraseMode.remove => (l10n.keysPassRemoveTitle, l10n.keysPassRemoveButton),
    };
    final removing = _mode == KeyPassphraseMode.remove;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: removing ? ZestDialogTone.destructive : ZestDialogTone.info,
      icon: removing ? LucideIcons.unlock : LucideIcons.lock,
      title: title,
      subtitle: l10n.keysPassSubtitle(name),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_sealed == null && _error == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else ...[
            if (_sealed == true && _keptOne)
              KeyDialogNote(key: const ValueKey('keys-passphrase-kept'), icon: LucideIcons.checkCircle2, text: l10n.keysPassUsesKept),
            if (_needsCurrent) ...[
              ZestTextField(
                key: const ValueKey('keys-passphrase-current'),
                controller: _current,
                label: l10n.keysActCurrentPassphrase,
                obscureText: true,
                errorText: _currentError,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
            ],
            if (removing)
              KeyDialogNote(icon: LucideIcons.alertTriangle, text: l10n.keysPassRemoveBody, color: ZestTokens.statusWarning)
            else ...[
              NewPassphraseFields(
                first: _new,
                second: _again,
                autofocus: !_needsCurrent,
                showMismatch: _again.text.isNotEmpty && _new.text != _again.text || _triedMismatch && !NewPassphraseFields.matches(_new, _again),
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(child: Text(l10n.keysPassKeepWithKey, style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary))),
                  ZestSwitch(
                    key: const ValueKey('keys-passphrase-keep'),
                    value: _keep,
                    onChanged: _busy ? null : (v) => setState(() => _keep = v),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _keep ? l10n.keysPassKeepOn : l10n.keysPassKeepOff,
                key: const ValueKey('keys-passphrase-keep-said'),
                style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary),
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            KeyDialogNote(
              key: const ValueKey('keys-passphrase-error'),
              icon: LucideIcons.alertTriangle,
              text: _error!,
              color: ZestTokens.statusCritical,
              details: _errorDetails,
            ),
          ],
        ],
      ),
      primaryKey: const ValueKey('keys-passphrase-save'),
      primaryDanger: removing,
      primaryAction: (label: button, icon: removing ? LucideIcons.unlock : LucideIcons.lock, onPressed: _ready ? _save : null),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}
