// macOS's word on the person at it (a security experience review),
// read through dart:ffi: no code in
// the runner. Both calls only read.
//
// Idle time: CGEventSourceSecondsSinceLastEventType (CoreGraphics) for any
// input event, in this login session's combined state (not the hardware's
// alone, which would count another person's input in their own session after
// a switch of users).
// Lock: CGSessionCopyCurrentDictionary (CoreGraphics) holds
// "CGSSessionScreenIsLocked", true while the lock screen is up and missing
// otherwise; read with CoreFoundation.
//
// Anything that fails (a framework or function missing, no dictionary, an
// answer of an unknown shape) answers null: the app goes on as before.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:zestssh/services/presence/system_presence.dart';
import 'package:zestssh/utils/logger.dart';

typedef _SecondsSinceC = Double Function(Int32, Uint32);
typedef _SecondsSinceDart = double Function(int, int);
typedef _CopyDictC = Pointer<Void> Function();
typedef _CopyDictDart = Pointer<Void> Function();
typedef _DictGetC = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _DictGetDart = Pointer<Void> Function(Pointer<Void>, Pointer<Void>);
typedef _StrCreateC = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32);
typedef _StrCreateDart = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _TypeIdOfC = Uint64 Function(Pointer<Void>);
typedef _TypeIdOfDart = int Function(Pointer<Void>);
typedef _BoolTypeIdC = Uint64 Function();
typedef _BoolTypeIdDart = int Function();
typedef _BoolValueC = Uint8 Function(Pointer<Void>);
typedef _BoolValueDart = int Function(Pointer<Void>);
typedef _ReleaseC = Void Function(Pointer<Void>);
typedef _ReleaseDart = void Function(Pointer<Void>);

const _kCoreGraphics = '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics';
const _kCoreFoundation = '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation';

/// kCGEventSourceStateCombinedSessionState.
const _kSessionState = 0;

/// kCGAnyInputEventType: (CGEventType)~0.
const _kAnyInput = 0xFFFFFFFF;

/// kCFStringEncodingUTF8.
const _kUtf8 = 0x08000100;

class MacPresence implements SystemPresence {
  _SecondsSinceDart? _secondsSince;
  _CopyDictDart? _copyDict;
  _DictGetDart? _dictGet;
  _StrCreateDart? _strCreate;
  _TypeIdOfDart? _typeIdOf;
  _BoolTypeIdDart? _boolTypeId;
  _BoolValueDart? _boolValue;
  _ReleaseDart? _release;

  /// A part that could not be loaded is not tried again.
  bool _idleGone = false;
  bool _lockGone = false;

  @override
  Future<Duration?> idleTime() async {
    if (_idleGone) return null;
    try {
      _secondsSince ??= DynamicLibrary.open(
        _kCoreGraphics,
      ).lookupFunction<_SecondsSinceC, _SecondsSinceDart>('CGEventSourceSecondsSinceLastEventType');
    } catch (e) {
      _idleGone = true;
      AppLogger.warning('Presence: no idle time from macOS ($e)');
      return null;
    }
    try {
      final seconds = _secondsSince!(_kSessionState, _kAnyInput);
      if (seconds.isNaN || seconds.isInfinite || seconds < 0) return null;
      return Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round());
    } catch (e) {
      return null;
    }
  }

  @override
  Future<bool?> isLocked() async {
    if (_lockGone) return null;
    try {
      if (_copyDict == null) {
        final cg = DynamicLibrary.open(_kCoreGraphics);
        final cf = DynamicLibrary.open(_kCoreFoundation);
        _dictGet = cf.lookupFunction<_DictGetC, _DictGetDart>('CFDictionaryGetValue');
        _strCreate = cf.lookupFunction<_StrCreateC, _StrCreateDart>('CFStringCreateWithCString');
        _typeIdOf = cf.lookupFunction<_TypeIdOfC, _TypeIdOfDart>('CFGetTypeID');
        _boolTypeId = cf.lookupFunction<_BoolTypeIdC, _BoolTypeIdDart>('CFBooleanGetTypeID');
        _boolValue = cf.lookupFunction<_BoolValueC, _BoolValueDart>('CFBooleanGetValue');
        _release = cf.lookupFunction<_ReleaseC, _ReleaseDart>('CFRelease');
        _copyDict = cg.lookupFunction<_CopyDictC, _CopyDictDart>('CGSessionCopyCurrentDictionary');
      }
    } catch (e) {
      _copyDict = null;
      _lockGone = true;
      AppLogger.warning('Presence: no lock state from macOS ($e)');
      return null;
    }
    try {
      final dict = _copyDict!();
      // No dictionary: this process is outside a window server session.
      if (dict == nullptr) return null;
      final name = 'CGSSessionScreenIsLocked'.toNativeUtf8();
      Pointer<Void> key = nullptr;
      try {
        key = _strCreate!(nullptr, name, _kUtf8);
        if (key == nullptr) return null;
        final value = _dictGet!(dict, key);
        // Missing while the screen is not locked.
        if (value == nullptr) return false;
        if (_typeIdOf!(value) != _boolTypeId!()) return null;
        return _boolValue!(value) != 0;
      } finally {
        if (key != nullptr) _release!(key);
        _release!(dict);
        malloc.free(name);
      }
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> close() async {}
}
