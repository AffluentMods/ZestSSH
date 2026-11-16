import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart';

class _Stats extends ServerStatsNotifier {
  _Stats(super.ref, Map<String, ServerStats> seed) {
    state = seed;
  }

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}
}

// The terminal header says "Reboot needed" while the host asks for a restart,
// and it only says so: no tap, no menu, nothing that restarts a host (a
// restart from the UI could happen by accident).
void main() {
  Future<void> pump(WidgetTester tester, {required bool? restart, String? id = 'web'}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        serverStatsProvider.overrideWith((ref) => _Stats(ref, {
              'web': ServerStats(collectedAt: DateTime(2026, 10, 23), restartRequired: restart),
            })),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: Center(child: SessionRebootChip(connectionId: id))),
      ),
    ));
    await tester.pump();
  }

  testWidgets('shown while the host asks for a restart, as words only', (tester) async {
    await pump(tester, restart: true);
    final l10n = lookupAppLocalizations(const Locale('en'));
    final chip = find.byKey(const ValueKey('session-reboot-needed'));
    expect(chip, findsOneWidget);
    expect(find.text(l10n.hostRebootNeeded), findsOneWidget);
    expect(find.ancestor(of: chip, matching: find.byType(InkWell)), findsNothing);
    expect(find.ancestor(of: chip, matching: find.byType(GestureDetector)), findsNothing);
    expect(find.ancestor(of: chip, matching: find.byType(MenuAnchor)), findsNothing);
  });

  testWidgets('not shown where it does not, where nothing was read, or with no host', (tester) async {
    await pump(tester, restart: false);
    expect(find.byKey(const ValueKey('session-reboot-needed')), findsNothing);
    await pump(tester, restart: null);
    expect(find.byKey(const ValueKey('session-reboot-needed')), findsNothing);
    await pump(tester, restart: true, id: 'other');
    expect(find.byKey(const ValueKey('session-reboot-needed')), findsNothing);
    await pump(tester, restart: true, id: null);
    expect(find.byKey(const ValueKey('session-reboot-needed')), findsNothing);
  });

  test('the header carries it', () {
    expect(
      RegExp(r'SessionRebootChip\(connectionId: sessionState\.connectionId\)')
          .hasMatch(_source('lib/ui/screens/desktop/widgets/session_chrome.dart')),
      isTrue,
    );
  });
}

String _source(String path) => File(path).readAsStringSync();
