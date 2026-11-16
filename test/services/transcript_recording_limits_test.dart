import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/session_transcript_service.dart';

/// A session recording that outgrows its caps says what it left out, and a
/// save never leaves a cut file under the name (found in a review).
/// Past 16 MB the oldest output went with nothing in the file to say so, and
/// the save wrote straight onto the name: a save stopped in the middle left
/// a cut file there, over the one before.
void main() {
  test('a recording past 16 MB says how much of its start was left out', () {
    SessionTranscriptService.startRecording('s-1', 'web-01');
    addTearDown(() => SessionTranscriptService.stopRecording('s-1'));
    final chunk = 'x' * (1024 * 1024);
    for (var i = 0; i < 17; i++) {
      SessionTranscriptService.appendOutput('s-1', chunk);
    }
    final text = SessionTranscriptService.exportAsText('s-1');
    expect(text, contains('NOTE: The first 1048576 characters of output were left out.'));
    expect(text, contains('A recording keeps at most 16 MB'));
  });

  test('a recording within its caps has no such note', () {
    SessionTranscriptService.startRecording('s-2', 'web-01');
    addTearDown(() => SessionTranscriptService.stopRecording('s-2'));
    SessionTranscriptService.appendOutput('s-2', 'hello');
    expect(SessionTranscriptService.exportAsText('s-2'), isNot(contains('were left out')));
  });

  test('a save that fails leaves the file before it as it was and nothing beside it', () async {
    final dir = Directory.systemTemp.createTempSync('zest_tx_save_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/session.txt';
    File(path).writeAsStringSync('the saved one');
    // The part file cannot be written (a folder stands in its place).
    Directory('$path.part').createSync();
    final saved = await SessionTranscriptService.saveTextToPath('the new one', path, encrypt: false);
    expect(saved, isNull);
    expect(File(path).readAsStringSync(), 'the saved one');
  });

  test('a save goes in whole under the name, and replaces the one before', () async {
    final dir = Directory.systemTemp.createTempSync('zest_tx_save_ok_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/session.txt';
    File(path).writeAsStringSync('the saved one');
    final saved = await SessionTranscriptService.saveTextToPath('the new one', path, encrypt: false);
    expect(saved, path);
    expect(File(path).readAsStringSync(), 'the new one');
    expect(File('$path.part').existsSync(), isFalse);
  });
}
