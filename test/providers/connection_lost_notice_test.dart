import 'dart:async';

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
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../helpers/fake_notifications_plugin.dart';

/// A session whose connection dropped by itself, told of as Settings says
/// (found while comparing the five versions). Settings has a
/// "Connection lost" switch under Notifications, on a phone and on a
/// computer, and nothing read it: a phone sent its system notification
/// whatever the switch said, and a computer, which has none of the app's,
/// never told of it at all, so a session that dropped in a tab behind the one
/// in front went unseen until its tab was opened.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;
  late List<_Shell> shells;
  final system = <(String, String)>[];

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
    shells = [];
    container.read(activeSessionsProvider.notifier).debugShellFor = (connection) {
      final shell = _Shell();
      shells.add(shell);
      return shell;
    };
    system.clear();
    NotificationService.debugShown = (title, body) => system.add((title, body));
  });

  tearDown(() async {
    NotificationService.debugShown = null;
    debugConnectionLostOnComputer = null;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];
  List<(NotificationSeverity, String, String?)> notices() => [
        for (final n in container.read(notificationCenterProvider).history.reversed) (n.severity, n.title, n.body),
      ];

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 15)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// web-01 (or [label]), connected, and the session it is open in.
  Future<String> connected([String id = 'h-web1', String label = 'web-01']) async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: '10.50.0.5',
          port: const Value(23),
          protocol: const Value('telnet'),
          createdAt: at,
          updatedAt: at,
        ));
    final host = (await tree.connectionsDao.getById(id))!;
    final session = sessions().startSession(host)!;
    await until(() => stateOf(session)?.status == SessionStatus.connected, 'the session');
    return session;
  }

  /// [shell]'s connection drops by itself, and the session says so.
  Future<void> drop(String session, _Shell shell) async {
    shell.drop();
    await until(() => stateOf(session)?.status == SessionStatus.disconnected, 'the drop');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test("on a phone, the system's notification, while the switch is on, and nothing once it is off", () async {
    debugConnectionLostOnComputer = false;
    final first = await connected();
    await drop(first, shells.last);
    expect(system, [(en.connectionLostTitle, en.connectionLostEnded('web-01'))]);
    expect(notices(), isEmpty, reason: "a phone's is the system's");

    system.clear();
    await container.read(settingsUpdaterProvider).setNotifyConnectionLost(false);
    final second = await connected('h-web2', 'web-02');
    await drop(second, shells.last);
    expect(system, isEmpty, reason: 'it was told of with the switch off');
  });

  test("on a computer, one of the app's notices for a session not on screen, none for one in the tab in front, and "
      'nothing once the switch is off', () async {
    debugConnectionLostOnComputer = true;
    final first = await connected();
    container.read(workTabsProvider.notifier).clearActiveTab();
    await drop(first, shells.last);
    expect(notices(), [(NotificationSeverity.warning, en.connectionLostTitle, en.connectionLostEnded('web-01'))],
        reason: 'a computer never told of it');
    expect(system, isEmpty, reason: "a computer has no system notification of the app's");

    final second = await connected('h-web2', 'web-02');
    final tabs = container.read(workTabsProvider.notifier);
    tabs.setActiveTab(tabs.tabContaining(second)!.id);
    await drop(second, shells.last);
    expect(notices(), hasLength(1), reason: 'its pane, in front, says so itself');

    await container.read(settingsUpdaterProvider).setNotifyConnectionLost(false);
    final third = await connected('h-web3', 'web-03');
    container.read(workTabsProvider.notifier).clearActiveTab();
    await drop(third, shells.last);
    expect(notices(), hasLength(1), reason: 'the switch is off');
  });

  test("on a computer whose person turned on system notifications (4.0): the system's notification as well while "
      'the window is not in front, even for the tab in front; none while the window is in front', () async {
    debugConnectionLostOnComputer = true;
    var front = false;
    await computerWithSystemNotices(inFront: () => front);
    addTearDown(NotificationService.debugReset);
    NotificationService.debugShown = (title, body) => system.add((title, body));
    // (The tabs are there before the session, so that it has one.)
    final tabs = container.read(workTabsProvider.notifier);
    final first = await connected();
    tabs.setActiveTab(tabs.tabContaining(first)!.id);
    await drop(first, shells.last);
    expect(system, [(en.connectionLostTitle, en.connectionLostEnded('web-01'))],
        reason: 'its pane says so, but the window is in the tray');
    expect(notices(), isEmpty, reason: 'its pane, in front, says so itself');

    front = true;
    final second = await connected('h-web2', 'web-02');
    container.read(workTabsProvider.notifier).clearActiveTab();
    await drop(second, shells.last);
    expect(system, hasLength(1), reason: "the window is in front: the app's notice is in sight");
    expect(notices(), hasLength(1));

    front = false;
    await container.read(settingsUpdaterProvider).setNotifyConnectionLost(false);
    final third = await connected('h-web3', 'web-03');
    await drop(third, shells.last);
    expect(system, hasLength(1), reason: 'the Connection lost switch is off');
  });

  test('a session ended by its person is told of nowhere', () async {
    debugConnectionLostOnComputer = true;
    final first = await connected();
    container.read(workTabsProvider.notifier).clearActiveTab();
    await sessions().endSession(first);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notices(), isEmpty);
    expect(system, isEmpty);
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

/// A shell the test drives: it connects, and its connection can drop.
class _Shell extends ShellService implements ShellEndReason {
  final _state = StreamController<bool>.broadcast();
  final _out = StreamController<Uint8List>.broadcast();
  bool _connected = false;

  void drop() {
    _connected = false;
    _state.add(false);
  }

  @override
  Future<String?> get endReason async => null;

  @override
  Future<void> connect() async {
    _connected = true;
    _state.add(true);
  }

  @override
  Future<void> disconnect() async {
    if (!_connected) return;
    _connected = false;
    _state.add(false);
  }

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(Uint8List data) {}

  @override
  void resize(int width, int height) {}

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> get connectionState => _state.stream;

  @override
  bool get exitedCleanly => false;
}
