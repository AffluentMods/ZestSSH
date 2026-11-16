import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/utils/type_name.dart';

// Applying a plan (3.0): its steps made in order, each as the
// change a person would make on the Team page, by the account signed in on
// this device and with its keys. It stops at the first step that fails and
// says what was done; nothing is undone, and the same file applied again
// goes on from there, since every step is what still differs.

/// What a plan's steps come down to. One implementation makes them
/// ([OrchardSetupActions]); a test's keeps what it was asked.
abstract class SetupActions {
  /// Adds a Crate and returns its id.
  Future<String> addCrate(String name, {required bool ownersOnly});

  Future<void> setCrate(String crateId, CrateParts parts);

  /// Adds a role below every other and returns its id.
  Future<String> addRole(String name, {required Set<String> can, required Map<String, Set<String>> crates});

  Future<void> setRole(String roleId, {Set<String>? can, Map<String, Set<String>>? crates});

  /// The roles [roleIds] (highest first) take that order among themselves.
  Future<void> orderRoles(List<String> roleIds);

  Future<void> setRules(SetupRules parts);

  Future<void> setRecords(SetupRecords parts);

  Future<void> setMember(String uid, {String? role, Map<String, Set<String>>? grants, Named<int?>? endsAt});

  /// Holds the member [uid] to [switches] in the Crate [crateId] (an empty
  /// set is No access), or with [switches] null lifts their limit there.
  Future<void> setLimit(String uid, String crateId, Set<String>? switches);

  Future<void> invite(String email, {required String role, required Map<String, Set<String>> grants, int? endsAt});

  /// Adds a group of hosts in a Crate and returns its id.
  Future<String> addGroup(String crateId, String name);

  /// [protocol] as a host stores it ([setupStoredProtocol]).
  Future<void> addHost(
    String crateId, {
    required String name,
    required String address,
    required int port,
    required String protocol,
    String? keyId,
    List<String> accountIds = const [],
    String? groupId,
    required Set<String> tags,
  });

  /// [accountIds] null: its other accounts stay as they are.
  Future<void> changeHost(
    String hostId, {
    String? address,
    int? port,
    String? protocol,
    Named<String?>? keyId,
    List<String>? accountIds,
    Named<String?>? groupId,
    Set<String>? tags,
  });

  /// Sends the hosts and groups written here to ZestSSH Cloud.
  Future<void> syncItems();
}

/// How applying a plan went.
class SetupOutcome {
  const SetupOutcome({required this.done, this.failed, this.error, this.left = const [], this.syncError});

  /// The steps made, in order.
  final List<SetupStep> done;

  /// The step that failed, with why; null when every step was made.
  final SetupStep? failed;
  final Object? error;

  /// The steps after it, not tried.
  final List<SetupStep> left;

  /// Hosts were written on this device and did not reach ZestSSH Cloud:
  /// they go with the next sync.
  final Object? syncError;

  bool get complete => failed == null;
}

/// A name a step uses that nothing on this device answers to: the Orchard
/// changed since the plan was made.
class SetupNameGone implements Exception, HasTypeName {
  const SetupNameGone(this.name);

  final String name;

  @override
  String toString() => 'Setup file: nothing is called "$name" any more';

  @override
  String get typeName => 'SetupNameGone';
}

