import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';

// What the team records (3.0) on the Rules page: each
// thing its owners can turn on, what it keeps and for whom, on or off.
// Owners change version history and activity, all at once, after saying
// yes and a recent sign-in; everyone else sees where things stand. Devices
// and sign-in addresses are not collected yet: they show only while a newer
// app has them on, and an owner can turn them off (or back on before saving).

class TeamTrackingPanel extends ConsumerStatefulWidget {
  const TeamTrackingPanel({super.key, required this.orchard});

  final OrchardSummary orchard;

  @override
  ConsumerState<TeamTrackingPanel> createState() => _TeamTrackingPanelState();
}

class _TeamTrackingPanelState extends ConsumerState<TeamTrackingPanel> {
  RecordTracking? _draft;
  bool _busy = false;

  Future<void> _save(RecordTracking was, RecordTracking next) async {
    final l10n = AppLocalizations.of(context)!;
    final name = orchardDisplayName(widget.orchard.name, l10n);
    final on = trackingOnNames(next, l10n);
    final body = [
      on.isEmpty ? l10n.trackingConfirmNoneBody : l10n.trackingConfirmBody(on.join(l10n.listSeparator)),
      if (next.history && !was.history) l10n.trackingHistoryStartsNow,
    ].join('\n\n');
    // The activity kept so far deleted: the one sentence that warns.
    final deletes = was.activity && !next.activity;
    final go = await ZestConfirmDialog.show(
      context,
      tone: deletes ? ZestDialogTone.warning : ZestDialogTone.neutral,
      title: l10n.trackingConfirmTitle(name),
      body: body,
      warning: deletes ? l10n.trackingActivityDeleted : null,
      confirmLabel: l10n.trackingSaveChange,
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final done = await withRecentSignIn(
        context,
        ref,
        () => ref.read(orchardServiceProvider).setTracking(widget.orchard.id, next),
        summary: (what: l10n.stepUpTracking(name), effects: const []),
      );
      if (!done || !mounted) return;
      ref.read(orchardListVersionProvider.notifier).state++;
      setState(() => _draft = null);
      showTopSnackBar(context, l10n.trackingSaved, isSuccess: true);
    } catch (e) {
      AppLogger.warning('Tracking: not changed ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final o = widget.orchard;
    final saved = ref.watch(teamTrackingProvider(o.id)).valueOrNull;
    final draft = _draft ?? saved;
    final owner = o.isOwner && o.active;
    final some = saved != null && !saved.isNone;
    final changed = saved != null && draft != null && draft != saved;
    void set(RecordTracking next) => setState(() => _draft = next);
    final rows = saved == null || draft == null
        ? const <Widget>[]
        : [
            _TrackingRow(
              key: const ValueKey('team-tracking-history'),
              icon: LucideIcons.history,
              title: l10n.trackingHistoryTitle,
              body: l10n.trackingHistoryBody,
              on: draft.history,
              onChanged: owner && !_busy ? (v) => set(draft.copyWith(history: v)) : null,
            ),
            _TrackingRow(
              key: const ValueKey('team-tracking-activity'),
              icon: LucideIcons.activity,
              title: l10n.trackingActivityTitle,
              body: l10n.trackingActivityBody,
              on: draft.activity,
              onChanged: owner && !_busy ? (v) => set(draft.copyWith(activity: v)) : null,
            ),
            // Not collected by this app: shown while saved on, so turning one
            // back on here only undoes turning it off.
            if (saved.devices)
              _TrackingRow(
                key: const ValueKey('team-tracking-devices'),
                icon: LucideIcons.laptop,
                title: l10n.trackingDevicesTitle,
                body: l10n.trackingDevicesBody,
                on: draft.devices,
                onChanged: owner && !_busy ? (v) => set(draft.copyWith(devices: v)) : null,
              ),
            if (saved.ips)
              _TrackingRow(
                key: const ValueKey('team-tracking-ips'),
                icon: LucideIcons.globe,
                title: l10n.trackingIpsTitle,
                body: l10n.trackingIpsBody,
                on: draft.ips,
                onChanged: owner && !_busy ? (v) => set(draft.copyWith(ips: v)) : null,
              ),
          ];
    // One card: its head, then each thing it can record on a row of its
    // own split by hairlines (they were bordered boxes inside the bordered
    // box), and Save at its foot once something changed (a disabled Save
    // sat alone under the rows before).
    return Container(
      key: const ValueKey('team-tracking'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final pad = box.maxWidth < kTeamNarrow ? 16.0 : 20.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, rows.isEmpty ? pad : 12),
              child: TeamCardHeader(
                icon: LucideIcons.eye,
                title: l10n.trackingTitle,
                body: l10n.trackingBody,
                trailing: saved == null
                    ? null
                    : ZestStatusPill(
                        key: ValueKey('team-tracking-state-${some ? 'some' : 'none'}'),
                        kind: some ? ZestStatusKind.healthy : ZestStatusKind.neutral,
                        label: some ? l10n.trackingStateSome : l10n.trackingStateNone,
                      ),
              ),
            ),
            for (final r in rows) ...[
              Divider(height: 1, thickness: 1, indent: pad, endIndent: pad, color: ZestTokens.borderSubtle),
              Padding(padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12), child: r),
            ],
            if (rows.isNotEmpty && !owner) ...[
              Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
              Padding(
                padding: EdgeInsets.fromLTRB(pad, 12, pad, 12),
                child: Text(l10n.trackingOwnersOnly,
                    key: const ValueKey('team-tracking-owners-only'),
                    style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary)),
              ),
            ] else if (changed || _busy) ...[
              Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
              Container(
                color: ZestTokens.surfaceRaisedAlt,
                padding: EdgeInsets.fromLTRB(pad, 12, pad, 12),
                alignment: AlignmentDirectional.centerEnd,
                child: teamButton(
                  key: const ValueKey('team-tracking-save'),
                  kind: TeamButtonKind.primary,
                  icon: LucideIcons.check,
                  busy: _busy,
                  label: l10n.save,
                  onPressed: () => _save(saved!, draft!),
                ),
              ),
            ] else if (rows.isNotEmpty)
              const SizedBox(height: 8),
          ],
        );
      }),
    );
  }
}

class _TrackingRow extends StatelessWidget {
  const _TrackingRow({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.on,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool on;

  /// Null when this account cannot change it: the state is shown instead.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TeamIconTile(icon: icon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, height: 1.4, color: ZestTokens.textPrimary)),
              const SizedBox(height: 2),
              Text(body, style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (onChanged != null)
          ZestSwitch(value: on, onChanged: onChanged)
        else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: ZestStatusPill(
              kind: on ? ZestStatusKind.healthy : ZestStatusKind.neutral,
              label: on ? l10n.teamRecoveryStateOn : l10n.teamRecoveryStateOff,
            ),
          ),
      ],
    );
  }
}
