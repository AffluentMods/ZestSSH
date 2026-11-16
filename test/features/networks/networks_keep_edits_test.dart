import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/engine/network_detector.dart';
import 'package:zestssh/features/networks/engine/network_state.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/networks/pages/networks_page.dart';
import 'package:zestssh/features/networks/pages/networks_screen.dart';
import 'package:zestssh/features/networks/state/network_controller.dart';
import 'package:zestssh/features/networks/widgets/network_detail_pane.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/profile_providers.dart'
    show refreshPersonState;

/// The Networks page goes when the computer shows a terminal in its place,
/// and its editor's unsaved edits went with it, with no word. The editor is
/// kept in memory now, and opens again with them, unsaved. (All names and
/// addresses made up.)
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
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = (await tester.runAsync(() async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final repo = NetworkRepository(db.networksDao);
      await repo.ensureDefaultExists();
      await repo.create(
        const Network(
          id: 'n-office',
          name: 'Office',
          color: GroupColor.blue,
          icon: LucideIcons.building,
          triggers: [SsidTrigger('office-wifi')],
          isFallback: false,
        ),
      );
      return db;
    }))!;
    final fallback = Network.systemDefault();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        currentNetworkStateProvider.overrideWith(
          (ref) async => const NetworkState(
            localAddresses: ['10.50.0.42'],
            connectivityKind: ConnectivityKind.ethernet,
          ),
        ),
        detectedNetworkProvider.overrideWith((ref) => Stream.value(fallback)),
        detectedNetworkMatchProvider.overrideWith(
          (ref) => Stream.value(
            NetworkMatch(network: fallback, reason: const AlwaysTrigger()),
          ),
        ),
      ],
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
                  shown ? const NetworksPage() : const Text('a terminal'),
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

  NetworkDetailPane pane(WidgetTester tester) =>
      tester.widget<NetworkDetailPane>(find.byType(NetworkDetailPane));
  NetworkEditController editor(WidgetTester tester) => pane(tester).controller;
  Finder field(TextEditingController c) => find.byWidgetPredicate(
    (w) => w is EditableText && identical(w.controller, c),
  );
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
      find.byType(NetworksScreen),
      findsNothing,
      reason: 'the page went, as it does for a terminal',
    );
    pageShown.value = true;
    await settle(tester);
  }

  Future<void> typeNew(WidgetTester tester) async {
    final c = editor(tester);
    await tester.enterText(field(c.nameController), 'Lab-7 bench');
    c.addSubnet('10.50.0.0/24');
    await settle(tester);
    expect(c.isDirty, isTrue);
  }

  testWidgets(
    'a new network typed, a terminal, the page again: the form as it was, unsaved; Save leaves nothing kept',
    (tester) async {
      final (container, pageShown) = await open(tester);
      await typeNew(tester);
      await awayAndBack(tester, pageShown);

      var c = editor(tester);
      expect(c.isCreating, isTrue);
      expect(c.isDirty, isTrue, reason: 'shown as unsaved');
      expect(c.nameController.text, 'Lab-7 bench');
      expect(c.triggers.single.textController?.text, '10.50.0.0/24');
      expect(prefsHold('10.50.0.0/24'), isFalse, reason: 'kept in memory only');

      final saving = pane(tester).onSave();
      await settle(tester);
      expect(await saving, isTrue);
      final saved = (await tester.runAsync(
        () => NetworkRepository(db.networksDao).list(),
      ))!;
      expect(saved.where((n) => n.name == 'Lab-7 bench'), hasLength(1));
      expect(container.read(networkDraftsProvider).isEmpty, isTrue);

      await awayAndBack(tester, pageShown);
      c = editor(tester);
      expect(c.isDirty, isFalse, reason: 'nothing unsaved came back');
      expect(
        c.isCreating,
        isTrue,
        reason: 'the page opens on a new network, as before',
      );
      expect(c.nameController.text, isEmpty);
      await finish(tester, container);
    },
  );

  testWidgets(
    'a saved network edited, a terminal, the page again: that network with the edit, unsaved; Cancel and Discard '
    'leave nothing kept',
    (tester) async {
      final (container, pageShown) = await open(tester);
      await tester.tap(find.text('Office').first);
      await settle(tester);
      var c = editor(tester);
      expect(c.original?.id, 'n-office');
      await tester.enterText(field(c.nameController), 'Office (2nd floor)');
      await settle(tester);
      await awayAndBack(tester, pageShown);

      c = editor(tester);
      expect(c.original?.id, 'n-office');
      expect(c.nameController.text, 'Office (2nd floor)');
      expect(c.isDirty, isTrue);

      pane(tester).onClose();
      await settle(tester);
      await tester.tap(find.text(en.zestDiscardDiscard).last);
      await settle(tester);
      expect(editor(tester).isCreating, isTrue);
      await awayAndBack(tester, pageShown);
      expect(editor(tester).isDirty, isFalse);
      expect(editor(tester).isCreating, isTrue);
      final saved = (await tester.runAsync(
        () => NetworkRepository(db.networksDao).list(),
      ))!;
      expect(
        saved.where((n) => n.id == 'n-office').single.name,
        'Office',
        reason: 'nothing was saved',
      );
      await finish(tester, container);
    },
  );

  testWidgets(
    'another network picked with unsaved edits still asks first, as before',
    (tester) async {
      final (container, _) = await open(tester);
      await typeNew(tester);
      await tester.tap(find.text('Office').first);
      await settle(tester);
      expect(find.text(en.zestDiscardDiscard), findsWidgets);
      await tester.tap(find.text(en.zestDiscardDiscard).last);
      await settle(tester);
      expect(editor(tester).original?.id, 'n-office');
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
    expect(container.read(networkDraftsProvider).isEmpty, isFalse);

    refreshPersonState(container);
    await settle(tester);
    expect(container.read(networkDraftsProvider).isEmpty, isTrue);
    pageShown.value = true;
    await settle(tester);
    expect(editor(tester).isDirty, isFalse);
    expect(editor(tester).nameController.text, isEmpty);

    await typeNew(tester);
    refreshPersonState(container);
    await settle(tester);
    expect(editor(tester).nameController.text, isEmpty);
    pageShown.value = false;
    await settle(tester);
    expect(container.read(networkDraftsProvider).isEmpty, isTrue);
    expect(prefsHold('Lab-7 bench'), isFalse);
    await finish(tester, container);
  });
}
