import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A session whose shell ends by itself, with a server played by the test
/// under the app's own session (3.0, from the SSH core's audit): what no
/// real server does when a test wants it. A shell that has ended by the
/// time the host's yes to it is read, and a host that says nothing of how
/// its sessions end (there is network gear that never does): its person
/// typing `exit` there was a connection that dropped, and was connected
/// to again.
///
/// With a real OpenSSH server: session_ended_by_host_real_host_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
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
  });

  tearDown(() async {
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

  /// A session of the app's to a played server, saved as web-01: let in,
  /// given a channel and a terminal, and asking for its shell.
  Future<({String id, PlayedServer server, PlayedChannel channel})> asked() async {
    final server = PlayedServer();
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: 'web-01.example.com',
          port: const Value(22),
          colorIndex: const Value(3),
          colorValue: const Value(0xFF7A1A),
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
        );
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await server.letIn();
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    return (id: id, server: server, channel: channel);
  }

  test('a shell that prints a notice and leaves, all in one read with the host\'s yes to it: the session stays, as '
      'ended by its host, with its exit status and the notice', () async {
    final s = await asked();
    s.server.send([
      s.channel.success,
      s.channel.data('Hi deploy! You have successfully authenticated,\r\nbut this host gives no shell access.\r\n'),
      s.channel.exitStatus(1),
      s.channel.eof,
      s.channel.close,
    ]);
    await until(() => stateOf(s.id)?.status == SessionStatus.disconnected, 'the end of the session');
    final ended = stateOf(s.id)!;
    expect(ended.dropped, isTrue);
    expect(
      sessionEnded(ended.dropCause),
      (
        exitCode: 1,
        signal: null,
        said: 'Hi deploy! You have successfully authenticated,\nbut this host gives no shell access.',
      ),
    );
    expect(ended.isReconnecting, isFalse);
    // It is the same tab still: its colours stay.
    expect(ended.colorIndex, 3);
    expect(ended.colorValue, 0xFF7A1A);
    expect(ended.isHidden, isFalse);
    expect(ended.connectionLabel, 'web-01');
    expect(ended.host, 'web-01.example.com');
    expect(ended.port, 22);
    await sessions().endSession(s.id);
  });

  test('a host that says nothing of how its sessions end closes one in order, and nobody had typed: it stays, as '
      'ended by the host, with what the host said last', () async {
    final s = await asked();
    s.server.send([s.channel.success, s.channel.data('switch-01> ')]);
    await until(() => stateOf(s.id)?.status == SessionStatus.connected, 'connected');
    s.server.send([s.channel.data('\r\nIdle too long, closing.\r\n'), s.channel.eof, s.channel.close]);
    await until(() => stateOf(s.id)?.status == SessionStatus.disconnected, 'the end of the session');
    final ended = stateOf(s.id)!;
    expect(sessionEnded(ended.dropCause), (exitCode: null, signal: null, said: 'switch-01>\nIdle too long, closing.'));
    expect(ended.isReconnecting, isFalse, reason: 'no connection dropped');
    await sessions().endSession(s.id);
  });

  test('a hidden session its host ends stays hidden', () async {
    final s = await asked();
    s.server.send([s.channel.success, s.channel.data('switch-01> ')]);
    await until(() => stateOf(s.id)?.status == SessionStatus.connected, 'connected');
    sessions().hideSession(s.id);
    expect(stateOf(s.id)?.isHidden, isTrue);
    s.server.send([s.channel.exitStatus(0), s.channel.eof, s.channel.close]);
    await until(() => stateOf(s.id)?.status == SessionStatus.disconnected, 'the end of the session');
    expect(stateOf(s.id)?.isHidden, isTrue);
    expect(sessionEnded(stateOf(s.id)?.dropCause)?.exitCode, 0);
    await sessions().endSession(s.id);
  });

  test('on such a host its person types `exit`, and the host closes the session: gone with its tab, and not '
      'connected to again', () async {
    final s = await asked();
    s.server.send([s.channel.success, s.channel.data('switch-01> ')]);
    await until(() => stateOf(s.id)?.status == SessionStatus.connected, 'connected');
    stateOf(s.id)!.session!.terminal.textInput('exit\r');
    final typed = SSH_Message_Channel_Data.decode(await s.server.next(SSH_Message_Channel_Data.messageId));
    expect(String.fromCharCodes(typed.data), 'exit\r');
    s.server.send([s.channel.data('exit\r\n'), s.channel.eof, s.channel.close]);
    await until(() => stateOf(s.id) == null, 'the session to be gone');
  });

  test('the connection ends under the session: a connection that dropped, which is connected to again', () async {
    final s = await asked();
    s.server.send([s.channel.success, s.channel.data('deploy@web-01:~\$ ')]);
    await until(() => stateOf(s.id)?.status == SessionStatus.connected, 'connected');
    s.server.hangUp();
    await until(() => stateOf(s.id)?.status != SessionStatus.connected, 'the drop');
    await until(() => stateOf(s.id)?.isReconnecting == true || stateOf(s.id)?.status == SessionStatus.connecting,
        'connecting again');
    expect(sessionEnded(stateOf(s.id)?.dropCause), isNull);
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

/// No networks are set up here: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
