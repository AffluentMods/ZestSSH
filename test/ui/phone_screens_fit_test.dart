import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/help/ios_backgrounding_help_screen.dart';
import 'package:zestssh/ui/screens/identity/key_generation_screen.dart';
import 'package:zestssh/ui/screens/import/ssh_config_import_screen.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/purchase/upgrade_screen.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';

import '../helpers/words_cut.dart';
import '../visual/shots_util.dart';

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

final _en = lookupAppLocalizations(const Locale('en'));
final _de = lookupAppLocalizations(const Locale('de'));

/// More of a phone's screens at the text sizes a phone can be set to, in
/// every language, on a phone 360 wide and on one 600 wide (3.0, 17 October
/// 2026), as phone_settings_fit_test.dart holds the settings pages: at the
/// size the app is drawn at and at 1.3 times, no line breaks inside a word
/// and no name is cut at its box's edge; at every size, no words are cut at
/// their top and bottom and nothing runs over. On
/// a phone 360 wide, at the size the app is drawn at, the host editor's Test
/// button cut its own words ("Test reac|hability") and its field names were
/// cut in their 88 pixels ("Soprannome", "Идентификатор"), and more at 1.3
/// times; key generation cut "Compatibility" at 1.3 times and its choice ran
/// out of its field in Russian; the profile's rows broke a long word beside
/// their button ("Wiederherstellungsschlüssel"); the iOS backgrounding help
/// and the SSH config import ran out of the page beside an icon; and the
/// Monitor tab's title read "Server Moni…". The host editor's advanced
/// settings too: in their column, "Широковещательный адрес" was cut at the
/// size the app is drawn at, a name that needed three lines lost the third, values beside
/// it lost words at 1.3 times ("predeterminado"), a network's overrides cut
/// "Benutzername" and "Basiskonfiguration", the upgrade button left "Connect
/// via (optional)" 91 pixels, and at twice the size a section's heading ran
/// off its row. Every word on these pages is in a font of the app (a
/// dropdown's value was in the system's). And the phone's Upgrade page
/// (a test draws a computer's otherwise), whose price line ran out of its
/// card from 1.3 times the text size. A dropdown's value of two lines in a
/// field a line tall lost its second (in Russian, "Use global default" at the
/// size the app is drawn at; "Ed25519 (Recommended)" from 1.3 times), and so
/// did the words of a button in a box of a fixed height (key generation's,
/// and the Upgrade page's from 1.3 times).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tearDown(() {
    ConnectionEditScreen.debugDesktopShell = null;
    UpgradeScreen.debugDesktop = null;
  });

  final pages = <String, (Widget Function(), Future<void> Function(WidgetTester)?)>{
    'the host editor (a new host)': (() => const ConnectionEditScreen(), null),
    'the host editor (a saved host)': (() => const ConnectionEditScreen(connectionId: 'c1'), null),
    "the host editor's advanced settings": (() => const ConnectionEditScreen(connectionId: 'c1'), _showAdvanced),
    'key generation': (() => const KeyGenerationScreen(), null),
    'the profile': (() => const ProfileScreen(), null),
    'the iOS backgrounding help': (() => const IosBackgroundingHelpScreen(), null),
    'the SSH config import': (() => const SshConfigImportScreen(), null),
    'the Monitor': (() => const ServerMonitorScreen(), null),
    "the phone's Upgrade page": (() => const UpgradeScreen(), null),
  };

  for (final MapEntry(key: name, value: (page, prepare)) in pages.entries) {
    for (final width in const [360.0, 600.0]) {
      for (final scale in const [1.0, 1.3, 1.5, 2.0]) {
        final words = scale <= 1.3;
        testWidgets('$name, ${width.toInt()} wide, at $scale times the text size, in every language: '
            '${words ? "no word cut in two or at its edge, every word in a font of the app, " : ''}'
            'no words cut at their top and bottom, nothing runs over',
            (tester) async {
          final problems = <String>[];
          for (final locale in AppLocalizations.supportedLocales) {
            await _pump(tester, page(),
                width: width, scale: scale, locale: locale, problems: problems, words: words, prepare: prepare);
          }
          expect(problems, isEmpty);
        });
      }
    }
  }

  group('what changed', () {
    testWidgets("the host editor's Test stands beside Save in the bar at its foot, on a phone and in a window 700 "
        'wide, each with its words (4.0: Test offers the two tests in a menu)', (tester) async {
      for (final width in [360.0, 700.0]) {
        await _pump(tester, const ConnectionEditScreen(), width: width);
        final test = find.byKey(const ValueKey('host-form-test'));
        final save = find.byKey(const ValueKey('host-form-save'));
        expect(find.descendant(of: test, matching: find.text(_en.hostFormTest)), findsOneWidget);
        expect(find.descendant(of: save, matching: find.text(_en.connectionSaveConnection)), findsOneWidget);
        expect(tester.getTopLeft(save).dx, greaterThan(tester.getTopRight(test).dx), reason: '${width.toInt()} wide');
        expect(tester.getTopLeft(save).dy, closeTo(tester.getTopLeft(test).dy, 1));
        expect(tester.getBottomLeft(find.byKey(const ValueKey('host-form-bar'))).dy, 2400, reason: 'at the foot');
        await _unmount(tester);
      }
    });

    testWidgets("the host editor's field names on a tablet: one column, as wide as its longest name (a phone's "
        'stand above their fields)', (tester) async {
      await _pump(tester, const ConnectionEditScreen(), locale: const Locale('ru'), width: 900);
      final ru = lookupAppLocalizations(const Locale('ru'));
      double cell(String label) =>
          tester.getSize(find.ancestor(of: find.text(label), matching: find.byType(SizedBox)).first).width;
      final identity = cell(ru.zestHostFieldIdentity);
      expect(identity, greaterThan(88), reason: '"Идентификатор" did not fit 88');
      expect(cell(ru.zestHostFieldNickname), identity);
      expect(cell(ru.zestHostFieldAddress), identity);
      await _unmount(tester);
    });

    testWidgets("the advanced settings' names above their values on a phone in Russian, where one did not hold in "
        'their column; beside them in English', (tester) async {
      for (final (locale, above) in [(const Locale('ru'), true), (const Locale('en'), false)]) {
        await _pump(tester, const ConnectionEditScreen(connectionId: 'c1'), locale: locale, prepare: _showAdvanced);
        final l10n = lookupAppLocalizations(locale);
        final name = find.text(l10n.connectionBroadcastAddress);
        expect(name, findsOneWidget);
        expect(find.ancestor(of: name, matching: find.byKey(const ValueKey('zest-field-name-above'))).evaluate().isNotEmpty,
            above, reason: '$locale');
        await _unmount(tester);
      }
    });

    testWidgets("the Monitor's title on a phone is its tab's name; on a wide page its own", (tester) async {
      await _pump(tester, const ServerMonitorScreen());
      expect(find.descendant(of: find.byType(AppBar), matching: find.text(_en.phoneTabMonitor)), findsOneWidget);
      await _unmount(tester);
      await _pump(tester, const ServerMonitorScreen(), width: 900);
      expect(find.descendant(of: find.byType(AppBar), matching: find.text(_en.monitorTitle)), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets("a profile row's button under its words on a phone in German, beside them on a wide page", (tester) async {
      for (final (width, beside) in [(360.0, false), (900.0, true)]) {
        await _pump(tester, const ProfileScreen(), width: width, locale: const Locale('de'));
        final row = find.ancestor(of: find.text(_de.accountSyncHelpOff), matching: find.byType(BesideOrUnder));
        expect(row, findsOneWidget);
        expect(tester.renderObject<RenderBesideOrUnder>(row).controlBeside, beside, reason: '${width.toInt()} wide');
        await _unmount(tester);
      }
    });
  });
}

/// The host editor with its Network, Automation and Wake-on-LAN sections
/// shown, as its Advanced options row shows them on a phone.
Future<void> _showAdvanced(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('host-form-advanced'));
  await tester.ensureVisible(row);
  await tester.pump();
  await tester.tap(row);
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(find.byKey(const ValueKey('host-form-advanced-open')), findsOneWidget);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 10));
}

