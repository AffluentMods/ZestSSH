import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/shortcuts/default_bindings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/features/terminal/terminal_dictation.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pane_keys_row.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart' show debugTopSnackBarOnPhone;
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../../a11y/a11y_checks.dart';

/// Speech to text on a computer (4.0, platform parity gap 10): the phone's
/// mic, in the session header, by Ctrl+Shift+Space and in the palette, and in
/// the keys row of a tablet's large screen. What is said is typed at the
/// prompt with its control characters taken out and never an Enter; only
/// where something listens (not on Linux); Squeezed's, as on the phone.
/// Names and addresses here are made up.

/// A recogniser that hears what a test says.
class _Engine implements DictationEngine {
  bool ready = true;
  bool listenFails = false;
  int stops = 0;
  void Function(String status)? status;
  void Function(String words, bool isFinal)? words;

  @override
  Future<bool> initialize(
      {required void Function(String status) onStatus, required void Function(String error) onError}) async {
    status = onStatus;
    return ready;
  }

  @override
  Future<void> listen({required void Function(String words, bool isFinal) onWords}) async {
    if (listenFails) throw PlatformException(code: 'onDeviceError');
    words = onWords;
  }

  @override
  Future<void> stop() async => stops++;

  void say(String what, {bool done = true}) => words!(what, done);
}

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void set(Map<String, SessionState> s) => state = s;
}

