import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/services/profiles/locked_copies.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';

import 'profile_world.dart';

/// The app's client for locked copies against the REAL server routes
/// (ZestSSH Cloud's routes/locked_copies.js) on a real Postgres, so both sides
/// agree on paths, fields and codes. Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running, or runs a version without these routes.
/// ZESTSSH_TEST_API overrides the base URL (default http://127.0.0.1:39200/v1).
/// A Firebase ID token there is `fb:<uid>:<authTime>:<iat>`.
void main() {
  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String firebaseToken(String uid, {int? authTime}) => 'fb:$uid:${authTime ?? now()}:${now()}';

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/account/locked-copies')).timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  String skip() => 'app contract server with locked copies not running at $base';

  LockedCopiesApi api() => LockedCopiesApi(client: client, baseUrl: base);

  List<int> secret(int fill) => List<int>.filled(32, fill);

  String copyId(String tag) => 'copy-$tag-${now()}0000000';

  Future<String> desktopSession(String uid, {int? authTime}) async {
    final r = await client.post(Uri.parse('$base/auth/session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_token': firebaseToken(uid, authTime: authTime)}));
    expect(r.statusCode, 200, reason: r.body);
    return (jsonDecode(r.body) as Map<String, dynamic>)['session_token'] as String;
  }

  test('a secret kept, handed back after a fresh sign-in, listed, and deleted', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = 'locked-${now()}-a';
    final bearer = await desktopSession(uid);
    final id = copyId('a');
    await api().store(bearer: bearer, id: id, secret: secret(7));
    // The same id twice is one store, of the first.
    await api().store(bearer: bearer, id: id, secret: secret(8));

    expect(await api().handBack(bearer: bearer, id: id), secret(7));
    final listed = await api().list(bearer: bearer);
    expect(listed.single.id, id);
    expect(listed.single.platform, Platform.operatingSystem);
    expect(listed.single.madeOn, matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));

    expect(await api().delete(bearer: bearer, id: id), isTrue);
    expect(await api().delete(bearer: bearer, id: id), isFalse);
    await expectLater(
      api().handBack(bearer: bearer, id: id),
      throwsA(isA<LockedCopyRefused>().having((e) => e.code, 'code', 'locked-copy-not-found').having((e) => e.status, 'status', 404)),
    );
  });

  test('a sign-in from long ago gets no secret, and says so in a way the app knows', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = 'locked-${now()}-b';
    final fresh = await desktopSession(uid);
    final id = copyId('b');
    await api().store(bearer: fresh, id: id, secret: secret(1));
    final old = await desktopSession(uid, authTime: now() - 3600);
    await expectLater(
      api().handBack(bearer: old, id: id),
      throwsA(isA<LockedCopyRefused>().having((e) => e.code, 'code', 'recent-sign-in-required').having((e) => e.status, 'status', 403)),
    );
    // Listing asks no fresh sign-in, and deleting does.
    expect((await api().list(bearer: old)).length, 1);
    await expectLater(api().delete(bearer: old, id: id), throwsA(isA<LockedCopyRefused>()));
    expect(await api().delete(bearer: fresh, id: id), isTrue);
  });

  test('another account reaches nothing of it', () async {
    if (!serverUp) return markTestSkipped(skip());
    final mine = await desktopSession('locked-${now()}-c');
    final theirs = await desktopSession('locked-${now()}-d');
    final id = copyId('c');
    await api().store(bearer: mine, id: id, secret: secret(2));
    await expectLater(api().handBack(bearer: theirs, id: id), throwsA(isA<LockedCopyRefused>()));
    expect(await api().list(bearer: theirs), isEmpty);
    expect(await api().delete(bearer: theirs, id: id), isFalse);
    expect(await api().handBack(bearer: mine, id: id), secret(2));
  });

  test('a whole sign-out and sign-in against the real routes: locked, handed back, replaced', () async {
    if (!serverUp) return markTestSkipped(skip());
    final world = await ProfileWorld.create();
    addTearDown(world.dispose);
    final uid = 'locked-${now()}-f';
    final bearer = await desktopSession(uid);
    final manager = world.launch(api: api());
    await manager.start();
    var db = await manager.openCurrent();

    var plan = await manager.planForAccount(uid: uid, label: 'someone@example.com', bearer: bearer);
    var prepared = await manager.prepare(plan);
    await db.close();
    await manager.commit(prepared);
    db = prepared.db;
    await addHost(db, 'host-of-the-account');
    expect(await manager.settleLockedCopy(db: db, bearer: bearer), isTrue);
    final id = manager.currentEntry!.id;
    final first = (await manager.copies.confirmed(id))!.id;

    expect(await manager.lockCurrent(), SignOutEnd.locked);
    final guest = await manager.openGuest();
    await db.close();

    // A token from an old sign-in, as one copied off this computer: refused.
    final old = await desktopSession(uid, authTime: now() - 3600);
    await expectLater(
      manager.planForAccount(uid: uid, label: null, bearer: old),
      throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-signed-in-long-ago')),
    );

    plan = await manager.planForAccount(uid: uid, label: null, bearer: bearer);
    prepared = await manager.prepare(plan);
    await guest.close();
    await manager.commit(prepared);
    expect(await hostsOf(prepared.db), ['host-of-the-account']);
    expect(await manager.settleLockedCopy(db: prepared.db, bearer: bearer, replace: true), isTrue);
    final second = (await manager.copies.confirmed(id))!.id;
    expect(second, isNot(first));
    expect((await api().list(bearer: bearer)).map((c) => c.id), [second], reason: 'the old one is gone at ZestSSH Cloud');
    await prepared.db.close();
  });

  test('the light check: numbers only, for the account asking', () async {
    if (!serverUp) return markTestSkipped(skip());
    final bearer = await desktopSession('locked-${now()}-e', authTime: now() - 86400);
    final counts = await api().waiting(bearer: bearer);
    expect(counts.total, 0);
  });
}
