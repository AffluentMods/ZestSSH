import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart';

import '../helpers/played_sftp_host.dart';

/// How a save and an upload end (3.0, the SSH core's audit), through the
/// app's own file service with the host played by the test, since no real
/// server can be made to refuse a close or to fail a write half way.
///
/// The editor on a phone saved into the file itself: cut to nothing when it
/// was opened, written from its beginning, and called saved before the host
/// had closed it, with nothing held against what the host then had. And
/// what an upload wrote beside a file was put in the file's place without
/// waiting for the host to close it: a close that the host refuses (a home
/// folder on a network with a limit says only then that it is full) was
/// seen by nobody, and what the host had not kept was put in the place of
/// the file.
void main() {
  /// The two ways in which the file service is handed what to write.
  final ways = <String, Future<void> Function(SftpService sftp, String path, Uint8List content)>{
    'the text of the editor on a phone': (sftp, path, content) => sftp.uploadFile(path, content),
    'a file on this device': (sftp, path, content) async {
      final folder = await Directory.systemTemp.createTemp('zest-app-sftp-save-test');
      addTearDown(() => folder.delete(recursive: true));
      final file = File('${folder.path}/content')..writeAsBytesSync(content);
      await sftp.uploadFileFromPath(file.path, path);
    },
  };

  Future<SftpService> fileServiceOn(PlayedSftpHost host) async {
    final sftp = SftpService(host.client);
    await sftp.open();
    addTearDown(sftp.close);
    return sftp;
  }

  Uint8List bytes(String words) => Uint8List.fromList(utf8.encode(words));
  String held(PlayedSftpHost host, String path) => utf8.decode(host.files[path]!.bytes);

  /// Until [done], or the test fails for waiting.
  Future<void> until(bool Function() done) async {
    final clock = Stopwatch()..start();
    while (!done()) {
      if (clock.elapsed > const Duration(seconds: 10)) fail('waited ten seconds for it');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  PlayedSftpHost hostWithConf({bool oneStepRename = true}) =>
      PlayedSftpHost(oneStepRename: oneStepRename)..files['/srv/conf'] = PlayedFile(bytes('old words'), permissions: 416);

  test('the text of the editor on a phone is written beside the file, held against what the host has of it, closed, '
      'and put in the place of the file', () async {
    final host = hostWithConf();
    final sftp = await fileServiceOn(host);

    await sftp.uploadFile('/srv/conf', bytes('new words'));

    expect(host.asked, [
      'lstat /srv/conf',
      'open /srv/conf.zestpart',
      'fstat /srv/conf.zestpart',
      'write /srv/conf.zestpart',
      'fstat /srv/conf.zestpart',
      'close /srv/conf.zestpart',
      'posix-rename /srv/conf.zestpart /srv/conf',
    ]);
    expect(host.files.keys, ['/srv/conf']);
    expect(held(host, '/srv/conf'), 'new words');
    expect(host.files['/srv/conf']!.permissions, 416, reason: 'who may read it is who could (640)');

    // A file that is not there yet is made, with what the host gives a new file.
    host.asked.clear();
    await sftp.uploadFile('/srv/fresh', bytes('first words'));
    expect(host.asked, [
      'lstat /srv/fresh',
      'open /srv/fresh.zestpart',
      'write /srv/fresh.zestpart',
      'fstat /srv/fresh.zestpart',
      'close /srv/fresh.zestpart',
      'posix-rename /srv/fresh.zestpart /srv/fresh',
    ]);
    expect(held(host, '/srv/fresh'), 'first words');
    expect(host.files['/srv/fresh']!.permissions, 420);

    // A text with nothing in it: the file is there, and empty.
    await sftp.uploadFile('/srv/conf', Uint8List(0));
    expect(host.files.keys, ['/srv/conf', '/srv/fresh']);
    expect(host.files['/srv/conf']!.bytes, isEmpty);

    // More than goes into one piece: every byte, in its place.
    final long = Uint8List.fromList([for (var i = 0; i < 100000; i++) 32 + (i * 7 + i ~/ 95) % 95]);
    host.asked.clear();
    await sftp.uploadFile('/srv/conf', long);
    expect(host.files['/srv/conf']!.bytes, long);
    expect(host.asked.where((request) => request == 'write /srv/conf.zestpart'), hasLength(4));
  });

  test('on a host that cannot put a file in the place of another in one step, the file is closed before the one '
      'it replaces is moved aside, and that one is removed only when the new file is under the name', () async {
    final host = hostWithConf(oneStepRename: false);
    final sftp = await fileServiceOn(host);

    await sftp.uploadFile('/srv/conf', bytes('new words'));

    final asked = host.askedFrom('close ');
    // Moved aside under this upload's own name: nothing already there is removed first.
    final aside = asked[2].split(' ').last;
    expect(aside, matches(RegExp(r'^/srv/conf\.zestold-[0-9a-f]{8}$')));
    expect(asked, [
      'close /srv/conf.zestpart',
      'rename /srv/conf.zestpart /srv/conf',
      'rename /srv/conf $aside',
      'rename /srv/conf.zestpart /srv/conf',
      'remove $aside',
    ]);
    expect(host.files.keys, ['/srv/conf']);
    expect(held(host, '/srv/conf'), 'new words');
  });

  for (final MapEntry(key: what, value: save) in ways.entries) {
    group(what, () {
      test('is put in the place of the file only when the host has closed what was written', () async {
        final host = hostWithConf();
        final sftp = await fileServiceOn(host);
        final closed = Completer<void>();
        host.waitsFor = (request) => request.startsWith('close ') ? closed.future : null;

        var saved = false;
        final saving = save(sftp, '/srv/conf', bytes('new words')).then((_) => saved = true);
        await until(() => host.asked.contains('close /srv/conf.zestpart'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(host.asked.last, 'close /srv/conf.zestpart', reason: 'nothing is asked of the host meanwhile');
        expect(held(host, '/srv/conf'), 'old words');
        expect(saved, isFalse);

        closed.complete();
        await saving;
        expect(host.asked.last, 'posix-rename /srv/conf.zestpart /srv/conf');
        expect(held(host, '/srv/conf'), 'new words');
      });

      test('a close that the host refuses is a save that failed: nothing is put in the place of the file, and what '
          'was beside it is cleared away', () async {
        for (final oneStepRename in [true, false]) {
          final host = hostWithConf(oneStepRename: oneStepRename);
          final sftp = await fileServiceOn(host);
          host.refuses = (request) => request.startsWith('close ') ? SftpStatusCode.failure : null;

          await expectLater(
            save(sftp, '/srv/conf', bytes('new words')),
            throwsA(isA<SftpStatusError>().having((e) => e.code, 'code', SftpStatusCode.failure)),
          );

          expect(host.askedFrom('close '), ['close /srv/conf.zestpart', 'remove /srv/conf.zestpart'],
              reason: 'one step: $oneStepRename');
          expect(host.files.keys, ['/srv/conf']);
          expect(held(host, '/srv/conf'), 'old words');
          expect(host.files['/srv/conf']!.permissions, 416);
        }
      });

      test('a write that the host refuses half way leaves the file as it was, and a close that it then refuses as '
          'well is an error for nobody', () async {
        final host = hostWithConf();
        final sftp = await fileServiceOn(host);
        var writes = 0;
        host.refuses = (request) {
          if (request.startsWith('write ') && ++writes == 3) return SftpStatusCode.failure;
          return request.startsWith('close ') ? SftpStatusCode.failure : null;
        };

        await expectLater(
          save(sftp, '/srv/conf', Uint8List(100000)),
          throwsA(isA<SftpStatusError>().having((e) => e.code, 'code', SftpStatusCode.failure)),
        );
        await until(() => host.asked.last == 'remove /srv/conf.zestpart');

        expect(host.asked.where((request) => request.startsWith('close ') || request.startsWith('remove ')),
            ['close /srv/conf.zestpart', 'remove /srv/conf.zestpart'], reason: 'what was open is closed all the same');
        expect(host.asked.where((request) => request.startsWith('posix-rename')), isEmpty);
        expect(host.files.keys, ['/srv/conf']);
        expect(held(host, '/srv/conf'), 'old words');
        // (Anything thrown at nobody fails this test by itself.)
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });

      test('a host that says yes to every write and has kept less: nothing is put in the place of the file', () async {
        final host = hostWithConf()..keepsAtMost = 5;
        final sftp = await fileServiceOn(host);

        await expectLater(
          save(sftp, '/srv/conf', bytes('new words')),
          throwsA(isA<SftpIntegrityException>()
              .having((e) => e.expected, 'sent', 9)
              .having((e) => e.actual, 'kept', 5)),
        );

        expect(host.asked.where((request) => request.startsWith('posix-rename')), isEmpty);
        expect(host.asked.last, 'remove /srv/conf.zestpart');
        expect(host.files.keys, ['/srv/conf']);
        expect(held(host, '/srv/conf'), 'old words');

        // And one that has kept nothing at all.
        final empty = hostWithConf()..keepsAtMost = 0;
        await expectLater(
          save(await fileServiceOn(empty), '/srv/conf', bytes('new words')),
          throwsA(isA<SftpIntegrityException>().having((e) => e.actual, 'kept', 0)),
        );
        expect(held(empty, '/srv/conf'), 'old words');

        // A host that reports no size for a file: there is nothing to hold it against but its yes to every write.
        final silent = hostWithConf()..saysSizes = false;
        await save(await fileServiceOn(silent), '/srv/conf', bytes('new words'));
        expect(held(silent, '/srv/conf'), 'new words');
      });

      test('a host that refuses to put it in the place of the file: the file is as it was, and what was written '
          'stays beside it', () async {
        final host = hostWithConf();
        final sftp = await fileServiceOn(host);
        host.refuses = (request) => request.startsWith('posix-rename ') ? SftpStatusCode.failure : null;

        await expectLater(
          save(sftp, '/srv/conf', bytes('new words')),
          throwsA(isA<SftpStatusError>().having((e) => e.code, 'code', SftpStatusCode.failure)),
        );

        expect(host.files.keys, ['/srv/conf', '/srv/conf.zestpart']);
        expect(held(host, '/srv/conf'), 'old words');
        expect(held(host, '/srv/conf.zestpart'), 'new words', reason: 'all of it, to be had from there');
        expect(host.asked.last, startsWith('posix-rename '), reason: 'and nothing is removed');
      });

      test('in a folder that may not be written to the file itself is written, and a close that the host refuses '
          'there is said as a file that holds part of the new content', () async {
        final host = hostWithConf()..sealedFolders.add('/srv');
        final sftp = await fileServiceOn(host);

        await save(sftp, '/srv/conf', bytes('new words'));
        expect(host.asked.where((request) => request.startsWith('open ')), ['open /srv/conf.zestpart', 'open /srv/conf']);
        expect(host.asked.last, 'close /srv/conf');
        expect(host.files.keys, ['/srv/conf']);
        expect(held(host, '/srv/conf'), 'new words');

        host.refuses = (request) => request.startsWith('close ') ? SftpStatusCode.failure : null;
        await expectLater(
          save(sftp, '/srv/conf', bytes('newer words')),
          throwsA(isA<SftpWrittenInPlaceException>()
              .having((e) => e.remotePath, 'path', '/srv/conf')
              .having((e) => e.cause, 'cause', isA<SftpStatusError>())),
        );
      });

      test('written where it is, a file is held against the size the host reports only where that says that the '
          'host kept less: a setting whose size the host makes up is saved, and so is a file that a program on '
          'the host made longer meanwhile', () async {
        // What the kernel of a host makes up as it is read. Under /proc no size is reported for it, and of a
        // file that is to be made there the host says that there is no such file; under /sys a whole page is
        // reported, and making a file is not permitted.
        final kernel = PlayedSftpHost()
          ..madeUpFolders.add('/proc/sys/vm')
          ..files['/proc/sys/vm/swappiness'] = (PlayedFile(bytes('60 '))..reportsSize = 0)
          ..sealedFolders.add('/sys/class/leds/power')
          ..files['/sys/class/leds/power/brightness'] = (PlayedFile(bytes('0 '))..reportsSize = 4096);
        final settings = await fileServiceOn(kernel);
        await save(settings, '/proc/sys/vm/swappiness', bytes('10 '));
        await save(settings, '/sys/class/leds/power/brightness', bytes('255 '));
        expect(held(kernel, '/proc/sys/vm/swappiness'), '10 ');
        expect(held(kernel, '/sys/class/leds/power/brightness'), '255 ');
        expect(kernel.files.keys, ['/proc/sys/vm/swappiness', '/sys/class/leds/power/brightness']);

        // A file that a program on the host adds to while it is saved.
        final host = hostWithConf()..sealedFolders.add('/srv');
        final sftp = await fileServiceOn(host);
        host.refuses = (request) {
          final file = host.files['/srv/conf']!;
          if (request == 'fstat /srv/conf') file.bytes = Uint8List.fromList([...file.bytes, ...bytes(' and theirs')]);
          return null;
        };
        await save(sftp, '/srv/conf', bytes('new words'));
        expect(held(host, '/srv/conf'), 'new words and theirs');

        // A host that kept less than it said yes to: said, as a file that holds part of the new content.
        final short = hostWithConf()
          ..sealedFolders.add('/srv')
          ..keepsAtMost = 5;
        await expectLater(
          save(await fileServiceOn(short), '/srv/conf', bytes('new words')),
          throwsA(isA<SftpWrittenInPlaceException>().having((e) => e.cause, 'cause', isA<SftpIntegrityException>())),
        );
        expect(held(short, '/srv/conf'), 'new w');
      });
    });
  }
}
