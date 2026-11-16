import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path/path.dart' as p;
import 'package:zestssh/features/sftp/local_places.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart' show SftpHiddenLevel;
import 'package:zestssh/utils/android_save_folder.dart' show downloadSaveFolder;
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';

/// A file or directory entry in either a local or remote pane.
///
/// Re-exports the shape of [SftpEntry] (same fields) so existing remote
/// rendering code is reusable. Local sources convert their `FileSystemEntity`
/// listings into this type.
typedef PaneFileEntry = SftpEntry;

/// Progress callback used by [PaneFileSource.uploadFile] and
/// [PaneFileSource.downloadFile]. `transferred` and `total` are byte counts;
/// `total` may be 0 if the size is unknown ahead of time.
typedef PaneTransferProgress = void Function(int transferred, int total);

/// Free / total bytes on the volume backing a pane's current directory, for the
/// "N GB free" / "78% used" readout in the pane footer.
class PaneFreeSpace {
  final int freeBytes;
  final int totalBytes;
  const PaneFreeSpace({required this.freeBytes, required this.totalBytes});

  /// 0..1 fraction of the volume in use (for the "78% used" form).
  double get usedFraction =>
      totalBytes > 0 ? (totalBytes - freeBytes) / totalBytes : 0;
}

/// Abstraction over "where the pane is browsing." Implementations:
///   - [LocalPaneFileSource] for the OS filesystem.
///   - [RemotePaneFileSource] for an SFTP server (wraps an [SftpService]).
///
/// Path semantics follow the source: local sources use platform paths
/// (Windows backslashes are normalized to forward slashes for display, but
/// stored paths remain in the platform's native form); remote sources use
/// POSIX paths exclusively.
abstract class PaneFileSource {
  /// Stable identifier used for hashing/keying - not for display.
  String get sourceId;

  /// True if this source uses POSIX path separators (`/`) end-to-end.
  /// Local on Windows is false; everything else is true.
  bool get isPosix;

  /// Returns the user's home directory on this source. For local, this is
  /// the platform's user-home equivalent.
  Future<String> homeDirectory();

  /// The canonical absolute form of [path] (symbolic links resolved), or
  /// [path] itself when the source cannot tell. What the remember-last-
  /// folder feature stores, so a folder reached through a link is remembered
  /// as where it really is (spec 2). Never throws.
  Future<String> realpath(String path) async => path;

  /// List entries directly under [path].
  ///
  /// When [includeHidden] is false, hides:
  /// * Unix dotfiles (`.bashrc`, `.ssh`, …) - the universal hidden
  ///   convention.
  /// * Windows protected operating-system files (NTUSER.DAT registry
  ///   hives, transaction logs, swap / hibernation files,
  ///   `desktop.ini`, `Thumbs.db`, etc.). These are `Hidden + System`
  ///   in NTFS so Windows Explorer doesn't show them even with "Show
  ///   hidden items" on; SFTP doesn't honour file attributes so we
  ///   filter them by name pattern instead.
  ///
  /// When [includeHidden] is true, every entry the server returns is
  /// surfaced (power-user view).
  Future<List<PaneFileEntry>> list(String path, {bool includeHidden = true});

  /// Stat a single file or directory. Returns null if it doesn't exist.
  Future<PaneFileEntry?> stat(String path);

  /// Free / total space on the volume holding [path], or null when it can't be
  /// determined (an SFTP server without the statvfs extension, or a local
  /// platform we can't query). Best-effort - the footer just omits the readout.
  Future<PaneFreeSpace?> freeSpace(String path) async => null;

  /// True if the path exists. Cheaper than [stat] when you only need
  /// existence (used by overwrite checks).
  Future<bool> exists(String path);

  /// Create a directory. By default fails if a parent doesn't exist; pass
  /// [recursive] to create intermediate parents.
  Future<void> mkdir(String path, {bool recursive = false});

  /// The actions of [SudoFileOps] as root through sudo, for what the host
  /// refused with "Permission denied" (3.4, Retry with sudo); null where
  /// there is no host to run sudo on (this computer).
  SudoFileOps? sudoOps() => null;

  /// Rename / move a file or directory within the same source. Cross-source
  /// moves are NOT supported - the dual-pane dispatcher handles those by
  /// copying then deleting.
  Future<void> rename(String oldPath, String newPath);

  /// Move [paths] to the OS trash / Recycle Bin, recoverable outside the app
  /// (delete safety spec, section 1). Returns true when every path was trashed,
  /// false when this source has no OS trash (every remote source, and a local
  /// volume where trash is unavailable). Default: no trash.
  Future<bool> trashPaths(List<String> paths) async => false;

  /// [trashPaths] with the reason for a refusal, so the pane can ask the user
  /// before it deletes anything permanently. Default: no trash. The reasons
  /// are shown to the person, so they come from the app-wide localizations
  /// (a file source has no context).
  Future<TrashResult> trashPathsDetailed(List<String> paths) async =>
      TrashResult(ok: false, reason: gl10n.sftpTrashReasonNoTrashSource);

  /// Delete a single file (not a directory).
  Future<void> deleteFile(String path);

  /// Delete a directory and everything under it. [onDeleted] fires once per
  /// removed entry (for Activity-queue progress); [isCancelled], polled before
  /// each removal, stops the walk and leaves a partial delete.
  Future<void> deleteDirectoryRecursive(
    String path, {
    void Function(String deletedPath)? onDeleted,
    bool Function()? isCancelled,
  });

  /// Read-only count of everything [deleteDirectoryRecursive] would remove
  /// under [path] (inclusive), for determinate delete progress.
  Future<int> countEntriesRecursive(String path);

  /// Resolve a Windows `.lnk` shortcut to its target path (local Windows pane
  /// only). Returns null when it isn't a shortcut, can't be resolved, or the
  /// source can't resolve shortcuts (e.g. a remote pane).
  Future<String?> resolveShortcut(String path) async => null;

  /// Change permissions (Unix mode). For local on Windows, the
  /// implementation is a best-effort no-op.
  Future<void> chmod(String path, int mode);