class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SessionState _state(String id, Terminal terminal) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-$id',
      connectionLabel: 'web-01',
      host: '10.50.0.21',
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: 'c-$id',
        terminal: terminal,
        shell: _Shell(),
        startedAt: DateTime(2026, 11, 14, 9),
      ),
    );

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  late _Engine engine;
  late Terminal terminal;
  late List<String> typed;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    engine = _Engine();
    terminal = Terminal();
    typed = [];
    terminal.onOutput = typed.add;
  });

  List<Override> overrides({bool pro = true, bool voice = true}) => [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(_Sessions.new),
        dictationEngineProvider.overrideWithValue(engine),
        voiceInputSupportedProvider.overrideWithValue(voice),
        isProProvider.overrideWith((ref) => _Pro(pro)),
      ];

  ProviderContainer container() {
    final c = ProviderContainer(overrides: overrides());
    addTearDown(c.dispose);
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({'s1': _state('s1', terminal)});
    return c;
  }

  group('what is heard', () {
    test('what was said is typed at the prompt, with no Enter; what is heard on the way is not', () async {
      final c = container();
      expect(await c.read(dictationProvider.notifier).toggle('s1'), DictationOutcome.started);
      expect(c.read(dictationProvider).listening, isTrue);
      expect(c.read(dictationProvider).sessionId, 's1');
      engine.say('git sta', done: false);
      expect(typed, isEmpty);
      engine.say('git status');
      expect(typed.join(), 'git status');
      expect(typed.join(), isNot(contains('\r')));
      expect(typed.join(), isNot(contains('\n')));
    });

    test('a second phrase goes after a space, and control characters never reach the shell', () async {
      final c = container();
      await c.read(dictationProvider.notifier).toggle('s1');
      engine.say('ls\r\n');
      engine.say('-la\x1b[2J\x07');
      expect(typed.join(), 'ls -la[2J');
      expect(typed.join().codeUnits.where((u) => u < 0x20 || u == 0x7f), isEmpty);
    });

    test('pressed again it stops, the recogniser with it, and nothing more is typed', () async {
      final c = container();
      final dictation = c.read(dictationProvider.notifier);
      await dictation.toggle('s1');
      final heard = engine.words!;
      expect(await dictation.toggle('s1'), DictationOutcome.stopped);
      expect(c.read(dictationProvider).listening, isFalse);
      expect(engine.stops, 1);
      heard('rm -rf build', true);
      expect(typed, isEmpty);
    });

    test('the recogniser ending by itself ends the listening', () async {
      final c = container();
      await c.read(dictationProvider.notifier).toggle('s1');
      engine.status!('done');
      expect(c.read(dictationProvider).listening, isFalse);
      // Started again, it listens again (the plugin's listeners are this
      // listening's).
      expect(await c.read(dictationProvider.notifier).toggle('s1'), DictationOutcome.started);
      engine.status!('notListening');
      expect(c.read(dictationProvider).listening, isFalse);
    });

    test('no recogniser, or none on the device: not available, and never listening', () async {
      final c = container();
      engine.ready = false;
      expect(await c.read(dictationProvider.notifier).toggle('s1'), DictationOutcome.unavailable);
      expect(c.read(dictationProvider).listening, isFalse);
      engine
        ..ready = true
        ..listenFails = true;
      expect(await c.read(dictationProvider.notifier).toggle('s1'), DictationOutcome.unavailable);
      expect(c.read(dictationProvider).listening, isFalse);
    });

    test('no terminal to type into: said, and nothing listens', () async {
      final c = container();
      expect(await c.read(dictationProvider.notifier).toggle('gone'), DictationOutcome.noTerminal);
      expect(engine.words, isNull);
    });

    test('its session ending stops it', () async {
      final c = container();
      await c.read(dictationProvider.notifier).toggle('s1');
      (c.read(activeSessionsProvider.notifier) as _Sessions).set({});
      await Future<void>.delayed(Duration.zero);
      expect(c.read(dictationProvider).listening, isFalse);
      expect(engine.stops, 1);
    });
  });

  group('its key', () {
    test('Ctrl+Shift+Space unless changed, a terminal action', () {
      expect(defaultShortcutBindings[ShortcutAction.dictate],
          ShortcutKey(keyId: LogicalKeyboardKey.space.keyId, ctrl: true, shift: true));
      expect(ShortcutAction.dictate.category, ShortcutCategory.terminal);
    });

    test('where nothing listens (Linux) it is not offered among the shortcuts', () {
      expect(shortcutActionsOffered(voice: true), contains(ShortcutAction.dictate));
      expect(shortcutActionsOffered(voice: false), isNot(contains(ShortcutAction.dictate)));
      expect(shortcutActionsOffered(voice: false).length, ShortcutAction.values.length - 1);
    });
  });

  group("the session header's button", () {
    Future<ProviderContainer> pump(WidgetTester tester, {bool pro = true, bool voice = true}) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: overrides(pro: pro, voice: voice));
      addTearDown(c.dispose);
      final state = _state('s1', terminal);
      (c.read(activeSessionsProvider.notifier) as _Sessions).set({'s1': state});
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: DictationAnnouncer(
              child: SessionHeaderBar(
                sessionId: 's1',
                sessionState: state,
                onToggleSftp: (_) {},
                onApplyLayout: (_) {},
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      return c;
    }

    final mic = find.byKey(const ValueKey('session-header-dictate'));

    testWidgets('named, a toggle, and said when it starts and stops listening', (tester) async {
      final handle = tester.ensureSemantics();
      final c = await pump(tester);
      expect(mic, findsOneWidget);
      expect(find.byTooltip('${en.softKbMicStart} (Ctrl+Shift+Space)'), findsOneWidget);
      expect(
          tester.getSemantics(find.bySemanticsLabel(en.softKbMicStart)),
          // (Its key is in its tooltip, for a mouse.)
          matchesSemantics(
              label: en.softKbMicStart,
              isButton: true,
              hasToggledState: true,
              isToggled: false,
              isFocusable: true,
              hasTapAction: true,
              hasFocusAction: true,
              hasEnabledState: true,
              isEnabled: true));
      tester.takeAnnouncements();
      await tester.tap(mic);
      await tester.pump();
      expect(c.read(dictationProvider).listening, isTrue);
      expect([for (final a in tester.takeAnnouncements()) a.message], [en.dictationAnnounceListening]);
      expect(find.byTooltip('${en.softKbMicStop} (Ctrl+Shift+Space)'), findsOneWidget);
      expect(tester.getSemantics(find.bySemanticsLabel(en.softKbMicStop)),
          matchesSemantics(
              label: en.softKbMicStop,
              isButton: true,
              hasToggledState: true,
              isToggled: true,
              isFocusable: true,
              hasTapAction: true,
              hasFocusAction: true,
              hasEnabledState: true,
              isEnabled: true));
      engine.say('uptime');
      expect(typed.join(), 'uptime');
      await tester.tap(mic);
      await tester.pump();
      expect(c.read(dictationProvider).listening, isFalse);
      expect([for (final a in tester.takeAnnouncements()) a.message], [en.dictationAnnounceStopped]);
      handle.dispose();
    });

    testWidgets('reached by Tab and pressed with Enter', (tester) async {
      final c = await pump(tester);
      bool focused() => Focus.of(tester.element(find.descendant(of: mic, matching: find.byType(Icon)))).hasFocus;
      for (var i = 0; i < 20 && !focused(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focused(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(c.read(dictationProvider).listening, isTrue);
    });

    testWidgets('where nothing listens (Linux) there is no button', (tester) async {
      await pump(tester, voice: false);
      expect(mic, findsNothing);
      expect(find.byTooltip('${en.softKbMicStart} (Ctrl+Shift+Space)'), findsNothing);
    });

    testWidgets('without Squeezed it asks first, as the phone does, and nothing listens', (tester) async {
      final c = await pump(tester, pro: false);
      await tester.tap(mic);
      await tester.pumpAndSettle();
      expect(find.text(en.terminalProGateMsg(en.terminalSpeechToText)), findsOneWidget);
      expect(engine.words, isNull);
      await tester.tap(find.text(en.notNow));
      await tester.pumpAndSettle();
      expect(c.read(dictationProvider).listening, isFalse);
    });

    testWidgets('no recogniser: why, and where that is changed, on Windows', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      debugTopSnackBarOnPhone = true;
      try {
        engine.ready = false;
        await pump(tester);
        await tester.tap(mic);
        await tester.pump();
        expect(find.text(en.dictationUnavailableWindows), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 1));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        debugTopSnackBarOnPhone = null;
      }
    });

    testWidgets('the accessibility guards on a computer: named, 32 square, readable, off and listening', (tester) async {
      final handle = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pump(tester);
        final failures = [
          for (final f in await a11yCheck(tester, computer: true, where: 'off'))
            if (f.contains(en.softKbMicStart)) f,
        ];
        await tester.tap(mic);
        await tester.pump();
        failures.addAll([
          for (final f in await a11yCheck(tester, computer: true, where: 'listening'))
            if (f.contains(en.softKbMicStop)) f,
        ]);
        expect(failures, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        handle.dispose();
      }
    });
  });

  group("a tablet's keys row in the computer's shell", () {
    Future<ProviderContainer> pump(WidgetTester tester, {bool voice = true}) async {
      // Portrait: the row's medium keys, 44 across and 48 down with their gap.
      tester.view.physicalSize = const Size(800, 1280);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: overrides(voice: voice));
      addTearDown(c.dispose);
      final state = _state('s1', terminal);
      (c.read(activeSessionsProvider.notifier) as _Sessions).set({'s1': state});
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: PaneKeysRow(sessionId: 's1', sessionState: state, terminal: terminal, onShowKeyboard: () {}),
            ),
          ),
        ),
      ));
      await tester.pump();
      return c;
    }

    testWidgets('has the mic, which listens for its terminal; a phone sized target, named', (tester) async {
      final handle = tester.ensureSemantics();
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final c = await pump(tester);
        final start = find.bySemanticsLabel(en.softKbMicStart);
        expect(start, findsOneWidget);
        // The row's own targets, as the phone's row is held to them
        // (test/a11y/terminal_area_a11y_test.dart), and a name for each.
        await expectLater(
            tester,
            meetsGuideline(const MinimumTapTargetGuideline(
                size: Size(44, 48), link: 'https://support.google.com/accessibility/android/answer/7101858')));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        expect(a11yFailures(tester, computer: false), isEmpty);
        await tester.tap(start);
        await tester.pump();
        expect(c.read(dictationProvider).sessionId, 's1');
        expect(find.bySemanticsLabel(en.softKbMicStop), findsOneWidget);
        engine.say('df -h');
        expect(typed.join(), 'df -h');
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
        handle.dispose();
      }
    });

    testWidgets('where nothing listens, no mic', (tester) async {
      debugTouchLayout = true;
      try {
        await pump(tester, voice: false);
        expect(find.bySemanticsLabel(en.softKbMicStart), findsNothing);
      } finally {
        debugTouchLayout = null;
      }
    });
  });

  test('speech to text is offered where speech_to_text has a recogniser: not on Linux', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // (Windows, macOS, Android and iOS have one; this host is one of the four,
    // or Linux.)
    expect(c.read(voiceInputSupportedProvider), !Platform.isLinux);
  });
}
