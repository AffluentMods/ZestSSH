import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_bearer.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/report_scrub.dart';
import 'package:zestssh/utils/type_name.dart';

// Ask Astryx (4.0, a named preview): one question to ZestSSH Cloud, which checks
// that the account is paid and has questions left today, and asks Astryx (Claude
// Haiku 5.5 first, Claude Sonnet 5.5 when it is unsure). No key of any AI service
// is in the app.
//
//   GET  /v1/assistant/status  -> whether this account can ask now, and how many are left
//   POST /v1/assistant/ask     {question, history, images} -> the answer and its doc links
//
// What leaves the device is what the person sees under "See exactly what is sent":
// the question and the earlier turns after ReportScrub (keys, tokens, passwords,
// host names, addresses, user names and folders replaced), and the screenshots the
// app took with recording mode on. Nothing is kept on the device either: the
// conversation lives in the open panel only.

/// Why Ask Astryx cannot answer now, as ZestSSH Cloud says it.
enum AssistantBlock {
  /// The preview is switched off (on the server or in Astryx).
  off,

  /// The account is not on a paid plan or a paid team seat.
  paidOnly,

  /// The plan could not be checked just now.
  planUnknown,

  /// This month's spending cap is reached: paused until the next month.
  capReached,

  /// Today's questions are used.
  dailyLimit,
}

AssistantBlock? _blockOf(String? reason) => switch (reason) {
      'off' => AssistantBlock.off,
      'free' => AssistantBlock.paidOnly,
      'plan_unknown' => AssistantBlock.planUnknown,
      'cap_reached' => AssistantBlock.capReached,
      'daily_limit' => AssistantBlock.dailyLimit,
      _ => null,
    };

/// What GET /v1/assistant/status said.
class AssistantStatus {
  const AssistantStatus({
    required this.available,
    this.block,
    required this.dailyLimit,
    required this.leftToday,
    this.resetsAt,
    this.capResetsAt,
    this.imagesMax = 3,
    this.imageMaxBytes = 2621440,
    this.questionMax = 4000,
  });

  final bool available;
  final AssistantBlock? block;
  final int dailyLimit;
  final int leftToday;
  final DateTime? resetsAt;
  final DateTime? capResetsAt;
  final int imagesMax;
  final int imageMaxBytes;
  final int questionMax;

  static AssistantStatus fromJson(Map<String, dynamic> j) {
    final limits = j['limits'] is Map<String, dynamic> ? j['limits'] as Map<String, dynamic> : const <String, dynamic>{};
    return AssistantStatus(
      available: j['available'] == true,
      block: _blockOf(j['reason'] as String?),
      dailyLimit: _int(j['daily_limit'], 10),
      leftToday: _int(j['left_today'], 0),
      resetsAt: _date(j['resets_at']),
      capResetsAt: _date(j['cap_resets_at']),
      imagesMax: _int(limits['images_max'], 3),
      imageMaxBytes: _int(limits['image_max_bytes'], 2621440),
      questionMax: _int(limits['question_max'], 4000),
    );
  }
}

/// A page of the docs an answer used, or one shown when Astryx could not answer.
class AssistantDoc {
  const AssistantDoc({required this.url, this.title = '', this.text = ''});

  final String url;
  final String title;
  final String text;

  /// The page's name: its title, or the last part of its address.
  String get name {
    if (title.isNotEmpty) return title;
    final parts = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
    if (parts.isEmpty) return url;
    final last = parts.last.replaceAll('-', ' ');
    return last.isEmpty ? url : '${last[0].toUpperCase()}${last.substring(1)}';
  }
}

/// One answer from POST /v1/assistant/ask.
class AssistantAnswer {
  const AssistantAnswer({
    required this.kind,
    required this.text,
    this.sources = const [],
    this.docs = const [],
    this.model,
    this.escalated = false,
    this.removedSecrets = const [],
    this.imageNote = '',
    this.imagesRefused = const [],
    this.imageSecrets = const [],
    this.imagesRead = false,
    this.leftToday,
    this.dailyLimit,
  });

  /// ok: an answer; declined: off-topic or a greeting; degraded: no model answered,
  /// [docs] holds the closest pages.
  final AssistantAnswerKind kind;
  final String text;
  final List<AssistantDoc> sources;
  final List<AssistantDoc> docs;

  /// 'haiku' or 'sonnet'.
  final String? model;
  final bool escalated;
  final List<String> removedSecrets;
  final String imageNote;
  final List<String> imagesRefused;
  final List<String> imageSecrets;
  final bool imagesRead;
  final int? leftToday;
  final int? dailyLimit;

