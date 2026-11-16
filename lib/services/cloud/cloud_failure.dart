import 'dart:async';

import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';

/// What stopped something that needed ZestSSH Cloud, when it was the
/// service or the way to it (3.0).
///
/// The app said "couldn't be reached, check your connection" for all of
/// these, in a dozen wordings, and "Something went wrong" with the name of
/// a class for a fault of the server's. Four situations hid behind that,
/// each with a different thing to do, and three of them are not the
/// person's to fix at all. Each has its words and its code now, and they
/// are made here, so that every screen that needs the service says the same
/// thing about the same situation.
///
/// Where the app could ask the status service, "not responding" has become
/// one of three ([down], [blockedHere], [nothingReached]): see
/// lib/services/cloud/cloud_reach.dart.
enum CloudFailureKind {
  /// The device has no network.
  deviceOffline,

  /// The device has a network and the service gave no answer.
  notResponding,

  /// Something answered at the service's address that could not be
  /// verified to be the service.
  notSecure,

  /// The service, or the network in front of it, answered with a fault of
  /// its own (HTTP 500 to 599).
  fault,

  /// The service is down: its status service says so, signed.
  down,

  /// The service is up, and this device cannot reach it from the network it
  /// is on.
  blockedHere,

  /// The device has a network and reached neither the service nor its
  /// status service: most likely no internet.
  nothingReached,
}

class CloudFailure {
  const CloudFailure(this.kind, {this.status, this.detail});

  final CloudFailureKind kind;

  /// The HTTP status of a [CloudFailureKind.fault].
  final int? status;

  /// What was caught, for whoever copies the details. Never the message.
  final String? detail;

  /// Whether what is in the way is on this device's side (its network, a
  /// connection it cannot make secure), and so not the service failing.
  bool get onThisSide => switch (kind) {
        CloudFailureKind.deviceOffline ||
        CloudFailureKind.nothingReached ||
        CloudFailureKind.blockedHere ||
        CloudFailureKind.notSecure =>
          true,
        CloudFailureKind.notResponding || CloudFailureKind.fault || CloudFailureKind.down => false,
      };

  ErrorCode get code => switch (kind) {
        CloudFailureKind.deviceOffline => ErrorCodes.deviceOffline,
        CloudFailureKind.notResponding => ErrorCodes.cloudNotResponding,
        CloudFailureKind.notSecure => ErrorCodes.cloudNotSecure,
        CloudFailureKind.fault => ErrorCodes.cloudFault,
        CloudFailureKind.down => ErrorCodes.cloudDown,
        CloudFailureKind.blockedHere => ErrorCodes.cloudBlockedHere,
        CloudFailureKind.nothingReached => ErrorCodes.cloudNothingReached,
      };

  /// What the person is told, ending in the code.
  String message(AppLocalizations l10n) => ErrorCodes.withCode(
        switch (kind) {
          CloudFailureKind.deviceOffline => l10n.cloudDeviceOffline,
          CloudFailureKind.notResponding => l10n.cloudNotResponding,
          CloudFailureKind.notSecure => l10n.cloudNotSecure,
          CloudFailureKind.fault => l10n.cloudFault(status ?? 500),
          CloudFailureKind.down => l10n.cloudDown,
          CloudFailureKind.blockedHere => l10n.cloudBlockedHere,
          CloudFailureKind.nothingReached => l10n.cloudNothingReached,
        },
        code,
      );

  /// The situation in a few words, as the status bar's chip says it.
  String label(AppLocalizations l10n) => switch (kind) {
        CloudFailureKind.deviceOffline => l10n.cloudChipOffline,
        CloudFailureKind.notResponding => l10n.cloudChipNotResponding,
        CloudFailureKind.notSecure => l10n.cloudChipNotSecure,
        CloudFailureKind.fault => l10n.cloudChipFault,
        CloudFailureKind.down => l10n.cloudChipDown,
        CloudFailureKind.blockedHere => l10n.cloudChipBlocked,
        CloudFailureKind.nothingReached => l10n.cloudChipNoInternet,
      };

