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
import 'package:zestssh/features/networks/pages/networks_mobile_page.dart';
import 'package:zestssh/features/onboarding/lan_scan_screen.dart';
import 'package:zestssh/features/onboarding/onboarding_screen.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/automation/automation_guide_screen.dart';
import 'package:zestssh/ui/screens/automation/automation_history_screen.dart';
import 'package:zestssh/ui/screens/automation/automation_wizard_screen.dart';
import 'package:zestssh/ui/screens/automation/scheduled_tasks_screen.dart';
import 'package:zestssh/ui/screens/automation/workflow_list_screen.dart';
import 'package:zestssh/ui/screens/command_history/command_history_screen.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/identity/identity_list_screen.dart';
import 'package:zestssh/ui/screens/import/putty_import_screen.dart';
import 'package:zestssh/ui/screens/notifications/notifications_screen.dart';
import 'package:zestssh/ui/screens/profile/email_auth_screen.dart';
import 'package:zestssh/ui/screens/security/pin_setup_screen.dart';
import 'package:zestssh/ui/screens/security/security_lock_screen.dart';
import 'package:zestssh/ui/screens/settings/sync_backend_screen.dart';
import 'package:zestssh/ui/screens/transcripts/transcripts_screen.dart';
import 'package:zestssh/ui/screens/triggers/triggers_screen.dart';

import '../helpers/words_cut.dart';
import '../visual/shots_util.dart';
import '../a11y/a11y_checks.dart';

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

/// The rest of a phone's screens at the text sizes a phone can be set to, in
/// every language, on a phone 360 wide (3.0), as
/// phone_screens_fit_test.dart holds the host editor and the others: at the
/// size the app is drawn at and at 1.3 times, no line breaks inside a word, no
/// name is cut at its box's edge and every word is in a font of the app; at
/// every size, no words are cut at their top and bottom, nothing runs over and
/// nothing fails. The automation guide drew its parameters and its
/// troubleshooting in the system's font, at the size the app is drawn at
/// whatever the person's text size (a RichText takes neither); its numbered
/// steps and the PIN setup's cut their number from 1.5 times; two German words
/// were longer than their row at 1.3 times ("Benachrichtigungseinstellungen",
/// "Automatisierungsverlauf"); and the PIN setup's check for a way to unlock
/// with the device threw where the system has none to ask.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  tearDown(() => ConnectionEditScreen.debugDesktopShell = null);

  final pages = <String, Widget Function()>{
    'the identities': () => const IdentityListScreen(),
    'the PIN setup': () => const PinSetupScreen(),
    'the LAN scan': () => const LanScanScreen(),
    'the PuTTY import': () => const PuttyImportScreen(),
    "the phone's keys": () => const KeysPhoneScreen(),
    "the phone's port forwards": () => const PortForwardsPhoneScreen(),
    "the phone's team": () => const TeamPhoneScreen(),
    "the phone's networks": () => const NetworksMobileScreen(),
    'the email sign-in': () => const EmailAuthScreen(),
    'the choice of sync storage': () => const SyncBackendScreen(),
    'the notifications': () => const NotificationsScreen(),
    'the triggers': () => const TriggersScreen(),
    'the command history': () => const CommandHistoryScreen(),
    'the transcripts': () => const TranscriptsScreen(),
    'the automation guide': () => const AutomationGuideScreen(),
    'the automation history': () => const AutomationHistoryScreen(),
    'the automation wizard': () => const AutomationWizardScreen(),
    'the scheduled tasks': () => const ScheduledTasksScreen(),
    'the workflows': () => const WorkflowListScreen(),
    'the welcome': () => const OnboardingScreen(),
    'the lock screen': () => const SecurityLockScreen(),
  };

  // The 4.0 accessibility pass: the welcome, the
  // notifications, a phone's keys and its team page hold to the checks every
  // screen of the pass does on a phone: every control a screen reader can
  // press has a name, a finger's target is 48 square, and the words read.
  testWidgets("the welcome, the notifications, a phone's keys and team: names, 48 targets, contrast (the 4.0 "
      'accessibility pass)', (tester) async {
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    try {
      for (final name in ['the welcome', 'the notifications', "the phone's keys", "the phone's team"]) {
        await _pump(tester, pages[name]!(),
            scale: 1,
            locale: const Locale('en'),
            problems: problems,
            words: false,
            a11y: () => a11yCheck(tester, computer: false, where: name));
      }
    } finally {
      handle.dispose();
    }
    expect(problems, isEmpty);
  });

  for (final MapEntry(key: name, value: page) in pages.entries) {
    for (final scale in const [1.0, 1.3, 1.5, 2.0]) {
      final words = scale <= 1.3;
      testWidgets('$name, 360 wide, at $scale times the text size, in every language: '
          '${words ? "no word cut in two or at its edge, every word in a font of the app, " : ''}'
          'no words cut at their top and bottom, nothing runs over', (tester) async {
        final problems = <String>[];
        for (final locale in AppLocalizations.supportedLocales) {
          await _pump(tester, page(), scale: scale, locale: locale, problems: problems, words: words);
        }
        expect(problems, isEmpty);
      });
    }
  }
}

