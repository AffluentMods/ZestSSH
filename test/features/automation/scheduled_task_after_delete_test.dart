import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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
import 'package:zestssh/services/automation_service.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

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
    ran.add(command);
    return const AutomationResult(success: true, output: 'ok', error: '', exitCode: 0, elapsed: Duration.zero);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Android's scheduled task posts "A scheduled task is ready. Tap to run it." when the
/// app is not on screen, and the tap carries the task's command and a launch token that
/// lives 12 hours (SshTaskWorker.kt). Deleting or turning off the task in the app cancels
/// WorkManager's job only: the notification stays, and the app ran what the tap carried
/// without asking whether the task was still there or still on.
/// It is refused now, and the person is told why.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));

  late AppDatabase tree;
  late ProviderContainer container;
  late _Service service;

  /// What the tap on the task's notification hands the app (MainActivity.kt's
  /// buildAutomationPayload, once the launch token was spent).
  Map<String, dynamic> tapOf(String taskId) => {
        'action': 'execute',
        'connection_id': 'web-1',
        'connection_label': null,
        'api_key_id': 'k-1',
        'scheduled_task_id': taskId,
        'command': 'rm -rf /srv/releases/*',
      };

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
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      automationServiceProvider.overrideWithValue(service),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(automationProvider.notifier).setEnabled(true);
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  Future<void> addTask(String id, {required bool enabled}) => tree.scheduledTasksDao.upsert(ScheduledTasksCompanion(
        id: Value(id),
        name: const Value('Clean releases'),
        action: const Value('execute'),
        connectionId: const Value('web-1'),
        command: const Value('rm -rf /srv/releases/*'),
        scheduleType: const Value('interval'),
        intervalMinutes: const Value(60),
        enabled: Value(enabled),
        apiKeyId: const Value('k-1'),
        createdAt: Value(DateTime(2026, 11, 5)),
      ));

  test('a task that is on runs from its notification (as it should)', () async {
    await addTask('task-on', enabled: true);
    await container.read(automationProvider.notifier).handleAutomation(tapOf('task-on'));
    expect(service.ran, ['rm -rf /srv/releases/*']);
    expect((await tree.scheduledTasksDao.getById('task-on'))?.lastRunAt, isNotNull);
  });

  test('a task deleted in the app does not run from the notification it left', () async {
    await addTask('task-gone', enabled: true);
    await tree.scheduledTasksDao.deleteById('task-gone');
    await container.read(automationProvider.notifier).handleAutomation(tapOf('task-gone'));
    expect(service.ran, isEmpty, reason: 'the task was deleted before its notification was tapped');
    expect(container.read(automationProvider).blocked, AutomationBlocked.taskGone, reason: 'the person is told why');
  });

  test('a task turned off in the app does not run from the notification it left', () async {
    await addTask('task-off', enabled: false);
    await container.read(automationProvider.notifier).handleAutomation(tapOf('task-off'));
    expect(service.ran, isEmpty, reason: 'the task was turned off before its notification was tapped');
    expect(container.read(automationProvider).blocked, AutomationBlocked.taskGone);
    expect((await tree.scheduledTasksDao.getById('task-off'))?.lastRunAt, isNull, reason: 'it did not run');
  });
}
