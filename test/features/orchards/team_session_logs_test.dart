import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/features/run/run_client.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SSHKeyPair;

import '../../../packages/zest_ssh_core/test/src/played_server.dart';
import '../../helpers/played_sign_in.dart';

import 'fake_crate_server.dart';

/// Team session logs (3.0): off, nothing is logged; on, what a
/// session shows goes to the team as text, redacted (the session's known
/// secrets, private key blocks, tokens), sealed with the Crate's key and in
/// order; owners and managers read it, checked; turned off, the writer stops
/// and the logs are gone; a log naming someone else, or with a chunk
/// missing, is not passed off as whole.

const _owner = 'owner-1';
const _alice = 'alice';

class _MemoryStorage implements OrchardDatabaseStorage {
  _MemoryStorage([this.folder]);

  /// With a folder, an Orchard's database is a file in it, so that it can
  /// be closed and opened again with what it kept; without one it is in
  /// memory, and opened once.
  final Directory? folder;
  final dbs = <String, AppDatabase>{};

  /// How often each Orchard's database was opened.
  final opens = <String, int>{};

  File? _file(String orchardId) => folder == null ? null : File('${folder!.path}/$orchardId.sqlite');

  @override
  Future<bool> exists(String orchardId) async => _file(orchardId)?.existsSync() ?? dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    opens[orchardId] = (opens[orchardId] ?? 0) + 1;
    final file = _file(orchardId);
    if (file != null) return dbs[orchardId] = AppDatabase.forTesting(NativeDatabase(file), isOrchard: true);
    return dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
  }

  @override
  Future<void> delete(String orchardId) async {
    dbs.remove(orchardId);
    final file = _file(orchardId);
    if (file != null && file.existsSync()) file.deleteSync();
  }

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

/// This device's clock from here on, as the test moves it
/// ([OrchardService.debugNow]); the real one again once the test has ended.
class _Clock {
  _Clock() {
    OrchardService.debugNow = () => now;
    addTearDown(() => OrchardService.debugNow = DateTime.now);
  }

  var now = DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch);

  void pass(Duration time) => now = now.add(time);
}

