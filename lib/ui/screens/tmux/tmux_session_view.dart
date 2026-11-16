import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/tmux/tmux_workspace.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/features/tmux/tmux_messages.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/time_text.dart';

/// Everything a session's tab shows while tmux mode is on: the session
/// picker while choosing, the workspace once attached, and the spinner /
/// failure / "session ended" states around them. Rendered inside the
/// session tab on desktop and full screen on mobile.
class TmuxSessionView extends ConsumerStatefulWidget {
  final TmuxSessionHost host;

  /// Leave tmux mode and show the normal terminal again (desktop) or pop
  /// the route (mobile).
  final VoidCallback onLeave;

  /// Find in terminal, opened for this session: its bar is shown above the
  /// panes, for the one in front ([TmuxWorkspace.findOpen]).
  final bool findOpen;

  /// How often Find was asked for while open: each time, its field takes the
  /// keyboard again.
  final int findAsk;

  /// Find's bar was closed (its close button, Escape).
  final VoidCallback? onFindClose;

  /// How often the keyboard was asked for here (a tab picked, a phone's key
  /// for it): each time, the pane in front takes it
  /// ([TmuxWorkspace.keyboardAsk]).
  final int keyboardAsk;

  const TmuxSessionView({
    super.key,
    required this.host,
    required this.onLeave,
    this.findOpen = false,
    this.findAsk = 0,
    this.onFindClose,
    this.keyboardAsk = 0,
  });

  @override
  ConsumerState<TmuxSessionView> createState() => _TmuxSessionViewState();
}

const _kIntroSeen = 'tmux_intro_seen';

class _TmuxSessionViewState extends ConsumerState<TmuxSessionView> {
  TmuxController? _wired;

  /// The host of the session tmux runs in, whose theme its panes show.
  String? get _connectionId => ref.watch(activeSessionsProvider.select((s) => s[widget.host.sessionId]?.connectionId));

  @override
  void initState() {
    super.initState();
    widget.host.addListener(_onHost);
    _wireErrors();
  }

  @override
  void didUpdateWidget(covariant TmuxSessionView old) {
    super.didUpdateWidget(old);
    if (old.host != widget.host) {
      old.host.removeListener(_onHost);
      widget.host.addListener(_onHost);
    }
    _wireErrors();
  }

  @override
  void dispose() {
    widget.host.removeListener(_onHost);
    super.dispose();
  }

  void _onHost() {
    if (!mounted) return;
    _wireErrors();
    setState(() {});
  }

