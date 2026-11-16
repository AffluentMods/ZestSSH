// FtpsClient over a fake native layer: the certificate rule, errors, listings and transfers,
// without a server. The Rust side has its own tests (cargo test), and the app has an integration
// test against a real server (test/native/ftps_integration_test.dart).
import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_native/ftps.dart';

/// Answers each request with what [answers] gives for its op, and keeps every request.
class FakeNative implements FtpsNative {
  FakeNative(this.answers);

  final Map<String, Object?> Function(Map<String, Object?> request) answers;
  final requests = <Map<String, Object?>>[];
  final cancelled = <int>[];
  final closed = <int>[];
  int moved = 0;
  var _next = 1;

  /// Holds the transfer ops until completed, so a test can look at them while they run.
  Completer<void>? hold;

  @override
  int open() => _next++;

  @override
  Future<Map<String, Object?>> call(int handle, Map<String, Object?> request) async {
    requests.add(request);
    if (hold != null && (request['op'] == 'get' || request['op'] == 'put')) await hold!.future;
    return answers(request);
  }

  @override
  void cancel(int handle) => cancelled.add(handle);

  @override
  int progress(int handle) => moved;

  @override
  Future<void> close(int handle) async => closed.add(handle);
}

const shaA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const shaB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Map<String, Object?> cert(String sha, {bool byAuthority = false}) => {
  'sha256': sha,
  'byAuthority': byAuthority,
  'der': '3082',
};

Map<String, Object?> connected(String sha, {bool byAuthority = false}) => {
  'ok': {
    'certificate': cert(sha, byAuthority: byAuthority),
    'home': '/home/demo',
    'welcome': '220 hi',
    'features': {'mlst': true, 'hash': false},
  },
};

Map<String, Object?> refused(String sha) => {
  'error': {'kind': 'certificate', 'message': 'not trusted', 'certificate': cert(sha)},
};

class FakeTrust implements FtpsTrust {
  FakeTrust({this.pinned, this.answer = true});

  String? pinned;
  bool answer;
  final asked = <(String, String?)>[];
  final remembered = <String>[];

  @override
  Future<String?> pinnedFor(String host, int port) async => pinned;

  @override
  Future<bool> ask(FtpsCertificate presented, {required String host, required int port, String? previous}) async {
    asked.add((presented.sha256, previous));
    return answer;
  }

  @override
  Future<void> remember(String host, int port, FtpsCertificate cert) async {
    remembered.add(cert.sha256);
    pinned = cert.sha256;
  }
}

const options = FtpsConnectOptions(host: 'files.example.test', port: 21, username: 'demo', password: 'pw');

