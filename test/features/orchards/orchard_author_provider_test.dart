import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';

/// Which keys are the account's, as the app is wired (3.0):
/// with ZestSSH Cloud out of reach and nothing known yet in this run, the
/// keys this device holds for the signed-in account as the server last
/// confirmed them. So an app started during an outage still opens what is
/// on the device and still logs in with a certificate it holds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uid = 'u-anna';
  late AccountKeys keys;
  late bool serverDown;
  late int asked;

  setUpAll(() async => keys = await AccountKeys.generate());

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    serverDown = false;
    asked = 0;
  });

  ProviderContainer app({String? signedInAs = uid}) {
    final store = AccountKeyStore(const FlutterSecureStorage());
    final container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(signedInAs == null ? null : UserProfile(uid: signedInAs)),
      accountKeyServiceProvider.overrideWithValue(AccountKeyService(
        api: AccountKeysApi(
          client: MockClient((request) async {
            asked++;
            if (serverDown) throw const SocketException('Connection refused');
            final published = await keys.publish(uid);
            return http.Response(jsonEncode({'uid': uid, ...published.toJson()}), 200);
          }),
          baseUrl: 'https://api.test/v1',
          bearer: () async => 'token',
        ),
        store: store,
        onKeysChanged: () {},
      )),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Future<void> hold(StoredKeyState state, {String account = uid}) async =>
      AccountKeyStore(const FlutterSecureStorage()).write(account, StoredAccountKeys(state, await keys.toSecretJson()));

  test('the server answers: its answer, checked against the keys on the device', () async {
    await hold(StoredKeyState.confirmed);
    final who = await app().read(orchardAuthorProvider)();
    expect(who!.uid, uid);
    expect(asked, 1);
  });

  test('started while the server is down: the keys the device holds as confirmed', () async {
    await hold(StoredKeyState.confirmed);
    serverDown = true;
    final who = await app().read(orchardAuthorProvider)();
    expect(who!.uid, uid);
    expect(await who.keys.toSecretJson(), await keys.toSecretJson());
    expect(asked, 1, reason: 'the server was asked first');
  });

  test('keys that were never confirmed, or that the server has replaced, stand in for nothing', () async {
    serverDown = true;
    for (final state in [StoredKeyState.pending, StoredKeyState.synced, StoredKeyState.superseded]) {
      FlutterSecureStorage.setMockInitialValues({});
      await hold(state);
      await expectLater(app().read(orchardAuthorProvider)(), throwsA(isA<SocketException>()), reason: '$state');
    }
  });

  test('another account\'s keys on the device are not this account\'s', () async {
    await hold(StoredKeyState.confirmed, account: 'u-someone-else');
    serverDown = true;
    await expectLater(app().read(orchardAuthorProvider)(), throwsA(isA<SocketException>()));
  });

  test('nobody signed in: nothing stands in', () async {
    await hold(StoredKeyState.confirmed);
    serverDown = true;
    // (Signed out, no token: the keys service answers that nobody is there.)
    final container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(null),
      accountKeyServiceProvider.overrideWithValue(AccountKeyService(
        api: AccountKeysApi(
          client: MockClient((_) async => throw const SocketException('Connection refused')),
          baseUrl: 'https://api.test/v1',
          bearer: () async => 'token',
        ),
        store: AccountKeyStore(const FlutterSecureStorage()),
        onKeysChanged: () {},
      )),
    ]);
    addTearDown(container.dispose);
    await expectLater(container.read(orchardAuthorProvider)(), throwsA(isA<SocketException>()));
  });
}
