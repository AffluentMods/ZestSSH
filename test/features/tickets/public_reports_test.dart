import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/tickets/public_reports.dart';
import 'package:zestssh/features/tickets/support_diagnostics.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/utils/logger.dart';

/// Everyone's reports and +1 as the app reads them (3.4, ZestSSH Cloud's
/// routes/reports.js), what "Include diagnostics" sends, and where a ticket
/// stands as it is kept on the device.
void main() {
  Map<String, dynamic> report({Object? id = '0123456789ab', Object? type = 'bug', Object? title = 'A title'}) => {
        'id': id,
        'type': type,
        'title': title,
        'body': 'Text.',
        'state': 'fixed',
        'state_version': '3.3.1',
        'votes': 23,
        'comments': 4,
        'closed': false,
        'discord_url': 'https://discord.com/channels/1/2',
        'created_at': '2026-11-01T10:00:00.000Z',
      };

  group('a report from the lists', () {
    test('is read with what the lists carry', () {
      final r = PublicReport.fromJson(report())!;
      expect(r.id, '0123456789ab');
      expect(r.type, TicketType.bug);
      expect(r.state, ReportState.fixed);
      expect(r.stateVersion, '3.3.1');
      expect(r.votes, 23);
      expect(r.comments, 4);
      expect(r.discordUrl, 'https://discord.com/channels/1/2');
    });

    test('anything that is not one is left out, and only a Discord link is taken', () {
      expect(PublicReport.fromJson(report(id: 'tk_0123456789abcdef')), isNull, reason: 'a ticket id is never a public id');
      expect(PublicReport.fromJson(report(type: 'support')), isNull, reason: 'support is never in a list');
      expect(PublicReport.fromJson(report(title: '  ')), isNull);
      expect(PublicReport.fromJson('not a map'), isNull);
      final odd = PublicReport.fromJson({...report(), 'discord_url': 'https://evil.example/x', 'state': 'done', 'state_version': '3.4 beta!', 'votes': -3})!;
      expect(odd.discordUrl, isNull);
      expect(odd.state, isNull);
      expect(odd.stateVersion, isNull);
      expect(odd.votes, 0);
    });
  });

  group('the service', () {
    late List<http.Request> calls;
    late int status;
    late Map<String, dynamic> answer;

    const device = 'device-0123456789abcdefABCDEF_-';

    late Set<String> kept;

    PublicReportsService service({String? bearer, String? deviceId = device}) => PublicReportsService(
          baseUrl: 'https://api.test/v1',
          bearer: () async => bearer,
          deviceId: () async => deviceId,
          guestVotes: () async => {...kept},
          rememberGuestVote: (id, on) async => on ? kept.add(id) : kept.remove(id),
          client: MockClient((req) async {
            calls.add(req);
            return http.Response(jsonEncode(answer), status, headers: {'content-type': 'application/json'});
          }),
        );

    setUp(() {
      calls = [];
      status = 200;
      answer = {'reports': [report()]};
      kept = {};
    });

    test('a list and the duplicate search carry no account, signed in or not', () async {
      final s = service(bearer: 'a-bearer');
      expect(await s.list(const ReportQuery(TicketType.suggestion, state: ReportState.planned)), hasLength(1));
      expect(calls.single.url.queryParameters, {'type': 'suggestion', 'sort': 'top', 'state': 'planned'});
      await s.similar('Deleting a folder over SFTP', TicketType.bug);
      expect(calls.last.url.path, endsWith('/reports/similar'));
      for (final c in calls) {
        expect(c.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
        expect(c.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-zestssh-device')),
            reason: 'a list says nothing of who reads it');
      }
      calls.clear();
      expect(await s.similar('ab', TicketType.bug), isEmpty, reason: 'too little typed to ask');
      expect(calls, isEmpty);
    });

    test('a list that does not come is an error for the screen to say', () async {
      status = 503;
      await expectLater(service().list(const ReportQuery(TicketType.bug)), throwsA(isA<StateError>()));
    });

    test('signed out, a vote is this device\'s; signed in, the account\'s and never with the device; each refusal told apart', () async {
      answer = {'id': '0123456789ab', 'votes': 24, 'voted': true};
      final guest = await service().vote('0123456789ab', on: true);
      expect(guest.outcome, VoteOutcome.done);
      expect(guest.votes, 24, reason: 'the total the server answers');
      expect(calls.single.method, 'POST');
      expect(calls.single.headers[kVoteDeviceHeader], device);
      expect(calls.single.headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
      expect(kept, {'0123456789ab'}, reason: 'a guest +1 is kept on the device');
      final mine = await service(bearer: 'a-bearer').vote('0123456789ab', on: true);
      expect(mine.outcome, VoteOutcome.done);
      expect(calls.last.headers['Authorization'], 'Bearer a-bearer');
      expect(calls.last.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-zestssh-device')),
          reason: 'the guest id never goes beside an account');
      answer = {'id': '0123456789ab', 'votes': 23, 'voted': false};
      await service(bearer: 'a-bearer').vote('0123456789ab', on: false);
      expect(calls.last.method, 'DELETE');
      expect(kept, {'0123456789ab'}, reason: 'an account\'s +1 is not kept on the device');
      await service().vote('0123456789ab', on: false);
      expect(kept, isEmpty, reason: 'a guest +1 taken back is forgotten');
      calls.clear();
      expect((await service(deviceId: null).vote('0123456789ab', on: true)).outcome, VoteOutcome.failed);
      expect((await service(deviceId: 'too short').vote('0123456789ab', on: true)).outcome, VoteOutcome.failed);
      expect(calls, isEmpty, reason: 'nobody to vote as: nothing is asked');
      for (final (code, body, outcome) in [
        (400, {'code': 'no-voter'}, VoteOutcome.failed),
        (403, {'code': 'blocked'}, VoteOutcome.blocked),
        (404, {'code': 'not-listed'}, VoteOutcome.notListed),
        (409, {'code': 'closed'}, VoteOutcome.closed),
        (429, <String, dynamic>{}, VoteOutcome.rateLimited),
        (500, <String, dynamic>{}, VoteOutcome.failed),
      ]) {
        status = code;
        answer = body;
        expect((await service().vote('0123456789ab', on: true)).outcome, outcome, reason: '$code $body');
      }
    });

    test('this person\'s votes: signed out, the ones this device kept (nothing is asked); signed in, the account\'s', () async {
      kept = {'aaaaaaaaaaa1'};
      expect(await service().myVotes(), {'aaaaaaaaaaa1'});
      expect(calls, isEmpty, reason: 'the id is never sent as the lists are read');
      answer = {'voted': ['0123456789ab', 7]};
      expect(await service(bearer: 'b').myVotes(), {'0123456789ab'});
      expect(calls.single.headers['Authorization'], 'Bearer b');
      expect(calls.single.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-zestssh-device')));
      status = 500;
      expect(await service(bearer: 'b').myVotes(), isEmpty);
    });

    test('what a +1 answered shows until the list is read again; one given while +1s are being read is kept', () async {
      final r = PublicReport.fromJson(report())!; // 23 in the list
      final reading = Completer<void>();
      var votedNow = <String>[];
      final notifier = ReportVotesNotifier(PublicReportsService(
        baseUrl: 'https://api.test/v1',
        bearer: () async => 'a-bearer',
        deviceId: () async => device,
        client: MockClient((req) async {
          if (req.url.path.endsWith('/reports/votes')) {
            await reading.future;
            return http.Response(jsonEncode({'voted': votedNow}), 200);
          }
          return http.Response(jsonEncode({'id': r.id, 'votes': 24, 'voted': true}), 200);
        }),
      ));
      addTearDown(notifier.dispose);

      final load = notifier.load(); // the list shows: its +1s are asked for
      await notifier.toggle(r); // and a +1 goes through before they come
      reading.complete(); // answered from before the +1
      await load;
      expect(notifier.state.hasVoted(r.id), isTrue, reason: 'the +1 given meanwhile is not undone');
      expect(notifier.state.over(r).votes, 24);

      // Shown again: the list read now has the latest total, whatever this device answered last.
      votedNow = [r.id];
      await notifier.load();
      expect(notifier.state.hasVoted(r.id), isTrue);
      expect(notifier.state.over(r.withVotes(40)).votes, 40, reason: '+1s given since elsewhere, in Discord too');
    });

    test('the device id: made once, random, kept as a device key, and kept by Reset all settings', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final id = reportVoteDeviceId(prefs);
      expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')), reason: '32 random bytes, base64url');
      expect(reportVoteDeviceId(prefs), id, reason: 'the same id every time');
      expect(prefs.getString(kReportVoteDeviceKey), id);
      final other = reportVoteDeviceId(await _fresh(), random: Random(7));
      expect(other, isNot(id));
      await prefs.setString(kReportVoteDeviceKey, 'not one!');
      expect(reportVoteDeviceId(prefs), isNot('not one!'), reason: 'a kept value of the wrong shape is replaced');
      expect(SettingsService.deviceKeys, contains(kReportVoteDeviceKey));
      expect(SettingsService.isProfileKey(kReportVoteDeviceKey), isFalse, reason: 'one per device, whoever uses it');
      expect(SettingsService.isResetKey(kReportVoteDeviceKey), isFalse, reason: 'a reset must not make a second voter');

      // Which reports it +1'd as a guest: kept beside it, newest 500, of the right shape only.
      await rememberReportGuestVote(prefs, '0123456789ab', true);
      await rememberReportGuestVote(prefs, 'aaaaaaaaaaa1', true);
      await rememberReportGuestVote(prefs, '0123456789ab', false);
      expect(reportGuestVotes(prefs), {'aaaaaaaaaaa1'});
      await prefs.setStringList(kReportVoteDeviceVotesKey, ['aaaaaaaaaaa1', 'tk_not_public', 'x']);
      expect(reportGuestVotes(prefs), {'aaaaaaaaaaa1'});
      for (var i = 0; i < 510; i++) {
        await rememberReportGuestVote(prefs, i.toRadixString(16).padLeft(12, '0'), true);
      }
      expect(reportGuestVotes(prefs), hasLength(500));
      expect(reportGuestVotes(prefs), isNot(contains('aaaaaaaaaaa1')), reason: 'the oldest go first');
      for (final key in [kReportVoteDeviceKey, kReportVoteDeviceVotesKey]) {
        expect(SettingsService.deviceKeys, contains(key));
        expect(SettingsService.keptKeys, contains(key));
      }
    });
  });

  group('what "Include diagnostics" sends', () {
    const ctx = FeedbackContext(
      appVersion: '3.4.0',
      build: 360,
      platform: 'windows',
      osVersion: 'Windows 11 24H2',
      locale: 'en-US',
      tier: 'free',
    );

    tearDown(AppLogger.forget);

    test('the version, the system, the last log lines with names and addresses taken out, and what was taken out', () {
      AppLogger.forget();
      AppLogger.remember(LogRecord(Level.WARNING, 'SFTP write to deploy@web-01.example.com (10.50.0.40) stalled', 'ZestSSH'));
      AppLogger.remember(LogRecord(Level.FINE, 'debug chatter is not kept', 'ZestSSH'));
      final text = supportDiagnostics(ctx, now: DateTime.utc(2026, 11, 6, 9, 40));
      expect(text, startsWith('ZestSSH diagnostics\nApp: ZestSSH 3.4.0 (360)\nSystem: windows Windows 11 24H2\n'));
      expect(text, contains('Time: 2026-11-06T09:40:00Z'));
      expect(text, contains('Log, the last 1 lines (oldest first):'));
      expect(text, contains('stalled'));
      expect(text, isNot(contains('web-01.example.com')));
      expect(text, isNot(contains('10.50.0.40')));
      expect(text, isNot(contains('debug chatter')));
      expect(diagnosticsSummary(text), 'v3.4.0, windows Windows 11 24H2');
      expect(kDiagnosticsLogLines, 200);
    });
  });

  group('where a ticket stands, as kept', () {
    test('the server\'s word is kept with the conversation and read back', () {
      final s = TicketStanding.fromJson({
        'visibility': 'private',
        'state': 'planned',
        'state_version': '3.4',
        'votes': 41,
        'public_id': '0123456789ab',
        'listed': false,
        'closed_reason': 'no_reply',
        'picked_up_at': '2026-11-04T10:12:00.000Z',
      }, fromServer: true);
      final again = TicketConversation.decode(TicketConversation(body: 'B', standing: s, diagnostics: 'D', hasScreenshot: true).encode())!;
      expect(again.standing.private, isTrue);
      expect(again.standing.state, 'planned');
      expect(again.standing.votes, 41);
      expect(again.standing.closedReason, 'no_reply');
      expect(again.standing.pickedUpAt, DateTime.utc(2026, 11, 4, 10, 12));
      expect(again.diagnostics, 'D');
      expect(again.hasScreenshot, isTrue);
      final old = TicketConversation.decode('{"body":"B","messages":[]}')!;
      expect(old.standing.private, isFalse, reason: 'a conversation kept before 3.4 still reads');
      expect(TicketStanding.fromJson({'state': 'done', 'closed_reason': 'bored', 'public_id': 'tk_x'}).state, isNull);
    });
  });
}

Future<SharedPreferences> _fresh() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}
