import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/database.dart' show Connection, Identity;
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/identity/identity_cert_expiry.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show AccessRequestView, DeviceRequestView;
import 'package:zestssh/features/orchards/team/team_attention.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart' show shortMemberId;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show orchardDisplayName;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/ui/screens/sync/sync_failing_text.dart';
import 'package:zestssh/ui/screens/sync/sync_pause.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// What a "Needs you" row is about (3.1, the phone's notification center).
enum NeedsYouKind {
  /// A host Server Monitor shows critical, or warning.
  hostCritical,
  hostWarning,

  /// A watched host Server Monitor cannot check, for a reason its person
  /// can do something about (it does not answer, it refused the sign-in,
  /// there is nothing to sign in with, its key is to be looked at).
  hostCantCheck,

  /// The team on screen: a device asks to be approved, someone asks for
  /// access, people accepted an invitation, keys nobody compared yet.
  teamDevice,
  teamAccess,
  teamInvites,
  teamKeysChanged,
  teamKeysReplaced,
  teamNotVerified,

  /// This device's sync stopped until someone acts, or its person paused it.
  syncFailing,
  syncPaused,

  /// A saved key's certificate has run out, or runs out soon.
  certRanOut,
  certSoon,
}

/// One thing that needs the person now, from what the app already holds:
/// it is worked out again whenever what it comes from changes, so it leaves
/// the list by itself once resolved. Nothing of it is kept or sent.
class NeedsYouItem {
  const NeedsYouItem(
    this.kind, {
    required this.id,
    this.name,
    this.count = 0,
    this.view,
    this.sync,
    this.orchardName,
  });

  final NeedsYouKind kind;

  /// What it is about: a connection, a request, a member, a key; stable, for
  /// the row's key.
  final String id;

  /// A host's, a key's or a member's name, as stored (masked when shown).
  final String? name;

  /// How many (invitations, members).
  final int count;

  /// For a host: what Server Monitor makes of it.
  final MonitorHostView? view;

  /// For sync: how it stands.
  final SyncHealthState? sync;

  /// For the team: its name.
  final String? orchardName;

  /// Loud (red) or not (amber).
  bool get critical => switch (kind) {
        NeedsYouKind.hostCritical || NeedsYouKind.teamKeysChanged || NeedsYouKind.syncFailing || NeedsYouKind.certRanOut => true,
        _ => false,
      };
}

/// The reasons a watched host cannot be checked that its person can act on.
const _actionableCantCheck = {
  CantCheckReason.unreachable,
  CantCheckReason.authFailed,
  CantCheckReason.noCredentials,
  CantCheckReason.hostKeyReview,
};

