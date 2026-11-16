import 'dart:convert';

import 'package:biometric_storage/biometric_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/hardware_vault_service.dart';

/// Stands in for the keychain / Keystore: one value per name, and a record of
/// every call in order.
class _FakeStore implements HardwareKeyStore {
  final items = <String, String>{};
  final writtenWith = <String, StorageFileInitOptions>{};
  final calls = <String>[];
  bool failWrites = false;
  CanAuthenticateResponse auth = CanAuthenticateResponse.success;
  bool authThrows = false;

  @override
  Future<CanAuthenticateResponse> canAuthenticate() async {
    if (authThrows) throw Exception('no hardware');
    return auth;
  }

  @override
  Future<String?> read(String name, StorageFileInitOptions options) async {
    calls.add('read $name');
    return items[name];
  }

  @override
  Future<void> write(
      String name, StorageFileInitOptions options, String value) async {
    calls.add('write $name');
    if (failWrites) throw Exception('keychain refused');
    items[name] = value;
    writtenWith[name] = options;
  }

  @override
  Future<void> delete(String name, StorageFileInitOptions options) async {
    calls.add('delete $name');
    items.remove(name);
  }
}

const _legacy = HardwareVaultService.legacyStorageName;
const _ios = HardwareVaultService.iosStorageName;

void main() {
  group('iOS options', () {
    test('the key accepts Face ID, Touch ID or the passcode (userPresence)',
        () {
      final json = HardwareVaultService.iosOptions.toJson();
      expect(json['darwinBiometricOnly'], isFalse);
      expect(json['authenticationRequired'], isTrue);
    });

    test('a pre-2.2.1 key is still opened with the query it was written under',
        () {
      // biometric_storage's default, which stored it under biometryCurrentSet.
      expect(HardwareVaultService.legacyIosOptions.toJson()['darwinBiometricOnly'],
          isTrue);
    });

    test('Android options are unchanged, so existing Android keys open', () {
      final json = HardwareVaultService.androidOptions.toJson();
      expect(json['androidBiometricOnly'], isFalse);
      expect(json['authenticationValidityDurationSeconds'], 10);
      expect(json['authenticationRequired'], isTrue);
    });
  });

  group('iOS', () {
    test('a new key is stored under the new name only', () async {
      final store = _FakeStore();
      final hw = HardwareVaultService(store: store, isIOS: true);
      final key = await hw.generateAndStore();

      expect(store.items.keys, [_ios]);
      expect(store.writtenWith[_ios], same(HardwareVaultService.iosOptions));
      expect(await hw.read(), key);
    });

    test('a pre-2.2.1 key is moved to the new name on first unlock', () async {
      final store = _FakeStore();
      final key = List<int>.generate(32, (i) => i);
      store.items[_legacy] = base64Encode(key);
      final hw = HardwareVaultService(store: store, isIOS: true);

      expect(await hw.read(), key);
      expect(store.items, {_ios: base64Encode(key)});
      expect(store.writtenWith[_ios], same(HardwareVaultService.iosOptions));
      // The new copy exists before the old one goes.
      expect(store.calls.indexOf('write $_ios'),
          lessThan(store.calls.indexOf('delete $_legacy')));

      // Later unlocks read the new key and touch nothing else.
      store.calls.clear();
      expect(await hw.read(), key);
      expect(store.calls, ['read $_ios']);
    });

    test('a failed move still unlocks and keeps the old key for next time',
        () async {
      final store = _FakeStore()..failWrites = true;
      final key = List<int>.generate(32, (i) => 255 - i);
      store.items[_legacy] = base64Encode(key);
      final hw = HardwareVaultService(store: store, isIOS: true);

      expect(await hw.read(), key);
      expect(store.items, {_legacy: base64Encode(key)});
      expect(store.calls, isNot(contains('delete $_legacy')));
    });

    test('no key under either name is an error', () async {
      final hw = HardwareVaultService(store: _FakeStore(), isIOS: true);
      expect(hw.read(), throwsStateError);
    });

    test('turning binding off removes the key under both names', () async {
      final store = _FakeStore()
        ..items[_ios] = 'a'
        ..items[_legacy] = 'b';
      await HardwareVaultService(store: store, isIOS: true).delete();
      expect(store.items, isEmpty);
    });

    test('a new key replaces a leftover old one', () async {
      final store = _FakeStore()..items[_legacy] = 'old';
      await HardwareVaultService(store: store, isIOS: true).generateAndStore();
      expect(store.items.keys, [_ios]);
    });
  });

  group('Android', () {
    test('keeps its original name and options', () async {
      final store = _FakeStore();
      final hw = HardwareVaultService(store: store, isIOS: false);
      final key = await hw.generateAndStore();

      expect(store.items.keys, [_legacy]);
      expect(store.writtenWith[_legacy],
          same(HardwareVaultService.androidOptions));
      expect(await hw.read(), key);
      await hw.delete();
      expect(store.items, isEmpty);
      expect(store.calls.where((c) => c.endsWith(_ios)), isEmpty);
    });

    test('a missing key is an error', () async {
      final hw = HardwareVaultService(store: _FakeStore(), isIOS: false);
      expect(hw.read(), throwsStateError);
    });
  });

  group('isAvailable', () {
    test('a screen lock without enrolled biometrics is enough', () async {
      final store = _FakeStore()
        ..auth = CanAuthenticateResponse.errorNoBiometricEnrolled;
      expect(await HardwareVaultService(store: store, isIOS: true).isAvailable(),
          isTrue);
    });

    test('no screen lock, or no hardware, is unavailable', () async {
      final noLock = _FakeStore()
        ..auth = CanAuthenticateResponse.errorPasscodeNotSet;
      expect(
          await HardwareVaultService(store: noLock, isIOS: true).isAvailable(),
          isFalse);
      final broken = _FakeStore()..authThrows = true;
      expect(
          await HardwareVaultService(store: broken, isIOS: false).isAvailable(),
          isFalse);
    });
  });
}
