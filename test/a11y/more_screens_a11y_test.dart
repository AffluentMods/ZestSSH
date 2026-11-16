import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/changelog/whats_new_dialog.dart';
import 'package:zestssh/features/notifications/widgets/notification_bell.dart';
import 'package:zestssh/ui/screens/desktop/widgets/automation_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/history_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/triggers_view.dart';
import 'package:zestssh/ui/screens/automation/automation_history_screen.dart';
import 'package:zestssh/ui/screens/automation/scheduled_tasks_screen.dart';
import 'package:zestssh/providers/scheduled_task_providers.dart' show ScheduledTasksHere;
import 'package:zestssh/ui/screens/automation/workflow_list_screen.dart';
import 'package:zestssh/ui/screens/command_history/command_history_screen.dart';
import 'package:zestssh/ui/screens/identity/identity_list_screen.dart';
import 'package:zestssh/ui/screens/settings/licenses_screen.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/screens/transcripts/transcripts_screen.dart';
import 'package:zestssh/ui/screens/triggers/triggers_screen.dart';

import 'a11y_checks.dart';
import 'hosts_a11y_harness.dart' hide a11yFailures;

/// The app's main screens outside the areas the 4.0 accessibility pass's
/// first guards cover (Hosts, Settings, Team, the terminal, files and the
/// editor), held to the same checks: every control a
/// screen reader can press has a name, a pointer's target is a mouse's 32 on
/// a computer and a finger's 48 on a phone, and every word reads on what it
/// is drawn on, in Ember, Graphite and Daylight. The computer's Keys,
/// Snippets, Automation (its workflows, triggers and runs), Server Monitor,
/// Triggers and History pages, the notifications panel, What's new and the
/// licences; the phone's Snippets tab, identities, workflows, automation
/// history, scheduled tasks, alerts, command history and transcripts.
void main() {
  tearDown(() => ScheduledTasksScreen.debugHere = null);

  /// The fleet with two keys and a few snippets (made-up names).
  Future<AppDatabase> world() async {
    final db = await fleetDatabase();
    final at = DateTime(2026, 9, 24);
    for (final (id, label, user) in [('k-ops', 'Ops laptop', 'deploy'), ('k-build', 'Build key', 'ci')]) {
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: id, label: label, username: user, authMethod: 'publicKey', createdAt: at, updatedAt: Value(at)));
    }
    for (final (id, label, command) in [
      ('s-up', 'Uptime', 'uptime'),
      ('s-disk', 'Disk usage', r'df -h $[MOUNT]'),
      ('s-logs', 'Follow nginx logs', 'sudo journalctl -fu nginx'),
    ]) {
      await db.into(db.snippets).insert(SnippetsCompanion.insert(id: id, label: label, command: command, createdAt: at, updatedAt: at));
    }
    return db;
  }

  final computerScreens = <String, Widget Function()>{
    'Keys': () => const KeysView(),
    'Snippets': () => const SnippetsLibraryView(),
    'Automation': () => const AutomationView(),
    'Server Monitor': () => const MonitorTableView(),
    'Triggers': () => const TriggersView(),
    'History': () => const HistoryView(),
    'Notifications': () => const Align(alignment: Alignment.topRight, child: NotificationBell()),
    "What's new": () => const WhatsNewDialog(),
    'Licences': () => const LicensesScreen(version: '4.0.0'),
    // A computer runs its scheduled tasks itself from 4.0.
    'Scheduled tasks': () {
      ScheduledTasksScreen.debugHere = ScheduledTasksHere.computer;
      return const ScheduledTasksScreen();
    },
  };

  for (final themeId in a11yThemes) {
    testWidgets('computer: Keys, Snippets, Automation, Monitor, Triggers, History, notifications, What\'s new, '
        'licences ($themeId)', (tester) async {
      final handle = tester.ensureSemantics();
      final failures = <String>[];
      for (final MapEntry(key: name, value: build) in computerScreens.entries) {
        final db = (await tester.runAsync(world))!;
        await pumpA11y(tester, build(), themeId: themeId, db: db);
        failures.addAll(await a11yCheck(tester, computer: true, where: '$name ($themeId)'));
        if (name == 'Notifications') {
          // And its panel, opened.
          await tester.tap(find.byType(NotificationBell));
          await a11ySettle(tester);
          failures.addAll(await a11yCheck(tester, computer: true, where: 'the notifications panel ($themeId)'));
        }
        await finishA11y(tester);
      }
      expect(failures, isEmpty);
      handle.dispose();
    });
  }

  // A phone's pages of these areas (its Keys tab, notifications, team and
  // the welcome are held by test/ui/phone_more_screens_fit_test.dart).
  final phoneScreens = <String, Widget Function()>{
    'Snippets': () => const SnippetsScreen(),
    'Identities': () => const IdentityListScreen(),
    'Workflows': () => const WorkflowListScreen(),
    'Automation history': () => const AutomationHistoryScreen(),
    'Scheduled tasks': () {
      ScheduledTasksScreen.debugHere = ScheduledTasksHere.android;
      return const ScheduledTasksScreen();
    },
    'Alerts': () => const TriggersScreen(),
    'Command history': () => const CommandHistoryScreen(),
    'Transcripts': () => const TranscriptsScreen(),
  };

  for (final themeId in a11yThemes) {
    testWidgets('phone: Snippets, identities, workflows, automation history, scheduled tasks, alerts, command '
        'history and transcripts ($themeId)', (tester) async {
      final handle = tester.ensureSemantics();
      final failures = <String>[];
      for (final MapEntry(key: name, value: build) in phoneScreens.entries) {
        final db = (await tester.runAsync(world))!;
        await pumpA11y(tester, build(), themeId: themeId, db: db, size: const Size(412, 900), touch: true, router: _router(build));
        failures.addAll(await a11yCheck(tester, computer: false, where: 'phone $name ($themeId)'));
        await finishA11y(tester);
      }
      expect(failures, isEmpty);
      handle.dispose();
    });
  }

  testWidgets('computer at 150% text and phone at 200%: nothing runs over', (tester) async {
    final failures = <String>[];
    for (final MapEntry(key: name, value: build) in computerScreens.entries) {
      final db = (await tester.runAsync(world))!;
      await pumpA11y(tester, build(), db: db, textScale: 1.5);
      failures.addAll(takeAllExceptions(tester, '$name at 150%'));
      await finishA11y(tester);
    }
    for (final MapEntry(key: name, value: build) in phoneScreens.entries) {
      final db = (await tester.runAsync(world))!;
      await pumpA11y(tester, build(), db: db, size: const Size(412, 900), touch: true, router: _router(build), textScale: 2);
      failures.addAll(takeAllExceptions(tester, 'phone $name at 200%'));
      await finishA11y(tester);
    }
    expect(failures, isEmpty);
  });
}

/// A phone's page as the app shows it: under a router (its rows push the
/// next page), any other route a page of its own.
GoRouter _router(Widget Function() page) => GoRouter(routes: [
      // In a page's Scaffold, as the phone's tabs stand in the home screen's.
      GoRoute(path: '/', builder: (context, state) => Scaffold(body: page())),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text(state.uri.toString()))),
    ]);
