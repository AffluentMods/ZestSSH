import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
// The plugin's own code path: what a released version writes, and how it reads.
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:flutter_secure_storage_windows/src/flutter_secure_storage_windows_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zestssh/services/profiles/windows_keychain.dart';

class _Path extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Path(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

class NoLegacy extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => false;
  @override
  Future<void> delete({required String key, required Map<String, String> options}) async {}
  @override
  Future<void> deleteAll({required Map<String, String> options}) async {}
  @override
  Future<String?> read({required String key, required Map<String, String> options}) async => null;
  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => {};
  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async {}
}

class _Stopped implements Exception {
  const _Stopped();
}

/// DPAPI that refuses for as long as it is told to.
class _Refusing implements KeychainCipher {
  bool refuse = true;
  static const _real = DpapiKeychainCipher();
  @override
  Uint8List protect(Uint8List plain) => refuse ? throw StateError('DPAPI refused it') : _real.protect(plain);
  @override
  Uint8List unprotect(Uint8List encrypted) => refuse ? throw StateError('DPAPI refused it') : _real.unprotect(encrypted);
}

const _o = {'useBackwardCompatibility': 'false'};

/// A writer of its own on the file at [path], for another isolate: it takes along
/// nothing but its two words.
Future<void> Function() _writer(String path, String name) => () async {
      final other = SafeWindowsKeychain(SafeKeychainFile(path: () async => path), legacy: NoLegacy());
      for (var i = 0; i < 25; i++) {
        await other.write(key: '$name$i', value: 'y' * 300, options: _o);
      }
    };

