part of 'orchard_service.dart';

// Changing who is in an Orchard and what they may do (3.0): a
// member's role, extra Crates and end date, ownership, suspension, removal
// and leaving; the roles the owners make; a Crate's settings and name. Each
// change to the record goes through [OrchardService._changeWith]: built from
// the record as it stands on the server, checked here entry by entry, and
// sent with every key it hands out.

/// The most entries sent in one step (the server takes up to 64, MAX_APPEND).
const int kSettleStepEntries = 60;

/// The steps of the record that make what an owner decided about members
/// outside the address domains so ([OrchardManagement.settleOutsideDomains]).
/// The rules first: where it takes more than one step and stops part way,
/// someone briefly held back can be let in again, and someone removed cannot.
/// [rulesAlone]: this account is held back now, and the server takes the rules
/// from it, and nothing else until they let it in, so they go in a step of their
/// own.
List<List<RecordChange>> outsideDomainSteps({
  RecordRules? rules,
  Map<String, int> guests = const {},
  Set<String> clear = const {},
  Set<String> remove = const {},
  bool rulesAlone = false,
}) {
  final first = <RecordChange>[if (rules != null) (type: RecordTypes.rulesSet, body: rules.toSetBody())];
  final members = <RecordChange>[
    for (final g in guests.entries) (type: RecordTypes.memberSet, body: {'uid': g.key, 'ends_at': g.value}),
    for (final uid in clear) (type: RecordTypes.memberSet, body: {'uid': uid, 'ends_at': 0}),
    for (final uid in remove) (type: RecordTypes.memberRemove, body: {'uid': uid}),
  ];
  final changes = rulesAlone ? members : [...first, ...members];
  return [
    if (rulesAlone && first.isNotEmpty) first,
    for (var i = 0; i < changes.length; i += kSettleStepEntries)
      changes.sublist(i, math.min(i + kSettleStepEntries, changes.length)),
  ];
}

/// A member as the Members screen shows them: who they are and their
/// standing from the Orchard's record, how far this device trusts their
/// keys, and what this account may change about them.
class OrchardPerson {
  const OrchardPerson({
    required this.uid,
    required this.isMe,
    required this.role,
    required this.status,
    required this.grants,
    required this.actions,
    this.limits = const {},
    this.email,
    this.name,
    this.picture,
    this.endsAt,
    this.endChosenByOwner = false,
    this.trust,
  });

  final String uid;
  final bool isMe;
  final String? email;

  /// Their name and picture as their own account shows them;
  /// null for none.
  final String? name;
  final String? picture;

  /// 'owner', 'admin' or the id of a role the owners made.
  final String role;
  final MemberStatus status;

  /// When their access ends, in seconds since the epoch; null for never.
  final int? endsAt;

  /// An owner signed the entry that gave [endsAt] (RecordMember.endsFromOwner).
  final bool endChosenByOwner;

  /// Their extra Crates: Crate id to switches.
  final Map<String, Set<String>> grants;

  /// Their limits: Crate id to the switches they are held to
  /// there, none for No access.
  final Map<String, Set<String>> limits;

  /// Their keys as this device trusts them; null before the member
  /// list was first read.
  final MemberView? trust;
  final MemberActions actions;

  /// Their end date has passed: nothing opens to them any more.
  bool endedAt(int nowSeconds) => endsAt != null && endsAt! <= nowSeconds;

  /// The server says their account was deleted.
  bool get accountDeleted => trust?.accountDeleted ?? false;
}

/// A key (a saved login: password, private key or certificate) someone
/// could use, and the hosts saved here that use it.
class ExposedKey {
  const ExposedKey({
    required this.id,
    required this.label,
    required this.username,
    required this.authMethod,
    required this.crateId,
    required this.hosts,
  });

  final String id;
  final String label;
  final String username;

  /// 'password', 'publicKey' or 'certificate'.
  final String authMethod;
  final String crateId;
  final List<({String id, String label, String host, int port})> hosts;
}

/// What a member could use in an Orchard (3.0): the keys they
/// could see or copy (Crates where they had reveal), the keys they could
/// only connect with (Connect), and the Crates they could open that this
/// account cannot, with who manages each. Keys held by a hardware token or
/// an agent are left out: nothing of theirs is in the Orchard to take.
class OrchardExposure {
  const OrchardExposure({required this.reveal, required this.connect, required this.closed});

  final List<ExposedKey> reveal;
  final List<ExposedKey> connect;

  /// Crate id to the members who manage it (the person aside).
  final Map<String, List<String>> closed;

  bool get isEmpty => reveal.isEmpty && connect.isEmpty && closed.isEmpty;
}

