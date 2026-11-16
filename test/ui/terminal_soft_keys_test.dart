// The row of keys above a phone's keyboard, and the form its arrows, Home
// and End are sent in.
//
// A terminal sends an arrow as `ESC [ A` until the program at the other end
// asks for the other form, `ESC O A`, which editors and pagers do. The row
// handed over the first form whatever had been asked for. An editor like
// vim takes both; less does not, and so neither does man, nor anything that
// runs under screen: the row's arrows did nothing in them. (Held against
// the real programs in test/terminal/live_programs_test.dart.)

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';

String shown(String keys) => keys.replaceAll('\x1b', 'ESC ');

void main() {
  /// A terminal, and what it sent as typed.
  (Terminal, List<String>) terminalAndSent() {
    final terminal = Terminal();
    final sent = <String>[];
    terminal.onOutput = (keys) => sent.add(shown(keys));
    return (terminal, sent);
  }

  const asked = '\x1b[?1h';
  const notAsked = '\x1b[?1l';

  test('an arrow, Home and End are typed in the form the program asked for; everything else as it is', () {
    final (terminal, sent) = terminalAndSent();
    const row = ['\x1B[A', '\x1B[B', '\x1B[C', '\x1B[D', '\x1B[H', '\x1B[F'];

    for (final key in row) {
      typeSoftKey(terminal, key);
    }
    expect(sent, ['ESC [A', 'ESC [B', 'ESC [C', 'ESC [D', 'ESC [H', 'ESC [F'], reason: 'nothing was asked for');

    sent.clear();
    terminal.write(asked);
    for (final key in row) {
      typeSoftKey(terminal, key);
    }
    expect(sent, ['ESC OA', 'ESC OB', 'ESC OC', 'ESC OD', 'ESC OH', 'ESC OF']);

    sent.clear();
    terminal.write(notAsked);
    typeSoftKey(terminal, '\x1B[A');
    expect(sent, ['ESC [A'], reason: 'the program gave the form back when it ended');

    // What has one form only, and what is text.
    sent.clear();
    terminal.write(asked);
    for (final key in ['\x1B', '\t', '/', '\x01', '\x1Bx', '\x1B[5~', '\x1B[3~', '\x1BOP', '\x1B[15~']) {
      typeSoftKey(terminal, key);
    }
    expect(sent, ['ESC ', '\t', '/', '\x01', 'ESC x', 'ESC [5~', 'ESC [3~', 'ESC OP', 'ESC [15~']);
  });

  test('the six are the row\'s own arrows, Home and End, by what it hands over for each', () {
    final ofTheRow = {
      for (final id in ['up', 'down', 'left', 'right', 'home', 'end']) findSoftKey(id)!.sequence!,
    };
    expect(softKeyTerminalKeys.keys.toSet(), ofTheRow);
    expect(softKeyTerminalKeys[findSoftKey('up')!.sequence], TerminalKey.arrowUp);
    expect(softKeyTerminalKeys[findSoftKey('down')!.sequence], TerminalKey.arrowDown);
    expect(softKeyTerminalKeys[findSoftKey('left')!.sequence], TerminalKey.arrowLeft);
    expect(softKeyTerminalKeys[findSoftKey('right')!.sequence], TerminalKey.arrowRight);
    expect(softKeyTerminalKeys[findSoftKey('home')!.sequence], TerminalKey.home);
    expect(softKeyTerminalKeys[findSoftKey('end')!.sequence], TerminalKey.end);
  });

  for (final scrollable in [true, false]) {
    testWidgets('the row itself, ${scrollable ? 'as one row that scrolls' : 'as two rows'}: its arrows, pressed '
        'while a pager runs, are arrows to the pager', (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'soft_keyboard_scrollable_mode': scrollable});
      final prefs = await SharedPreferences.getInstance();
      final (terminal, sent) = terminalAndSent();
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: TerminalSoftKeyboard(onKey: (key) => typeSoftKey(terminal, key)),
            ),
          ),
        ),
      ));
      await tester.pump();

      terminal.write(asked);
      for (final label in ['↑', '↓', '←', '→']) {
        await tester.ensureVisible(find.text(label));
        await tester.pump();
        await tester.tap(find.text(label));
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(sent, ['ESC OA', 'ESC OB', 'ESC OD', 'ESC OC']);

      sent.clear();
      for (final label in ['HOME', 'END']) {
        await tester.ensureVisible(find.text(label));
        await tester.pump();
        await tester.tap(find.text(label));
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(sent, ['ESC OH', 'ESC OF']);
    });
  }

  test('the phone\'s terminal screen types what the row hands over that way', () {
    final screen = File('lib/ui/screens/terminal/terminal_screen.dart').readAsStringSync();
    expect(screen, contains('if (terminal != null) typeSoftKey(terminal, key);'));
    expect(screen, isNot(contains('terminal.textInput(key)')));
  });
}
