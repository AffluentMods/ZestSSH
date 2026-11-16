import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';

/// The host editor and the icon's colour (3.0): it shows the host's choice,
/// hands the picker what it needs to name the choices for this host as the
/// form has it now, keeps what the picker gives back, and saves it; for a
/// host that is there and for a new one.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _blue = Color(0xFF3B82F6);
const _pink = Color(0xFFEC4899);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late bool closed;

  Future<void> pump(WidgetTester tester, {String? connectionId, int? iconColor, int? labelColor, String? group = 'g-web'}) async {
    closed = false;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 8);
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
          id: 'g-web',
          name: 'Web',
          colorValue: Value(_blue.toARGB32()),
          createdAt: now,
          updatedAt: Value(now),
        ));
    if (connectionId != null) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: connectionId,
            label: 'web-01',
            host: '192.168.10.21',
            port: const Value(22),
            groupId: Value(group),
            colorValue: Value(labelColor),
            iconId: const Value('debian'),
            iconColor: Value(iconColor),
            createdAt: now,
            updatedAt: now,
          ));
    }
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
        home: Scaffold(
          body: ConnectionEditScreen(connectionId: connectionId, inDialog: true, onClose: () => closed = true),
        ),
      ),
    ));
    await settle(tester);
  }

  /// The form's own picture of the icon, beside "Change".
  HostIcon field(WidgetTester tester) {
    final row = find.ancestor(of: find.text('Change'), matching: find.byType(Row)).first;
    return tester.widget<HostIcon>(find.descendant(of: row, matching: find.byType(HostIcon)));
  }

  /// Every picture of the host's icon the form shows: the one beside
  /// "Change" and the one on the card that previews the host.
  List<HostIcon> pictures(WidgetTester tester) => tester.widgetList<HostIcon>(find.byType(HostIcon)).toList();

  /// The picker's own picture of the choice.
  HostIcon inPicker(WidgetTester tester) =>
      tester.widget<HostIcon>(find.byWidgetPredicate((w) => w is HostIcon && w.size == 40));

  Future<void> openPicker(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Change'));
    await tester.pump();
    await tester.tap(find.text('Change'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Choose an icon'), findsOneWidget);
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('host-icon-color')), matching: find.text(label)));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Apply'));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.text(lookupAppLocalizations(const Locale('en')).connectionSaveChanges));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  testWidgets('a host in a group, nothing chosen: its own colour; the picker names the group; the choice is saved',
      (tester) async {
    await pump(tester, connectionId: 'c1');
    expect(field(tester).iconColor, isNull);
    expect(field(tester).labelColor, _blue, reason: 'what it would follow');
    expect(pictures(tester), hasLength(3),
        reason: 'in the header (the host\'s icon), beside "Change", and on the preview of the card');
    expect(pictures(tester).map((p) => (p.iconId, p.iconColor, p.labelColor)).toSet(), {('debian', null, _blue)});

    await openPicker(tester);
    expect(find.text('Group color'), findsOneWidget);
    // The picker is told whose colour that is, and what colour.
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('host-icon-color')), matching: find.text('Group color')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.widget<Text>(find.byKey(const ValueKey('host-icon-color-hint'))).data, 'Using the group "Web" color');
    expect(inPicker(tester).labelColor, _blue);
    await tester.tap(find.text('Apply'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(field(tester).iconColor, HostIconColor.followsLabel);
    expect(pictures(tester).map((p) => (p.iconColor, p.labelColor)).toSet(), {(HostIconColor.followsLabel, _blue)},
        reason: 'the preview of the card too');

    // Not saved until Save.
    expect((await db.connectionsDao.getById('c1'))!.iconColor, isNull);
    await save(tester);
    final saved = (await db.connectionsDao.getById('c1'))!;
    expect(saved.iconColor, HostIconColor.followsLabel);
    expect(saved.iconId, 'debian');
    expect(closed, isTrue);
    await finish(tester);
  });

  testWidgets('a host that has a choice opens with it, and it can be put back to the icon\'s own', (tester) async {
    await pump(tester, connectionId: 'c1', iconColor: 0xFF22C55E);
    expect(field(tester).iconColor, 0xFF22C55E);
    await openPicker(tester);
    expect(inPicker(tester).iconColor, 0xFF22C55E, reason: 'the picker opens with what the host has');
    expect(find.byKey(const ValueKey('host-icon-color-swatches')), findsOneWidget);
    await choose(tester, "Icon's own");
    expect(field(tester).iconColor, isNull);
    await save(tester);
    expect((await db.connectionsDao.getById('c1'))!.iconColor, isNull);
    await finish(tester);
  });

  testWidgets('saving something else leaves the choice as it is', (tester) async {
    await pump(tester, connectionId: 'c1', iconColor: HostIconColor.followsLabel);
    await tester.enterText(find.widgetWithText(TextField, 'web-01').first, 'web-01b');
    await tester.pump();
    await save(tester);
    final saved = (await db.connectionsDao.getById('c1'))!;
    expect(saved.label, 'web-01b');
    expect(saved.iconColor, HostIconColor.followsLabel);
    await finish(tester);
  });

  testWidgets('a new host is saved with the icon and the colour chosen for it', (tester) async {
    await pump(tester);
    final en = lookupAppLocalizations(const Locale('en'));
    await tester.enterText(find.widgetWithText(TextField, en.connectionNicknameHint), 'web-03');
    await tester.enterText(find.widgetWithText(TextField, en.phoneUiFormAddressHint), '192.168.10.23');
    await tester.pump();
    await openPicker(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is OsIcon && w.osId == 'ubuntu' && w.size == 32));
    await tester.pump(const Duration(milliseconds: 200));
    // No group and no label on a new host: the choice is still there to make.
    await choose(tester, 'Group color');
    expect(field(tester).iconId, 'ubuntu');
    expect(field(tester).iconColor, HostIconColor.followsLabel);
    await tester.tap(find.text(en.connectionSaveConnection));
    await settle(tester);
    final made = (await db.connectionsDao.getAll()).single;
    expect([made.label, made.host, made.iconId, made.iconColor],
        ['web-03', '192.168.10.23', 'ubuntu', HostIconColor.followsLabel]);
    await finish(tester);
  });

  testWidgets('a host with a colour label of its own: the picker names the label, and the icon would take the label\'s',
      (tester) async {
    await pump(tester, connectionId: 'c1', labelColor: _pink.toARGB32());
    expect(field(tester).labelColor, _pink, reason: 'the label over the group');
    await openPicker(tester);
    expect(find.text('Label color'), findsOneWidget);
    expect(find.text('Group color'), findsNothing);
    await finish(tester);
  });

  testWidgets('a host with no label and no group: the picker says there is nothing to follow yet', (tester) async {
    await pump(tester, connectionId: 'c1', group: null, iconColor: HostIconColor.followsLabel);
    expect(field(tester).labelColor, isNull);
    await openPicker(tester);
    expect(find.text('This host has no color label and is in no group, so its icon keeps its own color until it has one.'),
        findsOneWidget);
    await finish(tester);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
