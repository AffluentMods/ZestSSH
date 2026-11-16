import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart' show crateLevelLabel;
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Opens "Share this session" for [sessionId] (3.0): how it is shared, with
/// whom, whether they may ask for the keyboard, and who of them may end
/// the session (session moderation). For a session already
/// shared, it invites more people. [context] is one that stays while this
/// works out what sharing involves (a screen, not a pop-up that is closing).
Future<void> showShareSession(BuildContext context, String sessionId) async {
  final providers = ProviderScope.containerOf(context, listen: false);
  final session = providers.read(activeSessionsProvider)[sessionId];
  if (session == null) return;
  // A remote screen (4.0) has no terminal to share; its picture is not
  // shared in this version.
  if (providers.read(activeSessionsProvider.notifier).isScreen(sessionId)) {
    showTopSnackBar(context, AppLocalizations.of(context)!.hostScreenNoTerminal, isWarning: true);
    return;
  }
  final (shareContext, why) = await providers.read(sessionSharingProvider).availabilityFor(sessionId);
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  if (shareContext == null) {
    await ZestDialogShell.showModal<void>(
      context,
      size: ZestModalSize.compact,
      tone: ZestDialogTone.info,
      icon: LucideIcons.users,
      title: l10n.shareMenuItem,
      subtitle: why == ShareUnavailable.notInCrate
          ? l10n.shareNotInCrateSub(Redactable.host(session.connectionLabel).display)
          : null,
      body: Text(
        why == ShareUnavailable.notInCrate ? l10n.shareNotInCrateBody : l10n.shareNotReadyBody,
        style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary),
      ),
      // Nothing to do here but read it: Close, never as the main button.
      secondaryAction: (label: l10n.close, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
    );
    return;
  }
  await showZestModal<void>(
    context: context,
    size: ZestModalSize.large,
    child: ShareSessionDialog(sessionId: sessionId, shareContext: shareContext),
  );
}

/// A name for a tmux session made to be shared: short, and only letters and
/// digits that cannot be mistaken for one another.
String newSharedTmuxName([Random? random]) {
  const letters = 'abcdefghjkmnpqrstuvwxyz23456789';
  final r = random ?? Random.secure();
  return 'shared-${List.generate(4, (_) => letters[r.nextInt(letters.length)]).join()}';
}

class ShareSessionDialog extends ConsumerStatefulWidget {
  const ShareSessionDialog({super.key, required this.sessionId, required this.shareContext});

  final String sessionId;
  final ShareContext shareContext;

  @override
  ConsumerState<ShareSessionDialog> createState() => _ShareSessionDialogState();
}

class _ShareSessionDialogState extends ConsumerState<ShareSessionDialog> {
  late ShareMode _mode;
  final _picked = <String>{};

  /// Those picked who may end the session (a live view only).
  final _enders = <String>{};
  bool _keyboard = true;
  bool _busy = false;
  String? _error;

  ShareContext get _ctx => widget.shareContext;

  /// The share this session already has: then the dialog invites more.
  ShareHostController? get _existing => SessionShares.of(widget.sessionId);

  TmuxSessionHost get _tmux => ref.read(tmuxHostProvider(widget.sessionId));

  /// Why the session cannot be shared as tmux right now, in words; null
  /// when it can.
  String? _tmuxProblem(AppLocalizations l10n) {
    // A watched Crate's session is watched in a live view: someone
    // attached to a tmux session signs in by themselves, unwatched.
    if (_ctx.watched) return l10n.shareTmuxWatched;
    if (!_ctx.synced) return l10n.shareTmuxNeedsSync;
    final tmux = _tmux;
    if (tmux.live) {
      final name = tmux.controller?.currentSessionName ?? '';
      if (!kShareTmuxName.hasMatch(name)) return l10n.shareTmuxBadName;
    }
    return null;
  }

  /// A live view shows the session's own terminal: while the tab shows
  /// tmux, there is none to show.
  String? _liveProblem(AppLocalizations l10n) => _tmux.active ? l10n.shareLiveInTmux : null;

  @override
  void initState() {
    super.initState();
    final existing = _existing;
    if (existing != null) {
      _mode = existing.mode;
      _keyboard = existing.keyboardRequests;
    } else {
      _mode = ShareMode.tmux;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_existing != null) return;
    // The recommended way when it is possible, else the other one.
    final l10n = AppLocalizations.of(context)!;
    if (_mode == ShareMode.tmux && _tmuxProblem(l10n) != null && _liveProblem(l10n) == null) {
      _mode = ShareMode.live;
    }
  }

