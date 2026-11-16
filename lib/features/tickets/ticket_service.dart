import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/tickets/attachment_refusal.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_token.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_bearer.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// What happened to something the person tried to send.
enum TicketSendOutcome {
  /// The server has it.
  sent,

  /// The server could not be reached. It is kept on this device and sent
  /// later.
  queued,

  /// One of the server's limits fired. Not kept: the text stays in the form.
  rateLimited,

  /// The account may not open tickets. Not kept.
  blocked,

  /// "Include my account" was ticked and no account is signed in.
  needsSignIn,

  /// A follow-up on a ticket that is closed.
  closed,

  /// The server no longer has the ticket.
  gone,

  /// Too much is already waiting to be sent from this device.
  tooManyWaiting,

  /// The server refused it for good (malformed, too long).
  rejected,
}

class TicketSendResult {
  const TicketSendResult(this.outcome,
      {this.retryMinutes, this.nonce, this.number, this.leftBehind = false, this.attachments});
  final TicketSendOutcome outcome;

  /// Refused for what was attached (a screenshot, diagnostics), not for the
  /// words: they go without it ([AttachmentRefusal]). Null otherwise.
  final AttachmentRefusal? attachments;

  /// A follow-up kept to send later went without the screenshot and the
  /// diagnostics it was to carry: only its words wait on this device.
  final bool leftBehind;

  /// For a new ticket the server took: the number it gave it, said with "Sent"
  /// as the proof it arrived. Null where the
  /// server gave none, and for anything that was not sent.
  final int? number;

  /// For [TicketSendOutcome.rateLimited]: how long to wait.
  final int? retryMinutes;

  /// The ticket this was about (a new ticket's own nonce).
  final String? nonce;

  bool get delivered => outcome == TicketSendOutcome.sent;
}

/// What a refresh found.
class TicketRefresh {
  const TicketRefresh({required this.reached, this.replies = const []});

  /// The server answered (or there was nothing to ask it).
  final bool reached;

  /// Tickets with an answer from support that was not announced before.
  final List<SupportTicketRow> replies;
}

/// A way to reach the person outside the app, typed by hand. Never
/// prefilled from the account.
class TicketContact {
  const TicketContact.email(this.value);
  final String value;

  Map<String, String> toJson() => {'kind': 'email', 'value': value};
}

typedef _Bearer = Future<String?> Function();

class _Answer {
  const _Answer(this.status, this.body, [this.retryAfter, this.caught]);

  /// The HTTP status, or 0 when the server could not be reached.
  final int status;
  final Map<String, dynamic>? body;
  final int? retryAfter;

  /// What was caught, where nothing answered.
  final Object? caught;

  /// What stopped the request, for whoever says how ZestSSH Cloud stands:
  /// what was caught, or the status it was answered with, in words.
  Object get stopped => caught ?? 'HTTP $status';

  bool get ok => status >= 200 && status < 300;

  /// Trying again later can work: no answer, a server error, or a limit.
  bool get transient => status == 0 || status >= 500 || status == 429;

  int get retryMinutes =>
      retryAfter == null ? 60 : (retryAfter! / 60).ceil().clamp(1, 24 * 60);
}

const _uuid = Uuid();

/// The largest ticket number taken from the server: far past any real count,
/// and inside a signed 32-bit int, as the number column and every screen hold.
const int kMaxTicketNumber = 0x7fffffff;

/// The tickets this device has sent, and everything the app does with them:
/// keeping the ticket a report became, opening a private support ticket,
/// reading the answers and writing back.
///
/// Who may read a ticket is whoever holds its token (see [TicketToken]); the
/// token lives only in the encrypted database on this device. Reading,
/// answering and closing carry the token and nothing else: no account, no
/// install id. Opening a ticket carries the account bearer when one is
/// signed in, exactly as a report does: the server uses it to limit abuse
/// and stores it only if the person ticked "include my account".
///
/// Nothing is asked of the server while this device holds no ticket.
class TicketService {
  TicketService(
    this._db, {
    http.Client? client,
    Future<String?> Function()? bearer,
    DateTime Function()? now,
    String? baseUrl,
  })  : _client = client,
        _bearer = bearer,
        _now = now ?? DateTime.now,
        base = baseUrl ?? defaultBase;

  final AppDatabase _db;
  final http.Client? _client;
  final _Bearer? _bearer;
  final DateTime Function() _now;

  static String get defaultBase => kZestApiBase;

  /// Where the API is. Only tests name another one.
  final String base;

  static const Duration _timeout = Duration(seconds: 20);

