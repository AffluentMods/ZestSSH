import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/billing/seat_purchase_watch.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/features/orchards/team/team_seats_sheet.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart' show passkeyStepUpProvider;
import 'package:zestssh/utils/redactor.dart';

/// Buying seats from inside ZestSSH on a computer.
/// The numbers keep to the website's page and the server: a team starts
/// at 2 seats, holds up to 25 without Business, 250 at a time, 1,000 in all. A
/// card payment, a subscription and billing open Stripe's own pages in the
/// browser: no card is typed here, and only Stripe's pages are ever opened.
/// Coming back to the app reads the seats again. The sheet never speaks of
/// giving money back.

const _team = '0f0e0d0c-0b0a-4908-8706-050403020100';
const _owner = OrchardSummary(id: _team, name: 'Acme', role: FixedRoles.owner, crates: [], defaultCrateId: null);

const _checkoutUrl = 'https://checkout.stripe.com/c/pay/cs_test_acme';
const _portalUrl = 'https://billing.stripe.com/p/session/test_acme';
const _invoiceUrl = 'https://invoice.stripe.com/i/acct_test/test_acme';

Map<String, Object?> _prices = const {
  'seat_cents': 10000,
  'services_month_cents': 1500,
  'services_year_cents': 15000,
  'max_per_purchase': 250,
  'max_seats': 1000,
  'team_min_seats': 2,
  'team_max_seats': 25,
};

/// The billing route's answer.
Map<String, Object?> _answer({
  int bought = 5,
  int included = 0,
  int used = 3,
  Map<String, Object?>? services,
  List<Map<String, Object?>> held = const [],
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
    'business_services': services ?? {'state': 'off', 'status': null, 'interval': null, 'quantity': null},
    'prices': _prices,
    'is_owner': true,
    'held': held,
  };
}

const _soon = '2030-11-21T12:00:00.000Z';
Map<String, Object?> _heldBy(String kind, int seats) => {'seats': seats, 'kind': kind, 'until': _soon};

