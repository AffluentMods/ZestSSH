import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// With the encrypting app lock on, the database is closed while the app is
/// locked. A link waits for the unlock (LinkGate), but an Android automation
/// intent (Tasker, or the tap on a scheduled task's notification while the
/// app runs) went straight to handleAutomation, which read the closed
/// database: "Database is locked" was thrown out of it, nothing ran, nothing
/// waited, and Tasker got no answer. Now
/// another app is told the app is locked, and a scheduled task's tap runs
/// once the app is unlocked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const apiKey = 'zk_made-up-key-for-this-test-only';
  final en = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => L10nGlobal.update(en));
  const deeplink = MethodChannel('com.affluentlabs.zestssh/deeplink');

  late ProviderContainer container;
  late List<Map<Object?, Object?>> told;
  late _Service service;

  setUp(() async {
    told = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(deeplink, (call) async {
      if (call.method == 'setAutomationResult') told.add(call.arguments as Map<Object?, Object?>);
      return null;
    });
    FlutterSecureStorage.setMockInitialValues({
      'automation_api_keys': AutomationApiKey.encodeList([
        AutomationApiKey.fromSecret(id: 'k-1', label: 'tasker', secret: apiKey, createdAt: DateTime(2026)),
      ]),
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    service = _Service();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      automationServiceProvider.overrideWith((ref) {
        // As the real one: it reads the database, closed while locked.
        ref.watch(treeDatabaseProvider);
        return service;
      }),
    ]);
    // The encrypting lock is on and the app is locked: no database is open.
    expect(container.read(dbReadyProvider), isFalse);
    container.read(automationProvider.notifier).setEnabled(true);
  });

  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(deeplink, null);
  });

  test('a Tasker run while the app is locked is answered that the app is locked, not thrown out of the handler', () async {
    final run = container.read(automationProvider.notifier).handleAutomation({
      'action': 'execute',
      'key': apiKey,
      'connection_id': 'web-1',
      'command': 'uptime',
    });
    await expectLater(run, completes, reason: 'it threw "Database is locked" out of handleAutomation');
    expect(told.single['exit_code'], 1);
    expect(told.single['stdout'], contains('locked'));
    expect(service.ran, isEmpty);
  });

  test('a batch from Tasker while the app is locked is answered, not thrown', () async {
    final run = container.read(automationProvider.notifier).handleAutomation({
      'action': 'batch',
      'key': apiKey,
      'connection_ids': <Object?>['web-1', 'web-2'],
      'command': 'uptime',
    });
    await expectLater(run, completes);
    expect(told.single['stdout'], contains('locked'));
  });

  test('a scheduled task\'s tap while the app is locked runs once the app is unlocked', () async {
    await container.read(automationProvider.notifier).handleAutomation({
      'action': 'execute',
      'connection_id': 'web-1',
      'api_key_id': 'k-1',
      'scheduled_task_id': 'task-1',
      'command': 'uptime',
    });
    expect(service.ran, isEmpty, reason: 'nothing can run while the database is closed');

    // The person unlocks.
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(tree.close);
    await tree.scheduledTasksDao.upsert(ScheduledTasksCompanion(
      id: const Value('task-1'),
      name: const Value('Uptime'),
      action: const Value('execute'),
      connectionId: const Value('web-1'),
      command: const Value('uptime'),
      scheduleType: const Value('interval'),
      intervalMinutes: const Value(60),
      enabled: const Value(true),
      apiKeyId: const Value('k-1'),
      createdAt: Value(DateTime(2026, 11, 5)),
    ));
    container.read(databaseSessionProvider.notifier).seed(tree);
    for (var i = 0; i < 100 && service.ran.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.ran, ['uptime']);
    for (var i = 0; i < 100 && (await tree.scheduledTasksDao.getById('task-1'))?.lastRunAt == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect((await tree.scheduledTasksDao.getById('task-1'))?.lastRunAt, isNotNull, reason: 'its Last is written');
  });
}
