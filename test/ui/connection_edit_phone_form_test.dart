import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

import '../visual/shots_util.dart' show loadShotFonts;

/// The host form on a phone (4.0, as designed; before it, as a 3.0
/// UI review asked):
/// the protocols a grid of tiles with their whole names (one row of
/// pills cut "Teln..." and "Seri..."), each field's name above it, what the
/// host signs in with on the form, More options and the advanced options
/// folded, and Test and Save in a bar at the foot, with why Save is off. Its
/// values in the theme on screen; no resize grip on a phone.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  setUp(() async {
    debugTopSnackBarOnPhone = true;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 11, 12);
    for (final (id, label, user, method) in [
      ('k-deploy', 'deploy key', 'deploy', 'publicKey'),
      ('k-admin', 'admin password', 'admin', 'password'),
    ]) {
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: id,
            label: label,
            username: user,
            authMethod: method,
            createdAt: at,
          ));
    }
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: '192.168.10.21',
          port: const Value(22),
          identityId: const Value('k-deploy'),
          note: const Value('Behind the office VPN.'),
          createdAt: at,
          updatedAt: at,
        ));
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-plain',
          label: 'log-store',
          host: '192.168.10.24',
          port: const Value(22),
          createdAt: at,
          updatedAt: at,
        ));
  });

  tearDown(() async {
    debugHostFormOnComputer = null;
    debugHostFormLocalShell = null;
    debugTopSnackBarOnPhone = null;
    debugDefaultTargetPlatformOverride = null;
    await db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The form for [connectionId] (null: a new host), a page of the app
  /// opened over its home, on a phone (or a window [size] wide).
  Future<GoRouter> pump(WidgetTester tester,
      {String? connectionId, String themeId = 'graphite', Size size = const Size(390, 844)}) async {
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
    final theme = BuiltInThemes.getById(themeId);
    AppColors.applyTheme(theme.colorScheme);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(c.dispose);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('hosts'))),
      GoRoute(path: '/edit', builder: (_, _) => ConnectionEditScreen(connectionId: connectionId)),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        theme: theme.toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    router.push('/edit');
    await settle(tester);
    return router;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  }

  Finder keyed(String key) => find.byKey(ValueKey(key));
  Finder tile(String protocol) => keyed('host-form-protocol-$protocol');
  FilledButton save(WidgetTester tester) => tester.widget<FilledButton>(keyed('host-form-save'));

  Color portColor(WidgetTester tester) => tester
      .widget<TextField>(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '22'))
      .style!
      .color!;

  testWidgets("the port is drawn in the text colour of the theme on screen, after another theme's", (tester) async {
    await pump(tester, themeId: 'graphite');
    final dark = ZestTokens.textPrimary;
    expect(portColor(tester), dark);
    await unmount(tester);
    await pump(tester, themeId: 'default_light');
    expect(ZestTokens.textPrimary, isNot(dark), reason: 'the light theme has a text colour of its own');
    expect(portColor(tester), ZestTokens.textPrimary, reason: "the light theme's, not the first theme's");
    await unmount(tester);
    AppColors.applyTheme(BuiltInThemes.getById('graphite').colorScheme);
  });

  testWidgets("a phone's protocols: tiles of one size, 48 high, with their whole names; the chosen one checked, "
      'not told by colour alone; Mosh offered (the app\'s own client, 4.0), Eternal Terminal not', (tester) async {
    debugHostFormOnComputer = false;
    debugHostFormLocalShell = true;
    // The app's own fonts, which the tiles are measured with.
    await tester.runAsync(loadShotFonts);
    await pump(tester);
    final labels = {
      'ssh': 'SSH',
      'sftp': en.connectionEditProtocolSftpShort,
      'ftps': 'FTPS',
      'vnc': 'VNC',
      'rdp': 'RDP',
      'mosh': 'Mosh',
      'telnet': 'Telnet',
      'serial': en.connectionEditProtocolSerialShort,
      'localShell': en.connectionEditProtocolLocalShort,
    };
    final first = tester.getSize(tile('ssh'));
    expect(first.height, greaterThanOrEqualTo(48));
    for (final MapEntry(key: protocol, value: label) in labels.entries) {
      expect(tester.getSize(tile(protocol)), first, reason: '$protocol: every tile the same size');
      final words = find.descendant(of: tile(protocol), matching: find.text(label));
      expect(words, findsOneWidget, reason: protocol);
      // Drawn whole and at its size: no ellipsis, and not made smaller to fit.
      final paragraph = tester.renderObject<RenderParagraph>(words);
      expect(paragraph.didExceedMaxLines, isFalse, reason: protocol);
      expect(tester.getRect(words).width, moreOrLessEquals(paragraph.size.width, epsilon: 0.5), reason: protocol);
    }
    expect(find.text(en.connectionEditProtocolEtShort), findsNothing, reason: 'a phone has no Eternal Terminal client');
    // Nine tiles on a phone 390 wide (RDP among them since it is offered):
    // three rows of three, none left alone on a row.
    expect(tester.getTopLeft(tile('ftps')).dy, tester.getTopLeft(tile('ssh')).dy);
    expect(tester.getTopLeft(tile('vnc')).dy, greaterThan(tester.getTopLeft(tile('ssh')).dy));
    expect(tester.getTopLeft(tile('mosh')).dy, tester.getTopLeft(tile('vnc')).dy);
    expect(tester.getTopLeft(tile('telnet')).dy, greaterThan(tester.getTopLeft(tile('vnc')).dy));
    expect(tester.getTopLeft(tile('localShell')).dy, tester.getTopLeft(tile('telnet')).dy);

    // The chosen one has a check, and says it is chosen.
    Finder check(String protocol) => find.descendant(of: tile(protocol), matching: find.byIcon(LucideIcons.check));
    expect(check('ssh'), findsOneWidget);
    expect(check('telnet'), findsNothing);
    expect(tester.getSemantics(tile('ssh')), isSemantics(isSelected: true, isButton: true, label: 'SSH'));
    expect(tester.getSemantics(tile('sftp')),
        isSemantics(isSelected: false, label: 'SFTP only (files, no terminal)'),
        reason: 'a screen reader hears the whole name');

    await tester.tap(tile('telnet'));
    await settle(tester);
    expect(check('telnet'), findsOneWidget);
    expect(check('ssh'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '23'), findsOneWidget,
        reason: "Telnet's port");
    expect(keyed('host-form-sign-in'), findsNothing, reason: 'Telnet signs in with no key');
    await tester.pump(const Duration(seconds: 6));
    await unmount(tester);
  });

  testWidgets("each field's name above it: Address with Port beside it, Signs in with, and Nickname, said to be "
      'optional', (tester) async {
    await pump(tester);
    final address = find.text(en.zestHostFieldAddress);
    final port = find.text(en.zestHostFieldPort);
    final box = keyed('host-form-address');
    expect(tester.getBottomLeft(address).dy, lessThanOrEqualTo(tester.getTopLeft(box).dy));
    expect(tester.getTopLeft(address).dx, moreOrLessEquals(tester.getTopLeft(box).dx, epsilon: 16));
    expect(tester.getTopLeft(port).dx, greaterThan(tester.getTopRight(box).dx), reason: 'Port beside the address');
    expect((tester.getCenter(port).dy - tester.getCenter(address).dy).abs(), lessThan(2));
    expect(tester.getBottomLeft(find.text(en.hostFormSignsInWith)).dy,
        lessThanOrEqualTo(tester.getTopLeft(keyed('host-form-sign-in-key')).dy));
    final nickname = find.text(en.zestHostFieldNickname);
    expect(tester.getBottomLeft(nickname).dy, lessThanOrEqualTo(tester.getTopLeft(keyed('host-form-nickname')).dy));
    expect(find.text(en.hostFormOptional), findsOneWidget);
    expect(tester.getCenter(find.text(en.hostFormOptional)).dy, moreOrLessEquals(tester.getCenter(nickname).dy, epsilon: 2));
    // No old label column beside the values.
    expect(find.byKey(const ValueKey('zest-field-name-above')), findsNothing);
    await unmount(tester);
  });

  testWidgets('Save is off, with its reason over it, until the host has an address; then it is on', (tester) async {
    await pump(tester);
    expect(save(tester).onPressed, isNull);
    expect(find.text(en.hostFormAddAddressToSave), findsOneWidget);
    // The reason sits over the buttons, in the bar at the foot of the page.
    final bar = keyed('host-form-bar');
    expect(tester.getBottomLeft(bar).dy, 844);
    expect(tester.getBottomLeft(keyed('host-form-save-reason')).dy, lessThanOrEqualTo(tester.getTopLeft(keyed('host-form-save')).dy));
    await tester.enterText(keyed('host-form-address'), 'web-03.example.com');
    await settle(tester);
    expect(find.text(en.hostFormAddAddressToSave), findsNothing);
    expect(save(tester).onPressed, isNotNull);
    await tester.enterText(keyed('host-form-address'), '');
    await settle(tester);
    expect(save(tester).onPressed, isNull, reason: 'no address again');
    expect(find.text(en.hostFormAddAddressToSave), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('Signs in with: Key and Password each list their own; a password chosen in place of a key; with none, '
      'whom it signs in as', (tester) async {
    await pump(tester, connectionId: 'h-plain');
    // None chosen: the list asks for one, and says what happens without.
    expect(find.text(en.hostFormChooseKey), findsOneWidget);
    expect(find.text(en.hostFormSignsInAsDefault('root')), findsOneWidget);
    expect(tester.getSemantics(keyed('host-form-sign-in-key')), isSemantics(isSelected: true, isButton: true));
    Future<List<String>> listed() async {
      await tester.tap(keyed('host-form-identity'));
      await settle(tester);
      final names = [
        for (final e in find.byType(MenuItemButton).evaluate())
          ((e.widget as MenuItemButton).key as ValueKey?)?.value.toString() ?? '',
      ];
      // Closed with a tap beside it (on a field's name).
      await tester.tap(find.text(en.zestHostFieldProtocol));
      await settle(tester);
      return names;
    }

    expect(await listed(), ['zest-select-item-k-deploy', ''], reason: 'the keys, and Create new key');
    await tester.tap(keyed('host-form-sign-in-password'));
    await settle(tester);
    expect(find.text(en.hostFormChoosePassword), findsOneWidget);
    expect(await listed(), ['zest-select-item-k-admin', ''], reason: 'the passwords');
    expect(save(tester).onPressed, isNull, reason: 'looking at the passwords changes nothing');

    await tester.tap(keyed('host-form-identity'));
    await settle(tester);
    await tester.tap(keyed('zest-select-item-k-admin'));
    await settle(tester);
    expect(find.text('admin password (admin)'), findsOneWidget);
    expect(find.text(en.hostFormSignsInAsDefault('root')), findsNothing);
    expect(save(tester).onPressed, isNotNull);

    // Key again: the password is no longer chosen.
    await tester.tap(keyed('host-form-sign-in-key'));
    await settle(tester);
    expect(find.text(en.hostFormChooseKey), findsOneWidget);
    expect(find.text('admin password (admin)'), findsNothing);
    await unmount(tester);
  });

  testWidgets("the same form edits a saved host: its values in their fields, its key chosen, its note's More "
      'options open; a change saved', (tester) async {
    final router = await pump(tester, connectionId: 'h-web');
    expect(find.text(en.connectionEditTitle), findsOneWidget);
    expect(tester.widget<TextField>(find.descendant(of: keyed('host-form-nickname'), matching: find.byType(TextField))).controller!.text,
        'web-01');
    expect(tester.widget<TextField>(find.descendant(of: keyed('host-form-address'), matching: find.byType(TextField))).controller!.text,
        '192.168.10.21');
    expect(find.text('deploy key (deploy)'), findsOneWidget);
    expect(tester.getSemantics(keyed('host-form-sign-in-key')), isSemantics(isSelected: true));
    // A note is set: More options is open, so nothing set is hidden.
    expect(keyed('host-form-more-open'), findsOneWidget);
    expect(keyed('host-form-note'), findsOneWidget);
    // Nothing changed yet: Save is off, and nothing needs saying.
    expect(save(tester).onPressed, isNull);
    expect(keyed('host-form-save-reason'), findsNothing);
    expect(find.text(en.connectionSaveChanges), findsOneWidget);

    await tester.enterText(keyed('host-form-nickname'), 'web-01-new');
    await settle(tester);
    await tester.tap(keyed('host-form-save'));
    await settle(tester);
    final saved = (await db.connectionsDao.getById('h-web'))!;
    expect(saved.label, 'web-01-new');
    expect(saved.identityId, 'k-deploy');
    expect(saved.note, 'Behind the office VPN.');
    expect(router.routerDelegate.currentConfiguration.uri.path, '/', reason: 'the form closes once saved');
    await tester.pump(const Duration(seconds: 6));
    await unmount(tester);
  });

  testWidgets('More options and the advanced options open from rows of their own; a new host opens with them '
      'folded', (tester) async {
    await pump(tester);
    await tester.scrollUntilVisible(keyed('host-form-more'), 200, scrollable: find.byType(Scrollable).first);
    expect(keyed('host-form-more-open'), findsNothing);
    expect(find.text(en.zestHostFieldColor), findsNothing);
    expect(find.text(en.hostFormMoreOptionsSub), findsOneWidget);
    expect(tester.getSemantics(keyed('host-form-more')), isSemantics(isButton: true, isExpanded: false));
    await tester.ensureVisible(keyed('host-form-more'));
    await tester.pump();
    await tester.tap(keyed('host-form-more'));
    await settle(tester);
    expect(find.text(en.zestHostFieldColor), findsOneWidget);
    expect(find.text(en.hostIconLabel), findsOneWidget);
    expect(find.text(en.zestHostFieldTags), findsOneWidget);
    expect(find.text(en.zestHostFieldNote), findsOneWidget);
    // The icon's Auto with when it is set, as before.
    expect(find.text(en.phoneUiFormIconAuto), findsOneWidget);
    expect(find.text(en.phoneUiFormIconAutoPending), findsOneWidget);
    // The note has no grip on a phone.
    expect(find.byKey(const ValueKey('zest-field-grip')), findsNothing);
    expect(tester.getSemantics(keyed('host-form-more')), isSemantics(isExpanded: true));

    final advanced = keyed('host-form-advanced');
    await tester.ensureVisible(advanced);
    await tester.pump();
    await tester.tap(advanced);
    await settle(tester);
    expect(keyed('host-form-advanced-open'), findsOneWidget);
    expect(find.text(en.connectionStartupCommand, skipOffstage: false), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('Test offers the two tests by name in a menu (the unnamed swap button is gone); Save stands beside it, '
      'one Save on the page', (tester) async {
    await pump(tester, connectionId: 'h-web');
    expect(find.descendant(of: find.byType(AppBar), matching: find.byTooltip(en.save)), findsNothing);
    expect(keyed('host-form-save'), findsOneWidget);
    expect(keyed('host-form-test-swap'), findsNothing);
    final test = keyed('host-form-test');
    expect(tester.getSize(test).height, greaterThanOrEqualTo(48));
    expect(tester.getTopLeft(keyed('host-form-save')).dx, greaterThan(tester.getTopRight(test).dx));
    expect(tester.getTopLeft(keyed('host-form-save')).dy, moreOrLessEquals(tester.getTopLeft(test).dy, epsilon: 1));
    expect(find.text(en.zestHostTestReachability), findsNothing);
    await tester.tap(test);
    await settle(tester);
    expect(keyed('host-form-test-reachability'), findsOneWidget);
    expect(keyed('host-form-test-full'), findsOneWidget);
    expect(find.text(en.zestHostTestReachability), findsOneWidget);
    expect(find.text(en.zestHostTestFull), findsOneWidget);
    expect(tester.getSize(keyed('host-form-test-full')).height, greaterThanOrEqualTo(48));
    await unmount(tester);
  });

  testWidgets('on a computer the Note keeps its grip', (tester) async {
    await pump(tester, size: const Size(1300, 900));
    await tester.ensureVisible(find.text(en.zestHostFieldNote));
    await tester.pump();
    expect(find.byKey(const ValueKey('zest-field-grip')), findsOneWidget);
    await unmount(tester);
  });
}
