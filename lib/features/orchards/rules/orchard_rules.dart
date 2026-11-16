import 'dart:math' as math;

import 'package:zestssh/features/orchards/record/orchard_record.dart';

// An Orchard's rules on this device (3.0). The owners set them in
// the Orchard's record (RecordRules). The server holds members to the ones
// it can check: a second factor at sign-in, the address domain, how long
// ago they signed in, and whether they signed in through the Orchard's
// company sign-in. This device holds itself to the rest: the app lock
// and its timeout, no export, the offline limit, asking again before a
// Crate's secrets are shown, and the two rules about remote screens (through
// an SSH host only; nothing shared with them). Someone who falls short keeps what is on their
// device, but the Orchard stops syncing for them until they fix it, and the
// app says what to fix. These are the app's rules, not
// cryptography: a device that already holds the keys can, with enough effort
// outside the app, read what it holds, which is why the server's rules and
// removal stop anything new from reaching it.

/// The domain of an address, lower case; '' for none.
String addressDomain(String? email) {
  final s = (email ?? '').trim().toLowerCase();
  final at = s.lastIndexOf('@');
  return at < 0 ? '' : s.substring(at + 1);
}

/// Whether the rule on address [domains] holds back a member with the address
/// [email] and the end date [endsAt], as ZestSSH Cloud decides it (rulesUnmet,
/// lib/orchard_rules.js; the two are held to one corpus,
/// test/features/orchards/rules/domain_rule_corpus.json). Someone outside the
/// domains with an end date is a guest, and is let in until it passes, whoever
/// gave the date: an owner is told where it was no owner
/// ([OrchardPerson.endChosenByOwner]).
bool domainRuleHolds(Set<String> domains, String? email, {int? endsAt}) =>
    domains.isNotEmpty && !domains.contains(addressDomain(email)) && endsAt == null;

/// How far ahead a member's end date may be set: five years as the date picker
/// counts them, whatever the leap days, and the day it ends on (the server's
/// MAX_END_SECONDS, lib/orchard_rules.js, and the same corpus).
const int kMemberEndMaxSeconds = (5 * 366 + 1) * 24 * 60 * 60;

/// Whether the end date [endsAt], set at [nowSeconds], is further ahead than
/// one may be.
bool memberEndTooFar(int? endsAt, int nowSeconds) => endsAt != null && endsAt > nowSeconds + kMemberEndMaxSeconds;

/// The rule "approved devices only" as the server names it.
const String kTrustedDeviceRule = 'trusted_device';

/// A rule this account or this device falls short of.
enum UnmetRule {
  /// The server's: sign in with a second factor.
  twoStep,

  /// The server's: the account's address is outside the Orchard's domains.
  emailDomain,

  /// The server's: the last real sign-in is older than the rules allow.
  reauth,

  /// The server's: the sign-in did not come through the Orchard's company
  /// sign-in.
  sso,

  /// The server's: the Orchard lets in approved devices only, and this one
  /// is not. The device asks to be approved; signing in again changes
  /// nothing.
  trustedDevice,

  /// This device's: the app lock is off.
  appLock,

  /// This device's: the app lock waits longer than the rules allow.
  lockTimeout;

  /// A rule as the server names it, or null for one this version does not
  /// know.
  static UnmetRule? fromServer(String name) => switch (name) {
        'two_step' => twoStep,
        'email_domain' => emailDomain,
        'reauth' => reauth,
        'sso' => sso,
        kTrustedDeviceRule => trustedDevice,
        _ => null,
      };

  /// Checked by the server: the person fixes it and signs in again, or has
  /// this device approved (or an owner changes the rules). The others this
  /// device checks by itself.
  bool get server =>
      this == twoStep || this == emailDomain || this == reauth || this == sso || this == trustedDevice;
}