/// Someone this device's person has not compared codes with, for their
/// current keys, cannot be made an owner or admin (3.0).
class MemberNotCompared implements Exception, HasTypeName {
  const MemberNotCompared(this.uid);

  final String uid;

  @override
  String toString() => 'Not compared: $uid';

  @override
  String get typeName => 'MemberNotCompared';
}

/// A key to change after someone lost access (3.0; the
/// Overview's "Change these next"): what they could use, kept on the device
/// that took their access, until someone marks it changed.
class ChangeNextItem {
  const ChangeNextItem({
    required this.subjectUid,
    required this.entrySeq,
    required this.keyId,
    required this.label,
    required this.crateId,
    required this.couldReveal,
    required this.rank,
    required this.hosts,
    this.doneAt,
  });

  /// Who lost access, and the record entry that took it.
  final String subjectUid;
  final int entrySeq;

  final String keyId;

  /// The key's name now, or as it was when kept if it is gone since.
  final String label;
  final String crateId;

  /// They could see or copy it; otherwise they could only connect with it
  /// (the app hid it, their devices held it).
  final bool couldReveal;

  /// First to change first: what they could reveal, then the rest.
  final int rank;

  /// The hosts saved here that use it.
  final int hosts;

  /// When it was marked changed, in seconds since the epoch; null while it
  /// waits.
  final int? doneAt;

  bool get done => doneAt != null;
}

/// The members outside a list of address domains ([outsideDomainsOf]): who is
/// held back by it, who is in as a guest (outside it, with an end date), and
/// those whose address this device does not know: the server holds them back
/// where it is outside.
class OutsideDomains {
  const OutsideDomains({this.held = const [], this.guests = const [], this.unknown = const []});

  final List<OrchardPerson> held;
  final List<OrchardPerson> guests;
  final List<OrchardPerson> unknown;

  /// The guests whose end date no owner gave: nobody who may decide has seen
  /// that it lets them in.
  List<OrchardPerson> get unseen => [
        for (final p in guests)
          if (!p.endChosenByOwner) p,
      ];

  bool get isEmpty => held.isEmpty && guests.isEmpty && unknown.isEmpty;
}

/// Who of [people] the address [domains] leave out, this account aside (the
/// rules view refuses a list that leaves its own person out) and those whose
/// access or account ended: for them it changes nothing.
OutsideDomains outsideDomainsOf(OrchardPeople people, Set<String> domains, {int? nowSeconds}) {
  final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  if (domains.isEmpty) return const OutsideDomains();
  final held = <OrchardPerson>[];
  final guests = <OrchardPerson>[];
  final unknown = <OrchardPerson>[];
  for (final p in people.members) {
    if (p.isMe || p.status != MemberStatus.active || p.accountDeleted || p.endedAt(now)) continue;
    if (p.endsAt == null && p.email == null) {
      unknown.add(p);
    } else if (domainRuleHolds(domains, p.email, endsAt: p.endsAt)) {
      held.add(p);
    } else if (p.email != null && !domains.contains(addressDomain(p.email))) {
      guests.add(p);
    }
  }
  return OutsideDomains(held: held, guests: guests, unknown: unknown);
}

/// [OrchardManagement.settleOutsideDomains] stopped with some of it done.
class OutsideSettleStopped implements Exception, HasTypeName {
  const OutsideSettleStopped({required this.done, required this.total, required this.removed, required this.cause});

  /// How many changes went into the record, of [total].
  final int done;
  final int total;

  /// Who is out already.
  final Set<String> removed;
  final Object cause;

  @override
  String get typeName => 'OutsideSettleStopped';

  @override
  String toString() => 'Team members: $done of $total changes made, then: $cause';
}

/// An Orchard's people as this device knows them: everyone the record has
/// who was not removed, this account first, then by rank.
class OrchardPeople {
  const OrchardPeople({
    required this.me,
    required this.record,
    required this.members,
    required this.roles,
    required this.stepDown,
    required this.leave,
  });

  final String me;
  final OrchardRecord record;
  final List<OrchardPerson> members;

  /// The roles the owners made, highest first, with their names opened.
  final List<OrchardRoleView> roles;

  /// This account is an owner and another owner stays.
  final bool stepDown;

  /// Anyone but the last owner may leave.
  final bool leave;

  bool get isOwner => record.isOwner(me);

  /// The only owner: losing that account would leave nobody to run the
  /// Orchard (the Members screen suggests a second).
  bool get soleOwner => isOwner && record.owners.length == 1;

  /// A role's name, when it is one the owners made and its name opened.
  String? roleName(String id) => roles.where((r) => r.id == id).firstOrNull?.name;
}

