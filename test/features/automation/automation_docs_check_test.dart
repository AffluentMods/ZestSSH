// Automation as a 3.0 docs review found it:
// * a scheduled WORKFLOW never ran: the app saves its task with no host (a
//   workflow names its hosts in its steps), and Android's worker refused a
//   task without one;
// * a scheduled task's "Last:" never filled: nothing wrote it;
// * a workflow turned off in the list still ran from a link, another app or
//   a schedule: the switch was saved and never read;
// * a workflow's snippet step asks for ${NAME} and saved it, and only
//   {{name}} was filled, so the snippet ran with the placeholders in it;
// * a workflow with a step whose snippet was deleted went on (the words said
//   it skipped the step); now it stops there, naming the snippet;
// * the schedule's words were English whatever the language.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/models/scheduled_task.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/workflow_service.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Commands succeed; a snippet named "gone" is not there.
class _Automation implements AutomationService {
  final ran = <String>[];

  @override
  Future<AutomationResult> executeCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool unattended = false,
  }) async {
    ran.add(command);
    return const AutomationResult(success: true, output: 'ok', error: '', exitCode: 0, elapsed: Duration.zero);
  }

  @override
  Future<AutomationResult> runSnippet({
    required String connectionId,
    required String snippetName,
    Map<String, String>? variables,
    Duration timeout = const Duration(seconds: 30),
    bool unattended = false,
  }) async =>
      AutomationResult(
        success: false,
        output: '',
        error: 'The snippet "$snippetName" is not there',
        elapsed: Duration.zero,
        snippetMissing: true,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  group("Android's scheduler", () {
    final worker = File('android/app/src/main/kotlin/com/affluentlabs/zestssh/scheduler/SshTaskWorker.kt')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final manager = File('android/app/src/main/kotlin/com/affluentlabs/zestssh/scheduler/TaskSchedulerManager.kt')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final activity =
        File('android/app/src/main/kotlin/com/affluentlabs/zestssh/MainActivity.kt').readAsStringSync().replaceAll('\r\n', '\n');

    test('a workflow task runs without a host; every other still needs one', () {
      expect(worker, contains('val connectionId = inputData.getString("connection_id") ?: ""'));
      expect(worker, isNot(contains('getString("connection_id") ?: return Result.failure()')));
      expect(
          worker,
          matches(RegExp(r'if \(action == "workflow"\) \{\s*// [^\n]*\n\s*if \(workflowId\.isNullOrBlank\(\) && '
              r'workflowName\.isNullOrBlank\(\)\) return Result\.failure\(\)\s*\} else \{[^}]*connectionId\.isBlank\(\)')));
    });

    test("the task's id goes from the scheduler to the app, beside its key and only with the launch token", () {
      expect(manager, contains('.putString("task_id", taskId)'));
      expect(worker, contains('putExtra("scheduled_task_id", taskId)'));
      final tokenBlock = RegExp(r'if \(ScheduledLaunchTokens\.consume\(applicationContext, launchToken\)\) \{([^}]*)\}')
          .firstMatch(activity)!
          .group(1)!;
      expect(tokenBlock, contains('base["scheduled_task_id"]'));
      expect(activity.split('scheduled_task_id').length - 1, 2, reason: 'read nowhere else');
    });
  });

  group('the automation engine', () {
    const apiKey = 'zk_made-up-key-for-this-test-only';
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      final at = DateTime(2026, 10, 16);
      FlutterSecureStorage.setMockInitialValues({
        'automation_api_keys': AutomationApiKey.encodeList([
          AutomationApiKey.fromSecret(id: 'k-1', label: 'phone', secret: apiKey, createdAt: at),
        ]),
      });
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro()),
      ]);
      container.read(databaseSessionProvider.notifier).seed(db);
      container.read(automationProvider.notifier).setEnabled(true);
      await container.read(workflowsProvider.notifier).addWorkflow(Workflow(
            id: 'wf-off',
            name: 'Nightly',
            enabled: false,
            createdAt: at,
            steps: const [WorkflowStep(id: 's1', type: WorkflowStepType.execute, connectionId: 'c1', command: 'uptime')],
          ));
      await db.scheduledTasksDao.upsert(ScheduledTasksCompanion.insert(
        id: 'task-1',
        name: 'Nightly',
        action: 'workflow',
        connectionId: '',
        scheduleType: 'daily',
        intervalMinutes: const Value(1440),
        apiKeyId: 'k-1',
        createdAt: at,
      ));
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('a workflow turned off is not run from outside, and Automation history says so', () async {
      await container
          .read(automationProvider.notifier)
          .handleAutomation({'action': 'workflow', 'workflow_name': 'Nightly', 'key': apiKey});
      final history = await db.automationHistoryDao.getAll();
      expect(history, hasLength(1));
      expect(history.single.success, isFalse);
      expect(history.single.stderr, en.automationWorkflowOffNotRun);
    });

    test("a scheduled task's run is written as its last run, and only one the scheduler vouched for", () async {
      final before = await db.scheduledTasksDao.getById('task-1');
      expect(before!.lastRunAt, isNull);
      // As MainActivity hands over a run of the app's own scheduler.
      await container.read(automationProvider.notifier).handleAutomation(
          {'action': 'workflow', 'workflow_id': 'wf-off', 'api_key_id': 'k-1', 'scheduled_task_id': 'task-1'});
      final after = await db.scheduledTasksDao.getById('task-1');
      expect(after!.lastRunAt, isNotNull);
      expect(after.lastResult, 'failed', reason: 'the workflow is off');
      // A request that names a task but came with no scheduler's key id
      // (a link, another app) writes nothing.
      await db.scheduledTasksDao.updateLastRun('task-1', DateTime(2020), 'success');
      await container.read(automationProvider.notifier).handleAutomation(
          {'action': 'workflow', 'workflow_id': 'wf-off', 'key': apiKey, 'scheduled_task_id': 'task-1'});
      expect((await db.scheduledTasksDao.getById('task-1'))!.lastRunAt, DateTime(2020));
    });
  });

  group('snippets in automation', () {
    test(r"a snippet's ${NAME} forms are filled as {{name}} is, each value as one argument", () {
      const template = r'deploy {{app}} --branch ${BRANCH} --env ${ENV:-staging} --token ${TOKEN:secret} $[a,b]';
      final filled = withSnippetVariables(template, {
        'app': 'shop',
        'BRANCH': 'main; rm -rf /',
        'ENV': 'prod',
        'TOKEN': 's3cret',
        '[a,b]': 'b',
      });
      expect(filled, "deploy 'shop' --branch 'main; rm -rf /' --env 'prod' --token 's3cret' 'b'");
      // One with no value is left as it is (a default then comes from the shell).
      expect(withSnippetVariables(r'echo ${ENV:-staging} {{x}}', const {}), r'echo ${ENV:-staging} {{x}}');
      // A value is never read again for placeholders.
      expect(withSnippetVariables(r'echo ${A} ${B}', {'A': r'${B}', 'B': 'x'}), r"echo '${B}' 'x'");
    });

    test('a step whose snippet is gone stops the workflow, whatever the step does on failure, naming the snippet',
        () async {
      final automation = _Automation();
      final service = WorkflowService(automation, notice: (_, _, _) {});
      final result = await service.executeWorkflow(Workflow(
        id: 'w',
        name: 'Deploy',
        createdAt: DateTime(2026, 10, 1),
        steps: const [
          WorkflowStep(
            id: 'gone',
            type: WorkflowStepType.snippet,
            snippetName: 'gone',
            connectionId: 'c1',
            onFailure: StepFailureAction.continueNext,
          ),
          WorkflowStep(id: 'after', type: WorkflowStepType.execute, connectionId: 'c1', command: 'uptime'),
        ],
      ));
      expect(result.success, isFalse);
      expect(automation.ran, isEmpty, reason: 'the step after it did not run');
      expect(result.stepResults.first.error, contains('gone'));
      expect(result.stepResults.last.skipped, isTrue);
    });
  });

  test("a schedule's words in the person's language", () async {
    // (The app's localizations load every language's dates; a test does it itself.)
    await initializeDateFormatting();
    final de = lookupAppLocalizations(const Locale('de'));
    expect(ScheduleIntervals.displayLabel(en, 30), 'Every 30 min');
    expect(ScheduleIntervals.displayLabel(en, 60), 'Every hour');
    expect(ScheduleIntervals.displayLabel(en, 360), 'Every 6 hours');
    expect(ScheduleIntervals.displayLabel(en, 1440), 'Every day');
    expect(ScheduleIntervals.displayLabel(de, 360), 'Alle 6 Stunden');
    expect(WeekDay.shortName(en, 1), 'Mon');
    expect(WeekDay.name(en, 7), 'Sunday');
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      for (final m in ScheduleIntervals.presets) {
        expect(ScheduleIntervals.displayLabel(l, m), isNotEmpty);
      }
    }
  });
}
