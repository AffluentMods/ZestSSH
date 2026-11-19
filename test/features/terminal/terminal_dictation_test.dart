import 'dart:io' show Platform;

import 'package:fake_async/fake_async.dart';
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
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/inspector_speech_tool.dart';
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

/// A recogniser that hears what a test says, and says it listens as each
/// listen starts (as speech_to_text's platforms do).
class _Engine implements DictationEngine {
  bool ready = true;
  bool listenFails = false;
  bool saysListening = true;
  int listens = 0;
  int stops = 0;
  String? lang;
  void Function(String status)? status;
  void Function(String error)? error;
  void Function(String words, bool isFinal)? words;

  @override
  Future<bool> initialize(
      {required void Function(String status) onStatus, required void Function(String error) onError}) async {
    status = onStatus;
    error = onError;
    return ready;
  }

  @override
  Future<void> listen({required void Function(String words, bool isFinal) onWords}) async {
    listens++;
    if (listenFails) throw PlatformException(code: 'onDeviceError');
    words = onWords;
    if (saysListening) status!('listening');
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<String?> language() async => lang;

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

  List<Override> overrides({bool pro = true, bool voice = true, bool keepOn = true}) => [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(_Sessions.new),
        dictationEngineProvider.overrideWithValue(engine),
        voiceInputSupportedProvider.overrideWithValue(voice),
        dictationKeepsListeningProvider.overrideWithValue(keepOn),
        isProProvider.overrideWith((ref) => _Pro(pro)),
      ];

  ProviderContainer container({bool keepOn = true}) {
    final c = ProviderContainer(overrides: overrides(keepOn: keepOn));
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

    test('pressed again it stops, the recogniser with it; what it gives of what was said before is typed, '
        'and nothing after', () {
      var now = DateTime(2026, 11, 16, 9);
      dictationClock = () => now;
      addTearDown(() => dictationClock = DateTime.now);
      fakeAsync((time) {
        final c = container();
        final dictation = c.read(dictationProvider.notifier);
        dictation.toggle('s1');
        time.flushMicrotasks();
        final heard = engine.words!;
        engine.say('cd /srv');
        dictation.toggle('s1').then((o) => expect(o, DictationOutcome.stopped));
        time.flushMicrotasks();
        expect(c.read(dictationProvider).listening, isFalse);
        expect(engine.stops, 1);
        // (A Mac's recogniser gives its last phrase as it is stopped.)
        heard('make', true);
        // A guess is not typed, nor anything once the moment is over.
        heard('rm -rf', false);
        now = now.add(TerminalDictation.lastWordsWindow);
        heard('rm -rf build', true);
        time.elapse(const Duration(seconds: 30));
        expect(typed.join(), 'cd /srv make');
        expect(engine.listens, 1);
      });
    });

    test("a tablet's: the recogniser ending by itself ends the listening, as the phone's", () async {
      final c = container(keepOn: false);
      await c.read(dictationProvider.notifier).toggle('s1');
      engine.status!('done');
      expect(c.read(dictationProvider).listening, isFalse);
      // Started again, it listens again (the plugin's listeners are this
      // listening's).
      expect(await c.read(dictationProvider.notifier).toggle('s1'), DictationOutcome.started);
      engine.status!('notListening');
      expect(c.read(dictationProvider).listening, isFalse);
    });

    test("what is being heard is shown, then what was typed; and the recogniser's language", () async {
      engine.lang = 'English (United States)';
      final c = container();
      await c.read(dictationProvider.notifier).toggle('s1');
      await Future<void>.delayed(Duration.zero);
      expect(c.read(dictationProvider).language, 'English (United States)');
      engine.say('sudo sys', done: false);
      expect(c.read(dictationProvider).hearing, 'sudo sys');
      expect(typed, isEmpty);
      engine.say('sudo systemctl status nginx');
      expect(c.read(dictationProvider).hearing, isEmpty);
      expect(c.read(dictationProvider).lastTyped, 'sudo systemctl status nginx');
      await c.read(dictationProvider.notifier).stop();
      // (The language stays known.)
      expect(c.read(dictationProvider).language, 'English (United States)');
      expect(c.read(dictationProvider).lastTyped, isEmpty);
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

  group('on a computer it listens until it is turned off', () {
    // A recogniser that ends after each word, as a Mac's does after a pause
    // (its final words, then done), or after a silence (no match, then
    // done): the person still has it on.
    late DateTime now;

    setUp(() {
      now = DateTime(2026, 11, 16, 9);
      dictationClock = () => now;
    });
    tearDown(() => dictationClock = DateTime.now);

    /// [time] and the clock moved on together.
    void elapse(FakeAsync time, Duration d) {
      now = now.add(d);
      time.elapse(d);
    }

    test('a recogniser that ends after one word: listening goes on, and every word is typed once', () {
      fakeAsync((time) {
        final c = container();
        c.read(dictationProvider.notifier).toggle('s1');
        time.flushMicrotasks();
        for (final word in ['git', 'log', '--oneline']) {
          elapse(time, const Duration(seconds: 2));
          engine.say(word);
          engine.status!('notListening');
          engine.status!('done');
          elapse(time, const Duration(milliseconds: 200));
          expect(c.read(dictationProvider).listening, isTrue);
        }
        expect(typed.join(), 'git log --oneline');
        expect(engine.listens, 4);
        expect(engine.stops, 0);
      });
    });

    test('a silence (nothing heard, then done) starts it again, as often as it comes', () {
      fakeAsync((time) {
        final c = container();
        c.read(dictationProvider.notifier).toggle('s1');
        time.flushMicrotasks();
        for (var i = 0; i < 12; i++) {
          elapse(time, const Duration(seconds: 5));
          engine.error!('error_no_match');
          engine.status!('done');
          elapse(time, const Duration(milliseconds: 200));
        }
        expect(c.read(dictationProvider).listening, isTrue);
        expect(engine.listens, 13);
        expect(c.read(dictationProvider).gaveUp, 0);
      });
    });

    test('one end of a listening said more than once (done, an error, done) starts one listening', () {
      fakeAsync((time) {
        final c = container();
        c.read(dictationProvider.notifier).toggle('s1');
        time.flushMicrotasks();
        elapse(time, const Duration(seconds: 3));
        engine.status!('done');
        engine.error!('error_speech_timeout');
        engine.status!('done');
        elapse(time, const Duration(seconds: 1));
        expect(engine.listens, 2);
        expect(c.read(dictationProvider).listening, isTrue);
      });
    });

    test('a recogniser that ends as soon as it starts, with nothing heard: no loop; it stops and says so once', () {
      fakeAsync((time) {
        final c = container();
        c.read(dictationProvider.notifier).toggle('s1');
        time.flushMicrotasks();
        for (var i = 0; i < 20 && c.read(dictationProvider).listening; i++) {
          engine.status!('done');
          elapse(time, const Duration(seconds: 5));
        }
        expect(c.read(dictationProvider).listening, isFalse);
        expect(c.read(dictationProvider).gaveUp, 1);
        expect(engine.listens, TerminalDictation.quickEndsToGiveUp);
        elapse(time, const Duration(minutes: 1));
        expect(engine.listens, TerminalDictation.quickEndsToGiveUp);
        expect(c.read(dictationProvider).gaveUp, 1);
      });
    });

    test('the microphone or speech recognition no longer allowed: it stops at once and says so once', () {
      fakeAsync((time) {
        final c = container();
        c.read(dictationProvider.notifier).toggle('s1');
        time.flushMicrotasks();
        elapse(time, const Duration(seconds: 3));
        engine.error!('error_speech_recognizer_request_not_authorized');
        engine.status!('done');
        elapse(time, const Duration(minutes: 1));
        expect(c.read(dictationProvider).listening, isFalse);
        expect(c.read(dictationProvider).gaveUp, 1);
        expect(engine.listens, 1);
        expect(engine.stops, 1);
      });
    });

    test('a listen that never says it listens is tried again, and after the third it stops', () {
      fakeAsync((time) {
        engine.saysListening = false;
        final c = container();
        c.read(dictationProvider.notifier).toggle('s1');
        time.flushMicrotasks();
        elapse(time, const Duration(minutes: 2));
        expect(c.read(dictationProvider).listening, isFalse);
        expect(c.read(dictationProvider).gaveUp, 1);
        expect(engine.listens, TerminalDictation.failedStartsToGiveUp);
      });
    });

    test('a listen that throws when started again is tried again, and after the third it stops', () {
      fakeAsync((time) {
        final c = container();
        c.read(dictationProvider.notifier).toggle('s1');
        time.flushMicrotasks();
        engine.listenFails = true;
        elapse(time, const Duration(seconds: 3));
        engine.status!('done');
        elapse(time, const Duration(minutes: 1));
        expect(c.read(dictationProvider).listening, isFalse);
        expect(c.read(dictationProvider).gaveUp, 1);
        expect(engine.listens, 1 + TerminalDictation.failedStartsToGiveUp);
      });
    });

    test('turned off while a new listening waits to start: none starts', () {
      fakeAsync((time) {
        final c = container();
        c.read(dictationProvider.notifier).toggle('s1');
        time.flushMicrotasks();
        elapse(time, const Duration(seconds: 3));
        engine.status!('done');
        c.read(dictationProvider.notifier).stop();
        elapse(time, const Duration(minutes: 1));
        expect(engine.listens, 1);
        expect(c.read(dictationProvider).listening, isFalse);
        expect(c.read(dictationProvider).gaveUp, 0);
      });
    });

    test('its session ending while it waits to start again: none starts', () {
      fakeAsync((time) {
        final c = container();
        c.read(dictationProvider.notifier).toggle('s1');
        time.flushMicrotasks();
        elapse(time, const Duration(seconds: 3));
        engine.status!('done');
        (c.read(activeSessionsProvider.notifier) as _Sessions).set({});
        elapse(time, const Duration(minutes: 1));
        expect(engine.listens, 1);
        expect(c.read(dictationProvider).listening, isFalse);
      });
    });

    test('never an Enter, whatever the recogniser hears, across listenings', () {
      fakeAsync((time) {
        final c = container();
        c.read(dictationProvider.notifier).toggle('s1');
        time.flushMicrotasks();
        engine.say('reboot\r');
        engine.status!('done');
        elapse(time, const Duration(milliseconds: 200));
        engine.say('now\n');
        expect(typed.join(), 'reboot now');
        expect(c.read(dictationProvider).listening, isTrue);
      });
    });
  });

  group('what stops it', () {
    test('its session no longer shown in the tab in front; SFTP beside it is not its terminal', () {
      final tab = WorkTab(
        paneTree: PaneSplit(
          first: PaneLeaf.single(sessionId: 's1'),
          second: PaneLeaf.single(sessionId: 's2', type: 'sftp'),
          axis: Axis.horizontal,
        ),
      );
      expect(dictationSessionShown(tab, 's1'), isTrue);
      expect(dictationSessionShown(tab, 's2'), isFalse);
      expect(dictationSessionShown(null, 's1'), isFalse);
      // A pane showing another of its sessions.
      expect(dictationSessionShown(WorkTab(paneTree: PaneLeaf(sessionIds: ['s1', 's3'], activeIndex: 1)), 's1'),
          isFalse);
    });

    test('what says the recogniser cannot listen at all, and what only ends one listening', () {
      for (final e in [
        'error_permission',
        'error_audio_error',
        'error_speech_recognizer_request_not_authorized',
        'error_assets_not_installed',
      ]) {
        expect(dictationCannotListen(e), isTrue, reason: e);
      }
      for (final e in ['error_no_match', 'error_speech_timeout', 'error_retry', 'error_busy', 'error_unknown (1107)']) {
        expect(dictationCannotListen(e), isFalse, reason: e);
      }
    });
  });

  group("the Inspector's Speech to text", () {
    Future<ProviderContainer> pump(WidgetTester tester, {bool pro = true}) async {
      tester.view.physicalSize = const Size(340, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: overrides(pro: pro));
      addTearDown(c.dispose);
      (c.read(activeSessionsProvider.notifier) as _Sessions)
          .set({'s1': _state('s1', terminal), 's2': _state('s2', Terminal())});
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: DictationAnnouncer(child: InspectorSpeechTool(sessionId: 's1')),
            ),
          ),
        ),
      ));
      await tester.pump();
      return c;
    }

    final toggle = find.byKey(const ValueKey('inspector-speech-toggle'));

    testWidgets('off: what it does, the language, and that it is heard on this computer only', (tester) async {
      await pump(tester);
      expect(find.text(en.inspectorSpeechOff), findsOneWidget);
      expect(find.text(en.inspectorSpeechStart), findsOneWidget);
      expect(find.byTooltip('${en.inspectorSpeechStart} (Ctrl+Shift+Space)'), findsOneWidget);
      expect(find.text(en.inspectorSpeechHint), findsOneWidget);
      expect(find.text(en.inspectorSpeechLanguageSystem), findsOneWidget);
      expect(find.text(en.inspectorSpeechPrivacy), findsOneWidget);
    });

    testWidgets('Start listens for this session; what is heard shows, then what was typed; Stop stops',
        (tester) async {
      engine.lang = 'English (United Kingdom)';
      final c = await pump(tester);
      await tester.tap(toggle);
      await tester.pump();
      expect(c.read(dictationProvider).listening, isTrue);
      expect(c.read(dictationProvider).sessionId, 's1');
      expect(find.text(en.inspectorSpeechListening), findsOneWidget);
      expect(find.text(en.inspectorSpeechWaiting), findsOneWidget);
      expect(find.text(en.inspectorSpeechLanguage('English (United Kingdom)')), findsOneWidget);
      engine.say('journalctl', done: false);
      await tester.pump();
      expect(find.text(en.inspectorSpeechHearing('journalctl')), findsOneWidget);
      engine.say('journalctl -f');
      await tester.pump();
      expect(find.text(en.inspectorSpeechTyped('journalctl -f')), findsOneWidget);
      expect(typed.join(), 'journalctl -f');
      await tester.tap(find.text(en.inspectorSpeechStop));
      await tester.pump();
      expect(c.read(dictationProvider).listening, isFalse);
      expect(find.text(en.inspectorSpeechOff), findsOneWidget);
    });

    testWidgets('listening for another session: said, and Stop stops it', (tester) async {
      final c = await pump(tester);
      await c.read(dictationProvider.notifier).toggle('s2');
      await tester.pump();
      expect(find.text(en.inspectorSpeechListening), findsOneWidget);
      expect(find.text(en.inspectorSpeechListeningElsewhere), findsOneWidget);
      expect(find.byKey(const ValueKey('inspector-speech-heard')), findsNothing);
      expect(find.text(en.inspectorSpeechHint), findsNothing);
      await tester.tap(toggle);
      await tester.pump();
      expect(c.read(dictationProvider).listening, isFalse);
    });

    testWidgets('without Squeezed it asks first, and nothing listens', (tester) async {
      final c = await pump(tester, pro: false);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text(en.terminalProGateMsg(en.terminalSpeechToText)), findsOneWidget);
      expect(engine.listens, 0);
      await tester.tap(find.text(en.notNow));
      await tester.pumpAndSettle();
      expect(c.read(dictationProvider).listening, isFalse);
    });

