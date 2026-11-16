import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart';

import '../helpers/played_sftp_host.dart';

/// What becomes of a file on a host that was opened to be read (3.0, the
/// SSH core's audit), through the app's own file service with the host
/// played by the test.
///
/// A read into memory (what an editor opens, an image that is shown) that
/// failed half way left the file open on the host for as long as the session
/// lasted. And where the file was closed, nobody waited for what the host
/// said to that: a close that the host refused was an error thrown at
/// nobody. (A close that is asked of a session that has ended is not sent,
/// and fails nothing: it is a close that the host answers with a refusal
/// that nobody took.)
void main() {
  const path = '/srv/report.pdf';

  Future<(PlayedSftpHost, SftpService)> hostWithReport({int size = 100000}) async {
    final host = PlayedSftpHost()..files[path] = PlayedFile(Uint8List(size));
    final sftp = SftpService(host.client);
    await sftp.open();
    addTearDown(sftp.close);
    return (host, sftp);
  }

  /// Refuses the [nth] request that begins with [start], and every close where [closes] says so.
  int? Function(String) refusing(String start, int nth, {bool closes = false}) {
    var seen = 0;
    return (request) {
      if (closes && request.startsWith('close ')) return SftpStatusCode.failure;
      return request.startsWith(start) && ++seen == nth ? SftpStatusCode.failure : null;
    };
  }

  /// Runs [body], and gives everything that was thrown at nobody meanwhile.
  /// (What [body] itself fails with, an expectation of the test's, fails
  /// the test.)
  Future<List<Object>> thrownAtNobody(Future<void> Function() body) async {
    final uncaught = <Object>[];
    final over = Completer<void>();
    runZonedGuarded(() async {
      try {
        await body();
        over.complete();
      } catch (error, stack) {
        over.completeError(error, stack);
      }
    }, (error, stack) => uncaught.add(error));
    await over.future;
    return uncaught;
  }

  /// What the host was asked to close. (It answers in the order it was asked: when the file's state has been
  /// answered, everything asked before it has arrived.)
  Future<List<String>> closed(PlayedSftpHost host, SftpService sftp) async {
    await sftp.stat(path);
    return [
      for (final request in host.asked)
        if (request.startsWith('close ')) request,
    ];
  }

  /// A folder on this device for a download, removed at the end.
  Future<Directory> downloads() async {
    final folder = await Directory.systemTemp.createTemp('zest-app-sftp-handles-test');
    addTearDown(() => folder.delete(recursive: true));
    return folder;
  }

  group('read into memory', () {
    test('a read that the host refuses half way fails with the refusal, and the file is closed', () async {
      expect(
        await thrownAtNobody(() async {
          final (host, sftp) = await hostWithReport();
          host.refuses = refusing('read ', 2);
          await expectLater(sftp.downloadFile(path), throwsA(isA<SftpStatusError>()));
          expect(await closed(host, sftp), ['close $path']);
        }),
        isEmpty,
      );
    });

    test('where the close is refused as well, that is nobody\'s: the read fails with what the read failed with',
        () async {
      expect(
        await thrownAtNobody(() async {
          final (host, sftp) = await hostWithReport();
          host.refuses = refusing('read ', 2, closes: true);
          await expectLater(sftp.downloadFile(path), throwsA(isA<SftpStatusError>()));
          expect(await closed(host, sftp), ['close $path']);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }),
        isEmpty,
      );
    });

    test('a file that was read to its end is closed, and a close that the host refuses takes nothing from what was '
        'read', () async {
      expect(
        await thrownAtNobody(() async {
          final (host, sftp) = await hostWithReport();
          expect(await sftp.downloadFile(path), hasLength(100000));
          expect(await closed(host, sftp), ['close $path']);

          host.refuses = refusing('close ', 1);
          expect(await sftp.downloadFile(path), hasLength(100000));
          expect(await closed(host, sftp), ['close $path', 'close $path']);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }),
        isEmpty,
      );
    });

    test('a file that is larger than may be read is not opened where the size the host reports says so, and is '
        'closed where it is what comes that says so', () async {
      expect(
        await thrownAtNobody(() async {
          final (host, sftp) = await hostWithReport();
          await expectLater(sftp.downloadFile(path, maxBytes: 50000), throwsA(isA<SftpFileTooLargeException>()));
          expect(host.asked, ['stat $path'], reason: 'its size, and nothing else');

          // A host that reports no size for it: it is read to where it ends, or to what may be read.
          host.saysSizes = false;
          host.refuses = refusing('close ', 1);
          await expectLater(sftp.downloadFile(path, maxBytes: 50000), throwsA(isA<SftpFileTooLargeException>()));
          expect(await closed(host, sftp), ['close $path']);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }),
        isEmpty,
      );
    });
  });

  group('download to a file on this device', () {
    test('a read that the host refuses half way fails with the refusal, the file on the host is closed, and a close '
        'that is refused as well is nobody\'s', () async {
      expect(
        await thrownAtNobody(() async {
          final (host, sftp) = await hostWithReport();
          final folder = await downloads();
          host.refuses = refusing('read ', 2, closes: true);
          await expectLater(
              sftp.downloadFileToPath(path, '${folder.path}/report.pdf'), throwsA(isA<SftpStatusError>()));
          expect(await closed(host, sftp), ['close $path']);
          expect(File('${folder.path}/report.pdf').existsSync(), isFalse);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }),
        isEmpty,
      );
    });

    test('a file that the size the host reports says is larger than may be downloaded is refused before it is '
        'opened, with nothing made on this device for it, and a download of it that was broken off is as it was',
        () async {
      expect(
        await thrownAtNobody(() async {
          final (host, sftp) = await hostWithReport();
          final folder = await downloads();
          await expectLater(sftp.downloadFileToPath(path, '${folder.path}/report.pdf', maxBytes: 50000),
              throwsA(isA<SftpFileTooLargeException>()));
          expect(host.asked, ['stat $path'], reason: 'its size, and nothing else');
          expect(folder.listSync(), isEmpty);

          // What an earlier download of it left, broken off after 30000 bytes: it and its note stay as they were.
          final part = File('${folder.path}/report.pdf.zestpart')..writeAsBytesSync(Uint8List(30000));
          final note = File('${folder.path}/report.pdf.zestpart.meta')..writeAsStringSync('a note of its own');
          await expectLater(sftp.downloadFileToPath(path, '${folder.path}/report.pdf', maxBytes: 50000),
              throwsA(isA<SftpFileTooLargeException>()));
          expect(part.lengthSync(), 30000);
          expect(note.readAsStringSync(), 'a note of its own');
          expect(folder.listSync(), hasLength(2));
        }),
        isEmpty,
      );
    });

    test('a download that was broken off goes on from what is there when it came from this host, and starts over '
        'when it came from another', () async {
      final (_, sftp) = await hostWithReport();
      final folder = await downloads();
      final part = File('${folder.path}/report.pdf.zestpart');
      final note = File('${folder.path}/report.pdf.zestpart.meta');
      final marked = Uint8List(30000)..fillRange(0, 30000, 0xEE);
      final thisHost = transferSource('sftp', [7, 7, 7, 7, 0, ...'deploy'.codeUnits]);

      // The same path and size, on another host: none of its bytes are kept.
      part.writeAsBytesSync(marked);
      note.writeAsStringSync(
          SftpPartialMeta(remotePath: path, remoteSize: 100000, source: transferSource('sftp', [9, 9, 9, 9])).encode());
      await sftp.downloadFileToPath(path, '${folder.path}/report.pdf');
      var got = File('${folder.path}/report.pdf').readAsBytesSync();
      expect(got, hasLength(100000));
      expect(got.any((b) => b != 0), isFalse, reason: 'all of it is from the host asked now');
      File('${folder.path}/report.pdf').deleteSync();

      // A note from before the host was written into it: started over too.
      part.writeAsBytesSync(marked);
      note.writeAsStringSync(const SftpPartialMeta(remotePath: path, remoteSize: 100000).encode());
      await sftp.downloadFileToPath(path, '${folder.path}/report.pdf');
      got = File('${folder.path}/report.pdf').readAsBytesSync();
      expect(got.any((b) => b != 0), isFalse);
      File('${folder.path}/report.pdf').deleteSync();

      // From this host: it goes on after the 30000 bytes that are there.
      part.writeAsBytesSync(marked);
      note.writeAsStringSync(SftpPartialMeta(remotePath: path, remoteSize: 100000, source: thisHost).encode());
      await sftp.downloadFileToPath(path, '${folder.path}/report.pdf');
      got = File('${folder.path}/report.pdf').readAsBytesSync();
      expect(got, hasLength(100000));
      expect(got.sublist(0, 30000).every((b) => b == 0xEE), isTrue, reason: 'what was there is kept');
      expect(got.sublist(30000).any((b) => b != 0), isFalse);
    });

    test('a file of which more comes than may be downloaded, from a host that reports no size for it: the download '
        'ends there, the file on the host is closed, and what was written for it on this device is removed',
        () async {
      expect(
        await thrownAtNobody(() async {
          final (host, sftp) = await hostWithReport();
          final folder = await downloads();
          host.saysSizes = false;
          host.refuses = refusing('close ', 1);
          await expectLater(sftp.downloadFileToPath(path, '${folder.path}/report.pdf', maxBytes: 50000),
              throwsA(isA<SftpFileTooLargeException>()));
          expect(await closed(host, sftp), ['close $path']);
          expect(folder.listSync(), isEmpty);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }),
        isEmpty,
      );
    });

    test('a download into a folder that is not there yet makes the folder and lands whole (an iPhone never makes '
        'the app\'s folder for downloads: the first download failed there)', () async {
      final (host, sftp) = await hostWithReport();
      final folder = await downloads();
      final local = '${folder.path}/not/there/yet/report.pdf';
      await sftp.downloadFileToPath(path, local);
      expect(File(local).lengthSync(), 100000);
      expect(Directory('${folder.path}/not/there/yet').listSync().map((e) => e.uri.pathSegments.last), ['report.pdf'],
          reason: 'no staging file or note left beside it');
      expect(await closed(host, sftp), ['close $path']);
    });

    test('a download that is complete is closed, and a close that the host refuses takes nothing from it', () async {
      expect(
        await thrownAtNobody(() async {
          final (host, sftp) = await hostWithReport();
          final folder = await downloads();
          host.refuses = refusing('close ', 1);
          await sftp.downloadFileToPath(path, '${folder.path}/report.pdf');
          expect(File('${folder.path}/report.pdf').lengthSync(), 100000);
          expect(await closed(host, sftp), ['close $path']);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }),
        isEmpty,
      );
    });
  });
}
