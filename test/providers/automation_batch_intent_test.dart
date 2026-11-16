import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
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

/// Runs nothing: says which hosts a batch was run on.
class _Service implements AutomationService {
  final batches = <List<String>>[];

  @override
  Future<String?> resolveConnectionId(String labelOrId) async => labelOrId == 'web-1' ? 'id-web-1' : null;

  @override
  Future<Map<String, AutomationResult>> executeBatch({
    required List<String> connectionIds,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool parallel = true,
    bool unattended = false,
  }) async {
    batches.add(connectionIds);
    return const {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A batch from Android's intent runs (found in a
/// security review): Android hands its hosts over as a list of objects, which
/// a cast to a list of text threw on, so a batch from Tasker never ran, and
/// a key held to one host could not even be refused properly.
void main() {
  const anyHost = 'zk_made-up-key-any-host';
  const oneHost = 'zk_made-up-key-one-host';
  late ProviderContainer container;
  late _Service service;

  setUp(() async {
    final at = DateTime(2026, 10, 16);
    FlutterSecureStorage.setMockInitialValues({
      'automation_api_keys': AutomationApiKey.encodeList([
        AutomationApiKey.fromSecret(id: 'k-1', label: 'tasker', secret: anyHost, createdAt: at),
        AutomationApiKey.fromSecret(id: 'k-2', label: 'one', secret: oneHost, createdAt: at, scopeConnectionId: 'id-web-1'),
      ]),
    });
    SharedPreferences.setMockInitialValues(const {});
    service = _Service();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      isProProvider.overrideWith((ref) => _Pro()),
      automationServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);
    // The app is unlocked: its database is open (nothing runs while it is not).
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(tree.close);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(automationProvider.notifier).setEnabled(true);
  });

  /// [hosts] as the platform channel hands them over: a list of objects.
  Map<String, dynamic> intent(String key, List<Object?> hosts) =>
      {'action': 'batch', 'key': key, 'connection_ids': hosts, 'command': 'uptime', 'timeout': 5, 'parallel': true};

  test('a batch from an intent runs on its hosts', () async {
    await container.read(automationProvider.notifier).handleAutomation(intent(anyHost, <Object?>['web-1', 'db-1']));
    expect(service.batches, [
      ['web-1', 'db-1'],
    ]);
  });

  test('a key held to one host: a batch on it runs, one on another host is refused as such', () async {
    final automation = container.read(automationProvider.notifier);
    await automation.handleAutomation(intent(oneHost, <Object?>['web-1']));
    expect(service.batches, [
      ['web-1'],
    ]);
    await automation.handleAutomation(intent(oneHost, <Object?>['db-1']));
    expect(service.batches, hasLength(1));
    expect(container.read(automationProvider).blocked, AutomationBlocked.otherHost);
  });
}
