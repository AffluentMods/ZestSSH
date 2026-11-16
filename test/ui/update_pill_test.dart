import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/notifications/notification_center.dart' show notificationCenterProvider;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/services/app_updater.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/services/update_manifest.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';
import 'package:zestssh/ui/widgets/update_pill.dart';

/// The title bar's "Update available" and the dialog it opens (3.0):
/// it shows only with a newer release on a
/// computer's build from the website; Update and restart asks first, as
/// quitting does, only where sessions are open; then downloads, gets ready
/// and quits through the shell with the installer started first.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;

  final update = UpdateInfo(
    version: '3.0.1',
    downloadUrl: 'https://zestssh.com/download',
    notes: 'Faster SFTP and a fix for the tab strip.',
    package: UpdatePackage(url: Uri.parse('https://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe'), sha256: 'a' * 64, size: 10),
  );

  // A release out after the dialog's.
  final newer = UpdateInfo(
    version: '3.0.2',
    downloadUrl: 'https://zestssh.com/download',
    package: UpdatePackage(url: Uri.parse('https://zestssh.com/downloads/ZestSSH-3.0.2-Setup.exe'), sha256: 'b' * 64, size: 10),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    UpdateRestart.endApp = null;
  });
  tearDown(() => UpdateRestart.endApp = null);

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    bool supported = true,
    UpdateInfo? available,
    int sessions = 0,
    AppUpdater? updater,
    _Latest? latest,
    Widget child = const UpdateAvailablePill(),
  }) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appVersionProvider.overrideWith((ref) async => '3.0.0'),
        appBuildNumberProvider.overrideWith((ref) async => 279),
        inAppUpdateSupportedProvider.overrideWithValue(supported),
        updateOpenSessionCountProvider.overrideWithValue(sessions),
        appUpdaterProvider.overrideWithValue(updater ?? _FakeUpdater()),
        updateCheckServiceProvider.overrideWithValue(latest ?? _Latest()),
        syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Align(alignment: Alignment.topCenter, child: child)),
      ),
    ));
    final c = ProviderScope.containerOf(tester.element(find.byType(child.runtimeType)));
    if (available != null) c.read(availableUpdateProvider.notifier).set(available);
    await tester.pump();
    return c;
  }

  /// Frames enough for the update to run its course (the restarting step's
  /// spinner never settles: the app is meant to be gone by then).
  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('update-pill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('update-dialog')), findsOneWidget);
  }

  group('the pill', () {
    testWidgets('shows only while a newer release is known', (tester) async {
      final c = await pump(tester);
      expect(find.byKey(const ValueKey('update-pill')), findsNothing);
      c.read(availableUpdateProvider.notifier).set(update);
      await tester.pump();
      expect(find.text(en.appUpdatePill), findsOneWidget);
      c.read(availableUpdateProvider.notifier).set(null);
      await tester.pump();
      expect(find.byKey(const ValueKey('update-pill')), findsNothing);
    });

    testWidgets('never on a store\'s build or a phone, even with a newer release known', (tester) async {
      await pump(tester, supported: false, available: update);
      expect(find.byKey(const ValueKey('update-pill')), findsNothing);
      // What decides it: a store's build offers nothing (the store updates it).
      expect(UpdateCheckService.manualCheckSupportedIn(storeBuild: true), isFalse);
    });

    testWidgets('sits in the title bar, beside Search and the bell', (tester) async {
      await pump(
        tester,
        available: update,
        child: PillBar(
          activeNav: NavSection.hosts,
          sessions: const [],
          onNavChanged: (_) {},
          onSessionSelected: (_) {},
          onSessionClosed: (_) {},
          onNewSession: () {},
          onCommandPalette: () {},
          onHelp: () {},
        ),
      );
      final pill = find.byKey(const ValueKey('update-pill'));
      expect(pill, findsOneWidget);
      final search = find.text(en.commonSearch);
      expect(tester.getCenter(pill).dx, lessThan(tester.getCenter(search).dx), reason: 'just before Search');
      expect(tester.getCenter(pill).dx, greaterThan(800), reason: 'at the right of the bar');
    });

    testWidgets('opens the dialog: the version, its notes, Update and restart, and Later', (tester) async {
      await pump(tester, available: update);
      await openDialog(tester);
      expect(find.text(en.updateBannerVersionAvailable('3.0.1')), findsOneWidget);
      expect(find.text(en.appUpdateYouHave('3.0.0')), findsOneWidget);
      expect(find.text(update.notes!), findsOneWidget);
      expect(find.text(en.appUpdateNow), findsOneWidget);
      await tester.tap(find.text(en.appUpdateLater));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-dialog')), findsNothing);
    });
  });

  group('Update and restart', () {
    testWidgets('with sessions open, asks first as quitting does, naming how many; no means nothing happens',
        (tester) async {
      final updater = _FakeUpdater();
      await pump(tester, available: update, sessions: 2, updater: updater);
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('update-dialog-primary')));
      await tester.pumpAndSettle();
      expect(find.text(en.appUpdateConfirmTitle), findsOneWidget);
      expect(find.text(en.desktopActiveSessionsWillDisconnect(2)), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect(updater.downloads, 0);
      expect(find.byKey(const ValueKey('update-dialog')), findsOneWidget, reason: 'back to the offer');
    });

    testWidgets('with sessions open and the question answered yes, it goes on', (tester) async {
      final updater = _FakeUpdater();
      final ended = <bool>[];
      UpdateRestart.endApp = (launch) async {
        await launch();
        ended.add(true);
        return true;
      };
      await pump(tester, available: update, sessions: 1, updater: updater);
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('update-dialog-primary')));
      await tester.pumpAndSettle();
      expect(find.text(en.desktopActiveSessionsWillDisconnect(1)), findsOneWidget);
      await tester.tap(find.text(en.appUpdateNow).last);
      await frames(tester);
      expect(updater.downloads, 1);
      expect(updater.launches, 1);
      expect(ended, [true]);
    });

    testWidgets('with no session open: no question; download, ready, the installer started, then the app quits',
        (tester) async {
      final updater = _FakeUpdater();
      final order = <String>[];
      UpdateRestart.endApp = (launch) async {
        order.add('end asked');
        await launch();
        order.add('quit');
        return true;
      };
      updater.onLaunch = () => order.add('installer started');
      await pump(tester, available: update, updater: updater);
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('update-dialog-primary')));
      await frames(tester);
      expect(find.text(en.appUpdateConfirmTitle), findsNothing);
      expect(updater.downloads, 1);
      expect(updater.prepared, 1);
      expect(updater.preparedFrom, ('3.0.0', 279), reason: 'the running version and its build, so builds of one version compare');
      expect(order, ['end asked', 'installer started', 'quit'], reason: 'the installer first, then the quit');
      final pending = jsonDecode(prefs.getString(kUpdatePendingKey)!) as Map;
      expect(pending['version'], '3.0.1');
      expect(pending['from'], '3.0.0');
      expect(find.text(en.appUpdateRestarting), findsOneWidget);
      expect(updater.reopened, isTrue);
    });

    testWidgets('Update and close: the same download and checks, the installer told not to open it again', (tester) async {
      final updater = _FakeUpdater();
      var ended = false;
      UpdateRestart.endApp = (launch) async {
        await launch();
        ended = true;
        return true;
      };
      await pump(tester, available: update, sessions: 1, updater: updater);
      await openDialog(tester);
      expect(find.textContaining(en.appUpdateHowClose), findsOneWidget, reason: 'what each button does is said');
      await tester.tap(find.byKey(const ValueKey('update-dialog-secondary')));
      await tester.pumpAndSettle();
      // Sessions open: asked as Update and close.
      expect(find.text(en.appUpdateConfirmCloseTitle), findsOneWidget);
      await tester.tap(find.text(en.appUpdateAndClose).last);
      await frames(tester);
      expect(updater.downloads, 1);
      expect(updater.reopened, isFalse);
      expect(ended, isTrue);
      expect(find.text(en.appUpdateClosing), findsOneWidget);
    });

    testWidgets('a failure says what in plain words with its code and Copy details, and offers Retry', (tester) async {
      final updater = _FakeUpdater(fail: const UpdateFailure(ErrorCodes.updateFileMismatch, 'SHA-256: expected a, found b.'));
      await pump(tester, available: update, updater: updater);
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('update-dialog-primary')));
      await tester.pumpAndSettle();
      expect(find.text('${en.appUpdateErrMismatch} (ZS-1903)'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-dialog-copy-details')), findsOneWidget);
      expect(find.text(en.retry), findsOneWidget);
      expect(find.text(en.appUpdateDownloadPage), findsOneWidget);
      expect(updater.launches, 0, reason: 'nothing is started after a failure');
      expect(prefs.getString(kUpdatePendingKey), isNull);
    });

    testWidgets('an installer that does not start leaves the app open and says so (ZS-1905)', (tester) async {
      final updater = _FakeUpdater(launchFails: true);
      var quit = false;
      UpdateRestart.endApp = (launch) async {
        await launch();
        quit = true;
        return true;
      };
      await pump(tester, available: update, updater: updater);
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('update-dialog-primary')));
      await tester.pumpAndSettle();
      expect(quit, isFalse);
      expect(find.text('${en.appUpdateErrInstall} (ZS-1905)'), findsOneWidget);
      expect(prefs.getString(kUpdatePendingKey), isNull);
    });

    testWidgets('Windows asks to allow it: the dialog says so with Cancel; a No leaves the app open, says so, offers Retry',
        (tester) async {
      final updater = _FakeUpdater();
      final answer = Completer<void>();
      updater.launchWith = (cancel, onWaiting) async {
        onWaiting?.call();
        await answer.future;
        throw const UpdateFailure.notAllowed('The setup ended with exit code 2 before it opened its log.');
      };
      var quit = false;
      UpdateRestart.endApp = (launch) async {
        await launch();
        quit = true;
        return true;
      };
      await pump(tester, available: update, updater: updater);
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('update-dialog-primary')));
      await frames(tester);
      expect(find.text(en.appUpdateWaitingForWindows), findsOneWidget);
      expect(find.text(en.cancel), findsOneWidget);
      expect(quit, isFalse, reason: 'the app waits, open, while Windows asks');

      answer.complete();
      await tester.pumpAndSettle();
      expect(quit, isFalse);
      expect(find.text('${en.appUpdateErrNotAllowed} (ZS-1905)'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-dialog-copy-details')), findsOneWidget);
      expect(find.text(en.retry), findsOneWidget);
      expect(prefs.getString(kUpdatePendingKey), isNull);
    });

    testWidgets('Cancel while Windows asks: back to the offer, the app open', (tester) async {
      final updater = _FakeUpdater();
      updater.launchWith = (cancel, onWaiting) async {
        onWaiting?.call();
        while (!(cancel?.cancelled ?? false)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        throw const UpdateCancelled();
      };
      var quit = false;
      UpdateRestart.endApp = (launch) async {
        await launch();
        quit = true;
        return true;
      };
      await pump(tester, available: update, updater: updater);
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('update-dialog-primary')));
      await frames(tester);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect(quit, isFalse);
      expect(find.text(en.appUpdateNow), findsOneWidget, reason: 'the offer again');
      expect(prefs.getString(kUpdatePendingKey), isNull);
    });

    // 3.3.1 (it checks for an even newer
    // release first): the dialog installed the release it was opened with, also
    // where a newer one was out by the time Update was clicked.
    testWidgets('reads the signed manifest again first: a release out since the dialog\'s is the one installed',
        (tester) async {
      final updater = _FakeUpdater();
      final latest = _Latest(UpdateAvailable(newer))..hold = Completer<void>();
      UpdateRestart.endApp = (launch) async {
        await launch();
        return true;
      };
      final c = await pump(tester, available: update, updater: updater, latest: latest);
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('update-dialog-primary')));
      await tester.pump();
      expect(find.text(en.updateCheckChecking), findsOneWidget, reason: 'it says it is checking');
      expect(updater.downloads, 0, reason: 'nothing is downloaded before the answer');

      latest.hold!.complete();
      await frames(tester);
      expect(updater.versions, ['3.0.2'], reason: 'the newest release, not the one the dialog was opened with');
      expect(updater.preparedVersions, ['3.0.2']);
      expect((jsonDecode(prefs.getString(kUpdatePendingKey)!) as Map)['version'], '3.0.2');
      expect(find.text(en.updateBannerVersionAvailable('3.0.2')), findsOneWidget, reason: 'the dialog names it');
      expect(c.read(availableUpdateProvider)?.version, '3.0.2');
      await tester.pump(const Duration(seconds: 10)); // the start's own check said it: its notice times out
    });

    testWidgets('nothing newer than this copy any more: it says so, and nothing is downloaded', (tester) async {
      final updater = _FakeUpdater();
      final c = await pump(tester,
          available: update, updater: updater, latest: _Latest(const UpdateCheckUpToDate('3.0.0')));
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('update-dialog-primary')));
      await tester.pumpAndSettle();
      expect(updater.downloads, 0);
      expect(find.byKey(const ValueKey('update-dialog')), findsNothing, reason: 'the dialog has nothing to offer');
      expect(c.read(notificationCenterProvider).history.map((n) => n.title), contains(en.updateCheckUpToDate('3.0.0')));
      expect(c.read(availableUpdateProvider), isNull, reason: 'and the update is offered nowhere');
      await tester.pump(const Duration(seconds: 10)); // the notice times out
    });

    testWidgets('no answer (offline): the release the dialog was opened with is the one installed', (tester) async {
      final updater = _FakeUpdater();
      UpdateRestart.endApp = (launch) async {
        await launch();
        return true;
      };
      await pump(tester, available: update, updater: updater);
      await openDialog(tester);
      await tester.tap(find.byKey(const ValueKey('update-dialog-primary')));
      await frames(tester);
      expect(updater.versions, ['3.0.1']);
      expect((jsonDecode(prefs.getString(kUpdatePendingKey)!) as Map)['version'], '3.0.1');
    });

    testWidgets('a copy that cannot replace itself offers the download page, saying why (ZS-1904)', (tester) async {
      final updater = _FakeUpdater(block: const CannotInstall(InstallBlock.folderNotWritable, place: '/usr/lib/zestssh'));
      await pump(tester, available: update, updater: updater);
      await openDialog(tester);
      expect(find.text('${en.appUpdateErrCannotHere} (ZS-1904)'), findsOneWidget);
      expect(find.text(en.appUpdateDownloadPage), findsOneWidget);
      expect(find.text(en.appUpdateNow), findsNothing);
    });
  });
}

