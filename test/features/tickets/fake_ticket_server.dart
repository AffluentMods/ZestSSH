import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The person's side of the ticket API (ZestSSH Cloud's routes/tickets.js
/// and lib/tickets.js), in memory: the same paths, the same shapes and the
/// same answers, so the app's ticket code can be driven without a server.
/// `ticket_contract_test.dart` runs the same flows against the real routes.
///
/// The staff side is a handful of methods ([staffReply], [staffClose], ...)
/// that change a ticket the way the dashboard would.
class FakeTicketServer {
  final Map<String, FakeTicket> tickets = {};
  final List<http.Request> requests = [];

  /// Every call fails as if there were no network.
  bool offline = false;

  /// Every call is answered with this status and nothing is done.
  int? failWith;

  /// The next call is carried out, and its answer never arrives.
  bool loseNextAnswer = false;

  /// A call carrying a screenshot or diagnostics is refused for them, as the
  /// server's limits on attachments refuse it (from a security review of 3.4):
  /// with this status, code and Retry-After. The words alone go.
  ({int status, String code, int retryAfter})? refuseAttachments;

  /// Whether [req] carries a screenshot or diagnostics.
  static bool attaches(http.Request req) {
    if (req.method != 'POST' || req.body.isEmpty) return false;
    final b = jsonDecode(req.body);
    if (b is! Map) return false;
    final d = b['diagnostics'];
    return b['screenshot'] != null || (d is String && d.trim().isNotEmpty);
  }

  /// The refusal [refuseAttachments] says for [req], or null.
  http.Response? attachmentsRefused(http.Request req) {
    final r = refuseAttachments;
    if (r == null || !attaches(req)) return null;
    return http.Response(jsonEncode({'error': 'Too many screenshots and diagnostics.', 'code': r.code}), r.status,
        headers: {'retry-after': '${r.retryAfter}', 'content-type': 'application/json'});
  }

  /// The next call is answered 200 with this body, whatever it asked.
  String? nextRawAnswer;

  /// The uid a bearer stands for; a bearer not listed is anonymous.
  final Map<String, String> bearers = {};

  /// Everyone's listed bug reports and ideas (3.4, routes/reports.js).
  final List<FakePublicReport> publicReports = [];

  int _number = 10000;
  int _message = 0;
  DateTime now = DateTime.utc(2026, 10, 1, 7);

  Future<http.Response> handle(http.Request req) async {
    requests.add(req);
    if (offline) throw const SocketException('offline');
    if (failWith != null) {
      return http.Response('{"error":"no"}', failWith!,
          headers: {'retry-after': '120'});
    }
    final refused = attachmentsRefused(req);
    if (refused != null) return refused;
    if (nextRawAnswer != null) {
      final raw = nextRawAnswer!;
      nextRawAnswer = null;
      return http.Response(raw, 200);
    }
    final res = _route(req);
    if (loseNextAnswer) {
      loseNextAnswer = false;
      throw const SocketException('the answer was lost');
    }
    return res;
  }

  http.Response _json(int status, Object body) => http.Response(
      jsonEncode(body), status,
      headers: {'content-type': 'application/json; charset=utf-8'});

  static final _notFound = {'error': 'Not found'};

