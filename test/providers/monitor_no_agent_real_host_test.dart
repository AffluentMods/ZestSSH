import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';
import 'package:zestssh/services/ssh_service.dart';

/// Server Monitor's own connection to a host, on a real OpenSSH server: it
/// signs in by itself, in the background, and only reads figures. It
/// forwarded the person's agent to the host whenever the host's "Forward
/// SSH agent" switch was on: the switch is for a session its person works
/// in (to reach a next host from there), and a connection nobody sees has
/// no use for the agent, while forwarding it lets that host use the
/// person's keys for as long as the monitor runs.
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (tool/test_sshd.sh
/// starts it); its own client key logs in. Skips itself when the server is
/// not running. Override the location with ZESTSSH_TEST_SSHD_HOST / _PORT /
/// _USER / _DIR.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final sshPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  late bool up;
  SSHKeyPair? key;
  late AppDatabase tree;
  late ProviderContainer container;

  setUpAll(() async {
    try {
      final s = await Socket.connect(sshHost, sshPort, timeout: const Duration(seconds: 2));
      s.destroy();
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (up) key = SSHKeyPair.fromPem(file.readAsStringSync()).single;
    } catch (_) {
      up = false;
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
      sshConnectionFactoryProvider.overrideWithValue(_Signs(user, () => key!)),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  /// The test server, saved as web-01, with its switch for the agent.
  Future<Connection> saved({required bool forwardAgent}) async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: sshHost,
          port: Value(sshPort),
          forwardAgent: Value(forwardAgent),
          createdAt: at,
          updatedAt: at,
        ));
    return (await tree.connectionsDao.getById('h-web'))!;
  }

  Future<String> run(SshService ssh, String command) async =>
      utf8.decode(await ssh.client.run(command).timeout(const Duration(seconds: 15))).trim();

  test('Server Monitor\'s own connection forwards no agent, whatever the host\'s switch says, and reads its figures',
      () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    for (final forwardAgent in [true, false]) {
      final connection = await saved(forwardAgent: forwardAgent);
      final opened = await container.read(activeSessionsProvider.notifier).openExecClient(connection);
      expect(opened.outcome, MonitorExecOutcome.ok, reason: '${opened.failedWith}');
      final ssh = opened.service!;
      addTearDown(ssh.disconnect);
      expect(ssh.forwardAgent, isFalse, reason: 'the switch: $forwardAgent');
      // What the host itself has of it: no agent to ask.
      expect(await run(ssh, 'echo "[\$SSH_AUTH_SOCK]"'), '[]', reason: 'the switch: $forwardAgent');
      // And the figures are read.
      final stats = await ServerStatsService.getStats(ssh.client).timeout(const Duration(seconds: 40));
      expect(stats.cpuPercent, isNotNull);
      expect(stats.kernel, await run(ssh, 'uname -r'));
      ServerStatsService.clearCache(ssh.client);
      await ssh.disconnect();
      await tree.delete(tree.connections).go();
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}

/// Every host can be signed in to with nobody asked: the test server's key,
/// and its host key taken as known.
class _Signs implements SshConnectionFactory {
  _Signs(this.user, this.key);

  final String user;
  final SSHKeyPair Function() key;

  @override
  Future<SilentCreds?> resolveCredentialsSilently(Connection connection) async =>
      (username: user, password: null, keyPairs: [key()]);

  @override
  ChainHostKeyVerifyCallback buildTrustOnlyHostKeyVerifier(HostKeyReviewSignal signal, {TrustTarget? target}) =>
      (_, _, _, {hostId}) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

/// No networks are set up here: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
