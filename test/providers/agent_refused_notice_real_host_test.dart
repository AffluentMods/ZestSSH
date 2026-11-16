import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/redactor.dart';

/// A session to a host with "Forward agent" on, where the host refuses
/// agent forwarding, with a real SSH session under it: the session is there
/// (it failed for that), and its person is told once, in the app's
/// language, that the agent is not there and why. Nothing is said where
/// the host gives it, or where the switch is off.
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (tool/test_sshd.sh
/// starts it and makes the keys); `client_noagent_ed25519` is the key it
/// gives everything but agent forwarding. Skips itself when the server is
/// not running. Override the location with ZESTSSH_TEST_SSHD_HOST / _PORT /
/// _USER / _DIR.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final sshPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  late bool up;
  SSHKeyPair? noAgent;
  SSHKeyPair? free;
  late AppDatabase tree;
  late ProviderContainer container;

  setUpAll(() async {
    try {
      final s = await Socket.connect(sshHost, sshPort, timeout: const Duration(seconds: 2));
      s.destroy();
      final noAgentFile = File('$dir/client_noagent_ed25519');
      final freeFile = File('$dir/client_ed25519');
      up = noAgentFile.existsSync() && freeFile.existsSync();
      if (up) {
        noAgent = SSHKeyPair.fromPem(noAgentFile.readAsStringSync()).single;
        free = SSHKeyPair.fromPem(freeFile.readAsStringSync()).single;
      }
    } catch (_) {
      up = false;
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(autoReconnectEnabledProvider.notifier).state = false;
  });

  tearDown(() async {
    L10nGlobal.update(en);
    Redactor.instance.enabled = false;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  List<AppNotification> notices() => container.read(notificationCenterProvider).history;

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 20)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The test server, saved as web-01; its session, connected with [key],
  /// forwarding the agent or not.
  Future<String> connected(SSHKeyPair key, {required bool forwardAgent}) async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: sshHost,
          port: Value(sshPort),
          forwardAgent: Value(forwardAgent),
          createdAt: at,
          updatedAt: at,
        ));
    sessions().debugShellFor = (connection) => SshService(
          host: sshHost,
          port: sshPort,
          username: user,
          keyPairs: [key],
          forwardAgent: connection.forwardAgent,
          onHostKeyVerify: (_, _, _) async => true,
        );
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.connected, 'connected');
    return id;
  }

  test('the host refuses it: the session is there, and its person is told, once, what that means', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final id = await connected(noAgent!, forwardAgent: true);
    expect(container.read(activeSessionsProvider)[id]?.status, SessionStatus.connected);
    final told = notices().where((n) => n.title == en.agentRefusedTitle('web-01')).toList();
    expect(told, hasLength(1));
    expect(told.single.severity, NotificationSeverity.warning);
    expect(told.single.body, en.agentRefusedBody);
    expect(told.single.repeats, 1);
    await sessions().endSession(id);
  });

  test('while recording, the host is not named in it', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    Redactor.instance.enabled = true;
    final id = await connected(noAgent!, forwardAgent: true);
    final told = notices().where((n) => n.body == en.agentRefusedBody).toList();
    expect(told, hasLength(1));
    expect(told.single.title, isNot(contains('web-01')));
    expect(told.single.title, endsWith(' refused agent forwarding'));
    await sessions().endSession(id);
  });

  test('the host gives it, or the switch is off: nothing is said', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    for (final (key, forwardAgent) in [(free!, true), (noAgent!, false)]) {
      final id = await connected(key, forwardAgent: forwardAgent);
      // (Time for a notice that should not come.)
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(notices().where((n) => n.title.contains('agent forwarding')), isEmpty,
          reason: 'forwardAgent: $forwardAgent');
      await sessions().endSession(id);
      await tree.delete(tree.connections).go();
    }
  });

  test('in every language the app speaks, naming the host', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      expect(l10n.agentRefusedTitle('web-01'), contains('web-01'), reason: '$locale');
      if (locale.languageCode == 'en') continue;
      expect(l10n.agentRefusedTitle('web-01'), isNot(en.agentRefusedTitle('web-01')), reason: '$locale');
      expect(l10n.agentRefusedBody, isNot(en.agentRefusedBody), reason: '$locale');
    }
  });
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
