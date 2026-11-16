import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show ConnectionGroup, ConnectionGroupsCompanion;
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/team_write.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

import 'state/host_multi_select.dart';

/// The hosts a drag of [host] carries, in [order] (the order its list shows
/// them): the selection, where [host] is one of several selected, else
/// [host] alone.
List<ConnectionWithDetails> hostsCarriedWith(WidgetRef ref, ConnectionWithDetails host, List<String> order) {
  final ids = ref.read(hostMultiSelectProvider.notifier).dragSetFor(host.connection.id);
  if (ids.length < 2) return [host];
  final all = ref.read(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
  final byId = {for (final c in all) c.connection.id: c};
  return [
    for (final id in order)
      if (ids.contains(id)) ?byId[id],
    for (final id in ids)
      if (!order.contains(id)) ?byId[id],
  ];
}

/// Moves [hosts] into group [groupId] (null: out of their groups): those
/// this space lets change and that are not in it already. A move of several
/// says how many moved, with an Undo that puts each back where it was, and
/// ends the selection (as the bulk bar's Move to group does); one host moves
/// without a word, as it always did.
Future<void> moveHostsToGroup(BuildContext context, WidgetRef ref, List<ConnectionWithDetails> hosts, String? groupId) async {
  final moving = [
    for (final c in hosts)
      if (c.connection.groupId != groupId && mayChangeItem(ref, 'host', c.connection.id, watch: false)) c,
  ];
  if (moving.isEmpty) return;
  final before = {for (final c in moving) c.connection.id: c.connection.groupId};
  final crud = ref.read(connectionCrudProvider);
  for (final c in moving) {
    await crud.update(id: c.connection.id, groupId: groupId, clearGroupId: groupId == null);
  }
  if (hosts.length < 2 || !context.mounted) return;
  ref.read(hostMultiSelectProvider.notifier).exit();
  final l10n = AppLocalizations.of(context)!;
  final groupName = groupId == null
      ? null
      : (ref.read(connectionGroupsProvider).valueOrNull ?? const <ConnectionGroup>[])
          .where((g) => g.id == groupId)
          .firstOrNull
          ?.name;
  showTopSnackBar(
    context,
    groupName == null
        ? l10n.hostsSelUngroupedToast(moving.length)
        : l10n.hostsSelMovedToast(moving.length, Redactable.group(groupName).display),
    isSuccess: true,
    actionLabel: l10n.hostsSelUndo,
    onAction: () async {
      for (final e in before.entries) {
        await crud.update(id: e.key, groupId: e.value, clearGroupId: e.value == null);
      }
    },
  );
}

/// New group from a selection: asks for a name, makes the group and moves
/// the hosts of [ids] into it. Gives the new group's id back, or null when
/// nothing was made.
///
/// In a team's vault the role decides: with no right to add, or to change
/// any of the hosts, it is said before a name is asked; a host the role may
/// not change stays where it is. The group was made first and the moves
/// were refused by the team's database after it, with nothing said: an
/// empty group went to everyone in the team.
/// The group and the moves are one transaction: a move the database still
/// refuses leaves no group.
Future<String?> createGroupAndMoveHosts(BuildContext context, WidgetRef ref, Set<String> ids) async {
  final l10n = AppLocalizations.of(context)!;
  final movable = [
    for (final id in ids)
      if (mayChangeItem(ref, 'host', id, watch: false)) id,
  ];
  if (!mayAddScreenSpace(ref, watch: false) || movable.isEmpty) {
    showTopSnackBar(context, l10n.orchardWriteNotAllowed, isWarning: true);
    return null;
  }
  final rawName = await showZestInputDialog(
    context: context,
    title: l10n.hostsHomeNewGroupTitle,
    icon: LucideIcons.folderPlus,
    fieldLabel: l10n.hostsHomeGroupNameLabel,
    hintText: l10n.hostsHomeGroupNameLabel,
    confirmLabel: l10n.hostsHomeCreateAndMove,
    validator: (v) => v.trim().isEmpty ? l10n.hostsHomeEnterAName : null,
  );
  final name = rawName?.trim();
  if (name == null || name.isEmpty || !context.mounted) return null;
  if (movable.length < ids.length) {
    showTopSnackBar(context, l10n.orchardWriteNotAllowed, isWarning: true);
  }

  final dao = ref.read(connectionGroupsDaoProvider);
  final crud = ref.read(connectionCrudProvider);
  final groupId = 'group_${DateTime.now().millisecondsSinceEpoch}';
  // One transaction: a move the team's database still refuses takes the new
  // group back with it.
  final done = await runTeamWrite(
      context,
      () => dao.attachedDatabase.transaction(() async {
            await dao.insertGroup(ConnectionGroupsCompanion.insert(
              id: groupId,
              name: name,
              createdAt: DateTime.now(),
            ));
            for (final id in movable) {
              await crud.update(id: id, groupId: groupId);
            }
          }),
      where: 'New group from selection');
  return done ? groupId : null;
}
