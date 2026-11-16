import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/command_history/command_history_screen.dart';
import 'package:zestssh/ui/widgets/locked_feature_view.dart';
import 'package:zestssh/ui/screens/triggers/triggers_screen.dart';
import 'package:zestssh/ui/widgets/button_box.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';

class _Free extends StateNotifier<bool> implements ProStatusNotifier {
  _Free() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The buttons of an empty page are the same on every page (3.0, 18 October
/// 2026): 36 high with corners of 6, as the empty state's own. Triggers'
/// and the command history's were pills of their own, beside the Keys,
/// Port forwarding and Networks pages' squarer ones (the command history's
/// is the locked page's card since 4.0).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> pump(WidgetTester tester, Widget screen) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        isProProvider.overrideWith((ref) => _Free()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: screen,
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The corners of [button]'s shape, which must be 6.
  void cornersOfSix(WidgetTester tester, Finder button) {
    final style = tester.widget<ButtonStyleButton>(button).style!;
    final shape = style.shape!.resolve(<WidgetState>{}) as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(6));
  }

  testWidgets("Triggers' two buttons, 36 high with corners of 6", (tester) async {
    await pump(tester, const TriggersScreen());
    final empty = find.byType(ZestEmptyState);
    expect(empty, findsOneWidget);
    final boxes = find.descendant(of: empty, matching: find.byType(ButtonBox));
    expect(boxes, findsNWidgets(2));
    for (final label in [en.trgNewTrigger, en.trgAddExamples]) {
      final button = find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
      expect(tester.getSize(button.first).height, 36, reason: label);
      cornersOfSix(tester, button.first);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  });

  // The command history before Squeezed is a page of its own now (4.0, the
  // locked page): the page in use, faded, behind a card with its buy button,
  // not an empty state with Upgrade (test/ui/locked_feature_view_test.dart).
  testWidgets("the command history before Squeezed is the locked page, not an empty state's Upgrade", (tester) async {
    await pump(tester, const CommandHistoryScreen());
    expect(find.byType(ZestEmptyState), findsNothing);
    expect(find.byType(LockedFeatureView), findsOneWidget);
    expect(find.text('Upgrade to Squeezed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  });
}
