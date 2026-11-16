import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart' show Identity, PortForwardRule, Snippet;
import 'package:zestssh/features/hosts/state/host_multi_select.dart' show hostMultiSelectProvider;
import 'package:zestssh/features/orchards/certs/crate_authorities.dart' show authorityOfKey;
import 'package:zestssh/features/orchards/guardrails.dart' show ItemRules, isOrchardWriteRefused;
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds, TransferMode, TransferRefusal;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show showMoveCopyDialog, transferOffer, transferWhat;
import 'package:zestssh/features/orchards/orchard_providers.dart' show activeOrchardProvider;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show crateDisplayName;
import 'package:zestssh/features/selection/list_selection.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart' show AuthMethod;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart' show connectionCrudProvider, connectionsWithDetailsProvider;
import 'package:zestssh/providers/core_providers.dart'
    show activeSpaceProvider, allPortForwardRulesProvider, portForwardRulesDaoProvider;
import 'package:zestssh/providers/identity_providers.dart' show identitiesProvider, identityCrudProvider;
import 'package:zestssh/providers/pinned_hosts_provider.dart' show pinnedHostsProvider;
import 'package:zestssh/providers/snippet_providers.dart' show snippetCategoriesProvider, snippetCrudProvider, snippetsProvider;
import 'package:zestssh/providers/terminal_providers.dart' show StartForwardResult, activeForwardIdsProvider, activeSessionsProvider;
import 'package:zestssh/services/port_forward_messages.dart' show forwardDisplayName;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

// Selecting several keys, snippets or port forwards (3.4, for an
// easier way to move, and an easier way to
// share in bulk; multi-select first-class on every list). The selection
// works as the hosts' does (list_selection.dart); what a selection does is
// here, for a computer's bar and a phone's alike: Move to... and Copy to...
// (the one place picker, the batch's linked items asked once), Delete (one
// question for the batch, as a single delete may), a snippet's category, and
// a port forward's Start and Stop. A team's vault keeps its rules: each item
// is checked as a single action checks it, and what may not go is named.

/// The selection of one list of items ([TransferKinds.key], [TransferKinds.snippet],
/// [TransferKinds.forward]), as the hosts have theirs. Another space's items
/// are other items: selecting ends when the space on screen changes.
class ItemSelectionNotifier extends ListSelectionNotifier {
  @override
  ListSelectionState build() {
    ref.listen(activeSpaceProvider, (_, _) => exit());
    return const ListSelectionState();
  }
}

final keySelectionProvider = NotifierProvider<ItemSelectionNotifier, ListSelectionState>(ItemSelectionNotifier.new);
final snippetSelectionProvider = NotifierProvider<ItemSelectionNotifier, ListSelectionState>(ItemSelectionNotifier.new);
final forwardSelectionProvider = NotifierProvider<ItemSelectionNotifier, ListSelectionState>(ItemSelectionNotifier.new);

/// The selection of the list of [kind].
NotifierProvider<ItemSelectionNotifier, ListSelectionState> itemSelectionProvider(String kind) => switch (kind) {
      TransferKinds.key => keySelectionProvider,
      TransferKinds.snippet => snippetSelectionProvider,
      _ => forwardSelectionProvider,
    };

/// What changes the selection of [kind]: the hosts' own, or the list's of
/// [itemSelectionProvider].
ListSelectionNotifier _selectionOf(WidgetRef ref, String kind) => kind == TransferKinds.host
    ? ref.read(hostMultiSelectProvider.notifier)
    : ref.read(itemSelectionProvider(kind).notifier);

/// The items the list of a kind shows now (after its search and filters), in
/// its order: what Ctrl+A and Select all shown select, what a Shift-click's
/// range runs along, and the order the selection is acted on in.
final shownItemIdsProvider = StateProvider.family<List<String>, String>((ref, kind) => const []);

/// Says, after this frame, that the list of [kind] shows [ids] (a list says
/// it as it builds; a provider is not changed while a widget builds).
void publishShownItems(WidgetRef ref, String kind, List<String> ids) {
  if (listEquals(ref.read(shownItemIdsProvider(kind)), ids)) return;
  final shown = ref.read(shownItemIdsProvider(kind).notifier);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (shown.mounted && !listEquals(shown.state, ids)) shown.state = ids;
  });
}

