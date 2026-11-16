import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';

/// What the ZestSSH status service says is believed only when it is signed
/// by a key this app knows, is about this app's service, and holds now
/// (3.0). The service is a Cloudflare Worker
/// (infra/status_worker); its tests and these read the same file of signed
/// statements, which is what keeps the two sides agreeing on the bytes.
void main() {
  // (Signatures are the real thing under test: test/flutter_test_config.dart
  // stands in for key derivation only.)
  const service = 'api.zestssh.com';
  final vectors = jsonDecode(File('infra/status_worker/test/vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final publicKey = base64Decode(vectors['publicKey'] as String);
  final keys = {'k1': publicKey};
  final statements = (vectors['statements'] as List).cast<Map<String, dynamic>>();
  // Down for six hours when it was asked; up; and found down that moment.
  final down = statements[0]['signed'] as Map<String, dynamic>;
  final up = statements[1]['signed'] as Map<String, dynamic>;
  final justDown = statements[2]['signed'] as Map<String, dynamic>;
  final downAt = down['at'] as int;
  final downSince = down['since'] as int;

  // The key of the vectors: its seed is the bytes 1 to 32, so that a test
  // can sign statements of its own with it.
  final seed = List<int>.generate(32, (i) => i + 1);

  Future<String> signedBy(
    List<int> withSeed, {
    String about = service,
    bool isDown = true,
    required int at,
    required int until,
    int? since,
    String keyId = 'k1',
    Map<String, Object?> also = const {},
  }) async {
    final from = since ?? (isDown ? at : 0);
    final pair = await Ed25519().newKeyPairFromSeed(withSeed);
    final text =
        CloudStatement.canonical(service: about, down: isDown, at: at, until: until, since: from, keyId: keyId);
    final signature = await Ed25519().sign(utf8.encode(text), keyPair: pair);
    return jsonEncode({
      'v': 1,
      'service': about,
      'state': isDown ? 'down' : 'up',
      'at': at,
      'until': until,
      'since': from,
      'key': keyId,
      'sig': base64Encode(signature.bytes),
      ...also,
    });
  }

  Future<CloudStatement?> read(Object? statement, {int? now, Map<String, List<int>>? withKeys, String about = service}) =>
      CloudStatement.read(statement is String ? statement : jsonEncode(statement),
          service: about, keys: withKeys ?? keys, nowSeconds: now ?? downAt + 60);

  group('the statements the Worker signs', () {
    test('are believed, and say what the Worker said', () async {
      final said = await read(down);
      expect(said, isNotNull);
      expect(said!.down, isTrue);
      expect(said.at, down['at']);
      expect(said.until, down['until']);
      expect(said.since, downSince);
      expect(said.at - said.since, 6 * 3600, reason: 'down for six hours when it was asked');
      expect(said.keyId, 'k1');

      final other = await read(up, now: (up['at'] as int) + 60);
      expect(other!.down, isFalse);
      expect(other.since, 0, reason: 'up has no since');

      final fresh = await read(justDown);
      expect(fresh!.down, isTrue);
      expect(fresh.since, fresh.at, reason: 'found down that moment');
    });

    test('are signed over the very bytes this side makes of them', () async {
      expect(statements, hasLength(3));
      for (final vector in statements) {
        final signed = vector['signed'] as Map<String, dynamic>;
        expect(
          CloudStatement.canonical(
            service: signed['service'] as String,
            down: signed['state'] == 'down',
            at: signed['at'] as int,
            until: signed['until'] as int,
            since: signed['since'] as int,
            keyId: signed['key'] as String,
          ),
          vector['canonical'],
        );
      }
      expect(CloudStatement.domain, vectors['domain']);
    });

    test('and what this side signs with the same key is what the Worker signed, byte for byte', () async {
      final mine = jsonDecode(await signedBy(seed, at: downAt, until: down['until'] as int, since: downSince))
          as Map<String, dynamic>;
      expect(mine['sig'], down['sig']);
      final pair = await Ed25519().newKeyPairFromSeed(seed);
      expect((await pair.extractPublicKey()).bytes, publicKey);
    });
  });

  group('a statement is not believed', () {
    test('when anything in it was changed after it was signed', () async {
      for (final changed in <Map<String, dynamic>>[
        {...down, 'state': 'up', 'since': 0},
        {...down, 'at': downAt + 1},
        {...down, 'until': (down['until'] as int) + 600},
        {...down, 'since': downSince - 7 * 86400},
        {...down, 'since': downSince + 1},
        {...down, 'since': downAt},
        {...down, 'key': 'k2'},
      ]) {
        expect(await read(changed, withKeys: {'k1': publicKey, 'k2': publicKey}), isNull, reason: '$changed');
      }
    });

    test('when it is signed by a key the app does not know, or names one it does not know', () async {
      final stranger = List<int>.generate(32, (i) => 200 - i);
      final at = downAt, until = downAt + 900;
      expect(await read(await signedBy(stranger, at: at, until: until)), isNull, reason: 'another key under a known name');
      expect(await read(await signedBy(seed, at: at, until: until, keyId: 'k9')), isNull, reason: 'a name the app has no key for');
      expect(await read(await signedBy(seed, at: at, until: until), withKeys: const {}), isNull, reason: 'an app with no keys believes nothing');
      expect(await read(await signedBy(seed, at: at, until: until), withKeys: {'k1': publicKey.sublist(0, 31)}), isNull);
      expect(await read(await signedBy(seed, at: at, until: until)), isNotNull, reason: 'the same statement under the right key');
    });

    test('when it is about another service', () async {
      final theirs = await signedBy(seed, about: 'api.example.com', at: downAt, until: downAt + 900);
      expect(await read(theirs), isNull);
      expect(await read(theirs, about: 'api.example.com'), isNotNull, reason: 'the statement itself is sound');
    });

    test('when its time is not now: over, or yet to come, by more than the clocks may differ', () async {
      final until = down['until'] as int;
      final slack = CloudStatement.clockSlack.inSeconds;
      expect(await read(down, now: until + slack), isNotNull, reason: 'the last moment it holds');
      expect(await read(down, now: until + slack + 1), isNull, reason: 'an old "down" shown again');
      expect(await read(down, now: downAt - slack), isNotNull);
      expect(await read(down, now: downAt - slack - 1), isNull, reason: 'a statement from the future');
      expect(await read(down, now: downAt + 86400), isNull, reason: 'yesterday\'s outage');
    });

    test('when it asks to be believed for longer than an hour, whoever signed it', () async {
      final hour = CloudStatement.maxHolds.inSeconds;
      expect(await read(await signedBy(seed, at: downAt, until: downAt + hour)), isNotNull);
      expect(await read(await signedBy(seed, at: downAt, until: downAt + hour + 1)), isNull,
          reason: 'a key that got out must not be able to say "down for a year"');
    });

    test('when it says neither up nor down, though what is signed under it says one of them', () async {
      final signedUp =
          jsonDecode(await signedBy(seed, isDown: false, at: downAt, until: downAt + 900)) as Map<String, dynamic>;
      expect(await read(signedUp), isNotNull);
      expect(await read({...signedUp, 'state': 'degraded'}), isNull);
      expect(await read({...signedUp, 'state': 'UP'}), isNull);
      expect(await read({...signedUp, 'state': null}), isNull);
    });

    test('when it holds for no time at all, or is of no time', () async {
      expect(await read(await signedBy(seed, at: downAt, until: downAt)), isNull, reason: 'over the moment it was made');
      expect(await read(await signedBy(seed, isDown: false, at: 0, until: 900), now: 60), isNull, reason: 'of no time');
      expect(await read(await signedBy(seed, isDown: false, at: 1, until: 900), now: 60), isNotNull);
    });

    test('when what it says of since when cannot be: signed or not', () async {
      final until = downAt + 900;
      // Signed by the right key, every one of them: it is the rule that says no.
      expect(await read(await signedBy(seed, at: downAt, until: until, since: downAt + 1)), isNull,
          reason: 'down since a time after its own');
      expect(await read(await signedBy(seed, at: downAt, until: until, since: 0)), isNull, reason: 'down since never');
      expect(await read(await signedBy(seed, at: downAt, until: until, since: -5)), isNull);
      expect(await read(await signedBy(seed, isDown: false, at: downAt, until: until, since: downAt - 60)), isNull,
          reason: 'up, and down since');
      // And what can be.
      expect((await read(await signedBy(seed, at: downAt, until: until, since: downAt)))!.since, downAt);
      expect((await read(await signedBy(seed, at: downAt, until: until, since: 1)))!.since, 1,
          reason: 'how far back counts is for whoever uses it to limit');
      expect((await read(await signedBy(seed, isDown: false, at: downAt, until: until)))!.since, 0);
    });

    test('when it is not a statement at all', () async {
      for (final body in <String>[
        '',
        'down',
        '<html>Sign in to this network</html>',
        '[]',
        '"down"',
        '{}',
        jsonEncode({...down, 'v': 2}),
        jsonEncode({...down, 'state': 'degraded'}),
        jsonEncode({...down, 'at': '${down['at']}'}),
        jsonEncode({...down, 'at': downAt + 0.5}),
        jsonEncode({...down, 'until': down['at']}),
        jsonEncode({...down, 'since': '$downSince'}),
        jsonEncode({...down, 'since': downSince + 0.5}),
        jsonEncode({...down, 'key': 'K1'}),
        jsonEncode({...down, 'sig': 'not base64 !!'}),
        jsonEncode({...down, 'sig': base64Encode(List<int>.filled(63, 1))}),
        jsonEncode({...down}..remove('sig')),
        jsonEncode({...down}..remove('service')),
        jsonEncode({...down}..remove('since')),
      ]) {
        expect(await read(body), isNull, reason: body);
      }
    });

    test('when it is longer than a statement ever is', () async {
      final padded = await signedBy(seed, at: downAt, until: downAt + 900, also: {'note': 'x' * CloudStatement.maxLength});
      expect(await read(padded), isNull, reason: 'what a network puts in its place is not read through');
      expect(jsonEncode(down).length, lessThan(CloudStatement.maxLength ~/ 4), reason: 'a statement is nowhere near it');
    });

    test('more than a statement holds is passed over, as long as what is signed checks out', () async {
      final extra = await signedBy(seed, at: downAt, until: downAt + 900, also: {'note': 'maintenance'});
      expect(await read(extra), isNotNull, reason: 'a later Worker may say more; what is signed is what counts');
    });
  });

  group('asking the service', () {
    final config = CloudStatusConfig(url: 'https://status.zestssh.com/v1/now', service: service, keys: keys);

    test('asks its one question, with nothing about anyone, and believes a statement that checks out', () async {
      late http.Request asked;
      final said = await askCloudStatus(
        config,
        client: MockClient((request) async {
          asked = request;
          return http.Response(jsonEncode(down), 200);
        }),
        nowSeconds: () => downAt + 30,
      );
      expect(said!.down, isTrue);
      expect(said.since, downSince);
      expect(asked.method, 'GET');
      expect(asked.url.toString(), 'https://status.zestssh.com/v1/now');
      final sent = asked.headers.keys.map((k) => k.toLowerCase());
      expect(sent, isNot(contains('authorization')));
      expect(sent, isNot(contains('cookie')));
      expect(asked.body, isEmpty);
    });

    test('everything else is no statement: not set up, a fault, no answer, an answer that does not check out', () async {
      var asked = 0;
      Future<CloudStatement?> ask(CloudStatusConfig c, Future<http.Response> Function() answer) => askCloudStatus(
            c,
            client: MockClient((_) {
              asked++;
              return answer();
            }),
            nowSeconds: () => downAt + 30,
          );
      expect(await ask(const CloudStatusConfig.none(), () async => http.Response(jsonEncode(down), 200)), isNull);
      expect(await ask(CloudStatusConfig(url: '', service: service, keys: keys), () async => http.Response(jsonEncode(down), 200)), isNull);
      expect(await ask(CloudStatusConfig(url: 'https://status.zestssh.com/v1/now', service: '', keys: keys),
          () async => http.Response(jsonEncode(down), 200)), isNull);
      expect(await ask(const CloudStatusConfig(url: 'https://status.zestssh.com/v1/now', service: service, keys: {}),
          () async => http.Response(jsonEncode(down), 200)), isNull);
      expect(asked, 0, reason: 'a service that is not set up is not asked');

      expect(await ask(config, () async => http.Response('{"error":"the status service is not set up"}', 500)), isNull);
      expect(await ask(config, () async => http.Response(jsonEncode(down), 503)), isNull,
          reason: 'a statement that comes with a fault is not taken');
      expect(await ask(config, () async => throw const SocketException('Connection refused')), isNull);
      expect(await ask(config, () async => http.Response(jsonEncode({...down, 'state': 'up', 'since': 0}), 200)), isNull);
      expect(await ask(config, () async => http.Response(jsonEncode(down), 200)), isNotNull);
      expect(asked, 5);
    });

    test('a statement is taken by the clock as it reads when the answer is in', () async {
      // Asked a moment before the statement's time is over, answered after.
      var clock = (down['until'] as int) + CloudStatement.clockSlack.inSeconds;
      final said = await askCloudStatus(
        config,
        client: MockClient((_) async {
          clock += 2;
          return http.Response(jsonEncode(down), 200);
        }),
        nowSeconds: () => clock,
      );
      expect(said, isNull);
    });

    // (As a widget test for its clock: time passes when the test says so.)
    testWidgets('a service that does not answer is given up on after a few seconds', (tester) async {
      CloudStatement? said;
      var done = false;
      unawaited(
        askCloudStatus(config, client: MockClient((_) => Completer<http.Response>().future), nowSeconds: () => downAt)
            .then((value) {
          said = value;
          done = true;
        }),
      );
      await tester.pump(kCloudStatusTimeout - const Duration(seconds: 1));
      expect(done, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(done, isTrue);
      expect(said, isNull);
    });

    test('it does not wait for ever', () {
      expect(kCloudStatusTimeout, lessThanOrEqualTo(const Duration(seconds: 10)));
      expect(kCloudStatusTimeout, greaterThanOrEqualTo(const Duration(seconds: 3)));
    });
  });
}
