import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

/// When tabs say where a host comes from (Settings,
/// Appearance).
enum TabSourceMode {
  /// While the open tabs come from more than one place; a team where this
  /// account opens one vault leaves the vault out.
  auto,
  always,
  off;

  static TabSourceMode parse(String? s) => values.where((m) => m.name == s).firstOrNull ?? auto;

  String nameIn(AppLocalizations l10n) => switch (this) {
        auto => l10n.tabSourceAuto,
        always => l10n.tabSourceAlways,
        off => l10n.tabSourceOff,
      };
}

final tabSourceModeProvider =
    StateProvider<TabSourceMode>((ref) => TabSourceMode.parse(ref.read(settingsServiceProvider).tabSourceMode));
final tabSourceVaultProvider = StateProvider<bool>((ref) => ref.read(settingsServiceProvider).tabSourceVault);
final tabSourceGroupProvider = StateProvider<bool>((ref) => ref.read(settingsServiceProvider).tabSourceGroup);

Future<void> setTabSourceMode(WidgetRef ref, TabSourceMode mode) async {
  await ref.read(settingsServiceProvider).setTabSourceMode(mode.name);
  ref.read(tabSourceModeProvider.notifier).state = mode;
}

Future<void> setTabSourceVault(WidgetRef ref, bool on) async {
  await ref.read(settingsServiceProvider).setTabSourceVault(on);
  ref.read(tabSourceVaultProvider.notifier).state = on;
}

Future<void> setTabSourceGroup(WidgetRef ref, bool on) async {
  await ref.read(settingsServiceProvider).setTabSourceGroup(on);
  ref.read(tabSourceGroupProvider.notifier).state = on;
}

/// Where the host a session opens comes from: a team and the name of its
/// vault there ([orchardId] and [vaultName]), or the personal space (both
/// null), with the host's group there, in either ([groupName], null for
/// none): a team has three layers, team, vault and group.
typedef TabSource = ({String? orchardId, String? vaultName, String? groupName});

/// [connectionId]'s [TabSource], as its sessions work in it; null while
/// none has opened (the tabs say nothing of it then).
final tabSourceProvider = FutureProvider.autoDispose.family<TabSource?, String>((ref, connectionId) async {
  final sessions = ref.read(activeSessionsProvider.notifier);
  final space = sessions.spaceOfConnection(connectionId);
  if (space == null) return null;
  final db = sessions.sessionDatabaseOf(connectionId);
  // The host's group, in whichever space, where it has one.
  String? group;
  final groupId = db == null ? null : (await db.connectionsDao.getById(connectionId))?.groupId;
  if (db != null && groupId != null) {
    final row = await db.customSelect('SELECT name FROM connection_groups WHERE id = ?',
        variables: [Variable<String>(groupId)]).getSingleOrNull();
    group = row?.read<String?>('name');
  }
  if (space is! OrchardSpace) return (orchardId: null, vaultName: null, groupName: group);
  String? vault;
  if (db != null) {
    final crateId = await CratePlacement(db).crateOf('host', connectionId);
    if (crateId != null) {
      final row = await db.customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?',
          variables: [Variable<String>(crateId)]).getSingleOrNull();
      vault = row?.read<String?>('name');
    }
  }
  return (orchardId: space.orchardId, vaultName: vault, groupName: group);
});
