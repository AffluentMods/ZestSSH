import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/ssh_service.dart'
    show
        endReasonItself,
        hostClosedConnection,
        hostDataDamaged,
        hostKeyFailedAtNewKeys,
        hostSaid,
        hostStoppedAnswering,
        jumpHostEnded,
        sessionEnded;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart'
    show connectionFailureReport, maskConnectionLine;
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/error_translator.dart';

/// What the last try of connecting [state] again said, in the app's language
/// (null when nothing has failed yet). The host and the user are masked in
/// recording mode.
ConnectionError? lastTryOf(SessionState state, WidgetRef ref) {
  final error = state.errorMessage;
  if (error == null) return null;
  final host = state.host;
  final username = state.username;
  return ConnectionError.translate(
    error,
    host: host == null ? null : Redactable.address(host).displayIn(ref),
    port: state.port,
    username: username == null ? null : Redactable.username(username).displayIn(ref),
  );
}

/// What a dropped session says about why before any try of connecting again
/// has said anything: [name] closed the connection, it stopped answering and
/// the connection was given up (with what that can mean), the network to it
/// broke (with what to try), or that it ended. And of a session whose shell
/// its host ended ([sessionEnded]): that it did, how, and in [printed] the
/// last the host printed there, as the host wrote it, for whoever shows it
/// to set apart from the app's own words.
///
/// Where it was the connection to a jump host on the way that ended
/// ([jumpHostEnded]), that is said first, with the jump host's name (masked
/// in recording mode as a host's is), and then why, of the jump host: a
/// session that went through a jump host said that [name] had closed the
/// connection, whatever had ended the one to the jump host.
///
/// An X program's screen ([program], the program's name) ends when its
/// program does: that is said of the program, not of a host that "ended the
/// session".
///
/// An RDP screen whose server ended the session and said why ([screenEnd],
/// the sessions' `screenEndOf`): that reason in the app's words, with its
/// code where it has one, in place of "[name] ended the session".
({String sentence, String? tip, String? printed}) dropSaid(AppLocalizations l10n, SessionState state, String name,
    {String? program, ScreenFailure? screenEnd}) {
  final cause = state.dropCause;
  final ended = sessionEnded(cause);
  if (ended != null && screenEnd != null) {
    return (sentence: screenFailureText(l10n, screenEnd), tip: null, printed: null);
  }
  if (ended != null && program != null && ended.signal == null) {
    return (
      sentence: ended.exitCode != null
          ? l10n.xProgramEndedStatus(program, ended.exitCode!)
          : l10n.xProgramEndedPlain(program),
      tip: null,
      printed: ended.said.isEmpty ? null : ended.said,
    );
  }
  if (ended != null) {
    return (
      sentence: ended.signal != null
          ? l10n.sessionEndedSignal(name, ended.signal!)
          : ended.exitCode != null
              ? l10n.sessionEndedStatus(name, ended.exitCode!)
              : l10n.sessionEndedByHost(name),
      tip: null,
      printed: ended.said.isEmpty ? null : ended.said,
    );
  }
  final atJumpHost = jumpHostEnded(cause);
  if (atJumpHost != null) {
    final jump = Redactable.host(atJumpHost.label).display;
    final why = connectionEndSaid(l10n, atJumpHost.reason, jump, keyFailed: l10n.connJumpHostKeyFailedAtNewKeys(jump));
    return (sentence: '${l10n.connectionLostAtJumpHost(name, jump)} ${why.sentence}', tip: why.tip, printed: null);
  }
  final why = connectionEndSaid(l10n, cause, name, keyFailed: l10n.connHostKeyFailedAtNewKeys);
  return (sentence: why.sentence, tip: why.tip, printed: null);
}

