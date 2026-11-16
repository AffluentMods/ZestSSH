import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SSHClient;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';
import 'package:zestssh/ui/screens/desktop/widgets/sftp_dock.dart';
import 'package:zestssh/ui/screens/sftp/sftp_dual_pane_screen.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_locations_rail.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';

import '../helpers/played_sftp_host.dart';
import '../visual/shots_util.dart' show loadShotFonts;

/// The SFTP panel docked beside a session (4.0),
/// on the real terminal area,
/// with web-01's files on an SFTP server the test plays.
///
/// Connected, the panel is web-01's files in one pane: Up, Refresh, the path,
/// Upload, New folder and More on one row, with no rail and no pane of this
/// computer beside it (More turns two panes on again). Its Upload takes files
/// picked in the system's dialog, and its Download puts the selection in a
/// folder picked there.
///
/// Its session's connection dropped, the panel says that web-01 is
/// disconnected and why it has no files (it shares the tab's connection,
/// which dropped, and when), with Reconnect, Open SFTP on its own and Copy
/// details. It went on showing what it had listed, of a host nothing could
/// be asked of any more, with the host's name gone from its header; opened
/// again, it said "SFTP requires an active SSH connection" beside an icon,
/// with nothing to do, as for a session with no SSH at all.

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void set(Map<String, SessionState> s) => state = s;

  /// The sessions Reconnect was asked of.
  final reconnected = <String>[];

  @override
  void reconnectNow(String sessionId) => reconnected.add(sessionId);

  @override
  Future<bool> hostAllows(String? connectionId, String what) async => true;
}

/// As [_Sessions], knowing when a connection dropped and opening a session
/// of a host's files where asked.
class _DropSessions extends _Sessions {
  _DropSessions(super.ref);

  DateTime? dropTime;

  @override
  DateTime? droppedAt(String sessionId) => dropTime;

  /// The session "Open SFTP on its own" opens, and the sessions it was
  /// asked for.
  SessionState? filesSession;
  final filesAskedFor = <String>[];

  @override
  Future<String?> openFilesLike(String sessionId) async {
    filesAskedFor.add(sessionId);
    final files = filesSession;
    if (files == null) return null;
    state = {...state, 'files-1': files};
    return 'files-1';
  }
}

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

/// An SSH session's shell whose connection is an SFTP server the test plays.
class _PlayedSsh extends _Shell implements SshService {
  _PlayedSsh(this.client);

  @override
  final SSHClient client;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Health extends ConnectionHealthNotifier {}

/// A file picker that hands back what the test gives, and notes what it was
/// asked.
class _Picker extends FilePicker {
  _Picker({this.files = const [], this.folder});

  final List<String> files;
  final String? folder;
  final asked = <String>[];

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    asked.add('files: $dialogTitle, many: $allowMultiple');
    return FilePickerResult([
      for (final f in files) PlatformFile(path: f, name: f.split(Platform.pathSeparator).last, size: 0),
    ]);
  }

  @override
  Future<String?> getDirectoryPath(
      {String? dialogTitle, bool lockParentWindow = false, String? initialDirectory}) async {
    asked.add('folder: $dialogTitle');
    return folder;
  }
}

/// deploy's home folder on web-01, made up.
PlayedSftpHost _deployHome() {
  final host = PlayedSftpHost()..home = '/home/deploy';
  host.folders.add('/home/deploy/logs');
  host.files['/home/deploy/deploy.sh'] = PlayedFile(utf8.encode('#!/bin/sh\necho deployed\n'));
  host.files['/home/deploy/notes.md'] = PlayedFile(utf8.encode('# web-01\n'));
  return host;
}

SessionState _connected(SSHClient client, {String id = 's1', String label = 'web-01'}) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-web',
      connectionLabel: label,
      host: '10.0.0.5',
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: 'c-web',
        terminal: Terminal(),
        shell: _PlayedSsh(client),
        startedAt: DateTime(2026, 11, 12, 8),
      ),
    );

