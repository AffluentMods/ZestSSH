import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'fake_crate_server.dart';

/// An Orchard's rules on the devices (3.0): an owner sets them in
/// the record and every device keeps them; a Crate can ask again before its
/// secrets are shown; someone the server holds back by the rules keeps what
/// is on their device and syncs nothing, keeps to the device rules the
/// server says are in force, and treats every Crate as one that asks again;
/// an owner held back can still change the rules; a device that falls short
/// of its own rules (the app lock) syncs nothing; an Orchard past its
/// offline limit stays closed until the device reaches ZestSSH Cloud; and
/// changes to who may do what ask for a recent sign-in.

const _owner = 'owner-1';
const _alice = 'alice';

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
/// (an in-memory one is gone once it closes).
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

class _Device {
  _Device(FakeCrateServer shared, this.uid, AccountKeys keys,
      {Future<List<UnmetRule>> Function(RecordRules rules)? deviceRules, _MemoryStorage? storage})
      : server = shared.as(uid),
        storage = storage ?? _MemoryStorage() {
    databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: this.storage);
    service = OrchardService(
      server: server,
      databases: databases,
      author: () async => CrateAuthor(uid: uid, keys: keys),
      onContact: () {
        contacts++;
        databases.reopenOffline();
      },
    );
    sync = OrchardSyncCoordinator(service: service, server: server, databases: databases, deviceRules: deviceRules);
  }

  final String uid;
  final CrateServer server;
  final _MemoryStorage storage;
  late final OrchardDatabasesNotifier databases;
  late final OrchardService service;
  late final OrchardSyncCoordinator sync;
  var contacts = 0;

  Future<OrchardSummary> summary(String orchardId) async =>
      readOrchardSummary(await databases.open(orchardId), orchardId);

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    for (final uid in [_owner, _alice]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _alice]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  _Device device(String uid,
      {Future<List<UnmetRule>> Function(RecordRules rules)? deviceRules, _MemoryStorage? storage}) {
    final d = _Device(server, uid, keys[uid]!, deviceRules: deviceRules, storage: storage);
    devices.add(d);
    return d;
  }

  /// The owner's Orchard (Production, which the Member role uses), with
  /// Alice in it as a Member.
  Future<({String id, String production})> orchardWithAlice(_Device owner, _Device alice) async {
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(id).roles.values.single;
    await owner.service.invite(id, email: 'alice@example.com', role: member.id);
    server.acceptAs(id, (await owner.service.invites(id)).single.id, _alice);
    await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
    expect(await alice.service.refresh(), contains(id));
    return (id: id, production: member.crates.keys.single);
  }

  const strict = RecordRules(
    require2fa: true,
    emailDomains: {'example.com'},
    requireAppLock: true,
    maxLockMinutes: 15,
    noExport: true,
    offlineHours: 72,
    reauthDays: 30,
  );

  test('the rules an owner sets go into the record and reach every device; a Crate can ask again', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    expect((await alice.summary(o.id)).rules.isNone, isTrue);

    await owner.service.setRules(o.id, strict);
    expect(server.recordOf(o.id).rules.toBody(), strict.toBody());
    expect(server.appends.last, [RecordTypes.rulesSet]);
    expect((await owner.summary(o.id)).rules.toBody(), strict.toBody(), reason: 'kept on the device that set them');
    await alice.service.refresh();
    expect((await alice.summary(o.id)).rules.toBody(), strict.toBody());

    await owner.service.setCrateConfirmReveal(o.id, o.production, true);
    await alice.service.refresh();
    expect((await alice.summary(o.id)).crates.single.confirmReveal, isTrue);
    await owner.service.setCrateConfirmReveal(o.id, o.production, false);
    await alice.service.refresh();
    expect((await alice.summary(o.id)).crates.single.confirmReveal, isFalse);

    // Only owners set them: the device refuses before anything is sent.
    final sent = server.appends.length;
    await expectLater(alice.service.setRules(o.id, RecordRules.none), throwsA(isA<OrchardRecordRefused>()));
    expect(server.appends.length, sent);
  });

  test("a Crate's own offline limit goes into the record and reaches every device; only owners set it", () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    // As a device reads it: from its own copy of the record.
    Future<int> limitOn(_Device d) async =>
        (await latestRecordIn(await d.databases.open(o.id)))!.crates[o.production]!.offlineHours;
    expect(await limitOn(owner), 0);
    expect(await limitOn(alice), 0);

    await owner.service.setCrateOfflineLimit(o.id, o.production, 24);
    expect(server.recordOf(o.id).crates[o.production]!.offlineHours, 24);
    expect(server.appends.last, [RecordTypes.crateSet]);
    expect(await limitOn(owner), 24, reason: 'kept on the device that set it');
    expect(await limitOn(alice), 0, reason: 'a device knows of it once it has synced');
    await alice.service.refresh();
    expect(await limitOn(alice), 24);
    // It is the Crate's, not a rule of the Orchard.
    expect(server.recordOf(o.id).rules.offlineHours, 0);
    expect((await alice.summary(o.id)).rules.offlineHours, 0);

    // Changed, and taken off again.
    await owner.service.setCrateOfflineLimit(o.id, o.production, 72);
    await alice.service.refresh();
    expect(await limitOn(alice), 72);
    await owner.service.setCrateOfflineLimit(o.id, o.production, 0);
    await alice.service.refresh();
    expect(await limitOn(alice), 0);
    expect(server.recordOf(o.id).crates[o.production]!.offlineHours, 0);

    // Only owners set it, and a year at most: the device refuses before
    // anything is sent.
    final sent = server.appends.length;
    await expectLater(alice.service.setCrateOfflineLimit(o.id, o.production, 24), throwsA(isA<OrchardRecordRefused>()));
    await expectLater(owner.service.setCrateOfflineLimit(o.id, o.production, 8761), throwsA(isA<OrchardRecordRefused>()));
    expect(server.appends.length, sent);
    expect(server.recordOf(o.id).crates[o.production]!.offlineHours, 0);
  });

  test('who else may connect to a watched Crate without a watcher, while ZestSSH Cloud cannot be reached, goes into '
      'the record and reaches every device; only owners say', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    // As a device reads it: from its own copy of the record.
    Future<bool> awayOn(_Device d) async =>
        (await latestRecordIn(await d.databases.open(o.id)))!.crates[o.production]!.unwatchedAway;
    expect(await awayOn(owner), isFalse);
    expect(await awayOn(alice), isFalse);

    await owner.service.setCrateUnwatchedAway(o.id, o.production, true);
    expect(server.recordOf(o.id).crates[o.production]!.unwatchedAway, isTrue);
    expect(server.appends.last, [RecordTypes.crateSet]);
    expect(await awayOn(owner), isTrue, reason: 'kept on the device that set it');
    expect(await awayOn(alice), isFalse, reason: 'a device knows of it once it has synced');
    await alice.service.refresh();
    expect(await awayOn(alice), isTrue);
    // It says nothing of whether the Crate's sessions are watched.
    expect(server.recordOf(o.id).crates[o.production]!.watched, isFalse);

    // Taken back.
    await owner.service.setCrateUnwatchedAway(o.id, o.production, false);
    await alice.service.refresh();
    expect(await awayOn(alice), isFalse);
    expect(server.recordOf(o.id).crates[o.production]!.unwatchedAway, isFalse);

    // Only owners say: a member's device refuses before anything is sent.
    final sent = server.appends.length;
    await expectLater(
        alice.service.setCrateUnwatchedAway(o.id, o.production, true), throwsA(isA<OrchardRecordRefused>()));
    expect(server.appends.length, sent);
    expect(server.recordOf(o.id).crates[o.production]!.unwatchedAway, isFalse);
  });

  test("a report of a session without a watcher goes into the record from a member's device, with no recent sign-in "
      'asked, and reaches the others', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    Future<OrchardRecord> recordOn(_Device d) async => (await latestRecordIn(await d.databases.open(o.id)))!;
    final before = server.recordOf(o.id).seq;
    // The server asks for a recent sign-in for changes to who may do what.
    // A report is none: a device sends it by itself when it is back.
    server.requireRecentSignIn = true;
    final body = {
      'crate': o.production,
      'at': 1791504000,
      'gen': 1,
      'sealed': base64Encode(List<int>.filled(64, 9)),
    };
    await alice.service.change(o.id, RecordTypes.sessionUnwatched, body);
    expect(server.appends.last, [RecordTypes.sessionUnwatched]);
    expect(server.recordOf(o.id).seq, before + 1);
    expect((await recordOn(alice)).seq, before + 1, reason: 'kept on the device that sent it');
    await owner.service.refresh();
    expect((await recordOn(owner)).seq, before + 1, reason: "and read by an owner's device with its next sync");
    // What the record refuses is refused on the device, before anything
    // is sent: a Crate there is none of, and something that is no report.
    final sent = server.appends.length;
    await expectLater(alice.service.change(o.id, RecordTypes.sessionUnwatched, {...body, 'crate': 'no-such-crate'}),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'no such Crate')));
    await expectLater(alice.service.change(o.id, RecordTypes.sessionUnwatched, {...body, 'gen': 2}),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'malformed gen')));
    expect(server.appends.length, sent);
    expect(server.recordOf(o.id).seq, before + 1);
  });

  test('rules an owner does not meet themselves are refused, and say which', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    server.unmetBySender = (rules) => rules.require2fa ? ['two_step'] : const [];
    await expectLater(
      owner.service.setRules(o.id, const RecordRules(require2fa: true)),
      throwsA(isA<OrchardServerException>()
          .having((e) => e.code, 'code', 'rules-unmet-by-you')
          .having((e) => e.unmet, 'unmet', ['two_step'])),
    );
    expect(server.recordOf(o.id).rules.isNone, isTrue);
  });

  test('held back by the rules: listed as such, what is here stays, nothing syncs; let back in later', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    await owner.service.setRules(o.id, const RecordRules(emailDomains: {'corp.example', 'example.com'}));
    await alice.service.refresh();
    final before = (await alice.summary(o.id)).crates.map((c) => c.id).toList();

    server.held[_alice] = ['two_step', 'email_domain'];
    expect(await alice.service.refresh(), isNot(contains(o.id)), reason: 'not one to sync');
    final held = await alice.summary(o.id);
    expect(held.status, 'rules');
    expect(held.active, isFalse);
    expect(held.rulesUnmet, ['two_step', 'email_domain']);
    expect(held.ruleDomains, ['corp.example', 'example.com']);
    expect(held.crates.map((c) => c.id), before, reason: 'what is on the device stays');
    expect(held.rules.emailDomains, {'corp.example', 'example.com'}, reason: 'the rules as last read');

    final calls = server.changesCalls;
    final report = await alice.sync.syncOne(o.id);
    expect(report.held, isTrue);
    expect(report.received + report.sent, 0);
    expect(server.changesCalls, calls, reason: 'not even asked: the device knows it is held back');
    await expectLater(
        alice.service.setRules(o.id, RecordRules.none),
        throwsA(isA<OrchardServerException>().having((e) => e.rulesUnmet, 'rules-unmet', isTrue)),
        reason: 'held back, and not an owner either: the record is not even read');

    server.held.remove(_alice);
    expect(await alice.service.refresh(), contains(o.id));
    final back = await alice.summary(o.id);
    expect(back.status, 'active');
    expect(back.rulesUnmet, isEmpty);
    expect(back.active, isTrue);
    expect((await alice.sync.syncOne(o.id)).held, isFalse);
  });

  test('an owner held back still reads the record and can change the rules, and nothing else', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    await owner.service.setRules(o.id, const RecordRules(require2fa: true));

    server.held[_owner] = ['two_step'];
    // Their other device changes the rules meanwhile: this one keeps up
    // with the record (and the rules in it), though held back.
    final r = server.recordOf(o.id);
    await server.appendAs(_owner, o.id, [
      await signRecordEntry(keys[_owner]!,
          orchardId: o.id,
          seq: r.seq + 1,
          prev: r.head,
          type: RecordTypes.rulesSet,
          body: const RecordRules(require2fa: true, noExport: true).toBody(),
          by: _owner),
    ]);
    await owner.service.refresh();
    final held = await owner.summary(o.id);
    expect(held.status, 'rules');
    expect(held.rulesUnmet, ['two_step']);
    expect(held.rules.require2fa, isTrue);
    expect(held.rules.noExport, isTrue, reason: 'the record read while held back');

    await expectLater(
      owner.service.setMemberEndsAt(o.id, _alice, DateTime.now().millisecondsSinceEpoch ~/ 1000 + 86400),
      throwsA(isA<OrchardServerException>().having((e) => e.rulesUnmet, 'rules-unmet', isTrue)),
    );
    // Turning the rule off is allowed, and lets them back in.
    await owner.service.setRules(o.id, RecordRules.none);
    expect(server.recordOf(o.id).rules.isNone, isTrue);
    server.held.remove(_owner);
    await owner.service.refresh();
    expect((await owner.summary(o.id)).status, 'active');
  });

  test('held back in the middle of a sync: the Orchard is marked held and nothing more is sent', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    expect((await alice.sync.syncOne(o.id)).held, isFalse);

    server.held[_alice] = ['reauth'];
    final report = await alice.sync.syncOne(o.id);
    expect(report.held, isTrue);
    final held = await alice.summary(o.id);
    expect(held.status, 'rules');
    expect(held.rulesUnmet, ['reauth']);
    expect((await alice.sync.syncOne(o.id)).held, isTrue, reason: 'and stays so until a refresh says otherwise');
  });

  test('held back by the rules: device rules set in the same step still reach the device, and every Crate asks again',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    expect((await alice.summary(o.id)).crates.single.confirmReveal, isFalse);

    // Two-step sign-in, which Alice falls short of, set together with the
    // rules each device keeps to and a Crate that asks again: she cannot read
    // the record to learn any of it.
    await owner.service.setRules(o.id,
        const RecordRules(require2fa: true, requireAppLock: true, maxLockMinutes: 10, noExport: true, offlineHours: 24));
    await owner.service.setCrateConfirmReveal(o.id, o.production, true);
    server.held[_alice] = ['two_step'];
    expect(await alice.service.refresh(), isNot(contains(o.id)));

    final held = await alice.summary(o.id);
    expect(held.status, 'rules');
    expect((held.rules.requireAppLock, held.rules.maxLockMinutes, held.rules.noExport, held.rules.offlineHours),
        (true, 10, true, 24),
        reason: 'kept to on this device, though the record was not read');
    expect(held.crates.map((c) => c.confirmReveal), everyElement(isTrue),
        reason: 'no Crate switch reaches it meanwhile, so each asks again');
    final t = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(offlineLimitReached(held.rules, OrchardContact(lastContact: t - 25 * 3600, latest: t), t), isTrue,
        reason: 'the offline limit set in the same step closes it');

    // Let back in: the record's rules and switches, as they are.
    server.held.remove(_alice);
    expect(await alice.service.refresh(), contains(o.id));
    final back = await alice.summary(o.id);
    expect(back.rules.toBody(), server.recordOf(o.id).rules.toBody());
    expect(back.crates.single.confirmReveal, isTrue);
  });

  test('while held back, what the server says adds to the device rules the record gave, never takes any away',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    await owner.service.setRules(
        o.id, const RecordRules(requireAppLock: true, maxLockMinutes: 30, noExport: true, offlineHours: 24));
    await alice.service.refresh();

    // Looser in part (export allowed again, a longer offline limit), stricter
    // in part (a shorter lock), together with a rule Alice falls short of.
    const next = RecordRules(require2fa: true, requireAppLock: true, maxLockMinutes: 10, offlineHours: 72);
    await owner.service.setRules(o.id, next);
    server.held[_alice] = ['two_step'];
    await alice.service.refresh();
    final held = (await alice.summary(o.id)).rules;
    expect((held.requireAppLock, held.maxLockMinutes, held.noExport, held.offlineHours), (true, 10, true, 24));

    server.held.remove(_alice);
    await alice.service.refresh();
    expect((await alice.summary(o.id)).rules.toBody(), next.toBody(), reason: 'the record decides once it is read');
  });

  test('the two rules about remote screens: written only when on, read back, off when missing or not a real true; '
      'in force when the record or the server says so', () {
    const both = RecordRules(screensSshOnly: true, screensLockRedirections: true);
    expect(RecordRules.none.toBody().keys.where((k) => k.startsWith('screens_')), isEmpty,
        reason: 'rules from before them keep their bytes');
    expect(both.toBody()['screens_ssh_only'], true);
    expect(both.toBody()['screens_lock_redirections'], true);
    expect(both.isNone, isFalse);
    expect(const RecordRules(screensSshOnly: true).toBody().containsKey('screens_lock_redirections'), isFalse);
    final back = RecordRules.fromStored(jsonDecode(jsonEncode(both.toBody())));
    expect((back.screensSshOnly, back.screensLockRedirections), (true, true));
    final odd = RecordRules.fromStored({'screens_ssh_only': 'true', 'screens_lock_redirections': 1});
    expect((odd.screensSshOnly, odd.screensLockRedirections), (false, false));
    expect(both.copyWith(screensSshOnly: false).toBody().containsKey('screens_ssh_only'), isFalse);

    // Either side asking for one is enough; neither takes one away.
    final told = withStricterDeviceRules(const RecordRules(screensSshOnly: true), const RecordRules(screensLockRedirections: true));
    expect((told.screensSshOnly, told.screensLockRedirections), (true, true));
    expect(withStricterDeviceRules(both, RecordRules.none).toBody(), both.toBody());
    // As this device's database keeps them.
    expect(rulesInForce(null, null).isNone, isTrue);
    expect(rulesInForce(both.toBody(), null).toBody(), both.toBody());
    final held = rulesInForce(const RecordRules(noExport: true).toBody(), {
      'unmet': ['two_step'],
      'device_rules': const RecordRules(screensSshOnly: true).toBody(),
    });
    expect((held.noExport, held.screensSshOnly, held.screensLockRedirections), (true, true, false));
    expect(rulesInForce('not rules', 7).isNone, isTrue);

    // What an owner's rules.set carries from this version on: both always named, on or off.
    expect(RecordRules.none.toSetBody()['screens_ssh_only'], false);
    expect(RecordRules.none.toSetBody()['screens_lock_redirections'], false);
    expect(both.toSetBody()['screens_ssh_only'], true);
    expect({...RecordRules.none.toSetBody()}..removeWhere((k, _) => k.startsWith('screens_')), RecordRules.none.toBody());
  });

  test('the two screen rules go through the service: set, kept when an owner\'s older app saves the other rules '
      '(a rules.set that names neither), and turned off only by an app that says so', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    const screens = RecordRules(screensSshOnly: true, screensLockRedirections: true);
    await owner.service.setRules(o.id, screens);
    expect(server.recordOf(o.id).rules.toBody(), screens.toBody());
    await alice.service.refresh();
    expect((await alice.summary(o.id)).rules.toBody(), screens.toBody());

    // An owner's app from before the two rules: its rules.set names neither.
    await owner.service.change(o.id, RecordTypes.rulesSet, const RecordRules(noExport: true).toBody());
    expect(server.recordOf(o.id).rules.toBody(), screens.copyWith(noExport: true).toBody(),
        reason: 'the other rule changed, the two it does not know stayed');
    await alice.service.refresh();
    final kept = (await alice.summary(o.id)).rules;
    expect((kept.noExport, kept.screensSshOnly, kept.screensLockRedirections), (true, true, true));

    // This version turns one off by naming it, and the other stays.
    await owner.service.setRules(o.id, kept.copyWith(screensSshOnly: false));
    expect(server.recordOf(o.id).rules.toBody(), const RecordRules(noExport: true, screensLockRedirections: true).toBody());
    await owner.service.setRules(o.id, RecordRules.none);
    expect(server.recordOf(o.id).rules.isNone, isTrue);
    await alice.service.refresh();
    expect((await alice.summary(o.id)).rules.isNone, isTrue);
  });

  test('the stricter of two sets of device rules: either one asks for the lock or no export, the shorter limit wins, 0 is none',
      () {
    const record = RecordRules(emailDomains: {'example.com'}, reauthDays: 7, maxLockMinutes: 30);
    const told = RecordRules(require2fa: true, requireAppLock: true, noExport: true, offlineHours: 48);
    expect(
      withStricterDeviceRules(record, told).toBody(),
      const RecordRules(
        emailDomains: {'example.com'},
        reauthDays: 7,
        requireAppLock: true,
        maxLockMinutes: 30,
        noExport: true,
        offlineHours: 48,
      ).toBody(),
      reason: "the server's own rules stay as the record has them",
    );
    expect(
      withStricterDeviceRules(const RecordRules(maxLockMinutes: 5, offlineHours: 12),
              const RecordRules(maxLockMinutes: 15, offlineHours: 6))
          .toBody(),
      const RecordRules(maxLockMinutes: 5, offlineHours: 6).toBody(),
    );
    expect(withStricterDeviceRules(const RecordRules(noExport: true, offlineHours: 8), RecordRules.none).toBody(),
        const RecordRules(noExport: true, offlineHours: 8).toBody(),
        reason: 'never weaker than the record');
  });

  test('a device short of the app lock the rules ask for syncs nothing until it meets it', () async {
    var lockOn = false;
    final owner = device(_owner);
    final alice = device(_alice,
        deviceRules: (rules) async => deviceUnmet(rules, lockOn: lockOn, lockMinutes: 5));
    final o = await orchardWithAlice(owner, alice);
    expect((await alice.sync.syncOne(o.id)).held, isFalse, reason: 'no rule yet');

    await owner.service.setRules(o.id, const RecordRules(requireAppLock: true, maxLockMinutes: 10));
    await alice.service.refresh();
    final reads = server.memberReads.length;
    final report = await alice.sync.syncOne(o.id);
    expect(report.held, isTrue);
    expect(server.memberReads.length, reads);
    expect((await alice.summary(o.id)).status, 'active', reason: 'the server does not hold her back: her device does');

    lockOn = true;
    expect((await alice.sync.syncOne(o.id)).held, isFalse);
  });

  test('closed by its offline limit: it does not open until the device reaches ZestSSH Cloud', () async {
    final dir = await Directory.systemTemp.createTemp('zest-offline-');
    addTearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {/* Windows may hold a file a moment */}
    });
    final owner = device(_owner);
    final alice = device(_alice, storage: _FileStorage(dir));
    final o = await orchardWithAlice(owner, alice);
    final before = alice.contacts;

    await alice.databases.closeOffline(o.id);
    expect(alice.databases.closedOffline, {o.id});
    expect(alice.databases.state.containsKey(o.id), isFalse, reason: 'its database closed');
    await expectLater(alice.databases.open(o.id), throwsA(isA<OrchardClosedOffline>()));
    await expectLater(alice.sync.syncOne(o.id), throwsA(isA<OrchardClosedOffline>()));

    // Reaching ZestSSH Cloud opens it again, before anything reads it.
    expect(await alice.service.refresh(), contains(o.id));
    expect(alice.contacts, before + 1);
    expect(alice.databases.closedOffline, isEmpty);
    expect((await alice.summary(o.id)).status, 'active');

    // No contact, no reopening.
    await alice.databases.closeOffline(o.id);
    final failing = _Unreachable(server.as(_alice));
    final offline = OrchardService(
      server: failing,
      databases: alice.databases,
      author: () async => CrateAuthor(uid: _alice, keys: keys[_alice]!),
      onContact: () => alice.databases.reopenOffline(),
    );
    await expectLater(offline.refresh(), throwsA(isA<StateError>()));
    expect(alice.databases.closedOffline, {o.id});

    // Leaving the device forgets it was closed.
    await alice.databases.forget(o.id);
    expect(alice.databases.closedOffline, isEmpty);
  });

  test('changing who may do what asks for a recent sign-in; leaving does not', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    server.requireRecentSignIn = true;
    for (final change in <Future<void> Function()>[
      () => owner.service.setRules(o.id, const RecordRules(noExport: true)),
      () => owner.service.setCrateConfirmReveal(o.id, o.production, true),
      () => owner.service.setCrateAllow(o.id, o.production, {'sftp'}),
    ]) {
      await expectLater(change(),
          throwsA(isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'recent', isTrue)));
    }
    expect(server.recordOf(o.id).rules.isNone, isTrue);
    server.accountUid = _alice;
    await alice.service.leaveOrchard(o.id);
    expect(server.recordOf(o.id).members[_alice]!.status, MemberStatus.removed);
  });

  test('the rules and held state survive on the device as JSON it can read back', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final o = await orchardWithAlice(owner, alice);
    await owner.service.setRules(o.id, strict);
    await alice.service.refresh();
    final db = await alice.databases.open(o.id);
    final row = await db.customSelect('SELECT rules, held FROM orchard_info WHERE id = 1').getSingle();
    expect(jsonDecode(row.read<String>('rules')), strict.toBody());
    expect(row.read<String?>('held'), isNull);
  });
}

/// A server that cannot be reached.
class _Unreachable implements CrateServer {
  _Unreachable(this._inner);

  final CrateServer _inner;

  @override
  Future<List<RemoteOrchard>> orchards() async => throw StateError('offline');

  @override
  dynamic noSuchMethod(Invocation invocation) => Function.apply(
      (_inner as dynamic).noSuchMethod, [invocation]);
}