  /// Management errors from tmux surface as a toast, once per controller.
  void _wireErrors() {
    final c = widget.host.controller;
    if (c == null || identical(c, _wired)) return;
    _wired = c;
    c.onError = (message) {
      if (!mounted) return;
      // What tmux said, in the app's language where it is known, its own
      // words behind Copy details (3.0: they were shown as they
      // were, after "tmux:").
      final l10n = AppLocalizations.of(context)!;
      showTopSnackBar(context, tmuxSaid(l10n, message) ?? l10n.tmuxSaidFailed, isError: true, details: message);
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final host = widget.host;
    final bg = ref.watch(hostTerminalThemeProvider(_connectionId)).background;
    switch (host.stage) {
      case TmuxHostStage.idle:
      case TmuxHostStage.listing:
        return _Panel(bg: bg, child: _spinner(l10n.tmuxListing));
      case TmuxHostStage.noLiveSession:
        return _Panel(
          bg: bg,
          child: _Message(
            icon: LucideIcons.terminal,
            // A watched session (3.0) keeps its connection to
            // itself, so tmux has none to open its control channel on:
            // said as that, not as a session that is not live.
            text: SessionWatches.of(host.sessionId) != null
                ? l10n.tmuxWatchedUnavailable
                : l10n.tmuxUiNeedsLiveSession,
            actions: [(l10n.tmuxBackToShell, widget.onLeave)],
          ),
        );
      case TmuxHostStage.notInstalled:
        return _Panel(
          bg: bg,
          child: _Message(
            icon: LucideIcons.packageX,
            text: l10n.tmuxNotInstalledTitle,
            detail: l10n.tmuxNotInstalledBody,
            code: l10n.tmuxInstallHint,
            actions: [
              (l10n.tmuxTryAgain, host.restart),
              (l10n.tmuxBackToShell, widget.onLeave),
            ],
          ),
        );
      case TmuxHostStage.failed:
        return _Panel(
          bg: bg,
          child: _Message(
            icon: LucideIcons.alertTriangle,
            text: l10n.tmuxLaunchFailedTitle,
            detail: tmuxSaid(l10n, host.failure),
            report: host.failure.trim().isEmpty
                ? null
                : ErrorReport.build(what: 'tmux could not be started', where: 'Starting tmux', error: host.failure),
            actions: [
              (l10n.tmuxTryAgain, host.restart),
              (l10n.tmuxBackToShell, widget.onLeave),
            ],
          ),
        );
      case TmuxHostStage.picking:
        return _Panel(
          bg: bg,
          child: _SessionPicker(host: host, onCancel: widget.onLeave),
        );
      case TmuxHostStage.attached:
        final c = host.controller;
        if (c == null) return _Panel(bg: bg, child: _spinner(l10n.tmuxConnecting));
        if (c.exited) {
          return _Panel(
            bg: bg,
            child: _Message(
              icon: LucideIcons.powerOff,
              text: l10n.tmuxUiSessionEnded,
              // Why, in the app's language where it is known; tmux's own
              // words behind Copy details (they were shown as they were).
              detail: c.exitReason == null ? null : tmuxSaid(l10n, c.exitReason!),
              report: c.exitReason == null || c.exitReason!.trim().isEmpty
                  ? null
                  : ErrorReport.build(what: 'tmux session ended', where: 'tmux', error: c.exitReason),
              actions: [
                (l10n.tmuxSessionsMenu, host.restart),
                (l10n.tmuxBackToShell, widget.onLeave),
              ],
            ),
          );
        }
        return Column(
          children: [
            _IntroBanner(),
            Expanded(
              child: TmuxWorkspace(
                controller: c,
                connectionId: _connectionId,
                onDetach: widget.onLeave,
                findOpen: widget.findOpen,
                findAsk: widget.findAsk,
                onFindClose: widget.onFindClose,
                keyboardAsk: widget.keyboardAsk,
              ),
            ),
          ],
        );
    }
  }

  Widget _spinner(String text) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 12),
          Text(text, style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 13)),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final Color bg;
  final Widget child;
  const _Panel({required this.bg, required this.child});

  @override
  Widget build(BuildContext context) => ColoredBox(color: bg, child: child);
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? detail;
  final String? code;
  final List<(String, VoidCallback)> actions;

  /// What stands behind it, to read and copy (ErrorReport.build).
  final String? report;

  const _Message({
    required this.icon,
    required this.text,
    this.detail,
    this.code,
    this.actions = const [],
    this.report,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 34, color: AppColors.v3TextTertiary),
              const SizedBox(height: 14),
              Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.v3TextPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 6),
                Text(
                  detail!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.v3TextSecondary, fontSize: 13, height: 1.4),
                ),
              ],
              if (code != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.v3Surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.v3BorderSubtle),
                  ),
                  child: SelectableText(
                    code!,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                      height: 1.6,
                      color: AppColors.v3TextSecondary,
                    ),
                  ),
                ),
              ],
              if (report != null) ...[
                const SizedBox(height: 12),
                ErrorDetailsPanel(report: report!),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (var i = 0; i < actions.length; i++)
                      i == 0
                          ? FilledButton.tonal(
                              onPressed: actions[i].$2,
                              child: Text(actions[i].$1),
                            )
                          : TextButton(
                              onPressed: actions[i].$2,
                              child: Text(actions[i].$1),
                            ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A short "why tmux" card shown above the workspace the first time it is
/// used on this device, dismissed for good with one tap.
class _IntroBanner extends ConsumerStatefulWidget {
  @override
  ConsumerState<_IntroBanner> createState() => _IntroBannerState();
}

class _IntroBannerState extends ConsumerState<_IntroBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.read(sharedPreferencesProvider);
    if (_dismissed || (prefs.getBool(_kIntroSeen) ?? false)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.v3AccentPrimary.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(LucideIcons.info, size: 15, color: AppColors.v3AccentInk),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.tmuxIntroTitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${l10n.tmuxIntroPersist} ${l10n.tmuxIntroLayout} ${l10n.tmuxIntroShare}',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: AppColors.v3TextSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () {
              prefs.setBool(_kIntroSeen, true);
              setState(() => _dismissed = true);
            },
            style: TextButton.styleFrom(
              foregroundColor: AppColors.v3AccentInk,
              textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12, fontWeight: FontWeight.w600),
            ),
            child: Text(l10n.tmuxIntroGotIt),
          ),
        ],
      ),
    );
  }
}

