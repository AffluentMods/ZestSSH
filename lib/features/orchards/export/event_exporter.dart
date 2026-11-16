import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, TlsException;
import 'dart:math' as math;
import 'dart:ui' show Locale;

import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/export/event_export.dart';
import 'package:zestssh/features/orchards/export/export_settings.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart' show OrchardClosedOffline;
import 'package:zestssh/features/orchards/sync/crate_server.dart' show OrchardServerException;
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/own_network_http.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

// The device that sends an Orchard's events on (3.0).
//
// An owner sets it up on one device: the device makes a signing key, the
// Orchard's record takes its public half (export.set, which every member's
// app reads, so nobody is watched from outside without being told), and
// the private half stays here with the address the events go to. From then
// on this device sends every entry of the record, starting with the one
// that turned sending on, and every note of activity that arrives, each
// signed with that key, straight to that address. ZestSSH Cloud takes no
// part: it cannot read the activity, and it never learns the address.
//
// Events go while ZestSSH runs on this device, after each sync and once a
// minute. What could not be sent waits and goes with the next round, in
// order; nothing is skipped. An event may come twice (the device lost how
// far it got); it never fails to come because another did.
//
// When sending ends (turned off, activity no longer recorded, this owner no
// longer one, or another device took over) this device says what it has
// left and forgets the key and the address: the record up to the entry
// that ended it and, where another device took over, what members did
// until now (the device that took over starts with what they do from its
// own set-up on). Where the change that ends it is made on this device, it
// first sends what it had not sent yet. A request the receiver does not
// take ends that as well: a device that no longer sends does not go on
// trying.

/// Why a request to the address did not deliver its events.
enum ExportFailure {
  /// The receiver answered with something other than success.
  refused,

  /// No answer in time.
  timeout,

  /// The connection could not be made secure (the receiver's certificate
  /// was not accepted, most often).
  certificate,

  /// The address could not be reached.
  unreachable,

  /// Anything else.
  other,
}

/// What came of one request.
class ExportDelivery {
  const ExportDelivery.delivered(int this.status) : failure = null;
  const ExportDelivery.failed(ExportFailure this.failure, {this.status});

  /// The receiver's status, when it answered.
  final int? status;
  final ExportFailure? failure;

  bool get ok => failure == null;
}

/// Sends [body] to [to] and says what came of it. Never throws.
typedef ExportPost = Future<ExportDelivery> Function(ExportDestination to, String body);

/// [ExportPost] over HTTP: a POST that follows no redirect (the header it
/// carries is for the address it was given, and nowhere else), waits
/// [timeout] at most, and keeps nothing of what the receiver answers but
/// its status. Plain http only to an address on the person's own network
/// (own_network_http.dart).
ExportPost httpExportPost({http.Client? client, Duration timeout = const Duration(seconds: 20)}) {
  final inner = OwnNetworkHttpClient(inner: client);
  return (to, body) async {
    try {
      final request = http.Request('POST', to.url)
        ..followRedirects = false
        ..headers.addAll(to.headers)
        ..bodyBytes = utf8.encode(body);
      final response = await inner.send(request).timeout(timeout);
      final status = response.statusCode;
      // The receiver said whether it took them: what it writes after that
      // is not waited for longer than this, and changes nothing.
      try {
        await response.stream.drain<void>().timeout(timeout);
      } catch (_) {}
      return status >= 200 && status < 300
          ? ExportDelivery.delivered(status)
          : ExportDelivery.failed(ExportFailure.refused, status: status);
    } on TimeoutException {
      return const ExportDelivery.failed(ExportFailure.timeout);
    } on TlsException {
      // (A certificate that is not accepted is one of these.)
      return const ExportDelivery.failed(ExportFailure.certificate);
    } on SocketException {
      return const ExportDelivery.failed(ExportFailure.unreachable);
    } on PlainHttpRefused {
      return const ExportDelivery.failed(ExportFailure.unreachable);
    } catch (e) {
      AppLogger.info('Event export: a request failed (${errorKind(e)})');
      return const ExportDelivery.failed(ExportFailure.other);
    }
  };
}

