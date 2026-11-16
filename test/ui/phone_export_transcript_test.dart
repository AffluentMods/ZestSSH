import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/services/session_transcript_service.dart';

// A phone's Export transcript, when no recording runs, saves what the
// terminal holds as a recording is saved: encrypted, framed like one, in the
// transcripts folder the Transcripts page lists, and says so with the way to
// open it. It wrote plain text to terminal_<time>.txt in the documents
// folder, which nothing in the app listed or opened.
void main() {
  final source = File('lib/ui/screens/terminal/terminal_screen.dart').readAsStringSync();
  final start = source.indexOf('Future<void> _exportTranscript(');
  final body = source.substring(start, source.indexOf('Future<void> _shareTranscript(', start));

  test('nothing is written as plain text to the documents folder', () {
    expect(start, greaterThan(0));
    expect(body, isNot(contains(r'terminal_$timestamp')));
    expect(body, isNot(contains('getApplicationDocumentsDirectory')));
  });

  test('it saves what the terminal holds with saveSnapshot, and says how to open it', () {
    expect(body, contains('SessionTranscriptService.saveSnapshot(terminal, connectionLabel: connectionLabel)'));
    expect(body, contains('l10n.transcriptsOpen'));
  });

  // What saveSnapshot writes, read from the disk: the source pins alone
  // passed with the rule gone (found in a review).
  test('saved encrypted, framed as a transcript, as a transcript the app lists', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('zest_tx_snapshot_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final terminal = Terminal()..write('cat notes.txt\r\nthe northwind-demo line\r\n');
    final path = await SessionTranscriptService.saveSnapshot(terminal, connectionLabel: 'web-01', folder: dir.path);
    expect(path, isNotNull, reason: '${SessionTranscriptService.lastSaveError}');
    final bytes = File(path!).readAsBytesSync();
    expect(String.fromCharCodes(bytes), isNot(contains('northwind-demo')), reason: 'not plain text on disk');
    final read = await SessionTranscriptService.readFromFile(path);
    expect(read, contains('the northwind-demo line'));
    expect(read, contains('ZestSSH Session Transcript'));
    expect(read, contains('Connection: web-01'));
    expect([for (final t in await SessionTranscriptService.listSaved(folder: dir)) t.path.replaceAll('\\', '/')],
        [path.replaceAll('\\', '/')]);
  });

  test('an empty terminal says there is nothing to save', () {
    expect(body, contains('l10n.transcriptNothingToSave'));
  });
}
