import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/teams/account_key_service.dart';

import '../../helpers/contract_run.dart';

/// An Orchard's rules against the REAL server routes (ZestSSH Cloud's
/// routes/orchards.js, routes/invites.js and lib/orchard_rules.js) on a real
/// Postgres (3.0): a member without two-step sign-in is held back
/// (their device keeps what it has and syncs nothing) and let back in once
/// they sign in with it; an owner cannot set rules they do not meet, and
/// changes to who may do what want a recent sign-in; an invitation says what
/// is missing, accepting waits for it, and a confirmation checks how they
/// signed in when they accepted; an address outside the Orchard's domains is
/// held back with the domains named and cannot be invited; and a device past
/// the offline limit keeps the Orchard closed until it reaches the server.
/// Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1).

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

/// Orchard databases in files, opened afresh each time as on a real device
/// (an in-memory one is gone once it closes, as the offline limit does).
class _FileStorage extends _MemoryStorage {
  _FileStorage(this.dir);

  final Directory dir;

  File _file(String orchardId) => File('${dir.path}${Platform.pathSeparator}$orchardId.db');

  @override
  Future<bool> exists(String orchardId) async => _file(orchardId).exists();

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] = AppDatabase.forTesting(NativeDatabase(_file(orchardId)), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async {
    dbs.remove(orchardId);
    if (await _file(orchardId).exists()) await _file(orchardId).delete();
  }
}

/// How an account signs in: with a second factor, how long ago, and at
/// which domain its address is.
class _SignIn {
  bool secondFactor = false;
  int? at;
  String domain = 'example.com';
}

/// An account and one device of its.
class _Account {
  _Account(this.uid, this.signIn, this.service, this.sync, this.server, this.databases, this.author);

  final String uid;
  final _SignIn signIn;
  final OrchardService service;
  final OrchardSyncCoordinator sync;
  final OrchardsApi server;
  final OrchardDatabasesNotifier databases;

  /// The account's keys, for an entry a test signs by hand.
  final Future<CrateAuthor?> Function() author;

  String get email => '$uid@${signIn.domain}';