/// What reading the manifest again says: by default no answer (offline), so
/// the release found before is the one installed. [hold] keeps the answer
/// back until the test completes it.
class _Latest extends UpdateCheckService {
  _Latest([this.outcome = const UpdateCheckFailed()]);

  final UpdateCheckOutcome outcome;
  Completer<void>? hold;

  @override
  Future<UpdateCheckOutcome> checkNow() async {
    await hold?.future;
    return outcome;
  }
}

class _FakeUpdater extends AppUpdater {
  _FakeUpdater({this.block, this.fail, this.launchFails = false}) : super(platform: UpdatePlatform.windows);

  final CannotInstall? block;
  final UpdateFailure? fail;
  final bool launchFails;
  int downloads = 0;

  /// The version of each release downloaded, and of each one got ready.
  final versions = <String>[];
  final preparedVersions = <String>[];
  int prepared = 0;
  (String, int?)? preparedFrom;

  /// Whether the last update asked for was to open ZestSSH again.
  bool? reopened;
  int launches = 0;
  void Function()? onLaunch;

  @override
  InstallCheck check(UpdateInfo info) =>
      block ??
      const CanInstall(InstallTarget(platform: UpdatePlatform.windows, executable: r'C:\Z\zestssh.exe', installDir: r'C:\Z'));

