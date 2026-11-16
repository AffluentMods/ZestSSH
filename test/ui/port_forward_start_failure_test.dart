import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';

/// Start on a forward that does not start (3.0): it says why,
/// from what starting it threw, with its details. It said the local port
/// might be in use whatever the reason, with nothing behind it.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  Object? error;

  @override
  Future<StartForwardResult> startSavedForward(PortForwardRule rule) async => StartForwardResult.error;

  @override
  Object? lastForwardError(String ruleId) => error;
}

void main() {
  // Real time for the database's streams, frames for the screen (as the
  // shell tests do; pumpAndSettle waits on the list's loading for good).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a forward that does not start says why, with its details', (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    // Closed after the test, outside its clock (inside it, closing never ends).
    addTearDown(db.close);
    final at = DateTime(2026, 10, 1);
    // The database works in real time, not the test's clock.
    await tester.runAsync(() async {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-db1',
            label: 'db-01',
            host: '10.50.0.7',
            createdAt: at,
            updatedAt: at,
          ));
      await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
            id: 'r1',
            connectionId: 'h-db1',
            type: 'local',
            bindPort: 15432,
            remoteHost: '127.0.0.1',
            remotePort: 5432,
            label: const Value('db tunnel'),
            createdAt: at,
          ));
    });
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    // Disposed before the database closes (tear-downs run last first).
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    final sessions = container.read(activeSessionsProvider.notifier) as _Sessions;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: PortForwardListView()),
      ),
    ));
    await settle(tester);

    // The port on this device is taken.
    sessions.error = const SocketException('Failed to create server socket', osError: OSError('', 10048));
    await tester.tap(find.text(en.zestPfStart));
    await settle(tester);
    final notice = container.read(notificationCenterProvider).history.first;
    expect(notice.title, en.pfFailedPortInUse(15432));
    expect(notice.details, contains('Failed to create server socket'));
    expect(notice.details, contains('local port 15432'));

    // Nothing known: no reason is made up, and the report (every error has
    // one to copy) says only what the app knows.
    sessions.error = null;
    await tester.tap(find.text(en.zestPfStart));
    await settle(tester);
    expect(container.read(notificationCenterProvider).history.first.title, en.pfFailedOther);
    expect(container.read(notificationCenterProvider).history.first.details, isNot(contains('Failed to create server socket')));

    await tester.pumpWidget(const SizedBox());
    // The delayed clean-ups the providers schedule run out (as the shell
    // tests do).
    await tester.pump(const Duration(hours: 7));
  });
}