  Map<String, dynamic> _body(http.Request req) {
    try {
      final j = jsonDecode(req.body);
      return j is Map ? j.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }

  http.Response _route(http.Request req) {
    final path = req.url.path;
    final reportsAt = path.indexOf('/reports');
    if (reportsAt >= 0) return _reports(req, path.substring(reportsAt + '/reports'.length));
    final at = path.indexOf('/tickets');
    if (at < 0) return _json(404, _notFound);
    final rest = path.substring(at + '/tickets'.length);
    if (rest.isEmpty && req.method == 'POST') return _create(req);
    if (rest == '/lookup' && req.method == 'POST') return _lookup(req);
    final parts = rest.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return _json(404, _notFound);
    final ticket = tickets[parts[0]];
    final token = req.headers['X-Ticket-Token'] ?? req.headers['x-ticket-token'];
    // An unknown ticket and a wrong token are the same answer.
    if (ticket == null || token == null || token != ticket.token) {
      return _json(404, _notFound);
    }
    if (parts.length == 1 && req.method == 'GET') {
      return _json(200, {
        'ticket': {
          ...ticket.forUser(),
          'body': ticket.body,
          'expected': ticket.expected,
          'diagnostics': ticket.diagnostics,
          'has_screenshot': ticket.screenshot != null,
        },
        'messages': [for (final m in ticket.messages) m.forUser()],
      });
    }
    if (parts.length == 2 && parts[1] == 'screenshot' && req.method == 'GET') {
      final png = ticket.screenshot;
      return png == null ? _json(404, _notFound) : http.Response.bytes(png, 200, headers: {'content-type': 'image/png'});
    }
    if (parts.length == 4 && parts[1] == 'messages' && parts[3] == 'screenshot' && req.method == 'GET') {
      final m = ticket.messages.where((m) => m.id == parts[2]).firstOrNull;
      final png = m?.screenshot;
      return png == null ? _json(404, _notFound) : http.Response.bytes(png, 200, headers: {'content-type': 'image/png'});
    }
    if (parts.length == 2 && parts[1] == 'messages' && req.method == 'POST') {
      return _message_(ticket, req);
    }
    if (parts.length == 2 && parts[1] == 'close' && req.method == 'POST') {
      if (ticket.status != 'closed') ticket.closedReason = _body(req)['fixed'] == true ? 'fixed' : 'user';
      ticket.status = 'closed';
      return _json(200, {'ticket': ticket.forUser()});
    }
    return _json(404, _notFound);
  }

  http.Response _create(http.Request req) {
    final b = _body(req);
    final title = '${b['title'] ?? ''}'.trim();
    final body = '${b['body'] ?? ''}'.trim();
    if (title.isEmpty || body.isEmpty) {
      return _json(400, {'error': 'A ticket needs a subject and a message.'});
    }
    final auth = req.headers['Authorization'] ?? req.headers['authorization'];
    final uid = auth != null && auth.startsWith('Bearer ')
        ? bearers[auth.substring(7)]
        : null;
    if (b['include_account'] == true && uid == null) {
      return _json(401, {'error': 'Sign in to include your account with the ticket.'});
    }
    final nonce = b['nonce'] as String?;
    final token = b['ticket_token'] as String?;
    if (nonce != null) {
      for (final t in tickets.values) {
        if (t.nonce != nonce) continue;
        if (t.token != token) {
          return _json(409, {'error': 'That ticket was already sent.'});
        }
        return _json(200, {'ticket': t.created()});
      }
    }
    final type = b['type'] is String ? b['type'] as String : 'support';
    final shot = b['screenshot'];
    final t = FakeTicket(
      id: 'tk_${(tickets.length + 1).toRadixString(16).padLeft(16, '0')}',
      number: ++_number,
      type: type,
      title: title,
      body: body,
      token: token ?? 'made-by-the-server',
      nonce: nonce,
      createdAt: now,
      context: b['context'] is Map ? (b['context'] as Map).cast() : const {},
      contact: b['contact'],
      account: b['include_account'] == true ? uid : null,
      expected: b['expected'] as String?,
      private: true,
    )
      ..diagnostics = b['diagnostics'] as String?
      ..screenshot = shot is String ? base64Decode(shot) : null;
    tickets[t.id] = t;
    return _json(201, {
      'ticket': t.created(),
      if (token == null) 'token': t.token,
    });
  }

  http.Response _lookup(http.Request req) {
    final b = _body(req);
    final asked = b['tickets'];
    if (asked is! List) return _json(400, {'error': 'tickets must be a list'});
    if (asked.length > 50) {
      return _json(400, {'error': 'At most 50 tickets at a time'});
    }
    return _json(200, {
      'tickets': [
        for (final p in asked)
          if (p is Map && tickets[p['id']]?.token == p['token'])
            tickets[p['id']]!.forUser(),
      ],
    });
  }

  http.Response _message_(FakeTicket t, http.Request req) {
    final b = _body(req);
    final body = '${b['body'] ?? ''}';
    if (body.trim().isEmpty || body.runes.length > 4000) {
      return _json(400, {'error': 'A message needs 1 to 4000 characters.'});
    }
    final nonce = b['nonce'] as String?;
    final ref = nonce == null ? null : 'app-$nonce';
    if (ref != null) {
      for (final m in t.messages) {
        if (m.ref == ref) return _json(200, {'message': m.forUser()});
      }
    }
    if (t.status == 'closed' && t.closedReason != 'no_reply') {
      return _json(409, {
        'error': 'This ticket is closed. Open a new one to write again.',
        'code': 'closed',
      });
    }
    final shot = b['screenshot'];
    final m = FakeMessage('m_${++_message}', false, null, body, now, ref)
      ..diagnostics = b['diagnostics'] as String?
      ..screenshot = shot is String ? base64Decode(shot) : null;
    t.messages.add(m);
    if (t.status == 'closed') {
      t.status = 'open';
      t.closedReason = null;
    }
    t.awaiting = 'staff';
    t.lastMessageAt = now;
    return _json(201, {'message': m.forUser()});
  }

  // ── The staff side ─────────────────────────────────────────────────

  /// A ticket the server made for a report (the feedback route does this).
  FakeTicket addReport({
    required String token,
    String type = 'bug',
    String title = 'Tabs overlap',
    String body = 'The third tab is drawn under the pill bar.',
    String? discordUrl = 'https://discord.com/channels/1/2',
  }) {
    final t = FakeTicket(
      id: 'tk_${(tickets.length + 1).toRadixString(16).padLeft(16, '0')}',
      number: ++_number,
      type: type,
      title: title,
      body: body,
      token: token,
      createdAt: now,
      discordUrl: discordUrl,
    );
    tickets[t.id] = t;
    return t;
  }

  FakeMessage staffReply(String id, String body, {String name = 'Robin'}) {
    final t = tickets[id]!;
    final m = FakeMessage('m_${++_message}', true, name, body, now, null);
    t.messages.add(m);
    t.awaiting = 'user';
    t.lastMessageAt = now;
    return m;
  }

  void staffClose(String id) => tickets[id]!.status = 'closed';

  /// What the server's clean-up does to a ticket that waited 14 days on the
  /// person (3.4).
  void quietClose(String id) => tickets[id]!
    ..status = 'closed'
    ..closedReason = 'no_reply';

  // ── Everyone's reports and +1 (3.4) ─────────────────────────────────

  FakePublicReport addPublic({
    required String id,
    String type = 'bug',
    required String title,
    String body = '',
    String? state,
    String? version,
    int votes = 0,
    int comments = 0,
    bool closed = false,
    DateTime? createdAt,
  }) {
    final r = FakePublicReport(id, type, title, body, state, version, votes, comments, closed, createdAt ?? now);
    publicReports.add(r);
    return r;
  }

  String? _uidOf(http.Request req) {
    final auth = req.headers['Authorization'] ?? req.headers['authorization'];
    if (auth == null || !auth.startsWith('Bearer ')) return null;
    return bearers[auth.substring(7)];
  }

  http.Response _reports(http.Request req, String rest) {
    final q = req.url.queryParameters;
    if (rest.isEmpty && req.method == 'GET') {
      final type = q['type'];
      final state = q['state'];
      var list = [
        for (final r in publicReports)
          if (r.type == type && (state == null ? (type == 'bug' || !r.closed) : r.state == state)) r,
      ];
      if (q['sort'] == 'new') {
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      } else {
        list.sort((a, b) => b.votes.compareTo(a.votes));
      }
      return _json(200, {'reports': [for (final r in list) r.toJson()]});
    }
    if (rest == '/similar' && req.method == 'GET') {
      final words = (q['q'] ?? '').toLowerCase().split(RegExp(r'\W+')).where((w) => w.length >= 4).toSet();
      final found = [
        for (final r in publicReports)
          if ((q['type'] == null || r.type == q['type']) &&
              words.where((w) => r.title.toLowerCase().contains(w.substring(0, 4))).length >= 2)
            r,
      ];
      return _json(200, {'reports': [for (final r in found) r.toJson()]});
    }
    // A +1 is the account's when a sign-in holds up, else this device's (its
    // guest id); no verified address is asked for (3.4).
    final uid = _uidOf(req);
    final device = req.headers['X-ZestSSH-Device'] ?? req.headers['x-zestssh-device'];
    final guest = device == null ? null : 'device:$device';
    final voter = uid ?? guest;
    if (voter == null) return _json(400, {'error': 'A +1 needs a sign-in or the id of this device.', 'code': 'no-voter'});
    if (rest == '/votes' && req.method == 'GET') {
      return _json(200, {
        'voted': [
          for (final r in publicReports)
            if (r.voters.contains(voter) || (guest != null && r.voters.contains(guest))) r.id,
        ],
      });
    }
    final m = RegExp(r'^/([0-9a-f]{12})/vote$').firstMatch(rest);
    final r = m == null ? null : publicReports.where((r) => r.id == m.group(1)).firstOrNull;
    if (r == null) return _json(404, {'error': 'That report is not listed.', 'code': 'not-listed'});
    if (req.method == 'POST') {
      if (r.closed) return _json(409, {'error': 'That report is closed.', 'code': 'closed'});
      // Signed in where this device gave a guest +1: it becomes the account's.
      if (uid != null && guest != null && r.voters.remove(guest)) r.votes--;
      if (r.voters.add(voter)) r.votes++;
    } else if (req.method == 'DELETE') {
      if (r.voters.remove(voter)) r.votes--;
      if (uid != null && guest != null && r.voters.remove(guest)) r.votes--;
    }
    return _json(200, {'id': r.id, 'votes': r.votes, 'voted': r.voters.contains(voter)});
  }
  void staffReopen(String id) => tickets[id]!.status = 'open';
  void staffTags(String id, List<String> tags) => tickets[id]!.tags = tags;

  /// What the purge does to a private ticket 90 days after it was closed.
  void delete(String id) => tickets.remove(id);

  /// The calls made so far whose path ends with [suffix].
  List<http.Request> calls(String suffix) =>
      [for (final r in requests) if (r.url.path.endsWith(suffix)) r];
}

class FakeTicket {
  FakeTicket({
    required this.id,
    required this.number,
    required this.type,
    required this.title,
    required this.body,
    required this.token,
    required this.createdAt,
    this.nonce,
    this.expected,
    this.context = const {},
    this.contact,
    this.account,
    this.discordUrl,
    this.private = false,
  }) : lastMessageAt = createdAt;

