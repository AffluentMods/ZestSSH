import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/command_history/command_history_screen.dart';
import 'package:zestssh/ui/screens/desktop/widgets/automation_view.dart';
import 'package:zestssh/ui/screens/home/widgets/more_tab.dart';
import 'package:zestssh/utils/platform_utils.dart';

import '../helpers/last_line.dart';
import '../helpers/quick_wins_fixture.dart';
import '../visual/shots_util.dart';

/// No word alone on the last line, in the app's own fonts, at the widths the
/// design review saw it ("Orphan words"): a phone's More
/// ("away") and command history ("saved."), and the add-snippet question of
/// a computer's Automation ("as:"). The team's places are checked with their
/// own fixtures: event export (team_export_view_test), the broadcast pop-over
/// (broadcast_controls_test), ending access (team_access_view_test) and the
/// offline pass (pass_handover_dialogs_test).
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  mockQuickWinsChannels();
  final l10n = lookupAppLocalizations(const Locale('en'));
  // The phone the design review's pictures were taken on.
  const phone = Size(390, 844);

  /// [body] on a phone, as the app draws it there, in the app's fonts.
  Future<void> onPhone(WidgetTester tester, Widget body) async {
    await tester.runAsync(loadShotFonts);
    await pumpQuickWins(tester, body, phone);
  }

  for (final (name, body, words) in [
    ("More, Networks' line", const Scaffold(body: MoreTab()), l10n.phoneMoreNetworksDesc),
    ('Command history, recording off', const CommandHistoryScreen(), l10n.cmdhRecordingOffBanner),
  ]) {
    testWidgets('a phone 390 wide: $name keeps its last two words together', (tester) async {
      debugTouchLayout = true;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await onPhone(tester, body);
        expectNoOrphan(tester, findWords(words), reason: name);
        await unpumpQuickWins(tester);
      } finally {
        debugTouchLayout = null;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('a computer 1440 wide: the add-snippet question keeps "added as:" together, the command as it is',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.runAsync(loadShotFonts);
      L10nGlobal.update(l10n);
      final theme = BuiltInThemes.getById('default_light');
      AppColors.applyTheme(theme.colorScheme);
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({'automation_enabled': true});
      final prefs = await SharedPreferences.getInstance();
      // No snippets yet: the template asks to add the one it runs.
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          redactionFleetRegistrar.overrideWith((ref) {}),
          isProProvider.overrideWith((ref) => _Pro()),
        ],
        child: MaterialApp(
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: AutomationView()),
        ),
      ));
      await _settle(tester);
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('automation-template-updatePackages')), matching: find.text(l10n.autoTplUse)));
      await _settle(tester);
      final body = find.descendant(of: find.byKey(const ValueKey('zest-confirm-body')), matching: find.byType(Text)).first;
      final said = tester.widget<Text>(body).data!;
      final command = said.substring(said.indexOf('\n') + 1);
      expect(command, contains('apt-get'));
      expect(command, isNot(contains('\u00A0')), reason: 'a command is shown as it runs');
      expectNoOrphan(tester, body, reason: 'the words over the command', firstParagraph: true);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
