import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:zestssh/utils/type_name.dart';

/// Minimal Win32 FFI wrapper for synchronous local named-pipe IO.
///
/// Why this exists: `File('\\.\pipe\openssh-ssh-agent').open()` fails
/// on Windows with `ERROR_BAD_NETPATH` (53). Dart's `_File` Windows
/// implementation routes the `\\.\pipe\` path through a normalisation
/// step that mistakes the dot for an SMB server name. The OpenSSH
/// agent is reachable from every other tool on the system (ssh-add,
/// ssh, git, …) because they all call `CreateFileW` directly. We do
/// the same here.
///
/// We wrap the smallest possible Win32 surface - enough for one
/// open + repeated read/write + close per agent operation - without
/// pulling in the `win32` package. That keeps our build leaner and
/// leaves the bindings reviewable by anyone who's read the agent
/// protocol once.
///
/// LIMITATION: this is *synchronous* IO, but called from async
/// contexts via small chunked operations. The agent protocol is
/// request-reply with bounded message sizes (<=256 KiB by our cap),
/// so each read/write completes in well under a frame. No real risk
/// of UI jank for our usage pattern.

// ── Win32 constants (winnt.h, fileapi.h, winerror.h) ─────────────

const int _genericRead = 0x80000000;
const int _genericWrite = 0x40000000;
const int _openExisting = 3;
const int _invalidHandleValue = -1;

/// What CreateFileW is told of the pipe's server (found in a
/// security review): SECURITY_SQOS_PRESENT with
/// SECURITY_IDENTIFICATION, so that the program serving the pipe may learn
/// who connected and can never act as that person. Without them Windows lets
/// a pipe's server impersonate its client in full, and any service account
/// holding SeImpersonatePrivilege that served the agent's pipe had a token of
/// the person to act with.
const int kPipeOpenSecurityFlags = 0x00100000 /* SECURITY_SQOS_PRESENT */ | 0x00010000 /* SECURITY_IDENTIFICATION */;

// What the server of a pipe is asked (processthreadsapi.h, winnt.h, accctrl.h).
const int _processQueryLimitedInformation = 0x1000;
const int _tokenQuery = 0x0008;
const int _tokenUserClass = 1; // TOKEN_INFORMATION_CLASS.TokenUser
const int _seKernelObject = 6; // SE_OBJECT_TYPE.SE_KERNEL_OBJECT
const int _ownerSecurityInformation = 0x00000001;

// Common errors we surface verbatim so the user gets actionable text.
const int _errorFileNotFound = 2;
const int _errorAccessDenied = 5;
const int _errorPipeBusy = 231;
const int _errorBadNetpath = 53;

// ── Function signatures ─────────────────────────────────────────

// HANDLE WINAPI CreateFileW(
//   LPCWSTR lpFileName,
//   DWORD   dwDesiredAccess,
//   DWORD   dwShareMode,
//   LPSECURITY_ATTRIBUTES lpSecurityAttributes,
//   DWORD   dwCreationDisposition,
//   DWORD   dwFlagsAndAttributes,
//   HANDLE  hTemplateFile
// );
typedef _CreateFileWNative = IntPtr Function(
  Pointer<Utf16>,
  Uint32,
  Uint32,
  Pointer<Void>,
  Uint32,
  Uint32,
  Pointer<Void>,
);
typedef _CreateFileW = int Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<Void>,
  int,
  int,
  Pointer<Void>,
);

// BOOL WINAPI ReadFile(
//   HANDLE       hFile,
//   LPVOID       lpBuffer,
//   DWORD        nNumberOfBytesToRead,
//   LPDWORD      lpNumberOfBytesRead,
//   LPOVERLAPPED lpOverlapped
// );
typedef _ReadFileNative = Int32 Function(
  IntPtr,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _ReadFile = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);

// BOOL WINAPI WriteFile(
//   HANDLE       hFile,
//   LPCVOID      lpBuffer,
//   DWORD        nNumberOfBytesToWrite,
//   LPDWORD      lpNumberOfBytesWritten,
//   LPOVERLAPPED lpOverlapped
// );
typedef _WriteFileNative = Int32 Function(
  IntPtr,
  Pointer<Uint8>,
  Uint32,
  Pointer<Uint32>,
  Pointer<Void>,
);
typedef _WriteFile = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
);

// BOOL WINAPI CloseHandle(HANDLE hObject);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandle = int Function(int);

// DWORD WINAPI GetLastError(void);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastError = int Function();

// BOOL WINAPI WaitNamedPipeW(LPCWSTR lpNamedPipeName, DWORD nTimeOut);
typedef _WaitNamedPipeWNative = Int32 Function(Pointer<Utf16>, Uint32);
typedef _WaitNamedPipeW = int Function(Pointer<Utf16>, int);

