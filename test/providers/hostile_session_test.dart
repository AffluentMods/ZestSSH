import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Column, Table;
import 'package:flutter/widgets.dart' as widgets show Column;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/tmux/tmux_start_question.dart';

/// The app's own session, as it starts one, against a "host" on this machine
/// that says what a hostile or a compromised host says (a TCP server reached
/// with the Telnet shell, so everything from the socket to the terminal is the
/// real thing; the SSH path joins it at the same place). From a review of
/// hostile servers.
class _Host {
  _Host(this._server) {
    _server.listen((s) {
      sockets.add(s);
      s.listen(received.addAll, onError: (Object _) {});
    });
  }

  static Future<_Host> start() async => _Host(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final sockets = <Socket>[];
  final received = <int>[];

  int get port => _server.port;

  /// What the host was typed, as text (Telnet's own bytes are not text).
  String get text => latin1.decode(received);

  void say(String text) => sockets.last.add(utf8.encode(text));

  Future<void> stop() async {
    for (final s in sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

String _shown(Terminal terminal) {
  final b = StringBuffer();
  for (var y = 0; y < terminal.buffer.lines.length; y++) {
    final line = terminal.buffer.lines[y].getText().trimRight();
    if (line.isNotEmpty) b.writeln(line);
  }
  return b.toString().trim();
}

Future<void> _until(bool Function() ok, {required String what}) async {
  for (var i = 0; i < 600; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('It never came to this: $what');
}

/// Long enough for what would have happened to have happened.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 120));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late _Host host;
  late AppDatabase tree;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    host = await _Host.start();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
  });

  tearDown(() async {
    container.dispose();
    await host.stop();
    await tree.close();
  });

  Future<String> connect({String envVars = '', String? startup}) async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-1',
          label: 'Host',
          host: '127.0.0.1',
          port: Value(host.port),
          protocol: const Value('telnet'),
          envVars: Value(envVars),
          startupCommand: Value(startup),
          createdAt: at,
          updatedAt: at,
        ));
    final connection = (await tree.connectionsDao.getById('h-1'))!;
    final id = container.read(activeSessionsProvider.notifier).startSession(connection)!;
    await _until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.connected, what: 'connected');
    await _until(() => host.sockets.isNotEmpty, what: 'the host\'s side of it');
    return id;
  }

  Terminal terminalOf(String id) => container.read(activeSessionsProvider)[id]!.session!.terminal;
  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);

  // Every released version up to 3.2.7: the screen stood still for good from
  // here on, keys still reached the host, and what it printed piled up.
  group('one code at the first column', () {
    for (final code in ['\x1b[1K', '\x1b[0X', '\x1b[1J']) {
      test('${jsonEncode(code)}: the screen goes on', () async {
        final id = await connect();
        final terminal = terminalOf(id);
        host.say('before\r\n');
        await _until(() => _shown(terminal).contains('before'), what: 'what it said before');
        host.say('\r$code');
        await _settle();
        host.say('after\r\n');
        await _until(() => _shown(terminal).contains('after'), what: 'what it said after the code');
      });
    }

    test('what is thrown while drawing costs that drawing, and the next one comes', () async {
      final id = await connect();
      final terminal = terminalOf(id);
      // What the terminal itself no longer lets out: the timer that draws has
      // to stand by itself as well.
      terminal.onPrivateOSC = (_, _) => throw StateError('thrown while drawing');
      terminal.onWriteError = (error, _) => throw error;
      host.say('\x1b]52;c;QUJD\x07');
      await _settle();
      host.say('after\r\n');
      await _until(() => _shown(terminal).contains('after'), what: 'what it said after the throw');
    });
  });

  group('tmux control mode from output alone', () {
    test('a marker nobody asked for: nothing is typed, and the session asks', () async {
      final id = await connect();
      host.say('text of a file\r\n\x1bP1000p%session-changed \$1 work\n%window-add @1\n');
      await _until(() => container.read(tmuxStartQuestionProvider(id)), what: 'the question');
      await _settle();
      expect(host.text, isNot(contains('display-message')), reason: 'it typed tmux commands into the shell by itself');
      expect(host.text, isNot(contains('list-windows')));
      expect(container.read(tmuxHostProvider(id)).active, isFalse, reason: 'no workspace the file can draw');
      expect(_shown(terminalOf(id)), contains('text of a file'));

      // No: it is what was printed, shown as that, and the keys are keys.
      sessions().answerTmuxStart(id, false);
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
      await _until(() => _shown(terminalOf(id)).contains('%session-changed'), what: 'the rest of the file');
      terminalOf(id).textInput('hunter2\r');
      await _until(() => host.text.contains('hunter2'), what: 'the keys');
      expect(host.text, isNot(contains('send-keys')));
      expect(container.read(tmuxHostProvider(id)).active, isFalse);
    });

    test('yes: it starts, with what waited', () async {
      final id = await connect();
      host.say('\x1bP1000p%begin 1 1 0\r\n%end 1 1 0\r\n');
      await _until(() => container.read(tmuxStartQuestionProvider(id)), what: 'the question');
      expect(host.text, isNot(contains('display-message')));
      sessions().answerTmuxStart(id, true);
      await _until(() => container.read(tmuxHostProvider(id)).active, what: 'tmux mode');
      await _until(() => host.text.contains('display-message'), what: 'its first command');
    });

    test('going on typing is a no', () async {
      final id = await connect();
      host.say('\x1bP1000pthe rest');
      await _until(() => container.read(tmuxStartQuestionProvider(id)), what: 'the question');
      terminalOf(id).textInput('ls\r');
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
      await _until(() => _shown(terminalOf(id)).contains('the rest'), what: 'what waited');
      expect(container.read(tmuxHostProvider(id)).active, isFalse);
    });

    test('a person typing tmux -CC by hand is asked nothing', () async {
      final id = await connect();
      terminalOf(id).textInput('tmux -CC\r');
      await _until(() => host.text.contains('tmux -CC'), what: 'what was typed');
      host.say('tmux -CC\r\n\x1bP1000p%begin 1 1 0\r\n%end 1 1 0\r\n');
      await _until(() => container.read(tmuxHostProvider(id)).active, what: 'tmux mode');
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
    });

    test('a key at a time, as a person types it', () async {
      final id = await connect();
      for (final key in 'tmux -CC attach\r'.split('')) {
        terminalOf(id).textInput(key);
      }
      await _until(() => host.text.contains('attach'), what: 'what was typed');
      host.say('\x1bP1000p');
      await _until(() => container.read(tmuxHostProvider(id)).active, what: 'tmux mode');
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
    });

    test('a host whose start-up command is tmux -CC is asked nothing', () async {
      final id = await connect(startup: 'tmux -CC new -A -s main');
      await _until(() => host.text.contains('tmux -CC new'), what: 'the start-up command');
      host.say('\x1bP1000p');
      await _until(() => container.read(tmuxHostProvider(id)).active, what: 'tmux mode');
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
    });

    test('a snippet that runs it, sent for the person, is asked nothing', () async {
      final id = await connect();
      sessions().sendInput(id, utf8.encode('tmux -CC attach\r'));
      await _until(() => host.text.contains('tmux -CC attach'), what: 'the snippet');
      host.say('\x1bP1000p');
      await _until(() => container.read(tmuxHostProvider(id)).active, what: 'tmux mode');
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
    });

    test('keys sent one by one, as a window of its own sends them, are asked nothing', () async {
      final id = await connect();
      for (final key in 'tmux -CC\r'.split('')) {
        sessions().sendInput(id, utf8.encode(key));
      }
      await _until(() => host.text.contains('tmux -CC'), what: 'the keys');
      host.say('\x1bP1000p');
      await _until(() => container.read(tmuxHostProvider(id)).active, what: 'tmux mode');
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
    });

    test('the session ends while it asks: nothing stands', () async {
      final id = await connect();
      host.say('\x1bP1000p');
      await _until(() => container.read(tmuxStartQuestionProvider(id)), what: 'the question');
      await sessions().endSession(id);
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
    });

    test('the connection ends while it asks: what waited is shown, and nothing stands', () async {
      final id = await connect();
      final terminal = terminalOf(id);
      host.say('\x1bP1000pthe last of it');
      await _until(() => container.read(tmuxStartQuestionProvider(id)), what: 'the question');
      host.sockets.last.destroy();
      await _until(() => !container.read(tmuxStartQuestionProvider(id)), what: 'the question gone');
      await _until(() => _shown(terminal).contains('the last of it'), what: 'what waited');
    });

    test('the app closes while it asks (the container goes in tearDown): nothing throws', () async {
      final id = await connect();
      host.say('\x1bP1000p');
      await _until(() => container.read(tmuxStartQuestionProvider(id)), what: 'the question');
    });

    test('where Settings has it off, a marker is output, and nothing asks', () async {
      container.read(tmuxAutoDetectProvider.notifier).state = false;
      final id = await connect();
      host.say('a\x1bP1000pb');
      await _until(() => _shown(terminalOf(id)).contains('ab'), what: 'the output');
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
      expect(container.read(tmuxHostProvider(id)).active, isFalse);
      expect(host.text, isNot(contains('display-message')));
    });

    testWidgets('the question stands above the session, says what would happen, and each answer does what it says',
        (tester) async {
      final en = lookupAppLocalizations(const Locale('en'));
      late String id;
      await tester.runAsync(() async {
        id = await connect();
        host.say('\x1bP1000p');
        await _until(() => container.read(tmuxStartQuestionProvider(id)), what: 'the question');
      });
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: widgets.Column(children: [TmuxStartQuestion(sessionId: id)])),
        ),
      ));
      await tester.pump();
      expect(find.text(en.tmuxStartQuestion), findsOneWidget);
      expect(en.tmuxStartQuestion, allOf(contains('tmux'), contains('your keys')));
      expect(tester.widget<FilledButton>(find.ancestor(of: find.text(en.tmuxStartQuestionNo), matching: find.byType(FilledButton))), isNotNull,
          reason: 'no is the plain one');
      await tester.tap(find.byKey(ValueKey('tmux-start-question-no-$id')));
      await tester.pump();
      expect(find.text(en.tmuxStartQuestion), findsNothing);
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
      expect(container.read(tmuxHostProvider(id)).active, isFalse);

      // The next line entered, and a marker again: this time yes.
      await tester.runAsync(() async {
        terminalOf(id).textInput('cat other\r');
        host.say('\x1bP1000p');
        await _until(() => container.read(tmuxStartQuestionProvider(id)), what: 'the question again');
      });
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('tmux-start-question-yes-$id')));
      await tester.pump();
      expect(container.read(tmuxStartQuestionProvider(id)), isFalse);
      expect(container.read(tmuxHostProvider(id)).active, isTrue);
      await tester.pumpWidget(const SizedBox());
      // (The timers that session set while the test's clock stood.)
      await tester.pump(const Duration(seconds: 3));
    });

    test('both places that show a session have it', () {
      String text(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');
      expect(text('lib/ui/screens/desktop/widgets/desktop_terminal_area.dart'),
          contains('for (final e in activeSessions) TmuxStartQuestion(sessionId: e.key),'));
      expect(text('lib/ui/screens/terminal/terminal_screen.dart'), contains('TmuxStartQuestion(sessionId: widget.sessionId),'));
    });
  });

  group('values from a host\'s settings', () {
    test('one with a control character is not typed, is said by name, and the rest are set', () async {
      final id = await connect(envVars: jsonEncode({'GOOD': "it's fine", 'BAD': 'x\x15touch RAN\r', 'TAB': 'a\tb'}));
      await _until(() => host.text.contains('export GOOD'), what: 'the good one');
      expect(host.text, contains(r"export GOOD='it'\''s fine'; clear"));
      expect(host.text, isNot(contains('BAD')));
      expect(host.text, isNot(contains('touch RAN')));
      expect(host.text, isNot(contains('\x15')));
      expect(host.text, isNot(contains('TAB')));
      final told = container.read(notificationCenterProvider).history;
      final notice = told.singleWhere((n) => n.title.contains('BAD'));
      expect(notice.title, contains('TAB'));
      expect(notice.details, contains('ZestSSH error details'), reason: 'it has Copy details');
      expect(container.read(activeSessionsProvider)[id]!.connectionLog.join('\n'), contains('env: not set'));
    });

    test('with only such values nothing is typed, not even clear', () async {
      await connect(envVars: jsonEncode({'BAD': 'x\x15touch RAN\r'}));
      await _settle();
      expect(host.text, isNot(contains('export')));
      expect(host.text, isNot(contains('clear')));
    });
  });

  group('the forwarded agent', () {
    late List<String> log;
    late Connection connection;

    setUp(() {
      log = [];
      final at = DateTime(2026, 10, 1);
      connection = Connection(
        id: 'h-9',
        label: 'Build box',
        host: 'build',
        port: 22,
        keepAliveSeconds: 0,
        colorIndex: 0,
        protocol: 'ssh',
        zlibCompression: false,
        envVars: '',
        forwardAgent: true,
        compatibilityMode: false,
        sortOrder: 0,
        sizeTier: 1,
        pinned: false,
        monitored: false,
        createdAt: at,
        updatedAt: at,
      );
    });

    tearDown(() => sessionClock = DateTime.now);

    int noticesFor(String host) =>
        container.read(notificationCenterProvider).history.where((n) => n.title.contains(host)).length;

    test('a signature is said, quietly, at most once a minute per host', () {
      var now = DateTime(2026, 10, 30, 12);
      sessionClock = () => now;
      final other = connection.copyWith(id: 'h-10', label: 'Other box');
      sessions().debugAgentSigned(connection, log.add);
      expect(noticesFor('Build box'), 1);
      expect(log, hasLength(1));
      // A `git pull` signs several times in a row.
      now = now.add(const Duration(seconds: 59));
      sessions().debugAgentSigned(connection, log.add);
      sessions().debugAgentSigned(connection, log.add);
      expect(noticesFor('Build box'), 1);
      expect(log, hasLength(1));
      // Another host has its own minute.
      sessions().debugAgentSigned(other, log.add);
      expect(noticesFor('Other box'), 1);
      // And past the minute it is said again.
      now = now.add(const Duration(seconds: 2));
      sessions().debugAgentSigned(connection, log.add);
      expect(log, hasLength(3));
    });
  });
}
