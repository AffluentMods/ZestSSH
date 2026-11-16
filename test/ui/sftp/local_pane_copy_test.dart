import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';

/// A copy on this device (both panes "This computer", or any
/// LocalPaneFileSource copy) of a file over the 8 MB flush threshold added to
/// the staging file's IOSink while a flush it had not waited for was still
/// running, and dart:io's IOSink throws "StreamSink is bound to a stream" for
/// that: every such copy failed, and the close in the cleanup threw the same,
/// so the staging file was left beside the destination (found in a
/// review).
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local_pane_copy_');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  String inDir(String name) => '${dir.path}${Platform.pathSeparator}$name';

  Future<Uint8List> bigFile(String path, int megabytes) async {
    final rnd = Random(7);
    final data = Uint8List(megabytes * 1024 * 1024);
    for (var i = 0; i < data.length; i += 4096) {
      data[i] = rnd.nextInt(256);
    }
    await File(path).writeAsBytes(data, flush: true);
    return data;
  }

  test('a 24 MB file is copied whole, with nothing left beside it', () async {
    final data = await bigFile(inDir('big.bin'), 24);
    final dest = inDir('copy.bin');
    final progress = <int>[];

    await LocalPaneFileSource().downloadFile(inDir('big.bin'), dest, onProgress: (done, total) => progress.add(done));

    expect(await File('$dest.zestpart').exists(), isFalse);
    expect(await File(dest).readAsBytes(), data);
    expect(progress.last, data.length);
  });

  test('the same over an upload, onto a file that was there', () async {
    final data = await bigFile(inDir('big.bin'), 20);
    final dest = inDir('there.bin');
    await File(dest).writeAsString('old');

    await LocalPaneFileSource().uploadFile(inDir('big.bin'), dest);

    expect(await File('$dest.zestpart').exists(), isFalse);
    expect(await File(dest).length(), data.length);
  });

  test('a cancelled copy leaves the destination as it was and no staging file', () async {
    await bigFile(inDir('big.bin'), 24);
    final dest = inDir('there.bin');
    await File(dest).writeAsString('old');
    final cancel = TransferCancelToken();

    await expectLater(
      LocalPaneFileSource().downloadFile(inDir('big.bin'), dest, cancelToken: cancel, onProgress: (done, total) {
        if (done > 12 * 1024 * 1024) cancel.cancel();
      }),
      throwsA(isA<TransferCancelledException>()),
    );

    expect(await File('$dest.zestpart').exists(), isFalse);
    expect(await File(dest).readAsString(), 'old');
  });
}
