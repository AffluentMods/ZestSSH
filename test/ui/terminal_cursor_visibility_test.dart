import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';

/// When the terminal draws its cursor (4.0, a user's suggestion: "the cursor
/// jumps around while a TUI redraws"): a program's own request to hide it
/// (DECTCEM, ESC [ ? 25 l) is obeyed, which it was not (every terminal of the
/// app was drawn with alwaysShowCursor); the person can hide it for good, or
/// only while output that moves it about is arriving, drawn again a moment
/// after the output stops. The timer is the render object's; these tests
/// drive it with fake time.

class _Free extends StateNotifier<bool> implements ProStatusNotifier {
  _Free() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Mirrors RenderTerminal.cursorOutputQuiet.
const _quiet = Duration(milliseconds: 200);

/// Whether the cursor is drawn now.
typedef _Drawn = bool Function();

Future<_Drawn> _pump(
  WidgetTester tester,
  Terminal terminal, {
  bool hideCursor = false,
  bool hideCursorWhileOutput = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 200,
          child: TerminalView(terminal, hideCursor: hideCursor, hideCursorWhileOutput: hideCursorWhileOutput),
        ),
      ),
    ),
  );
  await tester.pump();
  return () => tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal.isCursorDrawn;
}

void main() {
  group("a program's own hide request (DECTCEM)", () {
    testWidgets('ESC [ ? 25 l hides the cursor and ESC [ ? 25 h shows it again', (tester) async {
      final terminal = Terminal(maxLines: 100);
      final drawn = await _pump(tester, terminal);
      expect(drawn(), isTrue);
      terminal.write('\x1b[?25l');
      await tester.pump();
      expect(drawn(), isFalse);
      terminal.write('\x1b[?25h');
      await tester.pump();
      expect(drawn(), isTrue);
    });

    test("no terminal of the app draws the cursor against its program's wish", () {
      // alwaysShowCursor draws it whatever the program asked: the computer's and the phone's terminals, tmux's panes
      // and a shared session's view had it on.
      final drawnAnyway = [
        for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
          if (f.path.endsWith('.dart') && RegExp(r'alwaysShowCursor:\s*true').hasMatch(f.readAsStringSync())) f.path,
      ];
      expect(drawnAnyway, isEmpty);
    });
  });

  group('the person hides the cursor', () {
    testWidgets('Never: not drawn, whatever the program asks', (tester) async {
      final terminal = Terminal(maxLines: 100);
      final drawn = await _pump(tester, terminal, hideCursor: true);
      expect(drawn(), isFalse);
      terminal.write('\x1b[?25h');
      await tester.pump();
      expect(drawn(), isFalse);
    });

    testWidgets(
      'Not while output arrives: hidden while a program draws all over the screen, drawn again a moment after it '
      'stops',
      (tester) async {
        final terminal = Terminal(maxLines: 100);
        final drawn = await _pump(tester, terminal, hideCursorWhileOutput: true);
        expect(drawn(), isTrue, reason: 'no output yet');

        // A full-screen program redraws, in pieces: the cursor goes to one row and another.
        terminal.write('\x1b[5;10Hcpu 12%');
        await tester.pump();
        expect(drawn(), isFalse);
        await tester.pump(const Duration(milliseconds: 150));
        terminal.write('\x1b[2;1Hmem 40%');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(drawn(), isFalse, reason: 'output kept coming: still hidden');
        // A small piece while it is hidden keeps it hidden too.
        terminal.write('x');
        await tester.pump(const Duration(milliseconds: 150));
        expect(drawn(), isFalse);

        await tester.pump(_quiet);
        expect(drawn(), isTrue, reason: 'no output for a moment: drawn again');
      },
    );

    testWidgets('Not while output arrives: what is typed, echoed a cell along the line, leaves it drawn', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100);
      final drawn = await _pump(tester, terminal, hideCursorWhileOutput: true);
      terminal.write('\$ ');
      await tester.pump();
      await tester.pump(_quiet);
      for (final ch in 'ls -la'.split('')) {
        terminal.write(ch);
        await tester.pump();
        expect(drawn(), isTrue, reason: 'typing "$ch"');
        await tester.pump(const Duration(milliseconds: 60));
      }
    });

    testWidgets('a program that hid the cursor is obeyed after the output stops, too', (tester) async {
      final terminal = Terminal(maxLines: 100);
      final drawn = await _pump(tester, terminal, hideCursorWhileOutput: true);
      terminal.write('\x1b[?25l\x1b[10;1Hdrawing');
      await tester.pump();
      await tester.pump(_quiet * 2);
      expect(drawn(), isFalse);
    });

    testWidgets('turned back to Always while hidden, it is drawn at once; taken down, no timer is left', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100);
      await _pump(tester, terminal, hideCursorWhileOutput: true);
      terminal.write('\x1b[8;3Hredraw');
      await tester.pump();
      final drawn = await _pump(tester, terminal);
      expect(drawn(), isTrue);
      terminal.write('\x1b[3;3Hmore');
      await tester.pump();
      expect(drawn(), isTrue, reason: 'Always: never hidden by output');
      await _pump(tester, terminal, hideCursorWhileOutput: true);
      terminal.write('\x1b[9;1Hagain');
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets("a phone's Terminal settings: Show the cursor, its three choices, the one for full-screen apps "
      'recommended, kept', (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Free()),
        isAppLockedProvider.overrideWith((ref) => _Lock()),
      ],
    );
    addTearDown(container.dispose);
    final en = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: TerminalSettingsScreen(),
        ),
      ),
    );
    await tester.pump();
    final tile = find.byKey(const ValueKey('cursor-visibility'));
    await tester.scrollUntilVisible(tile, 200);
    expect(container.read(cursorVisibilityProvider), TerminalCursorVisibility.always);
    expect(find.descendant(of: tile, matching: find.text(en.cursorVisibilityAlways)), findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text(en.cursorVisibilityNever), findsOneWidget);
    expect(find.text(en.cursorVisibilityNotDuringOutputNote), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cursor-visibility-notDuringOutput')));
    await tester.pumpAndSettle();
    expect(container.read(cursorVisibilityProvider), TerminalCursorVisibility.notDuringOutput);
    expect(prefs.getString('cursor_visibility'), 'notDuringOutput');
    expect(find.descendant(of: tile, matching: find.text(en.cursorVisibilityNotDuringOutput)), findsOneWidget);
  });
}
