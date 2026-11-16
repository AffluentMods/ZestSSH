import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/features/orchards/team/team_seats_sheet.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../../visual/shots_util.dart';

/// The seats sheet in the real fonts, in every language: nothing overflows,
/// in its fullest state either, in a window of a computer's least size. With
/// ZEST_SHOTS the pictures land in build/shots/seats-sheet-*.png.

const _team = '0f0e0d0c-0b0a-4908-8706-050403020100';
const _owner = OrchardSummary(id: _team, name: 'Northwind', role: FixedRoles.owner, crates: [], defaultCrateId: null);

Map<String, Object?> _answer({int bought = 5, int used = 7, Map<String, Object?>? services}) => {
      'seats': {'bought': bought, 'included': 0, 'total': bought, 'used': used, 'free': used > bought ? 0 : bought - used, 'over': used > bought},
      'business_services': services ?? {'state': 'off', 'status': null},
      'prices': {
        'seat_cents': 10000,
        'services_month_cents': 1500,
        'services_year_cents': 15000,
        'max_per_purchase': 250,
        'max_seats': 1000,
        'team_min_seats': 2,
        'team_max_seats': 25,
      },
    };

void main() {
  Future<void> show(
    WidgetTester tester,
    Locale locale, {
    required String shot,
    Size size = const Size(1000, 760),
    Map<String, Object?>? answer,
    String? press,
    double scrollAfter = 0,
    int? need,
  }) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = MockClient((request) async {
      if (request.method == 'GET') return http.Response(jsonEncode(answer ?? _answer()), 200);
      return http.Response(jsonEncode({'url': 'https://checkout.stripe.com/c/pay/cs_test_northwind'}), 201);
    });
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardBillingApiProvider
            .overrideWithValue(OrchardBillingApi(client: client, baseUrl: 'https://api.test/v1', bearer: () async => 'token')),
        billingOnThisDeviceProvider.overrideWithValue(true),
        seatsPageOpenerProvider.overrideWithValue((_) async {}),
        seatsArrivedProvider.overrideWithValue(() {}),
        orchardSummariesProvider.overrideWith((ref) async => const [_owner]),
        currentUserProvider.overrideWithValue(const UserProfile(uid: 'owner-1', email: 'alex@northwind.example')),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById('charcoal').toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => openSeatsSheet(context, ref, _team, need: need),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('seats-sheet')), findsOneWidget);
    if (press != null) {
      await tester.ensureVisible(find.byKey(ValueKey(press)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(press)));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull, reason: '$locale');
    if (shotsEnabled) {
      realShadows();
      await tester.pump();
      await saveShot(tester, key, shot);
      if (scrollAfter != 0) {
        final scrollable = find.ancestor(of: find.byKey(const ValueKey('seats-sheet')), matching: find.byType(Scrollable)).first;
        tester.state<ScrollableState>(scrollable).position.jumpTo(scrollAfter);
        await tester.pump();
        await saveShot(tester, key, '$shot-2');
      }
      plainShadows();
    }
    // The wait of a checkout started here ends with the app.
    await tester.pumpWidget(const SizedBox.shrink());
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('$locale: the sheet with seats short, nothing overflows', (tester) async {
      await show(tester, locale, need: 3, shot: 'seats-sheet-$locale', scrollAfter: 460);
    });

    testWidgets('$locale: the invoice form open', (tester) async {
      await show(tester, locale, press: 'seats-sheet-invoice', shot: 'seats-sheet-invoice-$locale');
    });

    testWidgets('$locale: an invoice waiting, a checkout open, and buying raises the Business bill', (tester) async {
      await show(tester, locale, shot: 'seats-sheet-held-$locale', answer: {
        ..._answer(services: {'state': 'active', 'status': 'active', 'interval': 'year', 'quantity': 5}),
        'held': [
          {'seats': 4, 'kind': 'invoice', 'until': '2030-11-21T12:00:00.000Z'},
          {'seats': 2, 'kind': 'checkout', 'until': '2030-11-21T12:00:00.000Z'},
        ],
      });
    });

    testWidgets('$locale: an invoice past its due date', (tester) async {
      await show(tester, locale, shot: 'seats-sheet-past-due-$locale', answer: {
        ..._answer(),
        'held': [
          {'seats': 4, 'kind': 'invoice', 'until': '2020-11-21T12:00:00.000Z'},
        ],
      });
    });

    testWidgets('$locale: Pay by card asks, with an invoice waiting', (tester) async {
      await show(tester, locale, press: 'seats-sheet-card', shot: 'seats-sheet-card-asks-$locale', answer: {
        ..._answer(),
        'held': [
          {'seats': 4, 'kind': 'invoice', 'until': '2030-11-21T12:00:00.000Z'},
        ],
      });
    });

    testWidgets('$locale: Business over, with days of grace for the first invoice', (tester) async {
      await show(tester, locale,
          shot: 'seats-sheet-grace-owed-$locale',
          answer: _answer(services: {'state': 'off', 'status': 'canceled', 'grace_owed_days': 9}),
          scrollAfter: 460);
    });

    testWidgets('$locale: paying in the browser', (tester) async {
      await show(tester, locale, press: 'seats-sheet-card', shot: 'seats-sheet-waiting-$locale');
    });

    testWidgets('$locale: Business on, in its grace', (tester) async {
      await show(
        tester,
        locale,
        shot: 'seats-sheet-grace-$locale',
        answer: _answer(services: {
          'state': 'grace',
          'status': 'past_due',
          'interval': 'year',
          'quantity': 5,
          'paid_through': '2026-10-01T12:00:00.000Z',
          'works_until': '2026-11-15T12:00:00.000Z',
        }),
      );
    });

    testWidgets('$locale: a window of a phone\'s width (a tablet\'s split view), nothing overflows', (tester) async {
      await show(tester, locale, shot: 'seats-sheet-narrow-$locale', size: const Size(480, 800));
    });
  }
}
