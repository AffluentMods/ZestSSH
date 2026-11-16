import 'dart:async';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/widgets/triggers_view.dart';
import 'package:zestssh/features/notifications/widgets/notification_prefs_sheet.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' as session;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart' show showSnippetCategoryEditor;
import 'package:zestssh/ui/screens/monitoring/monitor_manage_dialog.dart';
import 'package:zestssh/ui/screens/monitoring/prometheus_config_sheet.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart';
import 'package:zestssh/ui/screens/settings/widgets/font_picker.dart';
import 'package:zestssh/ui/screens/settings/widgets/theme_picker.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_variable_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_settings_sheet.dart';

import 'shots_util.dart';

/// Pictures of the dialogs, the third set reworked in 3.4 (the app's dialog
/// rules): the four follow-ups that opened a dialog
/// over a dialog, at a computer's width, and a dozen of a phone's sheets, in
/// English, dark and light, with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/dialogs_batch3_shots_test.dart
///
/// Pictures land in build/shots/dialogs-batch3/. Every name, host and key on
/// them is made up. (The pictures from before were made from master 147799b7
/// with this test, the sheets that a phone opened by a branch of its own
/// reached by a stand-in for the platform, and the pickers opened as the
/// settings did then.)
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

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<AppDatabase> _seeded() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final made = DateTime(2026, 1, 1);
  await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-web', name: 'Web', createdAt: made));
  const groups = {'web-01': 'g-web', 'web-02': 'g-web'};
  var i = 0;
  for (final label in ['web-01', 'web-02', 'db-primary', 'cache-01', 'monitoring']) {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-$label',
          label: label,
          host: '$label.example.internal',
          groupId: Value(groups[label]),
          sortOrder: Value(i++),
          createdAt: made,
          updatedAt: made,
        ));
  }
  return db;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late WidgetRef ref;

  Future<(GlobalKey, BuildContext)> shown(WidgetTester tester, String themeId,
      {bool phone = false, bool recording = false, Widget? page}) async {
    L10nGlobal.update(l10n);
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = phone ? const Size(390, 844) : const Size(960, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'automation_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    final db = (await tester.runAsync(_seeded))!;
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      recordingModeProvider.overrideWith((ref) => recording),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      isProProvider.overrideWith((ref) => _Pro()),
    ]);
    addTearDown(container.dispose);
    await tester.runAsync(() => container.read(automationKeysProvider.notifier).ready);
    final key = GlobalKey();
    late BuildContext context;
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Consumer(builder: (ctx, r, _) {
            context = ctx;
            ref = r;
            return Scaffold(body: page);
          }),
        ),
      ),
    ));
    await settle(tester);
    return (key, context);
  }

  Future<void> snap(WidgetTester tester, GlobalKey key, String name) async {
    await settle(tester);
    await saveShot(tester, key, 'dialogs-batch3/$name', pixelRatio: 2);
  }

  /// Closes whatever is open, from the top: back as a person would.
  Future<void> closeAll(WidgetTester tester, BuildContext context) async {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    await settle(tester);
  }

  Future<void> run(WidgetTester tester, Future<void> Function() body, {bool phone = false}) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = phone ? TargetPlatform.android : TargetPlatform.windows;
    try {
      await body();
      await tester.pump(const Duration(seconds: 5));
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }

  session.PasswordPromptRequest prompt() => session.PasswordPromptRequest(
      host: 'web-01.example.com', username: 'deploy', completer: Completer<session.PasswordPromptResult?>());

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';

    testWidgets('a dialog over a dialog, now in place ($tag)', (tester) async {
      if (!shotsEnabled) return;
      await run(tester, () async {
        // 1. Recording mode asks before a password shows.
        var (key, context) = await shown(tester, themeId, recording: true);
        unawaited(showPasswordPrompt(context, prompt()));
        await settle(tester);
        await tester.enterText(find.byType(EditableText).first, 'made-up-pass');
        await tester.tap(find.byTooltip(l10n.zestDialogShow).first);
        await snap(tester, key, 'r4-01-reveal-gate-$tag');
        await closeAll(tester, context);

        // 2. Create API key: a specific host.
        (key, context) = await shown(tester, themeId, page: const TriggersView());
        await tester.tap(find.text(l10n.zestAutoCreateApiKey));
        await settle(tester);
        await tester.enterText(find.byType(EditableText).first, 'deploy box');
        await tester.tap(find.text(l10n.zestAutoScopeSpecific));
        await snap(tester, key, 'r4-02-api-key-host-$tag');
        await closeAll(tester, context);

        // 3. Notification settings: turning the reachability checks on.
        (key, context) = await shown(tester, themeId);
        showNotificationPrefsSheet(context);
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('settings-reach-checks')));
        await snap(tester, key, 'r4-03-reach-checks-$tag');
        await closeAll(tester, context);

        // 4. A snippet category's custom colour.
        (key, context) = await shown(tester, themeId);
        unawaited(showSnippetCategoryEditor(context: context, name: 'Deploy', meta: null));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('zest-color-picker-custom-entry')));
        await snap(tester, key, 'r4-04-custom-colour-$tag');
        await closeAll(tester, context);
      });
    });

    testWidgets("a phone's sheets ($tag)", (tester) async {
      if (!shotsEnabled) return;
      await run(tester, phone: true, () async {
        var (key, context) = await shown(tester, themeId, phone: true);

        showNotificationPrefsSheet(context);
        await snap(tester, key, 'phone-01-notifications-$tag');
        await closeAll(tester, context);

        unawaited(showMonitorManageServers(context));
        await snap(tester, key, 'phone-02-monitor-hosts-$tag');
        await closeAll(tester, context);

        showMonitorDataSourceSheet(context);
        await snap(tester, key, 'phone-03-monitor-source-$tag');
        await closeAll(tester, context);

        showPrometheusConfigSheet(context);
        await snap(tester, key, 'phone-04-prometheus-$tag');
        await closeAll(tester, context);

        unawaited(showSignInWays(context));
        await snap(tester, key, 'phone-05-sign-in-ways-$tag');
        await closeAll(tester, context);

        TerminalSettingsSheet.show(context);
        await snap(tester, key, 'phone-06-terminal-settings-$tag');
        await closeAll(tester, context);

        unawaited(showVariableInputDialog(
            context: context,
            variables: const ['SERVICE', 'LINES'],
            snippetLabel: 'Tail a service log',
            command: r'journalctl -u ${SERVICE} -n ${LINES} --no-pager'));
        await snap(tester, key, 'phone-07-snippet-values-$tag');
        await closeAll(tester, context);

        unawaited(showThemePicker(context, ref));
        await snap(tester, key, 'phone-08-theme-picker-$tag');
        await closeAll(tester, context);

        unawaited(showFontPicker(context));
        await snap(tester, key, 'phone-09-font-picker-$tag');
        await closeAll(tester, context);

        // Recording mode asks before a password shows (a sheet over a sheet before).
        (key, context) = await shown(tester, themeId, phone: true, recording: true);
        unawaited(showPasswordPrompt(context, prompt()));
        await settle(tester);
        await tester.enterText(find.byType(EditableText).first, 'made-up-pass');
        await tester.tap(find.byTooltip(l10n.zestDialogShow).first);
        await snap(tester, key, 'phone-10-reveal-gate-$tag');
        await closeAll(tester, context);

        // Turning the reachability checks on, from the notification settings.
        (key, context) = await shown(tester, themeId, phone: true);
        showNotificationPrefsSheet(context);
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('settings-reach-checks')));
        await snap(tester, key, 'phone-11-reach-checks-$tag');
        await closeAll(tester, context);

        // A snippet category's custom colour, on a phone.
        (key, context) = await shown(tester, themeId, phone: true);
        unawaited(showSnippetCategoryEditor(context: context, name: 'Deploy', meta: null));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('zest-color-picker-custom-entry')));
        await snap(tester, key, 'phone-12-custom-colour-$tag');
        await closeAll(tester, context);
      });
    });
  }
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}