/// How sending went so far on this device: when events last went, how many
/// since it was set up, and what stopped the last try (nothing, when it
/// went).
class ExportStatus {
  const ExportStatus({this.sentAt, this.sent = 0, this.failure, this.failedStatus, this.failedAt});

  static const none = ExportStatus();

  /// When events were last delivered, in seconds since the epoch.
  final int? sentAt;

  /// How many were delivered since sending was set up here.
  final int sent;

  final ExportFailure? failure;
  final int? failedStatus;
  final int? failedAt;

  String toText() => jsonEncode({
        'sent_at': ?sentAt,
        'sent': sent,
        'failure': ?failure?.name,
        'failed_status': ?failedStatus,
        'failed_at': ?failedAt,
      });

  static ExportStatus fromText(String? text) {
    if (text == null) return none;
    try {
      final json = jsonDecode(text);
      if (json is! Map) return none;
      final sentAt = json['sent_at'], sent = json['sent'], status = json['failed_status'], at = json['failed_at'];
      return ExportStatus(
        sentAt: sentAt is int ? sentAt : null,
        sent: sent is int ? sent : 0,
        failure: ExportFailure.values.where((f) => f.name == json['failure']).firstOrNull,
        failedStatus: status is int ? status : null,
        failedAt: at is int ? at : null,
      );
    } on FormatException {
      return none;
    }
  }
}

/// Where event export stands in one Orchard, as this device sees it.
class ExportStanding {
  const ExportStanding({
    required this.isOwner,
    required this.activityOn,
    this.record,
    this.sendsHere = false,
    this.destination,
    this.status = ExportStatus.none,
  });

  /// This account is an owner: it may set it up and turn it off.
  final bool isOwner;

  /// The team records activity: only then can events be sent on.
  final bool activityOn;

  /// On, as the record says: the key the events are signed with and the
  /// owner who set it up. Null while it is off.
  final RecordExport? record;

  /// This device holds the key the record names: it is the one that sends.
  final bool sendsHere;

  /// Where they go, and how it went: only on the device that sends.
  final ExportDestination? destination;
  final ExportStatus status;

  bool get on => record != null;
}

/// How far this device got: the record's entries up to [record] and the
/// activity up to the note [activity] went out, signed with [key].
class _Cursor {
  const _Cursor(this.key, this.record, this.activity);

  final String key;
  final int record;
  final int activity;

  String toText() => jsonEncode({'key': key, 'record': record, 'activity': activity});

  /// Read back from [toText], when it was kept for [key]; null otherwise.
  static _Cursor? fromText(String? text, String key) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map || json['key'] != key) return null;
      final record = json['record'], activity = json['activity'];
      return record is int && activity is int ? _Cursor(key, record, activity) : null;
    } on FormatException {
      return null;
    }
  }
}

class OrchardEventExporter {
  OrchardEventExporter({
    required OrchardService Function() service,
    required this.settings,
    required this.post,
    this.onChanged,
    DateTime Function()? now,
  })  : _service = service,
        _now = now ?? DateTime.now;

  /// The account's Orchards, asked for at each use. (The app's service asks
  /// this exporter for what it has left, [flush]: neither is made from the
  /// other.)
  OrchardService get service => _service();
  final OrchardService Function() _service;
  final ExportSettingsStore settings;
  final ExportPost post;

  /// Called when what [standing] says may have changed.
  final void Function()? onChanged;
  final DateTime Function() _now;

  /// Where an Orchard's database keeps how far this device got, and how it
  /// went.
  static const sentKey = 'export.sent';
  static const statusKey = 'export.status';

  /// The most requests one round makes: what is left goes with the next.
  static const maxRequests = 10;

