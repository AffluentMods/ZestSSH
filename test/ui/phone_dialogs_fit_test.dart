import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/changelog/whats_new_dialog.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_view.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart' as session;
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/automation/workflow_editor_screen.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/help/contact_support_screen.dart';
import 'package:zestssh/ui/screens/help/report_issue_screen.dart';
import 'package:zestssh/ui/screens/help/setup_guide_screen.dart';
import 'package:zestssh/ui/screens/help/tickets_screen.dart';
import 'package:zestssh/ui/screens/home/widgets/quick_customize_sheet.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/ui/screens/profile/recovery_key_screen.dart';
import 'package:zestssh/ui/screens/security/vault_lock_setup_screen.dart';
import 'package:zestssh/ui/screens/settings/licenses_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/passphrase_prompt_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/server_question_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_settings_sheet.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';

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

Widget _dialog(Widget d) => Scaffold(body: Center(child: d));

session.HostKeyVerification _hostKey(bool changed) => session.HostKeyVerification(
      host: 'web-01.example.com',
      port: 22,
      hostKey: SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List(51)),
      fingerprint: 'SHA256:Kq3v8Xb0YQm4cJ1sT9fH2nW6pL5rZ7aE0dG3uV8iO1k',
      isChanged: changed,
      expectedFingerprint: changed ? 'SHA256:x9Lm2Qp7Rt4Vw1Ys6Bn3Cd8Fg0Hj5Kl2Mn7Pq4St9U' : null,
      completer: Completer<bool>(),
    );

