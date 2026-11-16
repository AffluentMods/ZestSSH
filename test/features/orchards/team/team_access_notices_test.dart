import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/generated/app_localizations_en.dart';

import '../fake_crate_server.dart';

/// Access on request (3.0) in words: what a device tells its person
/// (someone asks, a request was declined or lapsed, access is over; a Crate
/// given until a set time and that ended early, which only the member they
/// are about is told), the moment access ends as a notice writes it, and the
/// three changes as the Team page lists them.

const _owner = 'owner-1';
const _alice = 'alice';
const _bob = 'bob';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

class _Device {
  _Device(FakeCrateServer shared, this.uid, this.keys) : server = shared.as(uid) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
    coordinator = OrchardSyncCoordinator(service: service, server: server, databases: service.databases);
  }

  final String uid;
  final AccountKeys keys;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

RecordEntry _entry(String type, Map<String, Object?> body, {String by = 'owner', int seq = 7}) => RecordEntry(
      seq: seq,
      prev: Uint8List(0),
      type: type,
      bodyJson: jsonEncode(body),
      by: by,
      byKeyVersion: 1,
      signature: Uint8List(0),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('the moment access ends, as a notice writes it', () {
    final now = DateTime(2026, 10, 1, 9, 30);
    int seconds(DateTime at) => at.millisecondsSinceEpoch ~/ 1000;

    setUpAll(initializeDateFormatting);

    test('the time alone when it is today, with the day otherwise', () {
      final today = accessTimeText(seconds(DateTime(2026, 10, 1, 15, 45)), l10n, now: now);
      expect(today, contains('3:45'));
      expect(today, contains('PM'));
      expect(today, isNot(contains('Oct')));
      // Today lasts until midnight, and not a minute longer.
      expect(accessTimeText(seconds(DateTime(2026, 10, 1, 23, 59)), l10n, now: now), isNot(contains('Oct')));
      final tomorrow = accessTimeText(seconds(DateTime(2026, 10, 2)), l10n, now: now);
      expect(tomorrow, contains('Oct 2'));
      expect(tomorrow, contains('12:00'));

      // The same day of another month, and of another year, is not today.
      final nextMonth = accessTimeText(seconds(DateTime(2026, 11, 1, 15, 45)), l10n, now: now);
      expect(nextMonth, contains('Nov 1'));
      expect(nextMonth, contains('3:45'));
      expect(accessTimeText(seconds(DateTime(2027, 10, 1, 15, 45)), l10n, now: now), contains('Oct 1'));
      // Without a moment given, today is this device's.
      final soon = DateTime.now().add(const Duration(days: 40));
      expect(accessTimeText(seconds(soon), l10n), accessTimeText(seconds(soon), l10n, now: DateTime.now()));
    });

    test('in the language of the app', () {
      final de = lookupAppLocalizations(const Locale('de'));
      expect(accessTimeText(seconds(DateTime(2026, 10, 1, 15, 45)), de, now: now), '15:45');
      final later = accessTimeText(seconds(DateTime(2026, 10, 3, 15, 45)), de, now: now);
      expect(later, contains('3. Okt'));
      expect(later, contains('15:45'));
    });

    test('a language whose dates are not loaded is written the one way that is always there', () {
      // (Before the first screen no language's dates are loaded; one that
      // is never loaded stands in for that here.)
      final unknown = AppLocalizationsEn('xx');
      expect(unknown.localeName, 'xx');
      final today = accessTimeText(seconds(DateTime(2026, 10, 1, 15, 45)), unknown, now: now);
      expect(today, contains('3:45'));
      expect(today, contains('PM'));
      expect(accessTimeText(seconds(DateTime(2026, 10, 3, 15, 45)), unknown, now: now), contains('Oct 3'));
    });
  });

  group('what is new about access', () {
    final at = DateTime(2026, 10, 1, 9, 30);
    AppNotification told(AccessNotice notice, {DateTime? now, String orchardId = 'o-1'}) => accessNoticeNotification(
          notice,
          orchardId: orchardId,
          orchard: 'Acme Orchard',
          nameOf: (uid) => uid == null ? '' : '$uid@example.com',
          l10n: l10n,
          now: now ?? at,
        );

    test('in words: someone asks, declined, not answered, over', () {
      (String, String?) words(AccessNotice n) {
        final shown = told(n);
        return (shown.title, shown.body);
      }

      expect(words(const AccessNotice(AccessNoticeKind.asked, uid: 'alice')),
          (l10n.noticeAccessAskedTitle('Acme Orchard'), l10n.noticeAccessAskedBody('alice@example.com')));
      // Several people: how many, and no name.
      expect(words(const AccessNotice(AccessNoticeKind.asked, count: 3)),
          (l10n.noticeAccessAskedTitle('Acme Orchard'), l10n.noticeAccessAskedManyBody(3)));
      // Several from one person: named.
      expect(words(const AccessNotice(AccessNoticeKind.asked, uid: 'alice', count: 2)).$2,
          l10n.noticeAccessAskedBody('alice@example.com'));
      expect(words(const AccessNotice(AccessNoticeKind.declined)),
          (l10n.noticeAccessDeclinedTitle('Acme Orchard'), l10n.noticeAccessDeclinedBody));
      expect(words(const AccessNotice(AccessNoticeKind.lapsed)),
          (l10n.noticeAccessLapsedTitle('Acme Orchard'), l10n.noticeAccessLapsedBody));
      expect(words(const AccessNotice(AccessNoticeKind.over, crateId: 'c-1', crateName: 'Staging')),
          (l10n.noticeAccessOverTitle('Acme Orchard'), l10n.noticeAccessOverBody('Staging')));
      // A Crate this device never had a name for.
      expect(words(const AccessNotice(AccessNoticeKind.over, crateId: 'c-1')),
          (l10n.noticeAccessOverTitle('Acme Orchard'), l10n.noticeAccessOverBodyUnnamed));

      // The sentences themselves, once.
      expect(l10n.noticeAccessAskedTitle('Acme Orchard'), 'Someone asks for access in Acme Orchard');
      expect(l10n.noticeAccessOverBody('Staging'),
          'Staging was given to you for a set time, which has ended. It left this device.');
    });

    test('each stays in the bell until read, and is one of its own', () {
      const kinds = [
        AccessNotice(AccessNoticeKind.asked, uid: 'alice'),
        AccessNotice(AccessNoticeKind.declined),
        AccessNotice(AccessNoticeKind.lapsed),
        AccessNotice(AccessNoticeKind.over, crateId: 'c-1', crateName: 'Staging'),
      ];
      for (final n in kinds) {
        expect(told(n).severity, NotificationSeverity.warning, reason: '${n.kind}');
        expect(told(n).createdAt, at);
      }
      final ids = {
        for (final n in kinds) told(n).id,
        // Another Crate, another Orchard, another moment.
        told(const AccessNotice(AccessNoticeKind.over, crateId: 'c-2', crateName: 'Staging')).id,
        told(const AccessNotice(AccessNoticeKind.declined), orchardId: 'o-2').id,
        told(const AccessNotice(AccessNoticeKind.declined), now: at.add(const Duration(microseconds: 1))).id,
      };
      expect(ids, hasLength(7), reason: 'none replaces another in the bell');
      expect(told(kinds[1]).id, told(kinds[1]).id, reason: 'the same notice is the same one');
    });
  });

  group('the record entry as a notice', () {
    test('given, with when it ends, and ended early: each about one member', () {
      final given = teamNoticeOf(_entry(RecordTypes.accessGrant,
          {'uid': 'sam', 'crate': 'prod', 'switches': ['connect'], 'until': 1800000000}))!;
      expect((given.kind, given.seq, given.by, given.member, given.crateId, given.until),
          (TeamNoticeKind.accessGiven, 7, 'owner', 'sam', 'prod', 1800000000));
      expect(given.forMemberOnly, isTrue);
      final ended = teamNoticeOf(_entry(RecordTypes.accessGrant, {'uid': 'sam', 'crate': 'prod', 'until': 0}))!;
      expect((ended.kind, ended.member, ended.crateId, ended.until), (TeamNoticeKind.accessEnded, 'sam', 'prod', null));
      expect(ended.forMemberOnly, isTrue);
      // What every member is told is not for one member only.
      expect(teamNoticeOf(_entry(RecordTypes.recoverySet, {'on': true}))!.forMemberOnly, isFalse);
      expect(teamNoticeOf(_entry(RecordTypes.crateSet, {'id': 'prod', 'session_logs': true}))!.forMemberOnly, isFalse);
    });

    test('an entry that does not say who, which Crate or until when is no notice', () {
      expect(teamNoticeOf(_entry(RecordTypes.accessGrant, {'crate': 'prod', 'until': 1800000000})), isNull);
      expect(teamNoticeOf(_entry(RecordTypes.accessGrant, {'uid': 'sam', 'until': 1800000000})), isNull);
      expect(teamNoticeOf(_entry(RecordTypes.accessGrant, {'uid': 'sam', 'crate': 'prod'})), isNull);
      expect(teamNoticeOf(_entry(RecordTypes.accessGrant, {'uid': 'sam', 'crate': 'prod', 'until': '0'})), isNull);
      expect(teamNoticeOf(_entry(RecordTypes.accessGrant, {'uid': 7, 'crate': 'prod', 'until': 0})), isNull);
    });
  });

  group('on the Team page', () {
    test('the three changes in words', () {
      String words(TeamChangeKind kind) => teamChangeText(
            TeamChange(seq: 7, kind: kind, by: 'owner', byKeyVersion: 1, member: 'sam', crateId: 'prod'),
            l10n,
            nameOf: (uid) => '$uid@example.com',
            crateName: (id) => 'the $id Crate',
            roleName: (id) => id,
          );
      expect(words(TeamChangeKind.accessGiven), l10n.teamChangeAccessGiven('sam@example.com', 'the prod Crate'));
      expect(words(TeamChangeKind.accessEnded), l10n.teamChangeAccessEnded('sam@example.com', 'the prod Crate'));
      expect(words(TeamChangeKind.accessGivenUp), l10n.teamChangeAccessGivenUp('the prod Crate'));
      expect(l10n.teamChangeAccessGivenUp('Staging'), 'Gave up their access to Staging');
      expect(l10n.teamChangeAccessEnded('sam@example.com', 'Staging'), "Ended sam@example.com's access to Staging early");
    });
  });

  group('told to the member it is about, and nobody else', () {
    final keys = <String, AccountKeys>{};
    late FakeCrateServer server;
    final devices = <_Device>[];

    setUpAll(() async {
      await initializeDateFormatting();
      for (final uid in [_owner, _alice, _bob]) {
        keys[uid] = await AccountKeys.generate();
      }
    });

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      server = FakeCrateServer(accountUid: _owner);
      for (final uid in [_owner, _alice, _bob]) {
        await server.publish(uid, keys[uid]!, email: '$uid@example.com');
      }
    });

    tearDown(() async {
      for (final d in devices) {
        await d.close();
      }
      devices.clear();
    });

    _Device device(String uid) {
      final d = _Device(server, uid, keys[uid]!);
      devices.add(d);
      return d;
    }

    test('a Crate given until a set time, more in one, and both ended early', () async {
      final owner = device(_owner);
      final alice = device(_alice);
      final bob = device(_bob);
      final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final staging = await owner.service.createCrate(id, 'Staging');
      final member = server.recordOf(id).roles.values.single;
      final production = member.crates.keys.single;
      for (final person in [_alice, _bob]) {
        await owner.service.invite(id, email: '$person@example.com', role: member.id);
        server.acceptAs(id, (await owner.service.invites(id)).single.id, person);
        await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
      }

      Future<List<(String, String?)>> told(_Device d) async {
        await d.coordinator.syncAll();
        final notes = await takeTeamNotifications({id: await d.db(id)},
            me: d.uid, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard');
        return [for (final n in notes) (n.title, n.body)];
      }

      for (final d in [owner, alice, bob]) {
        expect(await told(d), isEmpty, reason: 'the first look only notes where things stand');
      }
      int until(String crateId) => server.recordOf(id).members[_alice]!.timed[crateId]!.until;

      // A Crate she does not open: named, with when it ends.
      await owner.service
          .giveAccess(id, uid: _alice, crateId: staging, level: CrateLevel.use, duration: const Duration(hours: 2));
      expect(await told(alice), [
        (
          l10n.noticeAccessGivenTitle('The Acme Orchard'),
          l10n.noticeAccessGivenBody('owner-1@example.com', 'Staging', accessTimeText(until(staging), l10n)),
        ),
      ]);
      expect(await told(bob), isEmpty, reason: 'not about him, though he is a member like her');
      expect(await told(owner), isEmpty, reason: 'its own change');
      expect(await told(alice), isEmpty, reason: 'told once');

      // More in one she opens: told the same way.
      await owner.service
          .giveAccess(id, uid: _alice, crateId: production, level: CrateLevel.edit, duration: const Duration(days: 3));
      expect(await told(alice), [
        (
          l10n.noticeAccessGivenTitle('The Acme Orchard'),
          l10n.noticeAccessGivenBody('owner-1@example.com', 'Production', accessTimeText(until(production), l10n)),
        ),
      ]);
      expect(await told(bob), isEmpty, reason: 'he opens that Crate too, and it is still not about him');

      // Both ended early by the owner: one notice each, saying who.
      await owner.service.endAccess(id, uid: _alice, crateId: staging);
      await owner.service.endAccess(id, uid: _alice, crateId: production);
      final ended = (l10n.noticeAccessEndedTitle('The Acme Orchard'), l10n.noticeAccessEndedBody('owner-1@example.com'));
      expect(await told(alice), [ended, ended]);
      expect(await told(bob), isEmpty);
      expect(await told(owner), isEmpty);
    });

    // Vault access per member: "Your access to Production is now
    // Connect (set by Sam)", to the member alone; a vault taken away is named
    // as it was, after it left the device.
    test('a vault set apart from their role, taken away and put back: the member alone is told, the vault named',
        () async {
      final owner = device(_owner);
      final alice = device(_alice);
      final bob = device(_bob);
      final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final member = server.recordOf(id).roles.values.single;
      final production = member.crates.keys.single;
      for (final person in [_alice, _bob]) {
        await owner.service.invite(id, email: '$person@example.com', role: member.id);
        server.acceptAs(id, (await owner.service.invites(id)).single.id, person);
        await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
      }

      Future<List<(String, String?)>> told(_Device d) async {
        await d.coordinator.syncAll();
        final notes = await takeTeamNotifications({id: await d.db(id)},
            me: d.uid, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard');
        return [for (final n in notes) (n.title, n.body)];
      }

      Future<Set<String>> held(_Device d) async => {
            for (final r in await (await d.db(id)).customSelect('SELECT crate_id FROM orchard_crates').get())
              r.read<String>('crate_id'),
          };

      for (final d in [owner, alice, bob]) {
        expect(await told(d), isEmpty, reason: 'the first look only notes where things stand');
      }
      final title = l10n.noticeVaultAccessTitle('The Acme Orchard');

      await owner.service.setVaultAccess(id, _alice, {production: VaultPick.connect});
      expect(await told(alice), [
        (title, l10n.noticeVaultSetBody('Production', l10n.crateLevelConnect, 'owner-1@example.com')),
      ]);
      expect(await told(bob), isEmpty, reason: 'not about him, though he opens the vault too');
      expect(await told(owner), isEmpty, reason: 'its own change');

      await owner.service.setVaultAccess(id, _alice, {production: VaultPick.none});
      expect(await told(alice), [(title, l10n.noticeVaultTakenBody('owner-1@example.com', 'Production'))]);
      expect(await held(alice), isNot(contains(production)), reason: 'the vault left her device');
      expect(await told(bob), isEmpty);

      await owner.service.setVaultAccess(id, _alice, {production: VaultPick.fromRole});
      expect(await told(alice), [(title, l10n.noticeVaultBackBody('owner-1@example.com', 'Production'))]);
      expect(await held(alice), contains(production), reason: 'back with her role');
    });

    test('what the member gives up is told to nobody; given and ended before they looked is told all the same',
        () async {
      final owner = device(_owner);
      final alice = device(_alice);
      final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final staging = await owner.service.createCrate(id, 'Staging');
      final member = server.recordOf(id).roles.values.single;
      await owner.service.invite(id, email: 'alice@example.com', role: member.id);
      server.acceptAs(id, (await owner.service.invites(id)).single.id, _alice);
      await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);

      Future<List<(String, String?)>> told(_Device d) async {
        await d.coordinator.syncAll();
        final notes = await takeTeamNotifications({id: await d.db(id)},
            me: d.uid, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard');
        return [for (final n in notes) (n.title, n.body)];
      }

      expect(await told(alice), isEmpty);
      expect(await told(owner), isEmpty);
      await owner.service
          .giveAccess(id, uid: _alice, crateId: staging, level: CrateLevel.use, duration: const Duration(hours: 2));
      expect(await told(alice), hasLength(1));
      await alice.service.endAccess(id, uid: _alice, crateId: staging);
      expect(await told(alice), isEmpty, reason: 'her own doing');
      expect(await told(owner), isEmpty, reason: 'the Team page lists it; nobody is rung for it');

      // Given and taken back while her device was away: she hears of both.
      // This time the vault never arrived, and it is named as her device
      // knew it when it last left (the app keeps the names of vaults that
      // leave a device for its notices).
      await owner.service
          .giveAccess(id, uid: _alice, crateId: staging, level: CrateLevel.use, duration: const Duration(hours: 2));
      final until = server.recordOf(id).members[_alice]!.timed[staging]!.until;
      await owner.service.endAccess(id, uid: _alice, crateId: staging);
      expect(await told(alice), [
        (
          l10n.noticeAccessGivenTitle('The Acme Orchard'),
          l10n.noticeAccessGivenBody('owner-1@example.com', 'Staging', accessTimeText(until, l10n)),
        ),
        (l10n.noticeAccessEndedTitle('The Acme Orchard'), l10n.noticeAccessEndedBody('owner-1@example.com')),
      ]);
    });
  });
}
