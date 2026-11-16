import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/groups/widgets/group_editor_panel.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart' show debugTopSnackBarOnPhone;
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// Groups on a phone and a tablet (3.0.1, as designed;
/// its New group chip at the far right went into the +'s menu in 4.0):
/// New group from a host's Move to a group (the host moves in, said with
/// Undo), from the host editor's group list (the form has it) and the +;
/// a long press on a group's chip or header: Edit group (renames,
/// recolours, its hosts), Delete group (asks; its hosts stay, ungrouped).
/// In a team's space, only who may add to the vault sees any of it. A
/// computer's host editor is as it was.

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _phone = Size(430, 932);
const _tablet = Size(1024, 1366);

/// Where each flow is tried: an iPhone, an Android phone, an iPad.
const _devices = [
  ('an iPhone', _phone, TargetPlatform.iOS),
  ('an Android phone', _phone, TargetPlatform.android),
  ('an iPad', _tablet, TargetPlatform.iOS),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);

  late AppDatabase db;
  late WidgetTester current;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await settle(tester);
  }

  Future<void> longPress(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.longPress(target);
    await settle(tester);
  }

  /// The host's own sheet on a phone (3.4): a long press selects it, and the
  /// selection's More offers its Host actions.
  Future<void> hostSheet(WidgetTester tester, Finder row) async {
    await longPress(tester, row);
    await tap(tester, find.descendant(of: find.byKey(const ValueKey('phone-selection-actions')), matching: find.byKey(const ValueKey('phone-tab-4'))));
    await tap(tester, find.byKey(const ValueKey('phone-selection-host-actions')));
  }

  Future<List<ConnectionGroup>> groups() async =>
      (await current.runAsync(() => db.select(db.connectionGroups).get()))!;

  Future<String?> groupOf(String hostId) async => (await current.runAsync(
          () => (db.select(db.connections)..where((c) => c.id.equals(hostId))).getSingle()))!
      .groupId;

  /// Web (db-primary, web-01) and log-store in no group, on a device of
  /// [size] and [platform]; [orchard] on screen when given.
  Future<void> seed(WidgetTester tester, Size size, TargetPlatform platform) async {
    current = tester;
    debugDefaultTargetPlatformOverride = platform;
    debugTouchLayout = true;
    debugTopSnackBarOnPhone = true;
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 23);
    await tester.runAsync(() async {
      await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
            id: 'g-web',
            name: 'Web',
            colorIndex: const Value(3),
            createdAt: now,
            updatedAt: Value(now),
          ));
      for (final (id, label, group) in [('c0', 'db-primary', 'g-web'), ('c1', 'web-01', 'g-web'), ('c2', 'log-store', null)]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: label,
              host: '192.168.10.${21 + int.parse(id.substring(1))}',
              groupId: Value(group),
              createdAt: now,
              updatedAt: now,
            ));
      }
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<ProviderContainer> pumpHome(WidgetTester tester, Size size, TargetPlatform platform,
      {OrchardSummary? orchard}) async {
    await seed(tester, size, platform);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      currentUserProvider.overrideWith((_) => null),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      recordingModeProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 23, 12))),
      if (orchard != null) ...[
        activeSpaceProvider.overrideWith((ref) => OrchardSpace(orchard.id)),
        activeOrchardProvider.overrideWithValue(AsyncData(orchard)),
      ],
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text('route ${state.uri.path}'))),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: router,
      ),
    ));
    await settle(tester);
    return container;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
    debugDefaultTargetPlatformOverride = null;
    debugTouchLayout = null;
    debugTopSnackBarOnPhone = null;
  }

  /// New group's sheet (a phone) or pane (a tablet): [name] typed, Create.
  Future<void> createGroup(WidgetTester tester, Size size, String name) async {
    expect(find.byKey(const ValueKey('group-new-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('group-side-pane')), size == _tablet ? findsOneWidget : findsNothing,
        reason: 'a tablet has a side pane, as a computer; a phone a sheet');
    final field = find.byKey(const ValueKey('group-name-field'));
    expect(tester.widget<TextField>(field).autofocus, isTrue, reason: 'the keyboard opens on the name');
    final create = find.byKey(const ValueKey('group-new-create'));
    await tap(tester, create);
    expect(find.byKey(const ValueKey('group-new-sheet')), findsOneWidget, reason: 'a name is needed');
    await tester.enterText(field, name);
    await settle(tester);
    await tap(tester, create);
    expect(find.byKey(const ValueKey('group-new-sheet')), findsNothing);
  }

  for (final (device, size, platform) in _devices) {
    testWidgets('on $device: New group from Move to a group makes the group and moves the host in, with Undo',
        (tester) async {
      await pumpHome(tester, size, platform);
      await hostSheet(tester, find.text('log-store'));
      await tap(tester, find.byKey(const ValueKey('phone-sheet-group')));
      // The sheet says what it is (the host's sheet under it has the row).
      expect(find.descendant(of: find.byKey(const ValueKey('zest-sheet')).last, matching: find.text(l10n.phoneHostsMoveToGroup)),
          findsOneWidget);
      final newRow = find.byKey(const ValueKey('phone-group-new'));
      expect(newRow, findsOneWidget);
      // The last row.
      expect(tester.getTopLeft(newRow).dy, greaterThan(tester.getTopLeft(find.byKey(const ValueKey('phone-group-none'))).dy));
      await tap(tester, newRow);
      expect(find.text(l10n.phoneGroupsGoesInto('log-store')), findsOneWidget);
      await createGroup(tester, size, 'Staging');
      final staging = (await groups()).singleWhere((g) => g.name == 'Staging');
      expect(await groupOf('c2'), staging.id);
      expect(staging.sortOrder, 1, reason: 'after every group, as a computer makes it');
      expect(find.text(l10n.phoneGroupsMovedHost('log-store', 'Staging')), findsOneWidget);
      await tap(tester, find.text(l10n.hostsSelUndo));
      expect(await groupOf('c2'), isNull, reason: 'Undo puts the host back');
      expect((await groups()).any((g) => g.name == 'Staging'), isTrue, reason: 'the group stays');
      await finish(tester);
    });

    // (4.0: New group is in the +'s menu; it was a chip at the far right of
    // the chips, a row of controls fewer.)
    testWidgets('on $device: no New group chip; the group made from the + is picked, to be filled', (tester) async {
      await pumpHome(tester, size, platform);
      expect(find.byKey(const ValueKey('phone-filter-new-group')), findsNothing);
      await tap(tester, find.byKey(const ValueKey('phone-new-host')));
      await tap(tester, find.byKey(const ValueKey('phone-new-menu-group')));
      await createGroup(tester, size, 'Lab');
      final lab = (await groups()).singleWhere((g) => g.name == 'Lab');
      expect(find.byKey(ValueKey('phone-filter-${lab.id}')), findsOneWidget, reason: 'an empty group keeps its chip');
      expect(find.byKey(ValueKey('phone-group-empty-${lab.id}')), findsOneWidget, reason: 'it is picked, and empty');
      expect(find.text('web-01'), findsNothing);
      await finish(tester);
    });

    testWidgets('on $device: the + offers New host and New group', (tester) async {
      await pumpHome(tester, size, platform);
      await tap(tester, find.byKey(const ValueKey('phone-new-host')));
      expect(find.byKey(const ValueKey('phone-new-menu-host')), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('phone-new-menu-group')));
      await createGroup(tester, size, 'Backups');
      expect((await groups()).map((g) => g.name), contains('Backups'));
      await tap(tester, find.byKey(const ValueKey('phone-new-host')));
      await tap(tester, find.byKey(const ValueKey('phone-new-menu-host')));
      expect(find.text('route /connection/edit'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('on $device: a long press on a group chip edits the group', (tester) async {
      await pumpHome(tester, size, platform);
      await longPress(tester, find.byKey(const ValueKey('phone-filter-g-web')));
      expect(find.byKey(const ValueKey('group-actions-sheet')), findsOneWidget);
      expect(find.text(l10n.hostsSelDragCount(2)), findsOneWidget);
      expect(find.byKey(const ValueKey('group-action-new')), findsOneWidget);
      expect(find.text(l10n.phoneGroupsDeleteMore), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('group-action-edit')));
      if (size == _tablet) {
        // A tablet: the computer's group editor, as it is.
        final panel = find.byType(GroupEditorPanel);
        expect(panel, findsOneWidget);
        expect(find.byKey(const ValueKey('group-edit-sheet')), findsNothing);
        await tester.enterText(find.descendant(of: panel, matching: find.byType(TextField)).first, 'Web servers');
        await settle(tester);
        await tap(tester, find.descendant(of: panel, matching: find.text(l10n.save)));
        expect((await groups()).single.name, 'Web servers');
      } else {
        expect(find.byKey(const ValueKey('group-edit-sheet')), findsOneWidget);
        expect(find.byKey(const ValueKey('group-edit-member-c0')), findsOneWidget);
        expect(find.byKey(const ValueKey('group-edit-member-c2')), findsNothing);
        await tester.enterText(find.byKey(const ValueKey('group-name-field')), 'Web servers');
        await tap(tester, find.byKey(const ValueKey('group-swatch-5')));
        // Out with db-primary, in with log-store, from the picker.
        await tap(tester, find.byKey(const ValueKey('group-edit-remove-c0')));
        expect(find.byKey(const ValueKey('group-edit-member-c0')), findsNothing);
        await tap(tester, find.byKey(const ValueKey('group-edit-add-hosts')));
        expect(find.byKey(const ValueKey('group-pick-c0')), findsOneWidget, reason: 'taken out, it may go back');
        await tap(tester, find.byKey(const ValueKey('group-pick-c2')));
        await tap(tester, find.byKey(const ValueKey('group-pick-add')));
        expect(find.byKey(const ValueKey('group-edit-member-c2')), findsOneWidget);
        expect((await groups()).single.name, 'Web', reason: 'nothing is written before Save');
        expect(await groupOf('c0'), 'g-web');
        await tap(tester, find.byKey(const ValueKey('group-edit-save')));
        expect(find.byKey(const ValueKey('group-edit-sheet')), findsNothing);
        final web = (await groups()).single;
        expect(web.name, 'Web servers');
        expect(web.colorIndex, 5);
        expect(web.colorValue, isNull);
        expect(await groupOf('c0'), isNull);
        expect(await groupOf('c1'), 'g-web');
        expect(await groupOf('c2'), 'g-web');
        // The chip says the new name, in the new colour's group.
        expect(find.text('Web servers'), findsWidgets);
        expect(AppColors.v3GroupColors[5], isNotNull);
      }
      await finish(tester);
    });

    testWidgets('on $device: Delete group from a group\'s header asks, and keeps its hosts, ungrouped',
        (tester) async {
      await pumpHome(tester, size, platform);
      await longPress(tester, find.byKey(const ValueKey('phone-section-g-web')));
      await tap(tester, find.byKey(const ValueKey('group-action-delete')));
      expect(find.text(l10n.zestGroupDeleteConfirm(2)), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('zest-dialog-primary')));
      expect(await groups(), isEmpty);
      expect(await groupOf('c0'), isNull);
      expect(await groupOf('c1'), isNull);
      expect(find.text('db-primary'), findsOneWidget, reason: 'the hosts stay');
      expect(find.text('web-01'), findsOneWidget);
      await finish(tester);
    });
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('on a phone (${platform.name}): Delete group inside Edit group asks, and keeps its hosts',
        (tester) async {
      await pumpHome(tester, _phone, platform);
      await longPress(tester, find.byKey(const ValueKey('phone-filter-g-web')));
      await tap(tester, find.byKey(const ValueKey('group-action-edit')));
      expect(find.text(l10n.phoneGroupsDeleteKeeps), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('group-edit-delete')));
      await tap(tester, find.byKey(const ValueKey('zest-dialog-secondary')));
      expect(await groups(), hasLength(1), reason: 'Cancel keeps it');
      await tap(tester, find.byKey(const ValueKey('group-edit-delete')));
      await tap(tester, find.byKey(const ValueKey('zest-dialog-primary')));
      expect(find.byKey(const ValueKey('group-edit-sheet')), findsNothing);
      expect(await groups(), isEmpty);
      expect(await groupOf('c0'), isNull);
      expect(find.text('db-primary'), findsOneWidget);
      await finish(tester);
    });
  }

  testWidgets('in a team space, only who may add to the vault sees New group, Edit and Delete', (tester) async {
    OrchardSummary team(Set<String> switches) => OrchardSummary(
          id: 'o-1',
          name: 'Acme',
          role: 'member',
          crates: [CrateSummary(id: 'k-1', name: 'Servers', level: 'use', switches: switches)],
          defaultCrateId: 'k-1',
        );
    await pumpHome(tester, _phone, TargetPlatform.iOS,
        orchard: team({CrateSwitches.connect, CrateSwitches.edit}));
    expect(find.byKey(const ValueKey('phone-filter-g-web')), findsOneWidget);
    // New group is the +'s (4.0), and there is no + here.
    expect(find.byKey(const ValueKey('phone-new-host')), findsNothing);
    await hostSheet(tester, find.text('log-store'));
    await tap(tester, find.byKey(const ValueKey('phone-sheet-group')));
    expect(find.byKey(const ValueKey('phone-group-none')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-group-new')), findsNothing);
    Navigator.of(tester.element(find.byKey(const ValueKey('zest-sheet')).last)).pop();
    await settle(tester);
    Navigator.of(tester.element(find.byKey(const ValueKey('zest-sheet')))).pop();
    await settle(tester);
    await longPress(tester, find.byKey(const ValueKey('phone-section-g-web')));
    expect(find.byKey(const ValueKey('group-actions-sheet')), findsNothing);
    // (A long press with nothing to offer is a tap: the chip is picked.)
    await longPress(tester, find.byKey(const ValueKey('phone-filter-g-web')));
    expect(find.byKey(const ValueKey('group-actions-sheet')), findsNothing);
    await finish(tester);

    await pumpHome(tester, _phone, TargetPlatform.iOS, orchard: team(CrateSwitches.all));
    await tap(tester, find.byKey(const ValueKey('phone-new-host')));
    expect(find.byKey(const ValueKey('phone-new-menu-group')), findsOneWidget);
    Navigator.of(tester.element(find.byKey(const ValueKey('zest-sheet')))).pop();
    await settle(tester);
    await longPress(tester, find.byKey(const ValueKey('phone-filter-g-web')));
    expect(find.byKey(const ValueKey('group-actions-sheet')), findsOneWidget);
    await finish(tester);
  }, skip: !kOrchardsEnabled);

  // ── The host editor's group list ──────────────────────────────────────

  Future<void> pumpEditor(WidgetTester tester, Size size, TargetPlatform platform, {bool touch = true}) async {
    await seed(tester, size, platform);
    debugTouchLayout = touch;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // A phone's and a tablet's editor is a page; a computer's a dialog.
        home: touch
            ? const ConnectionEditScreen(connectionId: 'c1')
            : Scaffold(body: ConnectionEditScreen(connectionId: 'c1', inDialog: true, onClose: () {})),
      ),
    ));
    await settle(tester);
  }

  /// The host editor's group list (on any of its tabs).
  ZestSelect<String?> groupList(WidgetTester tester) => tester.widget<ZestSelect<String?>>(find.byWidgetPredicate(
      (w) => w is ZestSelect<String?> && w.items.any((i) => i.value == 'g-web'),
      description: 'the group list',
      skipOffstage: false));

  for (final (device, size, platform) in _devices) {
    testWidgets('on $device: the host editor\'s group list ends with New group, and the form has the group made',
        (tester) async {
      await pumpEditor(tester, size, platform);
      // New group comes after the groups, as what the list does rather than
      // a group to choose.
      final actions = groupList(tester).actions;
      expect(actions.last.key, const ValueKey('host-group-new'));
      expect(groupList(tester).value, 'g-web');
      actions.last.onPressed();
      await settle(tester);
      expect(find.text(l10n.phoneGroupsGoesInto('web-01')), findsOneWidget);
      await createGroup(tester, size, 'Edge');
      final edge = (await groups()).singleWhere((g) => g.name == 'Edge');
      expect(groupList(tester).value, edge.id, reason: 'the new group is picked in the form');
      expect(await groupOf('c1'), 'g-web', reason: 'the host moves when it is saved');
      await finish(tester);
    });
  }

  testWidgets('a computer\'s host editor is as it was: its group list has no New group', (tester) async {
    await pumpEditor(tester, const Size(1300, 1400), TargetPlatform.windows, touch: false);
    final items = groupList(tester).items;
    expect(items.map((i) => i.value), [null, 'g-web']);
    expect(groupList(tester).actions, isEmpty);
    expect(find.byKey(const ValueKey('host-group-new'), skipOffstage: false), findsNothing);
    await finish(tester);
  });
}
