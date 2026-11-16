import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/pinned_http_client.dart';

/// An Orchard's seats (3.0): bought once, from ZestSSH on a computer
/// or on the website, counted for the Orchard, never tied to a person. Its people (members whose access
/// has not ended, and live invitations) may not be more than its seats.
class OrchardSeats {
  const OrchardSeats({
    required this.bought,
    required this.included,
    required this.total,
    required this.used,
    required this.free,
    required this.over,
  });

  /// Seats bought and not refunded.
  final int bought;

  /// The seats this team has without buying any: the one every team
  /// includes, and one more while an owner holds the personal Bundle.
  final int included;

  /// [bought] and [included] (at most 1,000).
  final int total;

  /// Who holds one: members whose access has not ended, and live invitations.
  final int used;

  final int free;

  /// More people than seats: nothing new is added (items, invitations)
  /// until an owner buys seats; nothing else stops.
  final bool over;

  static OrchardSeats? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int? n(String k) => raw[k] is int && (raw[k] as int) >= 0 ? raw[k] as int : null;
    final bought = n('bought'), included = n('included'), total = n('total'), used = n('used'), free = n('free');
    if (bought == null || included == null || total == null || used == null || free == null) return null;
    return OrchardSeats(
      bought: bought,
      included: included,
      total: total,
      used: used,
      free: free,
      over: raw['over'] == true,
    );
  }
}

/// Where an Orchard's Business Services stands: paid up, in the 14 days of
/// grace after the time paid for, or off (never subscribed, or lapsed).
enum BusinessServicesState {
  active,
  grace,
  off;

  static BusinessServicesState parse(Object? v) => switch (v) {
        'active' => active,
        'grace' => grace,
        _ => off,
      };
}

/// An Orchard's Business Services (company sign-in and directory sync), as
/// Stripe last told ZestSSH Cloud.
class OrchardBusinessServices {
  const OrchardBusinessServices({
    this.state = BusinessServicesState.off,
    this.status,
    this.yearly,
    this.quantity,
    this.paidThrough,
    this.worksUntil,
    this.endsAtPeriodEnd = false,
    this.compedUntil,
    this.graceAfterEnd,
    this.graceOwedDays = 0,
  });

  final BusinessServicesState state;

  /// The subscription as Stripe names it ('active', 'past_due', ...); null
  /// where there is none, and for anyone but an owner, who is not told it.
  final String? status;

  /// Billed by the year (true), the month (false), or never subscribed (null).
  final bool? yearly;

  /// The seats it is billed for.
  final int? quantity;

  /// The end of the time paid for.
  final DateTime? paidThrough;

  /// When it stops working: the time paid for and 14 days.
  final DateTime? worksUntil;

  /// Set to end when the time paid for ends (cancelled in billing).
  final bool endsAtPeriodEnd;

  /// The end of free months from a Business code; null for none.
  final DateTime? compedUntil;

  /// Whether 14 days of grace follow the end of the time it has now (once
  /// in 12 months); null where it has no end.
  final bool? graceAfterEnd;

  /// The days of grace after it last ended that a new subscription's first
  /// invoice pays for; an owner's to know, and 0 for anyone else.
  final int graceOwedDays;

  /// Paid for by a subscription (by the month or the year).
  bool get subscribed => yearly != null;

  /// A subscription that is not over: it is changed, paid or cancelled in
  /// billing (Stripe's portal), and a second one is not started (the server
  /// answers 'business-services-exists').
  bool get notOver => status != null && status != 'canceled' && status != 'incomplete_expired';

