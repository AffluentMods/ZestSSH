import 'dart:convert';
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
import 'package:zestssh/features/monitoring/monitor_state_ui.dart' show failedCheckSaid;
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_connection_factory.dart' show MonitorExecOutcome;
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

/// A host that ends the connection while it is being signed in to, saying
/// why (3.0; a reported case was an address banned by a
/// server that counts refused sign-ins), with a real OpenSSH server: the
/// fourth test server (127.0.0.1:2293, tool/test_sshd.sh of the SSH core
/// package) allows one failed sign-in, and ends the connection with "Too
/// many authentication failures" at the first key it does not know. Skips
/// itself when that server is not running.
///
/// Such an end was taken for a connection that broke: a session that had
/// dropped went on trying, ten times, and Server Monitor tried again by a
/// timer for as long as the host was monitored, each try one more failed
/// sign-in in the host's log.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final oneTryPort = int.tryParse(env['ZESTSSH_TEST_ONETRY_SSHD_PORT'] ?? '') ?? 2293;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  var up = false;
  String? keyPem;
  String? strangerPem;
  SSHHostKey? hostKey;
  late AppDatabase tree;
  late ProviderContainer container;

  setUpAll(() async {
    try {
      final file = File('$dir/client_ed25519');
      if (!file.existsSync()) return;
      keyPem = file.readAsStringSync();
      strangerPem = (await KeyGenerationService().generateEd25519(comment: 'stranger')).privatePem;
      // The server's host key, as a person approves it once.
      final client = SSHClient(
        await SSHSocket.connect(sshHost, oneTryPort, timeout: const Duration(seconds: 2)),
        username: user,
        identities: SSHKeyPair.fromPem(keyPem!),
        onVerifyHostKey: (type, bytes) {
          hostKey = SSHHostKey(type: type, bytes: Uint8List.fromList(bytes));
          return true;
        },
      );
      await client.authenticated.timeout(const Duration(seconds: 20));
      client.close();
      up = true;
    } catch (_) {
      up = false;
    }
  });

  /// What this device holds as the key of the identity the host signs in with.
  void keyOnDevice(String pem) => FlutterSecureStorage.setMockInitialValues({'identity_key_id-deploy': pem});

  setUp(() async {
    if (keyPem != null) keyOnDevice(keyPem!);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(autoReconnectEnabledProvider.notifier).state = true;
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(milliseconds: 20);
    if (!up) return;
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
          id: 'id-deploy',
          label: 'deploy key',
          username: user,
          authMethod: 'publicKey',
          createdAt: at,
        ));
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: sshHost,
          port: Value(oneTryPort),
          identityId: const Value('id-deploy'),
          createdAt: at,
          updatedAt: at,
        ));
    await KnownHostsService(tree.knownHostsDao).trustHost(sshHost, oneTryPort, hostKey!);
  });

  tearDown(() async {
    ActiveSessionsNotifier.debugReconnectDelay = null;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 40)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('a session that dropped does not go on trying a host that ends the sign-in, saying why: one try, and the '
      'session stays with the host\'s reason', () async {
    if (!up) {
      markTestSkipped('no test sshd that allows one failed sign-in at $sshHost:$oneTryPort');
      return;
    }
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await until(() => stateOf(id)?.status == SessionStatus.connected || stateOf(id)?.status == SessionStatus.error,
        'the connection');
    expect(stateOf(id)?.status, SessionStatus.connected, reason: '${stateOf(id)?.errorMessage}');

    // The key on this device is no longer the one the host knows, and the connection ends under the session.
    keyOnDevice(strangerPem!);
    sessions().sendInput(id, utf8.encode(r'kill -KILL $PPID' '\n'));
    await until(() {
      final s = stateOf(id);
      return s != null && s.dropped && !s.isReconnecting && s.errorMessage != null;
    }, 'the tries to end');
    // (Nine more tries would fit into this: they are 20 ms apart here.)
    await Future<void>.delayed(const Duration(seconds: 2));
    final last = stateOf(id)!;
    expect((last.status, last.dropped, last.isReconnecting, last.reconnectAttempt),
        (SessionStatus.disconnected, true, false, 1));
    expect(last.errorMessage, 'ZestSSH: The host ended the connection. Its reason: Too many authentication failures');
    await sessions().endSession(id);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('Server Monitor takes such an end for a refused sign-in, which it does not try again by a timer', () async {
    if (!up) {
      markTestSkipped('no test sshd that allows one failed sign-in at $sshHost:$oneTryPort');
      return;
    }
    keyOnDevice(strangerPem!);
    final polled = await sessions().openExecClient((await tree.connectionsDao.getById('h-web'))!);
    expect(polled.outcome, MonitorExecOutcome.signInRefused, reason: '${polled.failedWith}');
    // And what the host's status says of it is what the host said.
    expect(failedCheckSaid(polled.failedWith!, host: 'web-01', port: oneTryPort),
        'The host ended the connection. Its reason: Too many authentication failures');

    // With the key the host knows it is checked as any other.
    keyOnDevice(keyPem!);
    final made = await sessions().openExecClient((await tree.connectionsDao.getById('h-web'))!);
    expect(made.outcome, MonitorExecOutcome.ok, reason: '${made.failedWith}');
    await made.service!.disconnect();
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

/// No networks are set up here: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
