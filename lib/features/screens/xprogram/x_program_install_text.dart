// What is said of an X program's host that lacks Xvnc or xauth (ZS-1809), where
// a failed connection is said: the sentence, then the install command on a line
// of its own, in the terminal's type, with a button that copies it. The command
// stood in the sentence's own type, to be selected by hand out of a dialog.
//
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/screens/xprogram/x_program_script.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// [text] as its parts where it holds one of the install commands the app
/// knows ([xProgramInstallCommands]): what stands before it, the command, and
/// what stands after it (the error's code). Null for any other text.
({String before, String command, String after})? xProgramInstallParts(String text) {
  for (final command in xProgramInstallCommands) {
    final at = text.indexOf(command);
    if (at < 0) continue;
    return (
      before: text.substring(0, at).trimRight(),
      command: command,
      after: text.substring(at + command.length).trim(),
    );
  }
  return null;
}

/// A failure's description: as plain text in [style], or, where it holds an
/// install command, with the command in a box of its own that copies.
class FailureDescription extends StatelessWidget {
  const FailureDescription(this.text, {super.key, this.textKey, required this.style, this.textAlign});

  /// The key of the sentence itself (the whole text where it holds no command).
  final Key? textKey;

  final String text;
  final TextStyle style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final parts = xProgramInstallParts(text);
    if (parts == null) return Text(text, key: textKey, style: style, textAlign: textAlign);
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (parts.before.isNotEmpty) Text(parts.before, key: textKey, style: style, textAlign: textAlign),
        const SizedBox(height: 10),
        Container(
          key: const ValueKey('failure-install-command'),
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          decoration: BoxDecoration(
            color: AppColors.v3Surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  parts.command,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, color: AppColors.v3TextPrimary),
                ),
              ),
              IconButton(
                key: const ValueKey('failure-install-command-copy'),
                tooltip: l10n.hostKeyChangedCopyCommand,
                icon: const Icon(LucideIcons.copy, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: parts.command));
                  if (context.mounted) showTopSnackBar(context, l10n.hostKeyChangedCommandCopied);
                },
              ),
            ],
          ),
        ),
        if (parts.after.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(parts.after, style: style.copyWith(fontSize: (style.fontSize ?? 14) - 1.5), textAlign: textAlign),
        ],
      ],
    );
  }
}