/// Makes the steps of [plan], which was made from [now], through [actions].
/// [onStep] is told each step as it starts. Throws [StateError] for a plan
/// with problems: nothing of such a file is applied.
Future<SetupOutcome> applySetup(
  SetupPlan plan,
  OrchardSnapshot now,
  SetupActions actions, {
  void Function(SetupStep step, int index)? onStep,
}) async {
  if (!plan.canApply) throw StateError('A plan with problems is not applied');
  // What each name stands for: as the plan found it, and what the steps add.
  final crateIds = <String, String>{};
  final shared = <String>{};
  for (final c in now.crates) {
    final name = c.name;
    if (name == null) continue;
    final key = setupNameKey(name);
    if (crateIds.containsKey(key)) shared.add(key);
    crateIds[key] = c.id;
  }
  shared.forEach(crateIds.remove);
  final roleIds = <String, String>{};
  final groups = [...now.groups];

  String crate(String name) => crateIds[setupNameKey(name)] ?? (throw SetupNameGone(name));
  Map<String, Set<String>> byCrateId(Map<String, Set<String>> named) =>
      {for (final e in named.entries) crate(e.key): e.value};
  String role(String name, String? id) => id ?? roleIds[setupNameKey(name)] ?? (throw SetupNameGone(name));
  String group(String name, String crateId) {
    final found = calledIn(groups, name, crateId);
    return found.length == 1 ? found.single.id : (throw SetupNameGone(name));
  }

  final done = <SetupStep>[];
  for (var i = 0; i < plan.steps.length; i++) {
    final step = plan.steps[i];
    onStep?.call(step, i);
    try {
      switch (step) {
        case AddCrate():
          crateIds[setupNameKey(step.name)] = await actions.addCrate(step.name, ownersOnly: step.ownersOnly);
        case CrateSettings():
          await actions.setCrate(crate(step.crate), step.parts);
        case AddRole():
          roleIds[setupNameKey(step.name)] =
              await actions.addRole(step.name, can: step.can, crates: byCrateId(step.crates));
        case ChangeRole():
          await actions.setRole(step.roleId,
              can: step.can, crates: step.crates == null ? null : byCrateId(step.crates!));
        case OrderRoles():
          await actions.orderRoles([
            for (var n = 0; n < step.order.length; n++) role(step.order[n], step.ids[n]),
          ]);
        case SetRules():
          await actions.setRules(step.parts);
        case SetRecords():
          await actions.setRecords(step.parts);
        case ChangeMember():
          await actions.setMember(
            step.uid,
            role: step.role == null ? null : role(step.role!, step.roleId),
            grants: step.crates == null ? null : byCrateId(step.crates!),
            endsAt: step.until,
          );
        case LimitMember():
          await actions.setLimit(step.uid, step.crateId ?? crate(step.crate), step.switches);
        case Invite():
          await actions.invite(
            step.email,
            role: role(step.role, step.roleId),
            grants: byCrateId(step.crates),
            endsAt: step.until,
          );
        case AddGroup():
          final crateId = crate(step.crate);
          groups.add(SnapshotNamed(id: await actions.addGroup(crateId, step.name), crateId: crateId, name: step.name));
        case AddHost():
          final crateId = crate(step.crate);
          await actions.addHost(
            crateId,
            name: step.name,
            address: step.address,
            port: step.port,
            protocol: setupStoredProtocol(step.protocol),
            keyId: step.keyId,
            accountIds: step.accountIds,
            groupId: step.group == null ? null : group(step.group!, crateId),
            tags: step.tags,
          );
        case ChangeHost():
          final named = step.group;
          await actions.changeHost(
            step.hostId,
            address: step.address,
            port: step.port,
            protocol: step.protocol == null ? null : setupStoredProtocol(step.protocol!),
            keyId: step.key == null ? null : Named(step.keyId),
            accountIds: step.accountIds,
            groupId: named == null
                ? null
                : Named(named.value == null ? null : group(named.value!, crate(step.crate))),
            tags: step.tags,
          );
      }
    } catch (e) {
      return SetupOutcome(done: done, failed: step, error: e, left: plan.steps.sublist(i + 1));
    }
    done.add(step);
  }
  Object? syncError;
  if (done.any((s) => s is AddGroup || s is AddHost || s is ChangeHost)) {
    try {
      await actions.syncItems();
    } catch (e) {
      syncError = e;
    }
  }
  return SetupOutcome(done: done, syncError: syncError);
}

/// [SetupActions] made for real in the Orchard [orchardId]: record changes
/// through [service], hosts and groups written into the Orchard's database
/// on this device (each placed in its Crate first, so the Crate's own rules
/// decide) and sent on by [sync].
class OrchardSetupActions implements SetupActions {
  OrchardSetupActions(
    this.service,
    this.orchardId, {
    this.sync,
    DateTime Function() clock = DateTime.now,
    String Function()? newId,
  })  : _clock = clock,
        _newId = newId ?? (() => const Uuid().v4());

  final OrchardService service;
  final String orchardId;

