import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show PortForwardRule;
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/hosts/pending_files.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart' show HostTagChip;
import 'package:zestssh/features/hosts/widgets/host_panel_sections.dart';
import 'package:zestssh/features/orchards/widgets/crate_offline_limit_view.dart' show HostCrateClosedNote;
import 'package:zestssh/features/orchards/widgets/crate_session_logs_view.dart' show HostSessionsLoggedNote;
import 'package:zestssh/features/orchards/widgets/crate_watched_view.dart' show HostSessionsWatchedNote;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/connection_tags_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/host_address.dart';

/// Opens [host]'s page over the phone's Hosts (3.1): what a computer's host
/// panel shows, on a page of its own. [actions] are the row's, so Connect
/// and Edit do here what they do from the list.
Future<void> openPhoneHostPage(BuildContext context, ConnectionWithDetails host, PhoneHostActions actions) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PhoneHostPage(host: host, actions: actions),
  ));
}

/// A host's page on a phone (3.1, from the ⓘ at the end of its row): Connect
/// and Files at the top, then what the computer's host panel shows, each
/// section only where it has something to say: its health from Server
/// Monitor (or the way to have it watched), its recent sessions, its port
/// forwards, how it connects, what its team's vault says of it, its tags and
/// its note. Edit in the bar.
class PhoneHostPage extends ConsumerWidget {
  const PhoneHostPage({super.key, required this.host, required this.actions});

  /// The host as the row had it; the page follows the saved host as it
  /// changes (an edit made from here shows on return).
  final ConnectionWithDetails host;
  final PhoneHostActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final item = ref
            .watch(connectionsWithDetailsProvider)
            .valueOrNull
            ?.where((h) => h.connection.id == host.connection.id)
            .firstOrNull ??
        host;
    final conn = item.connection;
    final live = ref
        .watch(activeSessionsProvider)
        .entries
        .where((e) =>
            e.value.connectionId == conn.id &&
            (e.value.status == SessionStatus.connected || e.value.status == SessionStatus.connecting))
        .firstOrNull;
    final view = ref.watch(monitoredHostViewsProvider)[conn.id];
    final forwards =
        ref.watch(portForwardRulesForConnectionProvider(conn.id)).valueOrNull ?? const <PortForwardRule>[];
    final tags = ref.watch(tagsForConnectionProvider(conn.id)).valueOrNull ?? const <String>[];
    final watchable = conn.protocol.toLowerCase() == 'ssh';
    final hostName = conn.label.isNotEmpty ? conn.label : conn.host;
    final user = item.identity?.username;
    final hostPort = Redactable.address(hostWithPort(conn.host, conn.port)).displayIn(ref);
    final address = user == null ? hostPort : '${Redactable.username(user).displayIn(ref)}@$hostPort';
    final status = live == null
        ? (conn.lastConnected == null
            ? l10n.hostPanelNotConnected
            : '${l10n.hostPanelNotConnected} · ${l10n.hpanelLastSession(timeAgoInSentence(l10n, conn.lastConnected!))}')
        : live.value.status == SessionStatus.connected
            ? l10n.sessionInfoStatusConnected
            : l10n.sessionInfoStatusConnecting;

    // Connecting leaves this page: the session opens over the Hosts, as a
    // tap on the row opens it.
    // (The router is found before the page goes: a session opened after it
    // is pushed over the Hosts.)
    void openSession(String sessionId) {
      final router = GoRouter.of(context);
      Navigator.of(context).pop();
      router.push('/terminal/$sessionId');
    }

    void leaveThen(VoidCallback run) {
      Navigator.of(context).pop();
      run();
    }

    // Its files: its live session's, or the session connecting opens (as
    // the row's sheet has them).
    void files() {
      final open = live?.value.status == SessionStatus.connected ? live!.key : null;
      ref.read(sftpPendingConnectionProvider.notifier).state = conn.id;
      open != null ? openSession(open) : leaveThen(actions.connect);
    }

    Widget head(String label, {String? action, VoidCallback? onAction}) => Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 6),
          child: ZestSectionHeader(label: label, actionLabel: action, onAction: onAction),
        );

    return Scaffold(
      backgroundColor: ZestTokens.surfacePanel,
      appBar: AppBar(
        leading: const BackButton(),
        title: RedactedText(Redactable.host(hostName), maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton.icon(
            key: const ValueKey('phone-host-page-edit'),
            onPressed: actions.edit,
            icon: const Icon(LucideIcons.pencil, size: 16),
            label: Text(l10n.hostPanelEdit),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        key: const ValueKey('phone-host-page'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Row(
            children: [
              PhoneHostTile(host: item, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: ZestTokens.textSecondary)),
                    const SizedBox(height: 3),
                    Text(status,
                        key: const ValueKey('phone-host-page-status'),
                        style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  key: const ValueKey('phone-host-page-connect'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  onPressed: live == null
                      ? () => leaveThen(actions.connect)
                      : () => openSession(live.key),
                  icon: const Icon(LucideIcons.terminal, size: 17),
                  label: Text(live == null ? l10n.hostPanelConnect : l10n.hostPanelSwitchToSession),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('phone-host-page-files'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  onPressed: files,
                  icon: const Icon(LucideIcons.folderOpen, size: 17),
                  label: Text(l10n.phoneHostsFiles),
                ),
              ),
            ],
          ),
          // What its team's vault says of it before connecting.
          HostSessionsLoggedNote(connectionId: conn.id),
          HostSessionsWatchedNote(connectionId: conn.id),
          HostCrateClosedNote(connectionId: conn.id),
          if (watchable) ...[
            head(
              l10n.hostPanelHealth,
              action: view == null ? null : l10n.desktopServerMonitor,
              onAction: view == null ? null : () => context.push('/monitor/server/${conn.id}'),
            ),
            if (view == null)
              HostPanelWatch(connectionId: conn.id)
            else
              HostPanelHealth(connectionId: conn.id, hostName: hostName, view: view),
          ],
          if (HostPanelRecentSessions.hasAny(ref, conn.id)) ...[
            head(l10n.hpanelRecentSessions),
            HostPanelRecentSessions(connectionId: conn.id),
          ],
          if (forwards.isNotEmpty) ...[
            head(l10n.hpanelPortForwards,
                action: '+ ${l10n.hpanelAdd}', onAction: () => addPortForwardFor(context, ref, conn.id)),
            HostPanelPortForwards(rules: forwards),
          ],
          head(l10n.hostPanelConnection),
          _Fact(label: l10n.hpanelAddress, value: address, mono: true),
          if (item.identity != null)
            _Fact(
              label: l10n.hostPanelKey,
              value: item.identity!.keyType == null
                  ? Redactable.keyName(item.identity!.label).displayIn(ref)
                  : '${Redactable.keyName(item.identity!.label).displayIn(ref)} (${item.identity!.keyType})',
            ),
          if (tags.isNotEmpty) ...[
            head(l10n.hpanelTags),
            Wrap(
              key: const ValueKey('phone-host-page-tags'),
              spacing: 5,
              runSpacing: 5,
              children: [for (final t in tags) HostTagChip(tag: t)],
            ),
          ],
          if ((conn.note ?? '').trim().isNotEmpty) ...[
            head(l10n.hostPanelNote),
            RedactedText(
              Redactable.freeText(conn.note!.trim()),
              key: const ValueKey('phone-host-page-note'),
              style: TextStyle(fontSize: 13.5, height: 1.45, color: ZestTokens.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

/// One line of how the host connects: what, then its value.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: mono ? 12.5 : 13,
                fontFamily: mono ? 'JetBrainsMono' : null,
                color: ZestTokens.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
