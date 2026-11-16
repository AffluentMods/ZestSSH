import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart' show ScreenChannel;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_tester.dart';
import 'package:zestssh/features/hosts/widgets/host_network_overrides_section.dart' show EffectiveTestConfig;
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/session/screen_probe.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/session/screen_team_rules.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// A VNC server's side of a channel, all in memory: [said] is sent at once,
/// and what the app writes is kept in [written].
class _Server {
  _Server(List<int> said) {
    input.add(Uint8List.fromList(said));
    output.stream.listen(written.add, onDone: () => closed = true);
  }

  final input = StreamController<Uint8List>();
  final output = StreamController<List<int>>();
  final written = BytesBuilder(copy: true);
  bool closed = false;

  ScreenChannel get channel => ScreenChannel(input.stream, output.sink);

  void end() => input.close();
}

/// A screen's route through its carrier, signed in already, for the test.
class _Route implements ScreenProbeRoute {
  _Route(this.server, {this.fail});
  final _Server server;
  final Object? fail;
  bool closed = false;

  @override
  Future<ScreenChannel> open() async {
    final f = fail;
    if (f != null) throw f;
    return server.channel;
  }

  @override
  Future<void> close() async => closed = true;
}

List<int> _u32(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];
List<int> _banner(String v) => ascii.encode('RFB $v\n');