  @override
  String toString() => 'CloudFailure($kind${status == null ? '' : ' $status'})';
}

/// [error] as a failure of ZestSSH Cloud or of the way to it, or null when
/// it is neither: the service answered, and what it said is for whoever
/// asked to explain.
///
/// [status] is the HTTP status the caller knows the service answered with,
/// where it knows; without it, a status written in the error's own text
/// ("... HTTP 503") is taken. [deviceOnline] is whether the device has a
/// network, as the system says; left out, the app's own knowledge of it is
/// used ([currentCloudReach]), and where nothing is known the device is
/// taken to have one, since a device that is offline is at least as likely
/// to know it.
///
/// One failed request says little: "no answer". Where the app has meanwhile
/// found out more about the service (it asked the status service), that is
/// what is said: down, blocked on this network, or nothing reached.
CloudFailure? cloudFailureOf(Object error, {int? status, bool? deviceOnline}) {
  final detail = '$error';
  final found = currentCloudReach?.state.value.reach;
  if (isNoAnswer(error)) {
    if (isNotSecure(error)) return CloudFailure(CloudFailureKind.notSecure, detail: detail);
    final online = deviceOnline ?? currentCloudReach?.deviceHasNetwork;
    if (online == false) return CloudFailure(CloudFailureKind.deviceOffline, detail: detail);
    return CloudFailure(
      switch (found) {
        CloudReach.down => CloudFailureKind.down,
        CloudReach.blocked => CloudFailureKind.blockedHere,
        CloudReach.nothingReached => CloudFailureKind.nothingReached,
        _ => CloudFailureKind.notResponding,
      },
      detail: detail,
    );
  }
  final answered = status ?? _statusIn(detail);
  if (answered != null && answered >= 500 && answered <= 599) {
    return CloudFailure(
      found == CloudReach.down ? CloudFailureKind.down : CloudFailureKind.fault,
      status: answered,
      detail: detail,
    );
  }
  return null;
}

/// What a screen says where something it asked of ZestSSH Cloud did not
/// happen because of the service or the way to it ([error], with the HTTP
/// [status] where the screen knows it): how the service stands, with its
/// code, after [lead] where the screen has a sentence for what did not
/// happen ("Nothing was deleted."). Null where [error] is no such failure:
/// the service answered, and the screen says what it always said.
String? cloudStopped(AppLocalizations l10n, Object error, {String? lead, int? status}) {
  final failure = cloudFailureOf(error, status: status);
  if (failure == null) return null;
  final said = failure.message(l10n);
  return lead == null ? said : '$lead $said';
}

/// Nothing answered something that asked ZestSSH Cloud, and what was caught
/// is not at hand: which failure that is as far as the app knows now (the
/// device offline, the service down, this network in the way, nothing of
/// ZestSSH's reached), and "not responding" where it knows no more.
CloudFailure cloudNoAnswerNow({bool? deviceOnline}) =>
    cloudFailureOf(TimeoutException('no answer'), deviceOnline: deviceOnline)!;

/// How the service stands ([state]) as a failure someone can be told of;
/// null while nothing is in the way.
CloudFailure? cloudFailureOfReach(CloudReachState state) {
  final kind = switch (state.reach) {
    CloudReach.unknown || CloudReach.answering => null,
    CloudReach.deviceOffline => CloudFailureKind.deviceOffline,
    CloudReach.notResponding => CloudFailureKind.notResponding,
    CloudReach.fault => CloudFailureKind.fault,
    CloudReach.notSecure => CloudFailureKind.notSecure,
    CloudReach.down => CloudFailureKind.down,
    CloudReach.blocked => CloudFailureKind.blockedHere,
    CloudReach.nothingReached => CloudFailureKind.nothingReached,
  };
  return kind == null ? null : CloudFailure(kind, status: state.status, detail: state.detail);
}

final _httpStatus = RegExp(r'\bHTTP ([0-9]{3})\b');

int? _statusIn(String text) {
  final found = _httpStatus.firstMatch(text);
  return found == null ? null : int.parse(found.group(1)!);
}