/// Everything that needs the person right now, most pressing first. Built
/// only from state the app already has: Server Monitor's view of the hosts
/// it watches, the team on screen as this device holds it (requests are
/// counted only where the Team page already read them), how sync stands,
/// and the saved keys' certificates.
final needsYouProvider = Provider.autoDispose<List<NeedsYouItem>>((ref) {
  final now = DateTime.now();
  final hosts = <NeedsYouItem>[];
  final views = ref.watch(monitoredHostViewsProvider);
  if (views.isNotEmpty) {
    final names = {
      for (final Connection c in ref.watch(monitoredConnectionsProvider).valueOrNull ?? const <Connection>[]) c.id: c.label.isNotEmpty ? c.label : c.host,
    };
    for (final e in views.entries) {
      final v = e.value;
      final kind = switch (v.bucket) {
        MonitorBucket.critical => NeedsYouKind.hostCritical,
        MonitorBucket.warning => NeedsYouKind.hostWarning,
        MonitorBucket.cantCheck when _actionableCantCheck.contains(v.cantCheckReason) => NeedsYouKind.hostCantCheck,
        _ => null,
      };
      if (kind == null || !names.containsKey(e.key)) continue;
      hosts.add(NeedsYouItem(kind, id: e.key, name: names[e.key], view: v));
    }
    hosts.sort((a, b) => a.kind.index != b.kind.index
        ? a.kind.index.compareTo(b.kind.index)
        : (a.name ?? '').toLowerCase().compareTo((b.name ?? '').toLowerCase()));
  }

  final team = <NeedsYouItem>[];
  final orchard = ref.watch(activeOrchardProvider).valueOrNull;
  if (orchard != null && orchard.active) {
    final people = ref.watch(teamPeopleProvider(orchard.id)).valueOrNull;
    String nameOf(String uid) =>
        people?.members.where((m) => m.uid == uid).firstOrNull?.email ?? shortMemberId(uid);
    final teamName = orchard.name;
    // Requests wait on ZestSSH Cloud: listed only where this device already
    // read them (the Team page), never asked for from here.
    ref.watch(deviceRequestsVersionProvider);
    ref.watch(accessRequestsVersionProvider);
    final devices = ref.exists(deviceRequestsProvider(orchard.id))
        ? ref.watch(deviceRequestsProvider(orchard.id)).valueOrNull ?? const <DeviceRequestView>[]
        : const <DeviceRequestView>[];
    final asking = ref.exists(accessRequestsProvider(orchard.id))
        ? ref.watch(accessRequestsProvider(orchard.id)).valueOrNull?.waiting ?? const <AccessRequestView>[]
        : const <AccessRequestView>[];
    for (final d in devices) {
      team.add(NeedsYouItem(NeedsYouKind.teamDevice, id: d.id, name: nameOf(d.uid), orchardName: teamName));
    }
    for (final a in asking) {
      team.add(NeedsYouItem(NeedsYouKind.teamAccess,
          id: a.id, name: a.uid == null ? null : nameOf(a.uid!), orchardName: teamName));
    }
    for (final a in teamAttention(orchard: orchard, people: people, nowSeconds: now.millisecondsSinceEpoch ~/ 1000)) {
      final kind = switch (a.kind) {
        TeamAttentionKind.keysChanged => NeedsYouKind.teamKeysChanged,
        TeamAttentionKind.invitesWaiting => NeedsYouKind.teamInvites,
        TeamAttentionKind.keysReplaced => NeedsYouKind.teamKeysReplaced,
        TeamAttentionKind.notVerified => NeedsYouKind.teamNotVerified,
        _ => null,
      };
      if (kind == null) continue;
      team.add(NeedsYouItem(kind,
          id: a.uid ?? kind.name,
          name: a.uid == null ? null : nameOf(a.uid!),
          count: a.count,
          orchardName: teamName));
    }
  }

  final sync = ref.watch(syncHealthProvider);
  final syncItems = [
    // Failing and tried again by itself: nobody has to do anything.
    if (sync.health == SyncHealth.failing && !sync.retrying) NeedsYouItem(NeedsYouKind.syncFailing, id: 'sync', sync: sync),
    if (sync.health == SyncHealth.paused) NeedsYouItem(NeedsYouKind.syncPaused, id: 'sync', sync: sync),
  ];

  final certs = <NeedsYouItem>[];
  for (final Identity key in ref.watch(identitiesProvider).valueOrNull ?? const <Identity>[]) {
    switch (key.certReminder(now: now)) {
      case CertReminder.ranOut:
        certs.add(NeedsYouItem(NeedsYouKind.certRanOut, id: key.id, name: key.label));
      case CertReminder.runsOutSoon:
        certs.add(NeedsYouItem(NeedsYouKind.certSoon, id: key.id, name: key.label));
      case null:
        break;
    }
  }

  return [...hosts, ...team, ...syncItems, ...certs];
});

/// The "Needs you" section at the top of the phone's notification center:
/// a row for each item, what it is and the one action that resolves it.
/// Nothing at all while nothing needs the person.
class NeedsYouSection extends ConsumerWidget {
  const NeedsYouSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(needsYouProvider);
    if (items.isEmpty) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return Column(
      key: const ValueKey('needs-you'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Row(
            children: [
              Container(
                width: 2,
                height: 10,
                decoration: BoxDecoration(color: ZestColors.statusWarning, borderRadius: BorderRadius.circular(1)),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.needsYouTitle.toUpperCase(),
                style: TextStyle(fontSize: 11, letterSpacing: 0.88, color: ZestColors.textMuted, fontWeight: FontWeight.w500),
              ),
              const SizedBox(width: 6),
              Text('${items.length}',
                  key: const ValueKey('needs-you-count'),
                  style: TextStyle(fontSize: 11, color: ZestColors.textMuted, fontFamily: 'JetBrainsMono')),
              const SizedBox(width: 8),
              Expanded(child: Divider(height: 1, color: ZestColors.borderDefault)),
            ],
          ),
        ),
        for (final item in items) _NeedsYouRow(item: item),
      ],
    );
  }
}

class _NeedsYouRow extends ConsumerWidget {
  const _NeedsYouRow({required this.item});

