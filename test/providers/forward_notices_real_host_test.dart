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
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

/// What is said about a port forward that did not start, or did (3.0),
/// with a real SSH session under it: why, from what starting it
/// threw, in the app's language, with its details. Every failure was said to
/// be the local port in use, in English, and a forward set to start with the
/// connection that did not start was only logged.
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (the one
/// test/features/orchards/certs/team_certificate_login_test.dart uses); its
/// own client key logs in. Skips itself when the server is not running.
/// Override the location with ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final sshPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  late bool up;
  SSHKeyPair? key;
  late AppDatabase tree;
  late ProviderContainer container;

  setUpAll(() async {
    try {
      final s = await Socket.connect(sshHost, sshPort, timeout: const Duration(seconds: 2));
      s.destroy();
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (up) key = SSHKeyPair.fromPem(file.readAsStringSync()).single;
    } catch (_) {
      up = false;
    }
  });

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
  });

  tearDown(() async {
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

  /// A port on this device nothing listens on now.
  Future<int> freePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  /// The test server, saved, with [rules] for it; its session, connected.
  Future<String> connected(List<({String id, int bindPort, bool autoStart})> rules, {int remotePort = 22}) async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-lab',
          label: 'lab-01',
          host: sshHost,
          port: Value(sshPort),
          createdAt: at,
          updatedAt: at,
        ));
    for (final r in rules) {
      await tree.into(tree.portForwardRules).insert(PortForwardRulesCompanion.insert(
            id: r.id,
            connectionId: 'h-lab',
            type: 'local',
            bindAddress: const Value('127.0.0.1'),
            bindPort: r.bindPort,
            remoteHost: '127.0.0.1',
            remotePort: remotePort,
            autoStart: Value(r.autoStart),
            label: Value('db tunnel ${r.id}'),
            createdAt: at,
          ));
    }
    sessions().debugShellFor = (connection) => SshService(
          host: sshHost,
          port: sshPort,
          username: user,
          keyPairs: [key!],
          onHostKeyVerify: (_, _, _) async => true,
        );
    final id = sessions().startSession((await tree.connectionsDao.getById('h-lab'))!)!;
    await until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.connected, 'connected');
    return id;
  }

  Future<PortForwardRule> ruleOf(String id) async =>
      (await tree.select(tree.portForwardRules)..where((r) => r.id.equals(id))).getSingle();

  test('a forward whose port on this device is taken says so, with its details; one that starts says it runs',
      () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(taken.close);
    final free = await freePort();
    final id = await connected([
      (id: 'r-taken', bindPort: taken.port, autoStart: false),
      (id: 'r-free', bindPort: free, autoStart: false),
    ]);

    await sessions().connectThenStartForward(await ruleOf('r-taken'));
    final failed = notices().first;
    expect(failed.severity, NotificationSeverity.error);
    expect(failed.title, en.pfStartFailedTitle('db tunnel r-taken'));
    expect(failed.body, en.pfFailedPortInUse(taken.port));
    expect(failed.details, contains('Starting a port forward'));
    expect(failed.details, contains('Local port: ${taken.port}'));
    expect(sessions().lastForwardError('r-taken'), isA<SocketException>());

    await sessions().connectThenStartForward(await ruleOf('r-free'));
    final started = notices().first;
    expect(started.severity, NotificationSeverity.success);
    expect(started.title, en.pfStartedTitle);
    expect(started.body, en.pfStartedBody('db tunnel r-free'));
    expect(sessions().lastForwardError('r-free'), isNull);

    // The port is free again: it starts, and what it threw before is gone.
    await taken.close();
    await sessions().connectThenStartForward(await ruleOf('r-taken'));
    expect(notices().first.title, en.pfStartedTitle);
    expect(sessions().lastForwardError('r-taken'), isNull);

    await sessions().stopSavedForward('r-taken');
    await sessions().stopSavedForward('r-free');
    await sessions().endSession(id);
  });

  test('a forward that runs and whose connections the host cannot make says so, once, with what the host said',
      () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final free = await freePort();
    // It leads to a port of the host that nothing listens on.
    final id = await connected([(id: 'r-dead', bindPort: free, autoStart: false)], remotePort: 1);
    await sessions().connectThenStartForward(await ruleOf('r-dead'));
    expect(notices().first.title, en.pfStartedTitle);

    Future<void> isNotMade() async {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, free);
      await socket.drain<void>().timeout(const Duration(seconds: 20));
      socket.destroy();
    }

    await isNotMade();
    await until(() => notices().first.title != en.pfStartedTitle, 'the notice');
    final notice = notices().first;
    expect(notice.severity, NotificationSeverity.warning);
    expect(notice.title, en.pfTroubleTitle('db tunnel r-dead'));
    expect(notice.body, startsWith('${en.pfHostCannotConnect('127.0.0.1:1')} '));
    expect(notice.body!.toLowerCase(), contains('refused'));
    expect(notice.details, contains('A connection through a port forward'));
    expect(notice.details, contains('Local port: $free'));

    // A program that goes on trying does not make it be said again.
    await isNotMade();
    await isNotMade();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(notices().where((n) => n.title == en.pfTroubleTitle('db tunnel r-dead')), hasLength(1));
    expect(notices().first.repeats, 1, reason: 'nor counted on the one that is there');

    await sessions().stopSavedForward('r-dead');
    await sessions().endSession(id);
  });

  test('a forward set to start with the connection that cannot start is told, with why', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(taken.close);
    final id = await connected([(id: 'r-auto', bindPort: taken.port, autoStart: true)]);
    await until(() => notices().isNotEmpty, 'the notice');
    final notice = notices().first;
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.title, en.pfStartFailedTitle('db tunnel r-auto'));
    expect(notice.body, en.pfFailedPortInUse(taken.port));
    expect(notice.details, isNotNull);
    await sessions().endSession(id);
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
