// Broadcast, with the app's own sessions: what a person types into one
// terminal of a tab that broadcasts is typed into the others, and nothing
// else is.
//
// Bugs in 2.2.1: with sixteen terminals typing together and a
// dialog open in each, using one of them affected the others; and one
// session moved out of the group was still broadcast to with the rest
// of them. Each terminal's answer to its own host's question (where the
// cursor is, what kind of terminal this is) was sent on to all the other
// hosts as if typed, a key went out the way the terminal typed into spells
// it whatever the others' programs had asked for, and who received was a
// list taken when broadcast was switched on.
//
// Every session here is the app's own, started the way the app does it,
// against a host on this machine (a TCP server reached with the Telnet
// shell, so no SSH server is needed): what a host is sent is read off its
// socket.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/providers/broadcast_provider.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart' show detachedSessionsProvider;
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart' show kMaskedValueShown;
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart' show SoftKeyModifier;

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

/// The mark [_Rig.flush] sends straight to a host to know that everything
/// sent before it has arrived.
const _mark = 0x1e;

const esc = '\x1b';

/// One host: what it was sent, and what it says.
class _Host {
  _Host(this.socket);

  final Socket socket;
  final received = <int>[];
  int marks = 0;
  int expected = 0;

  /// Whether it shows what is typed, as a shell at its prompt does.
  bool echo = false;

  void take(List<int> data) {
    final typed = <int>[];
    for (final b in data) {
      if (b == _mark) {
        marks++;
      } else {
        typed.add(b);
      }
    }
    received.addAll(typed);
    if (echo && typed.isNotEmpty) {
      socket.add([
        for (final b in typed)
          if (b == 0x0d) ...[0x0d, 0x0a] else b,
      ]);
    }
  }

  /// What was typed to it.
  String get got => utf8.decode(received, allowMalformed: true);

  void clear() => received.clear();

  /// What it prints to its terminal.
  void say(String text) => socket.add(utf8.encode(text));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late ProviderContainer container;
  late AppDatabase db;
  late ServerSocket server;
  late WorkTabsNotifier tabs;
  late BroadcastModeNotifier broadcast;
  final hosts = <_Host>[];
  final hostOf = <String, _Host>{};

  /// The questions asked before a risky command ran everywhere: the command
  /// and the hosts named. Each is answered with [reply].
  final asked = <(String, List<String>)>[];

