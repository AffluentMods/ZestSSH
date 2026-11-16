import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/sync/zest_server_backend.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';

import '../helpers/fake_device_approvals_server.dart';

/// ZestSSH Cloud as it answers an account: its sync routes refuse an account
/// without Juiced with 403 and the code ENTITLEMENT_REQUIRED, and its
/// entitlement check says whether the account has it.
class _Cloud {
  bool juiced = false;
  final requests = <String>[];

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path.replaceFirst('/v1', '');
    requests.add('${request.method} $path');
    if (path == '/auth/verify-entitlement') return http.Response(jsonEncode({'has_cloud_sync': juiced}), 200);
    if (!juiced && path.startsWith('/sync/')) {
      return http.Response(jsonEncode({'error': 'Cloud Sync entitlement required', 'code': 'ENTITLEMENT_REQUIRED'}), 403);
    }
    if (path == '/sync/status') {
      return http.Response(jsonEncode({'has_data': false, 'version': 0, 'blob_size': 0}), 200);
    }
    return http.Response(jsonEncode({'error': 'Not found'}), 404);
  }
}

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

/// Setting sync up on ZestSSH Cloud with an account without Juiced (two
/// free accounts read "Couldn't reach the sync
/// server" and took it for an outage). ZestSSH Cloud is asked first whether
/// it keeps a copy for the account; without Juiced a dialog says that its
/// storage comes with Juiced and that sync is free with storage of one's own,
/// with a button to each, and nothing is asked of the sync storage.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final said = ErrorCodes.withCode(l10n.syncHostingNeedsJuiced, ErrorCodes.syncHostingNotIncluded);
  late _Cloud cloud;

  setUpAll(() {
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'demo', version: '3.0.0', buildNumber: '1', buildSignature: '');
  });

  setUp(() {
    cloud = _Cloud();
    ZestServerBackend.debugHttpClient = MockClient(cloud.answer);
  });

  tearDown(() => ZestServerBackend.debugHttpClient = null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// [screen] as the app shows it, with the two pages the dialog leads to.
  Widget app(Widget screen) => MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: GoRouter(routes: [
          GoRoute(path: '/', builder: (context, state) => Scaffold(body: screen)),
          GoRoute(path: Routes.upgrade, builder: (context, state) => const Scaffold(body: Text('the upgrade page'))),
          GoRoute(
              path: Routes.syncBackend, builder: (context, state) => const Scaffold(body: Text('the storage page'))),
        ]),
      );

  Future<AppDatabase> prepare(WidgetTester tester, Size size) async {
    // A desktop's sign-in, as the hosted backend reads it without Firebase.
    FlutterSecureStorage.setMockInitialValues({'session_token': 'st-demo'});
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return db;
  }

  Future<void> pumpAccount(WidgetTester tester, {required bool juiced}) async {
    // Narrow: the storage picker is a page of its own there.
    final db = await prepare(tester, const Size(520, 3000));
    final prefs = await SharedPreferences.getInstance();
    final list = MockClient((req) async => http.Response(jsonEncode({'sessions': <Object>[]}), 200));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith((_) => const UserProfile(uid: 'u1', email: 'you@example.com')),
        isCloudSyncProvider.overrideWith((ref) => _Juiced(juiced)),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 15, 12))),
        syncBackendProvider.overrideWithValue(ZestServerBackend(baseUrl: 'https://cloud.test/v1')),
        syncIsBringYourOwnProvider.overrideWithValue(false),
        deviceApprovalsApiProvider.overrideWithValue(FakeApprovalServer().device('desktop')),
        deviceSessionServiceProvider.overrideWithValue(DeviceSessionService(
          api: DeviceSessionsApi(client: list, baseUrl: 'https://cloud.test/v1', bearer: () async => 't'),
          store: DeviceSessionStore(const FlutterSecureStorage()),
          firebaseUid: () => null,
          sessionToken: () async => null,
          saveSessionToken: (_) async {},
          labels: () async => const DeviceLabels(platform: 'windows'),
        )),
      ],
      child: app(const SingleChildScrollView(child: ProfileScreen(embedded: true))),
    ));
    await settle(tester);
  }

  String? message(WidgetTester tester) {
    final shown = find.byKey(const Key('sync-hosting-message'));
    return shown.evaluate().isEmpty ? null : tester.widget<SelectableText>(shown).data;
  }

  group('the account page', () {
    testWidgets('Set up sync without Juiced: said, and Choose storage opens the storage picker', (tester) async {
      await pumpAccount(tester, juiced: false);
      final setUp = find.text(l10n.accountSyncSetUp);
      await tester.ensureVisible(setUp);
      await tester.tap(setUp);
      await settle(tester);
      expect(message(tester), said);
      expect(cloud.requests, ['POST /auth/verify-entitlement']);

      await tester.tap(find.text(l10n.syncHostingChooseStorage));
      await settle(tester);
      expect(find.text('the storage page'), findsOneWidget);
    });

    testWidgets('Get Juiced opens the upgrade page', (tester) async {
      await pumpAccount(tester, juiced: false);
      final setUp = find.text(l10n.accountSyncSetUp);
      await tester.ensureVisible(setUp);
      await tester.tap(setUp);
      await settle(tester);
      await tester.tap(find.text(l10n.profileGetCloudSync));
      await settle(tester);
      expect(find.text('the upgrade page'), findsOneWidget);
    });

    testWidgets('the storage reads Not chosen without Juiced, before a setup and after one refused', (tester) async {
      await pumpAccount(tester, juiced: false);
      expect(find.text(l10n.accountStorageNotChosen), findsOneWidget);
      expect(find.text('ZestSSH Cloud'), findsNothing);
      final setUp = find.text(l10n.accountSyncSetUp);
      await tester.ensureVisible(setUp);
      await tester.tap(setUp);
      await settle(tester);
      expect(message(tester), said);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(message(tester), isNull);
      expect(find.text(l10n.accountStorageNotChosen), findsOneWidget);
    });

    testWidgets('with Juiced the storage is ZestSSH Cloud, and Set up asks it first, then goes on', (tester) async {
      cloud.juiced = true;
      await pumpAccount(tester, juiced: true);
      expect(find.text('ZestSSH Cloud'), findsOneWidget);
      expect(find.text(l10n.accountStorageNotChosen), findsNothing);
      final setUp = find.text(l10n.accountSyncSetUp);
      await tester.ensureVisible(setUp);
      await tester.tap(setUp);
      await settle(tester);
      expect(message(tester), isNull);
      expect(cloud.requests, ['POST /auth/verify-entitlement', 'GET /sync/status']);
    });
  });
}
