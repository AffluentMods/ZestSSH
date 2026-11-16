import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/services/cloud/cloud_status_config.dart';
import 'package:zestssh/services/pinned_http_client.dart';

/// How the app's own parts are tied to its knowledge of ZestSSH Cloud (3.0):
/// the client every request to the service goes through
/// tells how each went, and the question "how are you" asks nothing about
/// anyone.
/// A client that says whether it was closed.
class _Closing extends http.BaseClient {
  _Closing(this._inner);

  final http.Client _inner;
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request);

  @override
  void close() => closed = true;
}

void main() {
  // Under the test binding every request is answered 400 without leaving
  // the machine: an answer, which is all these need.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(PinnedHttpClient.reset);
  tearDown(() {
    PinnedHttpClient.onExchange = null;
    PinnedHttpClient.reset();
  });

  group('the client every request to the service goes through', () {
    test('tells whoever listens how a request to the service went', () async {
      final heard = <(int?, Object?)>[];
      PinnedHttpClient.onExchange = (status, error) => heard.add((status, error));
      final response = await PinnedHttpClient.client.get(Uri.parse('$kCloudApiBase/orchards'));
      expect(response.statusCode, 400);
      expect(heard, [(400, null)]);
    });

    test('says nothing of the health check, nor of a request to anything else', () async {
      final heard = <(int?, Object?)>[];
      PinnedHttpClient.onExchange = (status, error) => heard.add((status, error));
      await PinnedHttpClient.client.get(Uri.parse('$kCloudApiBase/health'));
      await PinnedHttpClient.client.get(Uri.parse('https://zestssh.com/app/latest.json'));
      await PinnedHttpClient.client.get(Uri.parse('https://sync.northwind.example/v1/sync/status'));
      expect(heard, isEmpty);
    });

    test('is none the worse while nobody listens, and hears whoever starts listening later', () async {
      expect((await PinnedHttpClient.client.get(Uri.parse('$kCloudApiBase/orchards'))).statusCode, 400);
      final heard = <int?>[];
      PinnedHttpClient.onExchange = (status, _) => heard.add(status);
      await PinnedHttpClient.client.get(Uri.parse('$kCloudApiBase/orchards'));
      expect(heard, [400]);
    });

    test('the address of the service is the one a build names, and the default is ZestSSH Cloud', () {
      expect(kCloudApiBase, 'https://api.zestssh.com/v1');
    });
  });

  group('asking the service how it is', () {
    test('asks its health check, with nothing about anyone, and gives back the status', () async {
      late http.Request asked;
      final status = await cloudHealthStatus(
        client: MockClient((request) async {
          asked = request;
          return http.Response('{"status":"ok","service":"zestssh-api"}', 200);
        }),
      );
      expect(status, 200);
      expect(asked.method, 'GET');
      expect(asked.url.toString(), '$kCloudApiBase/health');
      expect(asked.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')),
          reason: 'no sign-in goes with it');
      expect(asked.headers.keys.map((k) => k.toLowerCase()), isNot(contains('cookie')));
      expect(asked.body, isEmpty);
    });

    test('a fault is its status, and no answer is thrown as it is', () async {
      expect(await cloudHealthStatus(client: MockClient((_) async => http.Response('degraded', 503))), 503);
      await expectLater(
        cloudHealthStatus(client: MockClient((_) async => throw http.ClientException('Connection refused'))),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('through the app\'s own client it is an answer like any other, and is told to nobody', () async {
      final heard = <int?>[];
      PinnedHttpClient.onExchange = (status, _) => heard.add(status);
      expect(await cloudHealthStatus(), 400);
      expect(heard, isEmpty);
    });

    test('it does not wait for ever', () {
      expect(kCloudHealthTimeout, lessThanOrEqualTo(const Duration(seconds: 10)));
      expect(kCloudHealthTimeout, greaterThanOrEqualTo(const Duration(seconds: 3)));
    });
  });

  // The status service, which the app asks when ZestSSH Cloud gave no answer
  // (3.0). It is a service of its own (infra/status_worker),
  // and a build knows it by an address and two public keys.
  group('the status service', () {
    final vectors =
        jsonDecode(File('infra/status_worker/test/vectors.json').readAsStringSync()) as Map<String, dynamic>;
    final testKey = vectors['publicKey'] as String;
    final down = (vectors['statements'] as List)[0]['signed'] as Map<String, dynamic>;
    final downAt = down['at'] as int;
    const address = 'https://status.zestssh.com/v1/now';

    test('a build is set up for it by an address and public keys: both, or it is not asked at all', () {
      final set = cloudStatusConfigOf(url: ' $address ', service: 'api.zestssh.com', keys: {'k1': testKey, 'k2': ' $testKey\n'});
      expect(set.isSet, isTrue);
      expect(set.url, address);
      expect(set.service, 'api.zestssh.com');
      expect(set.keys.keys, ['k1', 'k2']);
      expect(set.keys.values.map((k) => k.length), [32, 32]);
      expect(set.keys['k1'], base64Decode(testKey));

      expect(cloudStatusConfigOf(url: '', service: 'api.zestssh.com', keys: {'k1': testKey}).isSet, isFalse);
      expect(cloudStatusConfigOf(url: address, service: 'api.zestssh.com', keys: const {}).isSet, isFalse);
      expect(cloudStatusConfigOf(url: address, service: '', keys: {'k1': testKey}).isSet, isFalse);
    });

    test('a key that is not 32 bytes in base64 is no key', () {
      final config = cloudStatusConfigOf(url: address, service: 'api.zestssh.com', keys: {
        'k1': 'not base64 !!',
        'k2': base64Encode(List<int>.filled(31, 7)),
        'k3': base64Encode(List<int>.filled(33, 7)),
        'k4': '',
        'k5': testKey,
      });
      expect(config.keys.keys, ['k5']);
      expect(cloudStatusConfigOf(url: address, service: 'api.zestssh.com', keys: const {'k1': 'AAAA'}).isSet, isFalse,
          reason: 'with no key left, nothing is asked');
    });

    test('what this build ships with holds together: no address and no keys, or an address and keys that are keys', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final config = container.read(cloudStatusConfigProvider);
      expect(config.service, 'api.zestssh.com', reason: 'statements about the very host this build talks to');
      expect(kCloudStatusUrl.isEmpty, kCloudStatusKeys.isEmpty, reason: 'half set up is not set up');
      if (kCloudStatusUrl.isEmpty) {
        expect(config.isSet, isFalse);
        expect(container.read(cloudStatusAskerProvider), isNull, reason: 'nothing is asked until the service is put up');
      } else {
        final url = Uri.parse(kCloudStatusUrl);
        expect(url.scheme, 'https');
        expect(url.path, '/v1/now');
        expect(config.keys.length, kCloudStatusKeys.length, reason: 'every key it names can be read');
        expect(config.keys.length, greaterThanOrEqualTo(2), reason: 'the one in use, and the spare');
        expect(container.read(cloudStatusAskerProvider), isNotNull);
      }
    });

    test('asking it sends nothing about anyone, and believes a statement that checks out', () async {
      final config = cloudStatusConfigOf(url: address, service: 'api.zestssh.com', keys: {'k1': testKey});
      late http.Request asked;
      final said = await cloudStatusNow(
        config,
        client: MockClient((request) async {
          asked = request;
          return http.Response(jsonEncode(down), 200);
        }),
        nowSeconds: () => downAt + 30,
      );
      expect(said!.down, isTrue);
      expect(said.since, down['since']);
      expect(asked.url.toString(), address);
      expect(asked.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
      // And by the device's own clock where none is given: a statement of
      // long ago is not believed.
      expect(await cloudStatusNow(config, client: MockClient((_) async => http.Response(jsonEncode(down), 200))), isNull);
    });

    test('with no clock given it is the device\'s own: a statement of this moment is believed', () async {
      // Signed here with the key of the vectors (its seed is the bytes 1 to
      // 32), for now.
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final pair = await Ed25519().newKeyPairFromSeed(List<int>.generate(32, (i) => i + 1));
      final text = CloudStatement.canonical(
          service: 'api.zestssh.com', down: true, at: now, until: now + 900, since: now - 120, keyId: 'k1');
      final signature = await Ed25519().sign(utf8.encode(text), keyPair: pair);
      final body = jsonEncode({
        'v': 1,
        'service': 'api.zestssh.com',
        'state': 'down',
        'at': now,
        'until': now + 900,
        'since': now - 120,
        'key': 'k1',
        'sig': base64Encode(signature.bytes),
      });
      final config = cloudStatusConfigOf(url: address, service: 'api.zestssh.com', keys: {'k1': testKey});
      final said = await cloudStatusNow(config, client: MockClient((_) async => http.Response(body, 200)));
      expect(said, isNotNull);
      expect(said!.since, now - 120);
    });

    test('a connection it is given is the caller\'s, and is left open', () async {
      final config = cloudStatusConfigOf(url: address, service: 'api.zestssh.com', keys: {'k1': testKey});
      final client = _Closing(MockClient((_) async => http.Response(jsonEncode(down), 200)));
      await cloudStatusNow(config, client: client, nowSeconds: () => downAt + 30);
      expect(client.closed, isFalse);
    });

    test('a build that is set up asks over a connection of its own, and takes no answer for none', () async {
      final container = ProviderContainer(overrides: [
        cloudStatusConfigProvider.overrideWithValue(
            cloudStatusConfigOf(url: address, service: 'api.zestssh.com', keys: {'k1': testKey})),
      ]);
      addTearDown(container.dispose);
      final ask = container.read(cloudStatusAskerProvider);
      expect(ask, isNotNull);
      // (Under the test binding a request is answered 400 without leaving the
      // machine: no statement.)
      final heard = <int?>[];
      PinnedHttpClient.onExchange = (status, _) => heard.add(status);
      expect(await ask!(), isNull);
      expect(heard, isEmpty, reason: 'it is not one of the exchanges with ZestSSH Cloud the app keeps count of');
    });

    test('the app\'s own knowledge of the service asks it when the service gave no answer', () async {
      var asked = 0;
      final proof = CloudStatement(down: true, at: downAt, until: downAt + 900, since: downAt - 3600, keyId: 'k1');
      final container = ProviderContainer(overrides: [
        cloudHealthCheckProvider.overrideWithValue(() async => throw const SocketException('Connection refused')),
        cloudStatusAskerProvider.overrideWithValue(() async {
          asked++;
          return proof;
        }),
      ]);
      addTearDown(container.dispose);
      final reach = container.read(cloudReachProvider);
      final state = await reach.checkNow();
      expect(asked, 1);
      expect(state.reach, CloudReach.down);
      expect(state.outageSince, DateTime.fromMillisecondsSinceEpoch((downAt - 3600) * 1000, isUtc: true));
    });

    test('and with none set up, it says what one device can know', () async {
      final container = ProviderContainer(overrides: [
        cloudHealthCheckProvider.overrideWithValue(() async => throw const SocketException('Connection refused')),
        cloudStatusAskerProvider.overrideWithValue(null),
      ]);
      addTearDown(container.dispose);
      expect((await container.read(cloudReachProvider).checkNow()).reach, CloudReach.notResponding);
    });
  });

  // Signed out, nothing on the device uses ZestSSH Cloud: it is not said to
  // be down to someone who does not use it, and it is not asked how it is.
  group('the account', () {
    const dana = UserProfile(uid: 'uid-dana', email: 'dana@example.com');

    (ProviderContainer, CloudReachService) appWith(UserProfile? account) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(desktopSessionProvider.notifier).state = account;
      final reach = container.read(cloudReachProvider);
      // In the way without anything having to be asked: it answered, and
      // then the device lost its network.
      reach
        ..heard(200)
        ..networkChanged(up: false);
      expect(reach.state.value.reach, CloudReach.deviceOffline);
      return (container, reach);
    }

    test('signing out forgets what was known of the service: nothing is said, nothing is asked', () async {
      final (container, reach) = appWith(dana);
      container.read(desktopSessionProvider.notifier).state = null;
      await container.pump();
      expect(reach.state.value, const CloudReachState.unknown());
      expect(reach.state.value.inTheWay, isFalse);
      // And what the device's network does next says nothing either.
      reach.networkChanged(up: true);
      reach.networkChanged(up: false);
      expect(reach.state.value.reach, CloudReach.unknown);
    });

    test('signing in forgets nothing, and neither does the same account read afresh or another one', () async {
      final (container, reach) = appWith(null);
      container.read(desktopSessionProvider.notifier).state = dana;
      await container.pump();
      expect(reach.state.value.reach, CloudReach.deviceOffline, reason: 'signing in');
      container.read(desktopSessionProvider.notifier).state =
          const UserProfile(uid: 'uid-dana', email: 'dana@example.com', displayName: 'Dana');
      await container.pump();
      expect(reach.state.value.reach, CloudReach.deviceOffline, reason: 'the same account, read afresh');
      container.read(desktopSessionProvider.notifier).state = const UserProfile(uid: 'uid-lee', email: 'lee@example.com');
      await container.pump();
      expect(reach.state.value.reach, CloudReach.deviceOffline, reason: 'another account');
    });
  });
}
