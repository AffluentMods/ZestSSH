// A key from a keyboard, on the terminal screen of a phone or a tablet (and
// of a computer's pop-out window, which is the same screen).
//
// In 2.2.1 (Android, a tablet among the devices), vim's cursor
// movement did not work at all, and an arrow up for history did not work
// right: the last command did not show.
//
// The screen had a handler of its own for the keys that are no text (the
// arrows, Home, End, Page Up and Down, Insert, Delete, F1 to F12), beside
// the terminal that has the focus and takes the same keys: each press was
// sent twice. One arrow up went two commands back, past the last one; in an
// editor every arrow moved two places. The handler looked at no focus but a
// text field's, so it also sent to its session while another screen was in
// front, and with two sessions side by side to both.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

/// Sessions that keep what was sent to each as typed, by whatever way.
class _Sessions extends FakeSessions {
  _Sessions(super.ref);

  final sent = <String>[];

  @override
  bool sendInput(String sessionId, Uint8List bytes, {bool atStart = false}) {
    sent.add('$sessionId: ${shown(String.fromCharCodes(bytes))}');
    return true;
  }
}

String shown(String keys) => keys.replaceAll('\x1b', 'ESC ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The sessions [ids], each on a terminal screen of its own, side by side
  /// where there are two; and everything that is sent to a session as typed:
  /// by a screen itself, and by a terminal (which a session sends on the
  /// same way).
  Future<_Sessions> pumpScreens(WidgetTester tester, List<String> ids) async {
    tester.view.physicalSize = const Size(1800, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cursor_blink': false});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(container.dispose);
    final sessions = container.read(activeSessionsProvider.notifier) as _Sessions;
    sessions.show({for (final id in ids) id: connectedSession(id, 'Web $id')});
    for (final id in ids) {
      sessions.state[id]!.session!.terminal.onOutput = (keys) => sessions.sent.add('$id: ${shown(keys)}');
    }

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Row(children: [for (final id in ids) Expanded(child: TerminalScreen(sessionId: id))]),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TerminalView), findsNWidgets(ids.length));
    return sessions;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  /// One press of [key]: what was sent for it.
  Future<List<String>> press(WidgetTester tester, _Sessions sessions, LogicalKeyboardKey key) async {
    sessions.sent.clear();
    await tester.sendKeyEvent(key);
    await tester.pump();
    return [...sessions.sent];
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.windows]) {
    testWidgets('a key that is pressed once is sent once ($platform)', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      final sessions = await pumpScreens(tester, ['s1']);

      expect(await press(tester, sessions, LogicalKeyboardKey.arrowUp), ['s1: ESC [A'],
          reason: 'one arrow up went two commands back');
      for (final (key, code) in [
        (LogicalKeyboardKey.arrowDown, 'ESC [B'),
        (LogicalKeyboardKey.arrowRight, 'ESC [C'),
        (LogicalKeyboardKey.arrowLeft, 'ESC [D'),
        (LogicalKeyboardKey.home, 'ESC [H'),
        (LogicalKeyboardKey.end, 'ESC [F'),
        (LogicalKeyboardKey.pageUp, 'ESC [5~'),
        (LogicalKeyboardKey.pageDown, 'ESC [6~'),
        (LogicalKeyboardKey.insert, 'ESC [2~'),
        (LogicalKeyboardKey.delete, 'ESC [3~'),
        (LogicalKeyboardKey.f1, 'ESC OP'),
        (LogicalKeyboardKey.f5, 'ESC [15~'),
        (LogicalKeyboardKey.f12, 'ESC [24~'),
      ]) {
        expect(await press(tester, sessions, key), ['s1: $code'], reason: key.keyLabel);
      }
      await finish(tester);
    });
  }

  testWidgets('it is sent in the form the program at the other end asked for, and with what is held down with it',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final sessions = await pumpScreens(tester, ['s1']);
    final terminal = sessions.state['s1']!.session!.terminal;

    // As an editor or a pager asks for it.
    terminal.write('\x1b[?1h');
    expect(await press(tester, sessions, LogicalKeyboardKey.arrowUp), ['s1: ESC OA']);
    expect(await press(tester, sessions, LogicalKeyboardKey.home), ['s1: ESC OH']);
    terminal.write('\x1b[?1l');
    expect(await press(tester, sessions, LogicalKeyboardKey.arrowUp), ['s1: ESC [A']);

    // Ctrl with an arrow is a key of its own (a word to the left, in a shell).
    sessions.sent.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(sessions.sent, ['s1: ESC [1;5D']);
    await finish(tester);
  });

  testWidgets('a key that is pressed while another screen is in front is not sent to the session behind it',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final sessions = await pumpScreens(tester, ['s1']);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Center(child: Text('a list of files'))),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('a list of files'), findsOneWidget);

    for (final key in [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.delete, LogicalKeyboardKey.f9]) {
      expect(await press(tester, sessions, key), isEmpty, reason: '${key.keyLabel} went to the session behind');
    }

    // And back at the terminal it is sent again.
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(await press(tester, sessions, LogicalKeyboardKey.arrowUp), ['s1: ESC [A']);
    await finish(tester);
  });

  testWidgets('with two sessions side by side a key goes to the one that is typed into, and to no other',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final sessions = await pumpScreens(tester, ['s1', 's2']);

    await tester.tap(find.byType(TerminalView).first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(await press(tester, sessions, LogicalKeyboardKey.arrowUp), ['s1: ESC [A']);
    expect(await press(tester, sessions, LogicalKeyboardKey.f9), ['s1: ESC [20~']);

    await tester.tap(find.byType(TerminalView).last);
    await tester.pump(const Duration(milliseconds: 500));
    expect(await press(tester, sessions, LogicalKeyboardKey.arrowUp), ['s2: ESC [A']);
    await finish(tester);
  });
}
