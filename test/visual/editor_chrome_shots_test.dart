import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_button_group.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/ui/widgets/zest_pane_footer.dart';

import 'shots_util.dart';

/// Pictures of the editors' chrome on a computer (the header with its close
/// button, the footer with the tests and Save): the docked host editor and a
/// detail pane on the shared scaffold, in a dark and a light theme, with the
/// real fonts. Made-up hosts only:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/editor_chrome_shots_test.dart
///
/// Pictures land in build/shots/editor-chrome/.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _computer = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final themeId in const ['default_dark', 'default_light']) {
    testWidgets('the docked host editor, $themeId', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
      messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
          MockStreamHandler.inline(onListen: (arguments, events) {}));
      tester.view.physicalSize = const Size(700, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = BuiltInThemes.getById(themeId);
      AppColors.applyTheme(theme.colorScheme);
      SharedPreferences.setMockInitialValues({'os_kind_web': 'ubuntu'});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final now = DateTime.utc(2026, 10, 22);
      await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g', name: 'Lab', createdAt: now));
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'web',
            label: 'web-01',
            host: '192.168.10.21',
            port: const Value(22),
            protocol: const Value('ssh'),
            groupId: const Value('g'),
            createdAt: now,
            updatedAt: now,
          ));
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        isProProvider.overrideWith((ref) => _Pro(true)),
      ]);
      addTearDown(container.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.toThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(body: ConnectionEditScreen(inDialog: true, connectionId: 'web', onClose: () {})),
          ),
        ),
      ));
      await settle(tester);
      await saveShot(tester, key, 'editor-chrome/host-editor-$themeId');
      // With a change: Save turns on.
      await tester.enterText(find.widgetWithText(TextField, 'web-01').first, 'web-02');
      await settle(tester);
      await saveShot(tester, key, 'editor-chrome/host-editor-dirty-$themeId');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
      plainShadows();
    }, skip: !shotsEnabled, variant: _computer);

    testWidgets('the footer: wide, narrow, a test running, $themeId', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      tester.view.physicalSize = const Size(700, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = BuiltInThemes.getById(themeId);
      AppColors.applyTheme(theme.colorScheme);
      final l10n = lookupAppLocalizations(const Locale('en'));
      Widget footer(double width, {bool running = false, bool dirty = true}) => SizedBox(
            width: width,
            child: ZestPaneFooter(
              leading: ZestButtonGroup(items: [
                ZestButtonGroupItem(
                  label: l10n.zestHostTestReachability,
                  icon: LucideIcons.radio,
                  isLoading: running,
                  onPressed: running ? null : () {},
                ),
                ZestButtonGroupItem(
                  label: l10n.zestHostTestFull,
                  icon: LucideIcons.lock,
                  onPressed: running ? null : () {},
                ),
              ]),
              onSave: () {},
              saveEnabled: dirty,
              saveLabel: l10n.connectionSaveChanges,
            ),
          );
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                footer(700, running: true),
                const SizedBox(height: 16),
                // The editor at its least width, less its handle.
                footer(454, dirty: false),
              ],
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      await saveShot(tester, key, 'editor-chrome/footer-states-$themeId', pixelRatio: 2);
      plainShadows();
    }, skip: !shotsEnabled, variant: _computer);

    testWidgets('a detail pane on the shared scaffold, $themeId', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      tester.view.physicalSize = const Size(620, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = BuiltInThemes.getById(themeId);
      AppColors.applyTheme(theme.colorScheme);
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: ZestDetailScaffold(
              title: 'deploy-key',
              subtitle: 'SHA256:3q2+7w3lQ0a1mXk9',
              subtitleMono: true,
              icon: LucideIcons.keyRound,
              badge: const ZestDetailBadge(label: 'ED25519'),
              isDirty: true,
              onSave: () {},
              onClose: () {},
              footerLeading: ZestButton(label: 'Delete', variant: ZestButtonVariant.danger, onPressed: () {}),
              body: const SizedBox(height: 200),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await saveShot(tester, key, 'editor-chrome/detail-pane-$themeId');
      plainShadows();
    }, skip: !shotsEnabled, variant: _computer);
  }
}
