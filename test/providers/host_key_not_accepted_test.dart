import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/changed_host_keys_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

/// A host's key that its person is shown and does not accept (3.0, the SSH
/// core's audit, found while what is said of a sign-in that did not happen
/// was put right), through a session of the app against a REAL OpenSSH
/// server (the WSL test sshd on 127.0.0.1:2299; the tests skip themselves
/// when it is not running; ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR
/// say where it is).
///
/// Whoever said no to a host's key was then shown a connection that had
/// failed: "Authentication Failed: The server closed the connection before
/// completing login.", with a tip to check the sign-in details. They had
/// said no themselves, and nothing had been sent to the host.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  late bool up;
  String? keyPem;
  late AppDatabase tree;
  late ProviderContainer container;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (up) keyPem = file.readAsStringSync();
    } catch (_) {
      up = false;
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({if (keyPem != null) 'identity_key_id-deploy': keyPem!});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
      askBeforeTrustingKeysProvider.overrideWith((ref) => true),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(autoReconnectEnabledProvider.notifier).state = false;
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
          host: host,
          port: Value(port),
          identityId: const Value('id-deploy'),
          createdAt: at,
          updatedAt: at,
        ));
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  /// Answers every question about a host's key with [accept], and keeps
  /// what was asked.
  List<HostKeyVerification> answering(bool accept) {
    final asked = <HostKeyVerification>[];
    container.listen(hostKeyVerificationQueueProvider, (_, queue) {
      for (final question in queue) {
        if (question.completer.isCompleted) continue;
        asked.add(question);
        Future<void>.microtask(
            () => container.read(hostKeyVerificationQueueProvider.notifier).resolve(question, accept));
      }
    });
    return asked;
  }

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 30)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<String> started() async => sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;

  test('a new host whose key is accepted: connected, and the key is known from then on', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    final asked = answering(true);
    final id = await started();
    await until(() => stateOf(id)?.status == SessionStatus.connected || stateOf(id)?.status == SessionStatus.error,
        'the connection');
    expect(stateOf(id)?.status, SessionStatus.connected, reason: '${stateOf(id)?.errorMessage}');
    expect(asked, hasLength(1));
    expect(asked.single.isChanged, isFalse);
    expect(await tree.knownHostsDao.getAll(), hasLength(1));
    await sessions().endSession(id);
  });

  test('a new host whose key its person does not accept: the session is gone, with no failure to show, and the key '
      'is not known', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    final asked = answering(false);
    final id = await started();
    await until(() => stateOf(id) == null || stateOf(id)?.status == SessionStatus.error, 'the session to go');
    expect(asked, hasLength(1));
    expect(asked.single.isChanged, isFalse);
    expect(stateOf(id), isNull, reason: 'they said no themselves: ${stateOf(id)?.errorMessage}');
    expect(container.read(connectionErrorProvider), isNull, reason: 'nothing failed that a dialog should say');
    expect(await tree.knownHostsDao.getAll(), isEmpty);
  });

  test('a host that shows another key than the one this device trusts, not accepted: gone the same way, and the '
      'host is still marked as one whose key changed', () async {
    if (!up) return markTestSkipped('no test sshd at $host:$port');
    // Another key is trusted for it, as before the host was set up anew.
    await KnownHostsService(tree.knownHostsDao).trustHost(
        host, port, SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => i))));
    final asked = answering(false);
    final id = await started();
    await until(() => stateOf(id) == null || stateOf(id)?.status == SessionStatus.error, 'the session to go');
    expect(asked, hasLength(1));
    expect(asked.single.isChanged, isTrue);
    expect(stateOf(id), isNull, reason: 'they said no themselves: ${stateOf(id)?.errorMessage}');
    expect(container.read(connectionErrorProvider), isNull);
    expect(container.read(changedHostKeysProvider), isNotEmpty, reason: 'the host card still warns');
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
