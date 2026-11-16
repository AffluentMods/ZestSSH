import 'dart:async';
import 'dart:io' show HandshakeException, SocketException;

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/services/settings_service.dart' show SyncPause;
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_status_bar.dart';
import 'package:zestssh/ui/screens/sync/sync_pause.dart';

/// The status bar's sync item says plainly when this device is not syncing
/// (red) or is behind (amber), and clicking the version checks for updates
/// and says what it found.

/// Answers checks when the test says so, and counts them.
class _FakeUpdates extends UpdateCheckService {
  _FakeUpdates(this.answer);
  final Completer<UpdateCheckOutcome> answer;
  int calls = 0;

  @override
  Future<UpdateCheckOutcome> checkNow() {
    calls++;
    return answer.future;
  }
}

Widget _host(Widget child, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('status bar sync', () {
    Future<void> show(WidgetTester tester, SyncHealthState state) =>
        tester.pumpWidget(_host(
          const StatusBarSyncItem(),
          [syncHealthProvider.overrideWithValue(state)],
        ));

    Icon icon(WidgetTester tester) => tester.widget<Icon>(find.descendant(
        of: find.byKey(const ValueKey('status-bar-sync')),
        matching: find.byType(Icon)));

    String tooltip(WidgetTester tester) => tester
        .widget<Tooltip>(find.ancestor(
            of: find.byKey(const ValueKey('status-bar-sync')),
            matching: find.byType(Tooltip)))
        .message!;

    testWidgets('off (never set up): a quiet grey cloud that says Sync off, red being for a failure', (tester) async {
      await show(tester, const SyncHealthState(SyncHealth.off));
      expect(find.text(l10n.statusBarSyncOff), findsOneWidget);
      expect(icon(tester).icon, LucideIcons.cloudOff);
      expect(icon(tester).color, AppColors.v3TextTertiary);
      expect(tooltip(tester), l10n.statusBarNotSyncingTooltip);
    });

    testWidgets('behind: an amber cloud, with how long since it last synced',
        (tester) async {
      await show(
          tester,
          SyncHealthState(SyncHealth.behind,
              confirmedAt: DateTime.now().subtract(const Duration(days: 2))));
      expect(find.text(l10n.statusBarSyncBehind), findsOneWidget);
      expect(icon(tester).color, AppColors.v3Warning);
      expect(tooltip(tester), l10n.statusBarSyncStaleTooltip(l10n.timeDaysAgo(2)));
    });

    // The time inside the sentence takes the words made for it (3.0):
    // it said "Last synced Just now."
    testWidgets('behind a moment after it synced: just now, inside its sentence', (tester) async {
      await show(
          tester,
          SyncHealthState(SyncHealth.behind,
              confirmedAt: DateTime.now().subtract(const Duration(seconds: 5))));
      expect(tooltip(tester), 'Last synced just now. Click to open Sync.');
    });

    testWidgets('behind with changes waiting says they are waiting', (tester) async {
      await show(
          tester,
          SyncHealthState(SyncHealth.behind,
              confirmedAt: DateTime.now(), waiting: true));
      expect(tooltip(tester), l10n.statusBarSyncWaitingTooltip);
    });

    testWidgets('paused by its person until a time: an amber pause sign, and until when', (tester) async {
      final until = DateTime.now().add(const Duration(hours: 1));
      await show(tester, SyncHealthState(SyncHealth.paused, pause: SyncPause(until: until)));
      expect(find.text(l10n.statusBarSyncPaused), findsOneWidget);
      expect(icon(tester).icon, LucideIcons.pauseCircle);
      expect(icon(tester).color, AppColors.v3Warning);
      expect(tooltip(tester), l10n.statusBarSyncPausedUntilTooltip(syncPausedUntilText(until, 'en')));
    });

    testWidgets('paused until its person resumes it: says so', (tester) async {
      await show(tester, const SyncHealthState(SyncHealth.paused, pause: SyncPause()));
      expect(find.text(l10n.statusBarSyncPaused), findsOneWidget);
      expect(tooltip(tester), l10n.statusBarSyncPausedIndefinitelyTooltip);
    });

    testWidgets('failing: red, with what went wrong', (tester) async {
      await show(
          tester,
          const SyncHealthState(SyncHealth.failing,
              problem: 'The sync server could not be reached'));
      expect(find.text(l10n.statusBarSyncError), findsOneWidget);
      expect(icon(tester).icon, LucideIcons.refreshCwOff);
      expect(icon(tester).color, AppColors.v3Error);
      expect(tooltip(tester), 'The sync server could not be reached');
    });

    testWidgets('failing while the app tries again by itself: it says that too', (tester) async {
      await show(
          tester,
          const SyncHealthState(SyncHealth.failing,
              problem: 'The sync server could not be reached.', retrying: true));
      expect(find.text(l10n.statusBarSyncError), findsOneWidget);
      expect(tooltip(tester), 'The sync server could not be reached. ZestSSH keeps trying by itself.');
    });

    testWidgets('what is wrong is said in lines that can be read, not in one as wide as the window', (tester) async {
      tester.view.physicalSize = const Size(1600, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final problem = '${l10n.cloudNotResponding} (ZS-1101)';
      await show(tester, SyncHealthState(SyncHealth.failing, problem: problem, retrying: true));
      await tester.longPress(find.byKey(const ValueKey('status-bar-sync')));
      await tester.pump(const Duration(milliseconds: 400));
      final said = tester.getSize(find.text(problem));
      expect(said.width, lessThanOrEqualTo(460), reason: 'about seventy letters to a line');
      expect(said.height, greaterThan(30), reason: 'several lines');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('up to date: green', (tester) async {
      await show(tester,
          SyncHealthState(SyncHealth.upToDate, confirmedAt: DateTime.now()));
      expect(find.text(l10n.statusBarSynced), findsOneWidget);
      expect(icon(tester).color, AppColors.v3Success);
    });
  });

  group('status bar version', () {
    late SharedPreferences prefs;

    setUp(() async {
      // Automatic checks are off: a click still checks, because the person
      // asked.
      SharedPreferences.setMockInitialValues({'update_check_enabled': false});
      prefs = await SharedPreferences.getInstance();
    });

    Future<_FakeUpdates> showAndClick(WidgetTester tester) async {
      final service = _FakeUpdates(Completer<UpdateCheckOutcome>());
      await tester.pumpWidget(_host(const StatusBarVersionItem(), [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appVersionProvider.overrideWith((ref) async => '2.2.1'),
        updateCheckServiceProvider.overrideWithValue(service),
      ]));
      await tester.pump();
      expect(find.text('v2.2.1'), findsOneWidget);
      expect(service.calls, 0, reason: 'nothing checks until the click');

      await tester.tap(find.byKey(const ValueKey('status-bar-version')));
      await tester.pump();
      expect(service.calls, 1);
      expect(find.byKey(const ValueKey('status-bar-version-checking')),
          findsOneWidget);

      // A second click while it runs does not start another check.
      await tester.tap(find.byKey(const ValueKey('status-bar-version')));
      await tester.pump();
      expect(service.calls, 1);
      return service;
    }

    Future<AppNotification> answered(
        WidgetTester tester, _FakeUpdates service, UpdateCheckOutcome outcome) async {
      service.answer.complete(outcome);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('status-bar-version-checking')),
          findsNothing);
      final container = ProviderScope.containerOf(
          tester.element(find.byType(StatusBarVersionItem)));
      return container.read(notificationCenterProvider).history.single;
    }

    testWidgets('a click checks now and says this is the latest',
        (tester) async {
      final service = await showAndClick(tester);
      final said =
          await answered(tester, service, const UpdateCheckUpToDate('2.2.1'));
      expect(said.title, l10n.updateCheckUpToDate('2.2.1'));
      expect(said.severity, NotificationSeverity.success);
      expect(prefs.getInt('update_last_check_ms'), isNotNull);
      expect(find.byIcon(LucideIcons.arrowUpCircle), findsNothing);
      await tester.pump(const Duration(seconds: 10)); // the toast times out
    });

    testWidgets('a newer release turns the version into the update chip',
        (tester) async {
      final service = await showAndClick(tester);
      final said = await answered(
          tester,
          service,
          const UpdateAvailable(UpdateInfo(
              version: '2.3.0', downloadUrl: 'https://zestssh.com/download')));
      expect(said.title, l10n.updateBannerVersionAvailable('2.3.0'));
      expect(said.actionLabel, l10n.updateBannerUpdateAction);
      expect(find.byIcon(LucideIcons.arrowUpCircle), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('no answer says it could not check, and changes nothing',
        (tester) async {
      final service = await showAndClick(tester);
      final said =
          await answered(tester, service, const UpdateCheckFailed());
      expect(said.title, l10n.updateCheckFailed);
      expect(said.severity, NotificationSeverity.error);
      expect(prefs.getInt('update_last_check_ms'), isNull);
      expect(find.byIcon(LucideIcons.arrowUpCircle), findsNothing);
      expect(find.text('v2.2.1'), findsOneWidget);
    });
  });

  // How ZestSSH Cloud stands, where everybody can see it (3.0; so that
  // a server that is offline is known, and said as a message of
  // the backend or server not responding). It shows only while
  // something is in the way.
  group('status bar: ZestSSH Cloud', () {
    late int checks;
    late Object Function() health;
    late CloudReachService reach;

    setUp(() {
      checks = 0;
      health = () => 200;
      reach = CloudReachService(check: () async {
        checks++;
        final answer = health();
        if (answer is int) return answer;
        throw answer;
      });
    });

    Future<void> show(WidgetTester tester) async {
      addTearDown(reach.dispose);
      await tester.pumpWidget(_host(
        const StatusBarCloudItem(),
        [cloudReachProvider.overrideWithValue(reach)],
      ));
      await tester.pump();
    }

    Future<void> said(WidgetTester tester, void Function() happens) async {
      happens();
      await tester.pump();
      await tester.pump();
    }

    final item = find.byKey(const ValueKey('status-bar-cloud'));

    Icon icon(WidgetTester tester) =>
        tester.widget<Icon>(find.descendant(of: item, matching: find.byType(Icon)));

    String tooltip(WidgetTester tester) =>
        tester.widget<Tooltip>(find.ancestor(of: item, matching: find.byType(Tooltip))).message!;

    testWidgets('nothing shows while nothing is known, and nothing while it answers', (tester) async {
      await show(tester);
      expect(item, findsNothing);
      await said(tester, () => reach.heard(200));
      expect(item, findsNothing);
      expect(tester.getSize(find.byType(StatusBarCloudItem)), Size.zero, reason: 'no room taken either');
    });

    testWidgets('not responding: says so, with what is not affected, its code and since when', (tester) async {
      await show(tester);
      health = () => const SocketException('Connection refused');
      reach.networkChanged(up: true);
      await tester.runAsync(() async {
        reach.noAnswer(const SocketException('Connection refused'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await tester.pump();
      expect(find.text(l10n.cloudChipNotResponding), findsOneWidget);
      expect(icon(tester).icon, LucideIcons.cloudOff);
      expect(icon(tester).color, AppColors.v3Error);
      final since = reach.state.value.since!;
      final at = '${since.hour.toString().padLeft(2, '0')}:${since.minute.toString().padLeft(2, '0')}';
      expect(tooltip(tester), '${l10n.cloudNotResponding} (ZS-1101)\n${l10n.cloudChipSince(at)}');
    });

    testWidgets('the whole of it is said in lines that can be read, not in one as wide as the window', (tester) async {
      tester.view.physicalSize = const Size(1600, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await show(tester);
      reach.heard(200);
      await said(tester, () => reach.networkChanged(up: false));
      final whole = tooltip(tester);
      expect(whole, contains('\n'), reason: 'what is wrong, and since when under it');
      await tester.longPress(item);
      await tester.pump(const Duration(milliseconds: 400));
      final size = tester.getSize(find.text(whole));
      expect(size.width, lessThanOrEqualTo(460), reason: 'about seventy letters to a line');
      expect(size.height, greaterThan(40), reason: 'several lines');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the device offline: an amber word for that, not a red one for the service', (tester) async {
      await show(tester);
      reach.heard(200);
      await said(tester, () => reach.networkChanged(up: false));
      expect(find.text(l10n.cloudChipOffline), findsOneWidget);
      expect(icon(tester).icon, LucideIcons.wifiOff);
      expect(icon(tester).color, AppColors.v3Warning);
      expect(tooltip(tester), startsWith('${l10n.cloudDeviceOffline} (ZS-1102)'));
    });

    testWidgets('a fault of the service: says so, with the status it answered', (tester) async {
      await show(tester);
      health = () => 503;
      await tester.runAsync(() async {
        reach.heard(503);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await tester.pump();
      expect(find.text(l10n.cloudChipFault), findsOneWidget);
      expect(icon(tester).color, AppColors.v3Error);
      expect(tooltip(tester), startsWith('${l10n.cloudFault(503)} (ZS-1103)'));
    });

    testWidgets('a click asks again: still not answering is said again, with the details to copy', (tester) async {
      await show(tester);
      health = () => const SocketException('Connection refused');
      await tester.runAsync(() async {
        reach.noAnswer(const SocketException('Connection refused'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await tester.pump();
      final before = checks;
      await tester.runAsync(() async {
        await tester.tap(item);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      expect(checks, before + 1);
      final container = ProviderScope.containerOf(tester.element(find.byType(StatusBarCloudItem)));
      final notice = container.read(notificationCenterProvider).history.first;
      expect([notice.title, if (notice.body != null) notice.body].join(' '), '${l10n.cloudNotResponding} (ZS-1101)');
      expect(notice.details, contains('Connection refused'));
      expect(item, findsOneWidget);
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('a click asks again: answering again is said, and the item goes', (tester) async {
      await show(tester);
      health = () => const SocketException('Connection refused');
      await tester.runAsync(() async {
        reach.noAnswer(const SocketException('Connection refused'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await tester.pump();
      health = () => 200;
      await tester.runAsync(() async {
        await tester.tap(item);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      await tester.pump();
      final container = ProviderScope.containerOf(tester.element(find.byType(StatusBarCloudItem)));
      expect(container.read(notificationCenterProvider).history.first.title, l10n.cloudAnsweringAgain);
      expect(item, findsNothing);
      await tester.pump(const Duration(seconds: 12));
    });

    // With the status service asked, "not responding" is one of three, and
    // each is said (3.0).
    group('seen from somewhere else', () {
      late CloudStatement? Function() says;
      late CloudReachService watched;

      setUp(() {
        says = () => null;
        watched = CloudReachService(
          check: () async {
            final answer = health();
            if (answer is int) return answer;
            throw answer;
          },
          status: () async => says(),
        );
      });

      Future<void> showAfter(WidgetTester tester, Object met, {bool? network}) async {
        addTearDown(watched.dispose);
        await tester.pumpWidget(_host(
          const StatusBarCloudItem(),
          [cloudReachProvider.overrideWithValue(watched)],
        ));
        await tester.pump();
        health = () => met;
        if (network != null) watched.networkChanged(up: network);
        await tester.runAsync(() async {
          if (met is int) {
            watched.heard(met);
          } else {
            watched.noAnswer(met);
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pump();
        await tester.pump();
      }

      const refused = SocketException('Connection refused');

      testWidgets('proven down: a red word for it, and since when the service has been down', (tester) async {
        final today = DateTime.now();
        final began = DateTime(today.year, today.month, today.day, 8, 5);
        final at = today.millisecondsSinceEpoch ~/ 1000;
        says = () => CloudStatement(
            down: true, at: at, until: at + 900, since: began.millisecondsSinceEpoch ~/ 1000, keyId: 'k1');
        await showAfter(tester, refused, network: true);
        expect(find.text(l10n.cloudChipDown), findsOneWidget);
        expect(icon(tester).icon, LucideIcons.cloudOff);
        expect(icon(tester).color, AppColors.v3Error);
        expect(tooltip(tester), '${l10n.cloudDown} (ZS-1105)\n${l10n.cloudChipSince('08:05')}',
            reason: 'since the outage began, not since this device noticed');
      });

      testWidgets('up, and blocked on this network: an amber word for that', (tester) async {
        const at = 1791474000;
        says = () => const CloudStatement(down: false, at: at, until: at + 900, since: 0, keyId: 'k1');
        await showAfter(tester, refused);
        expect(find.text(l10n.cloudChipBlocked), findsOneWidget);
        expect(icon(tester).icon, LucideIcons.ban);
        expect(icon(tester).color, AppColors.v3Warning);
        expect(tooltip(tester), startsWith('${l10n.cloudBlockedHere} (ZS-1106)'));
      });

      testWidgets('nothing of ZestSSH reached: an amber word for no internet', (tester) async {
        await showAfter(tester, refused);
        expect(find.text(l10n.cloudChipNoInternet), findsOneWidget);
        expect(icon(tester).icon, LucideIcons.globe2);
        expect(icon(tester).color, AppColors.v3Warning);
        expect(tooltip(tester), startsWith('${l10n.cloudNothingReached} (ZS-1107)'));
      });

      testWidgets('what answered could not be verified: an amber word for that, with the two usual causes', (tester) async {
        await showAfter(tester, const HandshakeException('CERTIFICATE_VERIFY_FAILED'));
        expect(find.text(l10n.cloudChipNotSecure), findsOneWidget);
        expect(icon(tester).icon, LucideIcons.shieldAlert);
        expect(icon(tester).color, AppColors.v3Warning);
        expect(tooltip(tester), startsWith('${l10n.cloudNotSecure} (ZS-1104)'));
      });

      testWidgets('a click on a proven outage asks again and says the same, with the details', (tester) async {
        const at = 1791474000;
        says = () => const CloudStatement(down: true, at: at, until: at + 900, since: at - 60, keyId: 'k1');
        await showAfter(tester, refused);
        await tester.runAsync(() async {
          await tester.tap(item);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pump();
        final container = ProviderScope.containerOf(tester.element(find.byType(StatusBarCloudItem)));
        final notice = container.read(notificationCenterProvider).history.first;
        expect([notice.title, if (notice.body != null) notice.body].join(' '), '${l10n.cloudDown} (ZS-1105)');
        expect(notice.details, contains('Connection refused'));
        await tester.pump(const Duration(seconds: 12));
      });
    });

    test('since when is the time of day, and the day with it when that was not today', () async {
      await initializeDateFormatting('en');
      await initializeDateFormatting('de');
      final now = DateTime(2026, 10, 8, 14, 5);
      String? of(CloudReachState state, [String locale = 'en']) => StatusBarCloudItem.sinceText(state, locale, now: now);
      expect(of(const CloudReachState.unknown()), isNull);
      expect(of(CloudReachState(CloudReach.notResponding, since: DateTime(2026, 10, 8, 9, 3))), '09:03');
      expect(of(CloudReachState(CloudReach.notResponding, since: DateTime(2026, 10, 8, 0, 0))), '00:00');
      expect(of(CloudReachState(CloudReach.notResponding, since: DateTime(2026, 10, 7, 22, 15))), 'Oct 7, 22:15');
      expect(of(CloudReachState(CloudReach.notResponding, since: DateTime(2026, 10, 7, 22, 15)), 'de'), '7. Okt., 22:15');
      expect(of(CloudReachState(CloudReach.notResponding, since: DateTime(2025, 10, 8, 14, 5))), 'Oct 8, 14:05',
          reason: 'the same day of another year is another day');
      expect(of(CloudReachState(CloudReach.notResponding, since: DateTime(2026, 9, 8, 14, 5))), 'Sep 8, 14:05',
          reason: 'and so is the same day of another month');
      // A proven outage is since the service went down, not since this device noticed.
      final down = CloudReachState(CloudReach.down,
          since: DateTime(2026, 10, 8, 13, 50), outageSince: DateTime(2026, 10, 8, 6, 0));
      expect(of(down), '06:00');
      // It is said in this device's own time of day, whatever clock the
      // moment was written in (the status service's is UTC).
      final sixHere = DateTime(2026, 10, 8, 6, 0).toUtc();
      expect(sixHere.isUtc, isTrue);
      expect(of(CloudReachState(CloudReach.down, since: now, outageSince: sixHere)), '06:00');
      // A language whose date words were never loaded: the day in figures, never a failure.
      expect(of(CloudReachState(CloudReach.notResponding, since: DateTime(2026, 10, 7, 22, 15)), 'xx'), '2026-10-07, 22:15');
    });

    testWidgets('every language has a short word for each of the seven', (tester) async {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        final words = [
          l.cloudChipNotResponding,
          l.cloudChipOffline,
          l.cloudChipFault,
          l.cloudChipDown,
          l.cloudChipBlocked,
          l.cloudChipNoInternet,
          l.cloudChipNotSecure,
        ];
        expect(words.toSet(), hasLength(7), reason: '$locale');
        for (final word in words) {
          expect(word.trim(), isNotEmpty, reason: '$locale');
          expect(word.length, lessThan(40), reason: '$locale: it is a word for a status bar');
        }
        if (locale.languageCode != 'en') {
          expect(l.cloudChipDown, isNot(l10n.cloudChipDown), reason: '$locale');
          expect(l.cloudChipBlocked, isNot(l10n.cloudChipBlocked), reason: '$locale');
          expect(l.cloudChipNoInternet, isNot(l10n.cloudChipNoInternet), reason: '$locale');
          expect(l.cloudChipNotSecure, isNot(l10n.cloudChipNotSecure), reason: '$locale');
        }
      }
    });

    testWidgets('every language has a short word for each of the three', (tester) async {
      final en = l10n;
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        final words = [l.cloudChipNotResponding, l.cloudChipOffline, l.cloudChipFault];
        expect(words.toSet(), hasLength(3), reason: '$locale');
        for (final word in words) {
          expect(word.trim(), isNotEmpty, reason: '$locale');
          expect(word.length, lessThan(40), reason: '$locale: it is a word for a status bar');
        }
        expect(l.cloudChipSince('14:05'), contains('14:05'), reason: '$locale');
        expect(l.cloudAnsweringAgain, contains('ZestSSH Cloud'), reason: '$locale');
        if (locale.languageCode != 'en') {
          expect(l.cloudChipNotResponding, isNot(en.cloudChipNotResponding), reason: '$locale');
          expect(l.cloudChipSince('14:05'), isNot(en.cloudChipSince('14:05')), reason: '$locale');
          expect(l.cloudAnsweringAgain, isNot(en.cloudAnsweringAgain), reason: '$locale');
        }
      }
    });
  });
}
