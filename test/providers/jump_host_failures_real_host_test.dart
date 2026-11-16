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
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_connection_factory.dart' show MonitorExecOutcome, MonitorExecResult;
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;
import 'package:zestssh/utils/error_translator.dart';

/// A host that is reached through a jump host, where the jump host is what
/// fails (3.0, from the SSH core's audit), with real OpenSSH servers: the
/// first test server is the jump host (127.0.0.1:2299) and the second the
/// host behind it (127.0.0.1:2297), both started by tool/test_sshd.sh of
/// the SSH core package. The third (2295) is a second jump host, and the
/// fourth (2293), which allows one failed sign-in, a jump host that ends
/// the connection saying why. Skips itself when they are not running.
///
/// What a jump host failed with was handed on as it came, and said as the
/// host's own failure, with the host's address in it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final jumpPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final targetPort = int.tryParse(env['ZESTSSH_TEST_REKEY_SSHD_PORT'] ?? '') ?? 2297;
  // A second jump host, for a way through two: the third test server.
  final innerPort = int.tryParse(env['ZESTSSH_TEST_BANNER_SSHD_PORT'] ?? '') ?? 2295;
  // A jump host that allows one failed sign-in: the fourth.
  final oneTryPort = int.tryParse(env['ZESTSSH_TEST_ONETRY_SSHD_PORT'] ?? '') ?? 2293;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  late bool up;
  String? keyPem;
  String? strangerPem;
  // A key the servers let open no connection on to another host.
  String? noForwardPem;
  final hostKeys = <int, SSHHostKey>{};
  late AppDatabase tree;
  late ProviderContainer container;

  setUpAll(() async {
    try {
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (!up) return;
      keyPem = file.readAsStringSync();
      strangerPem = (await KeyGenerationService().generateEd25519(comment: 'stranger')).privatePem;
      // Each server's host key, as a person approves it once.
      for (final port in [jumpPort, targetPort, innerPort]) {
        final client = SSHClient(
          await SSHSocket.connect(sshHost, port, timeout: const Duration(seconds: 2)),
          username: user,
          identities: SSHKeyPair.fromPem(keyPem!),
          onVerifyHostKey: (type, bytes) {
            hostKeys[port] = SSHHostKey(type: type, bytes: Uint8List.fromList(bytes));
            return true;
          },
        );
        await client.authenticated.timeout(const Duration(seconds: 20));
        client.close();
      }
    } catch (_) {
      up = false;
    }
    if (!up) return;
    // What a setup of the servers from before these tests may lack: each is asked for by the test that needs it.
    final noForward = File('$dir/client_noforward_ed25519');
    if (noForward.existsSync()) noForwardPem = noForward.readAsStringSync();
    try {
      final client = SSHClient(
        await SSHSocket.connect(sshHost, oneTryPort, timeout: const Duration(seconds: 2)),
        username: user,
        identities: SSHKeyPair.fromPem(keyPem!),
        onVerifyHostKey: (type, bytes) {
          hostKeys[oneTryPort] = SSHHostKey(type: type, bytes: Uint8List.fromList(bytes));
          return true;
        },
      );
      await client.authenticated.timeout(const Duration(seconds: 20));
      client.close();
    } catch (_) {
      hostKeys.remove(oneTryPort);
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      if (keyPem != null) 'identity_key_id-deploy': keyPem!,
      if (strangerPem != null) 'identity_key_id-stranger': strangerPem!,
      if (noForwardPem != null) 'identity_key_id-no-forward': noForwardPem!,
    });
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
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    if (!up) return;
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
          id: 'id-deploy',
          label: 'deploy key',
          username: user,
          authMethod: 'publicKey',
          createdAt: at,
        ));
    // A key the servers do not know, and an identity whose key is not here.
    for (final (identity, label) in [
      ('id-stranger', 'stranger key'),
      ('id-no-key', 'no-key identity'),
      ('id-no-forward', 'no-forwarding key'),
    ]) {
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: identity,
            label: label,
            username: user,
            authMethod: 'publicKey',
            createdAt: at,
          ));
    }
    final known = KnownHostsService(tree.knownHostsDao);
    for (final entry in hostKeys.entries) {
      await known.trustHost(sshHost, entry.key, entry.value);
    }
  });

  tearDown(() async {
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

  /// The host db-primary behind the jump host bastion, each saved with where
  /// it is; a session to db-primary.
  Future<String> started({
    required int bastionPort,
    int? hostPort,
    String? bastionIdentity = 'id-deploy',
    int? innerBastionPort,
  }) async {
    final at = DateTime(2026, 10, 1);
    // With a second jump host: bastion first, inner-bastion behind it, and the host behind that.
    if (innerBastionPort != null) {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: 'h-inner',
            label: 'inner-bastion',
            host: sshHost,
            port: Value(innerBastionPort),
            identityId: const Value('id-deploy'),
            connectViaId: const Value('h-bastion'),
            createdAt: at,
            updatedAt: at,
          ));
    }
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-bastion',
          label: 'bastion',
          host: sshHost,
          port: Value(bastionPort),
          identityId: Value(bastionIdentity),
          createdAt: at,
          updatedAt: at,
        ));
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-db',
          label: 'db-primary',
          host: sshHost,
          port: Value(hostPort ?? targetPort),
          identityId: const Value('id-deploy'),
          connectViaId: Value(innerBastionPort == null ? 'h-bastion' : 'h-inner'),
          createdAt: at,
          updatedAt: at,
        ));
    return sessions().startSession((await tree.connectionsDao.getById('h-db'))!)!;
  }

  /// What the session says of how it failed, as its screen shows it.
  Future<ConnectionError> failureOf(String id) async {
    await until(() => stateOf(id)?.status == SessionStatus.error || stateOf(id)?.status == SessionStatus.connected,
        'the connection to be made or to fail');
    final s = stateOf(id)!;
    expect(s.status, SessionStatus.error, reason: 'it was to fail');
    return ConnectionError.translate(s.errorMessage!, host: s.host, port: s.port, username: s.username);
  }

  test('through a jump host that is there: connected, as before', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $targetPort');
      return;
    }
    final id = await started(bastionPort: jumpPort);
    await until(() => stateOf(id)?.status == SessionStatus.connected || stateOf(id)?.status == SessionStatus.error,
        'the connection');
    expect(stateOf(id)?.status, SessionStatus.connected, reason: '${stateOf(id)?.errorMessage}');
    await sessions().endSession(id);
  });

  test('the jump host cannot be reached: it is named, with its own address in the words, not the host\'s', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $targetPort');
      return;
    }
    // Nothing listens on port 1 of this machine.
    final id = await started(bastionPort: 1);
    final said = await failureOf(id);
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(said.description, startsWith('The jump host bastion could not be reached. '));
    expect(said.description, contains('port 1.'));
    expect(said.description, isNot(contains('$targetPort')), reason: 'the host was never asked');
    expect(stateOf(id)!.connectionLog.where((line) => line.startsWith('jump: bastion failed (reach) - ')), hasLength(1));
    await sessions().endSession(id);
  });

  test('signing in to the jump host does not work: said of the jump host', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $targetPort');
      return;
    }
    final id = await started(bastionPort: jumpPort, bastionIdentity: 'id-stranger');
    final said = await failureOf(id);
    expect(said.type, ConnectionErrorType.saidByApp);
    // (It was "The server closed the connection before completing login.": it refused the key, and closed nothing.)
    expect(
      said.description,
      'Signing in to the jump host bastion did not work. The server rejected your SSH key. ($user@$sshHost)',
    );
    await sessions().endSession(id);
  });

  test('the jump host takes the connection and then says nothing: its sign-in timed out, said of the jump host, in '
      'the time it is given', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $targetPort');
      return;
    }
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final taken = <Socket>[];
    silent.listen(taken.add);
    addTearDown(() async {
      for (final s in taken) {
        s.destroy();
      }
      await silent.close();
    });
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    addTearDown(() => AuthDeadline.debugPatience = null);
    final waited = Stopwatch()..start();
    final id = await started(bastionPort: silent.port);
    final said = await failureOf(id);
    expect(waited.elapsed, lessThan(const Duration(seconds: 10)), reason: 'the second it was given, not fifteen');
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(said.description,
        'Signing in to the jump host bastion did not work. $sshHost did not finish the sign-in in time.');
    expect(stateOf(id)!.connectionLog.where((line) => line.startsWith('jump: bastion failed (signIn) - ')), hasLength(1));
    await sessions().endSession(id);
  });

  test('the jump host cannot reach the host itself: what it said of it, as its own words', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $targetPort');
      return;
    }
    final id = await started(bastionPort: jumpPort, hostPort: 1);
    final said = await failureOf(id);
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(said.description, startsWith('The jump host bastion could not reach db-primary itself. What it said: '));
    expect(said.description.toLowerCase(), contains('refused'));
    await sessions().endSession(id);
  });

  test('through two jump hosts: connected; and where the first cannot reach the second, the first is named, with '
      'the second', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort, $innerPort and $targetPort');
      return;
    }
    final through = await started(bastionPort: jumpPort, innerBastionPort: innerPort);
    await until(
        () => stateOf(through)?.status == SessionStatus.connected || stateOf(through)?.status == SessionStatus.error,
        'the connection');
    expect(stateOf(through)?.status, SessionStatus.connected, reason: '${stateOf(through)?.errorMessage}');
    await sessions().endSession(through);
    await tree.delete(tree.connections).go();

    // Nothing listens where the second jump host is saved to be.
    final id = await started(bastionPort: jumpPort, innerBastionPort: 1);
    final said = await failureOf(id);
    expect(said.description, startsWith('The jump host bastion could not reach inner-bastion itself. What it said: '));
    expect(said.description, isNot(contains('db-primary')));
    await sessions().endSession(id);
  });

  test('the jump host passes no connections on for the key that signed in: said as that, of the jump host', () async {
    if (!up || noForwardPem == null) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $targetPort, or none with the key that may not forward');
      return;
    }
    final id = await started(bastionPort: jumpPort, bastionIdentity: 'id-no-forward');
    final said = await failureOf(id);
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(
      said.description,
      'The jump host bastion does not pass connections on to db-primary: forwarding is turned off there, or not '
      'allowed for this account or key.',
    );
    expect(stateOf(id)!.connectionLog.where((line) => line.startsWith('jump: bastion failed (onward) - ')), hasLength(1));
    await sessions().endSession(id);
  });

  test('the jump host ends the connection itself, saying why: its own words, said as the jump host\'s', () async {
    if (!up || !hostKeys.containsKey(oneTryPort)) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $targetPort, or none that allows one failed sign-in');
      return;
    }
    // The fourth server ends the connection at the first key it does not know.
    final id = await started(bastionPort: oneTryPort, bastionIdentity: 'id-stranger');
    final said = await failureOf(id);
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(said.description, 'The jump host bastion ended the connection. Its reason: Too many authentication failures');
    await sessions().endSession(id);
  });

  test('Server Monitor\'s own connection through a jump host: made; a jump host that refuses the sign-in is a '
      'refused sign-in; and one nobody is there to give its details is asked for them', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $targetPort');
      return;
    }
    Future<MonitorExecResult> polled({String? bastionIdentity = 'id-deploy'}) async {
      await tree.delete(tree.connections).go();
      final at = DateTime(2026, 10, 1);
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: 'h-bastion',
            label: 'bastion',
            host: sshHost,
            port: Value(jumpPort),
            identityId: Value(bastionIdentity),
            createdAt: at,
            updatedAt: at,
          ));
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: 'h-db',
            label: 'db-primary',
            host: sshHost,
            port: Value(targetPort),
            identityId: const Value('id-deploy'),
            connectViaId: const Value('h-bastion'),
            createdAt: at,
            updatedAt: at,
          ));
      return sessions().openExecClient((await tree.connectionsDao.getById('h-db'))!);
    }

    final made = await polled();
    expect(made.outcome, MonitorExecOutcome.ok, reason: '${made.failedWith}');
    await made.service!.disconnect();

    // A key the jump host does not know: not something to try again by a timer. What it failed with is kept as
    // the jump host's, and what the host's status says of it names the jump host.
    final refused = await polled(bastionIdentity: 'id-stranger');
    expect(refused.outcome, MonitorExecOutcome.signInRefused, reason: '${refused.failedWith}');
    expect(refused.failedWith, isA<JumpHostFailure>().having((f) => f.stage, 'stage', JumpStage.signIn));
    expect(failedCheckSaid(refused.failedWith!, host: 'db-primary', port: targetPort),
        startsWith('Signing in to the jump host bastion did not work. '));

    // A jump host whose key is not on this device: nobody is here to ask, so its person is.
    final nobody = await polled(bastionIdentity: 'id-no-key');
    expect(nobody.outcome, MonitorExecOutcome.needsCredentials, reason: '${nobody.failedWith}');
  });

  test('the jump host shows a key that its person does not accept: the session is gone, with no failure to show',
      () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $targetPort');
      return;
    }
    // The jump host's key is not known on this device, and its person is asked.
    await (tree.delete(tree.knownHosts)..where((k) => k.port.equals(jumpPort))).go();
    container.read(askBeforeTrustingKeysProvider.notifier).state = true;
    final asked = <HostKeyVerification>[];
    container.listen(hostKeyVerificationQueueProvider, (_, queue) {
      for (final question in queue) {
        if (question.completer.isCompleted) continue;
        asked.add(question);
        Future<void>.microtask(
            () => container.read(hostKeyVerificationQueueProvider.notifier).resolve(question, false));
      }
    });
    final id = await started(bastionPort: jumpPort);
    await until(() => stateOf(id) == null || stateOf(id)?.status == SessionStatus.error, 'the session to go');
    expect(asked, hasLength(1));
    expect((asked.single.port, asked.single.isChanged), (jumpPort, false));
    expect(stateOf(id), isNull, reason: 'they said no themselves: ${stateOf(id)?.errorMessage}');
    expect(container.read(connectionErrorProvider), isNull);
  });

  test('the sign-in details of the jump host cannot be used: said of the jump host', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $targetPort');
      return;
    }
    // An identity whose key is not on this device.
    final id = await started(bastionPort: jumpPort, bastionIdentity: 'id-no-key');
    final said = await failureOf(id);
    expect(said.type, ConnectionErrorType.saidByApp);
    // (It was English in every language: "SSH key not found for identity ...".)
    expect(
      said.description,
      'The sign-in details of the jump host bastion could not be used. The private key of "no-key identity" is not '
      'on this device: it was removed, or its import did not finish. Open the key and import its private key again.',
    );
    await sessions().endSession(id);
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
