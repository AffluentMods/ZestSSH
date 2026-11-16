import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// "Redeem a code" on an Orchard's Seats page (3.0): an owner on
/// a computer enters a code that gives the Orchard seats, through the real
/// client. A code that is taken closes the dialog, has the seats read
/// again, sends what waited on this device for seats and says how many
/// came; one that is not taken is said under the field and the dialog
/// stays. Members who are no owners, and phones, have no such button.

const _orchard = '0f0e0d0c-0b0a-4908-8706-050403020100';
const _owner = OrchardSummary(id: _orchard, name: 'Acme', role: FixedRoles.owner, crates: [], defaultCrateId: null);
const _admin = OrchardSummary(id: _orchard, name: 'Acme', role: FixedRoles.admin, crates: [], defaultCrateId: null);

/// The billing route's answer for an Orchard of one person with [bought] seats.
Map<String, Object?> _billing({int bought = 0}) => {
      'seats': {
        'bought': bought,
        'included': 0,
        'total': bought,
        'used': 1,
        'free': bought < 1 ? 0 : bought - 1,
        'over': bought < 1,
      },
      'business_services': {
        'state': 'off',
        'status': null,
        'interval': null,
        'quantity': null,
        'paid_through': null,
        'works_until': null,
        'cancel_at_period_end': false,
      },
      'prices': {'seat_cents': 7500, 'min_first_purchase': 2, 'max_per_purchase': 250},
    };

/// What the redeem route answers for a code that gave [added] seats.
Map<String, Object?> _redeemed({required int bought, required int added}) =>
    {..._billing(bought: bought), 'is_owner': true, 'added': added};

