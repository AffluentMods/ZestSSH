import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/desktop/screen_pane.dart';
import 'package:zestssh/features/screens/hints/screen_held_line.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/model/screen_view_size.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/features/screens/window/screen_windows.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart';
import 'package:zestssh/ui/widgets/hit_area.dart';

import '../../a11y/a11y_checks.dart';
import '../../features/screens/view/screen_view_fixture.dart';
import '../../features/screens/window/fake_window_backend.dart';

/// A remote screen's tab on a computer (4.0): its picture
/// under a slim toolbar where a terminal would be, the toolbar's and the F8
/// menu's actions on the screen, F8 never reaching the remote, paused while
/// the tab is behind another or the window is hidden, covered in recording
/// mode until shown for the session, the host's saved options applied, and
/// the terminal's own views while it connects or after it ended. The screen
/// session runs on the fake engine (FakeScreenNative).
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final screens = <String>{};

  void set(Map<String, SessionState> s) => state = s;

  @override
  bool isScreen(String sessionId) => screens.contains(sessionId);

  @override
  Set<String> get screenSessionIds => screens;
}

class _Terminal extends ShellService {
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

class _Trust implements ScreenTrust {
  @override
  Future<String?> pinned() async => null;
  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async => true;
  @override
  Future<void> remember(ScreenCertificate cert) async {}
}

class _Health extends ConnectionHealthNotifier {}

SessionState _state(String id, String label, ShellService shell) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-$id',
      connectionLabel: label,
      host: '192.0.2.30',
      port: 5900,
      session: TerminalSession(
        id: id,
        connectionId: 'c-$id',
        terminal: Terminal(),
        shell: shell,
        startedAt: DateTime(2026, 11, 8),
      ),
    );

