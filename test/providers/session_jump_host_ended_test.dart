import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The messages a played server sends are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_disconnect.dart';
import 'package:zestssh/database/database.dart';
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
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/widgets/connection_lost_view.dart' show dropKind, dropSaid;
import 'package:zestssh/utils/error_translator.dart';

import '../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/played_jump_host.dart';

/// A session of the app's to a host behind a jump host, when it is the
/// connection to the jump host that ends: while the session is open, while
/// the host is being signed in to, and while the next jump host on the way
/// is (3.0; the SSH core's audit, the last of its small findings).
///
/// Each was said as what the host behind had done: "db-primary closed the
/// connection" of a session whose jump host had shown another key when it
/// asked for new keys, and the session was connected to again by itself;
/// "the server closed the connection before the sign-in was over" of a
/// sign-in whose jump host went away; "signing in to the jump host
/// inner-bastion did not work" where the one before it had. And a sign-in
/// that the host refused left the connection to the jump host open, signed
/// in and kept alive, with nothing to close it.
///
/// The app dials the jump host for itself, so it is played on the loopback
/// address; the host behind it is the first real test server of the SSH
/// core package (tool/test_sshd.sh). Skips itself when that is not running.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final hostPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  late bool up;
  String? keyPem;
  String? strangerPem;
  SSHHostKey? hostKey;
  late AppDatabase tree;
  late ProviderContainer container;

  setUpAll(() async {
    try {
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (!up) return;
      keyPem = file.readAsStringSync();
      strangerPem = (await KeyGenerationService().generateEd25519(comment: 'stranger')).privatePem;
      // The host's key, as a person approves it once.
      final client = SSHClient(
        await SSHSocket.connect(sshHost, hostPort, timeout: const Duration(seconds: 2)),
        username: user,
        identities: SSHKeyPair.fromPem(keyPem!),
        onVerifyHostKey: (type, bytes) {
          hostKey = SSHHostKey(type: type, bytes: Uint8List.fromList(bytes));
          return true;
        },
      );
      await client.authenticated.timeout(const Duration(seconds: 20));
      client.close();
    } catch (_) {
      up = false;
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      if (keyPem != null) 'identity_key_id-deploy': keyPem!,
      if (strangerPem != null) 'identity_key_id-stranger': strangerPem!,
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
    container.read(autoReconnectEnabledProvider.notifier).state = true;
    // A try of connecting again waits two seconds in the app.
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(milliseconds: 200);
    if (!up) return;
    final at = DateTime(2026, 10, 1);
    for (final (identity, label) in [('id-deploy', 'deploy key'), ('id-stranger', 'stranger key')]) {
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: identity,
            label: label,
            username: user,
            authMethod: 'publicKey',
            createdAt: at,
          ));
    }
    await KnownHostsService(tree.knownHostsDao).trustHost(sshHost, hostPort, hostKey!);
  });

  tearDown(() async {
    ActiveSessionsNotifier.debugReconnectDelay = null;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  Future<void> until(bool Function() check, String what, {Duration within = const Duration(seconds: 40)}) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > within) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The host db-primary saved behind the jump host bastion, which the test
  /// plays on the loopback address and whose key this device trusts; and a
  /// session to db-primary, up to where the app is signed in to bastion and
  /// asks it for the way on. With [inner], a second jump host is saved
  /// between the two, which bastion is asked for the way to.
  Future<({String id, PlayedJumpHost bastion, PlayedSocketLine line})> dialled({
    String hostIdentity = 'id-deploy',
    bool inner = false,
  }) async {
    final listener = await PlayedListener.bind();
    final shows = PlayedHostKey.ed25519();
    await KnownHostsService(tree.knownHostsDao)
        .trustHost(listener.host, listener.port, SSHHostKey(type: shows.algorithm, bytes: shows.blob));
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-bastion',
          label: 'bastion',
          host: listener.host,
          port: Value(listener.port),
          identityId: const Value('id-deploy'),
          createdAt: at,
          updatedAt: at,
        ));
    if (inner) {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: 'h-inner',
            label: 'inner-bastion',
            host: '192.168.20.11',
            port: const Value(22),
            identityId: const Value('id-deploy'),
            connectViaId: const Value('h-bastion'),
            createdAt: at,
            updatedAt: at,
          ));
    }
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-db',
          label: 'db-primary',
          host: sshHost,
          port: Value(hostPort),
          identityId: Value(hostIdentity),
          connectViaId: Value(inner ? 'h-inner' : 'h-bastion'),
          createdAt: at,
          updatedAt: at,
        ));
    final id = sessions().startSession((await tree.connectionsDao.getById('h-db'))!)!;
    final line = await listener.line();
    final bastion = PlayedJumpHost(line: line, hostKey: shows);
    addTearDown(bastion.stop);
    await bastion.letIn();
    return (id: id, bastion: bastion, line: line);
  }

  /// A session to db-primary through bastion, connected.
  Future<({String id, PlayedJumpHost bastion, PlayedSocketLine line})> connected() async {
    final s = await dialled();
    await s.bastion.carryTo(sshHost, hostPort);
    await until(() => stateOf(s.id)?.status == SessionStatus.connected || stateOf(s.id)?.status == SessionStatus.error,
        'the connection');
    expect(stateOf(s.id)?.status, SessionStatus.connected, reason: '${stateOf(s.id)?.errorMessage}');
    return s;
  }

  /// What the session says of how it failed, as its screen shows it.
  Future<ConnectionError> failureOf(String id) async {
    await until(() => stateOf(id)?.status == SessionStatus.error || stateOf(id)?.status == SessionStatus.connected,
        'the connection to be made or to fail');
    final s = stateOf(id)!;
    expect(s.status, SessionStatus.error, reason: 'it was to fail');
    return ConnectionError.translate(s.errorMessage!, host: s.host, port: s.port, username: s.username);
  }

  Iterable<String> endsOfJumpHosts(String id) =>
      stateOf(id)!.connectionLog.where((line) => line.startsWith('jump: The ') && line.contains('bastion'));

  test('an open session whose jump host shows another key when it asks for new keys: it ends, says that of the '
      'jump host, and is not connected to again by itself', () async {
    if (!up) return markTestSkipped('no test sshd at $sshHost:$hostPort');
    final s = await connected();
    // Whoever has got into the connection to the jump host asks for new keys, with a key of their own.
    s.bastion.quiet();
    await s.bastion.server.rekey(hostKey: PlayedHostKey.ed25519()).then((_) {}, onError: (Object _) {});
    await until(() => stateOf(s.id)?.status == SessionStatus.disconnected, 'the end of the session');
    await until(() => stateOf(s.id)?.dropCause != null, 'why it ended');
    final ended = stateOf(s.id)!;
    expect(ended.dropped, isTrue);
    expect(ended.dropCause, endedAtJumpHost('bastion', hostKeyFailedAtNewKeys));
    expect(dropSaid(en, ended, 'db-primary'), (
      sentence: 'The connection to db-primary goes through the jump host bastion, and it was the connection to that '
          'jump host that ended. ${en.connJumpHostKeyFailedAtNewKeys('bastion')}',
      tip: null,
      printed: null,
    ));
    expect(dropKind(ended.dropCause), 'jumpHost.hostKeyAtNewKeys', reason: 'what a report of it names');
    expect(endsOfJumpHosts(s.id), [
      'jump: The connection to the jump host bastion ended - '
          'ssh_hostkey: Host key REJECTED when new keys were taken - Host key changed during re-key',
    ]);
    expect(ended.connectionLog, contains('dropped: ${ended.dropCause}'));
    // Longer than a try of connecting again waits here.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(stateOf(s.id)?.status, SessionStatus.disconnected, reason: 'not connected to again by itself');
    expect(stateOf(s.id)?.isReconnecting, isFalse);
    await sessions().endSession(s.id);
  });

  test('an open session whose jump host ends its connection and says why: its words, as the jump host\'s, and '
      'connected to again by itself as before', () async {
    if (!up) return markTestSkipped('no test sshd at $sshHost:$hostPort');
    final s = await connected();
    s.bastion.server.send([
      SSH_Message_Disconnect(reasonCode: 2, description: 'idle for too long', languageTag: '').encode(),
    ]);
    s.bastion.server.hangUp();
    await until(() => stateOf(s.id)?.status != SessionStatus.connected, 'the drop');
    await until(() => stateOf(s.id)?.dropCause != null, 'why it dropped');
    final dropped = stateOf(s.id)!;
    expect(dropped.dropCause,
        endedAtJumpHost('bastion', endReasonOf(SSHDisconnectError(2, 'idle for too long', authentic: true))));
    expect(
        dropSaid(en, dropped, 'db-primary').sentence,
        'The connection to db-primary goes through the jump host bastion, and it was the connection to that jump '
        'host that ended. bastion ended the connection. Its reason: idle for too long');
    expect(dropKind(dropped.dropCause), 'jumpHost.endedByHost');
    expect(endsOfJumpHosts(s.id), hasLength(1));
    // Longer than a try of connecting again waits here: it was tried.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final later = stateOf(s.id)!;
    expect(later.isReconnecting || later.status == SessionStatus.connecting, isTrue,
        reason: 'it goes on connecting again by itself');
    expect(later.reconnectAttempt, greaterThanOrEqualTo(1));
    sessions().stopAutoReconnect(s.id);
    await sessions().endSession(s.id);
  });

  test('an open session whose own connection ends while the jump host\'s stays: the host\'s own end, and the '
      'connection to the jump host is closed with it', () async {
    if (!up) return markTestSkipped('no test sshd at $sshHost:$hostPort');
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    final s = await connected();
    // The host behind ends the connection (it went down, say); the jump host is as it was.
    s.bastion.closeWay();
    await until(() => stateOf(s.id)?.status != SessionStatus.connected, 'the drop');
    await until(() => stateOf(s.id)?.dropCause != null, 'why it dropped');
    final dropped = stateOf(s.id)!;
    expect(dropped.dropCause, hostClosedConnection);
    expect(dropSaid(en, dropped, 'db-primary').sentence, 'db-primary closed the connection.');
    expect(endsOfJumpHosts(s.id), isEmpty, reason: 'the jump host did nothing');
    // Nobody holds the connection of a session that dropped: what it came through stayed open, signed in and
    // kept alive, and each time the session was connected to again one more was made.
    await until(() => s.line.clientGone, 'the connection to the jump host to be closed',
        within: const Duration(seconds: 5));
    expect(endsOfJumpHosts(s.id), isEmpty, reason: 'closing it is no end of its own');
    await sessions().endSession(s.id);
  });

  test('a sign-in that the host behind the jump host refuses: the host\'s own failure, and the connection to the '
      'jump host is closed with it', () async {
    if (!up) return markTestSkipped('no test sshd at $sshHost:$hostPort');
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    // A key the host does not know.
    final s = await dialled(hostIdentity: 'id-stranger');
    await s.bastion.carryTo(sshHost, hostPort);
    final said = await failureOf(s.id);
    expect(said.description, isNot(contains('bastion')), reason: 'nothing went wrong at the jump host');
    expect(endsOfJumpHosts(s.id), isEmpty);
    // It stayed open, signed in and kept alive, with nothing left to close it.
    await until(() => s.line.clientGone, 'the connection to the jump host to be closed',
        within: const Duration(seconds: 5));
    await sessions().endSession(s.id);
  });

  test('the jump host ends its connection while the host behind it is being signed in to: said of the jump host',
      () async {
    if (!up) return markTestSkipped('no test sshd at $sshHost:$hostPort');
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    final s = await dialled();
    // Nothing comes back from the host: its sign-in waits.
    s.bastion.quiet();
    await s.bastion.carryTo(sshHost, hostPort);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    s.bastion.server.send([
      SSH_Message_Disconnect(reasonCode: 2, description: 'idle for too long', languageTag: '').encode(),
    ]);
    s.bastion.server.hangUp();
    final said = await failureOf(s.id);
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(
        said.description,
        'The connection to the jump host bastion ended while the host behind it was being connected to. '
        'bastion ended the connection. Its reason: idle for too long');
    expect(endsOfJumpHosts(s.id), hasLength(1));
    expect(endsOfJumpHosts(s.id).single, startsWith('jump: The connection to the jump host bastion ended - '));
    await sessions().endSession(s.id);
  });

  test('of two jump hosts, the first ends its connection while the second is being signed in to: said of the '
      'first, where the second was said to have failed', () async {
    if (!up) return markTestSkipped('no test sshd at $sshHost:$hostPort');
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    final s = await dialled(inner: true);
    // The way to the second jump host is opened, and nobody answers on it.
    await s.bastion.carryToAPlayedServer();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    s.bastion.server.send([
      SSH_Message_Disconnect(reasonCode: 2, description: 'going down for maintenance', languageTag: '').encode(),
    ]);
    s.bastion.server.hangUp();
    final said = await failureOf(s.id);
    expect(said.type, ConnectionErrorType.saidByApp);
    expect(
        said.description,
        'The connection to the jump host bastion ended while the host behind it was being connected to. '
        'bastion ended the connection. Its reason: going down for maintenance');
    expect(said.description, isNot(contains('inner-bastion')));
    final log = stateOf(s.id)!.connectionLog;
    expect(log.where((line) => line.startsWith('jump: The connection to the jump host bastion ended - ')),
        hasLength(1));
    await sessions().endSession(s.id);
  });

  test('an open session through two jump hosts, of which the one nearest the host ends its connection: that one '
      'is named', () async {
    if (!up) return markTestSkipped('no test sshd at $sshHost:$hostPort');
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    final s = await dialled(inner: true);
    // The second jump host, behind the first, whose key this device trusts as well.
    final shows = PlayedHostKey.ed25519();
    await KnownHostsService(tree.knownHostsDao)
        .trustHost('192.168.20.11', 22, SSHHostKey(type: shows.algorithm, bytes: shows.blob));
    final inner = PlayedJumpHost(line: await s.bastion.carryToAPlayedServer(), hostKey: shows);
    addTearDown(inner.stop);
    await inner.letIn();
    await inner.carryTo(sshHost, hostPort);
    await until(() => stateOf(s.id)?.status == SessionStatus.connected || stateOf(s.id)?.status == SessionStatus.error,
        'the connection');
    expect(stateOf(s.id)?.status, SessionStatus.connected, reason: '${stateOf(s.id)?.errorMessage}');
    inner.server.send([
      SSH_Message_Disconnect(reasonCode: 2, description: 'this bastion is being replaced', languageTag: '').encode(),
    ]);
    inner.server.hangUp();
    await until(() => stateOf(s.id)?.dropCause != null, 'why it dropped');
    final dropped = stateOf(s.id)!;
    expect(
        dropped.dropCause,
        endedAtJumpHost(
            'inner-bastion', endReasonOf(SSHDisconnectError(2, 'this bastion is being replaced', authentic: true))));
    expect(
        dropSaid(en, dropped, 'db-primary').sentence,
        'The connection to db-primary goes through the jump host inner-bastion, and it was the connection to that '
        'jump host that ended. inner-bastion ended the connection. Its reason: this bastion is being replaced');
    expect(dropped.connectionLog.where((line) => line.startsWith('jump: The ')), hasLength(1));
    expect(dropped.connectionLog.where((line) => line.startsWith('jump: The ')).single,
        startsWith('jump: The connection to the jump host inner-bastion ended - '));
    await sessions().endSession(s.id);
  });

  test('which failures of a jump host are what the end of an earlier one\'s connection brings about', () {
    JumpHostFailure at(JumpStage stage) => JumpHostFailure(
        label: 'inner-bastion', host: '192.168.20.11', port: 22, stage: stage, cause: SSHAuthAbortError('closed'));
    // Reaching it, signing in to it, and its way on all go over the jump hosts before it.
    expect(failedOverEarlierJumpHosts(at(JumpStage.reach)), isTrue);
    expect(failedOverEarlierJumpHosts(at(JumpStage.signIn)), isTrue);
    expect(failedOverEarlierJumpHosts(at(JumpStage.onward)), isTrue);
    // Its sign-in details are read on this device: nothing of that is another jump host's doing.
    expect(failedOverEarlierJumpHosts(at(JumpStage.details)), isFalse);
    // Nor is its person closing a question, or what the app refuses by itself.
    expect(failedOverEarlierJumpHosts(ConnectionCancelledException()), isFalse);
    expect(failedOverEarlierJumpHosts(SSHAuthAbortError('closed')), isFalse);
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
