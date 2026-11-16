import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/orchard_contact.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/services/local_state_store.dart';

/// An Orchard's rules on a device (3.0): what this device checks by
/// itself (its app lock, the offline limit with a clock that may have been
/// turned back), the rules as the device keeps them, and when it last
/// reached ZestSSH Cloud, kept in its encrypted database.

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const hour = 3600;
  const t0 = 1800000000;

  group('the app lock', () {
    test('no rule about it: nothing to meet, whatever the device does', () {
      expect(deviceUnmet(RecordRules.none, lockOn: false, lockMinutes: -1), isEmpty);
      expect(deviceUnmet(const RecordRules(noExport: true, offlineHours: 5), lockOn: false, lockMinutes: -1), isEmpty);
    });

    test('the lock asked for: off falls short, on (at any timeout) meets it', () {
      const rules = RecordRules(requireAppLock: true);
      expect(deviceUnmet(rules, lockOn: false, lockMinutes: 1), [UnmetRule.appLock]);
      expect(deviceUnmet(rules, lockOn: true, lockMinutes: -1), isEmpty, reason: 'no timeout asked for');
      expect(deviceUnmet(rules, lockOn: true, lockMinutes: 1440), isEmpty);
    });

    test('a longest timeout: at it or under meets it; longer, or never, falls short', () {
      const rules = RecordRules(requireAppLock: true, maxLockMinutes: 15);
      expect(deviceUnmet(rules, lockOn: true, lockMinutes: 0), isEmpty, reason: 'locks at once');
      expect(deviceUnmet(rules, lockOn: true, lockMinutes: 15), isEmpty);
      expect(deviceUnmet(rules, lockOn: true, lockMinutes: 16), [UnmetRule.lockTimeout]);
      expect(deviceUnmet(rules, lockOn: true, lockMinutes: -1), [UnmetRule.lockTimeout], reason: 'never locks');
      expect(deviceUnmet(rules, lockOn: false, lockMinutes: 5), [UnmetRule.appLock], reason: 'the lock first');
    });

    test('a timeout without the lock (which the record refuses) still asks for the lock', () {
      expect(deviceUnmet(const RecordRules(maxLockMinutes: 5), lockOn: false, lockMinutes: 5), [UnmetRule.appLock]);
    });
  });

  group('the offline limit', () {
    const rules = RecordRules(offlineHours: 72);

    test('no limit: never reached, even with nothing known', () {
      expect(offlineLimitReached(RecordRules.none, const OrchardContact(), t0), isFalse);
    });

    test('measured from the last time this device reached ZestSSH Cloud', () {
      const contact = OrchardContact(lastContact: t0, latest: t0);
      expect(offlineLimitReached(rules, contact, t0 + 71 * hour), isFalse);
      expect(offlineLimitReached(rules, contact, t0 + 72 * hour), isFalse, reason: 'at the limit still counts');
      expect(offlineLimitReached(rules, contact, t0 + 72 * hour + 1), isTrue);
    });

    test('a device that has not reached it since the limit was kept counts as past it', () {
      expect(offlineLimitReached(rules, const OrchardContact(), t0), isTrue);
    });

    test('a clock turned back counts as past it; a few seconds of correction does not', () {
      const contact = OrchardContact(lastContact: t0, latest: t0 + 10 * hour);
      final slack = kClockSlack.inSeconds;
      expect(offlineLimitReached(rules, contact, t0 + 10 * hour - slack), isFalse);
      expect(offlineLimitReached(rules, contact, t0 + 10 * hour - slack - 1), isTrue);
      expect(offlineLimitReached(rules, const OrchardContact(lastContact: t0, latest: t0), t0 - slack - 1), isTrue,
          reason: 'earlier than the contact itself');
    });
  });

  // An outage of ZestSSH Cloud's own, proven by its status service, is not
  // this device's doing and does not count (3.0: SSH has to keep
  // working for teams).
  group('a limit that is about to be reached', () {
    const day = 24 * hour;

    test('it is said in the last quarter of a limit, and a day ahead at the most', () {
      expect(offlineWarningBefore(1), const Duration(minutes: 15));
      expect(offlineWarningBefore(2), const Duration(minutes: 30));
      expect(offlineWarningBefore(8), const Duration(hours: 2));
      expect(offlineWarningBefore(24), const Duration(hours: 6));
      expect(offlineWarningBefore(72), const Duration(hours: 18));
      expect(offlineWarningBefore(96), const Duration(days: 1), reason: 'a quarter of four days');
      expect(offlineWarningBefore(97), const Duration(days: 1), reason: 'and no more than that');
      expect(offlineWarningBefore(168), const Duration(days: 1));
      expect(offlineWarningBefore(8760), const Duration(days: 1));
    });

    test('where a limit ends: that long after the last contact, later by what was excused', () {
      const contact = OrchardContact(lastContact: t0, latest: t0);
      expect(offlineLimitEnd(24, contact, t0), t0 + day);
      expect(offlineLimitEnd(24, contact, t0 + 30 * day), t0 + day, reason: 'where no proof is believed, whenever asked');
      expect(offlineLimitEnd(1, contact, t0), t0 + hour);
      expect(offlineLimitEnd(0, contact, t0), isNull, reason: 'no limit ends nowhere');
      expect(offlineLimitEnd(24, const OrchardContact(), t0), isNull, reason: 'nothing to measure it from');
      expect(offlineLimitEnd(24, const OrchardContact(lastContact: t0, latest: t0 + 5 * hour), t0), t0 + day,
          reason: 'from the last contact, whatever the clock has read since');
      expect(offlineLimitEnd(24, const OrchardContact(lastContact: t0, latest: t0, excused: 7 * hour), t0),
          t0 + day + 7 * hour);
      // No more than seven days are excused, and never less than nothing.
      expect(offlineLimitEnd(24, const OrchardContact(lastContact: t0, latest: t0, excused: 9 * day), t0),
          t0 + day + 7 * day);
      expect(offlineLimitEnd(24, const OrchardContact(lastContact: t0, latest: t0, excused: -5 * hour), t0), t0 + day);
      // The end is the last moment within the limit: reached one second on.
      expect(offlineHoursReached(24, contact, offlineLimitEnd(24, contact, t0)!), isFalse);
      expect(offlineHoursReached(24, contact, offlineLimitEnd(24, contact, t0)! + 1), isTrue);
    });

    test('about to be reached: within that time of its end, and not past it', () {
      const contact = OrchardContact(lastContact: t0, latest: t0);
      expect(offlineLimitNear(24, contact, t0), isFalse);
      expect(offlineLimitNear(24, contact, t0 + 18 * hour - 1), isFalse, reason: 'six hours and a second to go');
      expect(offlineLimitNear(24, contact, t0 + 18 * hour), isTrue, reason: 'six hours to go');
      expect(offlineLimitNear(24, contact, t0 + 23 * hour), isTrue);
      expect(offlineLimitNear(24, contact, t0 + day), isTrue, reason: 'the last moment within it');
      expect(offlineLimitNear(24, contact, t0 + day + 1), isFalse, reason: 'reached: no longer about to be');
      // An hour's limit is said a quarter of an hour ahead; a week's, a day.
      expect(offlineLimitNear(1, contact, t0 + 44 * 60), isFalse);
      expect(offlineLimitNear(1, contact, t0 + 45 * 60), isTrue);
      expect(offlineLimitNear(168, contact, t0 + 6 * day - 1), isFalse);
      expect(offlineLimitNear(168, contact, t0 + 6 * day), isTrue);
      // No limit is never about to be reached.
      expect(offlineLimitNear(0, contact, t0 + 1000 * day), isFalse);
      // What counts as reached already is not about to be: no contact to
      // measure from, and a clock turned back.
      expect(offlineLimitNear(24, const OrchardContact(), t0), isFalse);
      expect(offlineLimitNear(24, const OrchardContact(lastContact: t0, latest: t0 + 30 * hour), t0 + 20 * hour), isFalse);
      // A proven outage moves the end, and the time it is said in with it.
      const excused = OrchardContact(lastContact: t0, latest: t0, excused: 7 * hour);
      expect(offlineLimitNear(24, excused, t0 + 20 * hour), isFalse);
      expect(offlineLimitNear(24, excused, t0 + 25 * hour), isTrue);
      expect(offlineLimitNear(24, excused, t0 + 31 * hour), isTrue);
      expect(offlineLimitNear(24, excused, t0 + 31 * hour + 1), isFalse);
    });
  });

  // A proof of an outage says until when it may be believed (a quarter of
  // an hour, as the status service signs them), and the app asks again
  // every five minutes at the most. Counted only up to the proof itself, a
  // limit ran between two proofs: a device with less left than that wait
  // closed its Crate until the next proof opened it again.
  group('a proof of an outage is believed until the time it says', () {
    const minute = 60;
    const day = 24 * hour;
    const contact = OrchardContact(lastContact: t0, latest: t0);
    // Fifty-nine minutes away. Down for the last two, says a statement
    // that may be believed for a quarter of an hour.
    final proven = contact.excusing(since: t0 + 57 * minute, at: t0 + 59 * minute, until: t0 + 74 * minute);

    test('the time that passes while it is believed is excused as it passes, and no further', () {
      expect((proven.excused, proven.excusedThrough, proven.provenUntil), (2 * minute, t0 + 59 * minute, t0 + 74 * minute));
      expect(proven.excusedAsOf(t0 + 59 * minute), 2 * minute);
      expect(proven.excusedAsOf(t0 + 64 * minute), 7 * minute);
      expect(proven.excusedAsOf(t0 + 74 * minute), 17 * minute);
      expect(proven.excusedAsOf(t0 + 75 * minute), 17 * minute, reason: 'believed no further than it says');
      expect(proven.excusedAsOf(t0 + 9 * day), 17 * minute);
      // A clock that reads earlier than the proof (the two clocks may
      // differ by minutes): what was counted, and nothing taken off.
      expect(proven.excusedAsOf(t0 + 55 * minute), 2 * minute);
      // A proof with no word of how long it holds is believed no further
      // than itself.
      final bare = contact.excusing(since: t0 + 57 * minute, at: t0 + 59 * minute);
      expect(bare.provenUntil, t0 + 59 * minute);
      expect(bare.excusedAsOf(t0 + 70 * minute), 2 * minute);
      // And one that says it holds until before it was made, no further either.
      expect(contact.excusing(since: t0 + 57 * minute, at: t0 + 59 * minute, until: t0 + 40 * minute).provenUntil,
          t0 + 59 * minute);
      // Nothing is believed of a contact that knows of no proof.
      expect(contact.excusedAsOf(t0 + 5 * hour), 0);
      expect(const OrchardContact(lastContact: t0, latest: t0, excused: 600).excusedAsOf(t0 + 5 * hour), 600);
      // What was kept is not trusted to be within its bounds.
      expect(const OrchardContact(lastContact: t0, latest: t0, excused: -600).excusedAsOf(t0 + hour), 0);
      expect(const OrchardContact(lastContact: t0, latest: t0, excused: 9 * day).excusedAsOf(t0 + hour), 7 * day);
      // Never more than seven days of one stretch, counted or passing.
      final long = contact.excusing(since: t0, at: t0 + 7 * day - hour, until: t0 + 7 * day + hour);
      expect(long.excusedAsOf(t0 + 7 * day - hour), 7 * day - hour);
      expect(long.excusedAsOf(t0 + 7 * day), 7 * day);
      expect(long.excusedAsOf(t0 + 7 * day + hour), 7 * day);
    });

    test('a limit with minutes left does not run out between one proof and the next', () {
      // An hour's limit, three minutes left when the outage was proven.
      expect(offlineHoursReached(1, proven, t0 + 59 * minute), isFalse);
      expect(offlineHoursReached(1, proven, t0 + 62 * minute + 1), isFalse,
          reason: 'counted up to the proof alone, it had run out here, two minutes before the app asks again');
      expect(offlineLimitEnd(1, proven, t0 + 59 * minute), t0 + 62 * minute);
      expect(offlineLimitEnd(1, proven, t0 + 64 * minute), t0 + 67 * minute, reason: 'three minutes on from the moment');
      expect(offlineLimitEnd(1, proven, t0 + 74 * minute), t0 + 77 * minute);
      // The next proof, five minutes after the first: nothing jumps.
      final next = proven.excusing(since: t0 + 57 * minute, at: t0 + 64 * minute, until: t0 + 79 * minute);
      expect((next.excused, next.excusedThrough, next.provenUntil), (7 * minute, t0 + 64 * minute, t0 + 79 * minute));
      expect(next.excusedAsOf(t0 + 64 * minute), proven.excusedAsOf(t0 + 64 * minute));
      expect(next.excusedAsOf(t0 + 70 * minute), proven.excusedAsOf(t0 + 70 * minute));
      expect(offlineHoursReached(1, next, t0 + 78 * minute), isFalse);
      // No proof since, and the last is believed no longer: the limit runs
      // again, with its three minutes.
      expect(offlineLimitEnd(1, next, t0 + 90 * minute), t0 + 82 * minute);
      expect(offlineHoursReached(1, next, t0 + 82 * minute), isFalse);
      expect(offlineHoursReached(1, next, t0 + 82 * minute + 1), isTrue);
      // A device that was past its limit before the outage stays closed
      // through it: an outage opens nothing that was closed without it.
      final late = contact.excusing(since: t0 + 90 * minute, at: t0 + 2 * hour, until: t0 + 2 * hour + 15 * minute);
      expect(offlineHoursReached(1, late, t0 + 2 * hour), isTrue);
      expect(offlineHoursReached(1, late, t0 + 2 * hour + 10 * minute), isTrue);
      expect(offlineHoursReached(1, late, t0 + 3 * hour), isTrue);
    });

    test('a newer proof says how long it holds, the same one again changes nothing, an older one is not heard', () {
      // The same statement, handed over twice.
      expect(identical(proven.excusing(since: t0 + 57 * minute, at: t0 + 59 * minute, until: t0 + 74 * minute), proven),
          isTrue);
      // The same moment, said to hold for longer: believed for longer.
      final longer = proven.excusing(since: t0 + 57 * minute, at: t0 + 59 * minute, until: t0 + 80 * minute);
      expect((longer.excused, longer.excusedThrough, longer.provenUntil), (2 * minute, t0 + 59 * minute, t0 + 80 * minute));
      // And never for less than a proof already said.
      expect(identical(proven.excusing(since: t0 + 57 * minute, at: t0 + 59 * minute, until: t0 + 60 * minute), proven),
          isTrue);
      // A later proof that says it holds for less still counts its own
      // time, and takes back nothing of what the earlier one held.
      final shorter = proven.excusing(since: t0 + 57 * minute, at: t0 + 64 * minute, until: t0 + 70 * minute);
      expect((shorter.excused, shorter.excusedThrough, shorter.provenUntil),
          (7 * minute, t0 + 64 * minute, t0 + 74 * minute));
      // A statement from before the one that was counted says nothing new,
      // however long it claims to hold.
      expect(identical(proven.excusing(since: t0 + 57 * minute, at: t0 + 58 * minute, until: t0 + 5 * hour), proven),
          isTrue);
      // An outage that began after the last one was counted: what was
      // believed between the two is not counted.
      final second =
          proven.excusing(since: t0 + 3 * hour, at: t0 + 3 * hour + 5 * minute, until: t0 + 3 * hour + 20 * minute);
      expect((second.excused, second.excusedThrough, second.provenUntil),
          (7 * minute, t0 + 3 * hour + 5 * minute, t0 + 3 * hour + 20 * minute));
      // The furthest reading of the clock is kept with it.
      final seen = proven.seeing(t0 + 60 * minute);
      expect((seen.latest, seen.excused, seen.excusedThrough, seen.provenUntil),
          (t0 + 60 * minute, 2 * minute, t0 + 59 * minute, t0 + 74 * minute));
      // With no contact to measure from, a proof is nothing.
      const never = OrchardContact();
      expect(identical(never.excusing(since: t0, at: t0 + hour, until: t0 + 2 * hour), never), isTrue);
      // Nor is one made no later than the last contact, however long it
      // says it holds: the service answered this device after it.
      expect(identical(contact.excusing(since: t0 - hour, at: t0, until: t0 + hour), contact), isTrue);
      expect(identical(contact.excusing(since: t0 - hour, at: t0 - minute, until: t0 + hour), contact), isTrue);
      // Found down this very moment: no time to count yet, and what passes
      // while it is believed is measured from that moment, not from where
      // the count stood before.
      final found = contact.excusing(since: t0 + 59 * minute, at: t0 + 59 * minute, until: t0 + 74 * minute);
      expect((found.excused, found.excusedThrough, found.provenUntil), (0, t0 + 59 * minute, t0 + 74 * minute));
      expect(found.excusedAsOf(t0 + 64 * minute), 5 * minute);
      expect(found.standsStill(t0 + 64 * minute), isTrue);
      final later = proven.excusing(since: t0 + 3 * hour, at: t0 + 3 * hour, until: t0 + 3 * hour + 15 * minute);
      expect((later.excused, later.excusedThrough, later.provenUntil),
          (2 * minute, t0 + 3 * hour, t0 + 3 * hour + 15 * minute));
      expect(later.excusedAsOf(t0 + 3 * hour + 5 * minute), 7 * minute);
    });

    test('once the service is known to be up its proof is believed no further, and what passed is counted', () {
      // Two minutes after the proof.
      final over = proven.ending(t0 + 61 * minute);
      expect((over.excused, over.excusedThrough, over.provenUntil), (4 * minute, t0 + 61 * minute, t0 + 61 * minute));
      expect(over.excusedAsOf(t0 + 61 * minute), 4 * minute);
      expect(over.excusedAsOf(t0 + 70 * minute), 4 * minute, reason: 'the limit runs from here');
      expect((over.lastContact, over.latest), (t0, t0), reason: 'an outage ending is no contact');
      expect(offlineLimitEnd(1, over, t0 + 62 * minute), t0 + 64 * minute);
      expect(offlineHoursReached(1, over, t0 + 64 * minute), isFalse);
      expect(offlineHoursReached(1, over, t0 + 64 * minute + 1), isTrue);
      // Heard after the proof was believed no longer: all it held is counted.
      final after = proven.ending(t0 + 2 * hour);
      expect((after.excused, after.excusedThrough, after.provenUntil), (17 * minute, t0 + 74 * minute, t0 + 74 * minute));
      // By a clock that reads earlier than the proof: nothing more counted.
      final early = proven.ending(t0 + 50 * minute);
      expect((early.excused, early.excusedThrough, early.provenUntil), (2 * minute, t0 + 59 * minute, t0 + 59 * minute));
      // Nothing believed beyond what was counted: nothing changes.
      expect(identical(over.ending(t0 + 62 * minute), over), isTrue);
      expect(identical(contact.ending(t0 + hour), contact), isTrue);
      const never = OrchardContact(provenUntil: t0 + hour);
      expect(identical(never.ending(t0), never), isTrue);
      // A later proof is taken in from where this one ended.
      final again = over.excusing(since: t0 + 57 * minute, at: t0 + 65 * minute, until: t0 + 80 * minute);
      expect((again.excused, again.excusedThrough, again.provenUntil), (8 * minute, t0 + 65 * minute, t0 + 80 * minute));
    });

    test('the limits stand still while a proof covers the moment, and nothing is about to close then', () {
      expect(proven.standsStill(t0 + 59 * minute), isTrue);
      expect(proven.standsStill(t0 + 55 * minute), isTrue, reason: 'by a clock a few minutes behind the proof too');
      expect(proven.standsStill(t0 + 74 * minute), isTrue, reason: 'the last moment it is believed');
      expect(proven.standsStill(t0 + 74 * minute + 1), isFalse);
      expect(contact.standsStill(t0 + hour), isFalse, reason: 'no proof');
      expect(contact.excusing(since: t0 + 57 * minute, at: t0 + 59 * minute).standsStill(t0 + 59 * minute), isFalse,
          reason: 'a proof believed no further than itself holds nothing still');
      expect(proven.ending(t0 + 61 * minute).standsStill(t0 + 61 * minute), isFalse, reason: 'from the moment it is over');
      // Three minutes left of an hour: about to close, were it not for the
      // proof; and about to close again once the proof is believed no more.
      expect(offlineLimitNear(1, contact, t0 + 57 * minute), isTrue);
      expect(offlineLimitNear(1, proven, t0 + 59 * minute), isFalse);
      expect(offlineLimitNear(1, proven, t0 + 74 * minute), isFalse);
      expect(offlineLimitNear(1, proven, t0 + 74 * minute + 1), isTrue);
      expect(offlineLimitNear(1, proven, t0 + 77 * minute), isTrue);
      expect(offlineLimitNear(1, proven, t0 + 77 * minute + 1), isFalse, reason: 'reached');
      // The time a limit is said in moves with its end: a day's limit, an
      // hour of it excused by a proof that was believed for a quarter of an
      // hour more, is near six hours before that later end, not before the
      // one it had when the proof was made.
      final day24 = contact.excusing(since: t0 + 9 * hour, at: t0 + 10 * hour, until: t0 + 10 * hour + 15 * minute);
      expect(offlineLimitEnd(24, day24, t0 + 19 * hour), t0 + 25 * hour + 15 * minute);
      expect(offlineLimitNear(24, day24, t0 + 19 * hour + 15 * minute - 1), isFalse);
      expect(offlineLimitNear(24, day24, t0 + 19 * hour + 15 * minute), isTrue);
      // Once all that is ever excused has been, the limits run although a
      // proof still covers the moment.
      final most = contact.excusing(since: t0, at: t0 + 7 * day, until: t0 + 7 * day + 15 * minute);
      expect(most.excused, 7 * day);
      expect(most.standsStill(t0 + 7 * day + 5 * minute), isFalse);
      expect(offlineLimitEnd(24, most, t0 + 7 * day + 5 * minute), t0 + 8 * day);
      expect(offlineLimitNear(24, most, t0 + 7 * day + 18 * hour), isTrue);
      final almost = contact.excusing(since: t0, at: t0 + 7 * day - 10 * minute, until: t0 + 7 * day + 5 * minute);
      expect(almost.standsStill(t0 + 7 * day - minute), isTrue);
      expect(almost.standsStill(t0 + 7 * day), isFalse, reason: 'the passing minutes have used up what was left');
    });
  });

  group('the offline limit and an outage that is ours', () {
    const rules = RecordRules(offlineHours: 24);
    const day = 24 * hour;
    const contact = OrchardContact(lastContact: t0, latest: t0);

    test('the time ZestSSH Cloud was down is not counted', () {
      // Thirty hours since this device reached it, seven of them an outage.
      expect(offlineLimitReached(rules, contact, t0 + 30 * hour), isTrue);
      final excused = contact.excusing(since: t0 + 20 * hour, at: t0 + 27 * hour);
      expect(excused.excused, 7 * hour);
      expect(excused.excusedThrough, t0 + 27 * hour);
      expect((excused.lastContact, excused.latest), (t0, t0), reason: 'the contact itself is as it was');
      expect(offlineLimitReached(rules, excused, t0 + 30 * hour), isFalse);
      // And it runs on from there: twenty-four hours of its own, no more.
      expect(offlineLimitReached(rules, excused, t0 + 31 * hour), isFalse, reason: 'exactly at the limit');
      expect(offlineLimitReached(rules, excused, t0 + 31 * hour + 1), isTrue);
    });

    test('a device that was past its limit before the outage began stays closed', () {
      // Thirty hours away, and then an outage of ten: the thirty were its own.
      final excused = contact.excusing(since: t0 + 30 * hour, at: t0 + 40 * hour);
      expect(excused.excused, 10 * hour);
      expect(offlineLimitReached(rules, excused, t0 + 40 * hour), isTrue);
    });

    test('an outage that began before the last contact counts from the contact only', () {
      final excused = contact.excusing(since: t0 - 5 * hour, at: t0 + 2 * hour);
      expect(excused.excused, 2 * hour);
    });

    test('no moment is counted twice, however many proofs of the same outage there are', () {
      var c = contact.excusing(since: t0 + hour, at: t0 + 3 * hour);
      expect(c.excused, 2 * hour);
      // The same outage, said again a little later, and again.
      c = c.excusing(since: t0 + hour, at: t0 + 3 * hour + 300);
      expect(c.excused, 2 * hour + 300);
      c = c.excusing(since: t0 + hour, at: t0 + 4 * hour);
      expect(c.excused, 3 * hour);
      // An older proof, or the same one, adds nothing and changes nothing.
      expect(identical(c.excusing(since: t0 + hour, at: t0 + 2 * hour), c), isTrue);
      expect(identical(c.excusing(since: t0 + hour, at: t0 + 4 * hour), c), isTrue);
      // A second outage later in the same stretch is added to the first.
      c = c.excusing(since: t0 + 10 * hour, at: t0 + 12 * hour);
      expect(c.excused, 5 * hour);
      expect(c.excusedThrough, t0 + 12 * hour);
    });

    test('at most seven days of one stretch are excused, whatever is proven', () {
      expect(kOutageExcuseMax, const Duration(days: 7));
      final long = contact.excusing(since: t0, at: t0 + 10 * day);
      expect(long.excused, 7 * day);
      expect(offlineLimitReached(rules, long, t0 + 8 * day), isFalse, reason: 'seven days of outage and one of its own');
      expect(offlineLimitReached(rules, long, t0 + 8 * day + 1), isTrue);
      // More proofs do not push it further.
      final more = long.excusing(since: t0, at: t0 + 20 * day);
      expect(more.excused, 7 * day);
      // And a number that was kept is held to it too, whatever it says.
      const kept = OrchardContact(lastContact: t0, latest: t0, excused: 1000 * day);
      expect(offlineLimitReached(rules, kept, t0 + 8 * day), isFalse);
      expect(offlineLimitReached(rules, kept, t0 + 8 * day + 1), isTrue);
      const negative = OrchardContact(lastContact: t0, latest: t0, excused: -1000 * day);
      expect(offlineLimitReached(rules, negative, t0 + 24 * hour), isFalse);
      expect(offlineLimitReached(rules, negative, t0 + 24 * hour + 1), isTrue, reason: 'never less than nothing');
      expect(negative.excusing(since: t0, at: t0 + hour).excused, hour);
    });

    test('with no contact to measure from nothing is excused, and the limit counts as reached', () {
      const never = OrchardContact();
      final same = never.excusing(since: t0, at: t0 + 10 * hour);
      expect(identical(same, never), isTrue);
      expect(offlineLimitReached(rules, same, t0 + 10 * hour), isTrue);
    });

    test('a clock turned back counts as past the limit, whatever was excused', () {
      final excused = const OrchardContact(lastContact: t0, latest: t0 + 10 * hour).excusing(since: t0, at: t0 + 10 * hour);
      expect(offlineLimitReached(rules, excused, t0 + 10 * hour), isFalse);
      expect(offlineLimitReached(rules, excused, t0 + 10 * hour - kClockSlack.inSeconds - 1), isTrue);
    });

    test('the clock moving on keeps what was excused', () {
      final excused = contact.excusing(since: t0 + hour, at: t0 + 3 * hour);
      final later = excused.seeing(t0 + 5 * hour);
      expect((later.lastContact, later.latest, later.excused, later.excusedThrough), (t0, t0 + 5 * hour, 2 * hour, t0 + 3 * hour));
    });

    test('no limit is no limit, outage or none', () {
      expect(offlineLimitReached(RecordRules.none, contact.excusing(since: t0, at: t0 + hour), t0 + 1000 * day), isFalse);
    });
  });

  group('the rules as this device keeps them', () {
    test('read back as they were stored', () {
      const rules = RecordRules(
        require2fa: true,
        emailDomains: {'b.example', 'a.example'},
        requireAppLock: true,
        maxLockMinutes: 15,
        noExport: true,
        offlineHours: 72,
        reauthDays: 30,
      );
      final back = RecordRules.fromStored(rules.toBody());
      expect(back.toBody(), rules.toBody());
      expect(back.isNone, isFalse);
    });

    test('anything missing or of the wrong kind reads as off', () {
      expect(RecordRules.fromStored(null).isNone, isTrue);
      expect(RecordRules.fromStored('text').isNone, isTrue);
      final odd = RecordRules.fromStored({
        'require_2fa': 'true',
        'email_domains': ['ok.example', 3],
        'max_lock_minutes': '15',
        'no_export': 1,
        'offline_hours': 12,
      });
      expect(odd.require2fa, isFalse);
      expect(odd.emailDomains, {'ok.example'});
      expect(odd.maxLockMinutes, 0);
      expect(odd.noExport, isFalse);
      expect(odd.offlineHours, 12);
    });

    test('copyWith changes only what it names', () {
      const rules = RecordRules(require2fa: true, offlineHours: 24);
      final next = rules.copyWith(noExport: true);
      expect(next.toBody(), {...rules.toBody(), 'no_export': true});
    });

    test('rules as the server names them', () {
      expect(UnmetRule.fromServer('two_step'), UnmetRule.twoStep);
      expect(UnmetRule.fromServer('email_domain'), UnmetRule.emailDomain);
      expect(UnmetRule.fromServer('reauth'), UnmetRule.reauth);
      expect(UnmetRule.fromServer('sso'), UnmetRule.sso);
      expect(UnmetRule.fromServer('trusted_device'), UnmetRule.trustedDevice);
      expect(kTrustedDeviceRule, 'trusted_device');
      expect(UnmetRule.fromServer('something_new'), isNull);
      expect([for (final r in UnmetRule.values) if (r.server) r],
          [UnmetRule.twoStep, UnmetRule.emailDomain, UnmetRule.reauth, UnmetRule.sso, UnmetRule.trustedDevice]);
    });
  });

  group('when this device last reached ZestSSH Cloud', () {
    late AppDatabase db;
    late LocalStateStore store;
    var now = t0;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = LocalStateStore(db);
      now = t0;
    });
    tearDown(() => db.close());

    OrchardContactNotifier notifier() => OrchardContactNotifier(store, now: () => now);

    test('kept in the encrypted database and read back by the next unlock', () async {
      final a = notifier();
      await a.loaded;
      expect(a.state.lastContact, isNull);
      await a.reached();
      expect((a.state.lastContact, a.state.latest), (t0, t0));
      expect(await store.readInt(OrchardContactNotifier.lastKey), t0);

      now = t0 + 500;
      final b = notifier();
      await b.loaded;
      expect((b.state.lastContact, b.state.latest), (t0, t0));
    });

    test("the clock's furthest reading is kept, written at most once a minute, and never lowered", () async {
      final a = notifier();
      await a.loaded;
      await a.reached();
      now = t0 + 30;
      await a.sawTime();
      expect(a.state.latest, t0 + 30);
      expect(await store.readInt(OrchardContactNotifier.latestKey), t0, reason: 'not yet a minute');
      now = t0 + 90;
      await a.sawTime();
      expect(await store.readInt(OrchardContactNotifier.latestKey), t0 + 90);
      now = t0 + 10;
      await a.sawTime();
      expect(a.state.latest, t0 + 90, reason: 'a clock turned back does not lower it');
    });

    test('reaching ZestSSH Cloud before what was kept is read keeps the newer', () async {
      await store.writeInt(OrchardContactNotifier.lastKey, t0 - 100 * hour);
      await store.writeInt(OrchardContactNotifier.latestKey, t0 - 100 * hour);
      final a = notifier();
      final reached = a.reached();
      await a.loaded;
      await reached;
      expect(a.state.lastContact, t0);
    });

    test('while locked (no store) it is kept in memory only', () async {
      final a = OrchardContactNotifier(null, now: () => now);
      await a.loaded;
      await a.reached();
      expect(a.state.lastContact, t0);
    });
  });
}
