import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';

/// Whether the account has Juiced, as the app holds it.
class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced(super.state);

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> forceRefresh() async => state;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Account, the sync card's Storage row (3.0): someone signed in
/// on ZestSSH Cloud with Juiced, with sync not set up yet, has their
/// storage: ZestSSH Cloud, where Set up goes. It used to say "Not chosen".
/// A guest, who cannot reach ZestSSH Cloud, still reads "Not chosen", and so
/// does an account without Juiced, for which ZestSSH Cloud keeps no copy
/// (free accounts took its refusal for an
/// outage).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<void> pumpAccount(WidgetTester tester, {required bool signedIn, bool juiced = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith(
            (_) => signedIn ? const UserProfile(uid: 'u1', email: 'you@example.com') : null),
        isCloudSyncProvider.overrideWith((ref) => _Juiced(juiced)),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 25, 12))),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: ProfileScreen(embedded: true))),
      ),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('signed in with Juiced, sync not set up yet: ZestSSH Cloud', (tester) async {
    await pumpAccount(tester, signedIn: true, juiced: true);
    expect(find.text('ZestSSH Cloud'), findsOneWidget);
    expect(find.text(l10n.accountStorageNotChosen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });

  testWidgets('signed in without Juiced: not chosen, as its storage comes with Juiced', (tester) async {
    await pumpAccount(tester, signedIn: true);
    expect(find.text(l10n.accountStorageNotChosen), findsOneWidget);
    expect(find.text('ZestSSH Cloud'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });

  testWidgets('a guest: not chosen', (tester) async {
    await pumpAccount(tester, signedIn: false);
    expect(find.text(l10n.accountStorageNotChosen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  });
}
