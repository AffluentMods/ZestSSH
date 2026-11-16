import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/key_passphrase.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

/// A key's passphrase added, changed and taken off (3.0, Keys, PROTECTION):
/// the private key written again sealed as OpenSSH seals it, the
/// passphrase kept with it or not as chosen, what the device knows of it
/// kept for the details pane, and a wrong or missing current passphrase
/// writing nothing. And the key still signs in afterwards, against the real
/// test sshd (127.0.0.1:2299, tool/test_sshd.sh): with the passphrase kept
/// it asks nothing; without, connecting asks for it, as for any key whose
/// passphrase is not kept.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String plainPem;
  late AppDatabase db;
  late ProviderContainer container;

  setUpAll(() async {
    plainPem = (await KeyGenerationService().generateEd25519(comment: 'deploy')).privatePem;
  });

  Future<void> start(String pem, {String? kept, List<Override> overrides = const []}) async {
    FlutterSecureStorage.setMockInitialValues({
      'identity_key_id-k': pem,
      'identity_passphrase_id-k': ?kept,
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs), ...overrides]);
    container.read(databaseSessionProvider.notifier).seed(db);
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<Identity> key(String username) async {
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'id-k',
          label: 'deploy',
          username: username,
          authMethod: 'publicKey',
          createdAt: DateTime(2026, 10, 22),
        ));
    return (await db.identitiesDao.getById('id-k'))!;
  }

  IdentityCrudNotifier crud() => container.read(identityCrudProvider);
  KeyPassphraseService service() => container.read(keyPassphraseServiceProvider);
  String publicOf(String pem, [String? passphrase]) =>
      SSHKeyPair.fromPem(pem, passphrase).first.toPublicKey().encode().join(',');

  test('added and kept with the key: the stored key is sealed with it, and the device knows it has one', () async {
    await start(plainPem);
    final k = await key('ops');
    expect(await container.read(keyPassphraseFlagsProvider).all(), isEmpty);
    await service().change(k, next: 'horse battery', keepWithKey: true);
    final stored = (await crud().getPrivateKey('id-k'))!;
    expect(OpenSSHKeyFile.isSealed(stored), isTrue);
    expect(publicOf(stored, 'horse battery'), publicOf(plainPem));
    expect(await crud().getKeyPassphrase('id-k'), 'horse battery');
    expect(await container.read(keyPassphraseFlagsProvider).all(), {'id-k': true});
  });

  test('added and not kept: no passphrase is kept beside it', () async {
    await start(plainPem);
    final k = await key('ops');
    await service().change(k, next: 'not kept', keepWithKey: false);
    expect(OpenSSHKeyFile.isSealed((await crud().getPrivateKey('id-k'))!), isTrue);
    expect(await crud().getKeyPassphrase('id-k'), isNull);
  });

  test('changed with the kept one; a wrong or missing current one writes nothing', () async {
    final sealed = OpenSSHKeyFile.rewrite(plainPem, newPassphrase: 'first');
    await start(sealed, kept: 'first');
    final k = await key('ops');
    await service().change(k, next: 'second');
    final now = (await crud().getPrivateKey('id-k'))!;
    expect(publicOf(now, 'second'), publicOf(plainPem));
    expect(await crud().getKeyPassphrase('id-k'), 'second');

    // The kept one taken away: the current one must be typed.
    await container.read(identitySecretsProvider).write('id-k', IdentitySecret.passphrase, null);
    await expectLater(service().change(k, next: 'third'),
        throwsA(isA<PassphraseChangeFailed>().having((e) => e.why, 'why', PassphraseChangeRefusal.needsCurrent)));
    await expectLater(service().change(k, current: 'wrong', next: 'third'),
        throwsA(isA<PassphraseChangeFailed>().having((e) => e.why, 'why', PassphraseChangeRefusal.wrongCurrent)));
    expect(await crud().getPrivateKey('id-k'), now, reason: 'nothing written');
  });

  test('taken off: the key is open again, and no passphrase is kept beside it', () async {
    await start(OpenSSHKeyFile.rewrite(plainPem, newPassphrase: 'p'), kept: 'p');
    final k = await key('ops');
    await service().change(k);
    final now = (await crud().getPrivateKey('id-k'))!;
    expect(OpenSSHKeyFile.isSealed(now), isFalse);
    expect(publicOf(now), publicOf(plainPem));
    expect(await crud().getKeyPassphrase('id-k'), isNull);
    expect(await container.read(keyPassphraseFlagsProvider).all(), {'id-k': false});
  });

  group('the key still signs in afterwards (real test sshd)', () {
    final env = Platform.environment;
    final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
    final sshPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
    final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
    final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
    String? clientPem;
    SSHHostKey? hostKey;

    setUpAll(() async {
      try {
        final file = File('$dir/client_ed25519');
        if (!file.existsSync()) return;
        final pem = file.readAsStringSync();
        final client = SSHClient(
          await SSHSocket.connect(sshHost, sshPort, timeout: const Duration(seconds: 2)),
          username: user,
          identities: SSHKeyPair.fromPem(pem),
          onVerifyHostKey: (type, bytes) {
            hostKey = SSHHostKey(type: type, bytes: Uint8List.fromList(bytes));
            return true;
          },
        );
        await client.authenticated.timeout(const Duration(seconds: 20));
        client.close();
        clientPem = pem;
      } catch (_) {
        clientPem = null;
      }
    });

    Future<Connection> setUpHost() async {
      L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
      await key(user);
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h',
            label: 'test sshd',
            host: sshHost,
            port: Value(sshPort),
            identityId: const Value('id-k'),
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ));
      await KnownHostsService(db.knownHostsDao).trustHost(sshHost, sshPort, hostKey!);
      return (await db.connectionsDao.getById('h'))!;
    }

    List<Override> app() => [
          isProProvider.overrideWith((ref) => _Pro()),
          isAppLockedProvider.overrideWith((ref) => _Lock()),
          connectionResolverProvider.overrideWithValue(_AsSaved()),
        ];

    test('kept with the key: connecting asks nothing and signs in', () async {
      if (clientPem == null) return markTestSkipped('no test sshd at $sshHost:$sshPort');
      await start(clientPem!, overrides: app());
      final host = await setUpHost();
      await service().change((await db.identitiesDao.getById('id-k'))!, next: 'kept here');
      var asked = false;
      container.listen(passphrasePromptProvider, (_, next) => asked = asked || next != null);
      final run = await container.read(activeSessionsProvider.notifier).openRunClient(host);
      expect(run.ssh.signedInWith, 'publickey');
      await run.ssh.disconnect();
      expect(asked, isFalse);
    });

    test('not kept: connecting asks for it, and signs in with it', () async {
      if (clientPem == null) return markTestSkipped('no test sshd at $sshHost:$sshPort');
      await start(clientPem!, overrides: app());
      final host = await setUpHost();
      await service().change((await db.identitiesDao.getById('id-k'))!, next: 'asked for', keepWithKey: false);
      var asked = 0;
      container.listen(passphrasePromptProvider, (_, next) {
        if (next == null) return;
        asked++;
        next.completer.complete(const PassphrasePromptResult(passphrase: 'asked for'));
      });
      final run = await container.read(activeSessionsProvider.notifier).openRunClient(host);
      expect(run.ssh.signedInWith, 'publickey');
      await run.ssh.disconnect();
      expect(asked, 1);
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

class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
