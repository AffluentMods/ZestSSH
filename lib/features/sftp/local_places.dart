/// The local quick-jump places of the SFTP rail (Home, Downloads, Desktop,
/// Documents and the drives), found WITHOUT ever making the caller wait on a
/// disk or the network.
///
/// On 2.2.1 (Windows), opening SFTP froze the whole window for
/// about 30 seconds. The screen asked, on the UI thread and one letter at a
/// time, whether `A:\` to `Z:\` exist. A drive letter mapped to a NAS or
/// server that is off makes Windows wait out its network timeout before it
/// answers (measured: 42 s for one unreachable share), and nothing can paint
/// in the meantime. So here:
///   * the drives Windows already lists come from its own bitmask, which is
///     held in memory and touches no drive;
///   * everything that has to ask a disk (does this folder exist, does a
///     letter Windows does not list answer after all, how much space is free)
///     is asked off the UI thread, and each answer is added when it arrives.
///     One that never arrives holds up nothing else.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// What a place is, so the screen can pick its icon and its translated name.
enum LocalPlaceKind { home, downloads, desktop, documents, drive }

/// One quick-jump place on this computer.
class LocalPlace {
  const LocalPlace(this.kind, this.label, this.path);

  final LocalPlaceKind kind;

  /// The stored label: the English folder name for a user folder (the pin
  /// repair looks a seed up by it), `C:` for a drive, `/` for the root.
  final String label;
  final String path;

  /// A drive or the filesystem root: fixed, never a pin.
  bool get isRoot => kind == LocalPlaceKind.drive;

  @override
  bool operator ==(Object other) =>
      other is LocalPlace &&
      other.kind == kind &&
      other.label == label &&
      other.path == path;

  @override
  int get hashCode => Object.hash(kind, label, path);

  @override
  String toString() => 'LocalPlace($label, $path)';
}

/// The drive letters set in a `GetLogicalDrives` bitmask (bit 0 = A).
List<String> driveLettersOf(int mask) => [
      for (var i = 0; i < 26; i++)
        if (mask & (1 << i) != 0) String.fromCharCode(0x41 + i),
    ];

/// Finds the local places. Every way it reaches outside is a parameter, so a
/// test can hand it a drive that never answers.
class LocalPlacesFinder {
  LocalPlacesFinder({
    Map<String, String>? environment,
    bool? isWindows,
    int Function()? driveMask,
    Future<bool> Function(String path)? directoryExists,
    Future<bool> Function(String root)? driveIsEmpty,
  })  : _env = environment ?? Platform.environment,
        _isWindows = isWindows ?? Platform.isWindows,
        _driveMask = driveMask ?? windowsLogicalDrives,
        _exists = directoryExists ?? _directoryExists,
        _driveIsEmpty = driveIsEmpty ?? windowsDriveIsEmpty;

  final Map<String, String> _env;
  final bool _isWindows;
  final int Function() _driveMask;
  final Future<bool> Function(String path) _exists;
  final Future<bool> Function(String root) _driveIsEmpty;

  /// The user folders seeded as pins, in rail order.
  static const _folders = <(LocalPlaceKind, String)>[
    (LocalPlaceKind.downloads, 'Downloads'),
    (LocalPlaceKind.desktop, 'Desktop'),
    (LocalPlaceKind.documents, 'Documents'),
  ];

  String? get _home {
    final home = _env['USERPROFILE'] ?? _env['HOME'];
    return (home == null || home.isEmpty) ? null : home;
  }

  p.Context get _path => _isWindows ? p.windows : p.posix;

  String _driveRoot(String letter) => '$letter:\\';

  /// What is known at once, with no disk or network access: Home, and the
  /// drives Windows lists (elsewhere, the filesystem root).
  List<LocalPlace> immediate() => _compose(const {}, _listedLetters());

  Set<String> _listedLetters() {
    if (!_isWindows) return const {};
    int mask;
    try {
      mask = _driveMask();
    } catch (_) {
      mask = 0;
    }
    return driveLettersOf(mask).toSet();
  }

  List<LocalPlace> _compose(
      Map<LocalPlaceKind, String> folders, Set<String> letters) {
    final home = _home;
    final sorted = letters.toList()..sort();
    return [
      if (home != null) LocalPlace(LocalPlaceKind.home, 'Home', home),
      if (home != null)
        for (final (kind, name) in _folders)
          if (folders[kind] != null) LocalPlace(kind, name, folders[kind]!),
      if (_isWindows)
        for (final letter in sorted)
          LocalPlace(LocalPlaceKind.drive, '$letter:', _driveRoot(letter))
      else
        const LocalPlace(LocalPlaceKind.drive, '/', '/'),
    ];
  }

  /// A user folder ([name] = Desktop, Documents or Downloads) as a path that
  /// really exists, or null. On a computer where OneDrive keeps these
  /// folders they live under the OneDrive folder, not the plain profile, so
  /// the OneDrive locations are asked first.
  Future<String?> resolveUserFolder(String name) async {
    final home = _home;
    if (home == null) return null;
    final candidates = <String>[
      for (final key in const [
        'OneDrive',
        'OneDriveConsumer',
        'OneDriveCommercial'
      ])
        if ((_env[key] ?? '').isNotEmpty) _path.join(_env[key]!, name),
      _path.join(home, name),
    ];
    for (final candidate in candidates) {
      if (await _safeExists(candidate)) return candidate;
    }
    return null;
  }

  Future<bool> _safeExists(String path) async {
    try {
      return await _exists(path);
    } catch (_) {
      return false;
    }
  }

