import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/assistant/assistant_service.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';

/// Ask Astryx's calls to ZestSSH Cloud (4.0): what is sent (the question after
/// ReportScrub, the last six turns, screenshots as base64), what is shown before
/// it goes, and how every answer of the server becomes a state with its code.
/// A stand-in server; nothing leaves the test.
void main() {
  const base = 'https://api.test/v1';
  final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]);

  AssistantService service(Future<http.Response> Function(http.Request r) handler, {String? token = 'tok'}) =>
      AssistantService(client: MockClient(handler), baseUrl: base, bearer: () async => token);

  http.Response json(int status, Map<String, dynamic> body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  test('the question goes redacted, with the sign-in, to POST /assistant/ask', () async {
    late http.Request seen;
    final s = service((r) async {
      seen = r;
      return json(200, {
        'status': 'ok',
        'answer': 'Open Settings, then Hosts.',
        'sources': ['https://docs.zestssh.com/features/hosts/', 'javascript:alert(1)', 'http://plain.example/'],
        'model': 'haiku',
        'escalated': false,
        'left_today': 7,
        'daily_limit': 10,
      });
    });
    final a = await s.ask(question: 'my password=hunter22 does not work on deploy@192.168.10.40');
    expect(seen.method, 'POST');
    expect(seen.url.toString(), '$base/assistant/ask');
    expect(seen.headers['Authorization'], 'Bearer tok');
    final body = jsonDecode(seen.body) as Map<String, dynamic>;
    expect(body['question'], isNot(contains('hunter22')));
    expect(body['question'], isNot(contains('192.168.10.40')));
    expect(body.containsKey('images'), isFalse);
    expect(a.text, 'Open Settings, then Hosts.');
    expect(a.model, 'haiku');
    expect(a.leftToday, 7);
    // Only https links come through.
    expect(a.sources.map((d) => d.url), ['https://docs.zestssh.com/features/hosts/']);
    expect(a.sources.single.name, 'Hosts');
  });

  test('the request: the last six turns, earlier questions redacted, screenshots as base64', () {
    final turns = [
      for (var i = 0; i < 5; i++) ...[AssistantTurn.user('q$i token=abcd$i'), AssistantTurn.astryx('a$i')],
    ];
    final r = AssistantService.request(question: 'now?', history: turns, images: [png]);
    final history = r['history'] as List;
    expect(history, hasLength(AssistantService.historyMax));
    expect((history.first as Map)['content'], isNot(contains('abcd2')));
    expect((history.last as Map), {'role': 'assistant', 'content': 'a4'});
    final images = r['images'] as List;
    expect((images.single as Map)['media_type'], 'image/png');
    expect(base64Decode((images.single as Map)['data'] as String), png);
  });

  test('the preview names a screenshot by its size, never spells it out', () {
    final preview = AssistantService.previewOf(AssistantService.request(question: 'why?', images: [png]));
    expect(preview, contains('<png, 1 KB, redacted>'));
    expect(preview, isNot(contains(base64Encode(png))));
    expect(preview, contains('"question": "why?"'));
  });

  test('no account on this device: nothing is sent', () async {
    var calls = 0;
    final s = service((r) async {
      calls++;
      return json(200, {});
    }, token: null);
    await expectLater(s.ask(question: 'q'),
        throwsA(isA<AssistantFailure>().having((f) => f.kind, 'kind', AssistantFailureKind.notSignedIn)));
    await expectLater(s.status(),
        throwsA(isA<AssistantFailure>().having((f) => f.kind, 'kind', AssistantFailureKind.notSignedIn)));
    expect(calls, 0);
  });

  test('the status says whether this account can ask, and why not', () async {
    final s = service((r) async {
      expect(r.url.toString(), '$base/assistant/status');
      return json(200, {
        'preview': true,
        'available': false,
        'reason': 'cap_reached',
        'daily_limit': 10,
        'left_today': 4,
        'resets_at': '2026-11-14T00:00:00.000Z',
        'cap_resets_at': '2026-12-01T00:00:00.000Z',
        'limits': {'images_max': 3, 'image_max_bytes': 2621440, 'question_max': 4000},
      });
    });
    final st = await s.status();
    expect(st.available, isFalse);
    expect(st.block, AssistantBlock.capReached);
    expect(st.leftToday, 4);
    expect(st.capResetsAt, DateTime.utc(2026, 12, 1));
  });

  test('every refusal of the server is a state with its own code', () async {
    final cases = <String, (int, AssistantFailureKind, ErrorCode)>{
      'assistant-off': (503, AssistantFailureKind.blocked, ErrorCodes.assistantOff),
      'assistant-paid-only': (403, AssistantFailureKind.blocked, ErrorCodes.assistantPaidOnly),
      'assistant-daily-limit': (429, AssistantFailureKind.blocked, ErrorCodes.assistantDailyLimit),
      'assistant-cap-reached': (503, AssistantFailureKind.blocked, ErrorCodes.assistantCapReached),
      'assistant-plan-unknown': (503, AssistantFailureKind.blocked, ErrorCodes.assistantPlanUnknown),
      'assistant-too-large': (413, AssistantFailureKind.refused, ErrorCodes.assistantRefused),
      'assistant-bad-image': (400, AssistantFailureKind.refused, ErrorCodes.assistantRefused),
      'assistant-busy': (429, AssistantFailureKind.busy, ErrorCodes.assistantBusy),
      'assistant-unreachable': (502, AssistantFailureKind.notAnswering, ErrorCodes.assistantNotAnswering),
      'assistant-timeout': (504, AssistantFailureKind.notAnswering, ErrorCodes.assistantNotAnswering),
      'assistant-failed': (502, AssistantFailureKind.notAnswering, ErrorCodes.assistantNotAnswering),
    };
    for (final MapEntry(key: code, value: (status, kind, errorCode)) in cases.entries) {
      final s = service((r) async => json(status, {'error': 'x', 'code': code}));
      try {
        await s.ask(question: 'q');
        fail('$code did not throw');
      } on AssistantFailure catch (f) {
        expect(f.kind, kind, reason: code);
        expect(f.code, errorCode, reason: code);
      }
    }
  });

  test('ZestSSH Cloud not answering, or failing, is said as the Cloud states are', () async {
    final down = service((r) async => throw const SocketException('connection refused'));
    try {
      await down.ask(question: 'q');
      fail('no throw');
    } on AssistantFailure catch (f) {
      expect(f.kind, AssistantFailureKind.cloud);
      expect(f.cloud, isNotNull);
      expect(f.code!.code, startsWith('ZS-11'));
    }
    final slow = service((r) => Completer<http.Response>().future.timeout(const Duration(milliseconds: 10)));
    await expectLater(slow.status(), throwsA(isA<AssistantFailure>().having((f) => f.kind, 'kind', AssistantFailureKind.cloud)));
    final broken = service((r) async => http.Response('<html>bad gateway</html>', 502));
    try {
      await broken.status();
      fail('no throw');
    } on AssistantFailure catch (f) {
      expect(f.kind, AssistantFailureKind.cloud);
      expect(f.cloud!.kind, isIn([CloudFailureKind.fault, CloudFailureKind.down]));
    }
  });

  test('a server from before 4.0 (404) reads as switched off; a sign-in that ran out as signed out', () async {
    final old = service((r) async => http.Response('Not found', 404));
    await expectLater(old.status(), throwsA(isA<AssistantFailure>().having((f) => f.block, 'block', AssistantBlock.off)));
    final expired = service((r) async => json(401, {'error': 'Sign in'}));
    await expectLater(
        expired.ask(question: 'q'), throwsA(isA<AssistantFailure>().having((f) => f.kind, 'kind', AssistantFailureKind.notSignedIn)));
  });

  test('a degraded answer carries the closest docs, https only', () {
    final a = AssistantAnswer.fromJson({
      'status': 'degraded',
      'answer': '',
      'docs': [
        {'title': 'Connection errors', 'url': 'https://docs.zestssh.com/troubleshooting/connection/', 'text': 'x'},
        {'title': 'Evil', 'url': 'file:///etc/passwd'},
      ],
    });
    expect(a.kind, AssistantAnswerKind.degraded);
    expect(a.docs.map((d) => d.name), ['Connection errors']);
  });
}
