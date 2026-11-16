import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/models/enums.dart';

import '../../helpers/record_commits.dart';

import 'fake_crate_server.dart';

/// Remote screens in a team (4.0): a VNC host and its
/// carrier (the SSH host it is reached through, its connect_via_id) are shared
/// under the SSH hosts' rules; a screen's record is of format 3, which 3.4
/// (format 2) and older versions refuse as a record that does not open, so
/// they never see one and lose nothing, and read their vaults again once they
/// update; a team's host never changes kind class; a screen is never opened
/// where its team watches sessions; and a team's log of a screen holds who,
/// which host and when, never the picture.

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _owner = 'owner-1';
const _alice = 'alice-1';
const _writer = 'role-writer';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AccountKeys ownerKeys;
  late AccountKeys aliceKeys;
  late Uint8List crateKey;
  late FakeCrateServer server;
  late List<RecordEntry> entries;
  late List<RecordEntry> watchedEntries;
  final dbs = <AppDatabase>[];

  setUpAll(() async {
    ownerKeys = await AccountKeys.generate();
    aliceKeys = await AccountKeys.generate();
    final chain = <RecordEntry>[];
    Future<void> add(String type, Map<String, Object?> body) async {
      chain.add(await signRecordEntry(ownerKeys,
          orchardId: _orchard,
          seq: chain.length + 1,
          prev: chain.isEmpty ? const [] : chain.last.hash(_orchard),
          type: type,
          body: body,
          by: _owner));
    }

    await add(RecordTypes.create, {
      'owner': {...recordKeysBody(await ownerKeys.publish(_owner)), 'uid': _owner},
      'key_commit': testCommit('orchard'),
      'crate': {'id': _crate, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(_crate)},
      'roles': [
        {
          'id': _writer,
          'rank': 30,
          'name_enc': base64Encode(utf8.encode('sealed-$_writer')),
          'name_gen': 1,
          'can': const <String>[],
          'crates': {
            _crate: ['add', 'connect', 'edit'],
          },
        },
      ],
    });
    await add(RecordTypes.memberAdd, {...recordKeysBody(await aliceKeys.publish(_alice)), 'uid': _alice, 'role': _writer});
    entries = [...chain];
    // The owner then has the vault's sessions watched (the terminal only).
    await add(RecordTypes.crateSet, {'id': _crate, 'watched': true, 'allow': <String>[]});
    watchedEntries = [...chain];
  });

  setUp(() {
    crateKey = newSpaceKey();
    server = FakeCrateServer(accountUid: _owner)..addCrate(_crate);
  });

  tearDown(() async {
    for (final db in dbs) {
      await db.close();
    }
    dbs.clear();
  });

  Future<List<int>?> signers(String who, int version) async => switch (who) {
        _owner when version == ownerKeys.version => ownerKeys.signingPublicKey,
        _alice when version == aliceKeys.version => aliceKeys.signingPublicKey,
        _ => null,
      };

  Future<AppDatabase> teamDb({bool watched = false}) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    dbs.add(db);
    await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
      "VALUES (1, ?, 'Acme', 'owner', 1, ?)",
      [_orchard, _crate],
    );
    await LocalRecord.empty(_orchard).extend(db, watched ? watchedEntries : entries);
    await db.customStatement(
      "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'Production', 'manage', ?, 1)",
      [_crate, jsonEncode(switchList(CrateSwitches.all.difference({CrateSwitches.agent})))],
    );
    await db.customStatement(
      "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('crate', ?, 1, ?)",
      [_crate, crateKey],
    );
    return db;
  }

  /// [db]'s sync engine as [uid] writes, reading item records up to
  /// [readsFormat] (2: as 3.4 reads them).
  CrateSyncEngine engine(AppDatabase db, String uid, AccountKeys keys, {int readsFormat = kItemRecordFormat}) =>
      CrateSyncEngine(
        db: db,
        orchardId: _orchard,
        server: server,
        author: CrateAuthor(uid: uid, keys: keys),
        signers: signers,
        readsFormat: readsFormat,
      );

  final options = ScreenOptions.defaults.copyWith(clipboardLocked: true, viewOnly: true).encode();

  Future<void> addHost(AppDatabase db, String id, {String protocol = 'ssh', String? via, String label = 'web'}) async {
    final now = DateTime(2026, 11, 9);
    final screen = ConnectionProtocol.storedIsScreen(protocol);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: screen ? 'localhost' : '10.0.0.1',
          port: Value(screen ? 5900 : 22),
          protocol: Value(protocol),
          connectViaId: Value(via),
          screenOptions: Value(screen ? options : null),
          createdAt: now,
          updatedAt: now,
        ));
  }

  Future<Map<String, String>> hosts(AppDatabase db) async => {
        for (final r in await db.customSelect('SELECT id, protocol FROM connections ORDER BY id').get())
          r.read<String>('id'): r.read<String>('protocol'),
      };

  Future<({Set<String> read, int refused})> serverAs(int readsFormat) async {
    final idKey = await crateItemIdKey(crateKey, orchardId: _orchard, crateId: _crate);
    final read = <String>{};
    var refused = 0;
    for (final remote in server.items[_crate]!.values) {
      try {
        final rec = await openItem(remote.item!,
            orchardId: _orchard, crateId: _crate, crateKey: crateKey, idKey: idKey, signers: signers, readsFormat: readsFormat);
        read.add('${rec.kind}|${rec.key}');
      } on ItemRejected {
        refused++;
      }
    }
    return (read: read, refused: refused);
  }

  test('two members on 4.0 share a screen and its carrier; 3.4 sees the carrier alone, loses nothing it holds, '
      'and gets the screen once it updates', () async {
    final owner = await teamDb();
    final ownerSync = engine(owner, _owner, ownerKeys);
    final alice = await teamDb();
    final aliceSync = engine(alice, _alice, aliceKeys);
    // The owner's laptop, still on 3.4.
    final older = await teamDb();
    var olderSync = engine(older, _owner, ownerKeys, readsFormat: 2);

    await addHost(owner, 'h-gw', label: 'gateway');
    await addHost(owner, 's-desk', protocol: 'vnc', via: 'h-gw', label: 'desk');
    final sent = await ownerSync.sync();
    expect(sent.sent, 2);

    // On the server: 3.4 opens the carrier alone; 4.0 both.
    final as34 = await serverAs(2);
    expect(as34.read, {'host|h-gw'});
    expect(as34.refused, 1);
    expect((await serverAs(kItemRecordFormat)).refused, 0);

    // Alice, on 4.0, gets the screen with its carrier and its options.
    await aliceSync.sync();
    expect(await hosts(alice), {'h-gw': 'ssh', 's-desk': 'vnc'});
    final desk = (await alice.connectionsDao.getById('s-desk'))!;
    expect(desk.connectViaId, 'h-gw');
    expect(desk.screenOptions, options);
    expect(ScreenOptions.decode(desk.screenOptions).clipboardOnByDefault(inTeam: true), isFalse,
        reason: "the team's editor locked the clipboard off");

    // 3.4: the carrier alone; nothing it holds deleted; its own changes go.
    final olderReport = await olderSync.sync();
    expect(olderReport.rejected, greaterThanOrEqualTo(1));
    expect(await hosts(older), {'h-gw': 'ssh'});
    await older.customStatement("UPDATE connections SET label = 'gateway (old laptop)' WHERE id = 'h-gw'");
    expect((await olderSync.sync()).sent, 1);
    await ownerSync.sync();
    expect(await hosts(owner), {'h-gw': 'ssh', 's-desk': 'vnc'}, reason: '3.4 wrote nothing over the screen');

    // It updates to 4.0: its vault is read again once, and the screen comes in.
    olderSync = engine(older, _owner, ownerKeys);
    await olderSync.sync();
    expect(await hosts(older), {'h-gw': 'ssh', 's-desk': 'vnc'});
    expect((await older.connectionsDao.getById('s-desk'))!.screenOptions, options);
    expect(await older.customSelect('SELECT 1 FROM crate_outbox').get(), isEmpty, reason: 'what came in is not sent back');
    expect((await olderSync.sync()).received, 0, reason: 'once');
  });

  test("a team's host never changes kind class; within one it may, and a personal space keeps no such rule", () async {
    final db = await teamDb();
    await addHost(db, 'h1');
    await addHost(db, 'f1', protocol: 'ftps');
    await addHost(db, 's1', protocol: 'vnc', via: 'h1');
    Future<void> setProtocol(AppDatabase on, String id, String protocol) =>
        on.customStatement('UPDATE connections SET protocol = ? WHERE id = ?', [protocol, id]);

    for (final (id, to) in [
      ('s1', 'ssh'),
      ('s1', 'sftp'),
      ('s1', 'ftps'),
      ('s1', 'mystery'),
      ('h1', 'vnc'),
      ('f1', 'vnc'),
      ('f1', 'ssh'),
      ('h1', 'ftpsImplicit'),
    ]) {
      await expectLater(setProtocol(db, id, to), throwsA(predicate((e) => '$e'.contains(kTeamHostKindRefused))),
          reason: '$id to $to');
    }
    expect(await hosts(db), {'f1': 'ftps', 'h1': 'ssh', 's1': 'vnc'});
    // Within a class: SSH to Mosh to an unknown name (read as SSH), FTPS's two.
    await setProtocol(db, 'h1', 'mosh');
    await setProtocol(db, 'h1', 'mystery');
    await setProtocol(db, 'f1', 'ftpsImplicit');
    await setProtocol(db, 's1', 'vnc');
    expect(await hosts(db), {'f1': 'ftpsImplicit', 'h1': 'mystery', 's1': 'vnc'});

    // The trigger's lists are the enum's own.
    final sql = (await db
            .customSelect("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'trg_gd_connections_kind'")
            .getSingle())
        .read<String>('sql');
    expect(sql, contains("IN ('vnc')"));
    expect(sql, contains("IN ('ftps', 'ftpsImplicit')"));

    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    dbs.add(tree);
    await addHost(tree, 'p1');
    await setProtocol(tree, 'p1', 'vnc');
    await setProtocol(tree, 'p1', 'ftps');
    expect(await hosts(tree), {'p1': 'ftps'});
  });

  // 4.0: an RDP host gives its key's password to whatever answers at
  // its address. A VNC host that became one by an edit would hand a password
  // meant for a VNC server to an RDP sign-in at the same address, so the two
  // screens are kinds apart (found in two reviews).
  test("a team's VNC host never becomes an RDP host, nor an RDP host anything else", () async {
    final db = await teamDb();
    await addHost(db, 'h1');
    await addHost(db, 'f1', protocol: 'ftps');
    await addHost(db, 's1', protocol: 'vnc', via: 'h1');
    await addHost(db, 'r1', protocol: 'rdp', via: 'h1');
    Future<void> setProtocol(String id, String protocol) =>
        db.customStatement('UPDATE connections SET protocol = ? WHERE id = ?', [protocol, id]);

    for (final (id, to) in [
      ('s1', 'rdp'),
      ('r1', 'vnc'),
      ('r1', 'ssh'),
      ('r1', 'ftps'),
      ('r1', 'mystery'),
      ('h1', 'rdp'),
      ('f1', 'rdp'),
    ]) {
      await expectLater(setProtocol(id, to), throwsA(predicate((e) => '$e'.contains(kTeamHostKindRefused))),
          reason: '$id to $to');
    }
    await setProtocol('r1', 'rdp');
    expect(await hosts(db), {'f1': 'ftps', 'h1': 'ssh', 'r1': 'rdp', 's1': 'vnc'});

    final sql = (await db
            .customSelect("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'trg_gd_connections_kind'")
            .getSingle())
        .read<String>('sql');
    expect(sql, contains("IN ('rdp') THEN ${ConnectionProtocol.kindClassRdp}"));
    expect(sql, contains("IN ('vnc') THEN ${ConnectionProtocol.kindClassScreen}"));
    expect(sql, contains("IN ('ftps', 'ftpsImplicit') THEN ${ConnectionProtocol.kindClassFtps}"));

    // Deleting the carrier leaves both screens pointing at it (never dialled
    // directly at an address the carrier saw).
    await db.connectionsDao.clearConnectViaReferences('h1');
    final via = {
      for (final r in await db.customSelect('SELECT id, connect_via_id FROM connections ORDER BY id').get())
        r.read<String>('id'): r.read<String?>('connect_via_id'),
    };
    expect(via['s1'], 'h1');
    expect(via['r1'], 'h1');
  });

  test('a screen is refused where its team watches sessions, its own vault or its carrier\'s, before anything is dialled',
      () async {
    const refusal = 'watched: no screen';
    final watched = await teamDb(watched: true);
    await addHost(watched, 'h-gw');
    await addHost(watched, 's-desk', protocol: 'vnc', via: 'h-gw');
    await CratePlacement(watched).place('host', 'h-gw', _crate);
    await CratePlacement(watched).place('host', 's-desk', _crate);
    expect(await hostIsWatchedIn(watched, 's-desk'), isTrue);
    await expectLater(refuseScreenWhereWatched(watched, 's-desk', carrierId: 'h-gw', refusal: refusal),
        throwsA(isA<OrchardAccessRefused>().having((e) => e.message, 'message', refusal)));

    // Not watched: it goes on.
    final open = await teamDb();
    await addHost(open, 'h-gw');
    await addHost(open, 's-desk', protocol: 'vnc', via: 'h-gw');
    await refuseScreenWhereWatched(open, 's-desk', carrierId: 'h-gw', refusal: refusal);

    // A person's own space is never watched.
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    dbs.add(tree);
    await addHost(tree, 's-own', protocol: 'vnc');
    await refuseScreenWhereWatched(tree, 's-own', refusal: refusal);
  });

  test("a team's log of a screen: who, which host and when, its lifecycle, never the picture", () {
    final header = SessionLogHeader(
      uid: _alice,
      label: 'desk',
      host: 'localhost',
      port: 5900,
      connectionId: 's-desk',
      kind: kScreenLogKind,
      startedAt: DateTime.utc(2026, 11, 9, 10),
    );
    final json = header.toJson();
    expect(json['v'], 1, reason: 'a version before it reads the header as it did');
    expect(json['kind'], 'vnc');
    final back = SessionLogHeader.fromJson(jsonDecode(jsonEncode(json)))!;
    expect(back.isScreen, isTrue);
    expect(back.connectionId, 's-desk');
    // A terminal's header is what it was.
    final terminal = SessionLogHeader(uid: _alice, label: 'web', host: '10.0.0.1', port: 22, startedAt: DateTime.utc(2026));
    expect(terminal.toJson().containsKey('kind'), isFalse);
    expect(SessionLogHeader.fromJson(terminal.toJson())!.isScreen, isFalse);

    expect(ScreenSessionLogLines.notRecorded, allOf(contains('picture'), contains('not')));
    expect(ScreenSessionLogLines.connected(viaCarrier: true), '[remote screen: connected through its SSH host]');
    expect(ScreenSessionLogLines.connected(viaCarrier: false), '[remote screen: connected directly over TLS]');
    expect(ScreenSessionLogLines.clipboard(on: true), '[remote screen: clipboard on]');
    expect(ScreenSessionLogLines.clipboard(on: false), '[remote screen: clipboard off]');
    expect(ScreenSessionLogLines.ended(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '[remote screen: ended after 1h 02m 03s]');
    expect(ScreenSessionLogLines.ended(const Duration(seconds: -5)), '[remote screen: ended after 0h 00m 00s]');

    // An RDP host's log: its own kind, a screen's all the same, with the account in the header
    // where the host's key names it, and said once it signed in.
    final rdp = SessionLogHeader(
      uid: _alice,
      label: 'office-pc',
      host: 'localhost',
      port: 3389,
      user: r'CORP\alex',
      connectionId: 'r-pc',
      kind: screenLogKind(rdp: true),
      startedAt: DateTime.utc(2026, 11, 13, 10),
    );
    expect(rdp.toJson()['kind'], 'rdp');
    final rdpBack = SessionLogHeader.fromJson(jsonDecode(jsonEncode(rdp.toJson())))!;
    expect((rdpBack.isScreen, rdpBack.kind, rdpBack.user), (true, kRdpScreenLogKind, r'CORP\alex'));
    expect(screenLogKind(rdp: false), kScreenLogKind);
    expect(ScreenSessionLogLines.notRecordedFor(rdp: false), ScreenSessionLogLines.notRecorded);
    expect(ScreenSessionLogLines.notRecordedFor(rdp: true),
        allOf(contains('(RDP)'), contains('the account'), contains('picture'), isNot(contains('VNC'))));
    expect(ScreenSessionLogLines.signedIn(r'CORP\alex'), r'[remote screen: signed in as CORP\alex]');
    // On one line, whatever was typed as the name, and no longer than a name is.
    expect(ScreenSessionLogLines.signedIn('alex\n[remote screen: ended after 0h]\x1b[2J'),
        '[remote screen: signed in as alex (remote screen: ended after 0h) (2J]');
    expect(ScreenSessionLogLines.signedIn('a' * 400).length, '[remote screen: signed in as ]'.length + 256);
    // To every reader: a line separator, a paragraph separator, a mark that turns the text around
    // or hides in it are spaces too, and the line's own brackets cannot be closed from inside.
    expect(ScreenSessionLogLines.signedIn('X\u2028[remote screen: ended]\u2029\\alex'),
        r'[remote screen: signed in as X (remote screen: ended) \alex]');
    expect(ScreenSessionLogLines.account('al\u202eex\u200b\ufeff\u2066!'), 'al ex   !');
    expect(ScreenSessionLogLines.account(r'CORP\alex'), r'CORP\alex');
    expect(ScreenSessionLogLines.account('ä-名前@corp.example'), 'ä-名前@corp.example', reason: 'letters of any script stay');
    expect(ScreenSessionLogLines.account(String.fromCharCodes([0x61, 0xd800, 0x62])), 'a b', reason: 'half a character');
  });
}
