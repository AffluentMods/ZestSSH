import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/locale_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/port_forward/port_forward_screen.dart';
import 'package:zestssh/ui/screens/settings/data_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_toolbar.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../helpers/phone_screen_harness.dart';

/// Four of the six fixes from a check on a small phone (393 by 807):
/// the terminal's bar names the host as its tabs do, SFTP's
/// footer keeps above the gesture bar, the Web preset of a port forward has
/// a browser's window (it had a translate icon), and the Language and Auto
/// backup sheets mark the one picked with the dot radio a pick-one choice
/// has (they had a check). (Settings' search and the More tab on a tablet
/// are in phone_settings_search_test.dart and tablet_page_column_test.dart.)
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  const pixel = Size(393, 807);

  /// Runs [body] drawn as a phone's ([touch]) or a computer's.
  void drawn(String name, Future<void> Function(WidgetTester tester) body, {bool touch = true}) {
    testWidgets(name, (tester) async {
      debugTouchLayout = touch;
      debugDefaultTargetPlatformOverride = touch ? TargetPlatform.android : TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  group("the terminal's bar", () {
    Future<void> pumpBar(WidgetTester tester, {required String label, String? title}) async {
      tester.view.physicalSize = const Size(393, 120);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: TerminalToolbar(
            sessionId: 's1',
            status: SessionStatus.connected,
            connectionLabel: label,
            host: '192.168.10.21',
            port: 22,
            // What the shell calls its terminal, which a computer's bar shows.
            terminalTitle: title,
            onDisconnect: () {},
            onBack: () {},
          ),
        ),
      ));
      await tester.pump();
    }

    drawn('on a phone names the host by its name, as its session tab does, not by its address', (tester) async {
      await pumpBar(tester, label: 'web-01', title: 'deploy@web-01:~');
      expect(find.text('web-01'), findsOneWidget);
      expect(find.text('192.168.10.21'), findsNothing, reason: 'it said the address while the tabs said the name');
      expect(find.text('deploy@web-01:~'), findsNothing, reason: "a phone's bar names the host");
    });

    drawn('on a phone, a host with no name: its address, as its tab falls back to', (tester) async {
      await pumpBar(tester, label: '', title: 'deploy@web-01:~');
      expect(find.text('192.168.10.21'), findsOneWidget);
    });

    drawn("a computer's bar keeps what the shell calls the terminal", (tester) async {
      await pumpBar(tester, label: 'web-01', title: 'deploy@web-01:~');
      expect(find.text('deploy@web-01:~'), findsOneWidget);
    }, touch: false);
  });

  group("SFTP's footer on a phone", () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    /// The phone's SFTP browser at a Pixel 3a's size, with a navigation bar
    /// [bottom] high under it (the screen's padding, as Android gives an app
    /// drawn edge to edge).
    Future<void> open(WidgetTester tester, {required double bottom}) async {
      tester.view.physicalSize = pixel;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(top: 24, bottom: bottom);
      tester.view.viewPadding = FakeViewPadding(top: 24, bottom: bottom);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: SftpBrowserScreen(sftp: _Sftp(), connectionLabel: 'web-01'),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    final words = find.text('${en.sftpFolderCount(1)}, ${en.sftpFileCount(1)}');

    drawn('its words above the gesture bar, its colour down to the edge under it', (tester) async {
      await open(tester, bottom: 48);
      expect(words, findsOneWidget);
      expect(tester.getRect(words).bottom, lessThanOrEqualTo(pixel.height - 48),
          reason: 'the folder and file count sat under the gesture bar');
      final footer = find.ancestor(of: words, matching: find.byType(Container)).first;
      expect(tester.getRect(footer).bottom, pixel.height, reason: 'its colour runs under the bar, as the tab bar\'s');
      await tester.pumpWidget(const SizedBox());
    });

    drawn('with no bar under it, where it was', (tester) async {
      await open(tester, bottom: 0);
      expect(tester.getRect(words).bottom, pixel.height - 8);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group("a port forward's Web preset", () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    /// The Web chip's icon, and SOCKS's beside it.
    (IconData?, IconData?) icons(WidgetTester tester, String web, String socks) {
      IconData? of(String words) => (tester.widget<ActionChip>(find.widgetWithText(ActionChip, words)).avatar as Icon?)?.icon;
      return (of(web), of(socks));
    }

    for (final touch in [true, false]) {
      drawn('a browser\'s window, not a translate icon or SOCKS\'s globe (${touch ? 'a phone\'s page' : 'a computer\'s dialog'})',
          (tester) async {
        tester.view.physicalSize = touch ? pixel : const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            recordingModeProvider.overrideWith((ref) => false),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(onPressed: () => showPortForwardEditor(context), child: const Text('open')),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final (web, socks) = icons(tester, en.portForwardWeb, en.portForwardSocks);
        expect(web, LucideIcons.appWindow);
        expect(web, isNot(LucideIcons.languages));
        expect(web, isNot(socks));
        await tester.pumpWidget(const SizedBox());
      }, touch: touch);
    }

    testWidgets("the same in a host's editor, Add port forward", (tester) async {
      await PhoneScreenHarness.pump(tester, const ConnectionEditScreen(connectionId: 'c1'), size: const Size(900, 1600));
      final page = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;
      // Port forwarding is among the advanced options.
      final advanced = find.text(en.connectionEditShowAdvanced);
      await tester.scrollUntilVisible(advanced, 300, scrollable: page);
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      final add = find.text(en.connectionAddPortForward);
      await tester.scrollUntilVisible(add, 300, scrollable: page);
      await tester.pump();
      await tester.tap(add);
      await tester.pumpAndSettle();
      final (web, socks) = icons(tester, en.connectionEditPfWeb, en.connectionEditPfSocks);
      expect(web, LucideIcons.appWindow);
      expect(web, isNot(socks));
      await PhoneScreenHarness.takeDown(tester);
    });
  });

  group("a phone's Settings: a pick-one sheet's dot radios", () {
    /// The phone's Settings at a Pixel 3a's width (tall enough that each
    /// sheet's every row is built).
    Future<ProviderContainer> pumpSettings(WidgetTester tester,
        {Map<String, Object> prefs = const {}, Widget home = const Scaffold(body: SettingsBody(bottomPadding: 16))}) async {
      tester.view.physicalSize = const Size(393, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
      FlutterSecureStorage.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      SharedPreferences.setMockInitialValues(prefs);
      final shared = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(shared),
        recordingModeProvider.overrideWith((ref) => false),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      ]);
      addTearDown(container.dispose);
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (context, state) => home),
        GoRoute(path: '/:rest(.*)', builder: (context, state) => Scaffold(body: Text('page ${state.uri}'))),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: BuiltInThemes.getById('default_dark').toThemeData(),
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      return container;
    }

    Future<void> takeDown(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 10));
    }

    final sheet = find.byKey(const ValueKey('zest-sheet'));
    Finder radioOf(String key) =>
        find.descendant(of: find.byKey(ValueKey(key)), matching: find.byWidgetPredicate((w) => w is Radio));

    /// Whether the row [key]'s radio says it is the one picked.
    void picked(WidgetTester tester, String key, bool yes) => expect(
        tester.getSemantics(radioOf(key)), isSemantics(isChecked: yes, isInMutuallyExclusiveGroup: true),
        reason: key);

    /// The dialogs' dot radio: 20 square at the row's leading edge, 10 before its words.
    void dialogsRadio(WidgetTester tester, String key) {
      final box = find.ancestor(of: radioOf(key), matching: find.byType(SizedBox)).first;
      expect(tester.getSize(box), const Size(20, 20), reason: key);
      final row = tester.getRect(find.byKey(ValueKey(key)));
      expect(tester.getRect(box).left, row.left + 14, reason: key);
      final words = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)).first;
      expect(tester.getRect(words).left - tester.getRect(box).right, 10, reason: key);
    }

    drawn('Language: a dot radio on every language, the one in use filled, no check; a tap on its words picks it',
        (tester) async {
      final container = await pumpSettings(tester);
      await tester.tap(find.byKey(const ValueKey('settings-language')));
      await tester.pumpAndSettle();
      expect(sheet, findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.byWidgetPredicate((w) => w is Radio<String?>)),
          findsNWidgets(AppLocalizations.supportedLocales.length + 1));
      expect(find.descendant(of: sheet, matching: find.byIcon(LucideIcons.check)), findsNothing,
          reason: 'a check is for where several can be picked');
      final semantics = tester.ensureSemantics();
      picked(tester, 'language-system', true);
      picked(tester, 'language-de', false);
      dialogsRadio(tester, 'language-de');

      // The whole row picks it: a tap on its words, not on the dot.
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('language-de')), matching: find.byType(Text)));
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
      expect(container.read(appLocaleProvider), const Locale('de'));

      await tester.tap(find.byKey(const ValueKey('settings-language')));
      await tester.pumpAndSettle();
      picked(tester, 'language-de', true);
      picked(tester, 'language-system', false);
      semantics.dispose();
      await takeDown(tester);
    });

    drawn("Auto backup: the schedule's three each a dot radio, the one set filled, no check; a tap on its words "
        'sets it', (tester) async {
      // The Backups row is the Backups and data page's (4.0).
      final container =
          await pumpSettings(tester, prefs: {'auto_backup_interval': 'daily'}, home: const DataSettingsScreen());
      await tester.tap(find.byKey(const ValueKey('settings-backups')));
      await tester.pumpAndSettle();
      expect(sheet, findsOneWidget);
      for (final key in ['off', 'daily', 'weekly']) {
        expect(radioOf('backup-schedule-$key'), findsOneWidget, reason: key);
      }
      expect(find.descendant(of: sheet, matching: find.byIcon(LucideIcons.check)), findsNothing);
      final semantics = tester.ensureSemantics();
      picked(tester, 'backup-schedule-daily', true);
      picked(tester, 'backup-schedule-off', false);
      dialogsRadio(tester, 'backup-schedule-off');

      // Off needs no password: the sheet stays, its dot moves.
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('backup-schedule-off')), matching: find.byType(Text)));
      await tester.pumpAndSettle();
      expect(container.read(autoBackupIntervalProvider), 'off');
      picked(tester, 'backup-schedule-off', true);
      picked(tester, 'backup-schedule-daily', false);
      semantics.dispose();
      await takeDown(tester);
    });
  });
}

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no team here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

/// A home folder with one folder and one file in it (made up).
class _Sftp implements SftpService {
  @override
  Future<String> getHomeDirectory() async => '/home/demo';

  @override
  Future<List<SftpEntry>> listDirectory(String path) async => path == '/home/demo'
      ? const [
          SftpEntry(name: 'logs', path: '/home/demo/logs', isDirectory: true, size: 0),
          SftpEntry(name: 'notes.txt', path: '/home/demo/notes.txt', isDirectory: false, size: 5),
        ]
      : const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
