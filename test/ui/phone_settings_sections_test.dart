import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/ui/screens/settings/widgets/choice_sheet.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';
import 'package:zestssh/ui/screens/settings/automation_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/data_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/notification_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/sftp_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/widgets/setting_control_tile.dart';
import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';

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

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(390, 9000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
  FlutterSecureStorage.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  SharedPreferences.setMockInitialValues({'automation_enabled': true});
  final shared = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(shared),
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
      theme: BuiltInThemes.getById('default_dark').toThemeData(),
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
    ),
  ));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

final _rows = find.byWidgetPredicate((w) => w is ListTile || w is SwitchListTile || w is SettingControlTile);
final _cards = find.byKey(const ValueKey('settings-section-card'));

/// A row's words, to name it in a failure.
String _name(Element e) {
  final texts = find.descendant(of: find.byElementPredicate((x) => x == e), matching: find.byType(Text)).evaluate();
  return texts.isEmpty ? '${e.widget.runtimeType}' : ((texts.first.widget as Text).data ?? '?');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  // A phone's settings pages (3.0): their groups named in
  // small grey capitals over a card of rows, as Settings' list and the More
  // tab, where each page had a look of its own.
  final pages = <String, Widget Function()>{
    'Terminal': () => const TerminalSettingsScreen(),
    'SFTP': () => const SftpSettingsScreen(),
    'Automation': () => const AutomationSettingsScreen(),
    'Notifications': () => const NotificationSettingsScreen(),
    'Data': () => const DataSettingsScreen(),
    'Security': () => const SecuritySettingsScreen(),
  };
  for (final MapEntry(key: name, value: screen) in pages.entries) {
    testWidgets('$name: every row is in a card of a named group', (tester) async {
      await _pump(tester, screen());
      expect(find.byType(SettingsSection), findsWidgets);
      expect(_cards, findsWidgets);
      final outside = [
        for (final e in _rows.evaluate())
          if (find.ancestor(of: find.byElementPredicate((x) => x == e), matching: _cards).evaluate().isEmpty) _name(e),
      ];
      expect(outside, isEmpty, reason: 'rows outside a card');
      // Each group's name in grey capitals, not in the accent; a page of one
      // section has no header of its own (its name is the page's title).
      final sections = find.byType(SettingsSection).evaluate().map((e) => e.widget as SettingsSection).toList();
      for (final s in sections) {
        final title = s.title;
        if (title == null) {
          expect(sections, hasLength(1), reason: 'only a page of one section goes without a header');
          continue;
        }
        final label = tester.widget<Text>(find.text(title.toUpperCase()).first);
        expect(label.style?.color, isNot(AppColors.accentInk), reason: title);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
    });

    // As Settings' list draws its rows (3.0): the icon
    // in the accent's tile, the name in the row's weight and in the app's
    // own font (a list tile's styles stand in for the theme's: one without
    // the family drew the names in the phone's default font).
    testWidgets("$name: each row's icon in the accent's tile, its name in the row's weight and the app's font",
        (tester) async {
      await _pump(tester, screen());
      final bare = [
        for (final e in find.descendant(of: _cards, matching: find.byType(ListTile)).evaluate())
          if ((e.widget as ListTile).leading is Icon) _name(e),
      ];
      expect(bare, isEmpty, reason: 'rows with a bare icon');
      expect(find.descendant(of: _cards, matching: find.byType(PhoneIconTile)), findsWidgets);
      expect(tester.getSize(find.byType(PhoneIconTile).first), const Size(36, 36));
      // The first row's name: its first Text (an Icon draws no Text).
      final title = find
          .descendant(
              of: find.descendant(of: find.descendant(of: _cards, matching: find.byType(ListTile)).first,
                  matching: find.byType(Text)).first,
              matching: find.byType(RichText))
          .first;
      final style = tester.renderObject<RenderParagraph>(title).text.style!;
      final family = Theme.of(tester.element(title)).textTheme.bodyLarge!.fontFamily;
      expect(family, isNotNull);
      expect(style.fontFamily, family, reason: "the app's own font");
      expect(style.fontWeight, PhoneListRow.titleStyle.fontWeight, reason: "the row's weight, as Settings' list");
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
    });
  }

  testWidgets('SFTP: a choice shows the one picked in a field that opens every choice in a sheet, the one picked '
      'marked; a pick is kept', (tester) async {
    await _pump(tester, const SftpSettingsScreen());
    final l10n = lookupAppLocalizations(const Locale('en'));
    final field = find.descendant(
        of: find.byType(SettingChoiceTile<SftpHiddenLevel>), matching: find.byKey(const ValueKey('setting-choice-field')));
    expect(find.descendant(of: field, matching: find.text(l10n.settingsMobSystemFilesOnly)), findsOneWidget);
    expect(find.byType(DropdownButton<SftpHiddenLevel>), findsNothing);
    await tester.tap(field);
    await tester.pumpAndSettle();
    // The app's sheet of choices (settings/widgets/choice_sheet.dart).
    final sheet = find.byKey(const ValueKey('zest-sheet'));
    expect(sheet, findsOneWidget);
    for (final words in [l10n.settingsMobSystemFilesOnly, l10n.settingsMobHiddenAndSystem]) {
      expect(find.descendant(of: sheet, matching: find.text(words)), findsOneWidget, reason: words);
    }
    // The one picked, its dot radio filled (a pick-one choice is a dot;
    // it was a check).
    expect(find.descendant(of: sheet, matching: find.byIcon(LucideIcons.check)), findsNothing);
    final semantics = tester.ensureSemantics();
    for (final (level, picked) in [(SftpHiddenLevel.systemOnly, true), (SftpHiddenLevel.hiddenAndSystem, false)]) {
      final row = find.byWidgetPredicate((w) => w is SettingsRadioRow<SftpHiddenLevel> && w.value == level);
      expect(row, findsOneWidget, reason: '$level');
      expect(tester.getSemantics(find.descendant(of: row, matching: find.byType(Radio<SftpHiddenLevel>))),
          isSemantics(isChecked: picked, isInMutuallyExclusiveGroup: true),
          reason: '$level');
    }
    semantics.dispose();
    await tester.tap(find.descendant(of: sheet, matching: find.text(l10n.settingsMobHiddenAndSystem)));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(find.descendant(of: field, matching: find.text(l10n.settingsMobHiddenAndSystem)), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(SftpSettingsScreen)));
    expect(container.read(sftpHiddenLevelProvider), SftpHiddenLevel.hiddenAndSystem);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  });

  testWidgets("Appearance: its groups named the same way, the themes' grid on the page itself", (tester) async {
    await _pump(tester, const AppearanceScreen());
    final sections = find.byType(SettingsSection);
    expect(sections, findsWidgets);
    // Its named groups hold grids on the page itself; the two rows over
    // them (whole-app themes, Terminal) are the one card without a name.
    for (final e in sections.evaluate()) {
      final s = e.widget as SettingsSection;
      expect(s.card, s.title == null, reason: s.title ?? 'the rows over the themes');
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  });
}
