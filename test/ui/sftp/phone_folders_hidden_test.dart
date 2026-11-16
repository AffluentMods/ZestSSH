import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';

/// A phone's SFTP browser (3.0, found while comparing the
/// five versions): a folder's tap opens it, and its actions (copy its path,
/// rename it, its properties, delete it) were in a sheet only a file's tap
/// opened, out of reach; and hidden files followed a switch of the screen's
/// own, off on every visit, which hid dotfiles and Windows system names
/// whatever Settings > SFTP said (its default shows dotfiles, as a computer
/// does).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> open(WidgetTester tester, _Sftp sftp) async {
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
    return ProviderScope.containerOf(tester.element(find.byType(SftpBrowserScreen)));
  }

  /// The More of the row named [name].
  Finder moreOf(String name) => find.descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
        matching: find.byTooltip(en.zestCommonMoreActions),
      );

  testWidgets("a folder's More opens its actions; its tap opens it, as before", (tester) async {
    final sftp = _Sftp()
      ..entries.addAll([_entry('logs', folder: true), _entry('notes.txt')]);
    await open(tester, sftp);
    await tester.tap(moreOf('logs'));
    await tester.pumpAndSettle();
    for (final action in [en.sftpCopyPath, en.sftpRename, en.sftpProperties, en.delete]) {
      expect(find.text(action), findsOneWidget, reason: action);
    }
    expect(find.text(en.sftpEditInEditor), findsNothing, reason: 'a folder is not opened in the editor');
    await tester.tap(find.text(en.sftpProperties));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(ZestDialogShell), matching: find.text(en.sftpPropertyDirectory)), findsOneWidget);
    await tester.tap(find.text(en.close));
    await tester.pumpAndSettle();

    // A file's More opens its own sheet, as its tap does.
    await tester.tap(moreOf('notes.txt'));
    await tester.pumpAndSettle();
    expect(find.text(en.sftpEditInEditor), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.text('logs'));
    await tester.pumpAndSettle();
    expect(sftp.listed.last, '/home/demo/logs');
  });

  testWidgets('hidden files as the setting has them, and its switch in the menu changes the setting, which the '
      'next visit keeps', (tester) async {
    final names = ['.bashrc', 'NTUSER.DAT', 'notes.txt'];
    _Sftp sftp() => _Sftp()..entries.addAll([for (final n in names) _entry(n)]);
    List<String> shown() => [for (final n in names) if (find.text(n).evaluate().isNotEmpty) n];

    // The default: dotfiles shown, Windows system names hidden.
    var container = await open(tester, sftp());
    expect(shown(), ['.bashrc', 'notes.txt']);

    // The menu's switch hides dotfiles, in the setting itself.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.sftpHideHiddenFiles));
    await tester.pumpAndSettle();
    expect(container.read(sftpHiddenLevelProvider), SftpHiddenLevel.hiddenAndSystem);
    expect(shown(), ['notes.txt']);

    // Another visit keeps it.
    await tester.pumpWidget(const SizedBox());
    container = await open(tester, sftp());
    expect(shown(), ['notes.txt']);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.sftpShowHiddenFiles));
    await tester.pumpAndSettle();
    expect(container.read(sftpHiddenLevelProvider), SftpHiddenLevel.systemOnly);
    expect(shown(), ['.bashrc', 'notes.txt']);

    // Settings' Hide nothing: everything.
    container.read(sftpHiddenLevelProvider.notifier).setLevel(SftpHiddenLevel.none);
    await tester.pumpAndSettle();
    expect(shown(), names);
  });
}

SftpEntry _entry(String name, {bool folder = false}) =>
    SftpEntry(name: name, path: '/home/demo/$name', isDirectory: folder, size: folder ? 0 : 5);

class _Sftp implements SftpService {
  final List<SftpEntry> entries = [];
  final List<String> listed = [];

  @override
  Future<String> getHomeDirectory() async => '/home/demo';

  @override
  Future<List<SftpEntry>> listDirectory(String path) async {
    listed.add(path);
    return path == '/home/demo' ? entries : const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
