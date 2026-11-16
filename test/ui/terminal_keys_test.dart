// A terminal's own keys from a keyboard (found while
// comparing the five versions). The terminal widget's own keys took Ctrl+A
// and Ctrl+V from the shell in a phone's terminal on Android (and in a live
// view and a window of its own on Windows and Linux), so Ctrl+A never went
// to the start of the line nor reached tmux or screen; a computer's panes
// and tmux's had no Cmd on a Mac and an iPad, where a phone's terminal had
// it; and a paste by keys went in unasked, dangerous or not, where the
// app's own paste asks first. Now every terminal one types into has one set
// (terminalKeys, lib/ui/widgets/terminal_paste.dart): Ctrl+Shift+C, V and A
// copy, paste and select all, Cmd+C, V and A as well on a Mac, an iPad and
// an iPhone, the plain Ctrl chords are the shell's, and a paste by them is
// the app's one paste of a terminal.
//
// And on a computer copy and paste are the keys Settings binds them to
// (found with the shell's keys): a key chosen there did
// nothing in a terminal. A key of Copy's own copies what is selected, and with
// nothing selected is the terminal's (Ctrl+C given to Copy still stops a
// program).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/clipboard_manager.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';
import 'package:zestssh/ui/screens/sharing/share_view_screen.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/tmux/tmux_workspace.dart';
import 'package:zestssh/ui/widgets/terminal_paste.dart';

import 'sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

