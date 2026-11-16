import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/account/device_approvals.dart';

/// Known answers for approving a new device (3.0), worked
/// out apart from the app with Python's cryptography package (X25519,
/// HKDF-SHA256, AES-256-GCM) and the BIP-39 English list: the commitment,
/// the three words, the seal key from either side, and the sealed layout
/// (nonce, tag, ciphertext) with the request named in the AAD. Changing any
/// input or label the steps bind breaks these.
List<int> _hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
String _toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final newSeed = List<int>.generate(32, (i) => i + 1);
  final approverSeed = List<int>.generate(32, (i) => i + 101);
  final newNonce = List<int>.filled(32, 0x22);
  final approverNonce = List<int>.filled(32, 0x33);
  const requestId = 'req-kat-1';

  const newPublic = '07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c';
  const approverPublic = '5714769d116bf76436ae74bc793d2c30ad1903c59ac5273805c7e2698b410c36';
  const commitment = 'fd48c29165dd6df6da2792d05b74b33e862cec1055347820902eeb7fd86515ca';
  const words = ['beach', 'lunar', 'sand'];
  const sealKey = '9789707aabd8c911dfdb8ac563f8d0609c541d92dde184292e50ab21752d0930';
  const sealed = '000102030405060708090a0bd820691033a3e5377c262088f745f1c047bd2f6e311819dc4c19a937';

  test('the one-time public keys from their seeds', () async {
    Future<String> pub(List<int> seed) async =>
        _toHex((await (await X25519().newKeyPairFromSeed(seed)).extractPublicKey()).bytes);
    expect(await pub(newSeed), newPublic);
    expect(await pub(approverSeed), approverPublic);
  });

  test('the commitment and the three words', () {
    expect(_toHex(approvalCommitment(_hex(newPublic), newNonce)), commitment);
    expect(
      approvalWords(
        commitment: _hex(commitment),
        approverKey: _hex(approverPublic),
        approverNonce: approverNonce,
        newKey: _hex(newPublic),
        newNonce: newNonce,
      ),
      words,
    );
  });

  test('the seal key, the same from either side', () async {
    final fromNew = await approvalSealKeyForTest(
      seed: newSeed,
      theirs: _hex(approverPublic),
      commitment: _hex(commitment),
      requestId: requestId,
      approverKey: _hex(approverPublic),
      newKey: _hex(newPublic),
    );
    final fromApprover = await approvalSealKeyForTest(
      seed: approverSeed,
      theirs: _hex(newPublic),
      commitment: _hex(commitment),
      requestId: requestId,
      approverKey: _hex(approverPublic),
      newKey: _hex(newPublic),
    );
    expect(_toHex(fromNew), sealKey);
    expect(_toHex(fromApprover), sealKey);
  });

  test('a key of low order is refused: no all-zero secret to seal with', () async {
    await expectLater(
      approvalSealKeyForTest(
        seed: newSeed,
        theirs: List<int>.filled(32, 0),
        commitment: _hex(commitment),
        requestId: requestId,
        approverKey: List<int>.filled(32, 0),
        newKey: _hex(newPublic),
      ),
      throwsA(isA<DeviceApprovalException>().having((e) => e.code, 'code', 'bad-key')),
    );
  });

  test('what was sealed opens for this request only', () async {
    final opened = await openHandoverForTest(
      newSeed: newSeed,
      approverKey: _hex(approverPublic),
      commitment: _hex(commitment),
      requestId: requestId,
      sealed: _hex(sealed),
    );
    expect(utf8.decode(opened), '{"kat":true}');
    await expectLater(
      openHandoverForTest(
        newSeed: newSeed,
        approverKey: _hex(approverPublic),
        commitment: _hex(commitment),
        requestId: 'req-kat-2',
        sealed: _hex(sealed),
      ),
      throwsA(isA<DeviceApprovalException>().having((e) => e.code, 'code', 'bad-seal')),
    );
  });
}
