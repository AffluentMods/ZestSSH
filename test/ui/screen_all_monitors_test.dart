// Full screen on all monitors (4.1, Windows, RDP): the remote is asked for
// one display per monitor of this PC, each at the monitor's size, place and
// scaling, and the window covers them all; leaving puts the window and the
// remote's displays back. The monitors and the window are played here.
import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/desktop/screen_pane.dart';
import 'package:zestssh/features/screens/desktop/screen_span.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/window_service.dart';

import '../features/screens/screen_clipboard_test.dart' show FakeClipboardIo;
import '../features/screens/view/screen_view_fixture.dart';

class _Trust implements ScreenTrust {
  @override
  Future<String?> pinned() async => null;
  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async => true;
  @override
  Future<void> remember(ScreenCertificate cert) async {}
}

/// This PC's monitors and its window, played.
class _Spanner implements MonitorSpanner {
  _Spanner(this.list);

  List<LocalMonitor> list;
  final calls = <String>[];
  bool refuse = false;

  @override
  Future<List<LocalMonitor>> monitors() async => list;

  @override
  Future<bool> span(Rect area) async {
    calls.add('span ${area.left.round()},${area.top.round()} ${area.width.round()}x${area.height.round()}');
    return !refuse;
  }

  @override
  Future<void> unspan() async => calls.add('unspan');
}