  static OrchardBusinessServices fromJson(Object? raw) {
    if (raw is! Map) return const OrchardBusinessServices();
    DateTime? at(String k) => raw[k] is String ? DateTime.tryParse(raw[k] as String) : null;
    final interval = raw['interval'];
    return OrchardBusinessServices(
      state: BusinessServicesState.parse(raw['state']),
      status: raw['status'] is String ? raw['status'] as String : null,
      yearly: interval == 'year' ? true : (interval == 'month' ? false : null),
      quantity: raw['quantity'] is int ? raw['quantity'] as int : null,
      paidThrough: at('paid_through'),
      worksUntil: at('works_until'),
      endsAtPeriodEnd: raw['cancel_at_period_end'] == true,
      compedUntil: at('comped_until'),
      graceAfterEnd: raw['grace_after_end'] is bool ? raw['grace_after_end'] as bool : null,
      graceOwedDays: raw['grace_owed_days'] is int ? raw['grace_owed_days'] as int : 0,
    );
  }
}

/// The prices of 27 October 2026 (Business $15 and $150, was $20 and $200),
/// for the words only, where ZestSSH Cloud
/// does not say them (a server from before it sent them): a seat, bought
/// once, and Business for one seat, by the month or by the year.
const kSeatPriceCents = 10000;
const kBusinessMonthCents = 1500;
const kBusinessYearCents = 15000;

/// What ZestSSH Cloud holds a team to, where it does not say them (a server
/// from before it sent them): a team starts at 2 seats, and holds up to 25
/// without Business; up to 250 at a time, and 1,000 in all.
const kTeamMinSeats = 2;
const kTeamMaxSeats = 25;
const kSeatsMaxPerPurchase = 250;
const kSeatsMax = 1000;

/// How long a seat checkout's page lasts in minutes, and holds its seats (the
/// server's CHECKOUT_MINUTES, lib/orchard_billing.js).
const kSeatCheckoutMinutes = 31;

/// Seats held by something waiting to be paid, as ZestSSH Cloud tells an owner.
class OrchardSeatHold {
  const OrchardSeatHold({required this.seats, required this.invoice, required this.until});

  final int seats;

  /// For an invoice; else for a checkout.
  final bool invoice;

  /// An invoice's due date, a checkout's end.
  final DateTime until;

  static OrchardSeatHold? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final seats = raw['seats'], until = raw['until'] is String ? DateTime.tryParse(raw['until'] as String) : null;
    if (seats is! int || until == null) return null;
    return OrchardSeatHold(seats: seats, invoice: raw['kind'] == 'invoice', until: until);
  }
}

/// An Orchard's seats and Business Services, as its members see them.
class OrchardBilling {
  const OrchardBilling({
    required this.seats,
    required this.services,
    this.isOwner = true,
    this.seatPriceCents = kSeatPriceCents,
    this.servicesMonthCents = kBusinessMonthCents,
    this.servicesYearCents = kBusinessYearCents,
    this.maxPerPurchase = kSeatsMaxPerPurchase,
    this.maxSeats = kSeatsMax,
    this.teamMinSeats = kTeamMinSeats,
    this.teamMaxSeats = kTeamMaxSeats,
    this.held = const [],
  });

  final OrchardSeats seats;
  final OrchardBusinessServices services;

  /// Whether this account owns the team, as ZestSSH Cloud says: only owners buy
  /// seats and Business, and they alone are told Stripe's word for the
  /// subscription ([OrchardBusinessServices.status]), what holds seats and the
  /// grace owed. (A server that does not say is one the owners' sheet read
  /// before it did.)
  final bool isOwner;

  /// What holds seats now, for an owner: paying for the same seats a second way
  /// is said before it is done.
  final List<OrchardSeatHold> held;

  /// What a seat costs, for the words only (the server asks Stripe for it).
  final int seatPriceCents;

  /// What Business costs for one seat, a month or a year, for the words
  /// only.
  final int servicesMonthCents;
  final int servicesYearCents;

  /// The most seats one purchase may buy, and a team may hold.
  final int maxPerPurchase;
  final int maxSeats;

  /// A team's seats: at least this many, and without Business at most.
  final int teamMinSeats;
  final int teamMaxSeats;