  Future<OrchardSummary> summary(String orchardId) async =>
      readOrchardSummary(await databases.open(orchardId), orchardId);
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  final opened = <_MemoryStorage>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/orchards')).timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final s in opened) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    opened.clear();
  });

  var made = 0;

  Future<_Account> account(String name, {bool secondFactor = false, _MemoryStorage? storage}) async {
    final uid = 'rules-$name-$contractRun-${made++}';
    final signIn = _SignIn()..secondFactor = secondFactor;
    // "fb:<uid>:<authTime>:<iat>:<2fa>:<domain>", as the contract server reads it.
    Future<String> token() async =>
        'fb:$uid:${signIn.at ?? now()}:${now()}:${signIn.secondFactor ? '2fa' : '-'}:${signIn.domain}';
    final keyService = AccountKeyService(
      api: AccountKeysApi(client: client, baseUrl: base, bearer: token),
      store: AccountKeyStore(const FlutterSecureStorage()),
      onKeysChanged: () {},
    );
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: token);
    storage ??= _MemoryStorage();
    opened.add(storage);
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    Future<CrateAuthor?> author() async {
      final ready = await keyService.readyKeys();
      return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
    }

    final service = OrchardService(
      server: server,
      databases: databases,
      author: author,
      onContact: databases.reopenOffline,
    );
    final sync = OrchardSyncCoordinator(service: service, server: server, databases: databases);
    return _Account(uid, signIn, service, sync, server, databases, author);
  }

  Future<String> orchard(_Account owner) =>
      owner.service.createOrchard('Rules', firstCrateName: 'Production', memberRoleName: 'Member');

  Future<void> join(_Account by, _Account person, String orchardId) async {
    final role = (await by.service.roles(orchardId)).single.id;
    await by.service.invite(orchardId, email: person.email, role: role);
    await person.service.acceptInvite((await person.service.myInvites()).single.id);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
  }

  Matcher refused(String code) => throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', code));

  test('a member without two-step sign-in is held back, keeps what they have, and is let back in', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner', secondFactor: true);
    final alice = await account('alice');
    final id = await orchard(owner);
    await join(owner, alice, id);
    expect(await alice.service.refresh(), contains(id));
    final crates = (await alice.summary(id)).crates.map((c) => c.id).toList();

    await owner.service.setRules(id, const RecordRules(require2fa: true));
    expect(await alice.service.refresh(), isNot(contains(id)));
    final held = await alice.summary(id);
    expect(held.status, 'rules');
    expect(held.rulesUnmet, ['two_step']);
    expect(held.crates.map((c) => c.id), crates, reason: 'what is on the device stays');
    expect((await alice.sync.syncOne(id)).held, isTrue);
    await expectLater(alice.server.record(id, after: 0), refused('rules-unmet'));

    alice.signIn.secondFactor = true;
    expect(await alice.service.refresh(), contains(id));
    expect((await alice.summary(id)).status, 'active');
    expect((await alice.sync.syncOne(id)).held, isFalse);
  });

  test('an owner cannot set rules they do not meet; changes want a recent sign-in; an owner held back relaxes them',
      () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final id = await orchard(owner);
    await expectLater(owner.service.setRules(id, const RecordRules(require2fa: true)), refused('rules-unmet-by-you'));

    owner.signIn.secondFactor = true;
    await owner.service.setRules(id, const RecordRules(require2fa: true, noExport: true));
    owner.signIn.at = now() - 3 * 3600;
    final production = (await owner.summary(id)).crates.single.id;
    await expectLater(owner.service.setCrateConfirmReveal(id, production, true), refused('recent-sign-in-required'));

    // Turned two-step sign-in off: held back, and still able to relax the rules.
    owner.signIn
      ..secondFactor = false
      ..at = null;
    expect(await owner.service.refresh(), isNot(contains(id)));
    expect((await owner.summary(id)).rulesUnmet, ['two_step']);
    await owner.service.setRules(id, const RecordRules(noExport: true));
    expect(await owner.service.refresh(), contains(id));
    final summary = await owner.summary(id);
    expect((summary.status, summary.rules.noExport, summary.rules.require2fa), ('active', true, false));
  });

  test(
      "a Crate's own offline limit: the server takes it from an owner, refuses it from anyone else in the record's "
      'words, and wants a recent sign-in', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final id = await orchard(owner);
    await join(owner, alice, id);
    expect(await alice.service.refresh(), contains(id));
    final production = (await owner.summary(id)).crates.single.id;
    // The record as the server has it, checked entry by entry on the way.
    Future<OrchardRecord> onServer(_Account who) async =>
        OrchardRecord.replay(id, (await who.server.record(id, after: 0)).entries);
    // As a device reads the limit: from its own copy of the record.
    Future<int> limitOn(_Account who) async =>
        (await latestRecordIn(await who.databases.open(id)))!.crates[production]!.offlineHours;
    expect((await onServer(owner)).crates[production]!.offlineHours, 0);

    await owner.service.setCrateOfflineLimit(id, production, 24);
    expect((await onServer(owner)).crates[production]!.offlineHours, 24);
    expect((await onServer(owner)).rules.offlineHours, 0, reason: "the Crate's, not a rule of the Orchard");
    expect(await limitOn(alice), 0, reason: 'a device knows of it once it has synced');
    await alice.service.refresh();
    expect(await limitOn(alice), 24);

    // Sent past the device's own check, the server refuses what the record
    // refuses, in the record's words: a member's entry, and an owner's that
    // is longer than a year.
    Future<void> sentByHand(_Account who, int hours, String reason) async {
      final record = await onServer(who);
      final me = (await who.author())!;
      final entry = await signRecordEntry(me.keys,
          orchardId: id,
          seq: record.seq + 1,
          prev: record.head,
          type: RecordTypes.crateSet,
          body: {'id': production, 'offline_hours': hours},
          by: me.uid);
      await expectLater(
          who.server.appendRecord(id, [entry]),
          throwsA(isA<OrchardServerException>()
              .having((e) => e.code, 'code', 'record-refused')
              .having((e) => e.reason, 'reason', reason)));
    }

    await sentByHand(alice, 0, "only owners set a Crate's offline limit");
    await sentByHand(alice, 72, "only owners set a Crate's offline limit");
    await sentByHand(owner, 8761, 'rule out of range');
    expect((await onServer(owner)).crates[production]!.offlineHours, 24);

    // It keeps people out of a Crate or lets them back in: not without a
    // recent sign-in, either way.
    owner.signIn.at = now() - 3 * 3600;
    await expectLater(owner.service.setCrateOfflineLimit(id, production, 0), refused('recent-sign-in-required'));
    await expectLater(owner.service.setCrateOfflineLimit(id, production, 1), refused('recent-sign-in-required'));
    expect((await onServer(owner)).crates[production]!.offlineHours, 24);
    owner.signIn.at = null;
    await owner.service.setCrateOfflineLimit(id, production, 0);
    expect((await onServer(owner)).crates[production]!.offlineHours, 0);
    await alice.service.refresh();
    expect(await limitOn(alice), 0);
  });

  test(
      'watched Crates while ZestSSH Cloud cannot be reached: the server takes who else may from an owner, with a '
      "recent sign-in, and a report of a session from any member's device, with none", () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final id = await orchard(owner);
    await join(owner, alice, id);
    expect(await alice.service.refresh(), contains(id));
    final production = (await owner.summary(id)).crates.single.id;
    // The record as the server has it, checked entry by entry on the way.
    Future<OrchardRecord> onServer(_Account who) async =>
        OrchardRecord.replay(id, (await who.server.record(id, after: 0)).entries);
    // As a device reads the setting: from its own copy of the record.
    Future<bool> awayOn(_Account who) async =>
        (await latestRecordIn(await who.databases.open(id)))!.crates[production]!.unwatchedAway;
    expect((await onServer(owner)).crates[production]!.unwatchedAway, isFalse);

    await owner.service.setCrateUnwatchedAway(id, production, true);
    expect((await onServer(owner)).crates[production]!.unwatchedAway, isTrue);
    expect(await awayOn(alice), isFalse, reason: 'a device knows of it once it has synced');
    await alice.service.refresh();
    expect(await awayOn(alice), isTrue);

    // Sent past the device's own check, the server refuses what the record
    // refuses, in the record's words.
    Future<void> sentByHand(_Account who, String type, Map<String, Object?> body, String reason) async {
      final record = await onServer(who);
      final me = (await who.author())!;
      final entry = await signRecordEntry(me.keys,
          orchardId: id, seq: record.seq + 1, prev: record.head, type: type, body: body, by: me.uid);
      await expectLater(
          who.server.appendRecord(id, [entry]),
          throwsA(isA<OrchardServerException>()
              .having((e) => e.code, 'code', 'record-refused')
              .having((e) => e.reason, 'reason', reason)));
    }

    await sentByHand(alice, RecordTypes.crateSet, {'id': production, 'unwatched_away': false},
        'only owners set watched sessions');

    // It changes who may connect without anyone watching: not without a
    // recent sign-in, either way.
    owner.signIn.at = now() - 3 * 3600;
    await expectLater(owner.service.setCrateUnwatchedAway(id, production, false), refused('recent-sign-in-required'));
    expect((await onServer(owner)).crates[production]!.unwatchedAway, isTrue);
    owner.signIn.at = null;

    // A report of a session: from a member whose sign-in is an hour old (the
    // device sends it by itself when it is back), into the record as it was
    // written, and read by the owner's device with its next sync.
    final before = (await onServer(owner)).seq;
    final report = {
      'crate': production,
      'at': now() - 1800,
      'gen': 1,
      'sealed': base64Encode(List<int>.filled(120, 9)),
    };
    alice.signIn.at = now() - 3 * 3600;
    await alice.service.change(id, RecordTypes.sessionUnwatched, report);
    alice.signIn.at = null;
    final entries = (await owner.server.record(id, after: before)).entries;
    expect(entries.map((e) => (e.type, e.by)), [(RecordTypes.sessionUnwatched, alice.uid)]);
    expect(entries.single.body, report);
    await owner.service.refresh();
    expect((await latestRecordIn(await owner.databases.open(id)))!.seq, before + 1);
    // And what is no report is refused in the record's words.
    await sentByHand(alice, RecordTypes.sessionUnwatched, {...report, 'gen': 2}, 'malformed gen');
    await sentByHand(alice, RecordTypes.sessionUnwatched, {...report, 'host': 'web-01'}, 'malformed session');
    await sentByHand(alice, RecordTypes.sessionUnwatched, {...report, 'sealed': 'AB=='}, 'malformed sealed');
    expect((await onServer(owner)).seq, before + 1);
    expect((await onServer(owner)).crates[production]!.unwatchedAway, isTrue);
  });

  test('joining: the invitation names what is missing, accepting waits for it, confirming checks the acceptance',
      () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner', secondFactor: true);
    final carol = await account('carol');
    final dave = await account('dave');
    final id = await orchard(owner);
    final role = (await owner.service.roles(id)).single.id;

    // Dave accepts before there are rules.
    await owner.service.invite(id, email: dave.email, role: role);
    await dave.service.acceptInvite((await dave.service.myInvites()).single.id);
    await owner.service.setRules(id, const RecordRules(require2fa: true));

    await owner.service.invite(id, email: carol.email, role: role);
    final offer = (await carol.service.myInvites()).single;
    expect(offer.rulesUnmet, ['two_step']);
    await expectLater(carol.service.acceptInvite(offer.id), refused('rules-unmet'));
    carol.signIn.secondFactor = true;
    expect((await carol.service.myInvites()).single.rulesUnmet, isEmpty);
    await carol.service.acceptInvite(offer.id);

    final invites = await owner.service.invites(id);
    final daves = invites.firstWhere((i) => i.email == dave.email);
    expect(daves.acceptedRulesUnmet, ['two_step']);
    expect(invites.firstWhere((i) => i.email == carol.email).acceptedRulesUnmet, isEmpty);
    await expectLater(owner.service.confirmInvite(id, daves), refused('invitee-rules-unmet'));
    await owner.service.confirmInvite(id, invites.firstWhere((i) => i.email == carol.email));
    expect(await carol.service.refresh(), contains(id));

    dave.signIn.secondFactor = true;
    await dave.service.acceptInvite((await dave.service.myInvites()).single.id);
    await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
    expect(await dave.service.refresh(), contains(id));
  });

  test('an address outside the domains is held back with the domains named, and cannot be invited', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner')
      ..signIn.domain = 'corp.example';
    final erin = await account('erin');
    final id = await orchard(owner);
    await join(owner, erin, id);
    await owner.service.setRules(id, const RecordRules(emailDomains: {'corp.example'}));

    expect(await erin.service.refresh(), isNot(contains(id)));
    final held = await erin.summary(id);
    expect(held.rulesUnmet, ['email_domain']);
    expect(held.ruleDomains, ['corp.example']);
    final role = (await owner.service.roles(id)).single.id;
    await expectLater(owner.service.invite(id, email: 'frank@example.com', role: role), refused('invitee-rules-unmet'));
  });

  test('members outside new domains: kept as guests, in one step with the rules, removed, or held back; as the server decides it', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner')
      ..signIn.domain = 'corp.example';
    final kept = await account('kept');
    final gone = await account('gone');
    final held = await account('held');
    final id = await orchard(owner);
    await join(owner, kept, id);
    await join(owner, gone, id);
    await join(owner, held, id);
    await owner.service.refresh();

    // What the app says of them, before anything changes.
    var outside = outsideDomainsOf(await owner.service.people(id), {'corp.example'});
    expect({for (final p in outside.held) p.uid}, {kept.uid, gone.uid, held.uid});
    expect(outside.guests, isEmpty);

    final until = now() + 30 * 24 * 3600;
    await owner.service.settleOutsideDomains(id,
        rules: const RecordRules(emailDomains: {'corp.example'}), guests: {kept.uid: until}, remove: {gone.uid});

    // The guest is let in; the one left alone is held back, the domains named.
    expect(await kept.service.refresh(), contains(id));
    expect((await kept.summary(id)).rulesUnmet, isEmpty);
    expect(await held.service.refresh(), isNot(contains(id)));
    expect((await held.summary(id)).rulesUnmet, ['email_domain']);
    expect((await held.summary(id)).ruleDomains, ['corp.example']);
    // Who was removed is out.
    expect(await gone.service.refresh(), isNot(contains(id)));

    // What the member list marks is what the server does.
    await owner.service.refresh();
    final people = await owner.service.people(id);
    outside = outsideDomainsOf(people, {'corp.example'});
    expect([for (final p in outside.held) p.uid], [held.uid]);
    expect([for (final p in outside.guests) p.uid], [kept.uid]);
    expect(outside.unseen, isEmpty, reason: 'an owner gave that date');
    final guest = people.members.singleWhere((p) => p.uid == kept.uid);
    expect(domainRuleHolds({'corp.example'}, guest.email, endsAt: guest.endsAt), isFalse);
    final notYet = people.members.singleWhere((p) => p.uid == held.uid);
    expect(domainRuleHolds({'corp.example'}, notYet.email, endsAt: notYet.endsAt), isTrue);

    // A guest's end date is moved; taken away, they are held back with the
    // rest. The one held back is let in by one.
    await owner.service.setMemberEndsAt(id, kept.uid, until + 3600);
    await owner.service.settleOutsideDomains(id, clear: {kept.uid});
    expect(await kept.service.refresh(), isNot(contains(id)));
    expect((await kept.summary(id)).rulesUnmet, ['email_domain']);
    await owner.service.setMemberEndsAt(id, kept.uid, until);
    expect(await kept.service.refresh(), contains(id));
    await owner.service.setMemberEndsAt(id, held.uid, until);
    expect(await held.service.refresh(), contains(id));

    // What the app takes for too far is what the server does: a second either side.
    final limit = now() + kMemberEndMaxSeconds;
    await expectLater(owner.service.setMemberEndsAt(id, kept.uid, limit + 3600), refused('end-too-far'));
    await owner.service.setMemberEndsAt(id, kept.uid, limit - 3600);
    await expectLater(owner.service.invite(id, email: 'kay@corp.example', role: (await owner.service.roles(id)).single.id, endsAt: limit + 3600),
        refused('end-too-far'));
  });

  test('an owner short of the rules in force takes one off, sets a list and keeps someone as a guest, all at once', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner', secondFactor: true)
      ..signIn.domain = 'corp.example';
    final sam = await account('sam');
    final id = await orchard(owner);
    await join(owner, sam, id);
    await owner.service.setRules(id, const RecordRules(require2fa: true));

    // Another day, signed in without it: held back by the rule.
    owner.signIn.secondFactor = false;
    await owner.service.refresh();
    expect((await owner.summary(id)).rulesUnmet, ['two_step']);

    final until = now() + 30 * 24 * 3600;
    await owner.service.settleOutsideDomains(id, rules: const RecordRules(emailDomains: {'corp.example'}), guests: {sam.uid: until});

    await owner.service.refresh();
    expect((await owner.summary(id)).rulesUnmet, isEmpty);
    final people = await owner.service.people(id);
    expect(people.members.singleWhere((p) => p.uid == sam.uid).endsAt, until);
    expect(await sam.service.refresh(), contains(id));
  });

  test('an end date someone below an owner gave, before there was a rule: it still lets them in, an owner is shown it, and only an owner moves it', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner')
      ..signIn.domain = 'corp.example';
    final admin = await account('admin')
      ..signIn.domain = 'corp.example';
    final dated = await account('dated');
    final id = await orchard(owner);
    await join(owner, admin, id);
    await join(owner, dated, id);
    await owner.service.refresh();
    await owner.service.setMemberRole(id, admin.uid, FixedRoles.admin);
    await admin.service.refresh();

    // The admin dates them, with no rule in force.
    final until = now() + 30 * 24 * 3600;
    await admin.service.setMemberEndsAt(id, dated.uid, until);
    await owner.service.refresh();
    var outside = outsideDomainsOf(await owner.service.people(id), {'corp.example'});
    expect([for (final p in outside.guests) p.uid], [dated.uid]);
    expect([for (final p in outside.unseen) p.uid], [dated.uid]);
    expect(outside.isEmpty, isFalse, reason: 'the dialog opens though nobody is held back');

    // The rules go in and they stay in: as the server decides it.
    await owner.service.setRules(id, const RecordRules(emailDomains: {'corp.example'}));
    expect(await dated.service.refresh(), contains(id));
    await admin.service.refresh();
    await expectLater(admin.service.setMemberEndsAt(id, dated.uid, until + 3600), refused('guest-owners-only'));
    await expectLater(admin.service.setMemberEndsAt(id, dated.uid, null), refused('guest-owners-only'));

    // An owner keeps the date as it is: Members has nothing more to ask.
    await owner.service.settleOutsideDomains(id, guests: {dated.uid: until});
    await owner.service.refresh();
    final people = await owner.service.people(id);
    outside = outsideDomainsOf(people, {'corp.example'});
    expect([for (final p in outside.guests) p.uid], [dated.uid]);
    expect(outside.unseen, isEmpty);
    expect(people.members.singleWhere((p) => p.uid == dated.uid).endsAt, until);
    expect(await dated.service.refresh(), contains(id));
  });

  test('past the offline limit the Orchard stays closed on the device until it reaches the server', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final dir = await Directory.systemTemp.createTemp('zest-offline-contract-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {/* Windows may hold a file a moment */}
    });
    final owner = await account('owner');
    final alice = await account('alice', storage: _FileStorage(dir));
    final id = await orchard(owner);
    await join(owner, alice, id);
    await owner.service.setRules(id, const RecordRules(offlineHours: 1));
    await alice.service.refresh();
    final rules = (await alice.summary(id)).rules;
    expect(rules.offlineHours, 1);

    // Last reached two hours ago: closed.
    final t = now();
    expect(offlineLimitReached(rules, OrchardContact(lastContact: t - 7200, latest: t), t), isTrue);
    expect(offlineLimitReached(rules, OrchardContact(lastContact: t - 60, latest: t), t), isFalse);
    await alice.databases.closeOffline(id);
    await expectLater(alice.databases.open(id), throwsA(isA<OrchardClosedOffline>()));
    // Reaching the server opens it again.
    expect(await alice.service.refresh(), contains(id));
    expect(alice.databases.closedOffline, isEmpty);
    expect((await alice.summary(id)).status, 'active');
  });
}
