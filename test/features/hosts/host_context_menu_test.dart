import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/hosts/widgets/host_panel.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/features/orchards/spaces.dart' show OrchardSpace;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/desktop/widgets/connection_editor_dock.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// A host's right-click menu on a computer,
/// its keys, and one pane at the right (the host's details, or its
/// editor in their place).
///
/// One hard rule: no screen can run off the app
/// screen. Every menu and submenu stays inside the window, wherever it is
/// opened.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const window = Size(1000, 720);

  late AppDatabase db;
  late ProviderContainer container;

  setUp(() => ConnectionEditScreen.debugDesktopShell = true);
  tearDown(() => ConnectionEditScreen.debugDesktopShell = null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// The Hosts page with [hosts] hosts (the first three in a group "Lab",
  /// every one watched by Server monitor), and the docked editor beside it
  /// as the shell docks it. With [team], a team's space as the screen reads
  /// it: h2 and h3 in a vault where the role connects only, the rest in one
  /// where it may do anything.
  Future<void> pump(WidgetTester tester,
      {int hosts = 6, Size size = window, double editorWidth = 700, bool team = false}) async {
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
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2026, 10, 22);
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g', name: 'Lab', createdAt: at));
    for (var i = 1; i <= hosts; i++) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h$i',
            label: 'host-$i',
            host: '10.50.0.$i',
            groupId: Value(i <= 3 ? 'g' : null),
            monitored: const Value(true),
            sortOrder: Value(i),
            createdAt: at,
            updatedAt: at,
          ));
    }
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      connectionEditorWidthProvider.overrideWith((ref) => editorWidth),
      if (team) ...[
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace('team-1')),
        activeOrchardProvider.overrideWithValue(const AsyncData(OrchardSummary(
          id: 'team-1',
          name: 'Platform team',
          role: 'member-role',
          defaultCrateId: 'all',
          crates: [
            CrateSummary(id: 'all', name: 'Legacy', level: 'manage', switches: CrateSwitches.all),
            CrateSummary(id: 'prod', name: 'Production', level: 'connect', switches: {CrateSwitches.connect}),
          ],
        ))),
        itemCratesProvider.overrideWith(
            (ref, kind) => Stream.value(kind == 'host' ? const {'h2': 'prod', 'h3': 'prod'} : const <String, String>{})),
      ],
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            final target = ref.watch(connectionEditorTargetProvider);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: HostsHomePage(onConnectTo: (_) {}, onOpenSftp: (_) {})),
                if (target != null) ConnectionEditorDock(target: target),
              ],
            );
          }),
        ),
      ),
    ));
    await settle(tester);
    Object? ex;
    while ((ex = tester.takeException()) != null) {
      expect(ex.toString(), contains('overflowed'));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder card(String id) => find.byWidgetPredicate((w) => w is HostCard && w.data.id == id);

  Future<void> rightClickAt(WidgetTester tester, Offset at) async {
    final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
    await g.up();
    await settle(tester);
  }

  /// Every box of the menus open now, as it is seen: a menu longer than the
  /// window scrolls inside it, so an item scrolled out of sight counts by the
  /// menu's own box (the part of it that shows).
  Iterable<Rect> menuBoxes(WidgetTester tester) => [
        for (final f in [find.byType(MenuItemButton), find.byType(SubmenuButton)])
          for (final e in f.evaluate())
            () {
              final item = find.byWidget(e.widget);
              final viewport = find.ancestor(of: item, matching: find.byType(Scrollable));
              return viewport.evaluate().isEmpty ? tester.getRect(item) : tester.getRect(viewport.first);
            }(),
      ];

  void expectInside(WidgetTester tester, Size size, String where) {
    final boxes = menuBoxes(tester).toList();
    expect(boxes, isNotEmpty, reason: '$where: a menu is open');
    for (final r in boxes) {
      expect(r.left, greaterThanOrEqualTo(-0.5), reason: '$where: $r');
      expect(r.top, greaterThanOrEqualTo(-0.5), reason: '$where: $r');
      expect(r.right, lessThanOrEqualTo(size.width + 0.5), reason: '$where: $r');
      expect(r.bottom, lessThanOrEqualTo(size.height + 0.5), reason: '$where: $r');
    }
  }

  testWidgets('one menu, grouped: Connect, Open in new tab, Open in split, SFTP and Edit, then Organize and Tools, '
      'then Delete, with its keys at the right', (tester) async {
    await pump(tester);
    await rightClickAt(tester, tester.getCenter(card('h1')));
    // The menu itself, top to bottom (4.0: it was some 22 items in one list).
    final top = [
      for (final e in [...find.byType(MenuItemButton).evaluate(), ...find.byType(SubmenuButton).evaluate()])
        if (e.widget.key case ValueKey<String>(:final value) when value.startsWith('host-menu-')) (value, tester.getTopLeft(find.byWidget(e.widget)).dy),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    expect([for (final t in top) t.$1], [
      'host-menu-connect',
      'host-menu-new_tab',
      'host-menu-split',
      'host-menu-sftp',
      'host-menu-edit',
      'host-menu-organize',
      'host-menu-tools',
      'host-menu-delete',
    ]);
    for (final t in [l10n.commonConnect, l10n.hmenuOpenNewTab, l10n.hpanelOpenInSplit, 'SFTP', l10n.edit,
        l10n.hostMenuOrganize, l10n.hostMenuTools, l10n.delete]) {
      expect(find.text(t), findsWidgets, reason: t);
    }
    // The same keys at the right as before.
    final keys = {
      for (final e in find.byType(MenuItemButton).evaluate())
        if (e.widget.key case ValueKey<String>(:final value)) value: (e.widget as MenuItemButton).shortcut,
    };
    String said(MenuSerializableShortcut? s) =>
        s is SingleActivator ? '${s.control ? 'Ctrl+' : ''}${s.meta ? 'Meta+' : ''}${s.trigger.keyLabel}' : '$s';
    expect(said(keys['host-menu-connect']), said(const SingleActivator(LogicalKeyboardKey.enter)));
    expect(said(keys['host-menu-new_tab']), said(const SingleActivator(LogicalKeyboardKey.enter, control: true)));
    expect(said(keys['host-menu-edit']), said(const SingleActivator(LogicalKeyboardKey.keyE)));
    expect(said(keys['host-menu-delete']), said(const SingleActivator(LogicalKeyboardKey.delete)));
    for (final t in [l10n.hpanelCopySsh, l10n.commonDuplicate, l10n.hmenuPinTop, l10n.hostBulkActionMoveToGroup]) {
      expect(find.text(t), findsNothing, reason: '$t is in a group');
    }
    // Organize: where the host is kept.
    await tester.tap(find.byKey(const ValueKey('host-menu-organize')));
    await settle(tester);
    for (final t in [l10n.hostBulkActionMoveToGroup, l10n.hmenuPinTop, l10n.commonDuplicate, l10n.hostsHomeMenuSelect]) {
      expect(find.text(t), findsWidgets, reason: t);
    }
    expect(find.text('Ctrl+click'), findsOneWidget);
    // Tools: what else may be done with it.
    await tester.tap(find.byKey(const ValueKey('host-menu-tools')));
    await settle(tester);
    for (final t in [l10n.hpanelCopySsh, l10n.hostPanelHealth, l10n.sftpForgetLastFolder]) {
      expect(find.text(t), findsWidgets, reason: t);
    }
    // Its Health submenu: the host's head, then what it offers.
    await tester.tap(find.byKey(const ValueKey('host-menu-health')));
    await settle(tester);
    expect(find.text(l10n.hmenuHealthOn('host-1').toUpperCase()), findsOneWidget);
    for (final t in [l10n.hmenuMuteAll, l10n.hmenuSnoozeDay, l10n.hmenuSnoozeRecovers, l10n.hpanelThresholds, l10n.monitorAgentlessStopHost]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await finish(tester);
  });

  testWidgets('the menu and its submenus stay inside the window, opened near each of its edges', (tester) async {
    // A small window, filled with hosts to its foot.
    const size = Size(900, 640);
    await pump(tester, hosts: 40, size: size);
    final cards = [
      for (final e in find.byType(HostCard).evaluate()) (id: (e.widget as HostCard).data.id, rect: tester.getRect(find.byWidget(e.widget))),
    ].where((c) => c.rect.bottom <= size.height && c.rect.top >= 0).toList();
    Offset near(Alignment corner) {
      // The card nearest that corner, and a point inside it as near as can be.
      final target = Offset((corner.x + 1) / 2 * size.width, (corner.y + 1) / 2 * size.height);
      cards.sort((a, b) => (a.rect.center - target).distance.compareTo((b.rect.center - target).distance));
      final r = cards.first.rect.deflate(3);
      return Offset(target.dx.clamp(r.left, r.right), target.dy.clamp(r.top, r.bottom));
    }

    for (final corner in [Alignment.topLeft, Alignment.topRight, Alignment.bottomLeft, Alignment.bottomRight]) {
      await rightClickAt(tester, near(corner));
      expectInside(tester, size, '$corner, the menu');
      for (final path in const [
        ['host-menu-tools', 'host-menu-health'],
        ['host-menu-organize', 'host-menu-move'],
        ['host-menu-split'],
      ]) {
        for (final sub in path) {
          await tester.tap(find.byKey(ValueKey(sub)));
          await settle(tester);
          expectInside(tester, size, '$corner, $sub');
        }
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
    }
    await finish(tester);
  });

  testWidgets('a host that is one of several selected: the selection\'s menu, saying how many', (tester) async {
    await pump(tester);
    container.read(hostMultiSelectProvider.notifier).selectAll(['h1', 'h2', 'h4']);
    await settle(tester);
    await rightClickAt(tester, tester.getCenter(card('h2')));
    expect(find.text(l10n.hmenuSelectionHead(3).toUpperCase()), findsOneWidget);
    expect(find.text(l10n.hostBulkActionDeleteButton(3)), findsOneWidget);
    expect(find.text(l10n.hostsSelOpenInTabs), findsOneWidget);
    expect(find.text(l10n.hmenuOpenNewTab), findsNothing, reason: 'not the one host\'s menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await finish(tester);
  });

  testWidgets('in a team\'s vault the selection\'s Delete counts the hosts its role may delete, and is not there '
      'where it may delete none', (tester) async {
    await pump(tester, team: true);
    container.read(hostMultiSelectProvider.notifier).selectAll(['h1', 'h2', 'h4']);
    await settle(tester);
    await rightClickAt(tester, tester.getCenter(card('h2')));
    expect(find.text(l10n.hmenuSelectionHead(3).toUpperCase()), findsOneWidget);
    expect(find.text(l10n.hostBulkActionDeleteButton(2)), findsOneWidget, reason: 'h2 stays: the role connects only');
    expect(find.text(l10n.hostBulkActionDeleteButton(3)), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    container.read(hostMultiSelectProvider.notifier).selectAll(['h2', 'h3']);
    await settle(tester);
    await rightClickAt(tester, tester.getCenter(card('h3')));
    expect(find.text(l10n.hmenuSelectionHead(2).toUpperCase()), findsOneWidget);
    expect(find.byKey(const ValueKey('host-menu-sel_delete')), findsNothing);
    expect(find.text(l10n.hostBulkActionDeleteButton(2)), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await finish(tester);
  });

  testWidgets('Move to group from the menu moves the host', (tester) async {
    await pump(tester);
    await rightClickAt(tester, tester.getCenter(card('h5')));
    await tester.tap(find.byKey(const ValueKey('host-menu-organize')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('host-menu-move')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('host-menu-move:g')));
    await settle(tester);
    final row = await tester.runAsync(() => db.connectionsDao.getById('h5'));
    expect(row!.groupId, 'g');
    await finish(tester);
  });

  group('One pane at the right', () {
    testWidgets('Edit swaps the details for the editor; Cancel brings the details of that host back', (tester) async {
      await pump(tester, size: const Size(2200, 1000), editorWidth: 980);
      await tester.tap(card('h2'), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(HostPanel), findsOneWidget);
      // E: the key its menu names.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await settle(tester);
      expect(container.read(connectionEditorTargetProvider)?.connectionId, 'h2');
      expect(find.byType(HostPanel), findsNothing, reason: 'never the details of one host beside the editor');
      expect(find.byType(ConnectionEditScreen), findsOneWidget);
      await tester.tap(find.byTooltip(l10n.cancel).first);
      await settle(tester);
      expect(container.read(connectionEditorTargetProvider), isNull);
      expect(find.byKey(const ValueKey('host-panel-h2')), findsOneWidget, reason: 'back to the details of that host');
      await finish(tester);
    });

    testWidgets('another host\'s details while editing ask about unsaved changes first', (tester) async {
      await pump(tester, size: const Size(2200, 1000), editorWidth: 980);
      await tester.tap(card('h2'), kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('host-panel-edit')));
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, 'host-2'), 'host-2-renamed');
      await settle(tester);
      await tester.tap(card('h4'), kind: PointerDeviceKind.mouse);
      await settle(tester);
      expect(find.text(l10n.zestDiscardTitle), findsOneWidget);
      // Cancel: the editor stays, with its change.
      await tester.tap(find.descendant(of: find.byType(ZestDialogShell), matching: find.text(l10n.zestDiscardCancel)));
      await settle(tester);
      expect(container.read(connectionEditorTargetProvider)?.connectionId, 'h2');
      expect(find.widgetWithText(TextField, 'host-2-renamed'), findsOneWidget);
      expect(find.byType(HostPanel), findsNothing);
      // Discard: the editor goes, and the other host's details come.
      await tester.tap(card('h4'), kind: PointerDeviceKind.mouse);
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(ZestDialogShell), matching: find.text(l10n.zestDiscardDiscard)));
      await settle(tester);
      expect(container.read(connectionEditorTargetProvider), isNull);
      expect(find.byKey(const ValueKey('host-panel-h4')), findsOneWidget);
      final row = await tester.runAsync(() => db.connectionsDao.getById('h2'));
      expect(row!.label, 'host-2', reason: 'nothing saved');
      await finish(tester);
    });
  });
}
