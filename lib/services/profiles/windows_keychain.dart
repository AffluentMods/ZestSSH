// The plugin keeps its storage behind names marked for tests, and this is the
// way it offers to give it another (createFlutterSecureStorageWindows).
// ignore_for_file: invalid_use_of_visible_for_testing_member, implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show listEquals, mapEquals, visibleForTesting;
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage_windows/src/flutter_secure_storage_windows_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

// The keychain on Windows is one file: every secret of the app, encrypted with
// DPAPI as a whole. The plugin rewrites it in place, with no lock: a write is
// load, change, save; a read that fails returns an empty map; a file that does
// not decrypt is deleted; the save truncates the file, inside a loop that retries
// for ever. So two callers that overlap lose each other's writes, a stop inside a
// write loses everything, the database's key included, and a file held for a
// moment by a scanner reads as empty and is then written back with one key in it
// (found in the review of to-do 60, with the real plugin on a temp file).
//
// This keeps the file and its format, so what is there reads as it is and an
// older version can read what is written here, and replaces how it is touched:
//
//  * one call at a time in this process, and for a write a lock file between
//    windows and processes (a pop-out runs on its own engine, and `zestssh admin`
//    runs beside the app); a read needs none, as a write replaces the file whole;
//  * a write goes to a temporary file, flushed and read back, and takes the
//    file's place by an atomic rename: at any stop the file is whole;
//  * a copy is written first, so it is never behind the file, and it is used;
//  * a read that fails throws, and it reads as empty only where nothing at all
//    is there;
//  * a file that will not decrypt while its copy does is renamed aside, and never
//    deleted; where neither does, DPAPI may be away for a while (a logon, a
//    password reset), so nothing is touched and it says so, until it opens again
//    or the person sets it aside;
//  * nothing loops for ever: a write that cannot complete throws, and says so.

/// The keychain file could not be read or written. Says nothing of the path,
/// which has a person's name in it.
class KeychainFileFailed implements Exception, HasTypeName {
  const KeychainFileFailed(this.step, [this.osError]);

  /// `read`, `write`, `busy` (something else holds the lock) or `does-not-open`
  /// (it did not decrypt and nothing good is there to take its place: it is left
  /// where it is, for when DPAPI answers again or the person sets it aside).
  final String step;
  final int? osError;

  @override
  String toString() => 'KeychainFileFailed($step${osError == null ? '' : ', os error $osError'})';

  @override
  String get typeName => 'KeychainFileFailed';
}

/// What the file is encrypted with.
abstract class KeychainCipher {
  Uint8List protect(Uint8List plain);

  /// Throws where it does not decrypt.
  Uint8List unprotect(Uint8List encrypted);
}

/// DPAPI, as the plugin calls it: no entropy, no description, no flags. The file
/// reads with the plugin's own code, and the plugin's with this.
class DpapiKeychainCipher implements KeychainCipher {
  const DpapiKeychainCipher();

  @override
  Uint8List protect(Uint8List plain) => _dpapi(plain, _protectData);

  @override
  Uint8List unprotect(Uint8List encrypted) => _dpapi(encrypted, _unprotectData);

  static Uint8List _dpapi(Uint8List input, _CryptCall call) {
    return using((alloc) {
      final data = alloc<Uint8>(input.isEmpty ? 1 : input.length);
      data.asTypedList(input.length).setAll(0, input);
      final inBlob = alloc<_Blob>();
      inBlob.ref.cbData = input.length;
      inBlob.ref.pbData = data;
      final outBlob = alloc<_Blob>();
      if (call(inBlob, outBlob) == 0) throw StateError('DPAPI refused it');
      final out = outBlob.ref.pbData;
      if (out.address == 0) throw StateError('DPAPI gave nothing');
      try {
        return Uint8List.fromList(out.asTypedList(outBlob.ref.cbData));
      } finally {
        _localFree(out.cast());
      }
    });
  }
}

typedef _CryptCall = int Function(Pointer<_Blob> input, Pointer<_Blob> output);

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

