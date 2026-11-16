import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart' show HostFileKind;
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart';
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';

import '../../visual/shots_util.dart' show loadShotFonts;

/// The first step of Import hosts as the 4.0 design draws it:
/// a zone at the top where a file
/// is dropped or chosen, "From another app" and "From the cloud" as grids of
/// tiles (three to a row at the dialog's width, fewer where it is narrower,
/// one on a phone), each app's monogram in its own colour and each file
/// format with a plain icon, the two ways to paste as quiet rows under them,
/// and "Need to import something else? Let us know" beside Cancel. The same
/// sources, names and descriptions as before.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late ImportHostsResult? result;
  late int picked;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    result = null;
    picked = 0;
  });

  tearDown(() => db.close());

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1400, 1100),
    Locale locale = const Locale('en'),
    List<Override> more = const [],
  }) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        ...more,
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showZestModal<ImportHostsResult>(
                  context: context,
                  size: ZestModalSize.large,
                  child: ImportHostsDialog(
                    readClipboard: () async => null,
                    pickFile: () async {
                      picked++;
                      return null;
                    },
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder k(String key) => find.byKey(ValueKey(key));
  const apps = [
    'ssh-config', 'putty', 'mobaxterm', 'securecrt', 'filezilla', 'winscp', 'mremoteng', 'remmina', 'termius', //
    'csv', 'zest',
  ];

  /// The tile of an app ([apps]; PuTTY's as this platform has it).
  Finder app(String name) =>
      name == 'putty' ? find.byWidgetPredicate((w) => w.key == const ValueKey('file-source-putty') || w.key == const ValueKey('file-source-putty-file')) : k('file-source-$name');

  testWidgets('a Remote Desktop file is a source only where this build offers RDP hosts', (tester) async {
    await open(tester, more: [rdpOfferedProvider.overrideWithValue(false)]);
    expect(k('file-source-rdp-file'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await open(tester, more: [rdpOfferedProvider.overrideWithValue(true)]);
    expect(k('file-source-rdp-file'), findsOneWidget);
    expect(find.descendant(of: k('file-source-rdp-file'), matching: find.text(l10n.migrateRdpFileTitle)), findsOneWidget);
    expect(find.byType(ImportSourceCard), findsNWidgets(apps.length + 1 + CloudProvider.values.length));
    // Chosen: the import of a host file opens for it.
    await tester.ensureVisible(k('file-source-rdp-file'));
    await tester.tap(k('file-source-rdp-file'));
    await tester.pumpAndSettle();
    expect(result, isA<ImportFromCsv>().having((r) => r.kind, 'kind', HostFileKind.rdpfile));
  });

  testWidgets('on a computer: the drop zone first, then the apps and the clouds three to a row, the pastes under them, Let us know beside Cancel',
      (tester) async {
    await open(tester);
    // (RDP is offered: the Remote Desktop file is a card of its own.)
    expect(find.byType(ImportSourceCard), findsNWidgets(apps.length + 1 + CloudProvider.values.length));
    // The drop zone at the top, with what ZestSSH does and Choose a file.
    final drop = tester.getRect(k('import-drop'));
    expect(find.text(l10n.importDropTitle), findsOneWidget);
    expect(find.text(l10n.importDropDesc), findsOneWidget);
    expect(find.descendant(of: k('import-drop'), matching: k('import-file')), findsOneWidget);
    // Three to a row, all as wide, each at least 48 tall.
    final lefts = <double>{};
    final widths = <double>{};
    for (final e in find.byType(ImportSourceCard).evaluate()) {
      final box = e.renderObject! as RenderBox;
      final at = box.localToGlobal(Offset.zero);
      expect(at.dy, greaterThan(drop.bottom));
      expect(box.size.height, greaterThanOrEqualTo(48));
      lefts.add(at.dx.roundToDouble());
      widths.add(box.size.width.roundToDouble());
    }
    expect(lefts, hasLength(3), reason: 'three columns');
    expect(widths, hasLength(1), reason: 'one width');
    // A row's tiles stand level and as tall as each other.
    expect(tester.getRect(app('ssh-config')).top, tester.getRect(app('mobaxterm')).top);
    expect(tester.getRect(app('ssh-config')).height, tester.getRect(app('mobaxterm')).height);
    // From another app over From the cloud, the clouds after the apps.
    final appsHead = tester.getRect(find.text(l10n.migrateFromApps.toUpperCase()));
    final cloudHead = tester.getRect(find.text(l10n.importFromCloud.toUpperCase()));
    expect(appsHead.top, lessThan(tester.getRect(app('ssh-config')).top));
    expect(cloudHead.top, greaterThan(tester.getRect(app('zest')).bottom));
    expect(tester.getRect(k('cloud-source-aws')).top, greaterThan(cloudHead.top));
    // The pastes are quiet rows under the clouds, side by side, at least 48 tall.
    final paste = tester.getRect(k('file-source-paste'));
    final link = tester.getRect(k('file-source-share-link'));
    expect(paste.top, greaterThan(tester.getRect(k('cloud-source-proxmox')).bottom));
    expect(paste.top, link.top);
    expect(paste.height, greaterThanOrEqualTo(48));
    expect(find.descendant(of: k('file-source-paste'), matching: find.byType(ImportSourceCard)), findsNothing);
    // Let us know, beside Cancel in the footer.
    final ask = tester.getRect(k('import-ask-source'));
    final cancel = tester.getRect(find.text(l10n.cancel));
    expect(ask.top, greaterThan(paste.bottom));
    expect((ask.center.dy - cancel.center.dy).abs(), lessThan(14));
    expect(ask.right, lessThan(cancel.left));
    expect(tester.takeException(), isNull);
  });

  testWidgets('each app has its own colour; a file format a plain icon; the names and descriptions are as before', (tester) async {
    await open(tester);
    Color? ink(String mark) => tester.widget<Text>(find.text(mark)).style?.color;
    // PuTTY, AWS and Azure looked alike: one grey each.
    expect({ink('PT'), ink('AWS'), ink('AZ')}, hasLength(3));
    expect({for (final m in ['PT', 'MX', 'CRT', 'FZ', 'WS', 'TM']) ink(m)}, hasLength(6), reason: 'no two apps alike');
    expect(importMarkHue('PT'), isNotNull);
    expect(importMarkHue('TS'), isNull, reason: "Tailscale's mark stays grey");
    for (final format in ['ssh-config', 'csv', 'zest']) {
      expect(find.descendant(of: app(format), matching: find.byType(Icon)), findsOneWidget, reason: format);
    }
    for (final (key, name, desc) in [
      ('file-source-ssh-config', l10n.cloudImpSshConfig, l10n.cloudImpSshConfigDesc),
      ('file-source-mobaxterm', 'MobaXterm', l10n.migrateMobaDesc),
      ('file-source-securecrt', 'SecureCRT', l10n.importSecureCrtDesc),
      ('file-source-filezilla', 'FileZilla', l10n.migrateFileZillaDesc),
      ('file-source-winscp', 'WinSCP', l10n.migrateWinScpDesc),
      ('file-source-termius', 'Termius', l10n.importTermiusDesc),
      ('file-source-csv', l10n.cloudImpCsv, l10n.cloudImpCsvDesc),
      ('file-source-zest', l10n.cloudImpZest, l10n.cloudImpZestDesc),
      ('file-source-paste', l10n.importPasteTitle, l10n.importPasteDesc),
      ('file-source-share-link', l10n.shareLinkPasteTitle, l10n.shareLinkPasteDesc),
      ('cloud-source-aws', 'AWS EC2', l10n.cloudImpAwsDesc),
      ('cloud-source-proxmox', 'Proxmox VE', l10n.cloudImpProxmoxDesc),
    ]) {
      expect(find.descendant(of: k(key), matching: find.text(name)), findsOneWidget, reason: key);
      expect(find.descendant(of: k(key), matching: find.text(desc)), findsOneWidget, reason: key);
    }
  });

  testWidgets('Choose a file asks for one; a tile and a paste row go on as before; the keyboard reaches the tiles', (tester) async {
    await open(tester);
    await tester.tap(k('import-file'));
    await tester.pumpAndSettle();
    expect(picked, 1);
    // The tiles take the keyboard: Tab reaches one, and Enter opens it.
    var tabs = 0;
    while (tabs < 30 && Focus.of(tester.element(find.text(l10n.cloudImpSshConfig))).hasFocus == false) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      tabs++;
    }
    expect(Focus.of(tester.element(find.text(l10n.cloudImpSshConfig))).hasFocus, isTrue, reason: 'Tab reaches the first tile');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result, isA<ImportFromSshConfig>());
    await open(tester);
    await tester.ensureVisible(k('file-source-paste'));
    await tester.pumpAndSettle();
    await tester.tap(k('file-source-paste'));
    await tester.pumpAndSettle();
    expect(result, isA<ImportFromCsv>());
  });

  testWidgets('a screen reader hears each tile and paste row as a button with its name and what it takes', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    for (final (key, name, desc) in [
      ('cloud-source-aws', 'AWS EC2', l10n.cloudImpAwsDesc),
      ('file-source-share-link', l10n.shareLinkPasteTitle, l10n.shareLinkPasteDesc),
    ]) {
      final node = tester.getSemantics(find.descendant(of: k(key), matching: find.text(name)));
      expect(node, isSemantics(isButton: true, hasTapAction: true));
      expect(node.label, allOf(contains(name), contains(desc)));
    }
    semantics.dispose();
  });

  testWidgets('a narrower window: two to a row; the drop zone keeps its button', (tester) async {
    await open(tester, size: const Size(760, 1000));
    final lefts = {for (final e in find.byType(ImportSourceCard).evaluate()) (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dx.round()};
    expect(lefts, hasLength(2));
    expect(find.descendant(of: k('import-drop'), matching: k('import-file')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone: one to a row, Import a file with its button 48 high, the pastes stacked, Let us know at the end', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await open(tester, size: const Size(390, 844));
      // Nothing is dropped on a phone: Import a file, and what it does.
      expect(find.text(l10n.importFileAction), findsOneWidget);
      expect(find.text(l10n.importDropTitle), findsNothing);
      final lefts = {for (final e in find.byType(ImportSourceCard).evaluate()) (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dx.round()};
      expect(lefts, hasLength(1));
      final choose = tester.getRect(k('import-file'));
      expect(choose.height, greaterThanOrEqualTo(48));
      expect(choose.width, greaterThan(tester.getRect(k('import-drop')).width * 0.8), reason: 'across the zone');
      await tester.ensureVisible(k('file-source-share-link'));
      await tester.pumpAndSettle();
      expect(tester.getRect(k('file-source-share-link')).top, greaterThan(tester.getRect(k('file-source-paste')).bottom - 1));
      await tester.ensureVisible(k('import-ask-source'));
      await tester.pumpAndSettle();
      expect(tester.getRect(k('import-ask-source')).top, greaterThan(tester.getRect(k('file-source-share-link')).bottom));
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('in $locale nothing overflows, on a computer and on a phone', (tester) async {
      await open(tester, locale: locale);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await open(tester, locale: locale, size: const Size(360, 760));
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
