// Windows' word on the person at it (a security experience review),
// read through dart:ffi: no code in
// the runner. Both calls only read.
//
// Idle time: GetLastInputInfo (user32) gives the tick count of the last
// input in this session, from any app; GetTickCount64 (kernel32) the tick
// count now.
// Lock: WTSQuerySessionInformationW (wtsapi32) with WTSSessionInfoEx gives
// this session's SessionFlags: WTS_SESSIONSTATE_LOCK (0) while the lock
// screen is up, WTS_SESSIONSTATE_UNLOCK (1) otherwise, and -1 when Windows
// does not know. (Windows 7 had the two the other way round; Flutter needs
// Windows 10 or later.)
//
// Anything that fails (a function missing, a call that answers FALSE, an
// answer of an unknown shape) answers null: the app goes on as before.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:zestssh/services/presence/system_presence.dart';
import 'package:zestssh/utils/logger.dart';

/// LASTINPUTINFO: its own size, then the tick count of the last input.
final class _LastInputInfo extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int dwTime;
}

typedef _GetLastInputInfoC = Int32 Function(Pointer<_LastInputInfo>);
typedef _GetLastInputInfoDart = int Function(Pointer<_LastInputInfo>);
typedef _GetTickCount64C = Uint64 Function();
typedef _GetTickCount64Dart = int Function();
typedef _WtsQueryC = Int32 Function(IntPtr, Uint32, Int32, Pointer<Pointer<Uint8>>, Pointer<Uint32>);
typedef _WtsQueryDart = int Function(int, int, int, Pointer<Pointer<Uint8>>, Pointer<Uint32>);
typedef _WtsFreeC = Void Function(Pointer<Uint8>);
typedef _WtsFreeDart = void Function(Pointer<Uint8>);

/// WTS_CURRENT_SERVER_HANDLE: this computer.
const _kThisServer = 0;

/// WTS_CURRENT_SESSION: the session this app runs in.
const _kThisSession = 0xFFFFFFFF;

/// WTS_INFO_CLASS.WTSSessionInfoEx.
const _kSessionInfoEx = 25;

/// WTSINFOEXW: Level (a DWORD), then the level-1 record, which holds 64-bit
/// times and so starts 8 bytes in; in it SessionId, SessionState, then
/// SessionFlags.
const _kLevelOffset = 0;
const _kFlagsOffset = 8 + 4 + 4;

/// WTS_SESSIONSTATE_LOCK and WTS_SESSIONSTATE_UNLOCK.
const _kSessionLocked = 0;
const _kSessionUnlocked = 1;

class WindowsPresence implements SystemPresence {
  _GetLastInputInfoDart? _getLastInputInfo;
  _GetTickCount64Dart? _getTickCount64;
  _WtsQueryDart? _wtsQuery;
  _WtsFreeDart? _wtsFree;

  /// A part that could not be loaded is not tried again.
  bool _idleGone = false;
  bool _lockGone = false;

  @override
  Future<Duration?> idleTime() async {
    if (_idleGone) return null;
    try {
      if (_getLastInputInfo == null || _getTickCount64 == null) {
        _getLastInputInfo = DynamicLibrary.open(
          'user32.dll',
        ).lookupFunction<_GetLastInputInfoC, _GetLastInputInfoDart>('GetLastInputInfo');
        _getTickCount64 = DynamicLibrary.open(
          'kernel32.dll',
        ).lookupFunction<_GetTickCount64C, _GetTickCount64Dart>('GetTickCount64');
      }
    } catch (e) {
      _idleGone = true;
      AppLogger.warning('Presence: no idle time from Windows ($e)');
      return null;
    }
    final info = calloc<_LastInputInfo>();
    try {
      info.ref.cbSize = sizeOf<_LastInputInfo>();
      if (_getLastInputInfo!(info) == 0) return null;
      // Both counts in milliseconds since Windows started; the last input's
      // is 32 bits and wraps every 49.7 days, so the difference is taken in
      // 32 bits as well.
      final ms = ((_getTickCount64!() & 0xFFFFFFFF) - info.ref.dwTime) & 0xFFFFFFFF;
      return Duration(milliseconds: ms);
    } catch (e) {
      return null;
    } finally {
      calloc.free(info);
    }
  }

  @override
  Future<bool?> isLocked() async {
    if (_lockGone) return null;
    try {
      if (_wtsQuery == null || _wtsFree == null) {
        final wtsapi = DynamicLibrary.open('wtsapi32.dll');
        _wtsQuery = wtsapi.lookupFunction<_WtsQueryC, _WtsQueryDart>('WTSQuerySessionInformationW');
        _wtsFree = wtsapi.lookupFunction<_WtsFreeC, _WtsFreeDart>('WTSFreeMemory');
      }
    } catch (e) {
      _lockGone = true;
      AppLogger.warning('Presence: no lock state from Windows ($e)');
      return null;
    }
    final buffer = calloc<Pointer<Uint8>>();
    final bytes = calloc<Uint32>();
    try {
      if (_wtsQuery!(_kThisServer, _kThisSession, _kSessionInfoEx, buffer, bytes) == 0) return null;
      final info = buffer.value;
      if (info == nullptr) return null;
      try {
        if (bytes.value < _kFlagsOffset + 4) return null;
        final level = (info + _kLevelOffset).cast<Uint32>().value;
        if (level != 1) return null;
        final flags = (info + _kFlagsOffset).cast<Int32>().value;
        return switch (flags) {
          _kSessionLocked => true,
          _kSessionUnlocked => false,
          _ => null,
        };
      } finally {
        _wtsFree!(info);
      }
    } catch (e) {
      return null;
    } finally {
      calloc.free(buffer);
      calloc.free(bytes);
    }
  }

  @override
  Future<void> close() async {}
}