  /// What secure storage holds for each account, as far as this run looked.
  /// Everything there is written through here, so one look is enough: the
  /// round that runs every minute asks the system's storage nothing.
  final _sending = <String, Set<String>>{};
  final _kept = <String, ExportSettings?>{};
  final _noted = <String, String?>{};

  /// The round that runs for each Orchard, while one does.
  final _running = <String, Future<void>>{};

  static final AppLocalizations _english = lookupAppLocalizations(const Locale('en'));

  int get _nowSeconds => _now().millisecondsSinceEpoch ~/ 1000;

  /// The Orchards this device keeps settings for, for the account [uid].
  Future<Set<String>> _orchards(String uid) async => _sending[uid] ??= await settings.orchards(uid);

  Future<ExportSettings?> _settings(String uid, String orchardId) async {
    final k = '$uid|$orchardId';
    if (_kept.containsKey(k)) return _kept[k];
    return _kept[k] = (await _orchards(uid)).contains(orchardId) ? await settings.read(uid, orchardId) : null;
  }

  Future<void> _keep(String uid, String orchardId, ExportSettings s) async {
    await settings.write(uid, orchardId, s);
    (await _orchards(uid)).add(orchardId);
    _kept['$uid|$orchardId'] = s;
  }

  /// This device sends nothing more for [orchardId]: the key and the
  /// address go, and the note of how far it got.
  Future<void> _forget(String uid, String orchardId) async {
    await settings.forget(uid, orchardId);
    (await _orchards(uid)).remove(orchardId);
    _kept['$uid|$orchardId'] = null;
    _noted['$uid|$orchardId'] = null;
  }

  /// How far this device noted it got with [orchardId], as it wrote it.
  Future<String?> _notedText(String uid, String orchardId) async {
    final k = '$uid|$orchardId';
    if (_noted.containsKey(k)) return _noted[k];
    return _noted[k] = await settings.readSent(uid, orchardId);
  }

  /// Notes beside the key how far this device got, when that moved. The
  /// Orchard's database keeps it after every request; this note is for
  /// when that database went and came back (the device was taken out of
  /// the Orchard for a while, or its data was cleared): it then goes on
  /// from here, and does not say everything again. Where the note cannot
  /// be written nothing is lost.
  Future<void> _note(String uid, String orchardId, _Cursor cursor) async {
    final k = '$uid|$orchardId';
    final text = cursor.toText();
    if (_noted[k] == text) return;
    try {
      await settings.writeSent(uid, orchardId, text);
      _noted[k] = text;
    } catch (e) {
      AppLogger.info('Event export: how far it got was not noted (${errorKind(e)})');
    }
  }

  /// A new signing key for an Orchard's events. Its public half goes into
  /// the record when sending is turned on ([setUp]); a test event before
  /// that is signed with it too.
  Future<DeviceIdentity> newKey() => DeviceIdentity.generate();

  /// Where event export stands in [orchardId], from this device's copy of
  /// the record and what it keeps. Offline too.
  Future<ExportStanding> standing(String orchardId) async {
    final me = await service.currentAuthor();
    final db = await service.databases.open(orchardId);
    final latest = (await LocalRecord.load(db, orchardId)).latest;
    final record = latest.eventExport;
    final kept = me == null ? null : await _settings(me.uid, orchardId);
    final here = kept != null && await _sends(record, me!.uid, kept);
    return ExportStanding(
      isOwner: me != null && latest.isOwner(me.uid),
      activityOn: latest.tracking.activity,
      record: record,
      sendsHere: here,
      destination: here ? kept.destination : null,
      status: here ? ExportStatus.fromText(await LocalStateStore(db).read(statusKey)) : ExportStatus.none,
    );
  }

  /// Whether the device that keeps [kept] for the account [uid] is the one
  /// [record] has send: it is on, set up by that account, with that key.
  static Future<bool> _sends(RecordExport? record, String uid, ExportSettings kept) async =>
      record != null && record.by == uid && record.keyText == (await DeviceIdentity.fromSeed(kept.seed)).key;

