import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/team/join_readiness.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart'
    show billingOnThisDeviceProvider, seatsArrivedProvider, seatsPageOpenerProvider;
import 'package:zestssh/features/orchards/team/team_sync_offer.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show showCreateOrchardDialog;
import 'package:zestssh/features/teams/account_key_service.dart' show AccountKeyStatus;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart' show isSignedInProvider;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart' show debugTopSnackBarOnPhone;

// A team made or joined with sync off (a fresh account
// could not make a team, since the sync it was sent to set up first comes
// from being in a paid team). The keys are made on the device; then the
// person is told how sync comes on: with a seat bought it is included
// (Squeezed and Juiced for everyone in a paid team),
// without one an owner is shown where seats are bought. A code that
// gives a team seats, entered under Redeem a code, goes to a team.

const _id = '0f0e0d0c-0b0a-4908-8706-050403020100';
const _other = '1f0e0d0c-0b0a-4908-8706-050403020101';

class _Sync extends SyncSetupStateService {
  _Sync(this.on) : super(const FlutterSecureStorage());
  final bool on;
  @override
  Future<bool> isSyncActive() async => on;
}

/// The team service as far as Create a team uses it.
class _Service implements OrchardService {
  final made = <String>[];
  @override
  Future<String> createOrchard(String name, {required String firstCrateName, required String memberRoleName}) async {
    made.add(name);
    return _id;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Spaces implements SpaceController {
  final to = <Space>[];
  @override
  Future<void> switchTo(Space space) async => to.add(space);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object?> _billing({required int bought}) => {
      'seats': {'bought': bought, 'included': 0, 'total': bought, 'used': 1, 'free': bought > 0 ? bought - 1 : 0, 'over': bought == 0},
      'business_services': {'state': 'off'},
    };

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  late bool syncOn;
  late int bought;
  late List<String> opened;
  late List<Uri> seatsPages;
  late int refreshed;
  late int ensured;
  late bool keysHere;
  late List<String> redeemed;
  late _Service service;
  late _Spaces spaces;
  late List<OrchardSummary> teams;
  late String? redeemRefused;

  setUp(() {
    // Notices as a phone shows them, on screen (a computer's go to the bell).
    debugTopSnackBarOnPhone = true;
    syncOn = false;
    bought = 0;
    opened = [];
    seatsPages = [];
    refreshed = 0;
    ensured = 0;
    keysHere = false;
    redeemed = [];
    service = _Service();
    spaces = _Spaces();
    teams = const [];
    redeemRefused = null;
  });

  tearDown(() => debugTopSnackBarOnPhone = null);

  Future<void> pump(WidgetTester tester, Widget Function(BuildContext, WidgetRef) button, {bool buysHere = true}) async {
    // Notices close on their own timers: they run out before the test ends.
    addTearDown(() => tester.pump(const Duration(seconds: 15)));
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path.endsWith('/billing/redeem')) {
        if (redeemRefused != null) return http.Response(jsonEncode({'code': redeemRefused, 'maximum': 25}), 409);
        redeemed.add('${request.url.pathSegments[request.url.pathSegments.length - 3]}:${jsonDecode(request.body)['code']}');
        bought = 3;
        return http.Response(jsonEncode({..._billing(bought: 3), 'added': 3}), 200, headers: {'content-type': 'application/json'});
      }
      return http.Response(jsonEncode(_billing(bought: bought)), 200, headers: {'content-type': 'application/json'});
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        isSignedInProvider.overrideWithValue(true),
        syncSetupStateServiceProvider.overrideWith((ref) => _Sync(syncOn)),
        orchardBillingApiProvider.overrideWithValue(
            OrchardBillingApi(client: client, baseUrl: 'https://api.test/v1', bearer: () async => 'token')),
        teamSyncRefreshProvider.overrideWithValue(() async => refreshed++),
        accountPageOpenerProvider.overrideWithValue((_) => opened.add('account')),
        seatsPageOpenerProvider.overrideWithValue((page) async => seatsPages.add(page)),
        billingOnThisDeviceProvider.overrideWithValue(buysHere),
        seatsArrivedProvider.overrideWithValue(() {}),
        orchardServiceProvider.overrideWithValue(service),
        spaceControllerProvider.overrideWithValue(spaces),
        orchardSummariesProvider.overrideWith((ref) async => teams),
        joinPreparerProvider.overrideWithValue(JoinPreparer(
          hasKeys: () async => keysHere,
          ensureKeys: () async {
            ensured++;
            keysHere = true;
            return AccountKeyStatus.ready;
          },
          forgetKeys: () {},
          syncNow: () async {},
        )),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: Consumer(builder: (context, ref, _) => Center(child: button(context, ref)))),
      ),
    ));
  }

  Future<void> createTeam(WidgetTester tester) async {
    await pump(tester, (context, ref) => TextButton(onPressed: () => showCreateOrchardDialog(context, ref), child: const Text('make')));
    await tester.tap(find.text('make'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Acme Ops');
    await tester.tap(find.text(l10n.orchardCreateButton));
    await tester.pumpAndSettle();
  }

  group('Create a team on a fresh account, sync off', () {
    testWidgets('the keys are made, the team is made, and with no seat yet an owner is shown where to add one',
        (tester) async {
      await createTeam(tester);
      expect(ensured, 1, reason: 'the keys are made here, with sync off');
      expect(service.made, ['Acme Ops']);
      expect(spaces.to.single, isA<OrchardSpace>());
      expect(find.textContaining('Your team keys aren'), findsNothing, reason: 'the old dead end is gone');
      expect(find.text(l10n.teamSyncOfferTitle), findsOneWidget);
      expect(find.text(l10n.teamSyncOfferNeedsSeatOwner), findsOneWidget);
      await tester.tap(find.text(l10n.teamSeatsBuy));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('seats-sheet')), findsOneWidget);
      expect(seatsPages, isEmpty, reason: 'bought from inside the app');
      expect(opened, isEmpty);
      expect(refreshed, 0, reason: 'nothing to read again without a seat');
    });

    testWidgets('with a seat already bought: sync is included, and Set up sync opens the account page',
        (tester) async {
      bought = 1;
      await createTeam(tester);
      expect(find.text(l10n.teamSyncOfferIncluded), findsOneWidget);
      expect(refreshed, 1, reason: "the team's sync is read in before setting it up");
      await tester.tap(find.text(l10n.joinSetUpSync));
      await tester.pumpAndSettle();
      expect(opened, ['account']);
      expect(find.text(l10n.teamSyncOfferTitle), findsNothing);
    });

    testWidgets('with sync on already: the team is made and nothing more is asked', (tester) async {
      syncOn = true;
      keysHere = true;
      await createTeam(tester);
      expect(ensured, 0);
      expect(service.made, ['Acme Ops']);
      expect(find.text(l10n.teamSyncOfferTitle), findsNothing);
    });
  });

  testWidgets('a member whose team has no seat yet is told the owners add them, with nothing to buy',
      (tester) async {
    await pump(tester,
        (context, ref) => TextButton(onPressed: () => offerTeamSync(context, ref, _id, owner: false), child: const Text('offer')));
    await tester.tap(find.text('offer'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.teamSyncOfferNeedsSeatMember), findsOneWidget);
    expect(find.text(l10n.teamSeatsBuy), findsNothing);
    await tester.tap(find.text(l10n.close));
    await tester.pumpAndSettle();
    expect(find.text(l10n.teamSyncOfferTitle), findsNothing);
  });

  group('on a phone, where seats are not bought', () {
    testWidgets('an owner with no seat is told where seats are bought: no Buy seats that goes nowhere', (tester) async {
      await pump(tester, buysHere: false,
          (context, ref) => TextButton(onPressed: () => offerTeamSync(context, ref, _id, owner: true), child: const Text('offer')));
      await tester.tap(find.text('offer'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.teamSeatsBuy), findsNothing);
      expect(find.text('${l10n.teamSyncOfferNeedsSeatOwner} ${l10n.teamSeatsOnComputer}'), findsOneWidget);
      expect(find.text(l10n.notNow), findsNothing, reason: 'nothing to say not now to');
      await tester.tap(find.text(l10n.close));
      await tester.pumpAndSettle();
      expect(find.text(l10n.teamSyncOfferTitle), findsNothing);
      expect(find.byKey(const ValueKey('seats-sheet')), findsNothing);
    });

    testWidgets('where the seats are there, sync is still offered', (tester) async {
      bought = 1;
      await pump(tester, buysHere: false,
          (context, ref) => TextButton(onPressed: () => offerTeamSync(context, ref, _id, owner: true), child: const Text('offer')));
      await tester.tap(find.text('offer'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.teamSyncOfferIncluded), findsOneWidget);
      expect(find.text(l10n.joinSetUpSync), findsOneWidget);
    });

    testWidgets('a code that takes the team past what it holds: said without a Buy seats there is none of', (tester) async {
      redeemRefused = 'business-needed-for-seats';
      keysHere = true;
      teams = const [OrchardSummary(id: _id, name: 'Acme Ops', role: 'owner', crates: [], defaultCrateId: null)];
      await pump(tester, buysHere: false,
          (context, ref) => TextButton(onPressed: () => redeemTeamCode(context, ref, 'ZEST-SEAT-0003'), child: const Text('code')));
      await tester.tap(find.text('code'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.redeemTeamCodeAddTo('Acme Ops')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.teamSeatsCodeNeedsBusinessElsewhere(25)), findsOneWidget);
      expect(find.text(l10n.teamSeatsCodeNeedsBusiness(25)), findsNothing);
      expect(l10n.teamSeatsCodeNeedsBusinessElsewhere(25), isNot(contains(l10n.teamSeatsBuy)));
      expect(l10n.teamSeatsCodeNeedsBusiness(25), contains(l10n.teamSeatsBuy), reason: 'on a computer it is there');
    });

    testWidgets('on a computer, the same code says where Business is', (tester) async {
      redeemRefused = 'business-needed-for-seats';
      keysHere = true;
      teams = const [OrchardSummary(id: _id, name: 'Acme Ops', role: 'owner', crates: [], defaultCrateId: null)];
      await pump(tester,
          (context, ref) => TextButton(onPressed: () => redeemTeamCode(context, ref, 'ZEST-SEAT-0003'), child: const Text('code')));
      await tester.tap(find.text('code'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.redeemTeamCodeAddTo('Acme Ops')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.teamSeatsCodeNeedsBusiness(25)), findsOneWidget);
    });
  });

  group('a code for team seats under Redeem a code', () {
    testWidgets('with no team: the new team is named, gets the seats, and its sync is offered', (tester) async {
      await pump(tester,
          (context, ref) => TextButton(onPressed: () => redeemTeamCode(context, ref, 'ZEST-SEAT-0001'), child: const Text('code')));
      await tester.tap(find.text('code'));
      await tester.pumpAndSettle();
      expect(find.textContaining(l10n.redeemTeamCodeNameTeam), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Acme Ops');
      await tester.tap(find.text(l10n.orchardCreateButton));
      await tester.pumpAndSettle();
      expect(service.made, ['Acme Ops']);
      expect(redeemed, ['$_id:ZEST-SEAT-0001']);
      expect(find.text(l10n.teamSeatsCodeAdded(3)), findsOneWidget);
      expect(find.text(l10n.teamSyncOfferIncluded), findsOneWidget, reason: 'the seats include sync');
    });

    testWidgets('with teams of its own: the one chosen gets the seats', (tester) async {
      keysHere = true;
      teams = const [
        OrchardSummary(id: _id, name: 'Acme Ops', role: 'owner', crates: [], defaultCrateId: null),
        OrchardSummary(id: _other, name: 'Lab', role: 'owner', crates: [], defaultCrateId: null),
      ];
      await pump(tester,
          (context, ref) => TextButton(onPressed: () => redeemTeamCode(context, ref, 'ZEST-SEAT-0002'), child: const Text('code')));
      await tester.tap(find.text('code'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.redeemTeamCodeChoose), findsOneWidget);
      expect(find.text(l10n.redeemTeamCodeNewTeam), findsOneWidget);
      await tester.tap(find.text(l10n.redeemTeamCodeAddTo('Lab')));
      await tester.pumpAndSettle();
      expect(redeemed, ['$_other:ZEST-SEAT-0002']);
      expect(service.made, isEmpty);
    });
  });

  test('the notice carries Set up sync and is once per account', () {
    var tapped = 0;
    final n = teamSyncNotification(l10n, 'u1', () => tapped++);
    expect(n.id, teamSyncNoticeId('u1'));
    expect(n.title, l10n.teamSyncOfferTitle);
    expect(n.actionLabel, l10n.joinSetUpSync);
    n.onAction!();
    expect(tapped, 1);
    expect(teamSyncToldKey('u1'), isNot(teamSyncToldKey('u2')));
  });
}
