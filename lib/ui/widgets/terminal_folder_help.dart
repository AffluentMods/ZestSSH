import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_folder_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart' show openGuide;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Where the terminal has said no folder (4.0, "Go to the terminal's folder"):
/// why (most shells do not say it), the line that makes bash or zsh say it,
/// each to copy, and the SFTP guide. The same on a computer's SFTP dock and a
/// phone's file browser.
Future<void> showTerminalFolderHelp(BuildContext context, WidgetRef ref) {
  final l10n = AppLocalizations.of(context)!;
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: Builder(
      builder: (ctx) => ZestDialogShell(
        key: const ValueKey('terminal-folder-help'),
        size: ZestModalSize.standard,
        tone: ZestDialogTone.info,
        icon: LucideIcons.folderSearch,
        title: l10n.sftpTerminalFolderNoneTitle,
        subtitle: l10n.sftpTerminalFolderNoneBody,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Label(l10n.sftpTerminalFolderBash),
            const TerminalFolderCopyLine(key: ValueKey('terminal-folder-bash'), text: kTerminalFolderBashLine),
            const SizedBox(height: 12),
            _Label(l10n.sftpTerminalFolderZsh),
            const TerminalFolderCopyLine(key: ValueKey('terminal-folder-zsh'), text: kTerminalFolderZshLine),
            const SizedBox(height: 12),
            Text(
              l10n.sftpTerminalFolderOthers,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary),
            ),
          ],
        ),
        // The guide, where this build has the docs site.
        tertiaryAction: kZestDocsOrigin == ''
            ? null
            : (
                label: l10n.sftpTerminalFolderGuide,
                onPressed: () {
                  zestDialogPop(ctx);
                  openGuide(context, ref, 'sftp');
                },
              ),
        primaryAction: (label: l10n.close, icon: null, onPressed: () => zestDialogPop(ctx)),
      ),
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestTokens.textSecondary),
    ),
  );
}

/// A shell line to copy, in the app's monospace, with its copy button.
class TerminalFolderCopyLine extends StatelessWidget {
  const TerminalFolderCopyLine({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 2, 0),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SelectableText(
                text,
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, height: 1.4, color: ZestTokens.textPrimary),
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.copy,
            iconSize: 16,
            color: ZestTokens.textSecondary,
            icon: const Icon(LucideIcons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              showTopSnackBar(context, l10n.sftpTerminalFolderLineCopied, isSuccess: true);
            },
          ),
        ],
      ),
    );
  }
}
