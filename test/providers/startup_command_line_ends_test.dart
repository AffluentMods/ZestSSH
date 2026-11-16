// What a host is sent when its session starts: its start-up command and its
// snippet on connect, typed and entered. The app's own session, started the
// way the app starts one, against a host on this machine (a TCP server
// reached with the Telnet shell, so no SSH server is needed).
//
// A command written or pasted on Windows ends its lines in a carriage return
// and a line feed. Typed as it stands, a shell takes each of the two for
// Enter (a bug in 2.2.1: a snippet of several lines was double
// spaced).

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

import '../features/sharing/share_fakes.dart' show until;

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

/// The host: a TCP server on this machine that keeps what it was sent.
class _Host {
  late final ServerSocket _server;
  final sockets = <Socket>[];
  final received = <int>[];

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      sockets.add(socket);
      socket.listen(received.addAll, onError: (Object _) {});
    });
  }

  int get port => _server.port;

  /// What the host was sent as typed text: from [first] on (Telnet's own
  /// bytes come before anything is typed, and are not text).
  String typedFrom(String first) {
    final text = latin1.decode(received);
    final at = text.indexOf(first);
    return at < 0 ? '' : text.substring(at);
  }

  Future<void> stop() async {
    for (final s in sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late ProviderContainer container;
  late AppDatabase db;
  late _Host host;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    host = _Host();
    await host.start();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(db);
  });

  tearDown(() async {
    container.dispose();
    await host.stop();
    await db.close();
  });

  Future<void> connect({String? startup, String? snippet, String? env}) async {
    final at = DateTime(2026, 10, 2);
    if (snippet != null) {
      // Put there as another device or an older version left it.
      await db.snippetsDao.insertSnippet(SnippetsCompanion(
        id: const Value('s1'),
        label: const Value('On connect'),
        command: Value(snippet),
        createdAt: Value(at),
        updatedAt: Value(at),
      ));
    }
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h1',
          label: 'Web 1',
          host: '127.0.0.1',
          port: Value(host.port),
          protocol: const Value('telnet'),
          startupCommand: Value(startup),
          envVars: env == null ? const Value.absent() : Value(env),
          snippetId: Value(snippet == null ? null : 's1'),
          createdAt: at,
          updatedAt: at,
        ));
    final connection = (await db.connectionsDao.getById('h1'))!;
    final id =
        container.read(activeSessionsProvider.notifier).startSession(connection)!;
    await until(
        () =>
            container.read(activeSessionsProvider)[id]?.status ==
            SessionStatus.connected,
        what: 'the session');
  }

  test('a start-up command of one line is typed and entered', () async {
    await connect(startup: 'cd /srv/app');
    await until(() => host.typedFrom('cd /srv').endsWith('\r'),
        what: 'the command');
    expect(host.typedFrom('cd /srv'), 'cd /srv/app\r');
  });

  test('a start-up command written on Windows gets one Enter per line',
      () async {
    await connect(startup: 'cd /srv/app\r\nexport STAGE=demo\r\nls -la');
    await until(() => host.typedFrom('cd /srv').contains('ls -la\r'),
        what: 'the command');
    expect(host.typedFrom('cd /srv'), 'cd /srv/app\rexport STAGE=demo\rls -la\r');
  });

  test('a snippet on connect written on Windows gets one Enter per line',
      () async {
    await connect(snippet: 'cd /srv/app\r\nls -la\r\n');
    await until(() => host.typedFrom('cd /srv').contains('ls -la\r'),
        what: 'the snippet');
    // Its own line end at the end is the Enter that runs it: not two.
    expect(host.typedFrom('cd /srv'), 'cd /srv/app\rls -la\r');
  });

  test('the start-up command comes first, then the snippet', () async {
    await connect(startup: 'cd /srv/app', snippet: 'git status\nls');
    await until(() => host.typedFrom('cd /srv').contains('ls\r'),
        what: 'both');
    expect(host.typedFrom('cd /srv'), 'cd /srv/app\rgit status\rls\r');
  });

  // Left to the shell, `${DIR:-/tmp/a}` gives that one place its default and
  // assigns nothing, and the `${DIR}` beside it is empty: `rm -rf /*`.
  test('a snippet on connect: a default stands at every place of its variable', () async {
    await connect(snippet: r'mkdir -p ${DIR:-/tmp/a}; rm -rf ${DIR}/*');
    await until(() => host.typedFrom('mkdir').endsWith('\r'), what: 'the snippet');
    expect(host.typedFrom('mkdir'), "mkdir -p '/tmp/a'; rm -rf '/tmp/a'/*\r");
  });

  test('a snippet on connect that is dangerous with its default empty is not typed', () async {
    await connect(startup: 'cd /srv/app', snippet: r'rm -rf ${DIR:-}/*');
    await until(() => host.typedFrom('cd /srv').endsWith('\r'), what: 'the command before it');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.typedFrom('rm -rf'), isEmpty);
  });

  test("a host's environment variables are exported and entered once",
      () async {
    await connect(env: '{"STAGE":"demo","NOTE":"it\'s here"}');
    await until(() => host.typedFrom('export').contains('clear'),
        what: 'the exports');
    await until(() => host.typedFrom('export').endsWith('\r'),
        what: 'their Enter');
    expect(host.typedFrom('export'),
        "export STAGE='demo'; export NOTE='it'\\''s here'; clear\r");
  });

  test('a value of two lines is not typed: a line end is a key as well, and the rest are set',
      () async {
    await connect(env: r'{"MOTD":"one\r\ntwo","STAGE":"demo"}');
    await until(() => host.typedFrom('export').endsWith('clear\r'),
        what: 'the exports');
    // Inside the quotes of a POSIX shell Enter is a line end. In any other
    // shell it ends the line, and the next is a command that no list of what
    // an imported host does shows.
    expect(host.typedFrom('export'), "export STAGE='demo'; clear\r");
  });
}