/// Whether the node a guideline's line [failure] names (its Rect) lies inside [area].
bool _inside(String failure, Rect area) {
  final m = RegExp(r'Rect\.fromLTRB\(([-0-9.]+), ([-0-9.]+), ([-0-9.]+), ([-0-9.]+)\)').firstMatch(failure);
  if (m == null) return true;
  final r = Rect.fromLTRB(double.parse(m[1]!), double.parse(m[2]!), double.parse(m[3]!), double.parse(m[4]!));
  return area.inflate(8).overlaps(r);
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late FakeScreenNative native;

  setUp(() {
    native = FakeScreenNative();
    ScreenPane.debugDecodeTile = syncDecode;
  });
  tearDown(() => ScreenPane.debugDecodeTile = null);

  /// A screen session reached directly, connected on the fake engine.
  Future<(ScreenShellService, FakeScreenSession)> connectScreen(
    WidgetTester tester, {
    ScreenOptions options = ScreenOptions.defaults,
    ScreenProtocol protocol = ScreenProtocol.vnc,
    Map<String, Object?>? connected,
  }) async {
    final toServer = StreamController<List<int>>();
    final fromServer = StreamController<Uint8List>();
    addTearDown(() {
      unawaited(toServer.close());
      unawaited(fromServer.close());
    });
    final shell = ScreenShellService(
      target: const DirectTlsTarget('192.0.2.30', 5900),
      trust: _Trust(),
      native: native,
      options: options,
      protocol: protocol,
      openDirect: (_, _) async => ScreenChannel(fromServer.stream, toServer.sink),
    );
    final connecting = shell.connect();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      if (native.sessions.isNotEmpty) break;
    }
    final engine = native.sessions.single;
    if (connected == null) {
      engine.connect(name: 'demo-desktop', width: 800, height: 500, security: 'VeNCrypt');
    } else {
      engine.emitJson(ScreenEventKind.connected, {'width': 800, 'height': 500, ...connected});
    }
    await tester.pump();
    await connecting;
    return (shell, engine);
  }

  int seq = 0;
  void frame(FakeScreenSession engine, Color c) {
    seq++;
    engine.frames.add(ScreenFrame(seq: seq, width: 800, height: 500, updates: 1, tiles: [tile(0, 0, 800, 500, c)]));
    engine.emit(ScreenEventKind.frame, a: seq);
  }

  Future<ProviderContainer> pumpArea(
    WidgetTester tester,
    Map<String, SessionState> sessions, {
    Set<String> screens = const {'s1'},
    String front = 's1',
    bool recording = false,
    Map<String, Object> prefsValues = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      recordingModeProvider.overrideWith((ref) => recording),
    ]);
    addTearDown(c.dispose);
    final tabs = c.read(workTabsProvider.notifier);
    final notifier = c.read(activeSessionsProvider.notifier) as _Sessions;
    notifier.screens.addAll(screens);
    notifier.set(sessions);
    tabs.setActiveTab(tabs.tabContaining(front)!.id);
    c.read(v3ActiveSessionTabProvider.notifier).state = front;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
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
    await tester.pump();
    return c;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// The session panel's list, and a tap on one of its rows or buttons once it is in sight.
  Finder panelList() =>
      find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable));

  Future<void> tapInPanel(WidgetTester tester, String id) async {
    final row = find.byKey(ValueKey('screen-panel-$id'));
    await tester.scrollUntilVisible(row, 150, scrollable: panelList());
    await tester.pumpAndSettle();
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  /// The colour the picture shows at its centre, read back from the pane.
  Future<Color> centreColour(WidgetTester tester) async {
    await tester.pump();
    final view = find.byType(ScreenView);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.ancestor(of: view, matching: find.byType(RepaintBoundary)).first);
    final box = tester.renderObject<RenderBox>(view);
    final centre = boundary.globalToLocal(box.localToGlobal(box.size.center(Offset.zero)));
    late Color out;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = (await image.toByteData())!;
      final i = (centre.dy.floor() * image.width + centre.dx.floor()) * 4;
      out = Color.fromARGB(data.getUint8(i + 3), data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2));
      image.dispose();
    });
    return out;
  }

  List<(int, int, bool)> takeKeys(FakeScreenSession engine) {
    final out = List.of(engine.keys);
    engine.keys.clear();
    return out;
  }

  testWidgets('the tab shows the picture under its toolbar, with no terminal and none of its tools', (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)});
    expect(find.byType(ScreenPane), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-toolbar')), findsOneWidget);
    expect(find.byType(TerminalView), findsNothing);
    expect(find.byKey(const ValueKey('screen-waiting')), findsOneWidget);
    frame(engine, const Color(0xFFE04020));
    await settle(tester);
    expect(find.byKey(const ValueKey('screen-waiting')), findsNothing);
    expect(await centreColour(tester), isColor(const Color(0xFFE04020)));
    // The header says VNC, and has no tmux, SFTP or Inspector.
    expect(find.byKey(const ValueKey('session-screen-s1')), findsOneWidget);
    expect(find.byType(ScreenTag), findsOneWidget);
    // To a screen reader the tag is one thing, said in words.
    final handle = tester.ensureSemantics();
    expect(tester.getSemantics(find.byType(ScreenTag)).label, en.screenTagTooltip);
    handle.dispose();
    expect(find.byType(SessionTmuxButton), findsNothing);
    expect(find.byTooltip(en.sessionHeaderSftpTooltip), findsNothing);
    expect(find.byTooltip(en.sessionHeaderInspectorTooltip), findsNothing);
    // A screen through no SSH host speaks no SSH (no tmux, no SFTP).
    expect(_state('s1', 'x', shell).speaksSsh, isFalse);
    await finish(tester);
  });

  testWidgets('accessibility: the screen\'s toolbar meets the 4.0 pass (named controls a screen reader can press, a '
      'pointer\'s 32 square, contrast), for a VNC screen and an RDP host', (tester) async {
    final handle = tester.ensureSemantics();
    for (final protocol in [ScreenProtocol.vnc, ScreenProtocol.rdp]) {
      final (shell, engine) = await connectScreen(tester, protocol: protocol);
      await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)});
      frame(engine, const Color(0xFF202020));
      await settle(tester);
      // What the checks say of the toolbar itself (the session's header above it is the
      // terminal's, with its own guard).
      final toolbar = tester.getRect(find.byKey(const ValueKey('screen-toolbar')));
      final found = [
        for (final f in await a11yCheck(tester, computer: true))
          if (!f.contains('Rect.fromLTRB') || _inside(f, toolbar)) f,
      ];
      expect(found, isEmpty, reason: protocol.name);
      // Every button of it can be pressed by a screen reader, and says its name.
      for (final key in ['viewOnly', 'sendCtrlAltDel', 'refresh', 'fullScreen', 'menu', 'disconnect']) {
        // (The button's own node: its target, which is under its tooltip.)
        final node = tester.getSemantics(
            find.descendant(of: find.byKey(ValueKey('screen-toolbar-$key')), matching: find.byType(HitArea)));
        final data = node.getSemanticsData();
        expect(data.hasAction(SemanticsAction.tap), isTrue, reason: '$key has no press');
        expect(data.label, isNotEmpty, reason: key);
        expect(node.rect.width, greaterThanOrEqualTo(32), reason: key);
        expect(node.rect.height, greaterThanOrEqualTo(32), reason: key);
      }
      await finish(tester);
      native = FakeScreenNative();
    }
    handle.dispose();
  });

  testWidgets('with the keyboard alone: the menu key opens the session panel, the arrows and Enter choose from it, '
      'a switch keeps it open, Esc closes it, and the picture has the keyboard again; at 150 percent text nothing '
      'overflows', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'the pane at 150 percent');
    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    await tester.tap(find.byType(ScreenView));
    await tester.pump();
    expect(view.controller.viewOnly, isFalse);

    // The row of the panel that has the focus.
    bool inRow(String id) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) return false;
      var found = false;
      focused.visitAncestorElements((e) {
        if (e.widget.key == ValueKey('screen-panel-$id')) found = true;
        return !found;
      });
      return found;
    }

    // F8 opens the panel; Esc closes it, nothing was chosen, and the picture has the keyboard.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'the panel at 150 percent');
    expect(inRow('fit'), isTrue, reason: 'the first option has the focus');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    expect(view.controller.viewOnly, isFalse);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote screen', reason: 'back to the picture');

    // Again, and down to View only with the arrows, Enter to choose it: a switch keeps the
    // panel open, with the focus where it was.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    for (var i = 0; i < 12 && !inRow('viewOnly'); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(inRow('viewOnly'), isTrue, reason: 'the arrows reach View only');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(view.controller.viewOnly, isTrue, reason: 'View only, chosen with the arrows and Enter');
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget, reason: 'a switch keeps the panel open');
    expect(inRow('viewOnly'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    await finish(tester);
  });

  testWidgets("the toolbar's actions go to the screen", (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)});
    await settle(tester);
    final view = tester.widget<ScreenView>(find.byType(ScreenView));

    await tester.tap(find.byKey(const ValueKey('screen-toolbar-sendCtrlAltDel')));
    await tester.pump();
    expect(takeKeys(engine), [
      (0xffe3, 0x1d, true), (0xffe9, 0x38, true), (0xffff, 0xd3, true),
      (0xffff, 0xd3, false), (0xffe9, 0x38, false), (0xffe3, 0x1d, false),
    ]);

    await tester.tap(find.byKey(const ValueKey('screen-toolbar-keys')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-keys-sendAltTab')));
    await tester.pumpAndSettle();
    expect(takeKeys(engine), [(0xffe9, 0x38, true), (0xff09, 0x0f, true), (0xff09, 0x0f, false), (0xffe9, 0x38, false)]);

    await tester.tap(find.byKey(const ValueKey('screen-toolbar-refresh')));
    await tester.pump();
    expect(engine.fullRefreshes, 1);

    expect(view.controller.fit, ScreenFit.fit);
    await tester.tap(find.byKey(const ValueKey('screen-toolbar-scaling')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-menu-oneToOne')).last);
    await tester.pumpAndSettle();
    expect(view.controller.fit, ScreenFit.oneToOne);
    expect(find.text(en.connectionEditScreenScalingOneToOne), findsOneWidget);

    // View only: nothing is sent, the keys' buttons are off.
    await tester.tap(find.byKey(const ValueKey('screen-toolbar-viewOnly')));
    await tester.pump();
    expect(view.controller.viewOnly, isTrue);
    await tester.tap(find.byKey(const ValueKey('screen-toolbar-sendCtrlAltDel')));
    await tester.pump();
    expect(takeKeys(engine), isEmpty);
    await tester.tap(find.byKey(const ValueKey('screen-toolbar-viewOnly')));
    await tester.pump();
    expect(view.controller.viewOnly, isFalse);

    // The clipboard's switch (its rules in screen_clipboard_ui_test): there, and on for a host of the
    // person's own space.
    final clip = find.byKey(const ValueKey('screen-toolbar-clipboard'));
    expect(clip, findsOneWidget);
    expect(tester.widget<InkWell>(find.descendant(of: clip, matching: find.byType(InkWell))).onTap, isNotNull);
    expect(find.byTooltip(en.screenClipboardTurnOff), findsOneWidget);

    // Disconnect asks first.
    await tester.tap(find.byKey(const ValueKey('screen-toolbar-disconnect')));
    await tester.pumpAndSettle();
    expect(find.text(en.sessionInfoDisconnectConfirmBody), findsOneWidget);
    await tester.tap(find.text(en.cancel).last);
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('keys go to the remote while the picture has the focus; F8 opens the panel and never reaches it',
      (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)});
    await settle(tester);
    // The tab in front took the keyboard to its picture.
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote screen');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(takeKeys(engine).map((k) => (k.$1, k.$3)), [(0x61, true), (0x61, false)]);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);
    expect(takeKeys(engine), isEmpty, reason: 'F8 is the panel, never the remote');
    // The panel has the keyboard: what is typed now does not reach the remote.
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('remote screen'));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(takeKeys(engine), isEmpty);

    await tapInPanel(tester, 'sendMenuKey');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing, reason: 'a key sent closes the panel');
    expect(takeKeys(engine), [(0xffc5, 0x42, true), (0xffc5, 0x42, false)]);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote screen', reason: 'back to the picture');

    // Release the keyboard: the keys stay with the app.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'releaseKeyboard');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('remote screen'));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pump();
    expect(takeKeys(engine), isEmpty);
    // A click on the picture gives it the keyboard again.
    await tester.tap(find.byType(ScreenView));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote screen');
    await tester.pump(const Duration(seconds: 5));
    await finish(tester);
  });

  testWidgets('paused while its tab is behind another, or the window hidden; the whole picture when back',
      (tester) async {
    final (shell, engine) = await connectScreen(tester);
    final c = await pumpArea(tester, {
      's1': _state('s1', 'design-mac', shell),
      's2': _state('s2', 'web-01', _Terminal()),
    });
    await settle(tester);
    expect(engine.pauses, 0);
    final tabs = c.read(workTabsProvider.notifier);
    tabs.setActiveTab(tabs.tabContaining('s2')!.id);
    c.read(v3ActiveSessionTabProvider.notifier).state = 's2';
    await tester.pump();
    await tester.pump();
    expect(engine.pauses, 1);
    expect(shell.session!.isPaused, isTrue);
    tabs.setActiveTab(tabs.tabContaining('s1')!.id);
    c.read(v3ActiveSessionTabProvider.notifier).state = 's1';
    await tester.pump();
    await tester.pump();
    expect(engine.resumes, 1);
    expect(shell.session!.isPaused, isFalse);

    // The window minimized, and shown again.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(engine.pauses, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(engine.resumes, 2);
    await finish(tester);
  });

  testWidgets('recording mode covers the picture, paused, until it is shown for this session', (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)}, recording: true);
    await settle(tester);
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsOneWidget);
    expect(find.text(en.screenRecordingCovered), findsOneWidget);
    expect(engine.pauses, 1);
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('remote screen'));
    await tester.tap(find.byKey(const ValueKey('screen-recording-show')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsNothing);
    expect(engine.resumes, 1);
    frame(engine, const Color(0xFF2080E0));
    await settle(tester);
    expect(await centreColour(tester), isColor(const Color(0xFF2080E0)));
    await finish(tester);
  });

  testWidgets('Settings, Remote screens: another menu key opens the menu, F8 then reaches the remote, and the menu '
      'sends the key it is opened with', (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)}, prefsValues: {kScreenMenuKeyKey: 'f9'});
    await settle(tester);
    expect(find.byTooltip('Screen menu (F9)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();
    expect(takeKeys(engine).map((k) => (k.$1, k.$3)), [(0xffc5, true), (0xffc5, false)], reason: 'F8 is a key now');
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(takeKeys(engine), isEmpty, reason: 'F9 is the menu, never the remote');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-sendMenuKey')), 150, scrollable: panelList());
    await tester.pumpAndSettle();
    expect(find.text('Send F9'), findsOneWidget);
    await tapInPanel(tester, 'sendMenuKey');
    await tester.pumpAndSettle();
    expect(takeKeys(engine), [(0xffc6, 0x43, true), (0xffc6, 0x43, false)]);
    await tester.pump(const Duration(seconds: 5));
    await finish(tester);
  });

  testWidgets('recording mode covers the picture: the bar and the panel are still there, and no key they offer is '
      'pressed on a remote computer nobody sees', (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)}, recording: true);
    await settle(tester);
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsOneWidget);
    takeKeys(engine);
    // The bar's menu button opens the panel over the covered picture.
    await tester.tap(find.byKey(const ValueKey('screen-toolbar-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);
    // The keys to send say why they cannot be pressed.
    await tester.scrollUntilVisible(find.text(en.screenWhyNotCovered).first, 150, scrollable: panelList());
    expect(find.text(en.screenWhyNotCovered), findsWidgets);
    for (final id in const ['sendCtrlAltDel', 'sendAltTab', 'sendAltF4', 'sendMenuKey']) {
      final row = find.byKey(ValueKey('screen-panel-$id'));
      await tester.scrollUntilVisible(row, 150, scrollable: panelList());
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(takeKeys(engine), isEmpty, reason: '$id goes nowhere while the picture is covered');
      // (A key to send closes the panel: open it again for the next.)
      if (find.byKey(const ValueKey('screen-panel')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('screen-toolbar-menu')));
        await tester.pumpAndSettle();
      }
    }
    if (find.byKey(const ValueKey('screen-panel')).evaluate().isNotEmpty) {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    expect(takeKeys(engine), isEmpty);
    expect(engine.pointers.where((p) => p.$3 != 0), isEmpty, reason: 'no button is pressed on the remote either');
    // Shown for this session: the same row sends its keys again.
    await tester.tap(find.byKey(const ValueKey('screen-recording-show')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('screen-toolbar-menu')));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('screen-panel-sendCtrlAltDel'));
    await tester.scrollUntilVisible(row, 150, scrollable: panelList());
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(takeKeys(engine).where((k) => k.$3), hasLength(3));
    await finish(tester);
  });

  testWidgets('Settings, Remote screens: recording mode may show the picture', (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)},
        recording: true, prefsValues: {kScreenRecordingKey: 'show'});
    await settle(tester);
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsNothing);
    expect(engine.pauses, 0);
    await finish(tester);
  });

  testWidgets('an RDP screen whose host says "Resize the remote": the remote takes the tab\'s size, the toolbar '
      'says so, another scaling leaves the remote as it is, and a VNC screen has no such choice', (tester) async {
    ScreenViewSize.lastFollowed = null;
    final (shell, engine) = await connectScreen(tester,
        options: const ScreenOptions(scaling: ScreenScaling.remoteResize), protocol: ScreenProtocol.rdp);
    expect(engine.request['kind'], 'rdp');
    expect(engine.request.containsKey('width'), isFalse, reason: 'no view was laid out yet on this device');
    await pumpArea(tester, {'s1': _state('s1', 'office-pc', shell)});
    await settle(tester);
    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    expect(view.controller.followViewSize, isTrue);
    expect(view.controller.fit, ScreenFit.fit, reason: 'fitted until the remote has the size');
    await tester.pump(ScreenController.resizeSettle * 2);
    expect(engine.resizes, hasLength(1));
    final (w, h) = engine.resizes.single;
    final box = tester.getSize(find.byType(ScreenView));
    expect((w, h), (box.width.floor() & ~1, box.height.floor()));
    expect(ScreenViewSize.lastFollowed, box);

    // The toolbar names it, and its list has it checked.
    final scaling = find.byKey(const ValueKey('screen-toolbar-scaling'));
    final l10n = AppLocalizations.of(tester.element(scaling))!;
    expect(find.descendant(of: scaling, matching: find.text(l10n.connectionEditScreenScalingRemote)), findsOneWidget);
    await tester.tap(scaling);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-menu-remoteResize')), findsOneWidget);
    // 100 percent: the picture's scaling changes and the remote is asked nothing more.
    await tester.tap(find.byKey(const ValueKey('screen-menu-oneToOne')).last);
    await tester.pumpAndSettle();
    expect((view.controller.followViewSize, view.controller.fit), (false, ScreenFit.oneToOne));
    // Back to it: asked at once (the size is the one the remote was asked for, so only where
    // the remote has another).
    await tester.tap(scaling);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-menu-remoteResize')).last);
    await tester.pumpAndSettle();
    expect((view.controller.followViewSize, view.controller.fit), (true, ScreenFit.fit));

    // A server that takes none: the toolbar is back at Fit (and a notice says why; on a computer
    // it goes to the notification centre, which this pane's test does not show).
    engine.emitJson(ScreenEventKind.info, {'resize_unavailable': true});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(l10n.screenResizeUnavailable, isNotEmpty);
    expect(view.controller.followViewSize, isFalse);
    expect(find.descendant(of: scaling, matching: find.text(l10n.connectionEditScreenScalingFit)), findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    await finish(tester);
  });

  testWidgets("the lock says how a screen reached directly is protected: VNC's VeNCrypt for a VNC host, TLS alone "
      'for an RDP host (it named VeNCrypt for RDP too)', (tester) async {
    String lock() => tester
        .widget<Tooltip>(find.ancestor(of: find.byKey(const ValueKey('screen-toolbar-security')), matching: find.byType(Tooltip)))
        .message!;
    const tls = {'protocol': 'TLSv1.3', 'cert_sha256': 'aa'};
    for (final protocol in [ScreenProtocol.vnc, ScreenProtocol.rdp]) {
      native = FakeScreenNative();
      final (shell, _) = await connectScreen(tester, protocol: protocol, connected: {'tls': tls});
      await pumpArea(tester, {'s1': _state('s1', 'desk-01', shell)});
      await settle(tester);
      if (protocol == ScreenProtocol.vnc) {
        expect(lock(), en.screenSecurityTls);
      } else {
        expect(lock(), en.screenSecurityTlsOnly);
        expect(lock(), isNot(contains('VeNCrypt')));
      }
      await finish(tester);
    }
  });

  testWidgets('a VNC screen is not offered "Resize the remote", whatever its host says', (tester) async {
    final (shell, engine) =
        await connectScreen(tester, options: const ScreenOptions(scaling: ScreenScaling.remoteResize));
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)});
    await settle(tester);
    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    expect(view.controller.followViewSize, isFalse);
    await tester.pump(ScreenController.resizeSettle * 2);
    expect(engine.resizes, isEmpty);
    await tester.tap(find.byKey(const ValueKey('screen-toolbar-scaling')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-menu-fit')), findsWidgets);
    expect(find.byKey(const ValueKey('screen-menu-remoteResize')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets("the host's saved scaling, view only and picture quality are applied", (tester) async {
    final (shell, engine) = await connectScreen(
      tester,
      options: const ScreenOptions(scaling: ScreenScaling.oneToOne, viewOnly: true, quality: ScreenQuality.high),
    );
    final encodings = engine.request['encodings'] as List;
    expect(encodings.first, 'Tight');
    expect(encodings, contains('CompressionLevel1'));
    expect(encodings.where((e) => '$e'.startsWith('JpegQuality')), isEmpty, reason: 'High is lossless Tight');
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)});
    await settle(tester);
    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    expect(view.controller.fit, ScreenFit.oneToOne);
    expect(view.controller.viewOnly, isTrue);
    await finish(tester);
  });

  test('picture quality as the encodings asked of the server', () {
    expect(screenEncodingsFor(ScreenQuality.auto), isNull);
    expect(screenEncodingsFor(ScreenQuality.low), containsAll(['JpegQuality3', 'CompressionLevel6', 'Cursor']));
    expect(screenEncodingsFor(ScreenQuality.high), isNot(contains(startsWith('JpegQuality'))));
    expect(screenFitOf(ScreenScaling.remoteResize), ScreenFit.fit);
  });

  testWidgets("connecting, dropped and ended are the terminal's own views", (tester) async {
    const connecting = SessionState(status: SessionStatus.connecting, connectionId: 'c-s1', connectionLabel: 'design-mac');
    final c = await pumpArea(tester, {'s1': connecting});
    expect(find.byType(ScreenPane), findsNothing);
    expect(find.text(en.desktopConnectingTo('design-mac')), findsOneWidget);
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({
      's1': SessionState.disconnected(
        connectionId: 'c-s1',
        connectionLabel: 'design-mac',
        host: '192.0.2.30',
        port: 5900,
        dropped: true,
        dropCause: 'The remote screen ended the session.',
      ),
    });
    await tester.pump();
    expect(find.byType(ScreenPane), findsNothing);
    expect(find.byKey(const ValueKey('connection-lost-reconnect')), findsOneWidget);
    // The view's title is a heading for a screen reader.
    final handle = tester.ensureSemantics();
    expect(tester.getSemantics(find.text(en.connectionLostTitle)), matchesSemantics(isHeader: true, label: en.connectionLostTitle));
    handle.dispose();
    await finish(tester);
  });

  testWidgets('a remote with two displays: the bar has the segment and the strip is left of the picture; one is '
      'picked from either, the strip can be closed and stays closed; with one display there is neither',
      (tester) async {
    final (shell, engine) = await connectScreen(tester);
    final container = await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    expect(find.byKey(const ValueKey('screen-display-segment')), findsNothing, reason: 'one display');
    expect(find.byKey(const ValueKey('screen-display-strip')), findsNothing);

    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    final (w, h) = (view.controller.width, view.controller.height);
    engine
      ..emit(ScreenEventKind.resize, a: ((w * 2) << 32) | h)
      ..displays([
        [0, 0, w, h],
        [w, 0, w, h],
      ]);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-display-segment')), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-display-strip')), findsOneWidget);
    // The strip is left of the picture, and the picture has the rest.
    final strip = tester.getRect(find.byKey(const ValueKey('screen-display-strip')));
    final picture = tester.getRect(find.byType(ScreenView));
    expect(strip.right, lessThanOrEqualTo(picture.left + 0.5));

    await tester.tap(find.byKey(const ValueKey('screen-display-segment-1')));
    await tester.pump();
    expect(view.controller.displays.value.shown, 1);
    expect(engine.shown.last, (w, 0, w, h));
    await tester.tap(find.byKey(const ValueKey('screen-display-strip-0')));
    await tester.pump();
    expect(view.controller.displays.value.shown, 0);

    // Closed: it stays closed for this computer, and can be opened again.
    await tester.tap(find.byKey(const ValueKey('screen-display-strip-close')));
    await tester.pumpAndSettle();
    expect(container.read(screenDisplayStripOpenProvider), isFalse);
    expect(find.byKey(const ValueKey('screen-display-strip')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('screen-display-strip-open')));
    await tester.pumpAndSettle();
    expect(container.read(screenDisplayStripOpenProvider), isTrue);
    expect(find.byKey(const ValueKey('screen-display-strip')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('Session details: the switch of the panel shows the card over the corner of the picture and closes '
      'the panel; it is sampled only while shown, the picture keeps the keyboard, and the button of the card closes it',
      (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'design-mac', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    expect(find.byKey(const ValueKey('screen-details-card')), findsNothing);
    expect(view.controller.detailsShown, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'sessionDetails');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing, reason: 'the panel gets out of the way');
    expect(find.byKey(const ValueKey('screen-details-card')), findsOneWidget);
    expect(view.controller.detailsShown, isTrue);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote screen', reason: 'the picture has the keyboard');
    // In the picture's top end corner, inside it.
    final card = tester.getRect(find.byKey(const ValueKey('screen-details-card')));
    final picture = tester.getRect(find.byType(ScreenView));
    expect(card.top, greaterThanOrEqualTo(picture.top));
    expect(card.right, lessThanOrEqualTo(picture.right));
    expect(card.left, greaterThan(picture.center.dx));
    // A second comes in.
    await tester.pump(const Duration(seconds: 1));
    expect(view.controller.details.value.last, hasLength(1));

    // The panel shows the switch as on; picking it again takes the card away.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'sessionDetails');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-details-card')), findsNothing);
    expect(view.controller.detailsShown, isFalse);

    // And the card's own close button does the same.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'sessionDetails');
    await tester.pumpAndSettle();
    final close = find.descendant(of: find.byKey(const ValueKey('screen-details-card')), matching: find.byType(IconButton));
    await tester.tap(close.first);
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-details-card')), findsNothing);
    expect(view.controller.detailsShown, isFalse);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets("the remote's sound: played once the tab is seen, and its switch in the panel", (tester) async {
    final (shell, engine) = await connectScreen(tester,
        protocol: ScreenProtocol.rdp,
        connected: const {
          'protocol': 'rdp',
          'sound': {'rate': 48000, 'channels': 2},
        });
    expect(engine.request['rdp_sound'], 'off', reason: 'silent until the tab is seen');
    await pumpArea(tester, {'s1': _state('s1', 'office-pc', shell)});
    await settle(tester);
    expect(engine.sounds, [true], reason: 'seen: it plays');

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'sound');
    await tester.pumpAndSettle();
    expect(engine.sounds, [true, false]);
    await tapInPanel(tester, 'sound');
    await tester.pumpAndSettle();
    expect(engine.sounds, [true, false, true]);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets("the remote's sound under recording mode: nothing plays, though the switch is on, until the picture is "
      'shown for this session', (tester) async {
    final (shell2, engine2) = await connectScreen(tester,
        protocol: ScreenProtocol.rdp,
        connected: const {
          'protocol': 'rdp',
          'sound': {'rate': 48000, 'channels': 2},
        });
    await pumpArea(tester, {'s1': _state('s1', 'office-pc', shell2)}, recording: true);
    await settle(tester);
    expect(engine2.sounds.where((on) => on), isEmpty, reason: 'not under the cover');
    await tester.tap(find.byKey(const ValueKey('screen-recording-show')));
    await tester.pump();
    await tester.pump();
    expect(engine2.sounds.last, isTrue, reason: 'shown for this session: it plays');
    await finish(tester);
  });

  testWidgets("the remote's sound on a tablet in the computer's layout: not asked of the server unless its host says "
      'so, and the switch is offered only where it was', (tester) async {
    // An Android or iOS device: the remote's sound is off there by default.
    ScreenShellService.debugOnPhoneSystem = true;
    addTearDown(() => ScreenShellService.debugOnPhoneSystem = null);

    Future<bool> switchOffered() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        await tester.drag(panelList(), const Offset(0, -400));
        await tester.pumpAndSettle();
      }
      final offered = find.byKey(const ValueKey('screen-panel-sound'), skipOffstage: false).evaluate().isNotEmpty;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      return offered;
    }

    final (quiet, quietEngine) = await connectScreen(tester,
        protocol: ScreenProtocol.rdp, connected: const {'protocol': 'rdp'});
    expect(quietEngine.request.containsKey('rdp_sound'), isFalse, reason: 'no sound asked of the server');
    await pumpArea(tester, {'s1': _state('s1', 'office-pc', quiet)});
    await settle(tester);
    expect(await switchOffered(), isFalse, reason: 'no switch that says on while nothing plays');
    await finish(tester);

    // A host whose person turned its sound on: asked for, and its switch is there.
    native = FakeScreenNative();
    final (loud, loudEngine) = await connectScreen(tester,
        protocol: ScreenProtocol.rdp,
        options: const ScreenOptions().copyWith(sound: true),
        connected: const {
          'protocol': 'rdp',
          'sound': {'rate': 48000, 'channels': 2},
        });
    expect(loudEngine.request['rdp_sound'], 'off', reason: 'asked for, silent until the tab is seen');
    await pumpArea(tester, {'s1': _state('s1', 'office-pc', loud)});
    await settle(tester);
    expect(await switchOffered(), isTrue);
    await finish(tester);
  });

  testWidgets("the remote's sound where this device has no output: the switch is greyed, and says why", (tester) async {
    final (shell3, engine3) = await connectScreen(tester,
        protocol: ScreenProtocol.rdp,
        connected: const {
          'protocol': 'rdp',
          'sound': {'unavailable': 'no output device'},
        });
    await pumpArea(tester, {'s1': _state('s1', 'office-pc', shell3)});
    await settle(tester);
    expect(engine3.sounds, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-sound')), 150, scrollable: panelList());
    await tester.pumpAndSettle();
    expect(find.text(en.screenWhyNotSoundHere), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('relative mouse: the switch of the panel, a click that holds the pointer, the line that says how to get '
      'it back for as long as it is held, and the menu key that gets it back', (tester) async {
    final capture = FakeCapture();
    ScreenController.debugCapture = capture;
    addTearDown(() => ScreenController.debugCapture = null);
    final (shell, engine) = await connectScreen(tester,
        options: const ScreenOptions(relativeMouse: true),
        protocol: ScreenProtocol.rdp,
        connected: const {'protocol': 'rdp', 'relative_mouse': true});
    expect(engine.request['rdp_relative_mouse'], isTrue);
    await pumpArea(tester, {'s1': _state('s1', 'office-pc', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    expect(view.controller.relativeMouse, isFalse, reason: 'never on by itself');
    expect(find.byKey(const ValueKey('screen-pointer-held')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'relativeMouse');
    await tester.pumpAndSettle();
    expect(view.controller.relativeMouse, isTrue);
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget, reason: 'a switch keeps the panel open');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(capture.starts, 0, reason: 'the switch alone holds nothing');

    // A click in the picture holds the pointer, and the line says so.
    await tester.tap(find.byType(ScreenView), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(view.controller.hold.held, isTrue);
    expect(find.byKey(const ValueKey('screen-pointer-held')), findsOneWidget);
    expect(tester.widget<ScreenHeldLine>(find.byKey(const ValueKey('screen-pointer-held'))).text,
        'Pointer held for the remote. Press F8 to get it back.');
    expect(find.text('F8'), findsOneWidget, reason: 'the key, drawn as a key');
    // It stays: it is the one thing that says the way out.
    await tester.pump(const Duration(seconds: 30));
    expect(find.byKey(const ValueKey('screen-pointer-held')), findsOneWidget);
    capture.move(11, 4);
    await tester.pump();
    expect(engine.relativePointers.last, (11, 4, 0));

    // The menu key: the pointer back, the line gone, no panel, nothing to the remote.
    final keysBefore = engine.keys.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pump();
    expect(view.controller.hold.held, isFalse);
    expect(find.byKey(const ValueKey('screen-pointer-held')), findsNothing);
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    expect(engine.keys.length, keysBefore);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('relative mouse on a computer that cannot hold the pointer, or with a server that does not take it: the '
      'switch is there, greyed, and says why', (tester) async {
    final capture = FakeCapture()..can = false;
    ScreenController.debugCapture = capture;
    addTearDown(() => ScreenController.debugCapture = null);
    final (shell, engine) = await connectScreen(tester,
        options: const ScreenOptions(relativeMouse: true),
        protocol: ScreenProtocol.rdp,
        connected: const {'protocol': 'rdp', 'relative_mouse': false});
    await pumpArea(tester, {'s1': _state('s1', 'office-pc', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-relativeMouse')), 150, scrollable: panelList());
    await tester.pumpAndSettle();
    expect(find.text('Not available on this computer yet'), findsOneWidget);
    await tapInPanel(tester, 'relativeMouse');
    await tester.pumpAndSettle();
    expect(view.controller.relativeMouse, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    // A click is a click: nothing is held.
    await tester.tap(find.byType(ScreenView), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect((view.controller.hold.held, capture.starts), (false, 0));
    await finish(tester);
  });

  testWidgets('Text size on the remote: the entry of the panel asks for a size with the one in use picked, and the '
      'remote is told the size chosen; closed without a choice, nothing is asked', (tester) async {
    final (shell, engine) = await connectScreen(tester,
        options: const ScreenOptions(textScale: 125),
        protocol: ScreenProtocol.rdp,
        connected: const {'protocol': 'rdp'});
    expect(engine.request['scale'], 125);
    await pumpArea(tester, {'s1': _state('s1', 'office-pc', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    expect(view.controller.textScale, 125);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'textSize');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing, reason: 'the panel gets out of the way');
    expect(find.byKey(const ValueKey('screen-text-size-question')), findsOneWidget);
    for (final n in ScreenOptions.textScales) {
      expect(find.byKey(ValueKey('screen-text-size-question-$n')), findsOneWidget);
    }
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('125%'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-text-size-question-150')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-text-size-question')), findsNothing);
    expect(view.controller.textScale, 150);
    expect(engine.layouts, [
      [
        {'x': 0, 'y': 0, 'width': 800, 'height': 500, 'scale': 150, 'primary': true},
      ],
    ]);

    // Asked again and closed: as it was.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'textSize');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-text-size-question')), findsNothing);
    expect(engine.layouts, hasLength(1));
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('a VNC screen has no Text size entry', (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'demo-desktop', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-refresh')), 150, scrollable: panelList());
    expect(find.byKey(const ValueKey('screen-panel-textSize')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('Command key as Ctrl: on a Mac the panel has the switch; on, Cmd+C reaches the remote as Ctrl+C, on '
      'this Mac for every screen until it is turned off; another computer has no such switch', (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'demo-desktop', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ScreenView)));
    final view = tester.widget<ScreenView>(find.byType(ScreenView));

    // Not a Mac: no switch, and Command is the Super key.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-releaseKeyboard')), 150, scrollable: panelList());
    expect(find.byKey(const ValueKey('screen-panel-commandAsControl')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();
      await tapInPanel(tester, 'commandAsControl');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget, reason: 'a switch keeps the panel open');
      expect(container.read(screenCommandAsControlProvider), isTrue);
      expect(view.controller.keyboard.commandAsControl, isTrue);
      expect(container.read(sharedPreferencesProvider).getString('screen_cmd_as_ctrl'), 'on');
      // Off again from the same switch.
      await tapInPanel(tester, 'commandAsControl');
      await tester.pumpAndSettle();
      expect(container.read(screenCommandAsControlProvider), isFalse);
      expect(view.controller.keyboard.commandAsControl, isFalse);
      // Turned on elsewhere on this Mac (another screen's panel): this screen follows.
      container.read(screenCommandAsControlProvider.notifier).set(on: true);
      await tester.pump();
      expect(view.controller.keyboard.commandAsControl, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('Smooth scaling: the switch of the panel turns it on for the picture, on this computer for every '
      'screen until it is turned off', (tester) async {
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'demo-desktop', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ScreenView)));
    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    expect(view.controller.smoothScaling, isFalse, reason: 'sharp, as it always was, until its person says so');

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'smoothScaling');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget, reason: 'a switch keeps the panel open');
    expect(container.read(screenSmoothScalingProvider), isTrue);
    expect(view.controller.smoothScaling, isTrue);
    expect(container.read(sharedPreferencesProvider).getString('screen_smooth_scaling'), 'on');
    await tapInPanel(tester, 'smoothScaling');
    await tester.pumpAndSettle();
    expect(container.read(screenSmoothScalingProvider), isFalse);
    expect(view.controller.smoothScaling, isFalse);
    // Turned on from another screen's panel: this picture follows.
    container.read(screenSmoothScalingProvider.notifier).set(on: true);
    await tester.pump();
    expect(view.controller.smoothScaling, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('Open in its own window: the screen moves to a window with the choices it had here, the tab says so in '
      'the place of the picture and stops nothing; Bring it back closes the window and the picture is here again',
      (tester) async {
    final backend = FakeWindowBackend();
    final before = ScreenWindows.instance.backend;
    ScreenWindows.instance.backend = backend;
    addTearDown(() async {
      await ScreenWindows.instance.closeAll();
      ScreenWindows.instance.backend = before;
    });
    final (shell, engine) = await connectScreen(tester,
        options: const ScreenOptions(textScale: 150), protocol: ScreenProtocol.rdp, connected: const {'protocol': 'rdp'});
    await pumpArea(tester, {'s1': _state('s1', 'office-pc', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    final controller = tester.widget<ScreenView>(find.byType(ScreenView)).controller;

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'ownWindow');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing, reason: 'the panel gets out of the way');

    // The window: this session, by its number, with what the tab had.
    final payload = ScreenWindowPayload.fromJson(backend.payloads.values.single)!;
    expect((payload.sessionId, payload.handle, payload.protocol), ('s1', shell.session!.handle, ScreenProtocol.rdp));
    expect((payload.textScale, payload.fit, payload.viewOnly), (150, 'fit', false));
    expect((payload.info['width'], payload.info['height']), (800, 500));
    expect(backend.payloads.values.single.toString().contains('office-pc'), isFalse, reason: 'nothing names the host');

    // The tab: says so, shows no picture, takes no frames, and does not stop the server.
    expect(find.byKey(const ValueKey('screen-in-own-window')), findsOneWidget);
    expect(find.text('It stays connected there, on whichever monitor you put it. Close that window, or bring it back, and it returns to this tab.'), findsOneWidget);
    expect(find.text('This screen is shown in its own window.'), findsOneWidget);
    expect(find.byType(ScreenView), findsNothing);
    expect(controller.idle, isTrue);
    expect(engine.pauses, 0);
    final keys = engine.keys.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(engine.keys, hasLength(keys), reason: 'keys typed in the main window are not the remote ones now');

    // Back.
    await tester.tap(find.byKey(const ValueKey('screen-own-window-back')));
    await tester.pumpAndSettle();
    expect(backend.closed, [backend.payloads.keys.single]);
    expect(find.byKey(const ValueKey('screen-in-own-window')), findsNothing);
    expect(find.byType(ScreenView), findsOneWidget);
    expect(tester.widget<ScreenView>(find.byType(ScreenView)).controller.idle, isFalse);
    expect(shell.session!.isClosed, isFalse);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('a screen in its own window comes back when its window is closed, and when recording mode covers the '
      'picture; while covered there is no such entry', (tester) async {
    final backend = FakeWindowBackend();
    final (before, every) = (ScreenWindows.instance.backend, ScreenWindows.instance.watchEvery);
    ScreenWindows.instance
      ..backend = backend
      ..watchEvery = const Duration(milliseconds: 200);
    addTearDown(() async {
      await ScreenWindows.instance.closeAll();
      ScreenWindows.instance
        ..backend = before
        ..watchEvery = every;
    });
    final (shell, engine) = await connectScreen(tester);
    await pumpArea(tester, {'s1': _state('s1', 'demo-desktop', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(ScreenView)));

    Future<void> openIt() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();
      await tapInPanel(tester, 'ownWindow');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('screen-in-own-window')), findsOneWidget);
    }

    // Closed with the button of the window itself.
    await openIt();
    backend.open.clear();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-in-own-window')), findsNothing);
    expect(find.byType(ScreenView), findsOneWidget);

    // Recording mode turned on: the picture is covered, so no window may show it.
    await openIt();
    container.read(recordingModeProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(ScreenWindows.instance.isShown('s1'), isFalse);
    expect(backend.closed.last, backend.payloads.keys.last, reason: 'the second window is closed');
    expect(find.byKey(const ValueKey('screen-in-own-window')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel-ownWindow')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    container.read(recordingModeProvider.notifier).state = false;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('Frame rate limit: the entry of the panel asks with the limit of the host picked, and the picture is '
      'drawn at the one chosen', (tester) async {
    final (shell, engine) = await connectScreen(tester, options: const ScreenOptions(frameLimit: 30));
    await pumpArea(tester, {'s1': _state('s1', 'demo-desktop', shell)});
    frame(engine, const Color(0xFF202020));
    await settle(tester);
    final view = tester.widget<ScreenView>(find.byType(ScreenView));
    expect(view.controller.frameLimit, 30);

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'frameLimit');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-frame-limit-question')), findsOneWidget);
    for (final n in ScreenOptions.frameLimits) {
      expect(find.byKey(ValueKey('screen-frame-limit-question-$n')), findsOneWidget);
    }
    expect(find.text('30 fps'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-frame-limit-question-15')));
    await tester.pumpAndSettle();
    expect(view.controller.frameLimit, 15);

    // Closed without a choice: as it was.
    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await tester.pumpAndSettle();
    await tapInPanel(tester, 'frameLimit');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(view.controller.frameLimit, 15);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
}
