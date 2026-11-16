import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/ui/screens/monitoring/prometheus_config_sheet.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_settings_sheet.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// A phone's sheets that are a question or a form are the app's dialog (the
/// dialog rules of 3.4): a phone's sheet of the shell, with its title,
/// one row of buttons at the bottom that say what they do, a side option as
/// the footer's link, and no tinted tiles. Each of these was a sheet of its
/// own (showModalBottomSheet): a title of its own or none, its buttons under
/// its fields or none at all, Test connection in a header.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<(BuildContext, ProviderContainer)> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    late BuildContext context;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(builder: (ctx) {
          context = ctx;
          return const Scaffold();
        }),
      ),
    ));
    await tester.pumpAndSettle();
    return (context, container);
  }

  /// A test on a phone (Android's look, its sheets).
  void phoneTest(String description, WidgetTesterCallback body) =>
      testWidgets(description, body, variant: TargetPlatformVariant.only(TargetPlatform.android));

  /// The one dialog open, the shell, drawn as a phone's sheet.
  Finder shell() => find.byType(ZestDialogShell);

  Finder inShell(Finder what) => find.descendant(of: shell(), matching: what);

  phoneTest('the ways to sign in: the shell, the ways its choices, the recovery the footer\'s link, Cancel beside it',
      (tester) async {
    final (context, _) = await phone(tester);
    SignInWay? picked = SignInWay.apple;
    var answered = false;
    showSignInWays(context).then((w) {
      picked = w;
      answered = true;
    });
    await tester.pumpAndSettle();
    expect(shell(), findsOneWidget);
    expect(find.byKey(const ValueKey('zest-sheet')), findsOneWidget, reason: "a phone's sheet of the shell");
    expect(inShell(find.text(l10n.profileSignIn)), findsOneWidget);
    // What an account is for, truly: a team, or ZestSSH Cloud; sync through
    // one's own storage needs none (a 4.0 review found it
    // said "Sign in to enable Cloud Sync", as if a free account brought it).
    expect(
        inShell(find.text(
            'Sign in to join a team or to use ZestSSH Cloud. Syncing through your own storage needs no account.')),
        findsOneWidget);
    expect(find.textContaining('enable Cloud Sync'), findsNothing);
    expect(inShell(find.byKey(const ValueKey('sign-in-way-google'))), findsOneWidget);
    // The account's recovery: the footer's side link, not a button among the ways.
    final recover = find.byKey(const ValueKey('sign-in-recover-account'));
    expect(tester.widget<ZestDialogShell>(shell()).tertiaryKey, const ValueKey('sign-in-recover-account'));
    expect(inShell(recover), findsOneWidget);
    expect(find.descendant(of: recover, matching: find.text(l10n.lockoutLink)), findsOneWidget);
    await tester.tap(inShell(find.text(l10n.cancel)));
    await tester.pumpAndSettle();
    expect(answered, isTrue);
    expect(picked, isNull);
    expect(shell(), findsNothing);
  });

  phoneTest("the monitor's data source: the shell, a dot radio each, Prometheus's settings the side link, Done",
      (tester) async {
    final (context, container) = await phone(tester);
    showMonitorDataSourceSheet(context);
    await tester.pumpAndSettle();
    expect(shell(), findsOneWidget);
    expect(inShell(find.text(l10n.monitorDataSource)), findsOneWidget);
    expect(find.byKey(const ValueKey('monitor-source-prometheus-settings')), findsNothing,
        reason: 'no settings to open while SSH is the source');
    await tester.tap(find.byKey(const ValueKey('monitor-source-prometheus')));
    await tester.pumpAndSettle();
    expect(container.read(monitorDataSourceProvider), 'prometheus');
    expect(tester.widget<ZestDialogShell>(shell()).tertiaryAction?.label, l10n.monitorSettingsPrometheusConfig);
    expect(tester.widget<ZestDialogShell>(shell()).primaryAction?.label, l10n.done);
    await tester.tap(find.byKey(const ValueKey('monitor-source-done')));
    await tester.pumpAndSettle();
    expect(shell(), findsNothing);
  });

  phoneTest("Prometheus's settings: the shell, Test connection the side link, Cancel and Save in the footer; no "
      'button left in its body', (tester) async {
    final (context, _) = await phone(tester);
    showPrometheusConfigSheet(context);
    await tester.pumpAndSettle();
    expect(shell(), findsOneWidget);
    final dialog = tester.widget<ZestDialogShell>(shell());
    expect(dialog.title, l10n.monitorSettingsPrometheusConfig);
    expect(dialog.tertiaryAction?.label, l10n.monitorPrometheusTestConnection);
    expect(dialog.secondaryAction?.label, l10n.cancel);
    expect(dialog.primaryAction?.label, l10n.save);
    // Its body's Cancel and Save went to the footer.
    expect(find.byType(FilledButton), findsNothing);
    await tester.tap(find.byKey(const ValueKey('prometheus-save')));
    await tester.pumpAndSettle();
    expect(shell(), findsNothing);
  });

  phoneTest("the terminal's settings: the shell, Done in its footer, no line across it", (tester) async {
    final (context, _) = await phone(tester);
    TerminalSettingsSheet.show(context);
    await tester.pumpAndSettle();
    expect(shell(), findsOneWidget);
    expect(tester.widget<ZestDialogShell>(shell()).title, l10n.terminalSettingsTitle);
    expect(inShell(find.text(l10n.terminalSettingsTitle)), findsOneWidget, reason: 'the title once, the header');
    expect(inShell(find.byType(Divider)), findsNothing);
    await tester.tap(find.byKey(const ValueKey('terminal-settings-done')));
    await tester.pumpAndSettle();
    expect(shell(), findsNothing);
  });
}
