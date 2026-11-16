import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/connection_failed_dialog.dart';
import 'package:zestssh/utils/error_translator.dart' as translator;

/// Connecting again by itself after a connection drops (3.0): a
/// try that fails leaves the session where it was, its connection gone with
/// what that try said, and the next try comes. A failed try was taken for a
/// new connection that failed: the session was removed 2 s later, and on a
/// computer the failure dialog ended it at once, so the loop got no further
/// than its first try.
void main() {
  late AppDatabase tree;
  late ProviderContainer container;
  // The shells the app is given, in turn: the first connects, then each one
  // after it connects or fails as the test says.
  late List<_Shell> shells;
  late List<Object?> nextFailures;

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
    container.read(autoReconnectEnabledProvider.notifier).state = true;
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(milliseconds: 20);
    shells = [];
    nextFailures = [];
    container.read(activeSessionsProvider.notifier).debugShellFor = (connection) {
      final shell = _Shell(fails: shells.isEmpty || nextFailures.isEmpty ? null : nextFailures.removeAt(0));
      shells.add(shell);
      return shell;
    };
  });

  tearDown(() async {
    ActiveSessionsNotifier.debugReconnectDelay = null;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  /// What signing in fails with when the host ends the connection and says so.
  SSHAuthAbortError endedSaying(int code, String words, {bool authentic = true}) => SSHAuthAbortError(
      'Connection closed before authentication', SSHDisconnectError(code, words, authentic: authentic));

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 15)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// A saved host, connected, and the session it is open in.
  Future<String> connected() async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web1',
          label: 'web-01',
          host: '10.50.0.5',
          port: const Value(23),
          protocol: const Value('telnet'),
          colorIndex: const Value(3),
          colorValue: const Value(0xFF2A9D8F),
          createdAt: at,
          updatedAt: at,
        ));
    final host = (await tree.connectionsDao.getById('h-web1'))!;
    final id = sessions().startSession(host)!;
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the session');
    return id;
  }

  test('tries that fail are followed by the next, and the session comes back', () async {
    final id = await connected();
    // The host is away for two tries, and back for the third.
    nextFailures.addAll([
      const SocketException('Connection refused'),
      const SocketException('Connection refused'),
    ]);
    // Every state the session passes through, to see it never goes.
    final seen = <SessionState?>[];
    container.listen(activeSessionsProvider, (_, next) => seen.add(next[id]), fireImmediately: false);

    shells.first.drop();
    await until(() => shells.length == 4 && stateOf(id)?.status == SessionStatus.connected, 'connected again');
    expect(stateOf(id)!.isReconnecting, isFalse);
    expect(stateOf(id)!.reconnectAttempt, 0);
    expect(seen, everyElement(isNotNull), reason: 'the session was never removed');
    expect(seen.whereType<SessionState>().map((s) => (s.colorIndex, s.colorValue)).toSet(), {(3, 0xFF2A9D8F)},
        reason: 'its colour all along');
    // Dropped: told so, with what was said while it connected.
    final drop = seen.whereType<SessionState>().first;
    expect(drop.status, SessionStatus.disconnected);
    expect(drop.dropped, isTrue);
    expect(drop.connectionLog, isNotEmpty, reason: 'the log of its connection, for its report');
    final tried = seen.whereType<SessionState>().where((s) => s.status == SessionStatus.disconnected && s.errorMessage != null);
    expect(tried, isNotEmpty, reason: 'between tries it said why the last one failed');
    expect(tried.first.errorMessage, contains('Connection refused'));
    expect(tried.first.isReconnecting, isTrue);
    expect(tried.first.dropped, isTrue);
    expect(tried.first.connectionLog.last, contains('Connection refused'));
    expect(container.read(connectionErrorProvider), isNull,
        reason: 'no failure dialog for a try: on a computer it ended the session');
    expect(seen.whereType<SessionState>().map((s) => s.status), isNot(contains(SessionStatus.error)));
    await sessions().endSession(id);
  });

  test('when every try fails, it gives up and the session stays, saying why', () async {
    final id = await connected();
    nextFailures.addAll(List.filled(20, const SocketException('No route to host')));
    shells.first.drop();
    await until(() {
      final s = stateOf(id);
      return s != null && !s.isReconnecting && s.reconnectAttempt == s.maxRetries;
    }, 'giving up');
    final last = stateOf(id)!;
    expect(last.status, SessionStatus.disconnected);
    expect(last.dropped, isTrue, reason: 'still shown with why and Reconnect');
    expect(last.errorMessage, contains('No route to host'));
    expect(shells, hasLength(1 + last.maxRetries), reason: 'one connection, then every try');
    // Long after the 2 s a failed new connection is given, it is still there.
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    expect(stateOf(id), isNotNull);
    expect(container.read(connectionErrorProvider), isNull);
    await sessions().endSession(id);
  });

  // A reported bug (an address banned by a server that
  // counts refused sign-ins and connections that end before one): a session
  // that dropped tried ten times in three minutes whatever the host
  // answered, a refused sign-in included.
  test('a host that refuses the sign-in is not tried ten times: the first refusal ends the tries, and the session '
      'stays with what the host said and Reconnect', () async {
    final id = await connected();
    nextFailures.addAll(List.filled(20, SSHAuthFailError('All authentication methods failed')));
    shells.first.drop();
    await until(() {
      final s = stateOf(id);
      return s != null && s.dropped && !s.isReconnecting && s.errorMessage != null;
    }, 'the tries ended');
    // (Twenty more tries would fit into this: they are 20 ms apart here.)
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(shells, hasLength(2), reason: 'one connection, and one try');
    final last = stateOf(id)!;
    expect((last.status, last.dropped, last.isReconnecting, last.reconnectAttempt),
        (SessionStatus.disconnected, true, false, 1));
    expect(last.errorMessage, contains('All authentication methods failed'));
    expect(container.read(connectionErrorProvider), isNull, reason: 'no failure dialog for a try');

    // Its person presses Reconnect once the password is put right.
    nextFailures.clear();
    sessions().reconnectNow(id);
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected again');
    expect(stateOf(id)!.isReconnecting, isFalse);
    await sessions().endSession(id);
  });

  test('the tries go on while the host cannot be reached, and end at the first one the host refuses', () async {
    final id = await connected();
    nextFailures.addAll([
      const SocketException('Connection refused'),
      const SocketException('Connection refused'),
      SSHAuthAbortError('Connection closed before authentication', SSHHostkeyError('Hostkey verification failed')),
      const SocketException('Connection refused'),
    ]);
    shells.first.drop();
    await until(() => shells.length == 4 && !(stateOf(id)?.isReconnecting ?? true), 'the third try ended them');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(shells, hasLength(4), reason: 'one connection, two tries that did not reach it, and the one it refused');
    final last = stateOf(id)!;
    expect((last.status, last.dropped, last.reconnectAttempt), (SessionStatus.disconnected, true, 3));
    // (It was kept as "Connection closed before authentication", and shown as a connection the server closed.)
    expect(last.errorMessage,
        "ZestSSH: The host's key was not accepted, so the connection was not made. Nothing was sent to the host.");
    await sessions().endSession(id);
  });

  test('a host that shows another key while its session is being connected again, and whose person says no to it: '
      'the session stays, saying so, and is not tried again', () async {
    final id = await connected();
    nextFailures.addAll([
      SSHAuthAbortError('Connection closed before authentication',
          HostKeyNotAccepted(HostKeyRefusal.declinedChanged, host: '192.0.2.10', port: 22)),
      const SocketException('Connection refused'),
    ]);
    shells.first.drop();
    await until(() => shells.length == 2 && !(stateOf(id)?.isReconnecting ?? true), 'the try ended them');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(shells, hasLength(2), reason: 'one connection, and the try whose key was not accepted');
    // It is not gone, as a first connection whose person says no is: nobody may have been looking.
    final last = stateOf(id)!;
    expect((last.status, last.dropped, last.reconnectAttempt), (SessionStatus.disconnected, true, 1));
    expect(
      last.errorMessage,
      'ZestSSH: 192.0.2.10 showed another key than the one this device trusts for it, and that key was not accepted. '
      "Nothing was sent to it. A host's key changes when the host is set up anew, and when something stands between "
      'this device and the host: check the key before you accept it.',
    );
    expect(container.read(connectionErrorProvider), isNull, reason: 'no failure dialog for a try');
    await sessions().endSession(id);
  });

  // A host can also say no to a sign-in by ending the connection, with a
  // message that it does (OpenSSH: "Too many authentication failures", once
  // it has refused as many keys as it allows a connection). That was taken
  // for a connection that broke: ten tries, each one more failed sign-in in
  // the host's log.
  test('nor is a host that ends the connection while it is being signed in to, saying that it does: the tries end '
      'there; one that has too many connections is tried again', () async {
    final id = await connected();
    nextFailures.addAll([
      endedSaying(12, 'Too many connections'),
      ...List.filled(20, endedSaying(2, 'Too many authentication failures')),
    ]);
    shells.first.drop();
    await until(() {
      final s = stateOf(id);
      return s != null && s.dropped && !s.isReconnecting && s.errorMessage != null;
    }, 'the tries ended');
    // (Twenty more tries would fit into this: they are 20 ms apart here.)
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(shells, hasLength(3), reason: 'one connection, a try the host was too busy for, and the one it refused');
    final last = stateOf(id)!;
    expect((last.status, last.dropped, last.isReconnecting, last.reconnectAttempt),
        (SessionStatus.disconnected, true, false, 2));
    expect(last.errorMessage, 'ZestSSH: The host ended the connection. Its reason: Too many authentication failures');
    expect(container.read(connectionErrorProvider), isNull, reason: 'no failure dialog for a try');
    await sessions().endSession(id);
  });

  test('trying again cannot help after a refused sign-in or a key that was not accepted; anything else is worth '
      'the next try, a reason of the app\'s own included', () {
    for (final Object ends in [
      SSHAuthFailError('All authentication methods failed'),
      SSHHostkeyError('Hostkey verification failed'),
      SSHAuthAbortError('Connection closed before authentication', SSHHostkeyError('Hostkey verification failed')),
      // The host ended the sign-in itself, and said so: in words, in none, and before its key was checked.
      endedSaying(2, 'Too many authentication failures'),
      endedSaying(14, ''),
      endedSaying(2, 'Too many authentication failures', authentic: false),
      // The same at a jump host on the way.
      JumpHostFailure(
          label: 'bastion',
          host: '10.50.0.9',
          port: 22,
          stage: JumpStage.signIn,
          cause: endedSaying(2, 'Too many authentication failures')),
    ]) {
      expect(reconnectCannotHelp(ends), isTrue, reason: '$ends');
    }
    for (final Object worthIt in [
      const SSHAuthFailedException('Your certificate is waiting for an owner.'),
      SSHAuthAbortError('Connection closed before authentication'),
      SSHAuthAbortError('Connection closed before authentication', SSHSocketError('Connection reset by peer')),
      // A host that has too many connections may have fewer at the next try.
      endedSaying(12, 'Too many connections'),
      // What ends a connection that was signed in to is no refused sign-in.
      SSHDisconnectError(2, 'Too many authentication failures', authentic: true),
      const SocketException('Connection refused'),
      TimeoutException('Authentication timed out'),
      StateError('anything else'),
    ]) {
      expect(reconnectCannotHelp(worthIt), isFalse, reason: '$worthIt');
    }
  });

  test('Reconnect, once the tries gave up or after Cancel, connects it again at once, in its place', () async {
    final id = await connected();
    nextFailures.addAll(List.filled(20, const SocketException('No route to host')));
    shells.first.drop();
    await until(() {
      final s = stateOf(id);
      return s != null && !s.isReconnecting && s.reconnectAttempt == s.maxRetries;
    }, 'giving up');

    // A wait between tries longer than any test: only a try at once connects.
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(hours: 1);
    nextFailures.clear();
    sessions().reconnectNow(id);
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected again at once');
    expect(stateOf(id)!.isReconnecting, isFalse);

    // Dropped again, and Cancel before the first try: Reconnect still connects.
    shells.last.drop();
    await until(() => stateOf(id)?.isReconnecting ?? false, 'connecting again by itself');
    sessions().stopAutoReconnect(id);
    expect(stateOf(id)!.isReconnecting, isFalse);
    sessions().reconnectNow(id);
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected again after Cancel');
    await sessions().endSession(id);
  });

  test('a hidden session stays hidden while it is connected again by itself', () async {
    final id = await connected();
    sessions().hideSession(id);
    nextFailures.add(const SocketException('Connection refused'));
    final seen = <SessionState>[];
    container.listen(activeSessionsProvider, (_, next) {
      final s = next[id];
      if (s != null && s.status != SessionStatus.connected) seen.add(s);
    });
    shells.first.drop();
    await until(() => shells.length == 3 && stateOf(id)?.status == SessionStatus.connected, 'connected again');
    expect(seen.map((s) => s.status).toSet(), {SessionStatus.disconnected, SessionStatus.connecting});
    expect(seen.map((s) => s.isHidden), everyElement(isTrue), reason: 'hidden until it is connected again');
    await sessions().endSession(id);
  });

  test('why it dropped is kept once the connection says: in its log, and through the tries', () async {
    final id = await connected();
    nextFailures.addAll([const SocketException('Connection refused'), const SocketException('Connection refused')]);
    final seen = <SessionState>[];
    container.listen(activeSessionsProvider, (_, next) {
      final s = next[id];
      if (s != null) seen.add(s);
    });
    shells.first.drop(because: 'SSHSocketError(SocketException: Connection reset by peer)');
    await until(() => shells.length == 4 && stateOf(id)?.status == SessionStatus.connected, 'connected again');
    final known = seen.indexWhere((s) => s.dropCause != null);
    expect(known, isNonNegative, reason: 'why it dropped was kept');
    expect(seen[known].dropCause, contains('Connection reset by peer'));
    expect(seen[known].connectionLog.last, 'dropped: SSHSocketError(SocketException: Connection reset by peer)');
    final dropsAfter = seen.skip(known).where((s) => s.status != SessionStatus.connected).toList();
    expect(dropsAfter.length, greaterThan(2), reason: 'the tries came after it');
    expect(dropsAfter.map((s) => s.dropCause), everyElement(contains('Connection reset by peer')),
        reason: 'kept through the tries');
    await sessions().endSession(id);
  });

  test('nothing said, nothing kept; said once it is connected again, not kept either', () async {
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    final id = await connected();
    shells.first.drop();
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'dropped');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(stateOf(id)!.dropped, isTrue);
    expect(stateOf(id)!.dropCause, isNull);

    // Connected again before the next drop says why.
    sessions().reconnectNow(id);
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected again');
    shells.last.drop(sayLater: true);
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'dropped again');
    sessions().reconnectNow(id);
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected once more');
    shells[1].say('SSHSocketError(SocketException: Broken pipe)');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(stateOf(id)!.dropCause, isNull, reason: 'said after it was connected again');
    await sessions().endSession(id);
  });

  // A reason the app itself wrote for the person (a sign-in it could not
  // start, a host it was told to skip) is kept as the app's own words, so
  // that every screen shows it as it is; what a library or the system said
  // is kept as it was said, and put into the app's words where it is shown
  // (3.0: the app's own reasons were shown as "An
  // unexpected error occurred while connecting").
  test('a new connection that fails for a reason the app wrote keeps that reason as the app\'s', () async {
    final at = DateTime(2026, 10, 1);
    Future<Connection> host(String id) async {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id,
            host: '10.50.0.7',
            port: const Value(23),
            protocol: const Value('telnet'),
            createdAt: at,
            updatedAt: at,
          ));
      return (await tree.connectionsDao.getById(id))!;
    }

    const waiting = 'Your certificate is waiting for an owner\'s device to sign it.';
    final cases = <String, (Object, String)>{
      'h-cert': (const SSHAuthFailedException(waiting), 'ZestSSH: $waiting'),
      'h-skip': (const HostSkippedOnNetworkException('Skipped on this network.'), 'ZestSSH: Skipped on this network.'),
      'h-refused': (const SocketException('Connection refused'), '${const SocketException('Connection refused')}'),
    };
    for (final c in cases.entries) {
      final (thrown, kept) = c.value;
      container.read(connectionErrorProvider.notifier).state = null;
      sessions().debugShellFor = (connection) => _Shell(fails: thrown);
      final id = sessions().startSession(await host(c.key))!;
      await until(() => container.read(connectionErrorProvider) != null, 'the failure told');
      expect(container.read(connectionErrorProvider)!.errorMessage, kept, reason: c.key);
      expect(stateOf(id)!.errorMessage, kept, reason: c.key);
      expect(stateOf(id)!.connectionLog.last, 'error: $thrown', reason: 'the log has what was thrown, as thrown');
      final shown = translator.ConnectionError.translate(kept, host: '10.50.0.7', port: 23);
      expect(shown.type == translator.ConnectionErrorType.saidByApp, c.key != 'h-refused', reason: c.key);
      await until(() => stateOf(id) == null, 'removed');
    }
    expect(
        translator.ConnectionError.translate('ZestSSH: $waiting', host: '10.50.0.7', port: 23).description, waiting);
  });

  test('a login that could get no certificate keeps which Crate an owner can sign one for, until it is of no use',
      () async {
    final at = DateTime(2026, 10, 1);
    Future<Connection> host(String id) async {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id,
            host: '10.50.0.8',
            port: const Value(23),
            protocol: const Value('telnet'),
            createdAt: at,
            updatedAt: at,
          ));
      return (await tree.connectionsDao.getById(id))!;
    }

    Map<String, ({String orchardId, String crateId})> offers() => container.read(certificateFromOwnerOfferProvider);
    Future<void> fails(Connection c, Object with_) async {
      container.read(connectionErrorProvider.notifier).state = null;
      sessions().debugShellFor = (connection) => _Shell(fails: with_);
      final id = sessions().startSession(c, allowDuplicate: true)!;
      await until(() => container.read(connectionErrorProvider) != null, 'the failure told');
      await until(() => stateOf(id) == null, 'removed');
    }

    final web = await host('h-web9');
    final db = await host('h-db9');
    expect(offers(), isEmpty);
    // Whoever shows it is told when it changes, and only then.
    var told = 0;
    container.listen(certificateFromOwnerOfferProvider, (_, _) => told++);
    await fails(web, const SocketException('Connection refused'));
    expect(told, 0, reason: 'nothing was kept, and nothing is');
    const waiting = SSHAuthFailedException('Your certificate is waiting.',
        handover: (orchardId: 'orchard-1', crateId: 'crate-1'));
    await fails(web, waiting);
    expect(offers(), {'h-web9': (orchardId: 'orchard-1', crateId: 'crate-1')});
    // Another host of another Crate: each has its own.
    await fails(db, const SSHAuthFailedException('No certificate.', handover: (orchardId: 'orchard-1', crateId: 'crate-2')));
    expect(offers(), {
      'h-web9': (orchardId: 'orchard-1', crateId: 'crate-1'),
      'h-db9': (orchardId: 'orchard-1', crateId: 'crate-2'),
    });
    // A failure no owner can get around, the app's own or not: nothing to offer for that host any more.
    await fails(web, const SSHAuthFailedException('You cannot open this key\'s Crate now.'));
    expect(offers(), {'h-db9': (orchardId: 'orchard-1', crateId: 'crate-2')});
    await fails(web, waiting);
    await fails(web, const SocketException('Connection refused'));
    expect(offers().keys, ['h-db9']);
    // The key of a jump host on the way to it can take a certificate too: offered for the host that was asked for.
    JumpHostFailure atBastion(Object cause) => JumpHostFailure(
        label: 'bastion', host: '10.50.0.9', port: 22, stage: JumpStage.details, cause: cause);
    await fails(web, atBastion(waiting));
    expect(offers()['h-web9'], (orchardId: 'orchard-1', crateId: 'crate-1'));
    await fails(web, atBastion(const SocketException('Connection refused')));
    expect(offers().keys, ['h-db9']);
    // Connected: nothing to offer either.
    sessions().debugShellFor = (connection) => _Shell();
    final id = sessions().startSession(db, allowDuplicate: true)!;
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected');
    expect(offers(), isEmpty);
    expect(told, 8, reason: 'kept, kept, dropped, kept, dropped, kept, dropped, dropped');
    await sessions().endSession(id);
  });

  test('a try of connecting again that fails for a reason the app wrote keeps it as the app\'s too', () async {
    final id = await connected();
    nextFailures.addAll([
      const SSHAuthFailedException('Your certificate is waiting.'),
      const SSHAuthFailedException('Your certificate is waiting.'),
    ]);
    final seen = <SessionState?>[];
    container.listen(activeSessionsProvider, (_, next) => seen.add(next[id]), fireImmediately: false);
    shells.first.drop();
    await until(() => shells.length == 4 && stateOf(id)?.status == SessionStatus.connected, 'connected again');
    final tried = seen.whereType<SessionState>().where((s) => s.status == SessionStatus.disconnected && s.errorMessage != null);
    expect(tried, isNotEmpty);
    expect(tried.map((s) => s.errorMessage).toSet(), {'ZestSSH: Your certificate is waiting.'});
    await sessions().endSession(id);
  });

  test('a new connection that fails is still told, and removed after a moment', () async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-db1',
          label: 'db-01',
          host: '10.50.0.6',
          port: const Value(23),
          protocol: const Value('telnet'),
          createdAt: at,
          updatedAt: at,
        ));
    // The first shell connects in these tests, so this one is given one that
    // fails by hand.
    sessions().debugShellFor = (connection) => _Shell(fails: const SocketException('Connection refused'));
    final id = sessions().startSession((await tree.connectionsDao.getById('h-db1'))!)!;
    await until(() => container.read(connectionErrorProvider) != null, 'the failure told');
    expect(container.read(connectionErrorProvider)!.errorMessage, contains('Connection refused'));
    expect(stateOf(id)!.status, SessionStatus.error);
    // What a computer's dialog puts into its report as the kind of the
    // failure is the kind it is shown as, as the report of every other
    // screen of a failed connection has it. (It was what the program calls
    // the type of what was thrown, "SocketException" here: another name in
    // a build made for release.)
    final told = container.read(connectionErrorProvider)!;
    final shown = translator.ConnectionError.translate(told.errorMessage, host: told.host, port: told.port);
    expect(shown.type, translator.ConnectionErrorType.refused);
    final report = ConnectionFailedDialog.reportOf(told, shown);
    expect(report.split('\n').where((line) => line.contains('Kind:')), ['  Kind: refused']);
    expect(report, contains('What: ${shown.title}'));
    await until(() => stateOf(id) == null, 'removed');
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

/// A shell the test drives: it connects, or fails as it was told to, and its
/// connection can drop (not a shell that ended), saying why or not, then or
/// a moment later.
class _Shell extends ShellService implements ShellEndReason {
  _Shell({this.fails});

  final Object? fails;
  final _state = StreamController<bool>.broadcast();
  final _out = StreamController<Uint8List>.broadcast();
  final _reason = Completer<String?>();
  bool _connected = false;

  void drop({String? because, bool sayLater = false}) {
    if (!sayLater) say(because);
    _connected = false;
    _state.add(false);
  }

  /// Why it ended, said now.
  void say(String? because) {
    if (!_reason.isCompleted) _reason.complete(because);
  }

  @override
  Future<String?> get endReason => _reason.future;

  @override
  Future<void> connect() async {
    final failure = fails;
    if (failure != null) throw failure;
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
