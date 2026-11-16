import 'dart:async';
import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/cloud_reach_banner.dart';

/// On a phone: how ZestSSH Cloud stands, while something is in the way of it
/// (3.0, the outage work). A computer says it in its status bar. A phone has
/// none, and said nothing until something its person asked for failed. The
/// banner says it in the same few words, with since when; a tap asks the
/// service again and says the whole of it.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const refused = SocketException('Connection refused');

  late CloudReachService reach;
  late Object Function() health;
  late int checks;

  setUp(() {
    health = () => 200;
    checks = 0;
    reach = CloudReachService(check: () async {
      checks++;
      final answer = health();
      if (answer is int) return answer;
      if (answer is Future<int>) return answer;
      throw answer;
    });
  });

  Future<void> show(WidgetTester tester, {Locale locale = const Locale('en')}) async {
    addTearDown(reach.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [cloudReachProvider.overrideWithValue(reach)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: const Scaffold(body: Column(children: [CloudReachBanner(), Expanded(child: SizedBox())])),
      ),
    ));
    await tester.pump();
  }

  /// Lets what [happens] reach the screen.
  Future<void> said(WidgetTester tester, void Function() happens) async {
    happens();
    await tester.pump();
    await tester.pump();
  }

  /// The service gives no answer to something the app asked of it.
  Future<void> noAnswer(WidgetTester tester) async {
    health = () => refused;
    await tester.runAsync(() async {
      reach.noAnswer(refused);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    await tester.pump();
  }

  final banner = find.byKey(const ValueKey('cloud-reach-banner'));

  Icon mark(WidgetTester tester) =>
      tester.widgetList<Icon>(find.descendant(of: banner, matching: find.byType(Icon))).first;

  String since() {
    final at = reach.state.value.since!;
    return '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(CloudReachBanner)));

  String lastNotice(WidgetTester tester) {
    final notice = containerOf(tester).read(notificationCenterProvider).history.first;
    return [notice.title, if (notice.body != null) notice.body].join(' ');
  }

  testWidgets('nothing shows, and no room is taken, while nothing is known and while the service answers',
      (tester) async {
    await show(tester);
    expect(banner, findsNothing);
    expect(tester.getSize(find.byType(CloudReachBanner)), Size.zero);
    await said(tester, () => reach.heard(200));
    expect(banner, findsNothing);
    expect(tester.getSize(find.byType(CloudReachBanner)).height, 0);
  });

  testWidgets('not responding: the status bar\'s words for it, in red, and since when, with what a tap does',
      (tester) async {
    await show(tester);
    await noAnswer(tester);
    expect(banner, findsOneWidget);
    expect(find.text(l10n.cloudChipNotResponding), findsOneWidget);
    expect(find.text(l10n.cloudBannerSince(since())), findsOneWidget);
    expect(mark(tester).icon, LucideIcons.cloudOff);
    expect(mark(tester).color, AppColors.v3Error);
    expect(tester.getSize(find.byType(CloudReachBanner)).height, greaterThan(30));
  });

  testWidgets('the device offline: an amber word for that, not a red one for the service', (tester) async {
    await show(tester);
    reach.heard(200);
    await said(tester, () => reach.networkChanged(up: false));
    expect(find.text(l10n.cloudChipOffline), findsOneWidget);
    expect(mark(tester).icon, LucideIcons.wifiOff);
    expect(mark(tester).color, AppColors.v3Warning);
  });

  testWidgets('a fault of the service: said as that, in red', (tester) async {
    await show(tester);
    health = () => 503;
    await tester.runAsync(() async {
      reach.heard(503);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.cloudChipFault), findsOneWidget);
    expect(mark(tester).color, AppColors.v3Error);
  });

  testWidgets('a tap asks again: still not answering is said in full, with its code and what was caught to copy',
      (tester) async {
    await show(tester);
    await noAnswer(tester);
    final before = checks;
    await tester.runAsync(() async {
      await tester.tap(banner);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(checks, before + 1);
    expect(lastNotice(tester), '${l10n.cloudNotResponding} (ZS-1101)');
    expect(containerOf(tester).read(notificationCenterProvider).history.first.details, contains('Connection refused'));
    expect(banner, findsOneWidget, reason: 'it is still in the way');
    // Once it has asked, it can be asked again.
    expect(find.descendant(of: banner, matching: find.byType(CircularProgressIndicator)), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(banner);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(checks, before + 2);
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('a tap asks again: answering again is said, and the banner goes', (tester) async {
    await show(tester);
    await noAnswer(tester);
    health = () => 200;
    await tester.runAsync(() async {
      await tester.tap(banner);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    await tester.pump();
    expect(lastNotice(tester), l10n.cloudAnsweringAgain);
    expect(banner, findsNothing);
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('taps while it is asking ask once', (tester) async {
    await show(tester);
    await noAnswer(tester);
    final answer = Completer<int>();
    health = () => answer.future;
    final before = checks;
    await tester.tap(banner);
    await tester.pump();
    expect(find.descendant(of: banner, matching: find.byType(CircularProgressIndicator)), findsOneWidget,
        reason: 'it shows that it is asking');
    await tester.tap(banner);
    await tester.tap(banner);
    await tester.pump();
    expect(checks, before + 1);
    await tester.runAsync(() async {
      answer.complete(200);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    await tester.pump();
    expect(banner, findsNothing);
    // (The service shares one question among all who ask at once, so the
    // taps would each have been told the answer.)
    final notice = containerOf(tester).read(notificationCenterProvider).history.first;
    expect(notice.title, l10n.cloudAnsweringAgain);
    expect(notice.repeats, 1, reason: 'what came of it is said once, however often it was tapped');
    await tester.pump(const Duration(seconds: 12));
  });

  testWidgets('it is read out as one thing: what is wrong, since when, and what a tap does', (tester) async {
    final handle = tester.ensureSemantics();
    await show(tester);
    await noAnswer(tester);
    expect(find.bySemanticsLabel('${l10n.cloudChipNotResponding}. ${l10n.cloudBannerSince(since())}'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('it speaks the language of the app', (tester) async {
    final de = lookupAppLocalizations(const Locale('de'));
    await show(tester, locale: const Locale('de'));
    await noAnswer(tester);
    expect(find.text(de.cloudChipNotResponding), findsOneWidget);
    expect(find.text(de.cloudBannerSince(since())), findsOneWidget);
  });

  test('the mark of each failure: its sign, and red for the service, amber for this side', () {
    expect({for (final kind in CloudFailureKind.values) kind: cloudFailureMark(CloudFailure(kind))}, {
      CloudFailureKind.deviceOffline: (LucideIcons.wifiOff, AppColors.v3Warning),
      CloudFailureKind.notResponding: (LucideIcons.cloudOff, AppColors.v3Error),
      CloudFailureKind.notSecure: (LucideIcons.shieldAlert, AppColors.v3Warning),
      CloudFailureKind.fault: (LucideIcons.cloudOff, AppColors.v3Error),
      CloudFailureKind.down: (LucideIcons.cloudOff, AppColors.v3Error),
      CloudFailureKind.blockedHere: (LucideIcons.ban, AppColors.v3Warning),
      CloudFailureKind.nothingReached: (LucideIcons.globe2, AppColors.v3Warning),
    });
  });

  test('since when: the time of day, and the day with it when that was not today', () {
    final now = DateTime(2026, 10, 9, 18, 30);
    String? of(DateTime? since, {DateTime? outage}) => cloudSinceText(
        CloudReachState(CloudReach.notResponding, since: since, outageSince: outage), 'en',
        now: now);
    expect(of(DateTime(2026, 10, 9, 7, 5)), '07:05');
    expect(of(DateTime(2026, 10, 8, 23, 59)), 'Oct 8, 23:59');
    expect(of(null), isNull);
    // An outage that is proven counts from when the service went down.
    expect(of(DateTime(2026, 10, 9, 18), outage: DateTime(2026, 10, 9, 16, 45)), '16:45');
  });

  test('every language says since when and what a tap does, and what a tap does where no time is known', () {
    final seen = <String>{};
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      expect(words.cloudBannerSince('18:30'), contains('18:30'), reason: '$locale');
      expect(words.cloudBannerTap.trim(), isNotEmpty, reason: '$locale');
      expect(words.cloudBannerSince('18:30'), isNot(words.cloudChipSince('18:30')),
          reason: '$locale: a phone is tapped, not clicked');
      seen
        ..add(words.cloudBannerSince('18:30'))
        ..add(words.cloudBannerTap);
    }
    expect(seen, hasLength(AppLocalizations.supportedLocales.length * 2));
  });
}