extension OrchardManagement on OrchardService {
  /// What [uid] could use in [orchardId] as the record [asOf] (this
  /// device's, when null) gives it to them, whatever their standing: for
  /// right before they are suspended or removed, and for owners and admins
  /// at any time. Built from what this device holds: the keys in each
  /// Crate it can open and the hosts that use them; the rest counted by
  /// Crate. No secret is read.
  Future<OrchardExposure> exposure(String orchardId, String uid, {OrchardRecord? asOf}) async {
    final db = await databases.open(orchardId);
    final record = (asOf ?? (await LocalRecord.load(db, orchardId)).latest).copy();
    // As if active: what their role and extra Crates give them.
    record.members[uid]?.status = MemberStatus.active;
    final open = {
      for (final r in await db.customSelect('SELECT crate_id FROM orchard_crates').get()) r.read<String>('crate_id'),
    };
    final reveal = <ExposedKey>[];
    final connect = <ExposedKey>[];
    final closed = <String, List<String>>{};
    for (final crateId in record.crates.keys) {
      // With what they were given until a set time, whether or not
      // that time has come: what they could use while they had it is what
      // there is to change.
      final switches = record.switchesAt(uid, crateId, 0);
      if (switches.isEmpty) continue;
      if (!open.contains(crateId)) {
        closed[crateId] = [
          for (final m in record.members.values)
            if (m.uid != uid && record.switchesOf(m.uid, crateId).contains(CrateSwitches.manage)) m.uid,
        ]..sort();
        continue;
      }
      final keys = await db.customSelect(
        'SELECT i.id, i.label, i.username, i.auth_method FROM identities i '
        "JOIN crate_items_meta m ON m.kind = 'key' AND m.item_key = i.id "
        "WHERE m.crate_id = ? AND i.auth_method IN ('password', 'publicKey', 'certificate') AND i.uses_agent = 0 "
        'ORDER BY i.label COLLATE NOCASE, i.id',
        variables: [Variable(crateId)],
      ).get();
      for (final k in keys) {
        final id = k.read<String>('id');
        final hosts = await db.customSelect(
          'SELECT id, label, host, port FROM connections WHERE identity_id = ? ORDER BY label COLLATE NOCASE, id',
          variables: [Variable(id)],
        ).get();
        final key = ExposedKey(
          id: id,
          label: k.read<String>('label'),
          username: k.read<String>('username'),
          authMethod: k.read<String>('auth_method'),
          crateId: crateId,
          hosts: [
            for (final h in hosts)
              (
                id: h.read<String>('id'),
                label: h.read<String>('label'),
                host: h.read<String>('host'),
                port: h.read<int>('port'),
              ),
          ],
        );
        (switches.contains(CrateSwitches.reveal) ? reveal : connect).add(key);
      }
    }
    return OrchardExposure(reveal: reveal, connect: connect, closed: closed);
  }

  /// Keeps what [uid] could use ([exposure], worked out just before they
  /// lost access) as the keys to change next: what they could reveal first,
  /// then what they could connect with. Filed under the latest entry of the
  /// record here that suspended or removed them, or changed what they may
  /// do in a vault. Keys kept before stay as they were.
  Future<void> keepChangeNext(String orchardId, String uid, OrchardExposure exposure) async {
    if (exposure.reveal.isEmpty && exposure.connect.isEmpty) return;
    final db = await databases.open(orchardId);
    final record = await LocalRecord.load(db, orchardId);
    final entry = record.entries.reversed
        .where((e) =>
            (e.type == RecordTypes.memberSuspend ||
                e.type == RecordTypes.memberRemove ||
                e.type == RecordTypes.memberSet ||
                e.type == RecordTypes.memberLimit) &&
            e.body['uid'] == uid)
        .firstOrNull;
    if (entry == null) return;
    var rank = 0;
    await db.transaction(() async {
      for (final (k, reveal) in [
        for (final k in exposure.reveal) (k, true),
        for (final k in exposure.connect) (k, false),
      ]) {
        rank++;
        await db.customStatement(
          'INSERT OR IGNORE INTO change_next (subject_uid, entry_seq, key_id, label, crate_id, could_reveal, rank) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          [uid, entry.seq, k.id, k.label, k.crateId, reveal ? 1 : 0, rank],
        );
      }
    });
  }