OrchardBilling _billing({int bought = 5, int included = 0, int used = 3, Map<String, Object?>? services}) =>
    OrchardBilling.fromJson(_answer(bought: bought, included: included, used: used, services: services));

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('how many seats may be bought, as the website and the server count it', () {
    test('a first purchase: a team starts at 2, and may go to 25', () {
      final b = _billing(bought: 0, used: 1);
      expect((b.seatsMinimum, b.seatsMaximum), (2, 25));
      expect(b.seatsSuggested(null), 2);
    });

    test('an owner\'s Bundle seat counts towards the two', () {
      final b = _billing(bought: 0, included: 1, used: 1);
      expect((b.seatsMinimum, b.seatsMaximum), (1, 24));
    });

    test('what an invitation said it needs, and enough for everyone here, with a team\'s first two at least', () {
      expect(_billing(bought: 5, used: 5).seatsSuggested(3), 3);
      expect(_billing(bought: 2, used: 7).seatsSuggested(null), 5);
      expect(_billing(bought: 2, used: 7).seatsNeeded(null), 5);
      expect(_billing(bought: 2, used: 7).seatsSuggested(9), 9);
      expect(_billing(bought: 0, used: 1).seatsSuggested(1), 2);
      expect(_billing(bought: 5, used: 3).seatsSuggested(null), 1);
      expect(_billing(bought: 5, used: 3).seatsNeeded(null), lessThanOrEqualTo(0));
    });

    test('never more than a team may hold: at 25 without Business there is no room', () {
      expect(_billing(bought: 24, used: 3).seatsMaximum, 1);
      expect(_billing(bought: 25, used: 3).seatsMaximum, 0);
      expect(_billing(bought: 24, used: 30).seatsSuggested(null), 1);
    });

    test('with Business, in its grace too: 250 at a time, and 1,000 in all', () {
      final on = {'state': 'active', 'status': 'active', 'interval': 'year', 'quantity': 30};
      expect(_billing(bought: 30, services: on).seatsMaximum, 250);
      expect(_billing(bought: 900, services: on).seatsMaximum, 100);
      expect(_billing(bought: 1000, services: on).seatsMaximum, 0);
      final grace = {'state': 'grace', 'status': 'past_due', 'interval': 'year', 'quantity': 30};
      expect(_billing(bought: 30, services: grace).seatsMaximum, 250);
    });

    test('a server from before it sent the limits: the same numbers', () {
      final b = OrchardBilling.fromJson({
        'seats': {'bought': 0, 'included': 0, 'total': 0, 'used': 1, 'free': 0, 'over': true},
      });
      expect((b.seatsMinimum, b.seatsMaximum, b.seatPriceCents), (2, 25, 10000));
    });

    test('a subscription that is not over is managed, never started again', () {
      expect(_billing(services: {'state': 'active', 'status': 'active'}).services.notOver, isTrue);
      expect(_billing(services: {'state': 'grace', 'status': 'past_due'}).services.notOver, isTrue);
      expect(_billing(services: {'state': 'off', 'status': 'canceled'}).services.notOver, isFalse);
      expect(_billing(services: {'state': 'off', 'status': 'incomplete_expired'}).services.notOver, isFalse);
      expect(_billing(services: {'state': 'active', 'status': null}).services.notOver, isFalse, reason: 'free months');
    });
  });

  group('the API', () {
    late List<http.Request> sent;
    OrchardBillingApi api(Object answer, {int status = 201}) {
      sent = [];
      return OrchardBillingApi(
        client: MockClient((r) async {
          sent.add(r);
          return http.Response(jsonEncode(answer), status);
        }),
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'token-1',
      );
    }

    test('a checkout asks for the seats, and gives Stripe\'s page', () async {
      final page = await api({'url': _checkoutUrl}).buySeats(_team, 3);
      expect(page, Uri.parse(_checkoutUrl));
      expect(sent.single.url.toString(), 'https://api.test/v1/orchards/$_team/billing/seats');
      expect(jsonDecode(sent.single.body), {'quantity': 3});
      expect(sent.single.headers['Authorization'], 'Bearer token-1');
    });

    test('a page that is not Stripe\'s is never handed on', () async {
      for (final url in [
        'https://evil.example/checkout.stripe.com/',
        'http://checkout.stripe.com/c/pay',
        'https://checkout.stripe.com.evil.example/',
        'https://invoice.stripe.com/i/x',
        'javascript:alert(1)',
        null,
      ]) {
        await expectLater(api({'url': url}).buySeats(_team, 3),
            throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'not-stripe')), reason: '$url');
      }
    });

    test('an invoice takes the address and the number where given; its page only where it is Stripe\'s', () async {
      final sentOne = await api({'url': _invoiceUrl, 'number': 'INV-0042', 'sent_to': 'billing@example.com'})
          .sendSeatInvoice(_team, 4, email: 'billing@example.com', po: 'PO 1234');
      expect(sent.single.url.path, '/v1/orchards/$_team/billing/invoice');
      expect(jsonDecode(sent.single.body), {'quantity': 4, 'email': 'billing@example.com', 'po_number': 'PO 1234'});
      expect((sentOne.number, sentOne.sentTo, sentOne.page), ('INV-0042', 'billing@example.com', Uri.parse(_invoiceUrl)));

      final plain = await api({'url': 'https://evil.example/i', 'number': 'INV-1', 'sent_to': 'owner@example.com'})
          .sendSeatInvoice(_team, 1);
      expect(jsonDecode(sent.single.body), {'quantity': 1});
      expect(plain.page, isNull);
    });

    test('Business by the year or the month, and billing, each Stripe\'s page', () async {
      expect(await api({'url': _checkoutUrl}).subscribeBusiness(_team, yearly: true), Uri.parse(_checkoutUrl));
      expect(jsonDecode(sent.single.body), {'interval': 'year'});
      await api({'url': _checkoutUrl}).subscribeBusiness(_team, yearly: false);
      expect(jsonDecode(sent.single.body), {'interval': 'month'});
      expect(await api({'url': _portalUrl}).billingPortal(_team), Uri.parse(_portalUrl));
      expect(sent.single.url.path, '/v1/orchards/$_team/billing/portal');
    });

    test('a refusal comes back with what it says', () async {
      final waiting = api({
        'code': 'seats-waiting',
        'waiting': 3,
        'can_buy': 2,
        'waiting_kind': 'invoice',
        'waiting_until': '2026-12-01T12:00:00.000Z',
      }, status: 409);
      await expectLater(
          waiting.buySeats(_team, 9),
          throwsA(isA<SeatPurchaseRefused>()
              .having((e) => e.code, 'code', 'seats-waiting')
              .having((e) => e.waiting, 'waiting', 3)
              .having((e) => e.canBuy, 'canBuy', 2)
              .having((e) => e.waitingOnInvoice, 'invoice', true)
              .having((e) => e.waitingUntil, 'until', DateTime.utc(2026, 12, 1, 12))));
      await expectLater(
          api({'code': 'seats-minimum', 'minimum': 2}, status: 409).buySeats(_team, 1),
          throwsA(isA<SeatPurchaseRefused>().having((e) => e.minimum, 'minimum', 2)));
      await expectLater(
          api({'code': 'business-needed-for-seats', 'maximum': 25}, status: 409).buySeats(_team, 30),
          throwsA(isA<SeatPurchaseRefused>().having((e) => e.maximum, 'maximum', 25)));
    });

    test('signed out: nothing is sent', () async {
      final none = OrchardBillingApi(
        client: MockClient((r) async => fail('nothing is sent signed out')),
        baseUrl: 'https://api.test/v1',
        bearer: () async => null,
      );
      await expectLater(none.buySeats(_team, 1), throwsA(isA<OrchardServerException>().having((e) => e.status, 'status', 401)));
    });
  });

  group('what a refusal says', () {
    String said(Object e) => seatPurchaseProblem(e, l10n);
    test('each in words, what to do next', () {
      expect(said(const SeatPurchaseRefused(409, 'seats-minimum', minimum: 2)), l10n.seatsSheetAtLeast(2, 2));
      expect(said(const SeatPurchaseRefused(409, 'business-needed-for-seats', maximum: 25)), l10n.seatsSheetNeedsBusiness(25));
      expect(said(const SeatPurchaseRefused(409, 'seats-maximum')), l10n.seatsSheetTooMany);
      expect(said(const OrchardServerException(403, 'owners-only')), l10n.teamSeatsAskOwner);
      expect(said(const OrchardServerException(409, 'seats-first')), l10n.seatsSheetSeatsFirst(2));
      expect(said(const OrchardServerException(409, 'business-services-exists')), l10n.seatsSheetBusinessExists);
      expect(said(const OrchardServerException(409, 'no-billing')), l10n.seatsSheetNoBilling);
      expect(said(const OrchardServerException(503, 'billing-unavailable')), l10n.seatsSheetUnavailable);
      expect(said(const OrchardServerException(400, 'invoice-address')), l10n.seatsSheetInvoiceAddress);
      expect(said(const OrchardServerException(409, 'invoice-open')), l10n.seatsSheetInvoiceOpen);
      expect(said(const OrchardServerException(502, 'not-stripe')), l10n.seatsSheetNotStripe);
    });

    test('another purchase holds seats: whose, until when, and how many may be bought', () async {
      await initializeDateFormatting('en');
      expect(said(const SeatPurchaseRefused(409, 'seats-waiting', waiting: 3, canBuy: 2)),
          '${l10n.seatsSheetWaitingCheckout(3)} ${l10n.seatsSheetCanBuy(2)}');
      expect(said(const SeatPurchaseRefused(409, 'seats-waiting', waiting: 3, canBuy: 0)),
          '${l10n.seatsSheetWaitingCheckout(3)} ${l10n.seatsSheetCanBuyNone}');
      final until = DateTime(2026, 12, 1, 12);
      expect(said(SeatPurchaseRefused(409, 'seats-waiting', waiting: 1, canBuy: 2, waitingOnInvoice: true, waitingUntil: until)),
          '${l10n.seatsSheetWaitingInvoiceDue(1, DateFormat.yMMMd('en').format(until))} ${l10n.seatsSheetCanBuy(2)}');
    });

    test('ZestSSH Cloud down is said as that, with its code', () {
      expect(said(const SocketException('no route to host')), '${l10n.cloudNotResponding} (ZS-1101)');
    });
  });

  group('the sheet', () {
    late List<http.Request> requests;
    late List<Uri> opened;
    late List<Object> answers;
    late int arrivedCalls;
    late int signIns;

    /// Shows the sheet of [_owner], ZestSSH Cloud answering GET with [billing]
    /// in turn (a Map is the answer, an Exception thrown) and POST with
    /// [posts] by the route's last word. [need]: what an invitation needs.
    Future<ProviderContainer> show(
      WidgetTester tester, {
      List<Object>? billing,
      Map<String, Object> posts = const {},
      int? need,
      bool here = true,
      bool recording = false,
      String? email = 'owner@example.com',
      Future<void> Function(Uri page)? open,
      Size size = const Size(1200, 1000),
      Future<void>? postsWait,
    }) async {
      requests = [];
      opened = [];
      answers = billing ?? [_answer()];
      arrivedCalls = 0;
      signIns = 0;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var n = 0;
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          final a = answers[n < answers.length ? n++ : answers.length - 1];
          if (a is Exception) throw a;
          return http.Response(jsonEncode(a), 200);
        }
        if (postsWait != null) await postsWait;
        // A list is answered from in turn.
        final kept = posts[request.url.pathSegments.last];
        final a = kept is List ? kept.removeAt(0) as Object : kept;
        if (a == null) return http.Response(jsonEncode({'code': 'no-answer'}), 500);
        if (a is Exception) throw a;
        final (status, body) = a as (int, Map<String, Object?>);
        return http.Response(jsonEncode(body), status);
      });
      late ProviderContainer container;
      await tester.pumpWidget(ProviderScope(overrides: [
        orchardBillingApiProvider
            .overrideWithValue(OrchardBillingApi(client: client, baseUrl: 'https://api.test/v1', bearer: () async => 'token-1')),
        billingOnThisDeviceProvider.overrideWithValue(here),
        seatsPageOpenerProvider.overrideWithValue(open ?? (page) async => opened.add(page)),
        seatsArrivedProvider.overrideWithValue(() => arrivedCalls++),
        orchardSummariesProvider.overrideWith((ref) async => const [_owner]),
        currentUserProvider.overrideWithValue(email == null ? null : UserProfile(uid: 'owner-1', email: email)),
        recordingModeProvider.overrideWith((ref) => recording),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        signInRefresherProvider.overrideWithValue((context, ref, {wrongAccount}) async {
          signIns++;
          return true;
        }),
        passkeyStepUpProvider.overrideWithValue(null),
      ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context, listen: false);
                return TextButton(
                  onPressed: () => openSeatsSheet(context, ref, _team, need: need),
                  child: const Text('open'),
                );
              },
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return container;
    }

    Finder k(String key) => find.byKey(ValueKey(key));

    /// Every word on screen.
    String words(WidgetTester tester) => [
          for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? '',
          for (final t in tester.widgetList<SelectableText>(find.byType(SelectableText))) t.data ?? '',
        ].join('\n');

    Future<void> tapIt(WidgetTester tester, String key) async {
      await tester.ensureVisible(k(key));
      await tester.pumpAndSettle();
      await tester.tap(k(key));
      await tester.pumpAndSettle();
    }

    Future<void> cameBack(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
    }

    testWidgets('says the price and the limits, as the website does, and how many a first purchase takes', (tester) async {
      await show(tester, billing: [_answer(bought: 0, used: 1)]);
      expect(find.text(l10n.seatsSheetPrice(r'$100', '2', '25')), findsOneWidget);
      // Business past 25 seats with no upper number, as the website has it
      // now (it said "up to 1,000").
      expect(find.textContaining('1,000'), findsNothing);
      expect(find.text(r'$100 per seat, once. A team is for 2 to 25 seats; Business goes past 25.'), findsOneWidget);
      expect(find.text(l10n.seatsSheetTotal(2, r'$200')), findsOneWidget);
      expect(find.text(l10n.seatsSheetLeast(2)), findsOneWidget);
      expect(find.text(l10n.seatsSheetMost(25)), findsOneWidget);
      // Every word about money on it: no card fields, and nothing about money back.
      final all = words(tester).toLowerCase();
      expect(all, isNot(contains('refund')));
      expect(all, isNot(contains('money back')));
      expect(all, isNot(contains('cvc')));
      expect(all, isNot(contains('card number')));
    });

    testWidgets('the stepper: minus and plus stop at the least and the most, a number typed is held to them', (tester) async {
      await show(tester, billing: [_answer(bought: 23, used: 3)]);
      expect(find.text(l10n.seatsSheetTotal(1, r'$100')), findsOneWidget);
      // At the least.
      expect(tester.widget<IconButton>(k('seats-sheet-minus')).onPressed, isNull);
      await tapIt(tester, 'seats-sheet-plus');
      expect(find.text(l10n.seatsSheetTotal(2, r'$200')), findsOneWidget);
      // At the most: 25 in all, and 23 are there.
      expect(tester.widget<IconButton>(k('seats-sheet-plus')).onPressed, isNull);
      await tester.enterText(k('seats-sheet-count'), '40');
      await tester.pump();
      expect(find.text(l10n.seatsSheetTotal(2, r'$200')), findsOneWidget);
      await tester.enterText(k('seats-sheet-count'), '1');
      await tester.pump();
      expect(find.text(l10n.seatsSheetTotal(1, r'$100')), findsOneWidget);
      await tapIt(tester, 'seats-sheet-most');
      expect(find.text(l10n.seatsSheetTotal(2, r'$200')), findsOneWidget);
    });

    testWidgets('what an invitation needs is said, and ready to buy', (tester) async {
      await show(tester, need: 3, billing: [_answer(bought: 5, used: 5)]);
      expect(find.text(l10n.seatsSheetNeed(3)), findsOneWidget);
      expect(find.text(l10n.seatsSheetTotal(3, r'$300')), findsOneWidget);
      expect(find.text(l10n.seatsSheetNeeded(3)), findsOneWidget);
      await tapIt(tester, 'seats-sheet-least');
      expect(find.text(l10n.seatsSheetTotal(1, r'$100')), findsOneWidget);
      await tapIt(tester, 'seats-sheet-needed');
      expect(find.text(l10n.seatsSheetTotal(3, r'$300')), findsOneWidget);
    });

    testWidgets('a team at 25 seats without Business: says add Business, and offers no way to pay', (tester) async {
      await show(tester, billing: [_answer(bought: 25, used: 20)]);
      expect(find.text(l10n.seatsSheetNeedsBusiness(25)), findsOneWidget);
      expect(k('seats-sheet-card'), findsNothing);
      expect(k('seats-sheet-subscribe'), findsOneWidget);
    });

    testWidgets('Pay by card: the seats asked for, Stripe\'s page in the browser, the hold of 31 minutes said', (tester) async {
      final container = await show(tester, posts: {
        'seats': (201, {'url': _checkoutUrl})
      });
      expect(find.text(l10n.seatsSheetHoldNote(31)), findsOneWidget);
      await tapIt(tester, 'seats-sheet-plus');
      await tapIt(tester, 'seats-sheet-card');
      final post = requests.lastWhere((r) => r.method == 'POST');
      expect(post.url.path, '/v1/orchards/$_team/billing/seats');
      expect(jsonDecode(post.body), {'quantity': 2});
      expect(opened, [Uri.parse(_checkoutUrl)]);
      expect(find.text(l10n.seatsSheetWaitingTitle), findsOneWidget);
      expect(find.text('${l10n.seatsSheetHeld(2, 31)} ${l10n.seatsSheetComeBack}'), findsOneWidget);
      // In view, though the button that led to it is further down.
      expect(tester.getTopLeft(k('seats-sheet-waiting')).dy, greaterThanOrEqualTo(0));
      expect(tester.getTopLeft(k('seats-sheet-waiting')).dy, lessThan(tester.view.physicalSize.height));
      // Opened again, and it is still there when the sheet comes back.
      await tapIt(tester, 'seats-sheet-open-again');
      expect(opened, hasLength(2));
      expect(container.read(billingWaitingProvider(_team)).single.quantity, 2);
    });

    testWidgets('coming back reads the seats, and again a few times shortly after; once they come: said, and what waited is sent',
        (tester) async {
      await show(
        tester,
        billing: [_answer(bought: 5), _answer(bought: 5), _answer(bought: 5), _answer(bought: 5), _answer(bought: 7)],
        posts: {
          'seats': (201, {'url': _checkoutUrl})
        },
      );
      await tapIt(tester, 'seats-sheet-plus');
      await tapIt(tester, 'seats-sheet-card');
      final reads = requests.where((r) => r.method == 'GET').length;
      await cameBack(tester);
      expect(requests.where((r) => r.method == 'GET').length, reads + 1, reason: 'at once');
      await tester.pump(const Duration(milliseconds: 2500));
      expect(requests.where((r) => r.method == 'GET').length, reads + 2, reason: '2.5 seconds on');
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text(l10n.seatsSheetArrived(2)), findsOneWidget);
      expect(find.text(l10n.seatsSheetWaitingTitle), findsNothing);
      expect(arrivedCalls, 1);
      expect(find.text(l10n.teamSeatsInUse(3, 7)), findsNothing, reason: 'said with its open count');
      expect(find.textContaining(l10n.teamSeatsInUse(3, 7)), findsOneWidget);
      // Nothing more is asked once it came.
      final after = requests.length;
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(requests.length, after);
    });

    testWidgets('Check now finds nothing yet: said, with the page still there to pay on', (tester) async {
      await show(tester, posts: {
        'seats': (201, {'url': _checkoutUrl})
      });
      await tapIt(tester, 'seats-sheet-card');
      await tapIt(tester, 'seats-sheet-check');
      expect(find.text(l10n.seatsSheetNotYet), findsOneWidget);
      expect(find.text(l10n.seatsSheetWaitingTitle), findsOneWidget);
    });

    group('seats that came another way are not the payment', () {
      testWidgets('fewer than were paid for: the figures show them, and the wait goes on with no word of a payment', (tester) async {
        await show(tester, billing: [_answer(bought: 5), _answer(bought: 5), _answer(bought: 6)], posts: {
          'seats': (201, {'url': _checkoutUrl})
        });
        await tapIt(tester, 'seats-sheet-plus');
        await tapIt(tester, 'seats-sheet-card');
        await tapIt(tester, 'seats-sheet-check');
        expect(find.text(l10n.seatsSheetArrived(1)), findsNothing);
        expect(k('seats-sheet-arrived'), findsNothing);
        expect(find.text(l10n.seatsSheetWaitingTitle), findsOneWidget);
        expect(find.textContaining(l10n.teamSeatsInUse(3, 6)), findsOneWidget);
        expect(arrivedCalls, 0);
      });

      testWidgets('as many as were paid for, while the checkout still holds its own: the same', (tester) async {
        await show(tester, billing: [_answer(bought: 5), _answer(bought: 5), _answer(bought: 7, held: [_heldBy('checkout', 2)])], posts: {
          'seats': (201, {'url': _checkoutUrl})
        });
        await tapIt(tester, 'seats-sheet-plus');
        await tapIt(tester, 'seats-sheet-card');
        await tapIt(tester, 'seats-sheet-check');
        expect(k('seats-sheet-arrived'), findsNothing);
        expect(find.text(l10n.seatsSheetWaitingTitle), findsOneWidget);
        expect(find.textContaining(l10n.teamSeatsInUse(3, 7)), findsOneWidget);
      });

      testWidgets('then the payment too: what was paid for is said, not all that rose', (tester) async {
        await show(
          tester,
          billing: [_answer(bought: 5), _answer(bought: 5), _answer(bought: 6), _answer(bought: 8)],
          posts: {
            'seats': (201, {'url': _checkoutUrl})
          },
        );
        await tapIt(tester, 'seats-sheet-plus');
        await tapIt(tester, 'seats-sheet-card');
        await tapIt(tester, 'seats-sheet-check');
        expect(k('seats-sheet-arrived'), findsNothing);
        await tapIt(tester, 'seats-sheet-check');
        expect(find.text(l10n.seatsSheetArrived(2)), findsOneWidget);
        expect(find.text(l10n.seatsSheetArrived(3)), findsNothing);
      });

      testWidgets('with the sheet closed: no notice of a payment either', (tester) async {
        final container = await show(tester, billing: [_answer(bought: 5), _answer(bought: 5), _answer(bought: 6)], posts: {
          'seats': (201, {'url': _checkoutUrl})
        });
        await tapIt(tester, 'seats-sheet-plus');
        await tapIt(tester, 'seats-sheet-card');
        await tester.tap(find.text(l10n.close).last);
        await tester.pumpAndSettle();
        await cameBack(tester);
        await tester.pumpAndSettle();
        expect(container.read(notificationCenterProvider).history, isEmpty);
        expect(container.read(billingWaitingProvider(_team)), hasLength(1));
        await tester.pump(kBillingWaitLimit);
      });
    });

    group('what holds seats is said before paying for them again', () {
      testWidgets('an invoice waiting: said above the buttons, and Pay by card asks first, naming it', (tester) async {
        await show(tester, billing: [_answer(bought: 5, held: [_heldBy('invoice', 4)])], posts: {
          'seats': (201, {'url': _checkoutUrl})
        });
        final due = DateFormat.yMMMd('en').format(DateTime.parse(_soon).toLocal());
        expect(find.text(l10n.seatsSheetHeldByInvoice(4, due)), findsOneWidget);
        expect(tester.getTopLeft(k('seats-sheet-held-invoice')).dy, lessThan(tester.getTopLeft(k('seats-sheet-card')).dy));
        await tapIt(tester, 'seats-sheet-card');
        expect(find.text(l10n.seatsSheetCardWithInvoiceTitle), findsOneWidget);
        final body = l10n.seatsSheetCardWithInvoiceBody(4, due);
        expect(find.text(body), findsOneWidget);
        expect(body.toLowerCase(), isNot(contains('refund')));
        // Not yet.
        await tester.tap(find.text(l10n.cancel).last);
        await tester.pumpAndSettle();
        expect(requests.where((r) => r.method == 'POST'), isEmpty);
        expect(opened, isEmpty);
        // Now as well.
        await tapIt(tester, 'seats-sheet-card');
        await tester.tap(find.text(l10n.seatsSheetPayCard).last);
        await tester.pumpAndSettle();
        expect(requests.where((r) => r.method == 'POST'), hasLength(1));
        expect(opened, [Uri.parse(_checkoutUrl)]);
      });

      testWidgets('nothing waiting: nothing to ask', (tester) async {
        await show(tester, posts: {
          'seats': (201, {'url': _checkoutUrl})
        });
        expect(k('seats-sheet-held-invoice'), findsNothing);
        expect(k('seats-sheet-held-checkout'), findsNothing);
        await tapIt(tester, 'seats-sheet-card');
        expect(find.text(l10n.seatsSheetCardWithInvoiceTitle), findsNothing);
        expect(opened, hasLength(1));
      });

      testWidgets('a checkout open elsewhere: said, and no question: a new one lets it lapse', (tester) async {
        await show(tester, billing: [_answer(bought: 5, held: [_heldBy('checkout', 3)])], posts: {
          'seats': (201, {'url': _checkoutUrl})
        });
        expect(k('seats-sheet-held-checkout'), findsOneWidget);
        await tapIt(tester, 'seats-sheet-card');
        expect(find.text(l10n.seatsSheetCardWithInvoiceTitle), findsNothing);
        expect(opened, hasLength(1));
        // This device's own says so in its panel.
        expect(k('seats-sheet-held-checkout'), findsNothing);
      });

      testWidgets('an invoice just sent: said there from then on', (tester) async {
        await show(tester, billing: [_answer(bought: 5), _answer(bought: 5, held: [_heldBy('invoice', 2)])], posts: {
          'invoice': (201, {'number': 'INV-1', 'url': _invoiceUrl, 'sent_to': 'owner@example.com'})
        });
        await tapIt(tester, 'seats-sheet-invoice');
        await tapIt(tester, 'seats-sheet-invoice-send');
        expect(k('seats-sheet-held-invoice'), findsOneWidget);
      });

      test('what the server sends is read; an older server sends nothing, and nothing is said', () {
        final b = OrchardBilling.fromJson(jsonDecode(jsonEncode(_answer(held: [_heldBy('invoice', 4), _heldBy('checkout', 2)]))) as Map<String, dynamic>);
        expect([for (final h in b.held) (h.seats, h.invoice)], [(4, true), (2, false)]);
        expect(b.held.first.until, DateTime.parse(_soon));
        expect(_billing().held, isEmpty);
        expect(OrchardBilling.fromJson({...jsonDecode(jsonEncode(_answer())) as Map<String, dynamic>}..remove('held')).held, isEmpty);
      });
    });

    group('Business said on only for a subscription that is going', () {
      for (final (name, services) in <(String, Map<String, Object?>)>[
        ('in the grace of one that is over', {'state': 'grace', 'status': 'canceled', 'interval': 'year', 'quantity': 3}),
        ('during free months from a code', {'state': 'active', 'status': null, 'interval': null, 'quantity': null, 'comped_until': '2030-01-20T00:00:00.000Z'}),
      ]) {
        testWidgets('$name: Subscribe, nothing paid, come back: nothing said, and the page still waits', (tester) async {
          await show(tester, billing: [_answer(bought: 3, used: 2, services: services)], posts: {
            'services': (201, {'url': _checkoutUrl})
          });
          await tapIt(tester, 'seats-sheet-subscribe');
          await tapIt(tester, 'seats-sheet-check');
          expect(find.text(l10n.seatsSheetBusinessArrived), findsNothing);
          expect(find.text(l10n.seatsSheetNotYet), findsOneWidget);
          expect(find.text(l10n.seatsSheetWaitingTitle), findsOneWidget);
        });

        testWidgets('$name: paid, the same: said then', (tester) async {
          await show(tester, billing: [
            _answer(bought: 3, used: 2, services: services),
            _answer(bought: 3, used: 2, services: {'state': 'active', 'status': 'active', 'interval': 'year', 'quantity': 3}),
          ], posts: {
            'services': (201, {'url': _checkoutUrl})
          });
          await tapIt(tester, 'seats-sheet-subscribe');
          await tapIt(tester, 'seats-sheet-check');
          expect(find.text(l10n.seatsSheetBusinessArrived), findsOneWidget);
        });
      }
    });

    group('a card page and an invoice for the same seats', () {
      testWidgets('an invoice sent with a card page open: the page is no longer waited for, and the invoice is what is said', (tester) async {
        final container = await show(tester, billing: [
          _answer(bought: 5),
          _answer(bought: 5),
          _answer(bought: 5, held: [_heldBy('checkout', 1)]),
          _answer(bought: 5, held: [_heldBy('invoice', 1)]),
        ], posts: {
          'seats': (201, {'url': _checkoutUrl}),
          'invoice': (201, {'url': _invoiceUrl, 'number': 'INV-1', 'sent_to': 'owner@example.com'}),
        });
        await tapIt(tester, 'seats-sheet-card');
        expect(k('seats-sheet-waiting'), findsOneWidget);
        await tapIt(tester, 'seats-sheet-invoice');
        await tapIt(tester, 'seats-sheet-invoice-send');
        expect(k('seats-sheet-invoice-sent'), findsOneWidget);
        expect(k('seats-sheet-waiting'), findsNothing);
        expect(k('seats-sheet-open-again'), findsNothing);
        expect(container.read(billingWaitingProvider(_team)), isEmpty);
      });

      testWidgets('it could not be sent: the page still waits', (tester) async {
        await show(tester, posts: {
          'seats': (201, {'url': _checkoutUrl}),
          'invoice': (409, {'code': 'invoice-open'}),
        });
        await tapIt(tester, 'seats-sheet-card');
        await tapIt(tester, 'seats-sheet-invoice');
        await tapIt(tester, 'seats-sheet-invoice-send');
        expect(k('seats-sheet-waiting'), findsOneWidget);
        expect(find.text(l10n.seatsSheetInvoiceOpen), findsOneWidget);
      });

      testWidgets('an invoice sent from elsewhere since this read the seats: read before the card, and asked', (tester) async {
        await show(tester, billing: [
          _answer(bought: 5),
          _answer(bought: 5, held: [_heldBy('invoice', 4)]),
        ], posts: {
          'seats': (201, {'url': _checkoutUrl})
        });
        expect(k('seats-sheet-held-invoice'), findsNothing, reason: 'not known yet');
        final reads = requests.where((r) => r.method == 'GET').length;
        await tapIt(tester, 'seats-sheet-card');
        expect(requests.where((r) => r.method == 'GET').length, greaterThan(reads));
        expect(find.text(l10n.seatsSheetCardWithInvoiceTitle), findsOneWidget);
        expect(requests.where((r) => r.method == 'POST'), isEmpty);
        await tester.tap(find.text(l10n.cancel).last);
        await tester.pumpAndSettle();
        expect(opened, isEmpty);
        expect(k('seats-sheet-held-invoice'), findsOneWidget, reason: 'said on the sheet from then on');
      });

      testWidgets('the seats counted are those of that read', (tester) async {
        await show(tester, billing: [
          _answer(bought: 5),
          _answer(bought: 6),
          _answer(bought: 6),
        ], posts: {
          'seats': (201, {'url': _checkoutUrl})
        });
        await tapIt(tester, 'seats-sheet-card');
        await tapIt(tester, 'seats-sheet-check');
        expect(k('seats-sheet-arrived'), findsNothing, reason: 'a code before the page opened is not the payment');
      });

      testWidgets('ZestSSH Cloud down at that read: said, and nothing is bought', (tester) async {
        await show(tester, billing: [_answer(bought: 5), const SocketException('down')], posts: {
          'seats': (201, {'url': _checkoutUrl})
        });
        await tapIt(tester, 'seats-sheet-card');
        expect(k('seats-sheet-failure'), findsOneWidget);
        expect(requests.where((r) => r.method == 'POST'), isEmpty);
        expect(opened, isEmpty);
      });

      testWidgets('an invoice past its due date is asked about all the same', (tester) async {
        const late = '2020-11-21T12:00:00.000Z';
        await show(tester, billing: [
          _answer(bought: 5, held: [
            {'seats': 4, 'kind': 'invoice', 'until': late}
          ])
        ], posts: {
          'seats': (201, {'url': _checkoutUrl})
        });
        final due = DateFormat.yMMMd('en').format(DateTime.parse(late).toLocal());
        expect(find.text(l10n.seatsSheetInvoicePastDue(4, due)), findsOneWidget, reason: 'it holds nothing any more');
        expect(find.text(l10n.seatsSheetHeldByInvoice(4, due)), findsNothing);
        await tapIt(tester, 'seats-sheet-card');
        expect(find.text(l10n.seatsSheetCardWithInvoiceTitle), findsOneWidget);
      });
    });

    group('past the time its page lasts', () {
      testWidgets('seats that come are said as added: no word of a payment, on the sheet', (tester) async {
        final container = await show(tester, billing: [_answer(bought: 5), _answer(bought: 7)]);
        container.read(seatPurchaseWatchProvider).started(
            _team,
            BillingWaiting(
              page: Uri.parse(_checkoutUrl),
              boughtBefore: 5,
              quantity: 2,
              until: DateTime.now().add(const Duration(minutes: 8)),
            ));
        await tester.pumpAndSettle();
        await tapIt(tester, 'seats-sheet-check');
        expect(k('seats-sheet-arrived'), findsOneWidget);
        expect(find.text(l10n.seatsSheetArrived(2)), findsNothing);
        expect(find.text(l10n.teamSeatsCodeAdded(2)), findsOneWidget);
        container.read(seatPurchaseWatchProvider).forget(_team, business: false);
      });

      testWidgets('and in the notice, with the sheet closed', (tester) async {
        final container = await show(tester, billing: [_answer(bought: 5), _answer(bought: 7)]);
        await tester.tap(find.text(l10n.close).last);
        await tester.pumpAndSettle();
        container.read(seatPurchaseWatchProvider).started(
            _team,
            BillingWaiting(
              page: Uri.parse(_checkoutUrl),
              boughtBefore: 5,
              quantity: 2,
              until: DateTime.now().add(const Duration(minutes: 8)),
            ));
        await cameBack(tester);
        await tester.pumpAndSettle();
        final titles = [for (final n in container.read(notificationCenterProvider).history) n.title];
        expect(titles, [l10n.teamSeatsCodeAdded(2)]);
      });

      testWidgets('within it, and a payment made at its last moment: said as paid', (tester) async {
        final container = await show(tester, billing: [_answer(bought: 5), _answer(bought: 7)]);
        container.read(seatPurchaseWatchProvider).started(
            _team,
            BillingWaiting(
              page: Uri.parse(_checkoutUrl),
              boughtBefore: 5,
              quantity: 2,
              until: DateTime.now().add(const Duration(minutes: 10)),
            ));
        await tester.pumpAndSettle();
        await tapIt(tester, 'seats-sheet-check');
        expect(find.text(l10n.seatsSheetArrived(2)), findsOneWidget);
        container.read(seatPurchaseWatchProvider).forget(_team, business: false);
      });
    });

    testWidgets('Business only once Stripe has it going: a subscription still incomplete is no Business yet', (tester) async {
      await show(tester, billing: [
        _answer(bought: 3, used: 2),
        _answer(bought: 3, used: 2, services: {'state': 'off', 'status': 'incomplete', 'interval': 'year', 'quantity': 3}),
        _answer(bought: 3, used: 2, services: {'state': 'active', 'status': 'active', 'interval': 'year', 'quantity': 3}),
      ], posts: {
        'services': (201, {'url': _checkoutUrl})
      });
      await tapIt(tester, 'seats-sheet-subscribe');
      await tapIt(tester, 'seats-sheet-check');
      expect(find.text(l10n.seatsSheetBusinessArrived), findsNothing);
      expect(find.text(l10n.seatsSheetBusinessWaiting), findsOneWidget);
      await tapIt(tester, 'seats-sheet-check');
      expect(find.text(l10n.seatsSheetBusinessArrived), findsOneWidget);
    });

    testWidgets('a Business checkout after a seat checkout waits beside it, each said as it comes', (tester) async {
      final container = await show(tester, billing: [
        _answer(bought: 3, used: 2),
        _answer(bought: 3, used: 2),
        _answer(bought: 5, used: 2),
        _answer(bought: 5, used: 2, services: {'state': 'active', 'status': 'active', 'interval': 'year', 'quantity': 5}),
      ], posts: {
        'seats': (201, {'url': _checkoutUrl}),
        'services': (201, {'url': _checkoutUrl}),
      });
      await tapIt(tester, 'seats-sheet-plus');
      await tapIt(tester, 'seats-sheet-card');
      await tapIt(tester, 'seats-sheet-subscribe');
      expect(container.read(billingWaitingProvider(_team)).map((w) => w.business), [false, true]);
      expect(k('seats-sheet-waiting'), findsOneWidget);
      expect(k('seats-sheet-waiting-business'), findsOneWidget);
      await tester.tap(k('seats-sheet-check').first);
      await tester.pumpAndSettle();
      expect(find.text(l10n.seatsSheetArrived(2)), findsOneWidget);
      expect(k('seats-sheet-waiting'), findsNothing);
      expect(k('seats-sheet-waiting-business'), findsOneWidget);
      await tapIt(tester, 'seats-sheet-check');
      expect(find.text(l10n.seatsSheetBusinessArrived), findsOneWidget);
      expect(container.read(billingWaitingProvider(_team)), isEmpty);
      await tester.pump(kBillingWaitLimit);
    });

    testWidgets('Check now with ZestSSH Cloud down says that, with the details, and not that nothing came', (tester) async {
      await show(tester, billing: [_answer(), _answer(), const SocketException('down')], posts: {
        'seats': (201, {'url': _checkoutUrl})
      });
      await tapIt(tester, 'seats-sheet-card');
      await tapIt(tester, 'seats-sheet-check');
      expect(find.text(l10n.seatsSheetNotYet), findsNothing);
      expect(k('seats-sheet-failure'), findsOneWidget);
      expect(find.text(l10n.seatsSheetWaitingTitle), findsOneWidget, reason: 'the page is still there to pay on');
    });

    group('Business is billed for each seat', () {
      const on = {'state': 'active', 'status': 'active', 'interval': 'year', 'quantity': 5};

      testWidgets('with a subscription, buying says so, and so does Business', (tester) async {
        await show(tester, billing: [_answer(bought: 5, services: on)]);
        expect(find.text(l10n.seatsSheetBuyRaisesBusiness), findsOneWidget);
        expect(tester.getTopLeft(k('seats-sheet-raises-business')).dy, lessThan(tester.getTopLeft(k('seats-sheet-card')).dy));
        expect(k('seats-sheet-business-follows'), findsOneWidget);
      });

      testWidgets('in its grace it is still said under Business; buying raises the bill once it is paid up, so not there', (tester) async {
        await show(tester, billing: [
          _answer(bought: 5, services: {'state': 'grace', 'status': 'past_due', 'interval': 'year', 'quantity': 5})
        ]);
        expect(k('seats-sheet-business-follows'), findsOneWidget);
        expect(k('seats-sheet-raises-business'), findsNothing);
      });

      testWidgets('without one, buying has nothing to say of it', (tester) async {
        await show(tester, billing: [_answer(bought: 5)]);
        expect(k('seats-sheet-raises-business'), findsNothing);
        expect(k('seats-sheet-first-invoice-grace'), findsNothing);
      });

      testWidgets('days of grace owed from the last time: the first invoice is said to include them', (tester) async {
        await show(tester, billing: [
          _answer(bought: 3, used: 2, services: {'state': 'off', 'status': 'canceled', 'grace_owed_days': 9})
        ]);
        expect(find.text(l10n.seatsSheetFirstInvoiceGrace(9)), findsOneWidget);
      });
    });

    testWidgets('what came in is said once: not again the next time the sheet opens', (tester) async {
      await show(tester, billing: [_answer(bought: 5), _answer(bought: 5), _answer(bought: 7)], posts: {
        'seats': (201, {'url': _checkoutUrl})
      });
      await tapIt(tester, 'seats-sheet-card');
      await tapIt(tester, 'seats-sheet-check');
      expect(k('seats-sheet-arrived'), findsOneWidget);
      await tester.tap(find.text(l10n.close).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(k('seats-sheet-arrived'), findsNothing);
    });

    testWidgets('what came while the sheet was closed had its notice: the sheet does not say it again', (tester) async {
      await show(tester, billing: [_answer(bought: 5), _answer(bought: 5), _answer(bought: 6)], posts: {
        'seats': (201, {'url': _checkoutUrl})
      });
      await tapIt(tester, 'seats-sheet-card');
      await tester.tap(find.text(l10n.close).last);
      await tester.pumpAndSettle();
      await cameBack(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(k('seats-sheet-arrived'), findsNothing);
    });

    testWidgets('on a computer, Escape closes the sheet, and does not while something is under way; what came of it is said', (tester) async {
      final gate = Completer<void>();
      await show(tester, postsWait: gate.future, posts: {
        'invoice': (201, {'number': 'INV-1', 'url': _invoiceUrl, 'sent_to': 'billing@example.com'})
      });
      // Nothing under way: it closes. (The keys go where the keyboard is: in a field.)
      await tester.tap(k('seats-sheet-count'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(k('seats-sheet'), findsNothing);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapIt(tester, 'seats-sheet-invoice');
      await tester.enterText(find.descendant(of: k('seats-sheet-invoice-to'), matching: find.byType(TextField)), 'billing@example.com');
      await tester.pump();
      await tester.ensureVisible(k('seats-sheet-invoice-send'));
      await tester.pumpAndSettle();
      await tester.tap(k('seats-sheet-invoice-send'));
      await tester.pump();
      // The keyboard on something in the sheet still, where the key reaches it.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(k('seats-sheet'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(k('seats-sheet-invoice-sent'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('another account signed in here has nothing of what this one waited for', (tester) async {
      requests = [];
      final client = MockClient((r) async {
        requests.add(r);
        return http.Response(jsonEncode(_answer()), 200);
      });
      final user = StateProvider<UserProfile?>((ref) => const UserProfile(uid: 'owner-1', email: 'owner@example.com'));
      final container = ProviderContainer(overrides: [
        orchardBillingApiProvider.overrideWithValue(OrchardBillingApi(client: client, baseUrl: 'https://api.test/v1', bearer: () async => 'token-1')),
        currentUserProvider.overrideWith((ref) => ref.watch(user)),
      ]);
      addTearDown(container.dispose);
      final waiting = BillingWaiting(page: Uri.parse(_checkoutUrl), boughtBefore: 5, quantity: 2, until: DateTime.now().add(kBillingWaitLimit));
      final first = container.read(seatPurchaseWatchProvider);
      first.started(_team, waiting);
      container.read(billingArrivalProvider(_team).notifier).state = (seats: 2, business: false, paid: true);
      expect(container.read(billingWaitingProvider(_team)), hasLength(1));
      container.read(user.notifier).state = const UserProfile(uid: 'owner-2', email: 'other@example.com');
      expect(container.read(billingWaitingProvider(_team)), isEmpty);
      expect(container.read(billingArrivalProvider(_team)), isNull);
      expect(identical(container.read(seatPurchaseWatchProvider), first), isFalse);
      // The same account going on keeps it.
      final second = container.read(seatPurchaseWatchProvider);
      second.started(_team, waiting);
      container.read(user.notifier).state = const UserProfile(uid: 'owner-2', email: 'other@example.com', displayName: 'A name now');
      expect(container.read(billingWaitingProvider(_team)), hasLength(1));
      // Signing out as well, and no timer is left of any of it.
      container.read(user.notifier).state = null;
      expect(container.read(billingWaitingProvider(_team)), isEmpty);
      container.read(seatPurchaseWatchProvider);
      await tester.pump(const Duration(milliseconds: 1));
    });

    testWidgets('nothing closes the sheet, nor changes what is being bought, while something is under way', (tester) async {
      final gate = Completer<void>();
      await show(tester, postsWait: gate.future, posts: {
        'invoice': (201, {'number': 'INV-1', 'url': _invoiceUrl, 'sent_to': 'owner@example.com'})
      });
      await tapIt(tester, 'seats-sheet-invoice');
      await tester.ensureVisible(k('seats-sheet-invoice-send'));
      await tester.pumpAndSettle();
      await tester.tap(k('seats-sheet-invoice-send'));
      await tester.pump();
      // The buttons at the foot, the cross, and Escape.
      final close = find.text(l10n.close).last;
      await tester.tap(close, warnIfMissed: false);
      await tester.pump();
      expect(k('seats-sheet'), findsOneWidget);
      await tester.tap(find.byIcon(LucideIcons.x).last, warnIfMissed: false);
      await tester.pump();
      expect(k('seats-sheet'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(k('seats-sheet'), findsOneWidget);
      // The stepper's shortcuts.
      for (final q in ['seats-sheet-least', 'seats-sheet-most']) {
        expect(tester.widget<TextButton>(find.descendant(of: k(q), matching: find.byType(TextButton), matchRoot: true)).onPressed, isNull, reason: q);
      }
      gate.complete();
      await tester.pumpAndSettle();
      // And what came of it is said.
      expect(k('seats-sheet-invoice-sent'), findsOneWidget);
      await tester.tap(find.text(l10n.close).last);
      await tester.pumpAndSettle();
      expect(k('seats-sheet'), findsNothing);
    });

    testWidgets('the team\'s name is masked while the screen is recorded', (tester) async {
      Redactor.instance.enabled = true;
      addTearDown(() => Redactor.instance.enabled = false);
      await show(tester, recording: true);
      expect(find.text('Acme'), findsNothing);
      expect(k('seats-sheet'), findsOneWidget);
    });

    testWidgets('the team\'s name shows otherwise', (tester) async {
      await show(tester);
      expect(find.text('Acme'), findsOneWidget);
    });

    testWidgets('a checkout not paid lapses here too: the wait ends by itself', (tester) async {
      final container = await show(tester, posts: {
        'seats': (201, {'url': _checkoutUrl})
      });
      await tapIt(tester, 'seats-sheet-card');
      expect(container.read(billingWaitingProvider(_team)), hasLength(1));
      await tester.pump(kBillingWaitLimit + const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(container.read(billingWaitingProvider(_team)), isEmpty);
      expect(find.text(l10n.seatsSheetWaitingTitle), findsNothing);
      expect(k('seats-sheet-card'), findsOneWidget);
    });

    testWidgets('the browser does not open: said, with the details, and the link to copy', (tester) async {
      await show(
        tester,
        posts: {
          'seats': (201, {'url': _checkoutUrl})
        },
        open: (_) async => throw StateError('The browser did not open'),
      );
      await tapIt(tester, 'seats-sheet-card');
      expect(find.text(l10n.seatsSheetNoBrowser), findsOneWidget);
      expect(k('seats-sheet-failure'), findsOneWidget);
      expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tapIt(tester, 'seats-sheet-copy-link');
      expect(copied, _checkoutUrl);
      // The notice that it was copied goes by itself.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('a page that is not Stripe\'s is not opened: said, with what to do and the details', (tester) async {
      await show(tester, posts: {
        'seats': (201, {'url': 'https://evil.example/pay'})
      });
      await tapIt(tester, 'seats-sheet-card');
      expect(opened, isEmpty);
      expect(find.text(l10n.seatsSheetNotStripe), findsOneWidget);
      expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
    });

    testWidgets('ZestSSH Cloud down while buying: said as that, with its code and the details; nothing else moves', (tester) async {
      await show(tester, posts: {'seats': const SocketException('no route to host')});
      await tapIt(tester, 'seats-sheet-card');
      expect(opened, isEmpty);
      expect(find.text('${l10n.cloudNotResponding} (ZS-1101)'), findsOneWidget);
      expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
      expect(k('seats-sheet-card'), findsOneWidget);
    });

    testWidgets('ZestSSH Cloud down opening the sheet: said, with Try again and the details, and hosts not affected', (tester) async {
      await show(tester, billing: [const SocketException('no route to host'), _answer()]);
      expect(k('seats-sheet-not-read'), findsOneWidget);
      expect(find.text(l10n.teamSeatsError), findsOneWidget);
      expect(find.text('${l10n.cloudNotResponding} (ZS-1101)'), findsOneWidget);
      expect(find.text(l10n.seatsSheetHostsStillWork), findsOneWidget);
      expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
      await tapIt(tester, 'seats-sheet-retry');
      expect(k('seats-sheet-buy'), findsOneWidget);
    });

    testWidgets('a read that fails on coming back changes nothing on screen', (tester) async {
      await show(tester, billing: [_answer(), const SocketException('no route to host')]);
      await cameBack(tester);
      await tester.pumpAndSettle();
      expect(k('seats-sheet-buy'), findsOneWidget);
      expect(k('seats-sheet-not-read'), findsNothing);
    });

    testWidgets('coming back reads the seats, and shows them where they changed', (tester) async {
      await show(tester, billing: [_answer(bought: 5), _answer(bought: 9)]);
      expect(find.textContaining(l10n.teamSeatsInUse(3, 5)), findsOneWidget);
      await cameBack(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining(l10n.teamSeatsInUse(3, 9)), findsOneWidget);
    });

    testWidgets('Pay by invoice: the form says what it is for, checks what the server would refuse, and sends', (tester) async {
      await show(tester, posts: {
        'invoice': (201, {'url': _invoiceUrl, 'number': 'INV-0042', 'sent_to': 'billing@example.com'})
      });
      await tapIt(tester, 'seats-sheet-plus');
      await tapIt(tester, 'seats-sheet-invoice');
      expect(find.text(l10n.seatsSheetInvoiceBody(2, r'$200')), findsOneWidget);
      // Bad address and number: said at the field, nothing is sent.
      await tester.enterText(find.descendant(of: k('seats-sheet-invoice-to'), matching: find.byType(EditableText)), 'nobody');
      await tester.enterText(find.descendant(of: k('seats-sheet-invoice-po'), matching: find.byType(EditableText)), 'PO%1');
      await tapIt(tester, 'seats-sheet-invoice-send');
      expect(find.text(l10n.seatsSheetInvoiceBadAddress), findsOneWidget);
      expect(find.text(l10n.seatsSheetInvoiceBadPo), findsOneWidget);
      expect(requests.where((r) => r.method == 'POST'), isEmpty);

      await tester.enterText(find.descendant(of: k('seats-sheet-invoice-to'), matching: find.byType(EditableText)), 'billing@example.com');
      await tester.enterText(find.descendant(of: k('seats-sheet-invoice-po'), matching: find.byType(EditableText)), 'PO-1234/A');
      await tapIt(tester, 'seats-sheet-invoice-send');
      final post = requests.lastWhere((r) => r.method == 'POST');
      expect(post.url.path, '/v1/orchards/$_team/billing/invoice');
      expect(jsonDecode(post.body), {'quantity': 2, 'email': 'billing@example.com', 'po_number': 'PO-1234/A'});
      expect(find.text(l10n.seatsSheetInvoiceSent('INV-0042', 'billing@example.com')), findsOneWidget);
      await tapIt(tester, 'seats-sheet-invoice-page');
      expect(opened, [Uri.parse(_invoiceUrl)]);
    });

    testWidgets('an invoice left empty goes to the owner\'s address: nothing but the seats is sent', (tester) async {
      await show(tester, posts: {
        'invoice': (201, {'url': null, 'number': 'INV-7', 'sent_to': 'owner@example.com'})
      });
      await tapIt(tester, 'seats-sheet-invoice');
      await tapIt(tester, 'seats-sheet-invoice-send');
      expect(jsonDecode(requests.lastWhere((r) => r.method == 'POST').body), {'quantity': 1});
      expect(k('seats-sheet-invoice-page'), findsNothing);
    });

    testWidgets('an address to the wrong place is refused by the server: its words, with the details', (tester) async {
      await show(tester, posts: {
        'invoice': (400, {'code': 'invoice-address'})
      });
      await tapIt(tester, 'seats-sheet-invoice');
      await tester.enterText(find.descendant(of: k('seats-sheet-invoice-to'), matching: find.byType(EditableText)), 'someone@elsewhere.example');
      await tapIt(tester, 'seats-sheet-invoice-send');
      expect(find.text(l10n.seatsSheetInvoiceAddress), findsOneWidget);
      expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
    });

    testWidgets('while the screen is recorded, the form asks first', (tester) async {
      await show(tester, recording: true);
      await tapIt(tester, 'seats-sheet-invoice');
      expect(find.text(l10n.recModeRevealTitle), findsOneWidget);
      await tester.tap(find.text(l10n.recModeRevealCancel).last);
      await tester.pumpAndSettle();
      expect(k('seats-sheet-invoice-form'), findsNothing);
      expect(words(tester), isNot(contains('owner@example.com')));
    });

    testWidgets('an address an invoice went to is masked while the screen is recorded', (tester) async {
      await show(tester, posts: {
        'invoice': (201, {'url': null, 'number': 'INV-7', 'sent_to': 'owner@example.com'})
      });
      await tapIt(tester, 'seats-sheet-invoice');
      Redactor.instance.enabled = true;
      addTearDown(() => Redactor.instance.enabled = false);
      await tapIt(tester, 'seats-sheet-invoice-send');
      expect(k('seats-sheet-invoice-sent'), findsOneWidget);
      expect(words(tester), isNot(contains('owner@example.com')));
    });

    testWidgets('Business: the price from the server, by the year unless chosen, for every seat; Subscribe opens Stripe', (tester) async {
      await show(tester, billing: [_answer(bought: 3, used: 2)], posts: {
        'services': (201, {'url': _checkoutUrl})
      });
      expect(find.text(l10n.seatsSheetYearPrice(r'$150')), findsOneWidget);
      expect(find.text(l10n.seatsSheetMonthPrice(r'$15')), findsOneWidget);
      expect(find.text(l10n.seatsSheetBusinessTotalYear(3, r'$450')), findsOneWidget);
      await tapIt(tester, 'seats-sheet-monthly');
      expect(find.text(l10n.seatsSheetBusinessTotalMonth(3, r'$45')), findsOneWidget);
      await tapIt(tester, 'seats-sheet-subscribe');
      expect(jsonDecode(requests.lastWhere((r) => r.method == 'POST').body), {'interval': 'month'});
      expect(opened, [Uri.parse(_checkoutUrl)]);
      expect(find.text(l10n.seatsSheetBusinessWaiting), findsOneWidget);
    });

    testWidgets('someone who is no owner: the figures and how Business stands, and nothing that buys', (tester) async {
      await show(tester, billing: [
        {
          ..._answer(bought: 3, used: 2, services: {
            'state': 'active',
            'status': null,
            'interval': 'year',
            'quantity': 3,
            'paid_through': '2027-11-01T00:00:00.000Z',
          }),
          'is_owner': false,
          'held': const <Object?>[],
        },
      ]);
      expect(k('seats-sheet-not-owner'), findsOneWidget);
      expect(k('seats-sheet-figures'), findsOneWidget);
      expect(find.text(l10n.teamSeatsAskOwner), findsOneWidget);
      expect(
          find.text(l10n.teamServicesRenewsYearly(3, DateFormat.yMMMd('en').format(DateTime.parse('2027-11-01T00:00:00.000Z').toLocal()))),
          findsOneWidget);
      for (final key in [
        'seats-sheet-card',
        'seats-sheet-invoice',
        'seats-sheet-subscribe',
        'seats-sheet-business-manage',
        'seats-sheet-portal',
        'seats-sheet-redeem',
      ]) {
        expect(k(key), findsNothing, reason: key);
      }
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
    });

    testWidgets('Business once it is paid: said on coming back', (tester) async {
      await show(tester, billing: [
        _answer(bought: 3, used: 2),
        _answer(bought: 3, used: 2, services: {'state': 'active', 'status': 'active', 'interval': 'year', 'quantity': 3, 'paid_through': '2027-11-01T00:00:00.000Z'}),
      ], posts: {
        'services': (201, {'url': _checkoutUrl})
      });
      await tapIt(tester, 'seats-sheet-subscribe');
      await cameBack(tester);
      await tester.pumpAndSettle();
      expect(find.text(l10n.seatsSheetBusinessArrived), findsOneWidget);
      expect(arrivedCalls, 0, reason: 'no seats came');
      expect(k('seats-sheet-business-manage'), findsOneWidget);
    });

    testWidgets('Business wants a recent sign-in: confirmed, then it goes on by itself', (tester) async {
      await show(tester, billing: [_answer(bought: 3, used: 2)], posts: {
        'services': [
          (403, <String, Object?>{'code': 'recent-sign-in-required'}),
          (201, <String, Object?>{'url': _checkoutUrl}),
        ],
      });
      await tester.ensureVisible(k('seats-sheet-subscribe'));
      await tester.pumpAndSettle();
      await tester.tap(k('seats-sheet-subscribe'));
      // (The button turns while it waits: nothing settles under the question.)
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(requests.where((r) => r.method == 'POST').length, 1);
      expect(opened, isEmpty);
      expect(find.text(l10n.stepUpTitle), findsOneWidget);
      expect(find.text(l10n.seatsSheetStepUpBusiness), findsOneWidget);
      await tester.tap(find.text(l10n.devicesSignInAgainTitle).last);
      await tester.pumpAndSettle();
      expect(signIns, 1);
      expect(requests.where((r) => r.method == 'POST').length, 2, reason: 'once more after it');
      expect(opened, [Uri.parse(_checkoutUrl)]);
    });

    testWidgets('a team without its first seats: Business says buy seats first', (tester) async {
      await show(tester, billing: [_answer(bought: 1, used: 1)]);
      expect(find.text(l10n.seatsSheetSeatsFirst(2)), findsOneWidget);
      expect(k('seats-sheet-subscribe'), findsNothing);
    });

    testWidgets('a subscription: Manage Business, and Pay what is due while a payment failed; never a second one', (tester) async {
      await show(tester, billing: [
        _answer(services: {'state': 'grace', 'status': 'past_due', 'interval': 'year', 'quantity': 5, 'works_until': '2027-01-29T12:00:00.000Z'})
      ], posts: {
        'portal': (201, {'url': _portalUrl})
      });
      expect(find.text(l10n.seatsSheetPayDue), findsOneWidget);
      expect(k('seats-sheet-subscribe'), findsNothing);
      await tapIt(tester, 'seats-sheet-business-manage');
      expect(opened, [Uri.parse(_portalUrl)]);
    });

    testWidgets('Manage billing: nothing bought yet is said, with the details', (tester) async {
      await show(tester, posts: {
        'portal': (409, {'code': 'no-billing'})
      });
      await tapIt(tester, 'seats-sheet-portal');
      expect(opened, isEmpty);
      expect(find.text(l10n.seatsSheetNoBilling), findsOneWidget);
    });

    testWidgets('Redeem a code is here too, and the website\'s page stays to open', (tester) async {
      await show(tester, need: 2);
      await tapIt(tester, 'seats-sheet-website');
      expect(opened, [orchardSeatsPage(_team, need: 2)]);
      await tapIt(tester, 'seats-sheet-redeem');
      expect(find.text(l10n.teamSeatsRedeemBody), findsOneWidget);
    });

    testWidgets('on a phone or tablet nothing opens, and nothing is asked of the server', (tester) async {
      await show(tester, here: false);
      expect(k('seats-sheet'), findsNothing);
      expect(requests, isEmpty);
    });

    testWidgets('a notice says seats came where the sheet was closed', (tester) async {
      final container = await show(
        tester,
        billing: [_answer(bought: 5), _answer(bought: 5), _answer(bought: 8)],
        posts: {
          'seats': (201, {'url': _checkoutUrl})
        },
      );
      await tapIt(tester, 'seats-sheet-plus');
      await tapIt(tester, 'seats-sheet-plus');
      await tapIt(tester, 'seats-sheet-card');
      await tester.tap(find.text(l10n.close).last);
      await tester.pumpAndSettle();
      expect(k('seats-sheet'), findsNothing);
      await cameBack(tester);
      await tester.pumpAndSettle();
      expect(arrivedCalls, 1);
      expect(container.read(notificationCenterProvider).history.any((n) => n.title == l10n.seatsSheetArrived(3)), isTrue);
    });
  });
}
