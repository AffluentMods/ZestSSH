import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/groups/widgets/group_editor_panel.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';

/// The Groups panel's list of every group (found in a code review): it
/// was a list that could not scroll, shrink-wrapped inside the panel's scroll
/// view, so a group dragged to the panel's lower edge stopped there and could
/// not be taken past the groups in view. Now the list is part of the panel's
/// one scrollable, which scrolls on under a drag.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('a group dragged to the lower edge scrolls the panel on, and lands past the groups that were in view',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById('default_dark');
    AppColors.applyTheme(theme.colorScheme);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
            id: 'g$i', name: 'Group ${i + 1}', createdAt: DateTime(2026, 10, 22), sortOrder: Value(i)));
      }
    });
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
              onPressed: () => GroupEditorPanel.showAdaptive(context, groupId: 'g0'),
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

    final panel = find.byType(GroupEditorPanel);
    final body = find.descendant(of: panel, matching: find.byType(Scrollable)).first;
    final position = tester.state<ScrollableState>(body).position;
    expect(position.pixels, 0);
    expect(position.maxScrollExtent, greaterThan(400), reason: 'thirty groups run past the panel');
    final view = tester.getRect(body);

    // Group 1's handle, held and taken down to the panel's lower edge.
    final handle = find.descendant(of: panel, matching: find.byIcon(LucideIcons.gripVertical)).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    final target = Offset(tester.getCenter(handle).dx, view.bottom - 6);
    final from = tester.getCenter(handle);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(from, target, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(position.pixels, greaterThan(100), reason: 'the panel scrolled on under the drag');
    await gesture.up();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // Group 1 is no longer first: it went past the groups that were in view.
    position.jumpTo(0);
    await tester.pump();
    final firstRowName = find.descendant(of: panel, matching: find.textContaining('Group ')).first;
    expect((tester.widget<Text>(firstRowName).data), isNot('Group 1'));
    expect(find.text('Group 1'), findsNothing, reason: 'Group 1 now sits below the groups first in view');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  });
}
