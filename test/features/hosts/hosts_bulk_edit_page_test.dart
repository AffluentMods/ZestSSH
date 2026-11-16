import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/open_many_hosts.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/state/kex_refused_hosts.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// The Hosts page's select, as remade
/// (3.4): Select on the hosts' line, the box over them that selects every
/// host shown, each card's box before its icon, the bar's Edit… and its
/// Tags and Move to group opening the editor at the right, Escape closing
/// the editor before it ends the selection, the edit said with Undo; and
/// many hosts opened a few at a time.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final opened = <String>[];

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false, String? usernameOverride, String? initialCommand, String? asAccount, bool unattended = false, Space? space}) {
    final id = 's-${connection.id}';
    opened.add(id);
    state = {
      ...state,
      id: SessionState(
        status: SessionStatus.connecting,
        connectionId: connection.id,
        connectionLabel: connection.label,
        host: connection.host,
        port: 22,
        session: TerminalSession(
          id: id,
          connectionId: connection.id,
          terminal: Terminal(),
          shell: _Shell(),
          startedAt: DateTime(2026, 10, 28),
        ),
      ),
    };
    return id;
  }

  /// The session [id] has connected.
  void connected(String id) => state = {...state, id: state[id]!.copyWith(status: SessionStatus.connected)};
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late AppDatabase db;
  late ProviderContainer container;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pump(WidgetTester tester, {Set<String> refused = const {}}) async {
    tester.view.physicalSize = const Size(1500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2026, 10, 28);
    for (var i = 1; i <= 6; i++) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h$i',
            label: 'legacy-$i',
            host: '10.20.4.$i',
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
    ]);
    addTearDown(container.dispose);
    for (final id in refused) {
      container.read(kexRefusedHostsProvider.notifier).refused(id);
    }
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: HostsHomePage(onConnectTo: (_) {})),
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
  Set<String> selected() => container.read(hostMultiSelectProvider).selected;
  bool selecting() => container.read(hostMultiSelectProvider).active;
  final panel = find.byKey(const ValueKey('host-bulk-edit-panel'));

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
  }

  Future<void> ctrlClick(WidgetTester tester, String id) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.tap(card(id), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('Select starts and ends it; each card has its box before its icon; the box over the hosts takes them all',
      (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('host-card-box-h1')), findsNothing);
    await tap(tester, find.byKey(const ValueKey('hosts-select')));
    expect(selecting(), isTrue);
    expect(find.text(l10n.bulkSelectingButton), findsOneWidget);
    // The box, and the icon still beside it (as the card is designed).
    final box = tester.getRect(find.byKey(const ValueKey('host-card-box-h1')));
    final icon = tester.getRect(find.descendant(of: card('h1'), matching: find.byType(HostIcon)));
    expect(box.right, lessThanOrEqualTo(icon.left), reason: 'the box before the icon');
    expect(find.text(l10n.bulkSomeSelected(0, 6)), findsOneWidget);

    await tap(tester, find.byKey(const ValueKey('host-selection-all')));
    expect(selected(), {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'});
    expect(find.text(l10n.bulkAllSelected(6)), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('host-selection-all')));
    expect(selected(), isEmpty, reason: 'all selected: the box takes them out');

    await tap(tester, card('h2'));
    await tap(tester, card('h4'));
    expect(selected(), {'h2', 'h4'}, reason: 'a click while selecting adds a host');
    expect(find.text(l10n.bulkSomeSelected(2, 6)), findsOneWidget);
    final partial = tester.widget<HostSelectBox>(
        find.descendant(of: find.byKey(const ValueKey('host-selection-all')), matching: find.byType(HostSelectBox)));
    expect((partial.checked, partial.partial), (false, true), reason: 'a dash: some are');
    await tap(tester, find.byKey(const ValueKey('host-selection-clear')));
    expect(selected(), isEmpty);
    expect(selecting(), isTrue, reason: 'Clear selection: selecting goes on');
    await tap(tester, find.byKey(const ValueKey('hosts-select')));
    expect(selecting(), isFalse, reason: 'Selecting, clicked: done');
    await finish(tester);
  });

  testWidgets('Edit… opens the editor of the selection at the right; Escape closes it, then ends the selection',
      (tester) async {
    await pump(tester);
    await ctrlClick(tester, 'h1');
    await ctrlClick(tester, 'h3');
    expect(find.text(l10n.bulkHintFields), findsOneWidget, reason: 'the hints say Tags and Move open the editor');
    await tap(tester, find.byKey(const ValueKey('bulk-edit')));
    expect(panel, findsOneWidget);
    expect(find.descendant(of: panel, matching: find.text(l10n.bulkEditTitle(2))), findsOneWidget);
    expect(find.byKey(const ValueKey('host-bulk-veil')), findsOneWidget, reason: 'the page under a veil beside it');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(panel, findsNothing);
    expect(selected(), {'h1', 'h3'}, reason: 'the editor closed, the selection kept');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(selecting(), isFalse);
    await finish(tester);
  });

  testWidgets('Tags and Move to group open the editor with that field ready', (tester) async {
    await pump(tester);
    await ctrlClick(tester, 'h1');
    await ctrlClick(tester, 'h2');
    for (final (button, field) in [('bulk-tag', 'bulk-card-tags'), ('bulk-move', 'bulk-field-group')]) {
      await tap(tester, find.byKey(ValueKey(button)));
      expect(panel, findsOneWidget, reason: button);
      final at = tester.getRect(find.byKey(ValueKey(field)));
      final body = tester.getRect(find.byKey(const ValueKey('bulk-edit-body')));
      expect(at.top >= body.top && at.top < body.bottom, isTrue, reason: '$field in sight');
      await tap(tester, find.byKey(const ValueKey('bulk-edit-close')));
      expect(panel, findsNothing);
    }
    await finish(tester);
  });

  testWidgets('a host refused for an old key exchange says so on its card; Apply turns the mode on, said with Undo',
      (tester) async {
    await pump(tester, refused: {'h2'});
    expect(find.byKey(const ValueKey('host-card-old-kex-h2')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-card-old-kex-h1')), findsNothing);
    for (final id in ['h1', 'h2', 'h3']) {
      await ctrlClick(tester, id);
    }
    await tap(tester, find.byKey(const ValueKey('bulk-edit')));
    await tap(tester, find.byKey(const ValueKey('bulk-compat-needing')));
    await tap(tester, find.byKey(const ValueKey('bulk-edit-apply')));
    expect(find.text(l10n.bulkAppliedChanged(3)), findsOneWidget);
    expect(selecting(), isFalse, reason: 'applied: the selection is done');
    expect(panel, findsNothing);
    var r = (await tester.runAsync(() => db.connectionsDao.getAll()))!;
    expect({for (final c in r) c.id: c.compatibilityMode}['h2'], isTrue);
    expect([for (final c in r) if (c.compatibilityMode) c.id], ['h2']);
    await settle(tester);
    expect(find.byKey(const ValueKey('host-card-old-kex-h2')), findsNothing, reason: 'the mode is on: nothing to say');

    await tester.tap(find.text(l10n.hostsSelUndo));
    await settle(tester);
    r = (await tester.runAsync(() => db.connectionsDao.getAll()))!;
    expect([for (final c in r) if (c.compatibilityMode) c.id], isEmpty, reason: 'Undo puts it back');
    await tester.pump(const Duration(seconds: 12));
    await finish(tester);
  });

  group('opening many hosts', () {
    test('a few at a time: each batch once the one before has connected', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(_Sessions.new),
      ]);
      addTearDown(c.dispose);
      c.read(workTabsProvider);
      final sessions = c.read(activeSessionsProvider.notifier) as _Sessions;
      final hosts = [
        for (var i = 1; i <= 12; i++)
          Connection(
            id: 'h$i',
            label: 'legacy-$i',
            host: '10.20.4.$i',
            port: 22,
            colorIndex: 0,
            protocol: 'ssh',
            zlibCompression: false,
            forwardAgent: false,
            compatibilityMode: false,
            keepAliveSeconds: 0,
            envVars: '',
            sortOrder: i,
            sizeTier: 1,
            pinned: false,
            monitored: false,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
      ];
      final run = openHostsInBatches(c, hosts, size: 5);
      await Future<void>.delayed(Duration.zero);
      expect(sessions.opened, [for (var i = 1; i <= 5; i++) 's-h$i'], reason: 'the first five, and no more yet');
      for (var i = 1; i <= 4; i++) {
        sessions.connected('s-h$i');
      }
      await Future<void>.delayed(Duration.zero);
      expect(sessions.opened, hasLength(5), reason: 'one of the batch still connecting');
      sessions.connected('s-h5');
      await Future<void>.delayed(Duration.zero);
      expect(sessions.opened, hasLength(10));
      for (var i = 6; i <= 10; i++) {
        sessions.connected('s-h$i');
      }
      final result = await run;
      expect(sessions.opened, hasLength(12));
      expect(result.opened, 12);
      expect(c.read(workTabsProvider).tabs, hasLength(12), reason: 'a tab each');
    });
  });
}