  /// How many tickets one lookup may ask about (the server's cap).
  static const int lookupChunk = 50;

  static final RegExp _idShape = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  /// The ticket whose conversation is on screen: an answer on it is read
  /// there and then, so it is not announced.
  String? viewing;

  /// What stopped the last read of the tickets ([refresh], [open]) where it
  /// did not get through: what was caught where nothing answered, or the
  /// status of the answer in words ("HTTP 503"). Null where the read got
  /// through, or asked nothing. For the screens, which say why what they
  /// show is what was read last.
  Object? readStopped;

  http.Client get _http => _client ?? PinnedHttpClient.client;

  // ── What this device holds ─────────────────────────────────────────

  /// Every ticket, latest activity first.
  Stream<List<SupportTicketRow>> watchTickets() =>
      _db.select(_db.supportTickets).watch().map((rows) => [...rows]
        ..sort((a, b) => b.lastActivity.compareTo(a.lastActivity)));

  Stream<SupportTicketRow?> watchTicket(String nonce) =>
      (_db.select(_db.supportTickets)..where((t) => t.nonce.equals(nonce)))
          .watchSingleOrNull();

  /// The follow-ups of one ticket that are still to be sent (or could not
  /// be), oldest first.
  Stream<List<TicketOutboxRow>> watchOutbox(String ticketNonce) =>
      (_db.select(_db.ticketOutbox)
            ..where((t) => t.ticketNonce.equals(ticketNonce))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch();

  Future<SupportTicketRow?> ticket(String nonce) =>
      (_db.select(_db.supportTickets)..where((t) => t.nonce.equals(nonce)))
          .getSingleOrNull();

  Future<List<SupportTicketRow>> _sent() =>
      (_db.select(_db.supportTickets)..where((t) => t.serverId.isNotNull()))
          .get();

  /// Whether any ticket here is open on the server: the only time the app
  /// keeps asking for answers while it runs.
  Future<bool> hasOpenTickets() async =>
      (await _sent()).any((t) => t.status == TicketStatus.open);

  /// Whether anything is waiting to be sent.
  Future<bool> hasWaiting() async {
    final tickets = await (_db.select(_db.supportTickets)
          ..where((t) => t.serverId.isNull() & t.sendError.isNull()))
        .get();
    if (tickets.isNotEmpty) return true;
    final replies = await (_db.select(_db.ticketOutbox)
          ..where((t) => t.error.isNull()))
        .get();
    return replies.isNotEmpty;
  }

  Future<void> _write(String nonce, SupportTicketsCompanion change) =>
      (_db.update(_db.supportTickets)..where((t) => t.nonce.equals(nonce)))
          .write(change);

  // ── Calls ──────────────────────────────────────────────────────────

  Future<_Answer> _call(
    String method,
    String path, {
    Map<String, String> headers = const {},
    Map<String, dynamic>? body,
  }) async {
    try {
      final uri = Uri.parse('$base$path');
      final all = {'Content-Type': 'application/json', ...headers};
      final resp = await (method == 'GET'
              ? _http.get(uri, headers: all)
              : _http.post(uri,
                  headers: all, body: jsonEncode(body ?? const {})))
          .timeout(_timeout);
      Map<String, dynamic>? json;
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map) json = decoded.cast<String, dynamic>();
      } catch (_) {
        json = null;
      }
      return _Answer(resp.statusCode, json,
          int.tryParse(resp.headers['retry-after'] ?? ''));
    } catch (e) {
      // Offline, a timeout, a TLS pin failure: all "not reached".
      AppLogger.warning('Ticket call not delivered: ${errorKind(e)}');
      return _Answer(0, null, null, e);
    }
  }

  Map<String, String> _proof(SupportTicketRow row) =>
      {'X-Ticket-Token': row.token};

  // ── Keeping the ticket a report became ─────────────────────────────

  /// A report the server took is a ticket from now on: keep it, so its
  /// status and the staff's answers can be read here. A report already kept
  /// (the server answered a retry) is left as it is.
  Future<void> keepReport(FeedbackReport report,
      {required String id, int? number}) async {
    final token = report.ticketToken;
    if (!_idShape.hasMatch(id)) return;
    final expected = report.expected?.trim();
    await _db.into(_db.supportTickets).insert(
          SupportTicketsCompanion.insert(
            nonce: report.nonce,
            serverId: Value(id),
            number: Value(number),
            token: token,
            type: report.type.wire,
            title: report.threadTitle,
            awaiting: const Value('staff'),
            createdAt: report.createdAt.millisecondsSinceEpoch,
            conversation: Value(TicketConversation(
              body: report.body.trim(),
              expected:
                  expected == null || expected.isEmpty ? null : expected,
              sentWith: report.context,
              diagnostics: report.diagnostics,
              hasScreenshot: report.screenshotPng != null,
            ).encode()),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  // ── A new support ticket ───────────────────────────────────────────

  /// The request a support ticket is sent with. Also what the form's
  /// "see exactly what is sent" shows (with the token left out by
  /// [previewOf]).
  static Map<String, dynamic> supportRequest({
    TicketType type = TicketType.support,
    required String title,
    required String body,
    String? expected,
    required FeedbackContext context,
    TicketContact? contact,
    required bool includeAccount,
    required String nonce,
    required String token,
    String? diagnostics,
    Uint8List? screenshot,
  }) =>
      {
        // 3.4: a bug report or an idea the person kept Private goes here too.
        if (type != TicketType.support) 'type': type.wire,
        'title': title.trim(),
        'body': body.trim(),
        if (expected != null && expected.trim().isNotEmpty) 'expected': expected.trim(),
        'context': context.toJson(),
        'contact': contact?.toJson(),
        'include_account': includeAccount,
        'nonce': nonce,
        'ticket_token': token,
        if (diagnostics != null && diagnostics.trim().isNotEmpty) 'diagnostics': diagnostics,
        if (screenshot != null && type == TicketType.bug) 'screenshot': base64Encode(screenshot),
      };

  /// [request] as readable JSON, with the token named instead of shown: it
  /// is a secret, and the preview is the kind of thing that gets pasted
  /// into a chat. A screenshot is said as its size.
  static String previewOf(Map<String, dynamic> request) {
    final shot = request['screenshot'];
    return const JsonEncoder.withIndent('  ').convert({
      ...request,
      if (request.containsKey('ticket_token'))
        'ticket_token': TicketToken.preview,
      if (shot is String) 'screenshot': '<png, ${(shot.length * 3 / 4 / 1024).round()} KB>',
    });
  }

  /// Opens a private support ticket. Never throws.
  ///
  /// Reached: the ticket is kept with the server's id. Not reached: it is
  /// kept as waiting and sent later. Refused: nothing is kept, and the form
  /// still holds the text.
  Future<TicketSendResult> createSupport({
    required String title,
    required String body,
    required FeedbackContext context,
    TicketContact? contact,
    bool includeAccount = false,
  }) =>
      createPrivate(
        type: TicketType.support,
        title: title,
        body: body,
        context: context,
        contact: contact,
        includeAccount: includeAccount,
      );

  /// Opens a private ticket: a support one, or (3.4) a bug report or an idea
  /// the person kept Private, with the redacted screenshot and the
  /// diagnostics they chose to attach. Never reaches Discord. Never throws;
  /// what is kept and refused is as [createSupport] says.
  Future<TicketSendResult> createPrivate({
    required TicketType type,
    required String title,
    required String body,
    String? expected,
    required FeedbackContext context,
    TicketContact? contact,
    bool includeAccount = false,
    String? diagnostics,
    Uint8List? screenshot,
  }) async {
    final nonce = _uuid.v4();
    final token = TicketToken.generate();
    final request = supportRequest(
      type: type,
      title: title,
      body: body,
      expected: expected,
      context: context,
      contact: contact,
      includeAccount: includeAccount,
      nonce: nonce,
      token: token,
      diagnostics: diagnostics,
      screenshot: screenshot,
    );
    final answer = await _postSupport(request);
    final refusal = _refusalOf(answer);
    if (refusal != null) {
      return TicketSendResult(refusal,
          retryMinutes: answer.retryMinutes, attachments: AttachmentRefusal.of(answer.status, answer.body));
    }
    final created = answer.ok ? _createdOf(answer) : null;
    if (created == null) {
      // Not reached (or an answer that makes no sense): keep it and try
      // later, unless too much is waiting already.
      final waiting = await (_db.select(_db.supportTickets)
            ..where((t) => t.serverId.isNull()))
          .get();
      if (waiting.length >= TicketLimits.maxWaiting) {
        return const TicketSendResult(TicketSendOutcome.tooManyWaiting);
      }
    }
    await _db.into(_db.supportTickets).insert(SupportTicketsCompanion.insert(
          nonce: nonce,
          serverId: Value(created?.$1),
          number: Value(created?.$2),
          token: token,
          type: type.wire,
          title: title.trim(),
          awaiting: const Value('staff'),
          createdAt: _now().millisecondsSinceEpoch,
          conversation: Value(TicketConversation(
            body: body.trim(),
            expected: expected == null || expected.trim().isEmpty ? null : expected.trim(),
            sentWith: context,
            accountIncluded: includeAccount,
            standing: const TicketStanding(private: true),
            diagnostics: request['diagnostics'] as String?,
            hasScreenshot: request.containsKey('screenshot'),
          ).encode()),
          pending: Value(created == null ? jsonEncode(request) : null),
        ));
    return TicketSendResult(
      created == null ? TicketSendOutcome.queued : TicketSendOutcome.sent,
      nonce: nonce,
      number: created?.$2,
    );
  }

  Future<_Answer> _postSupport(Map<String, dynamic> request) async {
    final headers = <String, String>{};
    final bearer = await _bearer?.call();
    if (bearer != null && bearer.isNotEmpty) {
      headers['Authorization'] = 'Bearer $bearer';
      headers.addAll(DeviceSessionHeader.headers);
    }
    return _call('POST', '/tickets', headers: headers, body: request);
  }

  /// Why the server will never take this ticket, or null when it took it or
  /// may take it later.
  TicketSendOutcome? _refusalOf(_Answer a) {
    if (a.ok || a.transient && a.status != 429) return null;
    return switch (a.status) {
      429 => TicketSendOutcome.rateLimited,
      401 => TicketSendOutcome.needsSignIn,
      403 => TicketSendOutcome.blocked,
      _ => TicketSendOutcome.rejected,
    };
  }

  /// The (id, number) in the answer to a new ticket, or null.
  (String, int?)? _createdOf(_Answer a) {
    final t = a.body?['ticket'];
    if (t is! Map) return null;
    final id = t['id'];
    if (id is! String || !_idShape.hasMatch(id)) return null;
    final n = t['number'];
    // A ticket number is a whole number the server counts up from 1: anything
    // else is no number, and the person is told "Sent." without one. A double
    // such as 1e400 (Infinity once parsed) made toInt() throw after the ticket
    // was made, so it was not kept here and was sent again (found in a
    // security review).
    return (id, n is int && n > 0 && n <= kMaxTicketNumber ? n : null);
  }

  // ── Reading ────────────────────────────────────────────────────────

  /// Asks the server how the tickets here stand. One call per fifty
  /// tickets, and none at all when this device holds no ticket.
  ///
  /// A ticket the server leaves out of a good answer is no longer there
  /// (a private ticket is deleted 90 days after it was closed): it is
  /// marked gone, and kept here with what was last read.
  Future<TicketRefresh> refresh() async {
    readStopped = null;
    final rows = await _sent();
    rows.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
    final replies = <SupportTicketRow>[];
    for (var i = 0; i < rows.length; i += lookupChunk) {
      final chunk = rows.skip(i).take(lookupChunk).toList();
      final answer = await _call('POST', '/tickets/lookup', body: {
        'tickets': [
          for (final r in chunk) {'id': r.serverId, 'token': r.token},
        ],
      });
      final list = answer.body?['tickets'];
      if (answer.status != 200 || list is! List) {
        readStopped = answer.stopped;
        return TicketRefresh(reached: false, replies: replies);
      }
      final byId = <String, Map>{
        for (final t in list)
          if (t is Map && t['id'] is String) t['id'] as String: t,
      };
      for (final row in chunk) {
        final t = byId[row.serverId];
        if (t == null) {
          if (!row.isGone) {
            await _write(row.nonce,
                const SupportTicketsCompanion(status: Value(TicketStatus.gone)));
          }
          continue;
        }
        await _write(row.nonce, _fromServer(row, t));
        final now = await ticket(row.nonce);
        if (now == null) continue;
        if (now.hasUnreadReply && now.lastMessageId != now.notifiedMessageId) {
          await _write(row.nonce,
              SupportTicketsCompanion(notifiedMessageId: Value(now.lastMessageId)));
          if (row.nonce != viewing) replies.add(now);
        }
      }
    }
    return TicketRefresh(reached: true, replies: replies);
  }

  /// The change a ticket as the server tells it makes to [row].
  SupportTicketsCompanion _fromServer(SupportTicketRow row, Map t) {
    final number = t['number'];
    final title = t['title'];
    final awaiting = t['awaiting'];
    final lastId = t['last_message_id'];
    final lastFrom = t['last_message_from'];
    final count = t['message_count'];
    final lastAt = DateTime.tryParse('${t['last_message_at'] ?? ''}');
    return SupportTicketsCompanion(
      number: Value(number is num ? number.toInt() : row.number),
      status: Value(
          t['status'] == 'closed' ? TicketStatus.closed : TicketStatus.open),
      awaiting:
          Value(awaiting == 'staff' || awaiting == 'user' ? awaiting as String : null),
      title: Value(title is String && title.trim().isNotEmpty
          ? _cut(title.trim(), TicketLimits.titleMax)
          : row.title),
      tags: Value(jsonEncode(_tagsOf(t['tags']))),
      // A support ticket has no place in Discord, whatever the answer says.
      discordUrl: Value(row.isPrivate ? null : discordLinkOf(t['discord_url'])),
      lastMessageAt: Value(lastAt?.millisecondsSinceEpoch ?? row.lastMessageAt),
      messageCount:
          Value(count is num && count >= 0 ? count.toInt() : row.messageCount),
      lastMessageId: Value(lastId is String && lastId.isNotEmpty ? lastId : null),
      lastMessageFrom:
          Value(lastFrom == 'staff' || lastFrom == 'user' ? lastFrom as String : null),
      // Where it stands (3.4), only where the server says: one from before
      // says nothing, and nothing kept is touched.
      conversation: t.containsKey('visibility') ? Value(_withStanding(row, t).encode()) : const Value.absent(),
    );
  }

  /// [row]'s conversation with where it stands as the server says it (3.4).
  /// A server from before 3.4 says nothing of it: what was known is kept, and
  /// a support ticket is private whatever the answer.
  TicketConversation _withStanding(SupportTicketRow row, Map t, [TicketConversation? base]) {
    final c = base ?? row.cachedConversation ?? const TicketConversation(body: '');
    if (!t.containsKey('visibility')) return c;
    final standing = TicketStanding.fromJson(t, fromServer: true);
    return c.copyWith(
      standing: row.ticketType == TicketType.support && !standing.private
          ? TicketStanding.fromJson({...t, 'visibility': 'private'}, fromServer: true)
          : standing,
    );
  }

  static String _cut(String s, int max) {
    final runes = s.runes;
    return runes.length <= max ? s : String.fromCharCodes(runes.take(max));
  }

  static List<String> _tagsOf(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final t in raw) {
      if (t is! String) continue;
      final name = _cut(t.trim(), 50);
      if (name.isNotEmpty && !out.contains(name)) out.add(name);
      if (out.length >= 20) break;
    }
    return out;
  }

  /// The forum post of a public report, when it really is a Discord link.
  /// The app opens this in the browser, so nothing else is taken.
  static String? discordLinkOf(Object? raw) {
    if (raw is! String || raw.length > 300) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (host != 'discord.com' && !host.endsWith('.discord.com')) return null;
    return uri.toString();
  }

  /// Reads one ticket's conversation and keeps it for reading offline.
  /// [seen] marks the newest follow-up as read (the conversation is on
  /// screen). Returns whether the server answered; when it did not, what
  /// was read last is still there.
  Future<bool> open(String nonce, {bool seen = true}) async {
    readStopped = null;
    final row = await ticket(nonce);
    if (row == null) return false;
    final id = row.serverId;
    if (id == null) return false;
    final answer = await _call('GET', '/tickets/$id', headers: _proof(row));
    if (answer.status == 404) {
      await _write(nonce,
          const SupportTicketsCompanion(status: Value(TicketStatus.gone)));
      return true;
    }
    final t = answer.body?['ticket'];
    final raw = answer.body?['messages'];
    if (answer.status != 200 || t is! Map || raw is! List) {
      readStopped = answer.stopped;
      return false;
    }
    final messages = <TicketMessage>[
      for (final m in raw) ?_messageOf(m),
    ];
    final old = row.cachedConversation;
    final body = t['body'];
    final expected = t['expected'];
    final diagnostics = t['diagnostics'];
    final conversation = _withStanding(
      row,
      t,
      TicketConversation(
        body: body is String && body.isNotEmpty ? body : (old?.body ?? ''),
        expected: expected is String && expected.isNotEmpty
            ? expected
            : old?.expected,
        messages: messages,
        sentWith: old?.sentWith,
        accountIncluded: old?.accountIncluded ?? false,
        standing: old?.standing ?? const TicketStanding(),
        diagnostics: diagnostics is String && diagnostics.isNotEmpty ? diagnostics : old?.diagnostics,
        hasScreenshot: t['has_screenshot'] == true || (old?.hasScreenshot ?? false),
      ),
    );
    final last = messages.isEmpty ? null : messages.last.id;
    await _write(
      nonce,
      _fromServer(row, t).copyWith(
        conversation: Value(conversation.encode()),
        lastSeenMessageId: seen ? Value(last) : const Value.absent(),
        notifiedMessageId: seen ? Value(last) : const Value.absent(),
      ),
    );
    return true;
  }

  /// One follow-up as the server tells it, or null.
  TicketMessage? _messageOf(Object? m) {
    if (m is! Map) return null;
    final id = m['id'];
    final body = m['body'];
    final at = DateTime.tryParse('${m['created_at'] ?? ''}');
    if (id is! String || id.isEmpty || body is! String || at == null) {
      return null;
    }
    final author = m['author'];
    final staff = author is Map && author['kind'] == 'staff';
    final name = author is Map ? author['name'] : null;
    final diagnostics = m['diagnostics'];
    return TicketMessage(
      id: id,
      fromStaff: staff,
      staffName: staff && name is String && name.trim().isNotEmpty
          ? _cut(name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim(), 80)
          : null,
      body: body,
      at: at,
      diagnostics: !staff && diagnostics is String && diagnostics.isNotEmpty ? diagnostics : null,
      hasScreenshot: !staff && m['has_screenshot'] == true,
    );
  }

  /// The newest follow-up has been on screen.
  Future<void> markSeen(String nonce) async {
    final row = await ticket(nonce);
    if (row == null || row.lastMessageId == row.lastSeenMessageId) return;
    await _write(nonce,
        SupportTicketsCompanion(lastSeenMessageId: Value(row.lastMessageId)));
  }

  // ── Writing back ───────────────────────────────────────────────────

  /// Sends a follow-up. Not reached: it is kept and sent later, and shown
  /// in the conversation as waiting. Refused: nothing is kept, the reply
  /// box still holds the text.
  Future<TicketSendResult> reply(String nonce, String text,
      {Uint8List? screenshot, String? diagnostics}) async {
    final row = await ticket(nonce);
    final body = text.trim();
    if (row == null ||
        row.serverId == null ||
        body.isEmpty ||
        body.runes.length > TicketLimits.bodyMax) {
      return const TicketSendResult(TicketSendOutcome.rejected);
    }
    final messageNonce = _uuid.v4();
    final writtenAt = _now();
    final attached = screenshot != null || (diagnostics != null && diagnostics.trim().isNotEmpty);
    final result = await _postReply(row, messageNonce, body,
        screenshot: screenshot, diagnostics: diagnostics);
    if (result.outcome != TicketSendOutcome.queued) return result;
    final waiting = await (_db.select(_db.ticketOutbox)
          ..where((t) => t.ticketNonce.equals(nonce)))
        .get();
    if (waiting.length >= TicketLimits.maxWaitingReplies) {
      return const TicketSendResult(TicketSendOutcome.tooManyWaiting);
    }
    await _db.into(_db.ticketOutbox).insert(TicketOutboxCompanion.insert(
          nonce: messageNonce,
          ticketNonce: nonce,
          body: body,
          createdAt: writtenAt.millisecondsSinceEpoch,
        ));
    // Only the words wait here: a picture and a log are retaken when they are
    // wanted again, never kept on the device to go later.
    return TicketSendResult(result.outcome, leftBehind: attached);
  }

  Future<TicketSendResult> _postReply(
      SupportTicketRow row, String messageNonce, String body,
      {Uint8List? screenshot, String? diagnostics}) async {
    final answer = await _call(
      'POST',
      '/tickets/${row.serverId}/messages',
      headers: _proof(row),
      body: {
        'body': body,
        'nonce': messageNonce,
        if (diagnostics != null && diagnostics.trim().isNotEmpty) 'diagnostics': diagnostics,
        if (screenshot != null) 'screenshot': base64Encode(screenshot),
      },
    );
    if (answer.ok) {
      final message = _messageOf(answer.body?['message']);
      if (message == null) {
        // Taken, but the answer cannot be read: the next read shows it.
        return TicketSendResult(TicketSendOutcome.sent, nonce: row.nonce);
      }
      final now = await ticket(row.nonce);
      final conversation =
          (now?.cachedConversation ?? const TicketConversation(body: ''))
              .withMessage(message);
      await _write(
        row.nonce,
        SupportTicketsCompanion(
          conversation: Value(conversation.encode()),
          // Taken, so open: one closed for want of a reply opens again by
          // being written on (3.4).
          status: const Value(TicketStatus.open),
          awaiting: const Value('staff'),
          lastMessageId: Value(message.id),
          lastMessageFrom: const Value('user'),
          lastSeenMessageId: Value(message.id),
          lastMessageAt: Value(message.at.millisecondsSinceEpoch),
          messageCount: Value(conversation.messages.length),
        ),
      );
      return TicketSendResult(TicketSendOutcome.sent, nonce: row.nonce);
    }
    final attachments = AttachmentRefusal.of(answer.status, answer.body);
    if (attachments != null) {
      return TicketSendResult(
          attachments == AttachmentRefusal.full ? TicketSendOutcome.rejected : TicketSendOutcome.rateLimited,
          retryMinutes: answer.retryMinutes,
          attachments: attachments);
    }
    switch (answer.status) {
      case 409:
        await _write(row.nonce,
            const SupportTicketsCompanion(
                status: Value(TicketStatus.closed), awaiting: Value(null)));
        return const TicketSendResult(TicketSendOutcome.closed);
      case 404:
        await _write(row.nonce,
            const SupportTicketsCompanion(status: Value(TicketStatus.gone)));
        return const TicketSendResult(TicketSendOutcome.gone);
      case 429:
        return TicketSendResult(TicketSendOutcome.rateLimited,
            retryMinutes: answer.retryMinutes);
    }
    if (answer.transient) return const TicketSendResult(TicketSendOutcome.queued);
    return const TicketSendResult(TicketSendOutcome.rejected);
  }

  /// Closes the ticket; [fixed] is "Fixed now, close it" (3.4). Returns
  /// whether the server took it.
  Future<bool> close(String nonce, {bool fixed = false}) async {
    final row = await ticket(nonce);
    if (row == null || row.serverId == null) return false;
    final answer = await _call('POST', '/tickets/${row.serverId}/close',
        headers: _proof(row), body: fixed ? const {'fixed': true} : null);
    if (answer.status == 404) {
      await _write(nonce,
          const SupportTicketsCompanion(status: Value(TicketStatus.gone)));
      return true;
    }
    final t = answer.body?['ticket'];
    if (answer.status != 200 || t is! Map) return false;
    await _write(nonce, _fromServer(row, t));
    return true;
  }

  /// The redacted screenshot the person attached to ticket [nonce], or to its
  /// follow-up [messageId]; null where there is none or it cannot be read now.
  /// Read with the ticket's token only, and kept in memory by whoever shows it.
  Future<Uint8List?> screenshot(String nonce, {String? messageId}) async {
    final row = await ticket(nonce);
    final id = row?.serverId;
    if (row == null || id == null) return null;
    if (messageId != null && !_idShape.hasMatch(messageId)) return null;
    try {
      final path = messageId == null ? '/tickets/$id/screenshot' : '/tickets/$id/messages/$messageId/screenshot';
      final resp = await _http.get(Uri.parse('$base$path'), headers: _proof(row)).timeout(_timeout);
      final bytes = resp.bodyBytes;
      final png = bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47;
      return resp.statusCode == 200 && png ? bytes : null;
    } catch (e) {
      AppLogger.warning('Ticket screenshot not read: ${errorKind(e)}');
      return null;
    }
  }

  /// Removes a ticket from this device: the row, its token and anything
  /// still waiting to be sent on it. The server's copy is not touched, and
  /// without the token it cannot be read from here again.
  Future<void> forget(String nonce) async {
    await _db.transaction(() async {
      await (_db.delete(_db.ticketOutbox)
            ..where((t) => t.ticketNonce.equals(nonce)))
          .go();
      await (_db.delete(_db.supportTickets)
            ..where((t) => t.nonce.equals(nonce)))
          .go();
    });
  }

  /// Drops a follow-up that is waiting or could not be sent.
  Future<void> discardFollowUp(String messageNonce) =>
      (_db.delete(_db.ticketOutbox)..where((t) => t.nonce.equals(messageNonce)))
          .go();

  // ── What is waiting ────────────────────────────────────────────────

  /// Tries everything that is waiting once: support tickets written
  /// offline first, then follow-ups, oldest first. Returns how many were
  /// delivered. What the server refuses for good is marked and not tried
  /// again; its text stays readable so it can be copied.
  Future<int> retryPending() async {
    var delivered = 0;
    final tickets = await (_db.select(_db.supportTickets)
          ..where((t) =>
              t.serverId.isNull() & t.pending.isNotNull() & t.sendError.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    for (final row in tickets) {
      Map<String, dynamic> request;
      try {
        request = (jsonDecode(row.pending!) as Map).cast<String, dynamic>();
      } catch (_) {
        await _write(row.nonce,
            const SupportTicketsCompanion(sendError: Value('rejected')));
        continue;
      }
      final answer = await _postSupport(request);
      final created = answer.ok ? _createdOf(answer) : null;
      if (created != null) {
        delivered++;
        await _write(
          row.nonce,
          SupportTicketsCompanion(
            serverId: Value(created.$1),
            number: Value(created.$2),
            pending: const Value(null),
          ),
        );
        continue;
      }
      if (answer.transient || answer.ok) continue;
      await _write(
        row.nonce,
        SupportTicketsCompanion(
          sendError: Value(switch (answer.status) {
            401 => 'account',
            403 => 'blocked',
            _ => 'rejected',
          }),
        ),
      );
    }

    final replies = await (_db.select(_db.ticketOutbox)
          ..where((t) => t.error.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    for (final item in replies) {
      final row = await ticket(item.ticketNonce);
      if (row == null) {
        await discardFollowUp(item.nonce);
        continue;
      }
      if (row.serverId == null) continue;
      final result = await _postReply(row, item.nonce, item.body);
      switch (result.outcome) {
        case TicketSendOutcome.sent:
          delivered++;
          await discardFollowUp(item.nonce);
        case TicketSendOutcome.queued:
        case TicketSendOutcome.rateLimited:
          break;
        case TicketSendOutcome.closed:
          await _markFollowUp(item.nonce, 'closed');
        case TicketSendOutcome.gone:
          await _markFollowUp(item.nonce, 'gone');
        case TicketSendOutcome.blocked:
        case TicketSendOutcome.needsSignIn:
        case TicketSendOutcome.tooManyWaiting:
        case TicketSendOutcome.rejected:
          await _markFollowUp(item.nonce, 'rejected');
      }
    }
    return delivered;
  }

  Future<void> _markFollowUp(String messageNonce, String error) =>
      (_db.update(_db.ticketOutbox)..where((t) => t.nonce.equals(messageNonce)))
          .write(TicketOutboxCompanion(error: Value(error)));

  /// A ticket the server refused, to be tried again because the person asked
  /// (what stood in the way can have changed: they signed in, the account is
  /// allowed again). Returns whether it is waiting again; [retryPending] sends
  /// it.
  Future<bool> retryRefused(String nonce) async {
    final row = await ticket(nonce);
    if (row == null || row.serverId != null || row.pending == null) {
      return false;
    }
    await _write(nonce, const SupportTicketsCompanion(sendError: Value(null)));
    return true;
  }

  /// A waiting ticket that was refused because the account was to be
  /// included and nobody is signed in: send it without the account after
  /// all. Returns whether it is waiting again.
  Future<bool> retryWithoutAccount(String nonce) async {
    final row = await ticket(nonce);
    if (row == null || row.serverId != null || row.pending == null) {
      return false;
    }
    try {
      final request = (jsonDecode(row.pending!) as Map).cast<String, dynamic>();
      request['include_account'] = false;
      await _write(
        nonce,
        SupportTicketsCompanion(
          pending: Value(jsonEncode(request)),
          sendError: const Value(null),
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

final ticketServiceProvider = Provider<TicketService>((ref) =>
    TicketService(ref.watch(treeDatabaseProvider), bearer: accountBearer));

/// Every ticket this device holds, latest activity first. Empty while the
/// database is locked.
final ticketsProvider = StreamProvider<List<SupportTicketRow>>((ref) {
  if (!ref.watch(dbReadyProvider)) return Stream.value(const []);
  return ref.watch(ticketServiceProvider).watchTickets();
});

/// One ticket, as it changes. Null when it is not on this device.
final ticketProvider =
    StreamProvider.autoDispose.family<SupportTicketRow?, String>((ref, nonce) {
  if (!ref.watch(dbReadyProvider)) return Stream.value(null);
  return ref.watch(ticketServiceProvider).watchTicket(nonce);
});

/// The follow-ups of one ticket that are waiting to be sent, or could not be.
final ticketOutboxProvider = StreamProvider.autoDispose
    .family<List<TicketOutboxRow>, String>((ref, nonce) {
  if (!ref.watch(dbReadyProvider)) return Stream.value(const []);
  return ref.watch(ticketServiceProvider).watchOutbox(nonce);
});

/// How many tickets have an answer from support that has not been read.
final ticketUnreadCountProvider = Provider<int>((ref) =>
    ref.watch(ticketsProvider).valueOrNull?.where((t) => t.hasUnreadReply).length ??
    0);
