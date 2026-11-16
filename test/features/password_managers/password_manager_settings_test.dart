import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_manager_requests.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_settings.dart';
import 'package:zestssh/features/password_managers/widgets/password_ref_editor.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';

/// Settings, Password managers (3.0): where each tool is, found or
/// not; what unlocked Bitwarden forgotten at once; settings kept on this
/// device. Adding from a password manager into an Orchard says others will
/// see the items' names. A question nobody answers counts as no.

class _Runner implements PmProcessRunner {
  @override
  Future<PmProcessResult> run(String executable, List<String> args,
      {Map<String, String> environment = const {}, String? stdin, required Duration timeout}) async {
    if (args.first == 'unlock') return const PmProcessResult(0, 'S', '');
    if (args.first == 'get') return const PmProcessResult(0, 'pw', '');
    return const PmProcessResult(0, '[]', '');
  }
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<(PasswordManagers, SharedPreferences)> pump(WidgetTester tester, Widget child, {bool orchard = false}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (orchard) activeSpaceProvider.overrideWith((ref) => const OrchardSpace('o1')),
        passwordManagersProvider.overrideWith((ref) => PasswordManagers(
              runner: _Runner(),
              settings: () => ref.read(passwordManagerSettingsProvider),
              environment: const {'PATH': '/usr/bin'},
              exists: (p) => p == '/usr/bin/op' || p == '/usr/bin/bw' || p == '/opt/kpx/keepassxc-cli',
              isWindows: false,
              isMacOS: false,
            )),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    return (container.read(passwordManagersProvider)!, prefs);
  }

  testWidgets('each tool, found or not; a path set here is used and kept on this device; forget now', (tester) async {
    final (managers, prefs) = await pump(tester, const PasswordManagerSettingsPanel());
    // Each as the places that need it show it: where it
    // is, or what to do.
    expect(find.text(l10n.pmToolFound('op', '/usr/bin/op')), findsOneWidget);
    expect(find.text(l10n.pmToolFound('bw', '/usr/bin/bw')), findsOneWidget);
    expect(find.text(l10n.pmSetupMissing('keepassxc-cli', 'KeePassXC')), findsOneWidget);

    // Set somewhere else: used, and kept in this device's preferences only.
    final container = ProviderScope.containerOf(tester.element(find.byType(PasswordManagerSettingsPanel)));
    await container
        .read(passwordManagerSettingsProvider.notifier)
        .setToolPath(PasswordManagerKind.keePassXc, '/opt/kpx/keepassxc-cli');
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmToolFound('keepassxc-cli', '/opt/kpx/keepassxc-cli')), findsOneWidget);
    expect(prefs.getString('password_managers_v1'), contains('/opt/kpx/keepassxc-cli'));
    expect(PasswordManagerSettingsNotifier.read(prefs).paths[PasswordManagerKind.keePassXc], '/opt/kpx/keepassxc-cli');

    // Unlocked for this run, then forgotten at once.
    await managers.fetch(PasswordRef.bitwarden('5f2c0e3a-1b2c-4d3e-8f9a-0b1c2d3e4f5a')!,
        ask: (kind, {required again}) async => 'master');
    expect(managers.unlockedForTests, isTrue);
    await tester.tap(find.byKey(const ValueKey('pm-settings-forget')));
    await tester.pump();
    expect(managers.unlockedForTests, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('adding into an Orchard says others will see the items\' names', (tester) async {
    await pump(
        tester,
        Consumer(
            builder: (context, ref, _) =>
                TextButton(onPressed: () => showAddFromPasswordManager(context, ref), child: const Text('add'))),
        orchard: true);
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pm-add-orchard')), findsOneWidget);
    expect(find.text(l10n.pmAddOrchardNote), findsOneWidget);
  });

  testWidgets('a question nobody answers counts as no', (tester) async {
    await pump(tester, const SizedBox());
    final container = ProviderScope.containerOf(tester.element(find.byType(SizedBox).first));
    final asker = PromptedAsker(container.read);
    final approved = asker.approve(PasswordManagerKind.onePassword, const PasswordRefDescription(title: 'x'), 'a@b:22');
    final unlocked = asker.unlock(PasswordManagerKind.bitwarden, again: false);
    final typed = asker.typeOnce(PasswordManagerKind.bitwarden, 'a@b:22');
    for (var i = 0; i < 4; i++) {
      await tester.pump(kPasswordManagerRequestTimeout + const Duration(seconds: 1));
    }
    expect(await approved, isFalse);
    expect(await unlocked, isNull);
    expect(await typed, isNull);
  });
}