  /// The keys to change after people lost access, newest loss first, each
  /// list in its order: those still waiting and those marked changed.
  Future<List<ChangeNextItem>> changeNext(String orchardId) async {
    final db = await databases.open(orchardId);
    final rows = await db
        .customSelect(
          'SELECT c.subject_uid, c.entry_seq, c.key_id, c.crate_id, c.could_reveal, c.rank, c.done_at, '
          'COALESCE(i.label, c.label) AS label, '
          '(SELECT COUNT(*) FROM connections WHERE identity_id = c.key_id) AS hosts '
          'FROM change_next c LEFT JOIN identities i ON i.id = c.key_id '
          'ORDER BY c.entry_seq DESC, c.rank',
        )
        .get();
    return [
      for (final r in rows)
        ChangeNextItem(
          subjectUid: r.read<String>('subject_uid'),
          entrySeq: r.read<int>('entry_seq'),
          keyId: r.read<String>('key_id'),
          label: r.read<String>('label'),
          crateId: r.read<String>('crate_id'),
          couldReveal: r.read<int>('could_reveal') == 1,
          rank: r.read<int>('rank'),
          hosts: r.read<int>('hosts'),
          doneAt: r.read<int?>('done_at'),
        ),
    ];
  }

  /// Marks [item] changed (at [now], this device's clock by default).
  Future<void> markChanged(String orchardId, ChangeNextItem item, {DateTime? now}) async {
    final db = await databases.open(orchardId);
    await db.customStatement(
      'UPDATE change_next SET done_at = ? WHERE subject_uid = ? AND entry_seq = ? AND key_id = ?',
      [(now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000, item.subjectUid, item.entrySeq, item.keyId],
    );
  }

  /// The people of [orchardId] as the record on this device has them.
  Future<OrchardPeople> people(String orchardId) async {
    final me = await _me();
    final db = await databases.open(orchardId);
    final record = (await LocalRecord.load(db, orchardId)).latest;
    final views = {for (final v in await MemberDirectory(db).view(me.uid)) v.uid: v};
    final roleViews = await roles(orchardId);
    final members = [
      for (final m in record.members.values)
        if (m.status != MemberStatus.removed)
          OrchardPerson(
            uid: m.uid,
            isMe: m.uid == me.uid,
            email: views[m.uid]?.email,
            name: views[m.uid]?.name,
            picture: views[m.uid]?.picture,
            role: m.role,
            status: m.status,
            endsAt: m.endsAt,
            endChosenByOwner: m.endsFromOwner,
            grants: {for (final g in m.grants.entries) g.key: {...g.value}},
            limits: {for (final l in m.limits.entries) l.key: {...l.value}},
            trust: views[m.uid],
            actions: MemberActions.of(record, me.uid, m.uid),
          ),
    ];
    members.sort((a, b) {
      if (a.isMe != b.isMe) return a.isMe ? -1 : 1;
      final rank = record.rankOfRole(b.role).compareTo(record.rankOfRole(a.role));
      if (rank != 0) return rank;
      return (a.email ?? a.uid).toLowerCase().compareTo((b.email ?? b.uid).toLowerCase());
    });
    final self = selfActions(record, me.uid);
    return OrchardPeople(
      me: me.uid,
      record: record,
      members: members,
      roles: roleViews,
      stepDown: self.stepDown,
      leave: self.leave,
    );
  }

  // ── Members ──

  /// Gives [uid] the role [role] (owners and admins lose their extra
  /// Crates in the same step; see [roleChangeBody]). Making someone an admin
  /// carries this account's comparison of their keys.
  Future<void> setMemberRole(String orchardId, String uid, String role) => _changeWith(orchardId, (latest) async {
        final body = roleChangeBody(latest, uid, role);
        final from = latest.members[uid]?.role ?? '';
        return [
          (
            type: RecordTypes.memberSet,
            body: makesOwnerOrAdmin(from, role) ? await _withComparison(orchardId, latest, uid, body) : body,
          ),
        ];
      });

  /// [body], a member.set making [uid] an owner or admin, with this
  /// account's signed statement that it compared their keys as [latest]
  /// holds them (3.0): only when this device holds those very
  /// keys for them, with no stop, and its person compared them. Throws
  /// [MemberNotCompared] otherwise.
  Future<Map<String, Object?>> _withComparison(
      String orchardId, OrchardRecord latest, String uid, Map<String, Object?> body) async {
    final me = await _me();
    final target = latest.members[uid];
    if (target == null) throw MemberNotCompared(uid);
    final keys = target.currentKeys.published(uid);
    final db = await databases.open(orchardId);
    final view = (await MemberDirectory(db).view(me.uid)).where((v) => v.uid == uid).firstOrNull;
    final pinned = view?.fingerprint;
    if (view == null ||
        view.hardStop ||
        !view.verifiedByMe ||
        view.keyVersion != keys.version ||
        pinned == null ||
        !_sameBytes(pinned, keys.fingerprint)) {
      throw MemberNotCompared(uid);
    }
    return {
      ...body,
      'verified': base64Encode(
          await signMemberVerification(me.keys, verifierUid: me.uid, orchardId: orchardId, subject: keys)),
    };
  }

  /// Sets [uid]'s extra Crates to [grants] (Crate id to switches); an
  /// empty map takes them all away.
  Future<void> setMemberGrants(String orchardId, String uid, Map<String, Set<String>> grants) =>
      changeAll(orchardId, [
        (
          type: RecordTypes.memberSet,
          body: {
            'uid': uid,
            'grants': {for (final g in grants.entries) g.key: switchList(g.value)},
          },
        ),
      ]);

  /// Sets [uid]'s access to vaults (vault access per member):
  /// vault id to what is picked, written as [vaultPickChanges] works it out
  /// from the record as it stands on the server (extra access, a limit, or
  /// both). Nothing is sent when it changes nothing by then.
  Future<void> setVaultAccess(String orchardId, String uid, Map<String, VaultPick> picks) =>
      _changeWith(orchardId, (latest) async => vaultPickChanges(latest, uid, picks));

  /// Ends [uid]'s access at [endsAt] (seconds since the epoch); null keeps
  /// it open with no end.
  Future<void> setMemberEndsAt(String orchardId, String uid, int? endsAt) => changeAll(orchardId, [
        (type: RecordTypes.memberSet, body: {'uid': uid, 'ends_at': endsAt ?? 0}),
      ]);

  /// Makes [uid] an owner, and with [stepDown] this account an admin in
  /// the same step (an ownership transfer).
  Future<void> makeOwner(String orchardId, String uid, {bool stepDown = false}) async {
    final me = await _me();
    await _changeWith(orchardId, (latest) async => [
          (
            type: RecordTypes.memberSet,
            body: await _withComparison(orchardId, latest, uid, roleChangeBody(latest, uid, FixedRoles.owner)),
          ),
          if (stepDown) (type: RecordTypes.memberSet, body: {'uid': me.uid, 'role': FixedRoles.admin}),
        ]);
  }

  /// This account, an owner, becomes an admin (another owner stays).
  Future<void> stepDown(String orchardId) async {
    final me = await _me();
    await change(orchardId, RecordTypes.memberSet, {'uid': me.uid, 'role': FixedRoles.admin});
  }

  /// Suspends [uid]: they keep what is on their devices, and nothing syncs
  /// to or from them until they are resumed. The keys they held wait to be
  /// replaced.
  Future<void> suspendMember(String orchardId, String uid) =>
      change(orchardId, RecordTypes.memberSuspend, {'uid': uid});

  /// Resumes [uid], with every generation of every key they gain back.
  Future<void> resumeMember(String orchardId, String uid) =>
      change(orchardId, RecordTypes.memberResume, {'uid': uid});

  /// Takes [uid] out of the Orchard. Their devices take it off at their
  /// next sync; the keys they held wait to be replaced.
  Future<void> removeMember(String orchardId, String uid) =>
      change(orchardId, RecordTypes.memberRemove, {'uid': uid});

  /// Takes this account out of [orchardId] and the Orchard off this device.
  /// The last owner cannot leave.
  Future<void> leaveOrchard(String orchardId) async {
    final me = await _me();
    await _changeWith(orchardId, (_) async => [(type: RecordTypes.memberRemove, body: {'uid': me.uid})],
        refresh: false);
    _standing.remove(orchardId);
    _listed.remove(orchardId);
    _invitesWaiting.remove(orchardId);
    // (That this account left is the last thing its device says of the
    // Orchard, where it is the one that sends its events on: event export.)
    await _flushEvents(orchardId);
    await databases.forget(orchardId);
  }

  // ── Roles (owners) ──

  /// Saves the role [id] (a new one, below every other, when null) with
  /// [name], what it [can] do in the Orchard, and its Crates with the
  /// switches it gives in each. Returns its id. Members who gain a Crate
  /// get its keys in the same step.
  Future<String> saveRole(
    String orchardId, {
    String? id,
    required String name,
    required Set<String> can,
    required Map<String, Set<String>> crates,
  }) async {
    final db = await databases.open(orchardId);
    final roleId = id ?? const Uuid().v4();
    final trimmed = name.trim();
    await _changeWith(orchardId, (latest) async {
      final existing = latest.roles[roleId];
      if (id != null && existing == null) throw const OrchardRecordRefused('no such role');
      // The name stays as it was encrypted unless it changed.
      var nameEnc = existing?.nameEnc;
      var nameGen = existing?.nameGeneration;
      if (existing == null || await _roleName(db, orchardId, existing) != trimmed) {
        nameGen = latest.generationOf(kOrchardScope);
        final key = await OrchardService._secret(db, orchardId, null, nameGen);
        if (key == null) throw const OrchardInviteError(OrchardInviteProblem.missingKeys);
        nameEnc = base64Encode(
            await encryptRoleName(trimmed, key, orchardId: orchardId, roleId: roleId, generation: nameGen));
      }
      Map<String, Object?> body(int rank) => {
            'id': roleId,
            'rank': rank,
            'name_enc': nameEnc,
            'name_gen': nameGen,
            'can': switchList(can),
            'crates': {for (final c in crates.entries) c.key: switchList(c.value)},
          };
      if (existing != null) return [(type: RecordTypes.roleSet, body: body(existing.rank))];
      if (latest.roles.length >= kMaxOrchardRoles) throw const OrchardRoleLimit();
      return reorderRoles(latest, [...rolesHighestFirst(latest), roleId], roleId, body);
    });
    return roleId;
  }

  /// The Admin role changed (admin.set, owners only): what it may do in the
  /// team and the Crates it opens, as a role's. Admins keep their rank.
  Future<void> setAdminRole(String orchardId, {required Set<String> can, required Map<String, Set<String>> crates}) =>
      _changeWith(orchardId, (latest) async => [
            (
              type: RecordTypes.adminSet,
              body: {
                'can': switchList(can),
                'crates': {for (final c in crates.entries) c.key: switchList(c.value)},
              },
            ),
          ]);

  /// The Admin role put back as every team starts: every Crate that is not
  /// owners-only, and everything in the team.
  Future<void> resetAdminRole(String orchardId) => _changeWith(
      orchardId, (latest) async => latest.adminRole == null ? const [] : [(type: RecordTypes.adminSet, body: {'all': true})]);

  /// Moves the role [id] one place up or down among the owners' roles.
  Future<void> moveRole(String orchardId, String id, {required bool up}) =>
      _changeWith(orchardId, (latest) async {
        final role = latest.roles[id];
        if (role == null) throw const OrchardRecordRefused('no such role');
        final order = rolesHighestFirst(latest);
        final at = order.indexOf(id);
        final to = up ? at - 1 : at + 1;
        if (to < 0 || to >= order.length) return const [];
        order
          ..removeAt(at)
          ..insert(to, id);
        return reorderRoles(latest, order, id, (rank) => roleBody(role, rank: rank));
      });

  /// Moves the role [id] to [index] among the owners' roles (0 is the
  /// highest), in as few entries as [reorderRoles] needs: where a role is
  /// dragged to on the Roles page.
  Future<void> moveRoleTo(String orchardId, String id, int index) =>
      _changeWith(orchardId, (latest) async {
        final role = latest.roles[id];
        if (role == null) throw const OrchardRecordRefused('no such role');
        final order = rolesHighestFirst(latest);
        final at = order.indexOf(id);
        final to = index.clamp(0, order.length - 1);
        if (to == at) return const [];
        order
          ..removeAt(at)
          ..insert(to, id);
        return reorderRoles(latest, order, id, (rank) => roleBody(role, rank: rank));
      });

  /// Deletes the role [id]; its members move to the role [moveTo].
  Future<void> dropRole(String orchardId, String id, String moveTo) =>
      change(orchardId, RecordTypes.roleDrop, {'id': id, 'move_to': moveTo});

  Future<String?> _roleName(AppDatabase db, String orchardId, RecordRole role) async {
    final key = await OrchardService._secret(db, orchardId, null, role.nameGeneration);
    if (key == null) return null;
    try {
      return await decryptRoleName(base64Decode(role.nameEnc), key,
          orchardId: orchardId, roleId: role.id, generation: role.nameGeneration);
    } catch (_) {
      return null;
    }
  }

  // ── Crates ──

  /// Sets what the Crate allows at all (SFTP, port forwarding, agent
  /// forwarding), for everyone in it. Needs Manage on it.
  Future<void> setCrateAllow(String orchardId, String crateId, Set<String> allow) =>
      change(orchardId, RecordTypes.crateSet, {'id': crateId, 'allow': switchList(allow)});

  /// Whether showing or copying a password, passphrase or private key from
  /// the Crate asks for the device PIN or a fingerprint first. Needs
  /// Manage on it.
  Future<void> setCrateConfirmReveal(String orchardId, String crateId, bool on) =>
      change(orchardId, RecordTypes.crateSet, {'id': crateId, 'confirm_reveal': on});

  /// Whether sessions to [crateId]'s hosts are logged for its owners and
  /// those who manage it. Owners only; every member who can open the
  /// Crate is told.
  Future<void> setCrateSessionLogs(String orchardId, String crateId, bool on) =>
      change(orchardId, RecordTypes.crateSet, {'id': crateId, 'session_logs': on});

  /// Whether sessions to [crateId]'s hosts are watched (3.0): one
  /// starts only once someone else who manages the Crate is watching it.
  /// Owners only; every member is told. A watched Crate allows the terminal
  /// only, so turning it on takes SFTP, port forwarding and agent
  /// forwarding off in the same entry (the record takes no other); turning
  /// it off leaves them off until someone allows them again.
  Future<void> setCrateWatched(String orchardId, String crateId, bool on) => change(orchardId, RecordTypes.crateSet, {
        'id': crateId,
        'watched': on,
        if (on) 'allow': switchList(const <String>{}),
      });

  /// Whether everyone who may connect to [crateId]'s hosts, and not only
  /// owners, may do so without a watcher while ZestSSH Cloud cannot be
  /// reached (3.0, the outage work). Owners only. It matters while the
  /// Crate's sessions are watched; whoever connects so gives a reason, and
  /// it is reported in the record once their device is back.
  Future<void> setCrateUnwatchedAway(String orchardId, String crateId, bool on) =>
      change(orchardId, RecordTypes.crateSet, {'id': crateId, 'unwatched_away': on});

  /// How many hours a device may go without reaching ZestSSH Cloud before
  /// [crateId] closes on it (3.0, the outage work): [hours] 0 takes the
  /// Crate's own limit off. Owners only, a year at most. The Orchard's own
  /// limit, where it has one, still closes all of the Orchard; a Crate's
  /// closes that Crate alone, so that a team can keep what is harmless open
  /// on a device that is away, and close what is not.
  Future<void> setCrateOfflineLimit(String orchardId, String crateId, int hours) =>
      change(orchardId, RecordTypes.crateSet, {'id': crateId, 'offline_hours': hours});

  /// Sets the Orchard's rules, all of them at once. Owners only; the
  /// server refuses rules the owner does not meet themselves.
  Future<void> setRules(String orchardId, RecordRules rules) =>
      change(orchardId, RecordTypes.rulesSet, rules.toSetBody());

  /// What an owner decided about members outside the address domains: those
  /// in [guests] stay until the time given (the server lets a member with an
  /// end date in from outside the domains), those in [clear] lose their end
  /// date and are held back, those in [remove] go, with [rules] where they
  /// change with it. All in one step of the record where it fits. Past that
  /// ([outsideDomainSteps]), [OutsideSettleStopped] says how far it came where
  /// a later step fails; what fails in the first left nothing changed.
  Future<void> settleOutsideDomains(
    String orchardId, {
    RecordRules? rules,
    Map<String, int> guests = const {},
    Set<String> clear = const {},
    Set<String> remove = const {},
  }) async {
    final info = await (await databases.open(orchardId))
        .customSelect('SELECT status FROM orchard_info WHERE id = 1')
        .getSingleOrNull();
    final steps = outsideDomainSteps(
        rules: rules, guests: guests, clear: clear, remove: remove, rulesAlone: info?.read<String>('status') == 'rules');
    final total = steps.fold<int>(0, (n, s) => n + s.length);
    var done = 0;
    final removed = <String>{};
    for (final step in steps) {
      try {
        await changeAll(orchardId, step);
      } catch (e) {
        if (done == 0) rethrow;
        throw OutsideSettleStopped(done: done, total: total, removed: removed, cause: e);
      }
      done += step.length;
      removed.addAll([
        for (final c in step)
          if (c.type == RecordTypes.memberRemove) c.body['uid']! as String,
      ]);
    }
  }

  /// Sets what the team records about its members, all four switches at
  /// once. Owners only; every member's device tells its person.
  Future<void> setTracking(String orchardId, RecordTracking tracking) =>
      change(orchardId, RecordTypes.trackingSet, tracking.toBody());

  /// Opens an owners-only Crate to admins and to the roles given it (an
  /// owner's call; a Crate becomes owners-only only when it is added).
  Future<void> openCrateToAll(String orchardId, String crateId) =>
      change(orchardId, RecordTypes.crateSet, {'id': crateId, 'owners_only': false});

  /// Renames a Crate: the new name, encrypted with its current key. Needs
  /// Manage on it.
  Future<void> renameCrate(String orchardId, String crateId, String name) async {
    await _me();
    final db = await databases.open(orchardId);
    final trimmed = name.trim();
    await _serial(orchardId, () async {
      final generation = (await LocalRecord.load(db, orchardId)).latest.generationOf(crateId);
      final key = await OrchardService._secret(db, orchardId, crateId, generation);
      if (key == null) throw const OrchardInviteError(OrchardInviteProblem.missingKeys);
      await server.renameCrate(
        crateId,
        await encryptCrateName(trimmed, key, orchardId: orchardId, crateId: crateId, generation: generation),
        generation: generation,
      );
      await db.customStatement('UPDATE orchard_crates SET name = ? WHERE crate_id = ?', [trimmed, crateId]);
    });
  }

  /// Renames the Orchard: the new name, encrypted with its current key. Owners
  /// and admins.
  Future<void> renameOrchard(String orchardId, String name) async {
    await _me();
    final db = await databases.open(orchardId);
    final trimmed = name.trim();
    await _serial(orchardId, () async {
      final generation = (await LocalRecord.load(db, orchardId)).latest.generationOf(kOrchardScope);
      final key = await OrchardService._secret(db, orchardId, null, generation);
      if (key == null) throw const OrchardInviteError(OrchardInviteProblem.missingKeys);
      await server.renameOrchard(
        orchardId,
        await encryptOrchardName(trimmed, key, orchardId: orchardId, generation: generation),
        generation: generation,
      );
      await db.customStatement('UPDATE orchard_info SET name = ? WHERE id = 1', [trimmed]);
    });
  }

  /// Whether [orchardId] has keys waiting to be replaced that this account
  /// may replace (see [rotateDue]), as this device last heard.
  Future<bool> keysWaiting(String orchardId) async {
    final db = await databases.open(orchardId);
    final info = await db.customSelect('SELECT role, rotation_due FROM orchard_info WHERE id = 1').getSingleOrNull();
    if (info == null) return false;
    final role = info.read<String>('role');
    if ((role == FixedRoles.owner || role == FixedRoles.admin) && info.read<int>('rotation_due') == 1) return true;
    final crates = await db.customSelect('SELECT switches FROM orchard_crates WHERE rotation_due = 1').get();
    return crates.any((c) => OrchardService._switches(c.read<String>('switches')).contains(CrateSwitches.manage));
  }

  /// Replaces the keys of [orchardId] that wait for it because someone lost
  /// access: the Orchard's own (owners and admins) and each Crate's this
  /// account manages. Returns the places that could not move this time.
  Future<List<String>> rotateDue(String orchardId) async {
    final me = await _me();
    await _serial(orchardId, () => _refreshOrchard(orchardId, me));
    final left = <String>[];
    await _rotatePlaces(orchardId, me, left, dueOnly: true);
    await _serial(orchardId, () => _refreshOrchard(orchardId, me));
    return left;
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// The owners' roles, highest rank first.
List<String> rolesHighestFirst(OrchardRecord record) =>
    (record.roles.values.toList()..sort((a, b) => b.rank.compareTo(a.rank))).map((r) => r.id).toList();

/// A role.set body for [role] as the record has it, at [rank].
Map<String, Object?> roleBody(RecordRole role, {int? rank}) => {
      'id': role.id,
      'rank': rank ?? role.rank,
      'name_enc': role.nameEnc,
      'name_gen': role.nameGeneration,
      'can': switchList(role.can),
      'crates': {for (final c in role.crates.entries) c.key: switchList(c.value)},
    };

/// The role.set entries that put the owners' roles in [order] (ids, highest
/// first, [moved] among them; it may be a role the record does not have
/// yet, made by [movedBody]). One entry when [moved] fits between its new
/// neighbours; otherwise every role is renumbered, first to ranks no role
/// holds or will hold, so no two roles share a rank at any entry.
List<RecordChange> reorderRoles(
  OrchardRecord record,
  List<String> order,
  String moved,
  Map<String, Object?> Function(int rank) movedBody,
) {
  int rankOf(String id) => record.roles[id]!.rank;
  final at = order.indexOf(moved);
  final above = at == 0 ? maxCustomRank + 1 : rankOf(order[at - 1]);
  final below = at == order.length - 1 ? 0 : rankOf(order[at + 1]);
  if (above - below > 1) {
    return [(type: RecordTypes.roleSet, body: movedBody(below + (above - below) ~/ 2))];
  }
  final n = order.length;
  final step = math.min(1000, maxCustomRank ~/ (n + 1));
  final targets = {for (var i = 0; i < n; i++) order[i]: (n - i) * step};
  final taken = {...record.roles.values.map((r) => r.rank), ...targets.values};
  final spare = <int>[];
  for (var r = maxCustomRank; spare.length < n; r--) {
    if (!taken.contains(r)) spare.add(r);
  }
  return [
    for (var i = 0; i < n; i++)
      if (record.roles.containsKey(order[i]))
        (type: RecordTypes.roleSet, body: roleBody(record.roles[order[i]]!, rank: spare[i])),
    for (final id in order)
      (
        type: RecordTypes.roleSet,
        body: id == moved ? movedBody(targets[id]!) : roleBody(record.roles[id]!, rank: targets[id]),
      ),
  ];
}
