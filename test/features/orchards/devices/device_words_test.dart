import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart' show rulesOn;
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Trusted devices (3.0) in words: what the record and ZestSSH
/// Cloud refuse, said with the way out; the rule by its name; the changes as
/// the Team page lists them; what a device tells its person; and where an
/// Orchard stands with its devices.

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  test('what the record refuses about devices is said with the way out', () {
    String refused(String reason) => orchardChangeErrorMessage(OrchardRecordRefused(reason), l10n);
    expect(refused('would leave no owner with an approved device'), l10n.deviceErrorLastOwner);
    expect(refused('two approved devices among the owners first'), l10n.deviceErrorTwoOwners);
    expect(refused('too many devices'), l10n.deviceErrorTooMany(kMaxMemberDevices));
    expect(l10n.deviceErrorTooMany(kMaxMemberDevices), contains('20'));
    expect(refused('not from an approved device'), l10n.deviceErrorNotApproved);
    // Anything else the record refuses reads as before.
    expect(refused('only an owner, or an admin for those below'), l10n.orchardErrorRefused);
    expect(refused('already approved'), l10n.orchardErrorRefused);
  });

  test('what ZestSSH Cloud refuses about devices, and what this device cannot do', () {
    String said(Object error) => orchardChangeErrorMessage(error, l10n);
    // Held back, and only as a device nobody approved.
    expect(said(const OrchardServerException(403, 'rules-unmet', unmet: ['trusted_device'])), l10n.deviceErrorNotApproved);
    expect(said(const OrchardServerException(403, 'rules-unmet', unmet: ['two_step', 'trusted_device'])),
        l10n.orchardErrorRulesUnmet, reason: 'something else as well: the banner says what');
    expect(said(const OrchardServerException(403, 'rules-unmet', unmet: ['two_step'])), l10n.orchardErrorRulesUnmet);
    // Answering or asking for a certificate from a device that is not approved.
    expect(said(const OrchardServerException(409, 'device-not-approved')), l10n.deviceErrorNotApproved);
    // The rule turned on from a device that is not approved after it.
    expect(said(const OrchardServerException(409, 'rules-unmet-by-you', unmet: ['trusted_device'])),
        l10n.deviceErrorNotApproved);
    expect(said(const OrchardServerException(409, 'rules-unmet-by-you', unmet: ['two_step', 'trusted_device'])),
        l10n.orchardRulesUnmetByYou('${l10n.orchardRuleNameTwoStep}, ${l10n.orchardRuleNameTrustedDevice}'));
    expect(said(const DeviceCannotBeNamed()), l10n.deviceAskCannot);
    expect(said(const DeviceRequestGone()), l10n.deviceRequestGone);
    expect(orchardErrorMessage(const DeviceCannotBeNamed(), l10n), l10n.deviceAskCannot);
    expect(orchardErrorMessage(const DeviceRequestGone(), l10n), l10n.deviceRequestGone);
    expect('${const DeviceCannotBeNamed()}', contains('device'));
    expect('${const DeviceRequestGone()}', contains('request'));
  });

  test('the rule by its name, among the rules a server names', () {
    expect(orchardRuleNames(['trusted_device'], l10n), l10n.orchardRuleNameTrustedDevice);
    expect(orchardRuleNames(['reauth', 'trusted_device'], l10n),
        '${l10n.orchardRuleNameReauth}, ${l10n.orchardRuleNameTrustedDevice}');
  });

  test('an Orchard held back only as a device nobody approved, and one that was removed', () {
    OrchardSummary held(List<String> unmet, {String status = 'rules', bool removed = false}) => OrchardSummary(
          id: 'o-1',
          name: 'Northwind',
          role: 'owner',
          crates: const [],
          defaultCrateId: null,
          status: status,
          rulesUnmet: unmet,
          deviceRemoved: removed,
        );
    expect(held(['trusted_device']).onlyDeviceHeld, isTrue);
    expect(held(['two_step', 'trusted_device']).onlyDeviceHeld, isFalse);
    expect(held(['two_step']).onlyDeviceHeld, isFalse);
    expect(held(const []).onlyDeviceHeld, isFalse);
    expect(held(['trusted_device'], status: 'active').onlyDeviceHeld, isFalse);
    expect(held(['trusted_device'], removed: true).deviceRemoved, isTrue);
    expect(held(['trusted_device']).deviceRemoved, isFalse);
  });

  test('the changes as the Team page lists them', () {
    String words(TeamChangeKind kind) => teamChangeText(
          TeamChange(seq: 9, kind: kind, by: 'owner', byKeyVersion: 1, member: 'sam'),
          l10n,
          nameOf: (uid) => '$uid@example.com',
          crateName: (_) => 'Production',
          roleName: (id) => id,
        );
    expect(words(TeamChangeKind.deviceApproved), l10n.teamChangeDeviceApproved('sam@example.com'));
    expect(words(TeamChangeKind.deviceApprovedOwn), l10n.teamChangeDeviceApprovedOwn);
    expect(words(TeamChangeKind.deviceRemoved), l10n.teamChangeDeviceRemoved('sam@example.com'));
    expect(words(TeamChangeKind.deviceRemovedOwn), l10n.teamChangeDeviceRemovedOwn);
    expect({for (final k in TeamChangeKind.values) words(k)}, hasLength(greaterThan(30)),
        reason: 'every kind has words');
  });

  test('how many rules are on counts the two that ZestSSH Cloud holds for a sign-in', () {
    expect(rulesOn(RecordRules.none), 0);
    expect(rulesOn(const RecordRules(trustedDevices: true)), 1);
    expect(rulesOn(const RecordRules(requireSso: true)), 1);
    // The two for remote screens (4.0) count, and are named last, as the Rules page lists them.
    expect(rulesOn(const RecordRules(screensSshOnly: true, screensLockRedirections: true)), 2);
    expect(rulesOn(const RecordRules(require2fa: true, trustedDevices: true, requireSso: true, noExport: true)), 4);
  });

  test('what a device tells its person about devices', () {
    AppNotification notice(DeviceNotice n) => deviceNoticeNotification(
          n,
          orchardId: 'o-1',
          orchard: 'Northwind',
          nameOf: (uid) => '$uid@example.com',
          l10n: l10n,
          now: DateTime(2026, 10, 2, 9),
        );
    var n = notice(const DeviceNotice(DeviceNoticeKind.asked, uid: 'sam'));
    expect((n.title, n.body), (l10n.noticeDeviceAskedTitle('Northwind'), l10n.noticeDeviceAskedBody('sam@example.com')));
    expect(n.severity, NotificationSeverity.warning);
    expect(n.createdAt, DateTime(2026, 10, 2, 9));
    n = notice(const DeviceNotice(DeviceNoticeKind.asked, uid: 'me', own: true));
    expect(n.body, l10n.noticeDeviceAskedOwnBody);
    n = notice(const DeviceNotice(DeviceNoticeKind.asked, count: 3));
    expect(n.body, l10n.noticeDeviceAskedManyBody(3));
    expect(n.body, contains('3'));
    n = notice(const DeviceNotice(DeviceNoticeKind.removed, orchardName: 'Northwind'));
    expect((n.title, n.body), (l10n.noticeDeviceRemovedTitle('Northwind'), l10n.noticeDeviceRemovedBody));
    // Two notices are two entries in the bell, whatever they say.
    final ids = {
      notice(const DeviceNotice(DeviceNoticeKind.asked, uid: 'sam')).id,
      notice(const DeviceNotice(DeviceNoticeKind.removed)).id,
      deviceNoticeNotification(const DeviceNotice(DeviceNoticeKind.asked, uid: 'sam'),
          orchardId: 'o-2', orchard: 'Other', nameOf: (uid) => '', l10n: l10n, now: DateTime(2026, 10, 2, 9)).id,
      deviceNoticeNotification(const DeviceNotice(DeviceNoticeKind.asked, uid: 'sam'),
          orchardId: 'o-1', orchard: 'Northwind', nameOf: (uid) => '', l10n: l10n, now: DateTime(2026, 10, 2, 10)).id,
    };
    expect(ids, hasLength(4));
  });

  test('where an Orchard stands with its devices: what turning the rule on takes', () {
    DeviceStanding standing({
      bool ruleOn = false,
      String? key = 'key',
      bool approved = false,
      int mine = 0,
      int ownerDevices = 0,
      bool isOwner = true,
    }) =>
        DeviceStanding(
          ruleOn: ruleOn,
          thisKey: key,
          approved: approved,
          mine: mine,
          ownerDevices: ownerDevices,
          isOwner: isOwner,
          without: const [],
        );
    // An owner's first device approves itself, while the rule is off.
    expect(standing().canApproveItself, isTrue);
    expect(standing(isOwner: false).canApproveItself, isFalse);
    expect(standing(ruleOn: true).canApproveItself, isFalse);
    expect(standing(mine: 1).canApproveItself, isFalse, reason: 'no longer the first');
    expect(standing(key: null).canApproveItself, isFalse);
    // The rule: this device approved, and two among the owners.
    expect(standing(approved: true, mine: 1, ownerDevices: 2).canTurnOn, isTrue);
    expect(standing(approved: true, mine: 1, ownerDevices: 1).canTurnOn, isFalse);
    expect(standing(approved: false, ownerDevices: 2).canTurnOn, isFalse);
    expect(standing(approved: true, mine: 2, ownerDevices: 3).canTurnOn, isTrue);
    expect(standing(key: null).thisCode, isNull);
    expect(standing().thisCode, matches(RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}$')));
  });
}
