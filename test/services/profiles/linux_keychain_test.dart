import 'dart:io';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zestssh/services/profiles/linux_keychain.dart';

/// One item holding a map, as the plugin keeps it on Linux: a write reads it, changes
/// it and stores it whole, with a gap in between for another process to come in.
class _OneItem {
  Map<String, String> item = {};

  Future<void> change(void Function(Map<String, String> map) what) async {
    final read = Map<String, String>.of(item);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    what(read);
    item = read;
  }
}

class _Plugin extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  _Plugin(this.keyring);
  final _OneItem keyring;
  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => keyring.item.containsKey(key);
  @override
  Future<void> delete({required String key, required Map<String, String> options}) => keyring.change((m) => m.remove(key));
  @override
  Future<void> deleteAll({required Map<String, String> options}) => keyring.change((m) => m.clear());
  @override
  Future<String?> read({required String key, required Map<String, String> options}) async => keyring.item[key];
  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map.of(keyring.item);
  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) =>
      keyring.change((m) => m[key] = value);
}

void main() {
  const o = <String, String>{};
  late Directory temp;
  late String lock;
  // A lock of this kind is a handle's on Windows, where the suite runs, and the
  // process's elsewhere: two stores here stand for two processes there.
  final twoProcesses = Platform.isWindows ? false : 'two stores in one process share its lock here';

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zest_linux_keychain_');
    lock = p.join(temp.path, 'keychain.lock');
  });
  tearDown(() => temp.delete(recursive: true));

  test('two processes writing lose nothing of each other\'s', () async {
    final keyring = _OneItem();
    final a = LinuxKeychain(_Plugin(keyring), lockPath: () async => lock);
    final b = LinuxKeychain(_Plugin(keyring), lockPath: () async => lock);
    await Future.wait([
      for (var i = 0; i < 10; i++) ...[
        a.write(key: 'a$i', value: 'x', options: o),
        b.write(key: 'b$i', value: 'x', options: o),
      ],
    ]);
    expect(keyring.item, hasLength(20));
  }, skip: twoProcesses);

  test('inside one process they come one at a time', () async {
    final keyring = _OneItem();
    final a = LinuxKeychain(_Plugin(keyring), lockPath: () async => lock);
    await Future.wait([for (var i = 0; i < 10; i++) a.write(key: 'a$i', value: 'x', options: o)]);
    expect(keyring.item, hasLength(10));
  });

  test('a lock file that cannot be had: the write goes on, as it always did', () async {
    final keyring = _OneItem();
    final a = LinuxKeychain(_Plugin(keyring), lockPath: () async => p.join(temp.path, 'a file', 'not a folder', 'lock'));
    await File(p.join(temp.path, 'a file')).writeAsString('in the way');
    await a.write(key: 'k', value: 'v', options: o);
    expect(keyring.item, {'k': 'v'});
    expect(await a.read(key: 'k', options: o), 'v');
  });

  test('a read needs no lock', () async {
    final keyring = _OneItem()..item = {'k': 'v'};
    final a = LinuxKeychain(_Plugin(keyring), lockPath: () async => lock);
    final held = await File(lock).open(mode: FileMode.append);
    await held.lock(FileLock.exclusive);
    final clock = Stopwatch()..start();
    expect(await a.read(key: 'k', options: o), 'v');
    expect(await a.readAll(options: o), {'k': 'v'});
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    await held.close();
  });
}
