import 'dart:convert';

import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';

/// What a ticket is. A support ticket is private: only the person and the
/// staff read it. A bug report or a suggestion is public: it is a forum post.
enum TicketType {
  support('support'),
  bug('bug'),
  suggestion('suggestion');

  const TicketType(this.wire);
  final String wire;

  static TicketType fromWire(Object? v) =>
      values.firstWhere((t) => t.wire == v, orElse: () => TicketType.support);
}

/// Local status values. `open` and `closed` are what the server says;
/// `gone` is this device noting that the server no longer has the ticket.
class TicketStatus {
  TicketStatus._();
  static const open = 'open';
  static const closed = 'closed';
  static const gone = 'gone';
}

/// Caps, the same as the server's (it refuses anything over them).
class TicketLimits {
  TicketLimits._();
  static const int titleMax = 200;
  static const int bodyMax = 4000;
  static const int contactMax = 254;

  /// Support tickets written offline and still waiting to be sent. Past
  /// this a new one is not kept (the form keeps the text).
  static const int maxWaiting = 5;

  /// Follow-ups waiting to be sent, per ticket.
  static const int maxWaitingReplies = 10;
}

/// One follow-up as the conversation shows it.
class TicketMessage {
  const TicketMessage({
    required this.id,
    required this.fromStaff,
    this.staffName,
    required this.body,
    required this.at,
    this.diagnostics,
    this.hasScreenshot = false,
  });

  final String id;
  final bool fromStaff;

  /// The name staff answered under. Null for the person's own messages.
  final String? staffName;
  final String body;
  final DateTime at;

  /// What the person attached to a follow-up of theirs (3.4): fresh
  /// diagnostics, and whether a redacted screenshot went with it.
  final String? diagnostics;
  final bool hasScreenshot;

  Map<String, dynamic> toJson() => {
        'id': id,
        'from': fromStaff ? 'staff' : 'user',
        if (staffName != null) 'name': staffName,
        'body': body,
        'at': at.toUtc().toIso8601String(),
        if (diagnostics != null) 'diagnostics': diagnostics,
        if (hasScreenshot) 'screenshot': true,
      };

  /// Null when the entry is not a message (the cache is this app's own, but
  /// a row that no longer parses must not wedge the screen).
  static TicketMessage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final body = raw['body'];
    final at = DateTime.tryParse('${raw['at'] ?? ''}');
    if (id is! String || id.isEmpty || body is! String || at == null) {
      return null;
    }
    final name = raw['name'];
    final diagnostics = raw['diagnostics'];
    return TicketMessage(
      id: id,
      fromStaff: raw['from'] == 'staff',
      staffName: name is String && name.isNotEmpty ? name : null,
      body: body,
      at: at,
      diagnostics: diagnostics is String && diagnostics.isNotEmpty ? diagnostics : null,
      hasScreenshot: raw['screenshot'] == true,
    );
  }
}

/// Where a ticket stands beyond open and closed, as the server says it (3.4):
/// who can see it, where a public report stands in the lists and how many said
/// "me too", why it was closed, and when support took it up. Kept with the
/// conversation, so it reads with no network.
class TicketStanding {
  const TicketStanding({
    this.private = false,
    this.state,
    this.stateVersion,
    this.votes = 0,
    this.publicId,
    this.listed = false,
    this.closedReason,
    this.pickedUpAt,
  });

  /// Only the person and support read it: a support ticket, or a bug report
  /// or an idea the person kept Private.
  final bool private;

  /// One of the states of the lists (planned, investigating, in_progress,
  /// fixed, shipped), or null.
  final String? state;
  final String? stateVersion;
  final int votes;

  /// The id the public lists show it under.
  final String? publicId;
  final bool listed;

  /// fixed, no_reply, user or staff.
  final String? closedReason;
  final DateTime? pickedUpAt;

  static const _states = {'planned', 'investigating', 'in_progress', 'fixed', 'shipped'};
  static const _reasons = {'fixed', 'no_reply', 'user', 'staff'};
  static final RegExp _version = RegExp(r'^[0-9A-Za-z.+-]{1,20}$');
  static final RegExp _publicId = RegExp(r'^[0-9a-f]{12}$');

  Map<String, dynamic> toJson() => {
        if (private) 'private': true,
        if (state != null) 'state': state,
        if (stateVersion != null) 'state_version': stateVersion,
        if (votes > 0) 'votes': votes,
        if (publicId != null) 'public_id': publicId,
        if (listed) 'listed': true,
        if (closedReason != null) 'closed_reason': closedReason,
        if (pickedUpAt != null) 'picked_up_at': pickedUpAt!.toUtc().toIso8601String(),
      };

  /// From what this app kept, or ([fromServer]) what the server answered:
  /// the server says who sees it as its visibility.
  static TicketStanding fromJson(Object? raw, {bool fromServer = false}) {
    if (raw is! Map) return const TicketStanding();
    final state = raw['state'];
    final version = raw['state_version'];
    final votes = raw['votes'];
    final publicId = raw['public_id'];
    final reason = raw['closed_reason'];
    return TicketStanding(
      private: fromServer ? raw['visibility'] == 'private' : raw['private'] == true,
      state: _states.contains(state) ? state as String : null,
      stateVersion: version is String && _version.hasMatch(version) ? version : null,
      votes: votes is int && votes > 0 ? votes : 0,
      publicId: publicId is String && _publicId.hasMatch(publicId) ? publicId : null,
      listed: raw['listed'] == true,
      closedReason: _reasons.contains(reason) ? reason as String : null,
      pickedUpAt: DateTime.tryParse('${raw['picked_up_at'] ?? ''}'),
    );
  }
}

