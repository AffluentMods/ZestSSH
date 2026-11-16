import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/deep_link_service.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Runs nothing.
class _Service implements AutomationService {
  @override
  Future<String?> resolveConnectionId(String labelOrId) async => labelOrId;

  @override
  Future<AutomationResult> executeCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool unattended = false,
    void Function(String chunk)? onOutput,
    Object? progress,
  }) async =>
      const AutomationResult(success: true, output: '', error: '', exitCode: 0, elapsed: Duration.zero);

  @override
  Future<Map<String, AutomationResult>> executeBatch({
    required List<String> connectionIds,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool parallel = true,
    bool unattended = false,
  }) async =>
      const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The log goes into Copy details, and a command can hold a password in ways no
/// scrub can know (`-pHunter2Secret`, `admin:S3cretPass`, `PGPASSWORD=...`: a
/// security review). The automation paths log how long a command
/// is, never what it says.
void main() {
  const secret = 'Hunter2Secret';
  const command = 'mysql -uroot -p$secret -h db.acme-internal.example';
  const apiKey = 'zk_made-up-key-any-host';
  late List<String> noted;

  setUp(() {
    noted = [];
    final level = Logger.root.level;
    Logger.root.level = Level.ALL;
    final listening = Logger.root.onRecord.listen((r) => noted.add(r.message));
    addTearDown(() {
      Logger.root.level = level;
      return listening.cancel();
    });
  });

  test('a run from an intent or a link: its command is not in the log', () async {
    FlutterSecureStorage.setMockInitialValues({
      'automation_api_keys': AutomationApiKey.encodeList([
        AutomationApiKey.fromSecret(id: 'k-1', label: 'tasker', secret: apiKey, createdAt: DateTime(2026, 10, 30)),
      ]),
    });
    SharedPreferences.setMockInitialValues(const {});
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      isProProvider.overrideWith((ref) => _Pro()),
      automationServiceProvider.overrideWithValue(_Service()),
    ]);
    addTearDown(container.dispose);
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(tree.close);
    container.read(databaseSessionProvider.notifier).seed(tree);
    final automation = container.read(automationProvider.notifier)..setEnabled(true);
    await automation.handleAutomation(
        {'action': 'execute', 'key': apiKey, 'connection_id': 'web-1', 'command': command, 'timeout': 5});
    await automation.handleAutomation({
      'action': 'batch',
      'key': apiKey,
      'connection_ids': ['web-1'],
      'command': command,
      'timeout': 5,
      'parallel': true,
    });
    expect(noted.any((l) => l.contains('EXECUTE')), isTrue, reason: 'it is still noted that one ran');
    expect(noted.any((l) => l.contains('BATCH')), isTrue);
    expect(noted.where((l) => l.contains(secret)), isEmpty);
  });

  test('a link refused by its person: its command is not in the log', () async {
    DeepLinkService.onAutomationRequested = (action, command, target, [variables = const {}]) async => false;
    addTearDown(() => DeepLinkService.onAutomationRequested = null);
    final link = Uri(scheme: 'zestssh', host: 'execute', queryParameters: {'connection': 'web-1', 'command': command, 'key': 'K'});
    expect(await DeepLinkService.extractAutomationParams(link), isNull);
    expect(noted.any((l) => l.contains('rejected by user')), isTrue);
    expect(noted.where((l) => l.contains(secret)), isEmpty);
  });
}
