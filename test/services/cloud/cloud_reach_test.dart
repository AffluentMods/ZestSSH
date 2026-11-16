import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';

/// How ZestSSH Cloud stands from this device (3.0: knowing when the
/// server is offline, so the message can say the service is not
/// responding, rather than show a basic
/// error).
///
/// Three things look alike from inside one failed request and call for
/// three different things from the person: the device is offline, the
/// service is not responding, the service answers with a fault. The service
/// here is told every exchange with ZestSSH Cloud, asks it how it is when
/// one fails, keeps asking while it does not answer, and tells whoever
/// waits the moment it answers again.
void main() {
  late DateTime now;
  late _Timers timers;
  late int checks;
  late Object Function() health;
  late CloudReachService reach;
  late List<CloudReachState> seen;
  late int cameBack;

  const refused = SocketException('Connection refused');

  setUp(() {
    now = DateTime(2026, 10, 8, 14, 5);
    timers = _Timers();
    checks = 0;
    health = () => 200;
    reach = CloudReachService(
      check: () async {
        checks++;
        final answer = health();
        if (answer is int) return answer;
        throw answer;
      },
      clock: () => now,
      timer: timers.call,
    );
    seen = [];
    cameBack = 0;
    reach.state.addListener(() => seen.add(reach.state.value));
    reach.addBackListener(() => cameBack++);
  });

  tearDown(() => reach.dispose());

  Future<void> settled() => Future<void>.delayed(Duration.zero);

  group('while all is well', () {
    test('nothing is known and nothing is asked until the app itself has asked something', () async {
      expect(reach.state.value.reach, CloudReach.unknown);
      expect(reach.state.value.inTheWay, isFalse);
      await settled();
      expect(checks, 0);
      expect(timers.waiting, isEmpty);
    });

    test('an answer is an answer, whatever it says, and nothing more is asked', () async {
      for (final status in [200, 204, 304, 401, 403, 404, 409, 426, 429]) {
        reach.heard(status);
        expect(reach.state.value.reach, CloudReach.answering, reason: 'HTTP $status');
      }
      await settled();
      expect(checks, 0, reason: 'what a request was told is between the service and whoever asked');
      expect(seen, hasLength(1), reason: 'said once, not at every exchange');
      expect(cameBack, 0, reason: 'it was never away');
    });

    test('what the client tells of an exchange is heard as an answer or as none', () async {
      reach.hear(200, null);
      expect(reach.state.value.reach, CloudReach.answering);
      health = () => refused;
      reach.hear(null, refused);
      await settled();
      expect(reach.state.value.reach, CloudReach.notResponding);
      reach.hear(null, null);
      await settled();
      expect(checks, 1, reason: 'an exchange with neither says nothing');
    });

    test('a device that never uses the service hears nothing of its network', () async {
      reach.networkChanged(up: false);
      reach.networkChanged(up: true);
      await settled();
      expect(reach.state.value.reach, CloudReach.unknown);
      expect(checks, 0);
    });
  });

  group('one failure is not an outage: the service is asked how it is', () {
    test('no answer to a request, and it answers the check: it is answering', () async {
      reach.heard(200);
      reach.noAnswer(refused);
      await settled();
      expect(checks, 1);
      expect(reach.state.value.reach, CloudReach.answering);
      expect(timers.waiting, isEmpty);
    });

    test('a fault from one thing asked, and the check is fine: it is answering', () async {
      reach.heard(500);
      await settled();
      expect(checks, 1);
      expect(reach.state.value.reach, CloudReach.answering);
    });

    test('several failures at once ask once', () async {
      health = () => refused;
      reach
        ..noAnswer(refused)
        ..noAnswer(TimeoutException('no answer'))
        ..heard(503);
      await settled();
      expect(checks, 1);
    });
  });

  group('the three ways it can be in the way', () {
    test('no answer, and the device has a network: the service is not responding', () async {
      health = () => refused;
      reach.networkChanged(up: true);
      reach.noAnswer(refused);
      await settled();
      final state = reach.state.value;
      expect(state.reach, CloudReach.notResponding);
      expect(state.inTheWay, isTrue);
      expect(state.since, now);
      expect(state.detail, contains('Connection refused'));
      expect(state.status, isNull);
    });

    test('no answer, and the device has no network: the device is offline', () async {
      health = () => refused;
      // (Heard before anything here used the service: it is remembered.)
      reach.networkChanged(up: false);
      expect(reach.state.value.reach, CloudReach.unknown);
      reach.noAnswer(refused);
      await settled();
      expect(reach.state.value.reach, CloudReach.deviceOffline);
      expect(reach.state.value.inTheWay, isTrue);
    });

    test('no answer, and the system cannot say how the network stands: said as the service not responding', () async {
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      expect(reach.state.value.reach, CloudReach.notResponding);
    });

    test('the check itself answers with a fault: a fault, with its status', () async {
      for (final status in [500, 502, 503, 504, 522, 530]) {
        reach.forget();
        health = () => status;
        reach.heard(status);
        await settled();
        expect(reach.state.value.reach, CloudReach.fault, reason: 'HTTP $status');
        expect(reach.state.value.status, status);
        expect(reach.state.value.inTheWay, isTrue);
      }
    });

    test('the details say what was found; what led to asking is in the log, once', () async {
      final logged = <String>[];
      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      final listening = Logger.root.onRecord.listen((record) => logged.add('${record.level.name}: ${record.message}'));
      addTearDown(() {
        Logger.root.level = level;
        return listening.cancel();
      });

      health = () => 503;
      reach.heard(502);
      await settled();
      expect(reach.state.value.detail, 'The health check answered HTTP 503');
      expect(logged, ['WARNING: ZestSSH Cloud: CloudReach.fault (HTTP 503), asked after: HTTP 502']);

      timers.fire();
      await settled();
      expect(reach.state.value.detail, 'The health check answered HTTP 503');
      expect(logged, hasLength(1), reason: 'the trouble going on is not logged again at every check');

      health = () => refused;
      timers.fire();
      await settled();
      expect(reach.state.value.reach, CloudReach.notResponding);
      expect(logged, hasLength(1), reason: 'nor at every turn it takes: it is still the one trouble');

      health = () => 200;
      timers.fire();
      await settled();
      expect(logged, hasLength(2));
      expect(logged.last, startsWith('INFO: ZestSSH Cloud answers again'));

      health = () => refused;
      reach.noAnswer(TimeoutException('no answer in time'));
      await settled();
      expect(reach.state.value.detail, contains('Connection refused'), reason: 'what the check itself met');
      expect(logged.last, allOf(startsWith('WARNING: ZestSSH Cloud: CloudReach.notResponding, asked after: '),
          contains('no answer in time')));
    });

    test('since when is the first moment, through whatever shape the trouble takes', () async {
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      final first = now;
      now = now.add(const Duration(minutes: 3));
      health = () => 503;
      timers.fire();
      await settled();
      expect(reach.state.value.reach, CloudReach.fault);
      expect(reach.state.value.since, first);
      now = now.add(const Duration(minutes: 3));
      reach.networkChanged(up: false);
      expect(reach.state.value.reach, CloudReach.deviceOffline);
      expect(reach.state.value.since, first);
    });
  });

  // What one device cannot know by itself the status service can: it looks
  // from somewhere else, and what it says is signed (3.0).
  group('seen from somewhere else', () {
    // Ten to two; the outage began at eight.
    final at = DateTime.utc(2026, 10, 8, 13, 50).millisecondsSinceEpoch ~/ 1000;
    final began = DateTime.utc(2026, 10, 8, 8);
    final downSince8 =
        CloudStatement(down: true, at: at, until: at + 900, since: began.millisecondsSinceEpoch ~/ 1000, keyId: 'k1');
    final up = CloudStatement(down: false, at: at, until: at + 900, since: 0, keyId: 'k1');

    late Object? Function() says;
    late int asked;
    late List<CloudStatement> proven;
    late CloudReachService watched;
    late List<CloudReachState> states;
    late int back;

    setUp(() {
      says = () => null;
      asked = 0;
      proven = [];
      watched = CloudReachService(
        check: () async {
          checks++;
          final answer = health();
          if (answer is int) return answer;
          throw answer;
        },
        status: () async {
          asked++;
          final said = says();
          if (said is CloudStatement?) return said;
          throw said;
        },
        clock: () => now,
        timer: timers.call,
      );
      states = [];
      back = 0;
      watched.state.addListener(() => states.add(watched.state.value));
      watched.addBackListener(() => back++);
      watched.addOutageListener(proven.add);
    });

    tearDown(() => watched.dispose());

    test('no answer, and it says "down": ZestSSH Cloud is down, since when it says, and that is proof', () async {
      health = () => refused;
      says = () => downSince8;
      watched.networkChanged(up: true);
      watched.noAnswer(refused);
      await settled();
      final state = watched.state.value;
      expect(state.reach, CloudReach.down);
      expect(state.inTheWay, isTrue);
      expect(state.outageSince, began, reason: 'long before this device noticed');
      expect(state.since, now, reason: 'and when this device noticed');
      expect(state.detail, contains('Connection refused'));
      expect(asked, 1);
      expect(proven, [downSince8]);
    });

    test('no answer, and it says "up": this network does not let the device reach it', () async {
      health = () => refused;
      says = () => up;
      watched.noAnswer(refused);
      await settled();
      expect(watched.state.value.reach, CloudReach.blocked);
      expect(watched.state.value.inTheWay, isTrue);
      expect(watched.state.value.outageSince, isNull);
      expect(proven, isEmpty, reason: 'nothing is proven by "up"');
    });

    test('no answer from either: nothing of ZestSSH is reached', () async {
      health = () => refused;
      watched.noAnswer(refused);
      await settled();
      expect(watched.state.value.reach, CloudReach.nothingReached);
      expect(watched.state.value.inTheWay, isTrue);
      expect(asked, 1);
      expect(proven, isEmpty);
    });

    test('asking it fails: the same as no statement, and nothing breaks', () async {
      health = () => refused;
      says = () => StateError('the status service could not be asked');
      watched.noAnswer(refused);
      await settled();
      expect(watched.state.value.reach, CloudReach.nothingReached);
      expect(timers.waiting, hasLength(1), reason: 'and the service is asked again as always');
    });

    test('with no status service set up, a device says what it can know alone', () async {
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      expect(reach.state.value.reach, CloudReach.notResponding);
    });

    test('the device has no network: it is offline, and nobody is asked what cannot be reached anyway', () async {
      health = () => refused;
      says = () => downSince8;
      watched.networkChanged(up: false);
      watched.noAnswer(refused);
      await settled();
      expect(watched.state.value.reach, CloudReach.deviceOffline);
      expect(asked, 0);
      expect(proven, isEmpty);
    });

    test('what answers cannot be verified: said as that, and nobody else is asked', () async {
      const forged = HandshakeException('CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate');
      health = () => forged;
      says = () => downSince8;
      watched.noAnswer(forged);
      await settled();
      expect(watched.state.value.reach, CloudReach.notSecure);
      expect(watched.state.value.inTheWay, isTrue);
      expect(watched.state.value.detail, contains('CERTIFICATE_VERIFY_FAILED'));
      expect(asked, 0);
      expect(proven, isEmpty);
      // The same without a status service.
      reach.noAnswer(forged);
      await settled();
      expect(reach.state.value.reach, CloudReach.notSecure);
    });

    test('a fault, and it says "down": down, with the status this device was answered', () async {
      health = () => 503;
      says = () => downSince8;
      watched.heard(503);
      await settled();
      expect(watched.state.value.reach, CloudReach.down);
      expect(watched.state.value.status, 503);
      expect(watched.state.value.outageSince, began);
      expect(watched.state.value.detail, 'The health check answered HTTP 503');
      expect(proven, [downSince8]);
    });

    test('a fault, and it says "up" or nothing: a fault, as this device met it', () async {
      for (final said in <CloudStatement?>[up, null]) {
        watched.forget();
        proven.clear();
        health = () => 502;
        says = () => said;
        watched.heard(502);
        await settled();
        expect(watched.state.value.reach, CloudReach.fault, reason: '$said');
        expect(watched.state.value.status, 502);
        expect(proven, isEmpty);
      }
    });

    test('while all is well it is never asked', () async {
      says = () => downSince8;
      watched.heard(200);
      watched.heard(404);
      health = () => 200;
      watched.heard(500);
      await settled();
      expect(watched.state.value.reach, CloudReach.answering);
      expect(asked, 0, reason: 'asked only after the service itself gave no answer');
      expect(proven, isEmpty);
    });

    test('an outage that goes on is asked about at every check, and each answer is proof', () async {
      health = () => refused;
      var minute = 0;
      says = () => CloudStatement(
          down: true,
          at: at + 60 * minute,
          until: at + 60 * minute + 900,
          since: began.millisecondsSinceEpoch ~/ 1000,
          keyId: 'k1');
      watched.noAnswer(refused);
      await settled();
      for (minute = 1; minute <= 4; minute++) {
        timers.fire();
        await settled();
      }
      expect(asked, 5);
      expect(proven.map((p) => p.at), [for (var m = 0; m <= 4; m++) at + 60 * m], reason: 'so that time goes on being excused');
      expect(states.where((s) => s.reach == CloudReach.down), hasLength(1),
          reason: 'the same outage found again is no news to what shows it');
    });

    test('an outage that turns out to have begun earlier is news to what shows it', () async {
      health = () => refused;
      // First seen by a part of the status service that had only just noticed.
      says = () => CloudStatement(down: true, at: at, until: at + 900, since: at, keyId: 'k1');
      watched.noAnswer(refused);
      await settled();
      says = () => downSince8;
      timers.fire();
      await settled();
      final downs = states.where((s) => s.reach == CloudReach.down).toList();
      expect(downs, hasLength(2));
      expect(downs.map((s) => s.outageSince), [DateTime.fromMillisecondsSinceEpoch(at * 1000, isUtc: true), began]);
      expect(downs.map((s) => s.since).toSet(), {now}, reason: 'when this device noticed is as it was');
    });

    test('the turns it can take: blocked, then down, then back', () async {
      health = () => refused;
      says = () => up;
      watched.noAnswer(refused);
      await settled();
      final noticed = now;
      expect(watched.state.value.reach, CloudReach.blocked);

      now = now.add(const Duration(minutes: 1));
      says = () => downSince8;
      timers.fire();
      await settled();
      expect(watched.state.value.reach, CloudReach.down);
      expect(watched.state.value.since, noticed, reason: 'since when is the first moment');

      health = () => 200;
      timers.fire();
      await settled();
      expect(watched.state.value.reach, CloudReach.answering);
      expect(watched.state.value.outageSince, isNull);
      expect(back, 1);
      expect(timers.waiting, isEmpty);
      expect(states.map((s) => s.reach), [CloudReach.blocked, CloudReach.down, CloudReach.answering]);
    });

    test('one who keeps count of outages and fails does not keep the others from hearing', () async {
      final heard = <CloudStatement>[];
      final other = CloudReachService(
        check: () async => throw refused,
        status: () async => downSince8,
        clock: () => now,
        timer: timers.call,
      )
        ..addOutageListener((_) => throw StateError('could not keep it'))
        ..addOutageListener(heard.add);
      addTearDown(other.dispose);
      other.noAnswer(refused);
      await settled();
      expect(heard, [downSince8]);
      expect(other.state.value.reach, CloudReach.down);
    });

    test('one who no longer wants to hear of outages is not told', () async {
      health = () => refused;
      says = () => downSince8;
      expect(watched.hasOutageListeners, isTrue);
      watched.removeOutageListener(proven.add);
      expect(watched.hasOutageListeners, isFalse);
      watched.noAnswer(refused);
      await settled();
      expect(watched.state.value.reach, CloudReach.down);
      expect(proven, isEmpty);
    });

    test('gone while the status service is being asked: its answer sets nothing and proves nothing', () async {
      final answer = Completer<CloudStatement?>();
      final heard = <CloudStatement>[];
      final other = CloudReachService(
        check: () async => throw refused,
        status: () => answer.future,
        timer: timers.call,
      )..addOutageListener(heard.add);
      other.noAnswer(refused);
      await settled();
      other.dispose();
      answer.complete(downSince8);
      await settled();
      expect(heard, isEmpty);
      expect(timers.waiting, isEmpty);
    });
  });

  group('while it does not answer it is asked again', () {
    test('later each time, up to every five minutes, for as long as it takes', () async {
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      final waits = <Duration>[timers.wait];
      for (var i = 0; i < 8; i++) {
        timers.fire();
        await settled();
        waits.add(timers.wait);
      }
      expect(waits, const [
        Duration(seconds: 10),
        Duration(seconds: 20),
        Duration(seconds: 30),
        Duration(minutes: 1),
        Duration(minutes: 2),
        Duration(minutes: 5),
        Duration(minutes: 5),
        Duration(minutes: 5),
        Duration(minutes: 5),
      ]);
      expect(checks, 9);
      expect(seen.where((s) => s.reach == CloudReach.notResponding), hasLength(1),
          reason: 'said once: asking again and hearing nothing again is no news');
    });

    test('a service that answers with a fault is asked again the same way, until it is well', () async {
      health = () => 503;
      reach.heard(503);
      await settled();
      expect(reach.state.value.reach, CloudReach.fault);
      final waits = <Duration>[timers.wait];
      for (var i = 0; i < 6; i++) {
        timers.fire();
        await settled();
        waits.add(timers.wait);
      }
      expect(waits, const [
        Duration(seconds: 10),
        Duration(seconds: 20),
        Duration(seconds: 30),
        Duration(minutes: 1),
        Duration(minutes: 2),
        Duration(minutes: 5),
        Duration(minutes: 5),
      ]);
      expect(checks, 7);
      expect(seen.where((s) => s.reach == CloudReach.fault), hasLength(1), reason: 'the same fault again is no news');

      health = () => 200;
      timers.fire();
      await settled();
      expect(reach.state.value.reach, CloudReach.answering);
      expect(cameBack, 1);
      expect(timers.waiting, isEmpty);
    });

    test('and the moment it answers, whoever waits is told, once', () async {
      health = () => refused;
      reach.heard(200);
      reach.noAnswer(refused);
      await settled();
      expect(cameBack, 0);

      health = () => 200;
      timers.fire();
      await settled();
      expect(reach.state.value.reach, CloudReach.answering);
      expect(reach.state.value.since, isNull);
      expect(cameBack, 1);
      expect(timers.waiting, isEmpty, reason: 'nothing more is asked once it answers');

      reach.heard(200);
      reach.heard(200);
      expect(cameBack, 1);
    });

    test('an exchange of the app that goes through says it is back, without waiting for the next check', () async {
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      expect(reach.state.value.inTheWay, isTrue);
      reach.heard(204);
      expect(reach.state.value.reach, CloudReach.answering);
      expect(cameBack, 1);
      expect(timers.waiting, isEmpty);
    });

    test('after it came back, the next trouble starts from the short wait again', () async {
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      timers.fire();
      await settled();
      expect(timers.wait, const Duration(seconds: 20));
      reach.heard(200);
      reach.noAnswer(refused);
      await settled();
      expect(timers.wait, const Duration(seconds: 10));
    });

    test('one who waits and fails does not keep the others from hearing', () async {
      var second = 0;
      reach
        ..addBackListener(() => throw StateError('a listener of its own'))
        ..addBackListener(() => second++);
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      reach.heard(200);
      expect(cameBack, 1);
      expect(second, 1);
    });
  });

  group('the device\'s network', () {
    test('gone: the device is offline, at once, and nothing is asked into the void', () async {
      reach.heard(200);
      reach.networkChanged(up: false);
      expect(reach.state.value.reach, CloudReach.deviceOffline);
      expect(reach.state.value.since, now);
      await settled();
      expect(checks, 0);
      expect(timers.waiting, isEmpty);
    });

    test('gone while a check waits its time: the check is dropped, since nothing would answer it', () async {
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      expect(timers.waiting, hasLength(1));
      reach.networkChanged(up: false);
      expect(timers.waiting, isEmpty);
      expect(reach.state.value.reach, CloudReach.deviceOffline);
      expect(checks, 1);
    });

    test('back: the service is asked at once, and what waited is told when it answers', () async {
      reach.heard(200);
      reach.networkChanged(up: false);
      reach.networkChanged(up: true);
      await settled();
      expect(checks, 1);
      expect(reach.state.value.reach, CloudReach.answering);
      expect(cameBack, 1, reason: 'what waited while the device was offline catches up');
    });

    test('back while a check waits its time: asked now, not at the end of the wait', () async {
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      expect(timers.waiting, hasLength(1));
      health = () => 200;
      reach.networkChanged(up: true);
      await settled();
      expect(checks, 2);
      expect(reach.state.value.reach, CloudReach.answering);
      expect(timers.waiting, isEmpty);
    });

    test('a change while all is well asks nothing', () async {
      reach.heard(200);
      reach.networkChanged(up: true);
      await settled();
      expect(checks, 0);
    });
  });

  group('asked for, and coming back to the front', () {
    test('asked for now: the state as it stands after the answer', () async {
      health = () => 503;
      final state = await reach.checkNow();
      expect(state.reach, CloudReach.fault);
      expect(state.status, 503);
      health = () => 200;
      expect((await reach.checkNow()).reach, CloudReach.answering);
    });

    test('the app back in front while the service was not answering: asked at once', () async {
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      health = () => 200;
      reach.appResumed();
      await settled();
      expect(checks, 2);
      expect(reach.state.value.reach, CloudReach.answering);
    });

    test('the app back in front while all is well, or nothing is known: nothing asked', () async {
      reach.appResumed();
      reach.heard(200);
      reach.appResumed();
      await settled();
      expect(checks, 0);
    });
  });

  group('nothing uses the service any more', () {
    test('forgotten: nothing known, nothing asked, the check that waited dropped', () async {
      health = () => refused;
      reach.noAnswer(refused);
      await settled();
      expect(timers.waiting, hasLength(1));
      reach.forget();
      expect(reach.state.value.reach, CloudReach.unknown);
      expect(reach.state.value.since, isNull);
      expect(timers.waiting, isEmpty);
    });

    test('gone: what arrives afterwards changes nothing and asks nothing', () async {
      final other = CloudReachService(
        check: () async {
          checks++;
          return 200;
        },
        timer: timers.call,
      );
      other.dispose();
      other
        ..heard(500)
        ..noAnswer(refused)
        ..networkChanged(up: true)
        ..appResumed();
      await settled();
      expect(checks, 0);
    });

    test('gone while a check is under way: its answer sets nothing', () async {
      final answer = Completer<int>();
      final other = CloudReachService(check: () => answer.future, timer: timers.call);
      other.noAnswer(refused);
      await settled();
      other.dispose();
      answer.completeError(refused);
      await settled();
      expect(timers.waiting, isEmpty);
    });
  });

  group('what kind of failure an error is', () {
    test('no answer: a refused connection, no answer in time, a connection that broke or is not secure', () {
      for (final error in <Object>[
        refused,
        TimeoutException('no answer'),
        const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        const TlsException('bad record'),
        const HttpException('Connection closed before full header was received'),
        const WebSocketException('Connection was not upgraded'),
        http.ClientException('Connection reset by peer'),
      ]) {
        expect(isNoAnswer(error), isTrue, reason: '$error');
      }
    });

    test('an answer, or a fault of the app\'s own, is not "no answer"', () {
      for (final error in <Object>[
        StateError('Account keys: HTTP 503'),
        const FormatException('not JSON'),
        ArgumentError('bad'),
        Exception('ClientException in name only'),
      ]) {
        expect(isNoAnswer(error), isFalse, reason: '$error');
      }
    });

    test('a connection that could not be made secure is told from the rest', () {
      expect(isNotSecure(const HandshakeException('Handshake error in client')), isTrue);
      expect(isNotSecure(const CertificateException('the certificate is not this host\'s')), isTrue);
      expect(isNotSecure(const TlsException('bad record')), isTrue);
      // By its kind, whatever it says of itself.
      expect(isNotSecure(const _SaysNothing()), isTrue);
      expect(isNoAnswer(const _SaysNothing()), isTrue);
      // As package:http hands them on, in the words of the error alone.
      expect(isNotSecure(http.ClientException('HandshakeException: Handshake error in client')), isTrue);
      expect(isNotSecure(http.ClientException('Connection failed (CERTIFICATE_VERIFY_FAILED: unable to get issuer)')), isTrue);
      expect(isNotSecure(http.ClientException('TlsException: Failure trusting builtin roots')), isTrue);
      expect(isNotSecure(refused), isFalse);
      expect(isNotSecure(TimeoutException('no answer')), isFalse);
      expect(isNotSecure(http.ClientException('Connection reset by peer')), isFalse);
    });
  });
}

/// A failure of the secure connection whose words do not say what it is.
class _SaysNothing extends TlsException {
  const _SaysNothing();

  @override
  String toString() => 'the connection ended';
}

/// The timers the service sets, held by the test: none runs by itself.
class _Timers {
  final waiting = <_Timer>[];

  Timer call(Duration wait, void Function() then) {
    final timer = _Timer(this, wait, then);
    waiting.add(timer);
    return timer;
  }

  Duration get wait => waiting.single.wait;

  void fire() {
    final timer = waiting.single;
    waiting.remove(timer);
    timer.then();
  }
}

class _Timer implements Timer {
  _Timer(this._owner, this.wait, this.then);

  final _Timers _owner;
  final Duration wait;
  final void Function() then;

  @override
  void cancel() => _owner.waiting.remove(this);

  @override
  bool get isActive => _owner.waiting.contains(this);

  @override
  int get tick => 0;
}