/// What kind of end the report of a dropped session names, by why it
/// dropped ([SessionState.dropCause]). Where it was the connection to a
/// jump host that ended, the kind is that connection's, and says so
/// ("jumpHost.closedByHost").
String dropKind(String? cause) {
  if (jumpHostEnded(cause) != null) return 'jumpHost.${dropKind(endReasonItself(cause))}';
  return sessionEnded(cause) != null
      ? 'sessionEndedByHost'
      : cause == hostClosedConnection
          ? 'closedByHost'
          : cause == hostStoppedAnswering
              ? 'stoppedAnswering'
              : cause == hostKeyFailedAtNewKeys
                  ? 'hostKeyAtNewKeys'
                  : cause == hostDataDamaged
                      ? 'packetCheckFailed'
                      : hostSaid(cause) != null
                          ? 'endedByHost'
                          : 'lost';
}

/// The last a host printed before it ended a session, set apart from the
/// app's own words: under what it is ([AppLocalizations.sessionEndedLastWords]),
/// in the terminal's own letters, to read and to copy. The host and the user
/// are masked in recording mode, line by line, as the lines of a
/// connection's log are.
class HostLastWords extends StatelessWidget {
  const HostLastWords({super.key, required this.printed, required this.host, required this.username, this.onDark});

  final String printed;
  final String? host;
  final String? username;

  /// The colour of the text of what this stands on, where that is a
  /// terminal's own theme and not the app's.
  final Color? onDark;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = onDark ?? AppColors.v3TextPrimary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.sessionEndedLastWords,
          style: TextStyle(
            fontFamily: 'GeistSans',
            fontSize: 12,
            color: onDark?.withValues(alpha: 0.6) ?? AppColors.v3TextSecondary,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: onDark?.withValues(alpha: 0.06) ?? AppColors.v3Surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: onDark?.withValues(alpha: 0.15) ?? AppColors.v3BorderSubtle),
          ),
          child: SelectableText(
            [for (final line in printed.split('\n')) maskConnectionLine(line, host: host, username: username)].join('\n'),
            key: const ValueKey('session-ended-last-words'),
            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, height: 1.4, color: text),
          ),
        ),
      ],
    );
  }
}

/// What is said of a session whose host gave it no terminal ([refusal]):
/// that [name] allows SFTP only (its server said so), or that it closed the
/// terminal the moment it opened, with its files offered either way.
String terminalRefusalSaid(AppLocalizations l10n, TerminalRefusal refusal, String name) => switch (refusal) {
      TerminalRefusal.sftpOnly => l10n.sftpOnlyRefusalSaid(name),
      TerminalRefusal.closedAtOnce => l10n.sftpOnlyRefusalAtOnce(name),
    };

/// Whether "Make this host SFTP only" can be offered for [state]'s host: a
/// saved one (a Quick connect's is not kept), which this account may change
/// (its Crate decides, [ActiveSessionsNotifier.makeHostSftpOnly] asks again).
bool mayOfferSftpOnlyHost(SessionState state) {
  final id = state.connectionId;
  return id != null && id.isNotEmpty && !id.startsWith('quick_');
}

/// The two ways on for a session whose host gave it no terminal: "Open its
/// files" (this session, files only, this once) and "Make this host SFTP
/// only" (saved, so it opens that way from now on), with what each did said
/// where it could not be done, and that a device on an older version turned
/// the host back into SSH where one did. [onDark] for a terminal's own colours.
class TerminalRefusedActions extends ConsumerStatefulWidget {
  const TerminalRefusedActions({super.key, required this.sessionId, required this.sessionState, this.onDark});

  final String sessionId;
  final SessionState sessionState;
  final Color? onDark;

  @override
  ConsumerState<TerminalRefusedActions> createState() => _TerminalRefusedActionsState();
}

class _TerminalRefusedActionsState extends ConsumerState<TerminalRefusedActions> {
  bool _saving = false;

  /// Said under the buttons where the host could not be changed.
  String? _notChanged;

