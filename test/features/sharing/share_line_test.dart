// The line to the relay (share_line.dart) against a WebSocket server on
// this machine that plays ZestSSH Cloud's part: what the app says first,
// what it makes of what it hears, how it frames bytes, and what it does when
// the line closes, for each way it can close.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';

const shareId = '11111111-1111-4111-8111-111111111111';

/// One connection as the server sees it.
class Conn {
  Conn(this.socket, this.path);

  final WebSocket socket;
  final String path;
  final texts = <Map<String, dynamic>>[];
  final binaries = <Uint8List>[];
  bool closed = false;
}

/// A WebSocket server standing in for the relay. [onAuth] decides what
/// each new connection is told after its first message.
class FakeRelay {
  late final HttpServer _server;
  final connections = <Conn>[];
  void Function(Conn c, Map<String, dynamic> auth)? onAuth;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      final c = Conn(socket, request.uri.toString());
      connections.add(c);
      socket.listen((m) {
        if (m is String) {
          final json = jsonDecode(m) as Map<String, dynamic>;
          c.texts.add(json);
          if (c.texts.length == 1) onAuth?.call(c, json);
        } else {
          c.binaries.add(Uint8List.fromList(m as List<int>));
        }
      }, onDone: () => c.closed = true);
    });
  }

  String get apiBase => 'http://127.0.0.1:${_server.port}/v1';

  Future<void> stop() async {
    for (final c in connections) {
      await c.socket.close();
    }
    await _server.close(force: true);
  }
}

