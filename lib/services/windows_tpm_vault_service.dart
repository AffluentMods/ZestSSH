import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/services/hardware_backed_vault.dart';

/// Windows TPM binding for the encrypting vault, via CNG's Microsoft Platform
/// Crypto Provider (dart:ffi -> ncrypt.dll).
///
/// A non-exportable RSA key is created inside the TPM. [generateAndStore]
/// generates a random 256-bit vault hardware key, seals it with that TPM key
/// (RSA-OAEP, the private op runs inside the TPM), and stores only the
/// ciphertext in secure storage (DPAPI). [read] TPM-decrypts it back. Because
/// the TPM key cannot leave the chip, the stored ciphertext is inert on any
/// other machine: copying the whole app-data folder to another PC cannot
/// recover the key, so the vault stays locked. This is the desktop counterpart
/// to the mobile Secure-Enclave binding, and it closes the offline-brute gap
/// (an attacker cannot even begin guessing the PIN without this TPM).
///
/// The round-trip against the real Platform Crypto Provider is exercised by
/// tool/tpm_probe.dart; the pure-Dart crypto wiring is covered by the vault
/// tests. The TPM path itself only runs on a Windows device with a TPM.
class WindowsTpmVaultService implements HardwareBackedVault {
  WindowsTpmVaultService(this._secure);

  final FlutterSecureStorage _secure;

  /// Secure-storage id for the TPM-sealed 256-bit key (ciphertext only).
  static const String _sealedKeyId = 'vault_tpm_sealed_key';

  /// The persistent TPM key's name inside the Platform Crypto Provider.
  static const String _tpmKeyName = 'ZestSSHVaultTpmKey';

  // ── CNG constants ──────────────────────────────────────────────────
  static const _msPlatformCryptoProvider = 'Microsoft Platform Crypto Provider';
  static const _rsaAlgorithm = 'RSA';
  static const _lengthProperty = 'Length';
  static const _sha256Algorithm = 'SHA256';
  static const _ncryptPadOaepFlag = 0x00000004;
  static const _errorSuccess = 0;

  @override
  Future<bool> isAvailable() async {
    final arena = Arena();
    try {
      final phProv = arena<IntPtr>();
      final st = _openProvider(phProv,
          _msPlatformCryptoProvider.toNativeUtf16(allocator: arena), 0);
      if (st == _errorSuccess) {
        _freeObject(phProv.value);
        return true;
      }
      return false;
    } catch (_) {
      return false; // ncrypt.dll missing / not Windows
    } finally {
      arena.releaseAll();
    }
  }

  @override
  Future<Uint8List> generateAndStore() async {
    final rng = Random.secure();
    final key =
        Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
    final sealed = _tpmSeal(key);
    await _secure.write(key: _sealedKeyId, value: base64Encode(sealed));
    return key;
  }

  @override
  Future<Uint8List> read() async {
    final raw = await _secure.read(key: _sealedKeyId);
    if (raw == null) {
      throw StateError('TPM-sealed vault key not found');
    }
    return _tpmUnseal(base64Decode(raw));
  }

  @override
  Future<void> delete() async {
    // Removing the sealed ciphertext is enough to unbind. The persistent TPM
    // key is left in place; it is reused (and overwritten) on the next enable.
    await _secure.delete(key: _sealedKeyId);
  }

  // ── TPM seal / unseal ──────────────────────────────────────────────

  Uint8List _tpmSeal(Uint8List plaintext) =>
      _tpmCrypt(plaintext, decrypt: false);

  Uint8List _tpmUnseal(Uint8List ciphertext) =>
      _tpmCrypt(ciphertext, decrypt: true);

  /// Runs one NCryptEncrypt / NCryptDecrypt against the persistent TPM key,
  /// opening the provider + key (creating the key on first use) each call.
  Uint8List _tpmCrypt(Uint8List input, {required bool decrypt}) {
    final arena = Arena();
    int hProv = 0, hKey = 0;
    try {
      final phProv = arena<IntPtr>();
      _check(
          _openProvider(phProv,
              _msPlatformCryptoProvider.toNativeUtf16(allocator: arena), 0),
          'open provider');
      hProv = phProv.value;
      hKey = _openOrCreateKey(hProv, arena);

      final pad = arena<_OaepPaddingInfo>();
      pad.ref.pszAlgId = _sha256Algorithm.toNativeUtf16(allocator: arena);
      pad.ref.pbLabel = nullptr;
      pad.ref.cbLabel = 0;

      final pIn = arena<Uint8>(input.length);
      pIn.asTypedList(input.length).setAll(0, input);
      final op = decrypt ? _decrypt : _encrypt;

      final pcb = arena<Uint32>();
      _check(
          op(hKey, pIn, input.length, pad.cast<Void>(), nullptr, 0, pcb,
              _ncryptPadOaepFlag),
          decrypt ? 'decrypt size' : 'encrypt size');
      final outLen = pcb.value;
      final pOut = arena<Uint8>(outLen);
      _check(
          op(hKey, pIn, input.length, pad.cast<Void>(), pOut, outLen, pcb,
              _ncryptPadOaepFlag),
          decrypt ? 'decrypt' : 'encrypt');
      return Uint8List.fromList(pOut.asTypedList(pcb.value));
    } finally {
      if (hKey != 0) _freeObject(hKey);
      if (hProv != 0) _freeObject(hProv);
      arena.releaseAll();
    }
  }

