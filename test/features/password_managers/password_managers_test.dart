import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';

/// Fetching from a password manager (3.0): the password comes back
/// once and is not kept; what unlocks Bitwarden or KeePassXC is asked for
/// once, handed over in the environment or on the tool's input (never as an
/// argument), kept in memory until ZestSSH locks, and asked again when
/// wrong; what the person checks before a password first goes to a host is
/// what the manager says, never a synced label.

class _Call {
  _Call(this.executable, this.args, this.environment, this.stdin);

  final String executable;
  final List<String> args;
  final Map<String, String> environment;
  final String? stdin;
}

class _FakeRunner implements PmProcessRunner {
  _FakeRunner(this.answer);

  final PmProcessResult Function(_Call call) answer;
  final calls = <_Call>[];

  @override
  Future<PmProcessResult> run(String executable, List<String> args,
      {Map<String, String> environment = const {}, String? stdin, required Duration timeout}) async {
    final call = _Call(executable, args, environment, stdin);
    calls.add(call);
    return answer(call);
  }
}

const _bwId = '5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a';

void main() {
  PasswordManagers managers(_FakeRunner runner, {KeePassXcDatabase? db, bool installed = true}) => PasswordManagers(
        runner: runner,
        settings: () => PasswordManagerSettings(keePassXc: db),
        environment: const {'PATH': '/usr/bin'},
        exists: (p) => installed,
        isWindows: false,
        isMacOS: false,
      );

  Future<String?> Function(PasswordManagerKind, {required bool again}) asking(List<(PasswordManagerKind, bool)> asked,
          List<String?> answers) =>
      (kind, {required again}) async {
        asked.add((kind, again));
        return answers.isEmpty ? null : answers.removeAt(0);
      };

  test('1Password: op read, the password as it is, nothing asked', () async {
    final runner = _FakeRunner((c) => const PmProcessResult(0, 'p@ss w0rd', ''));
    final asked = <(PasswordManagerKind, bool)>[];
    final pm = managers(runner);
    expect(await pm.fetch(PasswordRef.onePassword('op://Eng/db/password')!, ask: asking(asked, [])), 'p@ss w0rd');
    expect(runner.calls.single.executable, '/usr/bin/op');
    expect(runner.calls.single.args, ['read', '--no-newline', '--', 'op://Eng/db/password']);
    expect(asked, isEmpty);
  });

  test('a tool that is not there, or that says no, is said so with what it said', () async {
    final none = managers(_FakeRunner((c) => const PmProcessResult(0, 'x', '')), installed: false);
    await expectLater(none.fetch(PasswordRef.onePassword('op://Eng/db/password')!, ask: asking([], [])),
        throwsA(isA<PasswordManagerException>().having((e) => e.failure, 'failure', PmFailure.notInstalled)));
    final no = managers(_FakeRunner((c) => const PmProcessResult(1, 'never shown', '[ERROR] authorization prompt dismissed')));
    await expectLater(
        no.fetch(PasswordRef.onePassword('op://Eng/db/password')!, ask: asking([], [])),
        throwsA(isA<PasswordManagerException>()
            .having((e) => e.failure, 'failure', PmFailure.cancelled)
            .having((e) => e.details, 'details', '[ERROR] authorization prompt dismissed')
            .having((e) => e.toString(), 'text', isNot(contains('never shown')))));
  });

  test('Bitwarden: the master password once, in the environment of the unlock only; the session kept until locked',
      () async {
    final runner = _FakeRunner((c) {
      if (c.args.first == 'unlock') {
        return c.environment['ZESTSSH_BW_PASSWORD'] == 'master'
            ? const PmProcessResult(0, 'SESSION-KEY\n', '')
            : const PmProcessResult(1, '', 'Invalid master password.');
      }
      if (c.args.first == 'get' && c.environment['BW_SESSION'] == 'SESSION-KEY') {
        return const PmProcessResult(0, 'bw-secret', '');
      }
      return const PmProcessResult(1, '', 'Vault is locked.');
    });
    final pm = managers(runner);
    final asked = <(PasswordManagerKind, bool)>[];
    final answers = <String?>['wrong', 'master'];
    final ref = PasswordRef.bitwarden(_bwId)!;
    expect(await pm.fetch(ref, ask: asking(asked, answers)), 'bw-secret');
    expect(asked, [(PasswordManagerKind.bitwarden, false), (PasswordManagerKind.bitwarden, true)]);
    for (final c in runner.calls) {
      expect(c.args.join(' '), isNot(contains('master')), reason: 'never an argument');
      expect(c.environment['BW_NOINTERACTION'], 'true');
      if (c.args.first != 'unlock') expect(c.environment.containsKey('ZESTSSH_BW_PASSWORD'), isFalse);
    }
    expect(runner.calls.last.args, ['get', 'password', _bwId]);

    // Kept for this run: not asked again.
    expect(await pm.fetch(ref, ask: asking(asked, [])), 'bw-secret');
    expect(asked, hasLength(2));

    // Locked: forgotten, asked again.
    pm.lock();
    expect(pm.unlockedForTests, isFalse);
    expect(await pm.fetch(ref, ask: asking(asked, ['master'])), 'bw-secret');
    expect(asked, hasLength(3));

    // Cancelled, and three wrong ones.
    pm.lock();
    await expectLater(pm.fetch(ref, ask: asking(asked, [])),
        throwsA(isA<PasswordManagerException>().having((e) => e.failure, 'failure', PmFailure.cancelled)));
    await expectLater(pm.fetch(ref, ask: asking(asked, ['a', 'b', 'c'])),
        throwsA(isA<PasswordManagerException>().having((e) => e.failure, 'failure', PmFailure.wrongPassword)));
  });

  test('Bitwarden: a session gone stale is asked for again; an item not found is looked for after a sync', () async {
    var sessions = 0;
    var synced = false;
    final runner = _FakeRunner((c) {
      switch (c.args.first) {
        case 'unlock':
          return PmProcessResult(0, 'S${++sessions}', '');
        case 'sync':
          synced = true;
          return const PmProcessResult(0, 'Syncing complete.', '');
        default:
          if (c.environment['BW_SESSION'] == 'S1') return const PmProcessResult(1, '', 'Vault is locked.');
          return synced ? const PmProcessResult(0, 'found', '') : const PmProcessResult(1, '', 'Not found.');
      }
    });
    final pm = managers(runner);
    final asked = <(PasswordManagerKind, bool)>[];
    expect(await pm.fetch(PasswordRef.bitwarden(_bwId)!, ask: asking(asked, ['m', 'm'])), 'found');
    expect(asked, hasLength(2));
    expect(runner.calls.map((c) => c.args.first), ['unlock', 'get', 'unlock', 'get', 'sync', 'get']);
  });

  test('KeePassXC: the database password on the input, once, asked again when wrong; key file only; no database',
      () async {
    const db = KeePassXcDatabase(path: '/home/a/p.kdbx');
    final runner = _FakeRunner((c) => c.stdin == 'right\n'
        ? const PmProcessResult(0, 'kpx-secret\n', '')
        : const PmProcessResult(1, '', 'Error while reading the database: Invalid credentials were provided'));
    final pm = managers(runner, db: db);
    final asked = <(PasswordManagerKind, bool)>[];
    final ref = PasswordRef.keePassXc('Servers/web1')!;
    expect(await pm.fetch(ref, ask: asking(asked, ['wrong', 'right'])), 'kpx-secret');
    expect(asked, [(PasswordManagerKind.keePassXc, false), (PasswordManagerKind.keePassXc, true)]);
    expect(runner.calls.last.args,
        ['show', '--quiet', '--show-protected', '--attributes', 'Password', '--', '/home/a/p.kdbx', 'Servers/web1']);
    expect(runner.calls.every((c) => !c.args.contains('right')), isTrue);
    expect(await pm.fetch(ref, ask: asking(asked, [])), 'kpx-secret');
    expect(asked, hasLength(2), reason: 'kept for this run');

    final keyOnly = _FakeRunner((c) => const PmProcessResult(0, 'k\n', ''));
    final pk = managers(keyOnly, db: const KeePassXcDatabase(path: '/p.kdbx', keyFile: '/p.key', noPassword: true));
    expect(await pk.fetch(ref, ask: asking(asked, [])), 'k');
    expect((keyOnly.calls.single.stdin, keyOnly.calls.single.args.contains('--no-password')), ('', true));

    await expectLater(managers(runner).fetch(ref, ask: asking(asked, [])),
        throwsA(isA<PasswordManagerException>().having((e) => e.failure, 'failure', PmFailure.noDatabase)));
  });

  test('what the person checks: the manager\'s own names, never a secret kept', () async {
    final runner = _FakeRunner((c) {
      if (c.args.first == 'unlock') return const PmProcessResult(0, 'S', '');
      if (c.args.take(2).join(' ') == 'get item') {
        return const PmProcessResult(0,
            '{"id":"$_bwId","name":"Bank","login":{"username":"me","password":"hunter2"},"notes":"n"}', '');
      }
      if (c.args.take(2).join(' ') == 'item list') {
        return const PmProcessResult(0,
            '[{"id":"abcdefghijklmnopqrstuvwxyz","title":"db-prod","vault":{"id":"v","name":"Engineering"}}]', '');
      }
      return const PmProcessResult(1, '', 'no');
    });
    final pm = managers(runner, db: const KeePassXcDatabase(path: '/home/a/p.kdbx'));
    final ask = asking([], ['m']);

    final named = await pm.describe(PasswordRef.onePassword('op://Private/Bank/password')!, ask: ask);
    expect((named.title, named.where), ('Bank', 'Private'));
    expect(runner.calls, isEmpty, reason: 'a named reference is what op resolves');

    final byId = await pm.describe(
        PasswordRef.onePassword('op://abcdefghijklmnopqrstuvwxy0/abcdefghijklmnopqrstuvwxyz/password')!,
        ask: ask);
    expect((byId.title, byId.where), ('db-prod', 'Engineering'));
    expect(runner.calls.last.args, ['item', 'list', '--vault=abcdefghijklmnopqrstuvwxy0', '--format=json']);

    final bw = await pm.describe(PasswordRef.bitwarden(_bwId)!, ask: ask);
    expect((bw.title, bw.username), ('Bank', 'me'));

    final kpx = await pm.describe(PasswordRef.keePassXc('Personal/Bank')!, ask: ask);
    expect((kpx.title, kpx.where), ('Personal/Bank', '/home/a/p.kdbx'));
  });

  test('listing to pick from: names, where and user names; references that read back; never a password kept',
      () async {
    final runner = _FakeRunner((c) {
      final a = c.args.join(' ');
      if (a == 'item list --format=json') {
        return const PmProcessResult(0,
            '[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaa","title":"db-prod","vault":{"id":"vvvvvvvvvvvvvvvvvvvvvvvvvv","name":"Engineering"},"additional_information":"postgres"},'
            '{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbb","title":"a/b slash","vault":{"id":"vvvvvvvvvvvvvvvvvvvvvvvvvv","name":"Engineering"}},'
            '{"id":"cccccccccccccccccccccccccc","title":"Bank","vault":{"id":"pppppppppppppppppppppppppp","name":"Private"}}]',
            '');
      }
      if (c.args.first == 'unlock') return const PmProcessResult(0, 'S', '');
      if (a == 'list items --search=web') {
        return const PmProcessResult(0,
            '[{"id":"$_bwId","name":"web1","login":{"username":"deploy","password":"hunter2"},"notes":"n"},'
            '{"id":"6f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a","name":"web note","secureNote":{}}]',
            '');
      }
      if (c.args.first == 'ls') {
        expect(c.stdin, 'db-pass\n');
        return const PmProcessResult(0, 'Servers/\nServers/web1\nRoot entry\nRecycle Bin/\nRecycle Bin/old\n', '');
      }
      return const PmProcessResult(1, '', 'no');
    });
    final pm = managers(runner, db: const KeePassXcDatabase(path: '/p.kdbx'));

    final op = await pm.listItems(PasswordManagerKind.onePassword, ask: asking([], []));
    expect([for (final i in op) (i.title, i.where, i.username, i.ref.target)], [
      ('a/b slash', 'Engineering', null, 'op://vvvvvvvvvvvvvvvvvvvvvvvvvv/bbbbbbbbbbbbbbbbbbbbbbbbbb/password'),
      ('Bank', 'Private', null, 'op://Private/Bank/password'),
      ('db-prod', 'Engineering', 'postgres', 'op://Engineering/db-prod/password'),
    ]);
    expect((await pm.listItems(PasswordManagerKind.onePassword, search: 'eng', ask: asking([], []))).map((i) => i.title),
        ['a/b slash', 'db-prod']);

    // Bitwarden: only for a search, only items with a login.
    expect(await pm.listItems(PasswordManagerKind.bitwarden, ask: asking([], ['m'])), isEmpty);
    expect(runner.calls.where((c) => c.args.first == 'list'), isEmpty, reason: 'never the whole vault');
    final bw = await pm.listItems(PasswordManagerKind.bitwarden, search: 'web', ask: asking([], ['m']));
    expect([for (final i in bw) (i.title, i.username, i.ref.target)], [('web1', 'deploy', _bwId)]);

    // KeePassXC: entries, not groups or the recycle bin.
    final kpx = await pm.listItems(PasswordManagerKind.keePassXc, ask: asking([], ['db-pass']));
    expect([for (final i in kpx) (i.title, i.where, i.ref.target)],
        [('web1', 'Servers', 'Servers/web1'), ('Root entry', null, 'Root entry')]);
    expect(runner.calls.last.args, ['ls', '--quiet', '--recursive', '--flatten', '--', '/p.kdbx']);
  });

  test('moving a saved password in: it goes on the tool\'s input, never as an argument; the new item\'s reference comes back',
      () async {
    const secret = 'hunter2-moved';
    final runner = _FakeRunner((c) {
      final a = c.args.join(' ');
      if (a == 'vault list --format=json') {
        return const PmProcessResult(0, '[{"id":"vvvvvvvvvvvvvvvvvvvvvvvvvv","name":"Engineering"},{"id":"bad id","name":"x"}]', '');
      }
      if (a.startsWith('item create -')) {
        final t = jsonDecode(c.stdin!) as Map;
        expect(t['category'], 'LOGIN');
        expect((t['fields'] as List).firstWhere((f) => f['purpose'] == 'PASSWORD')['value'], secret);
        return const PmProcessResult(0, '{"id":"nnnnnnnnnnnnnnnnnnnnnnnnnn","vault":{"id":"vvvvvvvvvvvvvvvvvvvvvvvvvv"}}', '');
      }
      if (c.args.first == 'unlock') return const PmProcessResult(0, 'S', '');
      if (a == 'create item') {
        final item = jsonDecode(utf8.decode(base64.decode(c.stdin!))) as Map;
        expect((item['login'] as Map)['password'], secret);
        return const PmProcessResult(0, '{"id":"$_bwId","name":"web1"}', '');
      }
      if (c.args.first == 'add') {
        expect(c.stdin, 'db-pass\n$secret\n');
        return const PmProcessResult(0, 'Successfully added entry web1.', '');
      }
      return const PmProcessResult(1, '', 'no');
    });
    final pm = managers(runner, db: const KeePassXcDatabase(path: '/p.kdbx'));
    final ask = asking([], ['master', 'db-pass']);

    expect(await pm.onePasswordVaults(), [(id: 'vvvvvvvvvvvvvvvvvvvvvvvvvv', name: 'Engineering')]);
    final op = await pm.store(PasswordManagerKind.onePassword,
        title: 'web1', username: 'deploy', password: secret, url: 'ssh://web1:22', vaultId: 'vvvvvvvvvvvvvvvvvvvvvvvvvv', ask: ask);
    expect(op.target, 'op://vvvvvvvvvvvvvvvvvvvvvvvvvv/nnnnnnnnnnnnnnnnnnnnnnnnnn/password');
    final bw = await pm.store(PasswordManagerKind.bitwarden, title: 'web1', username: 'deploy', password: secret, ask: ask);
    expect(bw.target, _bwId);
    final kpx = await pm.store(PasswordManagerKind.keePassXc,
        title: 'web1', username: '-oops', password: secret, entryPath: 'ZestSSH/web1', ask: ask);
    expect(kpx.target, 'ZestSSH/web1');
    expect(runner.calls.last.args,
        ['add', '--quiet', '--username=-oops', '--password-prompt', '--', '/p.kdbx', 'ZestSSH/web1']);
    for (final c in runner.calls) {
      expect(c.args.join(' '), isNot(contains(secret)), reason: 'never an argument');
    }
    // A vault or an entry that is not one is refused before anything runs.
    final before = runner.calls.length;
    await expectLater(pm.store(PasswordManagerKind.onePassword, title: 't', username: 'u', password: secret, vaultId: '--help', ask: ask),
        throwsA(isA<PasswordManagerException>()));
    await expectLater(pm.store(PasswordManagerKind.keePassXc, title: 't', username: 'u', password: secret, entryPath: '-x', ask: ask),
        throwsA(isA<PasswordManagerException>()));
    expect(runner.calls.length, before);
  });
}
