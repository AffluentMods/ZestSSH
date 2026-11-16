// The folder a terminal is in (4.0, "SFTP: sync with the terminal's folder"),
// with the app's own sessions: what the host's shell says with OSC 7 or
// iTerm2's OSC 1337;CurrentDir= is kept for the session on every tier
// (command history, a Squeezed feature, was the only one that read it, and
// read it only where it was paid for and recording), said again only when it
// changed, and forgotten when the session ends.
//
// The host is a TCP server on this machine reached with the Telnet shell, as
// in broadcast_typing_test.dart: what it writes is what the terminal reads.

import 'dart:convert';
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
import 'package:zestssh/providers/terminal_folder_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

import '../features/sharing/share_fakes.dart' show until;

class _Free extends StateNotifier<bool> implements ProStatusNotifier {
  _Free() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ServerSocket server;
  late AppDatabase db;
  late ProviderContainer container;
  final hosts = <Socket>[];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    // Command history's switch is on: it is not what the folder waits for.
    SharedPreferences.setMockInitialValues(const {'command_history_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      hosts.add(socket);
      socket.listen((_) {}, onError: (Object _) {});
    });
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Free()),
        isAppLockedProvider.overrideWith((ref) => _Lock()),
      ],
    );
    container.read(databaseSessionProvider.notifier).seed(db);
    final at = DateTime(2026, 11, 15);
    await db
        .into(db.connections)
        .insert(
          ConnectionsCompanion.insert(
            id: 'h1',
            label: 'web-01',
            host: '127.0.0.1',
            port: Value(server.port),
            protocol: const Value('telnet'),
            createdAt: at,
            updatedAt: at,
          ),
        );
  });

  tearDown(() async {
    container.dispose();
    for (final h in hosts) {
      h.destroy();
    }
    hosts.clear();
    await server.close();
    await db.close();
  });

  test('on the free tier the folder the shell says is kept for its session, said again only when it changes, and '
      'forgotten when the session ends', () async {
    final notifier = container.read(activeSessionsProvider.notifier);
    final id = notifier.startSession((await db.connectionsDao.getById('h1'))!)!;
    await until(
      () => container.read(activeSessionsProvider)[id]?.status == SessionStatus.connected && hosts.isNotEmpty,
      what: 'the session',
    );
    expect(container.read(terminalFolderProvider(id)), isNull, reason: 'nothing said yet');

    final heard = <String?>[];
    final sub = container.listen<String?>(terminalFolderProvider(id), (_, now) => heard.add(now));
    addTearDown(sub.close);
    final host = hosts.single;

    // OSC 7, at a prompt.
    host.add(utf8.encode('\x1b]7;file://web-01/srv/app/My%20Site\x07deploy@web-01:~\$ '));
    await until(() => container.read(terminalFolderProvider(id)) == '/srv/app/My Site', what: 'OSC 7');

    // Said again at the next prompt, the same: not told again.
    host.add(utf8.encode('\x1b]7;file://web-01/srv/app/My%20Site\x07\r\n\$ '));
    // iTerm2's way, split across two writes.
    host.add(utf8.encode('\x1b]1337;Current'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    host.add(utf8.encode('Dir=/var/log\x1b\\\$ '));
    await until(() => container.read(terminalFolderProvider(id)) == '/var/log', what: 'OSC 1337;CurrentDir=');
    expect(heard, ['/srv/app/My Site', '/var/log']);

    await notifier.endSession(id);
    expect(container.read(terminalFolderProvider(id)), isNull);
  });
}