  /// Apply [mode] to [path] and everything under it, mirroring `chmod -R`
  /// (the same mode on files AND directories, the directory itself included).
  ///
  /// [onDone] fires once per entry whose mode was set; [isCancelled], polled
  /// before each op, stops the walk and leaves a PARTIAL apply. Symbolic links
  /// are skipped - never followed, never descended. On local Windows every
  /// chmod is a best-effort no-op (Windows has no Unix mode), so this walks and
  /// reports progress but changes nothing.
  Future<void> chmodRecursive(
    String path,
    int mode, {
    void Function(String path)? onDone,
    bool Function()? isCancelled,
  });

  /// Read a file's contents fully into memory. Use only for small files
  /// (configs, scripts) - large files should stream via [downloadFile].
  ///
  /// [maxBytes] caps how much will be buffered, enforced against the bytes
  /// actually received (not the server-advertised size), so a lying server
  /// can't make a "small file" open OOM the app.
  Future<Uint8List> readBytes(String path, {int? maxBytes});

  /// Write bytes to [path], replacing any existing file. Returns when the
  /// write is durable on the source.
  Future<void> writeBytes(String path, Uint8List bytes);

  /// Stream a remote file down to a local path with progress reporting.
  /// For local sources this is a copy on the same filesystem.
  ///
  /// [maxBytes], when set, is a hard ceiling enforced against the bytes
  /// actually received - a server that under-reports its size cannot bypass
  /// it. The transfer aborts (leaving nothing behind) once it is exceeded.
  ///
  /// [bulk] marks this as a queued file-manager transfer, which for a remote
  /// source routes the byte stream onto a dedicated SFTP channel so it can't
  /// block interactive listing / open-to-edit on the primary channel. Local
  /// sources ignore it (no channel involved).
  Future<void> downloadFile(
    String remotePath,
    String localPath, {
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    int? maxBytes,
    bool bulk = false,
  });

  /// Stream a local file up to a destination path on this source. For
  /// local sources this is a copy on the same filesystem.
  ///
  /// [bulk] marks this as a queued file-manager transfer; see [downloadFile].
  Future<void> uploadFile(
    String localPath,
    String remotePath, {
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    bool bulk = false,
  });

  /// Returns the parent directory of [path], or [path] itself if already
  /// at the root.
  String parentOf(String path) {
    if (isPosix) {
      if (path == '/' || path.isEmpty) return path;
      final i = path.lastIndexOf('/');
      if (i <= 0) return '/';
      return path.substring(0, i);
    }
    // Local Windows-or-platform-native: defer to package:path for correctness.
    final parent = p.dirname(path);
    return parent;
  }

  /// Joins [parent] and [name] using the source's path separator.
  String join(String parent, String name) {
    if (isPosix) {
      if (parent.endsWith('/')) return '$parent$name';
      return '$parent/$name';
    }
    return p.join(parent, name);
  }

  /// True if the two sources are backed by the same connection. Used by
  /// the dispatcher to optimize remote↔remote transfers within one host
  /// (server-side rename instead of bridge-through-local).
  bool sharesBackendWith(PaneFileSource other) =>
      runtimeType == other.runtimeType && sourceId == other.sourceId;
}

/// Patterns that match Windows-protected operating-system files /
/// directories. These are ordinarily hidden by Explorer (even with
/// "Show hidden items" enabled) because they carry the `Hidden + System`
/// NTFS attribute. SFTP doesn't expose attributes, so we filter by name.
///
/// Used by both local and remote pane sources from `list(...)` when
/// `includeHidden` is false. `includeHidden: true` short-circuits this
/// list - power users who flip the toggle want to see *everything*.
final List<RegExp> _windowsSystemFilePatterns = [
  // Registry hives: NTUSER.DAT, ntuser.dat.LOG1/2, NTUSER.DAT{guid}.TM*,
  // and the transactional registry blobs (.blf / .regtrans-ms).
  RegExp(r'^ntuser\.dat($|\.|\{)', caseSensitive: false),
  RegExp(r'^ntuser\.ini$', caseSensitive: false),
  RegExp(r'^usrclass\.dat($|\.|\{)', caseSensitive: false),
  RegExp(r'\.blf$', caseSensitive: false),
  RegExp(r'\.regtrans-ms$', caseSensitive: false),

  // Per-folder system files
  RegExp(r'^desktop\.ini$', caseSensitive: false),
  RegExp(r'^thumbs\.db$', caseSensitive: false),
  RegExp(r'^iconcache\.db$', caseSensitive: false),

  // Top-of-volume system locations
  RegExp(r'^\$recycle\.bin$', caseSensitive: false),
  RegExp(r'^system volume information$', caseSensitive: false),
  RegExp(r'^recovery$', caseSensitive: false),
  RegExp(r'^\$.+'), // $MFT, $LogFile, $Volume, $Extend, $Bitmap, etc.

  // Pagefile / hibernation / swap
  RegExp(r'^pagefile\.sys$', caseSensitive: false),
  RegExp(r'^hiberfil\.sys$', caseSensitive: false),
  RegExp(r'^swapfile\.sys$', caseSensitive: false),
  RegExp(r'^dumpstack\.log\.tmp$', caseSensitive: false),
];

/// Legacy Win9x-compatibility junctions Windows plants in a user profile
/// (`Application Data` → `AppData\Roaming`, `My Documents` → `Documents`, …).
/// They carry a DENY ACL that blocks even the owner from reading, resolving,
/// or traversing them, so they can't be opened or followed - Explorer hides
/// them (they need the separate "show protected OS files" toggle). Matched by
/// exact name, but only applied to actual LINKS, so a real folder someone
/// named "Templates" is never hidden.
const Set<String> windowsCompatJunctions = {
  'application data',
  'cookies',
  'local settings',
  'my documents',
  'my music',
  'my pictures',
  'my videos',
  'nethood',
  'printhood',
  'recent',
  'sendto',
  'start menu',
  'templates',
  'documents and settings',
};

/// True if [name] matches one of the Windows protected system file
/// patterns. Pure name match - case-insensitive where appropriate.
bool isWindowsSystemFile(String name) {
  for (final r in _windowsSystemFilePatterns) {
    if (r.hasMatch(name)) return true;
  }
  return false;
}

