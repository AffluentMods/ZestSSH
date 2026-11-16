import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/services/mosh/builtin_mosh_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';

/// Over a Mosh session's terminal (4.0, the built-in client), while the host
/// has not been heard from for a while: "Last contact 12s ago", as Mosh's
/// own client says on its top line. The session is kept and goes on trying,
/// so nothing is asked of the person; the mark goes when the host answers.
/// A screen reader is told once when it comes, and reads the time whenever
/// the mark is reached. Words and an icon, not a colour alone. Nothing for
/// any other session.
class MoshContactMark extends StatefulWidget {
  const MoshContactMark({super.key, required this.shell, this.now});

  final ShellService? shell;

  /// The clock (tests).
  final DateTime Function()? now;

  /// The Mosh link of [shell] (through a watched session's wrapper), or null.
  static MoshLinkSource? sourceOf(ShellService? shell) {
    final inner = shell is WatchedShell ? shell.inner : shell;
    return inner is MoshLinkSource ? inner as MoshLinkSource : null;
  }

  @override
  State<MoshContactMark> createState() => _MoshContactMarkState();
}

class _MoshContactMarkState extends State<MoshContactMark> {
  bool _wasQuiet = false;

  @override
  Widget build(BuildContext context) {
    final source = MoshContactMark.sourceOf(widget.shell);
    if (source == null) return const SizedBox.shrink();
    return ValueListenableBuilder<MoshLink>(
      valueListenable: source.moshLink,
      builder: (context, link, _) {
        final l10n = AppLocalizations.of(context)!;
        if (!link.quiet) {
          _wasQuiet = false;
          return const SizedBox.shrink();
        }
        final now = widget.now?.call() ?? DateTime.now();
        final time = timeAgoInSentence(l10n, now.subtract(link.lastHeard!), now: now, seconds: true);
        final label = l10n.moshNoContactLabel(time);
        if (!_wasQuiet) {
          _wasQuiet = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) zestAnnounce(context, label);
          });
        }
        return Semantics(
          container: true,
          label: label,
          child: ExcludeSemantics(
            child: Container(
              key: const ValueKey('mosh-contact-mark'),
              margin: const EdgeInsets.all(8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: ZestColors.chromeElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ZestColors.statusWarning),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.wifiOff, size: 14, color: ZestColors.statusWarning),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      l10n.moshLastContact(time),
                      style: TextStyle(fontSize: 12, color: ZestColors.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
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
