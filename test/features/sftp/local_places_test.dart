import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/sftp/local_places.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';

/// A bug in 2.2.1 on Windows: opening SFTP froze the whole window for
/// about 30 seconds. The screen asked on the UI thread whether each drive
/// letter exists, and a letter mapped to a server that is off makes Windows
/// wait out its network timeout. These pin what replaced it: nothing the
/// screen needs at once touches a drive, and a drive that never answers
/// holds up nothing else.

/// A disk whose answers the test hands out: a path in [never] is asked and
/// never answers, like a mapped drive whose server is off.
class _Disk {
  _Disk({this.present = const {}, this.never = const {}});

  final Set<String> present;
  final Set<String> never;
  final asked = <String>[];
  final _hung = <Completer<bool>>[];

  Future<bool> exists(String path) {
    asked.add(path);
    if (never.contains(path)) {
      final c = Completer<bool>();
      _hung.add(c);
      return c.future;
    }
    return Future.value(present.contains(path));
  }

  /// The server came back (or Windows gave up): every waiting question is
  /// answered.
  void answerHung(bool value) {
    for (final c in _hung) {
      c.complete(value);
    }
    _hung.clear();
  }
}

const _winEnv = {'USERPROFILE': r'C:\Users\alex'};

// C: and D: listed by Windows.
int _maskCD() => (1 << 2) | (1 << 3);

// Every listed drive has something in it.
Future<bool> _hasMedia(String root) async => false;

List<String> _labels(List<LocalPlace> places) =>
    [for (final p in places) p.label];

