import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_tester.dart';
import 'package:zestssh/features/hosts/widgets/host_network_overrides_section.dart' show EffectiveTestConfig;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';

import '../../services/ftps/fake_ftps_native.dart';

/// The host editor's Test buttons on an FTPS host (3.4): reach (the
/// port answers), TLS (the handshake and the certificate's check, with no user
/// name or password), and the sign-in with a listing of the first folder.
/// Credentials go only to a server whose certificate is trusted: the kept one,
/// or a new one accepted for the test alone (not kept); one that is not the
/// kept one stops the test before anything is sent. A local port stands in for
/// the server's (for the TCP step), the fake native layer for FTPS; all made up.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  late ServerSocket door;
  late AppDatabase db;
  late BuildContext at;
  late WidgetRef widgetRef;

  setUp(() async {
    door = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    door.listen((s) => s.destroy());
  });
  tearDown(() => door.close());

  Future<void> host(WidgetTester tester, {String? password = 'made-up-password'}) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'identity_password_k1': ?password});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() => db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'k1',
          label: 'demo',
          username: 'demo',
          authMethod: 'password',
          createdAt: DateTime(2026, 11, 6),
        )));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        connectionTimeoutProvider.overrideWith((ref) => 5),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            at = context;
            widgetRef = ref;
            return const SizedBox();
          }),
        ),
      ),
    ));
  }

  HostTester ftpsTester(FakeFtpsNative native) => HostTester(
        context: at,
        ref: widgetRef,
        addressChosenHere: (_) async => false,
        wouldGoUnwatched: (db, {hostId, keyId}) async => false,
        requireCratesOpen: (db, {hostId, keyId}) async {},
        ftps: true,
        ftpsNative: native,
      );

  EffectiveTestConfig cfg() => EffectiveTestConfig(host: '127.0.0.1', port: door.port, identityKeyId: 'k1');

  /// Runs [test] to its end, answering the certificate question with [trust] where it is asked.
  Future<HostTestResult?> run(WidgetTester tester, Future<HostTestResult?> Function() test, {bool? trust}) async {
    HostTestResult? result;
    var done = false;
    // Started here; the real socket's events are let in by runAsync, the rest by pump.
    unawaited(test().then((r) {
      result = r;
      done = true;
    }));
    var asked = false;
    for (var i = 0; i < 100 && !done; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      if (trust != null && !asked && find.byKey(const ValueKey('host-test-trust')).evaluate().isNotEmpty) {
        asked = true;
        expect(find.text(en.ftpsNewCertificateTitle), findsOneWidget);
        expect(find.textContaining('AB:AB:AB'), findsOneWidget);
        await tester.tap(find.byKey(trust ? const ValueKey('host-test-trust') : const ValueKey('host-test-cancel')));
        await tester.pump();
      }
    }
    expect(done, isTrue);
    if (trust != null) expect(asked, isTrue, reason: 'the certificate was asked about');
    return result;
  }

  List<Map<String, Object?>> signIns(FakeFtpsNative n) =>
      [for (final r in n.requests) if (r['op'] == 'connect' && r['login'] != false) r];

  testWidgets('Test reachability: the port and TLS, and no user name or password sent', (tester) async {
    await host(tester);
    final native = FakeFtpsNative();
    final result = await run(tester, () => ftpsTester(native).reachability(cfg()));
    expect(result!.success, isTrue, reason: result.message);
    expect(result.message, contains('TLS works'));
    expect(result.message, contains('not trusted yet'), reason: 'a new certificate is said, not asked about');
    final probe = native.requests.single;
    expect((probe['op'], probe['login'], probe['user'], probe['password']), ('connect', false, '', ''));
  });

  testWidgets('Test connection with the kept certificate: TLS, then the sign-in and a listing', (tester) async {
    await host(tester);
    final native = FakeFtpsNative();
    await tester.runAsync(() => KnownHostsService(db.knownHostsDao)
        .trustCertificate('127.0.0.1', door.port, sha256Hex: native.certificateSha, der: [1]));
    final result = await run(tester, () => ftpsTester(native).fullConnection(cfg()));
    expect(result!.success, isTrue, reason: result.message);
    expect(result.message, startsWith('Connected: TCP'));
    expect(native.requests.first['login'], false, reason: 'TLS checked before anything is sent');
    final signIn = signIns(native).single;
    expect((signIn['user'], signIn['password'], signIn['pinned']), ('demo', 'made-up-password', native.certificateSha));
    expect(native.requests.where((r) => r['op'] == 'list'), isNotEmpty);
  });

  testWidgets('a new certificate is asked about, used for this test alone, and not kept', (tester) async {
    await host(tester);
    final native = FakeFtpsNative();
    final result = await run(tester, () => ftpsTester(native).fullConnection(cfg()), trust: true);
    expect(result!.success, isTrue, reason: result.message);
    final signIn = signIns(native).single;
    expect((signIn['pinned'], signIn['allowAuthority']), (native.certificateSha, false));
    expect(await tester.runAsync(() => KnownHostsService(db.knownHostsDao).pinnedCertificate('127.0.0.1', door.port)),
        isNull);
  });

  testWidgets('a declined certificate sends nothing', (tester) async {
    await host(tester);
    final native = FakeFtpsNative();
    final result = await run(tester, () => ftpsTester(native).fullConnection(cfg()), trust: false);
    expect(result!.success, isFalse);
    expect(signIns(native), isEmpty);
  });

  testWidgets('a certificate that is not the kept one stops the test before anything is sent', (tester) async {
    await host(tester);
    final native = FakeFtpsNative();
    await tester.runAsync(() => KnownHostsService(db.knownHostsDao)
        .trustCertificate('127.0.0.1', door.port, sha256Hex: 'cd' * 32, der: [1]));
    final result = await run(tester, () => ftpsTester(native).fullConnection(cfg()));
    expect(result!.success, isFalse);
    expect(result.message, en.ftpsTestCertificateNotKept);
    expect(signIns(native), isEmpty);
  });

  testWidgets('no password under the key: said, and nothing is sent', (tester) async {
    await host(tester, password: null);
    final native = FakeFtpsNative();
    await tester.runAsync(() => KnownHostsService(db.knownHostsDao)
        .trustCertificate('127.0.0.1', door.port, sha256Hex: native.certificateSha, der: [1]));
    final result = await run(tester, () => ftpsTester(native).fullConnection(cfg()));
    expect(result!.success, isFalse);
    expect(result.message, en.connectionEditAuthFtps);
    expect(signIns(native), isEmpty);
  });

  testWidgets('a server without TLS is said with its code', (tester) async {
    await host(tester);
    final native = FakeFtpsNative()..failNext['connect'] = {'kind': 'no-tls', 'message': '502 AUTH not understood', 'code': 502};
    final result = await run(tester, () => ftpsTester(native).reachability(cfg()));
    expect(result!.success, isFalse);
    expect(result.message, contains('ZS-1606'));
    expect(result.detail, isNotNull);
  });
}
