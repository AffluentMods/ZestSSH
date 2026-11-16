import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/about_screen.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';
import 'package:zestssh/ui/screens/settings/automation_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/data_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/help_support_screen.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';
import 'package:zestssh/ui/screens/settings/known_hosts_screen.dart';
import 'package:zestssh/ui/screens/settings/notification_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/session_logs_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/settings/sftp_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/widgets/setting_control_tile.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';

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

/// A phone's settings pages at the text sizes a phone can be set to, in
/// every language, on a phone 360 wide and on one 600 wide (3.0).
/// At the size the app is drawn at and at 1.3 times, no line breaks
/// inside a word; at every size, no words are cut at their top and bottom
/// and nothing runs over. Beside a setting's words,
/// a dropdown, a slider or a few segments left them a few letters a line (on
/// the SFTP page in French, at the size the app is drawn at, a letter a
/// line); a (?) or a badge in a column of its own beside a name cut a long
/// one; the About card's pills ran off it in every language; at twice the
/// size a theme card's name pushed its picture out of it; and five words
/// (two German, three Russian) were longer than their row at 1.3 times.
/// Longer words than a row holds at 1.5 times and more are still cut there.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final pages = <String, Widget Function()>{
    "a phone's Settings tab": () => const Scaffold(body: SettingsBody(bottomPadding: 1)),
    'Appearance': () => const AppearanceScreen(),
    'Terminal': () => const TerminalSettingsScreen(),
    'Keyboard row': () => const KeyboardRowScreen(),
    'Keyboard row, its keys': () => ProviderScope(
          overrides: [softKeyboardScrollableModeProvider.overrideWith((ref) => true)],
          child: const KeyboardRowScreen(),
        ),
    'SFTP': () => const SftpSettingsScreen(),
    'Automation': () => const AutomationSettingsScreen(),
    'Notifications': () => const NotificationSettingsScreen(),
    'Data': () => const DataSettingsScreen(),
    'Security': () => const SecuritySettingsScreen(),
    'Known hosts': () => const KnownHostsScreen(),
    'Session logs': () => const SessionLogsScreen(),
    'Help': () => const HelpSupportScreen(),
    'About': () => const AboutScreen(),
  };

  for (final MapEntry(key: name, value: page) in pages.entries) {
    for (final width in const [360.0, 600.0]) {
      for (final scale in const [1.0, 1.3, 1.5, 2.0]) {
        final words = scale <= 1.3;
        testWidgets('$name, ${width.toInt()} wide, at $scale times the text size, in every language: '
            '${words ? 'no word cut in two, ' : ''}no words cut at their top and bottom, nothing runs over',
            (tester) async {
          final problems = <String>[];
          for (final locale in AppLocalizations.supportedLocales) {
            await _pump(tester, page(), width: width, scale: scale, locale: locale, problems: problems, words: words);
          }
          expect(problems, isEmpty);
        });
      }
    }
  }

  group('what the rows that changed do', () {
    testWidgets("SFTP: each choice is picked from its field under the setting's words, and kept", (tester) async {
      final c = await _pump(tester, const SftpSettingsScreen());
      // (Its help is behind More, 4.0: opened, the choice is under it.)
      await tester.tap(find.byKey(ValueKey('settings-row-more-${_en.settingsMobHiddenFilesInBrowser}')));
      await tester.pumpAndSettle();
      expect(_below(tester, find.text(_en.settingsMobSystemFilesOnly), find.text(_en.settingsMobHiddenFilesInBrowserDesc)),
          isTrue, reason: 'on a phone 360 wide the choice is under the words');
      for (final (shown, pick) in [
        (_en.settingsMobSystemFilesOnly, _en.settingsMobHiddenAndSystem),
        (sftpTimeFormatLabel(_en, SftpTimeFormat.h24), sftpTimeFormatLabel(_en, SftpTimeFormat.h12)),
        (_en.settingsDeleteHoldOff, _en.settingsDeleteHoldSeconds(10)),
      ]) {
        await tester.tap(find.text(shown));
        await tester.pumpAndSettle();
        await tester.tap(find.text(pick).last);
        await tester.pumpAndSettle();
        expect(find.text(pick), findsOneWidget);
      }
      final prefs = c.read(sharedPreferencesProvider);
      expect(c.read(sftpHiddenLevelProvider), SftpHiddenLevel.hiddenAndSystem);
      expect(prefs.getString('sftp_hidden_level'), 'hiddenAndSystem');
      expect(c.read(sftpTimeFormatProvider), SftpTimeFormat.h12);
      expect(prefs.getString('sftp_time_format'), 'h12');
      expect(c.read(sftpDeleteHoldSecondsProvider), 10);
      expect(prefs.getInt('sftp_delete_hold_seconds'), 10);
    });

    testWidgets("Terminal: the font size's slider and the cursor's segments still set them", (tester) async {
      final c = await _pump(tester, const TerminalSettingsScreen());
      expect(c.read(terminalFontSizeProvider), isNot(28));
      await tester.drag(find.byType(Slider), const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(c.read(terminalFontSizeProvider), 28);
      // The shapes are drawn (no font holds the block's character); each is
      // found by its key.
      await tester.tap(find.byKey(const ValueKey('cursor-shape-underline')));
      await tester.pumpAndSettle();
      expect(c.read(cursorStyleProvider), TerminalCursorShape.underline);
    });

    testWidgets("Keyboard row: a long name's (?) follows it and opens its help; the row's switch still switches",
        (tester) async {
      final c = await _pump(tester, const KeyboardRowScreen());
      final row = find.byWidgetPredicate(
          (w) => w is SwitchListTile && w.key == const ValueKey('keys-row-on'));
      expect(row, findsOneWidget);
      final help = find.descendant(of: row, matching: find.byTooltip(_en.settingsMobLearnMore));
      expect(help, findsOneWidget);
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(find.text(_en.settingsMobExtraKeyboardRowHelpBody), findsOneWidget);
      await tester.tap(find.text(_en.settingsMobGotIt));
      await tester.pumpAndSettle();
      final before = c.read(showExtraKeyboardRowProvider);
      // Its help is behind More (4.0): its words open it, and the switch is
      // still switched by the row.
      await tester.tap(find.byKey(ValueKey('settings-row-more-${_en.settingsExtraKeyboardRow}')));
      await tester.pumpAndSettle();
      expect(c.read(showExtraKeyboardRowProvider), before, reason: "More's tap is More's");
      await tester.tap(find.descendant(of: row, matching: find.text(_en.settingsExtraKeyboardRowDesc)));
      await tester.pumpAndSettle();
      expect(c.read(showExtraKeyboardRowProvider), !before);
    });

    // The terminal's font and its size are the Terminal page's alone, and
    // Appearance has a row that opens it
    // (its own field for the font was here).
    testWidgets("Appearance: the terminal's font is not picked here; its row says the one in use", (tester) async {
      final c = await _pump(tester, const AppearanceScreen());
      expect(find.byType(SettingChoiceTile<TerminalFontFamily>, skipOffstage: false), findsNothing);
      await c.read(settingsUpdaterProvider).setTerminalFontFamily(TerminalFontFamily.firaCode);
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('appearance-terminal-font'));
      await tester.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
      expect(find.descendant(of: row, matching: find.textContaining(TerminalFontFamily.firaCode.nameIn(_en))),
          findsOneWidget);
    });

    testWidgets('a control stands beside the words where they keep their room, under them where they would not',
        (tester) async {
      for (final (width, scale, beside) in [(360.0, 1.0, false), (700.0, 1.0, true), (700.0, 2.0, false), (900.0, 2.0, true)]) {
        await _pump(tester, const TerminalSettingsScreen(), width: width, scale: scale);
        final title = find.text(_en.settingsFontSize);
        final slider = find.byType(Slider);
        final besideIt = tester.getTopLeft(slider).dx > tester.getTopRight(title).dx &&
            tester.getTopLeft(slider).dy < tester.getBottomLeft(title).dy;
        expect(besideIt, beside, reason: '${width.toInt()} wide at $scale times');
        expect(_below(tester, slider, title), !beside, reason: '${width.toInt()} wide at $scale times');
      }
    });

    testWidgets("About: the words under the icon on a phone's page, beside it on a wide one", (tester) async {
      for (final (width, beside) in [(360.0, false), (900.0, true)]) {
        await _pump(tester, const AboutScreen(), width: width);
        final icon = find.byType(Image).first;
        final name = find.text('ZestSSH');
        expect(_below(tester, name, icon), !beside, reason: '${width.toInt()} wide');
        expect(tester.getTopLeft(name).dx > tester.getTopRight(icon).dx, beside, reason: '${width.toInt()} wide');
      }
    });

    // Found in a code review: a phone's About had two Rate rows, the
    // store's and an old one that opened the website's home page, which a
    // computer showed too. Rating is the stores': a computer has none.
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS, TargetPlatform.windows]) {
      testWidgets('About on ${platform.name}: the store Rate row where there is a store, and no other', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          for (final width in [360.0, 900.0]) {
            await _pump(tester, const AboutScreen(), width: width);
            expect(find.text(_en.aboutRateApp), platform == TargetPlatform.windows ? findsNothing : findsOneWidget,
                reason: '${width.toInt()} wide');
            expect(find.byKey(const ValueKey('about-rate-app')), platform == TargetPlatform.windows ? findsNothing : findsOneWidget,
                reason: '${width.toInt()} wide');
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });

  // A build made without ZEST_OFFICIAL=true (found in a review): what has no address
  // in it is not drawn, and the pages still fit.
  group('a community build shows only what it has', () {
    setUp(() {
      debugZestOfficial = false;
      addTearDown(() => debugZestOfficial = true);
    });

    testWidgets("a phone's Settings tab: no upgrade card, no Plan row, and no \"Sign in now\" on Account", (tester) async {
      await _pump(tester, const Scaffold(body: SettingsBody(bottomPadding: 1)));
      expect(find.byKey(const ValueKey('settings-upgrade')), findsNothing);
      expect(find.byKey(const ValueKey('settings-plan')), findsNothing);
      expect(find.byKey(const ValueKey('settings-account')), findsOneWidget);
      expect(find.text(_en.settingsMobSignInNow), findsNothing);
      expect(find.text(_en.settingsPageAccountDesc), findsOneWidget);
    });

    testWidgets('Help: no guides, no links into the docs, no reports, tickets, Support Hub, Ask Astryx, Discord, '
        'email or website; what needs no service stays', (tester) async {
      await _pump(tester, const HelpSupportScreen());
      for (final key in const ['help-guides', 'help-known-issues', 'help-ideas-board', 'help-ask-astryx']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      Finder group(String label) => find.byWidgetPredicate((w) => w is PhoneListGroup && w.label == label);
      for (final label in [_en.helpGuides, _en.helpGroupCommonQuestions, _en.helpGroupGetInTouch, _en.helpGroupMore]) {
        expect(group(label), findsNothing, reason: label);
      }
      for (final words in [
        _en.helpReportBug,
        _en.helpSuggest,
        _en.ticketsTitle,
        _en.helpDiscord,
        _en.helpEmail,
        _en.helpWebsite,
        _en.helpAllDocumentation,
      ]) {
        expect(find.text(words), findsNothing, reason: words);
      }
      expect(group(_en.helpGroupBeforeScreenshot), findsOneWidget);
      expect(group(_en.helpFaqTitle), findsOneWidget);
    });

    testWidgets('About: says which build it is, and shows no website, Discord, report, policy, terms or plan; '
        "What's new and the licences stay", (tester) async {
      await _pump(tester, const AboutScreen());
      expect(find.byKey(const ValueKey('about-build-kind')), findsOneWidget);
      expect(find.text(_en.communityBuild), findsOneWidget);
      for (final words in [
        _en.aboutScreenLinkWebsite,
        'Discord',
        _en.aboutScreenLinkReportBug,
        _en.aboutScreenLegalPrivacy,
        _en.aboutScreenLegalTerms,
      ]) {
        expect(find.text(words), findsNothing, reason: words);
      }
      expect(find.descendant(of: find.byKey(const ValueKey('about-tier')), matching: find.byType(Text)), findsNothing);
      expect(find.text(_en.aboutScreenLinkWhatsNew), findsOneWidget);
      expect(find.text(_en.aboutScreenLegalLicenses), findsOneWidget);
    });

    testWidgets('the three pages fit in every language, 360 wide, at the size drawn and at 1.3 times', (tester) async {
      final problems = <String>[];
      for (final page in <Widget Function()>[
        () => const Scaffold(body: SettingsBody(bottomPadding: 1)),
        () => const HelpSupportScreen(),
        () => const AboutScreen(),
      ]) {
        for (final scale in const [1.0, 1.3]) {
          for (final locale in AppLocalizations.supportedLocales) {
            await _pump(tester, page(), scale: scale, locale: locale, problems: problems, words: true);
          }
        }
      }
      expect(problems, isEmpty);
    });
  });

  testWidgets('the release says nothing about which build it is on About', (tester) async {
    await _pump(tester, const AboutScreen());
    expect(find.byKey(const ValueKey('about-build-kind')), findsNothing);
    expect(find.text(_en.communityBuild), findsNothing);
  });
}

/// Whether [lower] starts under where [upper] ends.
bool _below(WidgetTester tester, Finder lower, Finder upper) =>
    tester.getTopLeft(lower).dy >= tester.getBottomLeft(upper).dy;

/// [screen] drawn on a phone [width] wide at [scale] times the text size in
/// [locale], in the app's own theme and fonts. With [problems], each layout
/// that runs over, each paragraph cut at its top and bottom, and each word
/// cut in two where [words], is added to it, and the screen is taken down
/// again.
Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget screen, {
  double width = 360,
  double scale = 1.0,
  Locale locale = const Locale('en'),
  List<String>? problems,
  bool words = false,
}) async {
  await tester.runAsync(loadShotFonts);
  tester.view.physicalSize = Size(width, 7000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final theme = BuiltInThemes.getById('default_dark');
  AppColors.applyTheme(theme.colorScheme);
  FlutterSecureStorage.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    recordingModeProvider.overrideWith((ref) => false),
    databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
    orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
  ]);
  addTearDown(container.dispose);
  final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => screen)]);
  addTearDown(router.dispose);
  final found = <String>[];
  final reported = FlutterError.onError;
  if (problems != null) {
    FlutterError.onError = (details) =>
        found.add(details.exceptionAsString().split(String.fromCharCode(10)).first);
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
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (problems != null) {
      for (final e in find.byType(RichText).evaluate()) {
        final paragraph = e.renderObject;
        if (paragraph is! RenderParagraph) continue;
        final cut = cutTopAndBottom(paragraph);
        if (cut != null) found.add('cut at its top and bottom: $cut');
        if (words && paragraph.hasSize) {
          found.addAll(wordsCut(paragraph).map((cut) => 'a word cut in two: $cut'));
        }
      }
    }
  } finally {
    FlutterError.onError = reported;
  }
  if (problems != null) {
    problems.addAll(found.map((p) => '$locale: $p'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  }
  return container;
}