void main() {
  test('the drive bitmask reads as letters, bit 0 being A', () {
    expect(driveLettersOf(0), isEmpty);
    expect(driveLettersOf(1), ['A']);
    expect(driveLettersOf((1 << 2) | (1 << 25)), ['C', 'Z']);
    expect(driveLettersOf(0x3FFFFFF).length, 26);
    // Bits past Z mean nothing.
    expect(driveLettersOf(1 << 26), isEmpty);
  });

  group('what the rail shows at once', () {
    test('Home and the drives Windows lists, without asking any disk', () {
      final disk = _Disk();
      final finder = LocalPlacesFinder(
        environment: _winEnv,
        isWindows: true,
        driveMask: _maskCD,
        directoryExists: disk.exists,
        driveIsEmpty: _hasMedia,
      );
      final places = finder.immediate();
      expect(places, const [
        LocalPlace(LocalPlaceKind.home, 'Home', r'C:\Users\alex'),
        LocalPlace(LocalPlaceKind.drive, 'C:', r'C:\'),
        LocalPlace(LocalPlaceKind.drive, 'D:', r'D:\'),
      ]);
      expect(places.where((p) => p.isRoot).map((p) => p.label), ['C:', 'D:']);
      expect(disk.asked, isEmpty,
          reason: 'the first paint must not wait on a disk or the network');
    });

    test('off Windows: Home from HOME and the filesystem root', () {
      final disk = _Disk();
      final finder = LocalPlacesFinder(
        environment: const {'HOME': '/home/alex'},
        isWindows: false,
        driveMask: () => fail('no drive letters off Windows'),
        directoryExists: disk.exists,
        driveIsEmpty: _hasMedia,
      );
      expect(finder.immediate(), const [
        LocalPlace(LocalPlaceKind.home, 'Home', '/home/alex'),
        LocalPlace(LocalPlaceKind.drive, '/', '/'),
      ]);
      expect(disk.asked, isEmpty);
    });

    test('no home folder known: the drives alone', () {
      final finder = LocalPlacesFinder(
        environment: const {'USERPROFILE': ''},
        isWindows: true,
        driveMask: _maskCD,
        directoryExists: _Disk().exists,
      );
      expect(_labels(finder.immediate()), ['C:', 'D:']);
    });

    test('a drive list that cannot be read is no drives, not a crash', () {
      final finder = LocalPlacesFinder(
        environment: _winEnv,
        isWindows: true,
        driveMask: () => throw StateError('kernel32 missing'),
        directoryExists: _Disk().exists,
      );
      expect(_labels(finder.immediate()), ['Home']);
    });
  });

  group('what joins as the disk answers', () {
    test('a drive that never answers holds up nothing: folders and the other '
        'drives still arrive, and it joins in letter order when it does',
        () async {
      // N: is a remembered network drive Windows has not reconnected (so it
      // is not in its list) and whose server is off.
      final disk = _Disk(
        present: {
          r'C:\Users\alex\Downloads',
          r'C:\Users\alex\Desktop',
          r'C:\Users\alex\Documents',
          r'N:\',
          r'X:\',
        },
        never: {r'N:\'},
      );
      final finder = LocalPlacesFinder(
        environment: _winEnv,
        isWindows: true,
        driveMask: _maskCD,
        directoryExists: disk.exists,
        driveIsEmpty: _hasMedia,
      );
      final events = <List<LocalPlace>>[];
      var closed = false;
      final sub = finder.watch().listen(events.add, onDone: () => closed = true);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      expect(_labels(events.first), ['Home', 'C:', 'D:'],
          reason: 'the first event is what is known at once');
      expect(_labels(events.last),
          ['Home', 'Downloads', 'Desktop', 'Documents', 'C:', 'D:', 'X:'],
          reason: 'everything but the drive that has not answered');
      expect(closed, isFalse, reason: 'one answer is still out');
      // A listed drive is never asked about: asking is what wakes a dead one.
      expect(disk.asked, isNot(contains(r'C:\')));
      expect(disk.asked, isNot(contains(r'D:\')));
      expect(disk.asked, contains(r'N:\'));

      disk.answerHung(true);
      await pumpEventQueue();
      expect(_labels(events.last),
          ['Home', 'Downloads', 'Desktop', 'Documents', 'C:', 'D:', 'N:', 'X:']);
      expect(closed, isTrue, reason: 'every check has answered');
    });

    test('a letter with nothing behind it is not listed', () async {
      final disk = _Disk();
      final finder = LocalPlacesFinder(
        environment: _winEnv,
        isWindows: true,
        driveMask: _maskCD,
        directoryExists: disk.exists,
        driveIsEmpty: _hasMedia,
      );
      final last = await finder.watch().last;
      expect(_labels(last), ['Home', 'C:', 'D:']);
      // Every letter Windows does not list was asked once, none twice.
      final letters = disk.asked.where((p) => p.length == 3).toList();
      expect(letters.length, 24);
      expect(letters.toSet().length, 24);
    });

    test('a user folder kept by OneDrive is found there first', () async {
      final disk = _Disk(present: {
        r'C:\Users\alex\OneDrive\Documents',
        r'C:\Users\alex\Documents',
        r'C:\Users\alex\Downloads',
      });
      final finder = LocalPlacesFinder(
        environment: const {
          'USERPROFILE': r'C:\Users\alex',
          'OneDrive': r'C:\Users\alex\OneDrive',
        },
        isWindows: true,
        driveMask: _maskCD,
        directoryExists: disk.exists,
        driveIsEmpty: _hasMedia,
      );
      final last = await finder.watch().last;
      final byLabel = {for (final p in last) p.label: p.path};
      expect(byLabel['Documents'], r'C:\Users\alex\OneDrive\Documents');
      expect(byLabel['Downloads'], r'C:\Users\alex\Downloads');
      expect(byLabel.containsKey('Desktop'), isFalse,
          reason: 'a folder that is nowhere is not offered');
      expect(await finder.resolveUserFolder('Desktop'), isNull);
    });

    test('a check that fails is a no, and the rest goes on', () async {
      Future<bool> exists(String path) async {
        if (path.endsWith('Downloads')) throw const FileSystemException('x');
        return path.endsWith('Desktop');
      }

      final finder = LocalPlacesFinder(
        environment: const {'HOME': '/home/alex'},
        isWindows: false,
        directoryExists: exists,
      );
      final last = await finder.watch().last;
      expect(_labels(last), ['Home', 'Desktop', '/']);
      expect(last[1].path, '/home/alex/Desktop');
    });

    test('an empty card reader leaves the rail; a network drive that is off '
        'stays, and so does a drive whose check fails', () async {
      // Windows lists C:, E: (card reader, nothing in it), F: (check fails)
      // and Z: (network drive, server off: the question never comes back).
      final never = Completer<bool>();
      final asked = <String>[];
      Future<bool> noMedia(String root) {
        asked.add(root);
        return switch (root) {
          r'E:\' => Future.value(true),
          r'F:\' => Future.error(StateError('no answer')),
          r'Z:\' => never.future,
          _ => Future.value(false),
        };
      }

      final disk = _Disk();
      final finder = LocalPlacesFinder(
        environment: const {'USERPROFILE': ''},
        isWindows: true,
        driveMask: () => (1 << 2) | (1 << 4) | (1 << 5) | (1 << 25),
        directoryExists: disk.exists,
        driveIsEmpty: noMedia,
      );
      expect(_labels(finder.immediate()), ['C:', 'E:', 'F:', 'Z:']);

      final events = <List<LocalPlace>>[];
      final sub = finder.watch().listen(events.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(_labels(events.last), ['C:', 'F:', 'Z:']);
      expect(asked.toSet(), {r'C:\', r'E:\', r'F:\', r'Z:\'});
      // A listed drive is asked whether it is empty, never whether it exists.
      expect(disk.asked.where((p) => p.startsWith('Z')), isEmpty);
    });

    test('nothing is delivered after the screen stops listening', () async {
      final disk = _Disk(present: {r'N:\'}, never: {r'N:\'});
      final finder = LocalPlacesFinder(
        environment: _winEnv,
        isWindows: true,
        driveMask: _maskCD,
        directoryExists: disk.exists,
        driveIsEmpty: _hasMedia,
      );
      final events = <List<LocalPlace>>[];
      final sub = finder.watch().listen(events.add);
      await pumpEventQueue();
      final seen = events.length;
      await sub.cancel();
      disk.answerHung(true);
      await pumpEventQueue();
      expect(events.length, seen);
    });
  });

  group('this computer (Windows only)', () {
    test('Windows lists the system drive, and it reports its space', () async {
      if (!Platform.isWindows) {
        markTestSkipped('Windows drives exist only on Windows');
        return;
      }
      final system = Platform.environment['SystemDrive'] ?? 'C:';
      expect(driveLettersOf(windowsLogicalDrives()), contains(system[0]));
      // The real finder, on the real disk: Home and the system drive at once.
      final places = LocalPlacesFinder().immediate();
      expect(_labels(places), containsAll(['Home', system]));

      final space = await windowsDiskSpace('$system\\');
      expect(space, isNotNull);
      expect(space!.total, greaterThan(0));
      expect(space.free, inInclusiveRange(0, space.total));
      // A folder on the volume answers for the volume, with or without the
      // trailing separator.
      final temp = Directory.systemTemp.path;
      expect((await windowsDiskSpace(temp))?.total, isNotNull);
      // The pane's own readout is this call.
      final pane = await LocalPaneFileSource().freeSpace('$system\\');
      expect(pane!.totalBytes, space.total);
    });

    test('a drive that is not there has no space to report', () async {
      if (!Platform.isWindows) {
        markTestSkipped('Windows drives exist only on Windows');
        return;
      }
      final listed = driveLettersOf(windowsLogicalDrives()).toSet();
      final free = [
        for (var i = 25; i >= 0; i--) String.fromCharCode(0x41 + i),
      ].firstWhere((l) => !listed.contains(l), orElse: () => '');
      if (free.isEmpty) return; // every letter is taken on this machine
      expect(await windowsDiskSpace('$free:\\'), isNull);
      expect(await windowsDiskSpace(''), isNull);
    });

    test('a fixed disk is never taken for an empty card reader', () async {
      if (!Platform.isWindows) {
        markTestSkipped('Windows drives exist only on Windows');
        return;
      }
      final system = Platform.environment['SystemDrive'] ?? 'C:';
      expect(await windowsDriveIsEmpty('$system\\'), isFalse);
      // The real finder keeps every drive this machine really has: the list
      // once all checks are in still holds the system drive.
      final last = await LocalPlacesFinder()
          .watch()
          .last
          .timeout(const Duration(seconds: 20));
      expect(_labels(last), contains(system));
    });
  });

  group('a local folder is read in a helper', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zestssh_listing_');
    });
    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('files, folders, sizes and hidden names come back as before',
        () async {
      File('${dir.path}${Platform.pathSeparator}a.txt').writeAsStringSync('12345');
      File('${dir.path}${Platform.pathSeparator}.secret').writeAsStringSync('x');
      Directory('${dir.path}${Platform.pathSeparator}sub').createSync();

      final all = await LocalPaneFileSource().list(dir.path);
      final byName = {for (final e in all) e.name: e};
      expect(byName.keys.toSet(), {'a.txt', '.secret', 'sub'});
      expect(byName['a.txt']!.size, 5);
      expect(byName['a.txt']!.isDirectory, isFalse);
      expect(byName['a.txt']!.modifiedAt, isNotNull);
      expect(byName['a.txt']!.permissions, hasLength(10));
      expect(byName['sub']!.isDirectory, isTrue);
      expect(byName['sub']!.size, 0);
      expect(byName['.secret']!.isHidden, isTrue);
      expect(byName['a.txt']!.path,
          '${dir.path}${Platform.pathSeparator}a.txt');

      final shown = await LocalPaneFileSource().list(dir.path, includeHidden: false);
      expect(shown.map((e) => e.name).toSet(), {'a.txt', 'sub'});

      // The helper and a direct read agree entry for entry.
      final direct = listLocalDirectory(dir.path);
      expect(direct.map((e) => '${e.name}|${e.size}|${e.isDirectory}').toSet(),
          all.map((e) => '${e.name}|${e.size}|${e.isDirectory}').toSet());
    });

    test('a folder that is not there is said as one, in the app\'s language',
        () async {
      final missing = '${dir.path}${Platform.pathSeparator}nope';
      // (3.0: it was a FileSystemException with the English
      // "Directory not found", said as a local file error.)
      await expectLater(
        LocalPaneFileSource().list(missing),
        throwsA(isA<PathNotFoundException>().having((e) => e.path, 'path', missing)),
      );
      try {
        await LocalPaneFileSource().list(missing);
      } catch (e) {
        expect(sftpErrorMessage(e, name: 'nope', op: SftpOp.list),
            sftpErrorMessage(PathNotFoundException(missing, const OSError('', 2)), name: 'nope', op: SftpOp.list));
        expect(sftpErrorMessage(e, name: 'nope', op: SftpOp.list), isNot(contains('Directory not found')));
      }
    });

    test('a link is reported as a link, with where it points', () async {
      final target = Directory('${dir.path}${Platform.pathSeparator}real')
        ..createSync();
      final link = Link('${dir.path}${Platform.pathSeparator}jump');
      try {
        link.createSync(target.path);
      } on FileSystemException {
        markTestSkipped('this account may not create links');
        return;
      }
      final entries = await LocalPaneFileSource().list(dir.path);
      final jump = entries.firstWhere((e) => e.name == 'jump');
      expect(jump.isSymlink, isTrue);
      expect(jump.isDirectory, isFalse,
          reason: 'a recursive copy or delete must act on the link itself');
      expect(jump.linkTarget, isNotNull);
    });
  });

  test('the SFTP screens ask the disk nothing on the UI thread', () {
    // A blocking call in these files is what froze the window: the screen and
    // the pane run on the UI thread, and a disk question there waits for as
    // long as the disk (or a dead network drive) takes.
    final blocking = RegExp(
        r'\b(existsSync|statSync|listSync|readAsBytesSync|readAsStringSync|'
        r'lengthSync|lastModifiedSync|resolveSymbolicLinksSync|targetSync)\(');
    for (final path in const [
      'lib/ui/screens/sftp/sftp_dual_pane_screen.dart',
      'lib/ui/screens/sftp/widgets/sftp_pane.dart',
      'lib/ui/screens/sftp/widgets/sftp_locations_rail.dart',
    ]) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        expect(blocking.hasMatch(line), isFalse,
            reason: '$path:${i + 1} blocks the UI thread: ${line.trim()}');
      }
    }
  });
}
