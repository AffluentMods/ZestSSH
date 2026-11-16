import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Variable;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/record/local_record.dart' show latestRecordIn;
import 'package:zestssh/features/orchards/rules/offline_pass.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/type_name.dart';

// A Crate's own offline limit on this device (3.0, the outage
// work). An Orchard's owners can say, Crate by Crate, how many
// hours a device may go without reaching ZestSSH Cloud before that Crate
// closes on it (RecordCrate.offlineHours, in the signed record). The
// Orchard's own limit closes all of the Orchard, by closing its database
// (spaces.dart); a Crate's items live in that same database beside those of
// the Crates that stay open, so a closed Crate is a rule the app keeps
// wherever its items are about to be used: its hosts do not connect, its
// keys sign in nowhere and hand out no secret, and nothing in it is shown
// in clear, copied, exported or changed. Its items stay listed, so that
// nobody takes them for lost, and say why they are closed.
//
// Whether a Crate is closed is worked out each time it is asked, from the
// record and from when this device last reached ZestSSH Cloud: nothing is
// kept that could go stale, and a Crate opens again the moment the device
// is back in contact (or an outage of ours is proven, see
// OrchardContact.excused). Like every guardrail (guardrails.dart) this is
// the app's rule, not cryptography: the device holds what it holds.
//
// A limit that is reached closes nothing while an offline pass holds that an
// owner signed for this device (rules/offline_pass.dart): one for the Crate,
// or one for all of the Orchard. A pass is kept here, in the Orchard's own
// database, as it was checked when it was taken in.

//
// A Crate this account holds only until a set time (access on request)
// is closed here in the same way from the second that time comes: the
// Orchard's database keeps until when each such Crate is held
// ([kAccessUntilState]), and the device's own clock decides, so that it
// ends whether or not the server can be reached and whether or not
// anything has taken the Crate off the device yet (orchard_access.dart
// does, as soon as it runs).

final _contacts = Expando<DeviceContact>('how this device stands with ZestSSH Cloud');

/// Where an Orchard's database keeps until when this account holds each
/// Crate it opens only until a set time: a JSON map of Crate id to the
/// second, since the epoch, at which that time comes. Written whenever the
/// Orchard is brought up to date (orchard_service.dart), and read here.
const String kAccessUntilState = 'access.until';

/// Gives the Orchard database [db] how this device stands with ZestSSH
/// Cloud, so that whoever holds [db] can measure a Crate's offline limit.
/// A database nobody gave one counts every Crate with a limit as closed:
/// a limit that cannot be measured counts as reached, as an Orchard's does.
void attachDeviceContact(AppDatabase db, DeviceContact? contact) => _contacts[db] = contact;

/// How the Crates of an Orchard stand with their own offline limits on
/// this device, as of one look.
class CrateLimits {
  const CrateLimits({this.closed = const {}, this.closing = const {}, this.ended = const {}});

  /// No Crate closed, none about to be.
  static const none = CrateLimits();

  /// The Crates that are closed, each with its limit in hours.
  final Map<String, int> closed;

  /// The Crates that are open and about to close (in the last quarter of
  /// their limit, see offlineWarningBefore), each with the last second
  /// (since the epoch) at which it is still open: for saying so before it
  /// happens. None while the limits stand still for a proven outage of
  /// ZestSSH Cloud's own.
  final Map<String, int> closing;

  /// The Crates this account held only until a set time that has come by
  /// this device's clock, each with the second it came: closed here
  /// from then on, until they are off the device.
  final Map<String, int> ended;
}

/// How the Crates of the Orchard in [db] stand with their own offline
/// limits on this device right now. [CrateLimits.none] in your Tree's
/// database, and while the Orchard has no record here yet.
Future<CrateLimits> crateLimitsIn(AppDatabase db) async {
  // (Null for your Tree's database, which has no record.)
  final record = await latestRecordIn(db);
  if (record == null) return CrateLimits.none;
  final ended = await _accessOverIn(db);
  final limited = {
    for (final c in record.crates.values)
      if (c.offlineHours > 0) c.id: c.offlineHours,
  };
  // Where no Crate has a limit, nobody is asked how the device stands.
  if (limited.isEmpty) return ended.isEmpty ? CrateLimits.none : CrateLimits(ended: ended);
  final contact = _contacts[db];
  if (contact == null) return CrateLimits(closed: limited, ended: ended);
  await contact.loaded?.call();
  final state = contact.read();
  final now = contact.now();
  final closed = <String, int>{};
  final closing = <String, int>{};
  for (final MapEntry(key: id, value: hours) in limited.entries) {
    final stands = await _standing(hours, state, now, () => _passFor(db, id));
    if (stands.closed) {
      closed[id] = hours;
    } else if (stands.closesAt case final at?) {
      closing[id] = at;
    }
  }
  return CrateLimits(closed: closed, closing: closing, ended: ended);
}