  /// Turns sending on for [orchardId], from this device, to [to], with
  /// events signed by [key]: the record takes the key's public half (the
  /// change needs a recent sign-in), and this device keeps the rest. What
  /// members did before now is not sent from here (where another device
  /// sent until now, that one says it). A first round follows at once.
  Future<void> setUp(String orchardId, ExportDestination to, DeviceIdentity key) async {
    final me = await service.currentAuthor() ?? (throw const AccountKeysNotReady());
    final newest = await service.server.activity(orchardId);
    final from = newest.events.isEmpty ? 0 : newest.events.first.id;
    await service.change(orchardId, RecordTypes.exportSet, {'on': true, 'key': key.key});
    // (How it went with a key this device sent with before is not how it
    // goes with this one. How far it got is kept with its key, and is of no
    // use to another.)
    await LocalStateStore(await service.databases.open(orchardId)).remove(statusKey);
    await _keep(me.uid, orchardId, ExportSettings(seed: key.seed, destination: to, activityFrom: from));
    await round(orchardId);
  }

  /// Sends to [to] from now on. Only on the device that sends; the record
  /// does not change (it never held the address).
  Future<void> changeDestination(String orchardId, ExportDestination to) async {
    final me = await service.currentAuthor() ?? (throw const AccountKeysNotReady());
    final kept = await _settings(me.uid, orchardId);
    if (kept == null) throw StateError('This device does not send the events of that Orchard');
    await _keep(me.uid, orchardId, ExportSettings(seed: kept.seed, destination: to, activityFrom: kept.activityFrom));
    onChanged?.call();
    await round(orchardId);
  }

  /// Turns sending off for [orchardId] (owners; the change needs a recent
  /// sign-in). The device that sent sends the entry that says so as its
  /// last event, then forgets the key and the address. Where that device
  /// is this one, what it had not sent yet goes before the entry does (the
  /// service asks for it: [flush]).
  Future<void> turnOff(String orchardId) async {
    await service.change(orchardId, RecordTypes.exportSet, {'on': false});
    onChanged?.call();
    await round(orchardId);
  }

  /// Sends one event that says nothing happened to [to], signed with
  /// [key], and says what came of it. Changes nothing.
  Future<ExportDelivery> sendTest(String orchardId, ExportDestination to, DeviceIdentity key) async {
    final me = await service.currentAuthor() ?? (throw const AccountKeysNotReady());
    final names = await _names(await service.databases.open(orchardId), orchardId);
    final event = await signExportEvent(
      exportTestEvent(
        orchardId: orchardId,
        names: names,
        uid: me.uid,
        now: _now(),
        message: 'Test event from ZestSSH: nothing happened.',
      ),
      publicKey: key.publicKey,
      sign: key.sign,
    );
    return post(to, exportBody([event], to.format));
  }

  /// The key this device signs [orchardId]'s events with, when it is the
  /// one that sends: for a test event after sending was set up.
  Future<DeviceIdentity?> keyHere(String orchardId) async {
    final me = await service.currentAuthor();
    final kept = me == null ? null : await _settings(me.uid, orchardId);
    return kept == null ? null : DeviceIdentity.fromSeed(kept.seed);
  }

  /// A round for every Orchard this device sends for. Where ZestSSH Cloud
  /// no longer lists an Orchard for this account (it left, or was removed)
  /// and it is gone from this device, what was kept for it goes. Where an
  /// Orchard is only not on this device just now (its copy was dropped, and
  /// the next sync brings it back) it waits: a device does not stop sending
  /// on its own. Never throws.
  Future<void> rounds() async {
    try {
      final me = await service.currentAuthor();
      if (me == null) return;
      final mine = await _orchards(me.uid);
      if (mine.isEmpty) return;
      final here = (await service.databases.onDevice()).toSet();
      final listed = service.listedFor(me.uid);
      for (final orchardId in mine.toList()) {
        if (here.contains(orchardId)) {
          await round(orchardId);
        } else if (listed != null && !listed.contains(orchardId)) {
          await _forget(me.uid, orchardId);
          onChanged?.call();
        }
      }
    } catch (e) {
      AppLogger.info('Event export: the rounds did not finish (${errorKind(e)})');
    }
  }