Future<void> until(bool Function() check, {String? what}) async {
  for (var i = 0; i < 3000; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('timed out waiting${what == null ? '' : ' for $what'}');
}

void main() {
  late FakeRelay relay;
  final lines = <ShareLine>[];
  var tokens = <({bool fresh})>[];
  String? Function({bool fresh}) tokenFor = ({bool fresh = false}) => fresh ? 'fresh-token' : 'token';

  setUp(() async {
    relay = FakeRelay();
    await relay.start();
    tokens = [];
    tokenFor = ({bool fresh = false}) => fresh ? 'fresh-token' : 'token';
  });

  tearDown(() async {
    for (final l in lines) {
      await l.close();
    }
    lines.clear();
    await relay.stop();
  });

  ShareLine line({bool host = false, String? session, Duration renewEvery = const Duration(minutes: 45)}) {
    final l = ShareLine(
      url: ShareLine.urlFor(relay.apiBase),
      connect: (url) => WebSocket.connect(url.toString()),
      token: ({bool fresh = false}) async {
        tokens.add((fresh: fresh));
        return tokenFor(fresh: fresh);
      },
      session: () => session,
      shareId: shareId,
      host: host,
      retryDelay: (_) => const Duration(milliseconds: 5),
      renewEvery: renewEvery,
    );
    lines.add(l);
    return l;
  }

  /// Starts [l] and collects what it says.
  List<ShareLineEvent> listen(ShareLine l) {
    final events = <ShareLineEvent>[];
    l.events.listen(events.add);
    l.start();
    return events;
  }

  void ready(Conn c, Map<String, dynamic> message) => c.socket.add(jsonEncode({'type': 'ready', ...message}));

  test('the address is the API\'s, with nothing of the person in it', () {
    expect(ShareLine.urlFor('https://api.zestssh.com/v1').toString(), 'wss://api.zestssh.com/v1/share');
    expect(ShareLine.urlFor('https://api.zestssh.com/v1/').toString(), 'wss://api.zestssh.com/v1/share');
    expect(ShareLine.urlFor('http://127.0.0.1:39200/v1').toString(), 'ws://127.0.0.1:39200/v1/share');
  });

  test('the first thing said is the sign-in: the token, the share, the role, and never in the address', () async {
    relay.onAuth = (c, _) => ready(c, {'mode': 'live', 'viewers': <Object>[]});
    final host = line(host: true, session: 'device-1');
    final events = listen(host);
    await until(() => events.isNotEmpty);
    final c = relay.connections.single;
    expect(c.path, '/v1/share', reason: 'no token, no share, nothing in the address');
    expect(c.texts.single, {'type': 'auth', 'token': 'token', 'share': shareId, 'role': 'host', 'session': 'device-1'});
    expect(tokens, [(fresh: false)]);
    expect(host.isOpen, isTrue);
    final r = events.single as ShareLineReady;
    expect(r.mode, ShareMode.live);
    expect(r.viewers, isEmpty);
    expect(r.hostOnline, isFalse);

    // A viewer, on a device with no registration: no session is named.
    final viewer = line();
    final seen = listen(viewer);
    await until(() => seen.isNotEmpty);
    expect(relay.connections.last.texts.single, {'type': 'auth', 'token': 'token', 'share': shareId, 'role': 'viewer'});
  });

  test('what the relay says becomes events; what this version does not know is skipped', () async {
    relay.onAuth = (c, _) {
      // Before "ready" nothing counts, not even bytes.
      c.socket.add(jsonEncode({'type': 'viewer', 'lane': 9, 'uid': 'uid-early', 'on': true}));
      c.socket.add([9, 1, 2]);
      ready(c, {
        'mode': 'live',
        'viewers': [
          {'lane': 1, 'uid': 'uid-sam'},
          {'lane': 0, 'uid': 'uid-zero'},
          {'lane': 256, 'uid': 'uid-big'},
          {'lane': 2, 'uid': ''},
          {'lane': '3', 'uid': 'uid-text'},
          'nonsense',
          {'lane': 255, 'uid': 'uid-kit'},
        ],
      });
    };
    final events = listen(line(host: true));
    await until(() => events.isNotEmpty);
    final r = events.single as ShareLineReady;
    expect(r.viewers.map((v) => (v.lane, v.uid)), [(1, 'uid-sam'), (255, 'uid-kit')]);

    final c = relay.connections.single;
    c.socket.add(jsonEncode({'type': 'viewer', 'lane': 4, 'uid': 'uid-noa', 'on': true}));
    c.socket.add(jsonEncode({'type': 'viewer', 'lane': 4, 'uid': 'uid-noa', 'on': false}));
    c.socket.add(jsonEncode({'type': 'declined', 'uid': 'uid-kit'}));
    c.socket.add(jsonEncode({'type': 'renewed'}));
    c.socket.add(jsonEncode({'type': 'something-new', 'x': 1}));
    c.socket.add(jsonEncode({'type': 'viewer', 'lane': 4, 'uid': 'uid-noa'})); // no "on"
    c.socket.add(jsonEncode({'type': 'declined', 'uid': ''}));
    c.socket.add('not json');
    c.socket.add(jsonEncode([1, 2, 3]));
    c.socket.add(jsonEncode({'type': 'declined', 'uid': 'u', 'pad': 'x' * 5000}));
    c.socket.add(jsonEncode({'type': 'ready', 'mode': 'live', 'viewers': <Object>[]})); // a second "ready"
    c.socket.add(jsonEncode({'type': 'declined', 'uid': 'uid-last'}));
    await until(() => events.any((e) => e is ShareLineDeclined && e.uid == 'uid-last'));
    final rest = events.skip(1).toList();
    expect(rest.length, 4);
    expect((rest[0] as ShareLineViewer).on, isTrue);
    final gone = rest[1] as ShareLineViewer;
    expect((gone.lane, gone.uid, gone.on), (4, 'uid-noa', false));
    expect((rest[2] as ShareLineDeclined).uid, 'uid-kit');
    expect((rest[3] as ShareLineDeclined).uid, 'uid-last');
  });

  test('a viewer hears whether the host is there, and a mode it does not know is not a sign-in', () async {
    relay.onAuth = (c, _) => ready(c, {'mode': 'tmux', 'host': true});
    final events = listen(line());
    await until(() => events.isNotEmpty);
    final r = events.single as ShareLineReady;
    expect((r.mode, r.hostOnline), (ShareMode.tmux, true));
    expect(r.viewers, isEmpty);
    final c = relay.connections.single;
    c.socket.add(jsonEncode({'type': 'host', 'on': false}));
    c.socket.add(jsonEncode({'type': 'host', 'on': true}));
    c.socket.add(jsonEncode({'type': 'host'}));
    await until(() => events.length == 3);
    expect(events.skip(1).map((e) => (e as ShareLineHost).on), [false, true]);

    relay.onAuth = (c, _) => ready(c, {'mode': 'screen', 'host': true});
    final other = line();
    final none = listen(other);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(none, isEmpty);
    expect(other.isOpen, isFalse);
  });

  test('the host\'s bytes carry a lane, a viewer\'s do not', () async {
    relay.onAuth = (c, auth) => ready(c, {'mode': 'live', 'viewers': <Object>[], 'host': true});
    final host = line(host: true);
    final hostEvents = listen(host);
    final viewer = line();
    final viewerEvents = listen(viewer);
    await until(() => hostEvents.isNotEmpty && viewerEvents.isNotEmpty);
    final hostConn = relay.connections.firstWhere((c) => c.texts.first['role'] == 'host');
    final viewerConn = relay.connections.firstWhere((c) => c.texts.first['role'] == 'viewer');

    // Sending: the lane goes in front for the host, nothing for a viewer.
    host.send(Uint8List.fromList([0xaa, 0xbb]), lane: 3);
    viewer.send(Uint8List.fromList([0xcc]));
    viewer.send(Uint8List.fromList([0xdd]), lane: 9);
    await until(() => hostConn.binaries.length == 1 && viewerConn.binaries.length == 2);
    expect(hostConn.binaries.single, [3, 0xaa, 0xbb]);
    expect(viewerConn.binaries, [
      [0xcc],
      [0xdd]
    ]);

    // Receiving: the lane is taken off for the host; a viewer's are whole.
    hostConn.socket.add([7, 0x01, 0x02]);
    hostConn.socket.add([7]); // a lane and nothing: not passed on
    hostConn.socket.add(<int>[]);
    viewerConn.socket.add([0x02, 0x09]);
    viewerConn.socket.add(<int>[]);
    hostConn.socket.add([8, 0x05]);
    await until(() => hostEvents.length == 3 && viewerEvents.length == 2);
    final fromViewer = hostEvents[1] as ShareLineBytes;
    expect(fromViewer.lane, 7);
    expect(fromViewer.bytes, [0x01, 0x02]);
    final fromAnother = hostEvents[2] as ShareLineBytes;
    expect(fromAnother.lane, 8);
    expect(fromAnother.bytes, [0x05]);
    final fromHost = viewerEvents[1] as ShareLineBytes;
    expect(fromHost.lane, 0);
    expect(fromHost.bytes, [0x02, 0x09]);
  });

  test('started twice, it is one line: one sign-in, one connection', () async {
    relay.onAuth = (c, _) => ready(c, {'mode': 'live', 'host_online': false});
    final l = line();
    final events = listen(l);
    l.start();
    await until(() => events.whereType<ShareLineReady>().isNotEmpty, what: 'ready');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(tokens, hasLength(1));
    expect(relay.connections, hasLength(1));
    expect(events.whereType<ShareLineReady>(), hasLength(1));
  });

  test('nothing is sent on a line that is not open', () async {
    relay.onAuth = (_, _) {}; // never answers
    final l = line(host: true);
    listen(l);
    await until(() => relay.connections.isNotEmpty && relay.connections.single.texts.isNotEmpty);
    l.send(Uint8List.fromList([1, 2, 3]), lane: 1);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(relay.connections.single.binaries, isEmpty);
    expect(l.isOpen, isFalse);
  });

  for (final (code, why) in [
    (ShareLine.closeEnded, ShareLineEnd.ended),
    (ShareLine.closeNotFound, ShareLineEnd.notFound),
    (ShareLine.closeSignedOut, ShareLineEnd.signedOut),
    (ShareLine.closeReplaced, ShareLineEnd.replaced),
    (ShareLine.closeFull, ShareLineEnd.full),
    (ShareLine.closeBad, ShareLineEnd.refused),
  ]) {
    test('closed with $code: the line is over (${why.name}) and is not opened again', () async {
      relay.onAuth = (c, _) {
        ready(c, {'mode': 'live', 'host': true});
        c.socket.close(code, 'bye');
      };
      final l = line();
      final events = listen(l);
      await until(() => events.any((e) => e is ShareLineClosed));
      expect((events.last as ShareLineClosed).why, why);
      expect(events.whereType<ShareLineDown>(), isEmpty, reason: 'over, not dropped');
      expect(l.isOpen, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(relay.connections.length, 1);
    });
  }

  test('the same when the relay closes it before it ever said "ready"', () async {
    relay.onAuth = (c, _) => c.socket.close(ShareLine.closeNotFound, 'no such share');
    final events = listen(line());
    await until(() => events.isNotEmpty);
    expect((events.single as ShareLineClosed).why, ShareLineEnd.notFound);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(relay.connections.length, 1);
  });

  test('a refused sign-in is tried once more with a newly issued token, then given up', () async {
    relay.onAuth = (c, _) => c.socket.close(ShareLine.closeNotSignedIn, 'not signed in');
    final events = listen(line());
    await until(() => events.any((e) => e is ShareLineClosed));
    expect((events.single as ShareLineClosed).why, ShareLineEnd.refused);
    expect(relay.connections.length, 2);
    expect(relay.connections.map((c) => c.texts.single['token']), ['token', 'fresh-token']);
    expect(tokens, [(fresh: false), (fresh: true)]);
  });

  test('a refused sign-in that works with the fresh token goes on as if nothing had happened', () async {
    relay.onAuth = (c, auth) {
      if (auth['token'] == 'token') {
        c.socket.close(ShareLine.closeNotSignedIn, 'expired');
      } else {
        ready(c, {'mode': 'live', 'host': true});
      }
    };
    final l = line();
    final events = listen(l);
    await until(() => events.isNotEmpty);
    expect(events.single, isA<ShareLineReady>());
    expect(l.isOpen, isTrue);
  });

  test('a line that drops says so and opens again by itself, every time', () async {
    relay.onAuth = (c, _) => ready(c, {'mode': 'live', 'host': true});
    final l = line();
    final events = listen(l);
    await until(() => events.length == 1);
    // The connection is cut, with no word (a network that went away).
    await relay.connections.last.socket.close(WebSocketStatus.goingAway);
    await until(() => events.length == 3, what: 'down and ready again');
    expect(events[1], isA<ShareLineDown>());
    expect(events[2], isA<ShareLineReady>());
    expect(l.isOpen, isTrue);
    // Too much data, or too far behind: the same, it comes back.
    await relay.connections.last.socket.close(4413, 'behind');
    await until(() => events.length == 5);
    expect(events[3], isA<ShareLineDown>());
    expect(events[4], isA<ShareLineReady>());
    expect(relay.connections.length, 3);
    expect(tokens.every((t) => !t.fresh), isTrue, reason: 'a drop is not a refusal');
  });

  test('a relay that cannot be reached is tried again until it can', () async {
    final port = relay._server.port;
    await relay.stop();
    final l = ShareLine(
      url: Uri.parse('ws://127.0.0.1:$port/v1/share'),
      connect: (url) => WebSocket.connect(url.toString()),
      token: ({bool fresh = false}) async => 'token',
      session: () => null,
      shareId: shareId,
      host: false,
      retryDelay: (_) => const Duration(milliseconds: 5),
    );
    lines.add(l);
    final events = listen(l);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(events, isEmpty, reason: 'never open, so never "down" either');
    expect(l.isOpen, isFalse);
    // Start a fresh server for the tearDown to stop.
    relay = FakeRelay();
    await relay.start();
  });

  test('signed out: there is nothing to sign in with, and no connection is made', () async {
    tokenFor = ({bool fresh = false}) => null;
    final events = listen(line());
    await until(() => events.isNotEmpty);
    expect((events.single as ShareLineClosed).why, ShareLineEnd.signedOut);
    expect(relay.connections, isEmpty);
  });

  // Found in a review: a sign-in that could not be fetched (on a
  // phone or a Mac, Firebase's ID token throws while there is no network
  // whenever it has to be renewed) ended the line as signed out, so a share
  // that dropped with the network stopped for good, though nobody signed out.
  test('a sign-in that cannot be fetched for a moment is not a sign-out: the line opens again once it can', () async {
    relay.onAuth = (c, _) => ready(c, {'mode': 'live', 'host': true});
    var asked = 0;
    tokenFor = ({bool fresh = false}) {
      asked++;
      // Right after the drop, and once more, the network is not back yet.
      if (asked == 2 || asked == 3) throw const SocketException('network-request-failed');
      return 'token';
    };
    final l = line();
    final events = listen(l);
    await until(() => events.length == 1);
    // The connection drops (the phone went from Wi-Fi to mobile data).
    await relay.connections.last.socket.close(WebSocketStatus.goingAway);
    await until(() => events.length == 3, what: 'down and ready again');
    expect(events[1], isA<ShareLineDown>());
    expect(events[2], isA<ShareLineReady>());
    expect(events.whereType<ShareLineClosed>(), isEmpty);
    expect(asked, 4);
    expect(relay.connections, hasLength(2), reason: 'no connection is made without a sign-in');
    expect(l.isOpen, isTrue);
  });

  test('a fresh sign-in asked for after a refusal is asked for fresh again when it could not be fetched', () async {
    relay.onAuth = (c, auth) {
      if (auth['token'] == 'fresh-token') {
        ready(c, {'mode': 'live', 'host': true});
      } else {
        c.socket.close(ShareLine.closeNotSignedIn);
      }
    };
    var freshAsked = 0;
    tokenFor = ({bool fresh = false}) {
      if (fresh && ++freshAsked == 1) throw const SocketException('network-request-failed');
      return fresh ? 'fresh-token' : 'token';
    };
    final events = listen(line());
    await until(() => events.isNotEmpty);
    expect(events.single, isA<ShareLineReady>());
    expect(freshAsked, 2);
  });

  test('the sign-in is renewed in place, with a newly issued token', () async {
    relay.onAuth = (c, _) => ready(c, {'mode': 'live', 'host': true});
    final l = line(renewEvery: const Duration(milliseconds: 40));
    final events = listen(l);
    await until(() => events.isNotEmpty);
    final c = relay.connections.single;
    await until(() => c.texts.length >= 3, what: 'two renewals');
    expect(c.texts[1], {'type': 'renew', 'token': 'fresh-token'});
    expect(c.texts[2], {'type': 'renew', 'token': 'fresh-token'});
    expect(relay.connections.length, 1, reason: 'on the same connection');
    expect(l.isOpen, isTrue);
  });

  test('closing the line closes the connection for good and ends the events', () async {
    relay.onAuth = (c, _) => ready(c, {'mode': 'live', 'host': true});
    final l = line();
    final events = <ShareLineEvent>[];
    var done = false;
    l.events.listen(events.add, onDone: () => done = true);
    l.start();
    l.start(); // twice is once
    await until(() => events.isNotEmpty);
    expect(relay.connections.length, 1);
    await l.close();
    await until(() => relay.connections.single.closed && done);
    expect(l.isOpen, isFalse);
    l.send(Uint8List.fromList([1]));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(relay.connections.length, 1, reason: 'not opened again');
    expect(events.length, 1, reason: 'no "down", no "closed": this side closed it');
  });
}