  Future<void> _makeSftpOnly() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _saving = true;
      _notChanged = null;
    });
    final connectionId = widget.sessionState.connectionId;
    final made = await ref.read(activeSessionsProvider.notifier).makeHostSftpOnly(widget.sessionId);
    if (made && connectionId != null) {
      await ref.read(settingsServiceProvider).forgetSftpOnlyTurnedBack(connectionId);
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!made) _notChanged = l10n.sftpOnlyMakeNotAllowed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sessions = ref.read(activeSessionsProvider.notifier);
    final onDark = widget.onDark;
    final turnedBack = ref.read(settingsServiceProvider).sftpOnlyTurnedBack.contains(widget.sessionState.connectionId);
    final saidStyle = TextStyle(
      fontFamily: 'GeistSans',
      fontSize: 12.5,
      height: 1.45,
      color: onDark?.withValues(alpha: 0.6) ?? AppColors.v3TextSecondary,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('terminal-refused-open-files'),
              onPressed: _saving ? null : () => sessions.openFilesInstead(widget.sessionId),
              icon: const Icon(LucideIcons.folderOpen, size: 16),
              label: Text(l10n.sftpOnlyOpenFiles),
              style: FilledButton.styleFrom(backgroundColor: AppColors.v3AccentPrimary),
            ),
            if (mayOfferSftpOnlyHost(widget.sessionState))
              OutlinedButton.icon(
                key: const ValueKey('terminal-refused-make-sftp'),
                onPressed: _saving ? null : _makeSftpOnly,
                icon: const Icon(LucideIcons.hardDrive, size: 16),
                label: Text(l10n.sftpOnlyMakeHost),
                style: onDark == null
                    ? null
                    : OutlinedButton.styleFrom(
                        foregroundColor: onDark.withValues(alpha: 0.85),
                        side: BorderSide(color: onDark.withValues(alpha: 0.3)),
                      ),
              ),
          ],
        ),
        if (turnedBack) ...[
          const SizedBox(height: 8),
          Text(
            l10n.sftpOnlyTurnedBack,
            key: const ValueKey('terminal-refused-turned-back'),
            textAlign: TextAlign.center,
            style: saidStyle,
          ),
        ],
        if (_notChanged != null) ...[
          const SizedBox(height: 8),
          Text(
            _notChanged!,
            key: const ValueKey('terminal-refused-not-changed'),
            textAlign: TextAlign.center,
            style: saidStyle,
          ),
        ],
      ],
    );
  }
}

/// A session whose connection dropped, shown in its own place on a computer
/// (3.0): connecting again by itself (which try, what the last
/// one said, Cancel), or that the connection was lost and, once the tries are
/// over, how many there were, with Reconnect and the report of what went
/// wrong. Its tab showed another session's terminal, or none at all. A
/// session whose host gave it no terminal says so, and offers its files.
class ConnectionLostView extends ConsumerWidget {
  const ConnectionLostView({super.key, required this.sessionId, required this.sessionState});