/// Whether a remote entry named [name] is hidden at [level]: a protected
/// Windows name at every level but None, a dotfile only at Hidden and system
/// (as a computer's remote pane decides from the flags its source sets). A
/// phone's browser decides by it.
bool remoteNameHiddenAt(SftpHiddenLevel level, String name) => switch (level) {
      SftpHiddenLevel.none => false,
      SftpHiddenLevel.systemOnly => isWindowsSystemFile(name),
      SftpHiddenLevel.hiddenAndSystem => name.startsWith('.') || isWindowsSystemFile(name),
    };

// Windows file-attribute bits: Read-only, and the two that mean "Explorer
// hides this by default".
const int _fileAttributeReadOnly = 0x1;
const int _fileAttributeHidden = 0x2;
const int _fileAttributeSystem = 0x4;
const int _invalidFileAttributes = 0xFFFFFFFF;

/// GetFileAttributesW, bound once (Windows only). Reading a path's attributes
/// does NOT open it for read or traverse, so it succeeds even on the deny-ACL
/// compat junctions whose targets can't be resolved.
final int Function(Pointer<Utf16>)? _getFileAttributesW = Platform.isWindows
    ? DynamicLibrary.open('kernel32.dll').lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)>('GetFileAttributesW')
    : null;

/// The Windows Hidden / System attribute bits for [path], as two bools - split
/// so the 3-level hidden setting can hide SYSTEM items (the
/// default) separately from HIDDEN-attribute items. Both false on non-Windows
/// and on any lookup error, so a genuine file is never wrongly hidden. This is
/// what catches `AppData` (hidden) and `$RECYCLE.BIN` (system) etc., whose names
/// look ordinary but which Explorer hides by attribute. One syscall.
({bool hidden, bool system}) windowsHiddenSystem(String path) {
  final a = windowsFileAttributes(path);
  return (hidden: a.hidden, system: a.system);
}

/// The Windows Read-only / Hidden / System attribute bits for [path]. All
/// false on non-Windows and on any lookup error. One syscall.
({bool readOnly, bool hidden, bool system}) windowsFileAttributes(
    String path) {
  const none = (readOnly: false, hidden: false, system: false);
  final fn = _getFileAttributesW;
  if (fn == null) return none;
  final ptr = path.toNativeUtf16();
  try {
    final attrs = fn(ptr);
    if (attrs == _invalidFileAttributes) return none;
    return (
      readOnly: (attrs & _fileAttributeReadOnly) != 0,
      hidden: (attrs & _fileAttributeHidden) != 0,
      system: (attrs & _fileAttributeSystem) != 0,
    );
  } catch (_) {
    return none;
  } finally {
    calloc.free(ptr);
  }
}

/// The Attributes column's letters for a Windows local entry: R, H and S, in
/// that order, for the attributes that are set ('' when none is).
String windowsAttributeLetters(
        ({bool readOnly, bool hidden, bool system}) a) =>
    '${a.readOnly ? 'R' : ''}${a.hidden ? 'H' : ''}${a.system ? 'S' : ''}';

// ── Windows Recycle Bin (SHFileOperationW) ─────────────────────────────
// Deleting through the shell with FOF_ALLOWUNDO lands files in the Recycle
// Bin, recoverable from Explorer (delete safety spec, section 1). Bound once.

const int _foDelete = 0x0003;
const int _fofSilent = 0x0004;
const int _fofNoConfirmation = 0x0010;
const int _fofAllowUndo = 0x0040;
const int _fofNoErrorUi = 0x0400;
// "Send a warning if a file is being permanently destroyed during a delete
// operation rather than recycled" (a network path, a volume with the bin
// disabled, an item over the bin's size limit). It partially overrides
// FOF_NOCONFIRMATION: the shell asks, and a No comes back as aborted, so a
// delete that cannot be recycled is never silently permanent.
const int _fofWantNukeWarning = 0x4000;

/// What the shell answered to a Recycle Bin request.
class WindowsRecycleResult {
  const WindowsRecycleResult({required this.ok, this.code, this.aborted = false});

  /// True only when every item went to the Recycle Bin.
  final bool ok;

  /// SHFileOperation's return value when it was not 0 (a DE_* code or a
  /// Win32 error), for the message shown to the user.
  final int? code;

  /// The shell asked about a permanent delete and the user said no.
  final bool aborted;

  /// A short reason for a failure, in the user's terms (and language).
  String get reason {
    if (aborted) return gl10n.sftpTrashReasonCancelled;
    switch (code) {
      case null:
        return '';
      case 0x71:
        return gl10n.sftpTrashReasonSameSource;
      case 0x74:
        return gl10n.sftpTrashReasonRoot;
      case 0x7C:
        return gl10n.sftpTrashReasonInvalidPath;
      case 0x80:
        return gl10n.sftpTrashReasonInvalidPath;
      case 0x402:
        return gl10n.sftpTrashReasonNoBinOnDrive;
      case 2:
        return gl10n.sftpTrashReasonFileNotFound;
      case 3:
        return gl10n.sftpTrashReasonPathNotFound;
      case 5:
        return gl10n.sftpTrashReasonAccessDenied;
      case 32:
        return gl10n.sftpTrashReasonInUse;
      default:
        return gl10n.sftpTrashReasonShellError(code!.toRadixString(16));
    }
  }
}

/// SHFILEOPSTRUCTW. FFI inserts the x64 alignment padding automatically.
final class _ShFileOpW extends Struct {
  external Pointer<Void> hwnd;
  @Uint32()
  external int wFunc;
  external Pointer<Utf16> pFrom;
  external Pointer<Utf16> pTo;
  @Uint16()
  external int fFlags;
  @Int32()
  external int fAnyOperationsAborted;
  external Pointer<Void> hNameMappings;
  external Pointer<Utf16> lpszProgressTitle;
}

