import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/onboarding/data/lan_scan_service.dart';
import 'package:zestssh/features/onboarding/widgets/lan_scan_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// A network that is never probed: its scope is fixed and a scan finds
/// nothing at once.
class _QuietNetwork extends LanScanService {
  @override
  Future<LanScanScope?> resolveScope() async => const LanScanScope(cidr: '10.0.2.0/24', hostCount: 254);

  @override
  Future<void> scan({
    required LanScanScope scope,
    required void Function(LanScanHit hit) onHit,
    required void Function(int scanned, int total) onProgress,
  }) async =>
      onProgress(scope.hostCount, scope.hostCount);
}

/// The phone's Scan local network says what a scan found once one has run:
/// before Start it said "No SSH servers responded" when nothing had been
/// asked (found on an emulator).
void main() {
  testWidgets('no "No SSH servers responded" before Start; after a scan that found none, it says so', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: LanScanView(onAdded: (_, _) {}, service: _QuietNetwork())),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text(l10n.networkScanScope('10.0.2.0/24')), findsOneWidget);
    expect(find.text(l10n.networkScanFound(0)), findsNothing, reason: 'nothing has been probed yet');

    await tester.tap(find.text(l10n.networkScanStart).first);
    await tester.pumpAndSettle();
    expect(find.text(l10n.networkScanFound(0)), findsOneWidget);
    expect(find.text(l10n.networkScanEmpty), findsOneWidget);
  });
}
