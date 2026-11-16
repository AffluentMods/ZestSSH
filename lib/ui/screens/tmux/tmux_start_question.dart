import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';

/// The question whether to start tmux control mode in the session [sessionId],
/// where its output asked for that with nobody having asked for tmux
/// ([tmuxStartQuestionProvider]): above the terminal, in that session, for as
/// long as it stands. It says what would happen; the output waits for the
/// answer, and no is the plain one (going on typing is a no as well).
class TmuxStartQuestion extends ConsumerWidget {
  const TmuxStartQuestion({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(tmuxStartQuestionProvider(sessionId))) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    void answer(bool start) => ref.read(activeSessionsProvider.notifier).answerTmuxStart(sessionId, start);
    return ShareStateStrip(
      key: ValueKey('tmux-start-question-$sessionId'),
      icon: LucideIcons.layoutGrid,
      text: l10n.tmuxStartQuestion,
      tone: ShareStripTone.warning,
      actions: [
        shareButton(
          key: ValueKey('tmux-start-question-no-$sessionId'),
          label: l10n.tmuxStartQuestionNo,
          kind: ShareButtonKind.primary,
          onPressed: () => answer(false),
          dense: true,
        ),
        shareButton(
          key: ValueKey('tmux-start-question-yes-$sessionId'),
          label: l10n.tmuxStartQuestionYes,
          onPressed: () => answer(true),
          dense: true,
        ),
      ],
    );
  }
}
