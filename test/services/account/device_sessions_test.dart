import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/signed_out_notice.dart';

/// ZestSSH Cloud's device endpoints in memory, with the server's rules
/// (ZestSSH Cloud's routes/sessions.js): a session token (`st:<id>`) names
/// its session; a Firebase token (`fb:<uid>`) names a registration through
/// the X-ZestSSH-Session header; "legacy" is a session token from before
/// sessions existed. A registration made with token_only is named by its
/// token alone: its bare id names no session (migration 0030).
class _FakeCloud {
  final sessions = <String, Map<String, dynamic>>{};
  final revoked = <String>{};
  final requests = <http.Request>[];
  var nextId = 1;
  bool recentSignIn = true;

  /// A server from before tokens gives a registration none.
  bool giveTokens = true;

  String _newId() =>
      '00000000-0000-4000-8000-${(nextId++).toString().padLeft(12, '0')}';

  String addSession({String kind = 'session_token', String? platform}) {
    final id = _newId();
    sessions[id] = {'id': id, 'kind': kind, 'platform': platform};
    return id;
  }

  http.Response _json(int status, Map<String, dynamic> body) =>
      http.Response(jsonEncode(body), status);

  http.Client get client => MockClient((request) async {
        requests.add(request);
        final path = request.url.path.replaceFirst('/v1', '');
        final auth = request.headers['Authorization'] ?? '';
        final token = auth.startsWith('Bearer ') ? auth.substring(7) : '';

        // Who is asking, as the middleware sees it, and whether the request
        // proves it.
        String? current;
        var bound = false;
        if (token.startsWith('st:')) {
          current = token.substring(3);
          bound = true;
          if (revoked.contains(current) || !sessions.containsKey(current)) {
            return _json(401, {'code': 'session-revoked'});
          }
        } else if (token.startsWith('fb:')) {
          // A registration's token is "<id>.<proof>"; a bare id names it
          // too, unless it was made with token_only.
          final header = request.headers[DeviceSessionHeader.name];
          if (header != null) {
            final id = header.split('.').first;
            if (revoked.contains(id) || !sessions.containsKey(id)) {
              return _json(401, {'code': 'session-revoked'});
            }
            bound = header.contains('.');
            if (bound || sessions[id]!['token_only'] != true) current = id;
          }
        } else if (token != 'legacy') {
          return _json(401, {'error': 'Invalid token'});
        }

        if (path == '/auth/refresh' && request.method == 'POST') {
          final id = current ?? addSession();
          return _json(200, {'session_token': 'st:$id'});
        }
        if (path == '/sessions' && request.method == 'GET') {
          return _json(200, {
            'current_id': current,
            'sessions': [
              for (final s in sessions.values)
                if (!revoked.contains(s['id'])) {...s, 'current': s['id'] == current},
            ],
          });
        }
        if (path == '/sessions' && request.method == 'POST') {
          if (!token.startsWith('fb:')) {
            return _json(409, {'code': 'already-a-session'});
          }
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final id = addSession(
              kind: 'registration', platform: body['platform'] as String?);
          // A server from before tokens keeps nothing of token_only.
          sessions[id]!.addAll({...body}..removeWhere((k, _) => k == 'token_only' && !giveTokens));
          return _json(201, {'id': id, if (giveTokens) 'token': '$id.proof'});
        }
        if (path == '/sessions/current') {
          if (current == null) return _json(404, {'code': 'no-session'});
          if (request.method == 'GET') {
            return _json(200, {'id': current, 'kind': sessions[current]!['kind']});
          }
          sessions[current]!
              .addAll(jsonDecode(request.body) as Map<String, dynamic>);
          // A server from before tokens does not say whether it was proved.
          return _json(200, {'updated': true, if (giveTokens) 'bound': bound});
        }
        if (path == '/sessions/revoke-all' && request.method == 'POST') {
          if (!recentSignIn) return _json(403, {'code': 'recent-sign-in-required'});
          final n = sessions.keys.where((k) => !revoked.contains(k)).length;
          revoked.addAll(sessions.keys);
          return _json(200, {'signed_out': n});
        }
        if (path.startsWith('/sessions/') && request.method == 'DELETE') {
          final id = path.substring('/sessions/'.length);
          if (id != current && !recentSignIn) {
            return _json(403, {'code': 'recent-sign-in-required'});
          }
          if (!sessions.containsKey(id) || revoked.contains(id)) {
            return _json(404, {'code': 'no-such-session'});
          }
          revoked.add(id);
          return _json(200, {'signed_out': true});
        }
        return _json(404, {'error': 'Not found'});
      });
}

