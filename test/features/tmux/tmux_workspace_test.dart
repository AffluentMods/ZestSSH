import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/tmux/tmux_workspace.dart';
import 'package:zestssh/utils/redactor.dart';

const _layout1 =
    '%layout-change @1 bc62,80x24,0,0,0 bc62,80x24,0,0,0 *\n';
const _layout2 =
    '%layout-change @2 bc63,80x24,0,0,1 bc63,80x24,0,0,1 -\n';

/// Run the microtask continuations of the controller's `await run(...)`
/// chains. (`pumpEventQueue` uses `Future.delayed`, which never fires inside
/// a testWidgets fake-async zone.)
Future<void> _yield() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.value();
  }
}

Widget _app(TmuxController c, SharedPreferences prefs) => ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: TmuxWorkspace(controller: c)),
      ),
    );

void main() {
  late List<String> sent;
  late TmuxController c;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    sent = [];
    c = TmuxController(
      sendBytes: (b) => sent.add(utf8.decode(b)),
      expectMarker: false,
    );
    c.onData(utf8.encode('%session-changed \$0 main\n'));
    // Two windows, created through layout notifications only (a %window-add
    // would queue list-windows and wait for a reply that never comes).
    c.onData(utf8.encode(_layout1));
    c.onData(utf8.encode(_layout2));
    c.onData(utf8.encode('%window-renamed @1 bash\n%window-renamed @2 logs\n'));
  });

  tearDown(() => c.dispose());

  group('tmuxWindowLabel', () {
    test('an idle shell shows where it is, from the prompt title', () {
      final w = c.windows.first;
      w.activePane!.title = 'deploy@web-01: ~/shop';
      expect(tmuxWindowLabel(w), '~/shop');
      w.activePane!.title = 'deploy@web-01: ~';
      expect(tmuxWindowLabel(w), '~');
    });

    test('a shell without a prompt title, or a program, keeps the name', () {
      final w = c.windows.first;
      w.activePane!.title = '';
      expect(tmuxWindowLabel(w), 'bash');
      w.name = 'htop';
      w.activePane!.title = 'deploy@db-primary: ~';
      expect(tmuxWindowLabel(w), 'htop');
    });
  });

  // A bug: killing a window or the session did not work.
  // Through the screen, as a person does it: the menu, the question, Close.
  Future<void> settleMenus(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a window has a close of its own: on the active tab, and on another under the pointer; it asks first, '
      'then kills the window', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(_app(c, prefs));
    await tester.pump();
    Finder close(String id) => find.byKey(ValueKey('tmux-window-close-$id'));
    double shown(String id) =>
        tester.widget<Opacity>(find.ancestor(of: close(id), matching: find.byType(Opacity)).first).opacity;
    expect(shown('@1'), 1, reason: 'the active tab');
    expect(shown('@2'), 0, reason: 'another, until the pointer is over it');

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('logs')));
    await tester.pump();
    expect(shown('@2'), 1, reason: 'under the pointer');

    await tester.tap(close('@2'));
    await settleMenus(tester);
    expect(find.text(l10n.tmuxCloseWindowConfirmTitle('logs')), findsOneWidget, reason: 'asked first');
    expect(sent.map((s) => s.trim()), isNot(contains('kill-window -t @2')));
    await tester.tap(find.text(l10n.tmuxCloseWindow).last);
    await settleMenus(tester);
    await _yield();
    expect(sent.map((s) => s.trim()), contains('kill-window -t @2'));
    expect(c.activeWindowId, '@1', reason: 'the close did not select the window');
  });

  testWidgets('while recording, what the host put in a pane title is not in the pill, its tooltip or the question '
      'before a window is closed', (tester) async {
    c.windows.first.activePane!.title = 'deploy@web-01: ~/shop';
    List<String> tooltips() =>
        [for (final t in tester.widgetList<Tooltip>(find.byType(Tooltip))) t.message ?? ''];

    // Not recording: the tooltip is the title, as it was.
    await tester.pumpWidget(_app(c, prefs));
    await tester.pump();
    expect(tooltips(), contains('deploy@web-01: ~/shop'));

    Redactor.instance.enabled = true;
    addTearDown(() => Redactor.instance.enabled = false);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => true),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: TmuxWorkspace(controller: c)),
      ),
    ));
    await tester.pump();
    expect(tooltips().where((t) => t.contains('web-01') || t.contains('shop')), isEmpty);
    expect(find.textContaining('shop'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tmux-window-close-@1')));
    await settleMenus(tester);
    expect(find.textContaining('shop'), findsNothing, reason: 'the question names the window as the pill does');
    expect(find.textContaining('web-01'), findsNothing);
  });

  testWidgets("a window closed from its pill's menu is killed in tmux, after one question", (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(_app(c, prefs));
    await tester.pump();
    await tester.tap(find.text('logs'), buttons: kSecondaryButton);
    await settleMenus(tester);
    await tester.tap(find.text(l10n.tmuxCloseWindow).last);
    await settleMenus(tester);
    expect(find.text(l10n.tmuxCloseWindowConfirmTitle('logs')), findsOneWidget);
    await tester.tap(find.text(l10n.tmuxCloseWindow).last);
    await settleMenus(tester);
    await _yield();
    expect(sent.map((s) => s.trim()), contains('kill-window -t @2'));
  });

  testWidgets('the session killed from its menu is killed in tmux, after one question', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(_app(c, prefs));
    await tester.pump();
    await tester.tap(find.byTooltip(l10n.tmuxSessionsMenu));
    await settleMenus(tester);
    await tester.tap(find.text(l10n.tmuxKillSession).last);
    await settleMenus(tester);
    expect(find.text(l10n.tmuxKillSessionConfirmTitle('main')), findsOneWidget);
    await tester.tap(find.text(l10n.tmuxKillSession).last);
    await settleMenus(tester);
    await _yield();
    expect(sent.map((s) => s.trim()), contains(r'kill-session -t $0'));
  });

  testWidgets('window pills render, switch on tap and show a click cursor',
      (tester) async {
    await tester.pumpWidget(_app(c, prefs));
    await tester.pump();
    expect(find.text('bash'), findsOneWidget);
    expect(find.text('logs'), findsOneWidget);
    expect(c.activeWindowId, '@1');

    // Hovering a pill shows the click cursor.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('logs')));
    await tester.pump();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );

    await tester.tap(find.text('logs'));
    await tester.pump();
    expect(c.activeWindowId, '@2');
    expect(sent.any((s) => s.trim() == 'select-window -t @2'), isTrue);
  });

  testWidgets('right-click on a live pane pastes the clipboard into it',
      (tester) async {
    // Built inside the test body: continuations of the controller's
    // `await run(...)` chains must belong to the fake-async zone.
    final sent2 = <String>[];
    final c2 = TmuxController(
      sendBytes: (b) => sent2.add(utf8.decode(b)),
      expectMarker: false,
    );
    addTearDown(c2.dispose);
    // No %session-changed: it would queue a session resync whose replies
    // the hand-written blocks below would be taken for.
    c2.onData(utf8.encode(_layout1));
    String block(int n, List<String> lines) =>
        '%begin 1 $n 1\n${lines.map((l) => '$l\n').join()}%end 1 $n 1\n';
    // Answer the pane's display-message, then its capture.
    c2.onData(utf8.encode(block(1, [
      '%0 80 24 2 0 0 0 0 0 0 0 23 1 0 0 0 1 0 0 0 0 0 0 1 @1 bash',
    ])));
    await _yield();
    c2.onData(utf8.encode(block(2, ['\$ '])));
    await _yield();
    final pane0 = c2.windows.single.panes['%0']!;
    expect(pane0.awaitingCapture, isFalse);

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return {'text': 'pasted'};
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(_app(c2, prefs));
    await tester.pump();
    final pane = find.byKey(ValueKey('tmux-pane-%0-${pane0.terminal.hashCode}'));
    expect(pane, findsOneWidget);
    final before = sent2.length;
    await tester.tapAt(tester.getCenter(pane), buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final keys = sent2.sublist(before).where((s) => s.startsWith('send-keys'));
    expect(keys, isNotEmpty, reason: 'paste must reach the pane as send-keys');
    final hex = 'pasted'.codeUnits.map((b) => b.toRadixString(16)).join(' ');
    expect(keys.any((k) => k.contains(hex)), isTrue);
  });

  testWidgets(
      'a right click pastes at the release of the button, what the clipboard '
      'holds then, and a middle click pastes once', (tester) async {
    // (A bug in 2.2.1: over a remote desktop a paste was the one
    // before. What was copied on the other computer arrives with the click
    // into the window, a moment after the press.)
    final sent2 = <String>[];
    final c2 = TmuxController(
      sendBytes: (b) => sent2.add(utf8.decode(b)),
      expectMarker: false,
    );
    addTearDown(c2.dispose);
    c2.onData(utf8.encode(_layout1));
    String block(int n, List<String> lines) =>
        '%begin 1 $n 1\n${lines.map((l) => '$l\n').join()}%end 1 $n 1\n';
    c2.onData(utf8.encode(block(1, [
      '%0 80 24 2 0 0 0 0 0 0 0 23 1 0 0 0 1 0 0 0 0 0 0 1 @1 bash',
    ])));
    await _yield();
    c2.onData(utf8.encode(block(2, ['\$ '])));
    await _yield();
    final pane0 = c2.windows.single.panes['%0']!;

    var clipboard = 'before';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(_app(c2, prefs));
    await tester.pump();
    final pane = find.byKey(ValueKey('tmux-pane-%0-${pane0.terminal.hashCode}'));
    String hex(String text) =>
        text.codeUnits.map((b) => b.toRadixString(16)).join(' ');
    Iterable<String> pasted(int from, String text) => sent2
        .sublist(from)
        .where((s) => s.startsWith('send-keys') && s.contains(hex(text)));

    var mark = sent2.length;
    final right = await tester.startGesture(tester.getCenter(pane),
        kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await tester.pump(const Duration(milliseconds: 50));
    expect(sent2.sublist(mark).where((s) => s.startsWith('send-keys')), isEmpty,
        reason: 'nothing is pasted at the press');
    clipboard = 'after';
    await right.up();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(pasted(mark, 'after'), hasLength(1));
    expect(pasted(mark, 'before'), isEmpty);

    mark = sent2.length;
    clipboard = 'middle';
    final middle = await tester.startGesture(tester.getCenter(pane),
        kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    await tester.pump(const Duration(milliseconds: 50));
    await middle.up();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(pasted(mark, 'middle'), hasLength(1), reason: 'once, not twice');
  });

  for (final off in ['desktop_right_click_paste', 'desktop_middle_click_paste']) {
    testWidgets('a pane pastes by each button\'s own setting ($off off)', (tester) async {
      await prefs.setBool(off, false);
      final sent2 = <String>[];
      final c2 = TmuxController(
        sendBytes: (b) => sent2.add(utf8.decode(b)),
        expectMarker: false,
      );
      addTearDown(c2.dispose);
      c2.onData(utf8.encode(_layout1));
      String block(int n, List<String> lines) =>
          '%begin 1 $n 1\n${lines.map((l) => '$l\n').join()}%end 1 $n 1\n';
      c2.onData(utf8.encode(block(1, [
        '%0 80 24 2 0 0 0 0 0 0 0 23 1 0 0 0 1 0 0 0 0 0 0 1 @1 bash',
      ])));
      await _yield();
      c2.onData(utf8.encode(block(2, ['\$ '])));
      await _yield();
      final pane0 = c2.windows.single.panes['%0']!;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return {'text': 'pasted'};
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(_app(c2, prefs));
      await tester.pump();
      final pane =
          find.byKey(ValueKey('tmux-pane-%0-${pane0.terminal.hashCode}'));
      final hex = 'pasted'.codeUnits.map((b) => b.toRadixString(16)).join(' ');
      int pastes(int from) => sent2
          .sublist(from)
          .where((s) => s.startsWith('send-keys') && s.contains(hex))
          .length;

      Future<int> click(int button) async {
        final mark = sent2.length;
        final gesture = await tester.startGesture(tester.getCenter(pane),
            kind: PointerDeviceKind.mouse, buttons: button);
        await tester.pump(const Duration(milliseconds: 50));
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        return pastes(mark);
      }

      expect(await click(kSecondaryButton),
          off == 'desktop_right_click_paste' ? 0 : 1);
      expect(await click(kMiddleMouseButton),
          off == 'desktop_middle_click_paste' ? 0 : 1);
    });
  }

  testWidgets('both windows stay mounted so switching is a visibility flip',
      (tester) async {
    await tester.pumpWidget(_app(c, prefs));
    await tester.pump();
    final offstage = find.byWidgetPredicate(
        (w) => w is Offstage && (w.key as ValueKey?)?.value == 'tmux-window-@2');
    expect(offstage, findsOneWidget);
    expect(tester.widget<Offstage>(offstage).offstage, isTrue);
    c.selectWindow('@2');
    await tester.pump();
    expect(tester.widget<Offstage>(offstage).offstage, isFalse);
  });

  testWidgets('every pane asks the keyboard not to learn from it, until its person lets it (Settings)',
      (tester) async {
    await tester.pumpWidget(_app(c, prefs));
    await tester.pump();
    List<bool> learning() =>
        [
          for (final view in tester.widgetList<TerminalView>(find.byType(TerminalView, skipOffstage: false)))
            view.personalizedLearning,
        ];
    expect(learning(), [false, false], reason: 'a pane in each of the two windows, the one in front and the one behind');

    final container = ProviderScope.containerOf(tester.element(find.byType(TmuxWorkspace)));
    await container.read(settingsUpdaterProvider).setKeyboardIncognito(false);
    await tester.pump();
    expect(learning(), [true, true], reason: 'told while the session is on screen');
    await container.read(settingsUpdaterProvider).setKeyboardIncognito(true);
    await tester.pump();
    expect(learning(), [false, false]);
  });

  testWidgets('every pane asks for the keyboard without suggestions where its person chose it (Settings, the compact '
      'keyboard)', (tester) async {
    await tester.pumpWidget(_app(c, prefs));
    await tester.pump();
    List<TextInputType> asked() => [
          for (final view in tester.widgetList<TerminalView>(find.byType(TerminalView, skipOffstage: false)))
            view.keyboardType,
        ];
    expect(asked(), [TextInputType.emailAddress, TextInputType.emailAddress], reason: 'off: as it was');

    final container = ProviderScope.containerOf(tester.element(find.byType(TmuxWorkspace)));
    await container.read(settingsUpdaterProvider).setCompactKeyboard(true);
    await tester.pump();
    expect(asked(), [TextInputType.visiblePassword, TextInputType.visiblePassword],
        reason: 'the window in front and the one behind');
    await container.read(settingsUpdaterProvider).setCompactKeyboard(false);
    await tester.pump();
    expect(asked(), [TextInputType.emailAddress, TextInputType.emailAddress]);
  });

  // 4.0 accessibility pass: a tmux pane is a terminal to a screen reader as a
  // session's own is, named for its window, with Read the screen.
  testWidgets('a pane is a terminal to a screen reader, named for its window', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(c, prefs));
    await tester.pump();
    final en = lookupAppLocalizations(const Locale('en'));
    final node = find.bySemanticsLabel(en.terminalReaderName('bash'));
    expect(node, findsOneWidget);
    expect(tester.getSemantics(node).getSemanticsData().customSemanticsActionIds, isNotEmpty);
    semantics.dispose();
  });
}