  /// A bug report or an idea the person kept Private (3.4), or support.
  final bool private;
  String? state;
  String? stateVersion;
  int votes = 0;
  String? closedReason;
  DateTime? pickedUpAt;
  String? diagnostics;
  List<int>? screenshot;

  final String id;
  final int number;
  final String type;
  final String title;
  final String body;
  final String token;
  final String? nonce;
  final String? expected;
  final Map<String, dynamic> context;
  final Object? contact;
  final String? account;
  final DateTime createdAt;
  String? discordUrl;
  String status = 'open';
  String? awaiting = 'staff';
  List<String> tags = [];
  DateTime lastMessageAt;
  final List<FakeMessage> messages = [];

  Map<String, dynamic> created() => {
        'id': id,
        'number': number,
        'status': status,
        'created_at': createdAt.toIso8601String(),
      };

  Map<String, dynamic> forUser() => {
        'id': id,
        'number': number,
        'type': type,
        'status': status,
        'awaiting': status == 'closed' ? null : awaiting,
        'title': title,
        'tags': tags,
        'discord_url': type == 'support' ? null : discordUrl,
        'created_at': createdAt.toIso8601String(),
        'last_message_at': lastMessageAt.toIso8601String(),
        'message_count': messages.length,
        'last_message_id': messages.isEmpty ? null : messages.last.id,
        'last_message_from':
            messages.isEmpty ? null : (messages.last.staff ? 'staff' : 'user'),
        'visibility': type == 'support' || private ? 'private' : 'public',
        'closed_at': null,
        'public_id': '0123456789ab',
        'listed': type != 'support' && !private,
        'state': state,
        'state_version': stateVersion,
        'votes': votes,
        'closed_reason': status == 'closed' ? closedReason : null,
        'picked_up_at': pickedUpAt?.toIso8601String(),
      };
}

/// Someone's listed bug report or idea, as the public lists show it.
class FakePublicReport {
  FakePublicReport(this.id, this.type, this.title, this.body, this.state, this.version, this.votes, this.comments,
      this.closed, this.createdAt);

  final String id;
  final String type;
  final String title;
  final String body;
  final String? state;
  final String? version;
  int votes;
  final int comments;
  final bool closed;
  final DateTime createdAt;
  final Set<String> voters = {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': null,
        'type': type,
        'title': title,
        'body': body,
        'state': state,
        'state_version': version,
        'votes': votes,
        'comments': comments,
        'closed': closed,
        'discord_url': null,
        'created_at': createdAt.toIso8601String(),
        'updated_at': createdAt.toIso8601String(),
        'closed_at': closed ? createdAt.toIso8601String() : null,
      };
}

class FakeMessage {
  FakeMessage(this.id, this.staff, this.name, this.body, this.at, this.ref);

  final String id;
  final bool staff;
  final String? name;
  final String body;
  final DateTime at;
  final String? ref;
  String? diagnostics;
  List<int>? screenshot;

  Map<String, dynamic> forUser() => {
        'id': id,
        'author': {'kind': staff ? 'staff' : 'user', 'name': staff ? name : null},
        'body': body,
        'created_at': at.toIso8601String(),
        'diagnostics': diagnostics,
        'has_screenshot': screenshot != null,
      };
}