/// A host, a key, a snippet, a port forward, a trigger, a command run, an
/// automation run and a workflow, so the screens show rows (all made up).
Future<void> _seed(AppDatabase db) async {
  final now = DateTime(2026, 10, 17, 12);
  await db.into(db.connections).insert(ConnectionsCompanion.insert(
      id: 'c1', label: 'web-01', host: '192.168.10.21', port: const Value(22), createdAt: now, updatedAt: now));
  await db.into(db.identities).insert(IdentitiesCompanion.insert(
      id: 'i1', label: 'deploy key', username: 'alex', authMethod: 'key', keyType: const Value('ssh-ed25519'),
      createdAt: now));
  await db.into(db.snippets).insert(SnippetsCompanion.insert(
      id: 's1', label: 'Disk usage', command: 'df -h', createdAt: now, updatedAt: now));
  await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
      id: 'p1', connectionId: 'c1', type: 'local', bindPort: 8080, remoteHost: 'localhost', remotePort: 80,
      createdAt: now));
  await db.into(db.terminalTriggers).insert(TerminalTriggersCompanion.insert(
      id: 't1', name: 'Build failed', pattern: 'ERROR', createdAt: now));
  await db.into(db.commandHistory).insert(CommandHistoryCompanion.insert(
      id: 'h1', command: 'sudo systemctl restart nginx', createdAt: now));
  await db.into(db.automationHistory).insert(AutomationHistoryCompanion.insert(
      // Past a week, so the row says a date (Russian's the longest), the
      // same whatever the clock says; at noon of the day it said "10 hours
      // ago" from 22:00 and ran over the row at twice the text size.
      id: 'a1', timestamp: DateTime(2026, 9, 28, 12), action: 'execute', connectionId: 'c1', command: 'uptime', success: true,
      elapsedMs: 120));
  await db.into(db.workflows).insert(WorkflowsCompanion.insert(id: 'w1', name: 'Deploy web', createdAt: now));
}

/// [screen] drawn on a phone 360 wide at [scale] times the text size in
/// [locale], in the app's own theme and fonts, over a database with a few
/// rows. Each layout that runs over, each paragraph cut at its top and
/// bottom, each error, and each word cut in two, each name cut at its box's
/// edge and each word in no font of the app where [words], is added to
/// [problems], and the screen is taken down again.
Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  required double scale,
  required Locale locale,
  required List<String> problems,
  required bool words,
  Future<List<String>> Function()? a11y,
}) async {
  ConnectionEditScreen.debugDesktopShell = false;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(onListen: (arguments, events) {}));
  await tester.runAsync(loadShotFonts);
  tester.view.physicalSize = const Size(360, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final theme = BuiltInThemes.getById('default_dark');
  AppColors.applyTheme(theme.colorScheme);
  FlutterSecureStorage.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.runAsync(() => _seed(db));
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
  FlutterError.onError = (details) => found.add(details.exceptionAsString().split(String.fromCharCode(10)).first);
  try {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        // A phone's sizes: touch sized, a finger's 48 (the theme made on the
        // computer running the tests drew a mouse's, and the 48 checks held
        // controls a phone never shows).
        theme: theme.toThemeData(compact: false),
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
    for (final e in find.byType(RichText).evaluate()) {
      final paragraph = e.renderObject;
      if (paragraph is! RenderParagraph || !paragraph.hasSize) continue;
      final cut = cutTopAndBottom(paragraph);
      if (cut != null) found.add('cut at its top and bottom: $cut');
      if (!words) continue;
      found.addAll(wordsCut(paragraph).map((cut) => 'a word cut in two: $cut'));
      final clipped = _clipped(paragraph);
      if (clipped != null) found.add('cut at its edge: $clipped');
      if (paragraph.text.style?.fontFamily == null) {
        found.add('in no font of the app: "${paragraph.text.toPlainText(includeSemanticsLabels: false)}"');
      }
    }
    if (a11y != null) found.addAll(await a11y());
  } finally {
    FlutterError.onError = reported;
  }
  problems.addAll(found.map((p) => '$locale: $p'));
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  router.dispose();
  await tester.pump(const Duration(minutes: 10));
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
