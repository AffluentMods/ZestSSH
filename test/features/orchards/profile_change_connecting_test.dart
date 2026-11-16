// Accounts on one computer, found in a review: a session still connecting as a
// change of profile ends all sessions never comes up, and leaves no login live.
import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
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
import 'package:zestssh/services/ssh_service.dart';

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

class _SlowShell extends ShellService {
  final gate = Completer<void>();
  var connecting = false;
  var disconnects = 0;
  final _out = StreamController<Uint8List>.broadcast();
  final _state = StreamController<bool>.broadcast();
  @override
  Future<void> connect() {
    connecting = true;
    return gate.future;
  }

  @override
  Future<void> disconnect() async => disconnects++;
  @override
  late final Stream<Uint8List> stdout = _out.stream;
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => gate.isCompleted && disconnects == 0;
  @override
  late final Stream<bool> connectionState = _state.stream;
  @override
  bool get exitedCleanly => true;
  @override
  bool get isEncryptedSsh => false;
}

void main() {
  late AppDatabase db;
  late ProviderContainer c;
  late _SlowShell shell;
  late ActiveSessionsNotifier sessions;
  late String id;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final prefs = await SharedPreferences.getInstance();
    c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
    ]);
    c.read(databaseSessionProvider.notifier).seed(db);
    final at = DateTime.utc(2026, 10, 30);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h', label: 'Prod DB', host: 'db.acme.example', protocol: const Value('ssh'), createdAt: at, updatedAt: at));
    shell = _SlowShell();
    sessions = c.read(activeSessionsProvider.notifier)..debugShellFor = (_) => shell;
    id = sessions.startSession((await db.connectionsDao.getById('h'))!)!;
    for (var i = 0; i < 500 && !shell.connecting; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(shell.connecting, isTrue);
  });

  tearDown(() async {
    c.dispose();
    await db.close();
  });

  test('connected just after all sessions ended, before the provider is built anew: it does not come up', () async {
    await sessions.endAllSessions();
    shell.gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final status = c.read(activeSessionsProvider)[id]?.status;
    expect(shell.disconnects, greaterThan(0), reason: 'A live login to the old account\'s host stays open, status $status, nothing can close it after the change');
  });

  test('connected after the provider was built anew: the connection goes', () async {
    await sessions.endAllSessions();
    c.invalidate(activeSessionsProvider);
    c.read(activeSessionsProvider);
    shell.gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(shell.disconnects, greaterThan(0), reason: 'if (!mounted) return leaves a live login nobody holds');
  });

  test('connected after what marked its ending has gone (two seconds): the connection goes', () async {
    await sessions.endAllSessions();
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    shell.gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(shell.disconnects, greaterThan(0));
    expect(c.read(activeSessionsProvider)[id], isNull);
  });

  test('ended before it got as far as dialling: it is never dialled', () async {
    final second = _SlowShell();
    sessions.debugShellFor = (_) => second;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final other = sessions.startSession((await db.connectionsDao.getById('h'))!, allowDuplicate: true)!;
    expect(other, isNot(id));
    await sessions.endSession(other, byThePerson: false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(second.connecting, isFalse);
  });

  test('its try failing after it ended says nothing to anyone', () async {
    await sessions.endAllSessions();
    shell.gate.completeError(StateError('no route to host'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(c.read(connectionErrorProvider), isNull);
    expect(c.read(activeSessionsProvider)[id]?.status, isNot(SessionStatus.error));
  });

  test('one left alone comes up, and stays up', () async {
    shell.gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.read(activeSessionsProvider)[id]?.status, SessionStatus.connected);
    expect(shell.disconnects, 0);
  });
}