final int Function(Pointer<_ShFileOpW>)? _shFileOperationW = Platform.isWindows
    ? DynamicLibrary.open('shell32.dll').lookupFunction<
        Int32 Function(Pointer<_ShFileOpW>),
        int Function(Pointer<_ShFileOpW>)>('SHFileOperationW')
    : null;

/// Move [paths] to the Recycle Bin. True only when the shell reports success
/// and nothing was aborted; false on any error, e.g. a volume with the
/// Recycle Bin disabled. See [windowsRecycleDetailed] for the reason.
bool windowsRecycle(List<String> paths) => windowsRecycleDetailed(paths).ok;

/// [windowsRecycle] with the shell's answer attached, so a refusal can be
/// explained instead of quietly falling through to a permanent delete.
WindowsRecycleResult windowsRecycleDetailed(List<String> paths) {
  final fn = _shFileOperationW;
  if (fn == null || paths.isEmpty) return const WindowsRecycleResult(ok: false);
  // Double-null-terminated list of ABSOLUTE backslash paths. `toNativeUtf16`
  // copies the embedded NULs and appends the final terminator.
  final joined =
      '${paths.map((p) => p.replaceAll('/', r'\')).join('\x00')}\x00';
  final pFrom = joined.toNativeUtf16();
  final op = calloc<_ShFileOpW>();
  try {
    op.ref
      ..wFunc = _foDelete
      ..pFrom = pFrom
      ..fFlags = _fofAllowUndo |
          _fofNoConfirmation |
          _fofSilent |
          _fofNoErrorUi |
          _fofWantNukeWarning;
    final rc = fn(op);
    final aborted = op.ref.fAnyOperationsAborted != 0;
    if (rc == 0 && !aborted) return const WindowsRecycleResult(ok: true);
    return WindowsRecycleResult(
        ok: false, code: rc == 0 ? null : rc, aborted: aborted);
  } catch (_) {
    return const WindowsRecycleResult(ok: false);
  } finally {
    calloc.free(pFrom);
    calloc.free(op);
  }
}

/// [windowsRecycleDetailed] in a helper isolate. The shell call returns only
/// once everything is in the bin, which for a big folder is seconds: time the
/// UI thread must not spend waiting, or the window stops answering. The shell
/// expects COM on the calling thread, so the helper sets it up for the call
/// and takes it down again.
Future<WindowsRecycleResult> windowsRecycleInHelper(List<String> paths) =>
    Isolate.run(() => _recycleWithCom(paths), debugName: 'recycle');

WindowsRecycleResult _recycleWithCom(List<String> paths) {
  if (!Platform.isWindows) return const WindowsRecycleResult(ok: false);
  const coinitApartmentThreaded = 0x2;
  final ole32 = DynamicLibrary.open('ole32.dll');
  final coInitializeEx = ole32.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32),
      int Function(Pointer<Void>, int)>('CoInitializeEx');
  final coUninitialize =
      ole32.lookupFunction<Void Function(), void Function()>('CoUninitialize');
  // S_OK (0) and S_FALSE (1) both ask for a matching uninitialize; a negative
  // answer (the thread is already set up another way) asks for none.
  final hr = coInitializeEx(nullptr, coinitApartmentThreaded);
  try {
    return windowsRecycleDetailed(paths);
  } finally {
    if (hr >= 0) coUninitialize();
  }
}

/// The outcome of a trash request: [ok] when every item is in the OS trash,
/// else [reason] in the user's terms and [cancelled] when the OS asked about
/// a permanent delete and the user said no.
class TrashResult {
  const TrashResult({required this.ok, this.reason = '', this.cancelled = false});

  final bool ok;
  final String reason;
  final bool cancelled;
}

/// PaneFileSource backed by `dart:io` for the local OS filesystem.
class LocalPaneFileSource extends PaneFileSource {
  LocalPaneFileSource({@visibleForTesting this.debugOs, @visibleForTesting this.phoneFolder});

  /// The system, as [Platform.operatingSystem] names it, for tests.
  final String? debugOs;

  /// Where a phone's pane starts, for tests ([downloadSaveFolder]).
  final Future<Directory> Function()? phoneFolder;

  @override
  String get sourceId => 'local';

  @override
  bool get isPosix => Platform.pathSeparator == '/';

  /// On a phone (an FTPS host opens the two panes there too) the pane starts
  /// where the file browser's Download saves, a folder the app may list and
  /// the person can find: HOME is unset or the system's root for an Android
  /// app, which it may not list, and the app's container on an iPhone, which
  /// Files does not show. On a computer, the
  /// account's home.
  @override
  Future<String> homeDirectory() async {
    final os = debugOs ?? Platform.operatingSystem;
    if (os == 'android' || os == 'ios') return (await (phoneFolder ?? downloadSaveFolder)()).path;
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    return home;
  }

  @override
  Future<String> realpath(String path) async {
    try {
      return await Directory(path).resolveSymbolicLinks();
    } catch (_) {
      return path;
    }
  }