class _Device {
  _Device(FakeCrateServer shared, this.uid, this.keys, {bool Function()? cloudAway, Directory? folder})
      : server = shared.as(uid),
        storage = _MemoryStorage(folder) {
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
      cloudAway: cloudAway,
    )..debugSessionLogSleep = (time) async {
        slept.add(time);
        // The time passes while the turn waits, not the instant it begins
        // to: whoever asks for a turn meanwhile still reads the time before.
        await Future<void>.delayed(Duration.zero);
        onSleep?.call(time);
      };
    coordinator = OrchardSyncCoordinator(service: service, server: server, databases: service.databases);
  }

  final String uid;
  final AccountKeys keys;
  final CrateServer server;
  final _MemoryStorage storage;

  /// How long session log requests were told to wait for their turn. No
  /// test waits that long: [onSleep] hears of it a moment later, and moves
  /// a clock.
  final slept = <Duration>[];
  void Function(Duration time)? onSleep;
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      try {
        await db.close();
      } catch (_) {
        // (Closed by its test already.)
      }
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

  _Device device(String uid, {bool Function()? cloudAway, Directory? folder}) {
    final d = _Device(server, uid, keys[uid]!, cloudAway: cloudAway, folder: folder);
    devices.add(d);
    return d;
  }

  /// A sync of [d], and the round of session logs it started for [id]: a
  /// sync does not wait for that.
  Future<Map<String, CrateSyncReport>> sync(_Device d, String id) async {
    final reports = await d.coordinator.syncAll();
    await d.service.debugSessionLogRound(id);
    return reports;
  }

  Future<(String, String)> team(_Device owner, _Device alice) async {
    final id = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final crate = server.recordOf(id).roles.values.single.crates.keys.single;
    await owner.service.invite(id, email: 'alice@example.com', role: server.recordOf(id).roles.values.single.id);
    server.acceptAs(id, (await owner.service.invites(id)).single.id, _alice);
    await owner.service.confirmInvite(id, (await owner.service.invites(id)).single);
    await sync(alice, id);
    return (id, crate);
  }

  Future<TeamSessionLogWriter?> start(_Device d, String id, String crate) => d.service.startTeamSessionLog(id, crate,
      label: 'Web 1', host: 'web1.example.com', port: 22, user: 'deploy', connectionId: 'web1',
      flushEvery: const Duration(hours: 1), flushAtBytes: 1 << 20);

  /// The names under which [d] keeps session logs of [id] that the server
  /// has not taken, in order.
  Future<List<String>> kept(_Device d, String id) async => [
        for (final r in await (await d.db(id))
            .customSelect('''SELECT "key" AS k FROM local_state WHERE "key" LIKE 'sessionlog.%' ORDER BY "key"''').get())
          r.read<String>('k'),
      ];

  /// What [d] keeps under [name] in [id]'s database, read as the JSON it is.
  Future<Map<String, Object?>> keptRow(_Device d, String id, String name) async =>
      jsonDecode((await LocalStateStore(await d.db(id)).read(name))!) as Map<String, Object?>;

  /// The log [logId] as an owner reads it: its text, whether all of it is
  /// there, and whether it ended properly.
  Future<(String, bool, bool)> read(_Device owner, String id, String crate, String logId) async {
    final entry = (await owner.service.teamSessionLogs(id, crate)).entries.firstWhere((e) => e.id == logId);
    final text = await owner.service.teamSessionLogText(id, crate, entry);
    return (text.text, text.complete, entry.closed);
  }

  test('off: nothing is logged', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    expect(await alice.service.sessionLogsOn(id, crate), isFalse);
    expect(await start(alice, id, crate), isNull);
    expect(server.sessionLogRows[crate], isNull);
    expect(server.sessionLogStartCalls, 0, reason: 'the server does not even learn of the session');
  });

  test('on: a session goes to the team as redacted text, sealed and in order; managers read it whole', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    expect(await alice.service.sessionLogsOn(id, crate), isTrue);

    final log = (await start(alice, id, crate))!;
    log.addSecret('hunter2-pass');
    log.append('\x1b[1;32mdeploy@web1\x1b[0m:~\$ echo hunter2-pass\r\n');
    log.append('hunter2-pass\r\nGITHUB_TOKEN=ghp_');
    await log.flush();
    log.append('${'a' * 36}\r\ndone\r\n');
    await log.close();
    expect(log.waiting, 0);
    final stored = server.sessionLogRows[crate]!.single;
    expect(stored.closed, isTrue);
    for (final c in stored.chunks) {
      expect(utf8.decode(c.sealed, allowMalformed: true), isNot(contains('deploy@web1')), reason: 'sealed');
    }

    final page = await owner.service.teamSessionLogs(id, crate);
    final entry = page.entries.single;
    expect((entry.header.uid, entry.header.label, entry.header.host, entry.header.port, entry.header.user),
        (_alice, 'Web 1', 'web1.example.com', 22, 'deploy'));
    expect(entry.closed, isTrue);
    final text = await owner.service.teamSessionLogText(id, crate, entry);
    expect(text.complete, isTrue);
    expect(text.text, 'deploy@web1:~\$ echo [redacted]\n[redacted]\nGITHUB_TOKEN=[redacted]\ndone\n');

    // Someone who may only use the Crate reads none of it.
    await expectLater(alice.service.teamSessionLogs(id, crate),
        throwsA(isA<OrchardServerException>().having((e) => e.need, 'need', CrateSwitches.manage)));
  });

  test('a private key block is held back across chunks and left out whole, even when the session ends in it', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    final log = (await start(alice, id, crate))!;
    log.append('\$ cat id\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNz\n');
    await log.flush();
    expect(server.sessionLogRows[crate]!.single.chunks.length, 1, reason: 'only what came before the key went');
    log.append('aC1rZXk=\n-----END OPENSSH PRIVATE KEY-----\n\$ cat other\n-----BEGIN RSA PRIVATE KEY-----\nMIIE\n');
    await log.close();
    final entry = (await owner.service.teamSessionLogs(id, crate)).entries.single;
    final text = await owner.service.teamSessionLogText(id, crate, entry);
    expect(text.text, '\$ cat id\n[redacted private key]\n\$ cat other\n[redacted private key]\n');
    expect(text.text, isNot(contains('MIIE')));
  });

  test('a BEGIN line whose END never comes is not held for ever: past a bound it is left out and the log goes on', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    final log = (await start(alice, id, crate))!;
    log.append('\$ cat big\n-----BEGIN OPENSSH PRIVATE KEY-----\n');
    final line = '${'A' * 63}\n';
    for (var held = 0; held <= kSessionLogKeyHoldBytes; held += line.length) {
      log.append(line);
    }
    await log.flush();
    expect(server.sessionLogRows[crate]!.single.chunks, hasLength(1), reason: 'past the bound, it went');
    log.append('after\n');
    await log.close();
    final entry = (await owner.service.teamSessionLogs(id, crate)).entries.single;
    final text = await owner.service.teamSessionLogText(id, crate, entry);
    expect((text.text, text.complete), ('\$ cat big\n[redacted private key]\nafter\n', true));

    // Under the bound it is still held back, waiting for its END.
    final second = (await start(alice, id, crate))!;
    second.append('-----BEGIN OPENSSH PRIVATE KEY-----\n$line');
    await second.flush();
    expect(server.sessionLogChunkCalls, greaterThan(0));
    final calls = server.sessionLogChunkCalls;
    second.append(line);
    await second.flush();
    expect(server.sessionLogChunkCalls, calls, reason: 'held');
    await second.close();
  });

  test('turned off during a session: the writer stops, and the logs are gone', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    final log = (await start(alice, id, crate))!;
    log.append('one\n');
    await log.flush();
    expect(server.sessionLogRows[crate]!.single.chunks, hasLength(1));

    await owner.service.setCrateSessionLogs(id, crate, false);
    expect(server.sessionLogRows[crate], isNull, reason: 'gone when turned off');
    log.append('two\n');
    await log.flush();
    expect(log.stopped, isTrue);
    final calls = server.sessionLogChunkCalls;
    log.append('three\n');
    await log.close();
    expect(server.sessionLogChunkCalls, calls, reason: 'nothing more is sent once stopped');
    // And a device whose record says off starts none.
    await sync(alice, id);
    expect(await start(alice, id, crate), isNull);
  });

  test('a log naming someone other than who sent it is left out; a missing chunk ends the text, not complete', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    // Alice holds the Crate's key: she can seal a header naming the owner,
    // but the server says she sent it.
    final key = (await (await alice.db(id)).customSelect(
      "SELECT secret FROM space_keys WHERE scope = 'crate' AND scope_id = ? AND generation = 1",
      variables: [Variable(crate)],
    ).getSingle())
        .read<Uint8List>('secret');
    const framed = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    final header = SessionLogHeader(uid: _owner, label: 'x', host: 'x', port: 22, startedAt: DateTime.now());
    await alice.server.startSessionLog(crate, framed,
        keyGeneration: 1,
        header: await sealSessionLogPart(utf8.encode(jsonEncode(header.toJson())), key,
            orchardId: id, crateId: crate, logId: framed, part: 0, generation: 1));

    final log = (await start(alice, id, crate))!;
    log.append('first\n');
    await log.flush();
    log.append('second\n');
    await log.flush();
    log.append('third\n');
    await log.close();

    final page = await owner.service.teamSessionLogs(id, crate);
    expect(page.unreadable, 1);
    final entry = page.entries.single;
    expect((await owner.service.teamSessionLogText(id, crate, entry)).text, 'first\nsecond\nthird\n');
    // The server drops the second chunk.
    server.sessionLogRows[crate]!.firstWhere((l) => l.id == entry.id).chunks.removeAt(1);
    final cut = await owner.service.teamSessionLogText(id, crate, entry);
    expect(cut.text, 'first\n');
    expect(cut.complete, isFalse);
  });

  test('a chunk swapped with another, or taken from another log, does not open: the text stops there', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    Future<TeamSessionLogEntry> logOf(List<String> lines) async {
      final log = (await start(alice, id, crate))!;
      for (final l in lines) {
        log.append(l);
        await log.flush();
      }
      await log.close();
      return (await owner.service.teamSessionLogs(id, crate)).entries.firstWhere((e) => e.id == log.logId);
    }

    final a = await logOf(['first\n', 'second\n', 'third\n']);
    final b = await logOf(['other\n', 'more\n']);
    List<({int seq, int keyGeneration, Uint8List sealed})> chunksOf(TeamSessionLogEntry e) =>
        server.sessionLogRows[crate]!.firstWhere((l) => l.id == e.id).chunks;
    Future<(String, bool)> read() async {
      final t = await owner.service.teamSessionLogText(id, crate, a);
      return (t.text, t.complete);
    }

    expect(await read(), ('first\nsecond\nthird\n', true));
    final kept = [...chunksOf(a)];
    ({int seq, int keyGeneration, Uint8List sealed}) at(int seq, Uint8List sealed) =>
        (seq: seq, keyGeneration: 1, sealed: sealed);

    // The second and third swapped, each left in the other's place.
    chunksOf(a)
      ..[1] = at(2, kept[2].sealed)
      ..[2] = at(3, kept[1].sealed);
    expect(await read(), ('first\n', false));

    // The other log's second chunk in this one's second place.
    chunksOf(a)
      ..[1] = at(2, chunksOf(b)[1].sealed)
      ..[2] = kept[2];
    expect(await read(), ('first\n', false));

    // Put back as it was: whole again.
    chunksOf(a)[1] = kept[1];
    expect(await read(), ('first\nsecond\nthird\n', true));

    // The server drops its last chunks: what is there reads, but not as whole.
    chunksOf(a).removeRange(2, 4);
    expect(await read(), ('first\nsecond\n', false));
  });

  test('a flush with nothing new to send does not hold up the ones after it; the log still ends properly', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    final log = (await start(alice, id, crate))!;
    log.append('downloading 10%');
    await log.flush();
    expect(server.sessionLogChunkCalls, 0, reason: 'half a line waits');
    log.append(' 100%\n');
    await log.flush();
    expect(server.sessionLogChunkCalls, 1);
    await log.flush();
    log.append('done\n');
    await log.flush();
    await log.close();
    final entry = (await owner.service.teamSessionLogs(id, crate)).entries.single;
    final text = await owner.service.teamSessionLogText(id, crate, entry);
    expect((text.text, text.complete, entry.closed), ('downloading 10% 100%\ndone\n', true, true));
  });

  test('flushes asked at once keep the order the session showed', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    final log = (await start(alice, id, crate))!;
    final flushes = <Future<void>>[];
    for (var i = 1; i <= 6; i++) {
      log.append('${'line $i ' * (i * 400)}\n');
      flushes.add(log.flush());
    }
    await Future.wait(flushes);
    await log.close();
    final entry = (await owner.service.teamSessionLogs(id, crate)).entries.single;
    final text = await owner.service.teamSessionLogText(id, crate, entry);
    expect(text.complete, isTrue);
    expect(text.text, [for (var i = 1; i <= 6; i++) '${'line $i ' * (i * 400)}\n'].join());
    expect((entry.chunks, server.sessionLogChunkCalls), (2, 2), reason: 'each chunk asked for once, whoever asked');
  });

  test('what the server cannot take now goes at the next flush; what it refuses for good stops the log', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    // (Each flush here comes after whatever wait the fault before it set:
    // the waits have a test of their own.)
    final clock = _Clock();
    final log = (await start(alice, id, crate))!;
    var waiting = 0;
    for (final (status, code) in [(503, 'unavailable'), (429, 'rate-limited'), (401, 'unauthenticated'), (408, 'timeout')]) {
      server.sessionLogChunkFault = (_) => OrchardServerException(status, code);
      log.append('$code\n');
      clock.pass(kSessionLogLongestWait);
      final calls = server.sessionLogChunkCalls;
      await log.flush();
      expect((log.waiting, log.stopped), (++waiting, false), reason: '$status waits');
      expect(server.sessionLogChunkCalls, calls + 1, reason: 'asked once, and no further');
    }
    server.sessionLogChunkFault = (_) => StateError('no network');
    log.append('offline\n');
    clock.pass(kSessionLogLongestWait);
    await log.flush();
    expect((log.waiting, log.stopped), (5, false));
    server.sessionLogChunkFault = null;
    log.append('back\n');
    clock.pass(kSessionLogLongestWait);
    await log.flush();
    expect(log.waiting, 0);
    final entry = (await owner.service.teamSessionLogs(id, crate)).entries.single;
    expect((await owner.service.teamSessionLogText(id, crate, entry)).text,
        'unavailable\nrate-limited\nunauthenticated\ntimeout\noffline\nback\n');

    // Refused for good.
    server.sessionLogChunkFault = (_) => const OrchardServerException(400, 'invalid-request');
    log.append('refused\n');
    await log.flush();
    expect((log.stopped, log.waiting), (true, 0));
    server.sessionLogChunkFault = null;
    final calls = server.sessionLogChunkCalls;
    log.append('after\n');
    await log.close();
    expect(server.sessionLogChunkCalls, calls, reason: 'nothing more is sent');
  });

  test('a team whose session logs are full: the session goes on, an owner hears once, and nobody else does', () async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    Future<List<String>> told(_Device d, {DateTime? now}) async => [
          for (final n in await takeTeamNotifications({id: await d.db(id)},
              me: d.uid, l10n: l10n, orchardName: (name) => name ?? '?'))
            n.title,
        ];
    final title = l10n.orchardSessionLogsFullTitle('Acme');
    // What came before is told first.
    await told(owner);
    await told(alice);
    expect(await told(owner), isEmpty);

    // Asking to start one: the session is simply not logged, and goes on.
    server.sessionLogStartFault = const OrchardServerException(413, 'session-logs-team-full');
    expect(await start(alice, id, crate), isNull);
    expect(await told(alice), isEmpty, reason: 'a member has nothing to do about it');
    expect(await start(owner, id, crate), isNull);
    expect(await told(owner), [title]);
    expect(await told(owner), isEmpty, reason: 'once');

    // Sending one already under way: the same answer ends it, and it is not told again.
    server.sessionLogStartFault = null;
    server.sessionLogChunkFault = (_) => const OrchardServerException(413, 'session-logs-team-full');
    final log = (await start(owner, id, crate))!;
    log.append('more\n');
    await log.flush();
    expect((log.stopped, log.waiting), (true, 0));
    expect(await told(owner), isEmpty);
    server.sessionLogChunkFault = null;

    // A month on, with old logs gone, full again: heard again.
    final store = LocalStateStore(await owner.db(id));
    await store.write('orchards.session_logs_full_told', '${DateTime.now().subtract(const Duration(days: 31)).millisecondsSinceEpoch ~/ 1000}');
    server.sessionLogStartFault = const OrchardServerException(413, 'session-logs-team-full');
    expect(await start(owner, id, crate), isNull);
    expect(await told(owner), [title]);
    server.sessionLogStartFault = null;
  });

  test('a session that shows more than a log holds ends its text saying so, and the log ends properly', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    final log = (await alice.service.startTeamSessionLog(id, crate,
        label: 'Web 1', host: 'web1.example.com', port: 22,
        flushEvery: const Duration(hours: 1), flushAtBytes: 1 << 20, maxBytes: 8 * 1024))!;
    final first = '${'a' * 2999}\n';
    log.append(first);
    await log.flush();
    expect(log.full, isFalse);
    log.append('${'b' * 2999}\n');
    await log.flush();
    expect(log.full, isTrue);
    log.append('more\n');
    await log.close();
    final entry = (await owner.service.teamSessionLogs(id, crate)).entries.single;
    final text = await owner.service.teamSessionLogText(id, crate, entry);
    expect((text.text, text.complete), ('$first\n$kSessionLogFull\n', true));
    final stored = server.sessionLogRows[crate]!.single.chunks.fold<int>(0, (n, c) => n + c.sealed.length);
    expect(stored, lessThanOrEqualTo(8 * 1024));
  });

  test('the registry: output waits until the log starts, the chip follows it, secrets are kept only while a log is open', () async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    // With no log open, a masked value is not kept at all.
    TeamSessionLogs.addSecret('before-any-log');
    expect(TeamSessionLogs.secretsKept, 0);

    // A saved host in the Crate.
    final db = await alice.db(id);
    await (await owner.db(id)).customStatement(
        "INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES ('web1', 'Web 1', 'web1.example.com', 22, 0, 0)");
    await owner.coordinator.syncAll();
    await sync(alice, id);

    // A session expected: its output waits, the chip shows while it starts.
    TeamSessionLogs.expect('s1');
    expect(TeamSessionLogs.isLogged('s1'), isTrue);
    TeamSessionLogs.append('s1', 'banner\n');
    TeamSessionLogs.addSecret('s3cret-value');
    expect(TeamSessionLogs.secretsKept, 1);
    final writer = await start(alice, id, crate);
    TeamSessionLogs.started('s1', writer);
    TeamSessionLogs.append('s1', 'echo s3cret-value\n');
    // A value masked once the log is open is left out too.
    TeamSessionLogs.addSecret('typed-later');
    TeamSessionLogs.append('s1', 'echo typed-later\n');
    await TeamSessionLogs.end('s1');
    expect(TeamSessionLogs.isLogged('s1'), isFalse);
    expect(TeamSessionLogs.secretsKept, 0, reason: 'the last log ended: nothing kept');
    final entry = (await owner.service.teamSessionLogs(id, crate)).entries.single;
    final text = await owner.service.teamSessionLogText(id, crate, entry);
    expect(text.text, 'banner\necho [redacted]\necho [redacted]\n');
    expect(text.complete, isTrue);

    // A log that does not start keeps nothing and shows no chip.
    TeamSessionLogs.expect('s2');
    TeamSessionLogs.append('s2', 'anything\n');
    TeamSessionLogs.started('s2', null);
    expect(TeamSessionLogs.isLogged('s2'), isFalse);

    // What waits while a log starts is kept up to a bound.
    TeamSessionLogs.expect('s6');
    TeamSessionLogs.append('s6', '${'x' * (TeamSessionLogs.kEarlyOutputMax - 1)}\n');
    TeamSessionLogs.append('s6', 'overflow\n');
    TeamSessionLogs.started('s6', await start(alice, id, crate));
    await TeamSessionLogs.end('s6');
    final bounded = (await owner.service.teamSessionLogs(id, crate)).entries.first;
    final boundedText = (await owner.service.teamSessionLogText(id, crate, bounded)).text;
    expect((boundedText.length, boundedText.contains('overflow')), (TeamSessionLogs.kEarlyOutputMax, false));
    await owner.service.deleteTeamSessionLog(crate, bounded.id);

    // A log the server stops taking drops the chip.
    TeamSessionLogs.expect('s7');
    TeamSessionLogs.started('s7', await start(alice, id, crate));
    expect(TeamSessionLogs.isLogged('s7'), isTrue);
    server.sessionLogChunkFault = (_) => const OrchardServerException(409, 'log-closed');
    TeamSessionLogs.append('s7', '${'y' * (1 << 20)}\n');
    for (var i = 0; i < 50 && TeamSessionLogs.isLogged('s7'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      TeamSessionLogs.append('s7', 'more\n');
    }
    server.sessionLogChunkFault = null;
    expect(TeamSessionLogs.isLogged('s7'), isFalse);
    for (final l in [...server.sessionLogRows[crate]!]) {
      if (l.id != entry.id) await owner.service.deleteTeamSessionLog(crate, l.id);
    }

    // Through the helper a terminal calls: a saved host in a logging Crate.
    await startTeamSessionLogFor(alice.service, db, 's3',
        connectionId: 'web1', label: 'Web 1', host: 'web1.example.com', port: 22, user: 'deploy');
    expect(TeamSessionLogs.isLogged('s3'), isTrue);
    TeamSessionLogs.append('s3', 'hello\n');
    for (var i = 0; i < 50 && (server.sessionLogRows[crate]?.length ?? 0) < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await TeamSessionLogs.end('s3');
    final second = (await owner.service.teamSessionLogs(id, crate)).entries.first;
    expect(second.header.connectionId, 'web1');
    expect((await owner.service.teamSessionLogText(id, crate, second)).text, 'hello\n');

    // Your Tree's sessions, and hosts in a Crate that does not log, are not.
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(tree.close);
    await startTeamSessionLogFor(alice.service, tree, 's4', connectionId: 'x', label: 'x', host: 'x', port: 22);
    expect(TeamSessionLogs.isLogged('s4'), isFalse);
    await owner.service.setCrateSessionLogs(id, crate, false);
    await sync(alice, id);
    await startTeamSessionLogFor(alice.service, db, 's5', connectionId: 'web1', label: 'Web 1', host: 'w', port: 22);
    expect(TeamSessionLogs.isLogged('s5'), isFalse);
  });

  test('a session that ends while its log is still starting: what it showed goes in, and the log is closed; '
      'connecting again under the same id before then, it goes on in that log', () async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    /// The log [logId] once it has ended properly: its text, and whether all
    /// of it is there.
    Future<(String, bool)> ended(String logId) async {
      for (var i = 0; i < 250; i++) {
        final entries = (await owner.service.teamSessionLogs(id, crate)).entries.where((e) => e.id == logId);
        if (entries.isNotEmpty && entries.single.closed) {
          final (text, complete, _) = await read(owner, id, crate, logId);
          return (text, complete);
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('the log $logId did not end');
    }

    // Quicker than its log: what it showed, a masked value in it, its end,
    // and only then the log's start.
    TeamSessionLogs.expect('q1');
    TeamSessionLogs.append('q1', 'quick\n');
    TeamSessionLogs.addSecret('s3cret-value');
    TeamSessionLogs.append('q1', 'echo s3cret-value\n');
    await TeamSessionLogs.end('q1');
    expect(TeamSessionLogs.isLogged('q1'), isFalse, reason: 'the session is over');
    expect(TeamSessionLogs.secretsKept, 1, reason: 'kept until the log that waits for it has started');
    final quick = await start(alice, id, crate);
    TeamSessionLogs.started('q1', quick);
    TeamSessionLogs.append('q1', 'after the end\n');
    expect(TeamSessionLogs.isLogged('q1'), isFalse);
    expect(TeamSessionLogs.secretsKept, 0, reason: 'no log open or starting: nothing kept');
    expect(await ended(quick!.logId), ('quick\necho [redacted]\n', true));

    // Ended while its log starts, and connecting again under the same id
    // before it has: the session goes on in that log, and is logged.
    TeamSessionLogs.expect('q2');
    TeamSessionLogs.append('q2', 'first\n');
    await TeamSessionLogs.end('q2');
    TeamSessionLogs.expect('q2');
    expect(TeamSessionLogs.isLogged('q2'), isTrue);
    TeamSessionLogs.append('q2', 'again\n');
    final again = await start(alice, id, crate);
    TeamSessionLogs.started('q2', again);
    expect(TeamSessionLogs.isLogged('q2'), isTrue, reason: 'the session goes on, logged');
    TeamSessionLogs.append('q2', 'more\n');
    await TeamSessionLogs.end('q2');
    expect(await ended(again!.logId), ('first\nagain\nmore\n', true));
  });

  test('a run on hosts to a host whose Crate logs sessions is logged for the team: a line that says so, the '
      'command with its masked values left out, what it printed, and how it ended', () async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    final en = lookupAppLocalizations(const Locale('en'));
    L10nGlobal.update(en);
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    // A saved host in the Crate.
    await (await owner.db(id)).customStatement(
        "INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES ('web1', 'Web 1', 'web1.example.com', 22, 0, 0)");
    await owner.coordinator.syncAll();
    await sync(alice, id);
    final db = await alice.db(id);
    final key = SSHKeyPair.fromPem(
            File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync())
        .single;

    // The host, played: it takes the key, prints, and ends well.
    final server = PlayedServer();
    String? asked;
    Future<void> play(bool Function() over) async {
      await server.greet();
      if (!await PlayedSignIn(ways: ['publickey'], takesKey: true).play(server, over: over)) return;
      final channel = await server.confirmChannel();
      asked = (await channel.nextRequest()).command;
      server.send([
        channel.success,
        channel.data('Uptime: 5 days\n'),
        channel.errorData('a warning\n'),
        channel.exitStatus(0),
        channel.eof,
        channel.close,
      ]);
    }

    // Signed in to as the app does for a run, and its team's log started as
    // the app starts it (ActiveSessionsNotifier.openRunClient).
    String? logId;
    final run = RunOnHostsNotifier((host) async {
      final ssh = SshService(
        host: host.host,
        port: host.port,
        username: 'deploy',
        keyPairs: [key],
        keepAliveSeconds: 0,
        onHostKeyVerify: (_, _, _) async => true,
        tunnelSocket: server.socket,
      );
      var failed = false;
      unawaited(play(() => failed));
      try {
        await ssh.connectExec();
      } catch (_) {
        failed = true;
        rethrow;
      }
      logId = 'run_web1_1';
      await startTeamSessionLogFor(alice.service, db, logId!,
          connectionId: 'web1', label: 'Web 1', host: host.host, port: host.port, user: 'deploy');
      return RunClient(ssh, teamLog: TeamSessionLogs.isLogged(logId!) ? logId : null);
    });
    addTearDown(run.dispose);
    await run.run([(await db.connectionsDao.getById('web1'))!], 'mysql -u deploy -phunter22 -e status',
        typed: r'mysql -u ${USER} -p${PW:secret} -e status', secrets: const ['hunter22']);
    final h = run.state!.hosts.single;
    expect(h.succeeded, isTrue);
    expect(h.logged, isTrue);
    expect(asked, 'mysql -u deploy -phunter22 -e status');
    expect(TeamSessionLogs.isLogged(logId!), isFalse, reason: 'the run is over, and so is its log');

    var text = '';
    var closed = false;
    for (var i = 0; i < 250 && !closed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final entries = (await owner.service.teamSessionLogs(id, crate)).entries;
      if (entries.isNotEmpty && entries.single.closed) {
        closed = true;
        text = (await owner.service.teamSessionLogText(id, crate, entries.single)).text;
        expect(entries.single.header.connectionId, 'web1');
        expect(entries.single.header.user, 'deploy');
      }
    }
    expect(closed, isTrue, reason: 'the log ended');
    // (A log keeps its lines as text: each ends in a line feed.)
    expect(
        text,
        '[ZestSSH] ${en.runOnHostsLogLine}\n'
        '\$ mysql -u deploy -p[redacted] -e status\n'
        'Uptime: 5 days\na warning\n'
        '\n[ZestSSH] ${en.runOnHostsOk}\n');
    expect(text, isNot(contains('hunter22')));
    expect(TeamSessionLogs.secretsKept, 0);

    // A run stopped while its command runs: its log says it was stopped.
    await owner.service.deleteTeamSessionLog(crate, (await owner.service.teamSessionLogs(id, crate)).entries.single.id);
    final second = PlayedServer();
    Future<void> hangs(bool Function() over) async {
      await second.greet();
      if (!await PlayedSignIn(ways: ['publickey'], takesKey: true).play(second, over: over)) return;
      final channel = await second.confirmChannel();
      await channel.nextRequest();
      second.send([channel.success, channel.data('working\n')]);
    }

    final stopped = RunOnHostsNotifier((host) async {
      final ssh = SshService(
        host: host.host,
        port: host.port,
        username: 'deploy',
        keyPairs: [key],
        keepAliveSeconds: 0,
        onHostKeyVerify: (_, _, _) async => true,
        tunnelSocket: second.socket,
      );
      var failed = false;
      // (The run is stopped under it: the host's part may end anywhere.)
      unawaited(hangs(() => failed).catchError((Object _) {}));
      try {
        await ssh.connectExec();
      } catch (_) {
        failed = true;
        rethrow;
      }
      await startTeamSessionLogFor(alice.service, db, 'run_web1_2',
          connectionId: 'web1', label: 'Web 1', host: host.host, port: host.port, user: 'deploy');
      return RunClient(ssh, teamLog: TeamSessionLogs.isLogged('run_web1_2') ? 'run_web1_2' : null);
    });
    addTearDown(stopped.dispose);
    final going = stopped.run([(await db.connectionsDao.getById('web1'))!], 'make');
    for (var i = 0; i < 250 && stopped.state!.hosts.single.state != HostRunState.running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    stopped.stop();
    await going;
    var stoppedText = '';
    for (var i = 0; i < 250 && !stoppedText.contains(en.runOnHostsStopped); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final entries = (await owner.service.teamSessionLogs(id, crate)).entries;
      if (entries.isNotEmpty && entries.single.closed) {
        stoppedText = (await owner.service.teamSessionLogText(id, crate, entries.single)).text;
      }
    }
    expect(stoppedText, contains(r'$ make'));
    expect(stoppedText, endsWith('\n[ZestSSH] ${en.runOnHostsStopped}\n'));
  });

  test('ZestSSH Cloud away as a session starts: it is logged all the same, kept sealed on the device, and sent '
      'whole by the next sync', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    _Clock();

    server.down = true;
    final log = (await start(alice, id, crate))!;
    expect(server.askedWhileDown, 1, reason: 'asked once, as the log starts');
    expect(log.onDevice.value, isTrue, reason: 'its start was not taken: the log waits on this device');
    log.addSecret('hunter2-pass');
    log.append('deploy@web1:~\$ echo hunter2-pass\r\nhunter2-pass\r\n');
    await log.flush();
    log.append('done\r\n');
    await log.close();
    expect(server.askedWhileDown, 1, reason: 'left alone since: it did not answer a moment ago');
    expect((log.waiting, log.stopped), (3, false));
    expect(server.sessionLogRows[crate], isNull);
    expect(await alice.service.sessionLogsWaiting(id), 1);
    // The log's start and its chunks, each under a name of its own, in
    // order, and sealed: nothing of the session reads in the database.
    expect(await kept(alice, id),
        ['sessionlog.${log.logId}', for (var i = 1; i <= 3; i++) 'sessionlog.${log.logId}.0000000$i']);
    for (final name in await kept(alice, id)) {
      final row = await keptRow(alice, id, name);
      final sealed = utf8.decode(base64Decode((row['sealed'] ?? row['header'])! as String), allowMalformed: true);
      for (final plain in ['deploy', 'web1', 'Web 1', 'echo', 'hunter2', 'done', _alice]) {
        expect(sealed, isNot(contains(plain)), reason: name);
      }
    }
    expect((await keptRow(alice, id, 'sessionlog.${log.logId}'))['started'], 0);
    expect((await keptRow(alice, id, 'sessionlog.${log.logId}.00000003'))['last'], isTrue);

    // The server answers again: the next sync sends it, and nothing of it
    // stays on the device.
    server.down = false;
    await sync(alice, id);
    expect(await read(owner, id, crate, log.logId), ('deploy@web1:~\$ echo [redacted]\n[redacted]\ndone\n', true, true));
    expect(await kept(alice, id), isEmpty);
    expect(await alice.service.sessionLogsWaiting(id), 0);
    final calls = (server.sessionLogStartCalls, server.sessionLogChunkCalls);
    await sync(alice, id);
    expect((server.sessionLogStartCalls, server.sessionLogChunkCalls), calls, reason: 'a sync with nothing kept asks nothing');
  });

  test('the server lost in the middle of a session: what it did not take waits on the device, the session leaves '
      'the server alone for longer each time, and all of it goes in order once it answers', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    final clock = _Clock();

    final log = (await start(alice, id, crate))!;
    expect((await keptRow(alice, id, 'sessionlog.${log.logId}'))['started'], 1);
    log.append('one\n');
    await log.flush();
    expect(server.sessionLogRows[crate]!.single.chunks, hasLength(1));
    expect(await kept(alice, id), ['sessionlog.${log.logId}'], reason: 'its place stays while its session goes on');

    server.down = true;
    log.append('two\n');
    await log.flush();
    expect((server.askedWhileDown, log.waiting), (1, 1));
    var asked = 1;
    for (final wait in [15, 30, 60, 120, 240, 300, 300]) {
      clock.pass(Duration(seconds: wait - 1));
      log.append('still away\n');
      await log.flush();
      expect(server.askedWhileDown, asked, reason: 'not before $wait seconds have passed');
      clock.pass(const Duration(seconds: 1));
      await log.flush();
      expect(server.askedWhileDown, ++asked, reason: 'once $wait seconds have passed');
    }
    expect(log.waiting, 8);

    // It answers: everything goes with the next try, in order, and the
    // next time it is lost the wait is short again.
    server.down = false;
    clock.pass(const Duration(minutes: 5));
    log.append('back\n');
    await log.flush();
    expect(log.waiting, 0);
    server.down = true;
    log.append('lost again\n');
    await log.flush();
    asked = server.askedWhileDown;
    clock.pass(const Duration(seconds: 14));
    await log.flush();
    expect(server.askedWhileDown, asked);
    clock.pass(const Duration(seconds: 1));
    await log.flush();
    expect(server.askedWhileDown, asked + 1, reason: 'fifteen seconds again');
    server.down = false;
    clock.pass(const Duration(seconds: 30));
    await log.close();
    expect(await read(owner, id, crate, log.logId),
        ('one\ntwo\n${'still away\n' * 7}back\nlost again\n', true, true));
    expect(server.sessionLogRows[crate]!.single.chunks.map((c) => c.seq), [for (var i = 1; i <= 12; i++) i]);
    expect(await kept(alice, id), isEmpty);
  });

  test('the app ended in the middle of a session: its next run sends what was kept, and the log reads as cut '
      'short', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    _Clock();

    // One whose start the server took, one it never heard of.
    final begun = (await start(alice, id, crate))!;
    server.down = true;
    begun.append('before the end\n');
    await begun.flush();
    begun.append('half a line that never ended');
    final unheard = (await start(alice, id, crate))!;
    // The app ends here: nothing is closed.
    alice.service.debugSessionLogsNewRun();
    server.down = false;
    expect(await alice.service.sessionLogsWaiting(id), 2);
    expect(await alice.service.sessionLogRound(id), 2);
    expect(await read(owner, id, crate, begun.logId), ('before the end\n', false, false));
    expect(await read(owner, id, crate, unheard.logId), ('', false, false), reason: 'who, where and when, at least');
    expect(await kept(alice, id), isEmpty);
    expect(await alice.service.sessionLogRound(id), 0, reason: 'nothing waits');

    // A log that was started and had nothing waiting when the app ended:
    // only its place is left, and goes.
    final idle = (await start(alice, id, crate))!;
    expect(await kept(alice, id), ['sessionlog.${idle.logId}']);
    alice.service.debugSessionLogsNewRun();
    expect(await alice.service.sessionLogsWaiting(id), 0);
    final calls = (server.sessionLogStartCalls, server.sessionLogChunkCalls);
    expect(await alice.service.sessionLogRound(id), 0);
    expect(await kept(alice, id), isEmpty);
    expect((server.sessionLogStartCalls, server.sessionLogChunkCalls), calls, reason: 'nothing to send');
  });

  test('a log the server refuses for good is not kept, as it starts or later, and its writer stops', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    _Clock();

    // Off on the server, on as this device's record still says.
    await owner.service.setCrateSessionLogs(id, crate, false);
    expect(await start(alice, id, crate), isNull);
    expect(await kept(alice, id), isEmpty);

    // Turned off while a log waits on the device.
    await owner.service.setCrateSessionLogs(id, crate, true);
    server.down = true;
    final log = (await start(alice, id, crate))!;
    log.append('kept\n');
    await log.flush();
    final other = (await start(alice, id, crate))!;
    other.append('kept as well\n');
    await other.close();
    server.down = false;
    await owner.service.setCrateSessionLogs(id, crate, false);
    expect(await alice.service.sessionLogsWaiting(id), 2);
    expect(await alice.service.sessionLogRound(id), 0);
    expect(await kept(alice, id), isEmpty);
    expect((log.stopped, log.waiting), (true, 0));
    expect((other.stopped, other.waiting), (false, 2),
        reason: 'a writer whose session ended was let go: nothing reaches it any more');
    log.append('more\n');
    await log.close();
    expect(await kept(alice, id), isEmpty, reason: 'a stopped log keeps nothing more');
    expect(log.waiting, 0, reason: 'and seals nothing more: its end does not count as waiting');
    expect(server.sessionLogRows[crate], isNull);

    // The log deleted by an owner while its session goes on.
    await owner.service.setCrateSessionLogs(id, crate, true);
    final deleted = (await start(alice, id, crate))!;
    deleted.append('one\n');
    await deleted.flush();
    await owner.service.deleteTeamSessionLog(crate, deleted.logId);
    deleted.append('two\n');
    await deleted.flush();
    expect(deleted.stopped, isTrue);
    expect(await kept(alice, id), isEmpty);
  });

  test('held back by the Orchard\'s rules, a log is kept, and goes once the hold has ended', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    _Clock();

    server.held[_alice] = ['two_step'];
    final log = (await start(alice, id, crate))!;
    log.append('while held\n');
    await log.close();
    expect((log.stopped, await alice.service.sessionLogsWaiting(id)), (false, 1));
    expect(await alice.service.sessionLogRound(id), 0, reason: 'still held: it waits');
    expect(await alice.service.sessionLogsWaiting(id), 1);
    server.held.remove(_alice);
    expect(await alice.service.sessionLogRound(id), 1);
    expect(await read(owner, id, crate, log.logId), ('while held\n', true, true));
  });

  test('a device with no room left keeps nothing more of what a session shows, says so once in the log, and goes '
      'on once there is room', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    final clock = _Clock();

    server.down = true;
    final log = (await start(alice, id, crate))!;
    final line = '${'x' * 999}\n';
    log.append(line);
    await log.flush();
    log.append(line);
    await log.flush();
    expect((log.notKept, log.waiting), (false, 2));
    // Room for a little more, and not for another thousand characters.
    final row = await (await alice.db(id))
        .customSelect('''SELECT SUM(LENGTH(value)) AS n FROM local_state WHERE "key" LIKE 'sessionlog.%' ''').getSingle();
    alice.service.debugSessionLogKeepChars = row.read<int>('n') + 600;
    log.append(line);
    await log.flush();
    expect((log.notKept, log.full, log.stopped, log.waiting), (true, false, false, 3), reason: 'the log says so');
    log.append(line);
    await log.flush();
    expect(log.waiting, 3, reason: 'said once');
    log.append('small\n');
    await log.flush();
    expect(log.waiting, 4, reason: 'what there is room for is kept');
    expect(log.notKept, isFalse);
    log.append(line);
    await log.flush();
    expect((log.notKept, log.waiting), (true, 5), reason: 'and said again where more is missing');

    // A second session with no room for what it shows: its log is there,
    // says what is missing, and ends properly.
    final second = (await start(alice, id, crate))!;
    second.append(line);
    await second.close();
    expect(second.waiting, 2);

    // The server takes all of it: there is room again.
    server.down = false;
    clock.pass(const Duration(minutes: 5));
    await sync(alice, id);
    expect(await kept(alice, id), ['sessionlog.${log.logId}']);
    log.append(line);
    await log.flush();
    expect(log.notKept, isFalse);
    await log.close();
    expect(await read(owner, id, crate, log.logId),
        ('$line$line\n$kSessionLogNotKept\nsmall\n\n$kSessionLogNotKept\n$line', true, true));
    expect(await read(owner, id, crate, second.logId), ('\n$kSessionLogNotKept\n', true, true));
    expect(await kept(alice, id), isEmpty);
  });

  test('what a device keeps is counted, starts and all, taken off as it goes, and counted anew in a new run and '
      'after a log is dropped', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    _Clock();
    Future<int> chars() async => (await (await alice.db(id))
            .customSelect('''SELECT COALESCE(SUM(LENGTH(value)), 0) AS n FROM local_state WHERE "key" LIKE 'sessionlog.%' ''')
            .getSingle())
        .read<int>('n');

    // Five logs' starts, and room for a hundred characters more: a line of
    // six, sealed, is more than that.
    server.down = true;
    final logs = [for (var i = 0; i < 5; i++) (await start(alice, id, crate))!];
    final five = await chars();
    alice.service.debugSessionLogKeepChars = five + 100;
    logs[0].append('small\n');
    await logs[0].flush();
    expect(logs[0].notKept, isTrue, reason: 'the starts count');

    // Four of them end and the server takes everything: what went is no
    // longer counted, and the same line has room.
    for (final log in logs.skip(1)) {
      await log.close();
    }
    server.down = false;
    expect(await alice.service.sessionLogRound(id), 5);
    expect(await kept(alice, id), ['sessionlog.${logs[0].logId}']);
    logs[0].append('small\n');
    await logs[0].flush();
    expect((logs[0].notKept, logs[0].waiting), (false, 0));

    // A new run counts what the database keeps before it adds to it.
    alice.service.debugSessionLogKeepChars = 1 << 30;
    server.down = true;
    logs[0].append('${'x' * 999}\n');
    await logs[0].flush();
    expect(logs[0].waiting, 1);
    alice.service
      ..debugSessionLogKeepChars = await chars() + 100
      ..debugSessionLogsNewRun();
    final fresh = (await start(alice, id, crate))!;
    fresh.append('small\n');
    await fresh.flush();
    expect(fresh.notKept, isTrue, reason: 'what an earlier run kept counts');

    // The server refuses all of it for good: dropped, and counted anew.
    server.down = false;
    await owner.service.setCrateSessionLogs(id, crate, false);
    expect(await alice.service.sessionLogRound(id), 0);
    expect(await kept(alice, id), isEmpty);
    expect(await chars(), 0);
    await owner.service.setCrateSessionLogs(id, crate, true);
    final after = (await start(alice, id, crate))!;
    after.append('small\n');
    await after.flush();
    expect((after.notKept, after.waiting), (false, 0), reason: 'there is room again');
    await after.close();
  });

  test('while the Orchard\'s database is closed (the app locked, or the Orchard past its offline limit) what a '
      'session shows is held and nothing opens the database; it is written, in order, and sent once it is open '
      'again', () async {
    final folder = Directory.systemTemp.createTempSync('zestssh-session-logs');
    final owner = device(_owner);
    final alice = device(_alice, folder: folder);
    addTearDown(() async {
      await alice.close();
      folder.deleteSync(recursive: true);
    });
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    final databases = alice.service.databases;

    final log = (await start(alice, id, crate))!;
    log.append('before\n');
    await log.flush();
    expect(server.sessionLogRows[crate]!.single.chunks, hasLength(1));

    // Closed, as the app's lock closes it.
    await databases.close(id);
    final opens = alice.storage.opens[id];
    log.append('while closed\n');
    await log.flush();
    log.append('and more\n');
    await log.flush();
    expect((log.waiting, log.notKept, log.stopped), (2, false, false));
    expect(await alice.service.sessionLogsWaiting(id), 0, reason: 'nothing can be told of while it is closed');
    expect(await alice.service.sessionLogRound(id), 0);
    expect(alice.storage.opens[id], opens, reason: 'nothing opened it');
    expect(server.sessionLogRows[crate]!.single.chunks, hasLength(1));

    // Open again: the session's next look writes what it held, in order,
    // and sends it.
    await alice.db(id);
    await log.flush();
    expect(log.waiting, 0);
    expect(server.sessionLogRows[crate]!.single.chunks.map((c) => c.seq), [1, 2, 3]);

    // Closed by the Orchard's offline limit as the session ends: the
    // writer holds its end, and a round writes and sends it once the
    // Orchard is open again.
    await databases.closeOffline(id);
    log.append('at the end\n');
    await log.close();
    expect(log.waiting, 2);
    expect(databases.reopenOffline(), isTrue);
    await alice.db(id);
    expect(await kept(alice, id), ['sessionlog.${log.logId}'], reason: 'its place stays while its writer holds more');
    expect(await alice.service.sessionLogRound(id), 1);
    expect(await read(owner, id, crate, log.logId), ('before\nwhile closed\nand more\nat the end\n', true, true));
    expect(await kept(alice, id), isEmpty);

    // A database that fails under the writer (closed without the app
    // knowing): nothing sealed is lost either.
    final second = (await start(alice, id, crate))!;
    await (await alice.db(id)).close();
    second.append('under a failing database\n');
    await second.flush();
    expect((second.waiting, second.notKept, second.stopped), (1, false, false));
    await databases.close(id);
    await alice.db(id);
    await second.close();
    expect(await read(owner, id, crate, second.logId), ('under a failing database\n', true, true));
  });

  test('the app made its service anew while a session goes on: the log still counts as going on, and what the '
      'database keeps is counted once, whoever asks', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    _Clock();

    server.down = true;
    final log = (await start(alice, id, crate))!;
    log.append('before\n');
    await log.flush();
    // The sign-in changed, say: another service object over the same
    // databases, and the session goes on.
    final anew = OrchardService(
      server: alice.server,
      databases: alice.service.databases,
      author: () async => CrateAuthor(uid: _alice, keys: keys[_alice]!),
    );
    server.down = false;
    expect(await anew.sessionLogRound(id), 1);
    expect(await kept(alice, id), ['sessionlog.${log.logId}'], reason: 'its session goes on: its place stays');
    expect(log.waiting, 0);
    log.append('after\n');
    await log.close();
    expect(await read(owner, id, crate, log.logId), ('before\nafter\n', true, true));
    expect(await kept(alice, id), isEmpty);
    // (An answer the one service got ended the wait the other had begun:
    // how the database's server stands is the database's.)

    // What a writer of the first service keeps from here on leaves no room
    // for one of the second, which counted before.
    server.down = true;
    final first = (await start(alice, id, crate))!;
    final line = '${'x' * 999}\n';
    first.append(line);
    await first.flush();
    final row = await (await alice.db(id))
        .customSelect('''SELECT SUM(LENGTH(value)) AS n FROM local_state WHERE "key" LIKE 'sessionlog.%' ''').getSingle();
    anew.debugSessionLogKeepChars = row.read<int>('n') + 600;
    final second = (await anew.startTeamSessionLog(id, crate,
        label: 'Web 1', host: 'web1.example.com', port: 22,
        flushEvery: const Duration(hours: 1), flushAtBytes: 1 << 20))!;
    second.append(line);
    await second.flush();
    expect(second.notKept, isTrue);
  });

  test('what is kept goes with the log whose session started first before the others', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    final clock = _Clock();

    server.down = true;
    final logs = <TeamSessionLogWriter>[];
    for (var i = 1; i <= 6; i++) {
      final log = (await start(alice, id, crate))!;
      log.append('session $i\n');
      await log.close();
      logs.add(log);
      clock.pass(const Duration(minutes: 1));
    }
    server.down = false;
    expect(await alice.service.sessionLogRound(id), 6);
    expect(server.sessionLogRows[crate]!.map((l) => l.id), [for (final l in logs) l.logId]);
    for (var i = 1; i <= 6; i++) {
      expect(await read(owner, id, crate, logs[i - 1].logId), ('session $i\n', true, true));
    }
  });

  test('a start or a chunk whose answer never arrived is not sent as new; a round ends at the first log the server '
      'cannot take now', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    final clock = _Clock();

    server.down = true;
    final logs = <TeamSessionLogWriter>[];
    for (final text in ['first\n', 'second\n', 'third\n']) {
      final log = (await start(alice, id, crate))!;
      log.append(text);
      await log.close();
      logs.add(log);
      clock.pass(const Duration(minutes: 1));
    }
    server.down = false;

    // The server took the first log's start and its first chunk; its
    // answers never reached the device.
    final head = await keptRow(alice, id, 'sessionlog.${logs[0].logId}');
    await alice.server.startSessionLog(crate, logs[0].logId,
        keyGeneration: head['gen']! as int, header: base64Decode(head['header']! as String));
    final chunk = await keptRow(alice, id, 'sessionlog.${logs[0].logId}.00000001');
    await alice.server.sendSessionLogChunk(crate, logs[0].logId,
        seq: 1, keyGeneration: head['gen']! as int, sealed: base64Decode(chunk['sealed']! as String));

    // It answers five times more and is gone: the first log's three
    // requests, the second's start and first chunk.
    server.downAfter = 5;
    final away = server.askedWhileDown;
    expect(await alice.service.sessionLogRound(id), 1);
    expect(server.askedWhileDown, away + 1, reason: 'it did not go on to the third');
    server.down = false;
    expect(server.sessionLogRows[crate]!.map((l) => l.id), [logs[0].logId, logs[1].logId],
        reason: 'the third was not begun');
    expect(await read(owner, id, crate, logs[0].logId), ('first\n', true, true));
    expect(await read(owner, id, crate, logs[1].logId), ('second\n', false, false));
    expect(await kept(alice, id), [
      'sessionlog.${logs[1].logId}',
      'sessionlog.${logs[1].logId}.00000002',
      'sessionlog.${logs[2].logId}',
      'sessionlog.${logs[2].logId}.00000001',
      'sessionlog.${logs[2].logId}.00000002',
    ]..sort());
    expect(await alice.service.sessionLogsWaiting(id), 2);

    expect(await alice.service.sessionLogRound(id), 2);
    expect(await read(owner, id, crate, logs[1].logId), ('second\n', true, true));
    expect(await read(owner, id, crate, logs[2].logId), ('third\n', true, true));
    expect(await kept(alice, id), isEmpty);
  });

  test('chunks of a log this device no longer keeps are cleared away, what does not read as a log is dropped, and '
      'nothing else the database keeps is touched', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    final store = LocalStateStore(await alice.db(id));
    const gone = 'sessionlog.11111111-2222-4333-8444-555555555555';
    const unread = 'sessionlog.99999999-2222-4333-8444-555555555555';
    const listed = 'sessionlog.88888888-2222-4333-8444-555555555555';
    const shaped = 'sessionlog.77777777-2222-4333-8444-555555555555';
    await store.write('$gone.00000001', jsonEncode({'last': false, 'sealed': 'AAAA'}));
    await store.write('$gone.00000002', jsonEncode({'last': true, 'sealed': 'AAAA'}));
    await store.write(unread, 'not a log');
    await store.write('$unread.00000001', jsonEncode({'last': true, 'sealed': 'AAAA'}));
    await store.write(listed, '[1, 2]');
    await store.write(shaped, jsonEncode({'crate': 5, 'gen': 'one', 'header': 'AAAA', 'at': 0, 'started': 0}));
    // Names that only look alike.
    const others = ['sessionlog', 'sessionlog-x', 'sessionlog/', 'sessionlog/x', 'sessionlogs.x', 'sessionlo', 'unwatched.x'];
    for (final name in others) {
      await store.write(name, 'kept');
    }
    expect(await alice.service.sessionLogsWaiting(id), 3, reason: 'those whose start is there');
    final asked = server.asked;
    expect(await alice.service.sessionLogRound(id), 0);
    expect(await kept(alice, id), isEmpty);
    expect(server.asked, asked, reason: 'the server was asked nothing');
    for (final name in others) {
      expect(await store.read(name), 'kept', reason: name);
    }

    // A chunk that does not read ends its log where it stands.
    server.down = true;
    final cut = <String>[];
    for (final unreadable in ['not a chunk', '[1, 2]', jsonEncode({'last': 'no', 'sealed': 7})]) {
      final log = (await start(alice, id, crate))!;
      log.append('one\n');
      await log.flush();
      log.append('two\n');
      await log.flush();
      log.append('three\n');
      await log.close();
      await store.write('sessionlog.${log.logId}.00000002', unreadable);
      cut.add(log.logId);
    }
    server.down = false;
    expect(await alice.service.sessionLogRound(id), 0);
    for (final logId in cut) {
      expect(await read(owner, id, crate, logId), ('one\n', false, false));
    }
    expect(await kept(alice, id), isEmpty);
  });

  test('a sync does not fail for a log the server cannot take now, and sends it when it can', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    final clock = _Clock();

    // An older session that goes on, with nothing waiting.
    final idle = (await start(alice, id, crate))!;
    clock.pass(const Duration(minutes: 1));
    final log = (await start(alice, id, crate))!;
    server.sessionLogChunkFault = (_) => const OrchardServerException(503, 'unavailable');
    log.append('kept through a fault\n');
    await log.close();
    expect(await alice.service.sessionLogsWaiting(id), 1);
    // Ten of the fifteen seconds the sessions leave the server alone for.
    clock.pass(const Duration(seconds: 10));
    final calls = server.sessionLogChunkCalls;
    final reports = await sync(alice, id);
    expect(reports[id]!.held, isFalse, reason: 'the sync went through');
    expect(server.sessionLogChunkCalls, calls + 1, reason: 'a sync asks, whatever wait the sessions keep');
    expect(await alice.service.sessionLogsWaiting(id), 1);

    // That try failed during the wait, which is no longer for it, and the
    // older session's turn in the round asked nothing of the server, which
    // ends no wait: a session asks again once the fifteen seconds are
    // over, not before and not later.
    final starts = server.sessionLogStartCalls;
    clock.pass(const Duration(seconds: 4));
    final early = (await start(alice, id, crate))!;
    expect(server.sessionLogStartCalls, starts, reason: 'not yet');
    clock.pass(const Duration(seconds: 1));
    final onTime = (await start(alice, id, crate))!;
    expect(server.sessionLogStartCalls, starts + 1);

    // The server took that start: an answer, after which the wait starts
    // anew. The next thing it does not take is left alone for fifteen
    // seconds again, not for thirty.
    await early.close();
    expect(server.sessionLogStartCalls, starts + 2, reason: 'its start went in, its end did not');
    clock.pass(const Duration(seconds: 14));
    final soon = (await start(alice, id, crate))!;
    expect(server.sessionLogStartCalls, starts + 2);
    clock.pass(const Duration(seconds: 1));
    final anew = (await start(alice, id, crate))!;
    expect(server.sessionLogStartCalls, starts + 3);
    for (final open in [onTime, idle, soon, anew]) {
      await open.close();
    }

    server.sessionLogChunkFault = null;
    await sync(alice, id);
    expect(await read(owner, id, crate, log.logId), ('kept through a fault\n', true, true));
    expect(await kept(alice, id), isEmpty);
    expect(server.sessionLogRows[crate], hasLength(6));
  });

  test('while the app knows that ZestSSH Cloud is not answering, a session\'s log asks nothing of it', () async {
    var away = false;
    final owner = device(_owner);
    final alice = device(_alice, cloudAway: () => away);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);

    away = true;
    final asked = server.asked;
    final log = (await start(alice, id, crate))!;
    log.append('quiet\n');
    await log.flush();
    await log.close();
    expect(server.asked, asked);
    expect((log.waiting, await alice.service.sessionLogsWaiting(id)), (2, 1));
    // A sync that got through asks all the same.
    expect(await alice.service.sessionLogRound(id), 1);
    expect(await read(owner, id, crate, log.logId), ('quiet\n', true, true));

    // Known to answer, it is asked as the log starts.
    away = false;
    final second = (await start(alice, id, crate))!;
    expect(server.sessionLogRows[crate]!.map((l) => l.id), contains(second.logId));
    await second.close();
  });

  test('through the registry a terminal feeds, with ZestSSH Cloud away: the session shows as logged, and what it '
      'shows is kept and sent later', () async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await (await owner.db(id)).customStatement(
        "INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES ('web1', 'Web 1', 'web1.example.com', 22, 0, 0)");
    await owner.coordinator.syncAll();
    await sync(alice, id);
    _Clock();

    server.down = true;
    await startTeamSessionLogFor(alice.service, await alice.db(id), 's1',
        connectionId: 'web1', label: 'Web 1', host: 'web1.example.com', port: 22, user: 'deploy');
    expect(TeamSessionLogs.isLogged('s1'), isTrue);
    TeamSessionLogs.append('s1', 'shown while the log was starting\n');
    // The log starts in the background: the server is asked, does not
    // answer, and the log is there all the same.
    for (var i = 0; i < 200 && server.askedWhileDown == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(TeamSessionLogs.isLogged('s1'), isTrue, reason: 'kept on the device: logged');
    expect(TeamSessionLogs.waiting.value, {'s1'}, reason: 'and said to wait there');
    TeamSessionLogs.append('s1', 'and after\n');
    await TeamSessionLogs.end('s1');
    expect(TeamSessionLogs.isLogged('s1'), isFalse);
    expect(TeamSessionLogs.waiting.value, isEmpty, reason: 'the session is over: nothing is shown of it');
    expect(await alice.service.sessionLogsWaiting(id), 1);

    server.down = false;
    await sync(alice, id);
    final entry = (await owner.service.teamSessionLogs(id, crate)).entries.single;
    expect(entry.header.connectionId, 'web1');
    expect(await read(owner, id, crate, entry.id), ('shown while the log was starting\nand after\n', true, true));
  });

  test('a log says whether it waits on this device: from a send that did not get through until one that does',
      () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    _Clock();

    // The server answers: nothing waits, before or after anything is shown.
    final first = (await start(alice, id, crate))!;
    expect(first.onDevice.value, isFalse);
    first.append('one\n');
    await first.flush();
    expect((first.onDevice.value, first.waiting), (false, 0));

    // It goes away under the session: what was sealed waits.
    server.down = true;
    first.append('two\n');
    await first.flush();
    expect((first.onDevice.value, first.waiting), (true, 1));
    // A log that starts meanwhile waits from its start, with nothing shown.
    final second = (await start(alice, id, crate))!;
    expect((second.onDevice.value, second.waiting), (true, 0));

    // It answers again: the round of the next sync takes what both keep.
    server.down = false;
    await sync(alice, id);
    expect((first.onDevice.value, first.waiting), (false, 0));
    expect((second.onDevice.value, second.waiting), (false, 0));
    // And the sessions go on as before.
    first.append('three\n');
    await first.close();
    await second.close();
    expect(await read(owner, id, crate, first.logId), ('one\ntwo\nthree\n', true, true));
  });

  test('the sessions whose log waits, as the chip is told: from the send that failed until one gets through, and '
      'not once the session has ended', () async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    _Clock();

    TeamSessionLogs.expect('s1');
    expect(TeamSessionLogs.waiting.value, isEmpty, reason: 'a log that is starting is not said to wait');
    final first = (await start(alice, id, crate))!;
    TeamSessionLogs.started('s1', first);
    expect(TeamSessionLogs.waiting.value, isEmpty);

    server.down = true;
    TeamSessionLogs.append('s1', 'shown\n');
    await first.flush();
    expect(TeamSessionLogs.waiting.value, {'s1'});
    // A second session, whose log waits from its start.
    TeamSessionLogs.expect('s2');
    final second = (await start(alice, id, crate))!;
    TeamSessionLogs.started('s2', second);
    expect(TeamSessionLogs.waiting.value, {'s1', 's2'});

    // Ended while its log waits: it is off the list with its session, and
    // what its writer finds out afterwards reaches nobody.
    await TeamSessionLogs.end('s2');
    expect(TeamSessionLogs.waiting.value, {'s1'});
    second.onDevice.value = false;
    second.onDevice.value = true;
    expect(TeamSessionLogs.waiting.value, {'s1'});

    server.down = false;
    await sync(alice, id);
    expect(TeamSessionLogs.waiting.value, isEmpty);
    expect(TeamSessionLogs.isLogged('s1'), isTrue, reason: 'logged all along');
    await TeamSessionLogs.end('s1');
    expect(TeamSessionLogs.waiting.value, isEmpty);
  });

  test('requests are spaced for a server that limits them: twenty at once from all the logs together, and the '
      'next once the oldest of them is forty seconds ago', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    final clock = _Clock();
    alice.onSleep = clock.pass;
    var lines = 0;
    Future<void> send(TeamSessionLogWriter log, int requests) async {
      for (var i = 0; i < requests; i++) {
        log.append('line ${++lines}\n');
        await log.flush();
      }
    }

    // Ten requests now (two logs' starts and eight chunks), ten more ten
    // seconds on: twenty, none of which waited.
    final log = (await start(alice, id, crate))!;
    final other = (await start(alice, id, crate))!;
    await send(log, 4);
    await send(other, 4);
    clock.pass(const Duration(seconds: 10));
    await send(log, 5);
    await send(other, 5);
    expect(alice.slept, isEmpty);
    // Two more at once, five seconds later: one waits until the first is
    // forty seconds ago, and by then the first ten all are, so the other
    // goes right after it.
    clock.pass(const Duration(seconds: 5));
    await Future.wait([send(other, 1), send(log, 1)]);
    expect(alice.slept, [const Duration(seconds: 25)]);
    // Eight more go at once, and the one after waits for the eleventh's
    // forty seconds.
    await send(log, 8);
    expect(alice.slept, hasLength(1));
    await send(log, 1);
    expect(alice.slept, [const Duration(seconds: 25), const Duration(seconds: 10)]);
    // Nine more at once, and the next waits for the request that waited
    // first: forty seconds after it went, not after it was asked for.
    await send(other, 9);
    expect(alice.slept, hasLength(2));
    await send(other, 1);
    expect(alice.slept, [const Duration(seconds: 25), const Duration(seconds: 10), const Duration(seconds: 30)]);

    await log.close();
    await other.close();
    expect((await read(owner, id, crate, log.logId)).$2, isTrue);
    expect((await read(owner, id, crate, other.logId)).$2, isTrue);
    expect(server.sessionLogRows[crate]!.expand((l) => l.chunks), hasLength(lines + 2));
  });

  test('a sync does not wait for the round it starts, which goes on by itself; asked for again meanwhile, it is '
      'the same round', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    final clock = _Clock();

    server.down = true;
    final log = (await start(alice, id, crate))!;
    for (var i = 1; i <= 25; i++) {
      log.append('line $i\n');
      await log.flush();
    }
    await log.close();
    server.down = false;
    clock.pass(const Duration(minutes: 1));

    // The twenty-first request waits for its turn for as long as the test
    // holds it.
    final turn = Completer<void>();
    alice.service.debugSessionLogSleep = (_) => turn.future;
    final reports = await alice.coordinator.syncAll();
    expect(reports[id]!.held, isFalse, reason: 'the sync is done');
    final round = alice.service.debugSessionLogRound(id);
    expect(round, isNotNull, reason: 'and the round it started goes on');
    for (var i = 0; i < 300 && (server.sessionLogRows[crate]?.single.chunks.length ?? 0) < 19; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(server.sessionLogRows[crate]!.single.chunks, hasLength(19), reason: 'the start and nineteen chunks');
    expect(await alice.service.sessionLogsWaiting(id), 1);

    final again = alice.service.sessionLogRound(id);
    expect(identical(again, alice.service.sessionLogRound(id)), isTrue, reason: 'one round, whoever asks');
    final calls = server.sessionLogChunkCalls;
    turn.complete();
    expect(await again, 1);
    await round;
    expect(server.sessionLogChunkCalls, calls + 7, reason: 'each of the rest once');
    expect(await read(owner, id, crate, log.logId), ([for (var i = 1; i <= 25; i++) 'line $i\n'].join(), true, true));
    expect(await kept(alice, id), isEmpty);
    expect(await alice.service.sessionLogRound(id), 0, reason: 'a round of its own again, with nothing to send');
  });

  test('a round that fails does not fail the sync that asked for it, and is not kept as the round under way', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, _) = await team(owner, alice);
    // The database fails under whoever asks of it (closed without the app
    // knowing).
    await (await alice.db(id)).close();
    await alice.service.sessionLogCatchUp(id);
    final first = alice.service.sessionLogRound(id);
    await expectLater(first, throwsA(anything));
    final second = alice.service.sessionLogRound(id);
    expect(identical(first, second), isFalse, reason: 'asked anew');
    await expectLater(second, throwsA(anything));
  });

  test('while something sealed still waits to be sent, what a session shows is sealed less often, and at the usual '
      'pace again once the server has it', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    _Clock();
    const short = Duration(milliseconds: 20), long = Duration(seconds: 2);
    Future<void> until(bool Function() there, String what) async {
      for (var i = 0; i < 500 && !there(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(there(), isTrue, reason: what);
    }

    server.down = true;
    final log = (await alice.service.startTeamSessionLog(id, crate,
        label: 'Web 1', host: 'web1.example.com', port: 22,
        flushEvery: short, slowFlushEvery: long, flushAtBytes: 1 << 20))!;
    expect(log.flushDelay, short);
    log.append('first\n');
    await until(() => log.waiting == 1, 'sealed at the short interval');
    expect(log.flushDelay, long, reason: 'something waits');

    log.append('second\n');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(log.waiting, 1, reason: 'not at the short interval any more');
    await until(() => log.waiting == 2, 'sealed at the long one');

    // Told to wait long while something waited, then the server takes
    // what waited: sealed and sent at the short interval.
    log.append('third\n');
    server.down = false;
    expect(await alice.service.sessionLogRound(id), 1);
    expect((log.waiting, log.flushDelay), (0, short));
    final asked = Stopwatch()..start();
    await until(() => server.sessionLogRows[crate]!.single.chunks.length == 3, 'the third chunk');
    expect(asked.elapsed, lessThan(const Duration(milliseconds: 1500)), reason: 'not after the long interval');
    await log.close();
    expect(await read(owner, id, crate, log.logId), ('first\nsecond\nthird\n', true, true));

    // A writer told to wait an hour between its chunks is not told to
    // seal sooner while something waits.
    final hourly = (await start(alice, id, crate))!;
    server.down = true;
    hourly.append('kept\n');
    await hourly.flush();
    expect((hourly.waiting, hourly.flushDelay), (1, const Duration(hours: 1)));
    server.down = false;
    await hourly.close();
  });

  test('which of the server\'s answers end a log for good, and which only make it wait', () {
    bool forGood(int status, [String? code]) => sessionLogRefusedForGood(OrchardServerException(status, code));
    expect([
      forGood(409, 'session-logs-off'),
      forGood(404, 'not-found'),
      forGood(409, 'log-closed'),
      forGood(409, 'out-of-order'),
      forGood(409, 'id-taken'),
      forGood(413, 'log-full'),
      forGood(413, 'session-logs-team-full'),
      forGood(400, 'invalid-request'),
      forGood(403, 'read-only'),
      forGood(403),
      forGood(499),
    ], everyElement(isTrue));
    expect([
      forGood(401, 'unauthenticated'),
      forGood(408),
      forGood(429, 'rate-limited'),
      forGood(403, 'rules-unmet'),
      forGood(403, 'directory-removed'),
      forGood(500),
      forGood(502),
      forGood(503, 'unavailable'),
      forGood(399),
      forGood(200),
    ], everyElement(isFalse));
    // Only a 403 is a hold: the same words on another status are not.
    expect([forGood(409, 'rules-unmet'), forGood(404, 'directory-removed')], everyElement(isTrue));
  });

  test('a log whose start the server took well after its session began says so', () async {
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    await owner.service.setCrateSessionLogs(id, crate, true);
    await sync(alice, id);
    final clock = _Clock();
    server.clock = () => clock.now;

    Future<String> sentAfter(Duration time) async {
      server.down = true;
      final log = (await start(alice, id, crate))!;
      await log.close();
      clock.pass(time);
      server.down = false;
      expect(await alice.service.sessionLogRound(id), 1);
      return log.logId;
    }

    expect(kSessionLogLate, const Duration(minutes: 10), reason: 'under it, clocks that differ a little say nothing');
    final atOnce = (await start(alice, id, crate))!;
    await atOnce.close();
    final soon = await sentAfter(kSessionLogLate);
    final slow = await sentAfter(kSessionLogLate + const Duration(seconds: 1));
    final entries = {for (final e in (await owner.service.teamSessionLogs(id, crate)).entries) e.id: e};
    expect([for (final l in [atOnce.logId, soon, slow]) entries[l]!.receivedLater], [false, false, true]);
    expect(entries[slow]!.receivedAt.difference(entries[slow]!.header.startedAt),
        kSessionLogLate + const Duration(seconds: 1));
  });

  test('those who can open the Crate are told when its session logs change; its author and others are not', () async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    // A second Crate alice cannot open.
    final secret = await owner.service.createCrate(id, 'Secret', ownersOnly: true);
    await sync(alice, id);
    final aliceDb = await alice.db(id);
    final ownerDb = await owner.db(id);
    expect(await takeTeamNotices(aliceDb, id), isEmpty, reason: 'the first look only notes where things stand');
    expect(await takeTeamNotices(ownerDb, id), isEmpty);

    Future<List<(String, String?)>> told(_Device d) async {
      await d.coordinator.syncAll();
      final notes = await takeTeamNotifications({id: await d.db(id)},
          me: d.uid, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard');
      return [for (final n in notes) (n.title, n.body)];
    }

    await owner.service.setCrateSessionLogs(id, crate, true);
    await owner.service.setCrateSessionLogs(id, secret, true);
    expect(await told(alice), [
      (l10n.noticeSessionLogsOnTitle('Production'), l10n.noticeSessionLogsOnBody('owner-1@example.com', 'The Acme Orchard')),
    ], reason: 'Secret is not hers to open');
    expect(await told(owner), isEmpty, reason: 'its own change');

    await owner.service.setCrateSessionLogs(id, crate, false);
    expect(await told(alice), [
      (l10n.noticeSessionLogsOffTitle('Production'), l10n.noticeSessionLogsOffBody('owner-1@example.com', 'The Acme Orchard')),
    ]);
  });

  test('those who can open the Crate are told when its sessions become watched and when that ends; an entry '
      'that changes nothing tells nobody, and one that changes two things tells both', () async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final owner = device(_owner);
    final alice = device(_alice);
    final (id, crate) = await team(owner, alice);
    final secret = await owner.service.createCrate(id, 'Secret', ownersOnly: true);
    await sync(alice, id);
    expect(await takeTeamNotices(await alice.db(id), id), isEmpty, reason: 'the first look only notes where things stand');
    expect(await takeTeamNotices(await owner.db(id), id), isEmpty);

    Future<List<(String, String, String?)>> told(_Device d) async {
      await d.coordinator.syncAll();
      final notes = await takeTeamNotifications({id: await d.db(id)},
          me: d.uid, l10n: l10n, orchardName: (name) => 'The ${name ?? '?'} Orchard');
      return [for (final n in notes) (n.id, n.title, n.body)];
    }

    final on = (l10n.noticeWatchedOnTitle('Production'), l10n.noticeWatchedOnBody('owner-1@example.com', 'The Acme Orchard'));
    final off = (l10n.noticeWatchedOffTitle('Production'), l10n.noticeWatchedOffBody('owner-1@example.com', 'The Acme Orchard'));
    expect(on.$2, contains('starts only once someone who manages the vault is watching'));

    await owner.service.setCrateWatched(id, crate, true);
    await owner.service.setCrateWatched(id, secret, true);
    var seq = server.entriesOf(id).last.seq - 1;
    expect(await told(alice), [('orchard-notice-$id-$seq-watched', on.$1, on.$2)], reason: 'Secret is not hers to open');
    expect(await told(owner), isEmpty, reason: 'its own change');

    // Said again as it stands: nobody is told anything.
    await owner.service.setCrateWatched(id, crate, true);
    await owner.service.setCrateAllow(id, crate, const {});
    expect(await told(alice), isEmpty);

    // One entry turns watching off and session logs on: two notices, each
    // with an id of its own.
    await owner.service.change(id, RecordTypes.crateSet, {'id': crate, 'watched': false, 'session_logs': true});
    seq = server.entriesOf(id).last.seq;
    expect(await told(alice), [
      (
        'orchard-notice-$id-$seq',
        l10n.noticeSessionLogsOnTitle('Production'),
        l10n.noticeSessionLogsOnBody('owner-1@example.com', 'The Acme Orchard'),
      ),
      ('orchard-notice-$id-$seq-watched', off.$1, off.$2),
    ]);
    // Turned off where it was off: nothing.
    await owner.service.setCrateWatched(id, crate, false);
    expect(await told(alice), isEmpty);

    // The record's own log, in words (the Team page shows them, and the
    // device that sends the team's events on writes them in English).
    final local = await LocalRecord.load(await owner.db(id), id);
    final changes = await teamChanges(id, local.entries);
    String words(TeamChange c) => teamChangeText(c, l10n,
        nameOf: (uid) => '$uid', crateName: (c) => c == crate ? 'Production' : 'Secret', roleName: (r) => r);
    final watched = [
      for (final c in changes)
        if (c.kind == TeamChangeKind.watchedOn || c.kind == TeamChangeKind.watchedOff) words(c),
    ];
    expect(watched, [
      'Turned watched sessions on for Production',
      'Turned watched sessions on for Secret',
      'Turned watched sessions on for Production',
      'Turned watched sessions off for Production',
    ]);
  });
}

