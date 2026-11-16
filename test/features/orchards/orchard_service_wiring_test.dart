import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';

/// The team service as the app builds it (3.0): a login
/// knows what the app knows of how ZestSSH Cloud stands, so that it asks
/// nothing of a service that is not answering, and asks as ever while
/// nothing is in the way or nothing is known.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a login is told whether ZestSSH Cloud is answering, as the app knows it at that moment', () async {
    FlutterSecureStorage.setMockInitialValues({});
    Object answer = 200;
    late CloudReachService reach;
    final container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(null),
      orchardsApiProvider.overrideWithValue(OrchardsApi(
        client: MockClient((_) async => http.Response('{}', 200)),
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'token',
      )),
      cloudReachProvider.overrideWith((ref) {
        reach = CloudReachService(
          check: () async {
            final a = answer;
            if (a is int) return a;
            throw a;
          },
          timer: (wait, then) => Timer(const Duration(days: 1), () {}),
        );
        ref.onDispose(reach.dispose);
        return reach;
      }),
    ]);
    addTearDown(container.dispose);
    final away = container.read(orchardServiceProvider).cloudAway!;

    expect(away(), isFalse, reason: 'nothing is known yet: the server is asked');
    await reach.checkNow();
    expect(reach.state.value.reach, CloudReach.answering);
    expect(away(), isFalse);

    answer = const SocketException('Connection refused');
    await reach.checkNow();
    expect(reach.state.value.reach, CloudReach.notResponding);
    expect(away(), isTrue, reason: 'read when a login asks, not when the service was built');

    answer = 503;
    await reach.checkNow();
    expect(reach.state.value.reach, CloudReach.fault);
    expect(away(), isTrue);

    answer = 200;
    await reach.checkNow();
    expect(away(), isFalse, reason: 'it answers again');
  });

  test('a login waits six seconds for the record, where the API itself waits half a minute', () {
    FlutterSecureStorage.setMockInitialValues({});
    final container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(null),
      orchardsApiProvider.overrideWithValue(OrchardsApi(
        client: MockClient((_) async => http.Response('{}', 200)),
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'token',
      )),
    ]);
    addTearDown(container.dispose);
    expect(container.read(orchardServiceProvider).loginRecordWait, const Duration(seconds: 6));
  });
}
