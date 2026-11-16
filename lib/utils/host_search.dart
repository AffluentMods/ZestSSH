import 'package:zestssh/database/daos/connections_dao.dart';

/// Whether host [c] matches the search [query]: its name, its address, the
/// user it signs in as, or its group, ignoring case. An empty query matches
/// every host.
bool hostMatchesQuery(ConnectionWithDetails c, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  bool has(String? s) => s != null && s.toLowerCase().contains(q);
  return has(c.connection.label) || has(c.connection.host) || has(c.identity?.username) || has(c.group?.name);
}
