import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/authorized_keys_edit.dart';
import 'package:zestssh/features/keys/replace_key.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/run/install_key.dart';
import 'package:zestssh/features/run/run_client.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';

/// Replace on all hosts (3.0, Keys) against real OpenSSH servers (WSL), the
/// risky step most of all: taking the old key's line out of authorized_keys.
///
/// First, on the test sshd at 127.0.0.1:2299 (tool/test_sshd.sh), signed in
/// with its client key, the read and write commands on files of their own in
/// a folder made for the test (never the account's own ~/.ssh): before and
/// after, byte for byte; the file's permissions kept; other lines, their
/// comments and options kept; a wrong old key never taken out; a file that
/// changed meanwhile not written; a link not written through.
///
/// Then the whole replacement, as the app does it (signed in as a session
/// is, the new key proved on a connection of its own, the saved login
/// changed), on an sshd started for the test on 127.0.0.1:2281 whose
/// authorized keys are a file of the test's own; beside it a host the old
/// key does not sign in to (it fails, and nothing of it changes) and one
/// reached through a jump host (skipped). Skips itself without WSL or the
/// test sshd.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final sshPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  const e2ePort = 2281;
  final en = lookupAppLocalizations(const Locale('en'));
  var up = false;
  String? clientPem;
  SSHHostKey? hostKey;
  late String home;
  late String work;

  /// Signs in to the test sshd with its client key.
  Future<ReplaceLink> signIn({int port = 0, String? pem}) async {
    final ssh = SshService(
      host: sshHost,
      port: port == 0 ? sshPort : port,
      username: user,
      keyPairs: SSHKeyPair.fromPem(pem ?? clientPem!),
      onHostKeyVerify: (h, p, k) async => true,
    );
    await ssh.connectExec();
    return SshReplaceLink(RunClient(ssh));
  }

  Future<String> sh(ReplaceLink link, String command, {List<int>? input}) async {
    final r = await link.run(command, input: input);
    return latin1.decode(r.out);
  }

  setUpAll(() async {
    try {
      final file = File('$dir/client_ed25519');
      if (!file.existsSync()) return;
      clientPem = file.readAsStringSync();
      final client = SSHClient(
        await SSHSocket.connect(sshHost, sshPort, timeout: const Duration(seconds: 2)),
        username: user,
        identities: SSHKeyPair.fromPem(clientPem!),
        onVerifyHostKey: (type, bytes) {
          hostKey = SSHHostKey(type: type, bytes: Uint8List.fromList(bytes));
          return true;
        },
      );
      await client.authenticated.timeout(const Duration(seconds: 20));
      client.close();
      final link = await signIn();
      home = (await sh(link, r'printf %s "$HOME"')).trim();
      work = '$home/zestssh-sshd-test/replace-${Random().nextInt(1 << 30)}';
      await sh(link, 'mkdir -p $work && chmod 700 $work');
      await link.close();
      up = isPlainPath(work);
    } catch (_) {
      up = false;
    }
  });

  tearDownAll(() async {
    if (!up) return;
    final link = await signIn();
    await sh(link, 'if [ -f $work/sshd.pid ]; then kill "\$(cat $work/sshd.pid)"; fi; rm -rf $work');
    await link.close();
  });

  group('the read and write of authorized_keys on a real host', () {
    late String other;
    late String oldLine;
    late String newLine;

    setUpAll(() async {
      if (!up) return;
      final gen = KeyGenerationService();
      other = (await gen.generateEd25519(comment: 'ci@build')).publicOpenSSH.trim();
      oldLine = (await gen.generateEd25519(comment: 'old key')).publicOpenSSH.trim();
      newLine = (await gen.generateEd25519(comment: 'new key')).publicOpenSSH.trim();
    });

    /// Writes [content] to [path] with [mode], as it is.
    Future<void> put(ReplaceLink link, String path, List<int> content, {String mode = '640'}) async {
      await sh(link, 'cat > $path && chmod $mode $path', input: content);
    }

    Future<List<int>> get(ReplaceLink link, String path) async => (await link.run('cat $path')).out;

    test('a line taken out: every other byte as it was, the permissions kept, the checksum the one written', () async {
      if (!up) return markTestSkipped('no test sshd at $sshHost:$sshPort');
      final link = await signIn();
      try {
        final path = '$work/ak1';
        final before = latin1.encode('# ops keys\r\nfrom="10.0.0.0/8",no-pty $other\r\n$oldLine\n\n'
            '# caf\xe9 note\n$newLine');
        await put(link, path, before);
        final read = readAuthorizedKeysOutput((await link.run(readAuthorizedKeysCommand(path))).out);
        expect(read, isA<AuthorizedKeysFile>());
        final file = read! as AuthorizedKeysFile;
        expect(file.bytes, before, reason: 'read byte for byte');
        final edit = removeKeyLines(file.bytes, blobOfPublicLine(oldLine)!, keep: blobOfPublicLine(newLine));
        expect(edit.removed, [3]);
        final wrote = latin1.decode((await link.run(writeAuthorizedKeysCommand(file.sum, path), input: edit.bytes)).out);
        expect(wrote, contains('$kAkWritten ${posixCksum(edit.bytes)}'));
        final after = await get(link, path);
        expect(after, latin1.encode('# ops keys\r\nfrom="10.0.0.0/8",no-pty $other\r\n\n# caf\xe9 note\n$newLine'));
        expect((await sh(link, 'stat -c %a $path')).trim(), '640', reason: 'its permissions kept');
        expect((await sh(link, 'ls -a $work')).contains('zestssh-'), isFalse, reason: 'no file of its own left beside it');
      } finally {
        await link.close();
      }
    });

    test('a wrong old key takes nothing out, and the file is never written', () async {
      if (!up) return markTestSkipped('no test sshd at $sshHost:$sshPort');
      final link = await signIn();
      try {
        final path = '$work/ak2';
        final before = latin1.encode('$other\n$newLine\n');
        await put(link, path, before, mode: '600');
        final file = readAuthorizedKeysOutput((await link.run(readAuthorizedKeysCommand(path))).out)! as AuthorizedKeysFile;
        final edit = removeKeyLines(file.bytes, blobOfPublicLine(oldLine)!, keep: blobOfPublicLine(newLine));
        expect(edit.removed, isEmpty);
        expect(await get(link, path), before);
      } finally {
        await link.close();
      }
    });

    test('a file that changed after it was read is not written', () async {
      if (!up) return markTestSkipped('no test sshd at $sshHost:$sshPort');
      final link = await signIn();
      try {
        final path = '$work/ak3';
        await put(link, path, latin1.encode('$oldLine\n$newLine\n'));
        final file = readAuthorizedKeysOutput((await link.run(readAuthorizedKeysCommand(path))).out)! as AuthorizedKeysFile;
        await sh(link, 'printf "%s\\n" "$other" >> $path');
        final changed = await get(link, path);
        final edit = removeKeyLines(file.bytes, blobOfPublicLine(oldLine)!, keep: blobOfPublicLine(newLine));
        final wrote = latin1.decode((await link.run(writeAuthorizedKeysCommand(file.sum, path), input: edit.bytes)).out);
        expect(wrote, contains(kAkChanged));
        expect(await get(link, path), changed);
      } finally {
        await link.close();
      }
    });

    test('a link is said, and never written through', () async {
      if (!up) return markTestSkipped('no test sshd at $sshHost:$sshPort');
      final link = await signIn();
      try {
        final target = '$work/real_keys';
        final path = '$work/ak4';
        await put(link, target, latin1.encode('$oldLine\n'));
        await sh(link, 'ln -s $target $path');
        expect(readAuthorizedKeysOutput((await link.run(readAuthorizedKeysCommand(path))).out), isA<AuthorizedKeysIsLink>());
        final r = await link.run(writeAuthorizedKeysCommand(posixCksum(latin1.encode('$oldLine\n')), path), input: const []);
        expect(r.exitCode, 8);
        expect(await get(link, target), latin1.encode('$oldLine\n'));
        expect((await sh(link, 'test -L $path && echo link')).trim(), 'link');
      } finally {
        await link.close();
      }
    });

    test('no file: said; the add step makes it (readable by the account alone), then says the key is there', () async {
      if (!up) return markTestSkipped('no test sshd at $sshHost:$sshPort');
      final link = await signIn();
      try {
        final path = '$work/ak5';
        expect(readAuthorizedKeysOutput((await link.run(readAuthorizedKeysCommand(path))).out), isA<AuthorizedKeysMissing>());
        final add = latin1.decode((await link.run(installKeyCommandFor(path), input: utf8.encode('$newLine\n'))).out);
        expect(add, contains(kKeyAdded));
        final again = latin1.decode((await link.run(installKeyCommandFor(path), input: utf8.encode('$newLine\n'))).out);
        expect(again, contains(kKeyThere));
        expect(await get(link, path), utf8.encode('$newLine\n'));
        expect((await sh(link, 'stat -c %a $path')).trim(), '600');
      } finally {
        await link.close();
      }
    });
  });

  group('the whole replacement, as the app does it', () {
    late String oldPem;
    late String oldLine;
    late String bystander;
    late AppDatabase tree;
    late ProviderContainer container;
    var e2eUp = false;
    SSHHostKey? e2eHostKey;

    setUpAll(() async {
      if (!up) return;
      final gen = KeyGenerationService();
      final old = await gen.generateEd25519(comment: 'deploy');
      oldPem = old.privatePem;
      oldLine = old.publicOpenSSH.trim();
      bystander = (await gen.generateEd25519(comment: 'ci@build')).publicOpenSSH.trim();
      final link = await signIn();
      try {
        // Its authorized keys: a note, another key with options, the old key.
        await sh(link, 'cat > $work/authorized_keys && chmod 640 $work/authorized_keys',
            input: utf8.encode('# deploy keys\nno-pty,from="127.0.0.1" $bystander\n$oldLine\n'));
        final config = [
          'Port $e2ePort',
          'ListenAddress 127.0.0.1',
          'HostKey $work/host_ed25519',
          'AuthorizedKeysFile $work/authorized_keys',
          'PasswordAuthentication no',
          'KbdInteractiveAuthentication no',
          'PubkeyAuthentication yes',
          'UsePAM no',
          'StrictModes no',
          'PidFile $work/sshd.pid',
          'PerSourcePenalties no',
        ].join('\n');
        await sh(link, 'cat > $work/sshd_config', input: utf8.encode('$config\n'));
        final started = await sh(link,
            'ssh-keygen -q -t ed25519 -N "" -f $work/host_ed25519 && '
            '{ s=\$(command -v sshd || echo /usr/sbin/sshd); "\$s" -t -f $work/sshd_config 2>/dev/null || sed -i "/PerSourcePenalties/d" $work/sshd_config; '
            '"\$s" -f $work/sshd_config -E $work/sshd.log; } && sleep 1 && test -f $work/sshd.pid && echo started');
        e2eUp = started.contains('started');
      } finally {
        await link.close();
      }
      if (!e2eUp) return;
      final client = SSHClient(
        await SSHSocket.connect(sshHost, e2ePort, timeout: const Duration(seconds: 2)),
        username: user,
        identities: SSHKeyPair.fromPem(oldPem),
        onVerifyHostKey: (type, bytes) {
          e2eHostKey = SSHHostKey(type: type, bytes: Uint8List.fromList(bytes));
          return true;
        },
      );
      await client.authenticated.timeout(const Duration(seconds: 20));
      client.close();
    });

    Future<void> start() async {
      FlutterSecureStorage.setMockInitialValues({'identity_key_id-old': oldPem});
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      L10nGlobal.update(en);
      tree = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro()),
        isAppLockedProvider.overrideWith((ref) => _Lock()),
        connectionResolverProvider.overrideWithValue(_AsSaved()),
        replaceKeyRunWith((ref) => replaceKeyDepsOf(ref, authorizedKeys: '$work/authorized_keys')),
      ]);
      container.read(databaseSessionProvider.notifier).seed(tree);
      final at = DateTime(2026, 10, 22);
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: 'id-old',
            label: 'deploy',
            username: user,
            authMethod: 'publicKey',
            keyType: const Value('ed25519'),
            publicKeyData: Value(oldLine),
            createdAt: at,
          ));
      for (final (id, port, via) in [('h-new', e2ePort, null), ('h-shared', sshPort, null), ('h-behind', e2ePort, 'h-new')]) {
        await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: id,
              host: sshHost,
              port: Value(port),
              identityId: const Value('id-old'),
              connectViaId: Value(via),
              createdAt: at,
              updatedAt: at,
            ));
      }
      final known = KnownHostsService(tree.knownHostsDao);
      await known.trustHost(sshHost, e2ePort, e2eHostKey!);
      await known.trustHost(sshHost, sshPort, hostKey!);
    }

    Future<ReplaceRun> runIt(List<String> hostIds) async {
      final old = (await tree.identitiesDao.getById('id-old'))!;
      final hosts = [for (final id in hostIds) (await tree.connectionsDao.getById(id))!];
      await container.read(replaceKeyRunProvider.notifier).start(old, hosts, type: KeyType.ed25519, newLabel: 'deploy (new)');
      final run = container.read(replaceKeyRunProvider)!;
      expect(run.running, isFalse);
      return run;
    }

    Future<bool> signsIn(String pem) async {
      try {
        final link = await signIn(port: e2ePort, pem: pem);
        await link.close();
        return true;
      } catch (_) {
        return false;
      }
    }

    test('the host is done, the one that fails and the one behind a jump host are left as they were; run again, '
        'the same new key', () async {
      if (!up || !e2eUp) return markTestSkipped('no WSL sshd for the whole replacement');
      await start();
      addTearDown(() async {
        container.dispose();
        await tree.close();
      });
      final run = await runIt(['h-new', 'h-shared', 'h-behind']);
      final byId = {for (final h in run.hosts) h.host.id: h};
      expect(byId['h-new']!.step, ReplaceStep.done, reason: '${byId['h-new']!.why} ${byId['h-new']!.details}');
      expect(byId['h-new']!.removed, 1);
      expect(byId['h-shared']!.step, ReplaceStep.failed);
      expect(byId['h-shared']!.why, ReplaceWhy.signInFailed);
      expect(byId['h-behind']!.step, ReplaceStep.skipped);
      expect(byId['h-behind']!.why, ReplaceWhy.jumpHost);

      // The new key, kept in the vault with its user, and its line.
      final newId = run.newId!;
      final made = (await tree.identitiesDao.getById(newId))!;
      expect(made.label, 'deploy (new)');
      expect(made.username, user);
      final newPem = await container.read(identitySecretsProvider).read(newId, IdentitySecret.privateKey);
      expect(newPem, isNotNull);
      final newLine = made.publicKeyData!.trim();

      // authorized_keys: the old line gone, every other line as it was, the
      // new key after them, its permissions kept.
      final link = await signIn();
      try {
        expect(latin1.decode((await link.run('cat $work/authorized_keys')).out),
            '# deploy keys\nno-pty,from="127.0.0.1" $bystander\n$newLine\n');
        expect((await sh(link, 'stat -c %a $work/authorized_keys')).trim(), '640');
      } finally {
        await link.close();
      }
      expect(await signsIn(newPem!), isTrue, reason: 'the new key signs in');
      expect(await signsIn(oldPem), isFalse, reason: 'the old key no longer does');

      // The saved logins: the host done points at the new key, the others
      // still at the old one.
      expect((await tree.connectionsDao.getById('h-new'))!.identityId, newId);
      expect((await tree.connectionsDao.getById('h-shared'))!.identityId, 'id-old');
      expect((await tree.connectionsDao.getById('h-behind'))!.identityId, 'id-old');

      // Run again: it goes on with the same new key.
      final again = await runIt(['h-shared']);
      expect(again.newId, newId);
      expect(await tree.identitiesDao.getAll(), hasLength(2), reason: 'no second new key');
    });
  });
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No networks are set up: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
