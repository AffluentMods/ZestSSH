import 'package:zestssh/features/orchards/record/orchard_record.dart';

// Vault access per member: a
// member's access to each vault is what their role gives, or set for them
// apart from it, a level or No access. Picking a level writes whichever the
// record needs: extra access for what their role does not give (member.set
// grants, as before), a limit for what it gives that they should not have
// (member.limit). The record decides again when the change is made, here and
// on the server; this shapes what is offered, and builds the entries.

/// A member's access to one vault as it can be picked: their role's, No
/// access, or a level. [custom] is only shown, for access set by hand that
/// no level matches.
enum VaultPick {
  fromRole,
  none,
  connect,
  use,
  edit,
  manage,
  custom;

  /// The level picked, for the four levels.
  CrateLevel? get level => switch (this) {
        VaultPick.connect => CrateLevel.connect,
        VaultPick.use => CrateLevel.use,
        VaultPick.edit => CrateLevel.edit,
        VaultPick.manage => CrateLevel.manage,
        _ => null,
      };

  static VaultPick ofLevel(CrateLevel level) => switch (level) {
        CrateLevel.connect => VaultPick.connect,
        CrateLevel.use => VaultPick.use,
        CrateLevel.edit => VaultPick.edit,
        CrateLevel.manage => VaultPick.manage,
      };
}

/// One vault of a member's Vault access, as [vaultAccessOf] works it out.
class VaultAccessRow {
  const VaultAccessRow({
    required this.crateId,
    required this.fromRole,
    required this.current,
    required this.forThem,
    required this.picks,
    required this.waitsForSwitch,
  });

  final String crateId;

  /// What their role gives there, within what the vault allows.
  final Set<String> fromRole;

  /// What is set for them there now: [VaultPick.fromRole] when nothing is.
  final VaultPick current;

  /// The switches set for them there apart from their role: their limit
  /// where one is set (empty for No access), else their extra access; null
  /// when nothing is.
  final Set<String>? forThem;

  /// What may be picked there, in order, each with whether this account may
  /// pick it (false: shown greyed, it would give more than this account
  /// has). Empty when this account may change nothing there.
  final List<({VaultPick pick, bool open})> picks;

  /// Picks that lower access below the role, or lift a limit, are left out
  /// until new kinds of team record entry are on ([vaultAccessOf]'s
  /// limitsOn): the panel says why.
  final bool waitsForSwitch;

  /// Set for them, apart from their role: shown in the brand's ink.
  bool get apart => forThem != null;
}

/// The entries that give [uid] [picks] (vault id to pick) as [record]
/// stands: one member.set with their extra access, where it changes, then a
/// member.limit for each vault whose limit changes. In that order the
/// access after each entry never holds more than before the change and
/// after it together, so each entry hands out no more than the whole
/// change does. Nothing for picks that change nothing.
List<({String type, Map<String, Object?> body})> vaultPickChanges(
    OrchardRecord record, String uid, Map<String, VaultPick> picks) {
  final m = record.members[uid];
  if (m == null) return const [];
  final grants = {for (final g in m.grants.entries) g.key: {...g.value}};
  var grantsChanged = false;
  final limits = <String, Set<String>?>{};
  for (final p in picks.entries) {
    final crate = record.crates[p.key];
    if (crate == null || crate.ownersOnly || p.value == VaultPick.custom) continue;
    final target = _target(record, m, crate, p.value);
    if (!_same(grants[p.key], target.grant)) {
      grantsChanged = true;
      if (target.grant == null) {
        grants.remove(p.key);
      } else {
        grants[p.key] = target.grant!;
      }
    }
    if (!_same(m.limits[p.key], target.limit)) limits[p.key] = target.limit;
  }
  return [
    if (grantsChanged)
      (
        type: RecordTypes.memberSet,
        body: {
          'uid': uid,
          'grants': {for (final g in grants.entries) g.key: switchList(g.value)},
        },
      ),
    for (final l in limits.entries) (type: RecordTypes.memberLimit, body: memberLimitBody(uid, l.key, l.value)),
  ];
}

/// The body of the member.limit that holds [uid] to [switches] in the Crate
/// [crateId] (an empty set is No access), or with [switches] null lifts
/// their limit there. A setup file writes its limits the same way.
Map<String, Object?> memberLimitBody(String uid, String crateId, Set<String>? switches) => {
      'uid': uid,
      'crate': crateId,
      if (switches != null) 'switches': switchList(switches),
    };

/// [uid]'s Vault access as [me] sees it in [record]: every vault that is
/// not owners-only, with what their role gives, what is set for them, and
/// the picks [me] may make. Owners and admins have nothing to pick (the
/// Admin role is the lever for admins). With [limitsOn] false, the picks
/// that need a limit are left out (new kinds of team record entry are not
/// on yet).
List<VaultAccessRow> vaultAccessOf(OrchardRecord record, String me, String uid, {required bool limitsOn}) {
  final m = record.members[uid];
  if (m == null) return const [];
  final fixed = m.role == FixedRoles.owner || m.role == FixedRoles.admin;
  // Someone below this account, as for every change about a member.
  final mayChange = !fixed &&
      uid != me &&
      m.status != MemberStatus.removed &&
      record.rankOf(me) > record.rankOfRole(m.role);
  return [
    for (final crate in record.crates.values)
      if (!crate.ownersOnly) _row(record, me, m, crate, mayChange: mayChange, limitsOn: limitsOn),
  ];
}

