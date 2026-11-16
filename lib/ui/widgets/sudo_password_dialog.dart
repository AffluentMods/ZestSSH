import 'package:flutter/material.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sudo_runner.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The question before something runs as root with sudo (3.4): the file
/// editor's Save as root, the files' Retry with sudo. It says what will run
/// and where ([body]), and takes the sudo password for this one time: typed
/// each time, never stored or synced, out of its field as soon as it is
/// used, and gone with the dialog. [run] does the work with it; what it
/// throws is said in the dialog ([said]), which stays, so a password typed
/// wrong is typed again. True where [run] finished.
Future<bool> askSudoPassword(
  BuildContext context, {
  required String title,
  String? subtitle,
  required Widget body,
  required String helperText,
  required String actionLabel,
  required Future<void> Function(String password) run,
  required String Function(Object error) said,
  Key fieldKey = const ValueKey('sudo-password'),
  Key primaryKey = const ValueKey('sudo-run'),
}) async {
  final key = GlobalKey<_SudoPasswordDialogState>();
  final done = await showZestModal<bool>(
    context: context,
    size: ZestModalSize.compact,
    onDismissAttempt: () async => !(key.currentState?.busy ?? false),
    child: _SudoPasswordDialog(
      key: key,
      title: title,
      subtitle: subtitle,
      body: body,
      helperText: helperText,
      actionLabel: actionLabel,
      run: run,
      said: said,
      fieldKey: fieldKey,
      primaryKey: primaryKey,
    ),
  );
  return done ?? false;
}

/// What sudo's refusal is, in [l10n]'s words, with its code ([host] is the
/// host's name as it may be shown); null for what is no refusal of sudo's.
String? sudoRefusalSaid(Object error, AppLocalizations l10n, {required String host}) => switch (error) {
  SudoPasswordException(:final code) => ErrorCodes.withCode(l10n.editorSudoWrongPassword, code),
  SudoNotAllowedException(:final said, :final code) => ErrorCodes.withCode(l10n.editorSudoNotAllowed(sudoWordsShown(said)), code),
  SudoUnavailableException(:final code) => ErrorCodes.withCode(l10n.sudoUnavailable(host), code),
  SudoNeedsTerminalException(:final code) => ErrorCodes.withCode(l10n.sudoNeedsTerminal(host), code),
  SudoTimeoutException(:final code) => ErrorCodes.withCode(l10n.sudoNoAnswer, code),
  _ => null,
};

/// What the host or sudo said ([said]: "deploy is not in the sudoers
/// file", "cp: cannot create regular file '/srv/app/x'"), as it may be
/// shown: while the screen is recorded the account's name, the hosts and
/// the folders in it are masked (the 3.4 security review, L3).
String sudoWordsShown(String said) {
  if (!Redactor.instance.enabled) return said;
  var out = said.replaceAllMapped(_sudoUser, (m) => '${m[1]}${Redactor.username(m[2]!)}${m[3]}');
  out = out.replaceAllMapped(_quotedPath, (m) => "'${Redactor.path(m[1]!)}'");
  return Redactor.line(out);
}

final RegExp _sudoUser = RegExp(r'(^|\buser |\n)([A-Za-z0-9._-]+)( is not (?:in the sudoers file|allowed))', multiLine: true);
final RegExp _quotedPath = RegExp(r"'(/[^'\n]*)'");

class _SudoPasswordDialog extends StatefulWidget {
  const _SudoPasswordDialog({
    super.key,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.helperText,
    required this.actionLabel,
    required this.run,
    required this.said,
    required this.fieldKey,
    required this.primaryKey,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final String helperText;
  final String actionLabel;
  final Future<void> Function(String password) run;
  final String Function(Object error) said;
  final Key fieldKey;
  final Key primaryKey;

  @override
  State<_SudoPasswordDialog> createState() => _SudoPasswordDialogState();
}

class _SudoPasswordDialogState extends State<_SudoPasswordDialog> {
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool busy = false;

  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (busy) return;
    final l10n = AppLocalizations.of(context)!;
    if (_password.text.isEmpty) {
      setState(() => _error = l10n.editorSudoNeedsPassword);
      return;
    }
    setState(() {
      busy = true;
      _error = null;
    });
    final typed = _password.text;
    // Typed for this one time: out of the field at once, whatever happens.
    _password.clear();
    try {
      await widget.run(typed);
      if (mounted) zestDialogPop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          _error = widget.said(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.shield,
      title: widget.title,
      subtitle: widget.subtitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.body,
          const SizedBox(height: 14),
          ZestTextField(
            key: widget.fieldKey,
            controller: _password,
            label: l10n.editorSudoPassword,
            obscureText: true,
            autofillHints: const [],
            helperText: widget.helperText,
            errorText: _error,
            onSubmit: _submit,
          ),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: busy ? null : () => zestDialogPop(context, false)),
      primaryKey: widget.primaryKey,
      primaryAction: (label: widget.actionLabel, icon: LucideIcons.shield, onPressed: busy ? null : _submit),
    );
  }
}
