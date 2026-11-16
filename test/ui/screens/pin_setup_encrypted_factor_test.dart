import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/ui/screens/security/pin_setup_screen.dart';

/// Setting the PIN while "Encrypt data at rest" is on (3.0).
/// The lock screen never offers the device's own unlock in
/// that state (only the PIN opens the data), yet the PIN setup offered
/// "Also enable Windows Hello / Touch ID / biometrics", on by default, and
/// then said "Your PIN and biometrics are now active". Now it is not offered
/// there, one line says why, and the PIN alone is saved as the way in.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<_Lock> pump(WidgetTester tester, {required bool encrypted}) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({
      'security_lock_enabled': true,
      'encrypting_lock_enabled': encrypted,
    });
    final prefs = await SharedPreferences.getInstance();
    final lock = _Lock();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      securityLockServiceProvider.overrideWithValue(lock),
      vaultSlotServiceProvider.overrideWithValue(_Vault(enabled: encrypted)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: PinSetupScreen()),
      ),
    ));
    await tester.pumpAndSettle();
    // A PIN exists and the lock is on: the current one is asked first.
    await tester.enterText(find.byType(TextField).first, '2468');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    return lock;
  }

  Future<void> choose(WidgetTester tester, String pin) async {
    expect(tester.widget<TextField>(find.byKey(const ValueKey('pin-setup-pin'))).decoration?.hintText, isNotNull);
    await tester.enterText(find.byType(TextField).first, pin);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    // The confirm step opens empty: no dots in it that read as the PIN of
    // the first step, typed in already (found by the screenshot
    // tests).
    final confirm = tester.widget<TextField>(find.byKey(const ValueKey('pin-setup-confirm')));
    expect(confirm.decoration?.hintText, isNull);
    expect(confirm.controller?.text, isEmpty);
    await tester.enterText(find.byType(TextField).first, pin);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  // The factor's name on the computer the test runs on, as the screen names it.
  final factor = Platform.isWindows
      ? l10n.pinSetupBiometricFactorWindowsHello
      : Platform.isMacOS
          ? l10n.pinSetupBiometricFactorTouchId
          : l10n.pinSetupBiometricFactorGeneric;

  testWidgets('with the data encrypted, the factor is not offered, a line says why, and the PIN alone is saved',
      (tester) async {
    final lock = await pump(tester, encrypted: true);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text(l10n.pinSetupAlsoEnableFactor(factor)), findsNothing);
    expect(find.text(l10n.docCheckPinFactorOffEncrypted(factor)), findsOneWidget);

    await choose(tester, '7531');
    expect(lock.methods, [SecurityLockMethod.pin]);
    expect(find.text(l10n.pinSetupSuccessPinOnly), findsOneWidget);
    expect(find.text(l10n.pinSetupSuccessWithFactor(factor)), findsNothing);
  });

  testWidgets('with the data not encrypted, the factor is offered, on, and saved with the PIN', (tester) async {
    final lock = await pump(tester, encrypted: false);
    expect(find.text(l10n.pinSetupAlsoEnableFactor(factor)), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
    expect(find.text(l10n.docCheckPinFactorOffEncrypted(factor)), findsNothing);

    await choose(tester, '7531');
    expect(lock.methods, [SecurityLockMethod.both]);
    expect(find.text(l10n.pinSetupSuccessWithFactor(factor)), findsOneWidget);
  });

  // On a device, step 1 showed a push pin (Lucide's
  // "pin", a map pin's cousin, not a PIN) and step 2 a lock. One lock on both.
  testWidgets('choosing and confirming the PIN both show the lock, never a push pin', (tester) async {
    await pump(tester, encrypted: false);
    expect(find.byIcon(LucideIcons.lock), findsOneWidget, reason: 'choose');
    expect(find.byIcon(LucideIcons.pin), findsNothing);
    await tester.enterText(find.byType(TextField).first, '7531');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pin-setup-confirm')), findsOneWidget);
    expect(find.byIcon(LucideIcons.lock), findsOneWidget, reason: 'confirm');
    expect(find.byIcon(LucideIcons.pin), findsNothing);
  });
}

class _Lock implements SecurityLockService {
  final methods = <SecurityLockMethod>[];

  @override
  bool get isLockedOut => false;
  @override
  int get remainingLockoutSeconds => 0;
  @override
  Future<bool> verifyPin(String pin) async => true;
  @override
  Future<bool> hasPinConfigured() async => true;
  @override
  Future<void> setPin(String pin) async {}
  @override
  Future<void> setLockMethod(SecurityLockMethod method) async => methods.add(method);
  @override
  Future<SecurityLockMethod> getLockMethod() async => SecurityLockMethod.both;
  @override
  Future<bool> isBiometricAvailable() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vault implements VaultSlotService {
  _Vault({required this.enabled});
  final bool enabled;

  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<SecretKey> unlockVaultKey({String? pin, String? masterPassword, String? recoveryKey}) async =>
      SecretKey(List.filled(32, 7));
  @override
  Future<void> changePin(SecretKey vaultKey, String newPin) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
