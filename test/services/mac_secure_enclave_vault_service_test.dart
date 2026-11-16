import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/mac_secure_enclave_vault_service.dart';

/// A Mac's Secure Enclave, played: it seals under a secret of its own that
/// never crosses the channel, as the real one's key never leaves the chip.
/// What it hands back opens only on the enclave that made it.
class _Enclave {
  _Enclave(this._secret, {this.present = true});

  final int _secret;
  final bool present;
  final calls = <String>[];

  Uint8List _mix(Uint8List bytes) => Uint8List.fromList([for (final b in bytes) b ^ _secret]);

  Future<Object?> answer(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'isAvailable':
        return present;
      case 'seal':
        final key = (call.arguments as Map)['key'] as Uint8List;
        return {
          'enclaveKey': Uint8List.fromList([_secret + 1, 9, 9, 9]),
          'oneTimeKey': Uint8List.fromList(List.filled(65, 4)),
          'sealed': _mix(key),
        };
      case 'open':
        final arguments = call.arguments as Map;
        final enclaveKey = arguments['enclaveKey'] as Uint8List;
        if (enclaveKey.first != _secret + 1) {
          throw PlatformException(code: 'not-this-mac', message: 'open: another enclave made this');
        }
        return _mix(arguments['sealed'] as Uint8List);
    }
    throw MissingPluginException();
  }
}

/// Hardware-backed encryption on a Mac (4.0): the vault's hardware key is
/// sealed by the Secure Enclave and only what the enclave hands back is
/// kept, as the TPM does it on Windows. Until 4.0 a Mac had no such layer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(MacSecureEnclaveVaultService.channelName);
  const storage = FlutterSecureStorage();

  void play(_Enclave? enclave) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, enclave?.answer);

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => play(null));

  test('a Mac with an enclave has the layer; one without, or a runner with no such channel, has none', () async {
    final service = MacSecureEnclaveVaultService(storage);
    play(_Enclave(7));
    expect(await service.isAvailable(), isTrue);
    play(_Enclave(7, present: false));
    expect(await service.isAvailable(), isFalse);
    play(null);
    expect(await service.isAvailable(), isFalse, reason: 'no channel: said as none, not thrown');
  });

  test('the key that is made comes back from the enclave, and only what the enclave sealed is kept', () async {
    final enclave = _Enclave(7);
    play(enclave);
    final service = MacSecureEnclaveVaultService(storage);
    final key = await service.generateAndStore();
    expect(key, hasLength(32));

    final kept = await storage.read(key: MacSecureEnclaveVaultService.sealedKeyId);
    expect(kept, isNotNull);
    expect(kept, isNot(contains(base64Encode(key))), reason: 'the key itself is never kept');
    final parts = jsonDecode(kept!) as Map<String, dynamic>;
    expect(parts.keys, containsAll(['v', 'enclaveKey', 'oneTimeKey', 'sealed']));
    expect(await storage.readAll(), hasLength(1));

    expect(await service.read(), key);
    expect(enclave.calls, ['seal', 'open']);
    // A second binding makes another key.
    expect(await service.generateAndStore(), isNot(key));
  });

  test('what one Mac sealed opens nothing on another Mac', () async {
    play(_Enclave(7));
    final service = MacSecureEnclaveVaultService(storage);
    await service.generateAndStore();
    // The same kept bytes, as a restore or Migration Assistant carries them.
    play(_Enclave(8));
    await expectLater(
      service.read(),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'not-this-mac')),
    );
  });

  test('unbinding removes what was kept, and there is then nothing to read', () async {
    play(_Enclave(7));
    final service = MacSecureEnclaveVaultService(storage);
    await service.generateAndStore();
    await service.delete();
    expect(await storage.readAll(), isEmpty);
    await expectLater(service.read(), throwsStateError);
  });

  test('kept bytes that are not what was written are said as damaged, and the enclave is not asked', () async {
    final enclave = _Enclave(7);
    play(enclave);
    final service = MacSecureEnclaveVaultService(storage);
    for (final damaged in ['', 'not json', '[]', '{"v":1}', '{"enclaveKey":"AA==","oneTimeKey":"AA==","sealed":""}', '{"enclaveKey":"%%","oneTimeKey":"AA==","sealed":"AA=="}']) {
      await storage.write(key: MacSecureEnclaveVaultService.sealedKeyId, value: damaged);
      await expectLater(service.read(), throwsStateError, reason: damaged);
    }
    expect(enclave.calls, isEmpty);
  });

  test('an enclave that answers no key, or one of the wrong length, is no key', () async {
    final service = MacSecureEnclaveVaultService(storage);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'seal') return {'enclaveKey': Uint8List(0), 'oneTimeKey': Uint8List(65), 'sealed': Uint8List(48)};
      return Uint8List(16);
    });
    await expectLater(service.generateAndStore(), throwsStateError);
    expect(await storage.readAll(), isEmpty, reason: 'nothing is kept of a sealing that gave no key back');
    await storage.write(
        key: MacSecureEnclaveVaultService.sealedKeyId,
        value: jsonEncode({'v': 1, 'enclaveKey': 'AAEC', 'oneTimeKey': 'AAEC', 'sealed': 'AAEC'}));
    await expectLater(service.read(), throwsStateError);
  });

  group('the Mac runner', () {
    // As checked out on any machine (Windows' checkouts end lines with CR LF).
    String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');
    final swift = read('macos/Runner/SecureEnclaveChannel.swift');

    test('answers on this channel, with these three calls', () {
      expect(swift, contains('static let name = "${MacSecureEnclaveVaultService.channelName}"'));
      for (final method in ['case "isAvailable":', 'case "seal":', 'case "open":']) {
        expect(swift, contains(method));
      }
      for (final part in ['"enclaveKey"', '"oneTimeKey"', '"sealed"', '"key"']) {
        expect(swift, contains(part));
      }
      expect(swift, contains('code: "not-this-mac"'));
    });

    test('seals to a key made in the enclave, with a one-time key, HKDF and AES-GCM', () {
      expect(swift, contains('SecureEnclave.isAvailable'));
      expect('SecureEnclave.P256.KeyAgreement.PrivateKey('.allMatches(swift).length, greaterThanOrEqualTo(3));
      expect(swift, contains('SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: enclaveKey)'));
      expect(swift, contains('sharedSecretFromKeyAgreement(with:'));
      expect(swift, contains('hkdfDerivedSymmetricKey('));
      expect(swift, contains('AES.GCM.seal(key, using: wrapping)'));
      expect(swift, contains('AES.GCM.open('));
      expect(swift, contains('key.count == 32'), reason: 'only a 256-bit key is sealed');
    });

    test('is compiled into the app and started with its window', () {
      final project = read('macos/Runner.xcodeproj/project.pbxproj');
      expect('SecureEnclaveChannel.swift in Sources'.allMatches(project).length, 2);
      expect(read('macos/Runner/MainFlutterWindow.swift'), contains('SecureEnclaveChannel.register(with:'));
    });
  });
}
