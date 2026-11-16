import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';

/// What the Support Hub's New report can say before anything is sent: which of
/// the reports this device already holds look like what is being written. It
/// looks at this device's own and nothing leaves it: there is no list of other
/// people's reports to ask (a server route the app does not have yet).

const _small = {
  'the', 'and', 'for', 'with', 'that', 'this', 'when', 'after', 'from', 'not', 'but', 'have', 'has', 'was', 'are',
  'you', 'can', 'does', 'doesn', 'did', 'didn', 'into', 'then', 'than', 'there', 'what', 'why', 'how', 'its', 'too',
};

Set<String> _wordsOf(String text) => text
    .toLowerCase()
    .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
    .where((w) => w.runes.length >= 3 && !_small.contains(w))
    .toSet();

/// The tickets of [kind] in [tickets] whose words are close to [typed], the
/// closest first, at most [limit]. Words shared with a ticket's subject and
/// opening text count: at least two of them, or the one where only that much
/// has been typed, and a quarter of what was typed.
List<SupportTicketRow> similarTickets(
  Iterable<SupportTicketRow> tickets,
  TicketType kind,
  String typed, {
  int limit = 3,
}) {
  final words = _wordsOf(typed);
  if (words.isEmpty) return const [];
  final needed = words.length <= 2 ? 1 : 2;
  final scored = <(SupportTicketRow, int)>[];
  for (final t in tickets) {
    if (t.ticketType != kind) continue;
    final theirs = _wordsOf('${t.title} ${t.cachedConversation?.body ?? ''}');
    final shared = words.intersection(theirs).length;
    if (shared >= needed && shared * 4 >= words.length) scored.add((t, shared));
  }
  scored.sort((a, b) {
    final byWords = b.$2.compareTo(a.$2);
    return byWords != 0 ? byWords : b.$1.lastActivity.compareTo(a.$1.lastActivity);
  });
  return [for (final (t, _) in scored.take(limit)) t];
}