  @override
  Future<File> download(UpdateInfo info, {void Function(int received, int total)? onProgress, UpdateCancelToken? cancel}) async {
    downloads++;
    versions.add(info.version);
    onProgress?.call(5, 10);
    if (fail != null) throw fail!;
    onProgress?.call(10, 10);
    return File('ZestSSH-3.0.1-Setup.exe');
  }

  @override
  Future<PreparedUpdate> prepare(UpdateInfo info, File file, InstallTarget target,
      {required String currentVersion, int? currentBuild, bool reopen = true}) async {
    prepared++;
    preparedVersions.add(info.version);
    preparedFrom = (currentVersion, currentBuild);
    reopened = reopen;
    return PreparedUpdate(
        version: info.version,
        executable: file.path,
        arguments: windowsInstallerArgs(logPath: 'setup.log', relaunch: reopen),
        logPath: 'setup.log');
  }

  /// What the launch does before it returns (a stand-in for the Windows
  /// setup waiting for UAC); it may throw.
  Future<void> Function(UpdateCancelToken? cancel, void Function()? onWaiting)? launchWith;

  @override
  Future<void> launch(PreparedUpdate prepared, {UpdateCancelToken? cancel, void Function()? onWaiting}) async {
    if (launchFails) throw const UpdateFailure(ErrorCodes.updateInstallFailed, 'The installer could not be started.');
    if (launchWith != null) await launchWith!(cancel, onWaiting);
    launches++;
    onLaunch?.call();
  }
}