  final String sessionId;
  final SessionState sessionState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final s = sessionState;
    final sessions = ref.read(activeSessionsProvider.notifier);
    final name = Redactable.host(s.connectionLabel.isNotEmpty ? s.connectionLabel : (s.host ?? '')).displayIn(ref);
    final why = lastTryOf(s, ref);
    // Before a try has said anything: why it dropped.
    // An X program's screen: its end is its program's.
    final program = sessions.xProgramNameOf(sessionId);
    final said =
        why == null ? dropSaid(l10n, s, name, program: program, screenEnd: sessions.screenEndOf(sessionId)) : null;
    final tip = why?.tip ?? said?.tip;
    // Its host ended it, and nothing is being tried: not a connection lost.
    final endedByHost = why == null && sessionEnded(s.dropCause) != null;
    // And where it gave it no terminal (it allows SFTP only, or the shell
    // closed as it opened): said plainly, and its files offered.
    final refusal = endedByHost && !s.isReconnecting ? sessions.terminalRefusalOf(sessionId) : null;
    final title = s.isReconnecting
        ? l10n.terminalReconnecting
        : refusal != null
            ? l10n.sftpOnlyRefusalTitle
            : endedByHost
                ? (program != null ? l10n.xProgramEndedTitle : l10n.sessionEndedTitle)
                : l10n.connectionLostTitle;
    return Container(
      key: ValueKey('connection-lost-$sessionId'),
      color: AppColors.v3Background,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (s.isReconnecting)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.v3AccentPrimary),
                )
              else if (refusal != null)
                Icon(LucideIcons.folderOpen, size: 30, color: AppColors.v3TextSecondary)
              else if (endedByHost)
                Icon(program != null ? LucideIcons.appWindow : LucideIcons.terminal,
                    size: 30, color: AppColors.v3TextSecondary)
              else
                Icon(LucideIcons.unplug, size: 30, color: AppColors.v3Error),
              const SizedBox(height: 14),
              // The view's title: a heading for a screen reader, which reads
              // the page by its headings.
              Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                s.isReconnecting ? l10n.terminalReconnectAttempt(s.reconnectAttempt, s.maxRetries) : name,
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'GeistSans', fontSize: 13, color: AppColors.v3TextSecondary),
              ),
              const SizedBox(height: 12),
              // Why: what the last try said, or why it dropped.
              Text(
                refusal != null ? terminalRefusalSaid(l10n, refusal, name) : why?.description ?? said!.sentence,
                key: const ValueKey('connection-lost-why'),
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'GeistSans', fontSize: 13, height: 1.45, color: AppColors.v3TextPrimary),
              ),
              if (!s.isReconnecting && s.reconnectAttempt > 0) ...[
                const SizedBox(height: 6),
                Text(
                  l10n.terminalAutoReconnectFailed(s.reconnectAttempt),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'GeistSans', fontSize: 12.5, color: AppColors.v3TextSecondary),
                ),
              ],
              if (tip != null && !s.isReconnecting) ...[
                const SizedBox(height: 6),
                Text(
                  tip,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'GeistSans', fontSize: 12.5, height: 1.45, color: AppColors.v3TextSecondary),
                ),
              ],
              if (said?.printed != null && !s.isReconnecting) ...[
                const SizedBox(height: 14),
                HostLastWords(printed: said!.printed!, host: s.host, username: s.username),
              ],
              const SizedBox(height: 18),
              if (s.isReconnecting)
                OutlinedButton.icon(
                  key: const ValueKey('connection-lost-cancel'),
                  onPressed: () => sessions.stopAutoReconnect(sessionId),
                  icon: const Icon(LucideIcons.x, size: 16),
                  label: Text(l10n.cancel),
                )
              else if (refusal != null) ...[
                // Its files first; asking for a terminal again is there, under.
                TerminalRefusedActions(sessionId: sessionId, sessionState: s),
                const SizedBox(height: 6),
                TextButton.icon(
                  key: const ValueKey('connection-lost-reconnect'),
                  onPressed: () => sessions.reconnectNow(sessionId),
                  icon: const Icon(LucideIcons.refreshCw, size: 15),
                  label: Text(l10n.terminalReconnect),
                ),
              ] else
                FilledButton.icon(
                  key: const ValueKey('connection-lost-reconnect'),
                  onPressed: () => sessions.reconnectNow(sessionId),
                  // A program that ended is run again: nothing is connected
                  // to again.
                  icon: Icon(endedByHost && program != null ? LucideIcons.play : LucideIcons.refreshCw, size: 16),
                  label: Text(endedByHost && program != null ? l10n.xProgramRunAgain : l10n.terminalReconnect),
                  style: FilledButton.styleFrom(backgroundColor: AppColors.v3AccentPrimary),
                ),
              if (s.errorMessage != null || s.dropCause != null || s.connectionLog.isNotEmpty) ...[
                const SizedBox(height: 16),
                ErrorDetailsPanel(
                  report: connectionFailureReport(
                    title: why?.title ?? (endedByHost ? l10n.sessionEndedTitle : l10n.connectionLostTitle),
                    error: s.errorMessage ?? s.dropCause ?? '',
                    kind: why?.type.name ?? dropKind(s.dropCause),
                    log: s.connectionLog,
                    where: endedByHost ? 'A session its host ended' : 'A connection that dropped',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
