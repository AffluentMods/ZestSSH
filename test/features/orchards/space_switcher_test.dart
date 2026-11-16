import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/tree_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/tree_selector.dart';
import 'package:zestssh/utils/redactor.dart';

/// The desktop Tree selector as a space switcher (3.0):
/// it lists your Tree and your Orchards, each paired with plain words, and
/// picking one switches the whole app. Orchards are built behind a switch,
/// so this runs with `--dart-define=ZEST_ORCHARDS=true`.

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';

class _RecordingController extends SpaceController {
  _RecordingController(this._r) : super(_r);

  final Ref _r;
  final switched = <Space>[];

  @override
  Future<void> switchTo(Space space) async {
    switched.add(space);
    _r.read(activeSpaceProvider.notifier).state = space;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('lists the Tree and the Orchards, and switches to the one picked',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    late _RecordingController controller;
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        // The space button reads sync health; a still clock, so its 30-second
        // ticker does not outlive the test.
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 24))),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        treeNameOverrideProvider.overrideWith((ref) => "Alex's Tree"),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        orchardSummariesProvider.overrideWith((ref) async => const [
              OrchardSummary(
                id: _orchard,
                name: 'Acme',
                role: 'owner',
                defaultCrateId: null,
                crates: [],
              ),
            ]),
        spaceControllerProvider.overrideWith((ref) => controller = _RecordingController(ref)),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Align(alignment: Alignment.topLeft, child: TreeSelector())),
      ),
    ));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(TreeSelector)))!;

    // The pill: your Tree, paired with "Personal".
    expect(find.text("Alex's Tree"), findsOneWidget);

    await tester.tap(find.text("Alex's Tree"));
    await tester.pumpAndSettle();
    expect(find.text('Acme'), findsOneWidget);
    expect(find.text(l10n.orchardTeamRole(l10n.orchardRoleOwner)), findsOneWidget);
    expect(find.text(l10n.orchardCreateAction), findsOneWidget);
    expect(find.text(l10n.orchardSyncNow), findsOneWidget);

    await tester.tap(find.text('Acme'));
    await tester.pumpAndSettle();
    expect(controller.switched, [const OrchardSpace(_orchard)]);

    // The pill now shows the Orchard, paired with "Team".
    expect(find.text('Acme'), findsOneWidget);
    expect(find.text(l10n.treeSelectorCrateHostSummary(l10n.orchardTeam, 0)), findsOneWidget);

    // With the Orchard on screen the menu still only switches spaces:
    // running it is the Team page's (3.0).
    await tester.tap(find.text('Acme'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.orchardCreateAction), findsOneWidget);
    for (final gone in [
      l10n.orchardMembers,
      l10n.orchardCrates,
      l10n.orchardRoles,
      l10n.orchardRules,
      l10n.orchardDomains,
      l10n.teamPageSignIn,
      l10n.orchardRenameAction,
      l10n.crateNewAction,
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
  }, skip: !kOrchardsEnabled);

  testWidgets('a dot on the switcher: an invitation to answer, or someone waiting to be added',
      (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Future<void> pump(List<MyInvite> invites, List<OrchardSummary> orchards) async {
      await tester.pumpWidget(ProviderScope(
        key: UniqueKey(),
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
        // The space button reads sync health; a still clock, so its 30-second
        // ticker does not outlive the test.
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 24))),
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
          treeNameOverrideProvider.overrideWith((ref) => "Alex's Tree"),
          connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
          orchardSummariesProvider.overrideWith((ref) async => orchards),
          myInvitesProvider.overrideWith((ref) => invites),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Align(alignment: Alignment.topLeft, child: TreeSelector())),
        ),
      ));
      await tester.pumpAndSettle();
    }

    MyInvite invite({required bool accepted}) => MyInvite(
          id: 'invite-1',
          orchardId: _orchard,
          role: 'member',
          crates: 1,
          expiresAt: DateTime.utc(2026, 10, 8),
          accepted: accepted,
        );
    OrchardSummary acme(int waiting) => OrchardSummary(
          id: _orchard,
          name: 'Acme',
          role: 'owner',
          crates: const [],
          defaultCrateId: null,
          invitesWaiting: waiting,
        );
    final dot = find.byKey(const ValueKey('tree-selector-attention'));

    await pump(const [], [acme(0)]);
    expect(dot, findsNothing);
    await pump([invite(accepted: false)], const []);
    expect(dot, findsOneWidget, reason: 'an invitation to answer');
    await pump([invite(accepted: true)], const []);
    expect(dot, findsNothing, reason: 'accepted: nothing to do but wait to be added');
    await pump(const [], [acme(1)]);
    expect(dot, findsOneWidget, reason: 'someone to compare and add');
  });
}
