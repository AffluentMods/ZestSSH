// One account per email address (3.0): the ways an account signs in, as
// this device and ZestSSH Cloud tell them; a sign-in ZestSSH Cloud refuses
// because the address belongs to another account; a way someone tried that
// the address's account does not have yet; and the way a device signs in
// again.

import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/account/sign_in_ways.dart';
import 'package:zestssh/services/auth_service.dart';

void main() {
  group('The ways', () {
    test('each Firebase provider is the way ZestSSH names it', () {
      expect(signInWayOf('google.com'), SignInWay.google);
      expect(signInWayOf('apple.com'), SignInWay.apple);
      expect(signInWayOf('microsoft.com'), SignInWay.microsoft);
      expect(signInWayOf('password'), SignInWay.password);
      expect(signInWayOf('saml.northwind'), SignInWay.company);
      expect(signInWayOf('oidc.northwind'), SignInWay.company);
    });

    test('a provider ZestSSH does not offer is none', () {
      for (final id in ['github.com', 'facebook.com', 'phone', '', 'samlx', 'oidc']) {
        expect(signInWayOf(id), isNull, reason: id);
      }
    });

    test('from this device: each way once, in the order they are named everywhere', () {
      final ways = SignInWays.fromProviders(
        'alice@example.com',
        ['password', 'apple.com', 'github.com', 'google.com', 'oidc.a', 'saml.b'],
      );
      expect(ways.email, 'alice@example.com');
      expect(ways.ways, [SignInWay.google, SignInWay.apple, SignInWay.company, SignInWay.password]);
      expect(ways.hasPassword, isTrue);
    });

    test('an account made through Google has no password', () {
      final ways = SignInWays.fromProviders('alice@example.com', ['google.com']);
      expect(ways.ways, [SignInWay.google]);
      expect(ways.hasPassword, isFalse);
    });

    test("from ZestSSH Cloud's answer, words it does not know left out", () {
      final ways = SignInWays.fromJson({
        'email': 'alice@example.com',
        'methods': ['password', 'google', 'carrier-pigeon', 'microsoft', 'google'],
        'has_password': true,
      });
      expect(ways.email, 'alice@example.com');
      expect(ways.ways, [SignInWay.google, SignInWay.microsoft, SignInWay.password]);
      expect(ways.hasPassword, isTrue);
    });

    test('an answer without its parts is no ways and no address', () {
      final ways = SignInWays.fromJson({'methods': 'google', 'email': 7});
      expect(ways.email, '');
      expect(ways.ways, isEmpty);
      expect(ways.hasPassword, isFalse);
    });
  });

  group('Asking ZestSSH Cloud', () {
    late List<http.Request> asked;

    SignInWaysApi api(int status, Object body, {String? token = 'bearer-1'}) {
      asked = [];
      return SignInWaysApi(
        baseUrl: 'https://api.example.com/v1',
        bearer: () async => token,
        client: MockClient((request) async {
          asked.add(request);
          return http.Response(body is String ? body : jsonEncode(body), status);
        }),
      );
    }

    test('the ways of the account signed in here', () async {
      final ways = await api(200, {'email': 'bob@example.com', 'methods': ['google'], 'has_password': false}).load();
      expect(ways.ways, [SignInWay.google]);
      expect(ways.email, 'bob@example.com');
      expect(asked.single.method, 'GET');
      expect(asked.single.url.toString(), 'https://api.example.com/v1/account/sign-in-methods');
      expect(asked.single.headers['Authorization'], 'Bearer bearer-1');
    });

    test('an address that belongs to another account is said as such', () async {
      await expectLater(
        api(409, {'error': 'This email address already has a ZestSSH account', 'code': 'email-has-account'}).load(),
        throwsA(isA<AddressHasAccount>()),
      );
    });

    test('anything else is a failure that says what came back', () async {
      Future<SignInWaysException> failure(int status, Object body) async {
        try {
          await api(status, body).load();
        } on SignInWaysException catch (e) {
          return e;
        }
        fail('$status was taken for an answer');
      }

      final other = await failure(409, {'code': 'something-else'});
      expect((other.status, other.code), (409, 'something-else'));
      final down = await failure(503, {'code': 'sign-in-methods-unavailable'});
      expect((down.status, down.code), (503, 'sign-in-methods-unavailable'));
      final garbled = await failure(502, '<html>bad gateway</html>');
      expect((garbled.status, garbled.code), (502, 'unexpected'));
      final notAMap = await failure(200, ['google']);
      expect((notAMap.status, notAMap.code), (200, 'unexpected'));
    });

    test('nobody signed in here asks nothing', () async {
      final signedOut = api(200, {}, token: null);
      await expectLater(
        signedOut.load(),
        throwsA(isA<SignInWaysException>().having((e) => e.code, 'code', 'signed-out')),
      );
      expect(asked, isEmpty);
    });
  });

  group('A way the address does not have yet', () {
    final google = GoogleAuthProvider.credential(idToken: 'id-token', accessToken: 'access-token');

    test('is kept, with the address, to be added once they are signed in the usual way', () async {
      try {
        await AuthService.accountExists(
          () async => throw FirebaseAuthException(
            code: 'account-exists-with-different-credential',
            email: 'alice@example.com',
            credential: google,
          ),
        );
        fail('the sign-in went through');
      } on SsoAccountExists catch (pending) {
        expect(pending.email, 'alice@example.com');
        expect(pending.credential, same(google));
      }
    });

    test("Firebase's address is the one the account has", () async {
      await expectLater(
        AuthService.accountExists(
          () async => throw FirebaseAuthException(
            code: 'account-exists-with-different-credential',
            email: 'alice@example.com',
            credential: google,
          ),
          email: 'alice.work@example.com',
        ),
        throwsA(isA<SsoAccountExists>().having((p) => p.email, 'email', 'alice@example.com')),
      );
    });

    test('says which address when Firebase does not', () async {
      await expectLater(
        AuthService.accountExists(
          () async => throw FirebaseAuthException(code: 'account-exists-with-different-credential', credential: google),
          email: 'bob@example.com',
        ),
        throwsA(isA<SsoAccountExists>().having((p) => p.email, 'email', 'bob@example.com')),
      );
      await expectLater(
        AuthService.accountExists(
          () async => throw FirebaseAuthException(code: 'account-exists-with-different-credential', credential: google),
        ),
        throwsA(isA<SsoAccountExists>().having((p) => p.email, 'email', '')),
      );
    });

    test('without the way to add, or for any other failure, it is that failure', () async {
      await expectLater(
        AuthService.accountExists(
          () async => throw FirebaseAuthException(code: 'account-exists-with-different-credential'),
        ),
        throwsA(isA<FirebaseAuthException>()),
      );
      await expectLater(
        AuthService.accountExists(
          () async => throw FirebaseAuthException(code: 'network-request-failed', credential: google),
        ),
        throwsA(isA<FirebaseAuthException>().having((e) => e.code, 'code', 'network-request-failed')),
      );
    });
  });

  group('Signing in again', () {
    SignInWay? way(Set<String> providers, {bool appleHere = true}) =>
        AuthService.wayToSignInAgain(providers, appleHere: appleHere);

    test('goes by a way this device has', () {
      expect(way({'google.com', 'apple.com', 'password'}), SignInWay.google);
      expect(way({'apple.com', 'password'}), SignInWay.apple);
      expect(way({'apple.com', 'password'}, appleHere: false), SignInWay.password,
          reason: "Apple's own sign-in is on Apple's devices only");
      expect(way({'password', 'microsoft.com'}), SignInWay.password);
      expect(way({'microsoft.com'}), SignInWay.microsoft);
    });

    test('an account only Apple signs in to has no way on another device', () {
      expect(way({'apple.com'}, appleHere: false), isNull);
      expect(way({'apple.com'}), SignInWay.apple);
      expect(way({'github.com'}), isNull);
      expect(way(const {}), isNull);
    });
  });
}
