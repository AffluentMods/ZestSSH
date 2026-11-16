import 'dart:ui' show Locale;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';

import 'fake_crate_server.dart';

/// Watched Crates while ZestSSH Cloud cannot be reached, as people are told
/// of it (3.0): those who can open a watched Crate when
/// its owners change who connects there with nobody watching; the owners and
/// those who manage the Crate when a session ran so, with nothing of the
/// host or the reason in the notice; the Changes page's words for all
/// three; and how the service stood, in a few words with its code.

const _owner = 'owner-1';
const _alice = 'alice'; // a member: uses Production
const _cara = 'cara'; // another member
const _sam = 'sam'; // an admin: manages Production
const _bob = 'bob'; // opens nothing

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
  _Device(FakeCrateServer shared, this.uid, AccountKeys keys) : server = shared.as(uid) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
    sync = OrchardSyncCoordinator(service: service, server: server, databases: service.databases);
  }

  final String uid;
  final CrateServer server;
  final storage = _MemoryStorage();
  late final OrchardService service;
  late final OrchardSyncCoordinator sync;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final l10n = lookupAppLocalizations(const Locale('en'));
  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <String, _Device>{};

  setUpAll(() async {
    for (final uid in [_owner, _alice, _cara, _sam, _bob]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in keys.keys) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    for (final d in devices.values) {
      await d.close();
    }
    devices.clear();
  });

  _Device of(String uid) => devices[uid] ??= _Device(server, uid, keys[uid]!);

  /// Acme: alice and cara are members (they use Production), sam is an
  /// admin (manages it), bob's role opens nothing. Lab is a second Crate
  /// the members cannot open. Everyone has looked once, which tells
  /// nothing.
  Future<({String id, String production, String lab})> team() async {
    final owner = of(_owner).service;
    final id = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(id).roles.values.single;
    final production = member.crates.keys.single;
    final guests = await owner.saveRole(id, name: 'Guests', can: const {}, crates: const {});
    for (final (uid, role) in [(_alice, member.id), (_cara, member.id), (_sam, FixedRoles.admin), (_bob, guests)]) {
      await owner.invite(id, email: '$uid@example.com', role: role);
      server.acceptAs(id, (await owner.invites(id)).single.id, uid);
      await owner.confirmInvite(id, (await owner.invites(id)).single);
    }
    final lab = await owner.createCrate(id, 'Lab');
    for (final uid in keys.keys) {
      await of(uid).sync.syncAll();
      expect(await takeTeamNotices(await of(uid).db(id), id), isEmpty, reason: 'the first look only notes how it stands');
    }
    return (id: id, production: production, lab: lab);
  }

  /// What [uid]'s device tells its person now: each notice's id, title and
  /// body.
  Future<List<(String, String, String?)>> told(String uid, String id) async {
    final d = of(uid);
    await d.sync.syncAll();
    final notes = await takeTeamNotifications({id: await d.db(id)},
        me: uid, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard');
    return [for (final n in notes) (n.id, n.title, n.body)];
  }

  int lastSeq(String id) => server.entriesOf(id).last.seq;

  /// [uid]'s device reports a session to [crate]'s host that ran with nobody
  /// watching, and its sync puts the report into the record.
  Future<void> reports(String uid, String id, String crate) async {
    final service = of(uid).service;
    service.unwatchedRan(await service.keepUnwatchedReport(id,
        crateId: crate, hostLabel: 'db-primary', reason: 'restoring the database', reach: 'fault 503'));
    await of(uid).sync.syncAll();
    expect(server.entriesOf(id).last.type, RecordTypes.sessionUnwatched);
  }

  const by = 'owner-1@example.com';
  const orchard = 'The Acme Orchard';

  test('who connects while ZestSSH Cloud cannot be reached, when the owners change it: those who can open a watched '
      'Crate are told, whoever changed it and everyone else are not', () async {
    final t = await team();
    final owner = of(_owner).service;
    final watched = (l10n.noticeWatchedOnTitle('Production'), l10n.noticeWatchedOnBody(by, orchard));
    final everyone = (l10n.noticeUnwatchedAwayOnTitle('Production'), l10n.noticeUnwatchedAwayOnBody(by, orchard));
    final owners = (l10n.noticeUnwatchedAwayOffTitle('Production'), l10n.noticeUnwatchedAwayOffBody(by, orchard));
    expect(everyone.$2, contains('with nobody watching, after giving a reason'));
    expect(everyone.$2, contains('reported to the team'));
    expect(owners.$2, contains('Everyone else waits'));

    // Its sessions are not watched: the choice means nothing there, and
    // nobody is told of it.
    await owner.setCrateUnwatchedAway(t.id, t.production, true);
    for (final uid in [_alice, _cara, _sam, _bob, _owner]) {
      expect(await told(uid, t.id), isEmpty, reason: uid);
    }

    // They become watched with everyone let in already: both are said, each
    // with an id of its own, to those who can open the Crate.
    await owner.setCrateWatched(t.id, t.production, true);
    var seq = lastSeq(t.id);
    for (final uid in [_alice, _cara, _sam]) {
      expect(await told(uid, t.id), [
        ('orchard-notice-${t.id}-$seq-watched', watched.$1, watched.$2),
        ('orchard-notice-${t.id}-$seq-away', everyone.$1, everyone.$2),
      ], reason: uid);
    }
    expect(await told(_bob, t.id), isEmpty, reason: 'the Crate is not his to open');
    expect(await told(_owner, t.id), isEmpty, reason: 'their own change');

    // Owners alone again; said as it stands, nobody is told; and everyone
    // again.
    await owner.setCrateUnwatchedAway(t.id, t.production, false);
    seq = lastSeq(t.id);
    for (final uid in [_alice, _cara, _sam]) {
      expect(await told(uid, t.id), [('orchard-notice-${t.id}-$seq-away', owners.$1, owners.$2)], reason: uid);
    }
    expect(await told(_bob, t.id), isEmpty);
    await owner.setCrateUnwatchedAway(t.id, t.production, false);
    expect(await told(_alice, t.id), isEmpty);
    await owner.setCrateUnwatchedAway(t.id, t.production, true);
    seq = lastSeq(t.id);
    for (final uid in [_alice, _cara, _sam]) {
      expect(await told(uid, t.id), [('orchard-notice-${t.id}-$seq-away', everyone.$1, everyone.$2)], reason: uid);
    }

    // A Crate the members cannot open: sam, who manages it, is told, and
    // they are not. One entry that makes it watched and lets everyone in.
    await owner.change(t.id, RecordTypes.crateSet, {'id': t.lab, 'watched': true, 'allow': <String>[], 'unwatched_away': true});
    seq = lastSeq(t.id);
    expect([for (final n in await told(_sam, t.id)) (n.$1, n.$2)], [
      ('orchard-notice-${t.id}-$seq-watched', l10n.noticeWatchedOnTitle('Lab')),
      ('orchard-notice-${t.id}-$seq-away', l10n.noticeUnwatchedAwayOnTitle('Lab')),
    ]);
    expect(await told(_alice, t.id), isEmpty);

    // Watching ends: that is said, and nothing of who connects without it.
    await owner.setCrateWatched(t.id, t.production, false);
    seq = lastSeq(t.id);
    expect([for (final n in await told(_alice, t.id)) n.$1], ['orchard-notice-${t.id}-$seq-watched']);
    // Changed while it is not watched: nothing again.
    await owner.setCrateUnwatchedAway(t.id, t.production, false);
    expect(await told(_alice, t.id), isEmpty);
  });

  test('a session ran with nobody watching: the owners and those who manage the Crate are told, with nothing of the '
      'host or the reason; whoever reports it, and everyone else who can open the Crate, are not', () async {
    final t = await team();
    final owner = of(_owner).service;
    await owner.setCrateWatched(t.id, t.production, true);
    await owner.setCrateUnwatchedAway(t.id, t.production, true);
    for (final uid in keys.keys) {
      await told(uid, t.id);
    }

    await reports(_alice, t.id, t.production);
    var seq = lastSeq(t.id);
    final said = (
      'orchard-notice-${t.id}-$seq',
      l10n.noticeSessionUnwatchedTitle('Production'),
      l10n.noticeSessionUnwatchedBody('alice@example.com', orchard, l10n.teamPageTrust),
    );
    expect(said.$2, 'A session in Production ran with nobody watching');
    expect(said.$3, contains('alice@example.com connected while ZestSSH Cloud could not be reached'));
    expect(said.$3, contains('in the record of The Acme Orchard, under Trust'));
    expect(await told(_owner, t.id), [said]);
    expect(await told(_sam, t.id), [said], reason: 'an admin manages the Crate');
    expect(await told(_alice, t.id), isEmpty, reason: 'their own report');
    expect(await told(_cara, t.id), isEmpty, reason: 'she opens the Crate and does not answer for it');
    expect(await told(_bob, t.id), isEmpty);
    for (final part in [said.$2, said.$3]) {
      expect(part, isNot(contains('db-primary')));
      expect(part, isNot(contains('restoring')));
    }
    // Told once.
    expect(await told(_owner, t.id), isEmpty);

    // An owner's own report: sam is told, and the owner is not.
    await reports(_owner, t.id, t.production);
    seq = lastSeq(t.id);
    expect(await told(_sam, t.id), [
      (
        'orchard-notice-${t.id}-$seq',
        l10n.noticeSessionUnwatchedTitle('Production'),
        l10n.noticeSessionUnwatchedBody(by, orchard, l10n.teamPageTrust),
      ),
    ]);
    expect(await told(_owner, t.id), isEmpty);

    // The Changes page's words for all of it (the device that sends the
    // team's events on writes the same in English).
    final local = await LocalRecord.load(await of(_owner).db(t.id), t.id);
    final changes = await teamChanges(t.id, local.entries);
    String words(TeamChange c) => teamChangeText(c, l10n,
        nameOf: (uid) => '$uid', crateName: (c) => c == t.production ? 'Production' : 'Lab', roleName: (r) => r);
    expect([
      for (final c in changes)
        if (const {TeamChangeKind.unwatchedAwayOn, TeamChangeKind.unwatchedAwayOff, TeamChangeKind.sessionUnwatched}
            .contains(c.kind))
          (c.by, words(c)),
    ], [
      (_owner, 'Let everyone connect to Production while ZestSSH Cloud cannot be reached'),
      (_alice, 'Connected to a host in Production with nobody watching'),
      (_owner, 'Connected to a host in Production with nobody watching'),
    ]);
    final back = TeamChange(seq: 9, kind: TeamChangeKind.unwatchedAwayOff, by: _owner, byKeyVersion: 1, crateId: t.lab);
    expect(words(back), 'Left Lab to owners while ZestSSH Cloud cannot be reached');
  });

  test('how the service stood, in a few words with its code: each way it can be away, the status of a fault, and '
      'what this app does not know as it was written', () {
    expect(unwatchedReachWords('notResponding', l10n), 'ZestSSH Cloud not responding (ZS-1101)');
    expect(unwatchedReachWords('deviceOffline', l10n), 'Device offline (ZS-1102)');
    expect(unwatchedReachWords('fault 503', l10n), 'ZestSSH Cloud fault, HTTP 503 (ZS-1103)');
    expect(unwatchedReachWords('fault', l10n), 'ZestSSH Cloud fault (ZS-1103)');
    expect(unwatchedReachWords('down', l10n), ErrorCodes.withCode(l10n.cloudChipDown, ErrorCodes.cloudDown));
    expect(unwatchedReachWords('down 502', l10n),
        ErrorCodes.withCode('${l10n.cloudChipDown}, HTTP 502', ErrorCodes.cloudDown));
    expect(unwatchedReachWords('blocked', l10n),
        ErrorCodes.withCode(l10n.cloudChipBlocked, ErrorCodes.cloudBlockedHere));
    expect(unwatchedReachWords('nothingReached', l10n),
        ErrorCodes.withCode(l10n.cloudChipNoInternet, ErrorCodes.cloudNothingReached));
    expect(unwatchedReachWords('notSecure', l10n),
        ErrorCodes.withCode(l10n.cloudChipNotSecure, ErrorCodes.cloudNotSecure));
    // Not a way of being away, or nothing this app knows: as written.
    for (final other in ['answering', 'unknown', 'somethingNew', 'somethingNew 503', '']) {
      expect(unwatchedReachWords(other, l10n), other);
    }

    // In every language: its own few words for each, each with its code,
    // and no two the same.
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      final all = <String>{};
      for (final reach in CloudReach.values) {
        final failure = cloudFailureOfReach(CloudReachState(reach));
        if (failure == null) continue;
        final said = unwatchedReachWords(reach.name, t);
        expect(said, ErrorCodes.withCode(failure.label(t), failure.code), reason: '$locale $reach');
        expect(said, endsWith('(${failure.code.code})'), reason: '$locale $reach');
        expect(failure.label(t).trim(), isNotEmpty, reason: '$locale $reach');
        all.add(said);
      }
      expect(all, hasLength(7), reason: '$locale');
    }
  });

  test('the words in every language: each names what it is about, and no two say the same', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      final said = [
        t.crateUnwatchedAwayOwnersNote,
        t.crateUnwatchedAwayEveryoneNote,
        t.crateUnwatchedAwayTooltip,
        t.crateUnwatchedAwayAllow,
        t.crateUnwatchedAwayOwnersOnly,
        t.stepUpUnwatchedAway('Production'),
        t.noticeUnwatchedAwayOnTitle('Production'),
        t.noticeUnwatchedAwayOnBody('dana@example.com', 'Acme'),
        t.noticeUnwatchedAwayOffTitle('Production'),
        t.noticeUnwatchedAwayOffBody('dana@example.com', 'Acme'),
        t.noticeSessionUnwatchedTitle('Production'),
        t.noticeSessionUnwatchedBody('dana@example.com', 'Acme', t.teamPageTrust),
        t.teamChangeUnwatchedAwayOn('Production'),
        t.teamChangeUnwatchedAwayOff('Production'),
        t.teamChangeSessionUnwatched('Production'),
        t.unwatchedEntryWhen,
        t.unwatchedEntryHost,
        t.unwatchedEntryReason,
        t.unwatchedEntryService,
        t.unwatchedEntrySealed,
      ];
      expect(said.toSet(), hasLength(said.length), reason: '$locale');
      for (final s in said) {
        expect(s.trim(), isNotEmpty, reason: '$locale');
      }
      for (final s in [
        t.stepUpUnwatchedAway('Production'),
        t.noticeUnwatchedAwayOnTitle('Production'),
        t.noticeUnwatchedAwayOffTitle('Production'),
        t.noticeSessionUnwatchedTitle('Production'),
        t.teamChangeUnwatchedAwayOn('Production'),
        t.teamChangeUnwatchedAwayOff('Production'),
        t.teamChangeSessionUnwatched('Production'),
      ]) {
        expect(s, contains('Production'), reason: '$locale: $s');
      }
      for (final s in [
        t.noticeUnwatchedAwayOnBody('dana@example.com', 'Acme'),
        t.noticeUnwatchedAwayOffBody('dana@example.com', 'Acme'),
        t.noticeSessionUnwatchedBody('dana@example.com', 'Acme', t.teamPageTrust),
      ]) {
        expect(s, contains('dana@example.com'), reason: '$locale: $s');
        expect(s, contains('Acme'), reason: '$locale: $s');
      }
      expect(t.noticeSessionUnwatchedBody('dana@example.com', 'Acme', t.teamPageTrust), contains(t.teamPageTrust),
          reason: '$locale');
      // The service is named as everywhere else.
      for (final s in [t.crateUnwatchedAwayOwnersNote, t.crateUnwatchedAwayEveryoneNote, t.crateUnwatchedAwayTooltip]) {
        expect(s, contains('ZestSSH Cloud'), reason: '$locale: $s');
      }
    }
  });
}
