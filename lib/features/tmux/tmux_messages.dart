import 'package:zestssh/l10n/generated/app_localizations.dart';

/// What tmux said, in [t]'s language where it is known (3.0): a
/// session that is not there, a name taken, tmux no longer running, the
/// shell inside tmux already, no terminal for it, tmux stopped in this
/// session, or detached. Null when it is not known: tmux's own words, which
/// are English, stand behind Copy details either way. They were shown as
/// they were, after "tmux:".
String? tmuxSaid(AppLocalizations t, String raw) {
  final lower = raw.trim().toLowerCase();
  if (lower.isEmpty) return null;
  if (lower.contains("can't find session") ||
      lower.contains("can't find window") ||
      lower.contains("can't find pane") ||
      lower.contains('session not found')) {
    return t.tmuxSaidGone;
  }
  if (lower.contains('duplicate session')) return t.tmuxSaidDuplicate;
  if (lower.contains('no server running') || lower.contains('server exited') || lower.contains('lost server')) {
    return t.tmuxSaidNoServer;
  }
  if (lower.contains('sessions should be nested with care')) return t.tmuxSaidNested;
  if (lower.contains('missing or unsuitable terminal') || lower.contains('open terminal failed') || lower == 'lost tty') {
    return t.tmuxSaidTerminal;
  }
  // The app's own words for its link to tmux going.
  if (lower == 'connection closed' ||
      lower == 'tmux control mode has ended' ||
      lower == 'tmux exited' ||
      lower == 'disposed' ||
      lower == 'exited' ||
      lower == 'terminated') {
    return t.tmuxSaidEnded;
  }
  if (lower.startsWith('detached')) return t.tmuxSaidDetached;
  return null;
}
