import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/providers/scheduled_task_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/automation/scheduled_tasks_screen.dart';
import 'package:zestssh/ui/screens/desktop/widgets/automation_view.dart';

import '../a11y/a11y_checks.dart';
import '../a11y/hosts_a11y_harness.dart' hide a11yFailures;

/// A computer's Scheduled tasks (4.0): the same page as Android's, which
/// says above the tasks that they run while ZestSSH is open or in the tray
/// and what comes of a run missed while it was closed, tells when each runs
/// next, and has a Delete button a pointer and a keyboard can use (a
/// computer does not swipe); reached from Automation's Runs. Held to the
/// accessibility pass's checks in every theme and at 150% text.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    ScheduledTasksScreen.debugHere = ScheduledTasksHere.computer;
    final key = AutomationApiKey.fromSecret(id: 'k-1', label: 'This computer', secret: 'zk_made_up_0000', createdAt: DateTime(2026, 11));
    FlutterSecureStorage.setMockInitialValues({'automation_api_keys': jsonEncode([key.toJson()])});
  });
  tearDown(() => ScheduledTasksScreen.debugHere = null);

  Future<AppDatabase> withTasks() async {
    final db = await fleetDatabase();
    final made = DateTime.now().subtract(const Duration(days: 2));
    for (final (id, name, type, every, hour, day) in [
      ('t-disk', 'Check disk space', 'interval', 30, null, null),
      ('t-backup', 'Nightly backup', 'daily', 1440, 2, null),
      ('t-certs', 'Renew certificates', 'weekly', 10080, 4, 1),
    ]) {
      await db.scheduledTasksDao.upsert(ScheduledTasksCompanion(
        id: Value(id),
        name: Value(name),
        action: const Value('execute'),
        connectionId: const Value('h-web1'),
        command: const Value('uptime'),
        scheduleType: Value(type),
        intervalMinutes: Value(every),
        hour: Value(hour),
        minute: Value(hour == null ? null : 0),
        dayOfWeek: Value(day),
        enabled: const Value(true),
        apiKeyId: const Value('k-1'),
        createdAt: Value(made),
        lastRunAt: Value(made.add(const Duration(hours: 1))),
        lastResult: const Value('success'),
      ));
    }
    return db;
  }

  testWidgets('says when the tasks run, when each runs next, and each has a named Delete', (tester) async {
    final db = (await tester.runAsync(withTasks))!;
    await pumpA11y(tester, const ScheduledTasksScreen(), db: db, scaffold: false);
    expect(find.text(en.schedTaskComputerBanner), findsOneWidget);
    expect(find.text(en.schedTaskBackgroundBanner), findsNothing, reason: "Android's tap to run is no computer's");
    for (final id in ['t-disk', 't-backup', 't-certs']) {
      expect(find.byKey(ValueKey('sched-task-next-$id')), findsOneWidget, reason: id);
      expect(find.byKey(ValueKey('sched-task-delete-$id')), findsOneWidget, reason: id);
    }
    // Every N minutes, missed while the app was closed: due now.
    final disk = tester.widget<Text>(find.byKey(const ValueKey('sched-task-next-t-disk'))).data!;
    expect(disk, startsWith(en.schedTaskNextRun('')));
    expect(find.byTooltip(en.schedTaskDeleteNamed('Nightly backup')), findsOneWidget);
    expect(find.byTooltip(en.schedTaskNewTitle), findsOneWidget, reason: 'a new task, named');
    await finishA11y(tester);
  });

  testWidgets('Delete asks first, then the task is gone', (tester) async {
    final db = (await tester.runAsync(withTasks))!;
    await pumpA11y(tester, const ScheduledTasksScreen(), db: db, scaffold: false);
    await tester.tap(find.byKey(const ValueKey('sched-task-delete-t-backup')));
    await a11ySettle(tester);
    expect(find.text(en.schedTaskDeleteMessage), findsOneWidget);
    await tester.tap(find.text(en.delete).last);
    await a11ySettle(tester);
    expect((await tester.runAsync(() => db.scheduledTasksDao.getById('t-backup'))), isNull);
    expect(find.text('Nightly backup'), findsNothing);
    expect(find.text('Check disk space'), findsOneWidget);
    await finishA11y(tester);
  });

  testWidgets('with no task yet, it says when tasks run above the way to make one', (tester) async {
    await pumpA11y(tester, const ScheduledTasksScreen(), scaffold: false);
    expect(find.text(en.schedTaskComputerBanner), findsOneWidget);
    expect(find.text(en.scheduledEmptyTitle), findsOneWidget);
    expect(find.text(en.scheduledIosTitle), findsNothing, reason: 'a computer said scheduling was Android only');
    await finishA11y(tester);
  });

  for (final themeId in a11yThemes) {
    testWidgets('names, targets and contrast ($themeId)', (tester) async {
      final handle = tester.ensureSemantics();
      final db = (await tester.runAsync(withTasks))!;
      await pumpA11y(tester, const ScheduledTasksScreen(), themeId: themeId, db: db, scaffold: false);
      await expectA11y(tester, computer: true, where: 'Scheduled tasks ($themeId)');
      await finishA11y(tester);
      handle.dispose();
    });
  }

  testWidgets('at 150% text nothing runs over', (tester) async {
    final db = (await tester.runAsync(withTasks))!;
    await pumpA11y(tester, const ScheduledTasksScreen(), db: db, scaffold: false, textScale: 1.5);
    expect(takeAllExceptions(tester, 'Scheduled tasks at 150%'), isEmpty);
    await finishA11y(tester);
  });

  testWidgets("Automation's Runs has the way to them", (tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, state) => const Scaffold(body: AutomationView())),
      GoRoute(path: Routes.scheduledTasks, builder: (context, state) => const ScheduledTasksScreen()),
    ]);
    await pumpA11y(tester, const SizedBox(), router: router);
    expect(find.byKey(const ValueKey('automation-scheduled-tasks')), findsNothing, reason: 'Workflows is open');
    await tester.tap(find.text(en.zestAutoTabRuns));
    await a11ySettle(tester);
    await tester.tap(find.byKey(const ValueKey('automation-scheduled-tasks')));
    await a11ySettle(tester);
    expect(find.byType(ScheduledTasksScreen), findsOneWidget);
    expect(find.text(en.schedTaskComputerBanner), findsOneWidget);
    await finishA11y(tester);
  });
}
