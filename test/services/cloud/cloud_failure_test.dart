import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';

/// What stopped something that needed ZestSSH Cloud is said as what it is
/// (3.0), so that every error makes plain what is happening
/// exactly.
///
/// The device offline, the service not responding, no secure connection, a
/// fault of the service's own: four situations the app called "couldn't be
/// reached, check your connection" or "Something went wrong", three of which
/// are not the person's to fix. Each has its own words and its own code.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const refused = SocketException('Connection refused');

  tearDown(() => currentCloudReach = null);

  group('which of the four it is', () {
    test('no answer, and the device has a network: the service is not responding', () {
      for (final error in <Object>[
        refused,
        TimeoutException('no answer', const Duration(seconds: 30)),
        http.ClientException('Connection reset by peer'),
        const HttpException('Connection closed before full header was received'),
        const SocketException('Failed host lookup: api.zestssh.com'),
      ]) {
        final failure = cloudFailureOf(error, deviceOnline: true)!;
        expect(failure.kind, CloudFailureKind.notResponding, reason: '$error');
        expect(failure.code, ErrorCodes.cloudNotResponding);
        expect(failure.detail, '$error', reason: 'what was caught is kept for the details');
      }
    });

    test('no answer, and the device has no network: the device is offline', () {
      final failure = cloudFailureOf(refused, deviceOnline: false)!;
      expect(failure.kind, CloudFailureKind.deviceOffline);
      expect(failure.code, ErrorCodes.deviceOffline);
    });

    test('no answer, and nothing known of the network: said as the service, not as the device', () {
      expect(cloudFailureOf(refused)!.kind, CloudFailureKind.notResponding);
    });

    test('where the app knows how the device\'s network stands, that is what counts', () {
      final reach = CloudReachService(check: () async => 200);
      addTearDown(reach.dispose);
      currentCloudReach = reach;
      reach.networkChanged(up: false);
      expect(cloudFailureOf(refused)!.kind, CloudFailureKind.deviceOffline);
      reach.networkChanged(up: true);
      expect(cloudFailureOf(refused)!.kind, CloudFailureKind.notResponding);
      // What the caller knows goes before what the app knows.
      expect(cloudFailureOf(refused, deviceOnline: false)!.kind, CloudFailureKind.deviceOffline);
    });

    test('a connection that could not be made secure is its own thing, network or none', () {
      for (final online in [true, false, null]) {
        final failure = cloudFailureOf(const HandshakeException('CERTIFICATE_VERIFY_FAILED'), deviceOnline: online)!;
        expect(failure.kind, CloudFailureKind.notSecure);
        expect(failure.code, ErrorCodes.cloudNotSecure);
      }
    });

    test('an answer from 500 on is a fault of the service, with its status', () {
      for (final status in [500, 502, 503, 504, 522, 530, 599]) {
        final failure = cloudFailureOf(OrchardServerException(status, 'oops'), status: status)!;
        expect(failure.kind, CloudFailureKind.fault, reason: 'HTTP $status');
        expect(failure.status, status);
        expect(failure.code, ErrorCodes.cloudFault);
      }
    });

    test('a status written in the error\'s own words is taken where the caller names none', () {
      expect(cloudFailureOf(StateError('Account keys: HTTP 503'))!.status, 503);
      expect(cloudFailureOf(Exception('Status check failed: Server error (HTTP 502)'))!.status, 502);
      // What the caller knows goes before what the text says.
      expect(cloudFailureOf(StateError('Account keys: HTTP 503'), status: 500)!.status, 500);
    });

    test('whatever the service answered below 500 is not the service failing: that is for whoever asked to explain', () {
      for (final status in [400, 401, 403, 404, 409, 426, 429, 499]) {
        expect(cloudFailureOf(OrchardServerException(status, 'no'), status: status), isNull, reason: 'HTTP $status');
      }
      expect(cloudFailureOf(StateError('Account keys: HTTP 404')), isNull);
      expect(cloudFailureOf(StateError('HTTP 600 is no status')), isNull);
      expect(cloudFailureOf(const FormatException('not JSON')), isNull);
      expect(cloudFailureOf(StateError('a fault of the app\'s own')), isNull);
    });
  });

  // One failed request says "no answer". Once the app has asked the status
  // service it knows more, and that is what a message then says.
  group('what the app has found out since counts for more than one failed request', () {
    const at = 1791474000;
    final downSince = const CloudStatement(down: true, at: at, until: at + 900, since: at - 3600, keyId: 'k1');
    final up = const CloudStatement(down: false, at: at, until: at + 900, since: 0, keyId: 'k1');

    /// The app's knowledge of the service after its health check met
    /// [health] and the status service said [said].
    Future<CloudReachService> found(Object health, CloudStatement? said, {bool? network}) async {
      final reach = CloudReachService(
        check: () async => health is int ? health : throw health,
        status: () async => said,
        timer: (wait, then) => Timer(const Duration(days: 1), () {}),
      );
      addTearDown(reach.dispose);
      currentCloudReach = reach;
      if (network != null) reach.networkChanged(up: network);
      await reach.checkNow();
      return reach;
    }

    test('proven down: a request that got no answer is said as that', () async {
      final reach = await found(refused, downSince);
      expect(reach.state.value.reach, CloudReach.down);
      final failure = cloudFailureOf(refused)!;
      expect(failure.kind, CloudFailureKind.down);
      expect(failure.code, ErrorCodes.cloudDown);
      expect(failure.message(en), '${en.cloudDown} (ZS-1105)');
      expect(failure.detail, '$refused');
    });

    test('up, and this network in the way: said as that', () async {
      await found(refused, up);
      final failure = cloudFailureOf(TimeoutException('no answer'))!;
      expect(failure.kind, CloudFailureKind.blockedHere);
      expect(failure.message(en), '${en.cloudBlockedHere} (ZS-1106)');
    });

    test('nothing of ZestSSH reached: said as that', () async {
      await found(refused, null);
      final failure = cloudFailureOf(refused)!;
      expect(failure.kind, CloudFailureKind.nothingReached);
      expect(failure.message(en), '${en.cloudNothingReached} (ZS-1107)');
    });

    test('proven down: a fault this request was answered with is the outage too, with its status kept', () async {
      await found(503, downSince);
      final failure = cloudFailureOf(StateError('Orchards: HTTP 502'))!;
      expect(failure.kind, CloudFailureKind.down);
      expect(failure.status, 502);
      // And where the service is up for all the status service knows, a fault is a fault.
      await found(503, up);
      expect(cloudFailureOf(StateError('Orchards: HTTP 502'))!.kind, CloudFailureKind.fault);
    });

    test('the device offline, or a connection that is not secure, is still said as that', () async {
      final reach = await found(refused, downSince);
      expect(cloudFailureOf(refused, deviceOnline: false)!.kind, CloudFailureKind.deviceOffline,
          reason: 'what the caller knows of the device comes first');
      expect(cloudFailureOf(const HandshakeException('CERTIFICATE_VERIFY_FAILED'))!.kind, CloudFailureKind.notSecure);
      reach.networkChanged(up: false);
      expect(cloudFailureOf(refused)!.kind, CloudFailureKind.deviceOffline);
    });

    test('an answer that is no fault of the service is still nobody\'s outage', () async {
      await found(refused, downSince);
      expect(cloudFailureOf(StateError('Orchards: HTTP 404')), isNull);
      expect(cloudFailureOf(const FormatException('not JSON')), isNull);
    });

    test('each state the app can be in is one thing to say, and all is well is none', () {
      CloudFailure? of(CloudReach reach, {int? status}) =>
          cloudFailureOfReach(CloudReachState(reach, status: status, detail: 'what was met'));
      expect(of(CloudReach.unknown), isNull);
      expect(of(CloudReach.answering), isNull);
      final kinds = {
        CloudReach.deviceOffline: CloudFailureKind.deviceOffline,
        CloudReach.notResponding: CloudFailureKind.notResponding,
        CloudReach.fault: CloudFailureKind.fault,
        CloudReach.notSecure: CloudFailureKind.notSecure,
        CloudReach.down: CloudFailureKind.down,
        CloudReach.blocked: CloudFailureKind.blockedHere,
        CloudReach.nothingReached: CloudFailureKind.nothingReached,
      };
      expect(kinds.keys.toSet(), CloudReach.values.toSet().difference({CloudReach.unknown, CloudReach.answering}),
          reason: 'every state that is in the way is here');
      kinds.forEach((reach, kind) {
        final failure = of(reach, status: 503)!;
        expect(failure.kind, kind, reason: '$reach');
        expect(failure.status, 503);
        expect(failure.detail, 'what was met');
      });
      expect(CloudFailureKind.values.map((k) => CloudFailure(k).code).toSet(), hasLength(CloudFailureKind.values.length),
          reason: 'and each has a code of its own');
    });
  });

  group('what the person is told', () {
    test('each of the three the status service tells apart, in its own words, ending in its code', () {
      expect(const CloudFailure(CloudFailureKind.down).message(en), '${en.cloudDown} (ZS-1105)');
      expect(const CloudFailure(CloudFailureKind.blockedHere).message(en), '${en.cloudBlockedHere} (ZS-1106)');
      expect(const CloudFailure(CloudFailureKind.nothingReached).message(en), '${en.cloudNothingReached} (ZS-1107)');
      expect(en.cloudDown, contains('Nothing is wrong on your side'));
      expect(en.cloudDown, contains('not affected'));
      expect(en.cloudBlockedHere, contains('keeps working'));
      expect(en.cloudNothingReached, contains('keep working'));
      expect(en.cloudDown.toLowerCase(), isNot(contains('check your connection')));
    });

    test('every language has its own words for the three, and for an Orchard closed while the service is away', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        final texts = [l.cloudDown, l.cloudBlockedHere, l.cloudNothingReached, l.orchardClosedOfflineCloud];
        expect(texts.toSet(), hasLength(4), reason: '$locale');
        for (final text in texts) {
          expect(text, contains('ZestSSH Cloud'), reason: '$locale');
          expect(text.trim().length, greaterThan(30), reason: '$locale');
        }
        expect(l.orchardClosedOfflineCloud.toLowerCase(), contains(l.orchardTeam.toLowerCase()), reason: '$locale');
        if (locale.languageCode != 'en') {
          expect(l.cloudDown, isNot(en.cloudDown), reason: '$locale');
          expect(l.cloudBlockedHere, isNot(en.cloudBlockedHere), reason: '$locale');
          expect(l.cloudNothingReached, isNot(en.cloudNothingReached), reason: '$locale');
          expect(l.orchardClosedOfflineCloud, isNot(en.orchardClosedOfflineCloud), reason: '$locale');
        }
      }
    });

    test('each in its own words, ending in its code', () {
      expect(const CloudFailure(CloudFailureKind.notResponding).message(en), '${en.cloudNotResponding} (ZS-1101)');
      expect(const CloudFailure(CloudFailureKind.deviceOffline).message(en), '${en.cloudDeviceOffline} (ZS-1102)');
      expect(const CloudFailure(CloudFailureKind.fault, status: 503).message(en), '${en.cloudFault(503)} (ZS-1103)');
      expect(const CloudFailure(CloudFailureKind.notSecure).message(en), '${en.cloudNotSecure} (ZS-1104)');
    });

    test('a fault names the status it came with', () {
      expect(const CloudFailure(CloudFailureKind.fault, status: 502).message(en), contains('HTTP 502'));
      expect(const CloudFailure(CloudFailureKind.fault).message(en), contains('HTTP 500'),
          reason: 'a fault with no status known is said as the plainest one');
    });

    test('three of the four say that nothing on the device is affected, and none says "check your connection" of a fault that is ours', () {
      expect(en.cloudNotResponding, contains('not affected'));
      expect(en.cloudFault(500), contains('Nothing is wrong on this device'));
      expect(en.cloudDeviceOffline, contains('keep working'));
      for (final text in [en.cloudNotResponding, en.cloudFault(500)]) {
        expect(text.toLowerCase(), isNot(contains('check your connection')));
      }
    });

    test('every language has its own words for each, and a fault names its status in every one', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        final texts = [l.cloudNotResponding, l.cloudDeviceOffline, l.cloudFault(503), l.cloudNotSecure];
        expect(texts.toSet(), hasLength(4), reason: '$locale');
        expect(l.cloudFault(503), contains('503'), reason: '$locale');
        for (final text in texts) {
          expect(text, contains('ZestSSH Cloud'), reason: '$locale');
          expect(text.trim().length, greaterThan(30), reason: '$locale');
        }
        if (locale.languageCode != 'en') {
          expect(l.cloudNotResponding, isNot(en.cloudNotResponding), reason: '$locale');
          expect(l.cloudDeviceOffline, isNot(en.cloudDeviceOffline), reason: '$locale');
          expect(l.cloudFault(503), isNot(en.cloudFault(503)), reason: '$locale');
          expect(l.cloudNotSecure, isNot(en.cloudNotSecure), reason: '$locale');
        }
      }
    });
  });

  group('an Orchard screen says it that way', () {
    test('no answer: how ZestSSH Cloud stands, not "couldn\'t be reached"', () {
      expect(orchardErrorMessage(refused, en), '${en.cloudNotResponding} (ZS-1101)');
      expect(orchardErrorMessage(TimeoutException('no answer'), en), '${en.cloudNotResponding} (ZS-1101)');
      expect(orchardErrorMessage(http.ClientException('Connection reset'), en), '${en.cloudNotResponding} (ZS-1101)');
      expect(orchardErrorMessage(const HandshakeException('CERTIFICATE_VERIFY_FAILED'), en),
          '${en.cloudNotSecure} (ZS-1104)');
    });

    test('a fault of the server\'s: said as that, where it was "Something went wrong" and the name of a class', () {
      for (final status in [500, 502, 503]) {
        final said = orchardErrorMessage(OrchardServerException(status, 'server-error'), en);
        expect(said, '${en.cloudFault(status)} (ZS-1103)');
        expect(said, isNot(contains('OrchardServerException')));
        expect(said, isNot(contains('Something went wrong')));
      }
    });

    test('what the server said in so many words is still said as before', () {
      expect(orchardErrorMessage(const OrchardServerException(401, 'unauthorized'), en), en.orchardErrorSignedOut);
      // A route that is there and an item that is not: it may have been removed, or lost in a
      // restore of ZestSSH Cloud. A server with Teams off has no such route and answers without
      // a code.
      expect(orchardErrorMessage(const OrchardServerException(404, 'not-found'), en), en.orchardErrorGone);
      expect(orchardErrorMessage(const OrchardServerException(404, ''), en), en.orchardErrorUnavailable);
      expect(orchardErrorMessage(const OrchardServerException(409, 'seats-needed'), en), en.orchardSeatsNeeded);
      expect(orchardErrorMessage(const OrchardServerException(403, 'orchard-limit'), en), en.orchardErrorLimit);
    });

    test('with the device known to be offline, that is what an Orchard screen says', () {
      final reach = CloudReachService(check: () async => 200);
      addTearDown(reach.dispose);
      currentCloudReach = reach;
      reach.networkChanged(up: false);
      expect(orchardErrorMessage(refused, en), '${en.cloudDeviceOffline} (ZS-1102)');
    });
  });

  group('what any screen says where the service or the way to it stopped something', () {
    test('how the service stands, with its code: not responding, a fault of its own, the device offline', () {
      expect(cloudStopped(en, refused), '${en.cloudNotResponding} (ZS-1101)');
      expect(cloudStopped(en, TimeoutException('no answer')), '${en.cloudNotResponding} (ZS-1101)');
      // A fault, by the status the screen knows or by the one in what was caught.
      expect(cloudStopped(en, 'the answer', status: 503), '${en.cloudFault(503)} (ZS-1103)');
      expect(cloudStopped(en, const OrchardServerException(502, null)), '${en.cloudFault(502)} (ZS-1103)');
      expect(cloudStopped(en, 'Signed-in devices: HTTP 500'), '${en.cloudFault(500)} (ZS-1103)');
      final reach = CloudReachService(check: () async => 200);
      addTearDown(reach.dispose);
      currentCloudReach = reach;
      reach.networkChanged(up: false);
      expect(cloudStopped(en, refused), '${en.cloudDeviceOffline} (ZS-1102)');
      // The three read differently, and none sends anyone to check a
      // connection that is fine.
      final said = {en.cloudNotResponding, en.cloudFault(503), en.cloudDeviceOffline};
      expect(said, hasLength(3));
      for (final words in [en.cloudNotResponding, en.cloudFault(503)]) {
        expect(words.toLowerCase(), isNot(contains('check your connection')));
      }
    });

    test('after the screen\'s own sentence for what did not happen, where it has one; the code stays at the end', () {
      expect(cloudStopped(en, refused, lead: 'Nothing was deleted.'),
          'Nothing was deleted. ${en.cloudNotResponding} (ZS-1101)');
      expect(cloudStopped(en, 'the answer', status: 500, lead: 'Nothing was changed.'),
          'Nothing was changed. ${en.cloudFault(500)} (ZS-1103)');
    });

    test('nothing where the service answered: what it said is the screen\'s to explain', () {
      for (final answered in <Object>[
        const OrchardServerException(403, 'read-only'),
        const OrchardServerException(404, 'not-found'),
        'Signed-in devices: HTTP 409 recent-sign-in-required',
        StateError('something on this device'),
        const FormatException('not JSON'),
      ]) {
        expect(cloudStopped(en, answered), isNull, reason: '$answered');
        expect(cloudStopped(en, answered, lead: 'Nothing was deleted.'), isNull, reason: '$answered');
      }
      expect(cloudStopped(en, 'the answer', status: 400), isNull);
      expect(cloudStopped(en, 'the answer', status: 429), isNull);
    });
  });

  group('nothing answered, and what was caught is not at hand', () {
    test('said as far as the app knows: not responding, the device offline, or what it has found out since', () async {
      expect(cloudNoAnswerNow().kind, CloudFailureKind.notResponding);
      expect(cloudNoAnswerNow().code, ErrorCodes.cloudNotResponding);
      expect(cloudNoAnswerNow(deviceOnline: false).kind, CloudFailureKind.deviceOffline);
      final reach = CloudReachService(
        check: () async => throw refused,
        status: () async => null,
        timer: (wait, then) => Timer(const Duration(days: 1), () {}),
      );
      addTearDown(reach.dispose);
      currentCloudReach = reach;
      await reach.checkNow();
      expect(cloudNoAnswerNow().kind, CloudFailureKind.nothingReached);
      expect(cloudNoAnswerNow(deviceOnline: false).kind, CloudFailureKind.deviceOffline,
          reason: 'what the caller knows of the device comes first');
      reach.networkChanged(up: false);
      expect(cloudNoAnswerNow().kind, CloudFailureKind.deviceOffline);
    });

    test('which failures are on this side, and which are the service', () {
      expect({for (final kind in CloudFailureKind.values) kind: CloudFailure(kind).onThisSide}, {
        CloudFailureKind.deviceOffline: true,
        CloudFailureKind.notResponding: false,
        CloudFailureKind.notSecure: true,
        CloudFailureKind.fault: false,
        CloudFailureKind.down: false,
        CloudFailureKind.blockedHere: true,
        CloudFailureKind.nothingReached: true,
      });
    });
  });
}
