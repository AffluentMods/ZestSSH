import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';

/// Account and security, "Your keys are on another device" (3.0):
/// shown only when the account published keys this device does not hold,
/// with Start over, which asks first and then publishes the next version
/// with nothing to vouch for it. Needs --dart-define=ZEST_ORCHARDS=true
/// (the section is part of Teams).
class _KeysServer {
  _KeysServer(this.uid);

  final String uid;
  Map<String, dynamic>? published;
  int resets = 0;
  int reads = 0;
  http.Response? resetAnswer;

  http.Client get client => MockClient((request) async {
        if (request.url.path.endsWith('/keys/me')) {
          reads++;
          if (published == null) return http.Response(jsonEncode({'code': 'no-keys', 'uid': uid}), 404);
          return http.Response(jsonEncode({'uid': uid, ...published!}), 200);
        }
        if (request.url.path.endsWith('/keys/reset') && request.method == 'POST') {
          resets++;
          final refusal = resetAnswer;
          resetAnswer = null;
          if (refusal != null) return refusal;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['key_version'] != (published!['key_version'] as int) + 1) {
            return http.Response(jsonEncode({'code': 'version-conflict'}), 409);
          }
          published = body;
          return http.Response(jsonEncode({'published': true, 'key_version': body['key_version']}), 200);
        }
        return http.Response('{}', 404);
      });
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const uid = 'u1';
  late _KeysServer server;
  late AccountKeys elsewhere;

  setUpAll(() async => elsewhere = await AccountKeys.generate());

  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  bool shows(WidgetTester tester, String message) {
    if (find.text(message).evaluate().isNotEmpty) return true;
    final container = ProviderScope.containerOf(tester.element(find.byType(Navigator).first));
    return container.read(notificationCenterProvider).history.any((n) => n.title == message || n.body == message);
  }

  /// The Account panel, the account's keys published by another device,
  /// and this device's keys [mine] (none unless given).
  Future<AccountKeyStore> pump(WidgetTester tester, {AccountKeys? mine}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    server = _KeysServer(uid);
    server.published = (await tester.runAsync(() => elsewhere.publish(uid)))!.toJson();
    final store = AccountKeyStore(const FlutterSecureStorage());
    if (mine != null) {
      await tester.runAsync(() async =>
          store.write(uid, StoredAccountKeys(StoredKeyState.confirmed, await mine.toSecretJson())));
    }
    final service = AccountKeyService(
      api: AccountKeysApi(client: server.client, baseUrl: 'https://api.test/v1', bearer: () async => 'token'),
      store: store,
      onKeysChanged: () {},
    );
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: SingleChildScrollView(child: ProfileScreen(embedded: true))),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: uid, email: 'you@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 25, 12))),
        accountKeyServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: router,
      ),
    ));
    await settle(tester);
    return store;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  testWidgets('keys published elsewhere and none here: start over, after a yes, with the next version',
      (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped('run with --dart-define=ZEST_ORCHARDS=true');
    final store = await pump(tester);
    expect(find.text(l10n.accountKeysElsewhereTitle), findsOneWidget);
    expect(find.text(l10n.accountKeysElsewhereDesc), findsOneWidget);

    final button = find.byKey(const ValueKey('account-start-over'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await settle(tester);
    expect(find.text(l10n.accountStartOverConfirmTitle), findsOneWidget);
    expect(find.text(l10n.accountStartOverConfirmBody), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.resets, 0, reason: 'declined: nothing sent');

    await tester.tap(button);
    await settle(tester);
    await tester.tap(find.text(l10n.accountStartOverAction).last);
    await settle(tester, rounds: 30);
    expect(server.resets, 1);
    expect(server.published!['key_version'], 2);
    expect(server.published!['endorsement'], isNull);
    final stored = await tester.runAsync(() => store.read(uid));
    expect(stored!.state, StoredKeyState.confirmed);
    expect(stored.version, 2);
    expect(shows(tester, l10n.accountStartOverDone), isTrue);
    // The section is the usual one again, with the new keys.
    expect(find.text(l10n.accountKeysElsewhereTitle), findsNothing);
    expect(find.text(l10n.accountKeysVersion(2)), findsOneWidget);
    await finish(tester);
  });

  testWidgets('keys on this device: nothing to start over from', (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped('run with --dart-define=ZEST_ORCHARDS=true');
    await pump(tester, mine: elsewhere);
    expect(find.text(l10n.accountKeysElsewhereTitle), findsNothing);
    expect(find.byKey(const ValueKey('account-start-over')), findsNothing);
    expect(find.byKey(const ValueKey('account-replace-keys')), findsOneWidget);
    expect(server.reads, 0, reason: 'with the keys here the server is not asked for them');
    await finish(tester);
  });

  testWidgets('the keys moved on meanwhile: said so, and nothing on this device changes', (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped('run with --dart-define=ZEST_ORCHARDS=true');
    final store = await pump(tester);
    server.resetAnswer = http.Response(jsonEncode({'code': 'version-conflict'}), 409);
    final button = find.byKey(const ValueKey('account-start-over'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await settle(tester);
    await tester.tap(find.text(l10n.accountStartOverAction).last);
    await settle(tester, rounds: 30);
    expect(shows(tester, l10n.accountStartOverChanged), isTrue);
    expect(await tester.runAsync(() => store.read(uid)), isNull);
    expect(server.published!['key_version'], 1);
    await finish(tester);
  });
}
