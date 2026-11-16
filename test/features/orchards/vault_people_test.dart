import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/member_actions.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/widgets/vaults_page.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Who the vault switcher shows as able to open a vault (3.2):
/// owners always, nobody else for an owners-only
/// vault; otherwise admins, the roles that open it, extra grants and access
/// for a set time; active members only, never this account.
OrchardPerson _person(String uid, String role,
        {bool isMe = false,
        MemberStatus status = MemberStatus.active,
        Map<String, Set<String>> grants = const {},
        Map<String, Set<String>> limits = const {}}) =>
    OrchardPerson(
      uid: uid,
      isMe: isMe,
      role: role,
      status: status,
      grants: grants,
      limits: limits,
      actions: const MemberActions(),
      email: '$uid@example.com',
    );

void main() {
  const prod = CrateSummary(id: 'prod', name: 'Production', level: 'manage');
  const vault = CrateSummary(id: 'vault', name: 'Owners', level: 'manage', ownersOnly: true);
  final people = OrchardPeople(
    me: 'me',
    record: OrchardRecord('o1'),
    members: [
      _person('me', FixedRoles.owner, isMe: true),
      _person('alex', FixedRoles.owner),
      _person('sam', FixedRoles.admin),
      _person('priya', 'ops'),
      _person('jonah', 'dev'),
      _person('maya', 'dev', grants: {'prod': {}}),
      _person('lee', 'dev'),
      _person('paused', 'ops', status: MemberStatus.suspended),
    ],
    roles: const [
      OrchardRoleView(id: 'ops', name: 'Ops', rank: 1, can: {}, crates: {'prod': {}}),
      OrchardRoleView(id: 'dev', name: 'Dev', rank: 2, can: {}, crates: {}),
    ],
    stepDown: false,
    leave: true,
  );
  final timed = [
    const TimedAccess(
        uid: 'lee', crateId: 'prod', adds: {}, level: CrateLevel.connect, until: 0, wholeCrate: true, canEnd: true),
  ];

  test('a vault: owners, admins, its roles, extra grants and timed access; not me, not the suspended', () {
    expect([for (final p in vaultPeople(prod, people, timed)) p.uid], ['alex', 'sam', 'priya', 'maya', 'lee']);
    expect([for (final p in vaultPeople(prod, people, const [])) p.uid], ['alex', 'sam', 'priya', 'maya']);
  });

  // Vault access per member: No access set for someone keeps
  // them out whatever their role gives; a level set for them keeps them in;
  // access until a set time given since still opens it.
  test('a vault: one with No access set for them there is out, a lower level is in, timed access since is in', () {
    final limited = OrchardPeople(
      me: 'me',
      record: OrchardRecord('o1'),
      members: [
        _person('me', FixedRoles.owner, isMe: true),
        _person('priya', 'ops', limits: {'prod': {}}),
        _person('omar', 'ops', limits: {'prod': levelSwitches(CrateLevel.connect)}),
        _person('maya', 'dev', grants: {'prod': {}}, limits: {'prod': {}}),
        _person('lee', 'ops', limits: {'prod': {}}),
      ],
      roles: const [
        OrchardRoleView(id: 'ops', name: 'Ops', rank: 1, can: {}, crates: {'prod': {}}),
        OrchardRoleView(id: 'dev', name: 'Dev', rank: 2, can: {}, crates: {}),
      ],
      stepDown: false,
      leave: true,
    );
    expect([for (final p in vaultPeople(prod, limited, timed)) p.uid], ['omar', 'lee']);
    final l10n = lookupAppLocalizations(const Locale('en'));
    final ops = VaultAccess.of(prod, limited, const [], l10n).roles.singleWhere((r) => r.id == 'ops');
    expect(ops.people, 1, reason: 'of Ops, only Omar opens it');
  });

  test('a vault only owners open: the other owners alone', () {
    expect([for (final p in vaultPeople(vault, people, timed)) p.uid], ['alex']);
  });
}
