import 'package:zestssh/features/orchards/directory/orchard_directory_api.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';

/// What making roles for directory groups did: roles made (or groups given
/// a role of the same name), roles renamed with their group, and groups
/// left waiting because the team has no room for another role.
typedef DirectoryRolesDone = ({int made, int renamed, int left});

/// A group's name as a role's: trimmed, at most a role name's 50 characters.
String roleNameForGroup(String group) {
  final t = group.trim();
  return t.length <= 50 ? t : t.substring(0, 50).trimRight();
}

/// Directory groups become roles (3.3.0: groups made in the directory
/// update the team's roles automatically). While an
/// owner turned it on ([OrchardDirectory.autoRoles]), each group that gives
/// no role gets one: a role the owners already have of the same name, or a
/// new one named as the group, with no vaults and no powers, below every
/// other role, mapped as made for it, so that its name follows the group's.
/// Only an owner's device does this (only an owner signs a role into the
/// record), and only with a sign-in recent enough for role changes: what
/// [OrchardService] and [OrchardDirectoryApi] throw is left to the caller.
Future<DirectoryRolesDone> makeDirectoryRoles(
    OrchardService service, OrchardDirectoryApi api, String orchardId, OrchardDirectory directory) async {
  if (!directory.enabled || !directory.autoRoles) return (made: 0, renamed: 0, left: 0);
  var roles = await service.roles(orchardId);
  var made = 0, renamed = 0, left = 0;
  for (final g in directory.groups) {
    final name = roleNameForGroup(g.name);
    if (name.isEmpty) continue;
    final role = g.role;
    if (role == null) {
      final same = roles.where((r) => (r.name ?? '').toLowerCase() == name.toLowerCase()).firstOrNull;
      if (same != null) {
        // A role an owner made by hand keeps its own name.
        await api.mapGroup(orchardId, g.id, same.id);
        made++;
        continue;
      }
      if (roles.length >= kMaxOrchardRoles) {
        left++;
        continue;
      }
      final id = await service.saveRole(orchardId, name: name, can: const {}, crates: const {});
      await api.mapGroup(orchardId, g.id, id, auto: true);
      made++;
      roles = await service.roles(orchardId);
    } else if (g.autoRole && role != FixedRoles.admin) {
      final mine = roles.where((r) => r.id == role).firstOrNull;
      if (mine == null || mine.name == null || mine.name == name) continue;
      await service.saveRole(orchardId, id: mine.id, name: name, can: mine.can, crates: mine.crates);
      renamed++;
    }
  }
  return (made: made, renamed: renamed, left: left);
}

/// Whether [directory] has anything for [makeDirectoryRoles] to do, as far
/// as it says without reading the roles: a group with no role, or one whose
/// role was made for it (its name may have moved on).
bool directoryRolesWanted(OrchardDirectory directory) =>
    directory.enabled && directory.autoRoles && directory.groups.any((g) => g.role == null || g.autoRole);
