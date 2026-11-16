import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show activeForwardIdsProvider;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';

PortForwardRule _rule(String id, String label, {required bool autoStart}) => PortForwardRule(
      id: id,
      connectionId: 'c-db',
      type: 'local',
      bindAddress: '127.0.0.1',
      bindPort: 5432,
      remoteHost: 'localhost',
      remotePort: 5432,
      autoStart: autoStart,
      reconnect: true,
      exitOnFailure: true,
      gatewayPorts: false,
      label: label,
      createdAt: DateTime(2026, 10, 16),
    );

/// A phone's list of forwards (3.0, found while comparing the
/// five versions): a forward's mark was green when it starts with its
/// connection, which its Auto mark says too, and read as running. Now it is
/// green while the forward runs.
void main() {
  testWidgets('a forward is green while it runs, whether or not it starts with its connection', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      filteredPortForwardRulesProvider.overrideWith((ref) => Stream.value([
            _rule('f-auto', 'postgres on db-01', autoStart: true),
            _rule('f-hand', 'redis on db-01', autoStart: false),
          ])),
      connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const <ConnectionWithDetails>[])),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: PortForwardsPhoneScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump();

    Color? markOf(String label) => tester
        .widget<Icon>(find.descendant(
          of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
          matching: find.byType(Icon),
        ).first)
        .color;

    // Neither runs: neither green, though one starts with its connection.
    expect(markOf('postgres on db-01'), AppColors.textSecondary);
    expect(markOf('redis on db-01'), AppColors.textSecondary);

    // The one started by hand runs.
    container.read(activeForwardIdsProvider.notifier).state = {'f-hand'};
    await tester.pump();
    expect(markOf('redis on db-01'), AppColors.success);
    expect(markOf('postgres on db-01'), AppColors.textSecondary);
  });
}
