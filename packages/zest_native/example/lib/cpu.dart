// This process's CPU time, for the spike's measurements: GetProcessTimes on Windows,
// /proc/self/stat on Android and Linux, getrusage on iOS and macOS.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final DynamicLibrary? _kernel32 = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;

final _getCurrentProcess = _kernel32?.lookupFunction<IntPtr Function(), int Function()>('GetCurrentProcess');
final _getProcessTimes = _kernel32?.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
    int Function(int, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)>('GetProcessTimes');

/// Kernel plus user CPU time of this process, in microseconds (0 where it cannot be read).
int processCpuUs() {
  if (Platform.isAndroid || Platform.isLinux) return _procStatUs();
  if (Platform.isIOS || Platform.isMacOS) return _rusageUs();
  final f = _getProcessTimes;
  if (f == null) return 0;
  final t = calloc<Uint64>(4);
  try {
    if (f(_getCurrentProcess!(), t, t + 1, t + 2, t + 3) == 0) return 0;
    // FILETIME units of 100 ns.
    return ((t + 2).value + (t + 3).value) ~/ 10;
  } finally {
    calloc.free(t);
  }
}

/// utime + stime from /proc/self/stat (fields 14 and 15, in clock ticks of 10 ms on Android).
int _procStatUs() {
  try {
    final s = File('/proc/self/stat').readAsStringSync();
    // The command name (field 2) is in parentheses and may hold spaces: count after its end.
    final rest = s.substring(s.lastIndexOf(')') + 2).split(' ');
    // rest[0] is field 3, so field 14 is rest[11] and field 15 is rest[12].
    return (int.parse(rest[11]) + int.parse(rest[12])) * 10000;
  } on Object {
    return 0;
  }
}

final _getrusage = (Platform.isIOS || Platform.isMacOS)
    ? DynamicLibrary.process().lookupFunction<Int32 Function(Int32, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('getrusage')
    : null;

/// ru_utime + ru_stime from getrusage(RUSAGE_SELF): on Darwin each is a timeval of a 64-bit
/// tv_sec and a 32-bit tv_usec padded to 16 bytes, at offsets 0 and 16 of struct rusage.
int _rusageUs() {
  final f = _getrusage;
  if (f == null) return 0;
  final r = calloc<Uint8>(256);
  try {
    if (f(0, r) != 0) return 0;
    final d = r.cast<Int64>();
    final u = r.cast<Int32>();
    return d[0] * 1000000 + u[2] + d[2] * 1000000 + u[6];
  } finally {
    calloc.free(r);
  }
}
