import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/demo_shell_service.dart';
import 'package:zestssh/services/review_prompt.dart';
import 'package:zestssh/services/ssh_service.dart';

/// The stores' rating prompt counts a session the person ended on a server
/// they reached: never one the app ended (opened again, closed unwatched,
/// a viewer's request, every session at once), and never this device's own
/// shell or the demo (found in a code review).
void main() {
  late AppDatabase tree;
  late ProviderContainer container;
  late _Prompt prompt;
  var demo = false;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    prompt = _Prompt();
    demo = false;
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
      reviewPromptProvider.overrideWithValue(prompt),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(activeSessionsProvider.notifier).debugShellFor = (_) => demo ? DemoShellService() : _Shell();
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web1',
          label: 'web-01',
          host: '10.50.0.5',
          port: const Value(23),
          protocol: const Value('telnet'),
          createdAt: at,
          updatedAt: at,
        ));
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);

  Future<String> open() async {
    final host = (await tree.connectionsDao.getById('h-web1'))!;
    final id = sessions().startSession(host, allowDuplicate: true)!;
    final clock = Stopwatch()..start();
    while (container.read(activeSessionsProvider)[id]?.status != SessionStatus.connected) {
      if (clock.elapsed > const Duration(seconds: 15)) fail('waited for the session');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return id;
  }

  test('a session the person ends counts; one the app ends does not', () async {
    await sessions().endSession(await open());
    expect(prompt.ended, 1);
    await sessions().endSession(await open(), byThePerson: false);
    expect(prompt.ended, 1, reason: 'ended by the app');
    await open();
    await open();
    await sessions().endAllSessions();
    expect(prompt.ended, 1, reason: 'every session at once');
  });

  test("the demo's session never counts", () async {
    demo = true;
    await sessions().endSession(await open());
    expect(prompt.ended, 0);
  });
}

class _Prompt implements ReviewPrompt {
  int ended = 0;

  @override
  Future<bool> sessionEnded({required Duration lasted, required bool byThePerson, required bool othersOpen}) async {
    ended++;
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

/// A shell that connects and goes away when asked.
class _Shell extends ShellService {
  final _state = StreamController<bool>.broadcast();
  bool _connected = false;

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
  Stream<Uint8List> get stdout => const Stream.empty();

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