  /// Whether Business counts now, in its grace too: it lets a team go past
  /// [teamMaxSeats].
  bool get businessOn => services.state != BusinessServicesState.off;

  /// The fewest seats one purchase may buy now: enough for a team's first
  /// [teamMinSeats], at least one. The website's page and the server count
  /// it the same way (seatPurchaseProblem, lib/orchard_billing.js).
  int get seatsMinimum => math.max(1, teamMinSeats - seats.total);

  /// The most seats one purchase may buy now; 0 where the team holds all it
  /// may.
  int get seatsMaximum {
    final room = math.min(maxPerPurchase, maxSeats - seats.bought);
    return math.max(0, businessOn ? room : math.min(room, teamMaxSeats - seats.total));
  }

  /// How many seats are needed: what an invitation said it needs ([need]), or
  /// enough for everyone already here. 0 for none.
  int seatsNeeded(int? need) => math.max(need ?? 0, seats.used - seats.total);

  /// How many seats to start from: what is needed, and a team's first two at
  /// least.
  int seatsSuggested(int? need) =>
      math.max(seatsMinimum, math.min(seatsMaximum, seatsNeeded(need)));

  static OrchardBilling fromJson(Map<String, dynamic> raw) {
    final seats = OrchardSeats.fromJson(raw['seats']);
    if (seats == null) throw const FormatException('Not an Orchard\'s seats');
    final prices = raw['prices'];
    int price(String k, int fallback) =>
        prices is Map && prices[k] is int && (prices[k] as int) > 0 ? prices[k] as int : fallback;
    return OrchardBilling(
      seats: seats,
      services: OrchardBusinessServices.fromJson(raw['business_services']),
      isOwner: raw['is_owner'] != false,
      seatPriceCents: price('seat_cents', kSeatPriceCents),
      servicesMonthCents: price('services_month_cents', kBusinessMonthCents),
      servicesYearCents: price('services_year_cents', kBusinessYearCents),
      maxPerPurchase: price('max_per_purchase', kSeatsMaxPerPurchase),
      maxSeats: price('max_seats', kSeatsMax),
      teamMinSeats: price('team_min_seats', kTeamMinSeats),
      teamMaxSeats: price('team_max_seats', kTeamMaxSeats),
      held: [
        if (raw['held'] is List)
          for (final h in raw['held'] as List)
            ?OrchardSeatHold.fromJson(h),
      ],
    );
  }
}

/// The website, or the WEBSITE_URL a build names: a staging build's own site
/// (ZestSSH-Website `npm run staging:local`), so its seats page signs in to
/// the same staging project as the rest of that build.
String get kWebsiteBase => kZestWebsite;

/// [raw] without the slashes it may end with: a WEBSITE_URL given as
/// `https://host/` made the seats page `https://host//teams/seats` (found in a
/// review).
@visibleForTesting
String websiteBaseOf(String raw) => raw.replaceFirst(RegExp(r'/+$'), '');

/// The website's page for a team's seats and Business Services (the seats
/// sheet offers it too; nothing is bought in the phone apps): with [need],
/// ready to buy that many.
Uri orchardSeatsPage(String orchardId, {int? need}) => Uri.parse('${websiteBaseOf(kWebsiteBase)}/teams/seats')
    .replace(queryParameters: {'orchard': orchardId, if (need != null && need > 0) 'need': '$need'});

/// How the website names a team: by the start of its id, since the name is
/// encrypted end to end and ZestSSH Cloud does not know it.
String orchardShortId(String orchardId) => orchardId.length <= 8 ? orchardId : orchardId.substring(0, 8);

/// The only pages a checkout or the billing portal may open (the website's
/// STRIPE_PAGE): Stripe's own, over https.
final _stripePage = RegExp(r'^https://(checkout|billing)\.stripe\.com/');

/// Where Stripe shows an invoice: the only address its link may have.
final _invoicePage = RegExp(r'^https://invoice\.stripe\.com/');

