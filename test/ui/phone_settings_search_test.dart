import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';
import 'package:zestssh/ui/screens/settings/automation_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/data_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';
import 'package:zestssh/ui/screens/settings/notification_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/phone_settings_search.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/settings/sftp_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/widgets/setting_control_tile.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/setting_help.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

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

final _en = lookupAppLocalizations(const Locale('en'));

/// [screen] at the root of a router whose other pages say their own path, in
/// [locale], tall enough that every row of a settings page is built (or at
/// [size]).
Future<GoRouter> _pump(WidgetTester tester, Widget screen,
    {Locale locale = const Locale('en'), Map<String, Object> prefs = const {}, Size size = const Size(390, 9000)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
  FlutterSecureStorage.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  SharedPreferences.setMockInitialValues(prefs);
  final shared = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(shared),
    recordingModeProvider.overrideWith((ref) => false),
    databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
    orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
  ]);
  addTearDown(container.dispose);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (context, state) => screen),
    GoRoute(path: '/:rest(.*)', builder: (context, state) => Scaffold(body: Text('page ${state.uri}'))),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  return router;
}

String _text(Widget? w) {
  // A row whose help is behind More (4.0): its setting's name.
  if (w is FoldedHelpTitle) return w.setting;
  if (w is! Text) return '';
  return (w.data ?? w.textSpan?.toPlainText() ?? '').replaceAll('\u{FFFC}', '').trim();
}

/// The name of every setting [find]s on the screen: the rows of a settings page.
List<String> _settingNames() => [
      for (final e in find.byWidgetPredicate((w) => w is ListTile || w is SwitchListTile || w is SettingControlTile)
          .evaluate())
        switch (e.widget) {
          ListTile(:final title) => _text(title),
          SwitchListTile(:final title) => _text(title),
          SettingControlTile(:final title) => _text(title),
          _ => '',
        },
    ].where((n) => n.isNotEmpty).toSet().toList();

Future<void> _type(WidgetTester tester, String words) async {
  await tester.enterText(find.byKey(const ValueKey('settings-search')), words);
  await tester.pump();
}

