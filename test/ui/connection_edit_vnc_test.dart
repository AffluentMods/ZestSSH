import 'dart:convert';

import 'dart:ui' show SemanticsAction, Tristate;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart' show defaultIconIdFor, screenCarrierKind;
import 'package:zestssh/features/screens/screen_settings.dart' show kScreenScalingDefaultKey;
import 'package:zestssh/features/screens/session/screen_team_rules.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart' show connectionEditorTargetProvider;
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/theme/ui_density.dart' show ZestDensity;
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

import '../a11y/a11y_checks.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The host editor for a remote screen (4.0): the VNC
/// pill, the SSH host it is reached through (never locked for a free
/// account), an address and port or a Unix socket on that host, the key's
/// VNC password with the 8-character note, the clipboard by space, scaling,
/// quality and view only; nothing of a terminal's.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  setUp(() async {
    // These tests look at what a screen's More options hold: open from the start.
    debugScreenMoreOpen = true;
    debugTopSnackBarOnPhone = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 11, 8);
    Future<void> add(String id, String label, String protocol, int port,
        {String? via, String? options, DateTime? last}) =>
        db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: label,
              host: id == 's-desk' ? 'localhost' : '$label.example.com',
              port: Value(port),
              protocol: Value(protocol),
              connectViaId: Value(via),
              screenOptions: Value(options),
              lastConnected: Value(last),
              createdAt: at,
              updatedAt: at,
            ));
    await add('h-gw', 'gw', 'ssh', 22, last: DateTime(2026, 11, 7));
    await add('h-old', 'old-gw', 'ssh', 22, last: DateTime(2026, 10, 1));
    await add('h-files', 'nas-files', 'sftp', 22, last: DateTime(2026, 11, 8));
    await add('s-desk', 'desk', 'vnc', 5900, via: 'h-gw', options: '{"v":1}');
  });

  tearDown(() async {
    debugScreenMoreOpen = null;
    debugHostFormOnComputer = null;
    debugTopSnackBarOnPhone = null;
    await db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pump(WidgetTester tester, Widget home,
      {bool pro = false,
      Map<String, Object> prefsValues = const {},
      ScreenTeamRules teamRules = ScreenTeamRules.none,
      bool touch = false,
      Size size = const Size(1300, 1400)}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(pro)),
      screenTeamRulesProvider.overrideWithValue(teamRules),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark().copyWith(extensions: [...AppTheme.dark().extensions.values, ZestDensity(touch: touch)]),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: home),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder anywhere(String text) => find.text(text, skipOffstage: false);
  Finder keyed(String key) => find.byKey(ValueKey(key), skipOffstage: false);

  testWidgets('a free account picks VNC for a new host: reached through the SSH host last used (never locked), '
      'and saved at a Unix socket on it with the options', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(inDialog: true, onClose: () {}));
    await tester.tap(find.text('VNC').first);
    await settle(tester);
    // The SSH host last connected to, not an SFTP-only one, and no Squeezed lock on the picker.
    expect(keyed('host-edit-screen-reach'), findsOneWidget);
    expect(anywhere('gw'), findsWidgets);
    expect(anywhere(en.connectionEditScreenVia), findsWidgets);
    expect(keyed('host-edit-screen-direct-warning'), findsNothing);
    expect(keyed('host-edit-screen-password-note'), findsOneWidget);
    expect(anywhere(en.connectionConnectVia), findsNothing, reason: 'the jump field of SSH hosts is not shown');
    // Nothing of a terminal's.
    expect(anywhere(en.connectionStartupCommand), findsNothing);
    expect(anywhere(en.hostScreenNoTerminal), findsWidgets);
    // Own space: the clipboard is on, and there is no team lock.
    expect(keyed('host-edit-screen-clipboard-members'), findsNothing);

    await tester.tap(keyed('host-edit-screen-target-unix'));
    await settle(tester);
    expect(keyed('host-port'), findsNothing, reason: 'a socket has no address or port');
    await tester.enterText(keyed('host-edit-screen-socket'), '~/.vnc/zest.sock');
    await tester.tap(keyed('host-edit-screen-scaling-ScreenScaling.oneToOne'));
    await tester.tap(keyed('host-edit-screen-quality-ScreenQuality.low'));
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveConnection));
    await settle(tester);
    final saved = (await db.select(db.connections).get()).singleWhere((c) => c.id.length > 8 && c.protocol == 'vnc');
    expect(saved.connectViaId, 'h-gw');
    expect(saved.host, 'localhost');
    final options = jsonDecode(saved.screenOptions!) as Map<String, Object?>;
    expect(options['target'], 'unix');
    expect(options['socket'], '~/.vnc/zest.sock');
    expect(options['scaling'], 'one_to_one');
    expect(options['quality'], 'low');
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('"Add a screen for this host": the carrier filled in, localhost:5900', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester,
        ConnectionEditScreen(inDialog: true, onClose: () {}, initialProtocol: ConnectionProtocol.vnc, initialVia: 'h-old'));
    expect(anywhere('old-gw'), findsWidgets);
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '5900'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'localhost'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a screen has one Test, "Test the screen", on a computer and on a phone; no SSH tests', (tester) async {
    for (final computer in [true, false]) {
      debugHostFormOnComputer = computer;
      await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: computer, onClose: () {}), pro: true);
      expect(keyed('host-edit-screen-test'), findsOneWidget, reason: 'computer: $computer');
      expect(anywhere(en.screenTestButton), findsOneWidget);
      expect(anywhere(en.zestHostTestReachability), findsNothing);
      expect(anywhere(en.zestHostTestFull), findsNothing);
      await finish(tester);
    }
  });

  // Found in a security review.
  testWidgets('a saved screen whose carrier is gone says so, not that it is reached directly, and keeps pointing at '
      'it when saved', (tester) async {
    debugHostFormOnComputer = true;
    await db.customStatement("UPDATE connections SET connect_via_id = 'h-deleted' WHERE id = 's-desk'");
    await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: true, onClose: () {}), pro: true);
    expect(keyed('host-edit-screen-carrier-gone'), findsOneWidget);
    expect(anywhere(en.screenCarrierGone), findsOneWidget);
    expect(keyed('host-edit-screen-direct-warning'), findsNothing);
    await tester.tap(find.descendant(of: keyed('host-edit-screen-view-only'), matching: find.text(en.connectionEditScreenViewOnly)));
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    expect((await db.connectionsDao.getById('s-desk'))!.connectViaId, 'h-deleted', reason: 'never saved as direct');
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('a saved screen: reached directly, it says TLS is required; view only is saved; an SSH host\'s record '
      'keeps no options', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: true, onClose: () {}), pro: true);
    expect(anywhere(en.connectionEditScreenNetworkNote), findsOneWidget);
    expect(anywhere(en.connectionEditScreenClipboard), findsOneWidget);
    await tester.tap(find.descendant(of: keyed('host-edit-screen-view-only'), matching: find.text(en.connectionEditScreenViewOnly)));
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final saved = (await db.connectionsDao.getById('s-desk'))!;
    expect((jsonDecode(saved.screenOptions!) as Map)['view_only'], isTrue);
    expect(saved.connectViaId, 'h-gw');
    expect((await db.connectionsDao.getById('h-gw'))!.screenOptions, isNull);
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('a team that opens remote screens through SSH only: the editor offers no direct connection, and a '
      'screen with none says why it will not open; without the rule it is offered', (tester) async {
    debugHostFormOnComputer = true;
    await db.customStatement("UPDATE connections SET connect_via_id = NULL, host = 'desk.example.com' WHERE id = 's-desk'");
    List<String?> offered() => [
          for (final i in tester
              .widget<ZestSelect<String?>>(find.descendant(
                  of: keyed('host-edit-screen-reach'), matching: find.byType(ZestSelect<String?>, skipOffstage: false)))
              .items)
            i.value,
        ];

    await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: true, onClose: () {}),
        pro: true, teamRules: const ScreenTeamRules(sshOnly: true));
    expect(keyed('host-edit-screen-team-ssh-only'), findsOneWidget);
    expect(anywhere(en.connectionEditScreenTeamSshOnly), findsOneWidget);
    expect(keyed('host-edit-screen-direct-warning'), findsNothing, reason: 'one thing is said, the one that decides');
    expect(offered(), ['h-gw', 'h-old'], reason: 'its SSH hosts, and no direct connection');
    await finish(tester);

    await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: true, onClose: () {}), pro: true);
    expect(keyed('host-edit-screen-team-ssh-only'), findsNothing);
    expect(keyed('host-edit-screen-direct-warning'), findsOneWidget);
    expect(offered(), contains(null));
    await finish(tester);

    // Through an SSH host: nothing is said of the rule.
    await db.customStatement("UPDATE connections SET connect_via_id = 'h-gw', host = 'localhost' WHERE id = 's-desk'");
    await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: true, onClose: () {}),
        pro: true, teamRules: const ScreenTeamRules(sshOnly: true));
    expect(keyed('host-edit-screen-team-ssh-only'), findsNothing);
    expect(offered(), ['h-gw', 'h-old']);
    await finish(tester);
  });

  testWidgets('a team that shares nothing with remote screens: the clipboard switch is off, says why and cannot be '
      'turned on; the host\'s own setting is kept when saved', (tester) async {
    debugHostFormOnComputer = true;
    await db.customStatement('UPDATE connections SET screen_options = ? WHERE id = ?', ['{"v":1,"clipboard":"on"}', 's-desk']);
    await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: true, onClose: () {}),
        pro: true, teamRules: const ScreenTeamRules(lockRedirections: true));
    final row = keyed('host-edit-screen-clipboard');
    expect(find.descendant(of: row, matching: find.text(en.connectionEditScreenTeamNoSharing, skipOffstage: false)),
        findsOneWidget);
    expect(keyed('host-edit-screen-clipboard-members'), findsNothing);
    expect(
        tester.widget<Opacity>(find.descendant(of: row, matching: find.byType(Opacity, skipOffstage: false)).first).opacity,
        lessThan(1),
        reason: 'drawn as a switch that cannot be changed');
    // A tap on it changes nothing; another change is saved with the host's own clipboard setting as it was.
    await tester.tap(find.descendant(of: row, matching: find.text(en.connectionEditScreenClipboard, skipOffstage: false)));
    await tester.tap(find.descendant(of: keyed('host-edit-screen-view-only'), matching: find.text(en.connectionEditScreenViewOnly)));
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final saved = jsonDecode((await db.connectionsDao.getById('s-desk'))!.screenOptions!) as Map;
    expect((saved['clipboard'], saved['view_only']), ('on', true));
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);

    // Without the rule the switch is the host's own again.
    await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: true, onClose: () {}), pro: true);
    expect(anywhere(en.connectionEditScreenTeamNoSharing), findsNothing);
    expect(
        tester.widget<Opacity>(find.descendant(of: row, matching: find.byType(Opacity, skipOffstage: false)).first).opacity,
        1);
    await finish(tester);
  });

  testWidgets('accessibility: the editor of a VNC screen and of an RDP host meets the 4.0 pass on a computer and on a '
      'phone (named controls, targets, contrast), and its switches say that they are switches and whether they '
      'are on', (tester) async {
    final handle = tester.ensureSemantics();
    // Save, drawn turned off until something changed: no contrast is asked of that.
    final off = {en.connectionSaveChanges, 'icon U+F1EE'};
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'r-pc',
          label: 'office-pc',
          host: 'localhost',
          port: const Value(3389),
          protocol: const Value('rdp'),
          connectViaId: const Value('h-gw'),
          screenOptions: const Value('{"v":1}'),
          createdAt: DateTime(2026, 11, 8),
          updatedAt: DateTime(2026, 11, 8),
        ));
    for (final (id, computer) in [('s-desk', true), ('r-pc', true), ('s-desk', false), ('r-pc', false)]) {
      debugHostFormOnComputer = computer;
      final where = '$id on a ${computer ? 'computer' : 'phone'}';
      await pump(tester, ConnectionEditScreen(connectionId: id, inDialog: computer, onClose: () {}),
          pro: true, touch: !computer, size: computer ? const Size(1300, 1400) : const Size(390, 2600));
      expect(await a11yCheck(tester, computer: computer, where: where, except: off), isEmpty);
      // Its switches: a name, on or off, and a press.
      for (final name in [
        en.connectionEditScreenClipboard,
        en.connectionEditScreenViewOnly,
        if (id == 'r-pc') en.connectionEditRdpWithoutNla,
      ]) {
        final data = tester.getSemantics(find.bySemanticsLabel(name).first).getSemanticsData();
        expect(data.flagsCollection.isToggled, isNot(Tristate.none), reason: '$where: $name says no state');
        expect(data.hasAction(SemanticsAction.tap), isTrue, reason: '$where: $name has no press');
      }
      final viewOnly = tester.getSemantics(find.bySemanticsLabel(en.connectionEditScreenViewOnly).first);
      expect(viewOnly.getSemanticsData().flagsCollection.isToggled, Tristate.isFalse, reason: where);
      await finish(tester);
    }
    handle.dispose();
  });

  testWidgets('user@host in a screen\'s address is refused, never saved as the host\'s name; an SSH host with no key '
      'says it signs in as the default user', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester,
        ConnectionEditScreen(inDialog: true, onClose: () {}, initialProtocol: ConnectionProtocol.vnc, initialVia: 'h-gw'));
    // gw has no key: it signs in as Settings' default user (root), and says so.
    expect(keyed('host-edit-screen-carrier-no-key'), findsOneWidget);
    expect(anywhere(en.connectionEditScreenCarrierNoKey('gw', 'root')), findsOneWidget);
    final address = find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'localhost');
    await tester.enterText(address, 'alex@10.0.2.2');
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveConnection));
    await settle(tester);
    expect(anywhere(en.connectionEditScreenAddressUser), findsOneWidget);
    expect((await db.select(db.connections).get()).where((c) => c.protocol == 'vnc').length, 1,
        reason: 'only the screen there was before');

    // The address alone saves.
    await tester.enterText(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'alex@10.0.2.2'),
        '10.0.2.2');
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveConnection));
    await settle(tester);
    final saved = (await db.select(db.connections).get()).where((c) => c.protocol == 'vnc' && c.id != 's-desk');
    expect(saved.single.host, '10.0.2.2');
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('an SSH host with a key: no word of the default user', (tester) async {
    debugHostFormOnComputer = true;
    final at = DateTime(2026, 11, 8);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k1', label: 'alex key', username: 'alex', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
    await (db.update(db.connections)..where((c) => c.id.equals('h-gw'))).write(const ConnectionsCompanion(identityId: Value('k1')));
    await pump(tester,
        ConnectionEditScreen(inDialog: true, onClose: () {}, initialProtocol: ConnectionProtocol.vnc, initialVia: 'h-gw'));
    expect(keyed('host-edit-screen-reach'), findsOneWidget);
    expect(keyed('host-edit-screen-carrier-no-key'), findsNothing);
    await finish(tester);
  });

  testWidgets("a new screen starts at Settings' scaling for new screens; a saved one keeps its own", (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester,
        ConnectionEditScreen(inDialog: true, onClose: () {}, initialProtocol: ConnectionProtocol.vnc, initialVia: 'h-gw'),
        prefsValues: {kScreenScalingDefaultKey: 'oneToOne'});
    await tester.tap(find.text(en.connectionSaveConnection));
    await settle(tester);
    final saved = (await db.select(db.connections).get()).singleWhere((c) => c.protocol == 'vnc' && c.id != 's-desk');
    expect((jsonDecode(saved.screenOptions!) as Map)['scaling'], 'one_to_one');
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);

    await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: true, onClose: () {}),
        prefsValues: {kScreenScalingDefaultKey: 'oneToOne'});
    await tester.tap(find.descendant(of: keyed('host-edit-screen-view-only'), matching: find.text(en.connectionEditScreenViewOnly)));
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    expect((jsonDecode((await db.connectionsDao.getById('s-desk'))!.screenOptions!) as Map)['scaling'], 'fit');
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  test('a screen shows a screen icon where none is chosen; SSH-like hosts can carry one', () {
    expect(defaultIconIdFor('vnc'), 'desktop');
    expect(defaultIconIdFor('ssh'), isNull);
    expect([for (final p in ['ssh', 'mosh', 'et', 'sftp', 'ftps', 'vnc', 'telnet']) screenCarrierKind(p)],
        [true, true, true, false, false, false, false]);
  });

  group('a saved SSH host offers a screen of its own (4.0)', () {
    setUp(() => ConnectionEditScreen.debugDesktopShell = true);
    tearDown(() => ConnectionEditScreen.debugDesktopShell = null);

    testWidgets('under Protocol: "Remote screen for this host? Add a screen", which closes the editor and opens a new '
        'screen reached through the host, VNC or RDP asked first', (tester) async {
      debugHostFormOnComputer = true;
      var closed = 0;
      await pump(tester, ConnectionEditScreen(connectionId: 'h-gw', inDialog: true, onClose: () => closed++));
      expect(keyed('host-edit-add-screen-line'), findsOneWidget);
      expect(anywhere(en.hostEditScreenLine), findsOneWidget);
      await tester.tap(keyed('host-edit-add-screen'));
      await settle(tester);
      await tester.tap(keyed('host-screen-kind-vnc'));
      await settle(tester);
      expect(closed, 1, reason: "the host's own editor closes first");
      final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
      final target = c.read(connectionEditorTargetProvider)!;
      expect(target.connectionId, isNull);
      expect(target.initialProtocol, ConnectionProtocol.vnc);
      expect(target.initialVia, 'h-gw');
      expect(target.initialLabel, 'gw VNC');
      await finish(tester);
    });

    testWidgets('a screen host, and a host that carries none, have no such line', (tester) async {
      debugHostFormOnComputer = true;
      await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: true, onClose: () {}));
      expect(keyed('host-edit-add-screen-line'), findsNothing);
      await finish(tester);
      await pump(tester, ConnectionEditScreen(connectionId: 'h-files', inDialog: true, onClose: () {}));
      expect(keyed('host-edit-add-screen-line'), findsNothing);
      await finish(tester);
    });

    testWidgets("a new RDP screen of a host: the host's own address on 3389, through it, named as asked",
        (tester) async {
      debugHostFormOnComputer = true;
      await pump(
          tester,
          ConnectionEditScreen(
              inDialog: true,
              onClose: () {},
              initialProtocol: ConnectionProtocol.rdp,
              initialVia: 'h-gw',
              initialHost: 'gw.example.com',
              initialLabel: 'gw RDP'));
      expect(anywhere('gw'), findsWidgets);
      expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '3389'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'gw.example.com'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == 'gw RDP'), findsOneWidget);
      await finish(tester);
    });
  });
}
