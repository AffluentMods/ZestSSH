import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/ui/screens/settings/known_hosts_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart' show HostKeyFingerprint;

/// Trusted host keys (3.4): an FTPS server's certificate is said as one, "TLS
/// certificate (SHA-256)", with its whole fingerprint as the question showed it
/// (as openssl prints it), never its raw key type; an SSH host key's row is as
/// it was. Made-up hosts.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  testWidgets('a certificate row reads as a TLS certificate with its whole fingerprint', (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final known = KnownHostsService(db.knownHostsDao);
    await known.trustCertificate('files.example.test', 990, sha256Hex: 'ab' * 32, der: [1, 2, 3]);
    final fingerprint = KnownHostsService.certificateFingerprint('ab' * 32);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        knownHostsDaoProvider.overrideWithValue(db.knownHostsDao),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: KnownHostsScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(l10n.knownHostsTlsCertificate), findsOneWidget);
    expect(find.textContaining(KnownHostsService.certificateKeyType), findsNothing, reason: 'never the raw key type');
    final shown = tester.widget<HostKeyFingerprint>(find.byType(HostKeyFingerprint));
    expect(shown.fingerprint, fingerprint);
    expect(find.text(fingerprint), findsOneWidget, reason: 'whole, as the question showed it');
    await tester.pumpWidget(const SizedBox());
    // (drift closes the screen's query on a timer of its own.)
    await tester.pump(Duration.zero);
  });
}