/// More of a phone's screens and dialogs at the text sizes a phone can be set
/// to, in every language, on a phone 360 wide (3.0), as
/// phone_screens_fit_test.dart holds the host editor and the others: at the
/// size the app is drawn at and at 1.3 times, no line breaks inside a word, no
/// name is cut at its box's edge and every word is in a font of the app; at
/// every size, no words are cut at their top and bottom, nothing runs over and
/// nothing fails. The recovery key's confirmation stood beside its button,
/// which left its words a few letters a line in most languages at the size the
/// app is drawn at; the licenses put a license beside the list, 39 pixels wide;
/// the identity editor cut its field names in their 88 pixels; the passphrase
/// prompt's title, and the two prompts' choice to keep what was typed, ran out
/// of their row; so did a setup guide's name beside its badge, the terminal
/// settings sheet's two choices, the buttons at the end of the tickets', the
/// contact form's and the report's rows, What's new's headings, and a
/// ZestButton whose label was longer than its room (in the CSV import); and a
/// setup guide's numbered steps cut their number from 1.5 times.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUpAll(() => PackageInfo.setMockInitialValues(
      appName: 'ZestSSH', packageName: 'demo', version: '3.0.0', buildNumber: '1', buildSignature: ''));
  tearDown(() => ConnectionEditScreen.debugDesktopShell = null);

  final pages = <String, Widget Function()>{
    'the identity editor': () => const IdentityEditScreen(),
    'the snippets': () => const SnippetsScreen(),
    'the workflow editor': () => const WorkflowEditorScreen(),
    'the recovery key': () => const RecoveryKeyScreen(),
    'the device lock setup': () => const VaultLockSetupScreen(),
    'the report of an issue': () => const ReportIssueScreen(),
    'contact support': () => ContactSupportScreen(onDone: (_) {}),
    'the tickets': () => TicketsScreen(onOpen: (_) {}, onContactSupport: () {}),
    'the automation setup guide': () => const SetupGuideScreen(topic: SetupTopic.automation),
    'the snippets setup guide': () => const SetupGuideScreen(topic: SetupTopic.snippets),
    'the Server Monitor setup guide': () => const SetupGuideScreen(topic: SetupTopic.serverMonitor),
    'the licenses': () => const LicensesScreen(version: '3.0.0'),
    "What's new": () => _dialog(const WhatsNewDialog()),
    'the CSV import': () => _dialog(const CsvImportDialog()),
    'the quick customize sheet': () => const Scaffold(body: QuickCustomizeSheet()),
    'the terminal settings sheet': () => const Scaffold(body: TerminalSettingsSheet()),
    'the password prompt': () => _dialog(PasswordPromptDialog(
        request: session.PasswordPromptRequest(
            host: 'web-01.example.com', username: 'deploy', completer: Completer<session.PasswordPromptResult?>()))),
    'the passphrase prompt': () => _dialog(PassphrasePromptDialog(
        request: session.PassphrasePromptRequest(
            host: 'web-01.example.com', username: 'deploy', completer: Completer<session.PassphrasePromptResult?>()))),
    "a new host's key": () => _dialog(HostKeyChangedDialog(verification: _hostKey(false))),
    'a changed host key': () => _dialog(HostKeyChangedDialog(verification: _hostKey(true))),
    "a server's question": () => _dialog(ServerQuestionDialog(
        request: ServerQuestionRequest(
            host: 'bastion.example.com',
            port: 22,
            username: 'deploy',
            question: ServerQuestion(
              name: 'Two-factor',
              instruction: 'Enter the code from your authenticator app.',
              prompts: const [ServerPrompt('Verification code:', echo: false)],
              round: 1,
              withdrawn: Completer<void>().future,
            )))),
  };

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

  group('what changed', () {
    testWidgets('on a phone the licenses are a list, a package opens its license in its place, and back returns to '
        'the list; on a wide page the two stand side by side', (tester) async {
      LicenseRegistry.addLicense(
          () => Stream.value(const LicenseEntryWithLineBreaks(['demo_package'], 'The demo license, its words.')));
      final en = lookupAppLocalizations(const Locale('en'));
      for (final (width, sideBySide) in [(360.0, false), (900.0, true)]) {
        await _pump(tester, const LicensesScreen(version: '3.0.0'), width: width);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        expect(find.text('demo_package'), findsOneWidget, reason: '${width.toInt()} wide');
        await tester.tap(find.text('demo_package'));
        await tester.pump();
        expect(find.text('The demo license, its words.'), findsOneWidget, reason: '${width.toInt()} wide');
        expect(find.text('demo_package'), sideBySide ? findsNWidgets(2) : findsOneWidget,
            reason: sideBySide ? 'the list beside the license' : 'the license in place of the list');
        if (!sideBySide) {
          final back = tester.binding.handlePopRoute();
          await tester.pump();
          await back;
          await tester.pump();
          expect(find.text('The demo license, its words.'), findsNothing);
          expect(find.byType(TextField), findsOneWidget, reason: "the list's search: back is the list");
        }
        expect(en.licensesTitle, isNotEmpty);
        await _unmount(tester);
      }
    });

    testWidgets("a ZestButton's label longer than its room wraps, and the button grows by as much; one that fits is "
        'as tall as it was', (tester) async {
      Future<Size> button(double width) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: Wrap(children: [ZestButton(label: 'Paste from the clipboard', onPressed: () {})]),
              ),
            ),
          ),
        ));
        return tester.getSize(find.byType(ZestButton));
      }

      final wide = await button(600);
      final narrow = await button(140);
      expect(tester.takeException(), isNull, reason: 'nothing runs over');
      expect(narrow.width, lessThanOrEqualTo(140));
      expect(narrow.height, greaterThan(wide.height), reason: 'two lines and more');
      expect(cutTopAndBottom(tester.renderObject<RenderParagraph>(find.text('Paste from the clipboard'))), isNull);
      expect(wide.height, ZestSizing.buttonMedium, reason: 'one line: as tall as before');
    });

    testWidgets('the check finds a word cut in two, and lets an address (a host, an email, an IP address) break '
        'anywhere', (tester) async {
      Future<List<String>> cuts(String words) async {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: SizedBox(width: 90, child: Text(words, style: const TextStyle(fontSize: 14)))),
        ));
        return wordsCut(tester.renderObject<RenderParagraph>(find.text(words)));
      }

      expect(await cuts('Benachrichtigungseinstellungen'), isNotEmpty);
      expect(await cuts('dispositivo-extraordinariamente.'), isNotEmpty, reason: 'a full stop after a word');
      expect(await cuts('deploy@web-01.example.com'), isEmpty);
      expect(await cuts('2001:db8::1:22'), isEmpty);
      expect(await cuts('192.168.10.21:2222'), isEmpty);
    });
  });
}

/// A host, a key and a snippet, so the screens show rows (all made up).
Future<void> _seed(AppDatabase db) async {
  final now = DateTime(2026, 10, 17, 12);
  await db.into(db.connections).insert(ConnectionsCompanion.insert(
      id: 'c1', label: 'web-01', host: '192.168.10.21', port: const Value(22), createdAt: now, updatedAt: now));
  await db.into(db.identities).insert(IdentitiesCompanion.insert(
      id: 'i1', label: 'deploy key', username: 'alex', authMethod: 'key', keyType: const Value('ssh-ed25519'),
      createdAt: now));
  await db.into(db.snippets).insert(SnippetsCompanion.insert(
      id: 's1', label: 'Disk usage', command: 'df -h', createdAt: now, updatedAt: now));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 10));
}

/// [screen] drawn on a phone [width] wide at [scale] times the text size in
/// [locale], in the app's own theme and fonts, over a database with a few
/// rows. With [problems], each layout that runs over, each paragraph cut at
/// its top and bottom, each error, and each word cut in two, each name cut at
/// its box's edge and each word in no font of the app where [words], is added
/// to it, and the screen is taken down again.
Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  double width = 360,
  double scale = 1.0,
  Locale locale = const Locale('en'),
  List<String>? problems,
  bool words = false,
}) async {
  ConnectionEditScreen.debugDesktopShell = false;
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
    if (problems != null) {
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