  /// What each question quoted of its command, and how it was asked.
  final quoted = <List<String>>[];
  final askedAt = <DangerLevel>[];
  late Completer<bool?> reply;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      final host = _Host(socket);
      hosts.add(host);
      socket.listen(host.take, onError: (Object _) {});
    });
    db = AppDatabase.forTesting(NativeDatabase.memory());
    asked.clear();
    quoted.clear();
    askedAt.clear();
    reply = Completer<bool?>();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      broadcastConfirmProvider.overrideWithValue((command, matches, names, _) {
        expect(matches, isNotEmpty, reason: 'a question says why it is asked');
        asked.add((command, names));
        quoted.add([for (final m in matches) m.quotedIn(command)]);
        askedAt.add(worstDangerLevel(matches));
        return reply.future;
      }),
    ]);
    container.read(databaseSessionProvider.notifier).seed(db);
    // The tabs follow the sessions from the first one on.
    tabs = container.read(workTabsProvider.notifier);
    broadcast = container.read(broadcastModeProvider.notifier);
    final at = DateTime(2026, 10, 2);
    for (var i = 1; i <= 5; i++) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h$i',
            label: 'web-0$i',
            host: '127.0.0.1',
            port: Value(server.port),
            protocol: const Value('telnet'),
            createdAt: at,
            updatedAt: at,
          ));
    }
  });

  tearDown(() async {
    if (!reply.isCompleted) reply.complete(false);
    container.dispose();
    for (final h in hosts) {
      h.socket.destroy();
    }
    hosts.clear();
    hostOf.clear();
    await server.close();
    await db.close();
  });

  Map<String, SessionState> sessions() => container.read(activeSessionsProvider);
  ActiveSessionsNotifier notifier() => container.read(activeSessionsProvider.notifier);
  Terminal term(String id) => sessions()[id]!.session!.terminal;
  _Host at(String id) => hostOf[id]!;
  String got(String id) => at(id).got;

  /// The line the cursor of [t] is on.
  String lineOf(Terminal t) => t.buffer.lines[t.buffer.absoluteCursorY].toString().trimRight();

  /// A session to the host [host], connected.
  Future<String> open(String host) async {
    final connection = (await db.connectionsDao.getById(host))!;
    // (A session's id carries the time it was started at.)
    await Future<void>.delayed(const Duration(milliseconds: 3));
    final before = hosts.length;
    final id = notifier().startSession(connection)!;
    await until(
      () => sessions()[id]?.status == SessionStatus.connected && hosts.length > before,
      what: 'the session to $host',
    );
    hostOf[id] = hosts[before];
    return id;
  }

  /// Everything typed so far has reached its host.
  Future<void> flush() async {
    for (final e in hostOf.entries) {
      final s = sessions()[e.key];
      if (s == null || s.status != SessionStatus.connected) continue;
      s.session!.shell.write(Uint8List.fromList([_mark]));
      e.value.expected++;
    }
    await until(() => hostOf.values.every((h) => h.marks >= h.expected), what: 'the hosts to read');
  }

  /// Puts [ids] into one tab, each in a pane of its own.
  String joined(List<String> ids) {
    final first = tabs.tabContaining(ids.first)!.id;
    for (final id in ids.skip(1)) {
      tabs.mergeTabs(tabs.tabContaining(id)!.id, first);
    }
    tabs.setActiveTab(first);
    return first;
  }

  /// Three sessions in one tab, with nothing sent to their hosts yet.
  Future<(String, String, String, String)> three() async {
    final a = await open('h1');
    final b = await open('h2');
    final c = await open('h3');
    final tab = joined([a, b, c]);
    await flush();
    for (final h in hosts) {
      h.clear();
    }
    return (a, b, c, tab);
  }

  /// The same, and the tab broadcasts.
  Future<(String, String, String, String)> typingTogether() async {
    final all = await three();
    expect(broadcast.startTab(all.$4), isTrue);
    return all;
  }

  /// [host] prints [text], and its terminal has it.
  Future<void> shows(String id, String text, {required bool Function() when}) async {
    at(id).say(text);
    await until(when, what: 'the terminal to read what its host printed');
  }

  group('A tab that does not broadcast', () {
    test('nothing typed into one terminal reaches another', () async {
      final (a, b, c, _) = await three();
      term(a).textInput('uptime');
      term(a).keyInput(TerminalKey.enter);
      term(a).paste('echo pasted');
      term(a).charInput('c'.codeUnitAt(0), ctrl: true);
      await flush();
      expect(got(a), 'uptime\recho pasted\x03');
      expect(got(b), '');
      expect(got(c), '');
    });
  });

  group('A tab that broadcasts', () {
    test('what is typed into one terminal is typed into the others, once each', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).textInput('uptime');
      term(a).keyInput(TerminalKey.enter);
      await flush();
      for (final id in [a, b, c]) {
        expect(got(id), 'uptime\r', reason: 'the host of $id');
      }
    });

    test('whichever of them it is typed into', () async {
      final (a, b, c, _) = await typingTogether();
      term(b).textInput('one ');
      term(c).textInput('two ');
      term(a).textInput('three');
      await flush();
      for (final id in [a, b, c]) {
        expect(got(id), 'one two three', reason: 'the host of $id');
      }
    });

    test('a terminal of another tab gets nothing, and what is typed there stays there', () async {
      final (a, b, c, _) = await typingTogether();
      final d = await open('h4');
      await flush();
      at(d).clear();
      term(a).textInput('here');
      term(d).textInput('there');
      await flush();
      expect(got(d), 'there');
      for (final id in [a, b, c]) {
        expect(got(id), 'here', reason: 'the host of $id');
      }
    });

    test('a key goes out the way each terminal\'s own program asked', () async {
      final (a, b, c, _) = await typingTogether();
      // b shows a dialog that asked for the cursor keys in application mode;
      // a and c are at their prompt.
      await shows(b, '$esc[?1h', when: () => term(b).cursorKeysMode);
      term(a).keyInput(TerminalKey.arrowDown);
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(got(a), '$esc[B\r');
      expect(got(b), '${esc}OB\r', reason: 'the dialog would have read the other spelling as Escape');
      expect(got(c), '$esc[B\r');

      // Typed into the one with the dialog, it is right for the others too.
      for (final id in [a, b, c]) {
        at(id).clear();
      }
      term(b).keyInput(TerminalKey.arrowUp);
      await flush();
      expect(got(b), '${esc}OA');
      expect(got(a), '$esc[A');
      expect(got(c), '$esc[A');
    });

    test('a paste gets its brackets where the program asked for them, and only there', () async {
      final (a, b, c, _) = await typingTogether();
      await shows(b, '$esc[?2004h', when: () => term(b).bracketedPasteMode);
      term(a).paste('echo one\necho two');
      await flush();
      expect(got(a), 'echo one\recho two');
      expect(got(b), '$esc[200~echo one\recho two$esc[201~');
      expect(got(c), 'echo one\recho two');
    });

    test('a character with Ctrl is that character there', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).charInput('c'.codeUnitAt(0), ctrl: true);
      await flush();
      for (final id in [a, b, c]) {
        expect(got(id), '\x03', reason: 'the host of $id');
      }
    });

    test('letters of other scripts arrive as themselves', () async {
      final (a, b, _, _) = await typingTogether();
      term(a).textInput('echo ěščř 日本');
      await flush();
      expect(at(b).received, utf8.encode('echo ěščř 日本'));
      expect(at(a).received, utf8.encode('echo ěščř 日本'));
    });
  });

  group('What a terminal sends by itself', () {
    test('its answer goes to the host that asked, and to no other', () async {
      final (a, b, c, _) = await typingTogether();
      // The host of b asks where the cursor is and what kind of terminal
      // this is, as a dialog does when it opens.
      at(b).say('$esc[6n');
      await until(() => got(b).contains('R'), what: 'the answer');
      at(b).say('$esc[c');
      await until(() => got(b).endsWith('c'), what: 'the second answer');
      await flush();
      expect(got(b), matches(RegExp('^\x1b\\[\\d+;\\d+R\x1b\\[\\?[\\d;]+c\$')));
      expect(got(a), '', reason: 'it used to be typed into every other terminal');
      expect(got(c), '');
    });

    test('nor does a report of the mouse go anywhere else', () async {
      final (a, b, c, _) = await typingTogether();
      await shows(b, '$esc[?1000h', when: () => term(b).mouseMode != MouseMode.none);
      expect(
        term(b).mouseInput(TerminalMouseButton.left, TerminalMouseButtonState.down, const CellOffset(2, 1)),
        isTrue,
      );
      await flush();
      expect(got(b), isNotEmpty);
      expect(got(a), '');
      expect(got(c), '');
    });

    test('an answer is no part of the line that is typed', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).textInput('reb');
      at(b).say('$esc[6n');
      await until(() => got(b).contains('R'), what: 'the answer');
      term(a).textInput('oot');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      await flush();
      expect(asked.single.$1, 'reboot');
      expect(got(c), 'reboot');
      expect(got(a), 'reboot\r');
    });
  });

  group('Who receives', () {
    test('a session moved out of the tab gets nothing more, and sends nothing more', () async {
      final (a, b, c, _) = await typingTogether();
      tabs.splitSessionToNewTab(c);
      term(a).textInput('ls');
      term(c).textInput('pwd');
      await flush();
      expect(got(a), 'ls');
      expect(got(b), 'ls');
      expect(got(c), 'pwd', reason: 'it used to go on typing into the group it had left, and to be typed into');
    });

    test('a terminal that is left out gets nothing, and what is typed into it goes nowhere', () async {
      final (a, b, c, tab) = await typingTogether();
      broadcast.setReceiving(tab, c, false);
      term(a).textInput('ls');
      term(c).textInput('pwd');
      await flush();
      expect(got(a), 'ls');
      expect(got(b), 'ls');
      expect(got(c), 'pwd');
      broadcast.setReceiving(tab, c, true);
      term(b).textInput('!');
      await flush();
      expect(got(c), 'pwd!');
    });

    test('a tab that is down to one terminal stops, and one that joins later is not typed into', () async {
      final (a, b, c, tab) = await typingTogether();
      tabs.splitSessionToNewTab(c);
      tabs.splitSessionToNewTab(b);
      expect(container.read(broadcastModeProvider).any, isFalse);
      tabs.mergeTabs(tabs.tabContaining(b)!.id, tab);
      term(a).textInput('ls');
      await flush();
      expect(got(a), 'ls');
      expect(got(b), '');
      expect(got(c), '');
    });

    test('stopping stops it at once', () async {
      final (a, b, c, tab) = await typingTogether();
      term(a).textInput('one');
      broadcast.stopTab(tab);
      term(a).textInput('two');
      await flush();
      expect(got(a), 'onetwo');
      expect(got(b), 'one');
      expect(got(c), 'one');
    });

    test('a terminal that is not connected is passed over, and the others still get it', () async {
      final (a, b, c, _) = await typingTogether();
      // ignore: invalid_use_of_protected_member
      notifier().state = {...sessions(), b: sessions()[b]!.copyWith(status: SessionStatus.disconnected)};
      term(a).textInput('ls');
      await flush();
      expect(got(a), 'ls');
      expect(got(c), 'ls');
      expect(got(b), '');
    });

    test('nor is one that is hidden typed into', () async {
      final (a, b, c, _) = await typingTogether();
      notifier().hideSession(b);
      term(a).textInput('ls');
      await flush();
      expect(got(c), 'ls');
      expect(got(b), '');
    });

    test('a session shown in a window of its own gets nothing, and sends nothing', () async {
      final (a, b, c, _) = await typingTogether();
      container.read(detachedSessionsProvider.notifier).detach(c);
      term(a).textInput('ls');
      term(c).textInput('pwd');
      await flush();
      expect(got(a), 'ls');
      expect(got(b), 'ls');
      expect(got(c), 'pwd');
    });

    test('on a phone the sessions that were picked type together', () async {
      final (a, b, c, _) = await three();
      broadcast.enable({a, b});
      term(a).textInput('ls');
      term(c).textInput('pwd');
      await flush();
      expect(got(a), 'ls');
      expect(got(b), 'ls');
      expect(got(c), 'pwd');
      broadcast.disable();
      term(a).textInput('!');
      await flush();
      expect(got(b), 'ls');
    });
  });

  group('What the terminal typed into makes of a key', () {
    test('Ctrl held on a phone\'s key row turns the next letter into its control character, here and there, once', () async {
      final (a, b, c, _) = await typingTogether();
      container.read(mobileSoftKeyModifierProvider.notifier).state = SoftKeyModifier.ctrl;
      term(a).textInput('c');
      expect(container.read(mobileSoftKeyModifierProvider), SoftKeyModifier.none);
      term(a).textInput('c');
      await flush();
      for (final id in [a, b, c]) {
        expect(got(id), '\x03c', reason: 'the host of $id');
      }
    });

    test('a key row modifier set meanwhile is not used up by what a terminal receives', () async {
      final (a, b, _, _) = await typingTogether();
      // The answer to its own host must not use it up either.
      container.read(mobileSoftKeyModifierProvider.notifier).state = SoftKeyModifier.alt;
      at(b).say('$esc[5n');
      await until(() => got(b).contains('n'), what: 'the answer');
      expect(container.read(mobileSoftKeyModifierProvider), SoftKeyModifier.alt);
      term(a).textInput('f');
      await flush();
      expect(got(a), '${esc}f');
      expect(got(b), '$esc[0n${esc}f');
      expect(container.read(mobileSoftKeyModifierProvider), SoftKeyModifier.none);
    });

    test('a history suggestion on a terminal goes when a broadcast types there', () async {
      final (a, b, _, _) = await typingTogether();
      term(b).ghostText = 'atus';
      term(a).textInput('x');
      expect(term(b).ghostText, isNull);
    });

    test('Right arrow typed elsewhere is Right arrow there, also where a suggestion shows', () async {
      final (a, b, c, _) = await typingTogether();
      term(b).ghostText = 'atus';
      term(a).keyInput(TerminalKey.arrowRight);
      await flush();
      expect(got(b), '$esc[C', reason: 'a suggestion is taken where it was offered: typed there, not elsewhere');
      expect(got(c), '$esc[C');
    });
  });

  group('Command history', () {
    Future<List<CommandHistoryEntry>> rows() => db.select(db.commandHistory).get();

    Future<List<CommandHistoryEntry>> recorded(int count) async {
      for (var i = 0; i < 400; i++) {
        final r = await rows();
        if (r.length >= count) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // (Anything recorded late would be there by now.)
      await Future<void>.delayed(const Duration(milliseconds: 60));
      return rows();
    }

    setUp(() async {
      await container.read(commandHistoryEnabledProvider.notifier).set(true);
    });

    test('holds a broadcast command once, for the terminal it was typed into', () async {
      final (a, b, c, _) = await typingTogether();
      for (final h in hosts) {
        h.echo = true;
      }
      term(a).textInput('uptime');
      await until(() => [a, b, c].every((id) => lineOf(term(id)).contains('uptime')), what: 'the echo');
      term(a).keyInput(TerminalKey.enter);
      final r = await recorded(1);
      expect(r.map((e) => (e.command, e.connectionId)), [('uptime', 'h1')]);
    });

    test('what a broadcast typed is part of the line the person goes on typing there', () async {
      final (a, b, _, tab) = await typingTogether();
      for (final h in hosts) {
        h.echo = true;
      }
      term(a).textInput('apt upd');
      await until(() => lineOf(term(b)).contains('apt upd'), what: 'the echo');
      broadcast.stopTab(tab);
      term(b).textInput('ate');
      await until(() => lineOf(term(b)).contains('apt update'), what: 'the echo');
      term(b).keyInput(TerminalKey.enter);
      final r = await recorded(1);
      expect(r.map((e) => (e.command, e.connectionId)), [('apt update', 'h2')],
          reason: 'not "ate", the letters typed there last');
    });

    // The Inspector's Run again read this out in its question, in recording mode too.
    group('keeps nothing that holds a value typed with dots', () {
      Future<void> enter(String id, String line) async {
        term(id).keyInput(TerminalKey.enter);
        await until(() => hostOf[id]!.got.contains(line), what: 'the host to have it');
      }

      test('as it was typed, and the next command is kept as ever', () async {
        final (a, _, _, _) = await three();
        at(a).echo = true;
        container.read(autoExecuteSnippetsProvider.notifier).state = false;
        typePickedSnippet(container.read, term(a), "deploy --to /srv/'hunter2'", secrets: const ['hunter2']);
        await until(() => lineOf(term(a)).contains('hunter2'), what: 'the echo');
        await enter(a, 'hunter2');
        term(a).textInput('uptime');
        await until(() => lineOf(term(a)).contains('uptime'), what: 'the echo');
        term(a).keyInput(TerminalKey.enter);
        final r = await recorded(1);
        expect(r.map((e) => e.command), ['uptime']);
      });

      test('as it was written for its place: a quote in it does not stand as it was typed', () async {
        final (a, _, _, _) = await three();
        at(a).echo = true;
        container.read(autoExecuteSnippetsProvider.notifier).state = false;
        const line = r"login 'it'\''s'";
        typePickedSnippet(container.read, term(a), line, secrets: const ["it's"]);
        await until(() => lineOf(term(a)).contains('login'), what: 'the echo');
        term(a).keyInput(TerminalKey.enter);
        term(a).textInput('uptime');
        await until(() => lineOf(term(a)).contains('uptime'), what: 'the echo');
        term(a).keyInput(TerminalKey.enter);
        final r = await recorded(1);
        expect(r.map((e) => e.command), ['uptime']);
      });

      test('with the person opted in to keeping what looks like a secret', () async {
        final (a, _, _, _) = await three();
        at(a).echo = true;
        await container.read(commandHistoryIncludeSensitiveProvider.notifier).set(true);
        container.read(autoExecuteSnippetsProvider.notifier).state = false;
        typePickedSnippet(container.read, term(a), "deploy --to /srv/'hunter2'", secrets: const ['hunter2']);
        await until(() => lineOf(term(a)).contains('hunter2'), what: 'the echo');
        term(a).keyInput(TerminalKey.enter);
        term(a).textInput('mysql -psecret');
        await until(() => lineOf(term(a)).contains('mysql'), what: 'the echo');
        term(a).keyInput(TerminalKey.enter);
        final r = await recorded(1);
        expect(r.map((e) => e.command), ['mysql -psecret'], reason: 'what the person opted in to');
      });

      test('what it keeps to know them by goes with the session', () async {
        final (a, _, _, _) = await three();
        typePickedSnippet(container.read, term(a), 'x', secrets: const ['hunter2']);
        expect(notifier().filledSecretsKept(a), greaterThan(0));
        await notifier().endSession(a);
        expect(notifier().filledSecretsKept(a), 0);
      });
    });
  });

  // A dangerous snippet with `${TOKEN:secret}` in a tab that broadcasts: its first
  // question showed dots and the broadcast's showed the value, in recording mode too.
  group('A value typed with dots, in the question before a broadcast', () {
    void pressEnterAfterPasting(bool on) => container.read(autoExecuteSnippetsProvider.notifier).state = on;

    test('is dots, in the command and in what is said of it, and what runs is what it is', () async {
      final (a, b, c, _) = await typingTogether();
      pressEnterAfterPasting(true);
      typePickedSnippet(container.read, term(a), "reboot --token 'hunter22'", secrets: const ['hunter22']);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, "reboot --token '$kMaskedValueShown'");
      expect(quoted.single.join(), isNot(contains('hunter22')));
      reply.complete(true);
      await until(() => got(b).endsWith('\r') && got(c).endsWith('\r'), what: 'the Enter');
      expect(got(b), "reboot --token 'hunter22'\r");
    });

    test('what only the value makes risky is asked in red, and says nothing of it', () async {
      final (a, _, _, _) = await typingTogether();
      pressEnterAfterPasting(true);
      typePickedSnippet(container.read, term(a), "rm -rf '/etc/hunter22'", secrets: const ['/etc/hunter22']);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, "rm -rf '$kMaskedValueShown'");
      expect(askedAt.single, DangerLevel.harm);
      expect(quoted.single.single, "rm -rf '$kMaskedValueShown'");
    });

    test('as it was written for its place', () async {
      final (a, _, _, _) = await typingTogether();
      pressEnterAfterPasting(true);
      typePickedSnippet(container.read, term(a), r"reboot --token 'it'\''s'", secrets: const ["it's"]);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, "reboot --token '$kMaskedValueShown'");
    });

    test('typed now, entered later, from another of the terminals', () async {
      final (a, b, _, _) = await typingTogether();
      pressEnterAfterPasting(false);
      typePickedSnippet(container.read, term(a), "reboot --token 'hunter22'", secrets: const ['hunter22']);
      await flush();
      expect(asked, isEmpty, reason: 'nothing is entered yet');
      expect(got(b), "reboot --token 'hunter22'");
      term(b).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, "reboot --token '$kMaskedValueShown'");
    });

    test('typed before the broadcast began, and entered from another of the terminals', () async {
      final (a, b, _, tab) = await three();
      pressEnterAfterPasting(false);
      typePickedSnippet(container.read, term(a), "reboot --token 'hunter22'", secrets: const ['hunter22']);
      await flush();
      expect(got(b), isEmpty);
      expect(broadcast.startTab(tab), isTrue);
      term(b).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, "reboot --token '$kMaskedValueShown'");
    });

    test('where the terminal it was typed into has gone, and only the others hold the line', () async {
      final (a, b, _, _) = await typingTogether();
      pressEnterAfterPasting(false);
      typePickedSnippet(container.read, term(a), "reboot --token 'hunter22'", secrets: const ['hunter22']);
      await flush();
      await notifier().endSession(a);
      term(b).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, "reboot --token '$kMaskedValueShown'");
    });

    test('where one value holds another, all of the longer one', () async {
      final (a, _, _, _) = await typingTogether();
      pressEnterAfterPasting(true);
      typePickedSnippet(container.read, term(a), 'reboot hunter22 hunter22-and-more', secrets: const ['hunter22', 'hunter22-and-more']);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, 'reboot $kMaskedValueShown $kMaskedValueShown');
    });

    test('read off the screen, where an arrow brought the line back', () async {
      final (a, b, _, _) = await typingTogether();
      pressEnterAfterPasting(false);
      typePickedSnippet(container.read, term(a), "login 'hunter22'", secrets: const ['hunter22']);
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(asked, isEmpty);
      term(a).keyInput(TerminalKey.arrowUp);
      await shows(b, "\$ reboot --token 'hunter22'", when: () => lineOf(term(b)).contains('hunter22'));
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, "\$ reboot --token '$kMaskedValueShown'");
    });

    test('with nothing masked, the line as it stands', () async {
      final (a, _, _, _) = await typingTogether();
      pressEnterAfterPasting(true);
      typePickedSnippet(container.read, term(a), 'reboot');
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, 'reboot');
    });

    test('only in the sessions it was typed into', () async {
      final a = await open('h1');
      final d = await open('h4');
      final e = await open('h5');
      expect(broadcast.startTab(joined([d, e])), isTrue);
      pressEnterAfterPasting(false);
      typePickedSnippet(container.read, term(a), 'x hunter22', secrets: const ['hunter22']);
      term(d).textInput('reboot hunter22');
      term(d).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, 'reboot hunter22');
    });
  });

  group('A risky command', () {
    test('is held at Enter until the person says yes, and then runs everywhere', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).textInput('shutdown -h now');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      await flush();
      expect(asked.single.$1, 'shutdown -h now');
      expect(asked.single.$2, ['web-02', 'web-03'], reason: 'the others by name, not the one typed into');
      expect(got(a), 'shutdown -h now\r', reason: 'what is typed here runs here');
      expect(got(b), 'shutdown -h now', reason: 'typed, not entered');
      expect(got(c), 'shutdown -h now');
      reply.complete(true);
      await until(() => got(b).endsWith('\r') && got(c).endsWith('\r'), what: 'the Enter');
      await flush();
      expect(got(b), 'shutdown -h now\r');
      expect(got(c), 'shutdown -h now\r');
      expect(got(a), 'shutdown -h now\r', reason: 'not a second time');
    });

    test('is cleared from the others when the person says no', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      reply.complete(false);
      await until(() => got(b).endsWith('\x15') && got(c).endsWith('\x15'), what: 'the line to be cleared');
      await flush();
      expect(got(b), 'reboot\x15');
      expect(got(c), 'reboot\x15');
      expect(got(a), 'reboot\r');
      // The next Enter runs nothing there: their line is empty, and known
      // to be.
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(got(b), 'reboot\x15\r');
      expect(asked, hasLength(1));
    });

    test('is cleared from the others when there is no window to ask in', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      reply.complete(null);
      await until(() => got(b).endsWith('\x15') && got(c).endsWith('\x15'), what: 'the line to be cleared');
      await flush();
      expect(got(b), 'reboot\x15', reason: 'it used to be left standing, and the next Enter ran it');
      expect(got(c), 'reboot\x15');
    });

    test('runs unasked with the check switched off', () async {
      final (a, b, c, _) = await typingTogether();
      container.read(dangerousCommandProtectionProvider.notifier).state = false;
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(asked, isEmpty);
      for (final id in [a, b, c]) {
        expect(got(id), 'reboot\r');
      }
    });

    // The Broadcast pop-over's "Ask before risky commands" switch
    // sets the check through the settings, as Settings does: on by
    // default, a declined line reaches nobody else; off, it runs unasked.
    test('a line with its dangerous part in quotes is asked about too', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).textInput("rm -rf '/'");
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, "rm -rf '/'");
      reply.complete(false);
      await until(() => got(b).endsWith('\x15') && got(c).endsWith('\x15'), what: 'the line to be cleared');
      await flush();
      expect(got(b), isNot(contains('\r')), reason: 'not run on the others');
    });

    test('goes by the switch the Broadcast pop-over sets: asked by default, declined it reaches nobody else',
        () async {
      final (a, b, c, _) = await typingTogether();
      expect(container.read(dangerousCommandProtectionProvider), isTrue, reason: 'on for a new install');
      term(a).textInput('rm -rf /');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, 'rm -rf /');
      reply.complete(false);
      await until(() => got(b).endsWith('\x15') && got(c).endsWith('\x15'), what: 'the line to be cleared');
      await flush();
      expect(got(b), isNot(contains('\r')), reason: 'not run on the others');
      expect(got(c), isNot(contains('\r')));

      await container.read(settingsUpdaterProvider).setDangerousCommandProtection(false);
      asked.clear();
      for (final h in hosts) {
        h.clear();
      }
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(asked, isEmpty, reason: 'switched off in the pop-over');
      expect(got(b), 'reboot\r');
      expect(got(c), 'reboot\r');
    });

    test('a harmless one is not asked about', () async {
      final (a, b, _, _) = await typingTogether();
      term(a).textInput('uptime');
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(asked, isEmpty);
      expect(got(b), 'uptime\r');
    });

    test('is asked about for each of the others that is connected, and only those', () async {
      final (a, b, c, _) = await typingTogether();
      // ignore: invalid_use_of_protected_member
      notifier().state = {...sessions(), b: sessions()[b]!.copyWith(status: SessionStatus.disconnected)};
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      await flush();
      expect(asked.single.$2, ['web-03']);
      expect(got(c), 'reboot');
    });

    test('nor is one that is hidden named, or its line looked at', () async {
      final (a, b, c, tab) = await three();
      term(c).textInput('reboot');
      notifier().hideSession(c);
      broadcast.startTab(tab);
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(asked, isEmpty, reason: 'nothing is typed there, so nothing runs there');
      expect(got(b), '\r');
      expect(got(c), 'reboot');
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$2, ['web-02']);
    });

    test('with nobody connected to receive it there is nothing to ask', () async {
      final (a, b, _, tab) = await typingTogether();
      final c = sessions().keys.firstWhere((id) => id != a && id != b);
      // ignore: invalid_use_of_protected_member
      notifier().state = {
        ...sessions(),
        b: sessions()[b]!.copyWith(status: SessionStatus.disconnected),
        c: sessions()[c]!.copyWith(status: SessionStatus.disconnected),
      };
      expect(container.read(broadcastModeProvider).broadcasts(tab), isTrue);
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(asked, isEmpty);
      expect(got(a), 'reboot\r');
    });

    test('in a later line of a paste, with nobody connected to receive it, is nothing to ask about', () async {
      final (a, b, c, _) = await typingTogether();
      // ignore: invalid_use_of_protected_member
      notifier().state = {
        ...sessions(),
        b: sessions()[b]!.copyWith(status: SessionStatus.disconnected),
        c: sessions()[c]!.copyWith(status: SessionStatus.disconnected),
      };
      term(a).paste('echo one\nreboot\n');
      await flush();
      expect(asked, isEmpty, reason: 'it runs nowhere but here');
      expect(got(a), 'echo one\rreboot\r');
    });

    test('typed half into one pane and half into another is one line where it runs', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).textInput('shut');
      term(b).textInput('down -h now');
      term(b).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      await flush();
      expect(asked.single.$1, 'shutdown -h now', reason: 'it used to run everywhere unasked');
      expect(asked.single.$2, ['web-01', 'web-03']);
      expect(got(c), 'shutdown -h now');
      expect(got(a), 'shutdown -h now');
      expect(got(b), 'shutdown -h now\r');
    });

    test('begun in a terminal before it took part, it is still the line Enter runs there', () async {
      final (a, b, c, tab) = await three();
      term(b).textInput('reboot');
      broadcast.startTab(tab);
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      await flush();
      expect(asked.single.$1, 'reboot');
      expect(got(b), 'reboot', reason: 'the Enter is held');
      expect(got(c), '');
    });

    test('typed while nobody received, it is no part of the line the others have', () async {
      final (a, b, _, tab) = await three();
      // Typed into a alone; then the tab broadcasts and Enter is pressed: the
      // others have an empty line, and get the Enter.
      term(a).textInput('reboot');
      broadcast.startTab(tab);
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(asked, isEmpty);
      expect(got(a), 'reboot\r');
      expect(got(b), '\r');
    });

    test('is recognised after an arrow key, which leaves none of its letters in the line', () async {
      final (a, b, _, _) = await typingTogether();
      term(a).keyInput(TerminalKey.arrowUp);
      term(a).keyInput(TerminalKey.arrowDown);
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, 'reboot');
      await flush();
      expect(got(b), '$esc[A$esc[Breboot');
    });

    test('recalled from a host\'s own history, it is read off that terminal\'s screen', () async {
      final (a, b, c, _) = await typingTogether();
      // Arrow up: every host shows the last command of its OWN history. On
      // b that is a reboot.
      term(a).keyInput(TerminalKey.arrowUp);
      await shows(b, r'admin@web-02:~$ sudo reboot', when: () => lineOf(term(b)).contains('sudo reboot'));
      await shows(c, r'admin@web-03:~$ uptime', when: () => lineOf(term(c)).contains('uptime'));
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      await flush();
      expect(asked.single.$1, r'admin@web-02:~$ sudo reboot');
      expect(asked.single.$2, ['web-02', 'web-03']);
      expect(got(b), '$esc[A', reason: 'the Enter is held');
      expect(got(c), '$esc[A');
    });

    test('completed with Tab, it is read off the screen as well', () async {
      final (a, b, _, _) = await typingTogether();
      term(a).textInput('shutd');
      term(a).keyInput(TerminalKey.tab);
      await shows(b, r'$ shutdown ', when: () => lineOf(term(b)).contains('shutdown'));
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, r'$ shutdown');
      await flush();
      expect(got(b), 'shutd\t');
    });

    test('a screen that shows nothing risky is not asked about', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).keyInput(TerminalKey.arrowUp);
      await shows(b, r'admin@web-02:~$ uptime', when: () => lineOf(term(b)).contains('uptime'));
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(asked, isEmpty);
      expect(got(b), '$esc[A\r');
      expect(got(c), '$esc[A\r');
    });

    test('the screen is not read while the line is what was typed', () async {
      final (a, b, _, _) = await typingTogether();
      // The word stands on the screen of b, in what a program printed; the
      // line typed is harmless and was typed whole.
      await shows(b, 'next reboot at 02:00 ', when: () => lineOf(term(b)).contains('reboot'));
      term(a).textInput('uptime');
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(asked, isEmpty);
      expect(got(b), 'uptime\r');
    });

    test('nor is the screen of a program that fills it', () async {
      final (a, b, _, _) = await typingTogether();
      await shows(b, '$esc[?1049h', when: () => term(b).isUsingAltBuffer);
      await shows(b, 'reboot = no', when: () => lineOf(term(b)).contains('reboot'));
      term(a).keyInput(TerminalKey.arrowUp);
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(asked, isEmpty, reason: 'an editor with the word in a file is no command line');
      expect(got(b), '$esc[A\r');
    });

    test('in a later line of a paste holds the whole paste', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).paste('echo one\nreboot\necho three\n');
      await until(() => asked.isNotEmpty, what: 'the question');
      await flush();
      expect(asked.single.$1, 'reboot');
      expect(got(a), 'echo one\rreboot\recho three\r');
      expect(got(b), '', reason: 'none of it is typed there before the person says yes');
      expect(got(c), '');
      reply.complete(true);
      await until(() => got(b).isNotEmpty && got(c).isNotEmpty, what: 'the paste');
      await flush();
      expect(got(b), 'echo one\rreboot\recho three\r');
      expect(got(c), 'echo one\rreboot\recho three\r');
    });

    test('in a paste with its brackets is found as well', () async {
      final (a, b, _, _) = await typingTogether();
      await shows(a, '$esc[?2004h', when: () => term(a).bracketedPasteMode);
      term(a).paste('reboot\n');
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, 'reboot');
      await flush();
      expect(got(b), '');
      reply.complete(true);
      await until(() => got(b).isNotEmpty, what: 'the paste');
      expect(got(b), 'reboot\r', reason: 'b did not ask for brackets');
    });

    test('while the question is open, what is typed here goes to nobody else', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      term(a).textInput('ls');
      await flush();
      expect(got(a), 'reboot\rls');
      expect(got(b), 'reboot');
      reply.complete(true);
      await until(() => got(b).endsWith('\r'), what: 'the Enter');
      await flush();
      expect(got(b), 'reboot\r');
      expect(got(c), 'reboot\r');
      expect(asked, hasLength(1));
      // And once it is answered, typing goes to all again.
      term(a).textInput('x');
      await flush();
      expect(got(b), 'reboot\rx');
    });

    test('a terminal that left the tab while the question was open does not get the Enter', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      tabs.splitSessionToNewTab(c);
      reply.complete(true);
      await until(() => got(b).endsWith('\r'), what: 'the Enter');
      await flush();
      expect(got(b), 'reboot\r');
      expect(got(c), 'reboot', reason: 'it is no longer one of them');
    });

    test('nor is a line cleared in one that left', () async {
      final (a, b, c, _) = await typingTogether();
      term(a).textInput('reboot');
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      tabs.splitSessionToNewTab(c);
      reply.complete(false);
      await until(() => got(b).endsWith('\x15'), what: 'the line to be cleared');
      await flush();
      expect(got(c), 'reboot');
    });
  });

  group('A terminal that shows tmux', () {
    late List<String> sent;
    late TmuxController tmux;

    /// The session [id] shows tmux, with one pane (or none yet).
    void showsTmux(String id, {bool withPane = true}) {
      sent = [];
      tmux = TmuxController(sendBytes: (bytes) => sent.add(utf8.decode(bytes)), expectMarker: false);
      if (withPane) {
        tmux.onData(utf8.encode('%window-add @1\n'));
        tmux.onData(utf8.encode('%layout-change @1 bc62,80x24,0,0,0 bc62,80x24,0,0,0 *\n'));
        expect(tmux.activeWindow?.activeTerminal, isNotNull);
      }
      final keep = container.listen(tmuxHostProvider(id), (_, _) {});
      addTearDown(keep.close);
      container.read(tmuxHostProvider(id)).attachInband(tmux, forceExit: () {});
      addTearDown(tmux.dispose);
      expect(container.read(tmuxHostProvider(id)).live, isTrue);
    }

    /// What was typed into the pane in front, as tmux was told.
    String typedIntoPane() {
      final out = <int>[];
      for (final line in sent.expand((s) => s.split('\n'))) {
        const head = 'send-keys -t %0 -H ';
        if (!line.startsWith(head)) continue;
        out.addAll(line.substring(head.length).trim().split(' ').map((h) => int.parse(h, radix: 16)));
      }
      return utf8.decode(out);
    }

    test('gets a broadcast in its pane in front, not in the shell behind it', () async {
      final (a, b, c, _) = await typingTogether();
      showsTmux(b);
      term(a).textInput('ls');
      term(a).keyInput(TerminalKey.enter);
      await flush();
      expect(typedIntoPane(), 'ls\r');
      expect(got(b), '', reason: 'it used to be typed into the shell behind the tmux view, where nobody saw it run');
      expect(got(c), 'ls\r');
    });

    test('the pane sends a key the way its own program asked', () async {
      final (a, b, _, _) = await typingTogether();
      showsTmux(b);
      tmux.activeWindow!.activeTerminal!.write('$esc[?1h');
      term(a).keyInput(TerminalKey.arrowUp);
      await flush();
      expect(typedIntoPane(), '${esc}OA');
      expect(got(a), '$esc[A');
    });

    test('what is typed into its pane goes to the others, and what it receives goes no further', () async {
      final (a, b, c, _) = await typingTogether();
      showsTmux(b);
      tmux.activeWindow!.activeTerminal!.textInput('pwd');
      await flush();
      expect(typedIntoPane(), 'pwd');
      expect(got(a), 'pwd');
      expect(got(c), 'pwd');
      term(c).textInput('!');
      await flush();
      expect(typedIntoPane(), 'pwd!');
      expect(got(a), 'pwd!', reason: 'once, from c: the pane did not send it on');
      expect(got(c), 'pwd!');
    });

    test('while tmux has no pane yet, nothing is typed into it or into the shell behind it', () async {
      final (a, b, c, _) = await typingTogether();
      showsTmux(b, withPane: false);
      term(a).textInput('ls');
      await flush();
      expect(sent.where((s) => s.contains('send-keys')), isEmpty);
      expect(got(b), '');
      expect(got(c), 'ls');
    });

    test('a risky line typed into its pane is asked about like any other', () async {
      final (a, b, c, _) = await typingTogether();
      showsTmux(b);
      term(a).textInput('shut');
      final pane = tmux.activeWindow!.activeTerminal!;
      pane.textInput('down -h now');
      pane.keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      await flush();
      expect(asked.single.$1, 'shutdown -h now');
      expect(asked.single.$2, ['web-01', 'web-03']);
      expect(got(a), 'shutdown -h now');
      expect(got(c), 'shutdown -h now');
      expect(typedIntoPane(), 'shutdown -h now\r');
    });

    test('a line begun in its pane before the tab broadcast is the line Enter runs there', () async {
      final (a, b, _, tab) = await three();
      showsTmux(b);
      tmux.activeWindow!.activeTerminal!.textInput('reboot');
      broadcast.startTab(tab);
      term(a).keyInput(TerminalKey.enter);
      await until(() => asked.isNotEmpty, what: 'the question');
      expect(asked.single.$1, 'reboot');
      expect(typedIntoPane(), 'reboot', reason: 'the Enter is held');
    });

    test('once tmux is over, its own terminal is typed into again', () async {
      final (a, b, _, _) = await typingTogether();
      showsTmux(b);
      container.read(tmuxHostProvider(b)).inbandEnded();
      expect(container.read(tmuxHostProvider(b)).live, isFalse);
      term(a).textInput('ls');
      await flush();
      expect(got(b), 'ls');
      expect(sent.where((s) => s.contains('send-keys')), isEmpty);
    });
  });
}
