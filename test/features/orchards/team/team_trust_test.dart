import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/record_log.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_trust.dart';
import 'package:zestssh/features/orchards/watch/unwatched.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';

import 'record_log_test.dart' show orchardId, signedRecord;

/// The key log on the Trust page (3.0), on a real signed
/// record: each change opens to what was signed and copies whole; the record
/// is checked again from its first entry on request, and a changed entry is
/// named with details to copy; key changes can be shown alone; owners and
/// admins save the record for an audit; a long record shows in pages.

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late List<RecordEntry> entries;
  late List<TeamChange> changes;

  setUpAll(() async {
    (entries, _, _) = await signedRecord();
    changes = await teamChanges(orchardId, entries);
  });

  TeamRecord recordOf(List<RecordEntry> e, {List<TeamChange>? changesOf, Uint8List? head}) => TeamRecord(
        changes: changesOf ?? changes,
        entries: e,
        emails: const {'owner-1': 'owner@example.com', 'alice-1': 'alice@example.com'},
        head: head ?? entries.last.hash(orchardId),
        firstSeen: {1: DateTime(2026, 9, 1, 9), 2: DateTime(2026, 9, 2, 9)},
      );

  OrchardSummary summary(String role) =>
      OrchardSummary(id: orchardId, name: 'Acme', role: role, crates: const [], defaultCrateId: null);

  late List<({String fileName, String text})> saved;
  late List<String> copied;

  Future<void> show(WidgetTester tester, TeamRecord record,
      {String role = FixedRoles.owner, List<Override> extra = const []}) async {
    saved = [];
    copied = [];
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        teamRecordProvider.overrideWith((ref, id) async => record),
        teamPeopleProvider.overrideWith((ref, id) => Completer<OrchardPeople>().future),
        orchardRolesProvider.overrideWith((ref, id) async => const <OrchardRoleView>[]),
        recordLogSaverProvider.overrideWithValue(({required fileName, required bytes, required dialogTitle}) async {
          saved.add((fileName: fileName, text: utf8.decode(bytes)));
          return 'C:\\Users\\me\\Documents\\$fileName';
        }),
        ...extra,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: TeamTrust(orchard: summary(role)))),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder row(int seq) => find.byKey(ValueKey('team-trust-$seq'));

  testWidgets('each change opens to what was signed, and copies whole', (tester) async {
    await show(tester, recordOf(entries));
    expect(row(1), findsOneWidget);
    expect(row(3), findsOneWidget);
    await tester.tap(row(2));
    await tester.pumpAndSettle();
    final e = entries[1];
    expect(find.text(l10n.teamTrustEntryTitle(2)), findsOneWidget);
    expect(find.byTooltip(hexOf(e.hash(orchardId))), findsOneWidget, reason: 'whole in its tooltip');
    expect(find.byTooltip(hexOf(e.prev)), findsOneWidget, reason: 'the hash of entry 1');
    expect(hexOf(e.prev), hexOf(entries[0].hash(orchardId)));
    expect(find.byTooltip(base64Encode(e.signature)), findsOneWidget);
    expect(find.text(e.type), findsOneWidget);
    expect(find.textContaining('"uid": "alice-1"'), findsOneWidget, reason: 'the body as signed');
    // A long value is one line, cut in its middle where it does not fit,
    // and its button copies all of it.
    final shown = tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('team-trust-entry-signature')), matching: find.byType(Text)).last).data!;
    expect(shown.length, lessThan(base64Encode(e.signature).length));
    expect(shown, contains('\u2026'));
    expect(base64Encode(e.signature), startsWith(shown.substring(0, shown.indexOf('\u2026'))));
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('team-trust-entry-hash')), matching: find.byTooltip(l10n.copy)));
    await tester.pump();
    expect(copied.last, hexOf(e.hash(orchardId)));
    copied.clear();
    await tester.pump(const Duration(seconds: 5));
    // Each name a step quieter than its value, and a line with its copy
    // button no taller than one without (the names read as the values did,
    // and those lines stood apart, found in a design review).
    final name = tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('team-trust-entry-hash-label')), matching: find.byType(Text)));
    expect(name.style!.color, ZestColors.textTertiary);
    double lineHeight(String key) => tester.getSize(find.byKey(ValueKey('team-trust-entry-$key'))).height;
    expect(lineHeight('hash') - lineHeight('by'), lessThanOrEqualTo(3));

    await tester.tap(find.text(l10n.teamTrustEntryCopy));
    await tester.pump();
    final json = jsonDecode(copied.single) as Map<String, Object?>;
    expect(json['seq'], 2);
    expect(json['body_json'], e.bodyJson);
    expect(json['hash'], hexOf(e.hash(orchardId)));
    await tester.pump(const Duration(seconds: 5));

    // The first entry links to nothing.
    await tester.tap(find.text(l10n.close));
    await tester.pumpAndSettle();
    await tester.tap(row(1));
    await tester.pumpAndSettle();
    expect(find.text(l10n.teamTrustEntryFirst), findsOneWidget);
  });

  testWidgets('a session that ran with nobody watching opens to what was reported of it: when, the host, the reason '
      'and how the service stood; on a device that cannot open it, that is said', (tester) async {
    final report = RecordEntry(
      seq: entries.length + 1,
      prev: entries.last.hash(orchardId),
      type: RecordTypes.sessionUnwatched,
      bodyJson: jsonEncode({'crate': 'c-prod', 'at': 1791504000, 'gen': 1, 'sealed': 'AAAA'}),
      by: 'alice-1',
      byKeyVersion: 1,
      signature: Uint8List(64),
    );
    final listed = [...changes, describeRecordEntry(report, OrchardRecord(orchardId))];
    expect(listed.last.kind, TeamChangeKind.sessionUnwatched);
    UnwatchedSession? read = UnwatchedSession(
      seq: report.seq,
      by: 'alice-1',
      crateId: 'c-prod',
      at: 1791504000,
      report: const UnwatchedReport(host: 'db-primary', reason: 'restoring the database', reach: 'fault 503'),
    );
    final asked = <(String, int)>[];
    await show(tester, recordOf([...entries, report], changesOf: listed, head: report.hash(orchardId)), extra: [
      unwatchedSessionReaderProvider.overrideWithValue((id, entry) async {
        asked.add((id, entry.seq));
        return read;
      }),
    ]);
    Finder line(String key) => find.byKey(ValueKey('team-trust-entry-$key'));
    Finder said(String key, String text) => find.descendant(of: line(key), matching: find.text(text));

    // In the list: what it is, by its words.
    expect(find.descendant(of: row(report.seq), matching: find.textContaining('with nobody watching')), findsOneWidget);
    await tester.tap(row(report.seq));
    await tester.pumpAndSettle();
    expect(asked, [(orchardId, report.seq)]);
    expect(said('unwatched-when', accessTimeText(1791504000, l10n)), findsOneWidget);
    expect(said('unwatched-host', 'db-primary'), findsOneWidget);
    expect(said('unwatched-reason', 'restoring the database'), findsOneWidget);
    expect(said('unwatched-service', 'ZestSSH Cloud fault, HTTP 503 (ZS-1103)'), findsOneWidget);
    expect(line('unwatched-sealed'), findsNothing);
    for (final label in [l10n.unwatchedEntryWhen, l10n.unwatchedEntryHost, l10n.unwatchedEntryReason, l10n.unwatchedEntryService]) {
      expect(find.text(label), findsOneWidget);
    }
    // What was signed stays under it, as for every entry.
    expect(find.text(RecordTypes.sessionUnwatched), findsOneWidget);
    expect(find.byTooltip(hexOf(report.hash(orchardId))), findsOneWidget);

    // A device that does not hold the Crate's key: when, and that the rest
    // is sealed.
    await tester.tap(find.text(l10n.close));
    await tester.pumpAndSettle();
    read = UnwatchedSession(seq: report.seq, by: 'alice-1', crateId: 'c-prod', at: 1791504000);
    await tester.tap(row(report.seq));
    await tester.pumpAndSettle();
    expect(said('unwatched-when', accessTimeText(1791504000, l10n)), findsOneWidget);
    expect(said('unwatched-sealed', l10n.unwatchedEntrySealed), findsOneWidget);
    for (final key in ['unwatched-host', 'unwatched-reason', 'unwatched-service']) {
      expect(line(key), findsNothing, reason: key);
    }

    // Nothing read of it (the entry is not what it says): what was signed,
    // and nothing made up.
    await tester.tap(find.text(l10n.close));
    await tester.pumpAndSettle();
    read = null;
    await tester.tap(row(report.seq));
    await tester.pumpAndSettle();
    expect(line('unwatched-when'), findsNothing);
    expect(find.text(RecordTypes.sessionUnwatched), findsOneWidget);

    // An entry of another kind is not asked about.
    await tester.tap(find.text(l10n.close));
    await tester.pumpAndSettle();
    final before = asked.length;
    await tester.tap(row(2));
    await tester.pumpAndSettle();
    expect(asked, hasLength(before));
    expect(line('unwatched-when'), findsNothing);
  });

  testWidgets('checked again from its first entry on request: all of it holds', (tester) async {
    await show(tester, recordOf(entries));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('team-trust-check')));
      for (var i = 0; i < 50 && find.byKey(const ValueKey('team-trust-check-ok')).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('team-trust-check-ok')), findsOneWidget);
    expect(find.text(l10n.teamTrustCheckOk(3)), findsOneWidget);
    expect(find.byKey(const ValueKey('team-trust-check-failed')), findsNothing);
  });

  testWidgets('an entry that does not hold is named, with the details to copy', (tester) async {
    final changed = RecordEntry(
      seq: entries[1].seq,
      prev: entries[1].prev,
      type: entries[1].type,
      bodyJson: entries[1].bodyJson.replaceFirst('role-dev', 'role-lead'),
      by: entries[1].by,
      byKeyVersion: entries[1].byKeyVersion,
      signature: entries[1].signature,
    );
    await show(tester, recordOf([entries[0], changed, entries[2]]));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('team-trust-check')));
      for (var i = 0; i < 50 && find.byKey(const ValueKey('team-trust-check-failed')).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('team-trust-check-failed')), findsOneWidget);
    expect(find.text(l10n.teamTrustCheckFailed(2)), findsOneWidget);
    await tester.tap(find.text(l10n.desktopShellCopyDetails));
    await tester.pump();
    expect(copied.single, contains('Entry: 2'));
    expect(copied.single, contains('Orchard: $orchardId'));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('key changes on their own', (tester) async {
    await show(tester, recordOf(entries));
    expect(changes.map((c) => c.kind), [TeamChangeKind.created, TeamChangeKind.memberAdded, TeamChangeKind.memberRole]);
    await tester.tap(find.text(l10n.teamTrustFilterKeys));
    await tester.pumpAndSettle();
    expect(row(1), findsOneWidget);
    expect(row(2), findsOneWidget);
    expect(row(3), findsNothing, reason: 'a role change brings no key');
    await tester.tap(find.text(l10n.teamTrustFilterAll));
    await tester.pumpAndSettle();
    expect(row(3), findsOneWidget);
  });

  testWidgets('owners and admins save the record for an audit; others do not see it', (tester) async {
    await show(tester, recordOf(entries));
    await tester.tap(find.byKey(const ValueKey('team-trust-save')));
    await tester.pumpAndSettle();
    final file = saved.single;
    expect(file.fileName, matches(RegExp(r'^orchard-record-5a1f0c2e-\d{8}\.json$')));
    final doc = jsonDecode(file.text) as Map<String, Object?>;
    expect(doc['entries_count'], 3);
    expect(doc['head'], hexOf(entries.last.hash(orchardId)));
    // Where it went, readable.
    expect(find.text(l10n.teamTrustSaved), findsOneWidget);
    expect(find.text(l10n.teamTrustSavedBody(3)), findsOneWidget);
    expect(find.textContaining(file.fileName), findsWidgets);

    await show(tester, recordOf(entries), role: FixedRoles.admin);
    expect(find.byKey(const ValueKey('team-trust-save')), findsOneWidget);
    await show(tester, recordOf(entries), role: 'role-dev');
    expect(find.byKey(const ValueKey('team-trust-save')), findsNothing);
  });

  testWidgets('a long record shows a page at a time, newest first', (tester) async {
    final many = [
      for (var s = 1; s <= 250; s++) TeamChange(seq: s, kind: TeamChangeKind.rules, by: 'owner-1', byKeyVersion: 1),
    ];
    await show(tester, recordOf(const [], changesOf: many));
    expect(row(250), findsOneWidget);
    expect(row(151), findsOneWidget);
    expect(row(150), findsNothing);
    expect(find.text(l10n.teamTrustShowOlder(150)), findsOneWidget);
    Future<void> older() async {
      await tester.ensureVisible(find.byKey(const ValueKey('team-trust-older')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('team-trust-older')));
      await tester.pumpAndSettle();
    }

    await older();
    expect(row(51), findsOneWidget);
    expect(row(50), findsNothing);
    expect(find.text(l10n.teamTrustShowOlder(50)), findsOneWidget);
    await older();
    expect(row(1), findsOneWidget);
    expect(find.byKey(const ValueKey('team-trust-older')), findsNothing);
    // Without their entries here, rows do not open.
    await tester.ensureVisible(row(1));
    await tester.pumpAndSettle();
    await tester.tap(row(1));
    await tester.pumpAndSettle();
    expect(find.text(l10n.teamTrustEntryTitle(1)), findsNothing);
  });
}
