import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TypedText;
import 'package:zest_ssh_core/dartssh2.dart';
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

/// A session whose shell ends by itself, with a real SSH session under it
/// (3.0, from the SSH core's audit). Such a session was closed with its tab
/// at once, whoever had ended it: an account that prints a notice and
/// leaves was never read, and a session its host ended was just gone. Now
/// the tab is closed where its person's hand ended the shell (something
/// was typed into it in the ten seconds before), and any other end stays in
/// its place, as ended by the host, with how it ended and what the host
/// said last, and nothing connects again by itself.
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (tool/test_sshd.sh
/// starts it and makes the keys); `client_forced_ed25519` is the key that
/// runs one command whatever is asked for: it prints a word and ends at
/// once, with the status 7. Skips itself when the server is not running.
/// Override the location with ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final sshPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  late bool up;
  SSHKeyPair? forced;
  SSHKeyPair? free;
  late AppDatabase tree;
  late ProviderContainer container;

  setUpAll(() async {
    try {
      final s = await Socket.connect(sshHost, sshPort, timeout: const Duration(seconds: 2));
      s.destroy();
      final forcedFile = File('$dir/client_forced_ed25519');
      final freeFile = File('$dir/client_ed25519');
      up = forcedFile.existsSync() && freeFile.existsSync();
      if (up) {
        forced = SSHKeyPair.fromPem(forcedFile.readAsStringSync()).single;
        free = SSHKeyPair.fromPem(freeFile.readAsStringSync()).single;
      }
    } catch (_) {
      up = false;
    }
  });

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
    // Connecting again by itself is on, as it is unless turned off: a
    // session its host ended is not connected again all the same.
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

  /// The test server, saved as web-01, and a session to it with [key].
  Future<String> started(SSHKeyPair key) async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: sshHost,
          port: Value(sshPort),
          createdAt: at,
          updatedAt: at,
        ));
    sessions().debugShellFor = (connection) => SshService(
          host: sshHost,
          port: sshPort,
          username: user,
          keyPairs: [key],
          onHostKeyVerify: (_, _, _) async => true,
        );
    return sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
  }

  /// A session with a shell that runs, and has said its first words.
  Future<String> connected() async {
    final id = await started(free!);
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected');
    return id;
  }

  Uint8List entered(String command) => Uint8List.fromList(utf8.encode('$command\n'));

  test('a host that prints a word and ends the session at once: the session stays, as ended by the host, with its '
      'exit status and what the host printed, and nothing connects again', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await started(forced!);
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the end of the session');
    final ended = stateOf(id)!;
    expect(ended.dropped, isTrue);
    expect(sessionEnded(ended.dropCause), (exitCode: 7, signal: null, said: 'forced'));
    expect(ended.connectionLabel, 'web-01');
    expect(ended.connectionLog.last, 'ended: The host ended the session (exit status 7): forced');
    // Behind what the log held of the connection, which stays.
    expect(ended.connectionLog.where((line) => line.startsWith('ready: Session established')), hasLength(1));
    expect(ended.connectionLog.length, greaterThan(3));
    // Nothing connects again by itself: what ended it would end it again.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(stateOf(id)?.status, SessionStatus.disconnected);
    expect(stateOf(id)?.isReconnecting, isFalse);
    expect(stateOf(id)?.reconnectAttempt, 0);
    await sessions().endSession(id);
  });

  test('a shell its person ends: typed `exit`, and the session is gone with its tab, as before', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await connected();
    // Typed into its terminal, as a keyboard types.
    stateOf(id)!.session!.terminal.textInput('exit 3\r');
    await until(() => stateOf(id) == null, 'the session to be gone');
  });

  test('ended by what was sent into it for its person (a snippet they ran): gone as well', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await connected();
    expect(sessions().sendInput(id, entered('exit')), isTrue);
    await until(() => stateOf(id) == null, 'the session to be gone');
    expect(sessions().sendInput(id, entered('exit')), isFalse, reason: 'no session, nothing sent');
  });

  test('ended long after its person typed last (a limit on idle time, someone there): it stays, with how it ended',
      () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await connected();
    var now = DateTime(2026, 10, 10, 12);
    sessionClock = () => now;
    // Typed, and what was typed ends the shell a moment later...
    stateOf(id)!.session!.terminal.textInput('sleep 1; exit 4\r');
    // ...by which time more than ten seconds have gone by on the clock.
    now = now.add(const Duration(seconds: 11));
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the end of the session');
    final ended = stateOf(id)!;
    expect(ended.dropped, isTrue);
    final how = sessionEnded(ended.dropCause);
    expect(how?.exitCode, 4);
    expect(how?.said, contains('sleep 1; exit 4'));
    await sessions().endSession(id);
  });

  test('within ten seconds of what was typed: gone', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await connected();
    var now = DateTime(2026, 10, 10, 12);
    sessionClock = () => now;
    stateOf(id)!.session!.terminal.textInput('sleep 1; exit 4\r');
    now = now.add(const Duration(seconds: 10));
    await until(() => stateOf(id) == null, 'the session to be gone');
  });

  test('what the app types as a session starts is not its person\'s hand: a shell it ends stays', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await connected();
    expect(sessions().sendInput(id, entered('exit 5'), atStart: true), isTrue);
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the end of the session');
    expect(sessionEnded(stateOf(id)!.dropCause)?.exitCode, 5);
    await sessions().endSession(id);
  });

  test('ended by a signal: it stays, and says which', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await connected();
    sessions().sendInput(id, entered(r'kill -KILL $$'), atStart: true);
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the end of the session');
    final how = sessionEnded(stateOf(id)!.dropCause);
    expect(how?.signal, 'KILL');
    expect(how?.exitCode, isNull);
    await sessions().endSession(id);
  });

  test('when a session was last typed into: what its person typed or had sent, not what the terminal answers by '
      'itself or the app types as it starts; forgotten with the session', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await connected();
    var now = DateTime(2026, 10, 10, 12);
    sessionClock = () => now;
    final terminal = stateOf(id)!.session!.terminal;
    expect(sessions().debugLastInput(id), isNull, reason: 'nothing was typed yet');
    // What its host asks the terminal (what kind of terminal are you?) is answered by itself: no typing.
    terminal.write('${String.fromCharCode(0x1b)}[c');
    expect(sessions().debugLastInput(id), isNull);
    // Typed.
    terminal.textInput('l');
    expect(sessions().debugLastInput(id), now);
    final typedAt = now;
    // Typed by the app as a session starts: not its person's hand.
    now = now.add(const Duration(seconds: 1));
    sessions().sendInput(id, entered('true'), atStart: true);
    expect(sessions().debugLastInput(id), typedAt);
    // Sent for its person.
    sessions().sendInput(id, entered('true'));
    expect(sessions().debugLastInput(id), now);
    // Typed into a tmux pane of the session.
    now = now.add(const Duration(seconds: 1));
    sessions().typedInTmuxPane(id, 'x', const TypedText('x'));
    expect(sessions().debugLastInput(id), now);
    await sessions().endSession(id);
    expect(sessions().debugLastInput(id), isNull);
  });

  test('a session disconnected from here and kept forgets when it was typed into', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await connected();
    stateOf(id)!.session!.terminal.textInput('l');
    expect(sessions().debugLastInput(id), isNotNull);
    await sessions().disconnectSession(id);
    expect(sessions().debugLastInput(id), isNull);
    expect(stateOf(id)?.status, SessionStatus.disconnected);
    expect(sessionEnded(stateOf(id)?.dropCause), isNull, reason: 'ended from here, not by its host');
    await sessions().endSession(id);
  });

  test('a session whose connection ends under it is a dropped one, as before, and is connected again', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await connected();
    // The server's process for this connection, ended as a host that goes down ends it.
    sessions().sendInput(id, entered(r'kill -KILL $PPID'), atStart: true);
    await until(() => stateOf(id)?.status != SessionStatus.connected, 'the drop');
    await until(() => stateOf(id)?.dropped == true || stateOf(id)?.status == SessionStatus.connected, 'the drop said');
    expect(sessionEnded(stateOf(id)?.dropCause), isNull);
    // It is connected again by itself.
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected again');
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
