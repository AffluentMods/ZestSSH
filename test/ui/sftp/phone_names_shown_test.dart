// A security review found that
// the phone's file browser drew a server's file names as sent. A
// name with a direction override inside read as another kind of file: the
// letters after U+202E are drawn right to left, so "photo" + U+202E +
// "gnp.exe" reads as a .png. The computer's pane has shown such names with
// every character visible; the phone's list, its row sheet and what it says
// of a file did not.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SftpFileAttrs;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';

class _Sftp implements SftpService {
  final List<SftpEntry> entries = [];

  @override
  Future<String> getHomeDirectory() async => '/home/demo';

  @override
  Future<List<SftpEntry>> listDirectory(String path) async => entries;

  @override
  Future<SftpFileAttrs?> statOrNull(String path) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  final override = String.fromCharCode(0x202E);
  final zeroWidth = String.fromCharCode(0x200B);
  final disguised = 'photo${override}gnp.exe';
  final hidden = 're${zeroWidth}port.txt';
  // A backslash, written by its number: the shown form is a backslash, u and four digits.
  final bs = String.fromCharCode(0x5c);

  /// Every text on the screen, the parts of a rich text included.
  List<String> shown(WidgetTester tester) => [
        for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? '',
        for (final t in tester.widgetList<RichText>(find.byType(RichText))) t.text.toPlainText(),
      ];

  Future<void> open(WidgetTester tester, _Sftp sftp) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: SftpBrowserScreen(sftp: sftp, connectionLabel: 'web-01'),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the list draws a name with every character showing: no direction override, no zero-width space',
      (tester) async {
    final sftp = _Sftp()
      ..entries.addAll([
        SftpEntry(name: disguised, path: '/home/demo/$disguised', isDirectory: false, size: 3),
        SftpEntry(name: hidden, path: '/home/demo/$hidden', isDirectory: false, size: 3),
        const SftpEntry(name: 'notes.txt', path: '/home/demo/notes.txt', isDirectory: false, size: 3),
      ]);
    await open(tester, sftp);

    final texts = shown(tester);
    expect(texts.where((t) => t.contains(override) || t.contains(zeroWidth)), isEmpty);
    expect(find.text('photo${bs}u202egnp.exe'), findsOneWidget, reason: 'the override is written out, so the name reads as it is');
    expect(find.text('re${bs}u200bport.txt'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget, reason: 'a plain name is drawn as before');
  });

  testWidgets('the sheet of a file names it the same way', (tester) async {
    final sftp = _Sftp()
      ..entries.add(SftpEntry(name: disguised, path: '/home/demo/$disguised', isDirectory: false, size: 3));
    await open(tester, sftp);

    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    final texts = shown(tester);
    expect(texts.where((t) => t.contains(override)), isEmpty);
    expect(find.text('photo${bs}u202egnp.exe'), findsWidgets);
  });
}