/// "Attach to a session or start a new one", inline, when the host already
/// has tmux sessions. Idle and in-use sessions look different (attaching to
/// an in-use one shares its terminal live with the other client), the name
/// field starts empty, and New session only enables for a name not taken.
class _SessionPicker extends ConsumerStatefulWidget {
  final TmuxSessionHost host;
  final VoidCallback onCancel;
  const _SessionPicker({required this.host, required this.onCancel});

  @override
  ConsumerState<_SessionPicker> createState() => _SessionPickerState();
}

class _SessionPickerState extends ConsumerState<_SessionPicker> {
  final _name = TextEditingController();
  final _killing = <String>{};

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _typed => _name.text.trim();

  bool get _taken => widget.host.listed.any((s) => s.name == _typed);

  bool get _canCreate => _typed.isNotEmpty && !_taken;

  void _create() {
    if (!_canCreate) return;
    widget.host.createSession(_typed);
  }

  /// Kill a listed session from the picker (the overview of everything on
  /// the host): confirm with the blast radius, then re-list.
  Future<void> _kill(TmuxSessionInfo s) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.tmuxKillSessionConfirmTitle(
          Redactable.host(s.name).displayIn(ref)),
      body: s.attached > 0
          ? '${l10n.tmuxKillSessionConfirmBody(s.windows)} '
              '${l10n.tmuxKillSessionInUse(s.attached)}'
          : l10n.tmuxKillSessionConfirmBody(s.windows),
      confirmLabel: l10n.tmuxKillSession,
    );
    if (ok != true || !mounted) return;
    setState(() => _killing.add(s.id));
    final done = await widget.host.killListedSession(s.id);
    if (!mounted) return;
    setState(() => _killing.remove(s.id));
    if (!done) {
      final why = widget.host.lastKillFailure;
      showTopSnackBar(
        context,
        (why == null ? null : tmuxSaid(l10n, why)) ?? l10n.tmuxKillSessionFailed,
        isError: true,
        details: why,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final prefs = ref.read(sharedPreferencesProvider);
    final firstTime = !(prefs.getBool(_kIntroSeen) ?? false);
    final sorted = List.of(widget.host.listed)
      ..sort((a, b) {
        final ta = a.activity?.millisecondsSinceEpoch ?? 0;
        final tb = b.activity?.millisecondsSinceEpoch ?? 0;
        return tb.compareTo(ta);
      });
    final inUse = sorted.where((s) => s.attached > 0).toList();
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            decoration: BoxDecoration(
              color: AppColors.v3Surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.layoutGrid, size: 18, color: AppColors.v3AccentInk),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        l10n.tmuxPickerTitle,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.v3TextPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  firstTime
                      ? '${l10n.tmuxIntroPersist} ${l10n.tmuxPickerSubtitle}'
                      : l10n.tmuxPickerSubtitle,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: AppColors.v3TextSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                if (sorted.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      l10n.tmuxPickerNoSessions,
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: AppColors.v3TextTertiary,
                      ),
                    ),
                  ),
                for (final s in sorted)
                  _SessionRow(
                    session: s,
                    busy: _killing.contains(s.id),
                    onTap: () => widget.host.attach(s.id),
                    onKill: () => _kill(s),
                  ),
                if (inUse.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _InlineWarning(
                    text: l10n.tmuxInUseWarning(
                        inUse.map((s) => Redactable.host(s.name).displayIn(ref)).join(', ')),
                  ),
                ],
                const SizedBox(height: 8),
                // Bare `tmux -CC` in a shell always creates a session, which
                // reads as "it never re-attaches": say so once, here.
                Text(
                  l10n.tmuxPickerShellHint,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  l10n.tmuxPickerNewSessionHint.toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                    letterSpacing: 0.6,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
                const SizedBox(height: 6),
                ZestTextField(
                  controller: _name,
                  hintText: l10n.tmuxNameHint,
                  autofocus: false,
                  errorText: _taken ? l10n.tmuxNameTaken : null,
                  onSubmit: _create,
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: widget.onCancel,
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.v3TextSecondary,
                        textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12),
                      ),
                      child: Text(l10n.cancel),
                    ),
                    FilledButton(
                      onPressed: _canCreate ? _create : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.v3AccentPrimary,
                        foregroundColor: const Color(0xFF1A0D04),
                        textStyle: const TextStyle(
                            fontFamily: 'GeistSans',
                            fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                      child: Text(l10n.tmuxPickerNewSession),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineWarning extends StatelessWidget {
  final String text;
  const _InlineWarning({required this.text});

  @override
  Widget build(BuildContext context) {
    final warn = AppColors.v3Warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: warn.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.alertTriangle, size: 13, color: warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: Color.lerp(warn, AppColors.v3TextPrimary, 0.35),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends ConsumerStatefulWidget {
  final TmuxSessionInfo session;
  final VoidCallback onTap;
  final VoidCallback onKill;

  /// A kill is in flight for this row: the trash icon becomes a spinner and
  /// the row stops taking taps.
  final bool busy;
  const _SessionRow({
    required this.session,
    required this.onTap,
    required this.onKill,
    this.busy = false,
  });

  @override
  ConsumerState<_SessionRow> createState() => _SessionRowState();
}

class _SessionRowState extends ConsumerState<_SessionRow> {
  bool _hovering = false;

  String _since(BuildContext context, DateTime t) {
    final now = DateTime.now();
    final loc = MaterialLocalizations.of(context);
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return plainTimeSpaces(loc.formatTimeOfDay(TimeOfDay.fromDateTime(t),
          alwaysUse24HourFormat: true));
    }
    return loc.formatShortDate(t);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final s = widget.session;
    final inUse = s.attached > 0;
    final name = Redactable.host(s.name).displayIn(ref);
    final warn = AppColors.v3Warning;
    final meta = [
      l10n.tmuxPickerWindows(s.windows),
      if (inUse)
        l10n.tmuxClientActive
      else if (s.activity != null)
        l10n.tmuxIdleSince(_since(context, s.activity!)),
    ].join(' · ');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.busy ? null : widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: _hovering ? AppColors.v3Hover : AppColors.v3Elevated,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: inUse
                  ? warn.withValues(alpha: 0.30)
                  : _hovering
                      ? AppColors.v3AccentPrimary.withValues(alpha: 0.45)
                      : AppColors.v3BorderSubtle,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.v3TextPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta,
                      style: TextStyle(fontSize: 11, color: AppColors.v3TextTertiary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: inUse
                      ? warn.withValues(alpha: 0.12)
                      : AppColors.v3Elevated,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: inUse ? warn.withValues(alpha: 0.30) : AppColors.v3BorderSubtle,
                  ),
                ),
                child: Text(
                  inUse ? l10n.tmuxStatusInUse : l10n.tmuxStatusIdle,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                    color: inUse ? warn : AppColors.v3TextTertiary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                l10n.tmuxPickerAttach,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.v3AccentSecondary,
                ),
              ),
              const SizedBox(width: 2),
              Icon(LucideIcons.chevronRight, size: 14, color: AppColors.v3AccentSecondary),
              const SizedBox(width: 6),
              // Kill, always reachable (this list is the overview of every
              // session on the host); crit-coloured on hover so it never
              // reads as the row's primary action.
              SizedBox(
                width: 28,
                height: 28,
                child: widget.busy
                    ? const Padding(
                        padding: EdgeInsets.all(7),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : _KillButton(onTap: widget.onKill),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KillButton extends StatefulWidget {
  final VoidCallback onTap;
  const _KillButton({required this.onTap});

  @override
  State<_KillButton> createState() => _KillButtonState();
}

class _KillButtonState extends State<_KillButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: l10n.tmuxKillSession,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Tooltip(message: AppLocalizations.of(context)!.delete, child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            decoration: BoxDecoration(
              color: _hovering
                  ? AppColors.v3Error.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              LucideIcons.trash2,
              size: 14,
              color: _hovering ? AppColors.v3Error : AppColors.v3TextTertiary,
            ),
          ),
        )),
      ),
    );
  }
}
