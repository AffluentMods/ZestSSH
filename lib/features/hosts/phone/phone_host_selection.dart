import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds, TransferMode;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show showMoveCopyDialog, transferOffer;
import 'package:zestssh/features/selection/item_selection.dart' show deleteSelection;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/pinned_hosts_provider.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart';
import 'package:zestssh/ui/widgets/selection_bar.dart' show PhoneSelectionAppBar;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_bottom_nav.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';

import '../bulk/host_bulk_edit.dart' show BulkField;
import '../bulk/host_bulk_edit_panel.dart';
import '../open_many_hosts.dart';
import '../state/host_multi_select.dart';

// Selecting hosts on a phone (3.4):
// a long press on a host starts it, then taps add and take out. The bar at
// the top says how many and offers every host shown; the tab bar becomes the
// selection's actions (Edit, Open, Tags, Move, More).

/// The hosts the phone's list shows now (after the search, the vault and the
/// group picked), in order: what "Select all shown" selects, and what a
/// selected host the search hides is told apart by.
final phoneShownHostIdsProvider = StateProvider<List<String>>((ref) => const []);

/// The top bar while hosts are selected on a phone: the close, how many are
/// selected, and Select all shown.
class PhoneHostSelectionAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const PhoneHostSelectionAppBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = ref.watch(phoneShownHostIdsProvider);
    return PhoneSelectionAppBar(
      count: ref.watch(hostMultiSelectProvider).count,
      onClose: () => ref.read(hostMultiSelectProvider.notifier).exit(),
      onSelectAll: shown.isEmpty ? null : () => ref.read(hostMultiSelectProvider.notifier).addAll(shown),
    );
  }
}

/// The tab bar while hosts are selected on a phone: Edit (the one in the
/// brand's ink), Open, Tags, Move and More. [onOpened]
/// is told once sessions were opened (the Sessions tab comes up).
class PhoneHostSelectionBar extends ConsumerWidget {
  const PhoneHostSelectionBar({super.key, this.onOpened, this.onHostActions});

  final VoidCallback? onOpened;

  /// A host's own sheet (what a long press offered before it started
  /// selecting): More offers it while one host is selected.
  final void Function(ConnectionWithDetails host)? onHostActions;