  List<ShareGuest> get _guests => _existing?.guests ?? const <ShareGuest>[];

  /// Those who hold an invitation now. Someone who said no can be asked
  /// again.
  Set<String> get _alreadyInvited => {
        for (final g in _guests)
          if (g.state != ShareGuestState.declined) g.uid,
      };

  bool _canPick(ShareCandidate p) => !p.keysChanged && !_alreadyInvited.contains(p.uid);

  /// How many people the share would have: everyone on its list (those who
  /// said no keep their place on it) and those picked who are not.
  int get _total {
    final listed = {for (final g in _guests) g.uid};
    return listed.length + _picked.where((uid) => !listed.contains(uid)).length;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    if (_busy || _picked.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final sharing = ref.read(sessionSharingProvider);
    try {
      final existing = _existing;
      if (existing != null) {
        SessionShares.addNames(widget.sessionId, {
          for (final p in _ctx.people)
            if (_picked.contains(p.uid)) p.uid: p.email ?? p.uid,
        });
        await existing.invite(
          [
            for (final p in _ctx.people)
              if (_picked.contains(p.uid)) p.party!,
          ],
          watchOnly: {
            for (final p in _ctx.people)
              if (_picked.contains(p.uid) && p.watchOnly) p.uid,
          },
          enders: existing.mode == ShareMode.live ? _enders.intersection(_picked) : const {},
        );
      } else if (_mode == ShareMode.live) {
        await sharing.start(widget.sessionId, _ctx,
            mode: ShareMode.live, people: _picked, keyboardRequests: _keyboard, enders: _enders.intersection(_picked));
      } else {
        final name = await _tmuxSessionToShare();
        if (name == null) {
          if (mounted) {
            setState(() {
              _busy = false;
              _error = l10n.shareTmuxFailed;
            });
          }
          return;
        }
        await sharing.start(widget.sessionId, _ctx, mode: ShareMode.tmux, people: _picked, tmuxSession: name);
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      showTopSnackBar(context, l10n.shareStarted, isSuccess: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = shareStartFailureText(l10n, e, notReady: l10n.shareFailedNotReady);
      });
    }
  }

  /// The tmux session to invite people to: the one this tab is attached to,
  /// or a new one started here. Null when tmux could not be started.
  Future<String?> _tmuxSessionToShare() async {
    final tmux = _tmux;
    if (tmux.live) return tmux.controller?.currentSessionName;
    final name = newSharedTmuxName();
    await tmux.createSession(name);
    // Attached once tmux has answered; a host without tmux fails here.
    for (var i = 0; i < 100; i++) {
      if (tmux.live) return name;
      if (tmux.stage == TmuxHostStage.failed ||
          tmux.stage == TmuxHostStage.notInstalled ||
          tmux.stage == TmuxHostStage.noLiveSession) {
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return tmux.live ? name : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = ref.watch(activeSessionsProvider)[widget.sessionId];
    final existing = _existing;
    final hostName = Redactable.host(session?.connectionLabel ?? '').displayIn(ref);
    final crate = _ctx.crateName;
    final tmuxProblem = _tmuxProblem(l10n);
    final liveProblem = _liveProblem(l10n);
    final modeProblem = _mode == ShareMode.tmux ? tmuxProblem : liveProblem;
    final tooMany = _total > kShareMaxPeople;
    final canSubmit = !_busy && _picked.isNotEmpty && !tooMany && (existing != null || modeProblem == null);

    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.info,
      icon: LucideIcons.users,
      title: l10n.shareTitle(hostName),
      subtitle: l10n.shareUiSubtitle(crate),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (existing == null) ...[
            _ModeTile(
              key: const ValueKey('share-mode-tmux'),
              selected: _mode == ShareMode.tmux,
              enabled: tmuxProblem == null && !_busy,
              icon: LucideIcons.terminalSquare,
              title: l10n.shareChipTmux,
              badge: l10n.shareUiRecommended,
              body: l10n.shareModeTmuxBody,
              note: tmuxProblem ?? (_tmux.live ? null : l10n.shareTmuxNewSession),
              warn: tmuxProblem != null,
              onTap: () => setState(() => _mode = ShareMode.tmux),
            ),
            _ModeTile(
              key: const ValueKey('share-mode-live'),
              selected: _mode == ShareMode.live,
              enabled: liveProblem == null && !_busy,
              icon: LucideIcons.eye,
              title: l10n.shareModeLiveTitle,
              body: l10n.shareModeLiveBody,
              note: liveProblem,
              warn: liveProblem != null,
              onTap: () => setState(() => _mode = ShareMode.live),
            ),
            const SizedBox(height: 6),
          ],
          ShareGroupLabel(l10n.shareWho),
          if (_ctx.people.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(l10n.shareNobody(crate),
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary)),
            ),
          for (final p in _ctx.people)
            SharePersonTile(
              key: ValueKey('share-person-${p.uid}'),
              name: Redactable.account(p.email ?? p.uid).displayIn(ref),
              // (One picked who may end the session says so by the box
              // under their name, not twice.)
              detail: _alreadyInvited.contains(p.uid)
                  ? l10n.shareAlreadyInvited
                  : p.keysChanged
                      ? l10n.sharePersonKeyChanged
                      : _mode == ShareMode.live && p.watchOnly && !(_picked.contains(p.uid) && _enders.contains(p.uid))
                          ? l10n.sharePersonLevelWatchOnly(crate, crateLevelLabel(p.level, l10n))
                          : l10n.sharePersonLevel(crate, crateLevelLabel(p.level, l10n)),
              warn: p.keysChanged && !_alreadyInvited.contains(p.uid),
              checked: _picked.contains(p.uid) || _alreadyInvited.contains(p.uid),
              enabled: _canPick(p) && !_busy,
              onTap: () => setState(() {
                if (!_picked.remove(p.uid)) {
                  _picked.add(p.uid);
                  // In a watched Crate, someone who manages it is invited
                  // as one who watches: able to end the session.
                  if (_ctx.watched && p.canManage) _enders.add(p.uid);
                }
                _error = null;
              }),
              // In a live view, someone picked may be the one who can end
              // the session: then they watch and never type.
              canEnd: _mode == ShareMode.live && _picked.contains(p.uid) ? _enders.contains(p.uid) : null,
              canEndLabel: l10n.shareCanEnd,
              canEndHelp: l10n.shareCanEndHelp,
              verifyLabel: l10n.shareUiVerify,
              onVerify: _busy ? null : () => openKeyComparison(context, ref),
              onCanEnd: _busy
                  ? null
                  : (v) => setState(() {
                        v ? _enders.add(p.uid) : _enders.remove(p.uid);
                      }),
            ),
          if (_ctx.withoutAccess.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(
                l10n.shareCantJoin(
                    _ctx.withoutAccess.map((e) => Redactable.account(e).displayIn(ref)).join(', '), crate),
                style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary),
              ),
            ),
          if (tooMany)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(l10n.shareTooManyPeople(kShareMaxPeople),
                  style: TextStyle(fontSize: 12, color: ZestTokens.statusWarning)),
            ),
          if (_mode == ShareMode.live && existing == null) ...[
            const SizedBox(height: 10),
            ShareSwitchRow(
              key: const ValueKey('share-keyboard'),
              title: l10n.shareKeyboardTitle,
              subtitle: l10n.shareKeyboardBody,
              value: _keyboard,
              onChanged: _busy ? null : (v) => setState(() => _keyboard = v),
            ),
          ],
          if (_ctx.sessionLogs) ...[
            const SizedBox(height: 10),
            ShareNoteBox(icon: LucideIcons.fileText, text: l10n.shareLogsNote(crate)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            ShareNoteBox(key: const ValueKey('share-error'), icon: LucideIcons.alertTriangle, text: _error!, warn: true),
          ],
        ],
      ),
      primaryAction: (
        label: existing != null
            ? l10n.shareInviteMore
            : _mode == ShareMode.tmux
                ? l10n.shareStartTmux
                : l10n.shareStartLive,
        icon: LucideIcons.users,
        onPressed: canSubmit ? _submit : null,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: _busy ? null : () => Navigator.of(context).pop()),
    );
  }
}