/// A ticket's conversation: the opening text and the follow-ups, oldest
/// first. Kept as JSON in the ticket row so it reads with no network.
class TicketConversation {
  const TicketConversation({
    required this.body,
    this.expected,
    this.messages = const [],
    this.sentWith,
    this.accountIncluded = false,
    this.standing = const TicketStanding(),
    this.diagnostics,
    this.hasScreenshot = false,
  });

  /// The opening text, as the person wrote it.
  final String body;

  /// Bug reports: what the person expected.
  final String? expected;
  final List<TicketMessage> messages;

  /// The facts that went with it, as they were when it was sent: the Support
  /// Hub's details say them. Only this device knows them (the server does not
  /// tell them back), so a ticket sent before 3.3 has none.
  final FeedbackContext? sentWith;

  /// The person ticked "Include my account".
  final bool accountIncluded;

  /// Where it stands beyond open and closed (3.4).
  final TicketStanding standing;

  /// What "Include diagnostics" sent with it, and whether a redacted
  /// screenshot went with it (3.4).
  final String? diagnostics;
  final bool hasScreenshot;

  TicketConversation copyWith({
    List<TicketMessage>? messages,
    TicketStanding? standing,
    String? body,
    String? expected,
    String? diagnostics,
    bool? hasScreenshot,
  }) =>
      TicketConversation(
        body: body ?? this.body,
        expected: expected ?? this.expected,
        sentWith: sentWith,
        accountIncluded: accountIncluded,
        messages: messages ?? this.messages,
        standing: standing ?? this.standing,
        diagnostics: diagnostics ?? this.diagnostics,
        hasScreenshot: hasScreenshot ?? this.hasScreenshot,
      );

  TicketConversation withMessage(TicketMessage m) => copyWith(messages: [
        for (final e in messages)
          if (e.id != m.id) e,
        m,
      ]);

  String encode() => jsonEncode({
        'body': body,
        if (expected != null) 'expected': expected,
        'messages': [for (final m in messages) m.toJson()],
        if (sentWith != null) 'sent_with': sentWith!.toJson(),
        if (accountIncluded) 'account_included': true,
        'standing': standing.toJson(),
        if (diagnostics != null) 'diagnostics': diagnostics,
        if (hasScreenshot) 'screenshot': true,
      });

  static TicketConversation? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final expected = j['expected'];
      final sentWith = j['sent_with'];
      final diagnostics = j['diagnostics'];
      return TicketConversation(
        body: j['body'] is String ? j['body'] as String : '',
        expected: expected is String && expected.isNotEmpty ? expected : null,
        messages: [
          for (final m in (j['messages'] is List ? j['messages'] as List : const []))
            ?TicketMessage.fromJson(m),
        ],
        sentWith: sentWith is Map ? FeedbackContext.fromJson(sentWith.cast<String, dynamic>()) : null,
        accountIncluded: j['account_included'] == true,
        standing: TicketStanding.fromJson(j['standing']),
        diagnostics: diagnostics is String && diagnostics.isNotEmpty ? diagnostics : null,
        hasScreenshot: j['screenshot'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// How the app reads a ticket row.
extension SupportTicketRowX on SupportTicketRow {
  TicketType get ticketType => TicketType.fromWire(type);

  /// Only the person and the staff read it: a support ticket, or (3.4) a bug
  /// report or an idea the person kept Private.
  bool get isPrivate => ticketType == TicketType.support || (cachedConversation?.standing.private ?? false);

  /// Where it stands beyond open and closed (3.4).
  TicketStanding get standing => cachedConversation?.standing ?? const TicketStanding();

  /// It has reached the server.
  bool get isSent => serverId != null;

  /// Written offline and still to be sent.
  bool get isWaiting => serverId == null && sendError == null;

  /// It never reached the server and will not be tried again.
  bool get isRefused => serverId == null && sendError != null;

  bool get isOpen => isSent && status == TicketStatus.open;
  bool get isClosed => status == TicketStatus.closed;
  bool get isGone => status == TicketStatus.gone;

  /// Staff answered and the person has not had that answer on screen.
  bool get hasUnreadReply =>
      isSent &&
      !isGone &&
      lastMessageFrom == 'staff' &&
      lastMessageId != null &&
      lastMessageId != lastSeenMessageId;

  /// The forum tags of a public report ("Confirmed", "Planned", "Fixed").
  List<String> get tagNames {
    try {
      final j = jsonDecode(tags);
      if (j is! List) return const [];
      return [
        for (final t in j)
          if (t is String && t.isNotEmpty) t,
      ];
    } catch (_) {
      return const [];
    }
  }

  TicketConversation? get cachedConversation =>
      TicketConversation.decode(conversation);

  /// When something last happened on it.
  DateTime get lastActivity => DateTime.fromMillisecondsSinceEpoch(
      lastMessageAt ?? createdAt,
      isUtc: true);
}