// BOOL GetNamedPipeServerProcessId(HANDLE Pipe, PULONG ServerProcessId);
typedef _GetNamedPipeServerProcessIdNative = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _GetNamedPipeServerProcessId = int Function(int, Pointer<Uint32>);

// HANDLE OpenProcess(DWORD dwDesiredAccess, BOOL bInheritHandle, DWORD dwProcessId);
typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcess = int Function(int, int, int);

// HANDLE GetCurrentProcess(void); (a pseudo handle, never closed)
typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcess = int Function();

// HLOCAL LocalFree(HLOCAL hMem);
typedef _LocalFreeNative = IntPtr Function(Pointer<Void>);
typedef _LocalFree = int Function(Pointer<Void>);

// BOOL OpenProcessToken(HANDLE ProcessHandle, DWORD DesiredAccess, PHANDLE TokenHandle);
typedef _OpenProcessTokenNative = Int32 Function(IntPtr, Uint32, Pointer<IntPtr>);
typedef _OpenProcessToken = int Function(int, int, Pointer<IntPtr>);

// BOOL GetTokenInformation(HANDLE TokenHandle, TOKEN_INFORMATION_CLASS TokenInformationClass,
//   LPVOID TokenInformation, DWORD TokenInformationLength, PDWORD ReturnLength);
typedef _GetTokenInformationNative = Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>);
typedef _GetTokenInformation = int Function(int, int, Pointer<Void>, int, Pointer<Uint32>);

// BOOL ConvertSidToStringSidW(PSID Sid, LPWSTR *StringSid);
typedef _ConvertSidToStringSidWNative = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>);
typedef _ConvertSidToStringSidW = int Function(Pointer<Void>, Pointer<Pointer<Utf16>>);

// DWORD GetSecurityInfo(HANDLE handle, SE_OBJECT_TYPE ObjectType, SECURITY_INFORMATION SecurityInfo,
//   PSID *ppsidOwner, PSID *ppsidGroup, PACL *ppDacl, PACL *ppSacl, PSECURITY_DESCRIPTOR *ppSecurityDescriptor);
typedef _GetSecurityInfoNative = Uint32 Function(IntPtr, Int32, Uint32, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>,
    Pointer<Pointer<Void>>, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>);
typedef _GetSecurityInfo = int Function(int, int, int, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>,
    Pointer<Pointer<Void>>, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>);

// ── Loaded once ─────────────────────────────────────────────────

final DynamicLibrary _kernel32 =
    DynamicLibrary.open('kernel32.dll');

final _CreateFileW _createFile = _kernel32
    .lookupFunction<_CreateFileWNative, _CreateFileW>('CreateFileW');
final _ReadFile _readFile =
    _kernel32.lookupFunction<_ReadFileNative, _ReadFile>('ReadFile');
final _WriteFile _writeFile =
    _kernel32.lookupFunction<_WriteFileNative, _WriteFile>('WriteFile');
final _CloseHandle _closeHandle = _kernel32
    .lookupFunction<_CloseHandleNative, _CloseHandle>('CloseHandle');
final _GetLastError _getLastError = _kernel32
    .lookupFunction<_GetLastErrorNative, _GetLastError>('GetLastError');
final _WaitNamedPipeW _waitNamedPipe = _kernel32
    .lookupFunction<_WaitNamedPipeWNative, _WaitNamedPipeW>(
        'WaitNamedPipeW');
final _GetNamedPipeServerProcessId _getNamedPipeServerProcessId = _kernel32
    .lookupFunction<_GetNamedPipeServerProcessIdNative, _GetNamedPipeServerProcessId>('GetNamedPipeServerProcessId');
final _OpenProcess _openProcess = _kernel32.lookupFunction<_OpenProcessNative, _OpenProcess>('OpenProcess');
final _GetCurrentProcess _getCurrentProcess =
    _kernel32.lookupFunction<_GetCurrentProcessNative, _GetCurrentProcess>('GetCurrentProcess');
final _LocalFree _localFree = _kernel32.lookupFunction<_LocalFreeNative, _LocalFree>('LocalFree');

final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

final _OpenProcessToken _openProcessToken =
    _advapi32.lookupFunction<_OpenProcessTokenNative, _OpenProcessToken>('OpenProcessToken');
final _GetTokenInformation _getTokenInformation =
    _advapi32.lookupFunction<_GetTokenInformationNative, _GetTokenInformation>('GetTokenInformation');
final _ConvertSidToStringSidW _convertSidToStringSid =
    _advapi32.lookupFunction<_ConvertSidToStringSidWNative, _ConvertSidToStringSidW>('ConvertSidToStringSidW');
final _GetSecurityInfo _getSecurityInfo =
    _advapi32.lookupFunction<_GetSecurityInfoNative, _GetSecurityInfo>('GetSecurityInfo');