/// [rules] with each rule a device keeps to itself at least as strict as
/// [device]'s: the app lock, no export and the two rules about remote
/// screens when either asks for them, and
/// the lock timeout and the offline limit the shorter of the two (0 is
/// none). The rest stay as [rules] has them. For an Orchard the server
/// holds this account back from: it says which device rules are in
/// force, which can add to what the record last said, never take away.
RecordRules withStricterDeviceRules(RecordRules rules, RecordRules device) {
  int shorter(int a, int b) {
    if (a <= 0) return b > 0 ? b : 0;
    if (b <= 0) return a;
    return a < b ? a : b;
  }

  return rules.copyWith(
    requireAppLock: rules.requireAppLock || device.requireAppLock,
    maxLockMinutes: shorter(rules.maxLockMinutes, device.maxLockMinutes),
    noExport: rules.noExport || device.noExport,
    offlineHours: shorter(rules.offlineHours, device.offlineHours),
    screensSshOnly: rules.screensSshOnly || device.screensSshOnly,
    screensLockRedirections: rules.screensLockRedirections || device.screensLockRedirections,
  );
}

/// The rules in force on this device from what its team's database keeps
/// (orchard_info, both as decoded JSON): the record's as last read ([rules])
/// held to at least the device rules the server says are in force while it
/// holds this account back ([held], its `device_rules`). Anything missing or
/// of the wrong kind reads as no rule.
RecordRules rulesInForce(Object? rules, Object? held) {
  final record = RecordRules.fromStored(rules);
  final device = held is Map && held['device_rules'] is Map ? held['device_rules'] : null;
  return device == null ? record : withStricterDeviceRules(record, RecordRules.fromStored(device));
}

/// The rules in [rules] this device falls short of, from its app lock:
/// [lockOn] (on, with a PIN or biometrics) and [lockMinutes] (how long the
/// app may be left before it locks: 0 at once, a negative number never).
List<UnmetRule> deviceUnmet(RecordRules rules, {required bool lockOn, required int lockMinutes}) {
  // A timeout without the lock is refused by the record; asked for anyway,
  // it asks for the lock.
  final wantsLock = rules.requireAppLock || rules.maxLockMinutes > 0;
  if (!wantsLock) return const [];
  if (!lockOn) return const [UnmetRule.appLock];
  if (rules.maxLockMinutes > 0 && (lockMinutes < 0 || lockMinutes > rules.maxLockMinutes)) {
    return const [UnmetRule.lockTimeout];
  }
  return const [];
}

/// When this device last reached ZestSSH Cloud, and the latest time its
/// clock showed since, both in seconds since the epoch: what the offline
/// limit is measured with.
class OrchardContact {
  const OrchardContact({
    this.lastContact,
    this.latest = 0,
    this.excused = 0,
    this.excusedThrough = 0,
    this.provenUntil = 0,
  });

  /// Null until this device has reached it since the limit was kept.
  final int? lastContact;

  /// The furthest the clock has read since then: a clock that reads earlier
  /// than this was turned back.
  final int latest;

  /// How many seconds since [lastContact] ZestSSH Cloud itself was down, as
  /// its status service proved with a signed statement
  /// (lib/services/cloud/cloud_statement.dart). That time is ours, not this
  /// device's: it could not have reached the service however it tried, and
  /// it does not count towards the limit. Never more than
  /// [kOutageExcuseMax].
  final int excused;

  /// Up to when (seconds since the epoch) proven outages are already counted
  /// in [excused]: what a later proof adds starts from here, so that no
  /// moment is counted twice.
  final int excusedThrough;

  /// Until when (seconds since the epoch) the last proof of an outage may
  /// be believed, as the status service signed it. From [excusedThrough] to
  /// here the outage counts as lasting: that time is excused as it passes
  /// ([excusedAsOf]), so that a limit does not run between one proof and
  /// the next. Not after [excusedThrough] where nothing is believed beyond
  /// what was counted.
  final int provenUntil;

