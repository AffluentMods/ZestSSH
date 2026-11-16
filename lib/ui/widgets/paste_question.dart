import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/hidden_characters.dart';

/// The line breaks in [text]: a CR LF, a CR and an LF are one each.
int pasteLineBreaks(String text) => RegExp(r'\r\n|\r|\n').allMatches(text).length;

/// Before [text] is pasted into [terminal]: where its shell runs a line the
/// moment it is pasted (it has not asked for bracketed paste, with which it
/// waits for Enter) and the text has a line break, the person is asked, the
/// text shown. True to paste. (Found 16 October 2026 in the client's security
/// review: on a computer, and by a phone's paste keys, a paste of several
/// lines ran them all, unasked.)
Future<bool> askBeforeLinesRun(BuildContext context, Terminal terminal, String text) async {
  if (terminal.bracketedPasteMode || pasteLineBreaks(text) == 0) return true;
  if (!context.mounted) return false;
  return showPasteQuestion(context, text, runs: true);
}

/// The question before a paste: its lines and characters and its start, and
/// where [runs], that each line runs as it is pasted. True to paste.
Future<bool> showPasteQuestion(BuildContext context, String text, {required bool runs}) async {
  final l10n = AppLocalizations.of(context)!;
  final breaks = pasteLineBreaks(text);
  final shown = text.replaceAll(RegExp(r'\r\n|\r'), '\n');
  // Read on its own lines; what would draw it wrongly is made visible.
  final preview = commandForQuestion(shown, max: 201, keepLines: true);
  // The app's dialog (the dialog rules, 3.4): what runs as it is pasted is
  // said in its amber sentence; the text in its box; one footer.
  final answer = await showZestModal<bool>(
    context: context,
    size: ZestModalSize.standard,
    child: Builder(
      builder: (context) => ZestDialogShell(
        key: const ValueKey('paste-question'),
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.clipboardPaste,
        title: l10n.terminalConfirmPaste,
        maxWidth: 520,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (runs) ...[
              ZestCallout(l10n.terminalPasteRunsLines(breaks), key: const ValueKey('paste-question-runs')),
              const SizedBox(height: 12),
            ],
            Text(
              l10n.terminalPasteStats(breaks + 1, text.length),
              style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(maxHeight: 150),
              decoration: BoxDecoration(
                color: AppColors.v3Background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.v3BorderSubtle),
              ),
              child: SingleChildScrollView(
                child: Text(
                  preview,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: AppColors.v3TextPrimary),
                ),
              ),
            ),
          ],
        ),
        secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(context, false)),
        primaryAction: (label: l10n.terminalPaste, icon: null, onPressed: () => Navigator.pop(context, true)),
      ),
    ),
  );
  return answer == true;
}