  /// Every place, as a full list in rail order each time one more is known.
  /// The first event is [immediate]. A check that never answers (a mapped
  /// drive whose server is off) delays only itself; the stream closes once
  /// every check has answered. Cancel it when the screen goes.
  Stream<List<LocalPlace>> watch() {
    late final StreamController<List<LocalPlace>> controller;
    var cancelled = false;

    void start() {
      final folders = <LocalPlaceKind, String>{};
      final listed = _listedLetters();
      final letters = {...listed};
      var open = 0;

      void emit() {
        if (!cancelled) controller.add(_compose(folders, letters));
      }

      void track(Future<void> work) {
        open++;
        work.whenComplete(() {
          open--;
          if (open == 0 && !cancelled) controller.close();
        });
      }

      emit();
      if (_home != null) {
        for (final (kind, name) in _folders) {
          track(() async {
            final resolved = await resolveUserFolder(name);
            if (resolved == null) return;
            folders[kind] = resolved;
            emit();
          }());
        }
      }
      if (_isWindows) {
        for (var i = 0; i < 26; i++) {
          final letter = String.fromCharCode(0x41 + i);
          if (listed.contains(letter)) {
            // Windows also lists a card reader or disc drive with nothing in
            // it. That is not a place to go, so it leaves the rail again
            // (File Explorer hides those too). A network drive never does:
            // off or not, it stays where the person expects it.
            track(() async {
              bool empty;
              try {
                empty = await _driveIsEmpty(_driveRoot(letter));
              } catch (_) {
                empty = false;
              }
              if (!empty) return;
              letters.remove(letter);
              emit();
            }());
            continue;
          }
          // A letter Windows does not list can still be a remembered network
          // drive it has not reconnected yet; asking wakes it up. A letter
          // with nothing behind it answers no at once.
          track(() async {
            if (!await _safeExists(_driveRoot(letter))) return;
            letters.add(letter);
            emit();
          }());
        }
      }
      if (open == 0) controller.close();
    }

    controller = StreamController<List<LocalPlace>>(
      onListen: start,
      onCancel: () => cancelled = true,
    );
    return controller.stream;
  }
}

Future<bool> _directoryExists(String path) => Directory(path).exists();

// ── Windows, straight from the system ──────────────────────────────────

/// The drives Windows lists right now, as its bitmask (bit 0 = A). Read from
/// memory: no drive is touched, so a network drive that is off cannot make it
/// wait. 0 anywhere but Windows, or when the call is not there.
int windowsLogicalDrives() {
  if (!Platform.isWindows) return 0;
  try {
    final fn = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<Uint32 Function(), int Function()>('GetLogicalDrives');
    return fn();
  } catch (_) {
    return 0;
  }
}

/// True when [root] (`E:\`) is a card reader or disc drive with nothing in
/// it. Asked in a helper isolate, like every question a drive might be slow
/// to answer. False anywhere but Windows.
Future<bool> windowsDriveIsEmpty(String root) {
  if (!Platform.isWindows) return Future.value(false);
  return Isolate.run(() => windowsDriveIsEmptySync(root),
      debugName: 'drive-media');
}

/// [windowsDriveIsEmpty] on the calling thread. Only for an isolate that may
/// wait.
bool windowsDriveIsEmptySync(String root) {
  if (!Platform.isWindows) return false;
  // GetDriveType: 2 = removable (card reader, USB stick), 5 = disc drive.
  const removable = 2;
  const disc = 5;
  final int type;
  final name = root.toNativeUtf16();
  try {
    final getType = DynamicLibrary.open('kernel32.dll').lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)>('GetDriveTypeW');
    type = getType(name);
  } catch (_) {
    return false;
  } finally {
    calloc.free(name);
  }
  if (type != removable && type != disc) return false;
  // Something is in it exactly when the volume can say how big it is.
  return windowsDiskSpaceSync(root) == null;
}

/// Free and total bytes of the volume holding [directory] (a drive root, a
/// folder or a `\\server\share` path), or null when Windows cannot say.
///
/// Asked in a short-lived isolate: for a network drive that does not answer,
/// the call sits in Windows for as long as its timeout, and that wait must
/// never be the UI thread's. It also replaces a PowerShell start per drive.
Future<({int free, int total})?> windowsDiskSpace(String directory) {
  if (!Platform.isWindows) return Future.value(null);
  return Isolate.run(() => windowsDiskSpaceSync(directory),
      debugName: 'disk-space');
}

/// [windowsDiskSpace] on the calling thread. Only for an isolate that may wait.
({int free, int total})? windowsDiskSpaceSync(String directory) {
  if (!Platform.isWindows || directory.isEmpty) return null;
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getSpace = kernel32.lookupFunction<
      Int32 Function(
          Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
      int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
          Pointer<Uint64>)>('GetDiskFreeSpaceExW');
  // An empty card reader or disc drive must answer "not ready", never raise a
  // system "there is no disk in the drive" box. This thread only.
  const semFailCriticalErrors = 0x0001;
  final setMode = kernel32.lookupFunction<
      Int32 Function(Uint32, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)>('SetThreadErrorMode');
  // A UNC name has to end in a backslash; a drive root already does.
  final name = (directory.endsWith('\\') || directory.endsWith('/')
          ? directory
          : '$directory\\')
      .toNativeUtf16();
  final free = calloc<Uint64>();
  final total = calloc<Uint64>();
  final oldMode = calloc<Uint32>();
  var modeSet = false;
  try {
    modeSet = setMode(semFailCriticalErrors, oldMode) != 0;
    final ok = getSpace(name, free, total, nullptr);
    if (ok == 0 || total.value == 0) return null;
    return (free: free.value, total: total.value);
  } catch (_) {
    return null;
  } finally {
    // The thread goes back to a pool: leave it as it was found.
    if (modeSet) setMode(oldMode.value, nullptr);
    calloc.free(name);
    calloc.free(free);
    calloc.free(total);
    calloc.free(oldMode);
  }
}