  final NeedsYouItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final (title, body, action, onAction, icon) = _content(context, ref, l10n);
    final color = item.critical ? ZestColors.statusError : ZestColors.statusWarning;
    return Container(
      key: ValueKey('needs-you-${item.kind.name}-${item.id}'),
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        border: Border(top: BorderSide(color: ZestColors.borderDefault)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: color)),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                if (body != null && body.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: RedactedText(
                      Redactable.freeText(body),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, height: 1.45, color: ZestColors.textMuted),
                    ),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: ValueKey('needs-you-action-${item.kind.name}-${item.id}'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
                      minimumSize: const Size(48, 40),
                      foregroundColor: ZestColors.textPrimary,
                    ),
                    onPressed: onAction,
                    child: Text(action, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  (Widget, String?, String, VoidCallback, IconData) _content(BuildContext context, WidgetRef ref, AppLocalizations l10n) {
    final style = TextStyle(fontSize: 13.5, height: 1.35, fontWeight: FontWeight.w500, color: ZestColors.textPrimary);
    Widget plain(String s) => RedactedText(Redactable.freeText(s), style: style);
    String member() => item.name == null ? '' : Redactable.account(item.name!).displayIn(ref);
    final team = item.orchardName == null ? null : orchardDisplayName(item.orchardName, l10n);
    void push(String route) => context.push(route);
    switch (item.kind) {
      case NeedsYouKind.hostCritical:
      case NeedsYouKind.hostWarning:
      case NeedsYouKind.hostCantCheck:
        final v = item.view!;
        final over = v.overLimit.firstOrNull;
        final body = item.kind == NeedsYouKind.hostCantCheck || over == null
            ? monitorPillTooltip(v, l10n)
            : over.severity == MetricSeverity.critical
                ? l10n.zestMonitorTipCritical(monitorMetricLabel(over.metric, l10n),
                    monitorMetricValue(over.metric, over.value!), monitorMetricValue(over.metric, over.crit))
                : l10n.zestMonitorTipWarning(monitorMetricLabel(over.metric, l10n),
                    monitorMetricValue(over.metric, over.value!), monitorMetricValue(over.metric, over.warn));
        return (
          RedactedText(Redactable.host(item.name!), style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
          body,
          l10n.needsYouOpenInMonitor,
          () => push('/monitor/server/${item.id}'),
          item.kind == NeedsYouKind.hostCantCheck ? LucideIcons.wifiOff : LucideIcons.activity,
        );
      case NeedsYouKind.teamDevice:
        return (plain(l10n.deviceRequestTitle(member())), team, l10n.teamReview, () => push('/team/overview'), LucideIcons.smartphone);
      case NeedsYouKind.teamAccess:
        return (plain(l10n.accessRequestTitle(member())), team, l10n.teamReview, () => push('/team/overview'), LucideIcons.keyRound);
      case NeedsYouKind.teamInvites:
        return (plain(l10n.teamAttnInvites(item.count)), team, l10n.teamReview, () => push('/team/overview'), LucideIcons.mailCheck);
      case NeedsYouKind.teamKeysChanged:
        return (plain(l10n.teamAttnKeysChanged(member())), team, l10n.teamReview, () => push('/team/members'), LucideIcons.shieldAlert);
      case NeedsYouKind.teamKeysReplaced:
        return (plain(l10n.teamAttnKeysReplaced(item.count)), team, l10n.teamCompare, () => push('/team/members'), LucideIcons.refreshCw);
      case NeedsYouKind.teamNotVerified:
        return (plain(l10n.teamAttnNotVerified(item.count)), team, l10n.teamCompare, () => push('/team/members'), LucideIcons.fingerprint);
      case NeedsYouKind.syncFailing:
        return (
          plain(l10n.needsYouSyncFailing),
          syncFailingText(item.sync!, l10n, unknown: l10n.statusBarSyncError),
          l10n.needsYouOpenSync,
          () => push(Routes.profile),
          LucideIcons.cloudOff,
        );
      case NeedsYouKind.syncPaused:
        final until = item.sync!.pause?.until;
        return (
          plain(l10n.needsYouSyncPaused),
          until == null ? l10n.accountSyncPausedIndefinitely : l10n.accountSyncPausedUntil(syncPausedUntilText(until, l10n.localeName)),
          l10n.needsYouOpenSync,
          () => push(Routes.profile),
          LucideIcons.pauseCircle,
        );
      case NeedsYouKind.certRanOut:
      case NeedsYouKind.certSoon:
        final name = Redactable.keyName(item.name!).displayIn(ref);
        final key = ref.read(identitiesProvider).valueOrNull?.where((k) => k.id == item.id).firstOrNull;
        return (
          plain(item.kind == NeedsYouKind.certRanOut ? l10n.certReminderRanOutTitle(name) : l10n.certReminderSoonTitle(name)),
          key == null ? null : certExpirySaid(key, l10n),
          l10n.needsYouOpenKey,
          () => push('/identity/edit/${item.id}'),
          LucideIcons.badgeAlert,
        );
    }
  }
}

/// The severity the bell's badge takes from what needs the person: error
/// where anything is critical, else warning; null when nothing does.
bool? needsYouCritical(List<NeedsYouItem> items) => items.isEmpty ? null : items.any((i) => i.critical);
