import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/services/account/device_sessions.dart';

/// The app's device-session client against the REAL server routes
/// (ZestSSH Cloud's routes/auth.js, routes/sessions.js, the auth middleware)
/// on a real Postgres, so both sides agree on paths, fields, headers and
/// codes. Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1). A Firebase ID token there is
/// `fb:<uid>:<authTime>:<iat>`.
void main() {
  final base =
      Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String firebaseToken(String uid) => 'fb:$uid:${now()}:${now()}';

  setUpAll(() async {
    try {
      final r = await client
          .get(Uri.parse('$base/sessions'))
          .timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    DeviceSessionHeader.current = null;
  });

  String skip() => 'app contract server not running at $base';

  /// A desktop signs in the way the website does it for the app.
  Future<String> desktopSignIn(String uid) async {
    final r = await client.post(Uri.parse('$base/auth/session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_token': firebaseToken(uid)}));
    expect(r.statusCode, 200, reason: r.body);
    return (jsonDecode(r.body) as Map<String, dynamic>)['session_token']
        as String;
  }

  test('a phone registers, a desktop signs it out, and the phone learns it',
      () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = 'contract-${now()}-a';

    // The phone: signed in with Firebase, registers itself.
    final phoneToken = firebaseToken(uid);
    final phone = DeviceSessionService(
      api: DeviceSessionsApi(
          client: client, baseUrl: base, bearer: () async => phoneToken),
      store: DeviceSessionStore(const FlutterSecureStorage()),
      firebaseUid: () => uid,
      sessionToken: () async => null,
      saveSessionToken: (_) async {},
      labels: () async =>
          const DeviceLabels(platform: 'android'),
    );
    await phone.ensure();
    // What the phone sends is its token: its id, and what proves it.
    final phoneId = DeviceSessionHeader.current!.split('.').first;
    expect(DeviceSessionHeader.current, startsWith('$phoneId.'));
    var list = await phone.api.list();
    expect(list.single.id, phoneId);
    expect(list.single.current, isTrue);
    expect(list.single.kind, 'registration');
    expect(list.single.platform, 'android');

    // Its bare id, which the list shows to anybody of the account, names no
    // device: nothing calls as it, and a sign-in that is not recent does not
    // sign it out by it.
    final token = DeviceSessionHeader.current;
    final byId = DeviceSessionsApi(
        client: client,
        baseUrl: base,
        bearer: () async => 'fb:$uid:${now() - 3600}:${now()}');
    DeviceSessionHeader.current = phoneId;
    expect(await byId.current(), isNull);
    await expectLater(
      byId.signOut(phoneId),
      throwsA(isA<DeviceSessionsException>()
          .having((e) => e.needsRecentSignIn, 'needsRecentSignIn', isTrue)),
    );
    DeviceSessionHeader.current = token;
    expect(await phone.api.current(), phoneId, reason: 'its token still names it');

    // The desktop: a browser sign-in, then labels itself.
    var desktopToken = await desktopSignIn(uid);
    final desktop = DeviceSessionService(
      api: DeviceSessionsApi(
          client: client, baseUrl: base, bearer: () async => desktopToken),
      store: DeviceSessionStore(const FlutterSecureStorage()),
      firebaseUid: () => null,
      sessionToken: () async => desktopToken,
      saveSessionToken: (t) async => desktopToken = t,
      labels: () async =>
          const DeviceLabels(platform: 'windows'),
    );
    final phoneHeader = DeviceSessionHeader.current;
    DeviceSessionHeader.current = null; // the desktop sends none
    await desktop.ensure();
    list = await desktop.api.list();
    expect(list, hasLength(2));
    final me = list.firstWhere((d) => d.current);
    expect(me.kind, 'session_token');
    expect(me.platform, 'windows');
    expect(me.createdAt, isNotNull);

    // Freshly signed in, the desktop signs the phone out.
    await desktop.api.signOut(phoneId);

    // The phone's next request is refused and raises the signal.
    DeviceSessionHeader.current = phoneHeader;
    final before = sessionRevokedSignal.value;
    await expectLater(
      phone.api.list(),
      throwsA(isA<DeviceSessionsException>()
          .having((e) => e.signedOut, 'signedOut', isTrue)),
    );
    expect(sessionRevokedSignal.value, before + 1);
  });

  test('signing out another device without a recent sign-in is refused; '
      'sign out everywhere ends every session', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = 'contract-${now()}-b';

    // A stale desktop sign-in: auth_time an hour ago.
    final stale = await client.post(Uri.parse('$base/auth/session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_token': 'fb:$uid:${now() - 3600}:${now()}'}));
    final staleToken =
        (jsonDecode(stale.body) as Map<String, dynamic>)['session_token']
            as String;
    final other = await desktopSignIn(uid);
    final staleApi = DeviceSessionsApi(
        client: client, baseUrl: base, bearer: () async => staleToken);
    final otherApi = DeviceSessionsApi(
        client: client, baseUrl: base, bearer: () async => other);
    final otherId = await otherApi.current();

    await expectLater(
      staleApi.signOut(otherId!),
      throwsA(isA<DeviceSessionsException>()
          .having((e) => e.needsRecentSignIn, 'needsRecentSignIn', isTrue)),
    );
    await expectLater(
      staleApi.signOutEverywhere(),
      throwsA(isA<DeviceSessionsException>()
          .having((e) => e.needsRecentSignIn, 'needsRecentSignIn', isTrue)),
    );

    // The fresh one can.
    expect(await otherApi.signOutEverywhere(), 2);
    for (final api in [staleApi, otherApi]) {
      await expectLater(
        api.list(),
        throwsA(isA<DeviceSessionsException>()
            .having((e) => e.signedOut, 'signedOut', isTrue)),
      );
    }
  });
}