/// [url] as the page to open; a code the seats sheet words where ZestSSH
/// Cloud answered anything but a page of Stripe's, which is never opened.
Uri _stripeUri(Object? url) {
  if (url is String && _stripePage.hasMatch(url)) {
    final uri = Uri.tryParse(url);
    if (uri != null) return uri;
  }
  throw const OrchardServerException(502, 'not-stripe');
}

/// A purchase ZestSSH Cloud refused, with what the refusal says (the routes
/// in lib/orchard_billing.js): how many seats the least or the most is, how
/// many another purchase holds and how many may be bought meanwhile.
class SeatPurchaseRefused extends OrchardServerException {
  const SeatPurchaseRefused(
    super.status,
    super.code, {
    super.unmet,
    this.minimum,
    this.maximum,
    this.waiting,
    this.canBuy,
    this.waitingOnInvoice = false,
    this.waitingUntil,
  });

  /// For 'seats-minimum': the fewest to buy.
  final int? minimum;

  /// For 'business-needed-for-seats': what a team holds without Business.
  final int? maximum;

  /// For 'seats-waiting': the seats another purchase holds, and how many may
  /// be bought until it is paid or lapses.
  final int? waiting;
  final int? canBuy;

  /// For 'seats-waiting': that purchase is an invoice, not a checkout, and
  /// when it is due.
  final bool waitingOnInvoice;
  final DateTime? waitingUntil;

  @override
  String get typeName => 'SeatPurchaseRefused';
}

/// An invoice for seats, as ZestSSH Cloud sent it: its number, where it went,
/// and Stripe's page for it (null where it gave none we would open).
class SeatInvoice {
  const SeatInvoice({required this.number, required this.sentTo, this.page});

  final String number;
  final String sentTo;
  final Uri? page;
}

/// What redeeming a seat code did: the Orchard's seats and Business
/// Services as they are now, and how many seats the code [added] (0 where
/// this Orchard had used the code before, which changes nothing).
class SeatCodeRedeemed {
  const SeatCodeRedeemed({required this.billing, required this.added});

  final OrchardBilling billing;
  final int added;
}

/// ZestSSH Cloud's billing routes for an Orchard: its seats and
/// Business Services, for its members; for its owners on a computer a Stripe
/// page to pay on, an invoice, and a code that gives it seats. Card details
/// are only ever typed on Stripe's pages, in the browser. Errors are
/// [OrchardServerException]s ('not-found', 'rules-unmet'), purchases'
/// [SeatPurchaseRefused].
class OrchardBillingApi {
  OrchardBillingApi({http.Client? client, String? baseUrl, required this.bearer})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? OrchardsApi.defaultBase;

  final http.Client _client;
  final String _base;

  /// The account's bearer: the Firebase ID token on phones, the session
  /// token on desktop. Null when signed out.
  final Future<String?> Function() bearer;

  static const _timeout = Duration(seconds: 30);

  /// [orchardId]'s seats and Business Services.
  Future<OrchardBilling> get(String orchardId) async {
    final token = await bearer();
    if (token == null) throw const OrchardServerException(401, 'signed-out');
    final response = await _client.get(Uri.parse('$_base/orchards/$orchardId/billing'), headers: {
      'Authorization': 'Bearer $token',
      ...DeviceSessionHeader.headers,
    }).timeout(_timeout);
    reportIfSessionRevoked(response);
    final body = _json(response);
    if (response.statusCode == 200) return OrchardBilling.fromJson(body);
    throw _refused(response, body);
  }

  /// A Stripe Checkout page buying [quantity] seats for [orchardId], as one
  /// of its owners. The seats are held while it is open.
  Future<Uri> buySeats(String orchardId, int quantity) async =>
      _stripeUri((await _post('$orchardId/billing/seats', {'quantity': quantity}))['url']);