  @override
  Future<PaneFreeSpace?> freeSpace(String path) async {
    try {
      if (Platform.isWindows) {
        // Windows' own free-space call, made in a helper isolate: no program
        // is started (this used to launch PowerShell once per drive), and a
        // network drive that does not answer keeps only the helper waiting.
        // Works for a drive, a folder and a \\server\share path alike.
        final space = await windowsDiskSpace(path);
        if (space == null) return null;
        return PaneFreeSpace(freeBytes: space.free, totalBytes: space.total);
      }
      // macOS / Linux: `df -Pk` → data row columns are
      // [filesystem, 1024-blocks, used, available, capacity, mounted-on].
      final res = await Process.run('df', ['-Pk', path]);
      if (res.exitCode != 0) return null;
      final lines = res.stdout.toString().trim().split('\n');
      if (lines.length < 2) return null;
      final cols = lines[1].trim().split(RegExp(r'\s+'));
      if (cols.length < 4) return null;
      final totalKb = int.tryParse(cols[1]);
      final availKb = int.tryParse(cols[3]);
      if (totalKb == null || availKb == null) return null;
      return PaneFreeSpace(
          freeBytes: availKb * 1024, totalBytes: totalKb * 1024);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<PaneFileEntry>> list(
    String path, {
    bool includeHidden = true,
  }) =>
      _listInHelper(path, includeHidden);

  @override
  Future<PaneFileEntry?> stat(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    try {
      final stat = await FileStat.stat(path);
      return PaneFileEntry(
        name: p.basename(path),
        path: path,
        isDirectory: type == FileSystemEntityType.directory,
        size: type == FileSystemEntityType.file ? stat.size : 0,
        modifiedAt: stat.modified,
        permissions: _unixModeString(stat.mode, type),
        // `type` was resolved with followLinks: false above.
        isSymlink: type == FileSystemEntityType.link,
        modeBits: stat.mode & 0x1FF,
        windowsAttributes: Platform.isWindows
            ? windowsAttributeLetters(windowsFileAttributes(path))
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> exists(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    return type != FileSystemEntityType.notFound;
  }

  @override
  Future<void> mkdir(String path, {bool recursive = false}) async {
    await Directory(path).create(recursive: recursive);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final type = await FileSystemEntity.type(oldPath, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(oldPath).rename(newPath);
    } else {
      await File(oldPath).rename(newPath);
    }
  }

  static const MethodChannel _nativeTrashChannel =
      MethodChannel('zestssh/native_trash');

  @override
  Future<bool> trashPaths(List<String> paths) async =>
      (await trashPathsDetailed(paths)).ok;

  @override
  Future<TrashResult> trashPathsDetailed(List<String> paths) async {
    if (paths.isEmpty) return const TrashResult(ok: true);
    // Windows: shell Recycle Bin. macOS: NSFileManager.trashItem via the native
    // channel. Linux: gio trash (GLib) where it exists. A refusal is reported
    // with its reason; the pane then asks before deleting permanently, never
    // quietly.
    if (Platform.isWindows) {
      try {
        final r = await windowsRecycleInHelper(paths);
        return TrashResult(
            ok: r.ok, reason: r.reason, cancelled: r.aborted);
      } catch (e) {
        AppLogger.warning('The Recycle Bin refused: $e');
        return TrashResult(ok: false, reason: gl10n.sftpTrashReasonUnknown);
      }
    }
    if (Platform.isMacOS) {
      try {
        final ok = await _nativeTrashChannel
            .invokeMethod<bool>('trash', {'paths': paths});
        return TrashResult(
            ok: ok == true,
            reason: ok == true ? '' : gl10n.sftpTrashReasonFinder);
      } catch (e) {
        AppLogger.warning('The Trash refused: $e');
        return TrashResult(ok: false, reason: gl10n.sftpTrashReasonUnknown);
      }
    }
    if (Platform.isLinux) {
      // gio (GLib) implements the freedesktop trash spec, including the
      // per-volume .Trash folders; it is present on every desktop that has
      // a file manager. Absolute path, never a bare name.
      try {
        final res = await Process.run('gio', ['trash', ...paths]);
        if (res.exitCode == 0) return const TrashResult(ok: true);
        // (What gio said, in English and with the path in it, is logged.)
        AppLogger.warning('gio trash failed (${res.exitCode}): ${res.stderr.toString().trim()}');
        return TrashResult(ok: false, reason: gl10n.sftpTrashReasonGioFailed);
      } on ProcessException {
        return TrashResult(
            ok: false, reason: gl10n.sftpTrashReasonGioMissing);
      } catch (e) {
        AppLogger.warning('The trash refused: $e');
        return TrashResult(ok: false, reason: gl10n.sftpTrashReasonUnknown);
      }
    }
    return TrashResult(ok: false, reason: gl10n.sftpTrashReasonNoPlatform);
  }

  @override
  Future<void> deleteFile(String path) async {
    await File(path).delete();
  }

  @override
  Future<void> deleteDirectoryRecursive(
    String path, {
    void Function(String deletedPath)? onDeleted,
    bool Function()? isCancelled,
  }) async {
    // Local delete is atomic (the OS removes the whole tree in one call), so
    // per-item progress isn't available and cancel can't interrupt it - but the
    // op still shows in Activity and completes near-instantly. Report the root
    // once so the count-based row reads 1 of 1.
    await Directory(path).delete(recursive: true);
    onDeleted?.call(path);
  }

  @override
  Future<int> countEntriesRecursive(String path) async {
    // Atomic local delete → a single "item" for progress purposes.
    return 1;
  }

  @override
  Future<String?> resolveShortcut(String path) async {
    if (!Platform.isWindows) return null;
    if (!path.toLowerCase().endsWith('.lnk')) return null;
    try {
      // Resolve a Windows .lnk the same way Explorer does - the shell's
      // WScript.Shell COM object. The path is handed over in an environment
      // variable, which PowerShell reads as text and never as code: a name
      // can hold no quote that ends a string there. (It was a single-quoted
      // literal with its quotes doubled, but PowerShell also ends such a
      // string at the typographic quotes U+2018 to U+201B, which a file's name
      // may hold: a shortcut so named, downloaded from a host and opened in
      // the local pane, ran what its name said.)
      // Invoke PowerShell by its ABSOLUTE path under System32, never a bare
      // `powershell` - so a hostile powershell.exe planted earlier on $PATH
      // (or historically the working directory) can't be run in the real
      // one's stead. Windows PowerShell 5.1 ships in-box at this fixed
      // location on every install. Mirrors the absolute-path chmod below.
      final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
      final psExe =
          '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      final result = await Process.run(
        psExe,
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'(New-Object -ComObject WScript.Shell).CreateShortcut($env:ZEST_SHORTCUT).TargetPath',
        ],
        environment: {'ZEST_SHORTCUT': path},
      );
      if (result.exitCode != 0) return null;
      final target = (result.stdout as String).trim();
      return target.isEmpty ? null : target;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> chmod(String path, int mode) async {
    if (Platform.isWindows) return; // No-op on Windows.
    // dart:io doesn't expose chmod directly; shell out to the native tool.
    // Use an ABSOLUTE binary path rather than a PATH-resolved `chmod`, so a
    // hostile `chmod` earlier on $PATH can't be run in our stead, and pass a
    // `--` end-of-options guard so a filename beginning with `-` (e.g.
    // "--reference=…") is treated as a path, never as a flag.
    final chmodBin =
        await File('/bin/chmod').exists() ? '/bin/chmod' : '/usr/bin/chmod';
    final res = await Process.run(chmodBin, [
      '--',
      mode.toRadixString(8).padLeft(3, '0'),
      path,
    ]);
    if (res.exitCode != 0) {
      throw Exception('chmod failed: ${res.stderr}');
    }
  }

  @override
  Future<void> chmodRecursive(
    String path,
    int mode, {
    void Function(String path)? onDone,
    bool Function()? isCancelled,
  }) =>
      _chmodTree(path, mode, 0, onDone, isCancelled);

  /// Depth-first best-effort recursive chmod over the local tree. Children
  /// first, then the directory itself (so its read/execute survives the walk),
  /// mirroring the remote path. Symlinks are neither followed nor chmod'd -
  /// `dir.list(followLinks: false)` hands back a [Link] for one, which we skip.
  /// On Windows [chmod] is a no-op, so this reports progress but changes
  /// nothing.
  Future<void> _chmodTree(
    String path,
    int mode,
    int depth,
    void Function(String path)? onDone,
    bool Function()? isCancelled,
  ) async {
    if (depth > SftpService.maxRecursionDepth) return;
    await for (final ent in Directory(path).list(followLinks: false)) {
      if (isCancelled?.call() ?? false) return;
      if (ent is Link) continue; // never follow / chmod a link
      if (ent is Directory) {
        await _chmodTree(ent.path, mode, depth + 1, onDone, isCancelled);
        if (isCancelled?.call() ?? false) return;
      } else {
        await chmod(ent.path, mode);
        onDone?.call(ent.path);
      }
    }
    if (isCancelled?.call() ?? false) return;
    await chmod(path, mode);
    onDone?.call(path);
  }

  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) =>
      // Local file on a trusted filesystem - no lying peer, so the cap carries
      // no security weight and the size is what the OS reports.
      File(path).readAsBytes();

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    await File(path).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> downloadFile(
    String remotePath,
    String localPath, {
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    int? maxBytes,
    bool bulk = false,
  }) async {
    // Local→Local "download" is just a file copy on a trusted filesystem -
    // there is no lying peer, so [maxBytes] carries no security weight here,
    // and [bulk] has no channel to route onto.
    await _streamCopy(File(remotePath), File(localPath), onProgress, cancelToken);
  }

  @override
  Future<void> uploadFile(
    String localPath,
    String remotePath, {
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    bool bulk = false,
  }) async {
    await _streamCopy(File(localPath), File(remotePath), onProgress, cancelToken);
  }

  Future<void> _streamCopy(
    File source,
    File dest,
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  ) async {
    final total = await source.length();
    var transferred = 0;
    // Stage to a sibling `.zestpart` file and only rename onto the real
    // destination once the whole copy has landed and its length has been
    // verified. Writing straight to `dest` truncates it on open, so a cancel
    // or mid-copy error would leave the user with a truncated (or empty)
    // destination while their source is still intact - silent data loss for a
    // same-filesystem "copy". The SFTP download path uses exactly this pattern.
    final staging = File('${dest.path}.zestpart');
    final sink = staging.openWrite();
    var completed = false;
    // Bound the in-memory write buffer: `sink.add` doesn't block, so on a slow
    // destination (a cloud-synced folder) chunks pile up and OOM on big files.
    const flushThresholdBytes = 8 * 1024 * 1024;
    var sinceFlush = 0;
    // Throttle progress to integer-percent changes, mirroring the SFTP
    // streaming paths. Firing onProgress on every read chunk rebuilds the whole
    // Activity queue on the UI isolate per chunk - enough churn to jank a large
    // same-filesystem copy. Unknown-size (0-length) sources yield no chunks, so
    // the else branch is only a defensive fallback.
    var lastReportedPercent = -1;
    try {
      // await for, so the flush is waited for and the read pauses meanwhile:
      // an IOSink takes no add() while a flush runs ("StreamSink is bound to
      // a stream"), and a flush that was not waited for failed every copy
      // over the threshold (the SSH lane's deep review).
      await for (final chunk in source.openRead()) {
        cancelToken?.throwIfCancelled();
        sink.add(chunk);
        transferred += chunk.length;
        sinceFlush += chunk.length;
        if (sinceFlush >= flushThresholdBytes) {
          await sink.flush();
          sinceFlush = 0;
        }
        if (onProgress != null) {
          if (total > 0) {
            final percent = transferred * 100 ~/ total;
            if (percent != lastReportedPercent) {
              lastReportedPercent = percent;
              onProgress(transferred, total);
            }
          } else {
            onProgress(transferred, total);
          }
        }
      }
      // close() writes the rest and reports a write that failed.
      await sink.close();
      completed = true;
    } finally {
      if (!completed) {
        // Closed before the partial is deleted (Windows will not delete an
        // open file); its error is the one already being thrown, or none.
        try {
          await sink.close();
        } catch (_) {}
      }
      if (completed) {
        // Fail closed on a short copy before publishing (skips size 0 sources).
        verifyTransferSize(
          path: dest.path,
          expected: total,
          actual: await staging.length(),
        );
        // File.rename replaces on POSIX but throws on Windows if the target
        // exists, so remove the old destination first - only ever once a
        // complete replacement exists in staging, so nothing is lost.
        try {
          if (await dest.exists()) await dest.delete();
        } catch (_) {}
        await staging.rename(dest.path);
        // Carry the source mtime across, as the SFTP paths do, so a later
        // "replace changed files" copy recognises the unchanged file by size
        // and time instead of hashing it. Best-effort.
        try {
          await dest.setLastModified(await source.lastModified());
        } catch (_) {}
      } else {
        // Cancel or error: drop the partial so no truncated file is left.
        try {
          if (await staging.exists()) await staging.delete();
        } catch (_) {}
      }
    }
  }

}

/// Pretty-print a Unix mode like `rwxr-xr--`. On Windows the mode bits
/// don't carry the same meaning, but `dart:io` still returns sensible
/// values for read/write/execute on most paths.
String _unixModeString(int mode, FileSystemEntityType type) {
  final dirChar = type == FileSystemEntityType.directory ? 'd' : '-';
  String triplet(int bits) {
    return '${(bits & 4) != 0 ? 'r' : '-'}'
        '${(bits & 2) != 0 ? 'w' : '-'}'
        '${(bits & 1) != 0 ? 'x' : '-'}';
  }

  return dirChar +
      triplet((mode >> 6) & 7) +
      triplet((mode >> 3) & 7) +
      triplet(mode & 7);
}

/// A local folder's entries, read in a helper isolate.
///
/// Reading a folder asks the disk about every entry (its type, size and time,
/// and on Windows its attributes, which is a blocking system call). Done on
/// the UI thread that is one stall per entry: unnoticeable on an SSD, a
/// stutter on a big folder, and a frozen window on a network drive that
/// answers slowly or not at all. In the helper the same questions are asked
/// back to back with nothing else waiting on them, which is also faster than
/// thousands of round trips between the UI thread and the I/O threads.
Future<List<PaneFileEntry>> _listInHelper(String path, bool includeHidden) =>
    Isolate.run(() => listLocalDirectory(path, includeHidden: includeHidden),
        debugName: 'local-listing');

/// The entries directly under the local folder [path], read on the calling
/// thread (see [_listInHelper]; a test may call it directly). Throws a
/// [FileSystemException] when the folder is not there or cannot be read.
List<PaneFileEntry> listLocalDirectory(String path,
    {bool includeHidden = true}) {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    throw PathNotFoundException(path, const OSError('Directory not found', 2));
  }
  final out = <PaneFileEntry>[];
  for (final ent in dir.listSync(followLinks: false)) {
    final name = p.basename(ent.path);
    // `listSync(followLinks: false)` hands back a Link for a symlink OR a
    // Windows junction, so this identifies one without a second syscall. It
    // matters the same way it does remotely: a recursive copy or delete must
    // act on the link, not on whatever it points at.
    final isLink = ent is Link;
    // Two hidden CATEGORIES so the 3-level setting can treat them separately
    // as follows:
    //  · SYSTEM - a protected-OS name ($RECYCLE.BIN, pagefile, desktop.ini…),
    //    a deny-ACL compat junction, or the Windows System attribute. Hidden
    //    at the DEFAULT level.
    //  · HIDDEN - a leading dot (POSIX) or the Windows Hidden attribute.
    //    Hidden only at the "Hidden and system" level.
    final attr = windowsFileAttributes(ent.path);
    final winAttrs = Platform.isWindows ? windowsAttributeLetters(attr) : null;
    final isSystemHidden = isWindowsSystemFile(name) ||
        (isLink && windowsCompatJunctions.contains(name.toLowerCase())) ||
        attr.system;
    final isHidden = name.startsWith('.') || attr.hidden;
    if (!includeHidden && (isHidden || isSystemHidden)) continue;
    // Capture where a link points (best-effort) so the row can show
    // "to <target>" and follow it - parity with the remote pane, which
    // resolves targets via readlink.
    String? linkTarget;
    if (isLink) {
      try {
        linkTarget = Link(ent.path).targetSync();
      } catch (_) {
        // Target text unreadable - the row renders "target not readable".
      }
    }
    // dart:io answers a stat that failed with type "not found" and zeroed
    // fields; it does not throw. That is a broken link (target gone) or a
    // file the system keeps locked (pagefile.sys). Either still belongs in
    // the listing, with no permissions and no date, which the row renders as
    // "Not readable" rather than passing off a 1970 date as real.
    FileStat? stat;
    try {
      final s = ent.statSync();
      if (s.type != FileSystemEntityType.notFound) stat = s;
    } catch (_) {}
    if (stat == null) {
      out.add(PaneFileEntry(
        name: name,
        path: ent.path,
        isDirectory: !isLink && ent is Directory,
        isSymlink: isLink,
        linkTarget: linkTarget,
        isHidden: isHidden,
        isSystemHidden: isSystemHidden,
        windowsAttributes: winAttrs,
      ));
      continue;
    }
    out.add(PaneFileEntry(
      name: name,
      path: ent.path,
      isDirectory: !isLink && stat.type == FileSystemEntityType.directory,
      size: stat.type == FileSystemEntityType.file ? stat.size : 0,
      modifiedAt: stat.modified,
      permissions: _unixModeString(stat.mode, stat.type),
      isSymlink: isLink,
      modeBits: stat.mode & 0x1FF,
      linkTarget: linkTarget,
      isHidden: isHidden,
      isSystemHidden: isSystemHidden,
      windowsAttributes: winAttrs,
    ));
  }
  return out;
}

/// PaneFileSource backed by an [SftpService] talking to a remote host.
///
/// The service is borrowed, not owned - closing it is the caller's
/// responsibility (typically the leaf widget that opened it).
class RemotePaneFileSource extends PaneFileSource {
  final SftpService _sftp;
  @override
  final String sourceId;

  RemotePaneFileSource({required SftpService service, required this.sourceId})
      : _sftp = service;

  /// Underlying SFTP service - exposed so legacy code paths (sync, deep
  /// search, etc.) that still consume [SftpService] directly can be ported
  /// piecewise.
  SftpService get service => _sftp;

  @override
  bool get isPosix => true;

  @override
  Future<String> homeDirectory() => _sftp.getHomeDirectory();

  @override
  Future<String> realpath(String path) async {
    try {
      final real = await _sftp.realPath(path);
      return real.isEmpty ? path : real;
    } catch (_) {
      return path;
    }
  }

  @override
  Future<PaneFreeSpace?> freeSpace(String path) async {
    final v = await _sftp.statvfs(path);
    if (v == null) return null;
    return PaneFreeSpace(freeBytes: v.freeBytes, totalBytes: v.totalBytes);
  }

  @override
  Future<List<PaneFileEntry>> list(
    String path, {
    bool includeHidden = true,
  }) async {
    // A file session that is over while its connection goes on (the host
    // ended it, or whoever else held this service closed it) is opened
    // again here, where Retry and Refresh end up. Where the connection is
    // gone too, that fails with what ended it, as the listing would.
    if (!_sftp.isOpen) await _sftp.open();
    final entries = await _sftp.listDirectory(path);
    // Classify by the POSIX predicate (leading dot) plus the protected-OS names
    // an SFTP server can't flag by attribute. The flag rides with each entry so
    // the pane can filter + count; the remote default is to SHOW dotfiles, since
    // .ssh/.env/.bashrc are most of the reason to open a remote pane.
    final flagged = [
      for (final e in entries)
        e.withHiddenFlags(
          // On a remote (POSIX) source the "hidden" category is a leading dot;
          // the "system" category is the protected-OS names an SFTP server can't
          // flag by attribute (rare remotely). Remote dotfiles show at the
          // DEFAULT level - .ssh / .env / .bashrc are the point.
          hidden: e.name.startsWith('.'),
          systemHidden: isWindowsSystemFile(e.name),
        ),
    ];
    if (includeHidden) return flagged;
    return flagged.where((e) => !e.isHidden && !e.isSystemHidden).toList();
  }

  @override
  Future<PaneFileEntry?> stat(String path) async {
    try {
      final attrs = await _sftp.stat(path);
      return PaneFileEntry(
        name: p.posix.basename(path),
        path: path,
        isDirectory: attrs.isDirectory,
        size: attrs.size ?? 0,
        modifiedAt: attrs.modifyTime != null
            ? DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000)
            : null,
        // Mode bits → "rwxrwxrwx" string for parity with listing rows.
        permissions: _modeToPermsString(attrs),
        // NOTE: this stat FOLLOWS links (the overwrite-conflict check wants
        // the target's size/mtime), so a link reports its target's type here
        // and isSymlink stays false. The listing path uses readdir, which
        // does not follow, and that is what recursive walks consult.
        isSymlink: attrs.isSymbolicLink,
        modeBits: attrs.mode?.value,
      );
    } catch (_) {
      return null;
    }
  }

  /// Approximate Unix-style permission string from the SFTP attrs.
  /// dartssh2 only exposes the mode integer; we render the canonical
  /// rwx triplets so the properties dialog has something to show.
  String? _modeToPermsString(dynamic attrs) {
    final modeRaw = attrs.mode;
    if (modeRaw == null) return null;
    // The low nine bits of the mode are the permissions (SftpFileMode has
    // no permissions getter: reading one threw, and stat said every remote
    // file with a mode was not there, so an overwrite was never asked).
    final perms = (modeRaw.value as int) & 0x1ff;
    String triplet(int bits) =>
        '${(bits & 4) != 0 ? 'r' : '-'}'
        '${(bits & 2) != 0 ? 'w' : '-'}'
        '${(bits & 1) != 0 ? 'x' : '-'}';
    final dirChar = attrs.isDirectory ? 'd' : '-';
    return dirChar +
        triplet((perms >> 6) & 7) +
        triplet((perms >> 3) & 7) +
        triplet(perms & 7);
  }

  @override
  Future<bool> exists(String path) async {
    try {
      await _sftp.stat(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> mkdir(String path, {bool recursive = false}) async {
    if (recursive) {
      await _sftp.createDirectoryRecursive(path);
    } else {
      await _sftp.createDirectory(path);
    }
  }

  @override
  Future<void> rename(String oldPath, String newPath) =>
      _sftp.rename(oldPath, newPath);

  @override
  Future<void> deleteFile(String path) => _sftp.deleteFile(path);

  @override
  SudoFileOps? sudoOps() => _sftp.sudoFileOps();

  @override
  Future<void> deleteDirectoryRecursive(
    String path, {
    void Function(String deletedPath)? onDeleted,
    bool Function()? isCancelled,
  }) =>
      _sftp.deleteDirectoryRecursive(
        path,
        onDeleted: onDeleted,
        isCancelled: isCancelled,
      );

  @override
  Future<int> countEntriesRecursive(String path) =>
      _sftp.countEntriesRecursive(path);

  @override
  Future<void> chmod(String path, int mode) => _sftp.chmod(path, mode);

  @override
  Future<void> chmodRecursive(
    String path,
    int mode, {
    void Function(String path)? onDone,
    bool Function()? isCancelled,
  }) =>
      _sftp.chmodRecursive(
        path,
        mode,
        onDone: onDone,
        isCancelled: isCancelled,
      );

  // Between the host and this device's memory, both ways. (A file was read
  // by downloading it to a file in this device's temporary folder and
  // reading that, and written by writing a file there and uploading it: what
  // the editor opened and saved, and every image that was looked at, lay on
  // this device's disk in the clear meanwhile, and stayed there where the
  // app was ended before it was cleared away.)

  /// No more than [maxBytes] of it, held against the bytes that come and
  /// not against the size the host reports ([SftpService.downloadFile],
  /// which has a limit of its own where none is given).
  @override
  Future<Uint8List> readBytes(String path, {int? maxBytes}) => _sftp.downloadFile(path, maxBytes: maxBytes);

  /// As an upload is written: beside the file, and into its place once the
  /// host has all of it ([SftpService.uploadFile]). Its time is the host's
  /// own, and a file that is new is what the host makes a new file.
  @override
  Future<void> writeBytes(String path, Uint8List bytes) => _sftp.uploadFile(path, bytes);

  @override
  Future<void> downloadFile(
    String remotePath,
    String localPath, {
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    int? maxBytes,
    bool bulk = false,
  }) =>
      _sftp.downloadFileToPath(remotePath, localPath,
          onProgress: onProgress,
          cancelToken: cancelToken,
          maxBytes: maxBytes,
          useTransferChannel: bulk);

  @override
  Future<void> uploadFile(
    String localPath,
    String remotePath, {
    PaneTransferProgress? onProgress,
    TransferCancelToken? cancelToken,
    bool bulk = false,
  }) =>
      _sftp.uploadFileFromPath(localPath, remotePath,
          onProgress: onProgress,
          cancelToken: cancelToken,
          useTransferChannel: bulk);
}
