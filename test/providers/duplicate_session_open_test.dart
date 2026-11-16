// A host with two sessions is open while either of them is (a bug in
// 2.2.1: after a host was duplicated and its first session closed, the
// home screen showed the host as inactive and open nowhere, though its
// second session was still open).
//
// The app's own sessions, started and ended the way the app does it,
// against a host on this machine (a TCP server reached with the Telnet
// shell, so no SSH server is needed).

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

import '../features/sharing/share_fakes.dart' show until;

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late ProviderContainer container;
  late AppDatabase db;
  late ServerSocket server;
  final sockets = <Socket>[];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {}, onError: (Object _) {});
    });
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(db);
    final at = DateTime(2026, 10, 2);
    for (final id in ['h1', 'h2']) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id == 'h1' ? 'web-01' : 'web-02',
            host: '127.0.0.1',
            port: Value(server.port),
            protocol: const Value('telnet'),
            createdAt: at,
            updatedAt: at,
          ));
    }
  });

  tearDown(() async {
    container.dispose();
    for (final s in sockets) {
      s.destroy();
    }
    sockets.clear();
    await server.close();
    await db.close();
  });

  Map<String, SessionState> sessions() => container.read(activeSessionsProvider);
  ActiveSessionsNotifier notifier() => container.read(activeSessionsProvider.notifier);

  Future<String> open(String host, {bool duplicate = false}) async {
    final connection = (await db.connectionsDao.getById(host))!;
    // (A session's id carries the time it was started at.)
    await Future<void>.delayed(const Duration(milliseconds: 3));
    final id = notifier().startSession(connection, allowDuplicate: duplicate)!;
    await until(() => sessions()[id]?.status == SessionStatus.connected, what: 'the session to $host');
    return id;
  }

  test('a host is open while any of its sessions is', () async {
    final first = await open('h1');
    expect(hostIsOpen(sessions(), 'h1'), isTrue);
    expect(hostIsOpen(sessions(), 'h2'), isFalse);

    final second = await open('h1', duplicate: true);
    expect(second, isNot(first));
    expect(sessions().keys, containsAll([first, second]));

    // The first one is closed: the host is still open, in the second.
    await notifier().endSession(first);
    expect(sessions()[second]?.status, SessionStatus.connected);
    expect(sessions()[second]?.connectionId, 'h1');
    expect(hostIsOpen(sessions(), 'h1'), isTrue, reason: 'the duplicate is still open');
    // Also once the closed one is gone from the list.
    await until(() => !sessions().containsKey(first), what: 'the closed session to go');
    expect(sessions().keys, [second]);
    expect(hostIsOpen(sessions(), 'h1'), isTrue);

    // The second one is closed as well: now it is not.
    await notifier().endSession(second);
    expect(hostIsOpen(sessions(), 'h1'), isFalse);
  });
}