  /// An invoice for [quantity] seats of [orchardId], sent to [email] (the
  /// owner's own address where null), due in 30 days, with the purchase
  /// order number [po] on it where given. The seats come when it is paid.
  Future<SeatInvoice> sendSeatInvoice(String orchardId, int quantity, {String? email, String? po}) async {
    final body = await _post('$orchardId/billing/invoice', {
      'quantity': quantity,
      if (email != null && email.isNotEmpty) 'email': email,
      if (po != null && po.isNotEmpty) 'po_number': po,
    });
    final page = body['url'];
    return SeatInvoice(
      number: body['number'] is String ? body['number'] as String : '',
      sentTo: body['sent_to'] is String ? body['sent_to'] as String : (email ?? ''),
      page: page is String && _invoicePage.hasMatch(page) ? Uri.tryParse(page) : null,
    );
  }

  /// A Stripe Checkout page subscribing [orchardId] to Business, by the year
  /// or the month. Needs a recent sign-in.
  Future<Uri> subscribeBusiness(String orchardId, {required bool yearly}) async =>
      _stripeUri((await _post('$orchardId/billing/services', {'interval': yearly ? 'year' : 'month'}))['url']);

  /// Stripe's billing page for [orchardId]: receipts, invoices, the card on
  /// file and Business. Needs a recent sign-in.
  Future<Uri> billingPortal(String orchardId) async =>
      _stripeUri((await _post('$orchardId/billing/portal', const {}))['url']);

  /// Posts [body] to the Orchard route [path], as one of its owners.
  Future<Map<String, dynamic>> _post(String path, Map<String, Object?> body) async {
    final token = await bearer();
    if (token == null) throw const OrchardServerException(401, 'signed-out');
    final response = await _client
        .post(Uri.parse('$_base/orchards/$path'),
            headers: {
              'Authorization': 'Bearer $token',
              ...DeviceSessionHeader.headers,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body))
        .timeout(_timeout);
    reportIfSessionRevoked(response);
    final answer = _json(response);
    if (response.statusCode != 200 && response.statusCode != 201) throw _refused(response, answer);
    return answer;
  }

  /// Redeems [code] for [orchardId], as one of its owners: a code that
  /// gives the Orchard seats (whoever runs the service makes them). Errors
  /// are [OrchardServerException]s: 'code-invalid' (not valid, expired or
  /// used up), 'personal-code' (a code for an account), 'owners-only',
  /// 'seats-maximum', 'rate-limited'.
  Future<SeatCodeRedeemed> redeem(String orchardId, String code) async {
    final token = await bearer();
    if (token == null) throw const OrchardServerException(401, 'signed-out');
    final response = await _client
        .post(Uri.parse('$_base/orchards/$orchardId/billing/redeem'),
            headers: {
              'Authorization': 'Bearer $token',
              ...DeviceSessionHeader.headers,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'code': code.trim()}))
        .timeout(_timeout);
    reportIfSessionRevoked(response);
    final body = _json(response);
    if (response.statusCode != 200) throw _refused(response, body);
    return SeatCodeRedeemed(
        billing: OrchardBilling.fromJson(body), added: body['added'] is int ? body['added'] as int : 0);
  }

  static Map<String, dynamic> _json(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  static OrchardServerException _refused(http.Response response, Map<String, dynamic> body) {
    final unmet = body['unmet'];
    int? n(String k) => body[k] is int ? body[k] as int : null;
    final until = body['waiting_until'];
    return SeatPurchaseRefused(
      response.statusCode,
      body['code'] is String ? body['code'] as String : null,
      unmet: unmet is List ? [for (final u in unmet) if (u is String) u] : null,
      minimum: n('minimum'),
      maximum: n('maximum'),
      waiting: n('waiting'),
      canBuy: n('can_buy'),
      waitingOnInvoice: body['waiting_kind'] == 'invoice',
      waitingUntil: until is String ? DateTime.tryParse(until) : null,
    );
  }
}
