import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/services/sync/http_cap.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/zest_server_backend.dart';
import 'package:zestssh/services/sync_service.dart' show SyncException;

/// The small answers of a sync server are read under a cap (found in security
/// reviews). The pull
/// was. A status check, a verification, a push's acknowledgement and four
/// more were read whole before anything looked at their size, so a server
/// that is not what it should be could fill the device's memory with the
/// answer to "is there anything new".
void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'demo', version: '4.0.0', buildNumber: '1', buildSignature: '');
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => ZestServerBackend.debugHttpClient = null);

  ZestServerBackend own() => ZestServerBackend(
        baseUrl: 'https://sync.example.com/v1',
        kind: SyncBackendKind.custom,
        staticToken: 'demo-token',
        requiresEntitlement: false,
      );

  /// A server that answers a status check with [chunks] pieces of 64 KiB,
  /// and counts the pieces that were taken from it.
  (http.Client, List<int>) flooding({required int chunks, required bool saysLength}) {
    final taken = <int>[];
    final client = MockClient.streaming((request, body) async {
      Stream<List<int>> pieces() async* {
        for (var i = 0; i < chunks; i++) {
          taken.add(i);
          yield Uint8List(64 * 1024);
        }
      }

      return http.StreamedResponse(pieces(), 200, contentLength: saysLength ? chunks * 64 * 1024 : null);
    });
    return (client, taken);
  }

  test('a status answer of 8 MB that says its length is refused before a byte of it is read', () async {
    final (client, taken) = flooding(chunks: 128, saysLength: true);
    ZestServerBackend.debugHttpClient = client;
    await expectLater(own().getStatus(), throwsA(isA<SyncException>()));
    expect(taken, isEmpty);
  });

  test('one that says no length is cut off once it is over the cap, and the rest is not taken', () async {
    final (client, taken) = flooding(chunks: 128, saysLength: false);
    ZestServerBackend.debugHttpClient = client;
    await expectLater(own().getStatus(), throwsA(isA<SyncException>()));
    expect(taken.length, lessThan(24), reason: 'a little over 1 MiB, not all 8 MB');
  });

  test('an answer of the usual size is read as before', () async {
    ZestServerBackend.debugHttpClient = MockClient((request) async => http.Response(
          jsonEncode({'has_data': true, 'version': 7, 'blob_size': 1234}),
          200,
          headers: {'content-type': 'application/json'},
        ));
    final status = await own().getStatus();
    expect(status.hasData, isTrue);
    expect(status.version, 7);
  });

  test('the capped client by itself: under the cap the body is whole, and closing it leaves the lent client open',
      () async {
    var closed = false;
    final inner = _Closes(MockClient((request) async => http.Response('x' * 1000, 200)), () => closed = true);
    final capped = CappedClient(inner, 1000);
    expect((await capped.get(Uri.parse('https://sync.example.com/x'))).body, hasLength(1000));
    await expectLater(CappedClient(inner, 999).get(Uri.parse('https://sync.example.com/x')),
        throwsA(isA<SyncException>()));
    capped.close();
    expect(closed, isFalse);
  });
}

class _Closes extends http.BaseClient {
  _Closes(this._inner, this._onClose);

  final http.Client _inner;
  final void Function() _onClose;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request);

  @override
  void close() => _onClose();
}