/// The names of the rows the search found, in order.
List<String> _found() => [
      for (final e in find.byType(PhoneListRow).evaluate()) _text((e.widget as PhoneListRow).title),
    ];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // What each phone page shows: its rows with the key row on and scrollable
  // (so Customize keys shows) and automation on (so its pages show).
  final pages = <PhoneSettingsPage, Widget Function()>{
    PhoneSettingsPage.appearance: () => const AppearanceScreen(),
    PhoneSettingsPage.terminal: () => const TerminalSettingsScreen(),
    PhoneSettingsPage.sftp: () => const SftpSettingsScreen(),
    PhoneSettingsPage.automation: () => const AutomationSettingsScreen(),
    PhoneSettingsPage.notifications: () => const NotificationSettingsScreen(),
    PhoneSettingsPage.data: () => const DataSettingsScreen(),
    PhoneSettingsPage.security: () => const SecuritySettingsScreen(),
    PhoneSettingsPage.keyboardRow: () => const KeyboardRowScreen(),
  };
  for (final MapEntry(key: page, value: screen) in pages.entries) {
    testWidgets('every setting the ${page.name} page shows is found by the search, as on that page', (tester) async {
      await _pump(tester, screen(),
          prefs: {'show_extra_keyboard': true, 'soft_keyboard_scrollable_mode': true, 'automation_enabled': true});
      final names = _settingNames();
      expect(names, isNotEmpty);
      // The Backups and data page holds the rows that open the backups'
      // sheet and the question of Reset all settings (4.0).
      final on = {page, if (page == PhoneSettingsPage.data) ...[PhoneSettingsPage.backups, PhoneSettingsPage.reset]};
      final indexed = {for (final s in kPhoneSettingsIndex.where((s) => on.contains(s.page))) s.name(_en)};
      final pageNames = {for (final p in PhoneSettingsPage.values) p.nameIn(_en)};
      // A row that opens another page is that page: Appearance's Terminal,
      // and its Terminal font and size, which opens the Terminal page where
      // the font's rows are.
      final opensPage = {...pageNames, _en.appearanceTerminalFontAndSize};
      expect([for (final n in names) if (!indexed.contains(n) && !opensPage.contains(n)) n], isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
    });
  }

  testWidgets('the search lists the settings whose words hold what is typed, each with its page, and opens it',
      (tester) async {
    final router = await _pump(tester, const Scaffold(body: SettingsBody(bottomPadding: 16)));
    expect(find.byKey(const ValueKey('settings-account')), findsOneWidget);

    await _type(tester, 'FONT size');
    expect(_found(), [_en.settingsFontSize], reason: 'once, on the Terminal page');
    expect(find.byKey(const ValueKey('settings-account')), findsNothing, reason: 'the groups give way to what was found');
    expect(find.text(_en.settingsPageTerminalSsh), findsOneWidget, reason: 'the page each is on');

    // Words a setting's page says about it find it, after those whose names hold them.
    await _type(tester, 'tasker');
    expect(_found(), [_en.settingsMobExternalAutomation, _en.settingsMobScheduledTasks, _en.settingsMobAutomationGuide]);

    await _type(tester, 'size font');
    await tester.tap(find.text(_en.settingsFontSize));
    await tester.pumpAndSettle();
    expect(find.text('page ${Routes.terminalSettings}'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    await _type(tester, 'nothing has these words');
    expect(find.byKey(const ValueKey('settings-search-none')), findsOneWidget);
    expect(find.text(_en.settingsSearchNoResults), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('phone-search-clear')));
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-account')), findsOneWidget, reason: 'cleared, the groups are back');
    expect(find.byKey(const ValueKey('settings-search-none')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  });

  // A design review found a phone's search listed the
  // terminal's font twice, "Terminal font" (Appearance) and "Font" (Terminal),
  // and its size twice. Now the font's rows are
  // the Terminal page's alone, and Appearance has a row that opens that page.
  testWidgets('on a phone (412 by 915) the terminal font and its size are found once each, on the Terminal page, '
      'and Appearance has one row for them that opens it', (tester) async {
    debugTouchLayout = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      const phone = Size(412, 915);
      await _pump(tester, const Scaffold(body: SettingsBody(bottomPadding: 16)), size: phone);
      await _type(tester, 'font');
      final found = _found();
      expect(found.where((n) => n == _en.settingsFont), hasLength(1));
      expect(found.where((n) => n == _en.settingsFontSize), hasLength(1));
      expect(found, isNot(contains('Terminal font')));
      expect(found, isNot(contains('Terminal font size')));
      expect(found, isNot(contains(_en.appearanceTerminalFontAndSize)), reason: 'a way to the Terminal page, not a setting');
      for (final name in [_en.settingsFont, _en.settingsFontSize]) {
        final row = find.ancestor(of: find.text(name), matching: find.byType(PhoneListRow));
        expect(find.descendant(of: row, matching: find.text(_en.settingsPageTerminalSsh)), findsOneWidget, reason: name);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));

      await _pump(tester, const AppearanceScreen(),
          size: phone, prefs: {'terminal_font': TerminalFontFamily.firaCode.name, 'terminal_font_size': 16.0});
      expect(find.byType(Slider, skipOffstage: false), findsNothing, reason: 'the size is set on the Terminal page');
      expect(find.byType(SettingChoiceTile<TerminalFontFamily>, skipOffstage: false), findsNothing);
      expect(find.text('Terminal font', skipOffstage: false), findsNothing);
      expect(find.text('Terminal font size', skipOffstage: false), findsNothing);
      final link = find.byKey(const ValueKey('appearance-terminal-font'));
      await tester.scrollUntilVisible(link, 300, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(find.descendant(of: link, matching: find.text(_en.appearanceTerminalFontAndSize)), findsOneWidget);
      expect(
          find.descendant(
              of: link,
              matching: find.text(_en.appearanceTerminalFontAndSizeValue(TerminalFontFamily.firaCode.nameIn(_en), 16))),
          findsOneWidget,
          reason: 'what they are now');
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.text('page ${Routes.terminalSettings}'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
    } finally {
      debugTouchLayout = null;
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // A check on a small phone (393 by 807): "Terminal theme" was
  // found twice, Appearance's and the Terminal page's. It is the Terminal
  // page's, whose row of that name opens every terminal theme.
  testWidgets('on a phone (393 by 807) "Terminal theme" is found once, on the Terminal page, and opens it',
      (tester) async {
    debugTouchLayout = true;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final router =
          await _pump(tester, const Scaffold(body: SettingsBody(bottomPadding: 16)), size: const Size(393, 807));
      await _type(tester, 'Terminal theme');
      expect(_found().where((n) => n == _en.settingsTerminalTheme), hasLength(1), reason: '${_found()}');
      expect(_found().first, _en.settingsTerminalTheme, reason: 'the one named so first');
      final row = find.ancestor(of: find.text(_en.settingsTerminalTheme), matching: find.byType(PhoneListRow));
      expect(find.descendant(of: row, matching: find.text(_en.settingsPageTerminalSsh)), findsOneWidget,
          reason: 'on the Terminal page');
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('page ${Routes.terminalSettings}'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
    } finally {
      debugTouchLayout = null;
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets("in another language, the search goes by that language's words", (tester) async {
    final de = lookupAppLocalizations(const Locale('de'));
    await _pump(tester, const Scaffold(body: SettingsBody(bottomPadding: 16)), locale: const Locale('de'));
    await _type(tester, de.settingsDeleteHoldLabel.substring(0, 6).toLowerCase());
    expect(_found(), contains(de.settingsDeleteHoldLabel));
    expect(find.text(de.settingsPageFiles), findsWidgets);
    await _type(tester, _en.settingsDeleteHoldLabel);
    expect(_found(), isNot(contains(de.settingsDeleteHoldLabel)), reason: 'not by the English words');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  });

  test('every setting of the search has a name in every language', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final s in kPhoneSettingsIndex) {
        expect(s.name(l10n).trim(), isNotEmpty, reason: '$locale ${s.page}');
      }
    }
  });
}