/// A refusal as the service words it: its own English sentence and a code.
http.Response _refusal(int status, String code) => http.Response(
    jsonEncode({'error': 'Said in English by the service', 'code': code}), status,
    headers: {'content-type': 'application/json'});

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  // A notice is looked for where it is drawn on the page: the card a phone
  // shows (a computer hands it to its notification center).
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late List<http.Request> posts;
  late int reads;
  late int arrived;

  /// The Seats page of [orchard]: ZestSSH Cloud answers a read with [seats]
  /// in turn and a redeemed code with [redeems] in turn (a Map is JSON with
  /// 200), on a computer unless [here] is false.
  Future<void> show(
    WidgetTester tester,
    OrchardSummary orchard, {
    List<Map<String, Object?>>? seats,
    List<Object> redeems = const [],
    bool here = true,
  }) async {
    final answers = seats ?? [_billing()];
    posts = [];
    reads = 0;
    arrived = 0;
    var next = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        final a = answers[reads < answers.length ? reads : answers.length - 1];
        reads++;
        return http.Response(jsonEncode(a), 200, headers: {'content-type': 'application/json'});
      }
      posts.add(request);
      final a = redeems[next < redeems.length ? next++ : redeems.length - 1];
      if (a is http.Response) return a;
      return http.Response(jsonEncode(a), 200, headers: {'content-type': 'application/json'});
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardBillingApiProvider.overrideWithValue(
            OrchardBillingApi(client: client, baseUrl: 'https://api.test/v1', bearer: () async => 'token-1')),
        billingOnThisDeviceProvider.overrideWithValue(here),
        seatsPageOpenerProvider.overrideWithValue((page) async {}),
        seatsArrivedProvider.overrideWithValue(() => arrived++),
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

  final button = find.byKey(const ValueKey('team-seats-redeem'));
  final dialog = find.text(l10n.teamSeatsRedeemBody);

  /// Opens the dialog, types [code] and presses Redeem.
  Future<void> enter(WidgetTester tester, String code, {bool open = true}) async {
    if (open) {
      await tester.tap(button);
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.byType(TextField), code);
    await tester.tap(find.text(l10n.redeemDialogAction));
    await tester.pumpAndSettle();
  }

  /// Lets a notice go, so that none of its timers outlives the test.
  Future<void> letNoticeGo(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
  }

  testWidgets('an owner on a computer has Redeem a code beside Buy seats', (tester) async {
    await show(tester, _owner);
    expect(button, findsOneWidget);
    expect(find.descendant(of: button, matching: find.text(l10n.settingsMobRedeemCode)), findsOneWidget);
    expect(find.byKey(const ValueKey('team-seats-buy')), findsOneWidget);
    expect(dialog, findsNothing);
  });

  testWidgets('a member who is no owner has no Redeem a code', (tester) async {
    await show(tester, _admin);
    expect(find.text(l10n.teamSeatsAskOwner), findsOneWidget);
    expect(button, findsNothing);
  });

  testWidgets('an owner on a phone has no Redeem a code: nothing is bought or redeemed there', (tester) async {
    await show(tester, _owner, here: false);
    expect(find.text(l10n.teamSeatsOnComputer), findsOneWidget);
    expect(button, findsNothing);
  });

  testWidgets('a code is redeemed: the dialog closes, the seats are read again, what waited is sent, and a notice says how many came',
      (tester) async {
    await show(tester, _owner, seats: [_billing(), _billing(bought: 3)], redeems: [_redeemed(bought: 3, added: 3)]);
    expect(find.text(l10n.teamSeatsInUse(1, 0)), findsOneWidget);
    expect(reads, 1);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    expect(posts, isEmpty);
    // As a person types it: it is put in capitals, and the spaces go.
    await enter(tester, ' zest-abcd-2345 ', open: false);

    final sent = posts.single;
    expect(sent.method, 'POST');
    expect(sent.url.toString(), 'https://api.test/v1/orchards/$_orchard/billing/redeem');
    expect(sent.headers['Authorization'], 'Bearer token-1');
    expect(jsonDecode(sent.body), {'code': 'ZEST-ABCD-2345'});

    expect(dialog, findsNothing);
    expect(find.text(l10n.teamSeatsCodeAdded(3)), findsOneWidget);
    expect(reads, 2, reason: 'the seats are read again');
    expect(find.text(l10n.teamSeatsInUse(1, 3)), findsOneWidget);
    expect(arrived, 1, reason: 'what waited for seats on this device is sent');
    await letNoticeGo(tester);
  });

  testWidgets('a code this Orchard used before changes nothing, and says so', (tester) async {
    await show(tester, _owner, seats: [_billing(bought: 3)], redeems: [_redeemed(bought: 3, added: 0)]);
    await enter(tester, 'ZEST-ABCD-2345');
    expect(dialog, findsNothing);
    expect(find.text(l10n.teamSeatsCodeUsed), findsOneWidget);
    expect(find.text(l10n.teamSeatsCodeAdded(0)), findsNothing);
    expect(arrived, 0, reason: 'no seats came, so nothing new can go');
    await letNoticeGo(tester);
  });

  testWidgets('a code that is not taken is said under the field in the app\'s words, and the dialog stays for another', (tester) async {
    await show(tester, _owner, seats: [
      _billing(),
      _billing(bought: 2)
    ], redeems: [
      _refusal(404, 'code-invalid'),
      _refusal(409, 'personal-code'),
      _refusal(409, 'seats-maximum'),
      _redeemed(bought: 2, added: 2),
    ]);
    await enter(tester, 'NOPE-0000-0000');
    expect(find.text(l10n.teamSeatsCodeInvalid), findsOneWidget);
    expect(find.text('Said in English by the service'), findsNothing);
    expect(dialog, findsOneWidget, reason: 'the dialog stays for another try');
    expect((arrived, reads), (0, 1));

    await enter(tester, 'ACCT-AAAA-0001', open: false);
    expect(find.text(l10n.teamSeatsCodePersonal), findsOneWidget);
    expect(find.text(l10n.teamSeatsCodeInvalid), findsNothing);
    expect(dialog, findsOneWidget);

    // A code that would take the team past what any team holds is said as that
    // (it was the HTTP status, as an Orchard's other unexpected errors are).
    await enter(tester, 'TEAM-MANY-0002', open: false);
    expect(find.text(l10n.teamSeatsCodeTooManySeats), findsOneWidget);
    expect(find.text(l10n.teamSeatsCodePersonal), findsNothing);
    expect(dialog, findsOneWidget);
    expect((arrived, reads), (0, 1));

    await enter(tester, 'TEAM-GOOD-0003', open: false);
    expect(posts.map((p) => jsonDecode(p.body)['code']),
        ['NOPE-0000-0000', 'ACCT-AAAA-0001', 'TEAM-MANY-0002', 'TEAM-GOOD-0003']);
    expect(dialog, findsNothing);
    expect(find.text(l10n.teamSeatsCodeAdded(2)), findsOneWidget);
    expect((arrived, reads), (1, 2));
    await letNoticeGo(tester);
  });

  testWidgets('the hint shows a code of three groups; one of three groups and one of two are both sent as typed, '
      'and redeeming paused for everyone is said in the words of the app', (tester) async {
    await show(tester, _owner, seats: [
      _billing(),
      _billing(bought: 2)
    ], redeems: [
      _refusal(429, 'redeem-paused'),
      _redeemed(bought: 2, added: 2),
    ]);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('ZEST-XXXX-XXXX-XXXX'), findsOneWidget, reason: 'the shape of a new code, as a hint');
    expect(find.text('ZEST-XXXX-XXXX'), findsNothing);
    await enter(tester, 'zest-abcd-2345-6789', open: false);
    expect(find.text(l10n.redeemPaused), findsOneWidget);
    expect(dialog, findsOneWidget, reason: 'the dialog stays for another try');
    // A code of two groups, minted before codes had three, is taken too.
    await enter(tester, 'zest-abcd-2345', open: false);
    expect(posts.map((p) => jsonDecode(p.body)['code']), ['ZEST-ABCD-2345-6789', 'ZEST-ABCD-2345']);
    expect(dialog, findsNothing);
    expect(find.text(l10n.teamSeatsCodeAdded(2)), findsOneWidget);
    await letNoticeGo(tester);
  });

  testWidgets('an empty field is told, and nothing is sent; closing the dialog redeems nothing', (tester) async {
    await show(tester, _owner, redeems: [_redeemed(bought: 3, added: 3)]);
    await enter(tester, '   ');
    expect(find.text(l10n.redeemSvcEnterCode), findsOneWidget);
    expect(dialog, findsOneWidget);
    expect(posts, isEmpty);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    if (dialog.evaluate().isNotEmpty) {
      await tester.tap(find.text(MaterialLocalizations.of(tester.element(dialog)).cancelButtonLabel).last, warnIfMissed: false);
      await tester.pumpAndSettle();
    }
    expect(posts, isEmpty);
    expect((arrived, reads), (0, 1));
    expect(find.text(l10n.teamSeatsCodeAdded(3)), findsNothing);
  });

  test('what a refusal says: the two of a code in the app\'s words, anything else as an Orchard\'s errors are worded', () {
    expect(seatCodeRefusal(const OrchardServerException(404, 'code-invalid'), l10n), l10n.teamSeatsCodeInvalid);
    expect(seatCodeRefusal(const OrchardServerException(409, 'personal-code'), l10n), l10n.teamSeatsCodePersonal);
    expect(seatCodeRefusal(const OrchardServerException(429, 'redeem-paused'), l10n), l10n.redeemPaused);
    // Each refusal of a team code the backend gives is said as itself, not as an HTTP status.
    expect(seatCodeRefusal(const OrchardServerException(409, 'business-code-used'), l10n), l10n.teamSeatsCodeBusinessUsed);
    expect(seatCodeRefusal(const OrchardServerException(409, 'business-active'), l10n), l10n.teamSeatsCodeBusinessActive);
    expect(seatCodeRefusal(const OrchardServerException(409, 'business-paid-recently'), l10n),
        l10n.teamSeatsCodeBusinessPaidRecently);
    expect(seatCodeRefusal(const OrchardServerException(409, 'business-needed-for-seats'), l10n),
        l10n.teamSeatsCodeNeedsBusiness(25));
    expect(seatCodeRefusal(const OrchardServerException(409, 'seats-maximum'), l10n), l10n.teamSeatsCodeTooManySeats);
    for (final code in ['business-code-used', 'business-active', 'business-paid-recently', 'business-needed-for-seats', 'seats-maximum']) {
      expect(seatCodeRefusal(OrchardServerException(409, code), l10n), isNot(contains('409')));
    }
    // A team that is not there is no invalid code.
    const gone = OrchardServerException(404, 'not-found');
    expect(seatCodeRefusal(gone, l10n), orchardErrorMessage(gone, l10n));
    expect(seatCodeRefusal(gone, l10n), isNot(l10n.teamSeatsCodeInvalid));
    const signedOut = OrchardServerException(401, 'signed-out');
    expect(seatCodeRefusal(signedOut, l10n), l10n.orchardErrorSignedOut);
    final other = StateError('x');
    expect(seatCodeRefusal(other, l10n), orchardErrorMessage(other, l10n));
  });

  test('the words are there in every language, each in its own', () {
    final english = [
      l10n.teamSeatsRedeemBody,
      l10n.teamSeatsCodeInvalid,
      l10n.teamSeatsCodePersonal,
      l10n.teamSeatsCodeAdded(7),
      l10n.teamSeatsCodeUsed,
      l10n.redeemSvcTeamCode,
    ];
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      final words = [
        t.teamSeatsRedeemBody,
        t.teamSeatsCodeInvalid,
        t.teamSeatsCodePersonal,
        t.teamSeatsCodeAdded(7),
        t.teamSeatsCodeUsed,
        t.redeemSvcTeamCode,
      ];
      for (var i = 0; i < words.length; i++) {
        expect(words[i].trim(), isNotEmpty, reason: '$locale $i');
        if (locale.languageCode != 'en') expect(words[i], isNot(english[i]), reason: '$locale $i');
      }
      expect(t.teamSeatsCodeAdded(7), contains('7'), reason: '$locale');
      // The account page's row is named as the app names it.
      expect(t.teamSeatsCodePersonal, contains(t.settingsMobRedeemCode), reason: '$locale');
    }
  });

  group('the client', () {
    OrchardBillingApi api(http.Client client, {String? token = 'token-1'}) =>
        OrchardBillingApi(client: client, baseUrl: 'https://api.test/v1', bearer: () async => token);

    test('sends the code without the spaces around it, and reads what came of it', () async {
      late http.Request sent;
      final done = await api(MockClient((request) async {
        sent = request;
        return http.Response(jsonEncode(_redeemed(bought: 9, added: 4)), 200);
      })).redeem(_orchard, '  ZEST-ABCD-2345 ');
      expect(sent.url.toString(), 'https://api.test/v1/orchards/$_orchard/billing/redeem');
      expect(jsonDecode(sent.body), {'code': 'ZEST-ABCD-2345'});
      expect(sent.headers['Content-Type'], startsWith('application/json'));
      expect((done.added, done.billing.seats.bought, done.billing.seats.used), (4, 9, 1));
      // An answer that says nothing of seats added counts as none.
      final none =
          await api(MockClient((_) async => http.Response(jsonEncode(_billing(bought: 2)), 200))).redeem(_orchard, 'X');
      expect((none.added, none.billing.seats.bought), (0, 2));
    });

    test('a refusal is thrown with the service\'s status and code; signed out, nothing is sent', () async {
      await expectLater(
          api(MockClient((_) async => _refusal(404, 'code-invalid'))).redeem(_orchard, 'X'),
          throwsA(isA<OrchardServerException>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.code, 'code', 'code-invalid')));
      var asked = 0;
      final signedOut = api(MockClient((_) async {
        asked++;
        return _refusal(500, 'server');
      }), token: null);
      await expectLater(
          signedOut.redeem(_orchard, 'X'),
          throwsA(isA<OrchardServerException>()
              .having((e) => e.status, 'status', 401)
              .having((e) => e.code, 'code', 'signed-out')));
      expect(asked, 0);
    });
  });

  test('once seats came, what waited on this device is sent: every Orchard is synced', () {
    final scheduler = _CountingScheduler();
    final container = ProviderContainer(overrides: [orchardSyncSchedulerProvider.overrideWithValue(scheduler)]);
    addTearDown(container.dispose);
    final arrived = container.read(seatsArrivedProvider);
    expect(scheduler.synced, 0);
    arrived();
    expect(scheduler.synced, 1);
  });
}

class _CountingScheduler implements OrchardSyncScheduler {
  int synced = 0;

  @override
  Future<void> syncAll() async {
    synced++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
