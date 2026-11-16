import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';
import 'package:zestssh/ui/screens/profile/recovery_key_screen.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

/// The recovery key screen (3.0): during setup, saving and
/// confirming the key moves the setup steps on; a replacement made from
/// Account and security leaves them exactly where they were, and says the
/// old key stops working.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const storage = FlutterSecureStorage();

  /// Opens the screen in [mode] from a setup that has just chosen its
  /// password (or, with [keySaved], has saved its key too), saves the key,
  /// confirms it, and returns what the screen gave back.
  Future<String?> saveAndConfirm(WidgetTester tester, RecoveryKeyMode mode, {bool keySaved = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    await tester.runAsync(() async {
      final setup = SyncSetupStateService(storage);
      await setup.beginSetup();
      await setup.markPasswordChosen(salt: List<int>.filled(32, 7));
      if (keySaved) await setup.markRecoverySaved(recoverySalt: List<int>.filled(32, 9));
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    String? returned;
    await tester.pumpWidget(ProviderScope(
      overrides: [recordingModeProvider.overrideWith((ref) => false)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  returned = await Navigator.of(context).push<String>(
                    MaterialPageRoute(builder: (_) => RecoveryKeyScreen(mode: mode)),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(l10n.recoveryReplaceScreenNote), mode == RecoveryKeyMode.replace ? findsOneWidget : findsNothing);

    await tester.tap(find.text(l10n.recoveryKeyCopy));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.tap(find.text(l10n.recoveryKeyConfirm));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // Past the "copied" notice's own timer, and the 45 seconds the copied key
    // stays on the clipboard (SecretClipboard: its timer outlives the screen).
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(kSecretClipboardLife);
    return returned;
  }

  testWidgets('during setup: the steps move on to a confirmed key', (tester) async {
    final key = await saveAndConfirm(tester, RecoveryKeyMode.setup);
    expect(key, startsWith('ZEST-'));
    final setup = SyncSetupStateService(storage);
    expect(await tester.runAsync(setup.currentStep), SyncSetupStep.recoveryConfirmed);
    expect(await tester.runAsync(setup.readRecoverySalt), isNotNull);
  });

  testWidgets('a replacement leaves the setup steps where they were', (tester) async {
    final key = await saveAndConfirm(tester, RecoveryKeyMode.replace);
    expect(key, startsWith('ZEST-'));
    final setup = SyncSetupStateService(storage);
    expect(await tester.runAsync(setup.currentStep), SyncSetupStep.passwordChosen);
    expect(await tester.runAsync(setup.readRecoverySalt), isNull);
  });

  testWidgets('a replacement does not confirm a setup that is waiting on its own key', (tester) async {
    final key = await saveAndConfirm(tester, RecoveryKeyMode.replace, keySaved: true);
    expect(key, startsWith('ZEST-'));
    final setup = SyncSetupStateService(storage);
    expect(await tester.runAsync(setup.currentStep), SyncSetupStep.recoverySaved);
    expect(await tester.runAsync(setup.readRecoverySalt), List<int>.filled(32, 9));
  });
}
