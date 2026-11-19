import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/model/rdp_gateway_offered.dart';
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The host editor for an RDP host (4.0): the RDP pill,
/// offered only once its session is in the app ([rdpOfferedProvider]); port
/// 3389; reached directly (a plain note, RDP being always inside TLS) or
/// through an SSH host; the key's user name and password with the domain
/// note; signing in without NLA behind a switch whose warning shows while it
/// is on; the graphics choice; the remote resized to the tab by default; no
/// Unix socket, no picture quality and no test of VNC's.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  setUp(() async {
    // These tests look at what a screen's More options hold: open from the start.
    debugScreenMoreOpen = true;
    debugTopSnackBarOnPhone = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 11, 13);
    Future<void> add(String id, String label, String protocol, int port, {String? via, String? options}) =>
        db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: label,
              host: via == null ? '$label.example.com' : 'localhost',
              port: Value(port),
              protocol: Value(protocol),
              connectViaId: Value(via),
              screenOptions: Value(options),
              lastConnected: Value(protocol == 'ssh' ? DateTime(2026, 11, 12) : null),
              createdAt: at,
              updatedAt: at,
            ));
    await add('h-gw', 'gw', 'ssh', 22);
    await add('r-office', 'office-pc', 'rdp', 3389, via: 'h-gw', options: '{"v":1,"nla":false,"graphics":"remotefx"}');
    await add('r-home', 'home-pc', 'rdp', 3389);
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
      {bool offered = true,
      bool gateway = false,
      Locale locale = const Locale('en'),
      Size size = const Size(1300, 1400)}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
      rdpOfferedProvider.overrideWithValue(offered),
      rdpGatewayOfferedProvider.overrideWithValue(gateway),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
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
  Finder field(String text) => find.byWidgetPredicate((w) => w is TextField && w.controller?.text == text);

  testWidgets('RDP is not among a new host\'s kinds until its session is in the app; a host that is one keeps its pill',
      (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(inDialog: true, onClose: () {}), offered: false);
    expect(find.text('VNC'), findsWidgets);
    expect(find.text('RDP'), findsNothing);
    await finish(tester);

    await pump(tester, ConnectionEditScreen(connectionId: 'r-home', inDialog: true, onClose: () {}), offered: false);
    expect(find.text('RDP'), findsWidgets, reason: 'what it is can be read and edited');
    expect(keyed('host-edit-rdp-without-nla'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a new RDP host: port 3389, reached directly with a plain note, the remote resized to the tab, NLA on, '
      'and nothing of VNC\'s or a terminal\'s', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(inDialog: true, onClose: () {}));
    await tester.tap(find.text('RDP').first);
    await settle(tester);
    expect(field('3389'), findsOneWidget);
    expect(keyed('host-edit-screen-reach'), findsOneWidget);
    expect(keyed('host-edit-rdp-direct-note'), findsOneWidget);
    expect(anywhere(en.connectionEditRdpDirectNote), findsOneWidget);
    expect(keyed('host-edit-screen-direct-warning'), findsNothing, reason: "VNC's warning is not RDP's");
    expect(anywhere(en.connectionEditScreenDirectWarning), findsNothing);
    expect(anywhere(en.connectionEditRdpPasswordNote), findsOneWidget);
    expect(anywhere(en.connectionEditScreenPasswordNote), findsNothing, reason: 'no word of 8 characters');
    // RDP's own two.
    expect(keyed('host-edit-rdp-without-nla'), findsOneWidget);
    expect(anywhere(en.connectionEditRdpWithoutNla), findsOneWidget);
    for (final g in ScreenGraphics.values) {
      expect(keyed('host-edit-rdp-graphics-$g'), findsOneWidget);
    }
    // How many displays (4.0): one unless its person picks more.
    for (final n in [1, 2, 3, 4]) {
      expect(keyed('host-edit-rdp-displays-$n'), findsOneWidget);
    }
    expect(anywhere(en.connectionEditRdpDisplaysNote), findsOneWidget);
    // Relative mouse: a switch that is off.
    expect(keyed('host-edit-rdp-relative-mouse'), findsOneWidget);
    expect(anywhere(en.connectionEditRdpRelativeMouseNote), findsOneWidget);
    // Text size on the remote: nothing said (Auto) unless its person picks a size.
    for (final n in ScreenOptions.textScales) {
      expect(keyed('host-edit-rdp-text-size-$n'), findsOneWidget);
    }
    expect(anywhere(en.connectionEditRdpTextSizeNote), findsOneWidget);
    // A frame rate limit: none unless its person picks one.
    for (final n in ScreenOptions.frameLimits) {
      expect(keyed('host-edit-screen-frame-limit-$n'), findsOneWidget);
    }
    expect(anywhere(en.connectionEditScreenFrameLimitNote), findsOneWidget);
    expect(find.descendant(of: keyed('host-edit-rdp-text-size-150'), matching: find.text('150%')), findsOneWidget);
    // Not VNC's: a socket on the carrier, picture quality.
    expect(keyed('host-edit-screen-target-unix'), findsNothing);
    expect(keyed('host-edit-screen-quality-ScreenQuality.low'), findsNothing);
    // The screen's one Test (it reads the RDP server's answer; no sign-in), and no SSH test.
    expect(keyed('host-edit-screen-test'), findsOneWidget);
    expect(anywhere(en.zestHostTestFull), findsNothing, reason: 'no SSH test');
    // Nothing of a terminal's.
    expect(anywhere(en.connectionStartupCommand), findsNothing);
    expect(anywhere(en.hostScreenNoTerminal), findsWidgets);

    // The address is the one field with nothing in it yet beside the name: found by its hint.
    await tester.enterText(find.widgetWithText(TextField, en.phoneUiFormAddressHint).first, 'pc.example.com');
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveConnection));
    await settle(tester);
    final saved = (await db.select(db.connections).get()).singleWhere((c) => c.host == 'pc.example.com');
    expect(saved.protocol, 'rdp');
    expect(saved.port, 3389);
    expect(saved.connectViaId, isNull);
    final options = jsonDecode(saved.screenOptions!) as Map<String, Object?>;
    expect(options['scaling'], 'remote_resize');
    expect(options['target'], 'tcp');
    expect(options.containsKey('nla'), isFalse, reason: 'on, the default, is not written');
    expect(options.containsKey('graphics'), isFalse);
    expect(options.containsKey('displays'), isFalse, reason: 'one display is not written');
    expect(options.containsKey('relative_mouse'), isFalse, reason: 'off is not written');
    expect(ScreenOptions.decode(saved.screenOptions).nla, isTrue);
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('on a computer a screen choice is picked from the keyboard: Enter on the pill the keyboard is on',
      (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'r-home', inDialog: true, onClose: () {}));
    final pill = keyed('host-edit-rdp-displays-3');
    await tester.ensureVisible(pill);
    await settle(tester);
    // The keyboard's place is the pill's own (not whatever holds the form).
    final node = Focus.maybeOf(tester.element(find.descendant(of: pill, matching: find.text('3'))), scopeOk: true)!;
    expect(node.canRequestFocus, isTrue);
    expect(node.skipTraversal, isFalse, reason: 'Tab stops on it');
    final box = tester.renderObject<RenderBox>(pill);
    expect(node.rect.size, box.size, reason: 'the node is the pill, no wider');
    node.requestFocus();
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final saved = (await db.connectionsDao.getById('r-home'))!;
    expect((jsonDecode(saved.screenOptions!) as Map<String, Object?>)['displays'], 3);
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('without NLA is a switch that is off, and its warning is in sight while it is on; the graphics choice is saved',
      (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'r-home', inDialog: true, onClose: () {}));
    expect(anywhere(en.connectionEditRdpWithoutNlaNote), findsOneWidget);
    await tester.tap(find.descendant(of: keyed('host-edit-rdp-without-nla'), matching: find.text(en.connectionEditRdpWithoutNla)));
    await tester.tap(keyed('host-edit-rdp-graphics-${ScreenGraphics.basic}'));
    await tester.ensureVisible(keyed('host-edit-rdp-displays-3'));
    await tester.tap(keyed('host-edit-rdp-displays-3'));
    await settle(tester);
    final relative = find.descendant(
        of: keyed('host-edit-rdp-relative-mouse'), matching: find.text(en.connectionEditRdpRelativeMouse));
    await tester.ensureVisible(relative);
    await tester.tap(relative);
    await settle(tester);
    await tester.ensureVisible(keyed('host-edit-rdp-text-size-150'));
    await tester.tap(keyed('host-edit-rdp-text-size-150'));
    await settle(tester);
    await tester.ensureVisible(keyed('host-edit-screen-frame-limit-30'));
    await tester.tap(keyed('host-edit-screen-frame-limit-30'));
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final saved = (await db.connectionsDao.getById('r-home'))!;
    final options = jsonDecode(saved.screenOptions!) as Map<String, Object?>;
    expect(options['nla'], false);
    expect(options['graphics'], 'basic');
    expect(options['displays'], 3);
    expect(options['relative_mouse'], isTrue);
    expect(options['text_scale'], 150);
    expect(options['frame_limit'], 30);
    expect(saved.protocol, 'rdp');
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('a saved RDP host through an SSH host shows what it was saved with, and keeps it', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'r-office', inDialog: true, onClose: () {}));
    expect(anywhere('gw'), findsWidgets, reason: 'its SSH host');
    expect(keyed('host-edit-rdp-direct-note'), findsNothing);
    expect(field('localhost'), findsOneWidget);
    await tester.enterText(field('office-pc').first, 'office');
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final saved = (await db.connectionsDao.getById('r-office'))!;
    expect(saved.label, 'office');
    expect(saved.connectViaId, 'h-gw');
    final o = ScreenOptions.decode(saved.screenOptions);
    expect(o.nla, isFalse, reason: 'as it was saved');
    expect(o.graphics, ScreenGraphics.remotefx);
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('"Add a screen for this host" as RDP: the SSH host filled in, localhost:3389', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester,
        ConnectionEditScreen(inDialog: true, onClose: () {}, initialProtocol: ConnectionProtocol.rdp, initialVia: 'h-gw'));
    expect(anywhere('gw'), findsWidgets);
    expect(field('3389'), findsOneWidget);
    expect(field('localhost'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a VNC host that is saved never carries RDP\'s two options', (tester) async {
    debugHostFormOnComputer = true;
    final at = DateTime(2026, 11, 13);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 's-desk',
          label: 'desk',
          host: 'localhost',
          port: const Value(5900),
          protocol: const Value('vnc'),
          connectViaId: const Value('h-gw'),
          // As a hand-made or damaged record might hold them.
          screenOptions: const Value('{"v":1,"nla":false,"graphics":"basic","displays":3,"relative_mouse":true,"text_scale":150}'),
          createdAt: at,
          updatedAt: at,
        ));
    await pump(tester, ConnectionEditScreen(connectionId: 's-desk', inDialog: true, onClose: () {}));
    expect(keyed('host-edit-rdp-without-nla'), findsNothing);
    await tester.enterText(field('desk').first, 'desk-2');
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final options = jsonDecode((await db.connectionsDao.getById('s-desk'))!.screenOptions!) as Map<String, Object?>;
    expect(options.containsKey('nla'), isFalse);
    expect(options.containsKey('graphics'), isFalse);
    expect(options.containsKey('displays'), isFalse, reason: 'a VNC server has the displays it has');
    expect(options.containsKey('relative_mouse'), isFalse);
    expect(options.containsKey('text_scale'), isFalse);
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  // RD Gateway (4.0): a choice of "Reach through" for an RDP host.
  testWidgets('"Reach through" offers an RD Gateway only where this build does; chosen, its address, port and sign-in '
      'are saved in the options, and Directly takes it away', (tester) async {
    debugHostFormOnComputer = true;
    Future<void> openReach() async {
      await tester.tap(find.descendant(of: keyed('host-edit-screen-reach'), matching: find.text(en.connectionEditScreenDirect)).first);
      await settle(tester);
    }

    await pump(tester, ConnectionEditScreen(connectionId: 'r-home', inDialog: true, onClose: () {}));
    await openReach();
    expect(keyed('zest-select-item- rd-gateway'), findsNothing, reason: 'the switch is off');
    await finish(tester);

    await pump(tester, ConnectionEditScreen(connectionId: 'r-home', inDialog: true, onClose: () {}), gateway: true);
    // Test dials the PC directly: on for a host reached directly...
    bool testOn() => (tester.widget(keyed('host-edit-screen-test')) as dynamic).onPressed != null;
    expect(testOn(), isTrue);
    await openReach();
    await tester.tap(keyed('zest-select-item- rd-gateway'));
    await settle(tester);
    expect(keyed('host-edit-rdp-gateway'), findsOneWidget);
    // ... and off once it goes through a gateway, where no session dials the PC.
    expect(testOn(), isFalse);
    expect(keyed('host-edit-rdp-direct-note'), findsNothing);
    expect(anywhere(en.connectionEditRdpGatewayNote), findsOneWidget);
    expect(anywhere(en.connectionEditRdpGatewaySameSignIn), findsOneWidget, reason: "the PC's own sign-in at first");
    expect(field('443'), findsOneWidget);
    // Not an address: the form is not saved.
    await tester.enterText(keyed('host-edit-rdp-gateway-host'), 'rdg example');
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    expect(anywhere(en.connectionEditRdpGatewayHostInvalid), findsOneWidget);
    expect(ScreenOptions.decode((await db.connectionsDao.getById('r-home'))!.screenOptions).gateway, isNull);
    await tester.enterText(keyed('host-edit-rdp-gateway-host'), 'rdg.example.com');
    await tester.enterText(keyed('host-edit-rdp-gateway-port'), '8443');
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    var saved = (await db.connectionsDao.getById('r-home'))!;
    expect(saved.connectViaId, isNull);
    expect(jsonDecode(saved.screenOptions!)['gateway'], {'host': 'rdg.example.com', 'port': 8443});
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);

    // Opened again: shown as saved; Directly takes the gateway away.
    await pump(tester, ConnectionEditScreen(connectionId: 'r-home', inDialog: true, onClose: () {}), gateway: true);
    expect(field('rdg.example.com'), findsOneWidget);
    expect(field('8443'), findsOneWidget);
    await tester.tap(find.descendant(of: keyed('host-edit-screen-reach'), matching: find.text(en.connectionEditRdpGateway)).first);
    await settle(tester);
    await tester.tap(keyed('zest-select-item-null'));
    await settle(tester);
    expect(keyed('host-edit-rdp-gateway'), findsNothing);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    saved = (await db.connectionsDao.getById('r-home'))!;
    expect((jsonDecode(saved.screenOptions!) as Map).containsKey('gateway'), isFalse);
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('a gateway a sync brings while the editor is open is kept when the host is saved; one the person '
      'changed here is theirs', (tester) async {
    debugHostFormOnComputer = true;
    await pump(tester, ConnectionEditScreen(connectionId: 'r-home', inDialog: true, onClose: () {}), gateway: true);
    // Another device gives the host a gateway meanwhile.
    await (db.update(db.connections)..where((c) => c.id.equals('r-home'))).write(ConnectionsCompanion(
        screenOptions: const Value('{"v":1,"gateway":{"host":"rdg.example.test"}}'),
        updatedAt: Value(DateTime(2026, 11, 17))));
    await tester.enterText(field('home-pc').first, 'home');
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final saved = (await db.connectionsDao.getById('r-home'))!;
    expect(saved.label, 'home');
    expect(ScreenOptions.decode(saved.screenOptions).gateway, const ScreenGateway(host: 'rdg.example.test'),
        reason: 'untouched here: as the sync left it, never dropped (the PC would be dialled directly)');
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('a gateway this version cannot read is not shown, and kept as it came when the host is saved', (tester) async {
    debugHostFormOnComputer = true;
    await (db.update(db.connections)..where((c) => c.id.equals('r-home')))
        .write(const ConnectionsCompanion(screenOptions: Value('{"v":1,"gateway":{"host":"a b","later":1}}')));
    await pump(tester, ConnectionEditScreen(connectionId: 'r-home', inDialog: true, onClose: () {}), gateway: true);
    expect(keyed('host-edit-rdp-gateway'), findsNothing);
    await tester.enterText(field('home-pc').first, 'home');
    await settle(tester);
    await tester.tap(find.text(en.connectionSaveChanges));
    await settle(tester);
    final saved = (await db.connectionsDao.getById('r-home'))!;
    expect(saved.label, 'home');
    expect(jsonDecode(saved.screenOptions!)['gateway'], {'host': 'a b', 'later': 1});
    await tester.pump(const Duration(seconds: 7));
    await finish(tester);
  });

  testWidgets('on a phone, and in every language: the section is there and nothing runs over', (tester) async {
    for (final locale in AppLocalizations.supportedLocales) {
      for (final computer in [true, false]) {
        debugHostFormOnComputer = computer;
        await pump(tester, ConnectionEditScreen(connectionId: 'r-home', inDialog: computer, onClose: () {}),
            locale: locale, size: computer ? const Size(1300, 1400) : const Size(390, 1800));
        final l = lookupAppLocalizations(locale);
        expect(keyed('host-edit-rdp-without-nla'), findsOneWidget, reason: '$locale, computer $computer');
        expect(anywhere(l.connectionEditRdpWithoutNla), findsOneWidget, reason: '$locale');
        expect(anywhere(l.connectionEditRdpPasswordNote), findsOneWidget, reason: '$locale');
        expect(anywhere(l.connectionEditRdpDirectNote), findsOneWidget, reason: '$locale');
        expect(keyed('host-edit-rdp-graphics-${ScreenGraphics.remotefx}'), findsOneWidget);
        expect(keyed('host-edit-rdp-displays-4'), findsOneWidget);
        expect(anywhere(l.connectionEditRdpRelativeMouse), findsOneWidget, reason: '$locale');
        expect(anywhere(l.connectionEditRdpRelativeMouseNote), findsOneWidget, reason: '$locale');
        expect(anywhere(l.connectionEditRdpTextSize), findsOneWidget, reason: '$locale');
        expect(anywhere(l.connectionEditRdpTextSizeNote), findsOneWidget, reason: '$locale');
        expect(anywhere(l.connectionEditScreenFrameLimit), findsOneWidget, reason: '$locale');
        expect(anywhere(l.connectionEditScreenFrameLimitNote), findsOneWidget, reason: '$locale');
        expect(
          find.descendant(
              of: keyed('host-edit-screen-frame-limit-15'),
              matching: find.text(l.connectionEditScreenFrameLimitFps(15))),
          findsOneWidget,
          reason: '$locale',
        );
        expect(
          find.descendant(
              of: keyed('host-edit-rdp-text-size-0'), matching: find.text(l.connectionEditRdpTextSizeOwn)),
          findsOneWidget,
          reason: '$locale',
        );
        expect(
          find.descendant(
              of: keyed('host-edit-rdp-text-size-200'), matching: find.text(l.connectionEditRdpTextSizePercent(200))),
          findsOneWidget,
          reason: '$locale',
        );
        expect(anywhere(l.connectionEditRdpDisplays), findsOneWidget, reason: '$locale');
        expect(anywhere(l.connectionEditRdpDisplaysNote), findsOneWidget, reason: '$locale');
        expect(tester.takeException(), isNull, reason: '$locale, computer $computer');
        await finish(tester);
      }
    }
  });
  // What is needed to connect is what a screen's form shows; the rest is
  // behind More options, closed.
  group('what a remote screen needs to connect is all its form shows', () {
    const behind = [
      'host-edit-rdp-without-nla',
      'host-edit-rdp-graphics-ScreenGraphics.auto',
      'host-edit-rdp-displays-1',
      'host-edit-rdp-relative-mouse',
      'host-edit-rdp-sound',
      'host-edit-screen-frame-limit-0',
      'host-edit-screen-clipboard',
      'host-edit-screen-scaling-ScreenScaling.fit',
      'host-edit-screen-view-only',
    ];

    testWidgets('an RDP host: its address, how it is reached and its sign-in, one line on what to turn on on the PC, '
        'and More options closed; opened, everything a session starts with is there, as it was', (tester) async {
      debugScreenMoreOpen = null;
      debugHostFormOnComputer = true;
      await pump(tester, ConnectionEditScreen(connectionId: 'r-home', inDialog: true, onClose: () {}));
      expect(keyed('host-edit-screen-reach'), findsOneWidget);
      expect(field('home-pc.example.com'), findsOneWidget);
      expect(keyed('host-edit-screen-password-note'), findsOneWidget);
      expect(anywhere(en.connectionEditRdpTurnOnNote), findsOneWidget);
      expect(anywhere(en.connectionEditVncTurnOnNote), findsNothing);
      expect(anywhere(en.connectionEditScreenMoreOptions), findsOneWidget);
      expect(keyed('host-edit-screen-options'), findsNothing);
      for (final key in behind) {
        expect(keyed(key), findsNothing, reason: key);
      }

      await tester.ensureVisible(keyed('host-edit-screen-more'));
      await tester.tap(keyed('host-edit-screen-more'));
      await tester.pump();
      expect(keyed('host-edit-screen-options'), findsOneWidget);
      for (final key in behind) {
        expect(keyed(key), findsOneWidget, reason: key);
      }
      // And closed again by the same press.
      await tester.ensureVisible(keyed('host-edit-screen-more'));
      await tester.tap(keyed('host-edit-screen-more'));
      await tester.pump();
      expect(keyed('host-edit-screen-options'), findsNothing);
      await finish(tester);
    });

    testWidgets('a host that signs in without NLA opens with its options shown: the warning stays in sight',
        (tester) async {
      debugScreenMoreOpen = null;
      debugHostFormOnComputer = true;
      await pump(tester, ConnectionEditScreen(connectionId: 'r-office', inDialog: true, onClose: () {}));
      expect(keyed('host-edit-screen-options'), findsOneWidget);
      expect(keyed('host-edit-rdp-without-nla'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a new host of each kind: closed, with the line for its kind; saved without opening them, its options '
        'are the defaults a new host has', (tester) async {
      debugScreenMoreOpen = null;
      debugHostFormOnComputer = true;
      await pump(tester, ConnectionEditScreen(inDialog: true, onClose: () {}));
      await tester.tap(find.text('VNC').first);
      await tester.pump();
      expect(anywhere(en.connectionEditVncTurnOnNote), findsOneWidget);
      expect(keyed('host-edit-screen-options'), findsNothing);
      await tester.tap(find.text('RDP').first);
      await tester.pump();
      expect(anywhere(en.connectionEditRdpTurnOnNote), findsOneWidget);
      expect(anywhere(en.connectionEditVncTurnOnNote), findsNothing);
      expect(keyed('host-edit-screen-options'), findsNothing);
      expect(keyed('host-edit-rdp-displays-1'), findsNothing, reason: 'no number of displays is asked for before connecting');
      await finish(tester);
    });

    testWidgets('on a phone the group is named for the screen (its form has a More options of its own), 48 high',
        (tester) async {
      debugScreenMoreOpen = null;
      debugHostFormOnComputer = false;
      await pump(tester, const ConnectionEditScreen(connectionId: 'r-home'), size: const Size(412, 1800));
      expect(anywhere(en.connectionEditScreenOptionsPhone), findsOneWidget);
      expect(keyed('host-edit-screen-options'), findsNothing);
      expect(tester.getSize(keyed('host-edit-screen-more')).height, greaterThanOrEqualTo(48));
      await tester.ensureVisible(keyed('host-edit-screen-more'));
      await tester.tap(keyed('host-edit-screen-more'));
      await tester.pump();
      expect(keyed('host-edit-screen-options'), findsOneWidget);
      await finish(tester);
    });
  });
}
