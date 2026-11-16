import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/ui/cloud_accounts_view.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/shortcuts/widgets/keyboard_shortcuts_panel.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart' show planPageOpenerProvider;
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/data_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/setting_help.dart' show SettingMoreButton;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/redactor.dart' show RedactLevel;

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.pro);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

/// Settings' structure (4.0):
/// one structure on computers
/// and phones, the pages under Account, App, Connections, Security and data,
/// and About; General only the language, the window and startup; every row
/// moved, none dropped; rows one line with their help behind More; and the
/// search and every way into a page landing where the row is now.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(1274, 4000),
    Map<String, Object> prefs = const {},
    List<Override> extra = const [],
    bool router = false,
  }) async {
    AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(prefs);
    final shared = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(shared),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      // The account page's clock, which ticks every 30 seconds.
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 12, 12))),
      ...extra,
    ]);
    addTearDown(container.dispose);
    final Widget app;
    if (router) {
      final go = GoRouter(routes: [
        GoRoute(path: '/', builder: (context, state) => page),
        GoRoute(path: '/:rest(.*)', builder: (context, state) => Scaffold(body: Text('page ${state.uri}'))),
      ]);
      addTearDown(go.dispose);
      app = MaterialApp.router(
        routerConfig: go,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      );
    } else {
      app = MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: page,
      );
    }
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: app));
    await settle(tester);
    return container;
  }

  Future<void> takeDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  }

  const popup = Scaffold(body: SettingsInlineView());
  Finder nav(String page) => find.byKey(ValueKey('settings-nav-$page'));
  // Whether [page] is the one marked in the list: said selected to a screen
  // reader (its button's semantics).
  bool selected(WidgetTester tester, String page) =>
      tester
          .widget<Semantics>(find
              .descendant(of: nav(page), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.button == true))
              .first)
          .properties
          .selected ==
      true;

  Future<void> open(WidgetTester tester, String page) async {
    await tester.tap(nav(page));
    await settle(tester);
  }

  testWidgets('a computer lists its pages under their groups, in the order decided, with no second security page',
      (tester) async {
    await pump(tester, popup);
    final groups = [en.settingsGroupAccount, en.settingsGroupApp, en.settingsGroupConnections, en.settingsGroupSecurityData];
    final pages = [
      en.settingsAccount,
      en.settingsPagePlan,
      en.settingsInlineSectionGeneral,
      en.settingsInlineSectionAppearance,
      en.settingsPageKeyboardMouse,
      en.settingsNotifications,
      en.settingsPageTerminalSsh,
      en.settingsPageFiles,
      en.settingsScreensSection,
      en.settingsPageSecurityPrivacy,
      en.settingsPageBackupsData,
      en.settingsInlineSectionAbout,
    ];
    // Every group's label over its pages, top to bottom.
    final order = [
      groups[0].toUpperCase(), pages[0], pages[1],
      groups[1].toUpperCase(), pages[2], pages[3], pages[4], pages[5],
      groups[2].toUpperCase(), pages[6], pages[7], pages[8],
      groups[3].toUpperCase(), pages[9], pages[10],
      pages[11],
    ];
    final tops = [for (final words in order) tester.getTopLeft(find.text(words).first).dy];
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]), reason: '${order[i]} under ${order[i - 1]}');
    }
    for (final g in ['account', 'app', 'connections', 'securityData']) {
      expect(find.byKey(ValueKey('settings-group-$g')), findsOneWidget);
      expect(
        find.descendant(
            of: find.byKey(ValueKey('settings-group-$g')),
            matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.header == true)),
        findsOneWidget,
        reason: 'a heading to a screen reader',
      );
    }
    // Before: "Account and security", "Security", "Mouse", "Keyboard shortcuts".
    expect(nav('shortcuts'), findsNothing);
    expect(find.text(en.settingsInlineMouseSection), findsNothing, reason: 'Mouse is a heading on Keyboard and mouse, not a page');
    // Nothing owned: the plan says Free beside Plan.
    expect(find.descendant(of: nav('plan'), matching: find.text(en.settingsInlineTierFree)), findsOneWidget);
    await takeDown(tester);
  });

  testWidgets("Plan says what the account has; a team's member is told what the seat gives, never the plans' names",
      (tester) async {
    final opened = <Uri>[];
    await pump(tester, popup, prefs: {kSettingsLastSectionKey: 'plan'}, extra: [
      isProProvider.overrideWith((ref) => _Plan(true)),
      planPageOpenerProvider.overrideWithValue((page) async => opened.add(page)),
    ]);
    expect(selected(tester, 'plan'), isTrue);
    expect(find.text(en.settingsPagePlanDesc), findsOneWidget);
    expect(find.descendant(of: nav('plan'), matching: find.text(en.narrowSidebarTierSqueezed)), findsOneWidget);
    final yours = find.byKey(const ValueKey('settings-plan-yours'));
    expect(find.descendant(of: yours, matching: find.text(en.narrowSidebarTierSqueezed)), findsOneWidget);
    expect(find.descendant(of: yours, matching: find.text(en.narrowSidebarTierJuiced)), findsNothing);
    // The plan's chip explains it: the plan popover (4.0).
    await tester.tap(find.descendant(of: yours, matching: find.byKey(const ValueKey('plan-chip'))));
    await settle(tester);
    expect(find.byKey(const ValueKey('plan-popover')), findsOneWidget);
    expect(find.text(en.planPopoverTitle(en.narrowSidebarTierSqueezed)), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    // Compare plans opens the website's page on the plans.
    await tester.tap(find.byKey(const ValueKey('settings-plan-compare')));
    await settle(tester);
    expect(opened, [Uri.parse('https://zestssh.com/pricing/plans')]);
    // Not fully entitled: Redeem a code is here now (it was the account page's).
    expect(find.text(en.settingsMobRedeemCode), findsOneWidget);
    await takeDown(tester);

    await pump(tester, popup, prefs: {kSettingsLastSectionKey: 'plan'}, extra: [
      isProProvider.overrideWith((ref) => _Plan(true)),
      orchardSummariesProvider.overrideWith((ref) async => [OrchardSummary.closedOffline('o-demo')]),
    ]);
    expect(find.text(en.settingsPlanTeamSeat), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-nav-plan-tag')), findsNothing);
    expect(find.text(en.narrowSidebarTierSqueezed), findsNothing);
    expect(find.byKey(const ValueKey('settings-plan-compare')), findsNothing);
    // Nor does the search list Compare plans, whose words name them.
    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'compare');
    await settle(tester);
    expect(find.text(en.settingsPlanCompare), findsNothing);
    await takeDown(tester);
  });

  testWidgets('General holds the language, the window and startup alone; every row it had is on its page now',
      (tester) async {
    await pump(tester, popup);
    expect(selected(tester, 'general'), isTrue, reason: 'Settings opens on General the first time');
    expect(find.text(en.settingsPageGeneralDesc), findsOneWidget);
    for (final row in [
      en.settingsLanguage,
      en.settingsInlineCloseToTray,
      en.settingsConfirmCloseWindow,
      en.settingsInlineAutoRestore,
    ]) {
      expect(find.text(row), findsOneWidget, reason: row);
    }
    // One card of four rows, as the mockup draws General.
    expect(find.byKey(const ValueKey('settings-row-card')), findsOneWidget);
    for (final gone in [
      en.settingsInlineDefaultSshPort,
      en.settingsHealthChecks,
      en.settingsSftpTimeFormat,
      en.settingsInlineResetAllSettings,
    ]) {
      expect(find.text(gone), findsNothing, reason: '$gone is not General\'s');
    }
    expect(find.byType(CloudAccountsTiles), findsNothing);

    await open(tester, 'terminal');
    for (final row in [
      en.settingsInlineDefaultSshPort,
      en.settingsInlineDefaultUsername,
      en.settingsInlineConnectionTimeout,
      en.settingsHealthChecks,
      en.settingsInlineTerminalColours,
      en.settingsInlineFontFamily,
      en.settingsInlineCursorStyle,
      en.settingsInlineScrollbackBuffer,
      en.settingsInlineSshKeepaliveInterval,
      en.settingsSessionLogEnabled,
    ]) {
      expect(find.text(row), findsOneWidget, reason: '$row on Terminal and SSH');
    }

    await open(tester, 'files');
    for (final row in [en.settingsSftpTimeFormat, en.settingsMobHiddenFilesInBrowser, en.settingsDeleteHoldLabel]) {
      expect(find.text(row), findsOneWidget, reason: '$row on Files');
    }

    await open(tester, 'appearance');
    expect(find.text(en.settingsInlineAppTheme), findsOneWidget);
    expect(find.text(en.settingsInlineDensity), findsOneWidget);
    expect(find.text(en.settingsInlineTerminalColours), findsNothing, reason: 'the terminal is Terminal and SSH\'s');

    await open(tester, 'keyboard');
    expect(find.text(en.settingsInlineRightClickPaste), findsOneWidget);
    expect(find.text(en.settingsInlineMiddleClickPaste), findsOneWidget);
    expect(find.byType(KeyboardShortcutsPanel), findsOneWidget, reason: 'the shortcuts on the same page');

    await open(tester, 'security');
    for (final row in [
      en.settingsInlineAppLock,
      en.secSetEncryptAtRest,
      en.settingsInlineDangerousCommandProtection,
      en.settingsInlineUnknownHostKeys,
      en.recModeName,
    ]) {
      expect(find.text(row), findsOneWidget, reason: '$row on Security and privacy');
    }
    await takeDown(tester);
  });

  testWidgets('Backups and data has the data, the cloud accounts and the danger rows; Account has none of them',
      (tester) async {
    await pump(tester, popup, prefs: {kSettingsLastSectionKey: 'data'});
    expect(selected(tester, 'data'), isTrue);
    for (final row in [
      en.accountExport,
      en.accountImport,
      en.settingsMobConnectionsAsSshConfig,
      en.accountAutoBackups,
      en.accountClearCache,
      en.accountDeleteLocal,
      en.settingsInlineResetAllSettings,
    ]) {
      expect(find.text(row), findsOneWidget, reason: '$row on Backups and data');
    }
    expect(find.byType(CloudAccountsTiles), findsOneWidget);
    // A danger row says all of what it does, with no More.
    expect(find.text(en.settingsResetAllHelp), findsOneWidget);
    expect(find.text(en.accountDeleteLocalHelp), findsOneWidget);

    await open(tester, 'account');
    for (final row in [en.accountExport, en.accountImport, en.accountDeleteLocal, en.settingsInlineResetAllSettings]) {
      expect(find.text(row), findsNothing, reason: '$row is not the Account page\'s');
    }
    expect(find.text(en.settingsMobRedeemCode), findsNothing, reason: 'Redeem a code is the Plan page\'s');

    await open(tester, 'plan');
    expect(find.text(en.settingsMobRedeemCode), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-plan-compare')), findsOneWidget);
    await takeDown(tester);
  });

  testWidgets('a row is one line: its help behind More, shown and hidden again, said to a screen reader',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, popup);
    final more = find.byKey(ValueKey('settings-row-more-${en.settingsInlineCloseToTray}'));
    expect(more, findsOneWidget);
    expect(find.text(en.settingsInlineCloseToTrayDesc), findsNothing, reason: 'folded');
    expect(find.text(en.settingsRowMore), findsWidgets);
    expect(
      tester.getSemantics(more),
      isSemantics(
        label: en.settingsRowMoreAbout(en.settingsInlineCloseToTray),
        isButton: true,
        hasExpandedState: true,
        isExpanded: false,
        hasTapAction: true,
      ),
    );
    final before = tester.getSize(find.byKey(const ValueKey('settings-row-card'))).height;

    await tester.tap(more);
    await tester.pump();
    expect(find.text(en.settingsInlineCloseToTrayDesc), findsOneWidget);
    expect(find.descendant(of: more, matching: find.text(en.settingsRowLess)), findsOneWidget);
    expect(tester.getSemantics(more).label, en.settingsRowLessAbout(en.settingsInlineCloseToTray));
    expect(tester.getSize(find.byKey(const ValueKey('settings-row-card'))).height, greaterThan(before));
    // Only that row's help: the others stay folded.
    expect(find.text(en.settingsConfirmCloseWindowDesc), findsNothing);

    await tester.tap(more);
    await tester.pump();
    expect(find.text(en.settingsInlineCloseToTrayDesc), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('settings-row-card'))).height, before);
    semantics.dispose();
    await takeDown(tester);
  });

  testWidgets('a reason a control cannot be used stays in sight, with no More', (tester) async {
    await pump(tester, popup, prefs: {kSettingsLastSectionKey: 'security', 'security_lock_enabled': false});
    // Encrypt at rest needs the app lock first: that is said, not folded.
    expect(find.text(en.secSetEncryptNeedsLock), findsOneWidget);
    expect(find.byKey(ValueKey('settings-row-more-${en.secSetEncryptAtRest}')), findsNothing);
    await takeDown(tester);
  });

  testWidgets('recording mode on Security and privacy: its switch, and its level while it is on', (tester) async {
    final c = await pump(tester, popup, prefs: {kSettingsLastSectionKey: 'security'});
    final toggle = find.descendant(of: find.byKey(const ValueKey('settings-recording-mode')), matching: find.byType(ZestSwitch));
    expect(toggle, findsOneWidget);
    expect(tester.widget<ZestSwitch>(toggle).value, isFalse);
    expect(find.text(en.recModeLevelLabel), findsNothing);
    await tester.tap(toggle);
    await settle(tester);
    expect(c.read(recordingModeProvider), isTrue);
    expect(find.text(en.recModeLevelLabel), findsOneWidget);
    expect(find.text(en.recModeLevelLayout), findsOneWidget, reason: 'Layout, the level by default');
    expect(c.read(recordingRedactLevelProvider), RedactLevel.layout);
    await takeDown(tester);
  });

  group('the search finds each row on the page it is on now, and opens that page', () {
    for (final (words, row, page) in [
      ('ssh port', en.settingsInlineDefaultSshPort, 'terminal'),
      ('time format', en.settingsSftpTimeFormat, 'files'),
      ('middle', en.settingsInlineMiddleClickPaste, 'keyboard'),
      ('recording mode', en.recModeName, 'security'),
      ('export', en.accountExport, 'data'),
      ('reset all', en.settingsInlineResetAllSettings, 'data'),
      ('redeem', en.settingsMobRedeemCode, 'plan'),
      ('devices', en.zestProfileNavDevices, 'account'),
      ('tray', en.settingsInlineCloseToTray, 'general'),
    ]) {
      testWidgets('"$words": $row', (tester) async {
        await pump(tester, popup);
        await tester.enterText(find.byKey(const ValueKey('settings-search')), words);
        await settle(tester);
        final hit = find.ancestor(of: find.text(row), matching: find.byType(InkWell)).first;
        expect(hit, findsOneWidget);
        await tester.tap(hit);
        await settle(tester, rounds: 12);
        expect(selected(tester, page), isTrue, reason: '$row is on $page');
        // (The account page's headings are in capitals.)
        if (page != 'account') expect(find.text(row), findsWidgets);
        await takeDown(tester);
      });
    }
  });

  group('every way into a page lands on the page the row is on now', () {
    for (final (target, page) in [
      (SettingsJumpTarget.account, 'account'),
      (SettingsJumpTarget.plan, 'plan'),
      (SettingsJumpTarget.appearance, 'appearance'),
      (SettingsJumpTarget.keyboard, 'keyboard'),
      (SettingsJumpTarget.notifications, 'notifications'),
      (SettingsJumpTarget.terminal, 'terminal'),
      (SettingsJumpTarget.files, 'files'),
      (SettingsJumpTarget.security, 'security'),
      (SettingsJumpTarget.privacy, 'security'),
      (SettingsJumpTarget.data, 'data'),
    ]) {
      testWidgets('${target.name}: $page', (tester) async {
        final c = await pump(tester, popup);
        c.read(settingsJumpProvider.notifier).state = target;
        await settle(tester);
        expect(selected(tester, page), isTrue);
        expect(c.read(settingsJumpProvider), isNull, reason: 'taken once');
        await takeDown(tester);
      });
    }
  });

  testWidgets('Settings last left on a page of an earlier version opens where its rows are now', (tester) async {
    await pump(tester, popup, prefs: {kSettingsLastSectionKey: 'shortcuts'});
    expect(selected(tester, 'keyboard'), isTrue, reason: 'Keyboard shortcuts is in Keyboard and mouse');
    expect(find.byType(KeyboardShortcutsPanel), findsOneWidget);
    await takeDown(tester);
  });

  // ── A phone ────────────────────────────────────────────────────

  testWidgets("a phone's Settings has the same groups and pages, each row opening its page", (tester) async {
    await pump(tester, const Scaffold(body: SettingsBody(bottomPadding: 16)), size: const Size(412, 3000), router: true);
    final order = [
      en.settingsGroupAccount, 'settings-account', 'settings-plan',
      en.settingsGroupApp, 'settings-language', 'settings-appearance', 'settings-keyboard', 'settings-notifications',
      en.settingsGroupConnections, 'settings-terminal', 'settings-sftp', 'settings-screens',
      en.settingsGroupSecurityData, 'settings-security', 'settings-data',
      'settings-about',
    ];
    Finder at(String s) => s.startsWith('settings-')
        ? find.byKey(ValueKey(s))
        : find.byWidgetPredicate((w) => w is PhoneListGroup && w.label == s);
    final tops = [for (final s in order) tester.getTopLeft(at(s).first).dy];
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]), reason: '${order[i]} under ${order[i - 1]}');
    }
    String title(String key) =>
        ((tester.widget<PhoneListRow>(find.byKey(ValueKey(key)))).title as Text).data!;
    expect(title('settings-language'), en.settingsInlineSectionGeneral);
    expect(title('settings-keyboard'), en.settingsPageKeyboardMouse);
    expect(title('settings-terminal'), en.settingsPageTerminalSsh);
    expect(title('settings-sftp'), en.settingsPageFiles);
    expect(title('settings-security'), en.settingsPageSecurityPrivacy);
    expect(title('settings-data'), en.settingsPageBackupsData);
    expect(find.descendant(of: find.byKey(const ValueKey('settings-plan')), matching: find.text(en.settingsInlineTierFree)),
        findsOneWidget);
    // Backups, Automation and Reset all settings are no rows of the root.
    for (final gone in ['settings-backups', 'settings-automation', 'settings-reset']) {
      expect(find.byKey(ValueKey(gone)), findsNothing, reason: gone);
    }
    for (final (key, route) in [
      ('settings-plan', Routes.upgrade),
      ('settings-keyboard', Routes.keyboardRow),
      ('settings-terminal', Routes.terminalSettings),
      ('settings-sftp', Routes.sftpSettings),
      ('settings-data', Routes.dataSettings),
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(find.text('page $route'), findsOneWidget, reason: key);
      GoRouter.of(tester.element(find.text('page $route'))).pop();
      await tester.pumpAndSettle();
    }
    await takeDown(tester);
  });

  testWidgets("a phone's pages hold the rows that moved: the keyboard's and the mouse's, safety and recording mode, "
      'backups and Reset all settings', (tester) async {
    await pump(tester, const TerminalSettingsScreen(), size: const Size(412, 6000));
    for (final gone in [
      en.settingsInlineRightClickPaste,
      en.settingsInlineDangerousCommandProtection,
      en.settingsExtraKeyboardRow,
    ]) {
      expect(find.text(gone), findsNothing, reason: '$gone is not Terminal and SSH\'s');
    }
    expect(find.text(en.settingsPageTerminalSsh), findsOneWidget, reason: 'its title');
    await takeDown(tester);

    await pump(tester, const KeyboardRowScreen(), size: const Size(412, 6000));
    expect(find.text(en.settingsPageKeyboardMouse), findsOneWidget);
    expect(find.text(en.settingsInlineRightClickPaste), findsOneWidget);
    expect(find.text(en.settingsInlineMiddleClickPaste), findsOneWidget);
    await takeDown(tester);

    final c = await pump(tester, const SecuritySettingsScreen(), size: const Size(412, 6000));
    expect(find.text(en.settingsPageSecurityPrivacy), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-dangerous-commands')), findsOneWidget);
    final rec = find.byKey(const ValueKey('security-recording-mode'));
    expect(rec, findsOneWidget);
    expect(find.byKey(const ValueKey('security-recording-level')), findsNothing);
    await tester.tap(rec);
    await settle(tester);
    expect(c.read(recordingModeProvider), isTrue);
    expect(find.byKey(const ValueKey('security-recording-level')), findsOneWidget);
    await takeDown(tester);

    await pump(tester, const DataSettingsScreen(), size: const Size(412, 6000));
    expect(find.text(en.settingsPageBackupsData), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-backups')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-reset')), findsOneWidget);
    await takeDown(tester);
  });

  // The same on a phone: a row is one line, its help behind More.
  testWidgets("a phone's row is one line: its help behind More, which opens it without touching the switch, said to "
      'a screen reader; a 48 high target', (tester) async {
    final c = await pump(tester, const TerminalSettingsScreen(), size: const Size(412, 6000));
    final more = find.byKey(ValueKey('settings-row-more-${en.settingsKeepAwake}'));
    expect(more, findsOneWidget);
    expect(find.text(en.settingsKeepAwakeDesc), findsNothing, reason: 'folded');
    // 48 wide; 48 high through the row's padding (the test of More on the
    // name's line taps it 20 above and below its middle).
    expect(tester.getSize(more).width, greaterThanOrEqualTo(48));
    // The row is one node to a screen reader (the switch): it says the help
    // with the name, folded or not.
    expect(tester.getSemantics(more), isSemantics(hint: en.settingsKeepAwakeDesc));
    final before = c.read(keepScreenAwakeProvider);
    await tester.tap(more);
    await tester.pump();
    expect(find.text(en.settingsKeepAwakeDesc), findsOneWidget);
    expect(c.read(keepScreenAwakeProvider), before, reason: "More's tap is More's, not the switch's");
    await tester.tap(more);
    await tester.pump();
    expect(find.text(en.settingsKeepAwakeDesc), findsNothing);
    // A value stays in sight: the terminal's font.
    expect(find.text(en.settingsFont), findsOneWidget);
    expect(find.byKey(ValueKey('settings-row-more-${en.settingsFont}')), findsNothing);
    await takeDown(tester);
  });

  // A device run (Security and privacy on a phone and a
  // tablet): More's 48 high target made the name's line 48 high, an empty strip
  // under the name; under a long name More went to a line of its own; and the
  // icon and the chevron, at the row's top, stood higher than the name.
  testWidgets("a phone's rows: More on the name's line, the row no taller for it, its target still 48 high, the icon "
      'and the chevron level with the name', (tester) async {
    await pump(tester, const SecuritySettingsScreen(), size: const Size(412, 6000), prefs: {'security_lock_enabled': true});
    final name = find.text(en.secSetChangePin);
    final more = find.byKey(SettingMoreButton.keyOf(en.secSetChangePin));
    final row = find.ancestor(of: name, matching: find.byType(ListTile)).first;
    final mid = tester.getCenter(name).dy;
    expect((tester.getCenter(more).dy - mid).abs(), lessThan(2), reason: "More on the name's line");
    expect(tester.getSize(row).height, lessThan(64), reason: 'no strip under the name');
    final icon = find.descendant(of: row, matching: find.byType(PhoneIconTile));
    final chevron = find.descendant(of: row, matching: find.byIcon(LucideIcons.chevronRight));
    expect((tester.getCenter(icon).dy - mid).abs(), lessThan(3), reason: 'the icon level with the name');
    expect((tester.getCenter(chevron).dy - mid).abs(), lessThan(3), reason: 'the chevron level with the name');
    // A tap 20 above More's middle, in the row's padding, is still More's.
    expect(find.text(en.secSetChangePinSubtitle), findsNothing);
    await tester.tapAt(tester.getCenter(more) - const Offset(0, 20));
    await tester.pump();
    expect(find.text(en.secSetChangePinSubtitle), findsOneWidget);
    await tester.tapAt(tester.getCenter(more) + const Offset(0, 20));
    await tester.pump();
    expect(find.text(en.secSetChangePinSubtitle), findsNothing, reason: '20 below it too');

    await takeDown(tester);

    // A long name: More after its last word, not on a line of its own (600
    // wide: in the test's font, every letter a square, the last line of 412
    // has no room for it, and More goes under the name, as it should).
    await pump(tester, const SecuritySettingsScreen(), size: const Size(600, 6000), prefs: {'security_lock_enabled': true});
    final long = find.text(en.secSetLockShowSessions);
    final longMore = find.byKey(SettingMoreButton.keyOf(en.secSetLockShowSessions));
    expect(tester.getSize(long).height, greaterThan(30), reason: 'the name takes two lines or more here');
    expect(tester.getCenter(longMore).dy, lessThan(tester.getBottomLeft(long).dy), reason: 'beside its last line');
    expect(tester.getCenter(longMore).dy, greaterThan(tester.getCenter(long).dy), reason: 'its last line');
    await takeDown(tester);
  });

  testWidgets("a phone's danger rows, reasons and values stay in sight; a timeout's value is said with its help folded",
      (tester) async {
    await pump(tester, const SecuritySettingsScreen(), size: const Size(412, 6000), prefs: {'security_lock_enabled': true});
    // Clear all trusted keys: a danger row, in full.
    expect(find.text(en.secSetClearAllKeysSubtitle), findsOneWidget);
    // Folded help.
    for (final (name, help) in [
      (en.secSetTrustedHostKeys, en.secSetTrustedHostKeysSubtitle),
      (en.settingsInlineDangerousCommandProtection, en.settingsDangerousCommandDesc),
      (en.secSetIdleLock, en.secSetIdleLockDesc),
      (en.settingsInlineAutoLock, en.settingsInlineAutoLockDesc),
    ]) {
      expect(find.byKey(ValueKey('settings-row-more-$name')), findsOneWidget, reason: name);
      expect(find.text(help), findsNothing, reason: name);
    }
    await takeDown(tester);

    await pump(tester, const SecuritySettingsScreen(), size: const Size(412, 6000), prefs: {'security_lock_enabled': false});
    // Encryption needs the app lock: the reason in full.
    expect(find.text(en.secSetEncryptNeedsLock), findsOneWidget);
    await takeDown(tester);

    await pump(tester, const DataSettingsScreen(), size: const Size(412, 6000));
    expect(find.text(en.settingsClearAllDataDesc), findsOneWidget, reason: 'a danger row, in full');
    expect(find.text(en.settingsMobImportDataDesc), findsNothing, reason: 'folded');
    await takeDown(tester);
  });

  // A build made without ZEST_OFFICIAL=true.
  testWidgets('a community build: a computer has no Plan page, last left on it or not; About says which build it is '
      'and links to no website, Discord, report form, policy or terms', (tester) async {
    debugZestOfficial = false;
    addTearDown(() => debugZestOfficial = true);
    await pump(tester, popup, prefs: {kSettingsLastSectionKey: 'plan'});
    expect(nav('plan'), findsNothing);
    expect(nav('account'), findsOneWidget);
    expect(selected(tester, 'general'), isTrue, reason: 'a page that is not there opens General');
    await open(tester, 'about');
    expect(find.byKey(const ValueKey('settings-about-build-kind')), findsOneWidget);
    expect(find.text(en.communityBuild), findsOneWidget);
    for (final words in [
      en.settingsInlineLinkWebsite,
      en.settingsInlineLinkDiscord,
      en.settingsInlineLinkReportBug,
      en.settingsInlineLinkPrivacy,
      en.settingsInlineLinkTerms,
    ]) {
      expect(find.text(words), findsNothing, reason: words);
    }
    expect(find.text(en.settingsInlineLinkWhatsNew), findsOneWidget);
    expect(find.text(en.settingsInlineLinkLicenses), findsOneWidget);
    await takeDown(tester);
  });

  testWidgets('the release: About on a computer says nothing about which build it is', (tester) async {
    await pump(tester, popup);
    await open(tester, 'about');
    expect(find.byKey(const ValueKey('settings-about-build-kind')), findsNothing);
    expect(find.text(en.settingsInlineLinkPrivacy), findsOneWidget);
    await takeDown(tester);
  });
}

Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
