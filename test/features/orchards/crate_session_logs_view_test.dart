import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/orchards/widgets/crate_session_logs_view.dart';
import 'package:zestssh/features/orchards/widgets/team_logged_indicator.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/phone_host_card.dart';

import 'fake_crate_server.dart';
import 'package:zestssh/l10n/time_text.dart';

/// Team session logs on screen (3.0): owners switch them on a
/// Crate's row after a yes that says what they mean; everyone else sees that
/// sessions there are logged; owners and managers open the logs, read one,
/// copy it, and owners delete one; a logged session says so in its header
/// and on phones; a host whose sessions are logged says so before connecting.

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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  late OrchardService owner;
  late OrchardService alice;
  late String orchardId;
  late String crateId;
  final storages = <_MemoryStorage>[];
  WidgetTester? tester0;
  final devices = <OrchardService, ({_MemoryStorage storage, String uid})>{};

  setUpAll(() async {
    for (final uid in ['owner-1', 'alice']) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final s in storages) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    storages.clear();
  });

  OrchardService onStorage(_MemoryStorage storage, String uid) {
    final service = OrchardService(
      server: server.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys[uid]!),
    );
    devices[service] = (storage: storage, uid: uid);
    return service;
  }

  OrchardService serviceFor(String uid) {
    final storage = _MemoryStorage();
    storages.add(storage);
    return onStorage(storage, uid);
  }

  Future<void> sync(OrchardService s) =>
      OrchardSyncCoordinator(service: s, server: s.server, databases: s.databases).syncAll();

  Future<AppDatabase> ownerDb() => owner.databases.open(orchardId);


  /// Acme with the owner and alice (a member who may only use Production),
  /// recording [tracking]; web1 made, renamed [renames] times, then deleted
  /// when [deleted].
  Future<void> build(WidgetTester tester,
          {RecordTracking tracking = RecordTracking.none, List<String> renames = const [], bool deleted = false}) =>
      tester.runAsync(() async {
        server = FakeCrateServer(accountUid: 'owner-1');
        for (final uid in keys.keys) {
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        owner = serviceFor('owner-1');
        alice = serviceFor('alice');
        orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        crateId = server.recordOf(orchardId).roles.values.single.crates.keys.single;
        await owner.invite(orchardId, email: 'alice@example.com', role: server.recordOf(orchardId).roles.values.single.id);
        server.acceptAs(orchardId, (await owner.invites(orchardId)).single.id, 'alice');
        await owner.confirmInvite(orchardId, (await owner.invites(orchardId)).single);
        if (!tracking.isNone) await owner.setTracking(orchardId, tracking);
        final db = await ownerDb();
        await db.customStatement(
            "INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES ('web1', 'Web 1', 'web1.example.com', 22, 0, 0)");
        await sync(owner);
        for (final label in renames) {
          await db.customStatement("UPDATE connections SET label = ? WHERE id = 'web1'", [label]);
          await sync(owner);
        }
        if (deleted) {
          await db.customStatement("DELETE FROM connections WHERE id = 'web1'");
          await sync(owner);
        }
        await owner.refresh();
        await alice.refresh();
        await sync(alice);
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
      if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  Future<void> pump(WidgetTester tester, OrchardService as, Widget Function(OrchardSummary, CrateSummary) child,
      {List<Override> extra = const []}) async {
    final device = devices[as]!;
    as = onStorage(device.storage, device.uid);
    late OrchardSummary summary;
    await tester.runAsync(() async => summary = await readOrchardSummary(await as.databases.open(orchardId), orchardId));
    final crate = summary.crates.firstWhere((c) => c.id == crateId);
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final me = device.uid;
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(as),
        orchardDatabasesProvider.overrideWith((ref) => as.databases),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        orchardAuthorProvider.overrideWithValue(OrchardAuthorSource(() async => CrateAuthor(uid: me, keys: keys[me]!))),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        currentUserProvider.overrideWithValue(UserProfile(uid: me, email: '$me@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ...extra,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: child(summary, crate))),
      ),
    ));
    await settle(tester);
  }


  Future<void> logSession(String text) => tester0!.runAsync(() async {
        final writer = await alice.startTeamSessionLog(orchardId, crateId,
            label: 'Web 1', host: 'web1.example.com', port: 22, user: 'deploy', connectionId: 'web1');
        writer!.append(text);
        await writer.close();
      });

  testWidgets('owners switch session logs after a yes that says what they mean; a member sees they are on', (tester) async {
    tester0 = tester;
    await build(tester);
    await pump(tester, owner, (o, c) => CrateSessionLogsLine(orchard: o, crate: c));
    final chip = find.byKey(ValueKey('crate-session-logs-$crateId'));
    expect(tester.widget<ZestSwitch>(chip).value, isFalse);
    expect(find.byKey(ValueKey('crate-session-logs-open-$crateId')), findsNothing, reason: 'off: nothing to read');

    await tester.tap(chip);
    await settle(tester);
    expect(find.text(l10n.crateSessionLogsOnTitle('Production')), findsOneWidget);
    expect(find.textContaining('terminal output may still contain sensitive information'), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).crates[crateId]!.sessionLogs, isFalse, reason: 'declined: nothing sent');
    await tester.tap(chip);
    await settle(tester);
    await tester.tap(find.text(l10n.crateSessionLogsTurnOn).last);
    await settle(tester);
    expect(server.recordOf(orchardId).crates[crateId]!.sessionLogs, isTrue);
    await tester.pump(const Duration(seconds: 10));

    // The owner reads them; alice, who may only use the Crate, is told they
    // are on and neither switches nor reads them.
    await pump(tester, owner, (o, c) => CrateSessionLogsLine(orchard: o, crate: c));
    expect(find.byKey(ValueKey('crate-session-logs-open-$crateId')), findsOneWidget);
    // The switch at the end of the row, View logs under the words (the
    // switch sat right after the button).
    final open = tester.getRect(find.byKey(ValueKey('crate-session-logs-open-$crateId')));
    expect(open.top, greaterThan(tester.getRect(find.text(l10n.vaultUiSessionLogsHelp)).bottom));
    expect(tester.getRect(chip).left, greaterThan(open.right + 40));
    // Level with the words, above the button's middle (a finger's 48 high
    // switch reaches a little past its top, the 4.0 accessibility pass).
    expect(tester.getRect(chip).center.dy, lessThan(open.center.dy));
    await tester.runAsync(() async {
      await alice.refresh();
      await sync(alice);
    });
    await pump(tester, alice, (o, c) => CrateSessionLogsLine(orchard: o, crate: c));
    expect(find.byKey(ValueKey('crate-sessions-logged-$crateId')), findsOneWidget);
    expect(find.byKey(ValueKey('crate-session-logs-$crateId')), findsNothing);
    expect(find.byKey(ValueKey('crate-session-logs-open-$crateId')), findsNothing);

    // Off again, after a yes that says the logs go.
    await pump(tester, owner, (o, c) => CrateSessionLogsLine(orchard: o, crate: c));
    await tester.tap(chip);
    await settle(tester);
    expect(find.text(l10n.crateSessionLogsOffBody), findsOneWidget);
    await tester.tap(find.text(l10n.crateSessionLogsTurnOff).last);
    await settle(tester);
    expect(server.recordOf(orchardId).crates[crateId]!.sessionLogs, isFalse);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('owners and managers open the logs, read one, copy it; owners delete one', (tester) async {
    tester0 = tester;
    await build(tester);
    await tester.runAsync(() async {
      await owner.setCrateSessionLogs(orchardId, crateId, true);
      await alice.refresh();
      await sync(alice);
    });
    await logSession('deploy@web1:~\$ uptime\r\n 12:00 up 3 days\r\n');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await pump(tester, owner, (o, c) => CrateSessionLogsView(orchard: o, crate: c));
    final logId = server.sessionLogRows[crateId]!.single.id;
    expect(find.text(l10n.sessionLogRowTitle('alice@example.com', 'Web 1')), findsOneWidget);
    expect(find.textContaining(l10n.sessionLogNotClosed), findsNothing, reason: 'it ended properly');

    await tester.tap(find.byKey(ValueKey('session-log-open-$logId')));
    await settle(tester);
    expect(find.text('deploy@web1:~\$ uptime\n 12:00 up 3 days\n'), findsOneWidget);
    expect(find.byKey(const ValueKey('session-log-incomplete')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('session-log-copy')));
    await settle(tester);
    expect(copied, 'deploy@web1:~\$ uptime\n 12:00 up 3 days\n');

    // Declined: kept.
    await tester.tap(find.byKey(const ValueKey('session-log-delete')));
    await settle(tester);
    expect(find.text(l10n.sessionLogDeleteBody), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.sessionLogRows[crateId], hasLength(1));
    await tester.tap(find.byKey(const ValueKey('session-log-delete')));
    await settle(tester);
    expect(find.text(l10n.sessionLogDeleteBody), findsOneWidget);
    await tester.tap(find.text(l10n.sessionLogDelete).last);
    await settle(tester);
    expect(server.sessionLogRows[crateId], isEmpty);
    expect(find.byKey(ValueKey('session-log-$logId')), findsNothing);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a log cut short says so; an admin reads it, only owners delete', (tester) async {
    tester0 = tester;
    await build(tester);
    await tester.runAsync(() async {
      await owner.setCrateSessionLogs(orchardId, crateId, true);
      await owner.setMemberRole(orchardId, 'alice', FixedRoles.admin);
      await alice.refresh();
      await sync(alice);
      // Its device went away before it ended: never closed.
      final writer = await alice.startTeamSessionLog(orchardId, crateId,
          label: 'Web 1', host: 'web1.example.com', port: 22, flushEvery: const Duration(hours: 1));
      writer!.append('uptime\n');
      await writer.flush();
    });
    await pump(tester, alice, (o, c) => CrateSessionLogsView(orchard: o, crate: c));
    final logId = server.sessionLogRows[crateId]!.single.id;
    expect(find.textContaining(l10n.sessionLogNotClosed), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('session-log-open-$logId')));
    await settle(tester);
    expect(find.byKey(const ValueKey('session-log-incomplete')), findsOneWidget);
    expect(find.text('uptime\n'), findsOneWidget);
    expect(find.byKey(const ValueKey('session-log-copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-log-delete')), findsNothing, reason: 'owners delete');
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a log the server took well after its session began says when it was taken, and why', (tester) async {
    tester0 = tester;
    await build(tester);
    await tester.runAsync(() async {
      await owner.setCrateSessionLogs(orchardId, crateId, true);
      await alice.refresh();
      await sync(alice);
    });
    // One sent as its session ran, and one of a session three hours back
    // that its device kept until now.
    await logSession('sent at once');
    addTearDown(() => OrchardService.debugNow = DateTime.now);
    OrchardService.debugNow = () => DateTime.now().subtract(const Duration(hours: 3));
    await logSession('kept for three hours');
    OrchardService.debugNow = DateTime.now;

    await pump(tester, owner, (o, c) => CrateSessionLogsView(orchard: o, crate: c));
    final rows = server.sessionLogRows[crateId]!;
    final when = DateFormat.yMMMd('en').add_jm();
    expect(find.byKey(ValueKey('session-log-later-${rows[0].id}')), findsNothing, reason: 'sent at once: nothing to say');
    final later = find.byKey(ValueKey('session-log-later-${rows[1].id}'));
    expect(tester.widget<Text>(later).data, l10n.sessionLogReceivedLater(when.formatPlain(rows[1].startedAt.toLocal())));
    expect(tester.widget<Tooltip>(find.ancestor(of: later, matching: find.byType(Tooltip))).message,
        l10n.sessionLogReceivedLaterHint);
    // The row still says when the session was, by its device's clock.
    late TeamSessionLogEntry kept;
    await tester.runAsync(() async =>
        kept = (await owner.teamSessionLogs(orchardId, crateId)).entries.firstWhere((e) => e.id == rows[1].id));
    expect(rows[1].startedAt.difference(kept.header.startedAt).inMinutes, inInclusiveRange(179, 181));
    expect(
        find.descendant(
            of: find.byKey(ValueKey('session-log-${rows[1].id}')),
            matching: find.textContaining(when.formatPlain(kept.header.startedAt.toLocal()))),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  test('the words for a log taken later, in every language: when, and why', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      expect(t.sessionLogReceivedLater('12:00'), contains('12:00'), reason: '$locale');
      expect(t.sessionLogReceivedLater('12:00').replaceAll('12:00', '').trim(), isNotEmpty, reason: '$locale');
      expect(t.sessionLogReceivedLaterHint, contains('ZestSSH Cloud'), reason: '$locale');
      expect(t.sessionLogReceivedLaterHint, isNot(t.sessionLogReceivedLater('')), reason: '$locale');
    }
  });

  testWidgets('a logged session says so in its header and on phones, for as long as it is', (tester) async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('en'),
      home: Scaffold(body: Column(children: [TeamLoggedChip(sessionId: 's1'), TeamLoggedStrip(sessionId: 's1')])),
    ));
    expect(find.byKey(const ValueKey('team-logged-s1')), findsNothing);
    TeamSessionLogs.expect('s1');
    await tester.pump();
    expect(find.byKey(const ValueKey('team-logged-s1')), findsOneWidget);
    expect(find.text(l10n.sessionLoggedTooltip), findsOneWidget, reason: 'the phone strip says what is left out');
    await tester.runAsync(() => TeamSessionLogs.end('s1'));
    await tester.pump();
    expect(find.byKey(const ValueKey('team-logged-s1')), findsNothing);
    expect(find.byKey(const ValueKey('team-logged-strip-s1')), findsNothing);
  });

  testWidgets('a logged remote screen says what its log holds, not what a terminal\'s does: how the session went, '
      'never the picture; an RDP host\'s names the account too', (tester) async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('en'),
      home: Scaffold(
          body: Column(children: [
        TeamLoggedChip(sessionId: 's1'),
        TeamLoggedChip(sessionId: 's2', screen: LoggedScreen.vnc),
        TeamLoggedChip(sessionId: 's3', screen: LoggedScreen.rdp, overPicture: true),
      ])),
    ));
    for (final id in ['s1', 's2', 's3']) {
      TeamSessionLogs.expect(id);
    }
    await tester.pump();
    Tooltip tooltip(String id) =>
        tester.widget<Tooltip>(find.ancestor(of: find.byKey(ValueKey('team-logged-$id')), matching: find.byType(Tooltip)));
    expect(tooltip('s1').message, l10n.sessionLoggedTooltip);
    expect(tooltip('s2').message, l10n.screenSessionLoggedTooltip);
    expect(tooltip('s3').message, l10n.screenSessionLoggedTooltipRdp);
    expect(tooltip('s2').message, allOf(contains('picture'), isNot(contains('terminal output'))));
    expect(tooltip('s3').message, contains('the account that signed in'));
    // Over a picture (a phone's): a tap shows the words, where a pointer cannot rest.
    expect(tooltip('s3').triggerMode, TooltipTriggerMode.tap);
    expect(tooltip('s2').triggerMode, isNull);

    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      expect(sessionLoggedText(words, waits: false, screen: LoggedScreen.vnc), words.screenSessionLoggedTooltip);
      expect(sessionLoggedText(words, waits: true, screen: LoggedScreen.rdp),
          '${words.screenSessionLoggedTooltipRdp} ${words.sessionLoggedWaiting}');
      // The RDP words are the screen's with the account added, in every language.
      expect(words.screenSessionLoggedTooltipRdp.length, greaterThan(words.screenSessionLoggedTooltip.length),
          reason: '$locale');
      expect(words.screenSessionLoggedTooltipRdp, isNot(words.sessionLoggedTooltip), reason: '$locale');
    }
  });

  testWidgets('while its log has not reached ZestSSH Cloud, a logged session says that the log is kept on the device',
      (tester) async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('en'),
      home: Scaffold(body: Column(children: [TeamLoggedChip(sessionId: 's1'), TeamLoggedStrip(sessionId: 's1')])),
    ));
    String tooltip() => tester
        .widget<Tooltip>(find.ancestor(of: find.byKey(const ValueKey('team-logged-s1')), matching: find.byType(Tooltip)))
        .message!;
    final whole = '${l10n.sessionLoggedTooltip} ${l10n.sessionLoggedWaiting}';

    TeamSessionLogs.expect('s1');
    await tester.pump();
    expect(find.text(l10n.sessionLoggedChip), findsOneWidget);
    expect(find.text(l10n.sessionLoggedWaitingChip), findsNothing);
    expect(tooltip(), l10n.sessionLoggedTooltip);

    // Its log waits: the chip says so, and both say where the log is.
    TeamSessionLogs.waiting.value = {'s1'};
    await tester.pump();
    expect(find.text(l10n.sessionLoggedWaitingChip), findsOneWidget);
    expect(find.text(l10n.sessionLoggedChip), findsNothing);
    expect(tooltip(), whole);
    expect(find.text(whole), findsOneWidget, reason: 'the phone strip');
    expect(find.byKey(const ValueKey('team-logged-s1')), findsOneWidget, reason: 'it is logged all the same');

    // Another session's log waiting says nothing of this one.
    TeamSessionLogs.waiting.value = {'s2'};
    await tester.pump();
    expect(find.text(l10n.sessionLoggedChip), findsOneWidget);
    expect(find.text(whole), findsNothing);
    expect(find.text(l10n.sessionLoggedTooltip), findsOneWidget);

    // A session that is not logged says nothing, whatever waits.
    await tester.runAsync(() => TeamSessionLogs.end('s1'));
    TeamSessionLogs.waiting.value = {'s1'};
    await tester.pump();
    expect(find.byKey(const ValueKey('team-logged-s1')), findsNothing);
    expect(find.byKey(const ValueKey('team-logged-strip-s1')), findsNothing);
    // Forgetting everything (signing out) forgets what waited as well.
    TeamSessionLogs.reset();
    expect(TeamSessionLogs.waiting.value, isEmpty);
  });

  test('the words for a log that waits on the device, in every language', () {
    final seen = <String>{};
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      expect(words.sessionLoggedWaitingChip.trim(), isNotEmpty, reason: '$locale');
      expect(words.sessionLoggedWaitingChip, isNot(words.sessionLoggedChip), reason: '$locale');
      expect(words.sessionLoggedWaiting, contains('ZestSSH Cloud'), reason: '$locale');
      expect(sessionLoggedText(words, waits: true), '${words.sessionLoggedTooltip} ${words.sessionLoggedWaiting}');
      expect(sessionLoggedText(words, waits: false), words.sessionLoggedTooltip);
      seen
        ..add(words.sessionLoggedWaitingChip)
        ..add(words.sessionLoggedWaiting);
    }
    expect(seen, hasLength(AppLocalizations.supportedLocales.length * 2));
    expect(l10n.sessionLoggedWaitingChip, 'Logged, not sent yet');
  });

  testWidgets('a host whose sessions are logged says so before connecting', (tester) async {
    tester0 = tester;
    await build(tester);
    List<Override> onScreen() => [
          activeSpaceProvider.overrideWith((ref) => OrchardSpace(orchardId)),
          itemCratesProvider('host').overrideWith((ref) => Stream.value({'web1': crateId})),
        ];
    Widget notes(OrchardSummary o, CrateSummary c) => const Column(children: [
          HostSessionsLoggedNote(connectionId: 'web1'),
          HostSessionsLoggedNote(connectionId: 'web1', compact: true),
        ]);
    await pump(tester, owner, notes, extra: onScreen());
    expect(find.byKey(const ValueKey('host-logged-note-web1')), findsNothing, reason: 'off');
    await tester.runAsync(() => owner.setCrateSessionLogs(orchardId, crateId, true));
    await pump(tester, owner, notes, extra: onScreen());
    expect(find.byKey(const ValueKey('host-logged-note-web1')), findsOneWidget);
    expect(find.byKey(const ValueKey('host-logged-mark-web1')), findsOneWidget);
    expect(find.text(l10n.hostSessionsLogged), findsOneWidget);
  });

  testWidgets("on a phone, a host's card says its sessions are logged before connecting", (tester) async {
    tester0 = tester;
    await build(tester);
    final card = await phoneHostCard(tester, 'web1');
    final needs = await phoneHostCardNeeds(tester);
    List<Override> onScreen() => [
          activeSpaceProvider.overrideWith((ref) => OrchardSpace(orchardId)),
          itemCratesProvider('host').overrideWith((ref) => Stream.value({'web1': crateId})),
          ...needs,
        ];
    final mark = find.byKey(const ValueKey('host-logged-mark-web1'));
    await pump(tester, owner, (o, c) => card, extra: onScreen());
    expect(find.text('Web 1'), findsOneWidget);
    expect(mark, findsNothing, reason: 'off');
    await tester.runAsync(() => owner.setCrateSessionLogs(orchardId, crateId, true));
    await pump(tester, owner, (o, c) => card, extra: onScreen());
    expect(mark, findsOneWidget);
    expect(tester.widget<Tooltip>(find.ancestor(of: mark, matching: find.byType(Tooltip))).message,
        l10n.hostSessionsLogged);
  });
}
