import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/terminal/hardware_keyboard_use.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';
import 'package:zestssh/ui/screens/tmux/tmux_session_view.dart';
import 'package:zestssh/utils/platform_utils.dart';

import 'sharing_ui_fakes.dart';

// tmux on a phone: what is typed reaches the pane in front. With tmux on a
// phone, the connection opened but the keyboard did not
// work at all. The row of keys, its Show keyboard key, snippets and
// voice went to the session's own shell, hidden behind tmux; the panes took
// the on-screen keyboard otherwise than the session's terminal does.

/// A tmux host attached to [controller], as a session's screen shows it.
class _Host extends ChangeNotifier implements TmuxSessionHost {
  _Host(this.controller);

  @override
  final TmuxController controller;

  @override
  TmuxHostStage get stage => TmuxHostStage.attached;

  @override
  bool get active => true;

  @override
  bool get live => true;

  @override
  bool get inband => false;

  @override
  String get sessionId => 's1';

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A hardware keyboard typed on a moment ago: taps bring no on-screen
/// keyboard up, and the row (back) ends with its Show keyboard key.
class _HardwareUsed extends HardwareKeyboardUseNotifier {
  _HardwareUsed() {
    state = HardwareKeyboardUse(lastKeyAt: DateTime.now(), rowBack: true);
  }
}

class _Health extends ConnectionHealthNotifier {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> sent;
  late List<String> shell;
  late TmuxController c;

  setUp(() {
    debugPhoneKeysRow = true;
    debugTouchLayout = true;
    sent = [];
    shell = [];
    c = TmuxController(sendBytes: (b) => sent.add(utf8.decode(b)), expectMarker: false);
    c.onData(utf8.encode('%session-changed \$0 main\n'));
    c.onData(utf8.encode('%layout-change @1 bc62,80x24,0,0,0 bc62,80x24,0,0,0 *\n'));
    c.onData(utf8.encode('%window-renamed @1 bash\n'));
  });

  tearDown(() {
    debugPhoneKeysRow = null;
    debugTouchLayout = null;
    c.dispose();
  });

  Future<void> pumpScreen(WidgetTester tester, {bool hardwareUsed = false}) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {'cursor_blink': false, 'tmux_intro_seen': true});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      tmuxHostProvider.overrideWith((ref, sessionId) => _Host(c)),
      if (hardwareUsed) hardwareKeyboardUseProvider.overrideWith((ref) => _HardwareUsed()),
    ]);
    addTearDown(container.dispose);
    final sessions = container.read(activeSessionsProvider.notifier) as FakeSessions;
    sessions.show({'s1': connectedSession('s1', 'Web s1')});
    sessions.state['s1']!.session!.terminal.onOutput = shell.add;
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
    expect(find.byType(TmuxSessionView), findsOneWidget);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
  }

  Finder paneView() => find.byWidgetPredicate(
      (w) => w is TerminalView && identical(w.terminal, c.activeWindow!.activePane!.terminal));

  /// What was sent to tmux for the pane %0, as the bytes typed.
  List<String> keysTo0() => [
        for (final s in sent)
          for (final m in RegExp(r'send-keys -t %0 -H ([0-9a-f ]+)').allMatches(s)) m.group(1)!.trim(),
      ];

  int shown(WidgetTester tester) => tester.testTextInput.log.where((m) => m.method == 'TextInput.show').length;

  testWidgets('a tap on the pane brings the keyboard up, and what it types goes to the pane, none of it to the '
      'shell behind tmux', (tester) async {
    await pumpScreen(tester);
    expect(paneView(), findsOneWidget);
    expect(tester.widget<TerminalView>(paneView()).hardwareKeyboardOnly, isFalse,
        reason: "a phone's pane takes the on-screen keyboard");
    final before = shown(tester);
    // (tmux has the window at 80 columns here, wider than the phone, as it
    // keeps a window another client set larger: a tap where it shows.)
    await tester.tapAt(tester.getTopLeft(paneView()) + const Offset(60, 60), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 400));
    expect(shown(tester), greaterThan(before));
    expect(tester.widget<TerminalView>(paneView()).focusNode!.hasFocus, isTrue);

    // The keyboard types "ls" (the field starts with two spaces, so that a
    // deletion with nothing typed is seen), then deletes one.
    tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: '  ls', selection: TextSelection.collapsed(offset: 4)));
    await tester.pump();
    tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: ' ', selection: TextSelection.collapsed(offset: 1)));
    await tester.pump();
    expect(keysTo0(), ['6c 73', '7f']);
    expect(shell, isEmpty);
    await finish(tester);
  });

  testWidgets('a key of the row goes to the pane in front, not the shell behind tmux', (tester) async {
    await pumpScreen(tester);
    expect(find.byType(TerminalSoftKeyboard), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('softkey-esc')));
    await tester.pump();
    expect(keysTo0(), ['1b']);
    expect(shell, isEmpty);
    await finish(tester);
  });

  testWidgets("with a hardware keyboard typed on, the row's Show keyboard key brings it up for the pane",
      (tester) async {
    await pumpScreen(tester, hardwareUsed: true);
    expect(tester.widget<TerminalView>(paneView()).keyboardOnTap, isFalse, reason: 'as the terminal has it');
    final before = shown(tester);
    await tester.tap(find.byKey(const ValueKey('keys-row-show-keyboard')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(shown(tester), greaterThan(before));
    expect(tester.widget<TerminalView>(paneView()).focusNode!.hasFocus, isTrue);
    tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: '  q', selection: TextSelection.collapsed(offset: 3)));
    await tester.pump();
    expect(keysTo0(), ['71']);
    expect(shell, isEmpty);
    await finish(tester);
  });
}
