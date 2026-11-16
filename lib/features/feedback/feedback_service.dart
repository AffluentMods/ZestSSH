import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/tickets/attachment_refusal.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account_bearer.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/utils/error_kind.dart';

/// What happened to a report the user tried to send.
enum FeedbackOutcome {
  /// Accepted by the server: posted, deduplicated, or queued on the server
  /// for a Discord retry. All the same to the user: it is out of their hands.
  sent,

  /// Could not reach the server; the report is saved and retried on launch.
  queued,

  /// The client cooldown or one of the server's limits fired.
  rateLimited,

  /// The account is blocked from submitting (spec 6). Not retried.
  blocked,

  /// The server rejected the report for good (malformed, too large). Not
  /// retried; the clipboard fallback is offered.
  rejected,
}

class FeedbackSendResult {
  const FeedbackSendResult(this.outcome,
      {this.retryMinutes, this.ticketId, this.ticketNumber, this.attachments});
  final FeedbackOutcome outcome;

  /// Refused for the screenshot or the diagnostics it carried, not for its
  /// words, which go without them ([AttachmentRefusal]). Null otherwise.
  final AttachmentRefusal? attachments;

  /// For [FeedbackOutcome.rateLimited]: how long to wait.
  final int? retryMinutes;

  /// For [FeedbackOutcome.sent]: the ticket the report became, when the
  /// server said so. Null when it did not (a duplicate of a report sent in
  /// the last day, or a server from before tickets).
  final String? ticketId;
  final int? ticketNumber;
}

/// The account bearer to attach when the user happens to be signed in
/// (spec 1: used by the server for rate limiting and blocking only, never
/// shown in Discord). Null = anonymous, which is the default and works.
typedef BearerLoader = Future<String?> Function();

/// Called when the server has turned a report into a ticket, so it can be
/// kept and its answers read in the app.
typedef TicketKeeper = Future<void> Function(FeedbackReport report,
    {required String id, int? number});

/// Sends reports to `POST /v1/feedback` and never loses one (spec 3b):
/// a report that cannot be delivered is queued and retried on the next
/// launch, and the form always offers "copy to clipboard" as well.
///
/// The queue lives in the encrypted database ([FeedbackQueue]), not in
/// preferences: a bug report is free text that routinely names hosts, and
/// the vault is the only place such text is allowed to rest. Preferences
/// hold nothing but the cooldown timestamp.
///
/// Submitting needs no account. Nothing in the payload identifies the
/// device; a report can be tied to a person only through a Discord handle
/// they typed.
///
/// Since tickets: a report the server takes becomes a ticket, and the app
/// keeps it ([TicketKeeper]) so the person can read the staff's answer in
/// the app. What ties the two together is the report's ticket token, a
/// random secret made for that one report and kept on this device. It says
/// nothing about the account or the install.
class FeedbackService {
  FeedbackService(this._db, this._prefs,
      {http.Client? client,
      BearerLoader? bearer,
      TicketKeeper? onTicket,
      String? baseUrl})
      : _client = client,
        _bearer = bearer,
        _onTicket = onTicket,
        _base = baseUrl ?? base;

  final AppDatabase _db;
  final SharedPreferences _prefs;
  final http.Client? _client;
  final BearerLoader? _bearer;
  final TicketKeeper? _onTicket;

  /// Where the API is. Only tests name another one.
  final String _base;

  static String get base => kZestApiBase;

  /// Where the queue lived before schema v35 (plaintext preferences). Read
  /// once by [retryQueued], moved into the database, then deleted.
  static const String legacyQueueKey = 'feedback_queue_v1';
  static const String lastSentKey = 'feedback_last_sent_at';

  /// Client-side cooldown between reports. The server has its own limits;
  /// this one just keeps an accidental double-click from being a double post.
  static const Duration cooldown = Duration(minutes: 2);

  /// Queued reports beyond this are dropped oldest-first, so a broken network
  /// cannot grow the table without bound.
  static const int maxQueued = 5;

  static const Duration _timeout = Duration(seconds: 20);

  http.Client get _http => _client ?? PinnedHttpClient.client;

