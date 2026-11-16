// Whether saved hosts can be reached (a reported case:
// addresses banned by fail2ban's sshd jail in its ddos mode, even with
// Server Monitor off). The checks connected to every saved host's SSH port
// every 20 seconds and closed the connection without signing in, which a
// server logs as a connection that ended before sign-in, and they were on
// unless turned off. What is held here: nothing connects anywhere until its
// person turns the checks on, a host is checked no more often than the
// interval they chose, and never where a session already answers, where a
// connect would not go, or while the app is away.
//
// (testWidgets for its clock, which the test moves: no widget is drawn.)

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';

Connection host(String id, {String protocol = 'ssh', String? via, String? address, int port = 22}) {
  final at = DateTime.utc(2026);
  return Connection(
    id: id,
    label: id,
    host: address ?? '$id.example.com',
    port: port,
    connectViaId: via,
    colorIndex: 0,
    protocol: protocol,
    zlibCompression: false,
    keepAliveSeconds: 0,
    envVars: '',
    forwardAgent: false,
    compatibilityMode: false,
    sortOrder: 0,
    sizeTier: 1,
    pinned: false,
    monitored: false,
    createdAt: at,
    updatedAt: at,
  );
}

/// The checks with a clock the test moves, and hosts that answer or not as
/// the test says. Every connection a check makes is written down with its
/// second.
class Checks {
  Checks(this.tester, {ProbeTargetResolver? targetOf}) {
    final clock = tester.binding.clock;
    started = clock.now();
    notifier = ConnectionHealthNotifier(
      targetOf: targetOf,
      now: clock.now,
      probe: (host, port) {
        made.add((at: clock.now().difference(started).inSeconds, to: '$host:$port'));
        final hold = held;
        final answer = down.contains(host) ? null : latency;
        if (hold == null) return Future.value(answer);
        return hold.future.then((_) => answer);
      },
    );
  }

  final WidgetTester tester;
  late final DateTime started;
  late final ConnectionHealthNotifier notifier;
  final made = <({int at, String to})>[];
  final down = <String>{};

  /// How long a host that answers takes, in milliseconds.
  int latency = 4;

  /// While set, a check stays on its way until it completes.
  Completer<void>? held;

  /// The seconds at which [id] was connected to.
  List<int> at(String id) => [
        for (final m in made)
          if (m.to.startsWith('$id.example.com:')) m.at,
      ];

  ConnectionHealth? shown(String id) => notifier.state[id]?.status;

  /// Lets [time] pass on the test's clock, with every timer that falls due.
  Future<void> pass(Duration time) => tester.pump(time);

  /// Lets what is on its way finish, with no time passing.
  Future<void> now() => tester.pump();
}

/// The app's sessions, as the test sets them.
class Sessions extends ActiveSessionsNotifier {
  Sessions(super.ref);

  void show(Map<String, SessionState> sessions) => state = sessions;
}

Network office() => const Network(
    id: 'office',
    name: 'Office',
    color: GroupColor.blue,
    icon: LucideIcons.globe,
    triggers: [AlwaysTrigger()],
    isFallback: false);

/// The network settings as the test says: which hosts are skipped on the
/// network this device is on, which have another address there, and whether
/// they can be read at all. Counts how often the network was looked up.
class Networks implements ConnectionResolver {
  final hosts = <String, Connection>{};
  final skipped = <String>{};
  final moved = <String, ({String host, int port})>{};
  bool broken = false;
  int lookedUp = 0;

  @override
  Future<Network> currentNetwork() async {
    lookedUp++;
    if (broken) throw StateError('the networks cannot be read');
    return office();
  }

