import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';

// Vault access per member: what each pick writes to the team
// record, and which picks an account may make. The record's own rules for
// these entries are in the shared corpus (record_corpus_test); this is the
// app's side of choosing them.

const _owner = 'owner';
const _lead = 'lead';
const _riley = 'riley';
const _prod = 'prod';
const _staging = 'staging';
const _secret = 'secret';

/// A team in memory: an owner, a lead (rank 500, manages Production for
/// good, Use in Staging) and Riley (Developers, rank 100: Use in
/// Production, Connect in Staging); an owners-only vault besides.
OrchardRecord _team({Set<String>? developers, Set<String>? leadProd}) {
  final r = OrchardRecord('team');
  r.crates[_prod] = RecordCrate(id: _prod, ownersOnly: false, allow: {...CrateSwitches.capped});
  r.crates[_staging] = RecordCrate(id: _staging, ownersOnly: false, allow: {...CrateSwitches.capped});
  r.crates[_secret] = RecordCrate(id: _secret, ownersOnly: true, allow: {...CrateSwitches.capped});
  r.roles['devs'] = RecordRole(
    id: 'devs',
    rank: 100,
    nameEnc: '',
    nameGeneration: 1,
    can: {},
    crates: {_prod: developers ?? levelSwitches(CrateLevel.use), _staging: levelSwitches(CrateLevel.connect)},
  );
  r.roles['leads'] = RecordRole(
    id: 'leads',
    rank: 500,
    nameEnc: '',
    nameGeneration: 1,
    can: {RoleCan.changeRoles},
    crates: {_prod: leadProd ?? levelSwitches(CrateLevel.manage), _staging: levelSwitches(CrateLevel.use)},
  );
  for (final (uid, role) in [(_owner, FixedRoles.owner), (_lead, 'leads'), (_riley, 'devs')]) {
    r.members[uid] = RecordMember(uid: uid, role: role, keys: {}, since: 1);
  }
  return r;
}

VaultAccessRow _row(OrchardRecord r, String crate, {String me = _owner, String uid = _riley, bool on = true}) =>
    vaultAccessOf(r, me, uid, limitsOn: on).singleWhere((x) => x.crateId == crate);

List<VaultPick> _picks(VaultAccessRow row) => [for (final p in row.picks) p.pick];

Set<String> _set(Object? list) => {...(list as List).cast<String>()};

