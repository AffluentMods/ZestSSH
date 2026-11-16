import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/profiles/locked_copies.dart';

/// A call made with another account's sign-in than the one on screen sends
/// no registration of this device: it names a session of the account on
/// screen, and ZestSSH Cloud refused the call as one from a device signed out
/// (found in a security review).
void main() {
  late List<http.Request> seen;
  http.Client answering(String body) => MockClient((request) async {
        seen.add(request);
        return http.Response(body, 200);
      });

  setUp(() {
    seen = [];
    DeviceSessionHeader.current = 'token-of-the-one-on-screen';
  });
  tearDown(() => DeviceSessionHeader.current = null);

  test("deleting a locked copy as another account sends no registration of this device's", () async {
    final api = LockedCopiesApi(client: answering('{"deleted":true}'), baseUrl: 'https://api.test/v1');
    expect(await api.delete(bearer: 'bearer-of-alex', id: 'c-1', onScreen: false), isTrue);
    expect(await api.delete(bearer: 'bearer-on-screen', id: 'c-2'), isTrue);
    expect(seen[0].headers['Authorization'], 'Bearer bearer-of-alex');
    expect(seen[0].headers.containsKey(DeviceSessionHeader.name), isFalse);
    expect(seen[0].headers[DeviceSessionHeader.knowsName], DeviceSessionHeader.knows);
    expect(seen[1].headers[DeviceSessionHeader.name], 'token-of-the-one-on-screen');
  });

  test("ending another account's session sends no registration of this device's", () async {
    final api = DeviceSessionsApi(
        client: answering('{"id":"s-1"}'), baseUrl: 'https://api.test/v1', bearer: () async => 'bearer-of-alex', onScreen: false);
    await api.endOwnSession();
    expect(seen, hasLength(2));
    for (final r in seen) {
      expect(r.headers.containsKey(DeviceSessionHeader.name), isFalse, reason: r.url.path);
    }
  });
}
