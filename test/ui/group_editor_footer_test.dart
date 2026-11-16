import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/groups/widgets/group_editor_panel.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';

/// The Groups panel: Cancel closes it whether or
/// not anything changed, and New group pressed while a new group is already
/// open puts the cursor in its name and lights the section, where it seemed
/// to do nothing.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<void> open(WidgetTester tester, {String? groupId}) async {
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
    await tester.runAsync(() => db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
        id: 'g0', name: 'Web', createdAt: DateTime(2026, 10, 27), sortOrder: const Value(0))));
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
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => GroupEditorPanel.showAdaptive(context, groupId: groupId),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  testWidgets('Cancel closes the panel when nothing changed', (tester) async {
    await open(tester, groupId: 'g0');
    final cancel = find.byKey(const ValueKey('group-editor-cancel'));
    expect(tester.widget<ZestButton>(cancel).onPressed, isNotNull);
    await tester.tap(cancel);
    await settle(tester);
    expect(find.byType(GroupEditorPanel), findsNothing);
  });

  testWidgets('New group while a new group is open: the cursor in its name, and the section lit for a moment',
      (tester) async {
    await open(tester);
    final row = find.byKey(const ValueKey('group-new-row'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pump();
    await tester.pump();
    final name = find.descendant(
        of: find.byKey(const ValueKey('group-editor-section')), matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(name.first).focusNode.hasFocus, isTrue);
    final lit = tester.widget<AnimatedContainer>(find.byKey(const ValueKey('group-editor-section')));
    expect((lit.decoration as BoxDecoration?)?.color, isNot(Colors.transparent));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final after = tester.widget<AnimatedContainer>(find.byKey(const ValueKey('group-editor-section')));
    expect((after.decoration as BoxDecoration?)?.color, Colors.transparent);
    expect(find.text(l10n.zestGroupNewGroup), findsWidgets);
  });
}

/// Lets the database answer, then the frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}
