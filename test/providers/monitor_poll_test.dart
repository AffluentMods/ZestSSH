// Server Monitor's own connections (a reported case:
// an address banned by a server that counts connections which end before
// sign-in, and refused sign-ins). A host whose key this device does not
// trust was dialled again at every change of any session and every time the
// window came to the front, each time as far as the key and no further; and
// a host that refused the sign-in was tried again every five minutes for
// ever. What is held here: such a host is dialled once, and again only when
// what stood in the way may have changed, or when its person asks. So is a
// host whose connection the SSH core ends by itself over something no timer
// changes (the host cannot prove its key, names a group for the key
// exchange that is not taken, or a key of the app's own cannot sign): it
// was tried again by the timer for as long as it was monitored.
//
// (testWidgets for its clock, which the test moves: no widget is drawn.)

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/monitor_history_service.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';
import 'package:zestssh/services/ssh_service.dart';

Connection host(
  String id, {
  String? address,
  int port = 22,
  String? identityId = 'key-deploy',
  String? via,
  bool compatibility = false,
}) {
  final at = DateTime.utc(2026);
  return Connection(
    id: id,
    label: id,
    host: address ?? '$id.example.com',
    port: port,
    identityId: identityId,
    connectViaId: via,
    colorIndex: 0,
    protocol: 'ssh',
    zlibCompression: false,
    keepAliveSeconds: 0,
    envVars: '',
    forwardAgent: false,
    compatibilityMode: compatibility,
    sortOrder: 0,
    sizeTier: 1,
    pinned: false,
    monitored: true,
    createdAt: at,
    updatedAt: at,
  );
}

Identity identity(String id, {int savedAt = 0}) => Identity(
      id: id,
      label: id,
      username: 'deploy',
      authMethod: 'password',
      colorIndex: 0,
      isDefault: false,
      usesAgent: false,
      allowUnattended: false,
      passwordAfterKey: false,
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2026).add(Duration(seconds: savedAt)),
    );

/// The app's sessions as the test sets them, and its own way of signing in
/// for Server Monitor: every dial is written down, and ends as the test
/// says for that host.
class Sessions extends ActiveSessionsNotifier {
  Sessions(super.ref);

  final dialled = <String>[];
  final answers = <String, MonitorExecResult Function()>{};

  /// What a dial of a host waits for before it ends, where the test holds it.
  final waits = <String, Future<void>>{};

  void show(Map<String, SessionState> sessions) => state = sessions;

  @override
  Future<MonitorExecResult> openExecClient(Connection connection) async {
    dialled.add(connection.id);
    await waits[connection.id];
    return (answers[connection.id] ?? () => MonitorExecResult.error(const SocketException('Connection refused')))();
  }
}

/// A connection of Server Monitor's own to a host that answers nothing it is
/// asked: every command fails, as on a connection that has been lost.
class _NoFigures implements SshService {
  var disconnected = false;

  @override
  final SSHClient client = _DeadClient();

  @override
  Future<void> disconnect() async => disconnected = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DeadClient implements SSHClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('the connection is gone');
}