/// The keychain's file on Windows, on a temp file, with the plugin's own class and
/// the real DPAPI. What it stood in for lost every entry to a stop inside a write,
/// lost writes to any overlap, read as empty while something held the file, and
/// never returned from a write to a read-only one.
void main() {
  late Directory temp;
  late String path;
  late SafeKeychainFile file;
  late SafeWindowsKeychain store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zest_keychain_');
    PathProviderPlatform.instance = _Path(temp.path);
    // Never the real file.
    expect((await getApplicationSupportDirectory()).path, temp.path);
    path = p.join(temp.path, 'flutter_secure_storage.dat');
    file = SafeKeychainFile(path: () async => path);
    store = SafeWindowsKeychain(file, legacy: NoLegacy());
  });

  tearDown(() async {
    if (Platform.isWindows) await Process.run('attrib', ['-R', path]);
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> w(String k, String v, [SafeWindowsKeychain? on]) => (on ?? store).write(key: k, value: v, options: _o);
  Future<String?> r(String k, [SafeWindowsKeychain? on]) => (on ?? store).read(key: k, options: _o);
  Future<Map<String, String>> all([SafeWindowsKeychain? on]) => (on ?? store).readAll(options: _o);
  SafeWindowsKeychain nextLaunch() => SafeWindowsKeychain(SafeKeychainFile(path: () async => path), legacy: NoLegacy());
  FlutterSecureStorageWindows thePlugin() => createFlutterSecureStorageWindows(NoLegacy(), DpapiJsonFileMapStorage());

  final notWindows = Platform.isWindows ? false : 'the real DPAPI';

  test('existing files read as they are, and an older version reads what is written', () async {
    // A released version wrote this.
    final plugin = thePlugin();
    await plugin.write(key: 'profiles_v1', value: 'the list', options: _o);
    await plugin.write(key: 'p.abc.zestssh_db_encryption_key', value: 'k' * 64, options: _o);
    expect(await r('profiles_v1'), 'the list');
    expect(await r('p.abc.zestssh_db_encryption_key'), 'k' * 64);
    await w('identity_key_1', 'a private key');
    expect(await plugin.read(key: 'identity_key_1', options: _o), 'a private key');
    expect(await plugin.read(key: 'profiles_v1', options: _o), 'the list');
    expect(p.basename(path), encryptedJsonFileName);
    // Where the app itself looks is where the plugin wrote.
    expect(await SafeKeychainFile.defaultPath(), p.canonicalize(path));
  }, skip: notWindows);

  test('writers that overlap lose nothing', () async {
    for (var round = 0; round < 10; round++) {
      await w('dbkey', 'k' * 64);
      Future<void> writer(String name) async {
        for (var i = 0; i < 12; i++) {
          await w('$name$i', 'y' * (200 + (i * 91) % 1500));
        }
      }

      await Future.wait([writer('a'), writer('b'), writer('c')]);
      final left = await all();
      expect(left['dbkey'], 'k' * 64);
      for (final name in ['a', 'b', 'c']) {
        for (var i = 0; i < 12; i++) {
          expect(left.containsKey('$name$i'), isTrue, reason: '$name$i, round $round');
        }
      }
      await store.deleteAll(options: _o);
    }
  }, skip: notWindows);

  test('a stop at every place inside a write: the whole file before it, or the whole file after, and nothing else', () async {
    for (final place in ['half-written', 'temp-written', 'copied', 'replaced']) {
      await w('profiles_v1', 'the list');
      await w('p.abc.zestssh_db_encryption_key', 'k' * 64);
      file.stop = (at) {
        if (at == place) throw const _Stopped();
      };
      await expectLater(w('p.abc.session_token', 'a token'), throwsA(isA<_Stopped>()), reason: place);
      file.stop = null;

      final next = nextLaunch();
      expect(await r('profiles_v1', next), 'the list', reason: place);
      expect(await r('p.abc.zestssh_db_encryption_key', next), 'k' * 64, reason: place);
      // Before it took the file's place the write never happened, and after it, it did.
      final landed = place == 'replaced';
      expect(await r('p.abc.session_token', next), landed ? 'a token' : isNull, reason: place);
      await next.deleteAll(options: _o);
    }
  }, skip: notWindows);

  group('a file that will not decrypt', () {
    Future<void> broken(Uint8List Function(Uint8List) cut) async {
      await w('profiles_v1', 'the list');
      await w('p.abc.zestssh_db_encryption_key', 'k' * 64);
      final bytes = await File(path).readAsBytes();
      // What the plugin's own write leaves when an older version stops inside it.
      await File(path).writeAsBytes(cut(bytes), flush: true);
    }

    test('emptied by a stop in an older version: the last good copy takes its place', () async {
      await broken((_) => Uint8List(0));
      final next = nextLaunch();
      expect(await r('profiles_v1', next), 'the list');
      expect(await r('p.abc.zestssh_db_encryption_key', next), 'k' * 64);
      expect(await nextLaunch().readAll(options: _o), hasLength(2), reason: 'the file itself is whole again');
      expect(temp.listSync().where((f) => f.path.contains('.broken.')), isEmpty, reason: 'an empty file holds nothing to keep');
    }, skip: notWindows);

    test('emptied, with no copy: that is a keychain with nothing in it, and it can be written', () async {
      await broken((_) => Uint8List(0));
      await File('$path.good').delete();
      final next = nextLaunch();
      expect(await all(next), isEmpty);
      await w('a', '1', next);
      expect(await r('a', nextLaunch()), '1');
    }, skip: notWindows);

    test('half of one: the same', () async {
      await broken((b) => Uint8List.sublistView(b, 0, b.length ~/ 2));
      expect(await r('p.abc.zestssh_db_encryption_key', nextLaunch()), 'k' * 64);
      final aside = temp.listSync().whereType<File>().where((f) => f.path.contains('.broken.')).single;
      expect(aside.lengthSync(), greaterThan(0), reason: 'what was there is what is kept');
    }, skip: notWindows);

    test('with no copy to take its place: it says so each time, the file stays where it is, and it never reads as empty', () async {
      await broken((b) => Uint8List.sublistView(b, 0, b.length ~/ 2));
      await File('$path.good').delete();
      final next = nextLaunch();
      for (final _ in [1, 2]) {
        await expectLater(r('profiles_v1', next), throwsA(isA<KeychainFileFailed>().having((e) => e.step, 'step', 'does-not-open')));
      }
      expect(temp.listSync().where((f) => f.path.contains('.broken.')), isEmpty);
      expect(await File(path).exists(), isTrue);
    }, skip: notWindows);

    test('a copy that will not decrypt either is no copy', () async {
      await broken((b) => Uint8List.sublistView(b, 0, b.length ~/ 2));
      await File('$path.good').writeAsBytes(const [1, 2, 3], flush: true);
      await expectLater(r('profiles_v1', nextLaunch()), throwsA(isA<KeychainFileFailed>()));
    }, skip: notWindows);
  });

  group('DPAPI does not answer for a while: a logon, a password reset', () {
    late _Refusing cipher;
    late SafeWindowsKeychain flaky;
    List<String> names() => temp.listSync().map((f) => p.basename(f.path)).toList()..sort();

    setUp(() {
      cipher = _Refusing()..refuse = false;
      flaky = SafeWindowsKeychain(SafeKeychainFile(path: () async => path, cipher: cipher), legacy: NoLegacy());
    });

    test('neither the file nor its copy opens: nothing is touched, it says so each time, and all is there once it answers', () async {
      await w('dbkey', 'k' * 64, flaky);
      await w('identity_key_1', 'a private key', flaky);
      final before = await File(path).readAsBytes();
      cipher.refuse = true;
      for (final _ in [1, 2]) {
        await expectLater(r('dbkey', flaky), throwsA(isA<KeychainFileFailed>().having((e) => e.step, 'step', 'does-not-open')));
      }
      // The start goes no further: a write cannot put a new, empty keychain in its place.
      await expectLater(w('profiles_v1', 'a new guest', flaky), throwsA(isA<KeychainFileFailed>()));
      expect(names().where((n) => n.contains('.broken.')), isEmpty);
      expect(await File(path).readAsBytes(), before);
      cipher.refuse = false;
      expect((await all(flaky)).keys, unorderedEquals(['dbkey', 'identity_key_1']));
    }, skip: notWindows);

    test('the plugin\'s own file at a first start, with no copy yet: the same, and the move that follows has its key', () async {
      await thePlugin().write(key: 'zestssh_db_encryption_key', value: 'k' * 64, options: _o);
      cipher.refuse = true;
      await expectLater(r('zestssh_db_encryption_key', flaky), throwsA(isA<KeychainFileFailed>()));
      await expectLater(all(flaky), throwsA(isA<KeychainFileFailed>()));
      cipher.refuse = false;
      expect(await r('zestssh_db_encryption_key', flaky), 'k' * 64);
    }, skip: notWindows);

    test('it never opens, and the person will not wait: it stays under another name, and the keychain starts empty', () async {
      await w('dbkey', 'k' * 64, flaky);
      cipher.refuse = true;
      await expectLater(r('dbkey', flaky), throwsA(isA<KeychainFileFailed>()));
      await flaky.setFileAside();
      expect(await all(flaky), isEmpty);
      // What it could not open it still cannot; what is written now it can.
      cipher.refuse = false;
      await w('profiles_v1', 'a new list', flaky);
      expect(await r('profiles_v1', flaky), 'a new list');
      // Nothing was deleted, and nothing took it for what is here now.
      final aside = names().where((n) => n.contains('.aside.')).toList();
      expect(aside, hasLength(2), reason: 'the file and its copy');
      expect((await all(flaky)).keys, ['profiles_v1']);
      final kept = File(p.join(temp.path, aside.first));
      expect(jsonDecode(utf8.decode(const DpapiKeychainCipher().unprotect(await kept.readAsBytes()))), containsPair('dbkey', 'k' * 64));
      await file.forgetSetAside();
      expect(names().where((n) => n.contains('.aside.')), isEmpty);
    }, skip: notWindows);
  });

  group('what did not decrypt, and is kept under another name', () {
    Future<void> leaveBroken() async {
      await w('dbkey', 'k' * 64);
      await File(path).rename('$path.broken.100');
      await File('$path.good').delete();
    }

    test('with nothing else here it is put back, once it opens', () async {
      await leaveBroken();
      final next = nextLaunch();
      expect(await r('dbkey', next), 'k' * 64);
      expect(await File(path).exists(), isTrue);
      expect(await File('$path.good').exists(), isTrue);
      expect(temp.listSync().where((f) => f.path.contains('.broken.')), isEmpty);
    }, skip: notWindows);

    test('one that does not open is no empty keychain: it says so', () async {
      await leaveBroken();
      final broken = File('$path.broken.100');
      final bytes = await broken.readAsBytes();
      await broken.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2), flush: true);
      await expectLater(all(nextLaunch()), throwsA(isA<KeychainFileFailed>().having((e) => e.step, 'step', 'does-not-open')));
    }, skip: notWindows);

    test('only the newest three are kept: each holds a key', () async {
      for (var i = 0; i < 5; i++) {
        await w('dbkey', 'k' * 64);
        final bytes = await File(path).readAsBytes();
        await File(path).writeAsBytes(bytes.sublist(0, bytes.length ~/ 2), flush: true);
        expect(await r('dbkey', nextLaunch()), 'k' * 64);
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }
      expect(temp.listSync().where((f) => f.path.contains('.broken.')), hasLength(3));
    }, skip: notWindows);
  });

  group('the copy is never behind the file', () {
    Future<void> stoppedWrite(String place) async {
      await w('dbkey', 'k' * 64);
      file.stop = (at) {
        if (at == place) throw const _Stopped();
      };
      await expectLater(w('key-of-a-new-profile', 'the only copy'), throwsA(isA<_Stopped>()));
      file.stop = null;
    }

    test('a stop right after the file was replaced, and then the file is gone: that write is still there', () async {
      await stoppedWrite('replaced');
      await File(path).delete();
      final next = nextLaunch();
      await w('after', 'a write', next);
      expect((await all(next)).keys, containsAll(['dbkey', 'key-of-a-new-profile', 'after']));
    }, skip: notWindows);

    test('the same, and then the file does not decrypt', () async {
      await stoppedWrite('replaced');
      final bytes = await File(path).readAsBytes();
      await File(path).writeAsBytes(bytes.sublist(0, bytes.length ~/ 2), flush: true);
      final next = nextLaunch();
      await w('after', 'a write', next);
      expect((await all(next)).keys, containsAll(['dbkey', 'key-of-a-new-profile', 'after']));
    }, skip: notWindows);

    test('held for long after that stop: a read hands back what was written, and what a caller builds on it loses nothing', () async {
      await w('list', 'list-v1');
      file.stop = (at) {
        if (at == 'replaced') throw const _Stopped();
      };
      await expectLater(w('list', 'list-v2'), throwsA(isA<_Stopped>()));
      file.stop = null;
      final next = nextLaunch();
      final holder = await File(path).open(mode: FileMode.append);
      await holder.lock(FileLock.exclusive);
      final seen = await r('list', next);
      await holder.unlock();
      await holder.close();
      expect(seen, 'list-v2');
    }, skip: notWindows);

    test('a copy that cannot be written fails the write, and the file stays as it was', () async {
      await w('dbkey', 'k' * 64);
      await Process.run('attrib', ['+R', '$path.good']);
      addTearDown(() => Process.run('attrib', ['-R', '$path.good']));
      await expectLater(w('new', 'value'), throwsA(isA<KeychainFileFailed>().having((e) => e.step, 'step', 'write')));
      await Process.run('attrib', ['-R', '$path.good']);
      expect((await all()).keys, ['dbkey']);
      await w('new', 'value');
      expect((await all()).keys, unorderedEquals(['dbkey', 'new']));
    }, skip: notWindows);

    test('a write told it failed leaves the copy as the file is', () async {
      await w('dbkey', 'k' * 64);
      await Process.run('attrib', ['+R', path]);
      await expectLater(w('new', 'value'), throwsA(isA<KeychainFileFailed>()));
      await Process.run('attrib', ['-R', path]);
      await File(path).delete();
      expect((await all(nextLaunch())).keys, ['dbkey']);
    }, skip: notWindows);
  });

  test('a file that went away: the last good copy takes its place', () async {
    await w('p.abc.zestssh_db_encryption_key', 'k' * 64);
    await File(path).delete();
    expect(await r('p.abc.zestssh_db_encryption_key', nextLaunch()), 'k' * 64);
    expect(await File(path).exists(), isTrue);
  }, skip: notWindows);

  test('what was deleted is not in the copy either', () async {
    await w('p.abc.zestssh_db_encryption_key', 'k' * 64);
    await w('profiles_v1', 'the list');
    await store.delete(key: 'p.abc.zestssh_db_encryption_key', options: _o);
    await File(path).delete();
    final next = nextLaunch();
    expect(await r('p.abc.zestssh_db_encryption_key', next), isNull);
    expect(await r('profiles_v1', next), 'the list');
  }, skip: notWindows);

  group('held by something else', () {
    setUp(() async {
      await w('p.abc.zestssh_db_encryption_key', 'k' * 64);
      await w('profiles_v1', 'the list');
    });

    Future<RandomAccessFile> hold() async {
      final holder = await File(path).open(mode: FileMode.append);
      await holder.lock(FileLock.exclusive);
      return holder;
    }

    Future<void> letGo(RandomAccessFile holder) async {
      await holder.unlock();
      await holder.close();
    }

    test('for a moment: a read waits, and says what is there', () async {
      final holder = await hold();
      final reading = r('p.abc.zestssh_db_encryption_key');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await letGo(holder);
      expect(await reading, 'k' * 64);
    }, skip: notWindows);

    test('for a moment: a write waits, and everything else is still there after it', () async {
      final holder = await hold();
      final writing = w('p.abc.session_uid', 'x');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await letGo(holder);
      await writing;
      expect((await all()).keys, unorderedEquals(['p.abc.zestssh_db_encryption_key', 'profiles_v1', 'p.abc.session_uid']));
    }, skip: notWindows);

    test('for long: a read says what the last write left, a write says it failed, in bounded time, and nothing goes', () async {
      final holder = await hold();
      final clock = Stopwatch()..start();
      expect(await r('p.abc.zestssh_db_encryption_key'), 'k' * 64);
      await expectLater(w('p.abc.session_uid', 'x'), throwsA(isA<KeychainFileFailed>()));
      expect(clock.elapsed, lessThan(const Duration(seconds: 20)), reason: 'nothing loops for ever');
      await letGo(holder);
      expect((await all()).keys, unorderedEquals(['p.abc.zestssh_db_encryption_key', 'profiles_v1']));
    }, skip: notWindows);

    test('a write never builds on the copy, which an older version\'s write leaves behind', () async {
      await thePlugin().write(key: 'p.abc.newest', value: 'the last write', options: _o);
      final next = nextLaunch();
      final holder = await hold();
      // Held past what a read waits for, and let go while a write that went on from
      // the copy would be waiting to take the file's place.
      final writing = w('p.abc.after', 'x', next).then<Object?>((_) => null, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 3400));
      await letGo(holder);
      expect(await writing, isA<KeychainFileFailed>().having((e) => e.step, 'step', 'write'));
      expect(await r('p.abc.newest', nextLaunch()), 'the last write');
    }, skip: notWindows);

    test('for long, with no copy: a read says it failed, and never that there is nothing', () async {
      await File('$path.good').delete();
      final holder = await hold();
      await expectLater(r('p.abc.zestssh_db_encryption_key'), throwsA(isA<KeychainFileFailed>()));
      await letGo(holder);
      expect(await r('p.abc.zestssh_db_encryption_key'), 'k' * 64);
    }, skip: notWindows);
  });

  test('a read-only file: a write throws and says so, in bounded time, and what is there stays', () async {
    await w('p.abc.zestssh_db_encryption_key', 'k' * 64);
    await Process.run('attrib', ['+R', path]);
    final clock = Stopwatch()..start();
    await expectLater(w('p.abc.session_uid', 'x'), throwsA(isA<KeychainFileFailed>().having((e) => e.step, 'step', 'write')));
    expect(clock.elapsed, lessThan(const Duration(seconds: 10)));
    expect(await r('p.abc.zestssh_db_encryption_key'), 'k' * 64);
    await Process.run('attrib', ['-R', path]);
    await w('p.abc.session_uid', 'x');
    expect(await r('p.abc.session_uid'), 'x');
  }, skip: notWindows);

  group('a batch', () {
    test('many writes, one file written, and each read sees them', () async {
      await w('dbkey', 'k' * 64);
      final before = file.replaced;
      await store.batch(() async {
        for (var i = 0; i < 200; i++) {
          await w('identity_key_$i', 'value $i');
          expect(await r('identity_key_$i'), 'value $i');
        }
        await store.delete(key: 'dbkey', options: _o);
      });
      expect(file.replaced - before, 1);
      final next = await all(nextLaunch());
      expect(next, hasLength(200));
      expect(next.containsKey('dbkey'), isFalse);
    }, skip: notWindows);

    test('writes that overlap inside it lose nothing: the queue is what keeps them apart there', () async {
      await store.batch(() async {
        await Future.wait([for (var i = 0; i < 20; i++) w('k$i', 'v$i')]);
      });
      expect(await nextLaunch().readAll(options: _o), hasLength(20));
    }, skip: notWindows);

    test('a throw or a stop inside leaves the file as it was', () async {
      await w('dbkey', 'k' * 64);
      await expectLater(
        store.batch(() async {
          await w('identity_key_1', 'value');
          throw const _Stopped();
        }),
        throwsA(isA<_Stopped>()),
      );
      expect(await r('identity_key_1'), isNull);
      expect(await r('dbkey'), 'k' * 64);
      file.stop = (at) {
        if (at == 'temp-written') throw const _Stopped();
      };
      await expectLater(store.batch(() => w('identity_key_2', 'value')), throwsA(isA<_Stopped>()));
      file.stop = null;
      expect(await r('identity_key_2', nextLaunch()), isNull);
      expect(await r('dbkey', nextLaunch()), 'k' * 64);
    }, skip: notWindows);

    test('what is not part of it waits, and never sees what may be taken back', () async {
      await w('dbkey', 'k' * 64);
      final inside = Completer<void>();
      final going = Completer<void>();
      final batch = store.batch(() async {
        await w('identity_key_1', 'value');
        inside.complete();
        await going.future;
        throw const _Stopped();
      });
      await inside.future;
      String? seen = 'not read yet';
      final outside = r('identity_key_1').then((v) => seen = v);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(seen, 'not read yet');
      going.complete();
      await expectLater(batch, throwsA(isA<_Stopped>()));
      await outside;
      expect(seen, isNull);
    }, skip: notWindows);
  });

  test('another window or process on the same file: a lock file keeps them apart, and nothing is lost', () async {
    await w('dbkey', 'k' * 64);
    // Two other isolates, each with its own engine's state as a pop-out has, and
    // this one.
    await Future.wait([
      Isolate.run(_writer(path, 'a')),
      Isolate.run(_writer(path, 'b')),
      _writer(path, 'c')(),
    ]);
    final left = await all();
    expect(left['dbkey'], 'k' * 64);
    for (final name in ['a', 'b', 'c']) {
      for (var i = 0; i < 25; i++) {
        expect(left.containsKey('$name$i'), isTrue, reason: '$name$i');
      }
    }
  }, skip: notWindows, timeout: const Timeout(Duration(minutes: 2)));

  test('a lock another holds for long: a write says so, in bounded time; a read goes on', () async {
    await w('dbkey', 'k' * 64);
    final other = await File('$path.lock').open(mode: FileMode.append);
    await other.lock(FileLock.exclusive);
    final clock = Stopwatch()..start();
    await expectLater(w('x', 'y'), throwsA(isA<KeychainFileFailed>().having((e) => e.step, 'step', 'busy')));
    expect(clock.elapsed, lessThan(const Duration(seconds: 15)));
    // A read needs no lock: a write only ever replaces the file whole.
    final reading = Stopwatch()..start();
    expect(await r('dbkey'), 'k' * 64);
    expect(reading.elapsed, lessThan(const Duration(seconds: 2)));
    await other.close();
    await w('x', 'y');
  }, skip: notWindows, timeout: const Timeout(Duration(minutes: 1)));

  test('a file that cannot be encrypted says so like any other write', () async {
    final refusing = SafeWindowsKeychain(SafeKeychainFile(path: () async => path, cipher: _Refusing()), legacy: NoLegacy());
    await expectLater(w('k', 'v', refusing), throwsA(isA<KeychainFileFailed>().having((e) => e.step, 'step', 'write')));
    expect(File(path).existsSync(), isFalse);
  });

  test('a failure names no path: it has a person\'s name in it', () async {
    expect('${const KeychainFileFailed('write', 5)}', 'KeychainFileFailed(write, os error 5)');
  });
}