/// Every item of [kind] in the space on screen, by id ([watch]: rebuilds
/// the caller when they change).
Set<String> itemIdsOf(WidgetRef ref, String kind, {bool watch = false}) {
  T read<T>(ProviderListenable<T> p) => watch ? ref.watch(p) : ref.read(p);
  return switch (kind) {
    TransferKinds.key => {for (final i in read(identitiesProvider).valueOrNull ?? const <Identity>[]) i.id},
    TransferKinds.snippet => {for (final s in read(snippetsProvider).valueOrNull ?? const <Snippet>[]) s.id},
    _ => {for (final r in read(allPortForwardRulesProvider).valueOrNull ?? const <PortForwardRule>[]) r.id},
  };
}

/// The selected items of [kind] that are still there, in the order the list
/// shows them (those it does not show now after them).
List<String> selectedItemsInOrder(WidgetRef ref, String kind, {bool watch = false}) {
  final selected = (watch ? ref.watch(itemSelectionProvider(kind)) : ref.read(itemSelectionProvider(kind))).selected;
  final shown = watch ? ref.watch(shownItemIdsProvider(kind)) : ref.read(shownItemIdsProvider(kind));
  final there = itemIdsOf(ref, kind, watch: watch);
  return [
    for (final id in shown)
      if (selected.contains(id) && there.contains(id)) id,
    for (final id in selected)
      if (!shown.contains(id) && there.contains(id)) id,
  ];
}

