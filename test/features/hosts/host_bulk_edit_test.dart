import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/zest_ssh_core.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/bulk/host_bulk_edit.dart';
import 'package:zestssh/services/ssh_service.dart';

/// The bulk edit of hosts (3.4):
/// only the fields changed are written, each where the host's kind has it,
/// all of them in one transaction, and a team's vault refuses the edit as it
/// refuses a single one.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final at = DateTime.utc(2026, 1, 1);
  final later = DateTime.utc(2026, 11, 5, 12);

  late AppDatabase db;

  Future<void> identity(String id, String user) => db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: id,
        label: 'key-$id',
        username: user,
        authMethod: 'publicKey',
        createdAt: at,
      ));

  Future<void> host(
    String id, {
    String protocol = 'ssh',
    int port = 22,
    String? key,
    String? via,
    String? group,
    bool compat = false,
    int? color,
  }) =>
      db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value(id),
        host: Value('10.20.4.${id.hashCode % 200}'),
        port: Value(port),
        protocol: Value(protocol),
        identityId: Value(key),
        connectViaId: Value(via),
        groupId: Value(group),
        compatibilityMode: Value(compat),
        colorValue: Value(color),
        createdAt: Value(at),
        updatedAt: Value(at),
      ));

  Future<Map<String, Connection>> rows() async => {for (final c in await db.connectionsDao.getAll()) c.id: c};

  group('a tree of hosts', () {
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await identity('k-root', 'root');
      await identity('k-admin', 'admin');
      await db.into(db.connectionGroups).insert(
          ConnectionGroupsCompanion.insert(id: 'g-old', name: 'Imported from SecureCRT', createdAt: at));
      await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-eol', name: 'EOL', createdAt: at));
      await host('db-01', key: 'k-root', group: 'g-old', color: 0xFF10B981);
      await host('db-02', key: 'k-admin', port: 2222, group: 'g-old');
      await host('shell', protocol: 'localShell', group: 'g-old');
      await host('tel', protocol: 'telnet', port: 23);
      await host('mosh', protocol: 'mosh', key: 'k-root');
      await db.connectionTagsDao.setTagsForConnection('db-01', ['linux']);
      await db.connectionTagsDao.setTagsForConnection('db-02', ['linux', 'old']);
    });
    tearDown(() => db.close());

    const all = ['db-01', 'db-02', 'shell', 'tel', 'mosh'];

    test('a field left untouched is not written: only the port changes, and only where a host has one', () async {
      final before = await rows();
      final outcome = await applyHostBulkEdit(db, all, const HostBulkEdit(port: 2022), now: later);
      expect(outcome.changed, all);
      final after = await rows();
      expect({for (final e in after.entries) e.key: e.value.port},
          {'db-01': 2022, 'db-02': 2022, 'shell': 22, 'tel': 2022, 'mosh': 2022},
          reason: 'a shell on this device has no port to change');
      for (final id in all) {
        final b = before[id]!, a = after[id]!;
        expect(
          (a.identityId, a.groupId, a.connectViaId, a.compatibilityMode, a.colorValue, a.colorIndex, a.label, a.host),
          (b.identityId, b.groupId, b.connectViaId, b.compatibilityMode, b.colorValue, b.colorIndex, b.label, b.host),
          reason: '$id: nothing else of it',
        );
      }
      expect(after['shell']!.updatedAt, before['shell']!.updatedAt, reason: 'a host nothing was written to is as it was');
      expect(after['db-01']!.updatedAt.toUtc(), later);
      expect(await db.connectionTagsDao.getTagsForConnection('db-02'), ['linux', 'old'], reason: 'tags untouched');
    });

    test('an empty edit writes nothing at all', () async {
      final before = await rows();
      final outcome = await applyHostBulkEdit(db, all, const HostBulkEdit(), now: later);
      expect(outcome.undo.isEmpty, isTrue);
      final after = await rows();
      for (final id in all) {
        expect(after[id]!.updatedAt, before[id]!.updatedAt, reason: id);
      }
    });

    test('each field goes only where the host editor has it', () async {
      await applyHostBulkEdit(
        db,
        all,
        const HostBulkEdit(
          identity: BulkSet('k-admin'),
          jumpHost: BulkSet('db-01'),
          compat: BulkCompat.onAll,
        ),
        now: later,
      );
      final r = await rows();
      expect({for (final id in all) id: r[id]!.identityId},
          {'db-01': 'k-admin', 'db-02': 'k-admin', 'shell': null, 'tel': null, 'mosh': 'k-admin'},
          reason: 'a key for what signs in with one');
      expect({for (final id in all) id: r[id]!.connectViaId},
          {'db-01': null, 'db-02': 'db-01', 'shell': null, 'tel': null, 'mosh': null},
          reason: 'a jump host for SSH (and never a host as its own)');
      expect({for (final id in all) id: r[id]!.compatibilityMode},
          {'db-01': true, 'db-02': true, 'shell': false, 'tel': false, 'mosh': false},
          reason: 'Compatibility mode where the editor offers it');
    });

    test('Compatibility mode for those that need it changes those alone; Off turns it off everywhere it is', () async {
      await host('db-03', compat: true);
      await applyHostBulkEdit(db, ['db-01', 'db-02', 'db-03'], const HostBulkEdit(compat: BulkCompat.onNeeding),
          needCompat: {'db-02'});
      var r = await rows();
      expect([for (final id in ['db-01', 'db-02', 'db-03']) r[id]!.compatibilityMode], [false, true, true]);
      expect(r['db-01']!.updatedAt.toUtc(), at, reason: 'not one that needs it: not written');
      await applyHostBulkEdit(db, ['db-01', 'db-02', 'db-03'], const HostBulkEdit(compat: BulkCompat.off));
      r = await rows();
      expect([for (final id in ['db-01', 'db-02', 'db-03']) r[id]!.compatibilityMode], [false, false, false]);
    });

    test('group, colour label and none of each', () async {
      await applyHostBulkEdit(db, ['db-01', 'db-02'],
          const HostBulkEdit(group: BulkSet('g-eol'), color: BulkSet(0xFF3B82F6)));
      var r = await rows();
      expect([r['db-01']!.groupId, r['db-02']!.groupId], ['g-eol', 'g-eol']);
      expect([r['db-01']!.colorValue, r['db-02']!.colorValue], [0xFF3B82F6, 0xFF3B82F6]);
      await applyHostBulkEdit(db, ['db-01', 'db-02'], const HostBulkEdit(group: BulkSet(null), color: BulkSet(null)));
      r = await rows();
      expect([r['db-01']!.groupId, r['db-02']!.groupId], [null, null]);
      expect([r['db-01']!.colorValue, r['db-01']!.colorIndex], [null, 0], reason: 'none: the group colour');
    });

    test('tags are added, taken off, or made every host\'s', () async {
      Future<List<List<String>>> tags() async => [
            for (final id in ['db-01', 'db-02']) await db.connectionTagsDao.getTagsForConnection(id),
          ];
      await applyHostBulkEdit(db, ['db-01', 'db-02'], const HostBulkEdit(tags: BulkTags(BulkTagsMode.add, ['eol'])));
      expect(await tags(), [
        ['eol', 'linux'],
        ['eol', 'linux', 'old'],
      ]);
      await applyHostBulkEdit(db, ['db-01', 'db-02'], const HostBulkEdit(tags: BulkTags(BulkTagsMode.remove, ['linux'])));
      expect(await tags(), [
        ['eol'],
        ['eol', 'old'],
      ]);
      await applyHostBulkEdit(db, ['db-01', 'db-02'], const HostBulkEdit(tags: BulkTags(BulkTagsMode.replace, ['centos'])));
      expect(await tags(), [
        ['centos'],
        ['centos'],
      ]);
    });

    test('a key that was one of a host\'s other accounts leaves them; none takes the first other account', () async {
      await db.hostAccountsDao.setOtherAccounts('db-01', ['k-admin']);
      await identity('k-ops', 'ops');
      await db.hostAccountsDao.setOtherAccounts('db-02', ['k-ops', 'k-root']);
      await applyHostBulkEdit(db, ['db-01'], const HostBulkEdit(identity: BulkSet('k-admin')));
      expect((await rows())['db-01']!.identityId, 'k-admin');
      expect(await db.hostAccountsDao.otherAccountsOf('db-01'), isEmpty, reason: 'the default is never among the others');
      await applyHostBulkEdit(db, ['db-02'], const HostBulkEdit(identity: BulkSet(null)));
      expect((await rows())['db-02']!.identityId, 'k-ops');
      expect(await db.hostAccountsDao.otherAccountsOf('db-02'), ['k-root']);
    });

    test('Undo writes back what each host had, every field the edit changed, in one go', () async {
      await db.hostAccountsDao.setOtherAccounts('db-01', ['k-admin']);
      final before = await rows();
      final outcome = await applyHostBulkEdit(
        db,
        ['db-01', 'db-02', 'shell'],
        const HostBulkEdit(
          port: 2200,
          identity: BulkSet('k-admin'),
          compat: BulkCompat.onAll,
          group: BulkSet('g-eol'),
          color: BulkSet(0xFF3B82F6),
          tags: BulkTags(BulkTagsMode.replace, ['eol']),
        ),
      );
      await undoHostBulkEdit(db, outcome.undo);
      final after = await rows();
      for (final id in ['db-01', 'db-02', 'shell']) {
        final b = before[id]!, a = after[id]!;
        expect((a.port, a.identityId, a.compatibilityMode, a.groupId, a.colorValue, a.colorIndex),
            (b.port, b.identityId, b.compatibilityMode, b.groupId, b.colorValue, b.colorIndex),
            reason: id);
      }
      expect(await db.connectionTagsDao.getTagsForConnection('db-02'), ['linux', 'old']);
      expect(await db.connectionTagsDao.getTagsForConnection('shell'), isEmpty);
      expect(await db.hostAccountsDao.otherAccountsOf('db-01'), ['k-admin']);
    });
  });

  group('a team\'s vaults', () {
    const editVault = '11111111-1111-4111-8111-111111111111';
    const connectVault = '22222222-2222-4222-8222-222222222222';

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      await db.customStatement(
          'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
          "VALUES (1, '44444444-4444-4444-8444-444444444444', 'Platform team', 'member-role', 1, ?)",
          [editVault]);
      await db.customStatement(
          'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
          '''(?, 'Legacy', 'edit', '["add","connect","edit","reveal"]', 1), '''
          '''(?, 'Production', 'connect', '["connect"]', 1)''',
          [editVault, connectVault]);
      // As the sync engine leaves them: in their vault, and on the server.
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      for (final (id, vault) in [('legacy-db-01', editVault), ('legacy-pay-01', connectVault)]) {
        await host(id);
        await db.customStatement(
            "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', ?, ?, 3)",
            [id, vault]);
      }
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    });
    tearDown(() => db.close());

    test('a host its vault lets this account edit is written, and goes out as a change', () async {
      await applyHostBulkEdit(db, ['legacy-db-01'], const HostBulkEdit(compat: BulkCompat.onAll));
      expect((await rows())['legacy-db-01']!.compatibilityMode, isTrue);
      final queued = await db.customSelect("SELECT item_key FROM crate_outbox WHERE kind = 'host'").get();
      expect([for (final r in queued) r.read<String>('item_key')], ['legacy-db-01']);
    });

    test('one host its vault does not let this account edit refuses the whole edit, as a single edit is refused', () async {
      Matcher refused() => throwsA(predicate((e) => '$e'.contains('orchard-access')));
      // A single edit of it, as the host editor writes it: refused.
      await expectLater(
        db.connectionsDao.updateConnection(const ConnectionsCompanion(id: Value('legacy-pay-01'), port: Value(2022))),
        refused(),
      );
      // The bulk edit with it among the hosts: refused too, and nothing of it
      // written, not even to the host that may be edited.
      await expectLater(
        applyHostBulkEdit(db, ['legacy-db-01', 'legacy-pay-01'], const HostBulkEdit(compat: BulkCompat.onAll, port: 2022)),
        refused(),
      );
      final r = await rows();
      expect([r['legacy-db-01']!.compatibilityMode, r['legacy-db-01']!.port], [false, 22], reason: 'one transaction');
      expect([r['legacy-pay-01']!.compatibilityMode, r['legacy-pay-01']!.port], [false, 22]);
      expect(await db.customSelect('SELECT * FROM crate_outbox').get(), isEmpty, reason: 'nothing goes to the server');
    });

    test('the plan leaves out what the vault does not allow, by vault, as the screen shows it', () {
      final plan = planHostBulkEdit(
        ['legacy-db-01', 'legacy-pay-01', 'legacy-pay-02'],
        mayChange: (id) => id == 'legacy-db-01',
        vaultOf: (id) => id.startsWith('legacy-pay') ? connectVault : editVault,
      );
      expect(plan.editable, ['legacy-db-01']);
      expect(plan.skipped, {
        connectVault: ['legacy-pay-01', 'legacy-pay-02'],
      });
      expect(plan.skippedCount, 2);
    });
  });

  group('what the editor offers and says', () {
    test('the values the hosts have, the most common first', () {
      expect(bulkValueCounts(['admin', 'root', 'root', 'admin', 'root']), [
        (value: 'root', count: 3),
        (value: 'admin', count: 2),
      ]);
      expect(bulkValueCounts(['22', '2222']), [(value: '22', count: 1), (value: '2222', count: 1)],
          reason: 'as common: in the order first seen');
    });

    test('a key or jump host of a watched vault serves only that vault\'s hosts; any other serves all', () {
      expect(bulkItemServesAll('v-watched', {'v-watched'}, {'v-watched'}), isTrue);
      expect(bulkItemServesAll('v-watched', {'v-watched', 'v-other'}, {'v-watched'}), isFalse);
      expect(bulkItemServesAll('v-open', {'v-watched', 'v-other'}, {'v-watched'}), isTrue);
      expect(bulkItemServesAll(null, {'a'}, const {}), isTrue, reason: 'your own space');
    });

    test('a jump host is none of the hosts, and reaches none of them on its way', () {
      final via = {'b': 'a', 'c': 'x', 'x': null};
      expect(bulkJumpHostFits('a', {'a', 'z'}, (id) => via[id]), isFalse, reason: 'a host as its own jump host');
      expect(bulkJumpHostFits('b', {'a'}, (id) => via[id]), isFalse, reason: 'b is reached through a: a loop');
      expect(bulkJumpHostFits('c', {'a'}, (id) => via[id]), isTrue);
    });

    test('tags typed are kept as tags are kept, each once', () {
      expect(bulkCanonicalTags([' EOL ', 'eol', 'Linux  Box', '']), ['eol', 'linux box']);
    });
  });

  group('refused for an old key exchange', () {
    test('a group Compatibility mode takes, and nothing in common that it has', () {
      expect(refusedForOldKeyExchange(SSHKexGroupError('of 1024 bits', bits: 1024, shortestTaken: 2048)), isTrue);
      expect(refusedForOldKeyExchange(SSHHandshakeError('No matching cipher algorithm',
              offered: const ['aes256-gcm@openssh.com', 'aes256-ctr'], otherSideOffered: const ['aes128-cbc'])),
          isTrue);
    });

    test('not what the mode cannot help with', () {
      expect(refusedForOldKeyExchange(SSHKexGroupError('of 768 bits', bits: 768, shortestTaken: 2048)), isFalse,
          reason: 'shorter than the mode takes');
      expect(refusedForOldKeyExchange(SSHHandshakeError('No matching cipher algorithm',
              offered: const ['aes256-ctr'], otherSideOffered: const ['3des-cbc'])),
          isFalse, reason: 'the mode has nothing the server offers');
      expect(refusedForOldKeyExchange(SSHHandshakeError('Connection closed')), isFalse);
      expect(refusedForOldKeyExchange(Exception('timed out')), isFalse);
    });
  });
}
