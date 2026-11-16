import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/settings/clear_all_data_dialog.dart';

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

/// Clear all data, as the phone's Data page and a computer's settings ask it:
/// with sync set up here it says that it clears this device only and turns sync
/// off on it, and does; the keys' secrets go with them either way (a data
/// review found they stayed, and with sync on everything cleared
/// came back at the next sync).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const storage = FlutterSecureStorage();
  final t0 = DateTime.utc(2026, 10, 1, 9);
  final l10n = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-1', label: 'prod key', username: 'deploy', authMethod: 'publicKey', createdAt: t0, updatedAt: Value(t0)));
    await storage.write(key: 'identity_key_k-1', value: '-----BEGIN OPENSSH PRIVATE KEY----- made up');
    await storage.write(key: 'identity_passphrase_k-1', value: 'made-up passphrase');
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-1', label: 'prod', host: 'prod.example.com', identityId: const Value('k-1'), createdAt: t0, updatedAt: t0));
  });

  tearDown(() => db.close());

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) =>
                TextButton(onPressed: () => confirmClearAllData(context, ref), child: const Text('clear')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('clear'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  Future<void> typeDeleteAndConfirm(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'DELETE');
    await tester.pump();
    // The shell's red main button, in the footer (it was a Material FilledButton).
    await tester.tap(find.byKey(const ValueKey('clear-all-data-go')));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    // The notice that says it is done goes by itself.
    await tester.pump(const Duration(seconds: 4));
  }

  testWidgets('with sync set up here it says so, clears this device only and turns sync off on it', (tester) async {
    await storage.write(key: 'sync_dek', value: 'bWFkZS11cCBzeW5jIGtleQ==');
    await storage.write(key: 'sync_salt', value: 'bWFkZS11cCBzYWx0');
    await open(tester);
    expect(find.text(l10n.settingsClearAllDataConfirmMsg), findsOneWidget);
    expect(find.text(l10n.settingsClearAllDataSyncOn), findsOneWidget);

    await typeDeleteAndConfirm(tester);
    final left = (await tester.runAsync(() async => (
          hosts: (await db.connectionsDao.getAll()).length,
          keys: (await db.identitiesDao.getAll()).length,
          entries: (await storage.readAll()).keys.toSet(),
        )))!;
    expect((left.hosts, left.keys), (0, 0));
    expect(left.entries.where((k) => k.startsWith('identity_')), isEmpty,
        reason: 'the key\'s private key and passphrase stayed in secure storage');
    expect(left.entries.intersection({'sync_dek', 'sync_salt'}), isEmpty,
        reason: 'sync is still set up here, and brings everything back at the next sync');
  });

  testWidgets('without sync it says nothing of sync, and the keys\' secrets go', (tester) async {
    await open(tester);
    expect(find.text(l10n.settingsClearAllDataSyncOn), findsNothing);
    // Until DELETE is typed the red button does nothing (3.4: the shell, not
    // a plain dialog).
    await tester.tap(find.byKey(const ValueKey('clear-all-data-go')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.settingsClearAllDataConfirmTitle), findsOneWidget);
    await typeDeleteAndConfirm(tester);
    final entries = (await tester.runAsync(() async => (await storage.readAll()).keys.toSet()))!;
    expect(entries.where((k) => k.startsWith('identity_')), isEmpty);
  });
}
