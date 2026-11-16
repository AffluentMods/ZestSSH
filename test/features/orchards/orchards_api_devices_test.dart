import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';

/// Trusted devices (3.0) as the app says them to ZestSSH Cloud and
/// reads its answers: which sign-in this is, naming its device, the requests
/// of devices with what each side may see of them (one the app cannot read
/// is left out, never guessed at), the refusals with their codes, a device
/// that was removed, and a certificate request with its device.

void main() {
  http.Response json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  final asked = <http.Request>[];
  OrchardsApi api(Future<http.Response> Function(http.Request request) answer) => OrchardsApi(
        client: MockClient((request) {
          asked.add(request);
          return answer(request);
        }),
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'token',
      );

  setUp(asked.clear);

  Uint8List bytes(int fill, [int length = 32]) => Uint8List.fromList(List.filled(length, fill));
  String b64(int fill, [int length = 32]) => base64Encode(bytes(fill, length));

  Matcher refused(int status, String? code) => throwsA(
      isA<OrchardServerException>().having((e) => e.status, 'status', status).having((e) => e.code, 'code', code));

  test('which sign-in this is: its id, or none for a sign-in without a session', () async {
    expect(await api((r) async => json(200, {'id': 's-1', 'kind': 'session_token'})).currentSession(), 's-1');
    expect((asked.single.method, '${asked.single.url}'), ('GET', 'https://api.test/v1/sessions/current'));
    expect(asked.single.headers['Authorization'], 'Bearer token');
    expect(await api((r) async => json(404, {'code': 'no-session'})).currentSession(), isNull);
    expect(await api((r) async => json(200, {'id': 7})).currentSession(), isNull);
    // Anything else is an error, not "no session".
    await expectLater(api((r) async => json(404, {'code': 'not-found'})).currentSession(), refused(404, 'not-found'));
    await expectLater(api((r) async => json(401, {'code': 'session-revoked'})).currentSession(),
        refused(401, 'session-revoked'));
  });

  test('naming the device: its key and its signature; nothing to name is not an error, another key is',
      () async {
    // (A key and a signature whose base64 has a plus and a slash in it:
    // the one spelling the server takes.)
    final said = await api((r) async => json(200, {'bound': true}))
        .nameDevice(deviceKey: bytes(0xfb), signature: bytes(0xfb, 64));
    expect(said, isTrue);
    expect((asked.single.method, '${asked.single.url}'), ('PUT', 'https://api.test/v1/sessions/current/device'));
    expect(asked.single.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(asked.single.body), {'key': b64(0xfb), 'sig': b64(0xfb, 64)});
    expect(b64(0xfb), allOf(contains('+'), contains('/')));

    Future<bool> name(http.Response answer) =>
        api((r) async => answer).nameDevice(deviceKey: bytes(1), signature: bytes(2, 64));
    expect(await name(json(409, {'code': 'not-needed'})), isFalse, reason: 'the account is in no Orchard');
    expect(await name(json(404, {'code': 'no-session'})), isFalse);
    await expectLater(name(json(409, {'code': 'device-key-set'})), refused(409, 'device-key-set'));
    await expectLater(name(json(400, {'code': 'bad-signature'})), refused(400, 'bad-signature'));
    await expectLater(name(json(404, {'code': 'not-needed'})), refused(404, 'not-needed'),
        reason: 'the code and the status together say it');
    await expectLater(name(json(409, {'code': 'no-session'})), refused(409, 'no-session'));
  });

  test('the requests: this device\'s own, and those it could answer with what the asking device committed to',
      () async {
    final lists = await api((r) async => json(200, {
          // (Its own requests never say who asks, whatever the server puts
          // there.)
          'mine': [
            {'id': 'm-1', 'stage': 'created', 'expires_at': 1800000000, 'uid': 'someone-else'},
            {
              'id': 'm-2',
              'stage': 'responded',
              'expires_at': 1800000001,
              'responder_nonce': b64(5),
              'same_account': true,
              'uid': 7,
            },
          ],
          'waiting': [
            {'id': 'w-1', 'stage': 'created', 'expires_at': 1800000002, 'uid': 'alice', 'commitment': b64(6)},
            {
              'id': 'w-2',
              'stage': 'responded',
              'expires_at': 1800000003,
              'uid': 'bob',
              'commitment': b64(7),
              'responder_nonce': b64(8),
            },
            {
              'id': 'w-3',
              'stage': 'revealed',
              'expires_at': 1800000004,
              'uid': 'carol',
              'commitment': b64(9),
              'responder_nonce': b64(10),
              'device': b64(11),
              'nonce': b64(12),
            },
          ],
        })).deviceRequests('o-1');
    expect((asked.single.method, '${asked.single.url}'), ('GET', 'https://api.test/v1/orchards/o-1/device-requests'));
    expect([for (final r in lists.mine) (r.id, r.stage, r.expiresAt, r.uid, r.sameAccount)], [
      ('m-1', 'created', 1800000000, null, false),
      ('m-2', 'responded', 1800000001, null, true),
    ]);
    expect(lists.mine[0].responderNonce, isNull);
    expect(lists.mine[1].responderNonce, bytes(5));
    expect(lists.mine[1].commitment, isNull, reason: 'its own: it knows what it committed to');
    expect([for (final r in lists.waiting) (r.id, r.stage, r.expiresAt, r.uid)], [
      ('w-1', 'created', 1800000002, 'alice'),
      ('w-2', 'responded', 1800000003, 'bob'),
      ('w-3', 'revealed', 1800000004, 'carol'),
    ]);
    expect([for (final r in lists.waiting) r.commitment], [bytes(6), bytes(7), bytes(9)]);
    expect((lists.waiting[0].responderNonce, lists.waiting[0].deviceKey, lists.waiting[0].nonce), (null, null, null));
    expect(lists.waiting[1].responderNonce, bytes(8));
    expect(lists.waiting[2].responderNonce, bytes(10));
    expect(lists.waiting[2].deviceKey, bytes(11));
    expect(lists.waiting[2].nonce, bytes(12));
  });

  test('the requests: one the app cannot read is left out, and an answer that is no list is an error', () async {
    Map<String, Object?> waiting(Map<String, Object?> change) => {
          'id': 'w',
          'stage': 'revealed',
          'expires_at': 1800000000,
          'uid': 'alice',
          'commitment': b64(6),
          'responder_nonce': b64(8),
          'device': b64(11),
          'nonce': b64(12),
          ...change,
        };
    final lists = await api((r) async => json(200, {
          'mine': [
            'no request',
            {'stage': 'created', 'expires_at': 1},
            {'id': 'm', 'stage': 'approved', 'expires_at': 1},
            {'id': 'm', 'stage': 'approved', 'expires_at': 1, 'responder_nonce': b64(5)},
            {'id': 'm', 'stage': 'created', 'expires_at': '1'},
            {'id': 'm', 'stage': 'responded', 'expires_at': 1},
            {'id': 'm', 'stage': 'responded', 'expires_at': 1, 'responder_nonce': b64(5, 31)},
            {'id': 'kept', 'stage': 'revealed', 'expires_at': 1, 'responder_nonce': b64(5)},
          ],
          'waiting': [
            waiting({'stage': 'approved'}),
            waiting({'stage': 7}),
            waiting({'uid': null}),
            waiting({'uid': 7}),
            waiting({'commitment': null}),
            waiting({'commitment': b64(6, 33)}),
            waiting({'commitment': 'not base64 !'}),
            waiting({'responder_nonce': null}),
            waiting({'device': null}),
            waiting({'device': b64(11, 31)}),
            waiting({'nonce': null}),
            waiting({'nonce': b64(12, 16)}),
            waiting({'id': 'kept', 'stage': 'created', 'responder_nonce': null, 'device': null, 'nonce': null}),
          ],
        })).deviceRequests('o-1');
    expect([for (final r in lists.mine) r.id], ['kept'], reason: 'its own request, shown: nothing more to read');
    expect([for (final r in lists.waiting) r.id], ['kept']);

    await expectLater(api((r) async => json(200, {'mine': <Object>[]})).deviceRequests('o-1'), throwsFormatException);
    await expectLater(api((r) async => json(200, {'mine': <Object>[], 'waiting': 'none'})).deviceRequests('o-1'),
        throwsFormatException);
    await expectLater(api((r) async => json(403, {'code': 'rules-unmet', 'unmet': ['two_step']})).deviceRequests('o-1'),
        refused(403, 'rules-unmet'));
  });

  test('asking, answering, showing and taking back: what each sends, and the refusals with their codes', () async {
    expect(await api((r) async => json(201, {'id': 'r-1', 'expires_in': 600})).askDeviceTrust('o-1', bytes(3)), 'r-1');
    expect((asked.single.method, '${asked.single.url}'), ('POST', 'https://api.test/v1/orchards/o-1/device-requests'));
    expect(jsonDecode(asked.single.body), {'commitment': b64(3)});
    await expectLater(api((r) async => json(201, {'ok': true})).askDeviceTrust('o-1', bytes(3)), throwsFormatException);
    for (final code in ['device-not-named', 'device-approved']) {
      await expectLater(api((r) async => json(409, {'code': code})).askDeviceTrust('o-1', bytes(3)), refused(409, code));
    }

    asked.clear();
    await api((r) async => json(200, {'ok': true})).answerDeviceTrust('o-1', 'r-1', bytes(4));
    expect((asked.single.method, '${asked.single.url}'),
        ('POST', 'https://api.test/v1/orchards/o-1/device-requests/r-1/respond'));
    expect(jsonDecode(asked.single.body), {'nonce': b64(4)});
    for (final code in ['device-not-approved', 'answered']) {
      await expectLater(api((r) async => json(409, {'code': code})).answerDeviceTrust('o-1', 'r-1', bytes(4)),
          refused(409, code));
    }

    asked.clear();
    await api((r) async => json(200, {'ok': true})).showDeviceTrust('o-1', 'r-1', deviceKey: bytes(1), nonce: bytes(5));
    expect((asked.single.method, '${asked.single.url}'),
        ('POST', 'https://api.test/v1/orchards/o-1/device-requests/r-1/reveal'));
    expect(jsonDecode(asked.single.body), {'device': b64(1), 'nonce': b64(5)});
    for (final code in ['not-answered', 'reveal-mismatch']) {
      await expectLater(
          api((r) async => json(409, {'code': code})).showDeviceTrust('o-1', 'r-1', deviceKey: bytes(1), nonce: bytes(5)),
          refused(409, code));
    }

    asked.clear();
    await api((r) async => http.Response('', 204)).dropDeviceTrust('o-1', 'r-1');
    expect((asked.single.method, '${asked.single.url}'),
        ('DELETE', 'https://api.test/v1/orchards/o-1/device-requests/r-1'));
    expect(asked.single.body, isEmpty);
    await expectLater(api((r) async => json(404, {'code': 'not-found'})).dropDeviceTrust('o-1', 'r-1'),
        refused(404, 'not-found'));
  });

  test('the list: held back as a device nobody approved, and one that was removed', () async {
    Map<String, Object?> held(String id, Map<String, Object?> more) =>
        {'id': id, 'status': 'rules', 'role': 'owner', 'unmet': ['trusted_device'], ...more};
    final orchards = await api((r) async => json(200, {
          'orchards': [
            held('o-new', {}),
            held('o-removed', {'device_removed': true}),
            held('o-odd', {'device_removed': 'yes'}),
            {'id': 'o-suspended', 'status': 'suspended', 'device_removed': true},
          ],
        })).orchards();
    expect([for (final o in orchards) (o.id, o.status, o.deviceRemoved)], [
      ('o-new', 'rules', false),
      ('o-removed', 'rules', true),
      ('o-odd', 'rules', false),
      ('o-suspended', 'suspended', false),
    ]);
    expect(orchards[1].rulesUnmet, ['trusted_device']);
  });

  test('only the device holds it back: the one refusal that asking to be approved answers', () {
    OrchardServerException held(List<String>? unmet, {int status = 403, String code = 'rules-unmet'}) =>
        OrchardServerException(status, code, unmet: unmet);
    expect(held(['trusted_device']).deviceNotApproved, isTrue);
    expect(held(['two_step', 'trusted_device']).deviceNotApproved, isFalse, reason: 'something else as well');
    expect(held(['two_step']).deviceNotApproved, isFalse);
    expect(held(const []).deviceNotApproved, isFalse);
    expect(held(null).deviceNotApproved, isFalse);
    expect(held(['trusted_device'], status: 409, code: 'rules-unmet-by-you').deviceNotApproved, isFalse);
    expect(held(['trusted_device'], status: 409).deviceNotApproved, isFalse);
  });

  test('a certificate request names its device and carries its signature, both or neither', () async {
    CertRequest request({Uint8List? device, Uint8List? deviceSignature}) => CertRequest(
          id: 'q-1',
          uid: 'alice',
          keyVersion: 2,
          sshPublicKey: bytes(20),
          requestedAt: 1800000000,
          signature: bytes(21, 64),
          deviceKey: device,
          deviceSignature: deviceSignature,
        );
    await api((r) async => json(201, {'ok': true}))
        .askCertificate('c-1', request(device: bytes(1), deviceSignature: bytes(2, 64)));
    expect((asked.single.method, '${asked.single.url}'), ('POST', 'https://api.test/v1/crates/c-1/certificates'));
    expect(jsonDecode(asked.single.body), {
      'id': 'q-1',
      'ssh_public_key': b64(20),
      'requested_at': 1800000000,
      'key_version': 2,
      'signature': b64(21, 64),
      'device': b64(1),
      'device_sig': b64(2, 64),
    });
    asked.clear();
    await api((r) async => json(201, {'ok': true})).askCertificate('c-1', request());
    expect((jsonDecode(asked.single.body) as Map).keys, isNot(anyOf(contains('device'), contains('device_sig'))),
        reason: 'an older app names none');
    await expectLater(
        api((r) async => json(409, {'code': 'device-not-approved'})).askCertificate('c-1', request()),
        refused(409, 'device-not-approved'));

    // As an owner's device reads the ones that wait.
    Map<String, Object?> listed(Map<String, Object?> more) => {
          'id': 'q',
          'uid': 'alice',
          'key_version': 2,
          'ssh_public_key': b64(20),
          'requested_at': 1800000000,
          'signature': b64(21, 64),
          ...more,
        };
    final waiting = await api((r) async => json(200, {
          'requests': [
            listed({'id': 'old'}),
            listed({'id': 'named', 'device': b64(1), 'device_sig': b64(2, 64)}),
            listed({'id': 'no-signature', 'device': b64(1)}),
            listed({'id': 'no-device', 'device_sig': b64(2, 64)}),
            listed({'id': 'short-key', 'device': b64(1, 31), 'device_sig': b64(2, 64)}),
            listed({'id': 'odd-signature', 'device': b64(1), 'device_sig': 7}),
            listed({'id': 'not-base64', 'device': b64(1), 'device_sig': 'not base64 !'}),
          ],
        })).waitingCertificates('c-1');
    expect([for (final q in waiting) q.id], ['old', 'named'], reason: 'half a device is no request');
    expect((waiting[0].deviceKey, waiting[0].deviceSignature), (null, null));
    expect(waiting[1].deviceKey, bytes(1));
    expect(waiting[1].deviceSignature, bytes(2, 64));
    expect(deviceKeyText(waiting[1].deviceKey!), b64(1));
  });
}
