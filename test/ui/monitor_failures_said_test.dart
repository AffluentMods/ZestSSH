import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/monitoring/monitor_manage_dialog.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Locked implements Exception {
  const _Locked();
  @override
  String toString() => 'SqliteException(5): database is locked';
}

/// The server monitor's hosts that could not be loaded (3.0):
/// said so in the person's language, with Try again and Copy details, as the
/// other lists say it. It said "Error loading connections:" and the error as
/// the program writes it.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets('the hosts to monitor that cannot be loaded: said so, with Try again and its details', (tester) async {
    var asked = 0;
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        connectionsWithDetailsProvider.overrideWith((ref) {
          asked++;
          return Stream.error(const _Locked());
        }),
        isProProvider.overrideWith((ref) => _Pro(false)),
        canAddMonitoredHostProvider.overrideWith((ref) => true),
        monitoredCountProvider.overrideWith((ref) => 0),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMonitorManageServers(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(en.homeUnableToLoadConnections), findsOneWidget);
    expect(find.textContaining('database is locked'), findsNothing, reason: 'the error is not the sentence');
    expect(find.byType(CopyDetailsButton), findsOneWidget);
    final before = asked;
    await tester.tap(find.text(en.retry));
    await tester.pumpAndSettle();
    expect(asked, greaterThan(before), reason: 'Try again loads them again');
  });
}
