import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/features/orchards/team/team_seats_sheet.dart' show seatPurchaseProblem;
import 'package:zestssh/features/orchards/widgets/orchard_access_view.dart' show accessErrorMessage;
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart';
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// An Orchard's seats and Business Services on its Team page (3.0):
/// read from ZestSSH Cloud through the real client, shown to every
/// member; owners on a computer open the seats sheet to buy
/// (team_seats_sheet_test.dart), and on phones and tablets nothing is bought
/// or pointed to.

const _orchard = '0f0e0d0c-0b0a-4908-8706-050403020100';
const _owner = OrchardSummary(id: _orchard, name: 'Acme', role: FixedRoles.owner, crates: [], defaultCrateId: null);
const _admin = OrchardSummary(id: _orchard, name: 'Acme', role: FixedRoles.admin, crates: [], defaultCrateId: null);

/// The billing route's answer.
Map<String, Object?> _answer({
  int bought = 5,
  int included = 0,
  int used = 3,
  Map<String, Object?>? services,
}) {
  final total = bought + included;
  return {
    'seats': {
      'bought': bought,
      'included': included,
      'total': total,
      'used': used,
      'free': used > total ? 0 : total - used,
      'over': used > total,
    },
    'business_services': services ??
        {
          'state': 'active',
          'status': 'active',
          'interval': 'year',
          'quantity': total,
          'paid_through': '2027-01-15T12:00:00.000Z',
          'works_until': '2027-01-29T12:00:00.000Z',
          'cancel_at_period_end': false,
        },
    'prices': {'seat_cents': 7500, 'max_per_purchase': 250},
  };
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  String day(String iso) => DateFormat.yMMMd('en').format(DateTime.parse(iso).toLocal());

  late List<http.Request> requests;
  late List<Uri> opened;

  /// The Seats page of [orchard], ZestSSH Cloud answering with [answers] in
  /// turn (a Map is JSON with 200; an int is that status; an Exception is
  /// thrown), on a computer unless [here] is false.
  Future<void> show(WidgetTester tester, OrchardSummary orchard, List<Object> answers, {bool here = true}) async {
    requests = [];
    opened = [];
    var n = 0;
    final client = MockClient((request) async {
      requests.add(request);
      final a = answers[n < answers.length ? n++ : answers.length - 1];
      if (a is Exception) throw a;
      if (a is int) return http.Response(jsonEncode({'error': 'x', 'code': 'server'}), a);
      return http.Response(jsonEncode(a), 200, headers: {'content-type': 'application/json'});
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardBillingApiProvider.overrideWithValue(
            OrchardBillingApi(client: client, baseUrl: 'https://api.test/v1', bearer: () async => 'token-1')),
        billingOnThisDeviceProvider.overrideWithValue(here),
        seatsPageOpenerProvider.overrideWithValue((page) async => opened.add(page)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: TeamSeatsView(orchard: orchard))),
      ),
    ));
    await tester.pumpAndSettle();
  }

  String textOf(WidgetTester tester, String key) => tester
      .widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text), matchRoot: true))
      .map((t) => t.data ?? t.textSpan?.toPlainText())
      .join(' ');

  /// Every word on screen.
  String screen(WidgetTester tester) => [
        for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? '',
        for (final t in tester.widgetList<SelectableText>(find.byType(SelectableText))) t.data ?? '',
      ].join('\n');

  testWidgets('an owner on a computer sees the seats, and Buy seats opens the seats sheet, not the website', (tester) async {
    await show(tester, _owner, [_answer(bought: 5, included: 1, used: 3)]);
    expect(requests.single.url.toString(), 'https://api.test/v1/orchards/$_orchard/billing');
    expect(requests.single.headers['Authorization'], 'Bearer token-1');

    expect(find.text(l10n.teamSeatsInUse(3, 6)), findsOneWidget);
    expect(textOf(tester, 'team-seats-bought'), contains('5'));
    expect(textOf(tester, 'team-seats-included'), contains('1'));
    expect(textOf(tester, 'team-seats-free'), contains('3'));
    expect(find.byKey(const ValueKey('team-seats-over')), findsNothing);
    expect(find.text(l10n.teamSeatsBuyHint(r'$75')), findsOneWidget);
    // The website's name for the team is there to compare.
    expect(find.text(l10n.teamSeatsWebsiteId('0f0e0d0c')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-services-active')), findsOneWidget);
    expect(find.text(l10n.teamServicesRenewsYearly(6, day('2027-01-15T12:00:00.000Z'))), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('team-seats-buy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('seats-sheet')), findsOneWidget);
    expect(opened, isEmpty);
  });

  group('coming back to the app (seats bought in the browser show without a thing to press)', () {
    Future<void> cameBack(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    testWidgets('the seats are read again, and what changed shows', (tester) async {
      await show(tester, _owner, [_answer(bought: 5, used: 3), _answer(bought: 7, used: 3)]);
      expect(find.text(l10n.teamSeatsInUse(3, 5)), findsOneWidget);
      await cameBack(tester);
      expect(find.text(l10n.teamSeatsInUse(3, 7)), findsOneWidget);
      expect(find.text(l10n.teamSeatsInUse(3, 5)), findsNothing);
    });

    testWidgets('ZestSSH Cloud down meanwhile: what is on screen stays, with no error', (tester) async {
      await show(tester, _owner, [_answer(bought: 5, used: 3), 503]);
      await cameBack(tester);
      expect(find.text(l10n.teamSeatsInUse(3, 5)), findsOneWidget);
      expect(find.text(l10n.retry), findsNothing);
    });

    testWidgets('seats that could not be read are read again, and the error goes', (tester) async {
      await show(tester, _owner, [503, _answer(bought: 5, used: 3)]);
      expect(find.text(l10n.retry), findsOneWidget);
      await cameBack(tester);
      expect(find.text(l10n.teamSeatsInUse(3, 5)), findsOneWidget);
      expect(find.text(l10n.retry), findsNothing);
    });

    testWidgets('once the page is gone, nothing is read', (tester) async {
      await show(tester, _owner, [_answer(bought: 5, used: 3)]);
      final reads = requests.length;
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(requests, hasLength(reads));
    });
  });

  testWidgets('without a Bundle seat there is no line for it', (tester) async {
    await show(tester, _owner, [_answer(bought: 2, used: 1)]);
    expect(find.text(l10n.teamSeatsInUse(1, 2)), findsOneWidget);
    expect(find.byKey(const ValueKey('team-seats-included')), findsNothing);
  });

  testWidgets('no team is free: nothing bought and no Bundle, the owner alone has more people than seats',
      (tester) async {
    await show(tester, _owner, [_answer(bought: 0, used: 1)]);
    expect(find.text(l10n.teamSeatsInUse(1, 0)), findsOneWidget);
    expect(find.byKey(const ValueKey('team-seats-over')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-seats-buy')), findsOneWidget);
  });

  testWidgets('on a phone or tablet nothing is bought or pointed to: plain words, no link, no price', (tester) async {
    await show(tester, _owner, [_answer()], here: false);
    expect(find.byKey(const ValueKey('team-seats-buy')), findsNothing);
    expect(find.byKey(const ValueKey('team-seats-website-id')), findsNothing);
    expect(find.text(l10n.teamSeatsOnComputer), findsOneWidget);
    final words = screen(tester);
    expect(words, isNot(contains('zestssh.com')));
    expect(words, isNot(contains(r'$')));
    expect(find.byType(ButtonStyleButton), findsNothing);
    // Still every figure.
    expect(find.text(l10n.teamSeatsInUse(3, 5)), findsOneWidget);
  });

  testWidgets('someone who is not an owner sees the seats and is told to ask an owner, even on a computer', (tester) async {
    await show(tester, _admin, [_answer()]);
    expect(find.byKey(const ValueKey('team-seats-buy')), findsNothing);
    expect(find.text(l10n.teamSeatsAskOwner), findsOneWidget);
    expect(screen(tester), isNot(contains('zestssh.com')));
  });

  testWidgets('more people than seats: said plainly, and nothing is lost', (tester) async {
    await show(tester, _owner, [_answer(bought: 2, used: 4)]);
    expect(find.text(l10n.teamSeatsInUse(4, 2)), findsOneWidget);
    expect(find.text(l10n.teamSeatsOver), findsOneWidget);
    expect(textOf(tester, 'team-seats-free'), contains('0'));
  });

  testWidgets('Business Services: renewing monthly, set to end, a payment due, and off', (tester) async {
    await show(tester, _owner, [
      _answer(services: {
        'state': 'active', 'interval': 'month', 'quantity': 1,
        'paid_through': '2026-10-20T12:00:00.000Z', 'works_until': '2026-11-03T12:00:00.000Z',
      }),
    ]);
    expect(find.text(l10n.teamServicesRenewsMonthly(1, day('2026-10-20T12:00:00.000Z'))), findsOneWidget);

    await show(tester, _owner, [
      _answer(services: {
        'state': 'active', 'interval': 'year', 'quantity': 5, 'cancel_at_period_end': true,
        'paid_through': '2026-12-01T12:00:00.000Z', 'works_until': '2026-12-15T12:00:00.000Z',
      }),
    ]);
    expect(find.text(l10n.teamServicesEnds(day('2026-12-01T12:00:00.000Z'))), findsOneWidget);

    await show(tester, _owner, [
      _answer(services: {
        'state': 'grace', 'status': 'past_due', 'interval': 'year', 'quantity': 5,
        'paid_through': '2026-09-20T12:00:00.000Z', 'works_until': '2026-10-04T12:00:00.000Z',
      }),
    ]);
    expect(find.byKey(const ValueKey('team-services-grace')), findsOneWidget);
    expect(find.text(l10n.teamServicesGraceText(day('2026-10-04T12:00:00.000Z'))), findsOneWidget);

    await show(tester, _owner, [
      _answer(services: {'state': 'off', 'status': null, 'interval': null, 'quantity': null}),
    ]);
    expect(find.byKey(const ValueKey('team-services-off')), findsOneWidget);
    expect(find.text(l10n.teamServicesOffText), findsOneWidget);
    // What Business brings: more than 25 seats, with no upper number, as the
    // website has it now (it said "up to 1,000").
    expect(find.textContaining('more than 25 seats, priority support'), findsOneWidget);
    expect(find.textContaining('1,000'), findsNothing);
  });

  group('Business for a member who is no owner, told neither Stripe\'s word nor the grace owed', () {
    test('what ZestSSH Cloud does say reads as it does for an owner', () {
      OrchardBusinessServices services(Map<String, Object?> raw) => OrchardBusinessServices.fromJson(raw);
      const until = '2027-01-15T12:00:00.000Z';
      const works = '2027-01-29T12:00:00.000Z';
      final billed = services({'state': 'active', 'status': null, 'interval': 'year', 'quantity': 6, 'paid_through': until, 'works_until': works});
      expect(teamServicesLine(billed, l10n), l10n.teamServicesRenewsYearly(6, day(until)));
      expect(billed.notOver, isFalse, reason: 'nobody here can tell, and nobody here pays');
      final going = services({'state': 'active', 'status': null, 'interval': 'month', 'quantity': 6, 'paid_through': until, 'cancel_at_period_end': true});
      expect(teamServicesLine(going, l10n), l10n.teamServicesEnds(day(until)));
      final grace = services({'state': 'grace', 'status': null, 'interval': 'month', 'quantity': 6, 'paid_through': until, 'works_until': works});
      expect(teamServicesLine(grace, l10n), l10n.teamServicesGraceText(day(works)));
    });

    test('and with no date or number to say it with, no sentence has a hole in it', () {
      OrchardBusinessServices services(Map<String, Object?> raw) => OrchardBusinessServices.fromJson(raw);
      for (final raw in <Map<String, Object?>>[
        {'state': 'active'},
        {'state': 'active', 'status': null, 'interval': 'year', 'quantity': 6, 'paid_through': null},
        {'state': 'active', 'status': null, 'interval': 'month', 'quantity': null, 'paid_through': null},
        {'state': 'active', 'status': null, 'interval': 'year', 'quantity': null, 'paid_through': '2027-01-15T12:00:00.000Z'},
        {'state': 'active', 'status': null, 'interval': 'month', 'quantity': 0, 'paid_through': '2027-01-15T12:00:00.000Z'},
        {'state': 'active', 'status': null, 'interval': null, 'quantity': 3, 'paid_through': '2027-01-15T12:00:00.000Z'},
        {'state': 'active', 'cancel_at_period_end': true},
      ]) {
        final line = teamServicesLine(services(raw), l10n);
        expect(line, l10n.teamServicesOn, reason: '$raw');
      }
      expect(teamServicesLine(services({'state': 'grace'}), l10n), l10n.teamServicesGraceNoDate);
      for (final raw in <Map<String, Object?>>[
        {'state': 'active'},
        {'state': 'grace'},
        {'state': 'off'},
      ]) {
        final line = teamServicesLine(services(raw), l10n);
        expect(line, isNot(contains(' .')), reason: '$raw');
        expect(line, isNot(contains('0 seats')), reason: '$raw');
      }
    });

    testWidgets('its Seats page', (tester) async {
      await show(tester, _admin, [
        _answer(services: {
          'state': 'active', 'status': null, 'interval': 'year', 'quantity': 6,
          'paid_through': '2027-01-15T12:00:00.000Z', 'works_until': '2027-01-29T12:00:00.000Z',
        }),
      ]);
      expect(find.text(l10n.teamServicesRenewsYearly(6, day('2027-01-15T12:00:00.000Z'))), findsOneWidget);
      expect(find.text(l10n.teamSeatsAskOwner), findsOneWidget);
      expect(find.byKey(const ValueKey('team-services-see')), findsNothing);
    });
  });

  testWidgets('free Business from a code: until when and what follows, never a bill or a renewal without one',
      (tester) async {
    final until = DateTime.now().add(const Duration(days: 40)).toUtc().toIso8601String();
    await show(tester, _owner, [
      _answer(services: {
        'state': 'active', 'status': null, 'interval': null, 'quantity': 0, 'paid_through': null,
        'comped_until': until, 'grace_after_end': true,
      }),
    ]);
    expect(find.text('${l10n.teamServicesComped(day(until))} ${l10n.teamServicesCompedThenGrace}'), findsOneWidget);
    expect(find.textContaining(l10n.teamServicesRenewsMonthly(0, '').split('.').first), findsNothing);

    await show(tester, _owner, [
      _answer(services: {
        'state': 'active', 'status': null, 'interval': null, 'quantity': 0,
        'comped_until': until, 'grace_after_end': false,
      }),
    ]);
    expect(find.text('${l10n.teamServicesComped(day(until))} ${l10n.teamServicesCompedThenStops}'), findsOneWidget);

    // Free months over, the grace running.
    await show(tester, _owner, [
      _answer(services: {
        'state': 'grace', 'status': null, 'interval': null, 'quantity': 0,
        'comped_until': '2026-10-01T12:00:00.000Z', 'works_until': '2026-10-15T12:00:00.000Z',
      }),
    ]);
    expect(find.text(l10n.teamServicesCompedGrace(day('2026-10-15T12:00:00.000Z'))), findsOneWidget);

    // A subscription after the free months: both said.
    await show(tester, _owner, [
      _answer(services: {
        'state': 'active', 'status': 'active', 'interval': 'month', 'quantity': 3,
        'paid_through': until, 'comped_until': until, 'grace_after_end': true,
      }),
    ]);
    expect(find.text('${l10n.teamServicesComped(day(until))} ${l10n.teamServicesRenewsMonthly(3, day(until))}'),
        findsOneWidget);
  });

  testWidgets('seats that cannot be read say why, try again, and offer the details to copy', (tester) async {
    await show(tester, _owner, [const SocketException('no route to host'), _answer()]);
    expect(find.byKey(const ValueKey('team-seats-error')), findsOneWidget);
    expect(find.text(l10n.teamSeatsError), findsOneWidget);
    // Said as how ZestSSH Cloud stands, with the code for it.
    expect(find.text('${l10n.cloudNotResponding} (ZS-1101)'), findsOneWidget);
    expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('team-seats-retry')));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(find.text(l10n.teamSeatsInUse(3, 5)), findsOneWidget);
  });

  testWidgets('an answer that is not seats is an error, not a guess', (tester) async {
    await show(tester, _owner, [
      {'seats': {'bought': 'five'}},
    ]);
    expect(find.byKey(const ValueKey('team-seats-error')), findsOneWidget);
  });

  group('the banner above the hosts', () {
    Future<void> banner(WidgetTester tester, OrchardSummary orchard,
        {Set<String> short = const {_orchard}, Set<String> full = const {}, bool here = true}) async {
      opened = [];
      await tester.pumpWidget(ProviderScope(
        overrides: [
          activeOrchardProvider.overrideWithValue(AsyncData(orchard)),
          deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
          orchardSeatsShortProvider.overrideWith((ref) => short),
          orchardVaultsFullProvider.overrideWith((ref) => full),
          orchardBillingProvider.overrideWith((ref, id) async => OrchardBilling.fromJson(_answer())),
          billingOnThisDeviceProvider.overrideWithValue(here),
          seatsPageOpenerProvider.overrideWithValue((page) async => opened.add(page)),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('en'),
          home: Scaffold(body: OrchardStatusBanner()),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('new items waiting for seats: said, and an owner on a computer can buy them from there', (tester) async {
      await banner(tester, _owner);
      expect(find.byKey(const ValueKey('orchard-banner-seats')), findsOneWidget);
      expect(find.text(l10n.orchardSeatsBanner(l10n.orchardNamed('Acme'))), findsOneWidget);
      await tester.tap(find.text(l10n.teamSeatsBuy));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('seats-sheet')), findsOneWidget);
      expect(opened, isEmpty);
    });

    testWidgets('vaults that are full, not short of seats: said as that, what to do, its code and Copy details', (tester) async {
      await banner(tester, _owner, full: const {_orchard});
      final said = ErrorCodes.withCode(l10n.orchardVaultsFullBanner(l10n.orchardNamed('Acme')), ErrorCodes.teamVaultsFull);
      expect(find.text(said), findsOneWidget);
      expect(find.text(l10n.orchardSeatsBanner(l10n.orchardNamed('Acme'))), findsNothing);
      expect(said, contains(ErrorCodes.teamVaultsFull.code));
      expect(find.byKey(const ValueKey('orchard-banner-seats-details')), findsOneWidget);
      expect(find.text(l10n.teamSeatsBuy), findsOneWidget, reason: 'more seats make room');

      await banner(tester, _admin, full: const {_orchard});
      expect(find.text(said), findsOneWidget);
      expect(find.byKey(const ValueKey('orchard-banner-seats-details')), findsOneWidget);
      expect(find.text(l10n.teamSeatsBuy), findsNothing);
    });

    testWidgets('short of seats alone, as it was: no code and nothing to copy', (tester) async {
      await banner(tester, _owner);
      expect(find.byKey(const ValueKey('orchard-banner-seats-details')), findsNothing);
    });

    testWidgets('others, and anyone on a phone, are told without a link', (tester) async {
      await banner(tester, _admin);
      expect(find.byKey(const ValueKey('orchard-banner-seats')), findsOneWidget);
      expect(find.text(l10n.teamSeatsBuy), findsNothing);
      await banner(tester, _owner, here: false);
      expect(find.byKey(const ValueKey('orchard-banner-seats')), findsOneWidget);
      expect(find.text(l10n.teamSeatsBuy), findsNothing);
    });

    testWidgets('nothing when its last sync sent everything, or for another Orchard', (tester) async {
      await banner(tester, _owner, short: const {});
      expect(find.byKey(const ValueKey('orchard-banner-seats')), findsNothing);
      await banner(tester, _owner, short: const {'another-orchard'});
      expect(find.byKey(const ValueKey('orchard-banner-seats')), findsNothing);
    });
  });

  group('what the server says, in words', () {
    test('an invitation with no seat left, an Orchard short of seats, and Business Services needed', () {
      expect(inviteErrorMessage(const OrchardServerException(409, 'seats-full', seats: 5, seatsUsed: 5), l10n),
          l10n.orchardSeatsFull);
      expect(orchardErrorMessage(const OrchardServerException(409, 'seats-needed'), l10n), l10n.orchardSeatsNeeded);
      // How many more an invitation needs: what the server says, else one beyond those taken.
      expect(inviteSeatsNeededOf(const OrchardServerException(409, 'seats-full', seats: 5, seatsUsed: 5, seatsNeeded: 3)), 3);
      expect(inviteSeatsNeededOf(const OrchardServerException(409, 'seats-full', seats: 5, seatsUsed: 5)), 1);
      expect(inviteSeatsNeededOf(const OrchardServerException(409, 'seats-full', seats: 2, seatsUsed: 4)), 3);
      expect(inviteSeatsNeededOf(const OrchardServerException(409, 'seats-full')), 1);
      expect(inviteSeatsNeededOf(const OrchardServerException(409, 'seats-needed', seats: 1, seatsUsed: 2)), isNull);
      expect(inviteSeatsNeededOf(const OrchardServerException(429, 'rate-limited')), isNull);
      expect(inviteSeatsNeededOf(Exception('offline')), isNull);
      expect(orchardChangeErrorMessage(const OrchardServerException(409, 'business-services-required'), l10n),
          l10n.orchardServicesRequired);
    });

    test('what a team keeps is full: what happened and what to do, with a code to quote, on every path', () {
      const full = OrchardServerException(409, 'record-full');
      const large = OrchardServerException(413, 'record-entry-too-large');
      const vaults = OrchardServerException(409, 'seats-needed', reason: 'storage', seats: 5, seatsUsed: 5, seatsNeeded: 1);
      for (final (error, said, code) in [
        (full, l10n.orchardRecordFull, ErrorCodes.teamRecordFull),
        (large, l10n.orchardRecordEntryTooLarge, ErrorCodes.teamRecordEntryTooLarge),
        (vaults, l10n.orchardVaultsFull, ErrorCodes.teamVaultsFull),
      ]) {
        final expected = ErrorCodes.withCode(said, code);
        expect(orchardErrorMessage(error, l10n), expected);
        expect(orchardChangeErrorMessage(error, l10n), expected);
        expect(inviteErrorMessage(error, l10n), expected);
        expect(accessErrorMessage(error, l10n), expected);
        expect(seatPurchaseProblem(error, l10n), expected);
        expect(said, anyOf(contains('seats'), contains('smaller')));
        expect(said, contains('support'));
      }
      expect(orchardErrorMessage(const OrchardServerException(413, 'session-logs-team-full'), l10n), l10n.orchardSessionLogsFullBody);
      expect(l10n.orchardSessionLogsFullBody, contains('Connecting to hosts is not affected'));
    });

    test('and from the wire: the reason reaches the words', () async {
      final api = OrchardsApi(
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'token',
        client: MockClient((_) async => http.Response(
            jsonEncode({'code': 'seats-needed', 'reason': 'storage', 'seats': 5, 'used': 5, 'needed': 1, 'error': 'x'}), 409)),
      );
      await expectLater(
          api.write('crate', const [], keyVersion: 1),
          throwsA(isA<OrchardServerException>()
              .having((e) => e.reason, 'reason', 'storage')
              .having((e) => orchardErrorMessage(e, l10n), 'words', ErrorCodes.withCode(l10n.orchardVaultsFull, ErrorCodes.teamVaultsFull))));
    });

    test('every language says them', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final t = lookupAppLocalizations(locale);
        expect(t.orchardVaultsFullBanner('Acme'), contains('Acme'), reason: '$locale');
        expect(t.orchardSessionLogsFullTitle('Acme'), contains('Acme'), reason: '$locale');
        if (locale.languageCode != 'en') {
          for (final (mine, english) in [
            (t.orchardRecordFull, l10n.orchardRecordFull),
            (t.orchardRecordEntryTooLarge, l10n.orchardRecordEntryTooLarge),
            (t.orchardVaultsFull, l10n.orchardVaultsFull),
            (t.orchardSessionLogsFullBody, l10n.orchardSessionLogsFullBody),
            (t.teamServicesOn, l10n.teamServicesOn),
            (t.teamServicesGraceNoDate, l10n.teamServicesGraceNoDate),
            (t.trgPatternRefused, l10n.trgPatternRefused),
          ]) {
            expect(mine, isNot(english), reason: '$locale');
          }
        }
      }
    });
  });

  group('the billing answer', () {
    test('is read as sent', () {
      final b = OrchardBilling.fromJson(_answer(bought: 7, included: 1, used: 9));
      expect(b.seats.bought, 7);
      expect(b.seats.included, 1);
      expect(b.seats.total, 8);
      expect(b.seats.used, 9);
      expect(b.seats.free, 0);
      expect(b.seats.over, isTrue);
      expect(b.services.state, BusinessServicesState.active);
      expect(b.services.yearly, isTrue);
      expect(b.services.quantity, 8);
      expect(b.services.paidThrough, DateTime.utc(2027, 1, 15, 12));
      expect(b.services.worksUntil, DateTime.utc(2027, 1, 29, 12));
      expect(b.services.endsAtPeriodEnd, isFalse);
      expect(b.seatPriceCents, 7500);
    });

    test('the website\'s page for a team, ready to buy what an invitation needs', () {
      expect(orchardSeatsPage(_orchard).toString(), 'https://zestssh.com/teams/seats?orchard=$_orchard');
      expect(orchardSeatsPage(_orchard, need: 3).toString(), 'https://zestssh.com/teams/seats?orchard=$_orchard&need=3');
      expect(orchardSeatsPage(_orchard, need: 0), orchardSeatsPage(_orchard));
      // A WEBSITE_URL a build names with a slash at its end makes no `//` page
      // (found in a UI review).
      expect(websiteBaseOf('https://staging.example/'), 'https://staging.example');
      expect(websiteBaseOf('http://localhost:8788//'), 'http://localhost:8788');
      expect(websiteBaseOf('https://zestssh.com'), 'https://zestssh.com');
      expect(orchardShortId(_orchard), '0f0e0d0c');
      expect(orchardShortId('abc'), 'abc');
    });

    test('anything it cannot read is refused or off, never assumed', () {
      expect(() => OrchardBilling.fromJson(const {}), throwsFormatException);
      expect(() => OrchardBilling.fromJson({'seats': {'bought': -1, 'included': 0, 'total': 0, 'used': 0, 'free': 0}}),
          throwsFormatException);
      final b = OrchardBilling.fromJson({
        'seats': {'bought': 1, 'included': 0, 'total': 1, 'used': 1, 'free': 0},
        'business_services': 'nonsense',
      });
      expect(b.services.state, BusinessServicesState.off);
      expect(b.services.yearly, isNull);
      expect(b.seats.over, isFalse);
      // No prices sent: the words fall back to the prices of 22 October
      // 2026 (a seat of 100 dollars once, Business 20 a month or 200 a year).
      expect(b.seatPriceCents, kSeatPriceCents);
      expect(b.seatPriceCents, 10000);
      expect((b.servicesMonthCents, b.servicesYearCents), (1500, 15000));
      expect(BusinessServicesState.parse('grace'), BusinessServicesState.grace);
      expect(BusinessServicesState.parse('lapsed'), BusinessServicesState.off);
    });

    test('the server\'s refusals come back as they are', () async {
      final api = OrchardBillingApi(
        client: MockClient((_) async => http.Response(
            jsonEncode({'error': 'x', 'code': 'rules-unmet', 'unmet': ['sso']}), 403)),
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'token-1',
      );
      await expectLater(
          api.get(_orchard),
          throwsA(isA<OrchardServerException>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e.code, 'code', 'rules-unmet')
              .having((e) => e.unmet, 'unmet', ['sso'])));
      final signedOut = OrchardBillingApi(client: MockClient((_) async => http.Response('{}', 200)), bearer: () async => null);
      await expectLater(signedOut.get(_orchard), throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'signed-out')));
    });
  });
}
