import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/notifications/notification_center.dart' show notificationCenterProvider;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/services/app_updater.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/services/update_manifest.dart';
import 'package:zestssh/ui/widgets/update_banner.dart';
import 'package:zestssh/ui/widgets/update_dialog.dart';
import 'package:zestssh/ui/widgets/update_pill.dart';

/// The title bar's "Update available" kept out of the way: "Major update
/// available" for a release whose first number is higher, "Ignore update"
/// in the update's dialog (hidden until this copy is updated), and updates
/// installed by themselves as the app starts (off by default), with no pill
/// for a release that is installed that way. The status bar's version keeps
/// offering the update in every case ([availableUpdateProvider] stays set).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;

  UpdateInfo release(String version, {bool critical = false}) => UpdateInfo(
        version: version,
        downloadUrl: 'https://zestssh.com/download',
        critical: critical,
        package: UpdatePackage(url: Uri.parse('https://zestssh.com/downloads/ZestSSH-$version-Setup.exe'), sha256: 'a' * 64, size: 10),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  test('a major update is one whose first number is higher', () {
    expect(isMajorUpdate('4.2.1', '5.0.0'), isTrue);
    expect(isMajorUpdate('4.2.1', '4.3.0'), isFalse);
    expect(isMajorUpdate('4.2.1', '4.2.2+310'), isFalse);
    expect(isMajorUpdate('4.0.0+300', '10.0.0'), isTrue);
    expect(isMajorUpdate('4.0.0', 'x.1.0'), isFalse, reason: 'a number that cannot be read makes none major');
  });

  group('the start check', () {
    /// The app as it starts, with [out] released and the last check [ago].
    Future<ProviderContainer> start(WidgetTester tester, UpdateInfo out,
        {Duration ago = const Duration(hours: 1), _Updater? updater}) async {
      await prefs.setInt('update_last_check_ms', tester.binding.clock.now().subtract(ago).millisecondsSinceEpoch);
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        updateCheckServiceProvider.overrideWithValue(_Latest(UpdateAvailable(out))),
        updateClockProvider.overrideWithValue(tester.binding.clock.now),
        appUpdaterProvider.overrideWithValue(updater ?? _Updater()),
      ]);
      addTearDown(c.dispose);
      c.listen(updateBannerProvider, (_, _) {});
      await tester.pump();
      return c;
    }

    testWidgets('off (the default): nothing is installed, and the throttle holds as before', (tester) async {
      final c = await start(tester, release('4.0.1'));
      expect(c.read(autoUpdateProvider), isFalse);
      expect(c.read(availableUpdateProvider), isNull, reason: 'checked an hour ago');
      expect(c.read(autoUpdateStartProvider), isNull);
    });

    testWidgets('off, a check that is due: offered as before, not installed', (tester) async {
      final c = await start(tester, release('4.0.1'), ago: const Duration(hours: 7));
      expect(c.read(updateBannerProvider)?.version, '4.0.1');
      expect(c.read(autoUpdateStartProvider), isNull);
      expect(c.read(updateNoticeHiddenProvider), isFalse);
    });

    testWidgets('on: the start checks whatever the throttle says and hands the release to install', (tester) async {
      await prefs.setBool('update_auto_install', true);
      final c = await start(tester, release('4.0.1'));
      expect(c.read(autoUpdateStartProvider)?.version, '4.0.1');
      expect(c.read(availableUpdateProvider)?.version, '4.0.1', reason: 'the status bar still says one is out');
      expect(c.read(updateBannerProvider), isNull, reason: 'no banner for a release being installed');
      expect(c.read(updateNoticeHiddenProvider), isTrue);
    });

    testWidgets('on, while an update started before this start waits to be looked at: not installed now', (tester) async {
      await prefs.setBool('update_auto_install', true);
      await prefs.setString(kUpdatePendingKey, '{"version":"4.0.1","from":"4.0.0"}');
      final c = await start(tester, release('4.0.1'));
      expect(c.read(autoUpdateStartProvider), isNull);
    });

    testWidgets('on, a release whose update did not go in here: offered, not tried again', (tester) async {
      await prefs.setBool('update_auto_install', true);
      await prefs.setString(kUpdatePendingKey, '{"version":"4.0.1","build":301,"from":"4.0.0"}');
      final last = await takeLastUpdate(prefs, '4.0.0', runningBuild: 300);
      expect(last, isA<LastUpdateNotInstalled>());
      final c = await start(tester, UpdateInfo(
        version: '4.0.1',
        build: 301,
        downloadUrl: 'https://zestssh.com/download',
        package: release('4.0.1').package,
      ));
      expect(c.read(autoUpdateStartProvider), isNull);
      expect(c.read(updateNoticeHiddenProvider), isFalse, reason: 'the pill offers it');
      expect(c.read(updateBannerProvider)?.version, '4.0.1');
    });

    testWidgets('on, where this copy cannot install it: offered as before', (tester) async {
      await prefs.setBool('update_auto_install', true);
      final c = await start(tester, release('4.0.1'),
          updater: _Updater(block: const CannotInstall(InstallBlock.notInstalledBySetup)));
      expect(c.read(autoUpdateStartProvider), isNull);
      expect(c.read(updateNoticeHiddenProvider), isFalse);
    });

    testWidgets('on, with the check turned off: nothing is asked', (tester) async {
      await prefs.setBool('update_auto_install', true);
      await prefs.setBool('update_check_enabled', false);
      final c = await start(tester, release('4.0.1'));
      expect(c.read(autoUpdateStartProvider), isNull);
      expect(c.read(availableUpdateProvider), isNull);
    });
  });

  group('the pill and the dialog', () {
    Future<ProviderContainer> pump(WidgetTester tester,
        {String running = '4.0.0', _Updater? updater, Widget? child}) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appVersionProvider.overrideWith((ref) async => running),
          appBuildNumberProvider.overrideWith((ref) async => 300),
          inAppUpdateSupportedProvider.overrideWithValue(true),
          updateOpenSessionCountProvider.overrideWithValue(0),
          appUpdaterProvider.overrideWithValue(updater ?? _Updater()),
          updateCheckServiceProvider.overrideWithValue(_Latest(const UpdateCheckFailed())),
          syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Column(children: [
              const Align(alignment: Alignment.topCenter, child: UpdateAvailablePill()),
              const UpdateBanner(),
              if (child != null) child,
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(tester.element(find.byType(UpdateAvailablePill)));
    }

    Finder pill() => find.byKey(const ValueKey('update-pill'));

    testWidgets('says "Major update available" where the first number goes up, else "Update available"',
        (tester) async {
      final c = await pump(tester);
      c.read(availableUpdateProvider.notifier).set(release('5.0.0'));
      // (The version this copy runs is read once something shows a release.)
      await tester.pumpAndSettle();
      expect(find.text(en.appUpdatePillMajor), findsOneWidget);
      c.read(availableUpdateProvider.notifier).set(release('4.1.0'));
      await tester.pump();
      expect(find.text(en.appUpdatePillMajor), findsNothing);
      expect(find.text(en.appUpdatePill), findsOneWidget);
    });

    testWidgets('Ignore update hides the pill and the banner until this copy is updated', (tester) async {
      final c = await pump(tester);
      c.read(availableUpdateProvider.notifier).set(release('4.0.1'));
      await tester.pump();
      await tester.tap(pill());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-dialog-automatic')), findsOneWidget, reason: 'the switch is there too');
      await tester.tap(find.byKey(const ValueKey('update-dialog-ignore')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-dialog')), findsNothing);
      expect(c.read(notificationCenterProvider).history.map((n) => n.title), contains(en.appUpdateIgnored));
      expect(pill(), findsNothing);
      expect(prefs.getString('update_pill_hidden_on'), '4.0.0+300');
      expect(c.read(availableUpdateProvider)?.version, '4.0.1', reason: 'the status bar still offers it');

      // A newer release while this copy is the same: still hidden.
      c.read(availableUpdateProvider.notifier).set(release('4.0.2'));
      await tester.pump();
      expect(pill(), findsNothing);
      // An important one shows all the same.
      c.read(availableUpdateProvider.notifier).set(release('4.0.3', critical: true));
      await tester.pump();
      expect(pill(), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 10));
    });

    testWidgets('once this copy is updated, the pill shows again for the next release', (tester) async {
      await prefs.setString('update_pill_hidden_on', '4.0.0+300');
      final c = await pump(tester, running: '4.0.1');
      c.read(availableUpdateProvider.notifier).set(release('4.0.2'));
      await tester.pumpAndSettle();
      expect(pill(), findsOneWidget);
    });

    testWidgets('the dialog\'s switch turns automatic updates on, and the pill goes', (tester) async {
      final c = await pump(tester);
      c.read(availableUpdateProvider.notifier).set(release('4.0.1'));
      await tester.pump();
      await tester.tap(pill());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('update-dialog-automatic')));
      await tester.pumpAndSettle();
      expect(prefs.getBool('update_auto_install'), isTrue);
      expect(c.read(updateNoticeHiddenProvider), isTrue);
      // Ignore has nothing left to hide.
      expect(find.byKey(const ValueKey('update-dialog-ignore')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('update-dialog-tertiary')));
      await tester.pumpAndSettle();
      expect(pill(), findsNothing);
    });

    testWidgets('an important release has no Ignore update', (tester) async {
      final c = await pump(tester);
      c.read(availableUpdateProvider.notifier).set(release('4.0.1', critical: true));
      await tester.pump();
      await tester.tap(pill());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-dialog-ignore')), findsNothing);
    });

    testWidgets('opened to install by itself, the update is under way without a click', (tester) async {
      final updater = _Updater(fail: UpdateFailure(ErrorCodes.updateDownloadFailed, 'offline'));
      final c = await pump(tester, updater: updater);
      final info = release('4.0.1');
      c.read(availableUpdateProvider.notifier).set(info);
      await tester.pump();
      showUpdateDialog(tester.element(find.byType(UpdateAvailablePill)), info, autoStart: true);
      await tester.pumpAndSettle();
      expect(updater.downloads, 1);
      expect(find.byKey(const ValueKey('update-dialog-error')), findsOneWidget);
    });
  });
}

class _Latest extends UpdateCheckService {
  _Latest(this.outcome);

  final UpdateCheckOutcome outcome;

  @override
  bool get checksForUpdates => true;

  @override
  Future<UpdateCheckOutcome> checkNow() async => outcome;
}

class _Updater extends AppUpdater {
  _Updater({this.block, this.fail}) : super(platform: UpdatePlatform.windows);

  final CannotInstall? block;
  final UpdateFailure? fail;
  int downloads = 0;

  @override
  InstallCheck check(UpdateInfo info) =>
      block ??
      const CanInstall(InstallTarget(platform: UpdatePlatform.windows, executable: r'C:\Z\zestssh.exe', installDir: r'C:\Z'));

  @override
  Future<File> download(UpdateInfo info, {void Function(int received, int total)? onProgress, UpdateCancelToken? cancel}) async {
    downloads++;
    if (fail != null) throw fail!;
    return File('ZestSSH-${info.version}-Setup.exe');
  }
}
