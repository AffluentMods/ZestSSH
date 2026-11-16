import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/replace_key.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// Opens "Replace key on its hosts" (replace_key.dart) for [key]: what it
/// does and the hosts it does it on, then each host's part as it goes, and,
/// once every host is done, what becomes of the old key. A replacement that
/// runs is shown as it stands.
Future<void> showReplaceKey(BuildContext context, Identity key) => showZestModal<void>(
      context: context,
      size: ZestModalSize.large,
      child: ReplaceKeyDialog(oldKey: key),
    );

class ReplaceKeyDialog extends ConsumerStatefulWidget {
  const ReplaceKeyDialog({super.key, required this.oldKey});

  final Identity oldKey;

  @override
  ConsumerState<ReplaceKeyDialog> createState() => _ReplaceKeyDialogState();
}

class _ReplaceKeyDialogState extends ConsumerState<ReplaceKeyDialog> {
  late KeyType _type = replacementTypeFor(widget.oldKey);

  /// The new key a replacement made before, where it is still there.
  String? _continuing;

  /// Why each host will be skipped, before anything is done.
  Map<String, ReplaceWhy?> _skips = const {};
  var _skipsKnown = false;

  var _deleteOld = false;

  /// Whether something besides the hosts done still signs in with the old
  /// key (it may then only be kept); null until known.
  bool? _oldStillUsed;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final old = widget.oldKey;
    final keptId = await ref.read(replaceKeyLinksProvider).newKeyOf(old.id);
    final kept = keptId == null ? null : await ref.read(identitiesDaoProvider).getById(keptId);
    final hosts = ref.read(identityUsageHostsProvider).valueOrNull?[old.id] ?? const <Connection>[];
    final space = ref.read(activeSpaceProvider);
    final resolver = ref.read(connectionResolverProvider);
    // All at once: each may wait on the network the device is on.
    final found = await Future.wait([for (final h in hosts) replaceSkipBefore(h, old, space: space, resolver: resolver)]);
    final skips = <String, ReplaceWhy?>{for (var i = 0; i < hosts.length; i++) hosts[i].id: found[i]};
    if (!mounted) return;
    setState(() {
      _continuing = kept?.label;
      _skips = skips;
      _skipsKnown = true;
    });
  }

  Future<void> _checkOldStillUsed(String oldId) async {
    final db = ref.read(databaseProvider);
    final connections = await db.connectionsDao.getAll();
    final accounts = await db.hostAccountsDao.getAllAssignments();
    final overrides = await db.networksDao.getAllOverrides();
    final used = connections.any((c) => c.identityId == oldId) ||
        accounts.values.any((ids) => ids.contains(oldId)) ||
        overrides.any((o) => o.identityId == oldId);
    if (mounted) setState(() => _oldStillUsed = used);
  }

  void _start(List<Connection> hosts) {
    final l10n = AppLocalizations.of(context)!;
    unawaited(ref.read(replaceKeyRunProvider.notifier).start(
          widget.oldKey,
          hosts,
          type: _type,
          newLabel: l10n.keysReplaceNewName(widget.oldKey.label),
        ));
  }

  Future<void> _finish(ReplaceRun run) async {
    final l10n = AppLocalizations.of(context)!;
    final delete = _deleteOld && _oldStillUsed == false;
    try {
      await ref.read(replaceKeyRunProvider.notifier).finish(
            deleteOld: delete,
            replacedLabel: l10n.keysReplaceOldName(widget.oldKey.label),
          );
    } catch (e) {
      if (mounted) showTopSnackBar(context, l10n.zestKeysNotSaved, isError: true, details: '$e');
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  String _name(String raw) => Redactable.keyName(raw).displayIn(ref);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final run = ref.watch(replaceKeyRunProvider);
    if (run != null && run.oldId != widget.oldKey.id && run.running) return _busy(context, l10n);
    if (run != null && run.oldId == widget.oldKey.id) return _results(context, l10n, run);
    return _setup(context, l10n);
  }

  ZestDialogShell _shell({
    required Widget body,
    ({String label, VoidCallback? onPressed, IconData? icon})? primary,
    ({String label, VoidCallback? onPressed})? secondary,
    bool primaryDanger = false,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.info,
      icon: LucideIcons.refreshCw,
      title: l10n.keysReplaceTitle,
      subtitle: l10n.keysReplaceSubtitle(_name(widget.oldKey.label)),
      body: body,
      primaryKey: const ValueKey('keys-replace-primary'),
      secondaryKey: const ValueKey('keys-replace-secondary'),
      primaryAction: primary,
      secondaryAction: secondary,
      primaryDanger: primaryDanger,
    );
  }

  Widget _busy(BuildContext context, AppLocalizations l10n) => _shell(
        body: _Note(icon: LucideIcons.info, text: l10n.keysReplaceBusy),
        secondary: (label: l10n.close, onPressed: () => Navigator.of(context).pop()),
      );

  Widget _setup(BuildContext context, AppLocalizations l10n) {
    final hosts = ref.watch(identityUsageHostsProvider).valueOrNull?[widget.oldKey.id] ?? const <Connection>[];
    final goes = hosts.where((h) => _skips[h.id] == null).length;
    final newName = _continuing ?? l10n.keysReplaceNewName(widget.oldKey.label);
    final steps = [
      l10n.keysReplaceStepMake(_name(newName)),
      l10n.keysReplaceStepAdd,
      l10n.keysReplaceStepProve,
      l10n.keysReplaceStepRemove,
      l10n.keysReplaceStepPoint,
    ];
    final same = replacementTypeFor(widget.oldKey);
    final types = {same, ...kReplaceKeyTypes};
    return _shell(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestSectionHeader(label: l10n.keysReplaceHowHeader),
          for (var i = 0; i < steps.length; i++) _Step(number: i + 1, text: steps[i]),
          const SizedBox(height: 6),
          _Note(icon: LucideIcons.shieldCheck, text: l10n.keysReplaceSafe, iconColor: ZestTokens.statusHealthy),
          const SizedBox(height: 16),
          if (_continuing != null)
            _Note(
              key: const ValueKey('keys-replace-continuing'),
              icon: LucideIcons.keyRound,
              text: l10n.keysReplaceContinuing(_name(_continuing!)),
            )
          else ...[
            ZestFieldLabel(l10n.keysReplaceNewType),
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: ZestSelect<KeyType>(
                key: const ValueKey('keys-replace-type'),
                value: _type,
                width: 280,
                items: [
                  for (final t in types)
                    ZestSelectItem(t, t == same ? l10n.keysReplaceSameType(t.displayName) : t.displayName),
                ],
                onChanged: (t) => setState(() => _type = t),
              ),
            ),
          ],
          const SizedBox(height: 18),
          ZestSectionHeader(label: l10n.keysReplaceHostsHeader, count: hosts.length),
          if (hosts.isEmpty)
            _Note(icon: LucideIcons.info, text: l10n.keysReplaceNoHosts)
          else
            for (final h in hosts)
              _HostLine(
                key: ValueKey('keys-replace-host-${h.id}'),
                host: h,
                user: widget.oldKey.username,
                pill: _skips[h.id] == null ? null : (ZestStatusKind.warning, l10n.keysReplaceSkipped),
                note: _skips[h.id] == null ? null : whyWords(l10n, _skips[h.id]!),
              ),
        ],
      ),
      primary: (
        label: l10n.keysReplaceStart(goes),
        icon: LucideIcons.refreshCw,
        onPressed: _skipsKnown && goes > 0 ? () => _start(hosts) : null,
      ),
      secondary: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }

  Widget _results(BuildContext context, AppLocalizations l10n, ReplaceRun run) {
    final notifier = ref.read(replaceKeyRunProvider.notifier);
    final left = run.hosts.where((h) => h.step != ReplaceStep.done).length;
    final allDone = !run.running && run.allDone;
    if (allDone && _oldStillUsed == null) unawaited(_checkOldStillUsed(run.oldId));
    final newName = run.newLabel == null ? null : _name(run.newLabel!);
    return _shell(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (run.failure != null)
            _Note(
              key: const ValueKey('keys-replace-not-started'),
              icon: LucideIcons.alertTriangle,
              text: l10n.keysReplaceNotStarted,
              color: ZestTokens.statusCritical,
              details: '${run.failure}',
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.keysReplaceSummary(run.done, run.hosts.length),
                    key: const ValueKey('keys-replace-summary'),
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestTokens.textSecondary),
                  ),
                ),
                CopyDetailsButton(
                  key: const ValueKey('keys-replace-copy-all'),
                  label: l10n.runOnHostsCopyAll,
                  detail: replaceReport(run, l10n),
                ),
              ],
            ),
            if (newName != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  l10n.keysReplaceStepMake(newName),
                  style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
                ),
              ),
            for (final h in run.hosts)
              _HostLine(
                key: ValueKey('keys-replace-row-${h.host.id}'),
                host: h.host,
                user: h.user ?? widget.oldKey.username,
                pill: (stepKind(h), stepWords(l10n, h)),
                busy: h.going,
                note: noteOf(l10n, h),
                details: h.step == ReplaceStep.failed || h.step == ReplaceStep.skipped ? hostReport(h, l10n) : null,
              ),
          ],
          if (allDone) ...[
            const SizedBox(height: 16),
            _Note(
              key: const ValueKey('keys-replace-all-done'),
              icon: LucideIcons.checkCircle2,
              text: l10n.keysReplaceAllDone(newName ?? ''),
              color: ZestTokens.statusHealthy,
            ),
            const SizedBox(height: 12),
            ZestSectionHeader(label: l10n.keysReplaceOldKeyHeader),
            RadioGroup<bool>(
              groupValue: _deleteOld,
              onChanged: (delete) {
                if (delete == null || (delete && _oldStillUsed != false)) return;
                setState(() => _deleteOld = delete);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Choice(
                    key: const ValueKey('keys-replace-keep-old'),
                    value: false,
                    selected: !_deleteOld,
                    title: l10n.keysReplaceKeepOld(_name(l10n.keysReplaceOldName(widget.oldKey.label))),
                    hint: l10n.keysReplaceKeepOldHint,
                    onTap: () => setState(() => _deleteOld = false),
                  ),
                  const SizedBox(height: 8),
                  _Choice(
                    key: const ValueKey('keys-replace-delete-old'),
                    value: true,
                    selected: _deleteOld,
                    title: l10n.keysReplaceDeleteOld,
                    hint: _oldStillUsed == true ? l10n.keysReplaceOldStillUsed : l10n.keysReplaceDeleteOldHint,
                    danger: true,
                    onTap: _oldStillUsed == false ? () => setState(() => _deleteOld = true) : null,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      primary: run.running
          ? (label: l10n.keysReplaceStopButton, icon: LucideIcons.square, onPressed: notifier.stop)
          : allDone
              ? (label: l10n.keysReplaceFinish, icon: LucideIcons.check, onPressed: _oldStillUsed == null ? null : () => _finish(run))
              : (
                  label: l10n.keysReplaceAgain(left),
                  icon: LucideIcons.rotateCcw,
                  onPressed: left > 0 && run.failure == null ? () => unawaited(notifier.again()) : null,
                ),
      primaryDanger: run.running || (allDone && _deleteOld),
      secondary: (
        label: l10n.close,
        onPressed: () {
          // A run that failed before any host is forgotten: opened again,
          // the dialog starts over.
          if (run.failure != null) notifier.clear();
          Navigator.of(context).pop();
        },
      ),
    );
  }
}

/// Why a host was skipped or failed, or what is to be known of one done.
String whyWords(AppLocalizations l10n, ReplaceWhy why) => switch (why) {
      ReplaceWhy.notSsh => l10n.keysReplaceWhyNotSsh,
      ReplaceWhy.jumpHost => l10n.keysReplaceWhyJumpHost,
      ReplaceWhy.teamHost => l10n.keysReplaceWhyTeamHost,
      ReplaceWhy.otherKeyHere => l10n.keysReplaceWhyOtherKeyHere,
      ReplaceWhy.notOnThisNetwork => l10n.keysReplaceWhyNotOnThisNetwork,
      ReplaceWhy.signInFailed => l10n.keysReplaceWhySignInFailed,
      ReplaceWhy.unreadableFile => l10n.keysReplaceWhyUnreadableFile,
      ReplaceWhy.linkFile => l10n.keysReplaceWhyLinkFile,
      ReplaceWhy.oldWithOptions => l10n.keysReplaceWhyOldWithOptions,
      ReplaceWhy.oldUnreadable => l10n.keysReplaceWhyOldUnreadable,
      ReplaceWhy.notAdded => l10n.keysReplaceWhyNotAdded,
      ReplaceWhy.proofFailed => l10n.keysReplaceWhyProofFailed,
      ReplaceWhy.changedMeanwhile => l10n.keysReplaceWhyChanged,
      ReplaceWhy.newKeyMissing => l10n.keysReplaceWhyNewKeyMissing,
      ReplaceWhy.notWritten => l10n.keysReplaceWhyNotWritten,
      ReplaceWhy.notPointed => l10n.keysReplaceWhyNotPointed,
      ReplaceWhy.oldNotFound => l10n.keysReplaceWhyOldNotFound,
      ReplaceWhy.stopped => l10n.keysReplaceWhyStopped,
    };

/// A host's step, as a word or a few.
String stepWords(AppLocalizations l10n, ReplaceHost h) => switch (h.step) {
      ReplaceStep.waiting => l10n.keysReplaceWaiting,
      ReplaceStep.signingIn => l10n.keysReplaceSigningIn,
      ReplaceStep.reading => l10n.keysReplaceReading,
      ReplaceStep.adding => l10n.keysReplaceAdding,
      ReplaceStep.proving => l10n.keysReplaceProving,
      ReplaceStep.removing => l10n.keysReplaceRemoving,
      ReplaceStep.pointing => l10n.keysReplacePointing,
      ReplaceStep.done => l10n.keysReplaceDone,
      ReplaceStep.skipped => l10n.keysReplaceSkipped,
      ReplaceStep.failed => l10n.keysReplaceFailed,
      ReplaceStep.stopped => l10n.keysReplaceStoppedState,
    };

/// A host's step as a status: green done, amber skipped (or done with the
/// old key not found), red failed, grey waiting or stopped, and going.
ZestStatusKind stepKind(ReplaceHost h) => switch (h.step) {
      ReplaceStep.done => h.why == ReplaceWhy.oldNotFound ? ZestStatusKind.warning : ZestStatusKind.healthy,
      ReplaceStep.skipped => ZestStatusKind.warning,
      ReplaceStep.failed => ZestStatusKind.critical,
      ReplaceStep.waiting || ReplaceStep.stopped => ZestStatusKind.neutral,
      _ => ZestStatusKind.pending,
    };

/// What is said under a host: why, or that the old key was removed.
String? noteOf(AppLocalizations l10n, ReplaceHost h) {
  final why = h.why;
  if (why != null) return whyWords(l10n, why);
  if (h.step == ReplaceStep.done) return l10n.keysReplaceRemovedOld;
  return null;
}

/// One host's part as text, for its Copy details (scrubbed when copied).
String hostReport(ReplaceHost h, AppLocalizations l10n) {
  final name = h.host.label.isNotEmpty ? h.host.label : h.host.host;
  final out = StringBuffer('${l10n.keysReplaceTitle}: $name (${hostWithPort(h.host.host, h.host.port)}): ${stepWords(l10n, h)}');
  final note = noteOf(l10n, h);
  if (note != null) out.write('\n$note');
  final details = h.details?.trim();
  if (details != null && details.isNotEmpty) out.write('\n$details');
  return out.toString();
}

/// A replacement as text: each host with how it went.
String replaceReport(ReplaceRun run, AppLocalizations l10n) =>
    [for (final h in run.hosts) hostReport(h, l10n)].join('\n\n');

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: ZestTokens.surfaceChip,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: ZestTokens.borderSubtle),
              ),
              child: Text('$number',
                  style: TextStyle(fontSize: 10.5, fontFamily: 'JetBrainsMono', color: ZestTokens.textSecondary)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(fontSize: 13, height: 1.4, color: ZestTokens.textPrimary))),
          ],
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.icon, required this.text, this.color, this.iconColor, this.details});

  final IconData icon;
  final String text;
  final Color? color;

  /// The icon's own colour, where it is not the words'.
  final Color? iconColor;
  final String? details;

  @override
  Widget build(BuildContext context) {
    final c = color ?? ZestTokens.textTertiary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 14, color: iconColor ?? c)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: TextStyle(fontSize: 12.5, height: 1.4, color: c)),
                if (details != null) CopyDetailsButton(detail: details!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A host: its name, who it is signed in to as and where, its state, and
/// under them why (with Copy details where it did not go well).
class _HostLine extends ConsumerWidget {
  const _HostLine({
    super.key,
    required this.host,
    required this.user,
    this.pill,
    this.busy = false,
    this.note,
    this.details,
  });

  final Connection host;
  final String user;
  final (ZestStatusKind, String)? pill;
  final bool busy;
  final String? note;
  final String? details;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: HostRow(
                  host: host,
                  user: user,
                  nameStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
                  padding: EdgeInsets.zero,
                  margin: EdgeInsets.zero,
                  hovers: false,
                ),
              ),
              const SizedBox(width: 10),
              // A step under way turns in its pill: a spinner beside a pill
              // with its own icon said it twice
              // before.
              if (pill case (final kind, final label)) ZestStatusPill(kind: kind, label: label, busy: busy),
            ],
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(left: 25, top: 5),
              child: Text(note!, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
            ),
          if (details != null)
            Padding(
              padding: const EdgeInsets.only(left: 19),
              child: Align(alignment: AlignmentDirectional.centerStart, child: CopyDetailsButton(detail: details!)),
            ),
        ],
      ),
    );
  }
}

/// One of the two choices for the old key: one is picked, so the dot radio
/// the dialogs have, in the RadioGroup around the two (it
/// was a check in a circle before, which is for where several can
/// be picked).
class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.value,
    required this.selected,
    required this.title,
    required this.hint,
    this.onTap,
    this.danger = false,
  });

  /// What picking it sets: whether the old key is deleted.
  final bool value;
  final bool selected;
  final String title;
  final String hint;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final accent = danger ? ZestTokens.statusCritical : ZestTokens.brandInk;
    return Opacity(
      opacity: enabled || selected ? 1 : 0.55,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceRaisedAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: selected ? accent : ZestTokens.borderSubtle, width: selected ? 1.2 : 1),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  // Red where the choice deletes, as its edge is.
                  child: Radio<bool>(value: value, enabled: enabled, activeColor: danger ? accent : null),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary)),
                      const SizedBox(height: 3),
                      Text(hint, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
