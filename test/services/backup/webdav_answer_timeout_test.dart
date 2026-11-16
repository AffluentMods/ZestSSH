import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/services/backup/webdav_destination.dart';

/// A WebDAV backup server that takes a request and never answers fails it
/// in time (found in a review): Back up now, or an automatic backup,
/// waited for good.
class _Silent extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => Completer<http.StreamedResponse>().future;
}

void main() {
  tearDown(() => webDavAnswerBase = const Duration(seconds: 30));

  test('a server that never answers fails the request in its time', () async {
    webDavAnswerBase = const Duration(milliseconds: 100);
    final d = WebDavBackupDestination(
        serverUrl: 'https://dav.example.com', username: 'demo', password: 'x', client: _Silent());
    final at = DateTime.now();
    await expectLater(d.listBackups(), throwsA(isA<TimeoutException>()));
    expect(DateTime.now().difference(at), lessThan(const Duration(seconds: 5)));
  });

  test('a large upload has time for its size', () {
    expect(webDavAnswerTimeout(null), const Duration(seconds: 30));
    expect(webDavAnswerTimeout(50 * 1024 * 1024), const Duration(seconds: 30 + 1024));
  });
}
