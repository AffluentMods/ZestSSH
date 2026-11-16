import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/services/ftps/ftps_session.dart';
import 'package:zestssh/services/known_hosts_service.dart';

import '../../helpers/record_commits.dart';

import 'fake_crate_server.dart';

/// FTPS hosts in a team (3.4): shared under the SSH host rules, their
/// certificate pinned for the team as an SSH host key is, and kept from
/// versions before 3.4, which read item records of format 1 alone
/// ([kItemRecordFormat]): such a device never sees an FTPS host or a pinned
/// certificate, and loses nothing it holds; once it updates, it reads its
/// vaults again and they come in.

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _owner = 'owner-1';
const _alice = 'alice-1';
const _writer = 'role-writer';
const _viewer = 'role-viewer';

/// A made-up certificate's bytes: only its SHA-256 matters here.
final _der = utf8.encode('made-up certificate of files.example.com');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AccountKeys ownerKeys;
  late AccountKeys aliceKeys;
  late Uint8List crateKey;
  late FakeCrateServer server;
  late List<RecordEntry> entries;
  final dbs = <AppDatabase>[];

  Map<String, Object?> role(String id, int rank, List<String> switches) => {
        'id': id,
        'rank': rank,
        'name_enc': base64Encode(utf8.encode('sealed-$id')),
        'name_gen': 1,
        'can': const <String>[],
        'crates': {_crate: switches},
      };

  /// The record: made with the vault and two roles; Alice added as a writer
  /// (add, connect and edit).
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
        role(_viewer, 10, ['connect']),
        role(_writer, 30, ['add', 'connect', 'edit']),
      ],
    });
    await add(RecordTypes.memberAdd, {...recordKeysBody(await aliceKeys.publish(_alice)), 'uid': _alice, 'role': _writer});
    entries = chain;
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

  /// A team database of [uid]'s with [switches] in the vault.
  Future<AppDatabase> teamDb({Set<String>? switches}) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    dbs.add(db);
    await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
      "VALUES (1, ?, 'Acme', 'owner', 1, ?)",
      [_orchard, _crate],
    );
    await LocalRecord.empty(_orchard).extend(db, entries);
    await db.customStatement(
      "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'Production', 'manage', ?, 1)",
      [_crate, jsonEncode(switchList(switches ?? CrateSwitches.all.difference({CrateSwitches.agent})))],
    );
    await db.customStatement(
      "INSERT INTO space_keys (scope, scope_id, generation, secret) VALUES ('crate', ?, 1, ?)",
      [_crate, crateKey],
    );
    return db;
  }

  /// [db]'s sync engine as [uid] writes, reading item records up to
  /// [readsFormat] (1: as a version before 3.4 reads them).
  CrateSyncEngine engine(AppDatabase db, String uid, AccountKeys keys, {int readsFormat = kItemRecordFormat}) =>
      CrateSyncEngine(
        db: db,
        orchardId: _orchard,
        server: server,
        author: CrateAuthor(uid: uid, keys: keys),
        signers: signers,
        readsFormat: readsFormat,
      );

  Future<void> addHost(AppDatabase db, String id, {String protocol = 'ssh', int port = 22, String label = 'web'}) async {
    final now = DateTime(2026, 11, 6);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: protocol == 'ssh' ? '10.0.0.1' : 'files.example.com',
          port: Value(port),
          protocol: Value(protocol),
          createdAt: now,
          updatedAt: now,
        ));
  }

  Future<Map<String, String>> hosts(AppDatabase db) async => {
        for (final r in await db.customSelect('SELECT id, protocol FROM connections ORDER BY id').get())
          r.read<String>('id'): r.read<String>('protocol'),
      };

  Future<String?> label(AppDatabase db, String id) async => (await db
          .customSelect('SELECT label FROM connections WHERE id = ?', variables: [Variable(id)])
          .getSingleOrNull())
      ?.read<String>('label');

  Future<List<String>> pins(AppDatabase db) async =>
      [for (final r in await db.customSelect('SELECT host_keys FROM team_host_keys ORDER BY id').get()) r.read<String>('host_keys')];

  /// The vault's items as a reader of [readsFormat] opens them: what it
  /// reads, by kind and key; and how many it refuses.
  Future<({Set<String> read, int refused})> serverAs(int readsFormat) async {
    final idKey = await crateItemIdKey(crateKey, orchardId: _orchard, crateId: _crate);
    final read = <String>{};
    var refused = 0;
    for (final remote in server.items[_crate]!.values) {
      try {
        final rec = await openItem(remote.item!,
            orchardId: _orchard,
            crateId: _crate,
            crateKey: crateKey,
            idKey: idKey,
            signers: signers,
            readsFormat: readsFormat);
        read.add('${rec.kind}|${rec.key}');
      } on ItemRejected {
        refused++;
      }
    }
    return (read: read, refused: refused);
  }

  test('the names format 2 is decided by are the app\'s own', () {
    expect(kHostKeyKind, 'hostkey');
    expect(KnownHostsService.certificateKeyType, 'x509-sha256');
    expect([for (final p in ConnectionProtocol.values) if (p.isFtps) p.name], ['ftps', 'ftpsImplicit']);
  });

  test('two members on 3.4 share an FTPS host and its pinned certificate; a version before 3.4 sees neither, '
      'loses nothing it holds, and gets both once it updates', () async {
    final owner = await teamDb();
    final ownerSync = engine(owner, _owner, ownerKeys);
    final alice = await teamDb(switches: {'add', 'connect', 'edit'});
    final aliceSync = engine(alice, _alice, aliceKeys);
    // The owner's laptop, still on a version before 3.4.
    final older = await teamDb();
    var olderSync = engine(older, _owner, ownerKeys, readsFormat: 1);

    // What the team had before: an SSH host every version reads.
    await addHost(owner, 'h-ssh');
    await ownerSync.sync();
    await olderSync.sync();
    expect(await hosts(older), {'h-ssh': 'ssh'});

    // The owner adds an FTPS host of each kind and pins its certificate for
    // the team.
    await addHost(owner, 'f-explicit', protocol: 'ftps', port: 21, label: 'files');
    await addHost(owner, 'f-implicit', protocol: 'ftpsImplicit', port: 990, label: 'files tls');
    await TeamHostKeys(owner).pinCertificate('files.example.com', 21, _der, crateId: _crate);
    final sent = await ownerSync.sync();
    expect(sent.sent, 3);

    // On the server: an older reader opens the SSH host alone.
    final before34 = await serverAs(1);
    expect(before34.read, {'host|h-ssh'});
    expect(before34.refused, 3);
    expect((await serverAs(kItemRecordFormat)).refused, 0);

    // Alice, on 3.4, gets both FTPS hosts and the team's certificate.
    await aliceSync.sync();
    expect(await hosts(alice), {'f-explicit': 'ftps', 'f-implicit': 'ftpsImplicit', 'h-ssh': 'ssh'});
    final pin = await FtpsTeamPins(TeamHostKeys(alice), hostId: 'f-explicit').certificatePin('files.example.com', 21);
    expect(pin, isNotNull);
    expect(pin!.isCertificate, isTrue);
    expect(pin.certificateSha256, sha256.convert(_der).toString());
    expect(pin.fingerprint, KnownHostsService.certificateFingerprint(sha256.convert(_der).toString()));

    // She may edit it (her role edits): the owner gets her change.
    await alice.customStatement("UPDATE connections SET label = 'files (eu)' WHERE id = 'f-explicit'");
    expect((await aliceSync.sync()).sent, 1);
    await ownerSync.sync();
    expect(await label(owner, 'f-explicit'), 'files (eu)');

    // The older version: neither FTPS host nor the certificate, nothing it
    // holds deleted, and its own changes still go.
    final olderReport = await olderSync.sync();
    expect(olderReport.rejected, greaterThanOrEqualTo(1));
    expect(await hosts(older), {'h-ssh': 'ssh'});
    expect(await pins(older), isEmpty);
    await older.customStatement("UPDATE connections SET label = 'web (old laptop)' WHERE id = 'h-ssh'");
    expect((await olderSync.sync()).sent, 1);
    await ownerSync.sync();
    expect(await label(owner, 'h-ssh'), 'web (old laptop)');
    expect(await hosts(owner), {'f-explicit': 'ftps', 'f-implicit': 'ftpsImplicit', 'h-ssh': 'ssh'},
        reason: 'the older version wrote nothing over the FTPS hosts');

    // It updates to 3.4: its vault is read again once, and they come in.
    olderSync = engine(older, _owner, ownerKeys);
    await olderSync.sync();
    expect(await hosts(older), {'f-explicit': 'ftps', 'f-implicit': 'ftpsImplicit', 'h-ssh': 'ssh'});
    expect(await label(older, 'f-explicit'), 'files (eu)');
    expect(await pins(older), hasLength(1));
    expect(await older.customSelect('SELECT 1 FROM crate_outbox').get(), isEmpty,
        reason: 'what came in is not sent back');
    // Once: the next sync reads on from where it is.
    final again = await olderSync.sync();
    expect(again.received, 0);
  });

  test("a team's host never turns from FTPS into another kind, or back; within FTPS it may change, "
      'and a personal space keeps no such rule', () async {
    final db = await teamDb();
    await addHost(db, 'f1', protocol: 'ftps', port: 21);
    await addHost(db, 'h1');
    Future<void> setProtocol(AppDatabase on, String id, String protocol) =>
        on.customStatement('UPDATE connections SET protocol = ? WHERE id = ?', [protocol, id]);

    for (final (id, to) in [('f1', 'ssh'), ('f1', 'sftp'), ('h1', 'ftps'), ('h1', 'ftpsImplicit')]) {
      await expectLater(setProtocol(db, id, to), throwsA(predicate((e) => '$e'.contains(kTeamHostKindRefused))),
          reason: '$id to $to');
    }
    expect(await hosts(db), {'f1': 'ftps', 'h1': 'ssh'});
    await setProtocol(db, 'f1', 'ftpsImplicit');
    await setProtocol(db, 'h1', 'sftp');
    expect(await hosts(db), {'f1': 'ftpsImplicit', 'h1': 'sftp'});

    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    dbs.add(tree);
    await addHost(tree, 'p1');
    await setProtocol(tree, 'p1', 'ftps');
    expect(await hosts(tree), {'p1': 'ftps'});
  });

  // What the trigger refuses of this device's own changes is refused of a
  // record too. The app sends no such record; a changed client of a member
  // who may edit the host could, and it was taken (found in a
  // security review).
  test("a record that turns a team's host into another kind is not taken: the host stays as it was, "
      'what comes after it is taken, and the next change by the app replaces it', () async {
    final owner = await teamDb();
    final ownerSync = engine(owner, _owner, ownerKeys);
    final laptop = await teamDb();
    final laptopSync = engine(laptop, _owner, ownerKeys);
    final alice = await teamDb(switches: {'add', 'connect', 'edit'});
    final aliceSync = engine(alice, _alice, aliceKeys);
    Future<void> setProtocol(AppDatabase on, String id, String protocol) =>
        on.customStatement('UPDATE connections SET protocol = ? WHERE id = ?', [protocol, id]);

    await addHost(owner, 'h1');
    await addHost(owner, 'f1', protocol: 'ftps', port: 21, label: 'files');
    await ownerSync.sync();
    await aliceSync.sync();
    await laptopSync.sync();
    expect(await hosts(alice), {'f1': 'ftps', 'h1': 'ssh'});

    // Alice's client, changed: its own check is gone. It turns each host
    // into the other kind, renames one, and adds a host as anyone may.
    await alice.customStatement('DROP TRIGGER trg_gd_connections_kind');
    await setProtocol(alice, 'h1', 'ftps');
    await alice.customStatement("UPDATE connections SET label = 'renamed' WHERE id = 'h1'");
    await setProtocol(alice, 'f1', 'ssh');
    await addHost(alice, 'h2', label: 'new');
    expect((await aliceSync.sync()).sent, 3);

    final got = await ownerSync.sync();
    expect(got.rejected, 2, reason: 'the two records that change a kind');
    expect(await hosts(owner), {'f1': 'ftps', 'h1': 'ssh', 'h2': 'ssh'});
    expect(await label(owner, 'h1'), 'web', reason: 'nothing of a refused record is written');
    expect(await label(owner, 'h2'), 'new', reason: 'the record after them is taken');
    expect(await owner.customSelect('SELECT 1 FROM crate_outbox').get(), isEmpty);
    // Read once: the next sync does not stop at them again.
    expect((await ownerSync.sync()).rejected, 0);

    // Within its kind a record still changes a host, and the owner's next
    // change to it goes over the record that was refused.
    await setProtocol(owner, 'h1', 'sftp');
    await ownerSync.sync();
    await laptopSync.sync();
    expect(await hosts(laptop), {'f1': 'ftps', 'h1': 'sftp', 'h2': 'ssh'});
  });

  test('roles hold for an FTPS host as for any host: a viewer adds none, and what it may not send is not sent',
      () async {
    final viewer = await teamDb(switches: {'connect'});
    await expectLater(addHost(viewer, 'f1', protocol: 'ftps', port: 21),
        throwsA(predicate((e) => '$e'.contains('orchard-access'))));
    expect(await hosts(viewer), isEmpty);

    // One who may add but not pin (edit): the certificate is refused here.
    final adder = await teamDb(switches: {'add', 'connect'});
    await addHost(adder, 'f2', protocol: 'ftps', port: 21);
    expect(await TeamHostKeys(adder).mayPinIn(_crate), isFalse);
    await expectLater(TeamHostKeys(adder).pinCertificate('files.example.com', 21, _der, crateId: _crate),
        throwsA(predicate((e) => '$e'.contains('orchard-access'))));
    expect(await CratePlacement(adder).crateOf('host', 'f2'), _crate);
  });
}