  int _openOrCreateKey(int hProv, Arena arena) {
    final phKey = arena<IntPtr>();
    final open =
        _openKey(hProv, phKey, _tpmKeyName.toNativeUtf16(allocator: arena), 0, 0);
    if (open == _errorSuccess) return phKey.value;
    // Not found: create the persistent RSA-2048 key inside the TPM. If
    // set-property or finalize fails AFTER the handle exists, free it before
    // rethrowing - otherwise the created CNG key handle leaks (the caller's
    // finally never sees it because the assignment never completed).
    _check(
        _createKey(hProv, phKey, _rsaAlgorithm.toNativeUtf16(allocator: arena),
            _tpmKeyName.toNativeUtf16(allocator: arena), 0, 0),
        'create key');
    final hKey = phKey.value;
    try {
      final lenBuf = arena<Uint32>()..value = 2048;
      _check(
          _setProperty(hKey, _lengthProperty.toNativeUtf16(allocator: arena),
              lenBuf.cast<Uint8>(), 4, 0),
          'set length');
      _check(_finalizeKey(hKey, 0), 'finalize key');
      return hKey;
    } catch (_) {
      _freeObject(hKey);
      rethrow;
    }
  }

  static void _check(int status, String where) {
    if (status != _errorSuccess) {
      throw StateError(
          'TPM $where failed: 0x${(status & 0xFFFFFFFF).toRadixString(16)}');
    }
  }
}

// ── ncrypt.dll bindings ────────────────────────────────────────────────
final class _OaepPaddingInfo extends Struct {
  external Pointer<Utf16> pszAlgId;
  external Pointer<Uint8> pbLabel;
  @Uint32()
  external int cbLabel;
}

/// Load ncrypt.dll from the ABSOLUTE System32 path, never by bare name.
/// ncrypt.dll is not a Windows KnownDLL, so a bare-name load resolves through
/// the DLL search order whose first entry is the app's own (user-writable,
/// per-user Inno install) directory. A hostile ncrypt.dll dropped there would
/// otherwise be mapped in and could intercept the TPM seal/unseal path and the
/// vault key in cleartext (CWE-427). An absolute system path removes the app
/// directory from the resolution entirely.
final _ncrypt = _openNcrypt();

DynamicLibrary _openNcrypt() {
  final sysRoot = Platform.environment['SystemRoot'] ??
      Platform.environment['windir'] ??
      r'C:\Windows';
  return DynamicLibrary.open('$sysRoot\\System32\\ncrypt.dll');
}

final _openProvider = _ncrypt.lookupFunction<
    Int32 Function(Pointer<IntPtr>, Pointer<Utf16>, Uint32),
    int Function(Pointer<IntPtr>, Pointer<Utf16>, int)>(
    'NCryptOpenStorageProvider');

final _openKey = _ncrypt.lookupFunction<
    Int32 Function(IntPtr, Pointer<IntPtr>, Pointer<Utf16>, Uint32, Uint32),
    int Function(int, Pointer<IntPtr>, Pointer<Utf16>, int, int)>(
    'NCryptOpenKey');

final _createKey = _ncrypt.lookupFunction<
    Int32 Function(IntPtr, Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>,
        Uint32, Uint32),
    int Function(
        int, Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, int, int)>(
    'NCryptCreatePersistedKey');

final _setProperty = _ncrypt.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint8>, Uint32, Uint32),
    int Function(int, Pointer<Utf16>, Pointer<Uint8>, int, int)>(
    'NCryptSetProperty');

final _finalizeKey = _ncrypt.lookupFunction<Int32 Function(IntPtr, Uint32),
    int Function(int, int)>('NCryptFinalizeKey');

final _encrypt = _ncrypt.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Void>, Pointer<Uint8>,
        Uint32, Pointer<Uint32>, Uint32),
    int Function(int, Pointer<Uint8>, int, Pointer<Void>, Pointer<Uint8>, int,
        Pointer<Uint32>, int)>('NCryptEncrypt');

final _decrypt = _ncrypt.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Void>, Pointer<Uint8>,
        Uint32, Pointer<Uint32>, Uint32),
    int Function(int, Pointer<Uint8>, int, Pointer<Void>, Pointer<Uint8>, int,
        Pointer<Uint32>, int)>('NCryptDecrypt');

final _freeObject = _ncrypt.lookupFunction<Int32 Function(IntPtr),
    int Function(int)>('NCryptFreeObject');