  /// Syncs the Orchard's items; null where nothing does (they wait for the
  /// app's next sync).
  final Future<void> Function()? sync;
  final DateTime Function() _clock;
  final String Function() _newId;

  Future<AppDatabase> get _db => service.databases.open(orchardId);

  @override
  Future<String> addCrate(String name, {required bool ownersOnly}) =>
      service.createCrate(orchardId, name, ownersOnly: ownersOnly);

  @override
  Future<void> setCrate(String crateId, CrateParts parts) => service.setCrateParts(orchardId, crateId, parts);

  @override
  Future<String> addRole(String name, {required Set<String> can, required Map<String, Set<String>> crates}) =>
      service.saveRole(orchardId, name: name, can: can, crates: crates);

  @override
  Future<void> setRole(String roleId, {Set<String>? can, Map<String, Set<String>>? crates}) =>
      service.setRoleParts(orchardId, roleId, can: can, crates: crates);

  @override
  Future<void> orderRoles(List<String> roleIds) => service.orderRoles(orchardId, roleIds);

  @override
  Future<void> setRules(SetupRules parts) => service.setRuleParts(orchardId, parts);

  @override
  Future<void> setRecords(SetupRecords parts) => service.setRecordParts(orchardId, parts);

  @override
  Future<void> setMember(String uid, {String? role, Map<String, Set<String>>? grants, Named<int?>? endsAt}) =>
      service.setMemberParts(orchardId, uid, role: role, grants: grants, endsAt: endsAt);

  @override
  Future<void> setLimit(String uid, String crateId, Set<String>? switches) =>
      service.setMemberLimit(orchardId, uid, crateId, switches);

  @override
  Future<void> invite(String email,
          {required String role, required Map<String, Set<String>> grants, int? endsAt}) =>
      service.invite(orchardId, email: email, role: role, grants: grants, endsAt: endsAt);

  @override
  Future<String> addGroup(String crateId, String name) async {
    final db = await _db;
    final id = _newId();
    await db.transaction(() async {
      await CratePlacement(db).place('group', id, crateId);
      await db.connectionGroupsDao.insertGroup(ConnectionGroupsCompanion(
        id: Value(id),
        name: Value(name),
        isExpanded: const Value(true),
        createdAt: Value(_clock()),
      ));
    });
    return id;
  }

  @override
  Future<void> addHost(
    String crateId, {
    required String name,
    required String address,
    required int port,
    required String protocol,
    String? keyId,
    List<String> accountIds = const [],
    String? groupId,
    required Set<String> tags,
  }) async {
    final db = await _db;
    final id = _newId();
    final at = _clock();
    await db.transaction(() async {
      await CratePlacement(db).place('host', id, crateId);
      await db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value(name),
        host: Value(address),
        port: Value(port),
        identityId: Value(keyId),
        groupId: Value(groupId),
        protocol: Value(protocol),
        createdAt: Value(at),
        updatedAt: Value(at),
      ));
      if (tags.isNotEmpty) await db.connectionTagsDao.setTagsForConnection(id, tags);
      if (accountIds.isNotEmpty) await db.hostAccountsDao.setOtherAccounts(id, accountIds);
    });
  }

  @override
  Future<void> changeHost(
    String hostId, {
    String? address,
    int? port,
    String? protocol,
    Named<String?>? keyId,
    List<String>? accountIds,
    Named<String?>? groupId,
    Set<String>? tags,
  }) async {
    final db = await _db;
    await db.transaction(() async {
      await (db.update(db.connections)..where((c) => c.id.equals(hostId))).write(ConnectionsCompanion(
        host: address == null ? const Value.absent() : Value(address),
        port: port == null ? const Value.absent() : Value(port),
        protocol: protocol == null ? const Value.absent() : Value(protocol),
        identityId: keyId == null ? const Value.absent() : Value(keyId.value),
        groupId: groupId == null ? const Value.absent() : Value(groupId.value),
        updatedAt: Value(_clock()),
      ));
      if (tags != null) await db.connectionTagsDao.setTagsForConnection(hostId, tags);
      if (accountIds != null) await db.hostAccountsDao.setOtherAccounts(hostId, accountIds);
    });
  }

  @override
  Future<void> syncItems() async => sync?.call();
}