  /// Sends what [orchardId] has that this device has not sent yet, when it
  /// is the one that sends. One at a time for each Orchard: asked while one
  /// runs, it is that one. Never throws.
  Future<void> round(String orchardId) => _running[orchardId] ??= _guarded(orchardId).whenComplete(() {
        // (Not returned: what is taken out is this very round.)
        _running.remove(orchardId);
      });

  /// A round that starts now: after the one that runs, when one does.
  /// Before a change made on this device ends its sending, and before an
  /// Orchard this account leaves goes from the device.
  Future<void> flush(String orchardId) async {
    await _running[orchardId];
    await round(orchardId);
  }

  Future<void> _guarded(String orchardId) async {
    try {
      if (await _round(orchardId)) onChanged?.call();
    } on OrchardClosedOffline {
      // Closed until this device is online again: it waits.
    } catch (e) {
      AppLogger.info('Event export: a round did not finish (${errorKind(e)})');
    }
  }

  /// True when what [standing] says may have changed.
  Future<bool> _round(String orchardId) async {
    final me = await service.currentAuthor();
    if (me == null) return false;
    final kept = await _settings(me.uid, orchardId);
    if (kept == null) return false;
    final db = await service.databases.open(orchardId);
    final store = LocalStateStore(db);
    final record = await LocalRecord.load(db, orchardId);
    final key = await DeviceIdentity.fromSeed(kept.seed);
    // The record here does not name this key (yet, or any more: a device
    // that was taken out of the Orchard holds nothing of it): nothing to
    // send, and nothing to conclude.
    final start = _turnedOnAt(record, me.uid, key.key);
    if (start == null) return false;
    // While this device sends: every entry. Once it does not: up to the
    // entry that ended it.
    final ended = await _sends(record.latest.eventExport, me.uid, kept)
        ? null
        : await _endedAt(record, start, me.uid, key.key);
    final end = ended?.last ?? record.seq;
    // How far it got: what the Orchard's database says and what this device
    // noted beside the key, whichever is further. At the least: just before
    // the entry that turned sending on, and the last note of activity there
    // was then.
    final inDatabase = _Cursor.fromText(await store.read(sentKey), key.key);
    final noted = _Cursor.fromText(await _notedText(me.uid, orchardId), key.key);
    var cursor = _Cursor(
      key.key,
      [start - 1, inDatabase?.record ?? 0, noted?.record ?? 0].reduce(math.max),
      [kept.activityFrom, inDatabase?.activity ?? 0, noted?.activity ?? 0].reduce(math.max),
    );
    var requests = 0;
    var changed = false;
    // A request the receiver did not take (not: the round made its requests).
    var refused = false;
    ExportNames? known;
    Future<ExportNames> names() async => known ??= await _names(db, orchardId);

    /// Signs [events] and sends them, [kExportBatchMax] to a request; after
    /// each that went, this device is as far as [reached] says for its
    /// last event. False once one did not go, or the round has made its
    /// requests.
    Future<bool> send(List<Map<String, Object?>> events, _Cursor Function(int index) reached) async {
      for (var i = 0; i < events.length; i += kExportBatchMax) {
        if (requests++ >= maxRequests) return false;
        final last = math.min(i + kExportBatchMax, events.length);
        final signed = [
          for (final e in events.sublist(i, last)) await signExportEvent(e, publicKey: key.publicKey, sign: key.sign),
        ];
        final delivery = await post(kept.destination, exportBody(signed, kept.destination.format));
        final status = ExportStatus.fromText(await store.read(statusKey));
        changed = true;
        if (!delivery.ok) {
          await store.write(
            statusKey,
            ExportStatus(
              sentAt: status.sentAt,
              sent: status.sent,
              failure: delivery.failure,
              failedStatus: delivery.status,
              failedAt: _nowSeconds,
            ).toText(),
          );
          refused = true;
          return false;
        }
        cursor = reached(last - 1);
        await store.write(sentKey, cursor.toText());
        await store.write(statusKey, ExportStatus(sentAt: _nowSeconds, sent: status.sent + (last - i)).toText());
      }
      return true;
    }

    var went = true;
    if (cursor.record < end) {
      final first = cursor.record + 1;
      final events = <Map<String, Object?>>[];
      for (var seq = first; seq <= end; seq++) {
        final entry = record.entries[seq - 1];
        // (Never the record's first entry: sending starts with the entry
        // that turned it on.)
        final change = describeRecordEntry(entry, await record.stateAt(seq - 1));
        final seen = record.firstSeen[seq - 1];
        events.add(exportRecordEvent(
          orchardId: orchardId,
          names: await names(),
          entry: entry,
          change: change,
          seen: seen == null ? null : DateTime.fromMillisecondsSinceEpoch(seen * 1000),
          sent: _now(),
          message: _changeWords(change, entry.by, await names()),
          unwatched: entry.type == RecordTypes.sessionUnwatched
              ? await service.unwatchedSessionOf(orchardId, entry)
              : null,
        ));
      }
      final notes = cursor.activity;
      went = await send(events, (i) => _Cursor(key.key, first + i, notes));
    }

    /// What members did after the last note this device sent, a page at a
    /// time. True when all there is went; false once a request was not
    /// taken, or the round has made its requests.
    Future<bool> sendActivity() async {
      while (true) {
        final page = await service.teamActivityAfter(orchardId, cursor.activity);
        if (page.rows.isEmpty) return true;
        final named = await names();
        final sentSeq = cursor.record;
        // (As far as the highest note sent: a page that came out of order
        // sends none of them twice.)
        var highest = cursor.activity;
        final reached = [for (final row in page.rows) highest = math.max(highest, row.id)];
        final all = await send(
          [for (final row in page.rows) _activityEvent(orchardId, named, row)],
          (i) => _Cursor(key.key, sentSeq, reached[i]),
        );
        if (!all) return false;
        if (!page.more) return true;
      }
    }

    if (ended != null) {
      // Over. This device says what it has left: the record's entries above
      // and, where its sending was handed on, what members did until now.
      var done = went;
      if (went && ended.handedOn) {
        try {
          done = await sendActivity();
        } catch (e) {
          // Refused: this account may not read the activity any more, and
          // there is nothing more to say. Not reached just now: the next
          // round asks again.
          done = e is OrchardServerException && _mayNotRead.contains(e.status);
          AppLogger.info('Event export: the activity was not read (${errorKind(e)})');
        }
      }
      // All said, or the receiver did not take it: either way this device
      // is through, and keeps neither the key nor the address. (A round
      // that only made its requests goes on with the next.)
      if (done || refused) {
        await _forget(me.uid, orchardId);
        await store.remove(sentKey);
        await store.remove(statusKey);
        return true;
      }
      await _note(me.uid, orchardId, cursor);
      return changed;
    }
    if (went) {
      try {
        await sendActivity();
      } catch (e) {
        // ZestSSH Cloud did not hand the activity over (offline, most
        // often): the next round asks again. Nothing about the receiver.
        AppLogger.info('Event export: the activity was not read (${errorKind(e)})');
      }
    }
    await _note(me.uid, orchardId, cursor);
    return changed;
  }

