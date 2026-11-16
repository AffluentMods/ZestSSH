// A host's own terminal theme (found while comparing the
// five versions): a host's form can give it a theme of its own, and only a
// phone's terminal showed it; a computer's pane and tmux's panes showed the
// app's. And a theme chosen while a host was made was dropped: it was kept
// for a host that was there already alone.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/theme/terminal_themes.dart' as app_themes;
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/tmux/tmux_session_view.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

import 'sharing_ui_fakes.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));
final _dracula = app_themes.TerminalThemes.all[app_themes.TerminalThemes.dracula]!;

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Health extends ConnectionHealthNotifier {}

/// tmux attached in session s1.
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
  String get sessionId => 's1';

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test("a host's sessions show its own theme where it has one, else the app's", () async {
    SharedPreferences.setMockInitialValues({'terminal_theme_h-own': 'dracula', 'terminal_theme_h-gone': 'no-such-theme'});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    final app = c.read(terminalThemeProvider);
    expect(c.read(hostTerminalThemeProvider('h-own')), same(_dracula));
    expect(c.read(hostTerminalThemeProvider('h-none')), same(app));
    expect(c.read(hostTerminalThemeProvider('h-gone')), same(app), reason: 'a theme that is not there');
    expect(c.read(hostTerminalThemeProvider(null)), same(app));
    expect(app, isNot(same(_dracula)));
  });

  group("a session's terminals", () {
    Future<void> pump(WidgetTester tester, Widget home, {TmuxSessionHost? tmux}) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'cursor_blink': false, 'tmux_intro_seen': true, 'terminal_theme_c-s1': 'dracula'});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(FakeSessions.new),
        connectionHealthProvider.overrideWith((ref) => _Health()),
        if (tmux != null) tmuxHostProvider.overrideWith((ref, sessionId) => tmux),
      ]);
      addTearDown(container.dispose);
      (container.read(activeSessionsProvider.notifier) as FakeSessions).show({'s1': connectedSession('s1', 'Web s1')});
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: home),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
      debugDefaultTargetPlatformOverride = null;
    }

    testWidgets("a phone's terminal, as before", (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pump(tester, const TerminalScreen(sessionId: 's1'));
      expect(tester.widget<TerminalView>(find.byType(TerminalView)).theme, same(_dracula));
      await finish(tester);
    });

    testWidgets("tmux's panes (they showed the app's)", (tester) async {
      final c = TmuxController(sendBytes: (_) {}, expectMarker: false);
      addTearDown(c.dispose);
      c.onData(utf8.encode('%session-changed \$0 main\n'));
      c.onData(utf8.encode('%layout-change @1 bc62,80x24,0,0,0 bc62,80x24,0,0,0 *\n'));
      await pump(tester, TmuxSessionView(host: _Host(c), onLeave: () {}), tmux: _Host(c));
      expect(tester.widget<TerminalView>(find.byType(TerminalView)).theme, same(_dracula));
      await finish(tester);
    });
  });

  testWidgets('a theme chosen while a host is made is kept for it (it was dropped)', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(c.dispose);
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: ConnectionEditScreen(inDialog: true, onClose: () {})),
      ),
    ));
    await settle();
    await tester.enterText(find.widgetWithText(TextFormField, _l10n.connectionNicknameHint).first, 'web-09');
    await tester.enterText(find.widgetWithText(TextFormField, _l10n.phoneUiFormAddressHint).first, '192.168.10.9');
    await tester.tap(find.text(_l10n.connectionEditRailTerminal).first);
    await settle();
    await tester.tap(find.text(_l10n.connectionEditOverrideDefaults));
    await settle();
    await tester.tap(find.byType(ZestSelect<String?>).first);
    await settle();
    await tester.tap(
        find.descendant(of: find.byKey(const ValueKey('zest-select-item-dracula')), matching: find.text('Dracula')));
    await settle();
    await tester.tap(find.text(_l10n.connectionSaveConnection).first);
    await settle();
    final saved = (await tester.runAsync(() => db.connectionsDao.getAll()))!;
    expect(saved, hasLength(1));
    expect(prefs.getString('terminal_theme_${saved.single.id}'), 'dracula');
    expect(c.read(hostTerminalThemeProvider(saved.single.id)), same(_dracula));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  });
}
