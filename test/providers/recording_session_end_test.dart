import 'dart:io';

import 'package:flutter/material.dart' show Locale;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/redactor.dart';

/// Sessions the test sets directly.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void set(Map<String, SessionState> sessions) => state = sessions;
}

/// A shell that is connected and sends nothing anywhere.
class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

SessionState _connected(String id, String label) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-$id',
      connectionLabel: label,
      host: '192.0.2.10',
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: 'c-$id',
        terminal: Terminal(maxLines: 100),
        shell: _Shell(),
        startedAt: DateTime(2026, 10, 16, 9),
      ),
    );

/// A recording of a session outlives the screen it was started from, and is
/// saved as its session ends (3.0, found while comparing the
/// five versions): it lived in memory only, so a session that ended while it
/// was being recorded lost it, on every platform, and a phone threw it away
/// as the session's screen closed. Now the session's end saves it to the
/// transcripts folder, as stopping a recording on a phone does, and says
/// where, or that it could not be saved and why.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late Directory documents;
  late ProviderContainer container;

  setUp(() async {
    documents = Directory.systemTemp.createTempSync('zest_recordings_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => documents.path,
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
  });

  tearDown(() {
    container.dispose();
    for (final id in ['s1', 's2']) {
      SessionTranscriptService.stopRecording(id);
    }
    Redactor.instance.enabled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    try {
      documents.deleteSync(recursive: true);
    } catch (_) {}
  });

  _Sessions sessions() => container.read(activeSessionsProvider.notifier) as _Sessions;
  List<AppNotification> notices() => container.read(notificationCenterProvider).history;

  test('a session that ends while it is recorded: its transcript saved to the transcripts folder, the recording '
      'stopped, and where it went said', () async {
    sessions().set({'s1': _connected('s1', 'web-01'), 's2': _connected('s2', 'db-01')});
    SessionTranscriptService.startRecording('s1', 'web-01');
    SessionTranscriptService.appendOutput('s1', 'uptime\r\n 09:12:01 up 3 days\r\n');

    await sessions().endSession('s1');
    expect(SessionTranscriptService.isRecording('s1'), isFalse);
    final saved = Directory('${documents.path}/${SessionTranscriptService.defaultSubdir}')
        .listSync()
        .whereType<File>()
        .toList();
    expect(saved, hasLength(1));
    expect(saved.single.readAsStringSync(), contains('up 3 days'), reason: 'what was recorded');
    final notice = notices().single;
    expect(notice.severity, NotificationSeverity.success);
    expect(notice.title, en.transcriptSavedTitle);
    final name = saved.single.uri.pathSegments.last;
    expect(notice.body,
        en.transcriptSessionEndedSaved('web-01', '${documents.path}/${SessionTranscriptService.defaultSubdir}/$name'));

    // A session that ends while nothing records it: nothing saved, nothing said.
    await sessions().endSession('s2');
    expect(notices(), hasLength(1));
    expect(Directory('${documents.path}/${SessionTranscriptService.defaultSubdir}').listSync(), hasLength(1));
  });

  test('one that could not be saved: said, with what stopped it, and the recording stopped', () async {
    // A file where the transcripts folder should be: nothing can be written there.
    File('${documents.path}/ZestSSH').writeAsStringSync('demo');
    sessions().set({'s1': _connected('s1', 'web-01')});
    SessionTranscriptService.startRecording('s1', 'web-01');

    await sessions().endSession('s1');
    expect(SessionTranscriptService.isRecording('s1'), isFalse);
    final notice = notices().single;
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.title, en.transcriptSessionEndedNotSaved('web-01'));
    expect(SessionTranscriptService.lastSaveError, isA<FileSystemException>());
    expect(notice.details, '${SessionTranscriptService.lastSaveError}');
  });

  test('while the screen is recorded, the host is not said as it is', () async {
    Redactor.instance.enabled = true;
    sessions().set({'s1': _connected('s1', 'web-01')});
    SessionTranscriptService.startRecording('s1', 'web-01');

    await sessions().endSession('s1');
    final notice = notices().single;
    expect(notice.body, isNot(contains('web-01')));
    expect(notice.body, startsWith(en.transcriptSessionEndedSaved('', '').split(' ').first));
  });
}
