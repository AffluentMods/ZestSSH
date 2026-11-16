import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_words.dart';
import 'package:zestssh/features/shortcuts/widgets/keyboard_shortcuts_panel.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';

/// The keyboard shortcuts are named in the app's language (3.0: they were in
/// English that every language saw). Their names, what each does and the
/// names of their groups were written in English in the enum, and the
/// shortcuts page showed that to everyone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  test('in English each shortcut and each group is called what the code calls it', () {
    for (final a in ShortcutAction.values) {
      expect(shortcutName(en, a), a.label, reason: a.name);
      expect(shortcutHelp(en, a), a.description, reason: a.name);
    }
    for (final c in ShortcutCategory.values) {
      expect(shortcutCategoryName(en, c), c.label, reason: c.name);
    }
  });

  test('every other language has its own words: every line of what a shortcut does, and nearly every name', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final l = lookupAppLocalizations(locale);
      var sameNames = 0;
      for (final a in ShortcutAction.values) {
        expect(shortcutHelp(l, a), isNot(a.description), reason: '$locale ${a.name}');
        expect(shortcutHelp(l, a).trim(), isNotEmpty);
        expect(shortcutName(l, a).trim(), isNotEmpty);
        if (shortcutName(l, a) == a.label) sameNames++;
      }
      // (A name may be the same word in two languages; a language left in English has them all the same.)
      expect(sameNames, lessThan(3), reason: '$locale: $sameNames shortcuts are called as in English');
      final groups = [for (final c in ShortcutCategory.values) shortcutCategoryName(l, c)];
      expect(groups.toSet().length, ShortcutCategory.values.length, reason: '$locale: two groups with one name');
      // No two shortcuts with one name: a question that names a shortcut must name one.
      final names = [for (final a in ShortcutAction.values) shortcutName(l, a)];
      expect(names.toSet().length, names.length, reason: '$locale: two shortcuts with one name');
    }
  });

  test('the shortcut that adds a host is called New host, as the app calls it, in every language', () {
    // (It said New connection in the shortcuts and the command palette, found in a
    // design review, after the rest of the app said New host.)
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      expect(shortcutName(l, ShortcutAction.newConnection), l.hostsNewHost, reason: '$locale');
    }
  });

  Future<ProviderContainer> pump(WidgetTester tester, Locale locale) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1100, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: const Scaffold(body: SingleChildScrollView(child: KeyboardShortcutsPanel())),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the shortcuts page in German: German names, lines and groups, a German word finds its shortcut, and '
      'the dialog that records a key names the shortcut in German', (tester) async {
    final de = lookupAppLocalizations(const Locale('de'));
    final c = await pump(tester, const Locale('de'));
    for (final a in ShortcutAction.values) {
      expect(find.text(shortcutName(de, a)), findsOneWidget, reason: a.name);
      expect(find.text(shortcutHelp(de, a)), findsOneWidget, reason: a.name);
    }
    for (final group in ShortcutCategory.values) {
      // (A group's name is drawn in capitals.)
      expect(
        find.byWidgetPredicate((w) =>
            w is Text && (w.data ?? '').toLowerCase() == shortcutCategoryName(de, group).toLowerCase()),
        findsWidgets,
        reason: group.name,
      );
    }
    expect(find.text(ShortcutAction.toggleSidebar.label), findsNothing, reason: 'no English name is left');
    expect(find.text(ShortcutAction.toggleSidebar.description), findsNothing);

    // The search of the page goes by the German words.
    await tester.enterText(find.byType(TextField).first, 'seitenleiste');
    await tester.pumpAndSettle();
    final row = find.text(shortcutName(de, ShortcutAction.toggleSidebar));
    expect(row, findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();

    // The dialog that records a new key.
    final key = c.read(shortcutBindingsProvider).bindingFor(ShortcutAction.toggleSidebar)!.displayLabel;
    await tester.tap(find.text(key).first);
    await tester.pumpAndSettle();
    expect(find.text(de.keyboardShortcutsRebindTitle(shortcutName(de, ShortcutAction.toggleSidebar))), findsOneWidget);
    await tester.tap(find.text(de.cancel));
    await tester.pumpAndSettle();
  });

  test('the shortcuts page asks for the words, and shows none of the English of the code', () {
    final page = File('lib/features/shortcuts/widgets/keyboard_shortcuts_panel.dart').readAsStringSync();
    for (final english in ['action.label', 'action.description', 'a.label', 'a.description', 'c.label', 'category.label']) {
      expect(page, isNot(contains(english)), reason: english);
    }
  });
}
