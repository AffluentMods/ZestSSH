import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/cloud_import/ui/cloud_provider_info.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/menu_dots_button.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/l10n/time_text.dart';

/// Settings > Data: the cloud accounts kept in sync on this device (3.0
/// cloud import), each with its last check, Check now and Stop and forget.
class CloudAccountsTiles extends ConsumerStatefulWidget {
  const CloudAccountsTiles({super.key, this.tiled = false});

  /// Whether its icon stands in the accent's tile, as a phone's settings
  /// pages draw their rows (a computer's Settings draws none).
  final bool tiled;

  @override
  ConsumerState<CloudAccountsTiles> createState() => _CloudAccountsTilesState();
}

class _CloudAccountsTilesState extends ConsumerState<CloudAccountsTiles> {
  final Set<String> _checking = {};

  Future<void> _checkNow(CloudAccount a) async {
    setState(() => _checking.add(a.id));
    try {
      final outcome = await ref.read(cloudAccountsProvider.notifier).checkOne(a.id);
      if (outcome != null && mounted && outcome.changedAnything) {
        await showCloudImportOutcome(context, a.label, outcome);
      }
    } finally {
      if (mounted) setState(() => _checking.remove(a.id));
    }
  }

  Future<void> _forget(CloudAccount a) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.cloudAccForgetTitle(a.label),
      body: l10n.cloudAccForgetBody,
      confirmLabel: l10n.cloudAccForget,
      cancelLabel: l10n.cancel,
    );
    if (ok == true) await ref.read(cloudAccountsProvider.notifier).forget(a.id);
  }

  String _space(AppLocalizations l10n, CloudAccount a) {
    if (a.spaceId == kCloudTreeSpace) return l10n.cloudImpTree;
    final orchards = ref.watch(orchardSummariesProvider).valueOrNull ?? const [];
    final o = orchards.where((o) => o.id == a.spaceId).firstOrNull;
    if (o == null) return a.spaceId;
    final crate = o.crates.where((c) => c.id == a.crateId).firstOrNull?.name;
    return crate == null ? (o.name ?? '') : '${o.name ?? ''}, $crate';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accounts = ref.watch(cloudAccountsProvider);
    final format = MaterialLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const ValueKey('cloud-accounts'),
          leading: widget.tiled
              ? const PhoneIconTile(LucideIcons.cloud)
              : Icon(LucideIcons.cloud, color: AppColors.accentInk),
          title: Text(l10n.cloudAccTitle),
          subtitle: Text(
            accounts.isEmpty ? l10n.cloudAccNone : l10n.cloudAccDesc,
            style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary),
          ),
          trailing: const Icon(LucideIcons.chevronRight),
          onTap: () => openImportHosts(context),
        ),
        for (final a in accounts)
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 8, bottom: 6),
            child: Container(
              key: ValueKey('cloud-account-${a.id}'),
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
              decoration: BoxDecoration(
                color: ZestTokens.surfaceRaised,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: a.problem == null ? ZestTokens.borderSubtle : ZestTokens.statusWarning.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(cloudProviderMark(a.provider),
                          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10, fontWeight: FontWeight.w700, color: ZestTokens.textTertiary)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(Redactable.account(a.label).displayIn(ref),
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      l10n.cloudAccInto(_space(l10n, a)),
                      if (a.checkedAt != null)
                        '${l10n.cloudAccChecked('${format.formatShortDate(a.checkedAt!.toLocal())} ${plainTimeSpaces(format.formatTimeOfDay(TimeOfDay.fromDateTime(a.checkedAt!.toLocal())))}')}'
                            '${a.found == null ? '' : ', ${l10n.cloudAccFound(a.found!)}'}'
                      else
                        l10n.cloudAccNever,
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: ZestTokens.textTertiary),
                  ),
                  if (a.problem != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(LucideIcons.alertTriangle, size: 13, color: ZestTokens.statusWarning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${l10n.cloudAccProblem}: ${cloudErrorMessage(l10n, a.problem!, a.provider)}',
                            style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary),
                          ),
                        ),
                      ],
                    ),
                    if ((a.problemDetail ?? '').isNotEmpty)
                      Align(
                        alignment: Alignment.centerRight,
                        child: CopyDetailsButton(detail: a.problemDetail!, label: l10n.desktopShellCopyDetails),
                      ),
                  ],
                  // Check now as a quiet button; Stop and forget, which
                  // ends the sync, in the menu beside it, asked first (it
                  // stood as bare red words next to Check now).
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ZestButton(
                        key: ValueKey('cloud-account-check-${a.id}'),
                        label: _checking.contains(a.id) ? l10n.cloudAccChecking : l10n.cloudAccCheckNow,
                        icon: LucideIcons.refreshCw,
                        variant: ZestButtonVariant.ghost,
                        size: ZestButtonSize.medium,
                        onPressed: _checking.contains(a.id) ? null : () => _checkNow(a),
                      ),
                      const SizedBox(width: 4),
                      MenuDotsButton(
                        key: ValueKey('cloud-account-menu-${a.id}'),
                        tooltip: l10n.zestCommonMoreActions,
                        icon: LucideIcons.moreHorizontal,
                        onOpen: (at) async {
                          final picked = await showMenu<String>(
                            context: context,
                            position: at,
                            items: [
                              PopupMenuItem(
                                key: ValueKey('cloud-account-forget-${a.id}'),
                                value: 'forget',
                                child: Row(children: [
                                  Icon(LucideIcons.trash2, size: 16, color: ZestTokens.statusCritical),
                                  const SizedBox(width: 10),
                                  Text(l10n.cloudAccForget, style: TextStyle(color: ZestTokens.statusCritical)),
                                ]),
                              ),
                            ],
                          );
                          if (picked == 'forget' && mounted) await _forget(a);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
