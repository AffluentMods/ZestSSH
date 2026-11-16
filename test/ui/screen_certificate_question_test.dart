import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/session/screen_trust.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;
import 'package:zestssh/ui/screens/settings/known_hosts_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';

/// A remote screen's VeNCrypt certificate (4.0) is asked
/// about in the host key dialogs as FTPS's is, in a screen's words: where it
/// is and, behind a carrier, through which SSH host; and the trusted host keys
/// show it as "TLS certificate (remote screen)". Made-up hosts.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final fingerprint = KnownHostsService.certificateFingerprint('ab' * 32);

  Future<BuildContext> host(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    late BuildContext context;
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
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
    return context;
  }

  HostKeyVerification screen({String? via, bool changed = false}) => HostKeyVerification(
        certificate: true,
        screen: true,
        via: via,
        host: 'localhost',
        port: 5900,
        hostKey: SSHHostKey(type: KnownHostsService.certificateKeyType, bytes: Uint8List(8)),
        fingerprint: fingerprint,
        isChanged: changed,
        expectedFingerprint: changed ? KnownHostsService.certificateFingerprint('cd' * 32) : null,
        completer: Completer<bool>(),
      );

  testWidgets('a first certificate behind a carrier: where, through which SSH host, its fingerprint; Trust and connect '
      'trusts it',
      (tester) async {
    final context = await host(tester);
    bool? answer;
    unawaited(askHostKeyTrust(context, screen(via: 'gateway')).then((v) => answer = v));
    await tester.pumpAndSettle();
    expect(find.byType(NewHostKeyDialog), findsOneWidget);
    expect(find.text(l10n.hostKeyFirstTitle('localhost:5900')), findsOneWidget);
    expect(find.text(l10n.screenCertificateFirstWhyVia('gateway')), findsOneWidget);
    expect(find.text(l10n.ftpsCertificateFirstWhy), findsNothing, reason: 'not an FTPS server');
    expect(l10n.screenCertificateFirstWhyVia('gateway'), contains('for this route'));
    expect(find.textContaining('AB:AB:AB'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('host-key-new-trust')));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  testWidgets('a direct screen says TLS alone; a changed one is the red warning with the command to read it',
      (tester) async {
    final context = await host(tester);
    unawaited(askHostKeyTrust(context, screen()));
    await tester.pumpAndSettle();
    expect(find.text(l10n.screenCertificateFirstWhy), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('host-key-new-reject')));
    await tester.pumpAndSettle();

    unawaited(askHostKeyTrust(context, screen(via: 'gateway', changed: true)));
    await tester.pumpAndSettle();
    expect(find.byType(HostKeyChangedDialog), findsOneWidget);
    expect(find.text(l10n.ftpsCertificateChangedTitle), findsOneWidget);
    expect(find.textContaining('openssl x509 -noout -fingerprint -sha256'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('host-key-changed-cancel')));
    await tester.pumpAndSettle();
  });

  testWidgets('trusted host keys: a screen certificate reads "TLS certificate (remote screen)", an FTPS one as before',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final known = KnownHostsService(db.knownHostsDao);
    await known.trustCertificate('localhost', 5900,
        sha256Hex: 'ab' * 32, der: [1, 2, 3], viaScope: screenViaScope(carrierHost: 'gateway.example.test', carrierPort: 22));
    await known.trustCertificate('desk.example.test', 5900, sha256Hex: 'cd' * 32, der: [4, 5, 6]);
    await known.trustCertificate('files.example.test', 990, sha256Hex: 'ef' * 32, der: [7, 8, 9]);
    final now = DateTime(2026, 11, 9);
    final direct = Connection(
      id: 's-direct',
      label: 'desk direct',
      host: 'desk.example.test',
      port: 5900,
      colorIndex: 0,
      protocol: 'vnc',
      zlibCompression: false,
      keepAliveSeconds: 0,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      createdAt: now,
      updatedAt: now,
    );

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        knownHostsDaoProvider.overrideWithValue(db.knownHostsDao),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value([ConnectionWithDetails(connection: direct)])),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: KnownHostsScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(l10n.knownHostsScreenCertificate), findsNWidgets(2), reason: 'behind a carrier, and direct');
    expect(find.text(l10n.knownHostsTlsCertificate), findsOneWidget, reason: 'the FTPS one');
    expect(find.text(KnownHostsService.certificateFingerprint('ab' * 32)), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });
}