/// What a paste of the app asks about, and what it does not.
const _dangerous = 'rm -rf /var/lib/postgresql';
const _safe = 'uptime';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// What the system's clipboard holds.
  String? clipboard;

  setUp(() => clipboard = null);

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          clipboard = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return clipboard == null ? null : <String, Object?>{'text': clipboard};
        case 'Clipboard.hasStrings':
          return <String, Object?>{'value': clipboard != null};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  /// [key] pressed with [held] held down.
  Future<void> chord(WidgetTester tester, List<LogicalKeyboardKey> held, LogicalKeyboardKey key) async {
    for (final k in held) {
      await tester.sendKeyDownEvent(k);
    }
    await tester.sendKeyEvent(key);
    for (final k in held.reversed) {
      await tester.sendKeyUpEvent(k);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  const ctrl = [LogicalKeyboardKey.controlLeft];
  const ctrlShift = [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft];
  const cmd = [LogicalKeyboardKey.metaLeft];
  const shift = [LogicalKeyboardKey.shiftLeft];

  /// The keys Settings keeps: Copy at Ctrl+C, Paste at Shift+Insert.
  final rebound = <String, Object>{
    'shortcut_overrides': jsonEncode({
      'copySelection': ShortcutKey(keyId: LogicalKeyboardKey.keyC.keyId, ctrl: true).toJson(),
      'paste': ShortcutKey(keyId: LogicalKeyboardKey.insert.keyId, shift: true).toJson(),
    }),
  };

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  /// [text] pasted by [keys], where the app asks before a dangerous one:
  /// [answer] answers its question (null: there is none).
  Future<void> pasteBy(WidgetTester tester, List<LogicalKeyboardKey> keys, String text, {String? answer}) async {
    clipboard = text;
    await chord(tester, keys, LogicalKeyboardKey.keyV);
    await settle(tester);
    if (answer == null) {
      expect(find.text(l10n.dangerPasteTitle), findsNothing, reason: '$text was asked about');
      return;
    }
    expect(find.text(l10n.dangerPasteTitle), findsOneWidget, reason: '$text went in unasked');
    await tester.tap(find.text(answer).last);
    await settle(tester);
  }

  group('the keys', () {
    String named(ShortcutActivator activator) {
      final a = activator as SingleActivator;
      return [if (a.control) 'Ctrl', if (a.meta) 'Cmd', if (a.shift) 'Shift', a.trigger.keyLabel].join('+');
    }

    for (final (platform, apple) in [
      (TargetPlatform.android, false),
      (TargetPlatform.windows, false),
      (TargetPlatform.linux, false),
      (TargetPlatform.macOS, true),
      (TargetPlatform.iOS, true),
    ]) {
      test('Ctrl+Shift+C, V and A copy, paste and select all${apple ? ', and Cmd+C, V and A' : ''} ($platform); '
          'the plain Ctrl chords are left to the shell', () {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        var pasted = 0;
        final keys = terminalKeys(paste: () => pasted++);
        final byName = {for (final e in keys.entries) named(e.key): e.value};
        expect(byName.keys.toSet(), {
          'Ctrl+Shift+C', 'Ctrl+Shift+V', 'Ctrl+Shift+A',
          if (apple) ...{'Cmd+C', 'Cmd+V', 'Cmd+A'},
        });
        for (final prefix in ['Ctrl+Shift+', if (apple) 'Cmd+']) {
          expect(byName['${prefix}C'], isA<CopySelectionTextIntent>());
          expect(byName['${prefix}A'], isA<SelectAllTextIntent>());
          (byName['${prefix}V']! as VoidCallbackIntent).callback();
        }
        expect(pasted, apple ? 2 : 1, reason: 'a paste by them is the one given');
      });
    }

    test('with the keys Settings binds: Ctrl+Shift+C and V as they are; none for one cleared there', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      Set<String> names(ShortcutBindings bindings) =>
          {for (final k in terminalKeys(paste: () {}, bindings: bindings).keys) named(k)};
      expect(names(ShortcutBindings({})), {'Ctrl+Shift+C', 'Ctrl+Shift+V', 'Ctrl+Shift+A'});
      expect(names(ShortcutBindings({ShortcutAction.paste: const ShortcutKey(keyId: 0)})),
          {'Ctrl+Shift+C', 'Ctrl+Shift+A'});
      final noCopy = terminalKeys(
          paste: () {}, bindings: ShortcutBindings({ShortcutAction.copySelection: const ShortcutKey(keyId: 0)}));
      expect(noCopy.values.whereType<CopySelectionTextIntent>(), isEmpty);
      expect({for (final k in noCopy.keys) named(k)}, {'Ctrl+Shift+V', 'Ctrl+Shift+A'});
    });

    test('a window of its own reads the keys Settings keeps, as Settings keeps them', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(container.dispose);
      final keys = container.read(shortcutBindingsProvider.notifier);
      final copy = ShortcutKey(keyId: LogicalKeyboardKey.insert.keyId, ctrl: true);
      await keys.setBinding(ShortcutAction.copySelection, copy);
      await keys.unbind(ShortcutAction.paste);
      final read = ShortcutBindings.fromPrefs(prefs);
      expect(read.bindingFor(ShortcutAction.copySelection), copy);
      expect(read.bindingFor(ShortcutAction.paste), isNull);
      expect(read.bindingFor(ShortcutAction.zoomIn),
          container.read(shortcutBindingsProvider).bindingFor(ShortcutAction.zoomIn));
      await prefs.setString('shortcut_overrides', '{not json');
      expect(ShortcutBindings.fromPrefs(prefs).overrides, isEmpty, reason: 'what cannot be read is no binding');
    });

    test('a paste types no control character but a tab and a line break, and a bracketed one ends once '
        '(before, its end marker, rebuilt from its own pieces, ran the rest as typed)', () {
      expect(Terminal.pasteable('ls\x03\x1a\x00\x7f\x9b31m\x1b[0m\tx\r\nye\u0301 \u4e2d'),
          'ls31m[0m\tx\r\nye\u0301 \u4e2d');
      final terminal = Terminal();
      final out = <String>[];
      terminal.onOutput = out.add;
      terminal.paste('uptime\x1b[31m\nwhoami');
      terminal.write('\x1b[?2004h');
      terminal.paste('echo hi\x1b[20\x1b[201~1~\nrm -rf ~/demo\n');
      expect(out, [
        'uptime[31m\rwhoami',
        '\x1b[200~echo hi[20[201~1~\rrm -rf ~/demo\r\x1b[201~',
      ]);
    });

    testWidgets('what a keyboard commits from its clipboard goes the one way a paste goes: its question first, '
        'then as a paste may type it', (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      late BuildContext at;
      late WidgetRef widgetRef;
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Consumer(builder: (context, ref, _) {
            at = context;
            widgetRef = ref;
            return const SizedBox();
          }),
        ),
      ));
      final l10n = lookupAppLocalizations(const Locale('en'));
      final terminal = Terminal();
      final typed = <String>[];
      terminal.onOutput = typed.add;

      final asked = pasteTextIntoTerminal(at, widgetRef, terminal, 'uptime\x1b[201~\nwhoami\n');
      await settle(tester);
      expect(find.byKey(const ValueKey('paste-question-runs')), findsOneWidget);
      expect(typed, isEmpty, reason: 'nothing until it is answered');
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      await asked;
      expect(typed, isEmpty);

      // Where the shell waits for Enter it asks nothing, and no ESC gets through.
      terminal.write('\x1b[?2004h');
      await pasteTextIntoTerminal(at, widgetRef, terminal, 'uptime\x1b[201~\nwhoami\n');
      expect(typed, ['\x1b[200~uptime[201~\rwhoami\r\x1b[201~']);
    });

    testWidgets('a file dropped on a terminal: its path is typed, in quotes, unless a control character in it '
        'would act as a key on the way in', (tester) async {
      late BuildContext at;
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: Builder(builder: (context) {
            at = context;
            return const SizedBox();
          })),
        ),
      ));
      final terminal = Terminal();
      final typed = <String>[];
      terminal.onOutput = typed.add;
      typeDroppedPaths(at, terminal, ['/home/me/a b.txt', "/home/me/it's"]);
      expect(typed, [r"'/home/me/a b.txt' '/home/me/it'\''s'"]);
      typed.clear();
      typeDroppedPaths(at, terminal, ['/home/me/fine', '/home/me/x\x15touch RAN\r']);
      await tester.pump();
      expect(typed, isEmpty);
      final told = ProviderScope.containerOf(at).read(notificationCenterProvider).history.single;
      expect(told.title, lookupAppLocalizations(const Locale('en')).terminalNameNotTyped);
      expect(told.details, isNotNull, reason: 'it has Copy details, with folder names taken out as they always are');
      await tester.pump(const Duration(seconds: 30));
    });

    test('a link is asked about as what it is: a direction override drew it as another address', () {
      String text(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');
      expect(text('lib/ui/screens/terminal/terminal_screen.dart'), contains('body: withHiddenCharactersShown(url),'));
      expect(text('lib/ui/screens/desktop/widgets/desktop_terminal_area.dart'),
          contains('l10n.desktopTerminalAreaUrlDetectedBody(withHiddenCharactersShown(url))'));
    });

    testWidgets('a window of its own, which has no settings, pastes what the clipboard holds as a paste: marked '
        'where the shell asked for that, and asked about first where the shell would run its lines as they arrive',
        (tester) async {
      mockClipboard(tester);
      late BuildContext window;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(builder: (context) {
          window = context;
          return const SizedBox();
        }),
      ));
      final terminal = Terminal();
      final typed = <String>[];
      terminal.onOutput = typed.add;
      clipboard = _dangerous;
      await pasteClipboardAsIs(window, terminal);

      // Lines that would run as they arrive: asked first (they went in
      // unasked).
      clipboard = 'uptime\nwhoami\n';
      final asked = pasteClipboardAsIs(window, terminal);
      await settle(tester);
      expect(find.byKey(const ValueKey('paste-question-runs')), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      await asked;
      expect(typed, [_dangerous], reason: 'Cancel pastes nothing');

      terminal.write('\x1b[?2004h');
      clipboard = '$_safe\x07';
      await pasteClipboardAsIs(window, terminal);
      clipboard = '';
      await pasteClipboardAsIs(window, terminal);
      expect(typed, [_dangerous, '\x1b[200~$_safe\x1b[201~']);
      await finish(tester);
    });

    test('every terminal one types into is given them; a replay, where nothing typed goes anywhere, keeps the '
        "widget's own", () {
      final views = <String>{};
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final text = file.readAsStringSync();
        final n = RegExp(r'\bTerminalView\(').allMatches(text).length;
        if (n == 0) continue;
        final name = file.path.replaceAll(r'\', '/').split('/').last;
        views.add(name);
        if (name == 'session_replay_screen.dart') continue;
        expect(RegExp(r'shortcuts: terminalKeys\(').allMatches(text).length, n, reason: file.path);
        // A computer's terminals are given the keys Settings binds; a phone's
        // and a tablet's own terminal has no such settings.
        if (name != 'terminal_screen.dart') {
          expect(RegExp(r'terminalKeys\((?:(?!terminalKeys\().){0,400}?bindings: ', dotAll: true).allMatches(text).length, n,
              reason: '${file.path}: the bindings');
        }
      }
      expect(
          views,
          {
            'main.dart', 'desktop_terminal_area.dart', 'session_replay_screen.dart', 'share_view_screen.dart',
            'terminal_screen.dart', 'tmux_workspace.dart',
          },
          reason: 'a terminal somewhere new: give it terminalKeys, or say here why not');
    });
  });

  group("a phone's or a tablet's terminal", () {
    /// The terminal screen of a session on [platform], and what is sent to
    /// the session as typed.
    Future<(Terminal, List<String>)> pumpPhone(WidgetTester tester, TargetPlatform platform) async {
      debugDefaultTargetPlatformOverride = platform;
      mockClipboard(tester);
      tester.view.physicalSize = const Size(1800, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'cursor_blink': false});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(FakeSessions.new),
        connectionHealthProvider.overrideWith((ref) => _Health()),
      ]);
      addTearDown(container.dispose);
      final sessions = container.read(activeSessionsProvider.notifier) as FakeSessions;
      sessions.show({'s1': connectedSession('s1', 'Web 1')});
      final terminal = sessions.state['s1']!.session!.terminal;
      final typed = <String>[];
      terminal.onOutput = typed.add;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: TerminalScreen(sessionId: 's1'),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TerminalView), findsOneWidget);
      return (terminal, typed);
    }

    testWidgets('on Android Ctrl+A and Ctrl+V are the shell\'s; Ctrl+Shift+V pastes, asked about where it looks '
        'dangerous; Ctrl+Shift+A and C copy the screen', (tester) async {
      final (terminal, typed) = await pumpPhone(tester, TargetPlatform.android);
      await chord(tester, ctrl, LogicalKeyboardKey.keyA);
      await chord(tester, ctrl, LogicalKeyboardKey.keyV);
      expect(typed, ['\x01', '\x16'], reason: 'they were select all and paste');

      typed.clear();
      await pasteBy(tester, ctrlShift, _safe);
      expect(typed.join(), _safe);
      typed.clear();
      await pasteBy(tester, ctrlShift, _dangerous, answer: l10n.cancel);
      expect(typed, isEmpty, reason: 'Cancel pastes nothing');

      terminal.write('load average: 0.42\r\n');
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyA);
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyC);
      expect(clipboard, contains('load average: 0.42'));
      await finish(tester);
    });

    testWidgets("the menu's Paste asks before lines, a CR alone counting as a line break, and says where they run "
        'as they are pasted; it types no control character', (tester) async {
      final (terminal, typed) = await pumpPhone(tester, TargetPlatform.android);
      Future<void> pasteFromMenu() async {
        final press = await tester.startGesture(tester.getCenter(find.byType(TerminalView)));
        await tester.pump(const Duration(milliseconds: 900));
        await press.up();
        await settle(tester);
        final paste = find.text(l10n.terminalPaste).last;
        await tester.ensureVisible(paste);
        await tester.pump();
        await tester.tap(paste);
        await settle(tester);
      }

      final question = find.byKey(const ValueKey('paste-question'));
      final why = find.byKey(const ValueKey('paste-question-runs'));
      clipboard = 'uptime\rwhoami';
      await pasteFromMenu();
      expect(question, findsOneWidget, reason: 'two lines (only LFs were counted)');
      expect(why, findsOneWidget, reason: 'this shell runs them as they come');
      await tester.tap(find.descendant(of: question, matching: find.text(l10n.terminalPaste)));
      await settle(tester);
      expect(typed.join(), 'uptime\rwhoami');
      typed.clear();

      terminal.write('\x1b[?2004h');
      clipboard = 'uptime\nwhoami\x1b[201~';
      await pasteFromMenu();
      expect(question, findsOneWidget, reason: 'two lines');
      expect(why, findsNothing, reason: 'the shell waits for Enter');
      await tester.tap(find.descendant(of: question, matching: find.text(l10n.terminalPaste)));
      await settle(tester);
      expect(typed.join(), '\x1b[200~uptime\rwhoami[201~\x1b[201~');
      await finish(tester);
    });

    testWidgets('a line from the clipboard history is pasted as Paste pastes it: asked about where its lines run as '
        'they come, and with no control character', (tester) async {
      final (_, typed) = await pumpPhone(tester, TargetPlatform.android);
      final container = ProviderScope.containerOf(tester.element(find.byType(TerminalScreen)));
      container.read(clipboardManagerProvider.notifier).add('uptime\x07\rwhoami');
      final press = await tester.startGesture(tester.getCenter(find.byType(TerminalView)));
      await tester.pump(const Duration(milliseconds: 900));
      await press.up();
      await settle(tester);
      final history = find.text(l10n.terminalClipboardHistory).last;
      await tester.ensureVisible(history);
      await tester.pump();
      await tester.tap(history);
      await settle(tester);
      await tester.tap(find.textContaining('whoami').last);
      await settle(tester);
      final question = find.byKey(const ValueKey('paste-question'));
      expect(question, findsOneWidget);
      expect(find.byKey(const ValueKey('paste-question-runs')), findsOneWidget);
      await tester.tap(find.descendant(of: question, matching: find.text(l10n.terminalPaste)));
      await settle(tester);
      expect(typed.join(), 'uptime\rwhoami');
      await finish(tester);
    });

    testWidgets('on an iPad Cmd+V pastes, asked about where it looks dangerous; Cmd+A and C copy the screen; Ctrl+A '
        "is the shell's", (tester) async {
      final (terminal, typed) = await pumpPhone(tester, TargetPlatform.iOS);
      await pasteBy(tester, cmd, _safe);
      expect(typed.join(), _safe);
      typed.clear();
      await pasteBy(tester, cmd, _dangerous, answer: l10n.dangerPasteAnyway);
      expect(typed.join(), _dangerous, reason: 'pasted anyway');

      typed.clear();
      await chord(tester, ctrl, LogicalKeyboardKey.keyA);
      expect(typed, ['\x01']);
      terminal.write('3 users\r\n');
      await chord(tester, cmd, LogicalKeyboardKey.keyA);
      await chord(tester, cmd, LogicalKeyboardKey.keyC);
      expect(clipboard, contains('3 users'));
      await finish(tester);
    });
  });

  group("a computer's pane", () {
    /// A computer's terminal area with the session in its one pane, on
    /// [platform], the keyboard in its terminal; and what is sent to the
    /// session as typed.
    Future<(Terminal, List<String>)> pumpPane(WidgetTester tester, TargetPlatform platform,
        {Map<String, Object> saved = const {}}) async {
      debugDefaultTargetPlatformOverride = platform;
      mockClipboard(tester);
      tester.view.physicalSize = const Size(1200, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'cursor_blink': false, ...saved});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(FakeSessions.new),
        connectionHealthProvider.overrideWith((ref) => _Health()),
      ]);
      addTearDown(container.dispose);
      final sessions = container.read(activeSessionsProvider.notifier) as FakeSessions;
      final tabs = container.read(workTabsProvider.notifier);
      sessions.show({'s1': connectedSession('s1', 'Web 1')});
      tabs.setActiveTab(tabs.tabContaining('s1')!.id);
      container.read(v3ActiveSessionTabProvider.notifier).state = 's1';
      container.read(paneTreeProvider.notifier).initSinglePane('s1');
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: DesktopTerminalArea(onConnectTo: (_) {}, onToggleSftp: (_) {}, onApplyLayout: (_) {}),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final terminal = sessions.state['s1']!.session!.terminal;
      final typed = <String>[];
      terminal.onOutput = typed.add;
      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(milliseconds: 200));
      return (terminal, typed);
    }

    testWidgets("on Windows Ctrl+A and Ctrl+V are the shell's; Ctrl+Shift+V pastes, asked about where it looks "
        'dangerous (it went in unasked)', (tester) async {
      final (_, typed) = await pumpPane(tester, TargetPlatform.windows);
      await chord(tester, ctrl, LogicalKeyboardKey.keyA);
      await chord(tester, ctrl, LogicalKeyboardKey.keyV);
      expect(typed, ['\x01', '\x16']);
      typed.clear();
      await pasteBy(tester, ctrlShift, _safe);
      expect(typed.join(), _safe);
      typed.clear();
      await pasteBy(tester, ctrlShift, _dangerous, answer: l10n.cancel);
      expect(typed, isEmpty);
      await finish(tester);
    });

    testWidgets('with Copy at Ctrl+C and Paste at Shift+Insert in Settings: Ctrl+C copies what is selected, and '
        'with nothing selected stops the program as before; Shift+Insert pastes, asked about where it looks '
        'dangerous; Ctrl+Shift+C and V do neither (a key chosen there did nothing in a terminal)', (tester) async {
      final (terminal, typed) = await pumpPane(tester, TargetPlatform.windows, saved: rebound);
      terminal.write('web-01 ready\r\n');
      await chord(tester, ctrl, LogicalKeyboardKey.keyC);
      expect(typed, ['\x03'], reason: 'nothing selected: the terminal has it');
      expect(clipboard, isNull);
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyA);
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyC);
      expect(clipboard, isNull, reason: 'Ctrl+Shift+C is not Copy any more');
      typed.clear();
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyA);
      await chord(tester, ctrl, LogicalKeyboardKey.keyC);
      expect(clipboard, contains('web-01 ready'));
      expect(typed, isEmpty, reason: 'a copy types nothing');

      clipboard = _safe;
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyV);
      await settle(tester);
      expect(typed.join(), isNot(contains(_safe)), reason: 'Ctrl+Shift+V is not Paste any more');
      typed.clear();
      await chord(tester, shift, LogicalKeyboardKey.insert);
      await settle(tester);
      expect(typed.join(), _safe);
      typed.clear();
      clipboard = _dangerous;
      await chord(tester, shift, LogicalKeyboardKey.insert);
      await settle(tester);
      expect(find.text(l10n.dangerPasteTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      expect(typed, isEmpty);
      await finish(tester);
    });

    testWidgets('lines that would run as they are pasted are asked about first, saying why; where the shell waits '
        'for Enter (bracketed paste), and for one line, nothing is asked; what is typed has no control character',
        (tester) async {
      final (terminal, typed) = await pumpPane(tester, TargetPlatform.windows);
      bool asked() => find.byKey(const ValueKey('paste-question')).evaluate().isNotEmpty;

      clipboard = 'uptime\x03';
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyV);
      await settle(tester);
      expect(asked(), isFalse, reason: 'one line');
      expect(typed.join(), 'uptime');
      typed.clear();

      clipboard = 'uptime\rwhoami\n';
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyV);
      await settle(tester);
      expect(asked(), isTrue, reason: 'a CR alone is a line break as well');
      expect(find.text(l10n.terminalPasteRunsLines(2)), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      expect(typed, isEmpty, reason: 'Cancel pastes nothing');
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyV);
      await settle(tester);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('paste-question')), matching: find.text(l10n.terminalPaste)));
      await settle(tester);
      expect(typed.join(), 'uptime\rwhoami\r');
      typed.clear();

      terminal.write('\x1b[?2004h');
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyV);
      await settle(tester);
      expect(asked(), isFalse, reason: 'the shell waits for Enter');
      expect(typed.join(), '\x1b[200~uptime\rwhoami\r\x1b[201~');
      typed.clear();

      // What is looked at for danger is what would be typed: a control
      // character inside a word hid it.
      clipboard = 'r\x00m -rf /etc';
      await chord(tester, ctrlShift, LogicalKeyboardKey.keyV);
      await settle(tester);
      expect(find.text(l10n.dangerPasteTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      expect(typed, isEmpty);
      await finish(tester);
    });

    testWidgets('on a Mac Cmd+C copies and Cmd+V pastes, as in every terminal of a Mac (they did nothing), asked '
        'about where it looks dangerous; Ctrl+Shift+V too', (tester) async {
      final (terminal, typed) = await pumpPane(tester, TargetPlatform.macOS);
      terminal.write('web-01 ready\r\n');
      await chord(tester, cmd, LogicalKeyboardKey.keyA);
      await chord(tester, cmd, LogicalKeyboardKey.keyC);
      expect(clipboard, contains('web-01 ready'));
      typed.clear();
      await pasteBy(tester, cmd, _safe);
      expect(typed.join(), _safe);
      typed.clear();
      await pasteBy(tester, cmd, _dangerous, answer: l10n.cancel);
      expect(typed, isEmpty);
      await pasteBy(tester, ctrlShift, _safe);
      expect(typed.join(), _safe);
      await finish(tester);
    });
  });

  group("tmux's panes", () {
    /// A tmux session with one live pane on [platform], the keyboard in it;
    /// and what was sent to tmux.
    Future<List<String>> pumpTmux(WidgetTester tester, TargetPlatform platform,
        {Map<String, Object> saved = const {}}) async {
      debugDefaultTargetPlatformOverride = platform;
      mockClipboard(tester);
      SharedPreferences.setMockInitialValues(saved);
      final prefs = await SharedPreferences.getInstance();
      final sent = <String>[];
      final c = TmuxController(sendBytes: (b) => sent.add(utf8.decode(b)), expectMarker: false);
      addTearDown(c.dispose);
      c.onData(utf8.encode('%layout-change @1 bc62,80x24,0,0,0 bc62,80x24,0,0,0 *\n'));
      String block(int n, List<String> lines) => '%begin 1 $n 1\n${lines.map((l) => '$l\n').join()}%end 1 $n 1\n';
      c.onData(utf8.encode(block(1, ['%0 80 24 2 0 0 0 0 0 0 0 23 1 0 0 0 1 0 0 0 0 0 0 1 @1 bash'])));
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      c.onData(utf8.encode(block(2, [r'$ '])));
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: TmuxWorkspace(controller: c)),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(milliseconds: 200));
      return sent;
    }

    String hex(String text) => utf8.encode(text).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    Iterable<String> keysOf(List<String> sent) => sent.map((s) => s.trim()).where((s) => s.startsWith('send-keys'));

    testWidgets('on an iPad Cmd+V pastes into the pane, asked about where it looks dangerous (it did nothing); '
        "Ctrl+A is the shell's", (tester) async {
      final sent = await pumpTmux(tester, TargetPlatform.iOS);
      await pasteBy(tester, cmd, _safe);
      expect(keysOf(sent).any((k) => k.endsWith(hex(_safe))), isTrue, reason: '$sent');
      sent.clear();
      await pasteBy(tester, cmd, _dangerous, answer: l10n.cancel);
      expect(keysOf(sent), isEmpty);
      await chord(tester, ctrl, LogicalKeyboardKey.keyA);
      expect(keysOf(sent).single, endsWith('-H 01'));
      await finish(tester);
    });

    testWidgets('on a computer, with Paste at Shift+Insert in Settings, Shift+Insert pastes into the pane',
        (tester) async {
      final sent = await pumpTmux(tester, TargetPlatform.windows, saved: rebound);
      clipboard = _safe;
      await chord(tester, shift, LogicalKeyboardKey.insert);
      await settle(tester);
      expect(keysOf(sent).any((k) => k.endsWith(hex(_safe))), isTrue, reason: '$sent');
      await finish(tester);
    });

    testWidgets('on Android Ctrl+Shift+V pastes into the pane, asked about where it looks dangerous', (tester) async {
      final sent = await pumpTmux(tester, TargetPlatform.android);
      await pasteBy(tester, ctrlShift, _dangerous, answer: l10n.dangerPasteAnyway);
      expect(keysOf(sent).any((k) => k.endsWith(hex(_dangerous))), isTrue, reason: '$sent');
      await finish(tester);
    });
  });

  group("a live view of another's session", () {
    late IncomingShare share;

    setUpAll(() async {
      share = await incomingShare(
          shareId: '11111111-1111-4111-8111-0000000000a1',
          mode: ShareMode.live,
          from: await AccountKeys.generate(),
          to: await AccountKeys.generate());
    });

    tearDown(ShareViews.reset);

    /// The live view on Windows, watching, the keyboard [ours] or not; and
    /// what was typed into it.
    Future<(FakeView, List<String>)> pumpView(WidgetTester tester,
        {required bool ours, Map<String, Object> saved = const {}}) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      mockClipboard(tester);
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(saved);
      final prefs = await SharedPreferences.getInstance();
      final view = FakeView();
      view.terminal.resize(60, 12);
      final typed = <String>[];
      view.terminal.onOutput = typed.add;
      ShareViews.add(share, view);
      view.show(ShareViewPhase.watching, keyboard: ours ? ShareKeyboard.you : ShareKeyboard.host);
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: ShareViewScreen(shareId: share.shareId, onLeave: () {}),
        ),
      ));
      await settle(tester);
      await tester.tap(find.byType(TerminalView));
      await settle(tester);
      return (view, typed);
    }

    testWidgets("on Windows, the keyboard handed over: Ctrl+A is the shell's (it was select all), Ctrl+Shift+V "
        'pastes, asked about where it looks dangerous', (tester) async {
      final (_, typed) = await pumpView(tester, ours: true);
      await chord(tester, ctrl, LogicalKeyboardKey.keyA);
      expect(typed, ['\x01']);
      typed.clear();
      await pasteBy(tester, ctrlShift, _dangerous, answer: l10n.dangerPasteAnyway);
      expect(typed.join(), _dangerous);
      await finish(tester);
    });

    testWidgets('with Paste at Shift+Insert in Settings, the keyboard handed over, Shift+Insert pastes',
        (tester) async {
      final (_, typed) = await pumpView(tester, ours: true, saved: rebound);
      clipboard = _safe;
      await chord(tester, shift, LogicalKeyboardKey.insert);
      await settle(tester);
      expect(typed.join(), _safe);
      await finish(tester);
    });

    testWidgets('only watching, a paste by keys asks nothing and pastes nothing', (tester) async {
      final (_, typed) = await pumpView(tester, ours: false);
      await pasteBy(tester, ctrlShift, _dangerous);
      expect(typed, isEmpty);
      await finish(tester);
    });
  });
}
