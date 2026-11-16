import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/widgets/orchard_access_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show orchardChangeErrorMessage;
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Access on request (3.0) as the Team page words it: how long, what
/// a request asks for and what someone holds on one line, what ZestSSH Cloud
/// refused in words a person can act on, and what a member can ask more of.

CrateSummary _crate(String id, String? name, Set<String> switches, {bool ownersOnly = false}) => CrateSummary(
      id: id,
      name: name,
      level: (levelOf(switches) ?? CrateLevel.connect).name,
      switches: switches,
      ownersOnly: ownersOnly,
    );

OrchardSummary _orchard(List<CrateSummary> crates, {String role = 'member-role'}) =>
    OrchardSummary(id: 'o-1', name: 'Northwind', role: role, crates: crates, defaultCrateId: null);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final orchard = _orchard([
    _crate('c-prod', 'Production', levelSwitches(CrateLevel.use)),
    _crate('c-staging', 'Staging', levelSwitches(CrateLevel.connect)),
    _crate('c-new', null, levelSwitches(CrateLevel.edit)),
  ]);

  setUpAll(initializeDateFormatting);

  test('how long: whole days, else whole hours, else minutes', () {
    String words(Duration d) => accessDurationText(d, l10n);
    expect(words(const Duration(days: 1)), '1 day');
    expect(words(const Duration(days: 3)), '3 days');
    expect(words(const Duration(days: 30)), '30 days');
    expect(words(const Duration(hours: 24)), '1 day');
    expect(words(const Duration(hours: 1)), '1 hour');
    expect(words(const Duration(hours: 8)), '8 hours');
    // A day and a half is not whole days.
    expect(words(const Duration(hours: 36)), '36 hours');
    expect(words(const Duration(minutes: 5)), '5 minutes');
    expect(words(const Duration(minutes: 90)), '90 minutes');
    // Never less than was asked for.
    expect(words(const Duration(minutes: 5, seconds: 1)), '6 minutes');
    // Every time offered has words of its own.
    expect({for (final d in kAccessDurations) words(d)}, hasLength(kAccessDurations.length));
    expect(kAccessDurations, contains(kDefaultAccessDuration));
    expect(kAccessDurations.first, greaterThanOrEqualTo(kMinAccessDuration));
    expect(kAccessDurations.last, kMaxAccessDuration);
  });

  test('a Crate by the name this device has for it, or as one it cannot open', () {
    expect(teamAccessCrateName(orchard, 'c-prod', l10n), 'Production');
    expect(teamAccessCrateName(orchard, 'c-new', l10n), l10n.crateUnnamed);
    expect(teamAccessCrateName(orchard, 'c-elsewhere', l10n), l10n.teamCrateClosed);
    expect(teamAccessCrateName(orchard, null, l10n), l10n.teamCrateClosed);
  });

  test('what a request asks for, on one line', () {
    AccessRequestView request({String? crateId, CrateLevel level = CrateLevel.use, int minutes = 120}) =>
        AccessRequestView(
            id: 'r-1', crateId: crateId, level: level, duration: Duration(minutes: minutes), expiresAt: 1800000000);
    expect(accessRequestSummary(request(crateId: 'c-prod', level: CrateLevel.edit), orchard, l10n),
        'Production, Edit, 2 hours');
    // A Crate they could not name: the note says which.
    expect(accessRequestSummary(request(level: CrateLevel.connect, minutes: 30), orchard, l10n),
        '${l10n.accessCrateInNote}, Connect, 30 minutes');
    // One that names a Crate this device does not open.
    expect(accessRequestSummary(request(crateId: 'c-elsewhere', minutes: 3 * 24 * 60), orchard, l10n),
        '${l10n.teamCrateClosed}, Use, 3 days');
  });

  test('what someone holds until a set time, on one line', () {
    final now = DateTime(2026, 10, 1, 9, 30);
    final until = DateTime(2026, 10, 1, 15, 45).millisecondsSinceEpoch ~/ 1000;
    TimedAccess held(String crateId, {required bool wholeCrate, CrateLevel level = CrateLevel.use}) => TimedAccess(
          uid: 'kit',
          crateId: crateId,
          adds: const {CrateSwitches.reveal},
          level: level,
          until: until,
          wholeCrate: wholeCrate,
          canEnd: true,
        );
    final time = l10n.accessUntil(accessTimeText(until, l10n, now: now));
    // A whole Crate: its name and when it ends.
    expect(timedAccessSummary(held('c-staging', wholeCrate: true), orchard, l10n, now: now), 'Staging, $time');
    // More in a Crate they open anyway: how far, too.
    expect(timedAccessSummary(held('c-prod', wholeCrate: false, level: CrateLevel.edit), orchard, l10n, now: now),
        'Production, Edit, $time');
    expect(time, startsWith('until '));
    expect(time, contains('3:45'));
    // Without a moment given, today is this device's.
    final far = DateTime.now().add(const Duration(days: 40)).millisecondsSinceEpoch ~/ 1000;
    expect(
        timedAccessSummary(
            TimedAccess(
                uid: 'kit',
                crateId: 'c-staging',
                adds: const {CrateSwitches.reveal},
                level: CrateLevel.use,
                until: far,
                wholeCrate: true,
                canEnd: true),
            orchard,
            l10n),
        'Staging, ${l10n.accessUntil(accessTimeText(far, l10n))}');
  });

  test('what ZestSSH Cloud refused, in words a person can act on', () {
    String words(String? code, {int status = 409}) => accessErrorMessage(OrchardServerException(status, code), l10n);
    expect(words('request-limit'), l10n.accessErrorRequestLimit);
    expect(words('access-not-needed'), l10n.accessErrorNotNeeded);
    expect(words('access-until-passed'), l10n.accessErrorPassed);
    expect(words('access-too-long'), l10n.accessErrorTooLong);
    expect({words('request-limit'), words('access-not-needed'), words('access-until-passed'), words('access-too-long')},
        hasLength(4));
    // Anything else is worded as every other change to an Orchard is.
    for (final Object other in [
      const OrchardServerException(403, 'rules-unmet', unmet: ['two_step']),
      const OrchardServerException(503, null),
      StateError('offline'),
    ]) {
      expect(accessErrorMessage(other, l10n), orchardChangeErrorMessage(other, l10n));
      expect(accessErrorMessage(other, l10n), isNot(isIn([for (final c in ['request-limit', 'access-not-needed']) words(c)])));
    }
    // People are named the way the page names them.
    const notTrusted = MemberKeysNotTrusted('uid-kit');
    expect(accessErrorMessage(notTrusted, l10n, nameOf: (uid) => 'kit@example.com'),
        l10n.orchardErrorKeysNotTrusted('kit@example.com'));
  });

  test('what a member can ask more of: each Crate they open below Edit, with the levels above their own', () {
    final asks = accessMoreChoices(_orchard([
      _crate('c-watch', 'Watch', levelSwitches(CrateLevel.connect)),
      _crate('c-use', 'Use', levelSwitches(CrateLevel.use)),
      _crate('c-edit', 'Edit', levelSwitches(CrateLevel.edit)),
      _crate('c-mine', 'Mine', levelSwitches(CrateLevel.manage)),
      // Made by hand, without what Connect stands for in full: as Connect.
      _crate('c-custom', 'Custom', {CrateSwitches.connect}),
      // Owners only: nobody is given one.
      _crate('c-vault', 'Vault', levelSwitches(CrateLevel.connect), ownersOnly: true),
    ]));
    expect(asks, {
      'c-watch': [CrateLevel.use, CrateLevel.edit],
      'c-use': [CrateLevel.edit],
      'c-custom': [CrateLevel.use, CrateLevel.edit],
    });
    expect(accessMoreChoices(_orchard(const [])), isEmpty);
  });
}
