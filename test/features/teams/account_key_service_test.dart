import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// ZestSSH Cloud's keys endpoints in memory, with the server's rules:
/// create-only publishing, a harmless repeat, 409 with the winner's keys.
class _FakeServer {
  _FakeServer(this.uid);

  final String uid;
  Map<String, dynamic>? published;
  int publishes = 0;

  /// Makes the next publish lose a race to [winner].
  Map<String, dynamic>? raceWinner;

  /// Starting over (POST /keys/reset): how many arrived, the answer to
  /// give the next one instead of the server's own (a refusal), and whether
  /// the next one goes through with its answer lost on the way back.
  int resets = 0;
  http.Response? resetAnswer;
  bool loseResetAnswer = false;

  /// Everything that was asked of this server.
  int requests = 0;

  http.Client get client => MockClient((request) async {
        requests++;
        if (request.url.path.endsWith('/keys/reset') && request.method == 'POST') {
          resets++;
          final refusal = resetAnswer;
          resetAnswer = null;
          if (refusal != null) return refusal;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (published == null) return http.Response(jsonEncode({'code': 'no-keys'}), 404);
          if (body['key_version'] != (published!['key_version'] as int) + 1) {
            return http.Response(jsonEncode({'code': 'version-conflict'}), 409);
          }
          published = body;
          if (loseResetAnswer) {
            loseResetAnswer = false;
            return http.Response('', 502);
          }
          return http.Response(
              jsonEncode({'published': true, 'key_version': body['key_version'], 'copies_dropped': 0}), 200);
        }
        if (request.url.path.endsWith('/keys/me') && request.method == 'GET') {
          if (published == null) {
            return http.Response(
                jsonEncode({'code': 'no-keys', 'uid': uid}), 404);
          }
          return http.Response(jsonEncode({'uid': uid, ...published!}), 200);
        }
        if (request.url.path.endsWith('/keys') && request.method == 'POST') {
          publishes++;
          if (raceWinner != null) {
            published = raceWinner;
            raceWinner = null;
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (published == null) {
            published = body;
            return http.Response(jsonEncode({'published': true}), 201);
          }
          if (published!['x25519_pub'] == body['x25519_pub'] &&
              published!['ed25519_pub'] == body['ed25519_pub']) {
            return http.Response(jsonEncode({'published': true}), 200);
          }
          return http.Response(
              jsonEncode({'code': 'keys-exist', 'keys': published}), 409);
        }
        return http.Response('{}', 404);
      });
}

void main() {
  const uid = 'uid-alice';
  late _FakeServer server;
  late int changes;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    server = _FakeServer(uid);
    changes = 0;
  });

  AccountKeyService service({String? token = 'token', AccountKeyStore? store}) {
    return AccountKeyService(
      api: AccountKeysApi(
        client: server.client,
        baseUrl: 'https://api.test/v1',
        bearer: () async => token,
      ),
      store: store ?? AccountKeyStore(const FlutterSecureStorage()),
      onKeysChanged: () => changes++,
    );
  }

  Future<Map<String, dynamic>> bundleFor(AccountKeys keys) async =>
      (await keys.publish(uid)).toJson();

  test('the first device makes keys, publishes them and has sync carry them',
      () async {
    final store = AccountKeyStore(const FlutterSecureStorage());
    expect(await service(store: store).ensureKeys(), AccountKeyStatus.ready);

    final stored = await store.read(uid);
    expect(stored!.state, StoredKeyState.confirmed);
    expect(server.published, isNotNull);
    expect(changes, 1);
    final keys = await AccountKeys.fromSecretJson(stored.secret);
    expect(
        PublishedAccountKeys.fromJson(uid, server.published!).matches(keys),
        isTrue);
    expect((await store.exportForSync(account: uid)).keys, [uid]);

    // Nothing more to do on the next check.
    expect(await service(store: store).ensureKeys(), AccountKeyStatus.ready);
    expect(server.publishes, 1);
    expect(changes, 1);
  });

  test('a second device waits for the keys, then adopts them through sync',
      () async {
    final keys = await AccountKeys.generate();
    server.published = await bundleFor(keys);

    final storeB = AccountKeyStore(const FlutterSecureStorage());
    expect(await service(store: storeB).ensureKeys(),
        AccountKeyStatus.waitingForAnotherDevice);
    expect(await storeB.read(uid), isNull, reason: 'no second set is made');
    expect(server.publishes, 0);

    // Sync brings device A's keys.
    await storeB.importFromSync({uid: await keys.toSecretJson()});
    expect((await storeB.read(uid))!.state, StoredKeyState.synced);
    expect(await service(store: storeB).ensureKeys(), AccountKeyStatus.ready);
    expect((await storeB.read(uid))!.state, StoredKeyState.confirmed);
  });

  test('losing a publish race drops the unpublished keys', () async {
    final winner = await AccountKeys.generate();
    server.raceWinner = await bundleFor(winner);

    final store = AccountKeyStore(const FlutterSecureStorage());
    expect(await service(store: store).ensureKeys(),
        AccountKeyStatus.waitingForAnotherDevice);
    expect(await store.read(uid), isNull);
    expect(changes, 0);
  });

  test('keys this device confirmed are set aside, never deleted, when the '
      'server shows others', () async {
    final store = AccountKeyStore(const FlutterSecureStorage());
    await service(store: store).ensureKeys();
    final mine = (await store.read(uid))!.secret;

    // The server now shows other keys: replaced elsewhere, or substituted.
    server.published = await bundleFor(await AccountKeys.generate());
    expect(await service(store: store).ensureKeys(),
        AccountKeyStatus.changedElsewhere);
    final kept = (await store.read(uid))!;
    expect(kept.state, StoredKeyState.superseded);
    expect(kept.secret, mine);
    expect(await store.exportForSync(account: uid), isEmpty,
        reason: 'set-aside keys do not sync');
  });

  // For when the server cannot be asked (3.0): an Orchard on
  // this device, and a certificate it holds, go on working through an
  // outage with the keys the server last confirmed.
  group('the keys this device holds as confirmed, without asking the server', () {
    test('are the ones the server confirmed, and reading them asks nothing of it', () async {
      final store = AccountKeyStore(const FlutterSecureStorage());
      await service(store: store).ensureKeys();
      final asked = server.requests;
      final here = await service(store: store).confirmedKeysHere(uid);
      expect(here, isNotNull);
      expect(PublishedAccountKeys.fromJson(uid, server.published!).matches(here!), isTrue);
      expect(server.requests, asked, reason: 'the point is that the server cannot be reached');
    });

    test('are none on a device that holds no keys, or only those of another account', () async {
      final store = AccountKeyStore(const FlutterSecureStorage());
      expect(await service(store: store).confirmedKeysHere(uid), isNull);
      await service(store: store).ensureKeys();
      expect(await service(store: store).confirmedKeysHere('somebody-else'), isNull);
    });

    test('are none while keys that came through sync were never confirmed', () async {
      final store = AccountKeyStore(const FlutterSecureStorage());
      await store.importFromSync({uid: await (await AccountKeys.generate()).toSecretJson()});
      expect((await store.read(uid))!.state, StoredKeyState.synced);
      expect(await service(store: store).confirmedKeysHere(uid), isNull,
          reason: 'keys nobody checked against the server stand in for nothing');
    });

    test('are none once the server has shown others', () async {
      final store = AccountKeyStore(const FlutterSecureStorage());
      await service(store: store).ensureKeys();
      server.published = await bundleFor(await AccountKeys.generate());
      await service(store: store).ensureKeys();
      expect((await store.read(uid))!.state, StoredKeyState.superseded);
      expect(await service(store: store).confirmedKeysHere(uid), isNull);
    });
  });

  test('a published bundle that does not verify is not trusted', () async {
    final published = await bundleFor(await AccountKeys.generate());
    final sig = base64Decode(published['self_sig'] as String)..[0] ^= 1;
    server.published = {...published, 'self_sig': base64Encode(sig)};

    final store = AccountKeyStore(const FlutterSecureStorage());
    await store.importFromSync({uid: await (await AccountKeys.generate()).toSecretJson()});
    expect(await service(store: store).ensureKeys(),
        AccountKeyStatus.unavailable);
    expect((await store.read(uid))!.state, StoredKeyState.synced,
        reason: 'nothing local changes on an untrustworthy answer');
  });

  test('signed out: nothing happens', () async {
    expect(await service(token: null).ensureKeys(),
        AccountKeyStatus.unavailable);
    expect(server.publishes, 0);
  });

  group('keys arriving through sync', () {
    late AccountKeyStore store;
    setUp(() => store = AccountKeyStore(const FlutterSecureStorage()));

    test('confirmed keys are not replaced by other keys of the same version',
        () async {
      final mine = await AccountKeys.generate();
      await store.write(uid, StoredAccountKeys(
          StoredKeyState.confirmed, await mine.toSecretJson()));
      final other = await AccountKeys.generate();
      expect(await store.importFromSync({uid: await other.toSecretJson()}), 0);
      expect((await store.read(uid))!.secret, await mine.toSecretJson());
    });

    test('a newer version replaces confirmed or set-aside keys', () async {
      await store.write(uid, StoredAccountKeys(StoredKeyState.superseded,
          await (await AccountKeys.generate()).toSecretJson()));
      final newer = await AccountKeys.generate(version: 2);
      expect(await store.importFromSync({uid: await newer.toSecretJson()}), 1);
      expect((await store.read(uid))!.version, 2);
      expect((await store.read(uid))!.state, StoredKeyState.synced);
    });

    test('malformed entries and bad account ids are ignored', () async {
      final good = await (await AccountKeys.generate()).toSecretJson();
      expect(
        await store.importFromSync({
          'bad id!': good,
          'uid-x': {'format': 1},
          'uid-y': 'not a map',
        }),
        0,
      );
      expect(await store.importFromSync('not a map'), 0);
    });
  });

  group('starting over after the keys were lost', () {
    test('a device without the keys starts over with the next version, published without an endorsement',
        () async {
      server.published = await bundleFor(await AccountKeys.generate());
      final store = AccountKeyStore(const FlutterSecureStorage());
      expect(await service(store: store).ensureKeys(), AccountKeyStatus.waitingForAnotherDevice);

      final started = await service(store: store).startOver();
      expect(started.uid, uid);
      expect(started.keys.version, 2);
      expect(server.resets, 1);
      expect(PublishedAccountKeys.fromJson(uid, server.published!).matches(started.keys), isTrue);
      expect(server.published!['endorsement'], isNull, reason: 'nothing can vouch for them');
      expect((await store.read(uid))!.state, StoredKeyState.confirmed);
      expect(await store.readNext(uid), isNull);
      expect(changes, 1, reason: 'sync carries them to the next device');
      expect(await service(store: store).ensureKeys(), AccountKeyStatus.ready);
    });

    test('a device that holds the published keys replaces them instead', () async {
      final store = AccountKeyStore(const FlutterSecureStorage());
      await service(store: store).ensureKeys();
      await expectLater(service(store: store).startOver(), throwsA(isA<AccountKeysStillHere>()));
      expect(server.resets, 0);
    });

    test('keys this device held that the server no longer shows are set aside, never deleted', () async {
      final store = AccountKeyStore(const FlutterSecureStorage());
      await service(store: store).ensureKeys();
      final mine = (await store.read(uid))!.secret;
      server.published = await bundleFor(await AccountKeys.generate());
      expect(await service(store: store).ensureKeys(), AccountKeyStatus.changedElsewhere);

      final started = await service(store: store).startOver();
      expect(started.keys.version, 2);
      expect((await store.readPrevious(uid))!.secret, mine);
    });

    test('a start-over whose answer was lost finishes with the same keys, never a second time', () async {
      server.published = await bundleFor(await AccountKeys.generate());
      final store = AccountKeyStore(const FlutterSecureStorage());
      server.loseResetAnswer = true;
      await expectLater(service(store: store).startOver(), throwsA(isA<StateError>()));
      final pending = (await store.readNext(uid))!;
      expect(pending.state, StoredKeyState.pending);
      expect(await store.read(uid), isNull, reason: 'not switched before the server said so');

      final again = await service(store: store).startOver();
      expect(server.resets, 1, reason: 'the server had them already');
      expect(await again.keys.toSecretJson(), pending.secret);
      expect((await store.read(uid))!.state, StoredKeyState.confirmed);
    });

    test('refused, nothing changes: a sign-in needed, the keys moved on meanwhile; then the same new keys go',
        () async {
      server.published = await bundleFor(await AccountKeys.generate());
      final store = AccountKeyStore(const FlutterSecureStorage());
      server.resetAnswer = http.Response(jsonEncode({'code': 'recent-sign-in-required'}), 403);
      await expectLater(service(store: store).startOver(), throwsA(isA<AccountKeysNeedRecentSignIn>()));
      expect(await store.read(uid), isNull);
      final pending = (await store.readNext(uid))!.secret;
      server.resetAnswer = http.Response(jsonEncode({'code': 'version-conflict'}), 409);
      await expectLater(service(store: store).startOver(),
          throwsA(isA<AccountKeysReplaceConflict>().having((e) => e.code, 'code', 'version-conflict')));
      expect(await store.read(uid), isNull);

      final started = await service(store: store).startOver();
      expect(await started.keys.toSecretJson(), pending);
      expect(server.resets, 3);
    });

    test('signed out, or no keys published yet: nothing to start over from', () async {
      await expectLater(service(token: null).startOver(), throwsA(isA<AccountKeysNotReady>()));
      await expectLater(service().startOver(), throwsA(isA<AccountKeysNotReady>()));
      expect(server.resets, 0);
    });
  });

  group('AccountKeyChecker', () {
    test('checks until ready, then at most every six hours', () async {
      var now = DateTime.utc(2026, 9, 23, 12);
      final checker = AccountKeyChecker(service(), clock: () => now);

      await checker.afterSync();
      expect(checker.lastStatus, AccountKeyStatus.ready);
      expect(server.publishes, 1);

      server.published = null; // the next real check would publish again
      now = now.add(const Duration(hours: 5));
      await checker.afterSync();
      expect(server.publishes, 1, reason: 'skipped within six hours');

      now = now.add(const Duration(hours: 2));
      await checker.afterSync();
      expect(server.publishes, 2, reason: 'checked again after six hours');
    });

    test('a failure is logged and retried next time', () async {
      final failing = AccountKeyService(
        api: AccountKeysApi(
          client: MockClient((_) async => http.Response('oops', 500)),
          baseUrl: 'https://api.test/v1',
          bearer: () async => 'token',
        ),
        store: AccountKeyStore(const FlutterSecureStorage()),
        onKeysChanged: () {},
      );
      final checker = AccountKeyChecker(failing);
      await checker.afterSync();
      expect(checker.lastStatus, isNull);
    });
  });
}