  static AssistantAnswer fromJson(Map<String, dynamic> j) {
    final images = j['images'] is Map<String, dynamic> ? j['images'] as Map<String, dynamic> : const <String, dynamic>{};
    return AssistantAnswer(
      kind: switch (j['status']) {
        'declined' => AssistantAnswerKind.declined,
        'degraded' => AssistantAnswerKind.degraded,
        _ => AssistantAnswerKind.ok,
      },
      text: (j['answer'] as String? ?? '').trim(),
      sources: [
        for (final s in (j['sources'] as List? ?? const []))
          if (s is String && _isWebLink(s)) AssistantDoc(url: s),
      ],
      docs: [
        for (final d in (j['docs'] as List? ?? const []))
          if (d is Map<String, dynamic> && d['url'] is String && _isWebLink(d['url'] as String))
            AssistantDoc(url: d['url'] as String, title: d['title'] as String? ?? '', text: d['text'] as String? ?? ''),
      ],
      model: j['model'] is String ? j['model'] as String : null,
      escalated: j['escalated'] == true,
      removedSecrets: _strings(j['removed_secrets']),
      imageNote: images['note'] as String? ?? '',
      imagesRefused: _strings(images['refused']),
      imageSecrets: _strings(images['secrets']),
      imagesRead: images['read'] == true,
      leftToday: j['left_today'] is int ? j['left_today'] as int : null,
      dailyLimit: j['daily_limit'] is int ? j['daily_limit'] as int : null,
    );
  }
}

enum AssistantAnswerKind { ok, declined, degraded }

/// What went wrong when asking, if it was not an answer.
enum AssistantFailureKind {
  /// No account on this device (or its sign-in ran out).
  notSignedIn,

  /// ZestSSH Cloud said no ([AssistantFailure.block] says why).
  blocked,

  /// The question or a picture was refused (too large, not a picture).
  refused,

  /// Too many questions in a few minutes.
  busy,

  /// ZestSSH Cloud answered, but Astryx did not ([AssistantFailure.code] ZS-1966).
  notAnswering,

  /// ZestSSH Cloud or the way to it ([AssistantFailure.cloud]).
  cloud,
}

class AssistantFailure implements Exception, HasTypeName {
  const AssistantFailure(this.kind, {this.block, this.cloud, this.resetsAt, this.status, this.serverCode});

  final AssistantFailureKind kind;
  final AssistantBlock? block;
  final CloudFailure? cloud;
  final DateTime? resetsAt;
  final int? status;
  final String? serverCode;

  /// The code the person is shown with the message; null when signing in is all it takes.
  ErrorCode? get code => switch (kind) {
        AssistantFailureKind.notSignedIn => null,
        AssistantFailureKind.cloud => cloud?.code ?? ErrorCodes.cloudNotResponding,
        AssistantFailureKind.refused => ErrorCodes.assistantRefused,
        AssistantFailureKind.busy => ErrorCodes.assistantBusy,
        AssistantFailureKind.notAnswering => ErrorCodes.assistantNotAnswering,
        AssistantFailureKind.blocked => switch (block) {
            AssistantBlock.off => ErrorCodes.assistantOff,
            AssistantBlock.paidOnly => ErrorCodes.assistantPaidOnly,
            AssistantBlock.planUnknown => ErrorCodes.assistantPlanUnknown,
            AssistantBlock.capReached => ErrorCodes.assistantCapReached,
            AssistantBlock.dailyLimit => ErrorCodes.assistantDailyLimit,
            null => ErrorCodes.assistantOff,
          },
      };

  @override
  String get typeName => 'AssistantFailure';

  @override
  String toString() => 'AssistantFailure($kind${block == null ? '' : ' $block'}'
      '${status == null ? '' : ' HTTP $status'}${serverCode == null ? '' : ' $serverCode'})';
}

/// One earlier turn of the conversation.
class AssistantTurn {
  const AssistantTurn.user(this.content) : fromAstryx = false;
  const AssistantTurn.astryx(this.content) : fromAstryx = true;

  final String content;
  final bool fromAstryx;

  Map<String, String> toJson() => {'role': fromAstryx ? 'assistant' : 'user', 'content': content};
}

/// GET /v1/assistant/status and POST /v1/assistant/ask with this device's sign-in.
class AssistantService {
  AssistantService({http.Client? client, String? baseUrl, Future<String?> Function()? bearer})
      : _client = client ?? PinnedHttpClient.client,
        base = baseUrl ?? defaultBase,
        _bearer = bearer ?? accountBearer;

  static String get defaultBase => kZestApiBase;

  /// Astryx may take a minute on a hard question with pictures (the server waits 90 s).
  static const askTimeout = Duration(seconds: 100);
  static const statusTimeout = Duration(seconds: 15);

  /// Earlier turns sent with a follow-up; Astryx reads at most six.
  static const historyMax = 6;

  /// The longest question ZestSSH Cloud takes.
  static const questionMax = 4000;

  final http.Client _client;
  final String base;
  final Future<String?> Function() _bearer;

  /// The request for [question], exactly as it is sent: the words after ReportScrub,
  /// the last [historyMax] turns, and [images] as base64. The preview shows this.
  static Map<String, dynamic> request({
    required String question,
    List<AssistantTurn> history = const [],
    List<Uint8List> images = const [],
  }) {
    final turns = history.length > historyMax ? history.sublist(history.length - historyMax) : history;
    return {
      'question': ReportScrub.scrub(question.trim()),
      'history': [
        for (final t in turns)
          {'role': t.fromAstryx ? 'assistant' : 'user', 'content': t.fromAstryx ? t.content : ReportScrub.scrub(t.content)},
      ],
      if (images.isNotEmpty) 'images': [for (final png in images) {'media_type': 'image/png', 'data': base64Encode(png)}],
    };
  }

