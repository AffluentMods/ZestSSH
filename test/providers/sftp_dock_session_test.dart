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
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

/// What the SFTP dock of a session whose connection dropped asks of the
/// sessions (4.0): when the connection dropped,
/// which it says, and the host's files in a session of their own ("Open
/// SFTP on its own"), on a connection of their own and with no terminal.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase tree;
  late ProviderContainer container;
  // The shells the app is given, in turn.
  late List<_Shell> shells;

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
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(milliseconds: 20);
    shells = [];
  });

  tearDown(() async {
    ActiveSessionsNotifier.debugReconnectDelay = null;
    sessionClock = DateTime.now;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 15)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// web-01, saved with [protocol], and a session of it, connected. Where
  /// [files], every shell after the terminal's is one for a session of the
  /// host's files.
  Future<String> connected({String protocol = 'ssh', bool files = true}) async {
    final at = DateTime(2026, 11, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web1',
          label: 'web-01',
          host: '10.50.0.5',
          protocol: Value(protocol),
          createdAt: at,
          updatedAt: at,
        ));
    // The terminal's shell, then those of sessions of the host's files: an
    // SSH connection that signs in for files only, as the app's is.
    sessions().debugShellFor = (connection) {
      final shell = shells.isEmpty || !files ? _Shell() : _FilesShell();
      shells.add(shell);
      return shell;
    };
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web1'))!)!;
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the session');
    return id;
  }

  test("when a session's connection drops by itself, it says when, until it is connected again", () async {
    container.read(autoReconnectEnabledProvider.notifier).state = true;
    final id = await connected(files: false);
    expect(sessions().droppedAt(id), isNull, reason: 'connected, and never dropped');

    sessionClock = () => DateTime(2026, 11, 12, 9, 41);
    shells.first.drop(because: hostClosedConnection);
    await until(() => stateOf(id)?.status != SessionStatus.connected, 'the drop');
    expect(sessions().droppedAt(id), DateTime(2026, 11, 12, 9, 41));
    expect(stateOf(id)!.dropped, isTrue);

    // Connected again by itself: nothing is dropped any more.
    sessionClock = DateTime.now;
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected again');
    expect(sessions().droppedAt(id), isNull);
    await sessions().endSession(id);
    expect(sessions().droppedAt(id), isNull);
  });

  test("the host's files in a session of their own: files only, on a connection of their own, signed in as the "
      'session was; a second ask gives the same one', () async {
    final id = await connected();
    expect(sessions().isFilesOnly(id), isFalse);

    final files = await sessions().openFilesLike(id);
    expect(files, isNotNull);
    expect(files, isNot(id));
    expect(sessions().isFilesOnly(files!), isTrue);
    expect(stateOf(files)!.connectionId, 'h-web1');
    await until(() => stateOf(files)?.status == SessionStatus.connected, 'the files session');
    expect(shells, hasLength(2), reason: 'a connection of its own');
    expect(shells.last.forFiles, isTrue, reason: 'signed in for files only, no terminal asked for');
    expect(shells.first.forFiles, isFalse);
    expect(stateOf(id)!.status, SessionStatus.connected, reason: "the terminal's session is as it was");

    expect(await sessions().openFilesLike(id), files, reason: 'the one open already');
    expect(shells, hasLength(2));
    await sessions().endSession(files);
    await sessions().endSession(id);
  });

  test('a host that is no longer saved has no files to open on its own', () async {
    final id = await connected();
    await tree.connectionsDao.deleteConnection('h-web1');
    expect(await sessions().openFilesLike(id), isNull);
    expect(shells, hasLength(1));
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

/// A shell the test drives: it connects, and its connection can drop.
class _Shell extends ShellService implements ShellEndReason {
  final _state = StreamController<bool>.broadcast();
  final _out = StreamController<Uint8List>.broadcast();
  final _reason = Completer<String?>();
  bool _connected = false;

  void drop({String? because}) {
    if (!_reason.isCompleted) _reason.complete(because);
    _connected = false;
    _state.add(false);
  }

  @override
  Future<String?> get endReason => _reason.future;

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

  @override
  bool get isEncryptedSsh => true;

  /// Whether it was signed in for files only.
  bool get forFiles => false;
}

/// As [_Shell], an SSH connection as far as the sessions can tell, which
/// signs in for files only where it is asked to.
class _FilesShell extends _Shell implements SshService {
  bool _forFiles = false;

  @override
  bool get forFiles => _forFiles;

  @override
  Future<void> connectForFiles({String? notice}) async {
    _forFiles = true;
    await connect();
  }

  @override
  String get username => 'deploy';

  @override
  bool get agentForwardingRefused => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