// A 1920 x 1080 primary at 100%, and a 2560 x 1440 at 150% to its right, a little higher.
const _primary = LocalMonitor(left: 0, top: 0, width: 1920, height: 1080, primary: true);
const _right = LocalMonitor(left: 1920, top: -180, width: 2560, height: 1440, dpi: 144);

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  group('the plan', () {
    test('one display per monitor, at its size, place and scaling; the primary first', () {
      final plan = SpanPlan.of(const [_right, _primary])!;
      expect(plan.monitors, [_primary, _right]);
      final d = plan.displays;
      expect([d[0].x, d[0].y, d[0].width, d[0].height, d[0].scale, d[0].primary], [0, 180, 1920, 1080, 100, true]);
      expect([d[1].x, d[1].y, d[1].width, d[1].height, d[1].scale, d[1].primary], [1920, 0, 2560, 1440, 150, false]);
      expect(plan.area, const Rect.fromLTRB(0, -180, 4480, 1260));
    });

    test('one monitor, or one that fits: nothing to span', () {
      expect(SpanPlan.of(const [_primary]), isNull);
      expect(SpanPlan.of(const []), isNull);
      // A monitor larger than a remote display may be is left out.
      expect(SpanPlan.of(const [_primary, LocalMonitor(left: 1920, top: 0, width: 10240, height: 4320)]), isNull);
    });

    test('five monitors: the primary and the three nearest', () {
      final five = [
        _primary,
        const LocalMonitor(left: 1920, top: 0, width: 1920, height: 1080),
        const LocalMonitor(left: -1920, top: 0, width: 1920, height: 1080),
        const LocalMonitor(left: 0, top: -1080, width: 1920, height: 1080),
        const LocalMonitor(left: 7680, top: 0, width: 1920, height: 1080),
      ];
      final plan = SpanPlan.of(five)!;
      expect(plan.displays, hasLength(ScreenOptions.maxDisplays));
      expect(plan.monitors.map((m) => m.left), isNot(contains(7680)));
      expect(plan.area, const Rect.fromLTRB(-1920, -1080, 3840, 1080));
    });

    test('a monitor\'s scaling as RDP takes it', () {
      expect(const LocalMonitor(left: 0, top: 0, width: 1, height: 1).scalePercent, 100);
      expect(const LocalMonitor(left: 0, top: 0, width: 1, height: 1, dpi: 120).scalePercent, 125);
      expect(const LocalMonitor(left: 0, top: 0, width: 1, height: 1, dpi: 72).scalePercent, 100);
    });
  });

  group('the pane', () {
    late FakeScreenNative native;
    late SharedPreferences prefs;
    late _Spanner spanner;

    setUp(() async {
      native = FakeScreenNative();
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      spanner = _Spanner(const [_primary, _right]);
      ScreenPane.debugDecodeTile = syncDecode;
      ScreenPane.debugClipboard = FakeClipboardIo();
      ScreenPane.debugSetWindowFullScreen = (on) async {};
      ScreenPane.debugSpanner = spanner;
      WindowService.fullscreen.value = false;
    });
    tearDown(() {
      ScreenPane.debugDecodeTile = null;
      ScreenPane.debugClipboard = null;
      ScreenPane.debugSetWindowFullScreen = null;
      ScreenPane.debugSpanner = null;
      WindowService.fullscreen.value = false;
    });

    Future<(ScreenShellService, FakeScreenSession)> connect(WidgetTester tester, ScreenProtocol protocol) async {
      final toServer = StreamController<List<int>>();
      final fromServer = StreamController<Uint8List>();
      addTearDown(() {
        unawaited(toServer.close());
        unawaited(fromServer.close());
      });
      final shell = ScreenShellService(
        target: const DirectTlsTarget('192.0.2.30', 3389),
        trust: _Trust(),
        native: native,
        options: ScreenOptions.defaults,
        protocol: protocol,
        inTeam: false,
        connectionId: 'c-desk',
        openDirect: (_, _) async => ScreenChannel(fromServer.stream, toServer.sink),
      );
      final connecting = shell.connect();
      for (var i = 0; i < 5; i++) {
        await tester.pump();
        if (native.sessions.isNotEmpty) break;
      }
      final engine = native.sessions.single;
      engine.connect(name: 'demo-desktop', width: 1280, height: 800);
      await tester.pump();
      await connecting;
      return (shell, engine);
    }

    Future<void> pump(WidgetTester tester, ScreenShellService shell) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = SessionState(
        status: SessionStatus.connected,
        connectionId: 'c-desk',
        connectionLabel: 'Demo desktop',
        session: TerminalSession(
            id: 's1', connectionId: 'c-desk', terminal: Terminal(), shell: shell, startedAt: DateTime(2026, 11, 20)),
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: ScreenPane(sessionId: 's1', sessionState: state, front: true, visible: true)),
        ),
      ));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byType(ScreenView).first);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pumpAndSettle();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    }

    final item = find.byKey(const ValueKey('screen-panel-allMonitors'));
    final layer = find.byKey(const ValueKey('screen-full-screen'));

    testWidgets('RDP with two monitors: on all monitors, one display each, the window over both; and back',
        (tester) async {
      final (shell, engine) = await connect(tester, ScreenProtocol.rdp);
      await pump(tester, shell);
      await openMenu(tester);
      expect(item, findsOneWidget);
      expect(find.text(en.screenAllMonitors), findsOneWidget);
      await tester.ensureVisible(item);
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(spanner.calls, ['span 0,-180 4480x1440']);
      final asked = engine.layouts.last;
      expect(asked, hasLength(2));
      expect([asked[0]['width'], asked[0]['height'], asked[0]['primary'], asked[0]['scale']], [1920, 1080, true, 100]);
      expect([asked[1]['x'], asked[1]['width'], asked[1]['height'], asked[1]['scale']], [1920, 2560, 1440, 150]);
      expect(layer, findsOneWidget);

      // Ctrl+Alt+Break leaves, as from full screen.
      await tester.tap(find.byType(ScreenView).last);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.pause);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(spanner.calls.last, 'unspan');
      expect(layer, findsNothing);
      final back = engine.layouts.last;
      expect(back.length, isNot(2), reason: 'the remote is asked again for what it had');
      await finish(tester);
    });

    testWidgets('the window could not cover the monitors: said, and nothing else changed', (tester) async {
      spanner.refuse = true;
      final (shell, engine) = await connect(tester, ScreenProtocol.rdp);
      await pump(tester, shell);
      final before = engine.layouts.length;
      await openMenu(tester);
      await tester.ensureVisible(item);
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(engine.layouts.length, before);
      expect(layer, findsNothing);
      await finish(tester);
    });

    testWidgets('not offered for VNC, nor with one monitor', (tester) async {
      final (vnc, _) = await connect(tester, ScreenProtocol.vnc);
      await pump(tester, vnc);
      await openMenu(tester);
      expect(item, findsNothing);
      await finish(tester);

      native = FakeScreenNative();
      spanner.list = const [_primary];
      final (rdp, _) = await connect(tester, ScreenProtocol.rdp);
      await pump(tester, rdp);
      await openMenu(tester);
      expect(item, findsNothing);
      await finish(tester);
    });
  });
}