/// An item's name as it is painted (recording mode masks it).
String itemNameShown(WidgetRef ref, String kind, String id) {
  switch (kind) {
    case TransferKinds.host:
      final c = (ref.read(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[])
          .where((c) => c.connection.id == id)
          .firstOrNull
          ?.connection;
      if (c == null) return '?';
      // As a host's single delete names it (its address where it has no name).
      return c.label.isNotEmpty ? Redactable.host(c.label).display : Redactable.address(c.host).display;
    case TransferKinds.key:
      final i = (ref.read(identitiesProvider).valueOrNull ?? const <Identity>[]).where((i) => i.id == id).firstOrNull;
      return i == null ? '?' : Redactable.keyName(i.label).display;
    case TransferKinds.snippet:
      final s = (ref.read(snippetsProvider).valueOrNull ?? const <Snippet>[]).where((s) => s.id == id).firstOrNull;
      return s == null ? '?' : Redactable.freeText(s.label).display;
    default:
      final r = (ref.read(allPortForwardRulesProvider).valueOrNull ?? const <PortForwardRule>[])
          .where((r) => r.id == id)
          .firstOrNull;
      return r == null ? '?' : forwardDisplayName(r);
  }
}

/// The keys of [ids] that belong to their vault and never leave it (a team
/// certificate, the key a vault signs certificates with), with why: Move
/// to... and Copy to... name them and take the rest.
Map<String, TransferRefusal> keysKeptInVault(WidgetRef ref, List<String> ids) {
  final identities = {for (final i in ref.read(identitiesProvider).valueOrNull ?? const <Identity>[]) i.id: i};
  return {
    for (final id in ids)
      if (identities[id] case final identity?)
        if (identity.authMethod == AuthMethod.teamCertificate.name || authorityOfKey(ref, identity) != null)
          id: TransferRefusal.keyBelongsToVault,
  };
}

/// What Move to... and Copy to... offer for the items [ids] of [kind]: as for
/// one item ([transferOffer]), for those of them that may leave where they
/// are.
({bool move, bool copy}) selectionTransferOffer(WidgetRef ref, String kind, List<String> ids) {
  final kept = kind == TransferKinds.key ? keysKeptInVault(ref, ids) : const <String, TransferRefusal>{};
  return transferOffer(ref, kind, [for (final id in ids) if (!kept.containsKey(id)) id]);
}

/// Whether this account may delete any of [ids] of [kind] where they are
/// (in a team's vault, its role's rule; everything in your own).
bool mayDeleteAnyOf(WidgetRef ref, String kind, List<String> ids, {bool watch = false}) {
  final rules = ItemRules.of(ref, kind, watch: watch);
  return ids.any((id) => rules.mayChange(id, delete: true));
}

/// Move to... or Copy to... ([mode]) for the selected [ids] of [kind]: the
/// one place picker, with the batch's linked items asked once. Selecting ends
/// once any went.
Future<void> transferSelection(BuildContext context, WidgetRef ref, String kind, List<String> ids, TransferMode mode) async {
  if (ids.isEmpty) return;
  final selection = ref.read(itemSelectionProvider(kind).notifier);
  final kept = kind == TransferKinds.key ? keysKeptInVault(ref, ids) : const <String, TransferRefusal>{};
  final result = await showMoveCopyDialog(context, ref, kind: kind, keys: ids, mode: mode, kept: kept);
  if (result != null && result.done > 0) selection.exit();
}

/// Deletes the selected [ids] of [kind] once asked, in one question for the
/// whole batch (red, as every delete asks), each as a single delete may: in a
/// team's vault, only those its role may delete, the rest named in the
/// question and left selected. What could not be deleted stays selected and
/// is named; selecting ends where everything went. The hosts' selection
/// ([TransferKinds.host]: a computer's bar and its Delete key, a phone's
/// More) deletes here too: it asked without saying how many stay, and a host
/// the database refused ended the batch with an error.
Future<void> deleteSelection(BuildContext context, WidgetRef ref, String kind, List<String> ids) async {
  if (ids.isEmpty) return;
  final l10n = AppLocalizations.of(context)!;
  final rules = ItemRules.of(ref, kind, watch: false);
  final deletable = [for (final id in ids) if (rules.mayChange(id, delete: true)) id];
  if (deletable.isEmpty) {
    showTopSnackBar(context, l10n.orchardWriteNotAllowed, isWarning: true);
    return;
  }
  final stay = ids.length - deletable.length;
  final n = deletable.length;
  final bullets = <String>[
    if (kind == TransferKinds.key) ...[
      l10n.zestKeysDeleteFallsBack,
      l10n.zestKeysDeleteFileUntouched,
      // A vault signs nothing without its authority's key: said for
      // each one in the batch, as its single delete asks first.
      ..._authorityVaultsOf(ref, l10n, deletable).map(l10n.certAuthorityKeyDeleteBody),
    ],
    if (stay > 0) l10n.selectDeleteStay(stay),
  ];
  final confirmed = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: kind == TransferKinds.host ? l10n.hostBulkActionDeleteTitle : l10n.selectDeleteTitle(transferWhat(l10n, kind, n)),
    body: switch (kind) {
      TransferKinds.host => l10n.hostBulkActionDeleteConfirm(n),
      TransferKinds.key => l10n.selectDeleteKeysBody(n),
      TransferKinds.snippet => l10n.selectDeleteSnippetsBody(n),
      _ => l10n.selectDeleteForwardsBody(n),
    },
    bullets: bullets,
    confirmLabel: l10n.hostBulkActionDeleteButton(n),
  );
  if (confirmed != true || !context.mounted) return;
  final selection = _selectionOf(ref, kind);
  final names = {for (final id in deletable) id: itemNameShown(ref, kind, id)};
  final Future<void> Function(String id) delete = switch (kind) {
    TransferKinds.host => _hostDelete(ref),
    TransferKinds.key => ref.read(identityCrudProvider).delete,
    TransferKinds.snippet => ref.read(snippetCrudProvider).delete,
    _ => ref.read(portForwardRulesDaoProvider).deleteRule,
  };
  final failed = <String>[];
  var refused = false;
  Object? error;
  for (final id in deletable) {
    try {
      await delete(id);
    } catch (e) {
      failed.add(id);
      if (isOrchardWriteRefused(e)) {
        refused = true;
      } else {
        error ??= e;
      }
    }
  }
  final left = {for (final id in ids) if (!deletable.contains(id) || failed.contains(id)) id};
  left.isEmpty ? selection.exit() : selection.replaceSelection(left);
  if (!context.mounted) return;
  if (failed.isEmpty) {
    showTopSnackBar(context, l10n.selectDeletedToast(transferWhat(l10n, kind, n)), isSuccess: true);
    return;
  }
  final said = l10n.selectDeletedSome(n - failed.length, n, failed.map((id) => names[id]).join(', '));
  showTopSnackBar(
    context,
    refused && error == null ? '$said. ${l10n.orchardWriteNotAllowed}' : said,
    isError: true,
    details: error == null ? null : '$error',
  );
}

