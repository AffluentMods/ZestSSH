import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/utils/logger.dart';

/// How ZestSSH Cloud stands from this device (3.0).
///
/// The app works without the service: hosts, saved logins, keys, sessions
/// and what a team's device already holds need nothing from it. But what
/// goes through it (sync to it, changes to a team, new certificates, live
/// sharing) waits while it cannot be reached, and whoever is told that
/// something waits has to be told WHY, in one of three ways that call for
/// three different things from them: this device is offline (theirs to
/// fix), the service is not responding (ours, nothing to do but wait), or
/// it answers with a fault (ours, and worth reporting if it lasts). Until
/// this was held every part of the app said its own "couldn't be reached"
/// or "something went wrong", and none could tell the three apart.
///
/// "Not responding" is all one device can know by itself. With the status
/// service (lib/services/cloud/cloud_statement.dart), which looks from
/// somewhere else and is asked only when the service gave no answer, it
/// becomes one of three: the service is down ([down], proven), it is up and
/// this network does not let the device reach it ([blocked]), or the device
/// reaches nothing of ZestSSH's at all ([nothingReached]).
enum CloudReach {
  /// Nothing was asked of the service yet in this run, or nothing on this
  /// device uses it. Nothing is said to anyone.
  unknown,

  /// It answered what was last asked of it.
  answering,

  /// The device has no network at all.
  deviceOffline,

  /// The device has a network, and the service gives no answer.
  notResponding,

  /// The service, or the network in front of it, answers with a fault of
  /// its own (an HTTP status from 500 on).
  fault,

  /// Something answered at the service's address that could not be verified
  /// to be the service (a certificate that does not check out).
  notSecure,

  /// The service is down: its status service says so, signed. Nothing is
  /// wrong on this side.
  down,

  /// The service is up, says its status service, and this device cannot
  /// reach it from the network it is on.
  blocked,

  /// The system says the device has a network, and neither the service nor
  /// its status service could be reached: most likely no internet.
  nothingReached,
}

@immutable
class CloudReachState {
  const CloudReachState(this.reach, {this.since, this.status, this.detail, this.outageSince});

  const CloudReachState.unknown() : this(CloudReach.unknown);

  final CloudReach reach;

  /// Since when the service has not been answering; null while it is, and
  /// while nothing is known.
  final DateTime? since;

  /// The HTTP status of a [CloudReach.fault].
  final int? status;

  /// What was caught, or what was answered, for whoever copies the details
  /// of a message. Never shown as the message.
  final String? detail;

  /// For [CloudReach.down]: since when the service has been down, as its
  /// status service says (which may be long before this device noticed).
  final DateTime? outageSince;

  /// Whether what goes through the service waits.
  bool get inTheWay => reach != CloudReach.unknown && reach != CloudReach.answering;

  @override
  bool operator ==(Object other) =>
      other is CloudReachState &&
      other.reach == reach &&
      other.since == since &&
      other.status == status &&
      other.detail == detail &&
      other.outageSince == outageSince;

  @override
  int get hashCode => Object.hash(reach, since, status, detail, outageSince);

  @override
  String toString() => 'CloudReachState($reach${status == null ? '' : ' $status'}${since == null ? '' : ' since $since'})';
}

/// Keeps [state] true to what the app finds out as it goes: every exchange
/// with the service is told to it ([heard], [noAnswer]), and so is every
/// change of the device's network ([networkChanged]).
///
/// One failure is not an outage. When something fails, the service is asked
/// how it is (the health check, which asks nothing about anyone) and that
/// answer decides; while it does not answer, it is asked again, later each
/// time ([checkWaits]), and at once when the device's network comes back.
/// The moment it answers again, whoever asked to be told ([addBackListener])
/// is: that is when sync, the teams and whatever else waited catch up,
/// without anybody pressing anything.
///
/// Nothing is asked while all is well, and nothing at all on a device that
/// never uses the service: the first thing told to this service is the
/// app's own first exchange with it.
class CloudReachService {
  CloudReachService({
    required Future<int> Function() check,
    Future<CloudStatement?> Function()? status,
    DateTime Function()? clock,
    Timer Function(Duration wait, void Function() then)? timer,
  })  : _check = check,
        _status = status,
        _clock = clock ?? DateTime.now,
        _timer = timer ?? Timer.new;

  /// How long to wait before the service is asked again how it is, while it
  /// does not answer. The last wait goes for every time after it.
  static const checkWaits = <Duration>[
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];

  /// Asks the service how it is: the HTTP status of its health check, or a
  /// failure when nothing answered.
  final Future<int> Function() _check;

  /// Asks the status service how the service stands: its statement, signed
  /// and believed, or null when it gave none. Null itself where no status
  /// service is set up: then this device says what it can know alone.
  final Future<CloudStatement?> Function()? _status;

