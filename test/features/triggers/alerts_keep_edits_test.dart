import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart'
    show refreshPersonState;
import 'package:zestssh/providers/trigger_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/triggers_view.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';

/// The Alerts page goes when the computer shows a terminal in its place, and
/// its editor's unsaved edits went with it, with no word. They are kept in
/// memory now, and the same editor opens again with them, unsaved. (All
/// names made up.)
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late SharedPreferences prefs;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(ProviderContainer, ValueNotifier<bool>)> open(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        triggerRuntimeProvider.overrideWith((ref) {
          final rt = TriggerRuntime.forTesting(ref);
          ref.onDispose(rt.dispose);
          return rt;
        }),
      ],
    );
    await tester.runAsync(
      () => container
          .read(triggerCrudProvider)
          .create(name: 'Disk full', pattern: 'No space left'),
    );
    final pageShown = ValueNotifier(true);
    addTearDown(pageShown.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: pageShown,
              builder: (_, shown, _) =>
                  shown ? const TriggersView() : const Text('a terminal'),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return (container, pageShown);
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(minutes: 5));
    await tester.runAsync(db.close);
  }

  Finder field(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(EditableText),
  );
  String textOf(WidgetTester tester, String key) =>
      tester.widget<EditableText>(field(key)).controller.text;
  ZestDetailScaffold scaffold(WidgetTester tester) =>
      tester.widget<ZestDetailScaffold>(find.byType(ZestDetailScaffold));
  bool prefsHold(String typed) => prefs.getKeys().any(
    (k) =>
        k.toLowerCase().contains('draft') || '${prefs.get(k)}'.contains(typed),
  );

  Future<void> awayAndBack(
    WidgetTester tester,
    ValueNotifier<bool> pageShown,
  ) async {
    pageShown.value = false;
    await settle(tester);
    expect(
      find.byType(TriggersView),
      findsNothing,
      reason: 'the page went, as it does for a terminal',
    );
    pageShown.value = true;
    await settle(tester);
  }

  Future<void> typeNew(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('alert-preset-ownText')));
    await settle(tester);
    await tester.enterText(field('alert-own-text'), 'deploy finished');
    await tester.enterText(field('alert-name'), 'Deploy done');
    await settle(tester);
  }

  testWidgets(
    'a new alert typed, a terminal, the page again: the editor as it was, unsaved; Save leaves nothing kept',
    (tester) async {
      final (container, pageShown) = await open(tester);
      expect(
        textOf(tester, 'alert-name'),
        en.alertsPresetErrors,
        reason: 'a new alert is named after its preset',
      );
      await typeNew(tester);
      await awayAndBack(tester, pageShown);

      expect(textOf(tester, 'alert-name'), 'Deploy done');
      expect(textOf(tester, 'alert-own-text'), 'deploy finished');
      expect(scaffold(tester).isDirty, isTrue, reason: 'shown as unsaved');
      expect(prefsHold('Deploy done'), isFalse, reason: 'kept in memory only');

      scaffold(tester).onSave!();
      await settle(tester);
      final saved = (await tester.runAsync(
        () => db.terminalTriggersDao.getAll(),
      ))!;
      expect(saved.where((t) => t.name == 'Deploy done'), hasLength(1));
      expect(container.read(alertDraftsProvider).isEmpty, isTrue);

      await awayAndBack(tester, pageShown);
      expect(
        textOf(tester, 'alert-name'),
        en.alertsPresetErrors,
        reason: 'nothing unsaved came back: a new alert, as before',
      );
      await finish(tester, container);
    },
  );

  testWidgets('an untouched new alert is no edit: nothing is kept', (
    tester,
  ) async {
    final (container, pageShown) = await open(tester);
    pageShown.value = false;
    await settle(tester);
    expect(container.read(alertDraftsProvider).isEmpty, isTrue);
    await finish(tester, container);
  });

  testWidgets(
    'a saved alert edited, a terminal, the page again: that alert with the edit, unsaved; Cancel lets it go',
    (tester) async {
      final (container, pageShown) = await open(tester);
      await tester.tap(find.text('Disk full').first);
      await settle(tester);
      expect(scaffold(tester).isDirty, isFalse);
      await tester.enterText(field('alert-name'), 'Disk full (prod)');
      await settle(tester);
      expect(scaffold(tester).isDirty, isTrue);
      await awayAndBack(tester, pageShown);

      expect(textOf(tester, 'alert-name'), 'Disk full (prod)');
      expect(scaffold(tester).isDirty, isTrue);
      expect(find.byKey(const ValueKey('alert-preset-ownText')), findsWidgets);

      expect(
        scaffold(tester).title,
        'Disk full',
        reason: 'the same alert, not a new one',
      );

      // Cancel: the edit goes (as before), nothing is kept.
      scaffold(tester).onCancel!();
      await settle(tester);
      await awayAndBack(tester, pageShown);
      expect(container.read(alertDraftsProvider).isEmpty, isTrue);
      expect(textOf(tester, 'alert-name'), en.alertsPresetErrors);
      await finish(tester, container);
    },
  );

  testWidgets('a change of profile forgets the edits, kept or on screen', (
    tester,
  ) async {
    final (container, pageShown) = await open(tester);
    await typeNew(tester);
    pageShown.value = false;
    await settle(tester);
    expect(container.read(alertDraftsProvider).isEmpty, isFalse);

    refreshPersonState(container);
    await settle(tester);
    expect(container.read(alertDraftsProvider).isEmpty, isTrue);
    pageShown.value = true;
    await settle(tester);
    expect(textOf(tester, 'alert-name'), en.alertsPresetErrors);

    await typeNew(tester);
    refreshPersonState(container);
    await settle(tester);
    expect(textOf(tester, 'alert-name'), en.alertsPresetErrors);
    pageShown.value = false;
    await settle(tester);
    expect(container.read(alertDraftsProvider).isEmpty, isTrue);
    expect(prefsHold('Deploy done'), isFalse);
    await finish(tester, container);
  });
}