/// A host's delete, as its single delete does it: the host, then its pin
/// (pins are kept in the app's settings, not the database, and would be left
/// behind).
Future<void> Function(String id) _hostDelete(WidgetRef ref) {
  final crud = ref.read(connectionCrudProvider);
  final pins = ref.read(pinnedHostsProvider.notifier);
  return (id) async {
    await crud.delete(id);
    await pins.unpin(id);
  };
}

/// The names of the vaults whose certificate authority signs with one of the
/// keys [ids].
List<String> _authorityVaultsOf(WidgetRef ref, AppLocalizations l10n, List<String> ids) {
  final identities = {for (final i in ref.read(identitiesProvider).valueOrNull ?? const <Identity>[]) i.id: i};
  final crates = ref.read(activeOrchardProvider).valueOrNull?.crates ?? const [];
  return {
    for (final id in ids)
      if (identities[id] case final identity?)
        if (authorityOfKey(ref, identity) case final authority?)
          switch (crates.where((c) => c.id == authority.crateId).firstOrNull) {
            final crate? => crateDisplayName(crate, l10n),
            null => l10n.crateUnnamed,
          },
  }.toList();
}

/// "Move to category" for the selected snippets [ids]: the categories there
/// are, No category, or a new one named here. Only those this account may
/// change move (in a team's vault, its role's rule).
Future<void> moveSnippetsToCategory(BuildContext context, WidgetRef ref, List<String> ids) async {
  if (ids.isEmpty) return;
  final l10n = AppLocalizations.of(context)!;
  final rules = ItemRules.of(ref, TransferKinds.snippet, watch: false);
  final movable = [for (final id in ids) if (rules.mayChange(id)) id];
  if (movable.isEmpty) {
    showTopSnackBar(context, l10n.orchardWriteNotAllowed, isWarning: true);
    return;
  }
  final byId = {for (final s in ref.read(snippetsProvider).valueOrNull ?? const <Snippet>[]) s.id: s};
  String? categoryOf(String id) {
    final c = byId[id]?.category;
    return c == null || c.isEmpty ? null : c;
  }

  const none = '\u0000none';
  const fresh = '\u0000new';
  final now = {for (final id in movable) categoryOf(id)};
  final picked = await showZestChoice<String>(
    context,
    key: const ValueKey('select-category'),
    title: l10n.selectCategoryTitle(transferWhat(l10n, TransferKinds.snippet, movable.length)),
    icon: LucideIcons.folderInput,
    selected: now.length == 1 ? (now.single ?? none) : null,
    choices: [
      for (final c in ref.read(snippetCategoriesProvider))
        ZestChoice(value: c, label: c, icon: LucideIcons.folder, key: ValueKey('select-category-$c')),
      ZestChoice(
          value: none, label: l10n.selectCategoryNone, icon: LucideIcons.folderX, key: const ValueKey('select-category-none')),
      ZestChoice(
          value: fresh, label: l10n.selectCategoryNew, icon: LucideIcons.folderPlus, key: const ValueKey('select-category-new')),
    ],
  );
  if (picked == null || !context.mounted) return;
  String? category = picked == none ? null : picked;
  if (picked == fresh) {
    final named = await showZestInputDialog(
      context: context,
      title: l10n.selectCategoryNewTitle,
      icon: LucideIcons.folderPlus,
      hintText: l10n.snippetsCategoryHint,
      confirmLabel: l10n.selectCategoryMoveButton,
    );
    category = named?.trim();
    if (category == null || category.isEmpty || !context.mounted) return;
  }
  final selection = ref.read(itemSelectionProvider(TransferKinds.snippet).notifier);
  final crud = ref.read(snippetCrudProvider);
  final failed = <String>[];
  Object? error;
  for (final id in movable) {
    if (categoryOf(id) == category) continue;
    try {
      await crud.setCategory(id, category);
    } catch (e) {
      failed.add(id);
      if (!isOrchardWriteRefused(e)) error ??= e;
    }
  }
  final left = {for (final id in ids) if (!movable.contains(id) || failed.contains(id)) id};
  left.isEmpty ? selection.exit() : selection.replaceSelection(left);
  if (!context.mounted) return;
  final moved = movable.length - failed.length;
  final said = l10n.selectCategoryMoved(
      transferWhat(l10n, TransferKinds.snippet, moved), category ?? l10n.snippetsUncategorized);
  if (left.isEmpty) {
    showTopSnackBar(context, said, isSuccess: true);
  } else {
    showTopSnackBar(context, '$said ${l10n.orchardWriteNotAllowed}',
        isWarning: true, details: error == null ? null : '$error');
  }
}