  /// Whether the device has a network, as the system last said
  /// ([networkChanged]); null while it has said nothing, or cannot say (the
  /// service not answering is then said as that: a device that is offline
  /// is at least as likely to know it).
  bool? _networkUp;

  /// Whether the device has a network, as the system last said; null while
  /// it has said nothing.
  bool? get deviceHasNetwork => _networkUp;
  final DateTime Function() _clock;
  final Timer Function(Duration wait, void Function() then) _timer;

  final ValueNotifier<CloudReachState> state = ValueNotifier(const CloudReachState.unknown());

  final _backListeners = <VoidCallback>[];
  final _outageListeners = <void Function(CloudStatement proof)>[];
  Future<CloudReachState>? _checking;
  Timer? _next;
  int _checksFailed = 0;
  bool _disposed = false;

  /// [listener] is called each time the service answers again after it did
  /// not (or after the device was offline).
  void addBackListener(VoidCallback listener) => _backListeners.add(listener);

  void removeBackListener(VoidCallback listener) => _backListeners.remove(listener);

  /// [listener] is given every statement of the status service that says,
  /// signed and believed, that the service is down: proof of an outage, for
  /// whatever must not count that time against this device (an Orchard's
  /// offline limit).
  void addOutageListener(void Function(CloudStatement proof) listener) => _outageListeners.add(listener);

  void removeOutageListener(void Function(CloudStatement proof) listener) => _outageListeners.remove(listener);

  /// Whether anybody is listening for proven outages (for a test of who
  /// stops listening when).
  @visibleForTesting
  bool get hasOutageListeners => _outageListeners.isNotEmpty;

  /// Something was asked of the service and it answered with [status].
  /// Anything below 500 is an answer, whatever it says: that is between the
  /// service and whoever asked. From 500 on it may be a fault of the whole
  /// service or of the one thing asked, so the service is asked how it is.
  void heard(int status) {
    if (_disposed) return;
    if (status < 500) {
      _answering();
    } else {
      unawaited(_ask(why: 'HTTP $status'));
    }
  }

  /// Something asked of the service got no answer: no connection, no answer
  /// in time, a connection that broke or could not be made secure.
  void noAnswer(Object error) {
    if (_disposed) return;
    unawaited(_ask(why: '$error'));
  }

  /// How an exchange with the service went, as the client every request
  /// goes through tells it: the status that came back, or what was thrown.
  void hear(int? status, Object? error) {
    if (status != null) {
      heard(status);
    } else if (error != null) {
      noAnswer(error);
    }
  }

  /// The device's network changed: there is one now ([up]), or none. With
  /// none the device is offline, and nothing needs asking; with one again,
  /// the service is asked at once instead of at the end of a wait. While
  /// nothing here has used the service, a network change says nothing.
  void networkChanged({required bool up}) {
    if (_disposed) return;
    _networkUp = up;
    if (state.value.reach == CloudReach.unknown) return;
    if (!up) {
      _dropNext();
      _set(CloudReach.deviceOffline, detail: 'The system reports no network');
      return;
    }
    if (state.value.inTheWay) {
      _dropNext();
      unawaited(_ask(why: 'The network of the device changed'));
    }
  }

  /// Asks the service how it is, now; the state as it stands afterwards.
  /// Several callers at once share the one question.
  Future<CloudReachState> checkNow() => _ask(why: 'Asked for');

  /// The app is in front again (a phone's timers do not run while it is
  /// not): while the service was not answering, it is asked at once.
  void appResumed() {
    if (_disposed || !state.value.inTheWay) return;
    unawaited(_ask(why: 'The app came back to the front'));
  }

  /// Nothing on this device uses the service any more (signed out, sync to
  /// it turned off): nothing is known, nothing is asked, nothing is said.
  void forget() {
    if (_disposed) return;
    _dropNext();
    _checksFailed = 0;
    state.value = const CloudReachState.unknown();
  }