VaultAccessRow _row(OrchardRecord record, String me, RecordMember m, RecordCrate crate,
    {required bool mayChange, required bool limitsOn}) {
  final fixed = m.role == FixedRoles.owner || m.role == FixedRoles.admin;
  final fromRole = _capped(record.roleSwitches(m.role, crate.id), crate);
  final limit = fixed ? null : m.limits[crate.id];
  final grant = fixed ? null : m.grants[crate.id];
  final forThem = limit != null ? {...limit} : grant != null ? {...grant} : null;
  final current = forThem == null
      ? VaultPick.fromRole
      : forThem.isEmpty
          ? VaultPick.none
          : switch (vaultLevelIn(forThem, crate)) {
              null => VaultPick.custom,
              final l => VaultPick.ofLevel(l),
            };
  final picks = <({VaultPick pick, bool open})>[];
  var waits = false;
  if (mayChange && record.switchesOf(me, crate.id).contains(CrateSwitches.manage)) {
    final roleLevel = fromRole.isEmpty ? null : vaultLevelIn(fromRole, crate);
    for (final pick in [VaultPick.fromRole, VaultPick.none, VaultPick.connect, VaultPick.use, VaultPick.edit, VaultPick.manage]) {
      // Their role's own level is From role.
      if (pick != current && pick.level != null && pick.level == roleLevel) continue;
      final changes = vaultPickChanges(record, m.uid, {crate.id: pick});
      if (!limitsOn && changes.any((c) => c.type == RecordTypes.memberLimit)) {
        waits = true;
        if (pick != current) continue;
      }
      picks.add((pick: pick, open: pick == current || _handsOutOnlyOwn(record, me, m.uid, changes)));
    }
    if (current == VaultPick.custom) picks.add((pick: VaultPick.custom, open: false));
  }
  return VaultAccessRow(
    crateId: crate.id,
    fromRole: fromRole,
    current: current,
    forThem: forThem,
    picks: picks,
    waitsForSwitch: waits,
  );
}

/// What a pick sets for a member in [crate]: the extra access and the limit
/// that make their access the level picked, whatever their role gives. A
/// level above what their role gives is extra access, one below it a limit;
/// one their role neither holds nor is held in (a role made by hand) takes
/// both. Agent forwarding is in no level: a limit keeps it where their role
/// gives it.
({Set<String>? grant, Set<String>? limit}) _target(
    OrchardRecord record, RecordMember m, RecordCrate crate, VaultPick pick) {
  final level = pick.level;
  if (pick == VaultPick.none) return (grant: null, limit: <String>{});
  if (level == null) return (grant: null, limit: null);
  final want = levelSwitches(level);
  final role = record.roleSwitches(m.role, crate.id);
  final wantHere = _capped(want, crate)..remove(CrateSwitches.agent);
  final roleHere = _capped(role, crate)..remove(CrateSwitches.agent);
  return (
    grant: roleHere.containsAll(wantHere) ? null : want,
    limit: wantHere.containsAll(roleHere) ? null : {...want, if (role.contains(CrateSwitches.agent)) CrateSwitches.agent},
  );
}

/// The record as it would stand once [uid] has [picks] (what a change would
/// take away is read from it): a copy, [record] stays as it is.
OrchardRecord vaultRecordAfter(OrchardRecord record, String uid, Map<String, VaultPick> picks) {
  final sim = record.copy();
  for (final change in vaultPickChanges(record, uid, picks)) {
    _applyTo(sim, uid, change);
  }
  return sim;
}

/// Whether [changes] (about [uid], by [me]) hand out only what [me] has,
/// entry by entry, as the record checks them.
bool _handsOutOnlyOwn(OrchardRecord record, String me, String uid,
    List<({String type, Map<String, Object?> body})> changes) {
  final sim = record.copy();
  if (sim.members[uid] == null) return false;
  for (final change in changes) {
    final before = {for (final c in sim.crates.keys) c: sim.switchesOf(uid, c)};
    _applyTo(sim, uid, change);
    for (final c in sim.crates.keys) {
      final gained = sim.switchesOf(uid, c).difference(before[c]!);
      if (!record.switchesOf(me, c).containsAll(gained)) return false;
    }
  }
  return true;
}

/// [change] made to [uid] in [sim], as the record makes it: their extra
/// access replaced, or their limit in a vault set (ending what they were
/// given there until a set time) or cleared.
void _applyTo(OrchardRecord sim, String uid, ({String type, Map<String, Object?> body}) change) {
  final m = sim.members[uid]!;
  final body = change.body;
  if (change.type == RecordTypes.memberSet) {
    final grants = body['grants'] as Map<String, Object?>;
    m.grants = {for (final g in grants.entries) g.key: {...(g.value as List).cast<String>()}};
    return;
  }
  final crate = body['crate'] as String;
  final switches = body['switches'];
  if (switches == null) {
    m.limits.remove(crate);
  } else {
    m.limits[crate] = {...(switches as List).cast<String>()};
    m.timed.remove(crate);
  }
}

Set<String> _capped(Set<String> switches, RecordCrate crate) =>
    {...switches}..removeWhere((x) => CrateSwitches.capped.contains(x) && !crate.allow.contains(x));

/// The level [switches] come to in [crate], agent forwarding and what the
/// vault does not allow aside (a level where forwarding is off there is
/// still that level); null for a set no level matches.
CrateLevel? vaultLevelIn(Set<String> switches, RecordCrate crate) {
  final core = _capped(switches, crate)..remove(CrateSwitches.agent);
  for (final l in CrateLevel.values) {
    final s = _capped(levelSwitches(l), crate);
    if (s.length == core.length && s.containsAll(core)) return l;
  }
  return null;
}

bool _same(Set<String>? a, Set<String>? b) =>
    (a == null) == (b == null) && (a == null || (a.length == b!.length && a.containsAll(b)));