/// Starts the selected port forwards [ids] that are stopped, each as its
/// Start does; those whose host has no session are asked about once, for
/// all of them, and then each host is connected to once and its forwards
/// started. [onErrored] follows whether each one's last start failed.
Future<void> startSelectedForwards(BuildContext context, WidgetRef ref, List<String> ids,
    {void Function(String id, bool errored)? onErrored}) async {
  final l10n = AppLocalizations.of(context)!;
  final running = ref.read(activeForwardIdsProvider);
  final rules = [
    for (final r in ref.read(allPortForwardRulesProvider).valueOrNull ?? const <PortForwardRule>[])
      if (ids.contains(r.id) && !running.contains(r.id)) r,
  ];
  if (rules.isEmpty) return;
  final selection = ref.read(forwardSelectionProvider.notifier);
  final sessions = ref.read(activeSessionsProvider.notifier);
  var started = 0;
  var notAllowed = 0;
  final failed = <PortForwardRule>[];
  final needSession = <PortForwardRule>[];
  Object? error;
  for (final rule in rules) {
    switch (await sessions.startSavedForward(rule)) {
      case StartForwardResult.started:
        started++;
        onErrored?.call(rule.id, false);
      case StartForwardResult.noSession:
        needSession.add(rule);
      case StartForwardResult.error:
        failed.add(rule);
        onErrored?.call(rule.id, true);
        error ??= sessions.lastForwardError(rule.id);
      case StartForwardResult.notAllowed:
        notAllowed++;
    }
  }
  var connecting = 0;
  if (needSession.isNotEmpty && context.mounted) {
    final hosts = {for (final r in needSession) r.connectionId};
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      title: l10n.selectForwardsConnectTitle(hosts.length),
      body: l10n.selectForwardsConnectBody(needSession.length),
      confirmLabel: l10n.portForwardListConnectAndStart,
    );
    if (confirmed == true) {
      connecting = hosts.length;
      // One session to each host; its forwards start once it is up (the
      // notifier says how each went, as a single Connect & start does).
      for (final host in hosts) {
        unawaited(() async {
          for (final rule in needSession.where((r) => r.connectionId == host)) {
            await sessions.connectThenStartForward(rule);
          }
        }());
      }
    }
  }
  selection.exit();
  if (!context.mounted) return;
  if (failed.isNotEmpty) {
    showTopSnackBar(
      context,
      l10n.selectForwardsStartedSome(started, rules.length, failed.map(forwardDisplayName).join(', ')),
      isError: true,
      details: error == null ? null : '$error',
    );
  } else if (notAllowed > 0) {
    showTopSnackBar(context, l10n.orchardForwardNotAllowed, isWarning: true);
  } else if (connecting > 0) {
    showTopSnackBar(context, l10n.selectForwardsConnecting(connecting), isInfo: true);
  } else if (started > 0) {
    showTopSnackBar(context, l10n.selectForwardsStarted(transferWhat(l10n, TransferKinds.forward, started)),
        isSuccess: true);
  }
}

