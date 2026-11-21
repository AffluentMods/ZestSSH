// The keyboard follows tmux's panes in a computer's pane, a tablet's in the
// computer layout too (4.1.1): when the panes come up in the terminal's
// place they take the keyboard with no tap, and when they go (detached,
// closed) the terminal has it back. A tablet with a keyboard had neither:
// the terminal that had the keyboard was gone from the screen, and after a
// detach nothing typed arrived until a tap (seen on a tablet emulator with a
// keyboard, 21 November 2026).
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';
import 'package:zestssh/utils/platform_utils.dart';

import '../sharing_ui_fakes.dart';

class _Health extends ConnectionHealthNotifier {}

/// A tmux host whose panes come and go at the test's word.
class _Host extends ChangeNotifier implements TmuxSessionHost {
  _Host(this.controller);

  @override
  final TmuxController controller;

  bool on = false;

  void turn(bool value) {
    on = value;
    notifyListeners();
  }

  @override
  TmuxHostStage get stage => on ? TmuxHostStage.attached : TmuxHostStage.idle;

  @override
  bool get active => on;

  @override
  bool get live => on;

  @override
  bool get inband => false;

  @override
  String get sessionId => 's1';

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final touch in [false, true]) {
    testWidgets(
        '${touch ? "a tablet in the computer layout" : "a computer"}: the panes take the keyboard as they come up, '
        'and the terminal has it back when they go', (tester) async {
      debugTouchLayout = touch;
      debugDefaultTargetPlatformOverride = touch ? TargetPlatform.android : TargetPlatform.windows;
      final sent = <String>[];
      final c = TmuxController(sendBytes: (b) => sent.add(utf8.decode(b)), expectMarker: false);
      c.onData(utf8.encode('%session-changed \$0 main\n'));
      c.onData(utf8.encode('%layout-change @1 bc62,80x24,0,0,0 bc62,80x24,0,0,0 *\n'));
      c.onData(utf8.encode('%window-renamed @1 bash\n'));
      final host = _Host(c);
      try {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        SharedPreferences.setMockInitialValues(const {'cursor_blink': false, 'tmux_intro_seen': true});
        final prefs = await SharedPreferences.getInstance();
        final container = ProviderContainer(overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          activeSessionsProvider.overrideWith(FakeSessions.new),
          connectionHealthProvider.overrideWith((ref) => _Health()),
          tmuxHostProvider.overrideWith((ref, sessionId) => host),
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
        String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
        expect(focused(), 'TerminalPane', reason: 'the terminal in front has the keyboard');

        // tmux's panes come up in its place: no tap.
        host.turn(true);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(focused(), startsWith('tmux %'), reason: 'the active pane took the keyboard as it came up');

        // And go: the terminal has the keyboard back, no tap.
        host.turn(false);
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(focused(), 'TerminalPane', reason: 'the terminal has the keyboard back when the panes go');

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
        c.dispose();
      }
    });
  }
}
