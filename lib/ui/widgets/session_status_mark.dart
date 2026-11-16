import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart';

/// A session's state by its shape as well as its colour (4.0 accessibility
/// pass: by colour alone, a green, an amber and a red dot read alike to many
/// people): a dot while connected, a ring while connecting, a cross once it
/// is not. Drawn only: its words are said by what holds it.
class SessionStatusMark extends StatelessWidget {
  const SessionStatusMark({super.key, required this.status, this.size = 7});

  final SessionStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: switch (status) {
        SessionStatus.connected => Container(
            key: const ValueKey('status-mark-connected'),
            width: size,
            height: size,
            decoration: BoxDecoration(color: ZestColors.statusSuccess, shape: BoxShape.circle),
          ),
        SessionStatus.connecting => Container(
            key: const ValueKey('status-mark-connecting'),
            width: size,
            height: size,
            decoration: BoxDecoration(
              border: Border.all(color: ZestColors.statusWarning, width: 1.5),
              shape: BoxShape.circle,
            ),
          ),
        SessionStatus.disconnected || SessionStatus.error => SizedBox(
            key: const ValueKey('status-mark-down'),
            width: size,
            height: size,
            child: OverflowBox(
              maxWidth: size + 4,
              maxHeight: size + 4,
              child: Icon(LucideIcons.x, size: size + 4, color: ZestColors.statusError),
            ),
          ),
      },
    );
  }
}

/// A session's state in words, as its status chip says it.
String sessionStatusWord(AppLocalizations l10n, SessionStatus status) => switch (status) {
      SessionStatus.connected => l10n.sessionInfoStatusConnected,
      SessionStatus.connecting => l10n.sessionInfoStatusConnecting,
      SessionStatus.disconnected => l10n.sessionInfoStatusDisconnected,
      SessionStatus.error => l10n.sessionInfoStatusError,
    };