// ── Public API ──────────────────────────────────────────────────

/// Synchronous handle to a connected Windows named pipe. Zero
/// long-lived state - instances live for the duration of one agent
/// request/response exchange.
class WindowsNamedPipe {
  WindowsNamedPipe._(this._handle);

  final int _handle;
  bool _closed = false;

  /// Open a connection to a local named pipe. The path must be in
  /// the canonical `\\.\pipe\<name>` form.
  ///
  /// Throws [WindowsPipeException] with the Win32 error code on
  /// failure. If the pipe is busy (231 / `ERROR_PIPE_BUSY`), the
  /// caller can retry - Win32's `WaitNamedPipeW` would help here
  /// but we keep the API call-once-and-throw for simplicity.
  static WindowsNamedPipe open(String pipePath) {
    if (!Platform.isWindows) {
      throw StateError('WindowsNamedPipe only works on Windows');
    }
    final namePtr = pipePath.toNativeUtf16();
    try {
      // First try a direct CreateFileW. If the pipe is busy, fall
      // back to WaitNamedPipeW for up to 1s and retry once. A
      // higher retry count would mask real failures.
      final handle = _createFile(
        namePtr,
        _genericRead | _genericWrite,
        0, // no sharing
        nullptr,
        _openExisting,
        kPipeOpenSecurityFlags, // the server may identify us, never act as us
        nullptr,
      );
      if (handle != _invalidHandleValue) {
        return WindowsNamedPipe._(handle);
      }

      final err = _getLastError();
      if (err == _errorPipeBusy) {
        final waited = _waitNamedPipe(namePtr, 1000); // 1 s
        if (waited != 0) {
          final retry = _createFile(
            namePtr,
            _genericRead | _genericWrite,
            0,
            nullptr,
            _openExisting,
            kPipeOpenSecurityFlags,
            nullptr,
          );
          if (retry != _invalidHandleValue) {
            return WindowsNamedPipe._(retry);
          }
        }
      }

      throw WindowsPipeException(err, _describeError(err, pipePath));
    } finally {
      calloc.free(namePtr);
    }
  }

  /// Write [bytes] to the pipe. Returns when all bytes have been
  /// flushed. Throws [WindowsPipeException] on failure.
  void write(Uint8List bytes) {
    if (_closed) throw StateError('Pipe is closed');
    final buf = calloc<Uint8>(bytes.length);
    try {
      for (var i = 0; i < bytes.length; i++) {
        buf[i] = bytes[i];
      }
      var offset = 0;
      final written = calloc<Uint32>();
      try {
        while (offset < bytes.length) {
          final ok = _writeFile(
            _handle,
            (buf + offset),
            bytes.length - offset,
            written,
            nullptr,
          );
          if (ok == 0) {
            throw WindowsPipeException(
                _getLastError(), 'WriteFile failed');
          }
          if (written.value == 0) {
            throw const WindowsPipeException(0,
                'WriteFile reported 0 bytes - pipe likely closed by peer');
          }
          offset += written.value;
        }
      } finally {
        calloc.free(written);
      }
    } finally {
      calloc.free(buf);
    }
  }

  /// Read exactly [count] bytes. Loops over [ReadFile] until the
  /// requested length is satisfied or the pipe closes. Throws
  /// [WindowsPipeException] on truncation / error.
  Uint8List readExact(int count) {
    if (_closed) throw StateError('Pipe is closed');
    if (count <= 0) return Uint8List(0);

    final out = Uint8List(count);
    final buf = calloc<Uint8>(count);
    final read = calloc<Uint32>();
    try {
      var have = 0;
      while (have < count) {
        final ok = _readFile(
          _handle,
          (buf + have),
          count - have,
          read,
          nullptr,
        );
        if (ok == 0) {
          throw WindowsPipeException(
              _getLastError(), 'ReadFile failed');
        }
        if (read.value == 0) {
          throw WindowsPipeException(0,
              'Pipe closed by peer while we needed $count bytes (had $have)');
        }
        have += read.value;
      }
      for (var i = 0; i < count; i++) {
        out[i] = buf[i];
      }
      return out;
    } finally {
      calloc.free(buf);
      calloc.free(read);
    }
  }

