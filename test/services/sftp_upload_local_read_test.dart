import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';

import '../helpers/played_sftp_host.dart';

/// A file on this device that cannot be read to its end while it is
/// uploaded (3.0, the SSH core's audit), through the app's own file service
/// with the host played by the test, and the file one whose reading breaks
/// off as the test says: a stick that is pulled out, a file that another
/// program holds.
///
/// What writes a file to a host listened to the file for its bytes and its
/// end, and not for its failing: the failure went to nobody, and the upload
/// went on as one whose file had ended there. Held against the size of the
/// file it then said that so many bytes were sent and so many arrived, of a
/// file that this device had not let it read.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Uint8List bytes(String words) => Uint8List.fromList(utf8.encode(words));
  String held(PlayedSftpHost host, String path) => utf8.decode(host.files[path]!.bytes);

  /// A file of [size] bytes on this device, removed at the end.
  Future<File> onThisDevice(int size) async {
    final folder = await Directory.systemTemp.createTemp('zest-app-sftp-local-read-test');
    addTearDown(() => folder.delete(recursive: true));
    return File('${folder.path}/report.pdf')..writeAsBytesSync(Uint8List(size));
  }

  /// Runs [body] with [file] breaking off when [after] bytes of it were
  /// read, with [error]; every other file on this device is what it is.
  Future<T> breakingOff<T>(File file, int after, Object error, Future<T> Function() body) => IOOverrides.runZoned(
        body,
        createFile: (path) {
          final real = Zone.root.run(() => File(path));
          return path == file.path ? _BreaksOff(real, after, error) : real;
        },
      );

  Future<(PlayedSftpHost, SftpService)> hostWithConf() async {
    final host = PlayedSftpHost()..files['/srv/conf'] = PlayedFile(bytes('old words'), permissions: 416);
    final sftp = SftpService(host.client);
    await sftp.open();
    addTearDown(sftp.close);
    return (host, sftp);
  }

  const notReady = FileSystemException('Read failed', 'report.pdf', OSError('The device is not ready', 21));
  const inUse = FileSystemException(
    'Cannot open file',
    'report.pdf',
    OSError('The process cannot access the file because it is being used by another process', 32),
  );

  test('a file whose reading breaks off half way: the upload fails with what this device said, nothing is put in the '
      'place of the file on the host, and what was beside it is cleared away', () async {
    final (host, sftp) = await hostWithConf();
    final file = await onThisDevice(100000);

    Object? failure;
    try {
      await breakingOff(file, 40000, notReady, () => sftp.uploadFileFromPath(file.path, '/srv/conf'));
    } catch (e) {
      failure = e;
    }

    expect(failure, same(notReady));
    expect(sftpErrorMessage(failure!, name: 'report.pdf', op: SftpOp.upload, l10n: en),
        'Local file error: The device is not ready');
    expect(host.asked.where((request) => request.startsWith('write ')), hasLength(2), reason: 'what was read went out');
    expect(host.asked.where((request) => request.startsWith('posix-rename')), isEmpty);
    expect(host.files.keys, ['/srv/conf']);
    expect(held(host, '/srv/conf'), 'old words');
    // (Anything thrown at nobody fails this test by itself.)
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('a file that this device does not let the app read at all: said as that, and not as bytes that did not '
      'arrive', () async {
    final (host, sftp) = await hostWithConf();
    final file = await onThisDevice(100000);

    Object? failure;
    try {
      await breakingOff(file, 0, inUse, () => sftp.uploadFileFromPath(file.path, '/srv/conf'));
    } catch (e) {
      failure = e;
    }

    expect(failure, same(inUse));
    expect(
      sftpErrorMessage(failure!, name: 'report.pdf', op: SftpOp.upload, l10n: en),
      'Local file error: The process cannot access the file because it is being used by another process',
    );
    expect(host.asked.where((request) => request.startsWith('write ')), isEmpty);
    expect(host.files.keys, ['/srv/conf']);
    expect(held(host, '/srv/conf'), 'old words');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('where the file on the host could only be written where it is, it holds part of the new content, and that '
      'is said behind what this device said', () async {
    final (host, sftp) = await hostWithConf();
    host.sealedFolders.add('/srv');
    final file = await onThisDevice(100000);

    Object? failure;
    try {
      await breakingOff(file, 40000, notReady, () => sftp.uploadFileFromPath(file.path, '/srv/conf'));
    } catch (e) {
      failure = e;
    }

    expect(failure, isA<SftpWrittenInPlaceException>().having((e) => e.cause, 'cause', same(notReady)));
    // The upload fails at once, with what was read still on its way to the host. The host answers in the order
    // it was asked: when this is answered, that has arrived. (Looked at without it, the file held the first
    // piece alone on a machine that was busy.)
    await sftp.stat('/srv/conf');
    expect(host.files['/srv/conf']!.bytes, hasLength(40000));
    expect(
      sftpErrorMessage(failure!, name: 'conf', op: SftpOp.upload, l10n: en),
      'Local file error: The device is not ready. On the server, "conf" could only be written where it is, so what '
      'it holds there now is part of the new content. Save or upload it again.',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
}

/// A file on this device whose reading breaks off: [_after] bytes of
/// [_real] come, and then [_error].
class _BreaksOff implements File {
  _BreaksOff(this._real, this._after, this._error);

  final File _real;
  final int _after;
  final Object _error;

  @override
  String get path => _real.path;

  @override
  Future<FileStat> stat() => _real.stat();

  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    if (_after > 0) yield Uint8List.sublistView(await _real.readAsBytes(), 0, _after);
    throw _error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test: ${invocation.memberName}');
}
