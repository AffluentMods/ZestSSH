import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

// "This session is logged" (3.0): shown for as long as a session is
// logged for its team, beside the session's name on desktop and as a strip
// under the toolbar on phones. What is and is not left out is said with it;
// and, while its log has not reached ZestSSH Cloud yet, that the log is kept
// on this device and sent later (the session is logged all the same).

/// Whether [sessionId] is logged, and whether its log waits on this device.
(bool logged, bool waits) _loggedNow(String sessionId) =>
    (TeamSessionLogs.logged.value.contains(sessionId), TeamSessionLogs.waiting.value.contains(sessionId));

/// Rebuilds with the sessions that are logged and those whose log waits.
final Listenable _loggedSessions = Listenable.merge([TeamSessionLogs.logged, TeamSessionLogs.waiting]);

/// A logged session that is a remote screen's (4.0): its log holds how the
/// session went and never its picture, so what is said of it is not what is
/// said of a terminal's.
enum LoggedScreen {
  /// A VNC screen, or an X program's.
  vnc,

  /// An RDP host's: the account that signed in is logged too.
  rdp,
}

/// What is said of a logged session: what its log holds and leaves out (a
/// terminal's, or a remote [screen]'s), and where the log is while it [waits].
String sessionLoggedText(AppLocalizations l10n, {required bool waits, LoggedScreen? screen}) {
  final what = switch (screen) {
    null => l10n.sessionLoggedTooltip,
    LoggedScreen.vnc => l10n.screenSessionLoggedTooltip,
    LoggedScreen.rdp => l10n.screenSessionLoggedTooltipRdp,
  };
  return waits ? '$what ${l10n.sessionLoggedWaiting}' : what;
}

/// The session header's chip (desktop), and a phone's remote screen (which
/// has no room for the strip: the chip, with its words a long press away).
class TeamLoggedChip extends StatelessWidget {
  const TeamLoggedChip({super.key, required this.sessionId, this.screen, this.overPicture = false});

  final String sessionId;

  /// The session is a remote screen's.
  final LoggedScreen? screen;

  /// Drawn over a remote screen's picture (a phone's): on a dark backing so
  /// that it reads on any picture, with no space kept beside it, and its
  /// words shown by a tap (a phone has no pointer to rest on it). Its label
  /// is the one short word whether or not the log waits (the tap says that
  /// too), cut where its place is narrower, so it never grows over what is
  /// beside it.
  final bool overPicture;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: _loggedSessions,
      builder: (context, _) {
        final (logged, waits) = _loggedNow(sessionId);
        if (!logged) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(left: overPicture ? 0 : 8),
          child: Tooltip(
            message: sessionLoggedText(l10n, waits: waits, screen: screen),
            triggerMode: overPicture ? TooltipTriggerMode.tap : null,
            showDuration: overPicture ? const Duration(seconds: 8) : null,
            child: Container(
              key: ValueKey('team-logged-$sessionId'),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: overPicture
                    ? Color.alphaBlend(ZestColors.statusWarning.withValues(alpha: 0.14), const Color(0xF0151412))
                    : ZestColors.statusWarning.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: ZestColors.statusWarning.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.eye, size: 12, color: ZestColors.statusWarning),
                  const SizedBox(width: 4),
                  if (overPicture)
                    Flexible(
                      child: Text(
                        l10n.sessionLoggedChip,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ZestColors.statusWarning),
                      ),
                    )
                  else
                    Text(
                      waits ? l10n.sessionLoggedWaitingChip : l10n.sessionLoggedChip,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ZestColors.statusWarning),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The strip under a phone session's toolbar.
class TeamLoggedStrip extends StatelessWidget {
  const TeamLoggedStrip({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: _loggedSessions,
      builder: (context, _) {
        final (logged, waits) = _loggedNow(sessionId);
        if (!logged) return const SizedBox.shrink();
        return Container(
          key: ValueKey('team-logged-strip-$sessionId'),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: ZestColors.statusWarning.withValues(alpha: 0.14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(LucideIcons.eye, size: 13, color: ZestColors.statusWarning),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  sessionLoggedText(l10n, waits: waits),
                  style: TextStyle(fontSize: 11.5, height: 1.35, color: ZestColors.statusWarning),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
