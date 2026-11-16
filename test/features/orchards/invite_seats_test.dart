import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/features/orchards/team/join_readiness.dart' show JoinPreparer, joinPreparerProvider;
import 'package:zestssh/features/teams/account_key_service.dart' show AccountKeyStatus;
import 'package:zestssh/features/orchards/widgets/invite_people_dialog.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show showCreateOrchardDialog;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart' show isSignedInProvider;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';

/// Seats when inviting: no team is free;
/// each person in it holds a seat, the first bought or from an owner's
/// Bundle, and each person invited takes one. Where none is free
/// the invitation says how many more it needs, before anything is sent and
/// when the server refuses one; an owner on a computer buys exactly those on
/// the website, an owner on a phone or tablet is told where it is done with
/// no link, and anyone else is told to ask an owner.

const _id = '0f0e0d0c-0b0a-4908-8706-050403020100';
OrchardSummary _as(String role) => OrchardSummary(id: _id, name: 'Acme', role: role, crates: const [], defaultCrateId: null);

/// The seats as the billing route answers them.
OrchardBilling _seats({required int bought, int included = 0, required int used}) {
  final total = bought + included;
  return OrchardBilling.fromJson({
    'seats': {
      'bought': bought,
      'included': included,
      'total': total,
      'used': used,
      'free': used > total ? 0 : total - used,
      'over': used > total,
    },
    'business_services': {'state': 'off'},
  });
}

/// A service whose invitations the server refuses with [refusal] (or takes, when null).
class _Service implements OrchardService {
  _Service(this.refusal);

  final Object? refusal;
  final sent = <String>[];