  Future<CloudReachState> _ask({required String why}) {
    final running = _checking;
    if (running != null) return running;
    final done = Completer<CloudReachState>();
    _checking = done.future;
    unawaited(() async {
      try {
        _dropNext();
        final int status;
        try {
          status = await _check();
        } catch (e) {
          if (_disposed) return;
          _checksFailed++;
          if (_networkUp == false) {
            _set(CloudReach.deviceOffline, detail: '$e', why: why);
          } else if (isNotSecure(e)) {
            // What answered could not be verified to be the service: that
            // is the whole of it, and nobody else needs asking.
            _set(CloudReach.notSecure, detail: '$e', why: why);
          } else {
            // The device has a network, as far as the system says, and the
            // service gave no answer. Seen from somewhere else it is one of
            // three things.
            final said = await _askStatus();
            if (_disposed) return;
            if (said == null) {
              _set(_status == null ? CloudReach.notResponding : CloudReach.nothingReached, detail: '$e', why: why);
            } else if (said.down) {
              _proven(said);
              _set(CloudReach.down, detail: '$e', outageSince: _when(said.since), why: why);
            } else {
              _set(CloudReach.blocked, detail: '$e', why: why);
            }
          }
          _scheduleNext();
          return;
        }
        if (_disposed) return;
        if (status < 500) {
          _answering();
        } else {
          _checksFailed++;
          // A fault may be the whole service or the one thing in front of
          // this device: the status service says which.
          final said = await _askStatus();
          if (_disposed) return;
          final detail = 'The health check answered HTTP $status';
          if (said != null && said.down) {
            _proven(said);
            _set(CloudReach.down, status: status, detail: detail, outageSince: _when(said.since), why: why);
          } else {
            _set(CloudReach.fault, status: status, detail: detail, why: why);
          }
          _scheduleNext();
        }
      } finally {
        _checking = null;
        done.complete(state.value);
      }
    }());
    return done.future;
  }

  void _answering() {
    final was = state.value;
    _dropNext();
    _checksFailed = 0;
    // (Said once: a state equal to the one that stands tells nobody.)
    state.value = const CloudReachState(CloudReach.answering);
    if (was.inTheWay) {
      AppLogger.info('ZestSSH Cloud answers again (it had not since ${was.since})');
      for (final listener in List.of(_backListeners)) {
        try {
          listener();
        } catch (e) {
          AppLogger.warning('Catching up after ZestSSH Cloud came back failed: $e');
        }
      }
    }
  }

  /// What the status service says, or null: when there is none, when it
  /// gave no statement, and when asking it failed in any way.
  Future<CloudStatement?> _askStatus() async {
    final ask = _status;
    if (ask == null) return null;
    try {
      return await ask();
    } catch (e) {
      AppLogger.warning('The status service could not be asked: $e');
      return null;
    }
  }

  /// A signed "down" is handed to whoever keeps count of proven outages.
  void _proven(CloudStatement proof) {
    for (final listener in List.of(_outageListeners)) {
      try {
        listener(proof);
      } catch (e) {
        AppLogger.warning('A proven outage could not be noted: $e');
      }
    }
  }

  static DateTime _when(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

  void _set(CloudReach reach, {int? status, String? detail, DateTime? outageSince, String? why}) {
    final was = state.value;
    // Since when: from the first moment it stopped answering, through
    // whatever shape the trouble takes after that.
    final since = was.inTheWay ? was.since : _clock();
    final next = CloudReachState(reach, since: since, status: status, detail: detail, outageSince: outageSince);
    if (next == was) return;
    if (!was.inTheWay) {
      // (What led to the question is for the log alone: in the state it
      // would make the same finding look like news at every check.)
      AppLogger.warning('ZestSSH Cloud: $reach${status == null ? '' : ' (HTTP $status)'}'
          '${why == null ? '' : ', asked after: $why'}');
    }
    state.value = next;
  }

  void _scheduleNext() {
    if (_disposed) return;
    final wait = checkWaits[(_checksFailed.clamp(1, checkWaits.length)) - 1];
    _next = _timer(wait, () {
      _next = null;
      unawaited(_ask(why: 'Checked again'));
    });
  }

  void _dropNext() {
    _next?.cancel();
    _next = null;
  }

  void dispose() {
    _disposed = true;
    _dropNext();
    _backListeners.clear();
    _outageListeners.clear();
    state.dispose();
  }
}

/// The app's own service, once it has one
/// (lib/providers/cloud_reach_provider.dart): what a message with no other
/// way to it asks how things stand. Null in tests, unless a test sets one.
CloudReachService? currentCloudReach;

/// Whether [error] is the kind a request fails with before anything
/// answers: no connection, no name, no answer in time, a connection that
/// broke or could not be made secure (a handshake that failed and a
/// certificate that was refused are both a [TlsException]).
bool isNoAnswer(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    error is TlsException ||
    error is HttpException ||
    error is WebSocketException ||
    // package:http wraps what dart:io throws. (Told by its type, never by
    // its name: a build made for release gives types other names.)
    error is http.ClientException;

/// Whether [error] says that a secure connection could not be made (a
/// certificate that cannot be verified): a clock that is wrong, or a
/// network that reads connections, far more often than anything else.
bool isNotSecure(Object error) {
  // By its kind where it arrives as it was thrown, whatever it says of
  // itself; by its words where package:http handed it on as its own.
  if (error is TlsException) return true;
  final text = '$error'.toLowerCase();
  return text.contains('handshakeexception') || text.contains('certificate_verify_failed') || text.contains('tlsexception');
}