/// One way of sharing: a radio tile with its icon, what it means, and a
/// note when it is not possible here or does something worth knowing first.
/// Chosen shows as the radio and a brand outline, nothing more.
class _ModeTile extends StatelessWidget {
  const _ModeTile({
    super.key,
    required this.selected,
    required this.enabled,
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
    this.badge,
    this.note,
    this.warn = false,
  });

  final bool selected;
  final bool enabled;
  final IconData icon;
  final String title;
  final String? badge;
  final String body;
  final String? note;
  final bool warn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final on = selected && enabled;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: on,
        button: true,
        enabled: enabled,
        child: Opacity(
          opacity: enabled ? 1 : 0.6,
          child: Material(
            color: ZestTokens.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: enabled ? onTap : null,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: on ? ZestTokens.brandBorder : ZestTokens.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(on ? LucideIcons.circleDot : LucideIcons.circle,
                          size: 16, color: on ? ZestTokens.brandInk : ZestTokens.textTertiary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(icon, size: 16, color: ZestTokens.textSecondary),
                                  const SizedBox(width: 6),
                                  Text(title,
                                      style: TextStyle(
                                          fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                                ],
                              ),
                              if (badge != null) ShareBadge(badge!),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(body, style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary)),
                          if (note != null) ...[
                            const SizedBox(height: 6),
                            Text(note!,
                                style: TextStyle(
                                    fontSize: 12,
                                    height: 1.45,
                                    color: warn ? ZestTokens.statusWarning : ZestTokens.textSecondary)),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Someone who could be invited: a check tile with their address and what
/// they may do in the Crate. Picked shows as the checkbox and a brand
/// outline. One who cannot be picked (keys changed) has only the checkbox
/// dimmed: their address stays readable and the warning stays amber, with
/// the way to compare keys where [onVerify] is given.
class SharePersonTile extends StatelessWidget {
  const SharePersonTile({
    super.key,
    required this.name,
    required this.detail,
    required this.checked,
    required this.enabled,
    required this.onTap,
    this.warn = false,
    this.canEnd,
    this.canEndLabel = '',
    this.canEndHelp = '',
    this.onCanEnd,
    this.verifyLabel = '',
    this.onVerify,
  });

  final String name;
  final String detail;
  final bool checked;
  final bool enabled;
  final bool warn;
  final VoidCallback onTap;

  /// Whether this person may end the session; null where that is not to
  /// be chosen (not picked, or not a live view).
  final bool? canEnd;
  final String canEndLabel;
  final String canEndHelp;
  final ValueChanged<bool>? onCanEnd;

  /// Opens where their keys are compared, under a [warn]ing.
  final String verifyLabel;
  final VoidCallback? onVerify;

  @override
  Widget build(BuildContext context) {
    final ends = canEnd;
    final live = enabled || checked;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        checked: checked,
        enabled: enabled,
        child: Material(
          color: ZestTokens.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: enabled ? onTap : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: checked && enabled ? ZestTokens.brandBorder : ZestTokens.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Opacity(
                      opacity: live ? 1 : 0.45,
                      child: Icon(checked ? LucideIcons.checkSquare : LucideIcons.square,
                          size: 16, color: checked ? ZestTokens.brandInk : ZestTokens.textTertiary),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ShareAvatar(name: name),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                fontWeight: FontWeight.w600,
                                color: live ? ZestTokens.textPrimary : ZestTokens.textSecondary)),
                        const SizedBox(height: 2),
                        if (warn)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(LucideIcons.alertTriangle, size: 13, color: ZestTokens.statusWarning),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(detail,
                                    style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.statusWarning)),
                              ),
                            ],
                          )
                        else
                          Text(detail, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
                        if (ends != null) ...[
                          const SizedBox(height: 4),
                          _CanEndBox(value: ends, label: canEndLabel, help: canEndHelp, onChanged: onCanEnd),
                        ],
                      ],
                    ),
                  ),
                  if (warn && onVerify != null) ...[
                    const SizedBox(width: 8),
                    shareButton(
                      key: const ValueKey('share-person-verify'),
                      label: verifyLabel,
                      icon: LucideIcons.fingerprint,
                      onPressed: onVerify,
                      dense: true,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Can end the session" for one person: a checkbox with its words, as tall
/// as a finger needs on a phone.
class _CanEndBox extends StatelessWidget {
  const _CanEndBox({required this.value, required this.label, required this.help, required this.onChanged});

  final bool value;
  final String label;
  final String help;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final computer = switch (Theme.of(context).platform) {
      TargetPlatform.windows || TargetPlatform.macOS || TargetPlatform.linux => true,
      _ => false,
    };
    return Tooltip(
      message: help,
      child: Semantics(
        checked: value,
        enabled: onChanged != null,
        child: InkWell(
          key: const ValueKey('share-can-end'),
          borderRadius: BorderRadius.circular(6),
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: computer ? 30 : 44),
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(value ? LucideIcons.checkSquare : LucideIcons.square,
                      size: 16, color: value ? ZestTokens.brandInk : ZestTokens.textTertiary),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(label, style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