    testWidgets('the recogniser unable to go on: it stops, and why is said once', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      debugTopSnackBarOnPhone = true;
      try {
        final c = await pump(tester);
        await tester.tap(toggle);
        await tester.pump();
        engine.error!('error_audio_error');
        await tester.pump();
        expect(c.read(dictationProvider).listening, isFalse);
        expect(find.text(en.dictationUnavailableWindows), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 1));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        debugTopSnackBarOnPhone = null;
      }
    });

    testWidgets('the accessibility guards: named, readable, off and listening', (tester) async {
      final handle = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pump(tester);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        final failures = await a11yCheck(tester, computer: true, where: 'off');
        await tester.tap(toggle);
        await tester.pump();
        engine.say('ls', done: false);
        // (Once the button has turned from Start's fill to Stop's.)
        await tester.pump(const Duration(milliseconds: 300));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        failures.addAll(await a11yCheck(tester, computer: true, where: 'listening'));
        expect(failures, isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        handle.dispose();
      }
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
              child: Column(
                children: [
                  SessionHeaderBar(
                    sessionId: 's1',
                    sessionState: state,
                    onToggleSftp: (_) {},
                    onApplyLayout: (_) {},
                  ),
                  // Where it is started from: the Inspector's Tools tab.
                  const InspectorSpeechTool(sessionId: 's1'),
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      return c;
    }

    final mic = find.byKey(const ValueKey('session-header-dictate'));
    final start = find.byKey(const ValueKey('inspector-speech-toggle'));

    testWidgets('only while it listens: named, a toggle, said when it starts and stops, and gone once stopped',
        (tester) async {
      final handle = tester.ensureSemantics();
      final c = await pump(tester);
      // Not listening: no microphone in the header (it is started from the Inspector).
      expect(mic, findsNothing);
      expect(find.byTooltip('${en.softKbMicStart} (Ctrl+Shift+Space)'), findsNothing);
      tester.takeAnnouncements();
      await tester.tap(start);
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
      expect(mic, findsNothing);
      handle.dispose();
    });

    testWidgets('while it listens, reached by Tab and pressed with Enter to stop it', (tester) async {
      final c = await pump(tester);
      await tester.tap(start);
      await tester.pump();
      expect(c.read(dictationProvider).listening, isTrue);
      bool focused() => Focus.of(tester.element(find.descendant(of: mic, matching: find.byType(Icon)))).hasFocus;
      for (var i = 0; i < 20 && !focused(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(focused(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(c.read(dictationProvider).listening, isFalse);
    });

    testWidgets('where nothing listens (Linux) there is no button', (tester) async {
      await pump(tester, voice: false);
      expect(mic, findsNothing);
      expect(find.byTooltip('${en.softKbMicStart} (Ctrl+Shift+Space)'), findsNothing);
    });

    testWidgets('without Squeezed it asks first, as the phone does, and nothing listens', (tester) async {
      final c = await pump(tester, pro: false);
      await tester.tap(start);
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
        await tester.tap(start);
        await tester.pump();
        expect(find.text(en.dictationUnavailableWindows), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 1));
      } finally {
        debugDefaultTargetPlatformOverride = null;
        debugTopSnackBarOnPhone = null;
      }
    });

    testWidgets('the accessibility guards on a computer: named, 32 square, readable, while listening', (tester) async {
      final handle = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pump(tester);
        await tester.tap(start);
        await tester.pump();
        final failures = [
          for (final f in await a11yCheck(tester, computer: true, where: 'listening'))
            if (f.contains(en.softKbMicStop)) f,
        ];
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