/// Stops the selected port forwards [ids] that run.
Future<void> stopSelectedForwards(BuildContext context, WidgetRef ref, List<String> ids,
    {void Function(String id, bool errored)? onErrored}) async {
  final l10n = AppLocalizations.of(context)!;
  final running = ref.read(activeForwardIdsProvider);
  final stopping = [for (final id in ids) if (running.contains(id)) id];
  if (stopping.isEmpty) return;
  final selection = ref.read(forwardSelectionProvider.notifier);
  final sessions = ref.read(activeSessionsProvider.notifier);
  for (final id in stopping) {
    await sessions.stopSavedForward(id);
    onErrored?.call(id, false);
  }
  selection.exit();
  if (!context.mounted) return;
  showTopSnackBar(context, l10n.selectForwardsStopped(transferWhat(l10n, TransferKinds.forward, stopping.length)),
      isSuccess: true);
}

/// One thing a selection can do, for a computer's bar and a phone's tabs.
@immutable
class ItemSelectionAction {
  const ItemSelectionAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.run,
    this.shortLabel,
    this.enabled = true,
    this.destructive = false,
  });

  /// Its key's name: the bar's item is `bulk-` and this.
  final String id;
  final IconData icon;

  /// As a computer's bar says it.
  final String label;

  /// As a phone's tab says it (shorter), where it differs.
  final String? shortLabel;
  final bool enabled;

  /// Delete: red, at the bar's end.
  final bool destructive;
  final Future<void> Function(BuildContext context) run;
}

/// What a selection of [kind] offers for its items [ids] now: Move to... and
/// Copy to... where some place takes them, a snippet's category, a port
/// forward's Start and Stop, and Delete last. [onForwardErrored] follows
/// whether a port forward's last start failed (the computer's list says
/// Error).
List<ItemSelectionAction> itemSelectionActions(
  WidgetRef ref,
  AppLocalizations l10n,
  String kind,
  List<String> ids, {
  void Function(String id, bool errored)? onForwardErrored,
}) {
  final offer = selectionTransferOffer(ref, kind, ids);
  final running = kind == TransferKinds.forward ? ref.watch(activeForwardIdsProvider) : const <String>{};
  return [
    if (kind == TransferKinds.forward) ...[
      ItemSelectionAction(
        id: 'start',
        icon: LucideIcons.play,
        label: l10n.zestPfStart,
        enabled: ids.any((id) => !running.contains(id)),
        run: (context) => startSelectedForwards(context, ref, ids, onErrored: onForwardErrored),
      ),
      ItemSelectionAction(
        id: 'stop',
        icon: LucideIcons.square,
        label: l10n.zestPfStop,
        enabled: ids.any(running.contains),
        run: (context) => stopSelectedForwards(context, ref, ids, onErrored: onForwardErrored),
      ),
    ],
    if (kind == TransferKinds.snippet)
      ItemSelectionAction(
        id: 'category',
        icon: LucideIcons.folder,
        label: l10n.selectCategory,
        shortLabel: l10n.selectCategoryShort,
        enabled: ids.any(ItemRules.of(ref, kind).mayChange),
        run: (context) => moveSnippetsToCategory(context, ref, ids),
      ),
    if (offer.move)
      ItemSelectionAction(
        id: 'move-to',
        icon: LucideIcons.folderInput,
        label: l10n.transferMoveTo,
        run: (context) => transferSelection(context, ref, kind, ids, TransferMode.move),
      ),
    if (offer.copy)
      ItemSelectionAction(
        id: 'copy-to',
        icon: LucideIcons.copyPlus,
        label: l10n.transferCopyTo,
        run: (context) => transferSelection(context, ref, kind, ids, TransferMode.copy),
      ),
    ItemSelectionAction(
      id: 'delete',
      icon: LucideIcons.trash2,
      label: l10n.delete,
      destructive: true,
      enabled: mayDeleteAnyOf(ref, kind, ids, watch: true),
      run: (context) => deleteSelection(context, ref, kind, ids),
    ),
  ];
}
