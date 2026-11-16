import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show OrchardAccessRefused;
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/features/orchards/watch/unwatched.dart';
import 'package:zestssh/features/orchards/watch/watch_gate.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show orchardErrorMessage;
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_providers.dart' show shareStartFailureText;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/sharing/share_session_dialog.dart' show SharePersonTile;
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';

// A session to a watched Crate's host, on screen (3.0, session
// moderation): whom to ask to watch, what the tab says while it waits for
// one of them, and what it says while nobody is watching. And, while
// ZestSSH Cloud cannot be reached (the outage work): the question that asks
// whoever may go on with nobody watching for their reason, the way on for a
// held session, and the line a session shows while it goes on so.

/// Asks whom to ask to watch: the account ids picked, or null when the
/// person gives up.
Future<Set<String>?> showWatchAsk(BuildContext context, WatchRequest request) => showZestModal<Set<String>>(
      context: context,
      size: ZestModalSize.standard,
      child: WatchAskDialog(request: request),
    );

/// "Ask someone to watch": everyone else who manages the Crate, and what
/// asking them means.
class WatchAskDialog extends ConsumerStatefulWidget {
  const WatchAskDialog({super.key, required this.request});

  final WatchRequest request;

  @override
  ConsumerState<WatchAskDialog> createState() => _WatchAskDialogState();
}

class _WatchAskDialogState extends ConsumerState<WatchAskDialog> {
  final _picked = <String>{};

  WatchRequest get _request => widget.request;

  bool _canAsk(ShareCandidate p) => !p.keysChanged && !_request.alreadyAsked.contains(p.uid);

  @override
  void initState() {
    super.initState();
    // One person to ask: picked already, so asking is one press.
    final askable = _request.people.where(_canAsk).toList();
    if (askable.length == 1) _picked.add(askable.single.uid);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final host = Redactable.host(_request.hostLabel).displayIn(ref);
    final crate = _request.crateName;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.eye,
      title: l10n.watchAskTitle,
      subtitle: l10n.watchAskSub(host, crate),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ShareGroupLabel(l10n.shareWho),
          for (final p in _request.people)
            SharePersonTile(
              key: ValueKey('watch-person-${p.uid}'),
              name: Redactable.account(p.email ?? p.uid).displayIn(ref),
              detail: _request.alreadyAsked.contains(p.uid)
                  ? l10n.watchAskAlready
                  : p.keysChanged
                      ? l10n.sharePersonKeyChanged
                      : l10n.watchAskManages(crate),
              warn: p.keysChanged && !_request.alreadyAsked.contains(p.uid),
              checked: _picked.contains(p.uid) || _request.alreadyAsked.contains(p.uid),
              enabled: _canAsk(p),
              onTap: () => setState(() {
                if (!_picked.remove(p.uid)) _picked.add(p.uid);
              }),
            ),
          const SizedBox(height: 4),
          ShareNoteBox(icon: LucideIcons.eye, text: l10n.watchAskNote),
        ],
      ),
      primaryAction: (
        label: l10n.watchAskButton,
        icon: LucideIcons.eye,
        onPressed: _picked.isEmpty ? null : () => Navigator.of(context).pop(Set.of(_picked)),
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

/// Asks why the person goes on with nobody watching: their reason as a
/// report carries it, or null when they give up.
Future<String?> showUnwatchedAsk(BuildContext context, UnwatchedRequest request) => showZestModal<String>(
      context: context,
      size: ZestModalSize.standard,
      child: UnwatchedAskDialog(request: request),
    );

/// "Connect with nobody watching?": why nobody can be asked, what is
/// reported of the session and to whom, how ZestSSH Cloud stands (with its
/// code), and the reason, without which nothing goes on.
class UnwatchedAskDialog extends ConsumerStatefulWidget {
  const UnwatchedAskDialog({super.key, required this.request});

  final UnwatchedRequest request;

  @override
  ConsumerState<UnwatchedAskDialog> createState() => _UnwatchedAskDialogState();
}

class _UnwatchedAskDialogState extends ConsumerState<UnwatchedAskDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final request = widget.request;
    final host = Redactable.host(request.hostLabel).displayIn(ref);
    final crate = request.crateName;
    final reach = ref.watch(cloudReachStateProvider).valueOrNull;
    final failure = reach == null ? null : cloudFailureOfReach(reach);
    final given = unwatchedReason(_reason.text);
    void go() {
      if (given != null) Navigator.of(context).pop(given);
    }

    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.warning,
      icon: LucideIcons.eyeOff,
      title: request.held ? l10n.unwatchedAskTitleHeld : l10n.unwatchedAskTitle,
      subtitle: l10n.unwatchedAskSub(crate, host),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // What going on unwatched means, in its amber sentence (3.4).
          KeyedSubtree(
            key: const ValueKey('unwatched-ask-body'),
            child: ZestCallout(l10n.unwatchedAskBody(crate)),
          ),
          const SizedBox(height: 14),
          ZestFieldLabel(l10n.unwatchedAskReason),
          const SizedBox(height: 6),
          _ReasonField(
            key: const ValueKey('unwatched-ask-reason'),
            controller: _reason,
            hintText: l10n.unwatchedAskReasonHint,
            onChanged: (_) => setState(() {}),
            onSubmit: go,
          ),
          if (failure != null) ...[
            const SizedBox(height: 12),
            _CloudNote(key: const ValueKey('unwatched-ask-cloud'), failure: failure),
          ],
        ],
      ),
      // Going on with nobody watching is an exception the team is told of:
      // its button says so in red, never as a routine next step.
      primaryDanger: true,
      primaryAction: (
        label: request.held ? l10n.unwatchedAskGoOn : l10n.unwatchedAskConnect,
        icon: LucideIcons.eyeOff,
        onPressed: given == null ? null : go,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

/// The reason for going on with nobody watching: a few lines to write it
/// in (it is a sentence or two, read in full while written), Enter or Done
/// takes it, no longer than a report carries.
class _ReasonField extends StatefulWidget {
  const _ReasonField({super.key, required this.controller, required this.hintText, this.onChanged, this.onSubmit});

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmit;

  @override
  State<_ReasonField> createState() => _ReasonFieldState();
}

class _ReasonFieldState extends State<_ReasonField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      widget.controller.selection = TextSelection.collapsed(offset: widget.controller.text.length);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        focusNode: _focus,
        minLines: 3,
        maxLines: 6,
        maxLength: kUnwatchedReasonMax,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.done,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmit == null ? null : (_) => widget.onSubmit!(),
        style: TextStyle(fontFamily: 'GeistSans', fontSize: 14, height: 1.45, color: ZestTokens.textPrimary),
        decoration: InputDecoration(hintText: widget.hintText, counterText: '', hintMaxLines: 3),
      );
}

