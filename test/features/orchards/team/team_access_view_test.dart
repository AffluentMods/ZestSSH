import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show kNewRecordKindsVersion, newRecordKindsOn;
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_access_view.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../../helpers/last_line.dart';
import '../../../visual/shots_util.dart';
import '../fake_crate_server.dart';

/// Access on request (3.0) on the Team page, on a real Orchard:
/// someone asks, whoever manages a Crate answers (picking the Crate when the
/// request could not name it) or declines; what was given shows with its
/// end and can be ended; and a member asks, withdraws, and gives up what
/// they were given. Each account has its own device and service against one
/// (fake) server.

const _owner = 'owner-1';
const _alice = 'alice';
const _bob = 'bob';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

class _Device {
  _Device(this.shared, this.uid, this.keys, {_MemoryStorage? storage}) : storage = storage ?? _MemoryStorage() {
    databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: this.storage);
    service = OrchardService(
      server: shared.as(uid),
      databases: databases,
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
  }

  final FakeCrateServer shared;
  final String uid;
  final AccountKeys keys;
  final _MemoryStorage storage;
  late final OrchardDatabasesNotifier databases;
  late final OrchardService service;

  /// The same device with a service and a databases notifier of its own:
  /// a scope disposes the notifier it is given, and this one stays.
  _Device again() => _Device(shared, uid, keys, storage: storage);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    if (i >= 1 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late FakeCrateServer server;
  late _Device owner;
  late _Device alice;
  late _Device bob;
  late String orchardId;
  late String production;
  late String staging;

  Future<void> setUpOrchard(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    await tester.runAsync(() async {
      final devices = <_Device>[];
      for (final uid in [_owner, _alice, _bob]) {
        final keys = await AccountKeys.generate();
        await server.publish(uid, keys, email: '$uid@example.com');
        devices.add(_Device(server, uid, keys));
      }
      [owner, alice, bob] = devices;
      orchardId = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      staging = await owner.service.createCrate(orchardId, 'Staging');
      final member = server.recordOf(orchardId).roles.values.single;
      production = member.crates.keys.single;
      for (final person in [alice, bob]) {
        await owner.service.invite(orchardId, email: '${person.uid}@example.com', role: member.id);
        final invite = (await owner.service.invites(orchardId)).single;
        server.acceptAs(orchardId, invite.id, person.uid);
        await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
        await person.service.refresh();
      }
      await owner.service.refresh();
    });
    addTearDown(() async {
      for (final d in [owner, alice, bob]) {
        for (final db in d.storage.dbs.values) {
          try {
            await db.close();
          } catch (_) {}
        }
      }
    });
  }

  /// Someone else joins the Orchard as [role], on a device of their own.
  Future<_Device> join(String uid, String role) async {
    final keys = await AccountKeys.generate();
    await server.publish(uid, keys, email: '$uid@example.com');
    final device = _Device(server, uid, keys);
    await owner.service.invite(orchardId, email: '$uid@example.com', role: role);
    final invite = (await owner.service.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, uid);
    await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
    await device.service.refresh();
    addTearDown(() async {
      for (final db in device.storage.dbs.values) {
        try {
          await db.close();
        } catch (_) {}
      }
    });
    return device;
  }

  /// The Team page as [as] sees it, on a computer ([phone] false), the
  /// Overview alone on a small phone, or the phone's list of Team pages
  /// ([phoneList]).
  Future<ProviderContainer> pumpTeam(
    WidgetTester tester,
    _Device as, {
    bool phone = false,
    bool phoneList = false,
    Locale locale = const Locale('en'),
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = phone || phoneList ? const Size(360, 640) : const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A scope of its own each time, on a view of the device that is its
    // own too: nothing of an earlier page carries over.
    final view = as.again();
    final summary = (await tester.runAsync(() async {
      await view.service.refresh();
      return readOrchardSummary(await view.databases.open(orchardId), orchardId);
    }))!;
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(view.service),
        orchardDatabasesProvider.overrideWith((ref) => view.databases),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        activeSidebarNavProvider.overrideWith((ref) => NavSection.team),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: phoneList
            ? const TeamPhoneScreen()
            : Scaffold(
                body: phone
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: TeamOverview(orchard: summary, onOpen: (_) {}),
                      )
                    : const TeamView(),
              ),
      ),
    ));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
  }

  /// The number beside the section title [title] (drawn in capitals, as
  /// every section header is), or null when it has none.
  String? sectionCount(WidgetTester tester, String title) {
    final row = find.ancestor(of: find.text(title.toUpperCase()), matching: find.byType(Row)).first;
    final texts = [for (final t in tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))) t.data];
    // The number after the title (not a link at its end).
    return [for (final t in texts.skip(1)) if (t != null && int.tryParse(t) != null) t].firstOrNull;
  }

  /// Whether the dialog on top lets its main action be pressed.
  bool canConfirm(WidgetTester tester) =>
      tester.widget<ZestDialogShell>(find.byType(ZestDialogShell).last).primaryAction!.onPressed != null;

  Finder inKey(String key, Finder f) => find.descendant(of: find.byKey(ValueKey(key)), matching: f);

  bool toasted(ProviderContainer container, WidgetTester tester, String message) =>
      find.text(message).evaluate().isNotEmpty ||
      container.read(notificationCenterProvider).history.any((n) => n.title == message || n.body == message);

  /// Picks [label] in the dropdown keyed [key].
  Future<void> pick(WidgetTester tester, String key, String label) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> ask(WidgetTester tester, _Device who,
          {String? crateId, CrateLevel level = CrateLevel.use, String? note, Duration? duration}) =>
      tester.runAsync(() => who.service.requestAccess(orchardId,
          crateId: crateId, level: level, duration: duration ?? const Duration(hours: 2), note: note));

  RecordTimedGrant? given(String uid, String crateId) => server.recordOf(orchardId).members[uid]!.timed[crateId];

  testWidgets('someone asks: it shows under what needs the owner, who picks the Crate and gives it; then it runs, and is ended',
      (tester) async {
    await setUpOrchard(tester);
    await ask(tester, alice, note: 'Staging, for the release');
    final container = await pumpTeam(tester, owner);
    final request = server.requestsOf(orchardId).single;
    final row = 'team-attn-access-${request.id}';

    expect(inKey(row, find.text(l10n.accessRequestTitle('alice@example.com'))), findsOneWidget);
    final words = [l10n.accessCrateInNote, l10n.crateLevelUse, l10n.settingsInlineHoursOption(2)].join(l10n.listSeparator);
    expect(inKey(row, find.text('$words\nStaging, for the release')), findsOneWidget);
    expect(inKey('team-nav-overview', find.text('2')), findsOneWidget,
        reason: 'counted with what needs the owner, the only owner too');
    // Nothing runs yet: the section offers the way to give access unasked.
    expect(find.byKey(const ValueKey('team-access-give')), findsOneWidget);
    expect(find.byKey(const ValueKey('team-access-ask')), findsNothing, reason: 'an owner has nothing to ask for');

    await tester.tap(inKey(row, find.text(l10n.accessAnswer)));
    await settle(tester);
    expect(find.text(l10n.accessGiveTitle('alice@example.com')), findsOneWidget);
    expect(inKey('access-give-note', find.text('Staging, for the release')), findsOneWidget);
    expect(find.byKey(const ValueKey('access-give-member')), findsNothing, reason: 'the request says who');
    // No Crate yet: nothing to give.
    expect(find.text(l10n.accessGivePickCrate), findsOneWidget);
    await tester.tap(find.text(l10n.accessGiveAction).last);
    await settle(tester);
    expect(given(_alice, staging), isNull);

    await pick(tester, 'access-give-crate', 'Staging');
    expect(find.byKey(const ValueKey('access-give-reveal-note')), findsOneWidget, reason: 'Use shows secrets');
    expect(find.byKey(const ValueKey('access-give-no-certificate')), findsNothing);
    final endsLine = tester.widget<Text>(find.byKey(const ValueKey('access-give-ends'))).data!;
    expect(endsLine, startsWith(l10n.accessGiveEnds('').trim()));
    await tester.tap(find.text(l10n.accessGiveAction).last);
    await settle(tester);

    // Given as asked: Use, for two hours, and the request is done with.
    final grant = given(_alice, staging)!;
    expect(grant.switches, levelSwitches(CrateLevel.use));
    expect(grant.until, closeTo(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200, 30));
    expect(server.requestsOf(orchardId), isEmpty);
    expect(server.entriesOf(orchardId).last.body['req'], request.id);
    expect(find.text(l10n.accessGiveTitle('alice@example.com')), findsNothing, reason: 'the dialog closed');
    expect(toasted(container, tester, l10n.accessGiven('alice@example.com', accessTimeText(grant.until, l10n))), isTrue);
    expect(find.byKey(ValueKey(row)), findsNothing);
    expect(find.byKey(const ValueKey('team-nav-overview')), findsOneWidget);

    // What runs: who and which Crate, how far until when, the time left;
    // and the newest change says so.
    final timed = 'team-access-timed-$_alice-$staging';
    expect(inKey(timed, find.text('alice@example.com · Staging')), findsOneWidget);
    expect(inKey(timed, find.text([l10n.crateLevelUse, l10n.accessUntil(accessTimeText(grant.until, l10n))].join(' · '))),
        findsOneWidget);
    // The time left as the page drew it, a moment ago, or as it reads now:
    // across a minute's turn the two differ ("2h 0m left" then "1h 59m left").
    final now = DateTime.now();
    final left = {
      for (final ago in [0, 5, 10, 20]) accessLeftText(grant.until, l10n, now: now.subtract(Duration(seconds: ago))),
    };
    expect(left.where((text) => inKey(timed, find.text(text)).evaluate().isNotEmpty), hasLength(1), reason: '$left');
    expect(find.text(l10n.teamChangeAccessGiven('alice@example.com', 'Staging')), findsOneWidget);

    // Ended before its time, after asking.
    await tester.tap(inKey(timed, find.text(l10n.accessEndNow)));
    await settle(tester);
    expect(find.text(noOrphan(l10n.accessEndTitle('alice@example.com', 'Staging'))), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(given(_alice, staging), isNotNull, reason: 'Cancel ends nothing');
    await tester.tap(inKey(timed, find.text(l10n.accessEndNow)));
    await settle(tester);
    await tester.tap(find.text(l10n.accessEndConfirm).last);
    await settle(tester);
    expect(given(_alice, staging), isNull);
    expect(find.byKey(ValueKey(timed)), findsNothing);
    expect(toasted(container, tester, l10n.accessEnded), isTrue);
    expect(find.text(l10n.teamChangeAccessEnded('alice@example.com', 'Staging')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a request that names its Crate is answered for that Crate, or declined, and nothing is kept', (tester) async {
    await setUpOrchard(tester);
    await ask(tester, alice, crateId: production, level: CrateLevel.edit, duration: const Duration(minutes: 45));
    final container = await pumpTeam(tester, owner);
    final request = server.requestsOf(orchardId).single;
    final row = 'team-attn-access-${request.id}';
    final words =
        ['Production', l10n.crateLevelEdit, l10n.settingsInlineMinutesOption(45)].join(l10n.listSeparator);
    expect(inKey(row, find.text(words)), findsOneWidget, reason: 'no note: the summary alone');

    await tester.tap(inKey(row, find.text(l10n.accessAnswer)));
    await settle(tester);
    // The Crate is the one asked for and stays so; the time asked for is offered though it is not a usual one.
    expect(tester.widget<ZestSelect<String>>(find.byKey(const ValueKey('access-give-crate'))).onChanged, isNull);
    expect(tester.widget<ZestSelect<String>>(find.byKey(const ValueKey('access-give-crate'))).value, production);
    expect(inKey('access-give-crate', find.text('Production')), findsOneWidget);
    expect(inKey('access-give-duration', find.text(l10n.settingsInlineMinutesOption(45))), findsOneWidget);
    expect(inKey('access-give-level', find.text(l10n.crateLevelEdit)), findsOneWidget);

    await tester.tap(find.text(l10n.accessDecline));
    await settle(tester);
    expect(server.requestsOf(orchardId), isEmpty);
    expect(given(_alice, production), isNull);
    expect(toasted(container, tester, l10n.accessDeclined), isTrue);
    expect(find.byKey(ValueKey(row)), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('giving unasked: the owner picks who, which Crate, how far and for how long', (tester) async {
    await setUpOrchard(tester);
    final container = await pumpTeam(tester, owner);
    await tester.tap(inKey('team-access-give', find.text(l10n.accessGiveAction)));
    await settle(tester);
    expect(find.text(l10n.accessGiveTitleAnyone), findsOneWidget);
    expect(find.text(l10n.accessDecline), findsNothing, reason: 'nothing was asked');
    await pick(tester, 'access-give-member', 'bob@example.com');
    await pick(tester, 'access-give-crate', 'Staging');
    await pick(tester, 'access-give-level', l10n.crateLevelConnect);
    expect(find.byKey(const ValueKey('access-give-reveal-note')), findsNothing, reason: 'Connect shows no secrets');
    await pick(tester, 'access-give-duration', l10n.settingsMobExpiryDays(3));
    await tester.tap(find.text(l10n.accessGiveAction).last);
    await settle(tester);
    final grant = given(_bob, staging)!;
    expect(grant.switches, levelSwitches(CrateLevel.connect));
    expect(grant.until, closeTo(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3 * 86400, 30));
    expect(server.entriesOf(orchardId).last.body.containsKey('req'), isFalse);
    expect(toasted(container, tester, l10n.accessGiven('bob@example.com', accessTimeText(grant.until, l10n))), isTrue);
    expect(find.byKey(ValueKey('team-access-timed-$_bob-$staging')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('giving asks for a recent sign-in first, saying what will happen; backing out gives nothing', (tester) async {
    await setUpOrchard(tester);
    await ask(tester, alice, crateId: production, level: CrateLevel.edit);
    await pumpTeam(tester, owner);
    server.requireRecentSignIn = true;
    await tester.tap(find.text(l10n.accessAnswer));
    await settle(tester);
    await tester.tap(find.text(l10n.accessGiveAction).last);
    await settle(tester);
    expect(find.text(l10n.stepUpTitle), findsOneWidget);
    expect(inKey('step-up-summary', find.text(l10n.accessStepUpWhat('alice@example.com', 'Production'))), findsOneWidget);
    expect(inKey('step-up-summary', find.textContaining(l10n.accessStepUpEffect('').replaceAll('.', '').trim())),
        findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(given(_alice, production), isNull);
    expect(server.requestsOf(orchardId), hasLength(1), reason: 'still waiting');
    // The dialog is still there, to try again or decline.
    expect(find.text(l10n.accessGiveTitle('alice@example.com')), findsOneWidget);
    expect(tester.widget<ZestSelect<CrateLevel>>(find.byKey(const ValueKey('access-give-level'))).onChanged,
        isNotNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('what ZestSSH Cloud refuses is said in words: a clock far behind, and a role with no user name on a Crate with certificates',
      (tester) async {
    await setUpOrchard(tester);
    await tester.runAsync(() async {
      final vault = await owner.service.createCrate(orchardId, 'Owner keys', ownersOnly: true);
      await owner.service.setAuthorityKey(orchardId, staging,
          keyCrate: vault,
          ttlMinutes: 60,
          principals: {
            FixedRoles.owner: ['root'],
          },
          keyLabel: 'Staging authority');
    });
    await ask(tester, alice, note: 'Staging');
    await pumpTeam(tester, owner);
    await tester.tap(find.text(l10n.accessAnswer));
    await settle(tester);
    await pick(tester, 'access-give-crate', 'Staging');
    expect(find.byKey(const ValueKey('access-give-no-certificate')), findsOneWidget,
        reason: 'the Member role signs in as nobody there');
    await pick(tester, 'access-give-crate', 'Production');
    expect(find.byKey(const ValueKey('access-give-no-certificate')), findsNothing);

    // The server's clock is three hours ahead of this device's.
    server.clock = () => DateTime.now().add(const Duration(hours: 3));
    await tester.tap(find.text(l10n.accessGiveAction).last);
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(const ValueKey('access-give-error'))).data, l10n.accessErrorPassed);
    expect(given(_alice, production), isNull);
    server.clock = DateTime.now;
    await tester.tap(find.text(l10n.accessGiveAction).last);
    await settle(tester);
    expect(given(_alice, production), isNotNull);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a member asks from the Team page: for a Crate they cannot name, with a note; it waits, and is withdrawn',
      (tester) async {
    await setUpOrchard(tester);
    final container = await pumpTeam(tester, alice);
    expect(find.byKey(const ValueKey('team-access-give')), findsNothing, reason: 'she manages no Crate');
    await tester.tap(inKey('team-access-ask', find.text(l10n.accessAskAction)));
    await settle(tester);
    expect(find.text(l10n.accessAskSubtitle), findsOneWidget);

    // More in Production (she has Use: Edit is what there is to ask for), or another Crate.
    expect(find.byKey(const ValueKey('access-ask-more')), findsOneWidget);
    expect(inKey('access-ask-crate', find.text('Production')), findsOneWidget);
    expect(inKey('access-ask-level', find.text(l10n.crateLevelEdit)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('access-ask-other')));
    await settle(tester);
    expect(find.byKey(const ValueKey('access-ask-crate')), findsNothing, reason: 'she cannot name it');
    expect(find.byKey(const ValueKey('access-ask-other-help')), findsOneWidget);
    expect(inKey('access-ask-level', find.text(l10n.crateLevelUse)), findsOneWidget);
    // The note as tall as the choices above it, in their type (it was taller,
    // lighter edged and larger, found in a design review).
    final noteField = find.descendant(of: find.byKey(const ValueKey('access-ask-note')), matching: find.byType(TextField));
    final noteBox = find.ancestor(of: noteField, matching: find.byType(Container)).first;
    expect(tester.getSize(noteBox).height, tester.getSize(find.byKey(const ValueKey('access-ask-duration'))).height);
    expect(tester.widget<EditableText>(find.descendant(of: noteField, matching: find.byType(EditableText))).style.fontSize, 13);

    // Without a word nothing is sent.
    await tester.tap(find.text(l10n.accessAskSend));
    await settle(tester);
    expect(server.requestsOf(orchardId), isEmpty);
    expect(inKey('access-ask-note', find.text(l10n.accessAskNoteNeeded)), findsOneWidget);

    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('access-ask-note')), matching: find.byType(EditableText)),
        'Staging, for the release');
    await pick(tester, 'access-ask-duration', l10n.settingsInlineHoursOption(4));
    await tester.tap(find.text(l10n.accessAskSend));
    await settle(tester);
    final request = server.requestsOf(orchardId).single;
    expect((request.uid, request.crateId), (_alice, null));
    expect(toasted(container, tester, l10n.accessAskSent), isTrue);
    expect(find.text(l10n.accessAskSubtitle), findsNothing, reason: 'the dialog closed');

    // It waits, in her words for it; and she takes it back.
    final mine = 'team-access-mine-${request.id}';
    expect(inKey(mine, find.text(l10n.accessMineTitle)), findsOneWidget);
    final words = [l10n.accessCrateInNote, l10n.crateLevelUse, l10n.settingsInlineHoursOption(4)].join(l10n.listSeparator);
    expect(inKey(mine, find.text('$words\n${l10n.accessMineWaiting}')), findsOneWidget);
    await tester.tap(inKey(mine, find.text(l10n.accessWithdraw)));
    await settle(tester);
    expect(server.requestsOf(orchardId), isEmpty);
    expect(find.byKey(ValueKey(mine)), findsNothing);
    expect(toasted(container, tester, l10n.accessWithdrawn), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a member asks for more in a Crate they open, and is told when five already wait', (tester) async {
    await setUpOrchard(tester);
    await pumpTeam(tester, alice);
    await tester.tap(inKey('team-access-ask', find.text(l10n.accessAskAction)));
    await settle(tester);
    await tester.tap(find.text(l10n.accessAskSend));
    await settle(tester);
    final request = server.requestsOf(orchardId).single;
    expect((request.uid, request.crateId), (_alice, production));
    expect((await tester.runAsync(() => owner.service.accessRequests(orchardId)))!.waiting.single.level, CrateLevel.edit);

    // Five wait: the sixth is refused in words.
    await tester.runAsync(() async {
      for (var i = 0; i < 4; i++) {
        final extra = await owner.service.createCrate(orchardId, 'Extra $i');
        await alice.service.requestAccess(orchardId,
            crateId: extra, level: CrateLevel.use, duration: const Duration(hours: 1));
      }
    });
    await tester.tap(inKey('team-access-ask', find.text(l10n.accessAskAction)));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('access-ask-other')));
    await settle(tester);
    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('access-ask-note')), matching: find.byType(EditableText)), 'One more');
    await tester.tap(find.text(l10n.accessAskSend));
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(const ValueKey('access-ask-error'))).data, l10n.accessErrorRequestLimit);
    expect(server.requestsOf(orchardId), hasLength(5));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('what a member was given shows with its end, and they can give it up', (tester) async {
    await setUpOrchard(tester);
    await tester.runAsync(() => owner.service.giveAccess(orchardId,
        uid: _alice, crateId: staging, level: CrateLevel.edit, duration: const Duration(hours: 2)));
    await pumpTeam(tester, alice);
    final until = given(_alice, staging)!.until;
    final timed = 'team-access-timed-$_alice-$staging';
    expect(inKey(timed, find.text('${l10n.teamYou} · Staging')), findsOneWidget);
    expect(inKey(timed, find.text([l10n.crateLevelEdit, l10n.accessUntil(accessTimeText(until, l10n))].join(' · '))),
        findsOneWidget);
    // Bob, who neither manages the Crate nor is her, sees nothing of it.
    await pumpTeam(tester, bob);
    expect(find.byKey(ValueKey(timed)), findsNothing);

    await pumpTeam(tester, alice);
    await tester.tap(inKey(timed, find.text(l10n.accessGiveUp)));
    await settle(tester);
    expect(find.text(noOrphan(l10n.accessGiveUpTitle('Staging'))), findsOneWidget);
    await tester.tap(find.text(l10n.accessGiveUp).last);
    await settle(tester);
    expect(given(_alice, staging), isNull);
    expect(
        toasted(ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)), tester, l10n.accessEnded), isTrue);
    expect(find.byKey(ValueKey(timed)), findsNothing);
    expect(
        (await tester.runAsync(() async =>
            (await (await alice.databases.open(orchardId)).customSelect('SELECT name FROM orchard_crates').get())
                .map((r) => r.read<String?>('name'))
                .toList()))!,
        ['Production'],
        reason: 'it left her device');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('more in a Crate they open shows how far, on the page and on the member', (tester) async {
    await setUpOrchard(tester);
    await tester.runAsync(() => owner.service.giveAccess(orchardId,
        uid: _alice, crateId: production, level: CrateLevel.edit, duration: const Duration(hours: 1)));
    await pumpTeam(tester, owner);
    final until = given(_alice, production)!.until;
    final timed = 'team-access-timed-$_alice-$production';
    expect(inKey(timed, find.text('alice@example.com · Production')), findsOneWidget);
    expect(inKey(timed, find.text([l10n.crateLevelEdit, l10n.accessUntil(accessTimeText(until, l10n))].join(' · '))),
        findsOneWidget);
    // The words for what each kind of line says.
    final access = (await tester.runAsync(() => owner.service.timedAccess(orchardId)))!.single;
    final summary = (await tester.runAsync(
        () async => readOrchardSummary(await owner.databases.open(orchardId), orchardId)))!;
    // (At one and the same moment on both sides: in the last hour of a
    // day, an hour from now is tomorrow, and reads as a day and a time.)
    final at = DateTime.fromMillisecondsSinceEpoch(until * 1000);
    expect(timedAccessSummary(access, summary, l10n, now: at),
        ['Production', l10n.crateLevelEdit, l10n.accessUntil(accessTimeText(until, l10n, now: at))].join(l10n.listSeparator));
    expect(accessDurationText(const Duration(minutes: 90), l10n), l10n.settingsInlineMinutesOption(90));
    expect(accessDurationText(const Duration(hours: 36), l10n), l10n.settingsInlineHoursOption(36));
    expect(accessDurationText(const Duration(days: 2), l10n), l10n.settingsMobExpiryDays(2));
    expect(accessDurationText(const Duration(seconds: 61), l10n), l10n.settingsInlineMinutesOption(2));
    // Later today reads as a time, another day as a day and a time.
    final noon = DateTime(2030, 3, 10, 12);
    expect(accessTimeText(DateTime(2030, 3, 10, 15, 30).millisecondsSinceEpoch ~/ 1000, l10n, now: noon), '3:30 PM');
    expect(accessTimeText(DateTime(2030, 3, 12, 9).millisecondsSinceEpoch ~/ 1000, l10n, now: noon), 'Mar 12 9:00 AM');
  });

  testWidgets('who can be given something and how far: nobody above or beside the giver, nobody suspended, never Manage',
      (tester) async {
    await setUpOrchard(tester);
    late _Device carol;
    await tester.runAsync(() async {
      final member = server.recordOf(orchardId).members[_alice]!.role;
      final guest = await owner.service
          .saveRole(orchardId, name: 'Guest', can: {}, crates: {production: levelSwitches(CrateLevel.connect)});
      carol = await join('carol', member);
      await join('dave', member);
      await join('erin', guest);
      await owner.service.setMemberRole(orchardId, 'carol', FixedRoles.admin);
      await owner.service.suspendMember(orchardId, 'dave');
      await owner.service.setMemberGrants(orchardId, _alice, {staging: levelSwitches(CrateLevel.manage)});
      await alice.service.refresh();
      await carol.service.refresh();
    });
    List<String?> offered(String key) => [
          for (final i in tester.widget<ZestSelect<String>>(find.byKey(ValueKey(key))).items) i.value,
        ];

    // The owner: everyone below admin who is not suspended. Nothing can be
    // given before both a member and a Crate are picked.
    await pumpTeam(tester, owner);
    await tester.tap(inKey('team-access-give', find.text(l10n.accessGiveAction)));
    await settle(tester);
    expect(offered('access-give-member'), unorderedEquals([_alice, _bob, 'erin']));
    expect(offered('access-give-crate'), unorderedEquals([production, staging]));
    expect(canConfirm(tester), isFalse);
    await pick(tester, 'access-give-member', 'bob@example.com');
    expect(canConfirm(tester), isFalse, reason: 'no Crate yet');
    await pick(tester, 'access-give-crate', 'Staging');
    expect(canConfirm(tester), isTrue);
    expect([
      for (final i in tester.widget<ZestSelect<CrateLevel>>(find.byKey(const ValueKey('access-give-level'))).items)
        i.value,
    ], [CrateLevel.connect, CrateLevel.use, CrateLevel.edit]);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    // A Crate and nobody to give it to: nothing to confirm either.
    await tester.tap(inKey('team-access-give', find.text(l10n.accessGiveAction)));
    await settle(tester);
    await pick(tester, 'access-give-crate', 'Staging');
    expect(canConfirm(tester), isFalse, reason: 'no member yet');
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    // Alice, who manages Staging and ranks with bob and dave: only erin,
    // below her, and only that Crate. With one of each, both are set.
    final container = await pumpTeam(tester, alice);
    await tester.tap(inKey('team-access-give', find.text(l10n.accessGiveAction)));
    await settle(tester);
    expect(offered('access-give-member'), ['erin']);
    expect(offered('access-give-crate'), [staging]);
    expect(tester.widget<ZestSelect<String>>(find.byKey(const ValueKey('access-give-member'))).value, 'erin');
    expect(tester.widget<ZestSelect<String>>(find.byKey(const ValueKey('access-give-crate'))).value, staging);
    expect(canConfirm(tester), isTrue);
    await tester.tap(find.text(l10n.accessGiveAction).last);
    await settle(tester);
    final grant = given('erin', staging)!;
    expect(grant.switches, levelSwitches(CrateLevel.use));
    expect(toasted(container, tester, l10n.accessGiven('erin@example.com', accessTimeText(grant.until, l10n))), isTrue);

    // An admin opens every Crate there is to give: nothing to ask for, and
    // the way to give.
    await pumpTeam(tester, carol);
    expect(find.byKey(const ValueKey('team-access-ask')), findsNothing);
    expect(find.byKey(const ValueKey('team-access-give')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('what waits and what runs is counted beside each title, and on the phone beside Overview', (tester) async {
    await setUpOrchard(tester);
    await pumpTeam(tester, owner);
    // Nobody asks: only that the owner is the only one needs them, and
    // nothing runs.
    expect(sectionCount(tester, l10n.teamAttentionTitle), '1', reason: 'the only owner');
    expect(find.byKey(const ValueKey('team-sole-owner')), findsOneWidget);
    expect(find.text(l10n.teamAttentionNone), findsNothing);
    expect(sectionCount(tester, l10n.accessSectionTitle), isNull);

    await ask(tester, alice, note: 'Staging');
    await tester.runAsync(() => owner.service.giveAccess(orchardId,
        uid: _bob, crateId: staging, level: CrateLevel.use, duration: const Duration(hours: 1)));
    await pumpTeam(tester, owner);
    expect(sectionCount(tester, l10n.teamAttentionTitle), '2', reason: 'who asks needs the owner, as before');
    expect(find.text(l10n.teamAttentionNone), findsNothing);
    expect(sectionCount(tester, l10n.accessSectionTitle), '1', reason: 'what runs');

    // Alice: her own request waits, and something she was given runs.
    await tester.runAsync(() => owner.service.giveAccess(orchardId,
        uid: _alice, crateId: staging, level: CrateLevel.connect, duration: const Duration(hours: 1)));
    await pumpTeam(tester, alice);
    expect(sectionCount(tester, l10n.accessSectionTitle), '2');
    expect(sectionCount(tester, l10n.teamAttentionTitle), isNull, reason: 'nothing for her to answer');
    expect(find.text(l10n.teamAttentionNone), findsOneWidget, reason: 'and it says so');

    // The phone's list of Team pages: the number is beside Overview.
    await pumpTeam(tester, owner, phoneList: true);
    expect(inKey('team-phone-overview', find.text('1')), findsOneWidget);
    await pumpTeam(tester, alice, phoneList: true);
    expect(inKey('team-phone-overview', find.text('1')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a note that cannot be opened is said to be one, on the page and when answering', (tester) async {
    await setUpOrchard(tester);
    await ask(tester, alice, note: 'Staging, for the release');
    final request = server.requestsOf(orchardId).single;
    server.spoilRequestNote(orchardId, request.id);
    await pumpTeam(tester, owner);
    final row = 'team-attn-access-${request.id}';
    final words = [l10n.accessCrateInNote, l10n.crateLevelUse, l10n.settingsInlineHoursOption(2)].join(l10n.listSeparator);
    expect(inKey(row, find.text('$words\n${l10n.accessRequestNoteUnread}')), findsOneWidget);
    expect(find.textContaining('for the release'), findsNothing);

    await tester.tap(inKey(row, find.text(l10n.accessAnswer)));
    await settle(tester);
    expect(find.byKey(const ValueKey('access-give-note')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const ValueKey('access-give-note-unread'))).data, l10n.accessRequestNoteUnread);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    // A request with no note at all says nothing about one.
    await ask(tester, bob, crateId: production, level: CrateLevel.edit);
    await pumpTeam(tester, owner);
    final plain = server.requestsOf(orchardId).firstWhere((r) => r.uid == _bob);
    await tester.tap(inKey('team-attn-access-${plain.id}', find.text(l10n.accessAnswer)));
    await settle(tester);
    expect(find.byKey(const ValueKey('access-give-note')), findsNothing);
    expect(find.byKey(const ValueKey('access-give-note-unread')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('asking: the level someone picked stays while it can be asked for', (tester) async {
    await setUpOrchard(tester);
    await pumpTeam(tester, alice);
    await tester.tap(inKey('team-access-ask', find.text(l10n.accessAskAction)));
    await settle(tester);
    CrateLevel? level() =>
        tester.widget<ZestSelect<CrateLevel>>(find.byKey(const ValueKey('access-ask-level'))).value;
    Future<void> choose(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await settle(tester);
    }

    // More in Production, where she has Use: only Edit is left to ask for.
    expect(level(), CrateLevel.edit);
    // Another Crate: Use, unless she picks.
    await choose('access-ask-other');
    expect(level(), CrateLevel.use);
    await pick(tester, 'access-ask-level', l10n.crateLevelEdit);
    await choose('access-ask-more');
    expect(level(), CrateLevel.edit);
    await choose('access-ask-other');
    expect(level(), CrateLevel.edit, reason: 'her pick, which can be asked for here too');
    // A pick that cannot be asked for there gives way, and does not come back.
    await pick(tester, 'access-ask-level', l10n.crateLevelConnect);
    await choose('access-ask-more');
    expect(level(), CrateLevel.edit);
    await choose('access-ask-other');
    expect(level(), CrateLevel.use);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
  });

  testWidgets('the warning about certificates shows only when the Crate signs people in and the role has no user name there',
      (tester) async {
    await setUpOrchard(tester);
    late String memberRole;
    await tester.runAsync(() async {
      memberRole = server.recordOf(orchardId).members[_alice]!.role;
      final vault = await owner.service.createCrate(orchardId, 'Owner keys', ownersOnly: true);
      await owner.service.setAuthorityKey(orchardId, staging,
          keyCrate: vault,
          ttlMinutes: 60,
          principals: {
            FixedRoles.owner: ['root'],
          },
          keyLabel: 'Staging authority');
    });
    Future<bool> warns() async {
      await pumpTeam(tester, owner);
      await tester.tap(inKey('team-access-give', find.text(l10n.accessGiveAction)));
      await settle(tester);
      await pick(tester, 'access-give-member', 'alice@example.com');
      await pick(tester, 'access-give-crate', 'Staging');
      final shown = find.byKey(const ValueKey('access-give-no-certificate')).evaluate().isNotEmpty;
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      return shown;
    }

    expect(await warns(), isTrue, reason: 'the Member role signs in as nobody there');
    // Her role gets a user name: she would connect.
    await tester.runAsync(() => owner.service.changeAuthority(orchardId, staging, ttlMinutes: 60, principals: {
          FixedRoles.owner: ['root'],
          memberRole: ['deploy'],
        }));
    expect(await warns(), isFalse);
    // No user name again, and the authority turned off: nothing there asks for a certificate.
    await tester.runAsync(() async {
      await owner.service.changeAuthority(orchardId, staging, ttlMinutes: 60, principals: {
        FixedRoles.owner: ['root'],
      });
      await owner.service.turnAuthorityOff(orchardId, staging);
    });
    expect(await warns(), isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the member panel shows what someone may do in each vault now, with the end of what was given for a time',
      (tester) async {
    // The app's font: the table's columns are as wide as their words, and
    // the test's own font (each letter a full square) would stack them.
    await tester.runAsync(() async {
      final loader = FontLoader('GeistSans');
      for (final f in ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf']) {
        loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
      }
      await loader.load();
    });
    await setUpOrchard(tester);
    await tester.runAsync(() async {
      // More in Production (Edit over her Use), and nothing more in Staging
      // for bob, who is given what his role lacks there entirely. Hers ends
      // on another day, which is written with its date: the longest this
      // line gets. (Given for an hour, it ended on another day only when the
      // test ran in the last hour of a day, and ran out of its row then.)
      await owner.service.giveAccess(orchardId,
          uid: _alice, crateId: production, level: CrateLevel.edit, duration: const Duration(days: 2));
      await owner.service.giveAccess(orchardId,
          uid: _bob, crateId: production, level: CrateLevel.connect, duration: const Duration(hours: 1));
    });
    final container = await pumpTeam(tester, owner, theme: ThemeData(fontFamily: 'GeistSans'));
    container.read(teamPageProvider.notifier).state = TeamPage.members;
    await settle(tester);
    String text(Key key) => tester.widget<Text>(find.byKey(key)).data!;

    await tester.tap(find.byKey(const ValueKey('member-$_alice')));
    await settle(tester);
    final until = given(_alice, production)!.until;
    // Her role's Use, nothing set apart, and Edit on top until it ends.
    expect(text(ValueKey('vault-from-$production')), l10n.crateLevelUse);
    expect(text(ValueKey('vault-timed-$production')),
        [l10n.crateLevelEdit, l10n.accessUntil(accessTimeText(until, l10n))].join(l10n.listSeparator));
    expect(tester.widget<ZestSelect<Object?>>(find.byKey(ValueKey('vault-pick-$production'))).accent, isFalse);
    expect(text(ValueKey('vault-from-$staging')), l10n.crateLevelNone);
    expect(find.byKey(ValueKey('vault-timed-$staging')), findsNothing);
    // Each stands inside its row, the name with room beside the columns.
    final row = find.byKey(ValueKey('vault-row-$production'));
    final name = find.descendant(of: row, matching: find.text('Production'));
    for (final part in [
      find.byKey(ValueKey('vault-timed-$production')),
      find.byKey(ValueKey('vault-from-$production')),
      find.byKey(ValueKey('vault-pick-$production')),
    ]) {
      expect(tester.getRect(part).right, lessThanOrEqualTo(tester.getRect(row).right + 0.01));
      expect(tester.getRect(part).left, greaterThanOrEqualTo(tester.getRect(row).left - 0.01));
    }
    expect(tester.getRect(find.byKey(ValueKey('vault-from-$production'))).left - tester.getRect(name).right,
        greaterThanOrEqualTo(7.99));
    expect(tester.getSize(name).width, greaterThan(40));

    // Bob was given less than he has anyway: what he has, and no end.
    await tester.tap(find.byKey(const ValueKey('member-$_bob')));
    await settle(tester);
    expect(given(_bob, production), isNotNull);
    expect(text(ValueKey('vault-from-$production')), l10n.crateLevelUse);
    expect(find.byKey(ValueKey('vault-timed-$production')), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  // Vault access per member:
  // each pick is made from the panel at once, the first of a
  // new kind after the question about older versions, No access after its
  // own.
  Future<void> choose(WidgetTester tester, String crateId, VaultPick pick) async {
    await tester.ensureVisible(find.byKey(ValueKey('vault-pick-$crateId')));
    await tester.tap(find.byKey(ValueKey('vault-pick-$crateId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('zest-select-item-$pick')));
    await settle(tester);
  }

  ZestSelect<VaultPick> vaultSelect(WidgetTester tester, String crateId) =>
      tester.widget<ZestSelect<VaultPick>>(find.byKey(ValueKey('vault-pick-$crateId')));

  testWidgets('Vault access: held to Connect after the one question about older versions, taken away, raised, put back',
      (tester) async {
    await setUpOrchard(tester);
    final container = await pumpTeam(tester, owner);
    container.read(teamPageProvider.notifier).state = TeamPage.members;
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('member-$_alice')));
    await settle(tester);
    RecordMember held() => server.recordOf(orchardId).members[_alice]!;
    expect(vaultSelect(tester, production).value, VaultPick.fromRole);
    expect(vaultSelect(tester, production).accent, isFalse);

    // Below her role (Use): the first change of a new kind in the team asks
    // first, and Cancel changes nothing.
    await choose(tester, production, VaultPick.connect);
    expect(find.text(l10n.newKindsTitle(kNewRecordKindsVersion)), findsOneWidget);
    expect(find.text(l10n.newKindsBody), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(held().limits, isEmpty);
    expect(server.appends.where((a) => a.contains(RecordTypes.memberLimit)), isEmpty);

    await choose(tester, production, VaultPick.connect);
    await tester.tap(find.text(l10n.newKindsConfirm));
    await settle(tester);
    expect(held().limits[production], levelSwitches(CrateLevel.connect));
    expect(vaultSelect(tester, production).value, VaultPick.connect);
    expect(vaultSelect(tester, production).accent, isTrue, reason: 'set for her, apart from her role');
    expect(toasted(container, tester, l10n.orchardChangeSaved), isTrue);

    // Asked once in a team. No access asks its own question, in its words.
    await choose(tester, production, VaultPick.none);
    expect(find.text(l10n.newKindsTitle(kNewRecordKindsVersion)), findsNothing);
    expect(find.text(l10n.vaultNoAccessTitle('Production', '$_alice@example.com')), findsOneWidget);
    expect(find.text(l10n.vaultNoAccessBody('$_alice@example.com')), findsOneWidget);
    await tester.tap(find.text(l10n.vaultNoAccessConfirm));
    await settle(tester);
    expect(held().limits[production], isEmpty);
    expect(server.recordOf(orchardId).switchesOf(_alice, production), isEmpty);
    expect(vaultSelect(tester, production).value, VaultPick.none);

    // Above her role: extra access, the limit gone in the same change.
    await choose(tester, production, VaultPick.edit);
    expect(held().limits, isEmpty);
    expect(held().grants[production], levelSwitches(CrateLevel.edit));
    expect(server.appends.last, [RecordTypes.memberSet, RecordTypes.memberLimit]);

    // From role: as her role gives, nothing set apart.
    await choose(tester, production, VaultPick.fromRole);
    expect(held().grants, isEmpty);
    expect(held().limits, isEmpty);
    expect(vaultSelect(tester, production).accent, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Vault access before new kinds are on: lower is not offered, and the panel says why', (tester) async {
    await setUpOrchard(tester);
    server.newRecordKinds = false;
    addTearDown(() => newRecordKindsOn.value = true);
    final container = await pumpTeam(tester, owner);
    container.read(teamPageProvider.notifier).state = TeamPage.members;
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('member-$_alice')));
    await settle(tester);
    expect(newRecordKindsOn.value, isFalse);
    expect(find.text(l10n.vaultAccessNotYet(kNewRecordKindsVersion)), findsOneWidget);
    final picks = [for (final i in vaultSelect(tester, production).items) i.value];
    expect(picks, [VaultPick.fromRole, VaultPick.edit, VaultPick.manage]);
    // Extra access still works as before.
    await choose(tester, production, VaultPick.edit);
    expect(server.recordOf(orchardId).members[_alice]!.grants[production], levelSwitches(CrateLevel.edit));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('in every language, on a computer and on a small phone: the page, asking and answering, nothing clipped',
      (tester) async {
    await tester.runAsync(() async {
      final loader = FontLoader('GeistSans');
      for (final f in ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf']) {
        loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
      }
      await loader.load();
    });
    final theme = ThemeData(fontFamily: 'GeistSans');
    await setUpOrchard(tester);
    await tester.runAsync(() async {
      // Everything at once: a request with a long note, something running,
      // and a request of bob's own for him to see waiting.
      await alice.service.requestAccess(orchardId,
          level: CrateLevel.edit,
          duration: const Duration(days: 30),
          note: 'The staging database, to run the migration for the release on Thursday and check it afterwards');
      await owner.service.giveAccess(orchardId,
          uid: _bob, crateId: staging, level: CrateLevel.edit, duration: const Duration(days: 3));
      await bob.service.requestAccess(orchardId,
          crateId: production, level: CrateLevel.edit, duration: const Duration(hours: 8), note: 'On call this week');
    });
    Future<void> open(Finder button, String what) async {
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: what);
    }

    Future<void> close(AppLocalizations t) async {
      await tester.tap(find.text(t.cancel).last);
      await settle(tester);
    }

    try {
     for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      for (final phone in [false, true]) {
        final where = '$locale ${phone ? 'phone' : 'computer'}';
        // On a phone the dialogs are sheets, as on a real one.
        debugDefaultTargetPlatformOverride = phone ? TargetPlatform.android : null;
        // The owner: two requests to answer, one grant running, the way to give.
        await pumpTeam(tester, owner, phone: phone, locale: locale, theme: theme);
        expect(tester.takeException(), isNull, reason: '$where: the owner page');
        expect(find.text(t.accessSectionTitle.toUpperCase()), findsOneWidget, reason: where);
        expect(find.text(t.accessAnswer), findsNWidgets(2), reason: where);
        await open(find.text(t.accessAnswer).first, '$where: answering');
        expect(find.byKey(const ValueKey('access-give-crate')), findsOneWidget, reason: where);
        await close(t);
        if (phone) {
          await open(inKey('team-access-give', find.text(t.accessGiveAction)), '$where: giving unasked');
          await close(t);
          await open(find.text(t.accessEndNow).first, '$where: ending');
          await close(t);
        }

        // Bob: his request waiting, what he was given, the way to ask.
        await pumpTeam(tester, bob, phone: phone, locale: locale, theme: theme);
        expect(tester.takeException(), isNull, reason: '$where: the member page');
        expect(find.text(t.accessMineTitle), findsOneWidget, reason: where);
        expect(find.text('${t.teamYou} · Staging'), findsOneWidget, reason: where);
        if (phone) {
          await open(inKey('team-access-ask', find.text(t.accessAskAction)), '$where: asking');
          await tester.tap(find.byKey(const ValueKey('access-ask-other')));
          await settle(tester);
          await tester.tap(find.text(t.accessAskSend));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where: asking without a word');
          expect(find.text(t.accessAskNoteNeeded), findsOneWidget, reason: where);
          await close(t);
        }
      }
     }
     await tester.pump(const Duration(seconds: 5));
     await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  // Last in this file: it loads the app's fonts, which every test after it
  // would measure with.
  testWidgets('ending someone\'s access: its question leaves no word alone on a line', (tester) async {
    // ("End noa@example.com's access to Staging" over "now?": a design
    // review, with its picture's names.)
    await tester.runAsync(loadShotFonts);
    await setUpOrchard(tester);
    final container = await pumpTeam(tester, owner, theme: BuiltInThemes.getById('default_light').toThemeData());
    final page = tester.element(find.byType(TeamView));
    final orchard = container.read(activeOrchardProvider).value!;
    final access = TimedAccess(
      uid: 'noa',
      crateId: staging,
      adds: const {},
      level: CrateLevel.edit,
      until: DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000,
      wholeCrate: false,
      canEnd: true,
    );
    unawaited(endTimedAccess(page, page as WidgetRef, orchard, access, name: 'noa@example.com', mine: false));
    await settle(tester);
    expectNoOrphan(tester, findWords(l10n.accessEndTitle('noa@example.com', 'Staging')));
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
  });
}