/// From the absolute System32 path, never by bare name: the search order begins
/// with the app's own folder, and a planted copy would see every secret (CWE-427).
DynamicLibrary _system32(String name) {
  final root = Platform.environment['SystemRoot'] ?? Platform.environment['windir'] ?? r'C:\Windows';
  return DynamicLibrary.open('$root\\System32\\$name');
}

final _crypt32 = _system32('crypt32.dll');
final _kernel32 = _system32('kernel32.dll');

typedef _CryptNative = Int32 Function(
    Pointer<_Blob>, Pointer<Void>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _CryptDart = int Function(
    Pointer<_Blob>, Pointer<Void>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);

final _cryptProtectData = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
final _cryptUnprotectData = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptUnprotectData');
final _localFree =
    _kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');

int _protectData(Pointer<_Blob> input, Pointer<_Blob> output) =>
    _cryptProtectData(input, nullptr, nullptr, nullptr, nullptr, 0, output);

int _unprotectData(Pointer<_Blob> input, Pointer<_Blob> output) =>
    _cryptUnprotectData(input, nullptr, nullptr, nullptr, nullptr, 0, output);

/// The file itself. Its calls run one at a time, with the lock held, by
/// [SafeWindowsKeychain].
class SafeKeychainFile extends MapStorage {
  SafeKeychainFile({Future<String> Function()? path, KeychainCipher cipher = const DpapiKeychainCipher()})
      : _pathOf = path ?? defaultPath,
        _cipher = cipher;

  final Future<String> Function() _pathOf;
  final KeychainCipher _cipher;
  String? _path;

  /// The plugin's own file, where a released version has it.
  static Future<String> defaultPath() async =>
      p.canonicalize(p.join((await getApplicationSupportDirectory()).path, encryptedJsonFileName));

  /// How long a file held by something else is waited for, in steps: a scanner
  /// holds one for a moment, and a read-only file never lets go.
  static const _patience = [50, 100, 200, 400, 800, 1200];

  /// How long the lock is waited for.
  static const _lockWait = Duration(seconds: 5);

  /// How many files that did not decrypt are kept: each holds what the file held,
  /// the database's plain key included, under DPAPI.
  static const _keepBroken = 3;

  /// In a test, told each place a write can stop at, and throws to stop it there.
  @visibleForTesting
  void Function(String place)? stop;

  /// In a test, how many times the file was replaced.
  @visibleForTesting
  int replaced = 0;

  void _at(String place) => stop?.call(place);

  Map<String, String>? _pending;
  bool _dirty = false;

  /// The lock is held: what is read goes on to be written, and a repair needs no
  /// lock of its own.
  bool _holdingLock = false;

  bool get batching => _pending != null;

  Future<String> file() async => _path ??= await _pathOf();

  // ── What the plugin calls ──────────────────────────────────────────

  @override
  Future<Map<String, String>> load(Map<String, String> options) async {
    final pending = _pending;
    return pending != null ? Map<String, String>.of(pending) : _readFromDisk();
  }

  @override
  Future<void> save(Map<String, String> data, Map<String, String> options) async {
    if (_pending != null) {
      _pending = Map<String, String>.of(data);
      _dirty = true;
      return;
    }
    await _writeToDisk(data);
  }

  @override
  Future<void> clear(Map<String, String> options) async {
    if (_pending != null) {
      _pending = {};
      _dirty = true;
      return;
    }
    final path = await file();
    for (final name in [path, '$path.good', '$path.good.tmp', '$path.tmp']) {
      await _deletePatiently(File(name));
    }
  }

  // ── A batch: many writes, one file written ─────────────────────────

  /// The state of the file is held in memory from here on: writes go there, and
  /// reach the file together at [commitBatch]. Nothing of them is on the disk
  /// before that, so a stop leaves the file as it was.
  Future<void> beginBatch() async {
    _holdingLock = true;
    try {
      _pending = await _readFromDisk();
    } catch (_) {
      _holdingLock = false;
      rethrow;
    }
    _dirty = false;
  }

  Future<void> commitBatch() async {
    final pending = _pending;
    if (pending == null) return;
    if (_dirty) {
      await _writeToDisk(pending);
      // Read as a stranger would: what the batch says it did, it did.
      if (!mapEquals(await _readFromDisk(), pending)) throw const KeychainFileFailed('write');
    }
    _pending = null;
    _dirty = false;
  }

  void rollbackBatch() {
    _pending = null;
    _dirty = false;
    _holdingLock = false;
  }

  // ── The lock ───────────────────────────────────────────────────────

  /// Runs [body], which writes, with the lock on the file held. A read needs no
  /// lock: a write only ever replaces the file whole.
  Future<T> writing<T>(Future<T> Function() body) async {
    final lock = await acquireLock();
    _holdingLock = true;
    try {
      return await body();
    } finally {
      _holdingLock = false;
      await releaseLock(lock);
    }
  }

  Future<RandomAccessFile> acquireLock() async {
    final path = await file();
    final RandomAccessFile handle;
    try {
      await File(path).parent.create(recursive: true);
      handle = await File('$path.lock').open(mode: FileMode.append);
    } on FileSystemException catch (e) {
      throw KeychainFileFailed('write', e.osError?.errorCode);
    }
    final until = DateTime.now().add(_lockWait);
    var step = 10;
    while (true) {
      try {
        await handle.lock(FileLock.exclusive);
        return handle;
      } on FileSystemException {
        if (DateTime.now().isAfter(until)) {
          await _closeQuietly(handle);
          throw const KeychainFileFailed('busy');
        }
        await Future<void>.delayed(Duration(milliseconds: step));
        if (step < 200) step *= 2;
      }
    }
  }

  Future<void> releaseLock(RandomAccessFile handle) async {
    try {
      await handle.unlock();
    } catch (_) {/* closing lets go of it as well */}
    await _closeQuietly(handle);
  }

  static Future<void> _closeQuietly(RandomAccessFile handle) async {
    try {
      await handle.close();
    } catch (_) {/* nothing more to do */}
  }

  // ── Reading ────────────────────────────────────────────────────────

  Future<Map<String, String>> _readFromDisk() async {
    final path = await file();
    final main = File(path);
    final good = File('$path.good');
    final Uint8List? bytes;
    try {
      bytes = await _readPatiently(main);
    } on FileSystemException catch (e) {
      // Still held. A write builds on what it reads, and an older version may have
      // left the copy behind the file, so a write says so. A read gets the copy,
      // which is what the last write of this version left: it never reads as
      // empty, and never guesses. No copy: it says so.
      if (_holdingLock) throw KeychainFileFailed('write', e.osError?.errorCode);
      final copy = await _decodedCopy(good);
      if (copy != null) {
        AppLogger.warning('The keychain file is held by something else: its copy was read');
        return copy;
      }
      throw KeychainFileFailed('read', e.osError?.errorCode);
    }
    if (bytes != null && bytes.isNotEmpty) {
      final decoded = await _decodedPatiently(bytes);
      if (decoded != null) return decoded;
    } else if (!await good.exists() && (await _brokenFiles(path)).isEmpty) {
      // Nothing at all is here, or a file a stop emptied: nothing to keep.
      return {};
    }
    // Something is wrong. What is done about it is done with the lock held, as
    // another process may be writing just now.
    return _holdingLock ? _repair(path) : writing(() => _repair(path));
  }

  /// With the lock held: the file again, as another may have put it right, and what
  /// can take its place. Nothing is taken for empty while anything is here that may
  /// open yet.
  Future<Map<String, String>> _repair(String path) async {
    final main = File(path);
    final good = File('$path.good');
    final Uint8List? bytes;
    try {
      bytes = await _readPatiently(main);
    } on FileSystemException catch (e) {
      throw KeychainFileFailed('read', e.osError?.errorCode);
    }
    final damaged = bytes != null && bytes.isNotEmpty;
    if (damaged) {
      final decoded = await _decodedPatiently(bytes);
      if (decoded != null) return decoded;
    }
    final copy = await _decodedCopy(good);
    if (copy != null) {
      if (damaged) {
        // The copy opens, so DPAPI answers, and this file is damaged: a write of an
        // older version stopped inside it, or the disk. Kept, under another name.
        try {
          await _renamePatiently(main, '$path.broken.${DateTime.now().millisecondsSinceEpoch}');
        } on FileSystemException catch (e) {
          throw KeychainFileFailed('read', e.osError?.errorCode);
        }
        await _keepFewBroken(path);
        AppLogger.warning('The keychain file did not decrypt, and was set aside');
      } else {
        AppLogger.warning('The keychain file was gone: its copy was put back');
      }
      await _writeToDisk(copy);
      return copy;
    }
    // Neither opens: DPAPI itself may not answer for now. Nothing is renamed, and it
    // reads as nothing only where nothing is left that could open.
    if (damaged || await _hasBytes(good)) throw const KeychainFileFailed('does-not-open');
    for (final broken in await _brokenFiles(path)) {
      Map<String, String>? held;
      try {
        held = _decoded(await broken.readAsBytes());
      } on FileSystemException {
        held = null;
      }
      if (held == null) continue;
      AppLogger.warning('A keychain file that did not decrypt opens now, and was put back');
      await _renamePatiently(broken, path);
      await _writeToDisk(held);
      return held;
    }
    if ((await _brokenFiles(path)).isNotEmpty) throw const KeychainFileFailed('does-not-open');
    return {};
  }

  static Future<bool> _hasBytes(File file) async {
    try {
      return await file.exists() && await file.length() > 0;
    } on FileSystemException {
      return true;
    }
  }

  /// The files that did not decrypt, the newest first; none that holds nothing.
  static Future<List<File>> _brokenFiles(String path) async {
    final folder = File(path).parent;
    if (!await folder.exists()) return const [];
    final begin = '${p.basename(path)}.broken.';
    final found = <File>[];
    for (final entry in await folder.list().toList()) {
      if (entry is File && p.basename(entry.path).startsWith(begin) && await _hasBytes(entry)) found.add(entry);
    }
    int when(File f) => int.tryParse(p.basename(f.path).substring(begin.length)) ?? 0;
    return found..sort((a, b) => when(b).compareTo(when(a)));
  }

  /// One more for each failure to decrypt: only the newest few stay.
  static Future<void> _keepFewBroken(String path) async {
    final all = await _brokenFiles(path);
    for (final old in all.skip(_keepBroken)) {
      await _deleteQuietly(old);
    }
  }

  /// Bytes of [file], or null where it is not there. Waits a while for what holds
  /// it; rethrows what it last met once that is over.
  static Future<Uint8List?> _readPatiently(File file) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await file.readAsBytes();
      } on PathNotFoundException {
        return null;
      } on FileSystemException {
        if (!await file.exists()) return null;
        if (attempt >= _patience.length) rethrow;
        await Future<void>.delayed(Duration(milliseconds: _patience[attempt]));
      }
    }
  }

  /// A failure of DPAPI can be of the moment: tried once more before the file is
  /// taken to be broken.
  Future<Map<String, String>?> _decodedPatiently(Uint8List bytes) async {
    final first = _decoded(bytes);
    if (first != null || bytes.isEmpty) return first;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return _decoded(bytes);
  }

  Future<Map<String, String>?> _decodedCopy(File copy) async {
    try {
      if (!await copy.exists()) return null;
      return _decoded(await copy.readAsBytes());
    } on FileSystemException {
      return null;
    }
  }

  /// The map [bytes] hold, or null where they will not decrypt or are not one.
  /// Takes string pairs only, as the plugin does.
  Map<String, String>? _decoded(Uint8List bytes) {
    if (bytes.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(_cipher.unprotect(bytes)));
      if (decoded is! Map) return null;
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    } catch (_) {
      return null;
    }
  }

  // ── Writing ────────────────────────────────────────────────────────

  Future<void> _writeToDisk(Map<String, String> data) async {
    final path = await file();
    final temp = File('$path.tmp');
    final copyTemp = File('$path.good.tmp');
    final Uint8List bytes;
    try {
      bytes = _cipher.protect(Uint8List.fromList(utf8.encode(jsonEncode(data))));
    } catch (_) {
      throw const KeychainFileFailed('write');
    }
    var copied = false;
    try {
      await File(path).parent.create(recursive: true);
      await _writeFlushed(temp, bytes);
      _at('temp-written');
      // Whole on the disk, before it takes the place of what is there.
      if (!listEquals(await temp.readAsBytes(), bytes)) throw const KeychainFileFailed('write');
      // The copy first, so it is never behind the file: at any stop it holds this
      // write or the file does, and a copy that cannot be written fails the write
      // here, loudly, rather than leave a key where only the file has it.
      await _writeFlushed(copyTemp, bytes);
      await _renamePatiently(copyTemp, '$path.good');
      copied = true;
      _at('copied');
      await _renamePatiently(temp, path);
    } on FileSystemException catch (e) {
      await _afterFailedWrite(path, temp, copyTemp, copied);
      throw KeychainFileFailed('write', e.osError?.errorCode);
    } on KeychainFileFailed {
      await _afterFailedWrite(path, temp, copyTemp, copied);
      rethrow;
    }
    replaced++;
    _at('replaced');
  }

  /// A write that was told it failed: its temporary files go, and the copy holds
  /// what the file holds again, where the file can be read.
  static Future<void> _afterFailedWrite(String path, File temp, File copyTemp, bool copied) async {
    await _deleteQuietly(temp);
    await _deleteQuietly(copyTemp);
    if (!copied) return;
    try {
      // Its bytes, not a copy of the file: a copy takes a read-only file's attribute
      // along, and the next write could not replace it.
      await copyTemp.writeAsBytes(await File(path).readAsBytes(), flush: true);
      await copyTemp.rename('$path.good');
    } on FileSystemException {
      await _deleteQuietly(copyTemp);
    }
  }

  Future<void> _writeFlushed(File file, Uint8List bytes) async {
    final out = await file.open(mode: FileMode.write);
    try {
      if (stop != null) {
        // Half of it, to stop at: what a stop inside the write leaves.
        final half = bytes.length ~/ 2;
        await out.writeFrom(bytes, 0, half);
        _at('half-written');
        await out.writeFrom(bytes, half);
      } else {
        await out.writeFrom(bytes);
      }
      await out.flush();
    } finally {
      await _closeQuietly(out);
    }
  }

  /// A rename, waiting a while for what holds the file; rethrows once that is
  /// over. It replaces what is at [to] whole: on Windows MoveFileEx with
  /// MOVEFILE_REPLACE_EXISTING and MOVEFILE_WRITE_THROUGH.
  static Future<void> _renamePatiently(File from, String to) async {
    for (var attempt = 0;; attempt++) {
      try {
        await from.rename(to);
        return;
      } on FileSystemException {
        if (attempt >= _patience.length) rethrow;
        await Future<void>.delayed(Duration(milliseconds: _patience[attempt]));
      }
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on FileSystemException {/* gone, or the next write takes its place */}
  }

  static Future<void> _deletePatiently(File file) async {
    for (var attempt = 0;; attempt++) {
      try {
        if (await file.exists()) await file.delete();
        return;
      } on FileSystemException catch (e) {
        if (attempt >= _patience.length) throw KeychainFileFailed('write', e.osError?.errorCode);
        await Future<void>.delayed(Duration(milliseconds: _patience[attempt]));
      }
    }
  }

  /// Copies the file as it is to [to]: nothing is opened or changed.
  Future<void> copyTo(String to) async {
    final main = File(await file());
    if (!await main.exists()) return;
    await File(to).parent.create(recursive: true);
    for (var attempt = 0;; attempt++) {
      try {
        await main.copy('$to.part');
        break;
      } on FileSystemException {
        if (attempt >= _patience.length) rethrow;
        await Future<void>.delayed(Duration(milliseconds: _patience[attempt]));
      }
    }
    await _renamePatiently(File('$to.part'), to);
  }

  /// The file does not open and the person will not wait for it: it stays beside the
  /// new one under another name, with its copy and what did not decrypt before, and
  /// the keychain starts empty. Nothing is deleted, and nothing reads these again by
  /// itself: the person chose to start without them.
  Future<void> setAsideForGood() => writing(() async {
        final path = await file();
        final at = DateTime.now().millisecondsSinceEpoch;
        var n = 0;
        for (final name in [path, '$path.good', for (final b in await _brokenFiles(path)) b.path]) {
          final found = File(name);
          if (!await found.exists()) continue;
          try {
            await _renamePatiently(found, '$path.aside.$at.${n++}');
          } on FileSystemException catch (e) {
            throw KeychainFileFailed('write', e.osError?.errorCode);
          }
        }
      });

  /// What was set aside goes, on the person's word (Everything on this computer).
  Future<void> forgetSetAside() async {
    final path = await file();
    final folder = File(path).parent;
    if (!await folder.exists()) return;
    final name = p.basename(path);
    for (final entry in await folder.list().toList()) {
      if (entry is! File) continue;
      final found = p.basename(entry.path);
      if (found.startsWith('$name.broken.') || found.startsWith('$name.aside.')) await _deleteQuietly(entry);
    }
  }
}