void main() {
  test('every vault but the owners-only one, with what the role gives and nothing set apart', () {
    final rows = vaultAccessOf(_team(), _owner, _riley, limitsOn: true);
    expect([for (final r in rows) r.crateId], [_prod, _staging]);
    final prod = rows.first;
    expect(prod.fromRole, levelSwitches(CrateLevel.use));
    expect(prod.current, VaultPick.fromRole);
    expect(prod.apart, isFalse);
    // Their role's own level is From role: it is not offered twice.
    expect(_picks(prod),
        [VaultPick.fromRole, VaultPick.none, VaultPick.connect, VaultPick.edit, VaultPick.manage]);
    expect(prod.picks.every((p) => p.open), isTrue, reason: 'an owner may give and take anything');
  });

  test('above the role is extra access, below it a limit, No access a limit of nothing', () {
    final r = _team();
    final up = vaultPickChanges(r, _riley, {_prod: VaultPick.edit});
    expect([for (final c in up) c.type], [RecordTypes.memberSet]);
    expect(_set((up.single.body['grants'] as Map)[_prod]), levelSwitches(CrateLevel.edit));

    final down = vaultPickChanges(r, _riley, {_prod: VaultPick.connect});
    expect([for (final c in down) c.type], [RecordTypes.memberLimit]);
    expect(down.single.body, {'uid': _riley, 'crate': _prod, 'switches': switchList(levelSwitches(CrateLevel.connect))});

    final none = vaultPickChanges(r, _riley, {_prod: VaultPick.none});
    expect(none.single.body, {'uid': _riley, 'crate': _prod, 'switches': <String>[]});

    // Nothing to write for what is already so.
    expect(vaultPickChanges(r, _riley, {_prod: VaultPick.fromRole}), isEmpty);
    expect(vaultPickChanges(r, _riley, {_prod: VaultPick.use}), isEmpty, reason: 'their role gives Use');
  });

  test('From role clears both; a limit set where extra access was takes the extra access away first', () {
    final r = _team();
    r.members[_riley]!
      ..grants = {_prod: levelSwitches(CrateLevel.edit)}
      ..limits[_staging] = <String>{};
    final row = _row(r, _prod);
    expect(row.current, VaultPick.edit);
    expect(row.apart, isTrue);
    expect(_row(r, _staging).current, VaultPick.none);

    // Lowered below the role: the extra access goes in the same change,
    // before the limit, so no step between gives more than before or after.
    final down = vaultPickChanges(r, _riley, {_prod: VaultPick.connect});
    expect([for (final c in down) c.type], [RecordTypes.memberSet, RecordTypes.memberLimit]);
    expect(down.first.body['grants'], isEmpty);

    final back = vaultPickChanges(r, _riley, {_staging: VaultPick.fromRole});
    expect(back.single.body, {'uid': _riley, 'crate': _staging});
  });

  test('a role made by hand that a level neither holds nor is held in takes both, extra access first', () {
    // Developers: Connect and Reveal in Production, no forwarding, no files.
    final r = _team(developers: {CrateSwitches.connect, CrateSwitches.reveal});
    expect(_row(r, _prod).fromRole, {CrateSwitches.connect, CrateSwitches.reveal});
    final c = vaultPickChanges(r, _riley, {_prod: VaultPick.connect});
    expect([for (final x in c) x.type], [RecordTypes.memberSet, RecordTypes.memberLimit]);
    final after = vaultRecordAfter(r, _riley, {_prod: VaultPick.connect});
    expect(after.switchesOf(_riley, _prod), levelSwitches(CrateLevel.connect));
    expect(r.switchesOf(_riley, _prod), {CrateSwitches.connect, CrateSwitches.reveal}, reason: 'the record stays');
  });

  test('a limit keeps agent forwarding where the role gives it; levels never add it', () {
    final r = _team(developers: {...levelSwitches(CrateLevel.use), CrateSwitches.agent});
    expect(_row(r, _prod).current, VaultPick.fromRole);
    expect(_picks(_row(r, _prod)), isNot(contains(VaultPick.use)), reason: 'Use and agent forwarding is still Use');
    final after = vaultRecordAfter(r, _riley, {_prod: VaultPick.connect});
    expect(after.switchesOf(_riley, _prod), {...levelSwitches(CrateLevel.connect), CrateSwitches.agent});
    final up = vaultRecordAfter(r, _riley, {_prod: VaultPick.edit});
    expect(up.switchesOf(_riley, _prod), {...levelSwitches(CrateLevel.edit), CrateSwitches.agent});
  });

  test('a manager gives only what they have: more is greyed, less is not; lifting a limit counts as giving', () {
    // The lead manages Production without Reveal (by hand); Riley has Use.
    final r = _team(leadProd: {CrateSwitches.connect, CrateSwitches.manage, CrateSwitches.sftp, CrateSwitches.forward});
    final row = _row(r, _prod, me: _lead);
    bool open(VaultPick p) => row.picks.singleWhere((x) => x.pick == p).open;
    expect(open(VaultPick.none), isTrue);
    expect(open(VaultPick.connect), isTrue);
    expect(open(VaultPick.edit), isFalse);
    expect(open(VaultPick.manage), isFalse);

    // Held to Connect, putting her back to her role gives Reveal back: the
    // lead has none to give.
    r.members[_riley]!.limits[_prod] = levelSwitches(CrateLevel.connect);
    final limited = _row(r, _prod, me: _lead);
    expect(limited.picks.singleWhere((x) => x.pick == VaultPick.fromRole).open, isFalse);
    // The owner may.
    expect(_row(r, _prod).picks.singleWhere((x) => x.pick == VaultPick.fromRole).open, isTrue);
  });

  test('nothing to pick where this account does not manage the vault, or does not rank above', () {
    final r = _team();
    // The lead uses Staging, without managing it.
    expect(_row(r, _staging, me: _lead).picks, isEmpty);
    expect(_row(r, _prod, me: _lead).picks, isNotEmpty);
    // Riley ranks below the lead: nothing about the lead, nor about herself.
    expect(_row(r, _prod, me: _riley, uid: _lead).picks, isEmpty);
    expect(_row(r, _prod, me: _riley).picks, isEmpty);
  });

  test('owners and admins: nothing set per vault, nothing to pick', () {
    final r = _team();
    r.members['ada'] = RecordMember(uid: 'ada', role: FixedRoles.admin, keys: {}, since: 1);
    for (final uid in [_owner, 'ada']) {
      for (final row in vaultAccessOf(r, _owner, uid, limitsOn: true)) {
        expect(row.picks, isEmpty);
        expect(row.apart, isFalse);
      }
    }
    expect(_row(r, _prod, uid: 'ada').fromRole, CrateSwitches.all,
        reason: 'what the Admin role gives (all of it as every team starts)');
  });

  test('until new kinds are on, what needs a limit is left out and the row says it waits', () {
    final r = _team();
    final off = _row(r, _prod, on: false);
    expect(_picks(off), [VaultPick.fromRole, VaultPick.edit, VaultPick.manage]);
    expect(off.waitsForSwitch, isTrue);
    // A limit set before: it stays shown, and nothing else can be picked
    // there (putting it back is a limit entry too).
    r.members[_riley]!.limits[_prod] = <String>{};
    final held = _row(r, _prod, on: false);
    expect(_picks(held), [VaultPick.none]);
    expect(held.current, VaultPick.none);
  });

  test('a limit ends access given there until a set time, as the record does', () {
    final r = _team();
    r.members[_riley]!.timed[_prod] = RecordTimedGrant(until: 4000000000, switches: levelSwitches(CrateLevel.edit));
    expect(r.switchesAt(_riley, _prod, 1000), levelSwitches(CrateLevel.edit));
    final after = vaultRecordAfter(r, _riley, {_prod: VaultPick.connect});
    expect(after.switchesAt(_riley, _prod, 1000), levelSwitches(CrateLevel.connect));
    // Extra access leaves it running.
    final up = vaultRecordAfter(r, _riley, {_prod: VaultPick.manage});
    expect(up.members[_riley]!.timed[_prod], isNotNull);
  });
}