  /// The selected hosts, in the order the list shows them, then the rest.
  static List<ConnectionWithDetails> selectedHosts(WidgetRef ref) {
    final selected = ref.read(hostMultiSelectProvider).selected;
    final all = ref.read(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final byId = {for (final c in all) c.connection.id: c};
    final shown = ref.read(phoneShownHostIdsProvider);
    return [
      for (final id in shown)
        if (selected.contains(id)) ?byId[id],
      for (final id in selected)
        if (!shown.contains(id)) ?byId[id],
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final any = ref.watch(hostMultiSelectProvider).hasSelection;
    void run(void Function() action) {
      if (any) action();
    }

    return ZestBottomNav(
      key: const ValueKey('phone-selection-actions'),
      selectedIndex: 0,
      onDestinationSelected: (i) => switch (i) {
        0 => run(() => _edit(context, ref, null)),
        1 => run(() => unawaited(_open(context, ref))),
        2 => run(() => _edit(context, ref, BulkField.tags)),
        3 => run(() => _edit(context, ref, BulkField.group)),
        _ => run(() => unawaited(_more(context, ref))),
      },
      items: [
        ZestNavItem(icon: LucideIcons.pencil, selectedIcon: LucideIcons.pencil, label: l10n.edit),
        ZestNavItem(icon: LucideIcons.play, selectedIcon: LucideIcons.play, label: l10n.hostsSelOpen),
        ZestNavItem(icon: LucideIcons.tag, selectedIcon: LucideIcons.tag, label: l10n.bulkTags),
        ZestNavItem(icon: LucideIcons.folder, selectedIcon: LucideIcons.folder, label: l10n.bulkMove),
        ZestNavItem(icon: LucideIcons.moreHorizontal, selectedIcon: LucideIcons.moreHorizontal, label: l10n.phoneTabMore),
      ],
    );
  }

  /// The editor of the selection, in a sheet, on [focus].
  void _edit(BuildContext context, WidgetRef ref, BulkField? focus) {
    final ids = [for (final c in selectedHosts(ref)) c.connection.id];
    if (ids.isEmpty) return;
    final db = ref.read(databaseProvider);
    // Said on the app's page: this bar goes with the selection, and Undo
    // comes later.
    final page = Navigator.of(context, rootNavigator: true).context;
    unawaited(showHostBulkEditSheet(
      context,
      hostIds: ids,
      focus: focus,
      onUnselect: (skipped) => ref.read(hostMultiSelectProvider.notifier).removeAll(skipped),
      onApplied: (outcome, skipped) {
        if (page.mounted) sayHostBulkApplied(page, db, outcome, skipped: skipped);
        ref.read(hostMultiSelectProvider.notifier).exit();
      },
    ));
  }

  /// Open: a session to each selected host; past a few, asked how first
  /// ("Open 42 sessions?": a few at a time, or all at once; a phone has no
  /// split panes).
  Future<void> _open(BuildContext context, WidgetRef ref) async {
    var hosts = <Connection>[for (final c in selectedHosts(ref)) c.connection];
    if (hosts.isEmpty) return;
    var batches = false;
    if (hosts.length > kOpenManyAskOver) {
      final how = await askOpenMany(context, hosts.length, panes: false);
      if (how == null || !context.mounted) return;
      batches = how == OpenManyAs.batches;
    }
    if (hosts.any((c) => c.protocol == 'telnet')) {
      final ok = await confirmUnencryptedConnection(context);
      if (!context.mounted) return;
      if (!ok) hosts = [for (final c in hosts) if (c.protocol != 'telnet') c];
    }
    if (hosts.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final container = ProviderScope.containerOf(context, listen: false);
    // Said on the app's page: this bar goes with the selection.
    final page = Navigator.of(context, rootNavigator: true).context;
    final run = openPhoneSessions(container, hosts, size: batches ? kOpenBatchSize : hosts.length);
    ref.read(hostMultiSelectProvider.notifier).exit();
    onOpened?.call();
    final kept = await run;
    if (kept.isNotEmpty && page.mounted) {
      // Host names in a toast are painted: they go through the host rule.
      final names = kept.map((n) => Redactable.host(n).display).join(', ');
      showTopSnackBar(page, l10n.hostsSelNotOpenedPlan(names, freeSessionLimit), isWarning: true);
    }
  }

  /// More: Pin (or Unpin, where all are), Delete, and, with one host
  /// selected, that host's own actions (what a long press offered before
  /// it started selecting).
  Future<void> _more(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final hosts = selectedHosts(ref);
    if (hosts.isEmpty) return;
    final pinned = ref.read(pinnedHostsProvider);
    final allPinned = hosts.every((h) => pinned.contains(h.connection.id));
    final rules = ItemRules.of(ref, 'host', watch: false);
    final deletable = [for (final h in hosts) if (rules.mayChange(h.connection.id, delete: true)) h];
    final ids = [for (final h in hosts) h.connection.id];
    // Move to... and Copy to...: Personal, or a team's vault (3.4).
    final offer = transferOffer(ref, TransferKinds.host, ids);
    final pick = await showZestSheet<String>(
      context: context,
      child: ZestSheetFrame(
        child: Builder(
          builder: (sheet) => Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hosts.length == 1 && onHostActions != null)
                  ListTile(
                    key: const ValueKey('phone-selection-host-actions'),
                    leading: const Icon(LucideIcons.server, size: 20),
                    title: Text(l10n.bulkHostActions),
                    onTap: () => Navigator.of(sheet).pop('host'),
                  ),
                ListTile(
                  key: const ValueKey('phone-selection-pin'),
                  leading: Icon(allPinned ? LucideIcons.pinOff : LucideIcons.pin, size: 20),
                  title: Text(allPinned ? l10n.hostsHomeMenuUnpin : l10n.hostsHomeMenuPin),
                  onTap: () => Navigator.of(sheet).pop('pin'),
                ),
                if (offer.move)
                  ListTile(
                    key: const ValueKey('phone-selection-move-to'),
                    leading: const Icon(LucideIcons.folderInput, size: 20),
                    title: Text(l10n.transferMoveTo),
                    onTap: () => Navigator.of(sheet).pop('move_to'),
                  ),
                if (offer.copy)
                  ListTile(
                    key: const ValueKey('phone-selection-copy-to'),
                    leading: const Icon(LucideIcons.copyPlus, size: 20),
                    title: Text(l10n.transferCopyTo),
                    onTap: () => Navigator.of(sheet).pop('copy_to'),
                  ),
                if (deletable.isNotEmpty)
                  ListTile(
                    key: const ValueKey('phone-selection-delete'),
                    leading: Icon(LucideIcons.trash2, size: 20, color: ZestTokens.statusCritical),
                    title: Text(l10n.hostBulkActionDeleteButton(deletable.length),
                        style: TextStyle(color: ZestTokens.statusCritical)),
                    onTap: () => Navigator.of(sheet).pop('delete'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (pick == null || !context.mounted) return;
    switch (pick) {
      case 'host':
        // The host's own sheet: selecting is over.
        ref.read(hostMultiSelectProvider.notifier).exit();
        onHostActions?.call(hosts.single);
      case 'move_to' || 'copy_to':
        final result = await showMoveCopyDialog(context, ref,
            kind: TransferKinds.host, keys: ids, mode: pick == 'move_to' ? TransferMode.move : TransferMode.copy);
        if (result != null && result.done > 0) ref.read(hostMultiSelectProvider.notifier).exit();
      case 'pin':
        final pins = ref.read(pinnedHostsProvider.notifier);
        for (final h in hosts) {
          allPinned ? await pins.unpin(h.connection.id) : await pins.pin(h.connection.id);
        }
        ref.read(hostMultiSelectProvider.notifier).exit();
      case 'delete':
        // As every list's selection deletes, a computer's included: the
        // question says how many stay (those the role may not delete), one
        // the database refuses is named afterwards, and what did not go stays
        // selected.
        await deleteSelection(context, ref, TransferKinds.host, ids);
    }
  }
}

/// Starts a session to each of [hosts] on a phone, [size] at a time: each
/// batch once the one before has connected or failed (or a minute has gone
/// by). Returns the names of those the free plan kept back.
Future<List<String>> openPhoneSessions(ProviderContainer container, List<Connection> hosts, {required int size}) async {
  final kept = <String>[];
  for (var start = 0; start < hosts.length; start += size) {
    final end = start + size > hosts.length ? hosts.length : start + size;
    final ids = <String>[];
    for (final host in hosts.sublist(start, end)) {
      final id = container.read(activeSessionsProvider.notifier).startSession(host);
      if (id == null) {
        kept.add(host.label.isNotEmpty ? host.label : host.host);
      } else {
        ids.add(id);
      }
    }
    if (end < hosts.length && ids.isNotEmpty) await settledSessions(container, ids, kOpenBatchPatience);
  }
  return kept;
}
