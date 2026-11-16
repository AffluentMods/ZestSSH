import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The messages a played server reads are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/widgets/connection_lost_view.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A session whose host shows another key, or cannot sign with its own,
/// when it asks for new keys (3.0, from the SSH core's audit).
///
/// A host asks for new keys every so often on a session that is open, and
/// signs that exchange with its key as it signed the first. The SSH core
/// ends the connection where the key is another than the one the session
/// began with, or did not sign: a host keeps its key while a session is
/// open, so this is somebody who has got into the connection, or a server
/// that is broken. The app said of it that the connection had ended, with
/// no word of the key, and connected again by itself two seconds later: a
/// session that came back with the right key left nothing to see of what
/// had happened.
///
/// With the app's own session on a host played by the test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;
  // What the session's own service wrote into the connection's log.
  late List<String> log;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    log = [];
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
  });

  tearDown(() async {
    ActiveSessionsNotifier.debugReconnectDelay = null;
    sessionClock = DateTime.now;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 20)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  final hostPair = SSHKeyPair.fromPem(
          File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/ssh_host_ed25519_key').readAsStringSync())
      .single;

  /// A session of the app's in a shell on a played host, saved as web-01,
  /// whose key is the one of the key file.
  Future<({String id, PlayedServer server, PlayedChannel channel})> inAShell() async {
    final server = PlayedServer(hostKey: PlayedHostKey.of(hostPair, algorithm: 'ssh-ed25519'));
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: 'web-01.example.com',
          port: const Value(22),
          createdAt: at,
          updatedAt: at,
        ));
    sessions().debugShellFor = (connection) => SshService(
          host: connection.host,
          port: connection.port,
          username: 'deploy',
          password: 'not-a-real-one',
          keepAliveSeconds: 0,
          onHostKeyVerify: (_, _, _) async => true,
          tunnelSocket: server.socket,
          onLog: log.add,
        );
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await server.letIn();
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    server.send([channel.success, channel.data('deploy@web-01:~\$ ')]);
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected');
    return (id: id, server: server, channel: channel);
  }

  /// The session ended over the host's key at new keys: it says so, in the
  /// words for it, with what the SSH core found ([theCoreSays]) in the
  /// connection's log, and is not connected to again by itself.
  Future<void> endedOverTheKey(String id, String theCoreSays) async {
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the end of the session');
    await until(() => stateOf(id)?.dropCause != null, 'why it ended');
    final ended = stateOf(id)!;
    expect(ended.dropped, isTrue);
    expect(ended.dropCause, hostKeyFailedAtNewKeys);
    expect(dropSaid(en, ended, 'web-01'), (sentence: en.connHostKeyFailedAtNewKeys, tip: null, printed: null));
    expect(dropKind(ended.dropCause), 'hostKeyAtNewKeys', reason: 'what a report of it names');
    expect(ended.connectionLog.where((line) => line.contains(hostKeyFailedAtNewKeys)),
        ['dropped: $hostKeyFailedAtNewKeys'], reason: 'the connection log says why');
    expect(log.where((line) => line.contains('REJECTED')),
        ['ssh_hostkey: Host key REJECTED when new keys were taken - $theCoreSays'],
        reason: 'and what the SSH core found, in its own words');
    // Longer than a try of connecting again waits here.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(stateOf(id)?.status, SessionStatus.disconnected, reason: 'not connected to again by itself');
    expect(stateOf(id)?.isReconnecting, isFalse);
    await sessions().endSession(id);
  }

  test('a host that shows another key when it asks for new keys: the session ends, says that, and is not connected '
      'to again by itself', () async {
    final s = await inAShell();
    // Whoever has got into the connection asks for new keys, with a key of their own.
    await s.server.rekey(hostKey: PlayedHostKey.ed25519()).then((_) {}, onError: (_) {});
    await endedOverTheKey(s.id, 'Host key changed during re-key');
  });

  test('a host that shows its key and cannot sign with it when it asks for new keys: the same', () async {
    final s = await inAShell();
    await s.server
        .rekey(
          hostKey: PlayedHostKey(
            'ssh-ed25519',
            hostPair.toPublicKey().encode(),
            (hash) => hostPair.sign(Uint8List.fromList(hash.reversed.toList())).encode(),
          ),
        )
        .then((_) {}, onError: (_) {});
    await endedOverTheKey(s.id, 'Signature verification failed');
  });

  test('a host that asks for new keys with the key the session began with: the session goes on', () async {
    final s = await inAShell();
    await s.server.rekey();
    stateOf(s.id)!.session!.terminal.textInput('ls\r');
    final typed = SSH_Message_Channel_Data.decode(await s.server.next(SSH_Message_Channel_Data.messageId));
    expect(String.fromCharCodes(typed.data), 'ls\r');
    expect(stateOf(s.id)?.status, SessionStatus.connected);
    expect(log.where((line) => line.contains('REJECTED')), isEmpty);
    await sessions().endSession(s.id);
  });

  test('the connection ends under the session for another reason: connected to again by itself, as before',
      () async {
    final s = await inAShell();
    s.server.hangUp();
    await until(() => stateOf(s.id)?.status != SessionStatus.connected, 'the drop');
    // Why it dropped is known by now, and is nothing of the host's key.
    await until(() => stateOf(s.id)?.dropCause != null, 'why it dropped');
    expect(stateOf(s.id)?.dropCause, isNot(hostKeyFailedAtNewKeys));
    expect(dropSaid(en, stateOf(s.id)!, 'web-01').sentence, isNot(en.connHostKeyFailedAtNewKeys));
    expect(log.where((line) => line.contains('REJECTED')), isEmpty);
    // Longer than a try of connecting again waits here: it was tried.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final later = stateOf(s.id)!;
    expect(later.isReconnecting || later.status == SessionStatus.connecting, isTrue,
        reason: 'it goes on connecting again by itself');
    expect(later.reconnectAttempt, greaterThanOrEqualTo(1));
    sessions().stopAutoReconnect(s.id);
    await sessions().endSession(s.id);
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