  /// [request] as the person reads it: the pictures named by size, not spelled out.
  static String previewOf(Map<String, dynamic> request) {
    final shown = Map<String, dynamic>.of(request);
    final images = shown['images'];
    if (images is List) {
      shown['images'] = [
        for (final i in images)
          '<png, ${((base64Decode((i as Map)['data'] as String).length) / 1024).ceil()} KB, redacted>',
      ];
    }
    return const JsonEncoder.withIndent('  ').convert(shown);
  }

  Future<Map<String, String>> _headers() async {
    final token = await _bearer();
    if (token == null) throw const AssistantFailure(AssistantFailureKind.notSignedIn);
    return {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      ...DeviceSessionHeader.headers,
    };
  }

  /// Whether this account can ask now. Throws [AssistantFailure].
  Future<AssistantStatus> status() async {
    final headers = await _headers();
    final http.Response r;
    try {
      r = await _client.get(Uri.parse('$base/assistant/status'), headers: headers).timeout(statusTimeout);
    } catch (e) {
      throw AssistantFailure(AssistantFailureKind.cloud, cloud: cloudFailureOf(e) ?? cloudNoAnswerNow());
    }
    final body = _json(r.body);
    if (r.statusCode == 200 && body != null) return AssistantStatus.fromJson(body);
    throw _failureOf(r.statusCode, body);
  }

  /// One question. Throws [AssistantFailure]; never returns half an answer.
  Future<AssistantAnswer> ask({
    required String question,
    List<AssistantTurn> history = const [],
    List<Uint8List> images = const [],
  }) async {
    final headers = await _headers();
    final payload = request(question: question, history: history, images: images);
    final http.Response r;
    try {
      r = await _client
          .post(Uri.parse('$base/assistant/ask'), headers: headers, body: jsonEncode(payload))
          .timeout(askTimeout);
    } catch (e) {
      throw AssistantFailure(AssistantFailureKind.cloud, cloud: cloudFailureOf(e) ?? cloudNoAnswerNow());
    }
    final body = _json(r.body);
    if (r.statusCode == 200 && body != null) return AssistantAnswer.fromJson(body);
    throw _failureOf(r.statusCode, body);
  }

  static AssistantFailure _failureOf(int status, Map<String, dynamic>? body) {
    final code = body?['code'] as String?;
    final resets = _date(body?['resets_at']);
    AssistantFailure blocked(AssistantBlock b) =>
        AssistantFailure(AssistantFailureKind.blocked, block: b, resetsAt: resets, status: status, serverCode: code);
    switch (code) {
      case 'assistant-off':
        return blocked(AssistantBlock.off);
      case 'assistant-paid-only':
        return blocked(AssistantBlock.paidOnly);
      case 'assistant-plan-unknown':
        return blocked(AssistantBlock.planUnknown);
      case 'assistant-daily-limit':
        return blocked(AssistantBlock.dailyLimit);
      case 'assistant-cap-reached':
        return blocked(AssistantBlock.capReached);
      case 'assistant-bad-request':
      case 'assistant-too-large':
      case 'assistant-bad-image':
        return AssistantFailure(AssistantFailureKind.refused, status: status, serverCode: code);
      case 'assistant-busy':
        return AssistantFailure(AssistantFailureKind.busy, status: status, serverCode: code);
      case 'assistant-unreachable':
      case 'assistant-timeout':
      case 'assistant-failed':
        return AssistantFailure(AssistantFailureKind.notAnswering, status: status, serverCode: code);
    }
    if (status == 401) return const AssistantFailure(AssistantFailureKind.notSignedIn, status: 401);
    if (status == 429) return AssistantFailure(AssistantFailureKind.busy, status: status);
    if (status == 413) return AssistantFailure(AssistantFailureKind.refused, status: status);
    if (status == 404) {
      // A server from before 4.0 has no such route: Astryx is not there yet.
      return AssistantFailure(AssistantFailureKind.blocked, block: AssistantBlock.off, status: status);
    }
    if (status >= 500) {
      return AssistantFailure(
        AssistantFailureKind.cloud,
        cloud: cloudFailureOf(Exception('HTTP $status'), status: status),
        status: status,
      );
    }
    return AssistantFailure(AssistantFailureKind.refused, status: status, serverCode: code);
  }
}

Map<String, dynamic>? _json(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

int _int(Object? v, int fallback) => v is int ? v : fallback;

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

List<String> _strings(Object? v) => [for (final s in (v is List ? v : const [])) if (s is String) s];

bool _isWebLink(String s) {
  final u = Uri.tryParse(s);
  return u != null && u.scheme == 'https' && u.host.isNotEmpty;
}

final assistantServiceProvider = Provider<AssistantService>((ref) => AssistantService());

/// Whether this account can ask now; asked again when the panel opens.
final assistantStatusProvider = FutureProvider.autoDispose<AssistantStatus>(
  (ref) => ref.watch(assistantServiceProvider).status(),
);