  @override
  Future<bool> invite(String orchardId,
      {required String email, required String role, Map<String, Set<String>> grants = const {}, int? endsAt}) async {
    sent.add(email);
    final r = refusal;
    if (r != null) throw r;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late List<Uri> opened;

  Future<_Service> show(WidgetTester tester, OrchardSummary orchard,
      {OrchardBilling? billing, Object? refusal, bool here = true}) async {
    opened = [];
    final service = _Service(refusal);
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardServiceProvider.overrideWithValue(service),
        orchardRolesProvider.overrideWith((ref, id) async => const <OrchardRoleView>[]),
        orchardProvenDomainsProvider.overrideWith((ref, id) async => const <String>[]),
        orchardBillingProvider.overrideWith((ref, id) async {
          final b = billing;
          if (b == null) throw const OrchardServerException(503, null);
          return b;
        }),
        billingOnThisDeviceProvider.overrideWithValue(here),
        seatsPageOpenerProvider.overrideWithValue((page) async => opened.add(page)),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: Center(child: InvitePeopleDialog(orchard: orchard))),
      ),
    ));
    await tester.pumpAndSettle();
    return service;
  }

  Future<void> send(WidgetTester tester, String email) async {
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('invite-email')), matching: find.byType(EditableText)), email);
    await tester.tap(find.text(l10n.orchardInviteSend));
    await tester.pumpAndSettle();
  }

  testWidgets('every seat taken: said before anything is sent, and an owner on a computer buys exactly what is needed',
      (tester) async {
    await show(tester, _as(FixedRoles.owner), billing: _seats(bought: 1, used: 1));
    expect(find.text(l10n.inviteSeatsNeeded(1)), findsOneWidget);
    expect(find.text(l10n.inviteSeatsBuy(1)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('invite-seats-buy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('seats-sheet')), findsOneWidget);
    expect(find.text(l10n.seatsSheetNeed(1)), findsOneWidget);
    expect(opened, isEmpty, reason: 'bought from inside the app');
  });

  testWidgets('more people than seats: the invitation needs the seats that are short and one more', (tester) async {
    await show(tester, _as(FixedRoles.owner), billing: _seats(bought: 2, used: 4));
    expect(find.text(l10n.inviteSeatsNeeded(3)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('invite-seats-buy')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.seatsSheetNeed(3)), findsOneWidget);
    expect(find.text(l10n.seatsSheetTotal(3, r'$300')), findsOneWidget);
  });

  testWidgets('a seat free: nothing said, and the invitation goes', (tester) async {
    final service = await show(tester, _as(FixedRoles.owner), billing: _seats(bought: 2, used: 1));
    expect(find.byKey(const ValueKey('invite-seats')), findsNothing);
    await send(tester, 'robin@example.com');
    expect(service.sent, ['robin@example.com']);
  });

  testWidgets('the server refuses for seats: how many it says, under the form and not as the address\'s error',
      (tester) async {
    final service = await show(tester, _as(FixedRoles.owner),
        billing: _seats(bought: 4, used: 3),
        refusal: const OrchardServerException(409, 'seats-full', seats: 5, seatsUsed: 6, seatsNeeded: 2));
    expect(find.byKey(const ValueKey('invite-seats')), findsNothing, reason: 'a seat looked free');
    await send(tester, 'morgan@example.com');
    expect(service.sent, ['morgan@example.com']);
    expect(find.text(l10n.inviteSeatsNeeded(2)), findsOneWidget);
    expect(find.text(l10n.inviteSeatsBuy(2)), findsOneWidget);
    expect(find.text(l10n.orchardSeatsFull), findsNothing);
    await tester.tap(find.byKey(const ValueKey('invite-seats-buy')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.seatsSheetNeed(2)), findsOneWidget);
  });

  testWidgets('seats not read: the server is asked all the same, and says it', (tester) async {
    final service = await show(tester, _as(FixedRoles.owner),
        refusal: const OrchardServerException(409, 'seats-full', seats: 1, seatsUsed: 1));
    expect(find.byKey(const ValueKey('invite-seats')), findsNothing);
    await send(tester, 'alex@example.com');
    expect(service.sent, ['alex@example.com']);
    expect(find.text(l10n.inviteSeatsNeeded(1)), findsOneWidget);
  });

  testWidgets('another refusal is the address\'s error, as before', (tester) async {
    await show(tester, _as(FixedRoles.owner),
        billing: _seats(bought: 4, used: 1), refusal: const OrchardServerException(409, 'already-member'));
    await send(tester, 'robin@example.com');
    expect(find.text(l10n.orchardInviteErrorAlreadyMember), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-seats')), findsNothing);
  });

  testWidgets('an owner on a phone or tablet: where it is done, with no link and no price', (tester) async {
    await show(tester, _as(FixedRoles.owner), billing: _seats(bought: 1, used: 1), here: false);
    expect(find.text(l10n.inviteSeatsNeeded(1)), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-seats-buy')), findsNothing);
    expect(find.text(l10n.teamSeatsOnComputer), findsOneWidget);
    final words = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').join(' ');
    expect(words, isNot(contains('zestssh.com')));
    expect(words, isNot(contains(r'$')));
  });

  testWidgets('someone who is not an owner is told to ask one, even on a computer', (tester) async {
    await show(tester, _as(FixedRoles.admin), billing: _seats(bought: 1, used: 1));
    expect(find.text(l10n.inviteSeatsNeeded(1)), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-seats-buy')), findsNothing);
    expect(find.text(l10n.teamSeatsAskOwner), findsOneWidget);
  });

  testWidgets('making a team says that each person holds a seat, the first with the Bundle', (tester) async {
    // A tablet's window (the test runs as Android): its dialog's targets are
    // a finger's 48, which a 600 high window had no room for.
    tester.view.physicalSize = const Size(1024, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        isSignedInProvider.overrideWithValue(true),
        // The team keys are here already: Create a team asks for the name.
        joinPreparerProvider.overrideWithValue(JoinPreparer(
          hasKeys: () async => true,
          ensureKeys: () async => AccountKeyStatus.ready,
          forgetKeys: () {},
          syncNow: () async {},
        )),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) =>
                TextButton(onPressed: () => showCreateOrchardDialog(context, ref), child: const Text('make')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('make'));
    await tester.pumpAndSettle();
    expect(find.textContaining(l10n.orchardCreateSeatsNote), findsOneWidget);
    // No price and no link: phones show it too.
    expect(l10n.orchardCreateSeatsNote, isNot(anyOf(contains(r'$'), contains('zestssh.com'))));
  });

  test('the server\'s refusal of an invitation for seats is read with how many more it needs', () async {
    final api = OrchardsApi(
        client: MockClient((request) async => http.Response(
            jsonEncode({'error': 'x', 'code': 'seats-full', 'seats': 2, 'used': 2, 'needed': 1}), 409,
            headers: {'content-type': 'application/json'})),
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'token');
    await expectLater(
        api.invite(_id, email: 'robin@example.com', role: FixedRoles.admin),
        throwsA(isA<OrchardServerException>()
            .having((e) => e.code, 'code', 'seats-full')
            .having((e) => (e.seats, e.seatsUsed, e.seatsNeeded), 'seats, used, needed', (2, 2, 1))));
  });

  test('in each of the twelve languages: the number, one and many told apart, and not English', () {
    final en = lookupAppLocalizations(const Locale('en'));
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      for (final n in [1, 2, 5]) {
        expect(t.inviteSeatsNeeded(n), contains('$n'), reason: '$locale $n');
        expect(t.inviteSeatsBuy(n), contains('$n'), reason: '$locale $n');
      }
      if (locale.languageCode == 'en') continue;
      expect(t.inviteSeatsNeeded(1), isNot(en.inviteSeatsNeeded(1)), reason: '$locale');
      expect(t.inviteSeatsBuy(2), isNot(en.inviteSeatsBuy(2)), reason: '$locale');
      expect(t.orchardCreateSeatsNote, isNot(en.orchardCreateSeatsNote), reason: '$locale');
      expect(t.teamSeatsWebsiteId('0f0e0d0c'), allOf(contains('0f0e0d0c'), isNot(en.teamSeatsWebsiteId('0f0e0d0c'))),
          reason: '$locale');
      expect(t.teamSeatsBuyHint(r'$75'), allOf(contains(r'$75'), isNot(en.teamSeatsBuyHint(r'$75'))), reason: '$locale');
    }
    expect(en.inviteSeatsNeeded(1), 'Every seat is taken. You need 1 more seat to invite someone.');
    expect(en.inviteSeatsNeeded(2), 'Every seat is taken. You need 2 more seats to invite someone.');
    expect(en.inviteSeatsBuy(1), 'Buy 1 seat');
    expect(en.inviteSeatsBuy(3), 'Buy 3 seats');
    final ru = lookupAppLocalizations(const Locale('ru'));
    expect([ru.inviteSeatsBuy(1), ru.inviteSeatsBuy(2), ru.inviteSeatsBuy(5)],
        ['Купить 1 место', 'Купить 2 места', 'Купить 5 мест']);
  });
}
