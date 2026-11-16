import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/purchase/pricing_modal.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/database/database.dart' show Connection;

/// Launch the "Manage monitored servers" surface: the app's dialog
/// ([ZestDialogShell], 3.4), a phone's sheet, with the select-all / clear-all
/// controls, the Free-tier cap and the per-host checkboxes ([_MonitorManageBody])
/// and Done in the footer. (A phone's was a sheet of its own, with no Done.)
Future<void> showMonitorManageServers(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.large,
    tone: ZestDialogTone.neutral,
    icon: LucideIcons.activity,
    title: l10n.monitorManageTitle,
    subtitle: l10n.monitorManageSubtitle,
    body: _MonitorManageBody(
        maxListHeight: zestUsesSheets(context) ? MediaQuery.sizeOf(context).height * 0.5 : 380),
    primaryAction: (
      label: l10n.done,
      icon: LucideIcons.check,
      onPressed: () => Navigator.of(context).pop(),
    ),
  );
}

/// The reusable manage-servers body: a Select all / Clear all control row, the
/// live "N monitored" count + Free-tier note, and one checkbox row per saved
/// SSH host. Writes flip the connection's synced `monitored` flag through
/// [ConnectionsDao.setMonitored]; the watched providers make the change feel
/// instant.
class _MonitorManageBody extends ConsumerWidget {
  const _MonitorManageBody({required this.maxListHeight});

  /// Upper bound for the scrollable host list so the surface never grows
  /// unbounded inside a dialog or a bottom sheet.
  final double maxListHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final isPro = ref.watch(isProProvider);
    final canAddMore = ref.watch(canAddMonitoredHostProvider);
    final monitoredCount = ref.watch(monitoredCountProvider);
    final dao = ref.read(connectionsDaoProvider);

    return connectionsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, stack) => Padding(
        padding: const EdgeInsets.all(24),
        child: LoadErrorState(
          message: l10n.homeUnableToLoadConnections,
          where: 'Loading the hosts to choose for the server monitor',
          error: e,
          stack: stack,
          onRetry: () => ref.invalidate(connectionsWithDetailsProvider),
        ),
      ),
      data: (all) {
        // Only SSH hosts can be polled agentlessly (excludes localShell /
        // telnet / mosh / serial).
        final ssh =
            all.where((c) => c.connection.protocol == 'ssh').toList();

        if (ssh.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.server,
                    size: 44, color: AppColors.onSurfaceDim),
                const SizedBox(height: 12),
                Text(
                  l10n.monitorManageEmpty,
                  style: TextStyle(
                    fontSize: 15,
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.monitorManageEmptyDesc,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.onSurfaceDim,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          );
        }

        void selectAll() {
          if (isPro) {
            for (final c in ssh) {
              if (!c.connection.monitored) {
                dao.setMonitored(c.connection.id, true);
              }
            }
            return;
          }
          // Free tier: fill up to the cap in the same stable order the
          // poller applies it (sortOrder then label ≈ this list's order).
          var count = monitoredCount;
          for (final c in ssh) {
            if (count >= freeMonitorLimit) break;
            if (!c.connection.monitored) {
              dao.setMonitored(c.connection.id, true);
              count++;
            }
          }
        }

        void clearAll() {
          for (final c in ssh) {
            if (c.connection.monitored) {
              dao.setMonitored(c.connection.id, false);
            }
          }
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Control row: count + Select all / Clear all.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.monitorManageCount(monitoredCount),
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: selectAll,
                    child: Text(l10n.monitorSelectAll),
                  ),
                  TextButton(
                    onPressed: monitoredCount == 0 ? null : clearAll,
                    child: Text(l10n.monitorClearAll),
                  ),
                ],
              ),
            ),
            // Free-tier cap note.
            if (!isPro)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: _CapNote(
                  atLimit: !canAddMore,
                  text: l10n.monitorAgentlessLimitReached(freeMonitorLimit),
                  onUpgrade: () => PricingModal.show(context),
                ),
              ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxListHeight),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: ssh.length,
                itemBuilder: (context, i) {
                  final c = ssh[i];
                  final conn = c.connection;
                  final monitored = conn.monitored;
                  // A host can be toggled if it's already monitored (so it can
                  // be turned off) or there's headroom under the cap.
                  final enabled = monitored || canAddMore;
                  return _ManageRow(
                    host: conn,
                    monitored: monitored,
                    enabled: enabled,
                    onChanged: enabled
                        ? (v) => dao.setMonitored(conn.id, v)
                        : null,
                    onUpgrade:
                        enabled ? null : () => PricingModal.show(context),
                    upgradeLabel: l10n.upgrade,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One host row with a leading checkbox. When the Free-tier cap blocks adding
/// this host, the checkbox is disabled and a small "Upgrade" affordance is
/// shown in its place.
class _ManageRow extends StatelessWidget {
  const _ManageRow({
    required this.host,
    required this.monitored,
    required this.enabled,
    required this.onChanged,
    required this.onUpgrade,
    required this.upgradeLabel,
  });

  /// The host, drawn as a host is everywhere (masked while recording).
  final Connection host;
  final bool monitored;
  final bool enabled;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onUpgrade;
  final String upgradeLabel;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!monitored),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: Checkbox(
                value: monitored,
                onChanged:
                    onChanged == null ? null : (v) => onChanged!(v ?? false),
                activeColor: AppColors.brandOrange,
              ),
            ),
            Expanded(
              child: HostRow(
                host: host,
                under: true,
                padding: EdgeInsets.zero,
                margin: EdgeInsets.zero,
                hovers: false,
                nameStyle: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: enabled ? AppColors.onSurface : AppColors.onSurfaceDim,
                ),
              ),
            ),
            if (onUpgrade != null)
              TextButton.icon(
                onPressed: onUpgrade,
                icon: const Icon(LucideIcons.lock, size: 14),
                label: Text(upgradeLabel),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.accentInk,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Small inline note describing the Free-tier monitor cap. Turns amber and
/// gains an Upgrade action once the cap is reached.
class _CapNote extends StatelessWidget {
  const _CapNote({
    required this.atLimit,
    required this.text,
    required this.onUpgrade,
  });

  final bool atLimit;
  final String text;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    final color = atLimit ? AppColors.warning : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(atLimit ? LucideIcons.lock : LucideIcons.info,
              size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, color: color),
            ),
          ),
          if (atLimit)
            GestureDetector(
              onTap: onUpgrade,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  AppLocalizations.of(context)!.upgrade,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.accentInk,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
