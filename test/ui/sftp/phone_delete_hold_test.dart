import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sftp_delete_hold_provider.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// A phone's SFTP delete (3.0, found while comparing the five
/// versions): a phone deleted at once, though its Settings > SFTP offered
/// Delete hold and promised Undo; a computer holds a remote delete that long.
/// Now a phone asks as a computer asks, naming the host and the path, and
/// holds the delete where Settings says: its row gone, Undo there, and the
/// delete made once its time is out, the browser is left (before the
/// connection closes) or the app goes to the background.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() {
    L10nGlobal.update(en);
    debugTopSnackBarOnPhone = true;
  });
  tearDown(() => debugTopSnackBarOnPhone = null);

  Future<ProviderContainer> open(WidgetTester tester, _Sftp sftp, {int hold = 0}) async {
    SharedPreferences.setMockInitialValues({'sftp_delete_hold_seconds': hold});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The app's own, which outlives the browser (the holds are kept there).
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: SftpBrowserScreen(sftp: sftp, connectionLabel: 'web-01'),
      ),
    ));
    await tester.pump();
    await tester.pump();
    return container;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// [name]'s Delete, through its More, and the question it asks.
  Future<void> askDelete(WidgetTester tester, String name) async {
    await tester.tap(find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
      matching: find.byTooltip(en.zestCommonMoreActions),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(en.delete).last);
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets('with no hold: asked as a computer asks, the host and the path named, then deleted and said so; a '
      'folder with all in it', (tester) async {
    final sftp = _Sftp();
    await open(tester, sftp);
    await askDelete(tester, 'notes.txt');
    expect(find.text(en.sftpDeleteConfirmRemoteNoHold('web-01 /home/demo/notes.txt')), findsOneWidget);
    await tester.tap(find.text(en.delete).last);
    await settle(tester);
    expect(sftp.events, ['delete /home/demo/notes.txt']);
    expect(find.text(en.sftpDeletedOne('notes.txt')), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);

    await askDelete(tester, 'logs');
    expect(find.text(en.sftpDeleteConfirmRemoteNoHold(en.sftpTargetAndContents('web-01 /home/demo/logs'))),
        findsOneWidget);
    await tester.tap(find.text(en.delete).last);
    await settle(tester);
    expect(sftp.events.last, 'rmdir /home/demo/logs');
    await finish(tester);
  });

  testWidgets('with a hold: its row goes, nothing is deleted yet, and Undo brings it back with nothing deleted',
      (tester) async {
    final sftp = _Sftp();
    await open(tester, sftp, hold: 5);
    await askDelete(tester, 'notes.txt');
    expect(find.text(en.sftpDeleteConfirmRemote('web-01 /home/demo/notes.txt', 5)), findsOneWidget);
    await tester.tap(find.text(en.delete).last);
    await settle(tester);
    expect(find.text('notes.txt'), findsNothing, reason: 'its row goes at once');
    expect(sftp.events, isEmpty, reason: 'it was deleted at once');
    expect(find.text(en.sftpDeleteHolding(5)), findsOneWidget);
    await tester.tap(find.text(en.sftpDeleteUndo));
    await settle(tester);
    expect(find.text('notes.txt'), findsOneWidget, reason: 'back');
    expect(sftp.events, isEmpty);
    await finish(tester);
  });

  testWidgets('with a hold: leaving the browser makes the delete, before the connection closes', (tester) async {
    final sftp = _Sftp();
    final container = await open(tester, sftp, hold: 30);
    await askDelete(tester, 'notes.txt');
    await tester.tap(find.text(en.delete).last);
    await settle(tester);
    expect(sftp.events, isEmpty);
    final holds = container.read(sftpDeleteHoldProvider);
    await tester.pumpWidget(const SizedBox());
    await closePhoneSftp(holds, sftp);
    expect(sftp.events, ['delete /home/demo/notes.txt', 'close']);
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('with a hold: the app going to the background makes the delete', (tester) async {
    final sftp = _Sftp();
    await open(tester, sftp, hold: 30);
    await askDelete(tester, 'notes.txt');
    await tester.tap(find.text(en.delete).last);
    await settle(tester);
    expect(sftp.events, isEmpty);
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await settle(tester);
    expect(sftp.events, ['delete /home/demo/notes.txt']);
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await finish(tester);
  });

  testWidgets('one that fails is said, why, with what was thrown, and its row comes back', (tester) async {
    final sftp = _Sftp()..refuse = true;
    await open(tester, sftp);
    await askDelete(tester, 'notes.txt');
    await tester.tap(find.text(en.delete).last);
    await settle(tester);
    expect(find.textContaining(en.sftpNotDeleted('').trim()), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget, reason: 'listed again');
    await finish(tester);
  });
  test("a phone's terminal closes its SFTP connection through the held deletes", () {
    expect(File('lib/ui/screens/terminal/terminal_screen.dart').readAsStringSync(),
        contains('closePhoneSftp(ref.read(sftpDeleteHoldProvider), sftp)'));
  });
}

SftpEntry _entry(String name, {bool folder = false}) =>
    SftpEntry(name: name, path: '/home/demo/$name', isDirectory: folder, size: folder ? 0 : 5);

class _Sftp implements SftpService {
  final List<String> events = [];
  final Set<String> gone = {};
  bool refuse = false;

  @override
  Future<String> getHomeDirectory() async => '/home/demo';

  @override
  Future<List<SftpEntry>> listDirectory(String path) async => path == '/home/demo'
      ? [for (final e in [_entry('logs', folder: true), _entry('notes.txt')]) if (!gone.contains(e.path)) e]
      : const [];

  @override
  Future<void> deleteFile(String path) async {
    if (refuse) throw Exception('Permission denied');
    events.add('delete $path');
    gone.add(path);
  }

  @override
  Future<void> deleteDirectoryRecursive(String path,
      {int depth = 0, void Function(String deletedPath)? onDeleted, bool Function()? isCancelled}) async {
    events.add('rmdir $path');
    gone.add(path);
    onDeleted?.call(path);
  }

  @override
  Future<void> close() async => events.add('close');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