/// The keychain on Windows: the plugin's own class over [SafeKeychainFile], with
/// one call at a time, so that its load and save are one step.
class SafeWindowsKeychain extends FlutterSecureStoragePlatform {
  SafeWindowsKeychain(this.file, {FlutterSecureStoragePlatform? legacy})
      : _plugin = createFlutterSecureStorageWindows(legacy ?? MethodChannelFlutterSecureStorage(), file);

  final SafeKeychainFile file;
  final FlutterSecureStoragePlatform _plugin;

  Future<void> _tail = Future<void>.value();

  /// There while a batch is under way: what is not part of it waits, and never
  /// sees what may yet be taken back.
  Completer<void>? _batchEnded;
  final _zoneKey = Object();

  bool get _insideBatch => identical(Zone.current[_zoneKey], this);

  Future<T> _enqueue<T>(Future<T> Function() step) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await step());
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  Future<T> _inTurn<T>(Future<T> Function() call, {required bool write}) async {
    if (!_insideBatch) {
      while (_batchEnded != null) {
        await _batchEnded!.future;
      }
    }
    return _enqueue(() => file.batching || !write ? call() : file.writing(call));
  }

  /// [body]'s writes reach the file together, once, with the lock held meanwhile:
  /// a stop or a throw inside leaves the file as it was. A move of hundreds of
  /// secrets rewrites the file once, not once for each.
  Future<T> batch<T>(Future<T> Function() body) async {
    if (_insideBatch) return body();
    while (_batchEnded != null) {
      await _batchEnded!.future;
    }
    final ended = _batchEnded = Completer<void>();
    late RandomAccessFile lock;
    try {
      await _enqueue(() async {
        lock = await file.acquireLock();
        try {
          await file.beginBatch();
        } catch (_) {
          await file.releaseLock(lock);
          rethrow;
        }
      });
    } catch (_) {
      _batchEnded = null;
      ended.complete();
      rethrow;
    }
    try {
      final result = await runZoned(body, zoneValues: {_zoneKey: this});
      await _enqueue(file.commitBatch);
      return result;
    } finally {
      await _enqueue(() async {
        file.rollbackBatch();
        await file.releaseLock(lock);
      });
      _batchEnded = null;
      ended.complete();
    }
  }

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) =>
      _inTurn(() => _plugin.containsKey(key: key, options: options), write: false);

  @override
  Future<void> delete({required String key, required Map<String, String> options}) =>
      _inTurn(() => _plugin.delete(key: key, options: options), write: true);

  @override
  Future<void> deleteAll({required Map<String, String> options}) =>
      _inTurn(() => _plugin.deleteAll(options: options), write: true);

  @override
  Future<String?> read({required String key, required Map<String, String> options}) =>
      _inTurn(() => _plugin.read(key: key, options: options), write: false);

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) =>
      _inTurn(() => _plugin.readAll(options: options), write: false);

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) =>
      _inTurn(() => _plugin.write(key: key, value: value, options: options), write: true);

  /// Copies the file as it is to [to].
  Future<void> copyFileTo(String to) => _inTurn(() => file.copyTo(to), write: false);

  /// The file does not open and the person will not wait: [SafeKeychainFile.setAsideForGood].
  Future<void> setFileAside() => _enqueue(file.setAsideForGood);
}
