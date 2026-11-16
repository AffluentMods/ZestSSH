import 'package:drift/drift.dart' hide isNull, isNotNull;
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
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';

import '../helpers/orchard_db_fixture.dart';

/// Automation's "open" (a link, another app, a schedule; 3.0): the session
/// it opens is opened as unattended, so that what it signs in with besides
/// its host's own key (the key the host takes on a network, every jump
/// host's) is held to "Allow unattended runs" as that key is, and nothing is
/// asked (test/providers/unattended_session_test.dart). Its host's own key,
/// not allowed, is still refused before any session. The host is your
/// Tree's, and its session works in your Tree, whatever space is on screen
/// (it was read again from the space on screen, where a team space had no
/// such host).

/// Sessions asked for: the host, whether unattended, and the space it is to
/// work in.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final asked = <(String, bool, Space?)>[];

  @override
  String? startSession(
    Connection connection, {
    bool allowDuplicate = false,
    String? usernameOverride,
    String? initialCommand,
    String? asAccount,
    bool unattended = false,
    Space? space,
  }) {
    asked.add((connection.id, unattended, space));
    return null;
  }
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The team space of [db], open.
class _OneOrchard extends OrchardDatabasesNotifier {
  _OneOrchard(AppDatabase db) : super(OrchardDatabaseKeys(const FlutterSecureStorage())) {
    state = {kFixtureOrchardId: db};
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const apiKey = 'zk_made-up-key-for-this-test-only';
  late AppDatabase tree;
  late AppDatabase orchard;
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
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    orchard = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(orchard);
    for (final (id, allowed) in [('id-yes', true), ('id-no', false)]) {
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
          id: id, label: id, username: 'deploy', authMethod: 'publicKey', allowUnattended: Value(allowed), createdAt: at));
    }
    for (final (id, key) in [('h-allowed', 'id-yes'), ('h-walled', 'id-no')]) {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id, label: id, host: '$id.example.com', identityId: Value(key), createdAt: at, updatedAt: at));
    }
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      activeSessionsProvider.overrideWith(_Sessions.new),
      orchardDatabasesProvider.overrideWith((ref) => _OneOrchard(orchard)),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(automationProvider.notifier).setEnabled(true);
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
    await orchard.close();
  });

  _Sessions sessions() => container.read(activeSessionsProvider.notifier) as _Sessions;

  test('the session it opens is opened as unattended', () async {
    await container
        .read(automationProvider.notifier)
        .handleAutomation({'action': 'open', 'key': apiKey, 'connection_id': 'h-allowed', 'timeout': 1});
    expect(sessions().asked, [('h-allowed', true, const TreeSpace())]);
  });

  test("its host's own key, not allowed: refused before any session", () async {
    await container
        .read(automationProvider.notifier)
        .handleAutomation({'action': 'open', 'key': apiKey, 'connection_id': 'h-walled', 'timeout': 1});
    expect(sessions().asked, isEmpty);
    expect(container.read(automationProvider).blocked, AutomationBlocked.keyNotUnattended);
  });

  // Every other way of opening a Telnet host asks first; here nobody is
  // there to be asked (found in a security review).
  test('a Telnet host is not opened with nobody there, and the refusal says why', () async {
    final at = DateTime(2026, 11, 12);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
        id: 'h-switch',
        label: 'switch-01',
        host: 'switch-01.example.com',
        protocol: const Value('telnet'),
        identityId: const Value('id-yes'),
        createdAt: at,
        updatedAt: at));
    await container
        .read(automationProvider.notifier)
        .handleAutomation({'action': 'open', 'key': apiKey, 'connection_id': 'h-switch', 'timeout': 1});
    expect(sessions().asked, isEmpty);
    expect(container.read(automationProvider).blocked, AutomationBlocked.plaintextHost);
  });

  // A screen is for someone to look at, and its questions have nobody to answer
  // them (4.0: it opened and waited).
  test('a remote screen, VNC or RDP, is not opened with nobody there, and the refusal says why', () async {
    final at = DateTime(2026, 11, 13);
    for (final protocol in ['vnc', 'rdp']) {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-$protocol',
          label: 'desk-$protocol',
          host: 'desk.example.com',
          protocol: Value(protocol),
          identityId: const Value('id-yes'),
          createdAt: at,
          updatedAt: at));
      await container
          .read(automationProvider.notifier)
          .handleAutomation({'action': 'open', 'key': apiKey, 'connection_id': 'h-$protocol', 'timeout': 1});
      expect(sessions().asked, isEmpty, reason: protocol);
      expect(container.read(automationProvider).blocked, AutomationBlocked.screenHost, reason: protocol);
    }
  });

  test("with a team space on screen: the host is read from your Tree, its key's switch too, and its session works "
      'in your Tree', () async {
    container.read(activeSpaceProvider.notifier).state = const OrchardSpace(kFixtureOrchardId);
    final automation = container.read(automationProvider.notifier);
    await automation.handleAutomation({'action': 'open', 'key': apiKey, 'connection_id': 'h-allowed', 'timeout': 1});
    expect(sessions().asked, [('h-allowed', true, const TreeSpace())]);
    await automation.handleAutomation({'action': 'open', 'key': apiKey, 'connection_id': 'h-walled', 'timeout': 1});
    expect(sessions().asked, hasLength(1));
    expect(container.read(automationProvider).blocked, AutomationBlocked.keyNotUnattended);
  }, skip: !kOrchardsEnabled);
}
