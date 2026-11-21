import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/mcp/mcp_protocol.dart';
import 'package:zestssh/features/mcp/mcp_requests.dart';
import 'package:zestssh/features/mcp/mcp_service.dart';
import 'package:zestssh/features/mcp/widgets/mcp_dialogs.dart';
import 'package:zestssh/features/mcp/widgets/mcp_settings_parts.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

import '../../visual/shots_util.dart';

/// Settings > AI apps (4.1, a computer's): the switch, where the server
/// listens, the port, the token, the setup to copy and what AI apps did;
/// and the question a command waits on. Pictures with
/// `--dart-define=ZEST_SHOTS=true` (build/shots/mcp_*.png). Names are made up.

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;
  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no team here');
  @override
  Future<void> delete(String orchardId) async {}
  @override
  Future<List<String>> list() async => const [];
}

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.squeezed);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The server as if it listened, so the test opens no port.
class _Listening extends McpServerController {
  @override
  McpStatus build() => ref.watch(mcpEnabledProvider) && ref.watch(isProProvider)
      ? McpListening(ref.watch(mcpPortProvider))
      : const McpOff();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final shot = GlobalKey();

  Future<ProviderContainer> pump(WidgetTester tester, Widget home,
      {Size size = const Size(1274, 1500), bool squeezed = true}) async {
    await tester.runAsync(loadShotFonts);
    L10nGlobal.update(en);
    final t = BuiltInThemes.getById('default_dark');
    AppColors.applyTheme(t.colorScheme);
    FlutterSecureStorage.setMockInitialValues({kMcpTokenKey: 'zmcp_${'x' * 43}'});
    SharedPreferences.setMockInitialValues({kSettingsLastSectionKey: 'ai'});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2026, 11, 20, 14, 2);
    await tester.runAsync(() async {
      for (final (i, action, command, ok) in const [
        (0, 'mcp_list_hosts', '', true),
        (1, 'mcp_open_session', '', true),
        (2, 'mcp_read_output', '', true),
        (3, 'mcp_run_command', 'systemctl status nginx', true),
        (4, 'mcp_run_command', 'sudo systemctl restart nginx', false),
      ]) {
        await db.automationHistoryDao.insert(AutomationHistoryCompanion.insert(
          id: 'a$i',
          timestamp: at.add(Duration(minutes: i)),
          action: action,
          connectionId: 'h1',
          command: command,
          success: ok,
          elapsedMs: 0,
        ).copyWith(snippetName: const Value('Claude Code')));
      }
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 20, 12))),
      mcpServerProvider.overrideWith(_Listening.new),
      isProProvider.overrideWith((ref) => _Plan(squeezed)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: t.toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => RepaintBoundary(key: shot, child: child),
        home: Scaffold(body: home),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    return container;
  }

  Future<void> takeDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  }

  testWidgets('the page: off at first; turned on, it says where it listens; what AI apps did is listed', (tester) async {
    final container = await pump(tester, const SettingsInlineView());
    expect(find.text(en.mcpSwitch), findsOneWidget);
    expect(find.text(en.mcpStatusOff), findsOneWidget);
    expect(find.byKey(const ValueKey('mcp-copy-claude-code')), findsOneWidget);
    expect(find.textContaining('sudo systemctl restart nginx'), findsOneWidget);
    expect(find.textContaining(en.mcpActNotDone(en.mcpActRun)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mcp-switch')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(container.read(mcpEnabledProvider), isTrue);
    expect(find.text(en.mcpStatusListening('http://127.0.0.1:47390/mcp')), findsOneWidget);
    if (shotsEnabled) await saveShot(tester, shot, 'mcp_settings');
    await takeDown(tester);
  });

  testWidgets('without Squeezed the switch stays off and nothing is turned on', (tester) async {
    // (A tap opens the plans, a route of the app's router, which this test has not.)
    final container = await pump(tester, const SettingsInlineView(), squeezed: false);
    await container.read(mcpEnabledProvider.notifier).set(true);
    await tester.pump(const Duration(milliseconds: 600));
    final toggle = find.descendant(of: find.byKey(const ValueKey('mcp-switch')), matching: find.byType(ZestSwitch));
    expect(tester.widget<ZestSwitch>(toggle).value, isFalse, reason: 'shown off without Squeezed');
    expect(find.text(en.mcpStatusOff), findsOneWidget);
    await takeDown(tester);
  });

  testWidgets('a command waits on a question that shows it whole and says what the check found', (tester) async {
    await pump(tester, const SizedBox.expand(), size: const Size(1100, 760));
    final request = McpRunRequest(
      caller: const McpCaller(name: 'Claude Code'),
      hostName: 'web-01',
      command: 'sudo rm -rf /var/www/old-release',
      dangers: const ['rm -rf'],
    );
    final answer = showMcpRequest(tester.element(find.byType(SizedBox).last), request);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
    expect(find.text(en.mcpRunTitle('Claude Code')), findsOneWidget);
    expect(find.textContaining('sudo rm -rf /var/www/old-release'), findsOneWidget);
    expect(find.text(en.mcpRunDanger), findsOneWidget);
    if (shotsEnabled) await saveShot(tester, shot, 'mcp_run_question');
    await tester.tap(find.text(en.mcpDeny));
    await tester.pump(const Duration(milliseconds: 400));
    expect(await answer, isFalse);
    await takeDown(tester);
  });

  testWidgets('a question taken back (no answer in time, or the AI app gave up) closes by itself; one answered '
      'closes only itself', (tester) async {
    await pump(tester, const SizedBox.expand(key: ValueKey('home')), size: const Size(1100, 760));
    Future<void> settle() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
    }

    McpRunRequest ask() => McpRunRequest(caller: const McpCaller(name: 'Claude Code'), hostName: 'web-01', command: 'uptime');
    final context = tester.element(find.byKey(const ValueKey('home')));

    final takenBack = ask();
    final shown = showMcpRequest(context, takenBack);
    await settle();
    expect(find.text(en.mcpRunTitle('Claude Code')), findsOneWidget);
    takenBack.reply(false); // as askMcp does when time runs out or the call is cancelled
    await settle();
    expect(find.text(en.mcpRunTitle('Claude Code')), findsNothing, reason: 'nothing is left to allow');
    expect(await shown, isNull);

    final answered = ask();
    final allowed = showMcpRequest(context, answered);
    await settle();
    await tester.tap(find.text(en.mcpRunAllow));
    await tester.pump(const Duration(milliseconds: 50));
    answered.reply(await allowed ?? false); // as the app's root does with the answer
    await settle();
    expect(answered.answer, completion(isTrue));
    expect(find.byKey(const ValueKey('home')), findsOneWidget, reason: 'only the question\'s own route closed');
    await takeDown(tester);
  });

  test('the setup to paste names the address and carries the token', () {
    expect(mcpClaudeCodeCommand('http://127.0.0.1:47390/mcp', 'zmcp_t'),
        'claude mcp add --transport http zestssh http://127.0.0.1:47390/mcp --header "Authorization: Bearer zmcp_t"');
    expect(mcpJsonConfig('http://127.0.0.1:47390/mcp', 'zmcp_t'), contains('"Authorization": "Bearer zmcp_t"'));
  });
}