class _NoHistory implements MonitorHistoryService {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// The figures of hosts, with nothing read from anywhere and nothing asked of any host.
class _NoStats extends ServerStatsNotifier {
  _NoStats(super.ref);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}

/// Every host has what it takes to sign in with nobody asked.
class Factory implements SshConnectionFactory {
  @override
  Future<bool> canPollSilently(Connection connection) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Squeezed extends StateNotifier<bool> implements ProStatusNotifier {
  Squeezed() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A connected SSH session's shell, as far as Server Monitor looks.
class _Ssh extends ShellService {
  @override
  bool get isEncryptedSsh => true;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Stream<Uint8List> get stdout => const Stream.empty();

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(Uint8List data) {}

  @override
  void resize(int width, int height) {}

  @override
  bool get isConnected => true;

  @override
  Stream<bool> get connectionState => const Stream.empty();

  @override
  bool get exitedCleanly => false;
}

SessionState sessionOn(String hostId) => SessionState.connected(
      TerminalSession(id: 's-$hostId', connectionId: hostId, terminal: Terminal(), shell: _Ssh(), startedAt: DateTime(2026)),
    );

/// Server Monitor, turned on, with what the test gives it.
class Monitor {
  Monitor(this.tester, SharedPreferences prefs) {
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      monitoredConnectionsProvider.overrideWith((ref) => _monitored.stream),
      identitiesProvider.overrideWith((ref) => _identities.stream),
      trustedHostKeysProvider.overrideWith((ref) => _keys.stream),
      isProProvider.overrideWith((ref) => Squeezed()),
      activeSessionsProvider.overrideWith(Sessions.new),
      sshConnectionFactoryProvider.overrideWithValue(Factory()),
      // What a check that was made writes down: nothing of it reaches a database here.
      monitorHistoryServiceProvider.overrideWithValue(_NoHistory()),
      serverStatsProvider.overrideWith(_NoStats.new),
    ]);
    sessions = container.read(activeSessionsProvider.notifier) as Sessions;
    poller = container.read(agentlessMonitorPollerProvider.notifier);
  }

  final WidgetTester tester;
  late final ProviderContainer container;
  late final Sessions sessions;
  late final AgentlessMonitorPoller poller;
  final _monitored = StreamController<List<Connection>>.broadcast();
  final _identities = StreamController<List<Identity>>.broadcast();
  final _keys = StreamController<List<KnownHost>>.broadcast();

  /// The hosts chosen for Server Monitor, as they are saved now.
  Future<void> hosts(List<Connection> list) async {
    _monitored.add(list);
    await settle();
  }

  /// The keys and passwords as they are saved now.
  Future<void> identities(List<Identity> list) async {
    _identities.add(list);
    await settle();
  }

  /// The keys this device trusts changed.
  Future<void> trustedKeysChanged() async {
    _keys.add(const []);
    await settle();
  }

  /// Lets what was set in motion happen (the monitor waits a moment before
  /// it looks, so that a burst of changes is one look).
  Future<void> settle() => tester.pump(const Duration(milliseconds: 400));

