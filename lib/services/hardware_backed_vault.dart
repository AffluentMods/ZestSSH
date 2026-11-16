import 'dart:typed_data';

/// The device-hardware layer for the encrypting vault: a 256-bit key held by
/// secure hardware (Android Keystore / iOS Secure Enclave on mobile, the TPM on
/// Windows, the Secure Enclave on a Mac) that the vault uses to wrap its DB-key blob. Because the backing key
/// is bound to THIS device's hardware, an extracted copy of the files is useless
/// on any other machine.
///
/// [HardwareVaultService] (mobile, biometric_storage),
/// [WindowsTpmVaultService] (Windows, CNG/TPM) and
/// [MacSecureEnclaveVaultService] (macOS, CryptoKit) implement this; the rest
/// of the vault treats them identically through this interface.
abstract class HardwareBackedVault {
  /// Whether this device can back a key with secure hardware right now.
  Future<bool> isAvailable();

  /// Generate a fresh 256-bit key, store it hardware-protected, and return it.
  Future<Uint8List> generateAndStore();

  /// Recover the stored key (may prompt for device auth on some platforms).
  Future<Uint8List> read();

  /// Remove the stored key.
  Future<void> delete();
}

/// Fallback for platforms with no hardware layer (Linux today): the toggle
/// simply never appears because [isAvailable] is false.
class UnsupportedHardwareVault implements HardwareBackedVault {
  const UnsupportedHardwareVault();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<Uint8List> generateAndStore() =>
      throw UnsupportedError('No hardware-backed key store on this platform');

  @override
  Future<Uint8List> read() =>
      throw UnsupportedError('No hardware-backed key store on this platform');

  @override
  Future<void> delete() async {}
}
