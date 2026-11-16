import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/error_kind.dart';

/// The keychain on Linux, over the plugin. One item of the Secret Service holds a
/// JSON map of every secret, and each write reads it, changes it and stores it whole.
/// Inside one process the plugin takes its calls one at a time, so nothing is lost
/// there. Another process can come between (`zestssh admin` runs beside the app, and
/// Linux has no single-instance guard), and one write would then take the other's
/// away, so a write takes a lock file. It goes on without one where that cannot be had
/// in a few seconds: this is what the keychain always did, and a keychain that works
/// matters more.
class LinuxKeychain extends FlutterSecureStoragePlatform {
  LinuxKeychain(this._plugin, {Future<String> Function()? lockPath}) : _lockPath = lockPath ?? _defaultLockPath;

  final FlutterSecureStoragePlatform _plugin;
  final Future<String> Function() _lockPath;

  static const _wait = Duration(seconds: 5);

  static Future<String> _defaultLockPath() async =>
      p.join((await getApplicationSupportDirectory()).path, 'keychain.lock');

  Future<void> _tail = Future<void>.value();

  /// One write at a time here: a lock of this kind is the process's, and closing any
  /// handle on the file lets go of it.
  Future<T> _writing<T>(Future<T> Function() call) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      final lock = await _takeLock();
      try {
        done.complete(await call());
      } catch (e, s) {
        done.completeError(e, s);
      } finally {
        await _letGo(lock);
      }
    });
    return done.future;
  }

  Future<RandomAccessFile?> _takeLock() async {
    RandomAccessFile? handle;
    try {
      final path = await _lockPath();
      await File(path).parent.create(recursive: true);
      handle = await File(path).open(mode: FileMode.append);
      final until = DateTime.now().add(_wait);
      var step = 10;
      while (true) {
        try {
          await handle.lock(FileLock.exclusive);
          return handle;
        } on FileSystemException {
          if (DateTime.now().isAfter(until)) break;
          await Future<void>.delayed(Duration(milliseconds: step));
          if (step < 200) step *= 2;
        }
      }
    } catch (e) {
      AppLogger.warning('The keychain\'s lock could not be had (${errorKind(e)})');
    }
    await handle?.close();
    return null;
  }

  static Future<void> _letGo(RandomAccessFile? lock) async {
    if (lock == null) return;
    try {
      await lock.close();
    } catch (_) {/* nothing more to do */}
  }

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) =>
      _plugin.containsKey(key: key, options: options);

  @override
  Future<void> delete({required String key, required Map<String, String> options}) =>
      _writing(() => _plugin.delete(key: key, options: options));

  @override
  Future<void> deleteAll({required Map<String, String> options}) => _writing(() => _plugin.deleteAll(options: options));

  @override
  Future<String?> read({required String key, required Map<String, String> options}) =>
      _plugin.read(key: key, options: options);

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) => _plugin.readAll(options: options);

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) =>
      _writing(() => _plugin.write(key: key, value: value, options: options));
}
