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
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/ssh_service.dart';

/// Hosts that give files only, against what OpenSSH really does (SFTP-only
/// hosts in the big release). The server is the
/// WSL test sshd that gives files only, on 127.0.0.1:2287 (tool/test_sshd.sh
/// starts it: ForceCommand internal-sftp in a Match block, every session
/// starting in a folder of its own that holds hello.txt); its account and
/// client key are those of the other test servers. A shell or a command
/// asked of it is refused with "This service allows sftp connections only."
/// and the status 1. The plain one on 2299 has no SFTP at all, and its
/// `client_forced_ed25519` runs one command whatever is asked for, which
/// prints a word and ends at once.
///
/// Skips itself where the servers are not running. Override the location
/// with ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR and
/// ZESTSSH_TEST_SFTPONLY_SSHD_PORT.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final filesPort = int.tryParse(env['ZESTSSH_TEST_SFTPONLY_SSHD_PORT'] ?? '') ?? 2287;
  final plainPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  late bool filesUp;
  late bool plainUp;
  SSHKeyPair? key;
  SSHKeyPair? forced;
  late AppDatabase tree;
  late ProviderContainer container;

  Future<bool> listening(int port) async {
    try {
      final s = await Socket.connect(sshHost, port, timeout: const Duration(seconds: 2));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  setUpAll(() async {
    final keyFile = File('$dir/client_ed25519');
    final forcedFile = File('$dir/client_forced_ed25519');
    final keys = keyFile.existsSync() && forcedFile.existsSync();
    if (keys) {
      key = SSHKeyPair.fromPem(keyFile.readAsStringSync()).single;
      forced = SSHKeyPair.fromPem(forcedFile.readAsStringSync()).single;
    }
    filesUp = keys && await listening(filesPort);
    plainUp = keys && await listening(plainPort);
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
  });

  tearDown(() async {
    sessionClock = DateTime.now;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 20)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// files-01, saved with [protocol], at [port], and a session to it signed
  /// in with [signIn] (the plain client key where none is given).
  Future<String> started(String protocol, {int? port, SSHKeyPair? signIn}) async {
    final at = DateTime(2026, 10, 30);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-files',
          label: 'files-01',
          host: sshHost,
          port: Value(port ?? filesPort),
          protocol: Value(protocol),
          createdAt: at,
          updatedAt: at,
        ));
    sessions().debugShellFor = (connection) => SshService(
          host: sshHost,
          port: connection.port,
          username: user,
          keyPairs: [signIn ?? key!],
          onHostKeyVerify: (_, _, _) async => true,
        );
    return sessions().startSession((await tree.connectionsDao.getById('h-files'))!)!;
  }

  /// The text the session's terminal holds.
  String screen(String id) => lastRows(stateOf(id)!.session!.terminal).join('\n');

  test('a host saved as SFTP only: signed in with no terminal and no shell, its terminal says so, and its files are '
      "listed on the session's own connection", () async {
    if (!filesUp) {
      markTestSkipped('no SFTP-only test sshd at $sshHost:$filesPort');
      return;
    }
    final id = await started('sftp');
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected');
    expect(sessions().isFilesOnly(id), isTrue);
    final shell = stateOf(id)!.session!.shell as SshService;
    expect(shell.filesOnly, isTrue);
    // Never blank: one dim line says what it is.
    await until(() => screen(id).contains(en.sessionFilesOnlyLine), 'the line saying it is files only');

    final sftp = SftpService(shell.client);
    await sftp.open();
    final folder = await sftp.getHomeDirectory();
    expect(folder, endsWith('/sftponly/files'), reason: 'where its server starts every session');
    expect([for (final e in await sftp.listDirectory(folder)) e.name], containsAll(['hello.txt', 'reports']));
    await sftp.close();

    // Nothing is typed into it: there is no shell.
    expect(sessions().sendInput(id, Uint8List.fromList('ls\n'.codeUnits)), isFalse);
    // Still connected some seconds on: no shell ended under it.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(stateOf(id)?.status, SessionStatus.connected);
    expect(sessions().terminalRefusalOf(id), isNull);
    await sessions().endSession(id);
  });

  test('a connection test of a host that is SFTP only: signed in, its SFTP opened and its first folder listed, in '
      "the words that say so; a server with no SFTP fails it in SFTP's words", () async {
    if (!filesUp) {
      markTestSkipped('no SFTP-only test sshd at $sshHost:$filesPort');
      return;
    }
    final client = SSHClient(await SSHSocket.connect(sshHost, filesPort), username: user, identities: [key!]);
    addTearDown(() async {
      client.close();
      await client.done.catchError((_) {});
    });
    await client.authenticated;
    final listed = await sftpFirstFolder(client);
    expect(listed.folder, endsWith('/sftponly/files'));
    expect(listed.entries, greaterThanOrEqualTo(2), reason: 'hello.txt and reports');
    expect(en.connectionTestSftpWorks(3, 41, ''),
        'Connected: TCP 3ms, full handshake 41ms. SFTP works (its first folder was listed), and this host gives no '
        'terminal.');
    // The connection is left as it was: SFTP can be opened on it again.
    expect((await sftpFirstFolder(client)).folder, listed.folder);

    if (!plainUp) return;
    final plain = SSHClient(await SSHSocket.connect(sshHost, plainPort), username: user, identities: [key!]);
    addTearDown(() async {
      plain.close();
      await plain.done.catchError((_) {});
    });
    await plain.authenticated;
    Object? failure;
    try {
      await sftpFirstFolder(plain);
    } catch (e) {
      failure = e;
    }
    expect(failure, isA<SSHChannelRequestError>());
    expect(sftpStartFailure(failure!, l10n: en),
        'The host did not start SFTP. Its server may not offer SFTP, or may allow no more sessions.');
  });

  test('a normal SSH host whose server gives files only: its session ends with the status 1 and the server\'s own '
      'words, is said to give no terminal, and Open its files opens it as files only in its place', () async {
    if (!filesUp) {
      markTestSkipped('no SFTP-only test sshd at $sshHost:$filesPort');
      return;
    }
    final id = await started('ssh');
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the end of the session');
    final ended = stateOf(id)!;
    expect(ended.dropped, isTrue);
    final how = sessionEnded(ended.dropCause);
    expect(how?.exitCode, 1);
    expect(how?.said, contains(sftpOnlyServerWords));
    expect(sessions().terminalRefusalOf(id), TerminalRefusal.sftpOnly);
    expect(sessions().isFilesOnly(id), isFalse, reason: 'it asked for a terminal');
    expect(ended.connectionLog, contains(contains('The host gave no terminal (sftpOnly)')));
    expect(ended.connectionLog.last, startsWith('ended: The host ended the session (exit status 1)'));
    // Nothing connects again by itself: what ended it would end it again.
    expect(ended.isReconnecting, isFalse);

    sessions().openFilesInstead(id);
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected again, for its files');
    expect(sessions().isFilesOnly(id), isTrue);
    expect(sessions().terminalRefusalOf(id), isNull);
    expect((stateOf(id)!.session!.shell as SshService).filesOnly, isTrue);
    // The host is left as it is: the next session to it asks for a terminal.
    expect((await tree.connectionsDao.getById('h-files'))!.protocol, 'ssh');
    await sessions().endSession(id);
  });

  test('Make this host SFTP only: the host is saved so, and its session opened as files only', () async {
    if (!filesUp) {
      markTestSkipped('no SFTP-only test sshd at $sshHost:$filesPort');
      return;
    }
    final id = await started('ssh');
    await until(() => sessions().terminalRefusalOf(id) != null, 'the refusal');
    expect(await sessions().makeHostSftpOnly(id), isTrue);
    expect((await tree.connectionsDao.getById('h-files'))!.protocol, 'sftp');
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected, for its files');
    expect(sessions().isFilesOnly(id), isTrue);
    await sessions().endSession(id);

    // And every session to it from now on is files only.
    final next = sessions().startSession((await tree.connectionsDao.getById('h-files'))!)!;
    expect(sessions().isFilesOnly(next), isTrue);
    await until(() => stateOf(next)?.status == SessionStatus.connected, 'the next one connected');
    await sessions().endSession(next);
  });

  test('a shell that ends the moment it opens, with a word of its own: said to give no terminal, closed at once',
      () async {
    if (!plainUp) {
      markTestSkipped('no test sshd at $sshHost:$plainPort');
      return;
    }
    final id = await started('ssh', port: plainPort, signIn: forced);
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the end of the session');
    expect(sessionEnded(stateOf(id)!.dropCause)?.exitCode, 7);
    expect(sessions().terminalRefusalOf(id), TerminalRefusal.closedAtOnce);
    await sessions().endSession(id);
    expect(sessions().terminalRefusalOf(id), isNull, reason: 'forgotten with the session');
  });

  test('a shell that runs is no refusal: one its host ends later, after it ran, is a session that ended', () async {
    if (!plainUp) {
      markTestSkipped('no test sshd at $sshHost:$plainPort');
      return;
    }
    final id = await started('ssh', port: plainPort);
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected');
    await Future<void>.delayed(kShellAtOnce + const Duration(milliseconds: 500));
    // Ended by what the app types as it starts: not its person's hand, and
    // long after it opened.
    sessions().sendInput(id, Uint8List.fromList('exit 3\n'.codeUnits), atStart: true);
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the end of the session');
    expect(sessionEnded(stateOf(id)!.dropCause)?.exitCode, 3);
    expect(sessions().terminalRefusalOf(id), isNull);
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