SessionState _dropped({bool reconnecting = false, int attempt = 0, SessionStatus? status}) => SessionState(
      status: status ?? SessionStatus.disconnected,
      connectionId: 'c-web',
      connectionLabel: 'web-01',
      host: '10.0.0.5',
      port: 22,
      dropped: true,
      dropCause: hostClosedConnection,
      connectionLog: const ['connect: Initiating connection...', 'dropped: Connection closed by the host'],
      isReconnecting: reconnecting,
      reconnectAttempt: attempt,
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  // The app's fonts: its menus are as wide as the app draws them.
  setUpAll(() async => loadShotFonts());

  /// Lets the played host answer, the database too (it does in real time),
  /// and the panel draw what they said.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// A database of no hosts, closed after the test (outside its fake clock).
  AppDatabase database(WidgetTester tester) {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    return db;
  }

  /// The terminal area with web-01's session and its SFTP dock on the right
  /// (the side the mockup draws).
  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required SSHClient client,
    bool drops = false,
    Map<String, Object> prefs = const {},
    ValueChanged<String>? onShowSession,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(p),
      databaseProvider.overrideWithValue(database(tester)),
      activeSessionsProvider.overrideWith(drops ? _DropSessions.new : _Sessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(c.dispose);
    final tabs = c.read(workTabsProvider.notifier);
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({'s1': _connected(client)});
    tabs.setActiveTab(tabs.tabContaining('s1')!.id);
    c.read(v3ActiveSessionTabProvider.notifier).state = 's1';
    final tree = c.read(paneTreeProvider.notifier)..initSinglePane('s1');
    tree.splitPaneWithSftp(c.read(paneTreeProvider)!.allLeaves.first.id, Axis.horizontal, 's1');
    c.read(sftpDockPrefsProvider.notifier).setSide(SftpDockSide.right);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: BuiltInThemes.getById('default_dark').toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: DesktopTerminalArea(
            onConnectTo: (_) {},
            onToggleSftp: (_) {},
            onApplyLayout: (_) {},
            onShowSession: onShowSession,
          ),
        ),
      ),
    ));
    await settle(tester);
    return c;
  }

  _Sessions sessions(ProviderContainer c) => c.read(activeSessionsProvider.notifier) as _Sessions;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  /// What a screen reader is told of the dock's host pill.
  String pillSaid(WidgetTester tester) =>
      tester.getSemantics(find.byKey(const ValueKey('sftp-dock-host'))).label;

  group('connected', () {
    testWidgets("the panel is the host's files in one pane: Up, Refresh, the path, Upload, New folder and More on "
        'one row, with no rail and no pane of this computer', (tester) async {
      final semantics = tester.ensureSemantics();
      final host = _deployHome();
      await pump(tester, client: host.client);

      expect(find.text('deploy.sh'), findsOneWidget);
      expect(find.text('notes.md'), findsOneWidget);
      expect(find.text('logs'), findsOneWidget);
      expect(find.byType(SftpPane), findsOneWidget, reason: 'one pane: the host');
      expect(find.byType(SftpLocationsRail), findsNothing, reason: 'no rail of places');
      expect(tester.state<SftpPaneState>(find.byType(SftpPane)).currentPath, '/home/deploy');
      final row = find.byKey(const ValueKey('sftp-toolbar'));
      for (final key in ['sftp-toolbar-up', 'sftp-toolbar-refresh', 'sftp-toolbar-upload', 'sftp-toolbar-new-folder',
          'sftp-toolbar-menu']) {
        expect(find.descendant(of: row, matching: find.byKey(ValueKey(key))), findsOneWidget, reason: key);
      }
      // Upload and New folder with their words, the path between Refresh and them, all on one row.
      expect(find.descendant(of: row, matching: find.text(en.sftpUpload)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text(en.sftpNewFolderAction)), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('deploy')), findsOneWidget);
      final y = tester.getCenter(find.byKey(const ValueKey('sftp-toolbar-up'))).dy;
      expect(tester.getCenter(find.byKey(const ValueKey('sftp-toolbar-upload'))).dy, moreOrLessEquals(y, epsilon: 1));
      expect(tester.getCenter(find.descendant(of: row, matching: find.text('deploy'))).dy,
          moreOrLessEquals(y, epsilon: 2));
      // The host's state in words, not by its dot alone.
      expect(pillSaid(tester), 'web-01, ${en.sessionInfoStatusConnected}');
      // Back, Forward and Download are in More.
      await tester.tap(find.byKey(const ValueKey('sftp-toolbar-menu')));
      await tester.pumpAndSettle();
      expect(find.text(en.sftpBack), findsOneWidget);
      expect(find.text(en.sftpForward), findsOneWidget);
      expect(find.text(en.sftpDownload), findsOneWidget);
      expect(find.text(en.sftpDockTwoPanes), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      semantics.dispose();
      await finish(tester);
    });

    testWidgets("More's Two panes side by side shows this computer and the rail again, and the dock keeps it; "
        'from the two, one again', (tester) async {
      final host = _deployHome();
      final c = await pump(tester, client: host.client);

      await tester.tap(find.byKey(const ValueKey('sftp-toolbar-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.sftpDockTwoPanes));
      await settle(tester);
      expect(find.byType(SftpPane), findsNWidgets(2));
      expect(find.byType(SftpLocationsRail), findsOneWidget);
      expect(find.text('deploy.sh'), findsOneWidget, reason: "the host's pane is as it was");
      expect(c.read(sftpDockPrefsProvider).twoPanes, isTrue);
      expect(c.read(sharedPreferencesProvider).getBool('sftp_dock_two_panes'), isTrue, reason: 'kept on this device');

      // The host's pane (the right one) turns them off again.
      await tester.tap(find.byKey(const ValueKey('sftp-toolbar-menu')).last);
      await tester.pumpAndSettle();
      final item = find.byKey(const ValueKey('sftp-menu-two-panes'));
      expect(tester.widget<CheckedPopupMenuItem<void Function()>>(item).checked, isTrue);
      await tester.tap(item);
      await settle(tester);
      expect(find.byType(SftpPane), findsOneWidget);
      expect(find.byType(SftpLocationsRail), findsNothing);
      expect(c.read(sharedPreferencesProvider).getBool('sftp_dock_two_panes'), isFalse);
      await finish(tester);
    });

    // The Name column kept the width of the pane's first layout: moved from
    // the bottom to the right, the list pushed Size and Modified out of sight.
    testWidgets('moved from the bottom to the right, the list keeps Size and Modified in sight', (tester) async {
      final host = _deployHome();
      final c = await pump(tester, client: host.client);
      c.read(sftpDockPrefsProvider.notifier).setSide(SftpDockSide.bottom);
      await settle(tester);
      c.read(sftpDockPrefsProvider.notifier).setSide(SftpDockSide.right);
      await settle(tester);
      final pane = tester.getRect(find.byType(SftpPane));
      expect(tester.getRect(find.text(en.sftpColumnModified)).right, lessThanOrEqualTo(pane.right));
      expect(tester.getRect(find.text(en.sftpColumnSize)).left, greaterThan(pane.left));
      await finish(tester);
    });

    testWidgets('a dock set to two panes opens with them', (tester) async {
      final host = _deployHome();
      await pump(tester, client: host.client, prefs: {'sftp_dock_two_panes': true});
      expect(find.byType(SftpPane), findsNWidgets(2));
      expect(find.byType(SftpLocationsRail), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Upload sends files picked on this computer into the folder shown', (tester) async {
      final temp = await tester.runAsync(() => Directory.systemTemp.createTemp('zest-dock-upload'));
      addTearDown(() => tester.runAsync(() => temp!.delete(recursive: true)));
      final local = File('${temp!.path}${Platform.pathSeparator}release-notes.txt');
      await tester.runAsync(() => local.writeAsString('3.4.1: faster checkout\n'));
      final picker = _Picker(files: [local.path]);
      FilePicker.platform = picker;
      final host = _deployHome();
      await pump(tester, client: host.client);

      await tester.tap(find.byKey(const ValueKey('sftp-toolbar-upload')));
      String uploaded() => utf8.decode(host.files['/home/deploy/release-notes.txt']?.bytes ?? []);
      for (var i = 0; i < 80 && uploaded() != '3.4.1: faster checkout\n'; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(picker.asked, ['files: ${en.sftpUpload}, many: true']);
      expect(uploaded(), '3.4.1: faster checkout\n');
      await settle(tester);
      expect(find.text('release-notes.txt'), findsWidgets, reason: 'listed in the folder, and in Activity');
      await finish(tester);
    });

    testWidgets('Download, in More, puts the selection in a folder picked on this computer', (tester) async {
      final temp = await tester.runAsync(() => Directory.systemTemp.createTemp('zest-dock-download'));
      addTearDown(() => tester.runAsync(() => temp!.delete(recursive: true)));
      final picker = _Picker(folder: temp!.path);
      FilePicker.platform = picker;
      final host = _deployHome();
      await pump(tester, client: host.client);

      await tester.tap(find.text('deploy.sh'));
      // (A click selects once it is no double click.)
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const ValueKey('sftp-toolbar-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sftp-menu-transfer')));
      final saved = File('${temp.path}${Platform.pathSeparator}deploy.sh');
      for (var i = 0; i < 60 && !(await tester.runAsync(saved.exists))!; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      String? text;
      for (var i = 0; i < 40 && text != '#!/bin/sh\necho deployed\n'; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 50));
        text = await tester.runAsync<String?>(() async => await saved.exists() ? await saved.readAsString() : null);
      }
      expect(picker.asked, ['folder: ${en.sftpDownload}']);
      expect(text, '#!/bin/sh\necho deployed\n');
      await finish(tester);
    });
  });

  group('its connection dropped', () {
    // Before 4.0 this failed: the dock went on showing what it had listed,
    // and nothing said that web-01 was disconnected.
    testWidgets('the panel says the host is disconnected and why, with Reconnect, and Copy details copies the '
        "report of the drop without the host's address", (tester) async {
      final host = _deployHome();
      final c = await pump(tester, client: host.client);
      expect(find.text('deploy.sh'), findsOneWidget);

      sessions(c).set({'s1': _dropped()});
      await settle(tester);
      expect(find.text('web-01 is disconnected'), findsOneWidget);
      expect(find.text("This panel shares the tab's SSH connection, which dropped."), findsOneWidget);
      expect(find.text('deploy.sh').hitTestable(), findsNothing, reason: 'nothing listed of a host that is gone');
      expect(find.text('SFTP requires an active SSH connection'), findsNothing);

      final reconnect = find.byKey(const ValueKey('sftp-dock-reconnect'));
      expect(find.descendant(of: reconnect, matching: find.text('Reconnect')), findsOneWidget);
      await tester.tap(reconnect);
      await tester.pump();
      expect(sessions(c).reconnected, ['s1']);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.tap(find.byKey(const ValueKey('sftp-dock-copy-details')));
      await tester.pump();
      expect(copied, contains('ZestSSH error details'));
      expect(copied, contains('Kind: closedByHost'));
      expect(copied, isNot(contains('10.0.0.5')));
      await finish(tester);
    });

    testWidgets('it says when it dropped, in words as well as by its dot, and Open SFTP on its own opens the '
        "host's files in a tab of their own", (tester) async {
      final semantics = tester.ensureSemantics();
      final host = _deployHome();
      final shown = <String>[];
      final c = await pump(tester, client: host.client, drops: true, onShowSession: shown.add);
      final live = c.read(activeSessionsProvider.notifier) as _DropSessions;
      live.dropTime = DateTime.now().copyWith(hour: 9, minute: 41);
      live.set({'s1': _dropped()});
      await settle(tester);
      expect(find.text("This panel shares the tab's SSH connection, which dropped at 09:41."), findsOneWidget);
      expect(pillSaid(tester), 'web-01, ${en.sessionInfoStatusDisconnected}');

      // Where none could be opened (the host is not saved any more), it says so.
      await tester.tap(find.byKey(const ValueKey('sftp-dock-open-own')));
      await settle(tester);
      expect(live.filesAskedFor, ['s1']);
      // (Said as a computer says it: in the notification center.)
      expect(c.read(notificationCenterProvider).history.first.title, en.sftpDockHostGone('web-01'));
      expect(shown, isEmpty);
      await tester.pump(const Duration(seconds: 6));

      // A session of the host's files, of their own: its tab is brought to the front.
      live.filesSession = _connected(_deployHome().client, id: 'files-1');
      await tester.tap(find.byKey(const ValueKey('sftp-dock-open-own')));
      await settle(tester);
      expect(live.filesAskedFor, ['s1', 's1']);
      expect(shown, ['files-1']);
      semantics.dispose();
      await finish(tester);
    });

    testWidgets('while a try of connecting again runs, it says which, and Reconnect waits for it', (tester) async {
      final host = _deployHome();
      final c = await pump(tester, client: host.client);
      sessions(c).set({'s1': _dropped(reconnecting: true, attempt: 2, status: SessionStatus.connecting)});
      await settle(tester);
      expect(find.text('web-01 is disconnected'), findsOneWidget);
      final dock = find.byType(SftpDockDisconnected);
      expect(find.descendant(of: dock, matching: find.text(en.sessionHeaderReconnecting(2, 10))), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('sftp-dock-reconnect'))).onPressed, isNull);

      // Between tries, Reconnect tries at once.
      sessions(c).set({'s1': _dropped(reconnecting: true, attempt: 3)});
      await settle(tester);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('sftp-dock-reconnect'))).onPressed, isNotNull);
      await finish(tester);
    });

    testWidgets('a Quick connect is not saved: nothing to open on its own', (tester) async {
      final host = _deployHome();
      final c = await pump(tester, client: host.client);
      sessions(c).set({
        's1': SessionState.disconnected(
            connectionId: 'quick_1', connectionLabel: '10.0.0.5', host: '10.0.0.5', port: 22, dropped: true),
      });
      await settle(tester);
      expect(find.byKey(const ValueKey('sftp-dock-open-own')), findsNothing);
      expect(find.byKey(const ValueKey('sftp-dock-reconnect')), findsOneWidget);
      expect(find.byKey(const ValueKey('sftp-dock-copy-details')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('connected again, the files are back where they were, in the same browser', (tester) async {
      final host = _deployHome();
      final c = await pump(tester, client: host.client);
      final browser = tester.state(find.byType(SftpDualPaneScreen));
      final pane = tester.state<SftpPaneState>(find.byType(SftpPane));
      unawaited(pane.navigateTo('/home/deploy/logs'));
      await settle(tester);

      sessions(c).set({'s1': _dropped()});
      await settle(tester);
      expect(find.text('web-01 is disconnected'), findsOneWidget);

      // On a connection of its own, as a session connected again is.
      sessions(c).set({'s1': _connected(host.connect().client)});
      await settle(tester);
      expect(find.text('web-01 is disconnected'), findsNothing);
      expect(identical(tester.state(find.byType(SftpDualPaneScreen)), browser), isTrue, reason: 'the same browser');
      expect(tester.state<SftpPaneState>(find.byType(SftpPane)).currentPath, '/home/deploy/logs');
      expect(find.byKey(const ValueKey('sftp-toolbar-upload')).hitTestable(), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a dock opened while its session is dropped says so at once, and lists its files once it is back',
        (tester) async {
      final host = _deployHome();
      SharedPreferences.setMockInitialValues({});
      final p = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(p),
        databaseProvider.overrideWithValue(database(tester)),
        activeSessionsProvider.overrideWith(_Sessions.new),
        connectionHealthProvider.overrideWith((ref) => _Health()),
      ]);
      addTearDown(c.dispose);
      final tabs = c.read(workTabsProvider.notifier);
      sessions(c).set({'s1': _dropped()});
      tabs.setActiveTab(tabs.tabContaining('s1')!.id);
      c.read(v3ActiveSessionTabProvider.notifier).state = 's1';
      final tree = c.read(paneTreeProvider.notifier)..initSinglePane('s1');
      tree.splitPaneWithSftp(c.read(paneTreeProvider)!.allLeaves.first.id, Axis.horizontal, 's1');
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: DesktopTerminalArea(onConnectTo: (_) {}, onToggleSftp: (_) {}, onApplyLayout: (_) {}),
          ),
        ),
      ));
      await settle(tester);
      expect(find.text('web-01 is disconnected'), findsOneWidget);
      expect(find.text('SFTP requires an active SSH connection'), findsNothing);

      sessions(c).set({'s1': _connected(host.client)});
      await settle(tester);
      expect(find.text('deploy.sh'), findsOneWidget);
      await finish(tester);
    });
  });
}