  MonitorHostState? shown(String id) => poller.state[id]?.state;
  int dials(String id) => sessions.dialled.where((d) => d == id).length;
}

Future<void> withMonitor(WidgetTester tester, Future<void> Function(Monitor m) body) async {
  SharedPreferences.setMockInitialValues({'agentless_monitor_enabled': true});
  final m = Monitor(tester, await SharedPreferences.getInstance());
  try {
    await m.identities([identity('key-deploy'), identity('key-other')]);
    await body(m);
  } finally {
    m.container.dispose();
    await m._monitored.close();
    await m._identities.close();
    await m._keys.close();
  }
}

void main() {
  final web = host('web');
  final db = host('db');
  final refused = SSHAuthFailError('All authentication methods failed');

  /// What a host is shown as, with what its check failed with and whether that was a refused sign-in.
  (MonitorHostState, Object?, bool) held(Monitor m, String id) {
    final status = m.poller.state[id]!;
    return (status.state, status.failedWith, status.signInRefused);
  }

  /// Whether a host's status says that no timer tries it again.
  bool notTriedAgain(Monitor m, String id) => m.poller.state[id]!.notTriedAgain;

  testWidgets('a host whose key is not trusted is dialled once: not again when sessions change, the app is away '
      'and back, time passes, or something else of the hosts is written', (tester) => withMonitor(tester, (m) async {
    m.sessions.answers['web'] = () => MonitorExecResult.needsHostKeyReview(changed: false);
    await m.hosts([web, db]);
    expect(m.dials('web'), 1);
    expect(m.shown('web'), MonitorHostState.needsHostKeyReview);
    expect(m.poller.state['web']!.hostKeyChanged, isFalse, reason: 'the first key this device sees of it');

    // A session to another host connects and ends.
    m.sessions.show({'s1': sessionOn('cache')});
    await m.settle();
    m.sessions.show({});
    await m.settle();
    // The window is elsewhere for five minutes, and back.
    m.poller.pause();
    await tester.pump(const Duration(minutes: 5));
    m.poller.resume();
    await m.settle();
    // An hour goes by, and the list of hosts is written again as it was.
    await tester.pump(const Duration(hours: 1));
    await m.hosts([web, db]);
    expect(m.dials('web'), 1);
    expect(m.shown('web'), MonitorHostState.needsHostKeyReview);
    // (db, which cannot be reached, is tried again and again meanwhile.)
    expect(m.dials('db'), greaterThan(5));
  }));

  testWidgets('it is taken up again when the keys this device trusts change, when the host is saved differently, '
      'when its person signs in to it, when they ask, and when Server Monitor is turned off and on',
      (tester) => withMonitor(tester, (m) async {
    // (Another key than the one this device trusts for it, this time: its status keeps which it is.)
    m.sessions.answers['web'] = () => MonitorExecResult.needsHostKeyReview(changed: true);
    await m.hosts([web]);
    expect(m.dials('web'), 1);
    expect(m.poller.state['web']!.hostKeyChanged, isTrue);

    await m.trustedKeysChanged();
    expect(m.dials('web'), 2, reason: 'its key may be trusted now');
    await m.identities([identity('key-deploy', savedAt: 5), identity('key-other')]);
    expect(m.dials('web'), 2, reason: 'another password does not make its key trusted');

    // Saved differently: another server, perhaps, or another way to it.
    var saved = host('web', port: 2222);
    await m.hosts([saved]);
    expect(m.dials('web'), 3, reason: 'another port');
    await m.hosts([saved]);
    expect(m.dials('web'), 3, reason: 'written again as it is');
    saved = host('web', port: 2222, address: '192.0.2.10');
    await m.hosts([saved]);
    expect(m.dials('web'), 4, reason: 'another address');
    saved = host('web', port: 2222, address: '192.0.2.10', via: 'db');
    await m.hosts([saved]);
    expect(m.dials('web'), 5, reason: 'reached through another host now');
    await m.hosts([saved]);
    expect(m.dials('web'), 5);

    m.poller.retry('db');
    await m.settle();
    expect(m.dials('web'), 5, reason: 'asked for another host');
    m.poller.retry('web');
    await m.settle();
    expect(m.dials('web'), 6);
    m.poller.retry();
    await m.settle();
    expect(m.dials('web'), 7, reason: 'asked for all of them');

    // Its person connects to it: the session's own figures while it is
    // connected, and the monitor's own connection again once it is over.
    m.sessions.show({'s1': sessionOn('web')});
    await m.settle();
    expect((m.dials('web'), m.poller.state['web']!.detail), (7, 'live-session'));
    m.sessions.show({});
    await m.settle();
    expect(m.dials('web'), 8);

    await m.container.read(agentlessMonitorEnabledProvider.notifier).setEnabled(false);
    await m.settle();
    expect(m.poller.state, isEmpty);
    await m.container.read(agentlessMonitorEnabledProvider.notifier).setEnabled(true);
    await m.settle();
    expect(m.dials('web'), 9);
  }));

  testWidgets('a host that refused the sign-in is not tried again by a timer: again when the key or password it '
      'signs in with is saved anew, or its person asks', (tester) => withMonitor(tester, (m) async {
    m.sessions.answers['web'] = () => MonitorExecResult.signInRefused(refused);
    await m.hosts([web]);
    expect(m.dials('web'), 1);
    expect(held(m, 'web'), (MonitorHostState.error, refused, true));
    expect(notTriedAgain(m, 'web'), isTrue);

    await tester.pump(const Duration(hours: 6));
    m.sessions.show({'s1': sessionOn('cache')});
    await m.settle();
    m.poller.pause();
    await tester.pump(const Duration(minutes: 5));
    m.poller.resume();
    await m.settle();
    expect(m.dials('web'), 1, reason: 'it was tried again 5, 10, 20, 40, 80, 160 and then every 300 seconds');
    expect(held(m, 'web'), (MonitorHostState.error, refused, true));

    // Keys this device trusts changing has nothing to do with it; nor has
    // another host's password, or its own saved again as it was.
    await m.trustedKeysChanged();
    await m.identities([identity('key-deploy'), identity('key-other', savedAt: 9)]);
    expect(m.dials('web'), 1);
    // Its own password saved anew.
    await m.identities([identity('key-deploy', savedAt: 9), identity('key-other', savedAt: 9)]);
    expect(m.dials('web'), 2);
    // Another key chosen for it.
    await m.hosts([host('web', identityId: 'key-other')]);
    expect(m.dials('web'), 3);
    m.poller.retry();
    await m.settle();
    expect(m.dials('web'), 4);
  }));

  testWidgets('a host that is connected and gives no figures when it is asked: its check failed, with the app\'s own '
      'words for it, and it is tried again', (tester) => withMonitor(tester, (m) async {
    final en = lookupAppLocalizations(const Locale('en'));
    L10nGlobal.update(en);
    final connected = _NoFigures();
    m.sessions.answers['web'] = () => MonitorExecResult.ok(connected);
    await m.hosts([web]);
    await m.settle();

    final status = m.poller.state['web']!;
    expect((status.state, status.signInRefused), (MonitorHostState.error, false));
    expect(status.failedWith, isA<MonitorNoFigures>());
    expect('${status.failedWith}', en.monitorNoFiguresCame);
    expect(connected.disconnected, isTrue, reason: 'the connection that gave nothing is let go of');
    expect(m.dials('web'), 1);
    await tester.pump(const Duration(seconds: 5));
    expect(m.dials('web'), 2, reason: 'and made anew, as for any check that failed for no refused sign-in');
  }));

  testWidgets('a host that cannot be reached is tried again as before, at longer and longer waits, and at once '
      'when its person asks', (tester) => withMonitor(tester, (m) async {
    // (One whose connecting threw, where it should have said how it ended, is kept the same way.)
    final threw = StateError('thrown while connecting');
    m.sessions.answers['web'] = () => throw threw;
    await m.hosts([db, web]);
    expect(m.dials('db'), 1);
    // What the check failed with is kept, for whoever shows the host to say; and it is no refused sign-in.
    expect(held(m, 'db'), (MonitorHostState.error, const SocketException('Connection refused'), false));
    expect(held(m, 'web'), (MonitorHostState.error, threw, false));
    expect((notTriedAgain(m, 'db'), notTriedAgain(m, 'web')), (false, false));
    await m.hosts([db]);
    await tester.pump(const Duration(seconds: 5));
    expect(m.dials('db'), 2);
    await tester.pump(const Duration(seconds: 10));
    expect(m.dials('db'), 3);
    await tester.pump(const Duration(seconds: 19));
    expect(m.dials('db'), 3, reason: 'twenty seconds this time');
    m.poller.retry('db');
    await m.settle();
    expect(m.dials('db'), 4, reason: 'asked for: not waited for');
    await tester.pump(const Duration(seconds: 4));
    expect(m.dials('db'), 4, reason: 'and from the start again: five seconds');
    await tester.pump(const Duration(seconds: 1));
    expect(m.dials('db'), 5);
  }));

  // A phone on cellular, its hosts at home: each try lasts the connection's
  // time-out, and the host said "Connecting to collect stats." for all of
  // it, never why it could not be checked.
  testWidgets('while a host that could not be reached is tried again, what the try before failed with stays said; '
      'the first try has nothing before it', (tester) => withMonitor(tester, (m) async {
    final first = Completer<void>();
    m.sessions.waits['db'] = first.future;
    await m.hosts([db]);
    expect(held(m, 'db'), (MonitorHostState.connecting, null, false), reason: 'a first try: connecting, as it is');
    first.complete();
    await m.settle();
    expect(held(m, 'db'), (MonitorHostState.error, const SocketException('Connection refused'), false));

    final again = Completer<void>();
    m.sessions.waits['db'] = again.future;
    await tester.pump(const Duration(seconds: 5));
    expect(m.dials('db'), 2);
    expect(held(m, 'db'), (MonitorHostState.connecting, const SocketException('Connection refused'), false),
        reason: 'tried again: why the try before failed, while this one is under way');
    // Something else changes while the try is under way: still said.
    m.sessions.show(const {});
    await m.settle();
    expect(held(m, 'db'), (MonitorHostState.connecting, const SocketException('Connection refused'), false));
    expect(m.dials('db'), 2, reason: 'and not dialled twice');
    again.complete();
    await m.settle();
    expect(held(m, 'db').$1, MonitorHostState.error);
  }));

  test('a connect that failed is told as what it was: a key to review, a sign-in the host refused, or something '
      'worth trying again', () {
    final refusal = monitorExecFailure(refused, hostKeyNeedsReview: false);
    expect((refusal.outcome, refusal.failedWith), (MonitorExecOutcome.signInRefused, refused));
    // Its key first: nothing was offered to a host whose key was not accepted. Whether it is the first key this
    // device sees of the host, or another than the one it trusts, is kept.
    final firstKey = monitorExecFailure(SSHAuthFailError('x'), hostKeyNeedsReview: true);
    expect((firstKey.outcome, firstKey.hostKeyChanged), (MonitorExecOutcome.needsHostKeyReview, false));
    final otherKey = monitorExecFailure(SSHAuthFailError('x'), hostKeyNeedsReview: true, hostKeyChanged: true);
    expect((otherKey.outcome, otherKey.hostKeyChanged), (MonitorExecOutcome.needsHostKeyReview, true));
    // (Nothing of a key is said of a connect that failed for something else.)
    expect(monitorExecFailure(refused, hostKeyNeedsReview: false, hostKeyChanged: true).hostKeyChanged, isFalse);
    for (final Object other in [
      SSHAuthAbortError('Connection closed before authentication'),
      const SocketException('Connection refused'),
      TimeoutException('Authentication timed out'),
      StateError('anything else'),
    ]) {
      final failed = monitorExecFailure(other, hostKeyNeedsReview: false);
      expect((failed.outcome, failed.failedWith), (MonitorExecOutcome.error, other), reason: '$other');
    }
    // What a jump host on the way failed with is told as it would be of the host. A sign-in it refused is a
    // refused sign-in: trying again by a timer is one more of them in that jump host's log each time.
    JumpHostFailure atJumpHost(JumpStage stage, Object cause) =>
        JumpHostFailure(label: 'auth-gateway', host: '192.0.2.10', port: 22, stage: stage, cause: cause);
    final refusedThere = atJumpHost(JumpStage.signIn, refused);
    final atJump = monitorExecFailure(refusedThere, hostKeyNeedsReview: false);
    // (What it failed with is kept as it came, the jump host with it: what is shown of it says which it was.)
    expect((atJump.outcome, atJump.failedWith), (MonitorExecOutcome.signInRefused, refusedThere));
    // A jump host that fails with anything else is worth the next try, as the host would be.
    final downThere = atJumpHost(JumpStage.reach, const SocketException('Connection refused'));
    final away = monitorExecFailure(downThere, hostKeyNeedsReview: false);
    expect((away.outcome, away.failedWith), (MonitorExecOutcome.error, downThere));
    // A host that ended the connection while it was being signed in to, and said that it does, has refused the
    // sign-in too (too many failed sign-ins): the next try would be one more. One that has too many connections
    // has not, nor one that said nothing (the loop above).
    SSHAuthAbortError endedSaying(int code, String words) => SSHAuthAbortError(
        'Connection closed before authentication', SSHDisconnectError(code, words, authentic: true));
    final ended = endedSaying(2, 'Too many authentication failures');
    final tooMany = monitorExecFailure(ended, hostKeyNeedsReview: false);
    expect((tooMany.outcome, tooMany.failedWith), (MonitorExecOutcome.signInRefused, ended));
    expect(monitorExecFailure(endedSaying(12, 'Too many connections'), hostKeyNeedsReview: false).outcome,
        MonitorExecOutcome.error);
    expect(
        monitorExecFailure(atJumpHost(JumpStage.signIn, endedSaying(2, 'Too many authentication failures')),
                hostKeyNeedsReview: false)
            .outcome,
        MonitorExecOutcome.signInRefused);
  });

  // What the SSH core ends a connection over by itself, and no timer changes: the next try would end the same
  // way, and each one is a connection that ended before sign-in in the host's log.
  SSHAuthAbortError cutOff(SSHError reason) => SSHAuthAbortError('Connection closed before authentication', reason);
  final noTimerChanges = <String, Object>{
    'a key the host could not prove to be its own':
        cutOff(SSHHostkeyError('Signature verification failed', fault: SSHHostkeyFault.notSigned)),
    'what is no key a host has': SSHHostkeyError('The host key could not be read', fault: SSHHostkeyFault.noKey),
    'a group for the key exchange that is too short':
        cutOff(SSHKexGroupError('of 1024 bits', bits: 1024, shortestTaken: 2048)),
    'a group that is none': SSHKexGroupError('with a generator that is none', bits: 2048, shortestTaken: 2048),
    'a key of the app\'s own that could not sign':
        SSHAuthAbortError('The key could not sign', SSHKeySignError('The signature is not the key\'s own')),
    'the order of the strict key exchange broken': cutOff(SSHHandshakeError(
        'Strict KEX violation: the server\'s key exchange proposal was not the first packet it sent',
        strictOrderBroken: true)),
    'a key exchange with nothing in common': cutOff(SSHHandshakeError('No matching client cipher algorithm',
        offered: const ['aes256-ctr'], otherSideOffered: const ['3des-cbc'])),
  };

  test('a connect that ended over what no timer changes is told as that, at the host or at a jump host on the '
      'way, and is no refused sign-in; a key that is to be looked at comes first', () {
    for (final MapEntry(key: what, value: failure) in noTimerChanges.entries) {
      final told = monitorExecFailure(failure, hostKeyNeedsReview: false);
      expect((told.outcome, told.failedWith), (MonitorExecOutcome.endsTheSame, failure), reason: what);
      final there = JumpHostFailure(
          label: 'auth-gateway', host: '192.0.2.10', port: 22, stage: JumpStage.signIn, cause: failure);
      final atJump = monitorExecFailure(there, hostKeyNeedsReview: false);
      expect((atJump.outcome, atJump.failedWith), (MonitorExecOutcome.endsTheSame, there),
          reason: '$what, at a jump host');
      // A key this device does not trust was shown on the way: that is what its person can mend.
      expect(monitorExecFailure(failure, hostKeyNeedsReview: true).outcome, MonitorExecOutcome.needsHostKeyReview,
          reason: what);
    }
    // A refused sign-in stays one: it has its own words.
    expect(monitorExecFailure(refused, hostKeyNeedsReview: false).outcome, MonitorExecOutcome.signInRefused);
  });

  testWidgets('a host whose connection ends over what no timer changes is dialled once: not again when time passes, '
      'sessions change or the app is away and back', (tester) => withMonitor(tester, (m) async {
    for (final MapEntry(key: what, value: failure) in noTimerChanges.entries) {
      final id = 'h${m.sessions.answers.length}';
      m.sessions.answers[id] = () => monitorExecFailure(failure, hostKeyNeedsReview: false);
      await m.hosts([host(id)]);
      expect(m.dials(id), 1, reason: what);
      // What it failed with is kept, for whoever shows the host to say; and it is no refused sign-in.
      expect(held(m, id), (MonitorHostState.error, failure, false), reason: what);
      expect(notTriedAgain(m, id), isTrue, reason: what);

      await tester.pump(const Duration(hours: 6));
      m.sessions.show({'s1': sessionOn('cache')});
      await m.settle();
      m.sessions.show({});
      await m.settle();
      m.poller.pause();
      await tester.pump(const Duration(minutes: 5));
      m.poller.resume();
      await m.settle();
      expect(m.dials(id), 1, reason: '$what: it was tried again 5, 10, 20, 40, 80, 160 and then every 300 seconds');
      expect(held(m, id), (MonitorHostState.error, failure, false), reason: what);
      expect(notTriedAgain(m, id), isTrue, reason: what);
    }
  }));

  testWidgets('such a host is taken up again when its person asks, when the key or password it signs in with is '
      'saved anew, when it is saved differently and when its person signs in to it: not when the keys this device '
      'trusts change', (tester) => withMonitor(tester, (m) async {
    final failure = noTimerChanges['a group for the key exchange that is too short']!;
    m.sessions.answers['web'] = () => MonitorExecResult.endsTheSame(failure);
    await m.hosts([web]);
    expect(m.dials('web'), 1);

    await m.trustedKeysChanged();
    await m.identities([identity('key-deploy'), identity('key-other', savedAt: 9)]);
    expect(m.dials('web'), 1, reason: 'the keys this device trusts, and another host\'s password');
    m.poller.retry('web');
    await m.settle();
    expect(m.dials('web'), 2, reason: 'asked for');
    expect(notTriedAgain(m, 'web'), isTrue, reason: 'it ended the same way, and is held anew');
    await m.identities([identity('key-deploy', savedAt: 9), identity('key-other', savedAt: 9)]);
    expect(m.dials('web'), 3, reason: 'its key saved anew');
    await m.hosts([host('web', port: 2222)]);
    expect(m.dials('web'), 4, reason: 'saved differently');
    m.sessions.show({'s1': sessionOn('web')});
    await m.settle();
    m.sessions.show({});
    await m.settle();
    expect(m.dials('web'), 5, reason: 'its person signed in to it');
    await tester.pump(const Duration(hours: 6));
    expect(m.dials('web'), 5);

    // Mended since: the next time it is asked for it is checked, and its status says nothing of being held.
    m.sessions.answers['web'] = () => MonitorExecResult.error(const SocketException('Connection refused'));
    m.poller.retry('web');
    await m.settle();
    expect(m.dials('web'), 6);
    expect(notTriedAgain(m, 'web'), isFalse);
    await tester.pump(const Duration(seconds: 5));
    expect(m.dials('web'), 7, reason: 'and a timer tries it again, as any host that cannot be reached');
  }));

  testWidgets('a held host is taken up again when it is saved with Compatibility mode turned on or off: it is '
      'offered something else then', (tester) => withMonitor(tester, (m) async {
    final failure = noTimerChanges['a key exchange with nothing in common']!;
    m.sessions.answers['web'] = () => MonitorExecResult.endsTheSame(failure);
    await m.hosts([web]);
    expect(m.dials('web'), 1);
    await m.hosts([host('web')]);
    expect(m.dials('web'), 1, reason: 'written again as it is');
    await m.hosts([host('web', compatibility: true)]);
    expect(m.dials('web'), 2, reason: 'the mode turned on');
    await m.hosts([host('web', compatibility: true)]);
    expect(m.dials('web'), 2, reason: 'written again as it is');
    await m.hosts([host('web')]);
    expect(m.dials('web'), 3, reason: 'and turned off again');

    // So is a host that is held for its key: another kind of key may be shown to what is offered then.
    m.sessions.answers['db'] = () => MonitorExecResult.needsHostKeyReview(changed: false);
    await m.hosts([host('web'), db]);
    expect((m.dials('db'), m.dials('web')), (1, 3));
    await m.hosts([host('web'), host('db', compatibility: true)]);
    expect((m.dials('db'), m.dials('web')), (2, 3));
  }));

  testWidgets('a host that is monitored no longer is held no longer: chosen again, it is tried anew',
      (tester) => withMonitor(tester, (m) async {
    m.sessions.answers['web'] = () => MonitorExecResult.signInRefused(refused);
    await m.hosts([web]);
    expect(m.dials('web'), 1);
    await m.hosts([]);
    expect(m.poller.state, isEmpty);
    await m.hosts([web]);
    expect(m.dials('web'), 2);
    await m.hosts([web]);
    expect(m.dials('web'), 2, reason: 'held again');
  }));
}