/// The Crates of [db] this account held only until a set time that has come
/// ([kAccessUntilState]), each with the second it came. By this device's
/// clock, and by the furthest it has read where the device keeps that: a
/// clock turned back gives no time back.
Future<Map<String, int>> _accessOverIn(AppDatabase db) async {
  final kept = await LocalStateStore(db).read(kAccessUntilState);
  if (kept == null) return const {};
  final Object? until;
  try {
    until = jsonDecode(kept);
  } on FormatException {
    return const {};
  }
  if (until is! Map<String, dynamic>) return const {};
  final contact = _contacts[db];
  final now = contact == null
      ? DateTime.now().millisecondsSinceEpoch ~/ 1000
      : math.max(contact.now(), contact.read().latest);
  return {
    for (final MapEntry(key: id, value: at) in until.entries)
      if (at is int && at <= now) id: at,
  };
}

/// Where an Orchard's database keeps the offline passes this device took
/// in, by what each is for: a Crate's id, or [kAllOfOrchard].
const String kOfflinePassState = 'offline_pass.';

/// The pass this device holds in [db] for [crateId] ([kAllOfOrchard] for
/// all of the Orchard), run out or not; null where it holds none.
Future<HeldPass?> heldPassIn(AppDatabase db, String crateId) async =>
    HeldPass.fromStored(await LocalStateStore(db).read('$kOfflinePassState$crateId'));

/// The pass that lifts the limit of [crateId] the longest: its own, or one
/// for all of the Orchard.
Future<HeldPass?> _passFor(AppDatabase db, String crateId) async {
  final own = await heldPassIn(db, crateId);
  final all = await heldPassIn(db, kAllOfOrchard);
  if (own == null || all == null) return own ?? all;
  return own.until >= all.until ? own : all;
}

/// What a limit of [hours] comes to at [now] on a device that stands as
/// [state], with the pass that may lift it ([pass], asked for only where
/// the limit is reached or near): closed; or open, and then the last second
/// it is open, where it is about to close. What ends it is the limit, or
/// the pass where the limit is reached already or the pass reaches further
/// than the limit does.
Future<({bool closed, int? closesAt})> _standing(
    int hours, OrchardContact state, int now, Future<HeldPass?> Function() pass) async {
  final reached = offlineHoursReached(hours, state, now);
  if (!reached && !offlineLimitNear(hours, state, now)) return (closed: false, closesAt: null);
  final held = await pass();
  final end = reached ? null : offlineLimitEnd(hours, state, now);
  if (held != null && held.holdsAt(now, state.latest) && (end == null || held.until > end)) {
    return (closed: false, closesAt: held.endsSoonAt(now, state.latest) ? held.until : null);
  }
  return (closed: reached, closesAt: end);
}

/// The offline passes that hold on this device right now for the Orchard
/// in [db], by what each is for (a Crate's id, or [kAllOfOrchard]), with
/// the last second each holds: for saying on screen that something is open
/// by a pass, and until when. None where nobody told the database how the
/// device stands.
Future<Map<String, int>> passesHoldingIn(AppDatabase db) async {
  final contact = _contacts[db];
  if (contact == null) return const {};
  final store = LocalStateStore(db);
  await contact.loaded?.call();
  final now = contact.now();
  final latest = contact.read().latest;
  final out = <String, int>{};
  for (final key in await store.keysWithPrefix(kOfflinePassState)) {
    final pass = HeldPass.fromStored(await store.read(key));
    if (pass != null && pass.holdsAt(now, latest)) out[key.substring(kOfflinePassState.length)] = pass.until;
  }
  return out;
}

