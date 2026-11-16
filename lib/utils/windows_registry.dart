import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Which part of the Windows registry a value is read from.
enum RegistryRoot {
  /// HKEY_CURRENT_USER: this Windows account's.
  currentUser,

  /// HKEY_LOCAL_MACHINE, as a 64-bit program sees it: the PC's.
  localMachine,

  /// HKEY_LOCAL_MACHINE as a 32-bit program sees it (WOW6432Node): where a
  /// 32-bit installer writes the PC's.
  localMachine32,
}

// HKEY_CURRENT_USER and HKEY_LOCAL_MACHINE (winreg.h): a LONG made a pointer,
// so its sign carries into the upper half on a 64-bit Windows.
const _hkeyCurrentUser = -0x7FFFFFFF; // (HKEY)(ULONG_PTR)(LONG)0x80000001
const _hkeyLocalMachine = -0x7FFFFFFE; // (HKEY)(ULONG_PTR)(LONG)0x80000002

const _rrfRtRegSz = 0x00000002;
const _rrfSubkeyWow6464 = 0x00010000;
const _rrfSubkeyWow6432 = 0x00020000;
const _errorSuccess = 0;
const _errorMoreData = 234;

typedef _RegGetValueNative =
    Int32 Function(
      IntPtr key,
      Pointer<Utf16> subKey,
      Pointer<Utf16> value,
      Uint32 flags,
      Pointer<Uint32> type,
      Pointer<Void> data,
      Pointer<Uint32> size,
    );
typedef _RegGetValueDart =
    int Function(
      int key,
      Pointer<Utf16> subKey,
      Pointer<Utf16> value,
      int flags,
      Pointer<Uint32> type,
      Pointer<Void> data,
      Pointer<Uint32> size,
    );

/// The text value [value] of the registry key [key] under [root], from
/// advapi32's RegGetValueW (a REG_EXPAND_SZ comes with its variables filled
/// in); null where the key or the value is not there, the value is not text,
/// or it cannot be read. Only reads.
String? readRegistryString(RegistryRoot root, String key, String value) {
  final getValue = DynamicLibrary.open(
    'advapi32.dll',
  ).lookupFunction<_RegGetValueNative, _RegGetValueDart>('RegGetValueW');
  final hkey = root == RegistryRoot.currentUser
      ? _hkeyCurrentUser
      : _hkeyLocalMachine;
  final flags =
      _rrfRtRegSz |
      switch (root) {
        RegistryRoot.currentUser => 0,
        RegistryRoot.localMachine => _rrfSubkeyWow6464,
        RegistryRoot.localMachine32 => _rrfSubkeyWow6432,
      };
  final subKey = key.toNativeUtf16();
  final name = value.toNativeUtf16();
  final size = calloc<Uint32>();
  try {
    // Asked with no room first: Windows says how much room the text takes,
    // in bytes, its ending 0 among them. Asked again where it grew between.
    var code = getValue(hkey, subKey, name, flags, nullptr, nullptr, size);
    for (var i = 0; i < 3 && code == _errorSuccess; i++) {
      final bytes = size.value;
      if (bytes < 2) return '';
      final data = calloc<Uint16>(bytes ~/ 2 + 1);
      try {
        code = getValue(hkey, subKey, name, flags, nullptr, data.cast(), size);
        if (code == _errorSuccess) {
          final text = data.cast<Utf16>().toDartString(length: size.value ~/ 2);
          final end = text.indexOf('\u0000');
          return end < 0 ? text : text.substring(0, end);
        }
      } finally {
        calloc.free(data);
      }
      if (code == _errorMoreData) code = _errorSuccess;
    }
    return null;
  } finally {
    calloc.free(subKey);
    calloc.free(name);
    calloc.free(size);
  }
}