  Uri get _endpoint => Uri.parse('$_base/feedback');

  /// Minutes left on the client cooldown, or 0 when a report may be sent.
  int cooldownMinutesLeft({DateTime? now}) {
    final last = _prefs.getInt(lastSentKey);
    if (last == null) return 0;
    final elapsed = (now ?? DateTime.now())
        .difference(DateTime.fromMillisecondsSinceEpoch(last));
    if (elapsed >= cooldown) return 0;
    return (cooldown - elapsed).inMinutes + 1;
  }

  /// Send one report. Never throws.
  Future<FeedbackSendResult> send(FeedbackReport report) async {
    final wait = cooldownMinutesLeft();
    if (wait > 0) {
      return FeedbackSendResult(FeedbackOutcome.rateLimited,
          retryMinutes: wait);
    }
    final result = await _post(report);
    switch (result.outcome) {
      case FeedbackOutcome.sent:
        await _prefs.setInt(
            lastSentKey, DateTime.now().millisecondsSinceEpoch);
      case FeedbackOutcome.queued:
        await _enqueue(report);
      case FeedbackOutcome.rateLimited:
      case FeedbackOutcome.blocked:
      case FeedbackOutcome.rejected:
        break;
    }
    return result;
  }

  Future<Map<String, String>> _headers() async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      // This build keeps the ticket a report becomes, so the server may
      // tell staff that an answer will be read in the app.
      'X-ZestSSH-Tickets': '1',
    };
    final token = await _bearer?.call();
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
      headers.addAll(DeviceSessionHeader.headers);
    }
    return headers;
  }

  Future<FeedbackSendResult> _post(FeedbackReport report) async {
    try {
      final resp = await _http
          .post(_endpoint,
              headers: await _headers(), body: jsonEncode(report.toJson()))
          .timeout(_timeout);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return await _keepTicket(report, resp.body);
      }
      if (resp.statusCode == 429) {
        final retryAfter = int.tryParse(resp.headers['retry-after'] ?? '');
        Object? body;
        try {
          body = jsonDecode(resp.body);
        } catch (_) {
          body = null;
        }
        return FeedbackSendResult(FeedbackOutcome.rateLimited,
            retryMinutes: retryAfter == null ? 60 : (retryAfter / 60).ceil(),
            attachments: AttachmentRefusal.of(429, body));
      }
      if (resp.statusCode == 403) {
        return const FeedbackSendResult(FeedbackOutcome.blocked);
      }
      if (resp.statusCode >= 400 && resp.statusCode < 500) {
        AppLogger.warning('Feedback rejected: HTTP ${resp.statusCode}');
        return const FeedbackSendResult(FeedbackOutcome.rejected);
      }
      AppLogger.warning('Feedback not accepted: HTTP ${resp.statusCode}');
      return const FeedbackSendResult(FeedbackOutcome.queued);
    } on SocketException catch (_) {
      return const FeedbackSendResult(FeedbackOutcome.queued);
    } catch (e) {
      // Timeouts, TLS pin failures, anything else transient: keep the text.
      AppLogger.warning('Feedback send error: ${errorKind(e)}');
      return const FeedbackSendResult(FeedbackOutcome.queued);
    }
  }

  /// The report was taken. When the answer names the ticket it became, the
  /// ticket is kept; a report is sent either way, so nothing here may fail
  /// it.
  Future<FeedbackSendResult> _keepTicket(
      FeedbackReport report, String answer) async {
    String? id;
    int? number;
    try {
      final j = jsonDecode(answer);
      final t = j is Map ? j['ticket'] : null;
      if (t is Map && t['id'] is String) {
        id = t['id'] as String;
        number = t['number'] is num ? (t['number'] as num).toInt() : null;
      }
    } catch (_) {
      id = null;
    }
    if (id != null && _onTicket != null) {
      try {
        await _onTicket(report, id: id, number: number);
      } catch (e) {
        AppLogger.warning('Could not keep the ticket: ${errorKind(e)}');
      }
    }
    return FeedbackSendResult(FeedbackOutcome.sent,
        ticketId: id, ticketNumber: number);
  }

  // ── Queue (encrypted database) ─────────────────────────────────────

  /// The reports still waiting to be sent, oldest first, as they change:
  /// what My tickets shows above the tickets that did arrive.
  Stream<List<FeedbackReport>> watchQueued() =>
      (_db.select(_db.feedbackQueue)
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch()
          .map((rows) {
        final out = <FeedbackReport>[];
        for (final row in rows) {
          try {
            out.add(FeedbackReport.fromJson(
                (jsonDecode(row.payload) as Map).cast<String, dynamic>()));
          } catch (_) {
            // Dropped by the next retry; not shown.
          }
        }
        return out;
      });

  /// Queued reports, oldest first. A row that no longer parses is deleted
  /// rather than wedging every retry.
  Future<List<FeedbackReport>> queued() async {
    final rows = await (_db.select(_db.feedbackQueue)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    final out = <FeedbackReport>[];
    for (final row in rows) {
      try {
        out.add(FeedbackReport.fromJson(
            (jsonDecode(row.payload) as Map).cast<String, dynamic>()));
      } catch (_) {
        await _remove(row.nonce);
      }
    }
    return out;
  }

  Future<void> _enqueue(FeedbackReport report) async {
    await _db.into(_db.feedbackQueue).insertOnConflictUpdate(
          FeedbackQueueCompanion.insert(
            nonce: report.nonce,
            // The screenshot is dropped on purpose: it is the only large
            // part, and a report that already failed once should never be
            // what fills the database.
            payload: jsonEncode({
              ...report.toJson(includeScreenshot: false),
              'createdAt': report.createdAt.toIso8601String(),
            }),
            createdAt: report.createdAt.millisecondsSinceEpoch,
          ),
        );
    await _trim();
  }

  Future<void> _trim() async {
    final rows = await (_db.select(_db.feedbackQueue)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    if (rows.length <= maxQueued) return;
    for (final row in rows.take(rows.length - maxQueued)) {
      await _remove(row.nonce);
    }
  }

  Future<void> _remove(String nonce) => (_db.delete(_db.feedbackQueue)
        ..where((t) => t.nonce.equals(nonce)))
      .go();

  /// The pre-v35 queue lived in preferences. Move anything still there into
  /// the database, then delete the plaintext copy. Runs once.
  Future<void> _importLegacyQueue() async {
    final raw = _prefs.getStringList(legacyQueueKey);
    if (raw == null) return;
    for (final s in raw) {
      try {
        await _enqueue(FeedbackReport.fromJson(
            (jsonDecode(s) as Map).cast<String, dynamic>()));
      } catch (_) {
        // A corrupt entry is not worth keeping.
      }
    }
    await _prefs.remove(legacyQueueKey);
  }

  /// Retry every queued report once. Called on launch. Returns how many were
  /// delivered. A report the server rejects or refuses is dropped (it will
  /// never succeed); a transient failure keeps it for next time.
  Future<int> retryQueued() async {
    await _importLegacyQueue();
    final list = await queued();
    if (list.isEmpty) return 0;
    var delivered = 0;
    for (final r in list) {
      final res = await _post(r);
      switch (res.outcome) {
        case FeedbackOutcome.sent:
          delivered++;
          await _remove(r.nonce);
        case FeedbackOutcome.rejected:
        case FeedbackOutcome.blocked:
          await _remove(r.nonce);
        case FeedbackOutcome.queued:
        case FeedbackOutcome.rateLimited:
          break;
      }
    }
    return delivered;
  }
}

final feedbackServiceProvider = Provider<FeedbackService>((ref) =>
    FeedbackService(
        ref.watch(treeDatabaseProvider), ref.watch(sharedPreferencesProvider),
        bearer: accountBearer,
        onTicket: (report, {required id, number}) => ref
            .read(ticketServiceProvider)
            .keepReport(report, id: id, number: number)));

/// The reports this device still has to send. Empty while the database is
/// locked.
final queuedReportsProvider = StreamProvider<List<FeedbackReport>>((ref) {
  if (!ref.watch(dbReadyProvider)) return Stream.value(const []);
  return ref.watch(feedbackServiceProvider).watchQueued();
});