/// What is past its offline limit on this device right now, whatever pass
/// holds it open: [kAllOfOrchard] for the Orchard's own limit of
/// [orchardHours], and each Crate that is past its own, by its id. For a
/// device that is asked to sign a pass: one that is past a limit itself
/// lifts it for nobody, since it has not heard from the Orchard for too
/// long to speak for it. Where nobody told the database how the device
/// stands, every limit counts as reached.
Future<Set<String>> limitsReachedIn(AppDatabase db, {required int orchardHours}) async {
  final record = await latestRecordIn(db);
  final limited = {
    if (orchardHours > 0) kAllOfOrchard: orchardHours,
    if (record != null)
      for (final c in record.crates.values)
        if (c.offlineHours > 0) c.id: c.offlineHours,
  };
  if (limited.isEmpty) return const {};
  final contact = _contacts[db];
  if (contact == null) return limited.keys.toSet();
  await contact.loaded?.call();
  final state = contact.read();
  final now = contact.now();
  return {
    for (final MapEntry(key: what, value: hours) in limited.entries)
      if (offlineHoursReached(hours, state, now)) what,
  };
}

/// Whether a pass for all of the Orchard in [db] holds on this device right
/// now: then its own offline limit does not close it. False where nobody
/// told the database how the device stands (a pass cannot be measured then
/// either).
Future<bool> orchardPassHoldsIn(AppDatabase db) async {
  final contact = _contacts[db];
  if (contact == null) return false;
  final pass = await heldPassIn(db, kAllOfOrchard);
  if (pass == null) return false;
  await contact.loaded?.call();
  return pass.holdsAt(contact.now(), contact.read().latest);
}

/// The Crates of the Orchard in [db] that are closed on this device right
/// now: by an offline limit of their own, each with its limit in hours, and
/// those this account held only until a set time that has come, each with
/// 0 (which no limit is).
Future<Map<String, int>> closedCratesIn(AppDatabase db) async {
  final limits = await crateLimitsIn(db);
  if (limits.ended.isEmpty) return limits.closed;
  return {
    ...limits.closed,
    for (final id in limits.ended.keys) id: 0,
  };
}

/// When the Orchard's own offline limit of [hours] is about to close all of
/// the Orchard in [db] on this device: the last second (since the epoch) at
/// which it is still open, or null while that is not near, while the limits
/// stand still for a proven outage, or where it cannot be measured here
/// (then the scheduler closes it, see spaces.dart). With a pass for all of
/// the Orchard that reaches further than the limit, it is the pass's end
/// that is about to close it.
Future<int?> orchardClosingAt(AppDatabase db, int hours) async {
  final contact = _contacts[db];
  if (hours <= 0 || contact == null) return null;
  await contact.loaded?.call();
  final state = contact.read();
  final now = contact.now();
  return (await _standing(hours, state, now, () => heldPassIn(db, kAllOfOrchard))).closesAt;
}

/// What is about to close on this device in one Orchard, for saying so:
/// all of it by the Orchard's own limit ([all], under the key '') and the
/// Crates their own limits are about to close ([crates], by id), each with
/// the last second, since the epoch, at which it is still open. A Crate
/// that would close no sooner than all of the Orchard is not named beside
/// it: what closes it is the Orchard closing.
Map<String, int> closingSoon(int? all, Map<String, int> crates) => {
      '': ?all,
      for (final MapEntry(key: id, value: end) in crates.entries)
        if (all == null || end < all) id: end,
    };

/// What was asked of a Crate that its own offline limit has closed on this
/// device is refused. [message] says so in the person's language, with what
/// opens it again; it is what [toString] gives, so that whatever shows this
/// shows that.
class CrateClosedOffline implements Exception, HasTypeName {
  const CrateClosedOffline(
      {required this.crateId, required this.hours, required this.message, this.orchardId, this.accessOver = false});

  final String crateId;

  /// The Orchard the Crate is of, as its database says: whatever shows the
  /// refusal offers an offline pass for the Crate from it.
  final String? orchardId;

  /// The Crate's limit, in hours.
  final int hours;

  /// It is closed because this account held it only until a set time that
  /// has come, and not by an offline limit ([hours] is 0): reaching
  /// ZestSSH Cloud does not open it, and neither does an offline pass.
  final bool accessOver;

