// Empirical proof of the TPM binding's security CLAIMS (not just a round-trip):
//   1. The persistent TPM key is NON-EXPORTABLE  -> NCryptExportKey must FAIL.
//   2. The sealed blob is bound to THAT key       -> a different TPM key must
//      FAIL to decrypt it (this is what "another machine's TPM cannot unseal
//      it" reduces to: a different device has a different key).
//   3. Losing the key (TPM cleared / device reset / different machine) makes
//      the blob unrecoverable -> after deleting + recreating the key by the
//      same name (fresh material), the old ciphertext must FAIL to decrypt.
//
// Run: dart run tool/tpm_binding_probe.dart
// Uses throwaway key names (ZestSSHBindProbeA/B), never the real vault key, and
// deletes them at the end.
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _prov = 'Microsoft Platform Crypto Provider';
const _rsa = 'RSA';
const _len = 'Length';
const _sha256 = 'SHA256';
const _oaep = 0x00000004;
const _ok = 0;

final class _Oaep extends Struct {
  external Pointer<Utf16> pszAlgId;
  external Pointer<Uint8> pbLabel;
  @Uint32()
  external int cbLabel;
}

final _n = DynamicLibrary.open('ncrypt.dll');
final _openProv = _n.lookupFunction<
    Int32 Function(Pointer<IntPtr>, Pointer<Utf16>, Uint32),
    int Function(Pointer<IntPtr>, Pointer<Utf16>, int)>('NCryptOpenStorageProvider');
final _openKey = _n.lookupFunction<
    Int32 Function(IntPtr, Pointer<IntPtr>, Pointer<Utf16>, Uint32, Uint32),
    int Function(int, Pointer<IntPtr>, Pointer<Utf16>, int, int)>('NCryptOpenKey');
final _createKey = _n.lookupFunction<
    Int32 Function(IntPtr, Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, Uint32, Uint32),
    int Function(int, Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, int, int)>('NCryptCreatePersistedKey');
final _setProp = _n.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint8>, Uint32, Uint32),
    int Function(int, Pointer<Utf16>, Pointer<Uint8>, int, int)>('NCryptSetProperty');
final _finalize = _n.lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('NCryptFinalizeKey');
final _enc = _n.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Uint32),
    int Function(int, Pointer<Uint8>, int, Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, int)>('NCryptEncrypt');
final _dec = _n.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Uint32),
    int Function(int, Pointer<Uint8>, int, Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, int)>('NCryptDecrypt');
final _export = _n.lookupFunction<
    Int32 Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Void>, Pointer<Uint8>, Uint32, Pointer<Uint32>, Uint32),
    int Function(int, int, Pointer<Utf16>, Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>, int)>('NCryptExportKey');
final _del = _n.lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('NCryptDeleteKey');
final _free = _n.lookupFunction<Int32 Function(IntPtr), int Function(int)>('NCryptFreeObject');

String _hex(int s) => '0x${(s & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';

int _openOrCreate(int prov, String name, Arena a) {
  final p = a<IntPtr>();
  if (_openKey(prov, p, name.toNativeUtf16(allocator: a), 0, 0) == _ok) return p.value;
  if (_createKey(prov, p, _rsa.toNativeUtf16(allocator: a), name.toNativeUtf16(allocator: a), 0, 0) != _ok) {
    throw StateError('create $name failed');
  }
  final h = p.value;
  final l = a<Uint32>()..value = 2048;
  _setProp(h, _len.toNativeUtf16(allocator: a), l.cast<Uint8>(), 4, 0);
  _finalize(h, 0);
  return h;
}

Uint8List? _crypt(int key, Uint8List input, bool decrypt, Arena a) {
  final pad = a<_Oaep>();
  pad.ref.pszAlgId = _sha256.toNativeUtf16(allocator: a);
  pad.ref.pbLabel = nullptr;
  pad.ref.cbLabel = 0;
  final pin = a<Uint8>(input.length);
  pin.asTypedList(input.length).setAll(0, input);
  final op = decrypt ? _dec : _enc;
  final cb = a<Uint32>();
  var st = op(key, pin, input.length, pad.cast<Void>(), nullptr, 0, cb, _oaep);
  if (st != _ok) return null;
  final out = a<Uint8>(cb.value);
  st = op(key, pin, input.length, pad.cast<Void>(), out, cb.value, cb, _oaep);
  if (st != _ok) return null;
  return Uint8List.fromList(out.asTypedList(cb.value));
}

void main() {
  final a = Arena();
  int prov = 0;
  var pass = 0, fail = 0;
  void check(bool ok, String msg) {
    print(ok ? '  PASS  $msg' : '  FAIL  $msg');
    ok ? pass++ : fail++;
  }

  try {
    final pp = a<IntPtr>();
    if (_openProv(pp, _prov.toNativeUtf16(allocator: a), 0) != _ok) {
      print('no TPM provider');
      return;
    }
    prov = pp.value;

    // Key A + seal a payload.
    final keyA = _openOrCreate(prov, 'ZestSSHBindProbeA', a);
    final payload = Uint8List.fromList(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)));
    final ct = _crypt(keyA, payload, false, a);
    check(ct != null, 'sealed a 32-byte payload with TPM key A');

    // 1) Non-exportability: try to export A's PRIVATE key blob. Must fail.
    final cb = a<Uint32>();
    final exp = _export(keyA, 0, 'RSAFULLPRIVATEBLOB'.toNativeUtf16(allocator: a),
        nullptr, nullptr, 0, cb, 0);
    check(exp != _ok,
        'private key export is REFUSED by the TPM (status ${_hex(exp)}) - key cannot leave the chip');

    // 2) Per-key binding: a DIFFERENT TPM key must NOT decrypt A's ciphertext
    //    (this is exactly "a different device/TPM cannot unseal it").
    final keyB = _openOrCreate(prov, 'ZestSSHBindProbeB', a);
    final withB = ct == null ? null : _crypt(keyB, ct, true, a);
    check(withB == null,
        'a different TPM key (B) CANNOT decrypt A\'s blob - the ciphertext is bound to A');

    // sanity: A itself CAN still decrypt (proves we did not just break decrypt).
    final withA = ct == null ? null : _crypt(keyA, ct, true, a);
    final aWorks = withA != null &&
        withA.length == payload.length &&
        List.generate(payload.length, (i) => withA[i] == payload[i]).every((b) => b);
    check(aWorks, 'the ORIGINAL TPM key A still unseals its own blob (control)');

    // 3) Lose the key: delete A, recreate by the same name (fresh material),
    //    old ciphertext must fail (TPM cleared / device reset / another machine).
    _del(keyA, 0); // deletes + frees handle
    final keyA2 = _openOrCreate(prov, 'ZestSSHBindProbeA', a);
    final withA2 = ct == null ? null : _crypt(keyA2, ct, true, a);
    check(withA2 == null,
        'after the key is deleted + recreated (fresh material), the old blob is UNRECOVERABLE');

    // cleanup
    _del(keyA2, 0);
    _del(keyB, 0);

    print('\n${fail == 0 ? "ALL BINDING CLAIMS HELD" : "SOME CLAIMS FAILED"}: $pass passed, $fail failed');
  } finally {
    if (prov != 0) _free(prov);
    a.releaseAll();
  }
}
