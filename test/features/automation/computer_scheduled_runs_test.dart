import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/scheduled_task_providers.dart';
import 'package:zestssh/services/automation_service.dart';

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.pro);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Runs nothing: keeps what it was asked to run.
class _Service implements AutomationService {
  final ran = <String>[];

  @override
  Future<String?> resolveConnectionId(String labelOrId) async => labelOrId;

  @override
  Future<AutomationResult> executeCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool unattended = false,
  }) async {
    ran.add('$connectionId: $command${unattended ? ' (unattended)' : ''}');
    return const AutomationResult(success: true, output: 'ok', error: '', exitCode: 0, elapsed: Duration.zero);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A computer's scheduler (4.0) runs a task through the app's automation
/// path, as Android's worker does: with what Android hands it (the task's
/// API key by its id, the task's id), its last run written to the task, and
/// only with Squeezed and automation on. A task whose API key is gone is
/// refused as Android's is, and is not tried again at once.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));

  late AppDatabase tree;
  late ProviderContainer container;
  late _Service service;
  late _Plan plan;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'automation_api_keys': AutomationApiKey.encodeList([
        AutomationApiKey.fromSecret(id: 'k-1', label: 'schedule', secret: 'zk_made-up-key-for-this-test', createdAt: DateTime(2026)),
      ]),
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    service = _Service();
    plan = _Plan(true);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => plan),
      automationServiceProvider.overrideWithValue(service),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(automationProvider.notifier).setEnabled(true);
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  Future<void> addTask(String id, {String key = 'k-1', String command = 'df -h /'}) =>
      tree.scheduledTasksDao.upsert(ScheduledTasksCompanion(
        id: Value(id),
        name: const Value('Check disk space'),
        action: const Value('execute'),
        connectionId: const Value('web-1'),
        command: Value(command),
        scheduleType: const Value('interval'),
        intervalMinutes: const Value(30),
        enabled: const Value(true),
        apiKeyId: Value(key),
        createdAt: Value(DateTime.now().subtract(const Duration(minutes: 1))),
      ));

  test("what a computer's scheduler hands the automation path is what Android's worker hands it", () {
    final at = DateTime(2026, 11, 14);
    ScheduledTask t(String action, {String? command, String? snippet, String? workflow}) => ScheduledTask(
        id: 't-1', name: 'n', action: action, connectionId: action == 'workflow' ? '' : 'web-1', command: command,
        snippetName: snippet, workflowId: workflow, scheduleType: 'daily', intervalMinutes: 1440, enabled: true,
        apiKeyId: 'k-1', createdAt: at);
    expect(scheduledRunPayload(t('execute', command: 'uptime')), {
      'action': 'execute', 'connection_id': 'web-1', 'api_key_id': 'k-1', 'scheduled_task_id': 't-1', 'command': 'uptime',
    });
    expect(scheduledRunPayload(t('snippet', snippet: 'Disk usage')), {
      'action': 'snippet', 'connection_id': 'web-1', 'api_key_id': 'k-1', 'scheduled_task_id': 't-1', 'snippet_name': 'Disk usage',
    });
    expect(scheduledRunPayload(t('workflow', workflow: 'w-9')), {
      'action': 'workflow', 'connection_id': '', 'api_key_id': 'k-1', 'scheduled_task_id': 't-1', 'workflow_id': 'w-9',
    });
  });

  test('a due task runs unattended through automation, its last run is written, and it is not run again at once',
      () async {
    await addTask('disk');
    final scheduler = container.read(computerTaskSchedulerProvider);
    expect(await scheduler.tick(), ['disk']);
    expect(service.ran, ['web-1: df -h / (unattended)']);
    final task = (await tree.scheduledTasksDao.getById('disk'))!;
    expect(task.lastRunAt, isNotNull);
    expect(task.lastResult, 'success');
    expect(await scheduler.tick(), isEmpty);
    expect(scheduler.nextDue(task).isAfter(DateTime.now().add(const Duration(minutes: 29))), isTrue);
  });

  test('without Squeezed, or with automation off, nothing runs: the task waits (the same paywall as Android)', () async {
    await addTask('disk');
    final scheduler = container.read(computerTaskSchedulerProvider);
    plan.state = false;
    expect(await scheduler.tick(), isEmpty);
    plan.state = true;
    container.read(automationProvider.notifier).setEnabled(false);
    expect(await scheduler.tick(), isEmpty);
    expect(service.ran, isEmpty);
    container.read(automationProvider.notifier).setEnabled(true);
    expect(await scheduler.tick(), ['disk'], reason: 'what waited runs once');
  });

  test("a task whose API key is gone is refused as Android's is, said why, and not tried again at once", () async {
    await addTask('no-key', key: 'k-gone');
    final scheduler = container.read(computerTaskSchedulerProvider);
    expect(await scheduler.tick(), ['no-key']);
    expect(service.ran, isEmpty);
    expect(container.read(automationProvider).blocked, AutomationBlocked.keyNotKnown);
    expect((await tree.scheduledTasksDao.getById('no-key'))?.lastResult, 'failed');
    expect(await scheduler.tick(), isEmpty);
  });

  test('a task deleted through the app is forgotten by the scheduler and never runs', () async {
    await addTask('gone');
    final scheduler = container.read(computerTaskSchedulerProvider);
    debugScheduledTasksHere = ScheduledTasksHere.computer;
    addTearDown(() => debugScheduledTasksHere = null);
    await container.read(scheduledTasksProvider.notifier).deleteTask('gone');
    expect(await scheduler.tick(), isEmpty);
    expect(service.ran, isEmpty);
  });
}
