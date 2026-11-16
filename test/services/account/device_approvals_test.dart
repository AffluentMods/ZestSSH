import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/account/device_approvals.dart';

import '../../helpers/fake_device_approvals_server.dart';

/// Approving a new device (3.0), against a stand-in for
/// ZestSSH Cloud (test/helpers/fake_device_approvals_server.dart).

SyncHandover _handover() => SyncHandover(
      dek: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      verificationHash: Uint8List.fromList(utf8.encode('verification')),
      argon2Params: const {'version': 2, 'memory': 131072, 'iterations': 3, 'parallelism': 4},
      salt: Uint8List.fromList(List<int>.filled(32, 7)),
    );

Future<void> _noWait(Duration _) async {}

void main() {
  test('the commitment is the bytes the server checks (its own test vectors)', () {
    expect(approvalHex(approvalCommitment(List.filled(32, 0x11), List.filled(32, 0x22))),
        'e9d8667debf99012f0318a59bc5679bfd49e7418234b72d43ee00f40dde723f2');
    expect(
        approvalHex(approvalCommitment(
            List<int>.generate(32, (i) => i + 1), List<int>.generate(32, (i) => 0xff - i))),
        '01a71a956a7129622d067112d752b3027f657023918a442572c45d51f6a68933');
  });

  test('base64url without padding, one spelling only', () {
    final bytes = List<int>.generate(32, (i) => 250 - i);
    final text = b64url(bytes);
    expect(text.contains('='), isFalse);
    expect(fromB64url(text), bytes);
    expect(fromB64url('$text='), isNull, reason: 'padding');
    expect(fromB64url(base64.encode(bytes)), isNull, reason: 'standard base64 has + and /');
    expect(fromB64url(12), isNull);
  });

  test('two devices of one account: the same three words, then the key arrives and opens', () async {
    final server = FakeApprovalServer();
    final ask = await ApprovalAsk.start(server.device('new-laptop'), name: 'Laptop');
    // The approving device finds it among the open requests.
    final open = await server.device('desktop').list();
    expect(open.single.role, 'open');
    expect(open.single.name, 'Laptop');
    final give = await ApprovalGive.answer(server.device('desktop'), ask.id);
    expect(give.name, 'Laptop');

    final newWords = await ask.awaitApprover(wait: _noWait);
    final approverWords = await give.awaitReveal(wait: _noWait);
    expect(newWords, hasLength(3));
    expect(approverWords, newWords, reason: 'both screens show the same words');

    await give.send(_handover());
    final got = await ask.awaitHandover(wait: _noWait);
    expect(got.dek, _handover().dek);
    expect(got.verificationHash, _handover().verificationHash);
    expect(got.argon2Params, _handover().argon2Params);
    expect(got.salt, _handover().salt);
    expect(server.rows, isEmpty, reason: 'collected once, then gone');
    await expectLater(ask.api.receive(ask.id), throwsA(isA<DeviceApprovalException>().having((e) => e.ended, 'ended', isTrue)));
  });

  test('a server that swaps the reveal is caught: the approving device checks the commitment it read', () async {
    final server = FakeApprovalServer();
    final ask = await ApprovalAsk.start(server.device('new'), name: 'Laptop');
    final give = await ApprovalGive.answer(server.device('desktop'), ask.id);
    await ask.awaitApprover(wait: _noWait);
    server.swapReveal = (Uint8List.fromList(List.filled(32, 9)), Uint8List.fromList(List.filled(32, 8)));
    await expectLater(give.awaitReveal(wait: _noWait),
        throwsA(isA<DeviceApprovalException>().having((e) => e.mismatch, 'mismatch', isTrue)));
    expect(server.rows, isEmpty, reason: 'the approving device ended it');
  });

  test('a server that swaps the commitment too is caught: the approving device keeps the one it answered', () async {
    final server = FakeApprovalServer();
    final ask = await ApprovalAsk.start(server.device('new'), name: 'Laptop');
    final give = await ApprovalGive.answer(server.device('desktop'), ask.id);
    await ask.awaitApprover(wait: _noWait);
    final key = Uint8List.fromList(List.filled(32, 9));
    final nonce = Uint8List.fromList(List.filled(32, 8));
    server
      ..swapReveal = (key, nonce)
      ..swapCommitment = approvalCommitment(key, nonce);
    await expectLater(give.awaitReveal(wait: _noWait),
        throwsA(isA<DeviceApprovalException>().having((e) => e.mismatch, 'mismatch', isTrue)));
  });

  test('a server playing both sides cannot make the words match', () async {
    // The server answers the new device itself, and asks the real approver
    // with a request of its own: each side's words come from different
    // keys and nonces.
    final server = FakeApprovalServer();
    final ask = await ApprovalAsk.start(server.device('new'), name: 'Laptop');
    final fakeApprover = await ApprovalGive.answer(server.device('server-as-approver'), ask.id);
    final fakeAsk = await ApprovalAsk.start(server.device('server-as-new'), name: 'Laptop');
    final give = await ApprovalGive.answer(server.device('desktop'), fakeAsk.id);
    final shownOnNew = await ask.awaitApprover(wait: _noWait);
    await fakeApprover.awaitReveal(wait: _noWait);
    await fakeAsk.awaitApprover(wait: _noWait);
    final shownOnApprover = await give.awaitReveal(wait: _noWait);
    expect(shownOnApprover, isNot(shownOnNew));
  });

  test('a sealed key changed on the way does not open', () async {
    final server = FakeApprovalServer();
    final ask = await ApprovalAsk.start(server.device('new'), name: 'Laptop');
    final give = await ApprovalGive.answer(server.device('desktop'), ask.id);
    await ask.awaitApprover(wait: _noWait);
    await give.awaitReveal(wait: _noWait);
    await give.send(_handover());
    final row = server.rows[ask.id]!;
    row.sealed![row.sealed!.length - 1] ^= 0x01;
    await expectLater(ask.awaitHandover(wait: _noWait),
        throwsA(isA<DeviceApprovalException>().having((e) => e.code, 'code', 'bad-seal')));
  });

  test('steps out of order, and a request that ended, say so', () async {
    final server = FakeApprovalServer();
    final ask = await ApprovalAsk.start(server.device('new'), name: 'Laptop');
    await expectLater(ask.awaitHandover(wait: _noWait), throwsA(isA<StateError>()));
    // The new device cannot answer its own request.
    await expectLater(ApprovalGive.answer(server.device('new'), ask.id),
        throwsA(isA<DeviceApprovalException>()));
    await ask.cancel();
    await expectLater(ApprovalGive.answer(server.device('desktop'), ask.id),
        throwsA(isA<DeviceApprovalException>().having((e) => e.ended, 'ended', isTrue)));
  });

  test('a handover reads back only in its own shape', () {
    final bytes = _handover().toBytes();
    expect(SyncHandover.fromBytes(bytes).dek, _handover().dek);
    // Each of these is the good one with one thing wrong.
    Map<String, dynamic> good() => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    for (final bad in [
      utf8.encode('not json'),
      utf8.encode(jsonEncode(good()..['v'] = 2)),
      utf8.encode(jsonEncode(good()..['dek'] = b64url(List.filled(16, 1)))),
      utf8.encode(jsonEncode(good()..['dek'] = b64url(List.filled(33, 1)))),
      utf8.encode(jsonEncode(good()..remove('verification_hash'))),
      utf8.encode(jsonEncode(good()..['salt'] = '')),
      utf8.encode(jsonEncode(good()..['argon2_params'] = 'fast')),
    ]) {
      expect(() => SyncHandover.fromBytes(bad), throwsA(isA<DeviceApprovalException>()));
    }
  });
}