/// [screen] drawn on a phone [width] wide at [scale] times the text size in
/// [locale], in the app's own theme and fonts, over a database with one host.
/// With [problems], each layout that runs over, each paragraph cut at its
/// top and bottom, and each word cut in two and each name cut at its box's
/// edge where [words], is added to it, and the screen is taken down again.
Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  double width = 360,
  double scale = 1.0,
  Locale locale = const Locale('en'),
  List<String>? problems,
  bool words = false,
  Future<void> Function(WidgetTester tester)? prepare,
}) async {
  ConnectionEditScreen.debugDesktopShell = false;
  UpgradeScreen.debugDesktop = false;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(onListen: (arguments, events) {}));
  await tester.runAsync(loadShotFonts);
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final theme = BuiltInThemes.getById('default_dark');
  AppColors.applyTheme(theme.colorScheme);
  FlutterSecureStorage.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final now = DateTime(2026, 10, 17);
  await tester.runAsync(() => db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'c1',
        label: 'web-01',
        host: '192.168.10.21',
        port: const Value(22),
        createdAt: now,
        updatedAt: now,
      )));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    recordingModeProvider.overrideWith((ref) => false),
    databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
    databaseProvider.overrideWithValue(db),
    treeDatabaseProvider.overrideWithValue(db),
    orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
    syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 17, 12))),
  ]);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (context, state) => screen),
    GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text(state.uri.toString()))),
  ]);
  final found = <String>[];
  final reported = FlutterError.onError;
  if (problems != null) {
    FlutterError.onError = (details) => found.add(details.exceptionAsString().split(String.fromCharCode(10)).first);
  }
  try {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: theme.toThemeData(),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await prepare?.call(tester);
    if (problems != null) {
      for (final e in find.byType(RichText).evaluate()) {
        final paragraph = e.renderObject;
        if (paragraph is! RenderParagraph) continue;
        final cut = cutTopAndBottom(paragraph);
        if (cut != null) found.add('cut at its top and bottom: $cut');
      }
    }
    if (problems != null && words) {
      for (final e in find.byType(RichText).evaluate()) {
        final paragraph = e.renderObject;
        if (paragraph is! RenderParagraph || !paragraph.hasSize) continue;
        found.addAll(wordsCut(paragraph).map((cut) => 'a word cut in two: $cut'));
        final clipped = _clipped(paragraph);
        if (clipped != null) found.add('cut at its edge: $clipped');
        if (paragraph.text.style?.fontFamily == null) {
          found.add('in no font of the app: "${paragraph.text.toPlainText(includeSemanticsLabels: false)}"');
        }
      }
    }
  } finally {
    FlutterError.onError = reported;
  }
  if (problems != null) {
    problems.addAll(found.map((p) => '$locale: $p'));
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    router.dispose();
    await tester.pump(const Duration(minutes: 10));
  } else {
    addTearDown(container.dispose);
    addTearDown(router.dispose);
  }
}

/// The words of a one-line paragraph cut at its box's edge with nothing to
/// say so (an ellipsis or a fade does), or null.
String? _clipped(RenderParagraph paragraph) {
  if (paragraph.maxLines != 1 && paragraph.softWrap) return null;
  if (paragraph.overflow == TextOverflow.ellipsis || paragraph.overflow == TextOverflow.fade) return null;
  if (paragraph.constraints.maxWidth < 1) return null;
  final full = paragraph.getMaxIntrinsicWidth(double.infinity);
  if (full <= paragraph.size.width + 0.5) return null;
  return '"${paragraph.text.toPlainText(includeSemanticsLabels: false)}" in ${paragraph.size.width.toStringAsFixed(0)}';
}