  /// What ZestSSH Cloud answers an account that may not read an Orchard's
  /// activity: no owner, not in the Orchard, or none is recorded.
  static const _mayNotRead = {403, 404, 409};

  /// The entry with which [uid] last turned sending on with [key], by its
  /// number; null when the record here has none.
  static int? _turnedOnAt(LocalRecord record, String uid, String key) {
    for (final e in record.entries.reversed) {
      // (An entry that turns it off carries no key.)
      if (e.type == RecordTypes.exportSet && e.by == uid && e.body['key'] == key) return e.seq;
    }
    return null;
  }

  /// Where the sending of the device of [uid] with [key] (turned on at
  /// [start], and over as the record stands) ended. [last] is the last entry
  /// it says: the one that ended its sending, or the one before it when
  /// that entry hands sending to another device, which says it. [handedOn]
  /// when it was handed on and events have been sent on ever since: what
  /// members did until now is then still this device's to say. After a time
  /// with sending off it is not: nothing tells what they did before it from
  /// what they did during it.
  static Future<({int last, bool handedOn})> _endedAt(LocalRecord record, int start, String uid, String key) async {
    var seq = start;
    RecordExport? after;
    do {
      after = (await record.stateAt(++seq)).eventExport;
    } while (after?.keyText == key && after?.by == uid);
    if (after == null) return (last: seq, handedOn: false);
    for (var s = seq + 1; s <= record.seq; s++) {
      if ((await record.stateAt(s)).eventExport == null) return (last: seq - 1, handedOn: false);
    }
    return (last: seq - 1, handedOn: true);
  }

