// Settings of a phone that nothing read (found while
// comparing the five versions). "Destructive Command Confirmation" was a
// switch of its own, and the warning before a dangerous command is pasted,
// run as a snippet or broadcast answered to another (a computer's "Dangerous
// command protection"), which a phone could not change. "Default Snippet
// Category" left a new snippet in no category. "Keyboard Row Position" put
// the row of keys above the keyboard whatever it said.

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_edit_dialog.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';

import 'sharing_ui_fakes.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

class _Health extends ConnectionHealthNotifier {}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('the warning before a dangerous command', () {
    late AppDatabase db;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async => db.close());

    Future<ProviderContainer> pump(WidgetTester tester, Widget screen) async {
      tester.view.physicalSize = const Size(420, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      ]);
      addTearDown(container.dispose);
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => screen)]);
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ));
      await tester.pumpAndSettle();
      return container;
    }

    for (final (name, screen) in [
      ("a phone's Settings", const SettingsScreen() as Widget),
      // Security and privacy's (4.0: it was the Terminal page's).
      ('its Security and privacy page', const SecuritySettingsScreen() as Widget),
    ]) {
      testWidgets('$name switch it, the one a computer has, in its words', (tester) async {
        final c = await pump(tester, screen);
        final row = find.byKey(const ValueKey('settings-dangerous-commands'));
        await tester.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
        expect(find.descendant(of: row, matching: find.text(_l10n.settingsInlineDangerousCommandProtection)),
            findsOneWidget);
        expect(c.read(dangerousCommandProtectionProvider), isTrue);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(c.read(dangerousCommandProtectionProvider), isFalse, reason: 'it was a switch of its own');
        expect(tester.widget<SwitchListTile>(row).value, isFalse);
      });
    }
  });

  testWidgets('a new snippet starts in the category Settings gives new snippets; one there keeps its own',
      (tester) async {
    SharedPreferences.setMockInitialValues({'default_snippet_category': 'Docker'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shown = ValueNotifier<Snippet?>(null);
    addTearDown(shown.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: ValueListenableBuilder<Snippet?>(
            valueListenable: shown,
            builder: (_, snippet, _) => SnippetEditor(key: ValueKey(snippet?.id), snippet: snippet),
          ),
        ),
      ),
    ));
    await tester.pump();
    Finder field(String text) => find.byWidgetPredicate((w) => w is EditableText && w.controller.text == text);
    expect(field('Docker'), findsOneWidget, reason: 'it started in none');

    shown.value = Snippet(
      id: 's1',
      label: 'Disk use',
      command: 'df -h',
      category: 'System',
      confirmBeforeRun: false,
      isDefault: false,
      sortOrder: 0,
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
    );
    await tester.pump();
    expect(field('System'), findsOneWidget);
    expect(field('Docker'), findsNothing);
  });

  group("a phone's row of keys", () {
    Future<void> pumpScreen(WidgetTester tester, String? position, {bool shown = true}) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      debugPhoneKeysRow = true;
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({
        'cursor_blink': false,
        'show_extra_keyboard': shown,
        'extra_keyboard_position': ?position,
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(FakeSessions.new),
        connectionHealthProvider.overrideWith((ref) => _Health()),
      ]);
      addTearDown(container.dispose);
      (container.read(activeSessionsProvider.notifier) as FakeSessions).show({'s1': connectedSession('s1', 'Web s1')});
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
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
      debugDefaultTargetPlatformOverride = null;
      debugPhoneKeysRow = null;
    }

    testWidgets("the terminal's sheet (a long press on it) offers the row's own page", (tester) async {
      await pumpScreen(tester, 'aboveKeyboard');
      // The terminal's own long press: a finger held 800 ms.
      final finger = await tester.startGesture(tester.getCenter(find.byType(TerminalView)));
      await tester.pump(const Duration(milliseconds: 900));
      await finger.up();
      await tester.pumpAndSettle();
      expect(find.text(_l10n.settingsExtraKeyboardRow), findsOneWidget);
      await finish(tester);
    });

    testWidgets('above the keyboard, as it was', (tester) async {
      await pumpScreen(tester, 'aboveKeyboard');
      final keys = tester.getRect(find.byType(TerminalSoftKeyboard));
      expect(keys.top, greaterThanOrEqualTo(tester.getRect(find.byType(TerminalView)).bottom - 1));
      await finish(tester);
    });

    testWidgets('above the terminal, where Settings puts it there (it stayed above the keyboard)', (tester) async {
      await pumpScreen(tester, 'aboveTerminal');
      final keys = tester.getRect(find.byType(TerminalSoftKeyboard));
      expect(keys.bottom, lessThanOrEqualTo(tester.getRect(find.byType(TerminalView)).top + 1));
      expect(find.byType(TerminalSoftKeyboard), findsOneWidget, reason: 'once');
      await finish(tester);
    });

    testWidgets('nowhere where its position is Disabled, though its switch is on', (tester) async {
      await pumpScreen(tester, 'disabled');
      expect(find.byType(TerminalSoftKeyboard), findsNothing);
      await finish(tester);
    });
  });
}
