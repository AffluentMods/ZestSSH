import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/move/move_copy_menu.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';

/// An editor's Move or copy (4.0: a menu in the top right; pick a team,
/// then a vault, then move or
/// duplicate): a saved item's button opens its places, Personal and each
/// team with the vaults this account may add to, the place it is in marked
/// and not offered; under a place, Move here and Copy here run the one
/// place picker's transfer with that place picked. No button for a new item,
/// nor without a team. Runs with `--dart-define=ZEST_ORCHARDS=true`.

const _acme = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _prod = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _staging = '3f5b1d9b-8e4a-4a6d-8b7a-5d94f3b2eaa6';
const _ro = '4a6c2e0c-9f5b-4b7e-8c8b-6ea5a4c3fbb7';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  late ProviderContainer container;
  late AppDatabase tree;
  late AppDatabase acme;
  late _MemoryStorage storage;

  /// Personal with the hosts web-h1 and web-h2; with [team], the team Acme
  /// (owner) with Production and Staging, where it may add, and Archive,
  /// where it may only connect.
  Future<void> setUpSpaces(WidgetTester tester, {bool team = true}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    storage = _MemoryStorage();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
    ]);
    addTearDown(() async {
      container.dispose();
      for (final db in storage.dbs.values) {
        await db.close();
      }
      await tree.close();
    });
    container.read(databaseSessionProvider.notifier).seed(tree);
    await tester.runAsync(() async {
      if (team) {
        acme = await container.read(orchardDatabasesProvider.notifier).open(_acme);
        await acme.customStatement(
            'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can) '
            "VALUES (1, ?, 'Acme', 'owner', 1, ?, ?)",
            [_acme, _prod, jsonEncode(RoleCan.all.toList()..sort())]);
        final all = jsonEncode(CrateSwitches.all.toList()..sort());
        final readOnly = jsonEncode([CrateSwitches.connect, CrateSwitches.sftp]);
        await acme.customStatement(
            'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
            "(?, 'Production', 'manage', ?, 1), (?, 'Staging', 'manage', ?, 1), (?, 'Archive', 'connect', ?, 1)",
            [_prod, all, _staging, all, _ro, readOnly]);
      }
      final now = DateTime(2026, 11, 1);
      for (final id in ['h1', 'h2']) {
        await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: 'web-$id',
              host: '192.0.2.10',
              createdAt: now,
              updatedAt: now,
            ));
      }
      await container.read(orchardSummariesProvider.future);
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> pumpHome(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: home),
      ),
    ));
    await settle(tester);
  }

  late int moved;

  /// The button alone, for the saved host [key], at the top right.
  Future<void> pumpButton(WidgetTester tester, {String key = 'h2'}) async {
    moved = 0;
    await pumpHome(
      tester,
      Align(
        alignment: Alignment.topRight,
        child: MoveCopyMenuButton(kind: TransferKinds.host, itemKey: key, onMoved: () => moved++),
      ),
    );
  }

  final button = find.byKey(const ValueKey('move-copy-button'));
  // The place picker's rows (move_copy_dialog.dart).
  Finder place(String? crate) =>
      find.byKey(ValueKey('transfer-place-${crate == null ? 'personal' : _acme}-${crate ?? ''}'));
  final moveTo = find.byKey(const ValueKey('move-copy-move'));
  final copyTo = find.byKey(const ValueKey('move-copy-copy'));
  final picker = find.byKey(const ValueKey('transfer-pick'));

  /// What the app's messages said (a computer's go to its notifications).
  List<String> said() => [for (final n in container.read(notificationCenterProvider).history) n.title];

  Future<List<Connection>> teamHosts(WidgetTester tester) async => (await tester.runAsync(() => acme.select(acme.connections).get()))!;
  Future<List<Connection>> treeHosts(WidgetTester tester) async => (await tester.runAsync(() => tree.select(tree.connections).get()))!;

  testWidgets('the menu is Move to... and Copy to...; either opens the place picker, with Personal marked as '
      'where the host is and not offered, and the vaults this account may add to', (tester) async {
    await setUpSpaces(tester);
    await pumpButton(tester);
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(find.descendant(of: moveTo, matching: find.text(en.transferMoveTo)), findsOneWidget);
    expect(find.descendant(of: copyTo, matching: find.text(en.transferCopyTo)), findsOneWidget);
    expect(find.byType(SubmenuButton), findsNothing, reason: 'no menus inside the menu');
    await tester.tap(moveTo);
    await settle(tester);
    expect(picker, findsOneWidget);
    expect(find.descendant(of: place(null), matching: find.text(en.transferHere)), findsOneWidget);
    expect(place(_prod), findsOneWidget);
    expect(place(_staging), findsOneWidget);
    expect(place(_ro), findsNothing, reason: 'a vault without add is not listed');
    await tester.tap(place(null));
    await settle(tester);
    expect(picker, findsOneWidget, reason: 'where it is: nothing happened');
    expect(await teamHosts(tester), isEmpty);
    expect(moved, 0);
  }, skip: !kOrchardsEnabled);

  testWidgets('Move to..., then a vault: the host goes there, it is said, and the editor is told it moved', (tester) async {
    await setUpSpaces(tester);
    await pumpButton(tester);
    await tester.tap(button);
    await tester.pump();
    await tester.tap(moveTo);
    await settle(tester);
    await tester.tap(place(_staging));
    await settle(tester);
    expect(picker, findsNothing);
    final hosts = await teamHosts(tester);
    expect(hosts.single.label, 'web-h2');
    expect(await tester.runAsync(() => CratePlacement(acme).crateOf('host', hosts.single.id)), _staging);
    expect([for (final h in await treeHosts(tester)) h.id], ['h1']);
    expect(said(), contains(en.transferMovedToast(en.transferWhatHosts(1), 'Acme / Staging')));
    expect(moved, 1);
    await tester.pump(const Duration(seconds: 5)); // The line that says so goes.
  }, skip: !kOrchardsEnabled);

  testWidgets('Copy to..., then a vault: a copy goes there, the host stays, and nothing is told to close', (tester) async {
    await setUpSpaces(tester);
    await pumpButton(tester);
    await tester.tap(button);
    await tester.pump();
    await tester.tap(copyTo);
    await settle(tester);
    await tester.tap(place(_prod));
    await settle(tester);
    final hosts = await teamHosts(tester);
    expect(hosts.single.label, 'web-h2');
    expect(await tester.runAsync(() => CratePlacement(acme).crateOf('host', hosts.single.id)), _prod);
    expect([for (final h in await treeHosts(tester)) h.id]..sort(), ['h1', 'h2']);
    expect(said(), contains(en.transferCopiedToast(en.transferWhatHosts(1), 'Acme / Production')));
    expect(moved, 0);
    await tester.pump(const Duration(seconds: 5));
  }, skip: !kOrchardsEnabled);

  testWidgets('without a team there is no button: Personal to Personal means nothing', (tester) async {
    await setUpSpaces(tester, team: false);
    await pumpButton(tester);
    expect(button, findsNothing);
    expect(find.byTooltip(en.moveCopyMenuButton), findsNothing);
  }, skip: !kOrchardsEnabled);

  testWidgets('a screen reader hears its name, and the keyboard opens it, walks it and moves the host', (tester) async {
    await setUpSpaces(tester);
    final semantics = tester.ensureSemantics();
    await pumpButton(tester);
    expect(find.byTooltip(en.moveCopyMenuButton), findsOneWidget);
    expect(tester.getSemantics(find.descendant(of: button, matching: find.byType(IconButton))),
        isSemantics(tooltip: en.moveCopyMenuButton, isButton: true, hasTapAction: true, isFocusable: true));
    semantics.dispose();
    // Tab reaches it; Enter opens it on Move to..., and Enter on that opens the picker.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final iconButton = tester.widget<IconButton>(find.descendant(of: button, matching: find.byType(IconButton)));
    expect(iconButton.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump();
    expect(Focus.of(tester.element(find.descendant(of: moveTo, matching: find.text(en.transferMoveTo)))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(picker, findsOneWidget);
    await tester.tap(place(_staging));
    await settle(tester);
    expect((await teamHosts(tester)).single.label, 'web-h2');
    expect(moved, 1);
    await tester.pump(const Duration(seconds: 5));
  }, skip: !kOrchardsEnabled);

  group("the host editor's header", () {
    late int closed;

    Future<void> pumpEditor(WidgetTester tester, {String? id}) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
      messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
          MockStreamHandler.inline(onListen: (arguments, events) {}));
      tester.view.physicalSize = const Size(1300, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      closed = 0;
      await pumpHome(tester, ConnectionEditScreen(inDialog: true, connectionId: id, onClose: () => closed++));
      // The test font draws every glyph one em wide, so some labels overflow
      // here that fit with a real font.
      Object? ex;
      while ((ex = tester.takeException()) != null) {
        expect(ex.toString(), contains('overflowed'));
      }
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(hours: 1));
    }

    testWidgets("a saved host's editor has the button beside the header's icons; a new one's has none", (tester) async {
      await setUpSpaces(tester);
      await pumpEditor(tester, id: 'h2');
      expect(button, findsOneWidget);
      expect(find.byTooltip(en.moveCopyMenuButton), findsOneWidget);
      await finish(tester);

      await pumpEditor(tester);
      expect(button, findsNothing, reason: 'a new host has Save in');
      await finish(tester);
    }, skip: !kOrchardsEnabled);

    testWidgets('with a change not saved it says to save first and opens nothing; moved, the editor closes', (tester) async {
      await setUpSpaces(tester);
      await pumpEditor(tester, id: 'h2');
      await tester.enterText(find.widgetWithText(TextField, 'web-h2'), 'web-renamed');
      await settle(tester);
      await tester.tap(button);
      await tester.pump();
      expect(said(), contains(en.moveCopyMenuSaveFirst));
      expect(moveTo, findsNothing);
      await tester.pump(const Duration(seconds: 6));
      await finish(tester);

      await pumpEditor(tester, id: 'h2');
      await tester.tap(button);
      await tester.pump();
      await tester.tap(moveTo);
      await settle(tester);
      await tester.tap(place(_prod));
      await settle(tester);
      expect((await teamHosts(tester)).single.label, 'web-h2');
      expect(closed, 1);
      await tester.pump(const Duration(seconds: 5));
      await finish(tester);
    }, skip: !kOrchardsEnabled);

    testWidgets('without a team, a saved host has no button', (tester) async {
      await setUpSpaces(tester, team: false);
      await pumpEditor(tester, id: 'h2');
      expect(button, findsNothing);
      await finish(tester);
    }, skip: !kOrchardsEnabled);
  });
}
