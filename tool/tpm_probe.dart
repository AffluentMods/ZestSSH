// Standalone probe: prove a seal -> unseal round-trip through the Windows TPM
// via CNG's Microsoft Platform Crypto Provider, using dart:ffi to ncrypt.dll.
// Run: dart run tool/tpm_probe.dart
//
// This validates the exact calls WindowsTpmVaultService will make, on this
// machine's real TPM, before any of it goes near the vault.
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ── CNG constants ────────────────────────────────────────────────────
const _msPlatformCryptoProvider = 'Microsoft Platform Crypto Provider';
const _rsaAlgorithm = 'RSA';
const _lengthProperty = 'Length';
const _sha256Algorithm = 'SHA256';
const _ncryptPadOaepFlag = 0x00000004;
const _errorSuccess = 0;
// 0x80090016 as a signed 32-bit int (key not found on NCryptOpenKey).
const _nteBadKeyset = -2146893802; // 0x80090016

final class _OaepPaddingInfo extends Struct {
  external Pointer<Utf16> pszAlgId;
  external Pointer<Uint8> pbLabel;
  @Uint32()
  external int cbLabel;
}

// ── ncrypt.dll bindings ──────────────────────────────────────────────
final _ncrypt = DynamicLibrary.open('ncrypt.dll');

final _openProvider = _ncrypt.lookupFunction<
    Int32 Function(Pointer<IntPtr>, Pointer<Utf16>, Uint32),
    int Function(Pointer<IntPtr>, Pointer<Utf16>, int)>(
    'NCryptOpenStorageProvider');

final _openKey = _ncrypt.lookupFunction<
    Int32 Function(IntPtr, Pointer<IntPtr>, Pointer<Utf16>, Uint32, Uint32),
    int Function(int, Pointer<IntPtr>, Pointer<Utf16>, int, int)>(
    'NCryptOpenKey');

final _createKey = _ncrypt.lookupFunction<
    Int32 Function(
        IntPtr, Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, Uint32, Uint32),
    int Function(
        int, Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, int, int)>(
    'NCryptCreatePersistedKey');

final _setProperty = _ncrypt.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint8>, Uint32, Uint32),
    int Function(int, Pointer<Utf16>, Pointer<Uint8>, int, int)>(
    'NCryptSetProperty');

final _finalizeKey = _ncrypt.lookupFunction<
    Int32 Function(IntPtr, Uint32), int Function(int, int)>(
    'NCryptFinalizeKey');

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

String _hex(int status) =>
    '0x${(status & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';

void main() {
  const keyName = 'ZestSSHProbeKey';
  final arena = Arena();
  int hProv = 0, hKey = 0;
  try {
    // 1) open the TPM-backed provider
    final phProv = arena<IntPtr>();
    var st = _openProvider(
        phProv, _msPlatformCryptoProvider.toNativeUtf16(allocator: arena), 0);
    if (st != _errorSuccess) {
      print('FAIL open provider ${_hex(st)} (no TPM / PCP unavailable?)');
      return;
    }
    hProv = phProv.value;
    print('provider opened');

    // 2) open the persisted key, or create it
    final phKey = arena<IntPtr>();
    st = _openKey(
        hProv, phKey, keyName.toNativeUtf16(allocator: arena), 0, 0);
    if (st == _nteBadKeyset || st != _errorSuccess) {
      st = _createKey(hProv, phKey, _rsaAlgorithm.toNativeUtf16(allocator: arena),
          keyName.toNativeUtf16(allocator: arena), 0, 0);
      if (st != _errorSuccess) {
        print('FAIL create key ${_hex(st)}');
        return;
      }
      hKey = phKey.value;
      // set 2048-bit length before finalize
      final lenBuf = arena<Uint32>()..value = 2048;
      st = _setProperty(hKey, _lengthProperty.toNativeUtf16(allocator: arena),
          lenBuf.cast<Uint8>(), 4, 0);
      if (st != _errorSuccess) {
        print('FAIL set length ${_hex(st)}');
        return;
      }
      st = _finalizeKey(hKey, 0);
      if (st != _errorSuccess) {
        print('FAIL finalize ${_hex(st)}');
        return;
      }
      print('key created + finalized in TPM');
    } else {
      hKey = phKey.value;
      print('existing key opened');
    }

    // 3) build OAEP padding info (SHA-256)
    final pad = arena<_OaepPaddingInfo>();
    pad.ref.pszAlgId = _sha256Algorithm.toNativeUtf16(allocator: arena);
    pad.ref.pbLabel = nullptr;
    pad.ref.cbLabel = 0;

    // 4) a 32-byte payload = the future vault hardware key
    final rng = Random.secure();
    final payload =
        Uint8List.fromList(List<int>.generate(32, (_) => rng.nextInt(256)));
    final pIn = arena<Uint8>(payload.length);
    pIn.asTypedList(payload.length).setAll(0, payload);

    // encrypt: size query then real call
    final pcb = arena<Uint32>();
    st = _encrypt(hKey, pIn, payload.length, pad.cast<Void>(), nullptr, 0, pcb,
        _ncryptPadOaepFlag);
    if (st != _errorSuccess) {
      print('FAIL encrypt sizing ${_hex(st)}');
      return;
    }
    final ctLen = pcb.value;
    final pCt = arena<Uint8>(ctLen);
    st = _encrypt(hKey, pIn, payload.length, pad.cast<Void>(), pCt, ctLen, pcb,
        _ncryptPadOaepFlag);
    if (st != _errorSuccess) {
      print('FAIL encrypt ${_hex(st)}');
      return;
    }
    print('sealed: ${pcb.value} bytes of ciphertext');

    // 5) decrypt back
    st = _decrypt(hKey, pCt, ctLen, pad.cast<Void>(), nullptr, 0, pcb,
        _ncryptPadOaepFlag);
    if (st != _errorSuccess) {
      print('FAIL decrypt sizing ${_hex(st)}');
      return;
    }
    final ptLen = pcb.value;
    final pPt = arena<Uint8>(ptLen);
    st = _decrypt(hKey, pCt, ctLen, pad.cast<Void>(), pPt, ptLen, pcb,
        _ncryptPadOaepFlag);
    if (st != _errorSuccess) {
      print('FAIL decrypt ${_hex(st)}');
      return;
    }
    final recovered = pPt.asTypedList(pcb.value);
    final match = recovered.length == payload.length &&
        List.generate(payload.length, (i) => recovered[i] == payload[i])
            .every((b) => b);
    print(match
        ? 'ROUND_TRIP_OK: TPM sealed+unsealed 32 bytes, values match'
        : 'ROUND_TRIP_MISMATCH');
  } finally {
    if (hKey != 0) _freeObject(hKey);
    if (hProv != 0) _freeObject(hProv);
    arena.releaseAll();
  }
}
