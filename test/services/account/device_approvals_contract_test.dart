import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/services/account/device_approvals.dart';
import 'package:zestssh/services/account/device_sessions.dart';

/// Approving a new device, the app's client against the REAL server routes
/// (ZestSSH Cloud's routes/device_approvals.js) on a real Postgres (3.0):
/// a desktop signed in through the browser approves a
/// phone signed in with Firebase, both showing the same words, and the
/// sealed key arrives once. Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1). A Firebase ID token there is
/// `fb:<uid>:<authTime>:<iat>`.
void main() {
  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/sessions')).timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  String skip() => 'app contract server not running at $base';
  Future<void> poll(Duration _) => Future<void>.delayed(const Duration(milliseconds: 60));

  /// A phone signed in with Firebase, registered, and a desktop signed in
  /// through the browser, both of account [uid].
  Future<(DeviceApprovalsApi, DeviceApprovalsApi)> devices(String uid) async {
    final firebase = 'fb:$uid:${now()}:${now()}';
    final phoneSession = await DeviceSessionsApi(client: client, baseUrl: base, bearer: () async => firebase)
        .register(const DeviceLabels(platform: 'android'));
    final r = await client.post(Uri.parse('$base/auth/session'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'id_token': firebase}));
    expect(r.statusCode, 200, reason: r.body);
    final desktopToken = (jsonDecode(r.body) as Map<String, dynamic>)['session_token'] as String;
    return (
      DeviceApprovalsApi(
        client: client,
        baseUrl: base,
        bearer: () async => firebase,
        // The registration's token: what proves which device asks.
        sessionHeaders: () => {DeviceSessionHeader.name: phoneSession.token!},
      ),
      DeviceApprovalsApi(client: client, baseUrl: base, bearer: () async => desktopToken, sessionHeaders: () => {}),
    );
  }

  final handover = SyncHandover(
    dek: Uint8List.fromList(List<int>.generate(32, (i) => 31 - i)),
    verificationHash: Uint8List.fromList(utf8.encode('check')),
    argon2Params: const {'version': 2, 'memory': 131072, 'iterations': 3, 'parallelism': 4},
    salt: Uint8List.fromList(List<int>.filled(32, 3)),
  );

  test('a desktop approves a phone: the same words, and the key arrives once', () async {
    if (!serverUp) return markTestSkipped(skip());
    final (phone, desktop) = await devices('approval-${now()}-a');

    final ask = await ApprovalAsk.start(phone, name: 'Pixel');
    expect(ask.request.stage, 'created');
    final open = (await desktop.list()).where((r) => r.id == ask.id).single;
    expect((open.role, open.name), ('open', 'Pixel'));
    expect(open.commitment, isNull, reason: 'the list holds no commitment; reading the request does');
    final give = await ApprovalGive.answer(desktop, ask.id);
    expect(give.commitment, ask.commitment);

    final onPhone = await ask.awaitApprover(wait: poll);
    final onDesktop = await give.awaitReveal(wait: poll);
    expect(onDesktop, onPhone);
    await give.send(handover);
    final got = await ask.awaitHandover(wait: poll);
    expect(got.dek, handover.dek);
    expect(got.verificationHash, handover.verificationHash);
    expect(got.salt, handover.salt);
    expect(got.argon2Params, handover.argon2Params);
    // Collected once: the request is gone for both.
    for (final api in [phone, desktop]) {
      await expectLater(api.get(ask.id), throwsA(isA<DeviceApprovalException>().having((e) => e.ended, 'ended', isTrue)));
    }
  });

  test("the phone cannot answer its own request, and the desktop's refusal ends it", () async {
    if (!serverUp) return markTestSkipped(skip());
    final (phone, desktop) = await devices('approval-${now()}-b');
    final ask = await ApprovalAsk.start(phone, name: 'Pixel');
    await expectLater(ApprovalGive.answer(phone, ask.id), throwsA(isA<DeviceApprovalException>()));
    final give = await ApprovalGive.answer(desktop, ask.id);
    await give.refuse();
    await expectLater(ask.awaitApprover(wait: poll),
        throwsA(isA<DeviceApprovalException>().having((e) => e.ended, 'ended', isTrue)));
  });

  test('"This was not me": until someone answers, any device of the account ends it; then only the two sides', () async {
    if (!serverUp) return markTestSkipped(skip());
    final uid = 'approval-${now()}-d';
    final (phone, desktop) = await devices(uid);
    final ask = await ApprovalAsk.start(phone, name: 'Pixel');
    await desktop.cancel(ask.id);
    await expectLater(phone.get(ask.id), throwsA(isA<DeviceApprovalException>().having((e) => e.ended, 'ended', isTrue)));

    final again = await ApprovalAsk.start(phone, name: 'Pixel');
    await ApprovalGive.answer(desktop, again.id);
    final (_, laptop) = await devices(uid);
    await expectLater(laptop.cancel(again.id),
        throwsA(isA<DeviceApprovalException>().having((e) => e.ended, 'not its request', isTrue)));
    expect((await phone.get(again.id)).stage, 'responded', reason: 'still going between the two sides');
  });

  test('a reveal that is not what the phone committed to ends the request', () async {
    if (!serverUp) return markTestSkipped(skip());
    final (phone, desktop) = await devices('approval-${now()}-c');
    final ask = await ApprovalAsk.start(phone, name: 'Pixel');
    await ApprovalGive.answer(desktop, ask.id);
    await expectLater(
      phone.reveal(ask.id, publicKey: List<int>.filled(32, 5), nonce: List<int>.filled(32, 6)),
      throwsA(isA<DeviceApprovalException>().having((e) => e.mismatch, 'mismatch', isTrue)),
    );
    await expectLater(phone.get(ask.id), throwsA(isA<DeviceApprovalException>().having((e) => e.ended, 'ended', isTrue)));
  });
}
