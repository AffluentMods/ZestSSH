import 'dart:async';
import 'dart:convert';

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
import 'package:zestssh/services/ssh_service.dart';

/// A character of more than one byte that the host's output splits between
/// two reads (two SSH packets, two pty reads) was shown as replacement
/// characters, because each chunk was decoded on its own
/// (terminal_providers.dart, handleOutput: Utf8Decoder.convert per chunk; the
/// SSH code's review found it). One decoder per connection
/// (Utf8Chunks) puts it together.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase tree;
  late ProviderContainer container;
  late _Shell shell;

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
    shell = _Shell();
    container.read(activeSessionsProvider.notifier).debugShellFor = (connection) => shell;
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 15)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<(String, SessionState)> connected() async {
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
    final host = (await tree.connectionsDao.getById('h-web1'))!;
    final id = container.read(activeSessionsProvider.notifier).startSession(host)!;
    await until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.connected, 'the session');
    return (id, container.read(activeSessionsProvider)[id]!);
  }

  test('a character split between two chunks of output is shown whole', () async {
    final (_, session) = await connected();
    final terminal = session.session!.terminal;
    // "café 中" in UTF-8, cut inside the two-byte e-acute and again
    // inside the three-byte CJK character, as two pty reads can cut it.
    final bytes = utf8.encode('café 中文');
    // c a f 0xC3 | 0xA9 ' ' 0xE4 0xB8 | 0xAD ...
    shell.out.add(Uint8List.fromList(bytes.sublist(0, 4)));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    shell.out.add(Uint8List.fromList(bytes.sublist(4, 8)));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    shell.out.add(Uint8List.fromList(bytes.sublist(8)));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final shown = terminal.buffer.lines[0].getText().trimRight();
    expect(shown.contains('�'), isFalse, reason: 'shown: "$shown"');
    expect(shown, 'café 中文');
  });

  test('output that ends inside a character shows one replacement for it', () async {
    final (_, session) = await connected();
    final terminal = session.session!.terminal;
    shell.out.add(Uint8List.fromList([...utf8.encode('end '), 0xE4, 0xB8]));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await shell.out.close();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(terminal.buffer.lines[0].getText().trimRight(), 'end �');
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

class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Shell extends ShellService {
  final _state = StreamController<bool>.broadcast();
  final out = StreamController<Uint8List>.broadcast();
  bool _connected = false;

  @override
  Future<void> connect() async {
    _connected = true;
    _state.add(true);
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _state.add(false);
  }

  @override
  Stream<Uint8List> get stdout => out.stream;

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
