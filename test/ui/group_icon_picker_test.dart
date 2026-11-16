import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/data/os_catalog.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/groups/widgets/group_editor_panel.dart';
import 'package:zestssh/features/hosts/data/folder_icon_catalog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/host_icon_names.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';

/// A group's icon picker (3.0). It drew the folder twice
/// (the cell of no icon chosen, and the folder among the choices), and its
/// icons had no names, on hover or for a screen reader. Now the folder is
/// drawn once, its cell chosen whether the group has no icon or the folder's,
/// and each icon is named in the person's language: a host icon's name where
/// the two show the same thing.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final all = [for (final locale in AppLocalizations.supportedLocales) lookupAppLocalizations(locale)];

  test("every icon of a group has a name in every language, no two the same, a host icon's where the two show the "
      'same thing', () {
    for (final l10n in all) {
      final names = [for (final icon in folderIconChoices) folderIconName(icon, l10n)];
      expect(names.every((n) => n.trim().isNotEmpty), isTrue, reason: l10n.localeName);
      expect(names.toSet().length, folderIconChoices.length, reason: '${l10n.localeName}: $names');
      expect(folderIconName(LucideIcons.folder, l10n), l10n.iconNameFolder);
      expect(folderIconName(LucideIcons.server, l10n), hostIconName(OsCatalog.get('server'), l10n));
      expect(folderIconName(LucideIcons.layers, l10n), l10n.iconNameLayers);
      expect(folderIconName(LucideIcons.boxes, l10n), l10n.iconNameBoxes);
    }
    final de = lookupAppLocalizations(const Locale('de'));
    expect(folderIconName(LucideIcons.folder, de), 'Ordner');
    expect(folderIconName(LucideIcons.database, de), 'Datenbank');
    expect(folderIconName(LucideIcons.airplay, de), 'Ordner', reason: 'an icon outside the choices is a folder');
  });

  Future<AppLocalizations> openPicker(WidgetTester tester, Locale locale, {int? groupIcon}) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById('default_dark');
    AppColors.applyTheme(theme.colorScheme);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    if (groupIcon != null) {
      await tester.runAsync(() => db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
          id: 'g1', name: 'Web', createdAt: DateTime(2026, 10, 17), iconCodePoint: Value(groupIcon))));
    }
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: theme.toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => GroupEditorPanel.showAdaptive(context, groupId: groupIcon == null ? null : 'g1'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final l10n = lookupAppLocalizations(locale);
    await tester.tap(find.byTooltip(l10n.hostIconPickerTitle));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(Dialog), findsOneWidget);
    return l10n;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  }

  Finder inPicker(Finder finder) => find.descendant(of: find.byType(Dialog), matching: finder);

  testWidgets('the picker draws the folder once, names each icon, and the cell of no icon is the one chosen',
      (tester) async {
    final l10n = await openPicker(tester, const Locale('en'));
    expect(inPicker(find.byIcon(LucideIcons.folder)), findsOneWidget);
    for (final icon in folderIconChoices) {
      expect(inPicker(find.byIcon(icon)), findsOneWidget, reason: folderIconName(icon, l10n));
      expect(inPicker(find.byTooltip(folderIconName(icon, l10n))), findsOneWidget, reason: folderIconName(icon, l10n));
    }
    final chosen = inPicker(find.byWidgetPredicate((w) => w is Semantics && w.properties.selected == true));
    expect(chosen, findsOneWidget);
    expect(find.descendant(of: chosen, matching: find.byIcon(LucideIcons.folder)), findsOneWidget);

    await tester.tap(inPicker(find.byTooltip(folderIconName(LucideIcons.server, l10n))));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(Dialog), findsNothing);
    expect(find.byIcon(LucideIcons.server), findsOneWidget, reason: "the group's icon is the server now");
    await close(tester);
  });

  testWidgets("a group that kept the folder's own icon (an earlier version let it choose the folder twice) has the "
      "folder's cell chosen", (tester) async {
    await openPicker(tester, const Locale('en'), groupIcon: LucideIcons.folder.codePoint);
    final chosen = inPicker(find.byWidgetPredicate((w) => w is Semantics && w.properties.selected == true));
    expect(chosen, findsOneWidget);
    expect(find.descendant(of: chosen, matching: find.byIcon(LucideIcons.folder)), findsOneWidget);
    await close(tester);
  });

  testWidgets("the picker names its icons in the person's language", (tester) async {
    final de = await openPicker(tester, const Locale('de'));
    expect(inPicker(find.byTooltip('Ordner')), findsOneWidget);
    expect(inPicker(find.byTooltip('Datenbank')), findsOneWidget);
    expect(inPicker(find.byTooltip(de.iconNameLayers)), findsOneWidget);
    await close(tester);
  });
}