  /// Close the pipe handle. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _closeHandle(_handle);
  }

  /// Who serves this pipe, as Windows says it, before anything is sent: the
  /// user of this process, the user of the process at the pipe's other end
  /// (GetNamedPipeServerProcessId, then that process's token), and the owner
  /// of the pipe itself (GetSecurityInfo on this handle). Each is null where
  /// Windows would not say: a process of another account, or a service's, is
  /// not ours to open. Reads only; what is trusted is decided by the caller.
  PipeServerIdentity serverIdentity() {
    if (_closed) throw StateError('Pipe is closed');
    return PipeServerIdentity(
      ownUser: _tokenUserOfProcess(_getCurrentProcess()),
      serverProcessUser: _serverProcessUser(),
      pipeOwner: _pipeOwner(),
    );
  }

  String? _serverProcessUser() {
    final pid = calloc<Uint32>();
    try {
      if (_getNamedPipeServerProcessId(_handle, pid) == 0) return null;
      final process = _openProcess(_processQueryLimitedInformation, 0, pid.value);
      if (process == 0) return null;
      try {
        return _tokenUserOfProcess(process);
      } finally {
        _closeHandle(process);
      }
    } finally {
      calloc.free(pid);
    }
  }

  String? _pipeOwner() {
    final owner = calloc<Pointer<Void>>();
    final descriptor = calloc<Pointer<Void>>();
    try {
      final failed = _getSecurityInfo(
          _handle, _seKernelObject, _ownerSecurityInformation, owner, nullptr, nullptr, nullptr, descriptor);
      if (failed != 0) return null;
      try {
        return owner.value == nullptr ? null : _sidText(owner.value);
      } finally {
        // The owner points into the descriptor, which is freed once read.
        _localFree(descriptor.value);
      }
    } finally {
      calloc.free(owner);
      calloc.free(descriptor);
    }
  }
}

/// Who serves a named pipe, each as a SID in its text form (S-1-5-18 is
/// LocalSystem); null where Windows would not say ([WindowsNamedPipe.serverIdentity]).
class PipeServerIdentity {
  const PipeServerIdentity({this.ownUser, this.serverProcessUser, this.pipeOwner});

  /// The user this app runs as.
  final String? ownUser;

  /// The user of the process that serves the pipe.
  final String? serverProcessUser;

  /// The owner in the pipe's security descriptor: whoever created it, by the
  /// default owner of their token.
  final String? pipeOwner;

  @override
  String toString() =>
      'PipeServerIdentity(own: ${ownUser ?? '?'}, server process: ${serverProcessUser ?? '?'}, owner: ${pipeOwner ?? '?'})';
}

/// The user of [process]'s token, or null where it cannot be read.
String? _tokenUserOfProcess(int process) {
  final token = calloc<IntPtr>();
  try {
    if (_openProcessToken(process, _tokenQuery, token) == 0) return null;
    try {
      return _tokenUser(token.value);
    } finally {
      _closeHandle(token.value);
    }
  } finally {
    calloc.free(token);
  }
}

String? _tokenUser(int token) {
  // TOKEN_USER is a SID_AND_ATTRIBUTES, a SID's pointer first, with the SID
  // after it in the same buffer: at most 16 bytes and a SID's 68.
  const size = 256;
  final buffer = calloc<Uint8>(size);
  final needed = calloc<Uint32>();
  try {
    if (_getTokenInformation(token, _tokenUserClass, buffer.cast(), size, needed) == 0) return null;
    final sid = buffer.cast<Pointer<Void>>().value;
    return sid == nullptr ? null : _sidText(sid);
  } finally {
    calloc.free(buffer);
    calloc.free(needed);
  }
}

String? _sidText(Pointer<Void> sid) {
  final text = calloc<Pointer<Utf16>>();
  try {
    if (_convertSidToStringSid(sid, text) == 0) return null;
    try {
      return text.value.toDartString();
    } finally {
      _localFree(text.value.cast());
    }
  } finally {
    calloc.free(text);
  }
}

/// Exception thrown when the named pipe API rejects an operation.
class WindowsPipeException implements Exception, HasTypeName {
  const WindowsPipeException(this.errorCode, this.message);
  final int errorCode;
  final String message;

  @override
  String toString() =>
      'WindowsPipeException($errorCode): $message';

  @override
  String get typeName => 'WindowsPipeException';
}

/// Translate the most common Win32 errors into actionable text. We
/// pass the raw error code along so the caller can pattern-match if
/// needed.
String _describeError(int code, String pipePath) {
  switch (code) {
    case _errorFileNotFound:
      return 'Pipe "$pipePath" does not exist. The OpenSSH '
          'Authentication Agent service is not running, or it is '
          'using a different pipe name.';
    case _errorAccessDenied:
      return 'Access denied opening "$pipePath" - your user '
          'account is not permitted to talk to this agent. The '
          'agent may be running as a different user.';
    case _errorPipeBusy:
      return 'Pipe "$pipePath" is busy and did not free up within '
          '1 second.';
    case _errorBadNetpath:
      return 'Pipe "$pipePath" was rejected with ERROR_BAD_NETPATH '
          '(53). This is usually a path-formatting issue - verify '
          'the agent really registered the standard pipe name.';
    default:
      return 'CreateFileW("$pipePath") failed with Win32 error $code.';
  }
}