/// How ZestSSH Cloud stands, while it is in the way: what is going on, its
/// code apart where it can be read out, and Copy details for whoever helps.
class _CloudNote extends StatelessWidget {
  const _CloudNote({super.key, required this.failure});

  final CloudFailure failure;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final said = failure.message(l10n);
    final computer = switch (Theme.of(context).platform) {
      TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => true,
      _ => false,
    };
    return ShareNoteBox(
      icon: LucideIcons.cloudOff,
      text: ErrorCodes.withoutCode(said).$1,
      footer: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Container(
            key: const ValueKey('unwatched-ask-cloud-code'),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceChip,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: ZestTokens.borderSubtle),
            ),
            child: Text(failure.code.code,
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, height: 1.3, color: ZestTokens.textSecondary)),
          ),
          ConstrainedBox(
            // A finger's height on a phone.
            constraints: BoxConstraints(minHeight: computer ? 0 : 44),
            child: CopyDetailsButton(
              detail: ErrorReport.build(
                what: said,
                where: 'Watched session: asked why it goes on with nobody watching',
                details: failure.detail,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lets the held session [sessionId] go on with nobody watching, where its
/// person may: they are asked why first. Says so when it cannot be done.
Future<void> goOnWithNobodyWatching(BuildContext context, WidgetRef ref, String sessionId) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    await ref.read(activeSessionsProvider.notifier).goOnUnwatched(sessionId);
  } on SessionWatchCancelled {
    // They gave up: it stays held.
  } on OrchardAccessRefused catch (e) {
    if (context.mounted) showTopSnackBar(context, e.message, isError: true, details: '$e');
  } catch (e) {
    AppLogger.warning('Watched sessions: a held session could not go on with nobody watching ($e)');
    if (context.mounted) showTopSnackBar(context, orchardErrorMessage(e, l10n), isError: true, details: '$e');
  }
}

/// Asks someone else to watch the session [sessionId] (while it waits, or
/// while nobody is watching), and says so when that cannot be done.
Future<void> askSomeoneElseToWatch(BuildContext context, WidgetRef ref, String sessionId) async {
  final l10n = AppLocalizations.of(context)!;
  final gate = ref.read(watchGateProvider);
  final label = ref.read(activeSessionsProvider)[sessionId]?.connectionLabel ?? '';
  final request = await gate.requestFor(sessionId, hostLabel: label);
  if (request == null || !context.mounted) return;
  final picked = await showWatchAsk(context, request);
  if (picked == null || picked.isEmpty) return;
  try {
    await gate.askMore(sessionId, picked);
  } catch (e) {
    AppLogger.info('Watched sessions: nobody else could be asked ($e)');
    if (context.mounted) {
      showTopSnackBar(context, shareStartFailureText(l10n, e, notReady: l10n.watchedNotReady), isError: true, details: '$e');
    }
  }
}

/// The watch of [sessionId], rebuilt when it changes; nothing when the
/// session is not a watched one.
class _WatchOf extends StatelessWidget {
  const _WatchOf({required this.sessionId, required this.builder});

  final String sessionId;
  final Widget Function(BuildContext context, SessionWatch watch) builder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Map<String, SessionWatch>>(
        valueListenable: SessionWatches.active,
        builder: (context, watches, _) {
          final watch = watches[sessionId];
          if (watch == null) return const SizedBox.shrink();
          return ListenableBuilder(listenable: watch, builder: (context, _) => builder(context, watch));
        },
      );
}

/// What a connecting tab says while its session waits for someone to
/// watch: who was asked and where each stands, with the ways on (ask
/// someone else) and out (give up).
class WatchWaitingPanel extends ConsumerWidget {
  const WatchWaitingPanel({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final away = ref.watch(cloudReachStateProvider).valueOrNull?.inTheWay ?? false;
    return _WatchOf(
      sessionId: sessionId,
      builder: (context, watch) {
        if (watch.phase != SessionWatchPhase.choosing && watch.phase != SessionWatchPhase.waiting) {
          return const SizedBox.shrink();
        }
        final waiting = watch.phase == SessionWatchPhase.waiting;
        // ZestSSH Cloud cannot be reached and nobody was asked: the session
        // waits for nobody, its person is being asked why they connect.
        if (!waiting && away) return const SizedBox.shrink();
        // The card of a dialog, inline in the connecting tab: a header with
        // its icon, who was asked with where each stands, and the ways on
        // and out at its foot.
        return Container(
          key: ValueKey('watch-waiting-$sessionId'),
          constraints: const BoxConstraints(maxWidth: 440),
          margin: const EdgeInsets.only(top: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: ZestTokens.surfaceRaised,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ZestTokens.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: ZestTokens.statusWarning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: ZestTokens.statusWarning.withValues(alpha: 0.3)),
                    ),
                    child: Icon(LucideIcons.eye, size: 16, color: ZestTokens.statusWarning),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: waiting ? 0 : 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.watchWaitingTitle,
                              style: TextStyle(
                                  fontSize: 14, height: 1.35, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                          if (waiting) ...[
                            const SizedBox(height: 4),
                            Text(l10n.watchWaitingBody,
                                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (waiting) ...[
                const SizedBox(height: 14),
                for (final g in watch.asked)
                  Padding(
                    key: ValueKey('watch-asked-${g.uid}'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        ShareAvatar(
                            name: Redactable.account(SessionShares.nameOf(sessionId, g.uid)).displayIn(ref), size: 24),
                        const SizedBox(width: 10),
                        Expanded(
                          child: RedactedText(
                            Redactable.account(SessionShares.nameOf(sessionId, g.uid)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // A long state in a long language is drawn a little
                        // smaller, never over the card's edge.
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 200),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerEnd,
                            child: switch (g.state) {
                          ShareGuestState.invited =>
                            ZestStatusPill(kind: ZestStatusKind.neutral, label: l10n.shareStateInvited, icon: LucideIcons.mail),
                          ShareGuestState.declined =>
                            ZestStatusPill(kind: ZestStatusKind.stale, label: l10n.shareStateDeclined, icon: LucideIcons.xCircle),
                          ShareGuestState.connected =>
                            ZestStatusPill(kind: ZestStatusKind.pending, label: l10n.shareStateConnecting),
                          ShareGuestState.watching || ShareGuestState.typing => ZestStatusPill(
                              kind: ZestStatusKind.healthy, label: l10n.shareStateWatchingCanEnd, icon: LucideIcons.eye),
                        },
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 6),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    shareButton(
                      key: ValueKey('watch-cancel-$sessionId'),
                      label: l10n.cancel,
                      kind: ShareButtonKind.ghost,
                      onPressed: watch.cancel,
                    ),
                    shareButton(
                      key: ValueKey('watch-ask-other-$sessionId'),
                      label: l10n.watchAskOther,
                      onPressed: () => unawaited(askSomeoneElseToWatch(context, ref, sessionId)),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// How often a held session's line looks again whether its person could
/// let it go on with nobody watching (the app does not hear a live view's
/// link fail, so the service is asked).
const Duration kWatchGoOnLook = Duration(seconds: 15);

/// The line a watched session shows while nobody is watching it: typing
/// is held, when it closes, the way to ask someone else, and, while
/// ZestSSH Cloud cannot be reached, the way on for whoever may go on with
/// nobody watching. And the line of a session that goes on so.
class WatchHeldBanner extends ConsumerStatefulWidget {
  const WatchHeldBanner({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<WatchHeldBanner> createState() => _WatchHeldBannerState();
}

class _WatchHeldBannerState extends ConsumerState<WatchHeldBanner> {
  Timer? _tick;

  /// Whether the session is held, as last drawn.
  bool _held = false;

  /// Whether its person could let it go on with nobody watching, as last
  /// looked, and how many seconds ago that was.
  bool _mayGoOn = false;
  bool _looking = false;
  int _sinceLook = 0;

  /// The question that asks why is open.
  bool _asking = false;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Looks whether this session's person could let it go on now.
  Future<void> _look() async {
    if (_looking || !_held) return;
    _looking = true;
    _sinceLook = 0;
    var may = false;
    try {
      may = await ref.read(activeSessionsProvider.notifier).mayGoOnUnwatched(widget.sessionId);
    } catch (e) {
      AppLogger.info('Watched sessions: whether a held session may go on could not be read ($e)');
    } finally {
      _looking = false;
    }
    if (mounted && _held && may != _mayGoOn) setState(() => _mayGoOn = may);
  }

  Future<void> _goOn() async {
    setState(() => _asking = true);
    try {
      await goOnWithNobodyWatching(context, ref, widget.sessionId);
    } finally {
      if (mounted) setState(() => _asking = false);
      unawaited(_look());
    }
  }

  void _stop() {
    _tick?.cancel();
    _tick = null;
    _held = false;
    _mayGoOn = false;
  }

  /// The time left as minutes and seconds, counted down while it shows.
  String _left(DateTime closesAt) {
    final left = closesAt.difference(DateTime.now());
    final seconds = left.isNegative ? 0 : left.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // How ZestSSH Cloud stands changed: whether the session may go on is
    // looked at again at once.
    ref.listen(cloudReachStateProvider, (_, _) => unawaited(_look()));
    return _WatchOf(
      sessionId: widget.sessionId,
      builder: (context, watch) {
        // It runs with nobody watching, let go on while ZestSSH Cloud could
        // not be reached: said for as long as that is so.
        if (watch.phase == SessionWatchPhase.unwatched && watch.ranUnwatched) {
          _stop();
          return ShareStateStrip(
            key: ValueKey('watch-unwatched-${widget.sessionId}'),
            icon: LucideIcons.eyeOff,
            text: l10n.watchUnwatchedBanner,
            tone: ShareStripTone.warning,
          );
        }
        if (watch.phase != SessionWatchPhase.held) {
          _stop();
          return const SizedBox.shrink();
        }
        if (!_held) {
          _held = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_look()));
        }
        _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          if (++_sinceLook >= kWatchGoOnLook.inSeconds) unawaited(_look());
          setState(() {});
        });
        // While its person is asked why it goes on, nothing closes it.
        final closesAt = watch.closesAt;
        return ShareStateStrip(
          key: ValueKey('watch-held-${widget.sessionId}'),
          icon: LucideIcons.eyeOff,
          text: closesAt == null ? l10n.watchHeldBannerAsked : l10n.watchHeldBanner(_left(closesAt)),
          tone: ShareStripTone.warning,
          actions: [
            // Going on unwatched is an exception the team is told of: red,
            // as in the question that follows.
            if (_mayGoOn)
              shareButton(
                key: ValueKey('watch-held-go-on-${widget.sessionId}'),
                label: l10n.unwatchedAskGoOn,
                kind: ShareButtonKind.danger,
                onPressed: _asking ? null : () => unawaited(_goOn()),
                dense: true,
              ),
            shareButton(
              key: ValueKey('watch-held-ask-${widget.sessionId}'),
              label: l10n.watchAskOther,
              onPressed: () => unawaited(askSomeoneElseToWatch(context, ref, widget.sessionId)),
              dense: true,
            ),
          ],
        );
      },
    );
  }
}
