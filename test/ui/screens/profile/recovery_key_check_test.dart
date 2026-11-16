// Real Argon2id key derivation (the weakest profile deriveKey accepts); allow
// for a machine busy with the whole suite.
@Timeout(Duration(minutes: 4))
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/services/sync/sync_manifest.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/profile/recovery_key_check.dart';

import '../../../helpers/memory_store_backend.dart';

/// Checking a recovery key from the account's security settings (3.0,
/// recovery kit), against a real store and real key derivation: the kit's key
/// is confirmed; a mistyped one is said so in the dialog, which stays open to
/// type again; a key for another vault, or none stored, offers a new key; and
/// something that is not a key at all is caught before anything is derived.

const kitKey = 'ZEST-HJKM-NPQR-STUV-WXYZ-2345';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  // The account's own parameters: neither this build's default nor the
  // legacy set, so a check that did not derive under them would fail.
  const params = {'memory': 65536, 'iterations': 4, 'parallelism': 4};

  late SecretKey dek;
  late Uint8List storeBytes;
  late Uint8List noRecoveryBytes;

  setUpAll(() async {
    dek = SyncService.generateDek();
    final salt = SyncService.generateSalt();
    final recoverySalt = RecoveryKeyService.generateRecoverySalt();
    final kek = await SyncService.deriveKey(RecoveryKeyService.normalize(kitKey), recoverySalt, params: params);
    final encrypted = await SyncService.encrypt(const {'connections': []}, dek, salt);
    final wrapped = await SyncService.wrapDek(dek, kek);
    SyncManifest manifest({required bool recovery}) => SyncManifest(
          version: 1,
          updatedAt: DateTime.utc(2026, 9, 25),
          salt: salt,
          argon2Params: params,
          encryptedData: encrypted,
          wrappedDekRecovery: recovery ? wrapped : null,
          recoverySalt: recovery ? recoverySalt : null,
        );
    storeBytes = manifest(recovery: true).toBytes();
    noRecoveryBytes = manifest(recovery: false).toBytes();
  });

  late MemoryStoreBackend backend;
  late int madeNew;

  Future<void> open(WidgetTester tester, {required Uint8List store, List<int>? deviceDek, bool recording = false}) async {
    madeNew = 0;
    backend = MemoryStoreBackend(MemoryStore()..bytes = store);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final mine = deviceDek ?? await tester.runAsync(() => dek.extractBytes()) ?? const <int>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => recording),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => runRecoveryKeyCheck(
                context,
                ref,
                backend: backend,
                deviceDek: mine,
                onMakeNew: () async => madeNew++,
              ),
              child: const Text('check'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();
    if (!recording) expect(find.text(l10n.recoveryCheckTitle), findsOneWidget);
  }

  /// Types [typed] and presses Check, letting the real derivation run.
  Future<void> check(WidgetTester tester, String typed, {required Finder until}) async {
    await tester.enterText(find.byType(TextField), typed);
    await tester.pump();
    await tester.tap(find.text(l10n.recoveryCheckAction).last);
    await tester.runAsync(() async {
      for (var i = 0; i < 600 && until.evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('the kit\'s key, typed back any way, is confirmed', (tester) async {
    await open(tester, store: storeBytes);
    await check(tester, ' zest hjkm npqr stuv-wxyz 2345 ', until: find.text(l10n.recoveryCheckWorksTitle));
    expect(find.text(l10n.recoveryCheckWorksTitle), findsOneWidget);
    expect(find.text(l10n.recoveryCheckWorksBody), findsOneWidget);
    await tester.tap(find.text(l10n.close));
    await tester.pumpAndSettle();
    expect(madeNew, 0);
  });

  testWidgets('a mistyped key is said so and can be typed again; something not a key is caught first', (tester) async {
    await open(tester, store: storeBytes);
    // Not a key at all: caught at once, nothing derived.
    await tester.enterText(find.byType(TextField), 'my password');
    await tester.pump();
    await tester.tap(find.text(l10n.recoveryCheckAction).last);
    await tester.pump();
    expect(find.text(l10n.recoveryCheckFormat), findsOneWidget);
    // A real-looking key that is not this one.
    await check(tester, 'ZEST-HJKM-NPQR-STUV-WXYZ-2346', until: find.text(l10n.recoveryCheckWrong));
    expect(find.text(l10n.recoveryCheckWrong), findsOneWidget);
    expect(find.text(l10n.recoveryCheckTitle), findsOneWidget, reason: 'still open, to type again');
    // Then the right one.
    await check(tester, kitKey, until: find.text(l10n.recoveryCheckWorksTitle));
    expect(find.text(l10n.recoveryCheckWorksTitle), findsOneWidget);
  });

  testWidgets('a key for another vault offers a new key', (tester) async {
    await open(tester, store: storeBytes, deviceDek: List<int>.generate(32, (i) => i));
    await check(tester, kitKey, until: find.text(l10n.recoveryCheckOtherTitle));
    expect(find.text(l10n.recoveryCheckOtherTitle), findsOneWidget);
    expect(find.text(l10n.recoveryCheckOtherBody), findsOneWidget);
    expect(find.text(l10n.recoveryCheckNoneTitle), findsNothing);
    await tester.tap(find.text(l10n.recoveryCheckMakeNew));
    await tester.pumpAndSettle();
    expect(madeNew, 1);
  });

  testWidgets('while the screen is being recorded, it asks first; declining types nothing', (tester) async {
    await open(tester, store: storeBytes, recording: true);
    expect(find.text(l10n.recModeRevealTitle), findsOneWidget);
    expect(find.text(l10n.recoveryCheckTitle), findsNothing, reason: 'no field to type the key into yet');
    await tester.tap(find.text(l10n.recModeRevealCancel));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recoveryCheckTitle), findsNothing);
    expect(madeNew, 0);
  });

  testWidgets('with no key stored, it says so and offers one; closing leaves things as they are', (tester) async {
    await open(tester, store: noRecoveryBytes);
    await check(tester, kitKey, until: find.text(l10n.recoveryCheckNoneTitle));
    expect(find.text(l10n.recoveryCheckNoneTitle), findsOneWidget);
    expect(find.text(l10n.recoveryCheckNoneBody), findsOneWidget);
    expect(find.text(l10n.recoveryCheckOtherTitle), findsNothing);
    await tester.tap(find.text(l10n.close));
    await tester.pumpAndSettle();
    expect(madeNew, 0);
    expect(backend.store.counter, 0, reason: 'nothing was written');
  });
}