  /// What proven outages excuse as of [nowSeconds]: what was counted, and
  /// the time since the last proof for as long as that proof may be
  /// believed. Never more than [kOutageExcuseMax], and never less than
  /// nothing (a number that was kept is not trusted to be within that).
  int excusedAsOf(int nowSeconds) {
    final running = math.min(nowSeconds, provenUntil) - excusedThrough;
    return math.min(math.max(excused, 0) + math.max(running, 0), kOutageExcuseMax.inSeconds);
  }

  /// Whether the offline limits stand still at [nowSeconds]: a proof of an
  /// outage that is believed beyond what was counted covers the moment, and
  /// not all that is ever excused has been. Every second is excused as it
  /// passes then, so the end of every limit moves on with the clock.
  bool standsStill(int nowSeconds) =>
      provenUntil > excusedThrough && nowSeconds <= provenUntil && excusedAsOf(nowSeconds) < kOutageExcuseMax.inSeconds;

  /// This contact with an outage taken in that was proven to have lasted
  /// from [since] to [at], by a statement that may be believed until
  /// [until] (no further than [at] where none is given): what of it lies
  /// after the last contact, and after what was already counted, is added
  /// to [excused], and the count stands at [at] from then on. This very
  /// contact where the statement says nothing new: with no contact to
  /// measure from; made no later than the last contact (the service
  /// answered this device after it); made before what was counted; or the
  /// one that was counted, holding no longer than was known.
  OrchardContact excusing({required int since, required int at, int? until}) {
    final last = lastContact;
    if (last == null || at <= last || at < excusedThrough) return this;
    // (A statement is believed at least as far as itself, and a later one
    // never takes back what an earlier one said it held.)
    final holds = math.max(math.max(until ?? at, at), provenUntil);
    final from = math.max(math.max(since, last), excusedThrough);
    final added = at > from ? at - from : 0;
    if (added == 0 && at == excusedThrough && holds == provenUntil) return this;
    return OrchardContact(
      lastContact: last,
      latest: latest,
      excused: math.min(math.max(excused, 0) + added, kOutageExcuseMax.inSeconds),
      excusedThrough: at,
      provenUntil: holds,
    );
  }

  /// This contact once the outage that was proven is known to be over at
  /// [nowSeconds] (ZestSSH Cloud answers again, or its status service says
  /// that it is up): what its last proof excused up to this moment is
  /// counted, and the proof is believed no further. This very contact where
  /// nothing was believed beyond what was counted.
  OrchardContact ending(int nowSeconds) {
    if (lastContact == null || provenUntil <= excusedThrough) return this;
    final through = math.max(math.min(nowSeconds, provenUntil), excusedThrough);
    return OrchardContact(
      lastContact: lastContact,
      latest: latest,
      excused: excusedAsOf(nowSeconds),
      excusedThrough: through,
      provenUntil: through,
    );
  }

  /// This contact with the clock seen to read [seconds], the furthest yet.
  OrchardContact seeing(int seconds) => OrchardContact(
      lastContact: lastContact,
      latest: seconds,
      excused: excused,
      excusedThrough: excusedThrough,
      provenUntil: provenUntil);
}

/// The most of one stretch without contact that proven outages may excuse
/// (seven days). An offline limit
/// is there so that a device that has been taken out of an Orchard does not
/// keep it for ever by staying away; an outage of ours must not be what
/// closes a team's hosts, and must not hold them open without end either.
const kOutageExcuseMax = Duration(days: 7);

/// How far behind [OrchardContact.latest] the clock may read before it
/// counts as turned back (clocks are corrected by a few seconds now and
/// then; a person moving it back by hours is what this catches).
const kClockSlack = Duration(minutes: 5);

