import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_edit_dialog.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_panel.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_save_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/features/sftp/sftp_pane_paths.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';

import '../../visual/shots_util.dart';

/// Save layout as workspace (a design review found it always
/// took every open tab and pane, so other terminals had to be closed first) and
/// a workspace's panel on the Hosts page (a click connected everything at once).
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  /// While set, only these hosts open: a plan's limit reached for the rest.
  Set<String>? onlyOpens;

  void seed(String id, String connectionId, {String? label}) => state = {...state, id: _state(id, connectionId, label)};

  SessionState _state(String id, String connectionId, String? label) => SessionState(
        status: SessionStatus.connected,
        connectionId: connectionId,
        connectionLabel: label ?? connectionId,
        host: 'example.com',
        port: 22,
        session: TerminalSession(
          id: id,
          connectionId: connectionId,
          terminal: Terminal(),
          shell: _Shell(),
          startedAt: DateTime(2026, 10, 22),
        ),
      );

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false,
      String? usernameOverride,
      String? initialCommand,
      String? asAccount,
      bool unattended = false,
      Space? space}) {
    if (onlyOpens != null && !onlyOpens!.contains(connection.id)) return null;
    final id = 'new-${connection.id}-${state.length}';
    seed(id, connection.id);
    return id;
  }
}

class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