  final String message;

  @override
  String toString() => message;

  @override
  String get typeName => 'CrateClosedOffline';
}

/// What is said of the Crate named [crateName] once its offline limit has
/// closed it on this device. It opens again when the device reaches
/// ZestSSH Cloud. Where the service is the one that cannot be reached
/// ([reach]: down, not responding, or answering with a fault), "connect to
/// the internet" would send the person looking for a fault that is not
/// theirs: they are told that nothing needs doing and that it opens again
/// by itself (as for an Orchard, orchardClosedOfflineText).
String crateClosedOfflineText(AppLocalizations l10n, String crateName, CloudReach? reach) =>
    cloudIsWhatIsAway(reach) ? l10n.crateClosedOfflineCloud(crateName) : l10n.crateClosedOfflineError(crateName);

/// Whether, as far as the app knows ([reach]), ZestSSH Cloud is the one
/// that cannot be reached (it is down, does not respond, or answers with a
/// fault of its own): then nothing needs doing on the device, and nobody
/// is told to connect to the internet.
bool cloudIsWhatIsAway(CloudReach? reach) =>
    reach == CloudReach.down || reach == CloudReach.notResponding || reach == CloudReach.fault;

/// The refusal for the Crate [crateId] of [db] when it is closed on this
/// device (one of [closed], when the caller has already asked), or null
/// while it is open.
Future<CrateClosedOffline?> crateClosedIn(AppDatabase db, String? crateId, {Map<String, int>? closed}) async {
  final hours = (closed ?? await closedCratesIn(db))[crateId];
  if (hours == null || crateId == null) return null;
  final row = await db
      .customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?', variables: [Variable(crateId)])
      .getSingleOrNull();
  final name = row?.read<String?>('name');
  final info = await db.customSelect('SELECT orchard_id FROM orchard_info WHERE id = 1').getSingleOrNull();
  final shown = name == null || name.isEmpty ? gl10n.crateUnnamed : name;
  return CrateClosedOffline(
    crateId: crateId,
    orchardId: info?.read<String?>('orchard_id'),
    hours: hours,
    accessOver: hours == 0,
    message: hours == 0
        ? gl10n.crateAccessOverError(shown)
        : crateClosedOfflineText(gl10n, shown, currentCloudReach?.state.value.reach),
  );
}

/// The refusal for the item [key] of [kind] ('host', 'key', 'snippet', ...)
/// in [db] when the Crate it is in is closed on this device, or null. An
/// item not placed yet is in the Crate new items go into, as everywhere.
Future<CrateClosedOffline?> itemClosedIn(AppDatabase db, String kind, String key) async {
  final closed = await closedCratesIn(db);
  // (Nothing is closed, as nearly always: the database is asked no more.)
  if (closed.isEmpty) return null;
  return crateClosedIn(db, await CratePlacement(db).crateOf(kind, key), closed: closed);
}

/// Throws [CrateClosedOffline] when the host [hostId] of [db] is saved in a
/// Crate that is closed on this device, or the key [keyId] is in one: the
/// host does not connect, and the key signs in nowhere. A host that is not
/// saved (an address typed for a quick connect) uses nothing a Crate holds,
/// so only its key, when it has one, is asked about.
Future<void> requireCratesOpenIn(AppDatabase db, {String? hostId, String? keyId}) async {
  final closed = await closedCratesIn(db);
  // (Nothing is closed, as nearly always, and always in your Tree: the
  // database is asked no more. Every connection comes through here, the
  // monitor's every poll included.)
  if (closed.isEmpty) return;
  final placement = CratePlacement(db);
  if (hostId != null) {
    final saved = await db
        .customSelect('SELECT 1 AS x FROM connections WHERE id = ?', variables: [Variable(hostId)])
        .getSingleOrNull();
    if (saved != null) {
      final refusal = await crateClosedIn(db, await placement.crateOf('host', hostId), closed: closed);
      if (refusal != null) throw refusal;
    }
  }
  if (keyId != null) {
    final refusal = await crateClosedIn(db, await placement.crateOf('key', keyId), closed: closed);
    if (refusal != null) throw refusal;
  }
}
