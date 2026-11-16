import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart' show connectionFailureReport;
import 'package:zestssh/services/ssh_service.dart' show sessionEnded;
import 'package:zestssh/ui/widgets/connection_lost_view.dart'
    show HostLastWords, TerminalRefusedActions, dropKind, dropSaid, lastTryOf, terminalRefusalSaid;
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// A session whose connection dropped, on a phone's terminal screen:
/// connecting again by itself (which try, and Cancel), or disconnected, with
/// Reconnect. What the last try of connecting again said is shown, and its
/// report can be copied (3.0: a try that failed showed the
/// failure screen for a moment, and the session was gone).
class DroppedSessionView extends ConsumerWidget {
  const DroppedSessionView({
    super.key,
    required this.sessionId,
    required this.sessionState,
    required this.theme,
    required this.closing,
    this.onReconnect,
  });

  final String sessionId;
  final SessionState sessionState;
  final TerminalTheme theme;

  /// The screen closes by itself in a moment, and says so: only then (after
  /// Cancel it stays, and said it was closing).
  final bool closing;

  /// Reconnect; null when there is nothing to connect to.
  final VoidCallback? onReconnect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final why = lastTryOf(sessionState, ref);
    // What the last try said; before any did, why it dropped when known.
    // An X program's screen: its end is its program's.
    final program = ref.read(activeSessionsProvider.notifier).xProgramNameOf(sessionId);
    final dropped = why == null && sessionState.dropCause != null
        ? dropSaid(l10n, sessionState, Redactable.host(sessionState.connectionLabel).displayIn(ref),
            program: program, screenEnd: ref.read(activeSessionsProvider.notifier).screenEndOf(sessionId))
        : null;
    // Its host ended it, and nothing is being tried: not a connection lost.
    final endedByHost = why == null && sessionEnded(sessionState.dropCause) != null;
    // And where it gave it no terminal (it allows SFTP only, or the shell
    // closed as it opened): said plainly, and its files offered.
    final refusal = endedByHost && !sessionState.isReconnecting
        ? ref.read(activeSessionsProvider.notifier).terminalRefusalOf(sessionId)
        : null;
    final said = refusal != null
        ? terminalRefusalSaid(l10n, refusal, Redactable.host(sessionState.connectionLabel).displayIn(ref))
        : dropped?.sentence;
    final whyText = why == null && said == null
        ? null
        : Text(
            why?.description ?? said!,
            key: const ValueKey('terminal-last-try'),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.foreground.withValues(alpha: 0.6), fontSize: 13, height: 1.4),
          );

    if (sessionState.isReconnecting) {
      // Auto-reconnect in progress
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  color: AppColors.brandOrange,
                  strokeWidth: 3,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                l10n.terminalReconnecting,
                style: TextStyle(
                  color: theme.foreground,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.terminalReconnectAttempt(sessionState.reconnectAttempt, sessionState.maxRetries),
                style: TextStyle(
                  color: theme.foreground.withValues(alpha: 0.6),
                  fontSize: 14,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
              const SizedBox(height: 4),
              RedactedText(
                Redactable.host(sessionState.connectionLabel),
                style: TextStyle(
                  color: theme.foreground.withValues(alpha: 0.4),
                  fontSize: 13,
                ),
              ),
              if (whyText != null) ...[
                const SizedBox(height: 12),
                whyText,
              ],
              const SizedBox(height: 24),
              OutlinedButton.icon(
                key: const ValueKey('terminal-reconnect-cancel'),
                onPressed: () => ref.read(activeSessionsProvider.notifier).stopAutoReconnect(sessionId),
                icon: const Icon(LucideIcons.x, size: 18),
                label: Text(l10n.cancel),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.foreground.withValues(alpha: 0.7),
                  side: BorderSide(
                    color: theme.foreground.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Not reconnecting - check if max retries were exhausted
    final maxRetriesReached = sessionState.reconnectAttempt >= sessionState.maxRetries &&
        sessionState.maxRetries > 0 &&
        !sessionState.isReconnecting;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                refusal != null
                    ? LucideIcons.folderOpen
                    : endedByHost
                        ? (program != null ? LucideIcons.appWindow : LucideIcons.terminal)
                        : LucideIcons.unlink,
                size: 48,
                color: theme.foreground.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            // The view's title: a heading for a screen reader.
            Semantics(
              header: true,
              child: Text(
                refusal != null
                    ? l10n.sftpOnlyRefusalTitle
                    : endedByHost
                        ? (program != null ? l10n.xProgramEndedTitle : l10n.sessionEndedTitle)
                        : l10n.terminalDisconnected,
                style: TextStyle(
                  color: theme.foreground,
                  fontSize: 16,
                ),
              ),
            ),
            if (whyText != null) ...[
              const SizedBox(height: 8),
              whyText,
            ],
            if (dropped?.printed != null) ...[
              const SizedBox(height: 14),
              HostLastWords(
                printed: dropped!.printed!,
                host: sessionState.host,
                username: sessionState.username,
                onDark: theme.foreground,
              ),
            ],
            if (maxRetriesReached) ...[
              const SizedBox(height: 4),
              Text(
                l10n.terminalAutoReconnectFailed(sessionState.reconnectAttempt),
                style: TextStyle(
                  color: theme.foreground.withValues(alpha: 0.4),
                  fontSize: 13,
                ),
              ),
            ] else if (closing) ...[
              const SizedBox(height: 8),
              Text(
                l10n.terminalClosing,
                style: TextStyle(
                  color: theme.foreground.withValues(alpha: 0.4),
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 20),
            // Its files first, where its host gave it no terminal; asking for
            // a terminal again is there, under.
            if (refusal != null) ...[
              TerminalRefusedActions(sessionId: sessionId, sessionState: sessionState, onDark: theme.foreground),
              if (onReconnect != null)
                TextButton.icon(
                  key: const ValueKey('terminal-reconnect'),
                  onPressed: onReconnect,
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  label: Text(l10n.terminalReconnect),
                  style: TextButton.styleFrom(foregroundColor: theme.foreground.withValues(alpha: 0.7)),
                ),
            ]
            // Manual reconnect button
            else if (onReconnect != null)
              FilledButton.icon(
                key: const ValueKey('terminal-reconnect'),
                onPressed: onReconnect,
                // A program that ended is run again: nothing is connected to again.
                icon: Icon(endedByHost && program != null ? LucideIcons.play : LucideIcons.refreshCw, size: 18),
                label: Text(endedByHost && program != null ? l10n.xProgramRunAgain : l10n.terminalReconnect),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandOrange,
                ),
              ),
            // What went wrong, to read and copy (scrubbed).
            if (sessionState.errorMessage != null || sessionState.dropCause != null) ...[
              const SizedBox(height: 16),
              ErrorDetailsPanel(
                report: connectionFailureReport(
                  title: why?.title ?? (endedByHost ? l10n.sessionEndedTitle : l10n.terminalDisconnected),
                  error: sessionState.errorMessage ?? sessionState.dropCause!,
                  kind: why?.type.name ?? dropKind(sessionState.dropCause),
                  log: sessionState.connectionLog,
                  where: endedByHost ? 'A session its host ended' : 'A connection that dropped',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
