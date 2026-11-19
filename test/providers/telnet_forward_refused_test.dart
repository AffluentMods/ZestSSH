import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A saved port forward on a host that is reached over Telnet. Telnet
/// carries no forward, and nothing encrypts it: Start (Connect and start)
/// opened a Telnet session to the host with no question, and only once it
/// was connected said that the connection does not forward ports. The
/// forward is now refused before any session is opened.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;
  late List<String> shellsMade;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    shellsMade = [];
    // Any session that is opened gets a shell that fails to connect at once,
    // so that one opened by mistake shows here and does not wait.
    container.read(activeSessionsProvider.notifier).debugShellFor = (connection) {
      shellsMade.add(connection.id);
      return _FailingShell();
    };
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  List<AppNotification> notices() => container.read(notificationCenterProvider).history;

  Future<PortForwardRule> savedForwardOn(String protocol) async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-switch',
          label: 'core-switch',
          host: '10.50.0.2',
          port: const Value(23),
          protocol: Value(protocol),
          createdAt: at,
          updatedAt: at,
        ));
    await tree.into(tree.portForwardRules).insert(PortForwardRulesCompanion.insert(
          id: 'r-web',
          connectionId: 'h-switch',
          type: 'local',
          bindAddress: const Value('127.0.0.1'),
          bindPort: 18080,
          remoteHost: '127.0.0.1',
          remotePort: 80,
          label: const Value('switch web'),
          createdAt: at,
        ));
    return (tree.select(tree.portForwardRules)..where((r) => r.id.equals('r-web'))).getSingle();
  }

  test('Connect and start on a Telnet host opens no session and says the connection does not forward ports',
      () async {
    final rule = await savedForwardOn('telnet');
    await sessions().connectThenStartForward(rule);
    expect(shellsMade, isEmpty, reason: 'no Telnet session was opened');
    expect(container.read(activeSessionsProvider), isEmpty);
    final said = notices().first;
    expect(said.severity, NotificationSeverity.warning);
    expect(said.title, en.pfStartFailedTitle('switch web'));
    expect(said.body, en.pfNoForwarding);
  });

  test('an SSH host is still connected to for its forward', () async {
    final rule = await savedForwardOn('ssh');
    await sessions().connectThenStartForward(rule);
    expect(shellsMade, ['h-switch']);
  });
}

/// A shell whose connection fails at once.
class _FailingShell extends ShellService {
  @override
  Future<void> connect() async => throw StateError('refused');
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => false;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No networks are set up here: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