/// The host editor's Test of a remote screen (4.0): through its SSH
/// host, the VNC server's greeting and the security types it offers; directly,
/// VeNCrypt's subtypes; never a type chosen, a password sent, or TLS begun.
/// All made up.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  group('the greeting', () {
    test('3.8: the version answered and the types read; nothing else written', () async {
      final s = _Server([..._banner('003.008'), 2, 1, 2]);
      final g = await readRfbGreeting(s.channel);
      expect(g.version, '3.8');
      expect(g.securityTypes, [1, 2]);
      expect(g.offersOneTaken, isTrue);
      expect(ascii.decode(s.written.toBytes()), 'RFB 003.008\n');
    });

    test("3.3: the server's one type; Apple's 3.889 is answered as 3.8", () async {
      final old = _Server([..._banner('003.003'), ..._u32(2)]);
      final g = await readRfbGreeting(old.channel);
      expect(g.version, '3.3');
      expect(g.securityTypes, [2]);
      expect(ascii.decode(old.written.toBytes()), 'RFB 003.003\n');
      final apple = _Server([..._banner('003.889'), 2, 30, 2]);
      expect((await readRfbGreeting(apple.channel)).securityTypes, [30, 2]);
      expect(ascii.decode(apple.written.toBytes()), 'RFB 003.008\n');
    });

    test('a server that turns it away says why; one that is not VNC; one that ends first', () async {
      final refused = _Server([..._banner('003.008'), 0, ..._u32(14), ...utf8.encode('Too many tries')]);
      await expectLater(readRfbGreeting(refused.channel),
          throwsA(isA<RfbRefused>().having((e) => e.reason, 'reason', 'Too many tries')));
      // The server's words as shown: no control or bidirectional marks, not a page of them.
      final words = utf8.encode('Go\u001b[2J away\u202e\n${'x' * 400}');
      final odd = _Server([..._banner('003.008'), 0, ..._u32(words.length), ...words]);
      await expectLater(
          readRfbGreeting(odd.channel),
          throwsA(isA<RfbRefused>().having((e) => e.reason, 'reason',
              allOf(startsWith('Go [2J away x'), hasLength(300), endsWith('...')))));
      final ssh = _Server(ascii.encode('SSH-2.0-OpenSSH_9.6\r\n'));
      await expectLater(readRfbGreeting(ssh.channel), throwsA(isA<RfbNotVnc>()));
      final short = _Server(ascii.encode('RFB 003'))..end();
      await expectLater(readRfbGreeting(short.channel),
          throwsA(isA<ScreenFailure>().having((e) => e.kind, 'kind', ScreenFailureKind.serverEnded)));
    });

    test('VeNCrypt: chosen, its version answered, its subtypes read, none chosen (no TLS begins)', () async {
      final s = _Server([..._banner('003.008'), 2, 19, 2, 0, 2, 0, 2, ..._u32(261), ..._u32(257)]);
      final g = await readRfbGreeting(s.channel, vencrypt: true);
      expect(g.vencryptSubtypes, [261, 257]);
      expect(g.vencryptTaken, isTrue);
      expect(s.written.toBytes(), [...ascii.encode('RFB 003.008\n'), 19, 0, 2]);
      final anonymous = _Server([..._banner('003.008'), 1, 19, 0, 2, 0, 1, ..._u32(257)]);
      expect((await readRfbGreeting(anonymous.channel, vencrypt: true)).vencryptTaken, isFalse);
    });

    test('a server that says nothing in time', () async {
      final s = _Server(const []);
      await expectLater(readRfbGreeting(s.channel, timeout: const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()));
    });
  });

  group("an RDP server's answer", () {
    /// A Connection Confirm with the negotiation's answer: [type] 2 a pick, 3 a refusal.
    List<int> confirm(int type, int value) =>
        [3, 0, 0, 19, 14, 0xd0, 0, 0, 0x12, 0x34, 0, type, 0, 8, 0, value, 0, 0, 0];

    test('the request is the one a session sends: NLA and nothing less, or TLS alone; nothing of the account', () {
      expect(rdpConnectionRequest(nla: true), [3, 0, 0, 19, 14, 0xe0, 0, 0, 0, 0, 0, 1, 0, 8, 0, 0x0a, 0, 0, 0]);
      expect(rdpConnectionRequest(nla: false).sublist(15), [1, 0, 0, 0]);
      expect(rdpConnectionRequest(nla: true), hasLength(19), reason: 'no cookie with a user name in it');
    });

    test('what it picked, what it refused, and a server from before TLS; only the request is written', () async {
      final nla = _Server(confirm(2, 2));
      final a = await readRdpAnswer(nla.channel, nla: true);
      expect((a.selected, a.failure, a.nla), (2, null, true));
      expect(nla.written.toBytes(), rdpConnectionRequest(nla: true));
      final early = await readRdpAnswer(_Server(confirm(2, 8)).channel, nla: true);
      expect(early.nla, isTrue);
      final tls = _Server(confirm(2, 1));
      final b = await readRdpAnswer(tls.channel, nla: false);
      expect((b.selected, b.nla), (1, false));
      expect(tls.written.toBytes(), rdpConnectionRequest(nla: false));
      final refused = await readRdpAnswer(_Server(confirm(3, 5)).channel, nla: false);
      expect((refused.selected, refused.failure), (null, 5));
      // Eleven bytes, no word of security: RDP's own old encryption only.
      final old = await readRdpAnswer(_Server([3, 0, 0, 11, 6, 0xd0, 0, 0, 0x12, 0x34, 0]).channel, nla: true);
      expect((old.selected, old.failure), (null, null));
    });

    test('what is no RDP server, one that ends first, and one that says nothing in time', () async {
      await expectLater(readRdpAnswer(_Server(ascii.encode('SSH-2.0-OpenSSH_9.6\r\n')).channel, nla: true),
          throwsA(isA<RdpNotRdp>().having((e) => e.said, 'said', contains('SSH-'))));
      // A TPKT whose length is no Connection Confirm's, and one that is not a confirm at all.
      await expectLater(readRdpAnswer(_Server([3, 0, 0xff, 0xff, 1, 2, 3]).channel, nla: true), throwsA(isA<RdpNotRdp>()));
      await expectLater(readRdpAnswer(_Server([3, 0, 0, 11, 6, 0x80, 0, 0, 0, 0, 0]).channel, nla: true),
          throwsA(isA<RdpNotRdp>()));
      final short = _Server([3, 0, 0, 19, 14])..end();
      await expectLater(readRdpAnswer(short.channel, nla: true),
          throwsA(isA<ScreenFailure>().having((e) => e.kind, 'kind', ScreenFailureKind.serverEnded)));
      await expectLater(readRdpAnswer(_Server(const []).channel, nla: true, timeout: const Duration(milliseconds: 50)),
          throwsA(isA<TimeoutException>()));
    });
  });

  group('Test the screen', () {
    late AppDatabase db;
    late BuildContext at;
    late WidgetRef widgetRef;

    Future<void> host(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final made = DateTime(2026, 11, 8);
      await tester.runAsync(() async {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-gw', label: 'gw', host: 'gw.example.com', protocol: const Value('ssh'), createdAt: made, updatedAt: made));
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-tel', label: 'old', host: 'old.example.com', protocol: const Value('telnet'), createdAt: made, updatedAt: made));
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          connectionTimeoutProvider.overrideWith((ref) => 5),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              at = context;
              widgetRef = ref;
              return const SizedBox();
            }),
          ),
        ),
      ));
    }

    HostTester tester0({
      _Route? route,
      _Server? direct,
      String? socket,
      bool watched = false,
      bool rdp = false,
      bool nla = true,
      ScreenTeamRules teamRules = ScreenTeamRules.none,
      void Function(Connection carrier, ScreenTarget target)? opened,
    }) =>
        HostTester(
          context: at,
          ref: widgetRef,
          addressChosenHere: (_) async => false,
          wouldGoUnwatched: (db, {hostId, keyId}) async => watched,
          requireCratesOpen: (db, {hostId, keyId}) async {},
          screenTeamRules: (db) async => teamRules,
          screenSocket: socket,
          screenRdp: rdp,
          screenRdpNla: nla,
          openScreenRoute: (carrier, target) async {
            opened?.call(carrier, target);
            return route!;
          },
          openScreenDirect: (host, port, timeout) async => direct!.channel,
        );

    Future<HostTestResult?> run(WidgetTester tester, Future<HostTestResult?> Function() test) async {
      HostTestResult? result;
      var done = false;
      unawaited(test().then((r) {
        result = r;
        done = true;
      }));
      for (var i = 0; i < 50 && !done; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(done, isTrue);
      return result;
    }

    EffectiveTestConfig via(String? carrier, {String host = 'localhost', int port = 5900}) =>
        EffectiveTestConfig(host: host, port: port, jumpChain: [?carrier]);

    testWidgets('through its SSH host: the greeting read, the types said, no password sent, all closed', (tester) async {
      await host(tester);
      final server = _Server([..._banner('003.008'), 2, 2, 19]);
      final route = _Route(server);
      ScreenTarget? target;
      final r = await run(tester, () => tester0(route: route, opened: (c, t) => target = t).screenTest(via('h-gw')));
      expect(r!.success, isTrue, reason: r.message);
      expect(r.message, startsWith('Reachable through gw: signed in over SSH in'));
      expect(r.message, contains('a VNC server (RFB 3.8) answers at localhost:5900'));
      expect(r.message, contains('offering VncAuth, VeNCrypt. No VNC password was sent.'));
      expect(target, isA<TcpTarget>().having((t) => t.describe(), 'at', 'localhost:5900'));
      expect(ascii.decode(server.written.toBytes()), 'RFB 003.008\n', reason: 'no type chosen, nothing more');
      expect((server.closed, route.closed), (true, true));
    });

    testWidgets('an RDP host: reachable where the server takes its way of signing in, through its SSH host and '
        'directly; nothing sent but the request, and all closed', (tester) async {
      await host(tester);
      List<int> confirm(int type, int value) =>
          [3, 0, 0, 19, 14, 0xd0, 0, 0, 0x12, 0x34, 0, type, 0, 8, 0, value, 0, 0, 0];
      final server = _Server(confirm(2, 2));
      final route = _Route(server);
      var r = await run(tester, () => tester0(route: route, rdp: true).screenTest(via('h-gw', port: 3389)));
      expect(r!.success, isTrue, reason: r.message);
      expect(r.message, startsWith('Reachable through gw: signed in over SSH in'));
      expect(r.message, contains('an RDP server answers at localhost:3389'));
      expect(r.message, endsWith('No username or password was sent.'));
      expect(r.message, isNot(contains('VNC')));
      expect(server.written.toBytes(), rdpConnectionRequest(nla: true), reason: 'the request and nothing more');
      expect((server.closed, route.closed), (true, true));

      // Directly, a host that signs in without NLA and a server with TLS alone.
      final direct = _Server(confirm(2, 1));
      r = await run(tester,
          () => tester0(direct: direct, rdp: true, nla: false).screenTest(via(null, host: 'pc.example.com', port: 3389)));
      expect(r!.success, isTrue, reason: r.message);
      expect(r.message, startsWith('Reachable: an RDP server answers in'));
      expect(direct.written.toBytes(), rdpConnectionRequest(nla: false));
      expect(direct.closed, isTrue);
    });

    testWidgets('an RDP host whose way of signing in does not fit its server is told which switch to turn, with the '
        "session's own words and code; no TLS, a refusal and what is no RDP server are said", (tester) async {
      await host(tester);
      List<int> confirm(int type, int value) =>
          [3, 0, 0, 19, 14, 0xd0, 0, 0, 0x12, 0x34, 0, type, 0, 8, 0, value, 0, 0, 0];
      Future<HostTestResult> answered(List<int> bytes, {bool nla = true}) async =>
          (await run(tester, () => tester0(route: _Route(_Server(bytes)), rdp: true, nla: nla).screenTest(via('h-gw', port: 3389))))!;
      final setting = en.connectionEditRdpWithoutNla;

      // NLA asked of a server that has TLS only (xrdp): its refusal, or its picking TLS anyway.
      for (final bytes in [confirm(3, 1), confirm(2, 1)]) {
        final r = await answered(bytes);
        expect(r.success, isFalse);
        expect(r.message, allOf(contains(en.screenRdpNlaMissing(setting)), contains('ZS-1813')));
      }
      // Without NLA, of a server that insists on it (Windows by default).
      for (final bytes in [confirm(3, 5), confirm(3, 6), confirm(2, 2)]) {
        final r = await answered(bytes, nla: false);
        expect(r.success, isFalse);
        expect(r.message, allOf(contains(en.screenRdpNlaRequired(setting)), contains('ZS-1814')));
      }
      // No TLS at all: refused so, picked RDP's own encryption, or no word of security.
      for (final bytes in [confirm(3, 2), confirm(2, 0), [3, 0, 0, 11, 6, 0xd0, 0, 0, 0x12, 0x34, 0]]) {
        final r = await answered(bytes);
        expect((r.success, r.message), (false, en.screenTestRdpNoTls));
      }
      expect((await answered(confirm(3, 4))).message, en.screenTestRdpRefused(4));
      final notRdp = await answered(ascii.encode('HTTP/1.1 400 Bad Request'));
      expect(notRdp.message, en.screenTestRdpNotRdp('localhost:3389'));
      expect(notRdp.detail, contains('HTTP'));
    });

    testWidgets('at a socket on its SSH host: the socket is the target', (tester) async {
      await host(tester);
      ScreenTarget? target;
      final r = await run(
          tester,
          () => tester0(route: _Route(_Server([..._banner('003.008'), 1, 1])), socket: '~/.vnc/zest.sock', opened: (c, t) => target = t)
              .screenTest(via('h-gw')));
      expect(r!.success, isTrue, reason: r.message);
      expect(target, isA<UnixSocketTarget>().having((t) => t.path, 'path', '~/.vnc/zest.sock'));
      expect(r.message, contains('answers at ~/.vnc/zest.sock'));
    });

    testWidgets('what fails is said in a screen\'s words with its code: nothing there, refused, not VNC, nothing taken',
        (tester) async {
      await host(tester);
      final nothing = _Route(_Server(const []),
          fail: const ScreenFailure(ScreenFailureKind.nothingAnswers, 'the SSH host refused the channel (2: refused)',
              carrier: 'gw', address: 'localhost:5900'));
      var r = await run(tester, () => tester0(route: nothing).screenTest(via('h-gw')));
      expect(r!.success, isFalse);
      expect(r.message, contains(en.screenNothingAnswers('localhost:5900', 'gw')));
      expect(r.message, contains('ZS-1801'));
      expect(nothing.closed, isTrue, reason: 'the carrier is signed out of');

      r = await run(tester,
          () => tester0(route: _Route(_Server([..._banner('003.008'), 0, ..._u32(4), ...ascii.encode('busy')]))).screenTest(via('h-gw')));
      expect(r!.message, en.screenTestTurnedAway('busy'));

      r = await run(tester, () => tester0(route: _Route(_Server(ascii.encode('HTTP/1.1 400 ')))).screenTest(via('h-gw')));
      expect(r!.message, en.screenTestNotVnc('localhost:5900'));
      expect(r.detail, contains('HTTP/1.1 400'));

      r = await run(tester, () => tester0(route: _Route(_Server([..._banner('003.008'), 2, 5, 16]))).screenTest(via('h-gw')));
      expect(r!.success, isFalse);
      expect(r.message, contains(en.screenTestNothingTaken('RA2, Tight')));
      expect(r.message, contains('ZS-1804'));
    });

    testWidgets('no test of a watched screen, through a host that is no SSH host, or one gone', (tester) async {
      await host(tester);
      var opened = false;
      var r = await run(tester, () => tester0(watched: true, opened: (c, t) => opened = true).screenTest(via('h-gw')));
      expect(r!.message, en.watchedNoTest);
      r = await run(tester, () => tester0(opened: (c, t) => opened = true).screenTest(via('h-tel')));
      expect(r!.message, en.screenCarrierGone);
      r = await run(tester, () => tester0(opened: (c, t) => opened = true).screenTest(via('h-none')));
      expect(r!.message, en.screenCarrierGone);
      expect(opened, isFalse, reason: 'no SSH host was signed in to');
    });

    testWidgets('a team that opens remote screens through SSH only: a direct screen is not dialled by the Test '
        '(ZS-1821), VNC or RDP; one through its SSH host is tested as ever', (tester) async {
      await host(tester);
      const rule = ScreenTeamRules(sshOnly: true);
      for (final rdp in [false, true]) {
        // (No direct server is given: dialling would throw.)
        final r = await run(
            tester, () => tester0(teamRules: rule, rdp: rdp).screenTest(via(null, host: 'desk.example.com')));
        expect(r!.success, isFalse);
        expect(r.message, allOf(contains(en.screenTeamSshOnly(en.connectionEditScreenVia)), contains('ZS-1821')));
      }
      final route = _Route(_Server([..._banner('003.008'), 1, 2]));
      final r = await run(tester, () => tester0(teamRules: rule, route: route).screenTest(via('h-gw')));
      expect(r!.success, isTrue, reason: r.message);
      // The other rule changes nothing of a Test.
      final server = _Server([..._banner('003.008'), 2, 2, 19, 0, 2, 0, 2, ..._u32(261), ..._u32(257)]);
      final direct = await run(
          tester,
          () => tester0(teamRules: const ScreenTeamRules(lockRedirections: true), direct: server)
              .screenTest(via(null, host: 'desk.example.com')));
      expect(direct!.success, isTrue, reason: direct.message);
    });

    testWidgets('directly: VeNCrypt with a certificate offered, said; without it, refused with ZS-1804', (tester) async {
      await host(tester);
      final server = _Server([..._banner('003.008'), 2, 2, 19, 0, 2, 0, 2, ..._u32(261), ..._u32(257)]);
      var r = await run(tester, () => tester0(direct: server).screenTest(via(null, host: 'desk.example.com')));
      expect(r!.success, isTrue, reason: r.message);
      expect(r.message, contains('offers VeNCrypt with X509Vnc. Its certificate is checked when you connect'));
      expect(server.written.toBytes(), [...ascii.encode('RFB 003.008\n'), 19, 0, 2], reason: 'no subtype, no TLS, no password');
      expect(server.closed, isTrue);

      r = await run(tester,
          () => tester0(direct: _Server([..._banner('003.008'), 1, 2])).screenTest(via(null, host: 'desk.example.com')));
      expect(r!.success, isFalse);
      expect(r.message, contains(en.screenTestNoTls('VncAuth')));
      expect(r.message, contains('ZS-1804'));
      r = await run(tester, () => tester0().screenTest(via(null, host: '')));
      expect(r!.message, en.connectionHostRequired);
    });
  });
}
