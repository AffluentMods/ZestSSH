// Arrange on a phone's Hosts list (3.1, a user's request): the chip row's
// Arrange puts a handle on each host's row; a host dragged by it takes its
// new place in its group, saved to the hosts' sortOrder as a computer's
// Manual sort saves it (so it syncs and a computer shows the same order),
// and the Manual sort is picked; Done leaves. Outside Arrange a long press
// still opens the host's menu and a tap connects; while arranging neither.

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/features/hosts/state/host_sort_mode.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_theme.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 24);
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-web', name: 'Web', createdAt: at));
    for (final (i, id) in ['web-01', 'web-02', 'web-03'].indexed) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id,
            host: '$id.example.internal',
            groupId: const Value('g-web'),
            sortOrder: Value(i),
            sizeTier: const Value(2),
            createdAt: at,
            updatedAt: at,
          ));
    }
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'db-01', label: 'db-01', host: '10.0.0.5', sortOrder: const Value(7), createdAt: at, updatedAt: at));
  });

  tearDown(() => db.close());

  final calls = <String>[];

  Future<ProviderContainer> pump(WidgetTester tester, Size size, {Set<String> hidden = const {}}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    calls.clear();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            final hosts = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
            // [hidden]: what a search leaves out.
            return PhoneHostsList(
              hosts: [for (final h in hosts) if (!hidden.contains(h.connection.id)) h],
              actionsOf: (h) => PhoneHostActions(
                connect: () => calls.add('connect ${h.connection.id}'),
                edit: () => calls.add('edit ${h.connection.id}'),
              ),
            );
          }),
        ),
      ),
    ));
    await settle(tester);
    return c;
  }

  Future<List<(String, int, int)>> saved() async {
    final rows = await (db.select(db.connections)
          ..where((t) => t.groupId.equals('g-web'))
          ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
        .get();
    return [for (final r in rows) (r.id, r.sortOrder, r.sizeTier)];
  }

  Finder row(String id) => find.byKey(ValueKey('phone-host-g-web-$id'));

  /// Drags [id] by its handle to just past the middle of [over]'s row.
  Future<void> drag(WidgetTester tester, String id, String over) async {
    final from = tester.getCenter(find.byKey(ValueKey('phone-host-drag-$id')));
    final dy = tester.getCenter(row(over)).dy - tester.getCenter(row(id)).dy;
    final gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 50));
    const steps = 10;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(0, (dy + dy.sign * 8) / steps));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  /// Arrange, from the sort on the list's first head (4.0: it was an icon at
  /// the chips' end).
  Future<void> openArrange(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('phone-hosts-sort')));
    await settle(tester);
    expect(find.byKey(const ValueKey('phone-sort-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('phone-sort-arrange')));
  }

  for (final size in const [Size(360, 780), Size(430, 932)]) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$at: Arrange, a host dragged into its place, saved and the Manual sort picked; Done leaves',
        (tester) async {
      final c = await pump(tester, size);
      expect(find.byKey(const ValueKey('phone-host-drag-web-01')), findsNothing, reason: 'no handles before Arrange');

      await openArrange(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey('phone-arrange-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-filter-chips')), findsNothing);
      expect(c.read(hostSortModeProvider), HostSortMode.manual, reason: 'the hosts in their own order to arrange');
      for (final id in ['web-01', 'web-02', 'web-03', 'db-01']) {
        expect(find.byKey(ValueKey('phone-host-drag-$id')), findsOneWidget, reason: id);
        expect(find.byKey(ValueKey('phone-host-more-$id')), findsNothing, reason: '$id: the handle in its button\'s place');
      }
      expect(tester.takeException(), isNull);

      await drag(tester, 'web-01', 'web-03');
      expect(await saved(), [('web-02', 0, 2), ('web-03', 1, 2), ('web-01', 2, 2)],
          reason: 'the new order in sortOrder, each size kept');
      expect(c.read(hostSortModeProvider), HostSortMode.manual);
      final ys = [for (final id in ['web-02', 'web-03', 'web-01']) tester.getCenter(row(id)).dy];
      expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue, reason: 'shown in that order');

      // While arranging, a tap does not connect and a long press opens nothing.
      await tester.tap(find.text('web-02'));
      await tester.longPress(find.text('web-02'));
      await settle(tester);
      expect(calls, isEmpty);
      expect(find.byKey(const ValueKey('phone-sheet-connect')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('phone-arrange-done')));
      await settle(tester);
      expect(find.byKey(const ValueKey('phone-arrange-bar')), findsNothing);
      expect(find.byKey(const ValueKey('phone-host-drag-web-01')), findsNothing);
      expect(find.byKey(const ValueKey('phone-filter-chips')), findsOneWidget);
      final after = [for (final id in ['web-02', 'web-03', 'web-01']) tester.getCenter(row(id)).dy];
      expect(after[0] < after[1] && after[1] < after[2], isTrue, reason: 'the saved order, after Done');
      expect(tester.takeException(), isNull);
      await finish(tester);
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));

    testWidgets('$at: outside Arrange a tap connects and a long press starts selecting, with that host', (tester) async {
      await pump(tester, size);
      await tester.tap(find.text('web-02'));
      await settle(tester);
      expect(calls, ['connect web-02']);
      await tester.longPress(find.text('web-02'));
      await settle(tester);
      expect(find.byKey(const ValueKey('phone-sheet-connect')), findsNothing, reason: 'no sheet: selecting (3.4)');
      expect(find.byKey(const ValueKey('phone-host-box-web-02')), findsOneWidget);
      expect(calls, ['connect web-02'], reason: 'a long press connects nothing');
      await finish(tester);
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android}));
  }

  testWidgets('a host the search hides keeps its place in the group when the others are arranged', (tester) async {
    await pump(tester, const Size(430, 932), hidden: {'web-02'});
    await openArrange(tester);
    await settle(tester);
    await drag(tester, 'web-03', 'web-01');
    expect(await saved(), [('web-03', 0, 2), ('web-02', 1, 2), ('web-01', 2, 2)]);
    await finish(tester);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}
