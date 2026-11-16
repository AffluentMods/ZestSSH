import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/session_transcript_service.dart';

/// A running recording is written to disk as it goes, so an app that is
/// killed keeps what was recorded (found in a review): it lived in
/// memory until it was saved.
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('zest_tx_checkpoint_');
    SessionTranscriptService.checkpointFolder = () async => dir;
  });
  tearDown(() {
    SessionTranscriptService.forgetAll();
    SessionTranscriptService.checkpointEvery = const Duration(seconds: 30);
    dir.deleteSync(recursive: true);
  });

  List<File> files() => dir.listSync().whereType<File>().toList();

  test('what was recorded is on disk while it runs, and only what is new is written again', () async {
    SessionTranscriptService.startRecording('s-1', 'web-01');
    SessionTranscriptService.appendOutput('s-1', 'uptime\n 12:00 up 3 days\n');
    final path = await SessionTranscriptService.checkpoint('s-1');
    expect(path, isNotNull);
    expect(path!.split(Platform.pathSeparator).last.split('/').last, startsWith(SessionTranscriptService.checkpointPrefix));
    expect(await SessionTranscriptService.readFromFile(path), contains('12:00 up 3 days'));
    // Nothing new: nothing written.
    expect(await SessionTranscriptService.checkpoint('s-1'), isNull);
    SessionTranscriptService.appendOutput('s-1', 'df -h\n');
    expect(await SessionTranscriptService.checkpoint('s-1'), path);
    expect(await SessionTranscriptService.readFromFile(path), contains('df -h'));
  });

  test('it is written by itself while the recording runs', () async {
    SessionTranscriptService.checkpointEvery = const Duration(milliseconds: 50);
    SessionTranscriptService.startRecording('s-2', 'web-01');
    SessionTranscriptService.appendOutput('s-2', 'tail -f app.log\n');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(files(), hasLength(1));
  });

  test('saved and stopped, the running copy goes; stopped with no save after the last output, it stays', () async {
    SessionTranscriptService.startRecording('s-3', 'web-01');
    SessionTranscriptService.appendOutput('s-3', 'one\n');
    await SessionTranscriptService.checkpoint('s-3');
    final saved = await SessionTranscriptService.saveToPath('s-3', '${dir.path}/kept.txt', encrypt: false);
    expect(saved, isNotNull);
    SessionTranscriptService.stopRecording('s-3');
    expect([for (final f in files()) f.uri.pathSegments.last], ['kept.txt']);

    SessionTranscriptService.startRecording('s-4', 'db-01');
    SessionTranscriptService.appendOutput('s-4', 'two\n');
    final running = await SessionTranscriptService.checkpoint('s-4');
    // The save at the session's end failed (here: none was made).
    SessionTranscriptService.stopRecording('s-4');
    expect(File(running!).existsSync(), isTrue, reason: 'the only copy of what was recorded');
  });
}
