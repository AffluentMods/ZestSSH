import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/services/hardware_backed_vault.dart';

/// The Mac's Secure Enclave for the encrypting vault's hardware layer (4.0),
/// through the channel zestssh/secure_enclave
/// (macos/Runner/SecureEnclaveChannel.swift, which says how a key is sealed).
///
/// As [WindowsTpmVaultService] does with the TPM: [generateAndStore] makes a
/// random 256-bit key, has it sealed to a key that was made inside the
/// enclave and cannot leave it, and keeps only the sealed bytes in secure
/// storage; [read] has the enclave open them. Copied to another Mac (a
/// Time Machine restore, Migration Assistant, a stolen disk image) the sealed
/// bytes open nothing, so the vault there stays locked: the way across is to
/// unbind on this Mac first, or to set the other Mac up from sync or a backup,
/// as on Windows.
///
/// Until 4.0 a Mac had no hardware layer ([UnsupportedHardwareVault]), and
/// the toggle did not appear there. A Mac with no enclave (an Intel Mac
/// without a T2 chip) still has none: [isAvailable] is false.
class MacSecureEnclaveVaultService implements HardwareBackedVault {
  MacSecureEnclaveVaultService(this._secure, {MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'zestssh/secure_enclave';

  final FlutterSecureStorage _secure;
  final MethodChannel _channel;

  /// Secure-storage id of what the enclave sealed: the enclave key as it
  /// hands it out, the one-time public key and the sealed box, as JSON.
  static const sealedKeyId = 'vault_secure_enclave_sealed_key';

  @override
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      // A build whose runner has no such channel (an older runner, a test).
      return false;
    }
  }

  @override
  Future<Uint8List> generateAndStore() async {
    final rng = Random.secure();
    final key = Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
    final sealed = await _channel.invokeMapMethod<String, Object?>('seal', {'key': key});
    final parts = _SealedKey.of(sealed);
    if (parts == null) throw StateError('The Secure Enclave gave back no sealed key');
    await _secure.write(key: sealedKeyId, value: parts.toJson());
    return key;
  }

  @override
  Future<Uint8List> read() async {
    final raw = await _secure.read(key: sealedKeyId);
    if (raw == null) throw StateError('Secure Enclave sealed vault key not found');
    final parts = _SealedKey.parse(raw);
    if (parts == null) throw StateError('Secure Enclave sealed vault key is damaged');
    final key = await _channel.invokeMethod<Uint8List>('open', {
      'enclaveKey': parts.enclaveKey,
      'oneTimeKey': parts.oneTimeKey,
      'sealed': parts.sealed,
    });
    if (key == null || key.length != 32) throw StateError('The Secure Enclave opened no vault key');
    return key;
  }

  @override
  Future<void> delete() async {
    // Removing the sealed bytes is enough to unbind: the enclave key lives
    // only inside them (the enclave keeps no list of the keys it made).
    await _secure.delete(key: sealedKeyId);
  }
}

/// What is kept of one sealing.
class _SealedKey {
  const _SealedKey(this.enclaveKey, this.oneTimeKey, this.sealed);

  final Uint8List enclaveKey;
  final Uint8List oneTimeKey;
  final Uint8List sealed;

  /// From the channel's answer, or null where a part is missing or empty.
  static _SealedKey? of(Map<String, Object?>? answer) {
    final a = answer?['enclaveKey'], b = answer?['oneTimeKey'], c = answer?['sealed'];
    if (a is! Uint8List || b is! Uint8List || c is! Uint8List) return null;
    if (a.isEmpty || b.isEmpty || c.isEmpty) return null;
    return _SealedKey(a, b, c);
  }

  /// From what [toJson] wrote, or null where it is not that.
  static _SealedKey? parse(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final a = map['enclaveKey'], b = map['oneTimeKey'], c = map['sealed'];
      if (a is! String || b is! String || c is! String) return null;
      final parts = _SealedKey(base64Decode(a), base64Decode(b), base64Decode(c));
      if (parts.enclaveKey.isEmpty || parts.oneTimeKey.isEmpty || parts.sealed.isEmpty) return null;
      return parts;
    } on FormatException {
      return null;
    }
  }

  String toJson() => jsonEncode({
        'v': 1,
        'enclaveKey': base64Encode(enclaveKey),
        'oneTimeKey': base64Encode(oneTimeKey),
        'sealed': base64Encode(sealed),
      });
}