/// Whether a device that last reached ZestSSH Cloud as [contact] says, at
/// [nowSeconds], is past [rules]' offline limit: then the Orchard stays
/// closed on it until it reaches ZestSSH Cloud again. A device that has not
/// reached it since the limit was kept counts as past it, and so does a
/// clock turned back: the limit cannot be measured from either.
///
/// The time ZestSSH Cloud itself was down, as far as it was proven
/// ([OrchardContact.excused]), is not counted: a team's hosts do not close
/// because of an outage that was ours.
bool offlineLimitReached(RecordRules rules, OrchardContact contact, int nowSeconds) =>
    offlineHoursReached(rules.offlineHours, contact, nowSeconds);

/// [offlineLimitReached] for a limit of [hours] (0 or less is none): the
/// Orchard's own, which closes all of it, or a Crate's own, which closes
/// that Crate (lib/features/orchards/rules/crate_offline.dart). Both are
/// measured the same way, from the same contact.
bool offlineHoursReached(int hours, OrchardContact contact, int nowSeconds) {
  if (hours <= 0) return false;
  final last = contact.lastContact;
  final end = offlineLimitEnd(hours, contact, nowSeconds);
  if (last == null || end == null) return true;
  final slack = kClockSlack.inSeconds;
  if (nowSeconds + slack < contact.latest || nowSeconds + slack < last) return true;
  return nowSeconds > end;
}

/// The last second (since the epoch) at which a device that stands as
/// [contact] is still within a limit of [hours], as it looks at
/// [nowSeconds]: that long after it last reached ZestSSH Cloud, and later by
/// what proven outages excuse as of that moment
/// ([OrchardContact.excusedAsOf]: while a proof covers the moment, the end
/// moves on with the clock). Null where there is no limit, and where there
/// is nothing to measure one from (a device that has not reached the
/// service since the limit was kept, for which it counts as reached
/// already).
int? offlineLimitEnd(int hours, OrchardContact contact, int nowSeconds) {
  final last = contact.lastContact;
  if (hours <= 0 || last == null) return null;
  return last + contact.excusedAsOf(nowSeconds) + hours * Duration.secondsPerHour;
}

/// How long before a limit of [hours] is reached a device starts saying
/// so: the last quarter of it, and a day at the most. (A day's limit is
/// said six hours ahead, a week's a day ahead, and the shortest there is,
/// an hour's, a quarter of an hour ahead.)
Duration offlineWarningBefore(int hours) {
  final quarter = Duration(seconds: hours * Duration.secondsPerHour ~/ 4);
  return quarter > const Duration(days: 1) ? const Duration(days: 1) : quarter;
}

/// Whether a limit of [hours] is about to be reached at [nowSeconds] by a
/// device that stands as [contact]: it is within [offlineWarningBefore] of
/// its end, and not past it. A limit that counts as reached (no contact to
/// measure it from, a clock turned back) is not about to be: it is. And
/// none is while the limits stand still for a proven outage of ZestSSH
/// Cloud's own ([OrchardContact.standsStill]): nothing closes while that
/// lasts, and an outage of ours is not what alarms a team.
bool offlineLimitNear(int hours, OrchardContact contact, int nowSeconds) {
  final end = offlineLimitEnd(hours, contact, nowSeconds);
  if (end == null || contact.standsStill(nowSeconds) || offlineHoursReached(hours, contact, nowSeconds)) return false;
  return end - nowSeconds <= offlineWarningBefore(hours).inSeconds;
}

/// How this device stands with ZestSSH Cloud, for whoever holds one of its
/// Orchard databases and nothing else (a session, a helper with no ref at
/// hand). Each Orchard database is given one as it opens
/// (OrchardDatabasesNotifier), and a Crate's own offline limit is measured
/// with it wherever the Crate's items are about to be used.
class DeviceContact {
  const DeviceContact({required this.read, required this.now, this.loaded});

  /// The contact as it stands when asked.
  final OrchardContact Function() read;

  /// This device's clock, in seconds since the epoch.
  final int Function() now;

  /// Done once what was kept of the contact has been read (it is read
  /// afresh at each unlock); null where there is nothing to wait for.
  final Future<void> Function()? loaded;
}
