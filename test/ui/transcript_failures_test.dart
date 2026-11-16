import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/transcript_actions.dart';

/// A file picker that answers with [path].
class _Picker extends FilePicker {
  _Picker(this.path);

  final String path;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async =>
      path;
}

/// A transcript that could not be saved says so with what stopped it (3.0):
/// the saves answered null and the reason was only
/// logged; on a phone, stopping a recording whose save failed threw it away
/// as "Recording stopped", and exporting one said nothing.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late Directory tmp;
  late File blocker;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zest_transcripts_');
    // A file where a folder should be: nothing can be written under it.
    blocker = File('${tmp.path}${Platform.pathSeparator}blockerxq')..writeAsStringSync('demo');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmp.path,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String under(String name) => '${blocker.path}${Platform.pathSeparator}$name';

  group('a save that fails keeps what stopped it', () {
    test('a write that fails, and one that works after it', () async {
      expect(await SessionTranscriptService.saveTextToPath('uptime', under('t.txt'), encrypt: false), isNull);
      expect(SessionTranscriptService.lastSaveError, isA<FileSystemException>());
      final good = '${tmp.path}${Platform.pathSeparator}t.txt';
      expect(await SessionTranscriptService.saveTextToPath('uptime', good, encrypt: false), good);
      expect(SessionTranscriptService.lastSaveError, isNull, reason: 'one that worked leaves nothing behind');
    });

    test('a session that is not being recorded', () async {
      expect(await SessionTranscriptService.saveToPath('gone', '${tmp.path}/x.txt', encrypt: false), isNull);
      expect(SessionTranscriptService.lastSaveError, isA<StateError>());
      expect(await SessionTranscriptService.saveToFile('gone'), isNull);
      expect(SessionTranscriptService.lastSaveError, isA<StateError>());
    });
  });

  testWidgets('a computer says it was not saved, with what stopped it to copy', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    FilePicker.platform = _Picker(under('web-01.txt'));
    final terminal = Terminal()..write('uptime\r\n');
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => TranscriptActions.saveBufferSoFar(context, ref,
                  connectionLabel: 'web-01', terminal: terminal),
              child: const Text('save'),
            ),
          ),
        ),
      ),
    ));
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    await tester.tap(find.text('save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.desktopTerminalAreaPlainText));
    await tester.pump();
    for (var i = 0; i < 100 && container.read(notificationCenterProvider).history.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    final notice = container.read(notificationCenterProvider).history.first;
    expect(notice.title, en.desktopTerminalAreaSaveTranscriptError);
    expect(notice.details, contains('OS Error'));
    expect(notice.details, isNot(contains('blockerxq')), reason: 'a report names no folder');
    await tester.pump(const Duration(seconds: 8));
  });

  test('a phone keeps recording when stopping could not save, and says why', () {
    final source = File('lib/ui/screens/terminal/terminal_screen.dart').readAsStringSync().replaceAll('\r\n', '\n');
    final start = source.indexOf('Future<void> _toggleRecording(');
    final stop = source.indexOf('SessionTranscriptService.stopRecording(sessionId);', start);
    final failed = source.indexOf('if (path == null) {', start);
    expect(failed, greaterThan(start));
    expect(stop, greaterThan(failed));
    expect(source.substring(failed, stop), contains('return;'), reason: 'not stopped when not saved');
    final export = source.indexOf('Future<void> _exportTranscript(');
    expect(source.indexOf('if (path == null && mounted) {', export), greaterThan(export), reason: 'said, not silent');
    // What the terminal holds is saved as a transcript is (test/ui/phone_export_transcript_test.dart).
    expect(source.substring(export), contains('terminalTranscriptSaved(Redactable.freeText(path).display)'));
    // Every "not saved" a phone says carries what stopped it.
    final said = RegExp('desktopTerminalAreaSaveTranscriptError').allMatches(source).toList();
    expect(said, hasLength(3));
    for (final m in said) {
      expect(source.substring(m.end, m.end + 140), contains('details:'), reason: 'at ${m.start}');
    }
  });
}