void main() {
  late _FakeCloud cloud;
  late DeviceSessionStore store;
  String? bearerToken;
  String? firebaseUid;
  String? sessionToken;
  const labels = DeviceLabels(platform: 'android');

  DeviceSessionsApi api() => DeviceSessionsApi(
        client: cloud.client,
        baseUrl: 'https://api.test/v1',
        bearer: () async => bearerToken,
      );

  DeviceSessionService service() => DeviceSessionService(
        api: api(),
        store: store,
        firebaseUid: () => firebaseUid,
        sessionToken: () async => sessionToken,
        saveSessionToken: (t) async {
          sessionToken = t;
          bearerToken = t;
        },
        labels: () async => labels,
      );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    cloud = _FakeCloud();
    store = DeviceSessionStore(const FlutterSecureStorage());
    DeviceSessionHeader.current = null;
    bearerToken = null;
    firebaseUid = null;
    sessionToken = null;
  });

  test('labels carry only the platform', () {
    final json = DeviceLabels.forThisDevice().toJson();
    expect(json.keys, everyElement(equals('platform')));
  });

  group('a device signed in with Firebase', () {
    setUp(() {
      firebaseUid = 'alice';
      bearerToken = 'fb:alice';
    });

    test('registers once, then sends its registration with every request',
        () async {
      await service().ensure();
      final stored = await store.read();
      expect(stored!.uid, 'alice');
      expect(stored.token, '${stored.id}.proof');
      expect(DeviceSessionHeader.current, stored.token, reason: 'its token, not its bare id');
      expect(cloud.sessions[stored.id]!['kind'], 'registration');
      expect(cloud.sessions[stored.id]!['platform'], 'android');
      final post = cloud.requests.singleWhere((r) => r.method == 'POST');
      expect(jsonDecode(post.body), {'platform': 'android', 'token_only': true},
          reason: 'it says that it keeps the token, so that its bare id names nothing');

      // Next start: no second registration, labels refreshed with the header.
      cloud.requests.clear();
      DeviceSessionHeader.current = null;
      await service().ensure();
      expect(cloud.sessions.length, 1);
      final put = cloud.requests.single;
      expect(put.method, 'PUT');
      expect(put.headers[DeviceSessionHeader.name], stored.token);
    });

    test('a registration for another account is not reused', () async {
      await store.save('bob', '00000000-0000-4000-8000-000000000999');
      await service().ensure();
      final stored = await store.read();
      expect(stored!.uid, 'alice');
      expect(stored.id, isNot('00000000-0000-4000-8000-000000000999'));
    });

    test('signed out elsewhere: the next contact raises the signal', () async {
      await service().ensure();
      final id = (await store.read())!.id;
      cloud.revoked.add(id);
      final before = sessionRevokedSignal.value;
      await service().ensure(); // never throws
      expect(sessionRevokedSignal.value, before + 1);
    });

    test('signing out here signs the registration out and forgets it',
        () async {
      await service().ensure();
      final id = (await store.read())!.id;
      await service().signOutHere();
      expect(cloud.revoked, contains(id));
      expect(await store.read(), isNull);
      expect(DeviceSessionHeader.current, isNull);
    });

    test('a registration kept from before tokens is made again, once, and the old one is signed out by its own id',
        () async {
      final old = cloud.addSession(kind: 'registration', platform: 'android');
      // As an app from before tokens kept it: an id alone.
      await const FlutterSecureStorage()
          .write(key: DeviceSessionStore.storageKey, value: jsonEncode({'uid': 'alice', 'id': old}));
      await service().ensure();
      final stored = await store.read();
      expect(stored!.id, isNot(old));
      expect(stored.token, '${stored.id}.proof');
      expect(DeviceSessionHeader.current, stored.token);
      expect(cloud.revoked, contains(old));
      final delete = cloud.requests.singleWhere((r) => r.method == 'DELETE');
      expect(delete.url.path, endsWith('/sessions/$old'));
      expect(delete.headers[DeviceSessionHeader.name], old, reason: 'it names itself to sign itself out');
      // Next start: kept, not made again.
      cloud.requests.clear();
      await service().ensure();
      expect(cloud.requests.map((r) => r.method), ['PUT']);
    });

    test('an old registration already signed out elsewhere does not sign this device out', () async {
      final old = cloud.addSession(kind: 'registration');
      cloud.revoked.add(old);
      await const FlutterSecureStorage()
          .write(key: DeviceSessionStore.storageKey, value: jsonEncode({'uid': 'alice', 'id': old}));
      final before = sessionRevokedSignal.value;
      await service().ensure();
      expect(sessionRevokedSignal.value, before, reason: 'what the old one is answered is not about this device');
      expect((await store.read())!.token, isNotNull);
    });

    test('a server that gives no token: the id is sent, and the registration is not made again at each start',
        () async {
      cloud.giveTokens = false;
      await service().ensure();
      final stored = await store.read();
      expect(stored!.token, isNull);
      expect(DeviceSessionHeader.current, stored.id);
      cloud.requests.clear();
      await service().ensure();
      expect(cloud.sessions.length, 1);
      expect(cloud.requests.map((r) => r.method), ['PUT']);
    });

    test('kept without a token where the server gave none, it is made again once the server says its id proves nothing',
        () async {
      cloud.giveTokens = false;
      await service().ensure();
      final old = (await store.read())!.id;
      // The server is updated: it gives tokens, and says what a request proves.
      cloud.giveTokens = true;
      cloud.requests.clear();
      await service().ensure();
      final stored = await store.read();
      expect(stored!.id, isNot(old));
      expect(stored.token, '${stored.id}.proof');
      expect(DeviceSessionHeader.current, stored.token);
      expect(cloud.requests.map((r) => r.method), ['PUT', 'POST', 'DELETE']);
      expect(cloud.revoked, [old]);
      expect(cloud.requests.last.url.path, endsWith('/sessions/$old'));
      expect(cloud.requests.last.headers[DeviceSessionHeader.name], old, reason: 'it names itself to sign itself out');
      // Next start: kept, as the server says its token proves it.
      cloud.requests.clear();
      await service().ensure();
      expect(cloud.requests.map((r) => r.method), ['PUT']);
      expect((await store.read())!.id, stored.id);
    });

    test('labelling says whether the request proved which device it comes from', () async {
      await service().ensure();
      final stored = (await store.read())!;
      expect(await api().label(labels), isTrue);
      DeviceSessionHeader.current = stored.id;
      await expectLater(api().label(labels), throwsA(isA<DeviceSessionsException>()),
          reason: 'its bare id names no device: the server knows no session for it');
      cloud.giveTokens = false;
      DeviceSessionHeader.current = stored.token;
      expect(await api().label(labels), isNull, reason: 'a server from before tokens says nothing of it');
    });
  });

  group('a desktop signed in through the browser', () {
    test('a token from before sessions existed becomes a listed session',
        () async {
      sessionToken = 'legacy';
      bearerToken = 'legacy';
      await service().ensure();
      expect(sessionToken, startsWith('st:'), reason: 'refreshed and saved');
      final id = sessionToken!.substring(3);
      expect(cloud.sessions[id]!['platform'], 'android',
          reason: 'labelled after the upgrade');
      expect(DeviceSessionHeader.current, isNull,
          reason: 'session tokens carry their session');
    });

    test('a current session token is only labelled', () async {
      final id = cloud.addSession();
      sessionToken = 'st:$id';
      bearerToken = sessionToken;
      await service().ensure();
      expect(sessionToken, 'st:$id');
      expect(cloud.requests.map((r) => r.method), ['GET', 'PUT']);
    });

    // It lives 30 days and was never renewed while in use: a computer was
    // signed out every month (found in a security review).
    group('renewed while in use', () {
      final today = DateTime.utc(2026, 10, 29, 12);
      var saves = 0;
      DeviceSessionService aged(Duration age, {DateTime Function()? clock}) => DeviceSessionService(
            api: api(),
            store: store,
            firebaseUid: () => firebaseUid,
            sessionToken: () async => sessionToken,
            saveSessionToken: (t) async {
              saves++;
              sessionToken = t;
              bearerToken = t;
            },
            labels: () async => labels,
            issuedAt: (_) => today.subtract(age),
            now: clock ?? () => today,
          );
      Iterable<http.Request> renewals() => cloud.requests.where((r) => r.url.path.endsWith('/auth/refresh'));
      late String id;
      setUp(() {
        saves = 0;
        id = cloud.addSession();
        sessionToken = 'st:$id';
        bearerToken = sessionToken;
      });

      test('a week old, it is renewed and what the server gave is kept', () async {
        await aged(DeviceSessionService.renewAfter + const Duration(minutes: 1)).renewIfOld();
        expect(renewals(), hasLength(1));
        expect(renewals().single.headers['Authorization'], 'Bearer st:$id');
        expect((saves, sessionToken), (1, 'st:$id'));
      });

      test('younger, nothing is asked', () async {
        await aged(const Duration(days: 2)).renewIfOld();
        expect(cloud.requests, isEmpty);
        expect(saves, 0);
      });

      test('at the start too, after the device is labelled', () async {
        await aged(const Duration(days: 20)).ensure();
        expect(cloud.requests.map((r) => '${r.method} ${r.url.path}'),
            ['GET /v1/sessions/current', 'PUT /v1/sessions/current', 'POST /v1/auth/refresh']);
      });

      test('looked at no more than once an hour, however often the window comes back', () async {
        var at = today;
        final s = aged(const Duration(days: 9), clock: () => at);
        await s.renewIfOld();
        at = at.add(const Duration(minutes: 20));
        await s.renewIfOld();
        expect(renewals(), hasLength(1));
        at = at.add(DeviceSessionService.renewCheckEvery);
        await s.renewIfOld();
        expect(renewals(), hasLength(2));
      });

      test('signed in with Firebase, nothing: its own sign-in stays fresh', () async {
        firebaseUid = 'alice';
        await aged(const Duration(days: 9)).renewIfOld();
        expect(cloud.requests, isEmpty);
      });

      test('signed out elsewhere, the renewal says so and keeps the token', () async {
        cloud.revoked.add(id);
        final before = sessionRevokedSignal.value;
        await aged(const Duration(days: 9)).renewIfOld();
        expect(sessionRevokedSignal.value, before + 1);
        expect((saves, sessionToken), (0, 'st:$id'));
      });
    });

    // Turning two-step on signs the other devices out: said as that, not
    // as some other device (found in a security review).
    test('the reason ZestSSH Cloud gives is kept for the notice, and the notice says it', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      reportIfSessionRevoked(http.Response(
          jsonEncode({'error': 'x', 'code': 'session-revoked', 'reason': 'second-step-required'}), 401));
      expect(sessionRevokedReason, kSignedOutForTwoStep);
      expect(signedOutNotice(l10n, sessionRevokedReason).title, l10n.devicesSignedOutTwoStepTitle);
      expect(signedOutNotice(l10n, sessionRevokedReason).body, l10n.devicesSignedOutTwoStepBody);
      reportIfSessionRevoked(http.Response(jsonEncode({'code': 'session-revoked'}), 401));
      expect(sessionRevokedReason, isNull);
      expect(signedOutNotice(l10n, sessionRevokedReason).body, l10n.devicesSignedOutElsewhereBody);
    });

    // The company sign-in this account used is gone (its team deleted,
    // or an owner turned it off): every call is refused from then
    // on, so the device signs that account out and says why, instead of
    // failing on every screen.
    test('a company sign-in that is gone signs this device out, and the notice says why', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      final before = sessionRevokedSignal.value;
      final out = reportIfSessionRevoked(http.Response(
          jsonEncode({'error': 'Your company sign-in is no longer on for this account.', 'code': 'sso-removed'}), 403));
      expect(out, isTrue);
      expect(sessionRevokedSignal.value, before + 1);
      expect(sessionRevokedReason, kSignedOutSsoRemoved);
      expect(signedOutNotice(l10n, sessionRevokedReason).title, l10n.devicesSignedOutSsoRemovedTitle);
      expect(signedOutNotice(l10n, sessionRevokedReason).body,
          'Your company sign-in is no longer on for this account. Sign in again another way.');
      // Other refusals are not a sign-out.
      for (final code in ['sso-not-active', 'sso-domain-mismatch', 'rules-unmet', 'team-being-deleted']) {
        expect(reportIfSessionRevoked(http.Response(jsonEncode({'code': code}), 403)), isFalse, reason: code);
      }
      expect(sessionRevokedSignal.value, before + 1);
    });

    // It said "Invalid token", and the advice was to sign out, which turned
    // sync off (found in a security review).
    test('a sign-in that ran out is said as that: not a sign-out, and the app is told', () {
      final expired = sessionExpiredSignal.value, revoked = sessionRevokedSignal.value;
      final ranOut = reportIfSessionRevoked(http.Response(
          jsonEncode({'error': 'This sign-in ran out. Sign in again.', 'code': 'session-expired'}), 401));
      expect(ranOut, isFalse, reason: 'nothing is signed out');
      expect(sessionExpiredSignal.value, expired + 1);
      expect(sessionRevokedSignal.value, revoked);
    });

    test('a session token says when it was made; anything else says nothing', () {
      String jwt(Object? claims) =>
          'eyJhbGciOiJIUzI1NiJ9.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.c2ln';
      expect(sessionTokenIssuedAt(jwt({'userId': 7, 'iat': 1793000000})),
          DateTime.fromMillisecondsSinceEpoch(1793000000 * 1000, isUtc: true));
      expect(sessionTokenIssuedAt(jwt({'userId': 7})), isNull);
      expect(sessionTokenIssuedAt(jwt({'iat': '1793000000'})), isNull);
      expect(sessionTokenIssuedAt('st:00000000-0000-4000-8000-000000000001'), isNull);
      expect(sessionTokenIssuedAt('a.%%%.c'), isNull);
    });
  });

  test('signing out offline does not hang, and still forgets the device',
      () async {
    firebaseUid = 'alice';
    bearerToken = 'fb:alice';
    await store.save('alice', '00000000-0000-4000-8000-000000000001');
    DeviceSessionHeader.current = '00000000-0000-4000-8000-000000000001';
    final never = Completer<http.Response>();
    final offline = DeviceSessionService(
      api: DeviceSessionsApi(
        client: MockClient((_) => never.future),
        baseUrl: 'https://api.test/v1',
        bearer: () async => bearerToken,
      ),
      store: store,
      firebaseUid: () => firebaseUid,
      sessionToken: () async => null,
      saveSessionToken: (_) async {},
      labels: () async => labels,
    );
    final watch = Stopwatch()..start();
    await offline.signOutHere(within: const Duration(milliseconds: 200));
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(await store.read(), isNull);
    expect(DeviceSessionHeader.current, isNull);
  });

  test('signed out: nothing is asked and no header is sent', () async {
    DeviceSessionHeader.current = 'stale';
    await service().ensure();
    expect(cloud.requests, isEmpty);
    expect(DeviceSessionHeader.current, isNull);
  });

  group('the device list and sign-out', () {
    test('lists devices with the asking one marked', () async {
      final mine = cloud.addSession(platform: 'windows');
      cloud.addSession(kind: 'registration', platform: 'ios');
      bearerToken = 'st:$mine';
      final list = await api().list();
      expect(list, hasLength(2));
      expect(list.firstWhere((d) => d.current).id, mine);
      expect(list.firstWhere((d) => !d.current).isPhone, isTrue);
    });

    test('signing another device out may need a recent sign-in', () async {
      final mine = cloud.addSession();
      final other = cloud.addSession();
      bearerToken = 'st:$mine';
      cloud.recentSignIn = false;
      await expectLater(
        api().signOut(other),
        throwsA(isA<DeviceSessionsException>()
            .having((e) => e.needsRecentSignIn, 'needsRecentSignIn', isTrue)),
      );
      cloud.recentSignIn = true;
      await api().signOut(other);
      expect(cloud.revoked, {other});
    });

    test('sign out everywhere reports how many went', () async {
      final mine = cloud.addSession();
      cloud.addSession();
      bearerToken = 'st:$mine';
      expect(await api().signOutEverywhere(), 2);
    });

    test('a signed-out device learns it from any answer', () async {
      final mine = cloud.addSession();
      bearerToken = 'st:$mine';
      cloud.revoked.add(mine);
      final before = sessionRevokedSignal.value;
      await expectLater(
        api().list(),
        throwsA(isA<DeviceSessionsException>()
            .having((e) => e.signedOut, 'signedOut', isTrue)),
      );
      expect(sessionRevokedSignal.value, before + 1);
    });

    test('other 401s are not mistaken for a sign-out', () {
      final before = sessionRevokedSignal.value;
      expect(
          reportIfSessionRevoked(
              http.Response(jsonEncode({'code': 'account-not-found'}), 401)),
          isFalse);
      expect(reportIfSessionRevoked(http.Response('not json', 401)), isFalse);
      expect(sessionRevokedSignal.value, before);
    });
  });

  test('a token that does not name the registration it came with is not kept', () async {
    final api = DeviceSessionsApi(
      client: MockClient((request) async => http.Response(jsonEncode({'id': 'a1', 'token': 'b2.proof'}), 201)),
      baseUrl: 'https://api.test/v1',
      bearer: () async => 'fb:alice',
    );
    final made = await api.register(const DeviceLabels(platform: 'android'));
    expect(made.id, 'a1');
    expect(made.token, isNull);
  });

  group('stillSignedInHere (a "signed out" for a sign-in since replaced)', () {
    DeviceSessionsApi api(http.Response Function() answer, {String? token = 'st:new'}) => DeviceSessionsApi(
          client: MockClient((request) async => answer()),
          baseUrl: 'https://api.test/v1',
          bearer: () async => token,
        );

    test('the sign-in this device has now is alive: still signed in, and no second signal', () async {
      final before = sessionRevokedSignal.value;
      expect(await stillSignedInHere(api(() => http.Response(jsonEncode({'id': 'a1', 'kind': 'session_token'}), 200))),
          isTrue);
      expect(sessionRevokedSignal.value, before);
    });

    test('ZestSSH Cloud says this sign-in too is signed out: signed out', () async {
      expect(await stillSignedInHere(api(() => http.Response(jsonEncode({'code': 'session-revoked'}), 401))), isFalse);
    });

    test('a company sign-in that is gone: signed out', () async {
      expect(await stillSignedInHere(api(() => http.Response(jsonEncode({'code': 'sso-removed'}), 403))), isFalse);
    });

    test('nothing to sign in with: signed out', () async {
      expect(await stillSignedInHere(api(() => http.Response('{}', 200), token: null)), isFalse);
    });

    test('a device that cannot ask now (offline, a fault of the server) is taken as still signed in', () async {
      expect(await stillSignedInHere(api(() => throw const SocketLikeFailure())), isTrue);
      expect(await stillSignedInHere(api(() => http.Response('{}', 503))), isTrue);
    });

    test('a Firebase sign-in without a registration (no session) is still signed in', () async {
      expect(await stillSignedInHere(api(() => http.Response(jsonEncode({'code': 'no-session'}), 404))), isTrue);
    });
  });
}

class SocketLikeFailure implements Exception {
  const SocketLikeFailure();
}