void main() {
  group('certificates', () {
    test('a first certificate is asked about, kept on a yes, and the connection made with it alone', () async {
      final native = FakeNative((r) => r['pinned'] == shaA ? connected(shaA) : refused(shaA));
      final trust = FakeTrust();
      final client = await FtpsClient.connectTrusting(options, trust, native: native);
      expect(client.certificate.sha256, shaA);
      expect(trust.asked, [(shaA, null)]);
      expect(trust.remembered, [shaA]);
      // The second try trusts that certificate and no authority's.
      expect(native.requests.last['pinned'], shaA);
      expect(native.requests.last['allowAuthority'], false);
      // The first failed try's handle was closed.
      expect(native.closed, [1]);
    });

    test('a no stops the connection and keeps nothing', () async {
      final native = FakeNative((r) => refused(shaA));
      final trust = FakeTrust(answer: false);
      await expectLater(
        FtpsClient.connectTrusting(options, trust, native: native),
        throwsA(isA<FtpsException>().having((e) => e.kind, 'kind', FtpsErrorKind.certificate)),
      );
      expect(trust.remembered, isEmpty);
      expect(native.requests, hasLength(1));
    });

    test('the certificate accepted before connects without a question', () async {
      final native = FakeNative((r) => r['pinned'] == shaA ? connected(shaA) : refused(shaA));
      final trust = FakeTrust(pinned: shaA);
      await FtpsClient.connectTrusting(options, trust, native: native);
      expect(trust.asked, isEmpty);
      expect(trust.remembered, isEmpty);
    });

    test('a changed certificate is asked about with the one before', () async {
      final native = FakeNative((r) => r['pinned'] == shaB ? connected(shaB) : refused(shaB));
      final trust = FakeTrust(pinned: shaA);
      await FtpsClient.connectTrusting(options, trust, native: native);
      expect(trust.asked, [(shaB, shaA)]);
      expect(trust.remembered, [shaB]);
    });

    test('an authority-signed certificate is kept without a question, so a later one without is a change', () async {
      final native = FakeNative((r) => connected(shaA, byAuthority: true));
      final trust = FakeTrust();
      await FtpsClient.connectTrusting(options, trust, native: native);
      expect(trust.asked, isEmpty);
      expect(trust.remembered, [shaA]);
      expect(trust.pinned, shaA);
    });

    test('the fingerprint reads as server tools print it', () {
      final c = FtpsCertificate(sha256: 'ab01', byAuthority: false, der: Uint8List(0));
      expect(c.fingerprint, 'AB:01');
    });
  });

  test('a server without TLS fails as such, and its handle is closed', () async {
    final native = FakeNative(
      (r) => {
        'error': {'kind': 'no-tls', 'message': 'AUTH not implemented', 'code': 502},
      },
    );
    await expectLater(
      FtpsClient.connect(options, native: native),
      throwsA(isA<FtpsException>().having((e) => e.kind, 'kind', FtpsErrorKind.noTls).having((e) => e.code, 'code', 502)),
    );
    expect(native.closed, [1]);
  });

  test('a listing, a missing entry and a 550', () async {
    final native = FakeNative((r) {
      switch (r['op']) {
        case 'connect':
          return connected(shaA, byAuthority: true);
        case 'list':
          return {
            'ok': [
              {'name': 'notes.txt', 'dir': false, 'link': false, 'size': 5, 'mtime': 0, 'mode': 420, 'target': null},
              {'name': 'logs', 'dir': true, 'link': false, 'size': 0, 'mtime': null, 'mode': null, 'target': null},
            ],
          };
        case 'stat':
          return {'ok': null};
        default:
          return {
            'error': {'kind': 'reply', 'message': 'No such file', 'code': 550},
          };
      }
    });
    final client = await FtpsClient.connect(options, native: native);
    expect(client.home, '/home/demo');
    expect(client.features.mlst, isTrue);
    final entries = await client.list('/home/demo');
    expect(entries.map((e) => e.name), ['notes.txt', 'logs']);
    expect(entries.first.mode, 0x1a4);
    expect(entries.first.modified, DateTime.utc(1970));
    expect(entries.last.isDirectory, isTrue);
    expect(await client.stat('/nothing'), isNull);
    await expectLater(client.delete('/nothing'), throwsA(isA<FtpsException>().having((e) => e.notThere, 'notThere', isTrue)));
  });

  test('calls on one connection run one after another', () async {
    final order = <String>[];
    final native = FakeNative((r) {
      order.add(r['op'] as String);
      return r['op'] == 'connect' ? connected(shaA, byAuthority: true) : {'ok': null};
    });
    final client = await FtpsClient.connect(options, native: native);
    await Future.wait([client.mkdir('/a'), client.rename('/a', '/b'), client.rmdir('/b')]);
    expect(order, ['connect', 'mkdir', 'rename', 'rmdir']);
  });

  test('a transfer reports progress from its offset, and a cancel reaches the native call', () async {
    final native = FakeNative(
      (r) => r['op'] == 'connect'
          ? connected(shaA, byAuthority: true)
          : {
              'ok': {'bytes': 300},
            },
    )..hold = Completer<void>();
    final client = await FtpsClient.connect(options, native: native);
    final seen = <int>[];
    final cancel = Completer<void>();
    final done = client.download('/big.iso', '/tmp/big.iso.zestpart', offset: 100, onProgress: seen.add, whenCancelled: cancel.future);
    native.moved = 50;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(seen, contains(150));
    cancel.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(native.cancelled, isNotEmpty);
    native.hold!.complete();
    expect(await done, 300);
    expect(seen.last, 400);
    expect(native.requests.last['offset'], 100);
  });

  test('a transfer cancelled before it starts never starts', () async {
    final native = FakeNative((r) => r['op'] == 'connect' ? connected(shaA, byAuthority: true) : {'ok': null})
      ..hold = Completer<void>();
    final client = await FtpsClient.connect(options, native: native);
    final first = client.upload('/tmp/a', '/a');
    final cancel = Completer<void>()..complete();
    final second = client.upload('/tmp/b', '/b', whenCancelled: cancel.future);
    await Future<void>.delayed(Duration.zero);
    native.hold!.complete();
    await first;
    await expectLater(second, throwsA(isA<FtpsException>().having((e) => e.kind, 'kind', FtpsErrorKind.cancelled)));
    expect(native.requests.where((r) => r['op'] == 'put'), hasLength(1));
  });

  test('close ends the handle once, and later calls fail as closed', () async {
    final native = FakeNative((r) => connected(shaA, byAuthority: true));
    final client = await FtpsClient.connect(options, native: native);
    await client.close();
    await client.close();
    expect(native.closed, [1]);
    await expectLater(client.pwd(), throwsA(isA<FtpsException>().having((e) => e.kind, 'kind', FtpsErrorKind.closed)));
  });

  test('the Rust library answers a call on a handle that is not connected', () async {
    const native = RustFtpsNative();
    final h = native.open();
    final answer = await native.call(h, {'op': 'pwd'});
    await native.close(h);
    expect((answer['error'] as Map)['kind'], 'closed');
  });
}
