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
import 'package:zestssh/services/ssh_service.dart';

/// What a host's output may do to the app's terminal (found
/// in a security review). A host sized the terminal with
/// ESC[8;rows;cols t, to any size: every line of the scrollback was made that
/// wide at once, so one line of output stopped the app; the size was also
/// told back to the host as the window's. And the title a host sets was shown
/// as it came, control characters, direction overrides and all.
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

  /// A session open on web-01: its id and its state.
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

  test('a host does not size the terminal: ESC[8;rows;cols t is left alone, a size of any number of columns too, '
      'and nothing is told back to the host', () async {
    final (_, session) = await connected();
    final terminal = session.session!.terminal;
    terminal.resize(100, 30);
    shell.sizes.clear();
    terminal.write('\x1b[8;40;120t');
    terminal.write('\x1b[8;50;999999t');
    terminal.write('\x1b[8;9999999;80t');
    terminal.write('after\r\n');
    expect((terminal.viewWidth, terminal.viewHeight), (100, 30));
    expect(shell.sizes, isEmpty);
    expect(terminal.buffer.lines.length, lessThan(1000), reason: 'no rows were made for it');
  });

  test('the title a host sets is shown without control characters, direction overrides or invisible '
      'characters, and no longer than 120 characters', () async {
    final (id, session) = await connected();
    final terminal = session.session!.terminal;
    String? title() => container.read(terminalTitleProvider(id));

    terminal.write('\x1b]0;deploy@web-01: ~/app\x07');
    expect(title(), 'deploy@web-01: ~/app');

    terminal.write('\x1b]2;invoice\u202Etxt.exe\u200B \u0085done\x07');
    expect(title(), 'invoicetxt.exe done');

    terminal.write('\x1b]0;${'x' * 500}\x07');
    expect(title(), '${'x' * kTerminalTitleMax}\u2026');
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

/// A shell that connects and stays, and keeps the sizes it is told.
class _Shell extends ShellService {
  final _state = StreamController<bool>.broadcast();
  final sizes = <(int, int)>[];
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
  Stream<Uint8List> get stdout => const Stream.empty();

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(Uint8List data) {}

  @override
  void resize(int width, int height) => sizes.add((width, height));

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> get connectionState => _state.stream;

  @override
  bool get exitedCleanly => false;
}
