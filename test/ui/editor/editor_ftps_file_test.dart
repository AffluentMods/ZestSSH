import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/ftps.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/ftps/ftps_pane_file_source.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane_source.dart';

import '../../helpers/code_editor_text.dart';
import '../../helpers/fake_editor_source.dart';
import '../../services/ftps/fake_ftps_native.dart';

/// A file opened from an FTPS host's pane (3.4, found by a docs check
/// before the release): it was taken for this computer's, its tab said
/// "This PC" and its draft was kept as a local file's of the same path (one
/// tab and one draft with this computer's own file there). Its Save did go
/// to the server, through the pane's FTPS session. Now it is the host's
/// everywhere: its tab names the host, its draft is the host's (a team
/// host's in the team's database), Save writes through the FTPS session, and
/// Save as root is never offered. A delete on the pane names the host too.
class _Drafts implements EditorDraftStore {
  final Map<(String, String), EditorDraft> kept = {};

  @override
  Future<EditorDraft?> read(String identity, {String? team}) async => kept[(team ?? '', identity)];

  @override
  Future<void> write(String identity, EditorDraft draft, {String? team}) async => kept[(team ?? '', identity)] = draft;

  @override
  Future<void> remove(String identity, {String? team}) async => kept.remove((team ?? '', identity));

  @override
  Future<void> forgetOld({DateTime? now}) async {}
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  const path = '/home/demo/nginx.conf';
  final teamHost = EditorHost.saved(team: 'team-1', connectionId: 'ftps-host-1');

  Future<(FakeFtpsNative, FtpsPaneFileSource)> ftps() async {
    final native = FakeFtpsNative();
    final client = await FtpsClient.connect(
      const FtpsConnectOptions(host: 'files.example.test', port: 21, username: 'demo', password: 'pw'),
      pinnedSha256: native.certificateSha,
      native: native,
    );
    return (native, FtpsPaneFileSource(client: client, sourceId: 'session-1'));
  }

  PaneEditorSource ofPane(FtpsPaneFileSource files, {void Function()? onSaved}) => PaneEditorSource.ofPane(
        pane: FtpsPaneSource(sessionId: 'session-1', hostLabel: 'files-01', files: files),
        files: files,
        path: path,
        fileName: 'nginx.conf',
        thisComputer: 'This PC',
        hostOfSession: (sessionId) {
          expect(sessionId, 'session-1');
          return teamHost;
        },
        onSaved: onSaved,
      );

  test("an FTPS pane's file is its host's: named by it, told apart by its id, saved through the session", () async {
    final (native, files) = await ftps();
    addTearDown(files.close);
    native.files[path] = utf8.encode('worker_processes 1;\n');
    var saved = 0;
    final source = ofPane(files, onSaved: () => saved++);
    expect(source.isLocal, isFalse);
    expect(source.hostLabel, 'files-01');
    expect(source.host.key, teamHost.key);
    expect(source.host.known, isTrue);
    expect(source.host.team, 'team-1', reason: "a team host's draft is kept in the team's database");
    final local = PaneEditorSource.ofPane(
      pane: const LocalPaneSource(),
      files: LocalPaneFileSource(),
      path: path,
      fileName: 'nginx.conf',
      thisComputer: 'This PC',
      hostOfSession: (_) => fail('a local pane has no session'),
    );
    expect(local.hostLabel, 'This PC');
    expect(local.host.key, const EditorHost.thisComputer().key);
    expect(source.identity, isNot(local.identity), reason: "never this computer's file of the same path");

    expect(utf8.decode(await source.read()), 'worker_processes 1;\n');
    await source.write(Uint8List.fromList(utf8.encode('worker_processes 4;\n')));
    expect(utf8.decode(native.files[path]!), 'worker_processes 4;\n', reason: 'written on the server');
    expect(native.requests.any((r) => r['op'] == 'get' || r['op'] == 'put'), isFalse,
        reason: 'in memory, never through a file of this device');
    expect(saved, 1);

    // No Save as root: FTPS has no sudo.
    expect(await source.access(), isNull);
    await expectLater(source.writeAsRoot(Uint8List(0), 'pw'), throwsUnsupportedError);
    expect(source.sibling('/home/demo/other.conf')!.host.key, teamHost.key);
  });

  testWidgets("in the editor: its tab names the host, its draft is the team host's, Save writes to the server",
      (tester) async {
    final drafts = _Drafts();
    // (Made in the test's own zone: the client's calls go on in the zone it was made in.)
    final (native, files) = await ftps();
    native.files[path] = utf8.encode('worker_processes 1;\n');
    final source = ofPane(files);
    await openEditorPage(tester, [source], overrides: [editorDraftStoreProvider.overrideWithValue(drafts)]);
    await openFile(tester, source);
    expect(editorCode(tester).text, 'worker_processes 1;\n');
    expect(find.text('files-01'), findsWidgets);
    expect(find.text('This PC'), findsNothing);

    editorCode(tester).text = 'worker_processes 2;\n';
    await tester.pump(const Duration(seconds: 3));
    expect(drafts.kept.keys.single, ('team-1', source.identity));

    expect(find.text(en.editorSaveAsRoot), findsNothing);
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(utf8.decode(native.files[path]!), 'worker_processes 2;\n');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a delete on an FTPS pane names the host and its path, never this computer', (tester) async {
    SharedPreferences.setMockInitialValues({'sftp_delete_hold_seconds': 0});
    final prefs = await SharedPreferences.getInstance();
    final (native, files) = await ftps();
    native.files['/home/demo/notes.txt'] = utf8.encode('hello\n');
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SftpPane(
            source: files,
            sourceDescriptor: FtpsPaneSource(sessionId: 'session-1', hostLabel: 'files-01', files: files),
            paneSide: 0,
            onInterPaneDrop: (_, _) {},
          ),
        ),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('notes.txt'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(find.text(en.sftpDeleteConfirmRemoteNoHold('files-01 /home/demo/notes.txt')), findsOneWidget);
    await tester.tap(find.text(en.cancel).last);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 15));
  });
}
