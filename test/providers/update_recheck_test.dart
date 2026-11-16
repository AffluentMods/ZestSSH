import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/services/update_check_service.dart';

/// Answers each check with the release the test says is out (none: this
/// copy is the latest). It counts the checks asked of it, and the requests
/// they would make (none on a store's build, as the service has it).
class _Releases extends UpdateCheckService {
  _Releases(this.out, {super.storeBuild});

  UpdateInfo? out;
  int asked = 0;
  int checks = 0;

  @override
  Future<UpdateCheckOutcome> checkNow() async {
    asked++;
    if (!checksForUpdates) return const UpdateCheckFailed();
    checks++;
    final release = out;
    return release == null ? const UpdateCheckUpToDate('3.3.0') : UpdateAvailable(release);
  }
}

UpdateInfo _release(String version) => UpdateInfo(version: version, downloadUrl: 'https://zestssh.com/download');

/// 3.3.1: the update check looks again for releases newer than the one
/// it already found.
/// The automatic check ran once per start, so an app left
/// open never heard of a release out after it, and kept offering the first
/// one it found.
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// The app as it runs, on the test's clock, with what shows the update on
  /// screen (the shell's banner listens).
  Future<(ProviderContainer, ProviderSubscription<UpdateInfo?>)> start(WidgetTester tester, _Releases releases) async {
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      updateCheckServiceProvider.overrideWithValue(releases),
      updateClockProvider.overrideWithValue(tester.binding.clock.now),
    ]);
    final banner = c.listen(updateBannerProvider, (_, _) {});
    await tester.pump();
    return (c, banner);
  }

  int said(ProviderContainer c) => c.read(notificationCenterProvider).history.length;

  testWidgets('an app left open checks again every six hours, and a newer release takes the place of the one it had',
      (tester) async {
    final releases = _Releases(_release('3.3.1'));
    final (c, banner) = await start(tester, releases);
    expect(releases.checks, 1, reason: 'at the start, as before');
    expect(c.read(availableUpdateProvider)?.version, '3.3.1');
    expect(c.read(updateBannerProvider)?.version, '3.3.1');
    expect(said(c), 1);

    await tester.pump(const Duration(hours: 5, minutes: 59));
    expect(releases.checks, 1, reason: 'not before six hours');
    await tester.pump(const Duration(minutes: 1));
    expect(releases.checks, 2, reason: 'six hours on');
    expect(c.read(updateBannerProvider)?.version, '3.3.1');
    expect(said(c), 1, reason: 'the same release is said once');

    releases.out = _release('3.3.2');
    await tester.pump(const Duration(hours: 6));
    expect(releases.checks, 3);
    expect(c.read(availableUpdateProvider)?.version, '3.3.2', reason: 'the newer release is the one held now');
    expect(c.read(updateBannerProvider)?.version, '3.3.2', reason: 'and the one the banner offers');
    expect(said(c), 2, reason: 'and it is said');

    banner.close();
    c.dispose();
  });

  testWidgets('a release waved off stays off, one newer than it is shown, and a check of an earlier start counts',
      (tester) async {
    // Checked two hours before this start: the next is due in four.
    await prefs.setInt(
        'update_last_check_ms', tester.binding.clock.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch);
    final releases = _Releases(_release('3.3.1'));
    final (c, banner) = await start(tester, releases);
    expect(releases.checks, 0, reason: 'checked less than six hours ago');
    await tester.pump(const Duration(hours: 4));
    expect(releases.checks, 1, reason: 'six hours after the last check, not after this start');
    expect(c.read(updateBannerProvider)?.version, '3.3.1');

    await c.read(updateBannerProvider.notifier).dismiss();
    await tester.pump(const Duration(hours: 6));
    expect(releases.checks, 2);
    expect(c.read(updateBannerProvider), isNull, reason: 'waved off until something newer');
    expect(c.read(availableUpdateProvider)?.version, '3.3.1', reason: 'the status bar still has it');

    releases.out = _release('3.3.2');
    await tester.pump(const Duration(hours: 6));
    expect(c.read(updateBannerProvider)?.version, '3.3.2');

    banner.close();
    c.dispose();
  });

  testWidgets('none while turned off, none on a store\'s build, none while nothing shows it, and back when something '
      'does', (tester) async {
    await prefs.setBool('update_check_enabled', false);
    final off = _Releases(_release('3.3.1'));
    final (c1, banner1) = await start(tester, off);
    await tester.pump(const Duration(days: 2));
    expect(off.asked, 0, reason: 'turned off');
    banner1.close();
    c1.dispose();
    await prefs.setBool('update_check_enabled', true);
    await prefs.remove('update_last_check_ms');

    final store = _Releases(_release('3.3.1'), storeBuild: true);
    final (c2, banner2) = await start(tester, store);
    await tester.pump(const Duration(days: 2));
    expect(store.asked, 1, reason: 'the start\'s check only, as before: nothing more is waited for');
    expect(store.checks, 0, reason: 'and no request: the store updates it');
    expect(c2.read(availableUpdateProvider), isNull);
    banner2.close();
    c2.dispose();
    await prefs.remove('update_last_check_ms');

    final releases = _Releases(_release('3.3.1'));
    final (c3, banner3) = await start(tester, releases);
    expect(releases.checks, 1);
    // The shell goes (the app locked): no check while nothing shows one.
    banner3.close();
    await tester.pump(const Duration(hours: 13));
    expect(releases.checks, 1);
    // It is back: the check that is due comes.
    final again = c3.listen(updateBannerProvider, (_, _) {});
    await tester.pump(const Duration(minutes: 1));
    expect(releases.checks, 2);
    again.close();
    c3.dispose();
  });
}