  @override
  Future<ResolvedConnection> resolveOn(Network network, String hostId) async {
    final c = hosts[hostId]!;
    if (skipped.contains(hostId)) throw HostUnreachableException(c.label, network.name);
    return ResolvedConnection(
      hostId: hostId,
      network: network,
      address: moved[hostId]?.host ?? c.host,
      port: moved[hostId]?.port ?? c.port,
      username: 'deploy',
      identityKeyId: null,
      jumpChain: [if (c.connectViaId != null) c.connectViaId!],
      bringUpVpnHostId: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Squeezed extends StateNotifier<bool> implements ProStatusNotifier {
  Squeezed(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Runs [body] with the checks, and stops them when it is over: the test's
/// clock allows no timer to outlive its test.
Future<void> withChecks(WidgetTester tester, Future<void> Function(Checks c) body,
    {ProbeTargetResolver? targetOf}) async {
  final c = Checks(tester, targetOf: targetOf);
  try {
    await body(c);
  } finally {
    c.notifier.dispose();
  }
}

void main() {
  final web = host('web');
  final db = host('db');
  final cache = host('cache');

  testWidgets('nothing connects anywhere until the checks are turned on, whoever asks, and nothing is looked up '
      'for it; turned on, every host is checked once at once', (tester) {
    var lookedUp = 0;
    return withChecks(tester, targetOf: (connection) async {
      lookedUp++;
      return (host: connection.host, port: connection.port);
    }, (c) async {
      expect(c.notifier.enabled, isFalse);
      // The Hosts page, a sweep from the Monitor screen, and one host's own
      // refresh.
      c.notifier.startPeriodicChecks([web, db]);
      unawaited(c.notifier.checkAll([web, db, cache]));
      unawaited(c.notifier.checkAll([web, db, cache], asked: true));
      unawaited(c.notifier.checkHealth(web));
      await c.pass(const Duration(minutes: 30));
      expect(c.made, isEmpty);
      expect(c.notifier.state, isEmpty);
      expect(lookedUp, 0, reason: 'where a host is reached is not asked of the network settings either');

      c.notifier.setEnabled(true);
      c.notifier.setEnabled(true);
      await c.now();
      expect(c.made.map((m) => m.to), ['web.example.com:22', 'db.example.com:22'],
          reason: 'the hosts the page asked for, each once');
      expect(lookedUp, 2);
      expect((c.shown('web'), c.shown('db')), (ConnectionHealth.online, ConnectionHealth.online));
      expect(c.notifier.state['web']!.latencyMs, 4);
    });
  });

  testWidgets('turned on while no screen shows hosts, nothing is checked until one does',
      (tester) => withChecks(tester, (c) async {
    c.notifier.setEnabled(true);
    await c.pass(const Duration(minutes: 5));
    expect(c.made, isEmpty);
    c.notifier.startPeriodicChecks([web]);
    await c.now();
    expect(c.at('web'), [300]);
  }));

  testWidgets('a host is checked once in each interval and no more often: at the start, a minute apart until '
      'Settings say otherwise, and never under half a minute apart', (tester) => withChecks(tester, (c) async {
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web, db]);
    await c.pass(const Duration(minutes: 10));
    expect(c.at('web'), [for (var s = 0; s <= 600; s += 60) s]);
    expect(c.at('db'), c.at('web'));
    // The first tick after the start does not check what was just checked.
    expect(c.at('web').where((s) => s < 60), [0]);

    c.made.clear();
    c.notifier.setInterval(const Duration(minutes: 5));
    await c.pass(const Duration(minutes: 30));
    expect(c.at('web'), [for (var s = 900; s <= 2400; s += 300) s], reason: 'five minutes after the last');

    c.made.clear();
    c.notifier.setInterval(const Duration(seconds: 1));
    await c.pass(const Duration(minutes: 2));
    final times = c.at('web');
    expect(times, hasLength(4));
    expect([for (var i = 1; i < times.length; i++) times[i] - times[i - 1]], everyElement(30));
    // What a result stands for goes with the interval: two of them.
    expect(c.notifier.state['web']!.goodFor, const Duration(seconds: 60));
  }));

  testWidgets('a host that stops answering is looked at once more a tick later, shown as away then, and checked at '
      'the interval again; the same when it is back', (tester) => withChecks(tester, (c) async {
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web]);
    await c.pass(const Duration(minutes: 2));
    expect(c.at('web'), [0, 60, 120]);
    expect(c.shown('web'), ConnectionHealth.online);

    c.down.add('web.example.com');
    c.made.clear();
    await c.pass(const Duration(seconds: 60));
    expect(c.at('web'), [180]);
    expect(c.shown('web'), ConnectionHealth.online, reason: 'one check that fails is not the host being away');
    await c.pass(const Duration(seconds: 5));
    expect(c.at('web'), [180, 185]);
    expect(c.shown('web'), ConnectionHealth.offline);
    expect(c.notifier.state['web']!.latencyMs, isNull);
    await c.pass(const Duration(minutes: 3));
    expect(c.at('web'), [180, 185, 245, 305, 365], reason: 'away: checked as often as any other, and no more');

    c.down.clear();
    c.made.clear();
    await c.pass(const Duration(seconds: 60));
    expect(c.at('web'), [425]);
    expect(c.shown('web'), ConnectionHealth.offline);
    await c.pass(const Duration(seconds: 5));
    expect(c.at('web'), [425, 430]);
    expect(c.shown('web'), ConnectionHealth.online);
    await c.pass(const Duration(minutes: 2));
    expect(c.at('web'), [425, 430, 490, 550]);
  }));

  testWidgets('what a connection says nothing about is not checked: a serial port, a shell on this device, the '
      'demo; nor is a host reached through another one', (tester) => withChecks(tester, (c) async {
    final hosts = [
      web,
      host('console', protocol: 'serial', address: 'COM3'),
      host('here', protocol: 'localShell'),
      host('tour', protocol: 'demo'),
      host('inner', via: 'web'),
      host('old', protocol: 'telnet', port: 23),
      host('roaming', protocol: 'mosh'),
      host('eternal', protocol: 'et', port: 2022),
    ];
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks(hosts);
    unawaited(c.notifier.checkAll(hosts));
    await c.pass(const Duration(minutes: 3));
    expect(c.made.map((m) => m.to).toSet(),
        {'web.example.com:22', 'old.example.com:23', 'roaming.example.com:22', 'eternal.example.com:2022'});
    expect(c.notifier.state.keys.toSet(), {'web', 'old', 'roaming', 'eternal'},
        reason: 'nothing is said of a host that is not checked');
  }));

  testWidgets('a host is checked where a connect would go, and one that is to be left alone is: nothing connects, '
      'nothing is shown, and what was shown before is taken away', (tester) {
    final leftAlone = <String>{};
    var failing = false;
    return withChecks(tester, targetOf: (connection) async {
      if (failing) throw StateError('the settings cannot be read');
      if (leftAlone.contains(connection.id)) return null;
      return connection.id == 'web' ? (host: '192.0.2.10', port: 2222) : (host: connection.host, port: connection.port);
    }, (c) async {
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web, db]);
    await c.now();
    expect(c.made.map((m) => m.to), ['192.0.2.10:2222', 'db.example.com:22']);
    expect(c.shown('web'), ConnectionHealth.online);
    await c.pass(const Duration(seconds: 70));

    // Skipped on the network the device moved to.
    leftAlone.add('web');
    c.made.clear();
    await c.pass(const Duration(minutes: 3));
    expect(c.made.map((m) => m.to).toSet(), {'db.example.com:22'});
    expect(c.shown('web'), isNull);
    expect(c.shown('db'), ConnectionHealth.online);

    // Back on a network that reaches it, where it does not answer: the
    // first check says so, with nothing left of the two that it answered.
    leftAlone.clear();
    c.down.add('192.0.2.10');
    c.made.clear();
    await c.pass(const Duration(seconds: 50));
    expect(c.made.where((m) => m.to == '192.0.2.10:2222').map((m) => m.at), [300], reason: 'checked once so far');
    expect(c.shown('web'), ConnectionHealth.offline, reason: 'at that one check, with no second look');
    c.down.clear();
    await c.pass(const Duration(seconds: 80));

    // Where to connect cannot be found out: nothing is tried.
    failing = true;
    c.made.clear();
    await c.pass(const Duration(minutes: 3));
    expect(c.made, isEmpty);
    expect(c.shown('db'), isNull);
    });
  });

  testWidgets('a host a session is connected to is not checked, whoever asks, and shows as reachable; when the '
      'session ends nothing is known of it until it is next due: a session brings no check forward',
      (tester) => withChecks(tester, (c) async {
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web, db]);
    await c.pass(const Duration(seconds: 70));
    expect(c.at('web'), [0, 60]);

    // A short session: connected at 70 seconds, over at 80.
    c.notifier.setSessionHosts({'web'});
    expect(c.shown('web'), ConnectionHealth.online);
    expect(c.notifier.state['web']!.latencyMs, isNull, reason: 'not the figure of a check made before');
    // Told again as it is: nothing changes.
    final before = c.notifier.state;
    c.notifier.setSessionHosts({'web'});
    expect(identical(c.notifier.state, before), isTrue);
    await c.pass(const Duration(seconds: 10));
    c.notifier.setSessionHosts({});
    expect(c.shown('web'), isNull);
    c.made.clear();
    c.latency = 40;
    await c.pass(const Duration(seconds: 35));
    expect(c.at('web'), isEmpty, reason: 'checked at 60 seconds: not due before 120');
    await c.pass(const Duration(seconds: 5));
    expect(c.at('web'), [120]);
    expect(c.shown('web'), ConnectionHealth.online);
    expect(c.notifier.state['web']!.latencyMs, 40, reason: 'nothing is left of how long its answers took before');

    // A long one, during which the host goes away.
    c.notifier.setSessionHosts({'web'});
    c.down.add('web.example.com');
    c.made.clear();
    await c.pass(const Duration(minutes: 10));
    unawaited(c.notifier.checkAll([web, db], asked: true));
    unawaited(c.notifier.checkHealth(web));
    await c.now();
    expect(c.at('web'), isEmpty, reason: 'the session says it is reachable');
    expect(c.at('db'), hasLength(11), reason: 'ten in ten minutes, and the one asked for');
    expect(c.shown('web'), ConnectionHealth.online);

    c.notifier.setSessionHosts({});
    expect(c.shown('web'), isNull);
    await c.pass(const Duration(seconds: 5));
    expect(c.at('web'), hasLength(1), reason: 'long due');
    expect(c.shown('web'), ConnectionHealth.offline, reason: 'it had gone away: the first check says so');
  }));

  testWidgets('how long a session\'s round trips take is the latency of the host it is connected to, smoothed '
      'like a check\'s; nothing is taken for a host no session is connected to, and nothing of it is left once '
      'the session ends', (tester) => withChecks(tester, (c) async {
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web, db]);
    await c.now();
    c.notifier.sessionLatency('web', 99);
    expect(c.notifier.state['web']!.latencyMs, 4, reason: 'no session is connected to it: its check\'s figure');

    await c.pass(const Duration(seconds: 61));
    c.notifier.setSessionHosts({'web'});
    expect(c.notifier.state['web']!.latencyMs, isNull);
    await c.pass(const Duration(seconds: 2));
    c.notifier.sessionLatency('web', 30);
    final first = c.notifier.state['web']!;
    expect((first.status, first.latencyMs, first.goodFor, first.checkedAt),
        (ConnectionHealth.online, 30, const Duration(seconds: 60), c.started.add(const Duration(seconds: 63))));
    // One slow answer among quick ones does not show.
    c.notifier.sessionLatency('web', 31);
    c.notifier.sessionLatency('web', 900);
    expect(c.notifier.state['web']!.latencyMs, 31);
    c.notifier.sessionLatency('db', 55);
    expect(c.notifier.state['db']!.latencyMs, 4, reason: 'db has no session');

    // The session ends; the next check of web is its own, with nothing of
    // the session's figures in it.
    c.notifier.setSessionHosts({});
    c.latency = 7;
    await c.pass(const Duration(seconds: 60));
    expect(c.notifier.state['web']!.latencyMs, 7);
  }));

  testWidgets('with the checks off, what a session says is all there is', (tester) => withChecks(tester, (c) async {
    c.notifier.startPeriodicChecks([web, db]);
    c.notifier.setSessionHosts({'web'});
    expect((c.shown('web'), c.shown('db')), (ConnectionHealth.online, null));
    await c.pass(const Duration(minutes: 10));
    c.notifier.setSessionHosts({});
    await c.pass(const Duration(minutes: 10));
    expect(c.notifier.state, isEmpty);
    expect(c.made, isEmpty);
  }));

  testWidgets('a check on its way when a session connects, or when the checks are turned off, says nothing',
      (tester) => withChecks(tester, (c) async {
    c.held = Completer<void>();
    c.down.add('web.example.com');
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web, db]);
    await c.now();
    expect(c.made, hasLength(2));
    // A session connects to web while its check is on its way.
    c.notifier.setSessionHosts({'web'});
    c.held!.complete();
    await c.now();
    expect(c.shown('web'), ConnectionHealth.online, reason: 'the session, not the check that failed');
    expect(c.shown('db'), ConnectionHealth.online);

    // The checks are turned off while the next one of db is on its way.
    c.held = Completer<void>();
    c.down.add('db.example.com');
    await c.pass(const Duration(seconds: 60));
    expect(c.made, hasLength(3));
    c.notifier.setEnabled(false);
    c.held!.complete();
    await c.now();
    expect(c.notifier.state.keys, ['web'], reason: 'turned off before it answered: only what the session says');
    expect(c.shown('web'), ConnectionHealth.online);
  }));

  testWidgets('a session that connects, or the checks being turned off, while it is looked up where a host is '
      'reached: nothing connects to it', (tester) {
    var lookup = Completer<void>();
    return withChecks(tester, targetOf: (connection) async {
      await lookup.future;
      return (host: connection.host, port: connection.port);
    }, (c) async {
      c.notifier
        ..setEnabled(true)
        ..startPeriodicChecks([web, db]);
      await c.now();
      expect(c.made, isEmpty, reason: 'still being looked up');
      c.notifier.setSessionHosts({'db'});
      lookup.complete();
      await c.now();
      expect(c.made.map((m) => m.to), ['web.example.com:22'], reason: 'db has a session now');

      lookup = Completer<void>();
      await c.pass(const Duration(seconds: 60));
      expect(c.made, hasLength(1), reason: 'the next check of web is being looked up');
      c.notifier.setEnabled(false);
      lookup.complete();
      await c.now();
      expect(c.made, hasLength(1));
      expect(c.notifier.state.keys, ['db'], reason: 'what its session says, and nothing else');
    });
  });

  testWidgets('the app closes with a check on its way, or while it is looked up where a host is reached: '
      'nothing connects after, and nothing is thrown', (tester) async {
    final answered = Checks(tester)..held = Completer<void>();
    answered.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web]);
    await answered.now();
    expect(answered.made, hasLength(1));
    answered.notifier.dispose();
    answered.held!.complete();
    await answered.now();
    expect(tester.takeException(), isNull);

    final lookup = Completer<void>();
    final lookedUp = Checks(tester, targetOf: (connection) async {
      await lookup.future;
      return (host: connection.host, port: connection.port);
    });
    lookedUp.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web]);
    await lookedUp.now();
    lookedUp.notifier.dispose();
    lookup.complete();
    await lookedUp.now();
    expect(lookedUp.made, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('turned off, the checks stop at once and what they found is forgotten, while what sessions say '
      'stays; turned on again they start anew', (tester) => withChecks(tester, (c) async {
    c.down.add('db.example.com');
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web, db, cache]);
    await c.pass(const Duration(seconds: 70));
    c.notifier.setSessionHosts({'cache'});
    expect((c.shown('web'), c.shown('db'), c.shown('cache')),
        (ConnectionHealth.online, ConnectionHealth.offline, ConnectionHealth.online));

    c.notifier.setEnabled(false);
    expect(c.notifier.state.keys, ['cache'], reason: 'a dot nobody checks any more says nothing');
    c.made.clear();
    await c.pass(const Duration(hours: 1));
    expect(c.made, isEmpty);

    // Meanwhile db came back, and the hosts answer more slowly.
    c.down.clear();
    c.latency = 40;
    c.notifier.setEnabled(true);
    await c.now();
    expect(c.made.map((m) => m.to), ['web.example.com:22', 'db.example.com:22'], reason: 'at once, each once');
    expect(c.shown('db'), ConnectionHealth.online, reason: 'the first check decides: nothing is left of before');
    expect(c.notifier.state['web']!.latencyMs, 40, reason: 'nor of how long its answers took');

    // Off and on again within the minute: checked anew at once all the same.
    c.notifier.setEnabled(false);
    await c.pass(const Duration(seconds: 10));
    c.made.clear();
    c.notifier.setEnabled(true);
    await c.now();
    expect(c.made.map((m) => m.to), ['web.example.com:22', 'db.example.com:22']);
  }));

  testWidgets('while the app is away nothing is checked, and the hosts that fell due are checked when it is back',
      (tester) => withChecks(tester, (c) async {
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web, db]);
    await c.pass(const Duration(seconds: 30));
    c.notifier.pause();
    c.made.clear();
    await c.pass(const Duration(hours: 2));
    unawaited(c.notifier.checkAll([web, db], asked: true));
    unawaited(c.notifier.checkHealth(web));
    await c.now();
    expect(c.made, isEmpty);

    c.notifier.resume();
    await c.now();
    expect(c.made.map((m) => m.to), ['web.example.com:22', 'db.example.com:22']);
    c.notifier.resume();
    await c.now();
    expect(c.made, hasLength(2), reason: 'back already: nothing is checked twice');
    await c.pass(const Duration(seconds: 59));
    expect(c.made, hasLength(2));
    await c.pass(const Duration(seconds: 6));
    expect(c.made, hasLength(4));

    // No screen asks for the hosts any more: coming back checks nothing.
    c.notifier.stopPeriodicChecks();
    c.notifier.pause();
    await c.pass(const Duration(minutes: 10));
    c.made.clear();
    c.notifier.resume();
    await c.now();
    expect(c.made, isEmpty);
  }));

  testWidgets('a sweep a screen asks for is a check like any other: it counts towards the interval, and ten hosts '
      'at most are on their way at a time', (tester) => withChecks(tester, (c) async {
    final many = [for (var i = 0; i < 25; i++) host('h$i')];
    c.held = Completer<void>();
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks(many);
    await c.pass(const Duration(seconds: 20));
    expect(c.made, hasLength(10), reason: 'ten wait for their answer, and the others for them');
    c.held!.complete();
    c.held = null;
    await c.pass(const Duration(seconds: 10));
    expect(c.made.map((m) => m.to).toSet(), hasLength(25));
    expect(c.made, hasLength(25));

    // The Monitor screen opens, half a minute in: nothing is due, and a
    // screen that opens asks for nothing.
    c.made.clear();
    unawaited(c.notifier.checkAll(many));
    await c.now();
    expect(c.made, isEmpty);
    // Its refresh, pressed: every host now.
    unawaited(c.notifier.checkAll(many, asked: true));
    await c.now();
    expect(c.made, hasLength(25), reason: 'asked for by its person: checked now');
    await c.pass(const Duration(seconds: 55));
    expect(c.made, hasLength(25), reason: 'and not again until the interval is over');
    // One host's own refresh is asked for as well.
    unawaited(c.notifier.checkHealth(many.first));
    await c.now();
    expect(c.made, hasLength(26));
  }));

  testWidgets('a host whose check is on its way is not checked again by a refresh',
      (tester) => withChecks(tester, (c) async {
    c.held = Completer<void>();
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web, db]);
    await c.now();
    expect(c.made, hasLength(2));
    unawaited(c.notifier.checkAll([web, db, cache], asked: true));
    await c.now();
    expect(c.made.map((m) => m.to), ['web.example.com:22', 'db.example.com:22', 'cache.example.com:22'],
        reason: 'only the one that was not on its way');
    // Nor when it is due again and still has no answer.
    c.notifier.startPeriodicChecks([web, db, cache]);
    await c.pass(const Duration(seconds: 70));
    expect(c.made, hasLength(3));
    c.held!.complete();
    await c.now();
    expect(c.notifier.state.keys.toSet(), {'web', 'db', 'cache'});
  }));

  testWidgets('hosts that are not checked do not stand in the way of those that are, however many there are',
      (tester) => withChecks(tester, (c) async {
    final consoles = [for (var i = 0; i < 12; i++) host('console$i', protocol: 'serial')];
    final busy = [for (var i = 0; i < 12; i++) host('busy$i')];
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([...consoles, web]);
    await c.pass(const Duration(minutes: 3));
    expect(c.made.map((m) => m.at), [0, 60, 120, 180]);
    expect(c.at('web'), [0, 60, 120, 180]);

    // The same with hosts that sessions are connected to.
    c.notifier.setSessionHosts({for (final b in busy) b.id});
    c.notifier.startPeriodicChecks([...busy, web]);
    c.made.clear();
    await c.pass(const Duration(minutes: 3));
    expect(c.made.map((m) => m.at), [240, 300, 360]);
    expect(c.at('web'), [240, 300, 360]);
  }));

  testWidgets('a result stands for two of the intervals the checks run at, one that follows another within '
      'seconds as well', (tester) => withChecks(tester, (c) async {
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web]);
    await c.now();
    expect(c.notifier.state['web']!.goodFor, const Duration(minutes: 2));

    // Every five minutes from now on, and a refresh a second later.
    c.notifier.setInterval(const Duration(minutes: 5));
    c.latency = 40;
    await c.pass(const Duration(seconds: 1));
    unawaited(c.notifier.checkAll([web], asked: true));
    await c.now();
    expect(c.made, hasLength(2));
    final again = c.notifier.state['web']!;
    expect((again.goodFor, again.latencyMs, again.checkedAt), (const Duration(minutes: 10), 40, c.started.add(const Duration(seconds: 1))));
  }));

  // (Neither of these two stops the checks at its end: the test's clock
  // fails a test that leaves a timer behind.)
  testWidgets('turned off, the checks keep no timer', (tester) async {
    final c = Checks(tester);
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web]);
    await c.pass(const Duration(seconds: 70));
    expect(c.at('web'), [0, 60]);
    c.notifier.setEnabled(false);
  });

  testWidgets('with no screen asking for them, the checks keep no timer', (tester) async {
    final c = Checks(tester);
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web]);
    await c.pass(const Duration(seconds: 70));
    expect(c.at('web'), [0, 60]);
    c.notifier.stopPeriodicChecks();
  });

  testWidgets('a host that is saved no longer is forgotten, and the hosts checked are those of the list as it is '
      'now', (tester) => withChecks(tester, (c) async {
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web, db]);
    await c.now();
    expect(c.notifier.state.keys.toSet(), {'web', 'db'});
    c.notifier.setSessionHosts({'cache'});

    // The page draws again with the list as it is now.
    c.notifier.startPeriodicChecks([web]);
    expect(c.notifier.state.keys.toSet(), {'web', 'cache'},
        reason: 'db is gone; cache has a session, on this list or not');
    c.made.clear();
    await c.pass(const Duration(minutes: 2));
    expect(c.made.map((m) => m.to).toSet(), {'web.example.com:22'});

    c.notifier.stopPeriodicChecks();
    c.made.clear();
    await c.pass(const Duration(minutes: 5));
    expect(c.made, isEmpty, reason: 'no screen asks for them any more');
  }));

  testWidgets('another list of hosts on screen, and the first one back: no host is checked sooner for it',
      (tester) => withChecks(tester, (c) async {
    c.notifier
      ..setEnabled(true)
      ..startPeriodicChecks([web, db]);
    await c.pass(const Duration(seconds: 70));
    c.made.clear();
    // Another space, with a host of its own: checked at the next tick.
    c.notifier.startPeriodicChecks([cache]);
    expect(c.notifier.state, isEmpty);
    await c.pass(const Duration(seconds: 10));
    expect(c.made.map((m) => (m.at, m.to)), [(75, 'cache.example.com:22')]);
    // And back, eighty seconds in, with web no longer answering.
    c.down.add('web.example.com');
    c.notifier.startPeriodicChecks([web, db]);
    c.made.clear();
    await c.pass(const Duration(seconds: 35));
    expect(c.made, isEmpty, reason: 'checked at a minute: not due before two');
    expect(c.shown('web'), isNull);
    await c.pass(const Duration(seconds: 5));
    expect(c.made.map((m) => (m.at, m.to)), [(120, 'web.example.com:22'), (120, 'db.example.com:22')]);
    expect((c.shown('web'), c.shown('db')), (ConnectionHealth.offline, ConnectionHealth.online),
        reason: 'the first check decides: nothing is left of the two it answered');
  }));

  test('how old a result is, for whoever weighs it: what the result stands for, where that is longer than what its '
      'reader allows', () {
    final at = DateTime(2026, 10, 9, 12);
    const online = ConnectionHealth.online;
    final plain = HealthCheckResult(status: online, checkedAt: at);
    final fiveMinutes = HealthCheckResult(status: online, checkedAt: at, goodFor: const Duration(minutes: 10));
    const allowed = Duration(seconds: 90);
    expect(plain.staleAt(at.add(const Duration(seconds: 90)), allowed), isFalse);
    expect(plain.staleAt(at.add(const Duration(seconds: 91)), allowed), isTrue);
    expect(fiveMinutes.staleAt(at.add(const Duration(minutes: 10)), allowed), isFalse);
    expect(fiveMinutes.staleAt(at.add(const Duration(minutes: 10, seconds: 1)), allowed), isTrue);
    expect(fiveMinutes.staleAt(at.add(const Duration(minutes: 15)), const Duration(minutes: 20)), isFalse);
  });

  test('the status bar counts the hosts that can be reached only where hosts are checked', () {
    final at = DateTime(2026, 10, 9, 12);
    HealthCheckResult is_(ConnectionHealth status) => HealthCheckResult(status: status, checkedAt: at);
    final known = {
      'web': is_(ConnectionHealth.online),
      'db': is_(ConnectionHealth.online),
      'cache': is_(ConnectionHealth.offline),
      'old': is_(ConnectionHealth.unknown),
    };
    expect(reachableHostsCount(known, checksOn: true), (online: 2, tracked: 3));
    expect(reachableHostsCount(const {}, checksOn: true), (online: 0, tracked: 0));
    // Off: what is known there is what sessions say, and the bar has a
    // count of sessions.
    expect(reachableHostsCount(known, checksOn: false), (online: 0, tracked: 0));
  });

  group('where a check connects', () {
    Network network(String name) => Network(
        id: name,
        name: name,
        color: GroupColor.blue,
        icon: LucideIcons.globe,
        triggers: const [AlwaysTrigger()],
        isFallback: false);
    ResolvedConnection resolved(Connection c, {String? address, int? port, List<String>? chain}) => ResolvedConnection(
          hostId: c.id,
          network: network('Office'),
          address: address ?? c.host,
          port: port ?? c.port,
          username: 'deploy',
          identityKeyId: null,
          jumpChain: chain ?? [if (c.connectViaId != null) c.connectViaId!],
          bringUpVpnHostId: null,
        );
    final inner = host('inner', via: 'web');

    test('the address and port a connect from this network would dial', () {
      expect(probeTargetFor(web, resolved: resolved(web), isPro: true), (host: 'web.example.com', port: 22));
      expect(probeTargetFor(web, resolved: resolved(web, address: '192.0.2.10', port: 2222), isPro: false),
          (host: '192.0.2.10', port: 2222));
      expect(probeTargetFor(web, resolved: null, isPro: true), (host: 'web.example.com', port: 22),
          reason: 'the network settings could not be read: the host as it is saved');
    });

    test('nowhere for a host reached through another, whoever says so: the host itself or this network', () {
      expect(probeTargetFor(inner, resolved: resolved(inner), isPro: true), isNull);
      expect(probeTargetFor(inner, resolved: null, isPro: true), isNull);
      expect(probeTargetFor(web, resolved: resolved(web, chain: ['db']), isPro: true), isNull);
      // This network reaches it directly.
      expect(probeTargetFor(inner, resolved: resolved(inner, chain: const []), isPro: true),
          (host: 'inner.example.com', port: 22));
    });

    test('without Squeezed nothing is reached through another host, so the host itself is what is checked', () {
      expect(probeTargetFor(inner, resolved: resolved(inner), isPro: false), (host: 'inner.example.com', port: 22));
      expect(probeTargetFor(inner, resolved: null, isPro: false), (host: 'inner.example.com', port: 22));
      expect(probeTargetFor(web, resolved: resolved(web, chain: ['db']), isPro: false),
          (host: 'web.example.com', port: 22));
    });

    test('a host as it is saved, where there are no network settings at all', () async {
      expect(await savedProbeTarget(web), (host: 'web.example.com', port: 22));
      expect(await savedProbeTarget(inner), isNull);
    });
  });

  group('where the app\'s checks connect', () {
    late AppDatabase tree;
    late Networks networks;
    late DateTime clock;
    final inner = host('inner', via: 'web');

    ReachabilityTargets targets({bool squeezed = true}) {
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(tree),
        connectionResolverProvider.overrideWithValue(networks),
        isProProvider.overrideWith((ref) => Squeezed(squeezed)),
      ]);
      addTearDown(container.dispose);
      return container.read(Provider((ref) => ReachabilityTargets(ref, now: () => clock)));
    }

    setUp(() {
      tree = AppDatabase.forTesting(NativeDatabase.memory());
      networks = Networks()..hosts.addAll({for (final c in [web, db, cache, inner]) c.id: c});
      clock = DateTime(2026, 10, 9, 12);
    });

    tearDown(() => tree.close());

    test('where a connect from this network would: the address it has here, nowhere when it is skipped here or '
        'reached through another host', () async {
      final t = targets();
      networks.moved['web'] = (host: '192.0.2.10', port: 2222);
      networks.skipped.add('db');
      expect(await t.of(web), (host: '192.0.2.10', port: 2222));
      expect(await t.of(db), isNull);
      expect(await t.of(cache), (host: 'cache.example.com', port: 22));
      expect(await t.of(inner), isNull);
      // Without Squeezed nothing is reached through another host.
      expect(await targets(squeezed: false).of(inner), (host: 'inner.example.com', port: 22));
    });

    test('the network is looked up once for the hosts checked within the same few seconds, and anew after', () async {
      final t = targets();
      await Future.wait([t.of(web), t.of(db), t.of(cache)]);
      expect(networks.lookedUp, 1, reason: 'three hosts due at one tick');
      clock = clock.add(const Duration(seconds: 3));
      await t.of(web);
      expect(networks.lookedUp, 1);
      clock = clock.add(const Duration(seconds: 2));
      await t.of(web);
      expect(networks.lookedUp, 2, reason: 'the device may have moved since');
    });

    test('where the network settings cannot be read the host is taken as it is saved, and they are asked for anew '
        'the next time', () async {
      final t = targets();
      networks.broken = true;
      networks.moved['web'] = (host: '192.0.2.10', port: 2222);
      expect(await t.of(web), (host: 'web.example.com', port: 22));
      expect(await t.of(inner), isNull, reason: 'as it is saved: through another host');
      expect(networks.lookedUp, 2, reason: 'a lookup that failed is not kept');
      networks.broken = false;
      expect(await t.of(web), (host: '192.0.2.10', port: 2222));
    });
  });

  group('sessions time their own round trips', () {
    late Sessions sessions;
    late ConnectionHealthNotifier checks;
    late void Function() end;
    final asked = <String>[];
    // What each session answers, by its label: a time, or nothing where it
    // cannot be timed.
    final answers = <String, int?>{};
    Completer<void>? held;

    SessionState session(String host, String label, {SessionStatus status = SessionStatus.connected}) =>
        SessionState(status: status, connectionId: host, connectionLabel: label);

    Future<void> start(WidgetTester tester, {Map<String, SessionState> there = const {}}) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      asked.clear();
      answers.clear();
      held = null;
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(Sessions.new),
        connectionHealthProvider.overrideWith((ref) => ConnectionHealthNotifier(now: tester.binding.clock.now)),
      ]);
      sessions = container.read(activeSessionsProvider.notifier) as Sessions;
      checks = container.read(connectionHealthProvider.notifier);
      if (there.isNotEmpty) sessions.show(there);
      end = wireReachabilityChecks(container, roundTrip: (s) async {
        asked.add(s.connectionLabel);
        await held?.future;
        return answers[s.connectionLabel];
      });
      addTearDown(container.dispose);
    }

    int? latency(String host) => checks.state[host]?.latencyMs;

    testWidgets('as a session connects and every half minute after, for as long as it is connected, with the '
        'checks off', (tester) async {
      await start(tester);
      answers['web-1'] = 12;
      await tester.pump(const Duration(minutes: 2));
      expect(asked, isEmpty, reason: 'no session, nothing to time');

      sessions.show({'s1': session('web', 'web-1')});
      await tester.pump();
      expect(asked, ['web-1'], reason: 'at once');
      expect((checks.state['web']!.status, latency('web')), (ConnectionHealth.online, 12));
      expect(checks.enabled, isFalse);

      answers['web-1'] = 14;
      await tester.pump(const Duration(seconds: 29));
      expect(asked, hasLength(1));
      await tester.pump(const Duration(seconds: 1));
      expect(asked, hasLength(2));
      expect(latency('web'), 14);
      await tester.pump(const Duration(minutes: 2));
      expect(asked, hasLength(6));

      // Its state changing (a line in its log) is no new connection.
      sessions.show({'s1': session('web', 'web-1').withLog('ready')});
      await tester.pump();
      expect(asked, hasLength(6));

      // Dropped: nothing more is asked of it, and nothing is shown.
      sessions.show({'s1': session('web', 'web-1', status: SessionStatus.disconnected)});
      await tester.pump(const Duration(minutes: 2));
      expect(asked, hasLength(6));
      expect(checks.state, isEmpty);
      end();
    });

    testWidgets('a session that was there before the app got this far is timed as it starts', (tester) async {
      await start(tester, there: {'s1': const SessionState(status: SessionStatus.connected, connectionId: 'web', connectionLabel: 'web-1')});
      await tester.pump();
      expect(asked, ['web-1']);
      end();
    });

    testWidgets('one figure for a host: the first of its sessions that can be timed; none where none can',
        (tester) async {
      await start(tester);
      answers.addAll({'web-telnet': null, 'web-ssh': 20, 'web-ssh-2': 99, 'console': null});
      sessions.show({
        's1': session('web', 'web-telnet'),
        's2': session('web', 'web-ssh'),
        's3': session('web', 'web-ssh-2'),
        's4': session('serial', 'console'),
        's5': session('db', 'db-connecting', status: SessionStatus.connecting),
      });
      await tester.pump();
      expect(asked, ['web-telnet', 'console', 'web-ssh'], reason: 'not the third: the second answered');
      expect(latency('web'), 20);
      expect((checks.state['serial']!.status, latency('serial')), (ConnectionHealth.online, null),
          reason: 'connected, with no figure');
      expect(checks.state.containsKey('db'), isFalse);
      end();
    });

    testWidgets('not while the app is away, and no second round while one is on its way', (tester) async {
      await start(tester);
      answers['web-1'] = 12;
      sessions.show({'s1': session('web', 'web-1')});
      await tester.pump();
      expect(asked, hasLength(1));

      checks.pause();
      await tester.pump(const Duration(minutes: 5));
      expect(asked, hasLength(1));
      checks.resume();
      await tester.pump(const Duration(seconds: 30));
      expect(asked, hasLength(2));

      // An answer that takes longer than half a minute.
      held = Completer<void>();
      await tester.pump(const Duration(seconds: 30));
      expect(asked, hasLength(3));
      await tester.pump(const Duration(minutes: 2));
      expect(asked, hasLength(3), reason: 'still waiting for that one');
      held!.complete();
      held = null;
      await tester.pump(const Duration(seconds: 30));
      expect(asked, hasLength(4));
      end();
    });

    testWidgets('ended with the app: nothing is timed any more, and no timer is left', (tester) async {
      await start(tester);
      answers['web-1'] = 12;
      sessions.show({'s1': session('web', 'web-1')});
      await tester.pump();
      end();
      await tester.pump(const Duration(minutes: 5));
      expect(asked, hasLength(1));
    });
  });

  group('in the app', () {
    final made = <String>[];

    Future<ProviderContainer> app({Map<String, Object> saved = const {}}) async {
      SharedPreferences.setMockInitialValues(saved);
      final prefs = await SharedPreferences.getInstance();
      made.clear();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        activeSessionsProvider.overrideWith(Sessions.new),
        connectionHealthProvider.overrideWith((ref) => ConnectionHealthNotifier(probe: (host, port) async {
              made.add('$host:$port');
              return 4;
            })),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    test('nothing is checked for someone who never chose, whatever the setting before this one held', () async {
      final container = await app(saved: {'health_checks_enabled': true});
      final checks = container.read(connectionHealthProvider.notifier);
      addTearDown(wireReachabilityChecks(container));
      expect(checks.enabled, isFalse);
      checks.startPeriodicChecks([web, db]);
      await checks.checkAll([web, db], asked: true);
      expect(made, isEmpty);
      expect(checks.interval, const Duration(seconds: 60), reason: 'once a minute, when they are turned on');
    });

    test('until the app has started them the checks follow nothing; from then on they follow Settings: on or '
        'off, and how often', () async {
      final container = await app(saved: {'reachability_checks_enabled': true, 'health_check_interval': 300});
      final checks = container.read(connectionHealthProvider.notifier);
      expect((checks.enabled, checks.interval), (false, const Duration(seconds: 60)));
      await checks.checkAll([web], asked: true);
      expect(made, isEmpty);

      final end = wireReachabilityChecks(container);
      expect((checks.enabled, checks.interval), (true, const Duration(minutes: 5)));
      await checks.checkAll([web], asked: true);
      expect(made, ['web.example.com:22']);

      final settings = container.read(settingsUpdaterProvider);
      await settings.setHealthCheckInterval(30);
      expect(checks.interval, const Duration(seconds: 30));
      await settings.setHealthChecksEnabled(false);
      expect(checks.enabled, isFalse);
      expect(checks.state, isEmpty, reason: 'what was found is forgotten with them');
      await settings.setHealthChecksEnabled(true);
      expect(checks.enabled, isTrue);

      // Ended (the app closes): nothing is followed any more.
      end();
      await settings.setHealthChecksEnabled(false);
      await settings.setHealthCheckInterval(300);
      (container.read(activeSessionsProvider.notifier) as Sessions)
          .show({'s1': const SessionState(status: SessionStatus.connected, connectionId: 'db')});
      expect((checks.enabled, checks.interval), (true, const Duration(seconds: 30)));
      expect(checks.state, isEmpty);
    });

    test('the hosts sessions are connected to show as reachable, whether the checks are on or not; one that is '
        'still connecting, or dropped, does not', () async {
      final container = await app();
      final checks = container.read(connectionHealthProvider.notifier);
      final sessions = container.read(activeSessionsProvider.notifier) as Sessions;
      const connected = SessionStatus.connected;
      // A session that is there before the app has got this far (one
      // brought back as it starts), with a screen already showing the hosts.
      sessions.show({'s0': const SessionState(status: connected, connectionId: 'cache')});
      container.listen(connectionHealthProvider, (_, _) {});
      addTearDown(wireReachabilityChecks(container));
      expect(checks.state.keys, ['cache']);
      sessions.show({
        's1': const SessionState(status: connected, connectionId: 'web'),
        's2': const SessionState(status: connected, connectionId: 'web'),
        's3': const SessionState(status: SessionStatus.connecting, connectionId: 'db'),
        's4': const SessionState(status: SessionStatus.disconnected, connectionId: 'cache', dropped: true),
        's5': const SessionState(status: connected),
      });
      expect(checks.state.keys, ['web']);
      expect(checks.state['web']!.status, ConnectionHealth.online);
      expect(connectedHosts(container.read(activeSessionsProvider)), {'web'});

      // One of its two sessions ends: still connected to. Both: nothing is known of it.
      sessions.show({'s2': const SessionState(status: connected, connectionId: 'web')});
      expect(checks.state.keys, ['web']);
      sessions.show({'s2': const SessionState(status: SessionStatus.disconnected, connectionId: 'web', dropped: true)});
      expect(checks.state, isEmpty);
      expect(made, isEmpty);
    });
  });
}