Future<void> nameItNow(WidgetTester tester, String name) async {
  await tester.enterText(find.byType(TextField).first, name);
  await tester.pumpAndSettle();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final at = DateTime(2026, 10, 1);

  late AppDatabase db;
  late ProviderContainer container;
  late _Sessions sessions;
  late String tabA;
  late String tabB;

  /// Two tabs: A with web-01 and web-02 side by side (group Nodes), B with
  /// db-01 (no group) and a local shell made for the moment.
  Future<void> setUpApp() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-nodes', name: 'Nodes', createdAt: at));
    for (final (id, label, group) in [
      ('h-web1', 'web-01', 'g-nodes'),
      ('h-web2', 'web-02', 'g-nodes'),
      ('h-db', 'db-01', null),
    ]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: '$label.example.com',
            groupId: Value(group),
            createdAt: at,
            updatedAt: at,
          ));
    }
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    sessions = container.read(activeSessionsProvider.notifier) as _Sessions;
    container.read(savedTabGroupsProvider);
    await LocalStateStore(db).write('desktop_saved_tab_groups', jsonEncode(const []));
    container.listen(connectionsWithDetailsProvider, (_, _) {});
    await container.read(connectionsWithDetailsProvider.future);
    sessions.seed('s-web1', 'h-web1', label: 'web-01');
    sessions.seed('s-web2', 'h-web2', label: 'web-02');
    sessions.seed('s-db', 'h-db', label: 'db-01');
    sessions.seed('s-local', 'local_1', label: 'Local shell');
    final tabs = container.read(workTabsProvider.notifier);
    tabA = tabs.createTab('s-web1');
    tabs.replaceTabTree(
      tabA,
      PaneSplit(
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'l-web1', sessionIds: ['s-web1']),
        second: PaneLeaf(id: 'l-web2', sessionIds: ['s-web2']),
      ),
    );
    tabB = tabs.createTab('s-db');
    tabs.replaceTabTree(
      tabB,
      PaneSplit(
        axis: Axis.vertical,
        first: PaneLeaf(id: 'l-db', sessionIds: ['s-db']),
        second: PaneLeaf(id: 'l-local', sessionIds: ['s-local']),
      ),
    );
    tabs.setActiveTab(tabA);
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> pumpSave(WidgetTester tester, {Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => WorkspaceSaveDialog.show(context),
              child: const Text('save'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
  }

  // Pictures, with the real fonts: --dart-define=ZEST_SHOTS=true.
  testWidgets('pictures: Choose tabs, and the panel', (tester) async {
    await tester.runAsync(loadShotFonts);
    await tester.runAsync(setUpApp);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById('graphite');
    AppColors.applyTheme(theme.colorScheme);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            backgroundColor: AppColors.v3Background,
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => WorkspaceSaveDialog.show(context),
                child: const Text('save'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    await nameItNow(tester, 'Production stack');
    await saveShot(tester, key, 'review_workspace_this_tab');
    await tester.tap(find.text(l10n.workspaceScopeChoose));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'review_workspace_choose');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }, skip: !shotsEnabled);

  Future<void> nameIt(WidgetTester tester, String name) async {
    await tester.enterText(find.byType(TextField).first, name);
    await tester.pumpAndSettle();
  }

  Future<void> pressSave(WidgetTester tester) async {
    await tester.tap(find.text(l10n.save));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }

  SavedTabGroup savedNamed(String name) =>
      container.read(savedTabGroupsProvider).firstWhere((g) => g.name == name);

  // Pictures, with the real fonts: --dart-define=ZEST_SHOTS=true.
  testWidgets('pictures: Update, what it saves and its question', (tester) async {
    await tester.runAsync(loadShotFonts);
    await tester.runAsync(setUpApp);
    final store = container.read(savedTabGroupsProvider.notifier);
    final id = store.saveCaptured('Ops', (
      tabs: [
        TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: 'h-web1')),
        TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: 'h-web2')),
        TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: 'h-db')),
      ],
      hostNames: const {'h-web1': 'web-01', 'h-web2': 'web-02', 'h-db': 'db-01'},
    ));
    sessions.onlyOpens = {'h-web1'};
    await tester.runAsync(() => launchWorkspace(_RefOf(container), id));
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById('graphite');
    AppColors.applyTheme(theme.colorScheme);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(onPressed: () => WorkspaceSaveDialog.show(context), child: const Text('save')),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'workspace-update-offer');
    final update = find.byKey(const ValueKey('workspace-update'));
    await tester.ensureVisible(update);
    await tester.pumpAndSettle();
    await tester.tap(update);
    await tester.pumpAndSettle();
    await saveShot(tester, key, 'workspace-update-question');
    await tester.tap(find.text(l10n.cancel).last);
    await tester.pumpAndSettle();
  }, skip: !shotsEnabled);

  group('the choice at the top', () {
    setUp(() => NotificationCenter.debugToastsDrawn = true);
    tearDown(() => NotificationCenter.debugToastsDrawn = null);

    testWidgets('This tab is the default: the tab in front, with its splits, and no other', (tester) async {
      await tester.runAsync(setUpApp);
      await pumpSave(tester);
      expect(tester.widget<ZestModeToggle>(find.byKey(const ValueKey('workspace-scope'))).selectedId,
          WorkspaceSaveScope.thisTab.name);
      await nameIt(tester, 'Web');
      expect(find.text(workspaceCount(l10n, 1, 2)), findsOneWidget);
      await pressSave(tester);
      final saved = savedNamed('Web');
      expect(saved.tabs, hasLength(1));
      expect(saved.tabs.single.paneTreeOfConnIds, isA<PaneSplit>(), reason: 'its split stays');
      expect(saved.tabs.single.paneTreeOfConnIds.allLeaves.map((l) => l.sessionIds.single), ['h-web1', 'h-web2']);
      expect(saved.hostNames, {'h-web1': 'web-01', 'h-web2': 'web-02'});
    });

    testWidgets('All tabs takes both; a pane with no saved host is left out and its tab stays', (tester) async {
      await tester.runAsync(setUpApp);
      await pumpSave(tester);
      await tester.tap(find.text(l10n.workspaceScopeAllTabs));
      await tester.pumpAndSettle();
      await nameIt(tester, 'Everything');
      expect(find.text(workspaceCount(l10n, 2, 3)), findsOneWidget);
      await pressSave(tester);
      final saved = savedNamed('Everything');
      expect(saved.tabs, hasLength(2));
      expect(saved.tabs[1].paneTreeOfConnIds, isA<PaneLeaf>(), reason: 'the local shell is out, its split gone');
      expect(saved.tabs[1].paneTreeOfConnIds.allLeaves.single.sessionIds.single, 'h-db');
    });

    testWidgets('with no tab in front it starts on All tabs, and This tab says why it cannot be picked', (tester) async {
      await tester.runAsync(setUpApp);
      container.read(workTabsProvider.notifier).clearActiveTab();
      await pumpSave(tester);
      final scope = tester.widget<ZestModeToggle>(find.byKey(const ValueKey('workspace-scope')));
      expect(scope.selectedId, WorkspaceSaveScope.allTabs.name);
      final thisTab = scope.segments.firstWhere((s) => s.id == WorkspaceSaveScope.thisTab.name);
      expect(thisTab.enabled, isFalse);
      expect(thisTab.disabledReason, l10n.workspaceScopeNoTab);
    });

    testWidgets('a name already taken asks, and Replace keeps the choice made', (tester) async {
      await tester.runAsync(setUpApp);
      container.read(savedTabGroupsProvider.notifier).saveCaptured(
            'Web',
            container.read(savedTabGroupsProvider.notifier).captureTabs(container.read(workTabsProvider).tabs)!,
          );
      await pumpSave(tester);
      await nameIt(tester, 'Web');
      await tester.tap(find.text(l10n.workspaceReplaceNamed('Web')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(container.read(savedTabGroupsProvider), hasLength(1));
      expect(savedNamed('Web').tabs, hasLength(1), reason: 'now only the tab in front');
    });
  });

  group('Choose tabs', () {
    setUp(() => NotificationCenter.debugToastsDrawn = true);
    tearDown(() => NotificationCenter.debugToastsDrawn = null);

    Future<void> openChoose(WidgetTester tester) async {
      await tester.runAsync(setUpApp);
      await pumpSave(tester);
      await tester.tap(find.text(l10n.workspaceScopeChoose));
      await tester.pumpAndSettle();
    }

    Future<void> tick(WidgetTester tester, String key) async {
      final row = find.byKey(ValueKey(key));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }

    testWidgets('lists every tab and its panes, starting from the tab in front', (tester) async {
      await openChoose(tester);
      expect(find.text(l10n.workspacePickTabNumber(1)), findsOneWidget);
      expect(find.text(l10n.workspacePickTabNumber(2)), findsOneWidget);
      expect(find.byKey(const ValueKey('workspace-pick-pane-l-web1')), findsOneWidget);
      expect(find.byKey(const ValueKey('workspace-pick-pane-l-db')), findsOneWidget);
      expect(find.text(workspaceCount(l10n, 1, 2)), findsOneWidget, reason: 'the strip follows the choice');
    });

    testWidgets('a tab\'s box ticks its panes, each pane its own; the strip follows, and what is saved is what is ticked',
        (tester) async {
      await openChoose(tester);
      await nameIt(tester, 'Picked');
      await tick(tester, 'workspace-pick-pane-l-web2');
      expect(find.text(workspaceCount(l10n, 1, 1)), findsOneWidget);
      await tick(tester, 'workspace-pick-tab-$tabB');
      expect(find.text(workspaceCount(l10n, 2, 2)), findsOneWidget);
      await pressSave(tester);
      final saved = savedNamed('Picked');
      expect(saved.tabs.map((t) => t.paneTreeOfConnIds.allLeaves.single.sessionIds.single), ['h-web1', 'h-db']);
    });

    testWidgets('in a language written right to left a pane is indented from the right', (tester) async {
      await tester.runAsync(setUpApp);
      await pumpSave(tester, locale: const Locale('ar'));
      await tester.tap(find.text(lookupAppLocalizations(const Locale('ar')).workspaceScopeChoose));
      await tester.pumpAndSettle();
      Finder boxIn(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Checkbox));
      final tabBox = tester.getTopRight(boxIn('workspace-pick-tab-$tabA'));
      final paneBox = tester.getTopRight(boxIn('workspace-pick-pane-l-web1'));
      expect(paneBox.dx, lessThan(tabBox.dx), reason: 'further in from where the line starts');
      expect(tabBox.dx - paneBox.dx, closeTo(22, 1));
    });

    testWidgets('a pane with no saved host cannot be ticked, and says why', (tester) async {
      await openChoose(tester);
      expect(find.text(l10n.workspacePickNotSaved), findsOneWidget);
      await tick(tester, 'workspace-pick-pane-l-local');
      expect(find.text(workspaceCount(l10n, 1, 2)), findsOneWidget);
    });

    testWidgets('Select all and none; by group ticks that group\'s panes, and again unticks them', (tester) async {
      await openChoose(tester);
      await tick(tester, 'workspace-pick-none');
      expect(find.text(l10n.workspaceSaveEmptyTitle), findsOneWidget, reason: 'nothing ticked, nothing to save');
      await tester.enterText(find.byType(TextField).first, 'Nothing');
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.save));
      await tester.pumpAndSettle();
      expect(container.read(savedTabGroupsProvider), isEmpty, reason: 'Save is off');
      await tick(tester, 'workspace-pick-group-g-nodes');
      expect(find.text(workspaceCount(l10n, 1, 2)), findsOneWidget);
      await tick(tester, 'workspace-pick-group-g-nodes');
      expect(find.text(l10n.workspaceSaveEmptyTitle), findsOneWidget);
      await tick(tester, 'workspace-pick-all');
      expect(find.text(workspaceCount(l10n, 2, 3)), findsOneWidget);
    });
  });

  group('a layout opened from a workspace', () {
    setUp(() => NotificationCenter.debugToastsDrawn = true);
    tearDown(() => NotificationCenter.debugToastsDrawn = null);

    testWidgets('offers Update: its tabs as they are now go back in, whatever else is open', (tester) async {
      await tester.runAsync(setUpApp);
      final store = container.read(savedTabGroupsProvider.notifier);
      final id = store.saveCaptured('Ops', store.captureTabs([container.read(workTabsProvider).tabs.first])!);
      await tester.runAsync(() => launchWorkspace(_RefOf(container), id));
      final opened = store.tabsOpenedFrom(id);
      expect(opened, hasLength(1));
      await pumpSave(tester);
      expect(find.byKey(const ValueKey('workspace-update-offer')), findsOneWidget);
      // Its tab loses a pane; the other tabs stay out of it.
      final tabs = container.read(workTabsProvider.notifier);
      tabs.replaceTabTree(opened.single.id, PaneLeaf.single(sessionId: opened.single.paneTree.allLeaves.first.sessionId));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-update')));
      await tester.pumpAndSettle();
      // It would lose a pane: asked, and answered.
      await tester.tap(find.text(l10n.workspaceUpdateRemove));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      final saved = store.byId(id)!;
      expect(saved.tabs, hasLength(1));
      expect(saved.tabs.single.paneTreeOfConnIds.allLeaves, hasLength(1));
    });

    testWidgets('with nothing lost it asks nothing, and a pane added since goes in', (tester) async {
      await tester.runAsync(setUpApp);
      final store = container.read(savedTabGroupsProvider.notifier);
      final id = store.saveCaptured('Ops', store.captureTabs([container.read(workTabsProvider).tabs.first])!);
      await tester.runAsync(() => launchWorkspace(_RefOf(container), id));
      final opened = store.tabsOpenedFrom(id).single;
      sessions.seed('s-more', 'h-db', label: 'db-01');
      container.read(workTabsProvider.notifier).replaceTabTree(
            opened.id,
            PaneSplit(axis: Axis.horizontal, first: opened.paneTree, second: PaneLeaf.single(sessionId: 's-more')),
          );
      await pumpSave(tester);
      expect(find.byKey(const ValueKey('workspace-update-not-open')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('workspace-update')));
      await tester.pump();
      expect(find.text(l10n.workspaceUpdateNotOpenTitle), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(store.byId(id)!.tabs.single.paneTreeOfConnIds.allLeaves, hasLength(3));
    });

    testWidgets('no offer where nothing came from one', (tester) async {
      await tester.runAsync(setUpApp);
      await pumpSave(tester);
      expect(find.byKey(const ValueKey('workspace-update-offer')), findsNothing);
    });

    // Found in review: where the plan's limit let only part of
    // a workspace open, Update turned its tabs [web-01], [web-02], [db-01] into
    // [web-01], and a split of two into one and an empty place.
    List<List<String>> tabsOf(SavedTabGroup group) => [
          for (final tab in group.tabs)
            [
              for (final leaf in tab.paneTreeOfConnIds.allLeaves)
                if (!leaf.isPlaceholder) ...leaf.sessionIds,
            ],
        ];

    Future<String> threeTabsOpenOne(WidgetTester tester) async {
      await tester.runAsync(setUpApp);
      final store = container.read(savedTabGroupsProvider.notifier);
      final id = store.saveCaptured('Ops', (
        tabs: [
          TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: 'h-web1'), customName: 'One'),
          TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: 'h-web2'), customName: 'Two', colorIndex: 3),
          TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: 'h-db'), customName: 'Three'),
        ],
        hostNames: const {'h-web1': 'web-01', 'h-web2': 'web-02', 'h-db': 'db-01'},
      ));
      sessions.onlyOpens = {'h-web1'};
      await tester.runAsync(() => launchWorkspace(_RefOf(container), id));
      expect(store.tabsOpenedFrom(id), hasLength(1));
      await pumpSave(tester);
      return id;
    }

    Future<void> pressUpdate(WidgetTester tester) async {
      final update = find.byKey(const ValueKey('workspace-update'));
      await tester.ensureVisible(update);
      await tester.pumpAndSettle();
      await tester.tap(update);
      await tester.pumpAndSettle();
    }

    testWidgets('what Update saves shows above its button, and what is not open is named there', (tester) async {
      await threeTabsOpenOne(tester);
      final preview = find.byKey(const ValueKey('workspace-update-preview'));
      expect(find.descendant(of: preview, matching: find.text('web-01')), findsOneWidget);
      expect(find.descendant(of: preview, matching: find.text('web-02')), findsNothing);
      expect(find.descendant(of: preview, matching: find.text(l10n.workspaceUpdateSaves.toUpperCase())), findsOneWidget);
      expect(find.text(l10n.workspaceUpdateNotOpen('web-02, db-01')), findsOneWidget);
      expect(tester.getBottomLeft(preview).dy, lessThanOrEqualTo(tester.getTopLeft(find.byKey(const ValueKey('workspace-update'))).dy));
    });

    testWidgets('Update asks, naming the panes it would lose; Keep them keeps every tab, in its place and as it was',
        (tester) async {
      final id = await threeTabsOpenOne(tester);
      final store = container.read(savedTabGroupsProvider.notifier);
      await pressUpdate(tester);
      expect(find.text(l10n.workspaceUpdateNotOpenTitle), findsOneWidget);
      final list = find.byKey(const ValueKey('workspace-update-not-open-list'));
      expect(find.descendant(of: list, matching: find.text('web-02')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('db-01')), findsOneWidget);
      expect(find.descendant(of: list, matching: find.text('web-01')), findsNothing);
      expect(tabsOf(store.byId(id)!), [['h-web1'], ['h-web2'], ['h-db']], reason: 'nothing changes before the answer');

      await tester.tap(find.text(l10n.workspaceUpdateKeep));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      final saved = store.byId(id)!;
      expect(tabsOf(saved), [['h-web1'], ['h-web2'], ['h-db']]);
      expect(saved.tabs[1].customName, 'Two');
      expect(saved.tabs[1].colorIndex, 3);
      expect(saved.hostNames['h-db'], 'db-01');
    });

    testWidgets('Remove them takes them out', (tester) async {
      final id = await threeTabsOpenOne(tester);
      final store = container.read(savedTabGroupsProvider.notifier);
      await pressUpdate(tester);
      await tester.tap(find.text(l10n.workspaceUpdateRemove));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(tabsOf(store.byId(id)!), [['h-web1']]);
    });

    testWidgets('Cancel, or Esc, leaves the workspace as it is, and the dialog open', (tester) async {
      final id = await threeTabsOpenOne(tester);
      final store = container.read(savedTabGroupsProvider.notifier);
      await pressUpdate(tester);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(tabsOf(store.byId(id)!), [['h-web1'], ['h-web2'], ['h-db']]);
      expect(find.byKey(const ValueKey('workspace-update-offer')), findsOneWidget);
      await pressUpdate(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tabsOf(store.byId(id)!), [['h-web1'], ['h-web2'], ['h-db']]);
      expect(find.byKey(const ValueKey('workspace-update-offer')), findsOneWidget);
    });

    Future<String> splitOpensOne(WidgetTester tester) async {
      await tester.runAsync(setUpApp);
      final store = container.read(savedTabGroupsProvider.notifier);
      final id = store.saveCaptured('Ops', (
        tabs: [
          TabSnapshot(
            paneTreeOfConnIds: PaneSplit(
              axis: Axis.vertical,
              ratio: 0.3,
              first: PaneLeaf(id: 'a', sessionIds: const ['h-web1']),
              second: PaneLeaf(id: 'b', sessionIds: const ['h-web2']),
            ),
          ),
        ],
        hostNames: const {'h-web1': 'web-01', 'h-web2': 'web-02'},
      ));
      sessions.onlyOpens = {'h-web1'};
      await tester.runAsync(() => launchWorkspace(_RefOf(container), id));
      await pumpSave(tester);
      return id;
    }

    testWidgets('a split the limit left half open: Keep them puts the pane back in its place, the split as it was',
        (tester) async {
      final id = await splitOpensOne(tester);
      await pressUpdate(tester);
      await tester.tap(find.text(l10n.workspaceUpdateKeep));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      final tree = container.read(savedTabGroupsProvider.notifier).byId(id)!.tabs.single.paneTreeOfConnIds as PaneSplit;
      expect(tree.axis, Axis.vertical);
      expect(tree.ratio, 0.3);
      expect((tree.first as PaneLeaf).sessionIds, ['h-web1']);
      expect((tree.second as PaneLeaf).sessionIds, ['h-web2']);
    });

    testWidgets('a split the limit left half open: Remove them leaves no empty place', (tester) async {
      final id = await splitOpensOne(tester);
      await pressUpdate(tester);
      await tester.tap(find.text(l10n.workspaceUpdateRemove));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      final leaves = container.read(savedTabGroupsProvider.notifier).byId(id)!.tabs.single.paneTreeOfConnIds.allLeaves;
      expect(leaves, hasLength(1));
      expect(leaves.single.sessionIds, ['h-web1']);
    });

    testWidgets('a host of another space: named, and kept as asked; with nothing else open there is no dead button',
        (tester) async {
      await tester.runAsync(setUpApp);
      final store = container.read(savedTabGroupsProvider.notifier);
      final id = store.saveCaptured('Ops', (
        tabs: [TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: 'h-db'))],
        hostNames: const {'h-db': 'db-01'},
      ));
      await tester.runAsync(() => launchWorkspace(_RefOf(container), id));
      expect(store.tabsOpenedFrom(id), hasLength(1));
      // In the space it is in now, this host is not there.
      await tester.runAsync(() async {
        await (db.delete(db.connections)..where((c) => c.id.equals('h-db'))).go();
        await container.read(connectionsWithDetailsProvider.future);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await pumpSave(tester);
      expect(find.byKey(const ValueKey('workspace-update')), findsNothing, reason: 'a button that does nothing');
      expect(store.byId(id)!.tabs, hasLength(1), reason: 'and the workspace keeps it');
    });

    testWidgets('a host of another space among others: named, and kept as asked', (tester) async {
      await tester.runAsync(setUpApp);
      final store = container.read(savedTabGroupsProvider.notifier);
      final id = store.saveCaptured('Ops', (
        tabs: [
          TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: 'h-web1')),
          TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: 'h-db')),
        ],
        hostNames: const {'h-web1': 'web-01', 'h-db': 'db-01'},
      ));
      await tester.runAsync(() => launchWorkspace(_RefOf(container), id));
      await tester.runAsync(() async {
        await (db.delete(db.connections)..where((c) => c.id.equals('h-db'))).go();
        await container.read(connectionsWithDetailsProvider.future);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await pumpSave(tester);
      expect(find.text(l10n.workspaceUpdateNotOpen('db-01')), findsOneWidget);
      await pressUpdate(tester);
      await tester.tap(find.text(l10n.workspaceUpdateKeep));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(tabsOf(store.byId(id)!), [['h-web1'], ['h-db']]);
    });

    test('two saved tabs of one host are two open tabs, and what is not open goes back to its own', () {
      TabSnapshot tab(List<String> hosts) =>
          TabSnapshot(paneTreeOfConnIds: linearSplitOf([for (final h in hosts) PaneLeaf.single(sessionId: h)]));
      final merged = withPanesNotOpen(
        [tab(['a']), tab(['b']), tab(['a', 'c'])],
        [tab(['a']), tab(['a'])],
      );
      expect(merged.map((t) => t.paneTreeOfConnIds.allLeaves.map((l) => l.sessionIds.single).toList()).toList(), [
        ['a'],
        ['b'],
        ['a', 'c'],
      ]);
    });

    test('what is not open is told by hosts, as often as a workspace holds them', () {
      TabSnapshot tab(List<String> hosts) => TabSnapshot(paneTreeOfConnIds: linearSplitOf([for (final h in hosts) PaneLeaf.single(sessionId: h)]));
      expect(panesNotOpen([tab(['a', 'a', 'b'])], [tab(['a'])]).map((l) => l.sessionIds.single), ['a', 'b']);
      expect(panesNotOpen([tab(['a'])], [tab(['a', 'a'])]), isEmpty);
      // Stacked in one place, the one that is not open is what is named.
      final stacked = TabSnapshot(paneTreeOfConnIds: PaneLeaf(sessionIds: const ['a', 'b']));
      expect(panesNotOpen([stacked], [tab(['a'])]).single.sessionIds, ['b']);
      // A tab of nothing open stands as saved; a pane with no empty place goes beside.
      final merged = withPanesNotOpen([tab(['a', 'b']), tab(['c'])], [tab(['a'])]);
      expect(merged.map((t) => t.paneTreeOfConnIds.allLeaves.map((l) => l.sessionIds.single).toList()).toList(), [
        ['a', 'b'],
        ['c'],
      ]);
      // A tab open that no saved one was comes after.
      expect(
        withPanesNotOpen([tab(['a'])], [tab(['z']), tab(['a'])]).map((t) => t.paneTreeOfConnIds.allLeaves.single.sessionIds.single),
        ['a', 'z'],
      );
    });

    test('every leaf after a merge has an id of its own', () {
      final same = PaneLeaf(id: 'x', sessionIds: const ['a']);
      final other = PaneLeaf(id: 'x', sessionIds: const ['b']);
      final merged = withPanesNotOpen(
        [TabSnapshot(paneTreeOfConnIds: PaneSplit(axis: Axis.horizontal, first: same, second: other))],
        [TabSnapshot(paneTreeOfConnIds: PaneLeaf(id: 'x', sessionIds: const ['a']))],
      );
      final ids = merged.expand((t) => t.paneTreeOfConnIds.allLeaves).map((l) => l.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('Add this tab to a workspace it came from', () {
    setUp(() => NotificationCenter.debugToastsDrawn = true);
    tearDown(() => NotificationCenter.debugToastsDrawn = null);

    test('its panes get ids of their own, and their remembered folders go with them', () {
      const paths = SftpPanePaths(remotePath: '/srv/made-up');
      final tab = TabSnapshot(
        paneTreeOfConnIds: PaneLeaf(id: 'x', sessionIds: const ['a'], type: 'sftp'),
        panePaths: {'x': paths},
      );
      final fresh = withFreshLeafIds(tab);
      final leaf = fresh.paneTreeOfConnIds.allLeaves.single;
      expect(leaf.id, isNot('x'));
      expect(leaf.sessionIds, ['a']);
      expect(leaf.type, 'sftp');
      expect(fresh.panePaths, {leaf.id: paths});
    });

    testWidgets('saved from a tab and that tab added: two rows in its editor, not one, and no assertion',
        (tester) async {
      await tester.runAsync(setUpApp);
      final store = container.read(savedTabGroupsProvider.notifier);
      final tab = container.read(workTabsProvider).tabs.first;
      final id = store.saveCaptured('Ops', store.captureTabs([tab])!);
      expect(store.addTabToWorkspace(id, tab.id), isTrue);
      final saved = store.byId(id)!;
      final ids = flattenWorkspaceLeaves(saved).map((l) => l.id).toList();
      expect(ids, hasLength(4));
      expect(ids.toSet(), hasLength(4), reason: 'the editor tells its rows apart by these');

      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: SizedBox(width: 560, child: WorkspaceEditDialog(workspaceId: id, onDone: () {}))),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('web-01'), findsNWidgets(2));
      expect(find.text('web-02'), findsNWidgets(2));
    });
  });

  test('Add this tab to a workspace: it joins after the others, and a tab with no saved host adds nothing', () async {
    await setUpApp();
    final store = container.read(savedTabGroupsProvider.notifier);
    final id = store.saveCaptured('Ops', store.captureTabs([container.read(workTabsProvider).tabs.first])!);
    expect(store.addTabToWorkspace(id, tabB), isTrue);
    final saved = store.byId(id)!;
    expect(saved.tabs, hasLength(2));
    expect(saved.tabs[1].paneTreeOfConnIds.allLeaves.single.sessionIds.single, 'h-db');
    expect(saved.hostNames['h-db'], 'db-01');
    sessions.seed('s-local2', 'local_2', label: 'Local shell');
    final localOnly = container.read(workTabsProvider.notifier).createTab('s-local2');
    expect(store.addTabToWorkspace(id, localOnly), isFalse);
    expect(store.addTabToWorkspace('no-such', tabA), isFalse);
    expect(store.byId(id)!.tabs, hasLength(2));
  });

  group('capturePanesAsSnapshots', () {
    WorkTab tab(PaneNode tree) => WorkTab(paneTree: tree);
    String? conn(String sid) => {'a': 'h-a', 'b': 'h-b'}[sid];

    test('a kept leaf keeps its id, so its remembered folders stay with it', () {
      final tree = PaneSplit(
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'x', sessionIds: ['a']),
        second: PaneLeaf(id: 'y', sessionIds: ['b']),
      );
      final snaps = capturePanesAsSnapshots([tab(tree)], conn, keep: {'y'})!;
      expect(snaps.single.paneTreeOfConnIds.allLeaves.single.id, 'y');
      expect(snaps.single.paneTreeOfConnIds.allLeaves.single.sessionIds, ['h-b']);
    });

    test('an empty place stays in a tab saved whole, and goes when panes are picked', () {
      final tree = PaneSplit(
        axis: Axis.horizontal,
        first: PaneLeaf(id: 'x', sessionIds: ['a']),
        second: PaneLeaf.placeholder(id: 'p'),
      );
      expect(capturePanesAsSnapshots([tab(tree)], conn)!.single.paneTreeOfConnIds.allLeaves, hasLength(2));
      expect(capturePanesAsSnapshots([tab(tree)], conn, keep: {'x'})!.single.paneTreeOfConnIds.allLeaves, hasLength(1));
    });

    test('nothing left is null: a tab of a local shell alone, or nothing ticked', () {
      final local = PaneLeaf(id: 'x', sessionIds: ['local']);
      expect(capturePanesAsSnapshots([tab(local)], conn), isNull);
      expect(capturePanesAsSnapshots([tab(PaneLeaf(id: 'y', sessionIds: ['a']))], conn, keep: const {}), isNull);
    });

    test('a pane holding a saved host and a local shell keeps the host: the picker listed it, and the capture dropped it',
        () {
      final both = PaneLeaf(id: 'x', sessionIds: const ['local', 'a', 'b'], activeIndex: 2);
      final kept = capturePanesAsSnapshots([tab(both)], conn)!.single.paneTreeOfConnIds.allLeaves.single;
      expect(kept.id, 'x');
      expect(kept.sessionIds, ['h-a', 'h-b']);
      expect(kept.activeIndex, 1, reason: 'the one in front stays in front');
      // Ticked by name, the same.
      expect(capturePanesAsSnapshots([tab(both)], conn, keep: {'x'}), isNotNull);
      // The local shell in front: the host behind it.
      final behind = PaneLeaf(id: 'y', sessionIds: const ['a', 'local'], activeIndex: 1);
      final leaf = capturePanesAsSnapshots([tab(behind)], conn)!.single.paneTreeOfConnIds.allLeaves.single;
      expect(leaf.sessionIds, ['h-a']);
      expect(leaf.activeIndex, 0);
    });
  });

  group('the panel', () {
    setUp(() => NotificationCenter.debugToastsDrawn = true);
    tearDown(() => NotificationCenter.debugToastsDrawn = null);

    Future<String> pumpPanel(WidgetTester tester, {bool editing = false, VoidCallback? onOpen}) async {
      await tester.runAsync(setUpApp);
      final store = container.read(savedTabGroupsProvider.notifier);
      final id = store.saveCaptured('Ops', store.captureTabs(container.read(workTabsProvider).tabs)!);
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final view = ref.watch(workspacesProvider).where((w) => w.id == id).firstOrNull;
                return Row(
                  children: [
                    const Expanded(child: SizedBox()),
                    if (view != null)
                      WorkspacePanel(
                        workspace: view,
                        startEditing: editing,
                        onClose: () {},
                        onOpen: onOpen ?? () {},
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return id;
    }

    testWidgets('names its tabs and panes with when it was opened, and Open workspace is what opens it', (tester) async {
      var opened = 0;
      await pumpPanel(tester, onOpen: () => opened++);
      expect(find.text('Ops'), findsOneWidget);
      expect(find.text(l10n.workspacePanelTabsAndPanes.toUpperCase()), findsOneWidget);
      expect(find.text(l10n.workspacePickTabNumber(1)), findsOneWidget);
      expect(find.text(l10n.workspacePickTabNumber(2)), findsOneWidget);
      for (final host in ['web-01', 'web-02', 'db-01']) {
        expect(find.text(host), findsOneWidget);
      }
      expect(find.textContaining(l10n.workspaceNeverOpened), findsOneWidget);
      expect(opened, 0, reason: 'nothing connects by itself');
      await tester.tap(find.byKey(const ValueKey('workspace-panel-open')));
      expect(opened, 1);
    });

    testWidgets('Edit swaps it for the editor in place: rename, and back with the new name', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('workspace-panel-edit')));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceEditDialog), findsOneWidget);
      expect(find.text(l10n.workspaceEditTabAll), findsNothing, reason: 'the cards beside it are the list');
      await tester.enterText(find.byType(TextField).first, 'Ops two');
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.save));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceEditDialog), findsNothing);
      expect(find.text('Ops two'), findsOneWidget);
    });

    // Russian ran over by 6 pixels here (found in review).
    testWidgets('the editor in the panel\'s width, in Russian, runs over nothing', (tester) async {
      await tester.runAsync(loadShotFonts);
      await tester.runAsync(setUpApp);
      final store = container.read(savedTabGroupsProvider.notifier);
      final id = store.saveCaptured('Ops', store.captureTabs(container.read(workTabsProvider).tabs)!);
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'GeistSans'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('ru'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final view = ref.watch(workspacesProvider).where((w) => w.id == id).firstOrNull;
                return Row(
                  children: [
                    const Expanded(child: SizedBox()),
                    if (view != null) WorkspacePanel(workspace: view, startEditing: true, onClose: () {}, onOpen: () {}),
                  ],
                );
              },
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(WorkspaceEditDialog), findsOneWidget);
    });

    testWidgets('its rows are the row of a host in any list: the host\'s own icon, its name and address', (tester) async {
      await pumpPanel(tester);
      expect(find.byType(HostRow), findsNWidgets(3));
      expect(find.byIcon(LucideIcons.server), findsNothing);
      expect(find.byType(HostGlyph), findsNWidgets(3));
      expect(find.text('web-01.example.com'), findsOneWidget);
    });

    testWidgets('a host gone is said, with no host\'s icon', (tester) async {
      final id = await pumpPanel(tester);
      await tester.runAsync(() async {
        await (db.delete(db.connections)..where((c) => c.id.equals('h-db'))).go();
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(id, isNotEmpty);
      expect(find.byType(HostRow), findsNWidgets(2));
      expect(find.byIcon(LucideIcons.serverOff), findsOneWidget);
    });

    testWidgets('its Delete goes with an undo, and the panel goes with the workspace', (tester) async {
      final id = await pumpPanel(tester, editing: true);
      final delete = find.text(l10n.workspaceDeleteHeading);
      await tester.ensureVisible(delete.first);
      await tester.pumpAndSettle();
      await tester.tap(delete.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.delete).last);
      await tester.pump();
      expect(container.read(savedTabGroupsProvider.notifier).byId(id), isNull);
      final said = container.read(notificationCenterProvider).history.first;
      expect(said.actionLabel, l10n.workspaceUndo);
      await tester.pumpAndSettle(const Duration(seconds: 11));
      expect(find.byType(WorkspacePanel), findsNothing);
    });
  });
}

/// `1 tab · 2 panes` as the dialog writes it.
String workspaceCount(AppLocalizations l10n, int tabs, int panes) =>
    '${l10n.workspaceTabCountLabel(tabs)} · ${l10n.workspacePaneCountLabel(panes)}';

/// What [launchWorkspace] takes, over a plain container.
class _RefOf implements WidgetRef {
  _RefOf(this.container);
  final ProviderContainer container;

  @override
  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