  /// The names this device has for what [orchardId]'s events are about.
  Future<ExportNames> _names(AppDatabase db, String orchardId) async {
    final info = await db.customSelect('SELECT name FROM orchard_info WHERE id = 1').getSingleOrNull();
    return ExportNames(
      orchard: info?.read<String?>('name'),
      emails: {
        for (final r in await db.customSelect('SELECT uid, email FROM member_keys').get())
          r.read<String>('uid'): r.read<String?>('email'),
      },
      crates: {
        for (final r in await db.customSelect('SELECT crate_id, name FROM orchard_crates').get())
          r.read<String>('crate_id'): r.read<String?>('name'),
      },
      roles: {for (final r in await service.roles(orchardId)) r.id: r.name},
    );
  }

  static String _who(String uid, ExportNames names) => names.person(uid)['email'] as String? ?? uid;

  /// [change], made by [by], in an English sentence: the Team page's words.
  static String _changeWords(TeamChange change, String by, ExportNames names) {
    final text = teamChangeText(
      change,
      _english,
      nameOf: (uid) => uid == null ? '' : _who(uid, names),
      crateName: (id) => (id == null ? null : names.crate(id)['name'] as String?) ?? _english.crateUnnamed,
      roleName: (id) => names.role(id)['name'] as String? ?? _english.orchardRoleMember,
    );
    return '${_who(by, names)}: $text';
  }

  static Map<String, Object?> _activityEvent(String orchardId, ExportNames names, TeamActivityRow row) {
    final event = row.event;
    if (event == null) {
      return exportUnreadableEvent(
        orchardId: orchardId,
        names: names,
        id: row.id,
        uid: row.uid,
        received: row.receivedAt,
        message: 'A note of activity from ${_who(row.uid, names)} could not be read.',
      );
    }
    // (A name of nothing but spaces is none, as for a Crate or an Orchard.)
    final name = event.name == null || event.name!.trim().isEmpty ? null : event.name;
    return exportActivityEvent(
      orchardId: orchardId,
      names: names,
      id: row.id,
      uid: event.uid,
      action: event.kind.name,
      at: event.at,
      received: row.receivedAt,
      crateId: event.crateId,
      itemKind: event.itemKind,
      itemKey: event.itemKey,
      itemName: name,
      message: teamActivityText(
        event.kind,
        _english,
        who: _who(event.uid, names),
        item: name ?? _english.crateItemUnnamed,
      ),
    );
  }
}
