import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/utils/host_address.dart';

/// The host the session [sessionId] works on, as the editor tells hosts
/// apart ([EditorHost.saved]): the space its host is kept in, its id there
/// and the account it signs in as. A session the app does not know (a pane
/// handed a connection with no session behind it), or whose space is not
/// known, is a host of its own ([EditorHost.unknown]): its files never share
/// a tab, and keep no draft.
EditorHost editorHostOfSession(WidgetRef ref, String sessionId) =>
    editorHostOf(ref.read(activeSessionsProvider.notifier), ref.read(activeSessionsProvider)[sessionId], sessionId);

/// [editorHostOfSession] from what it reads.
EditorHost editorHostOf(ActiveSessionsNotifier sessions, SessionState? state, String sessionId) {
  final connectionId = state?.connectionId;
  if (connectionId == null) return EditorHost.unknown();
  final space = sessions.spaceOfConnection(connectionId);
  return switch (space) {
    TreeSpace() => EditorHost.saved(connectionId: connectionId, account: sessions.accountOf(sessionId)),
    OrchardSpace(:final orchardId) =>
      EditorHost.saved(team: orchardId, connectionId: connectionId, account: sessions.accountOf(sessionId)),
    null => EditorHost.unknown(),
  };
}

/// The saved hosts shown as [label] (their own label, else `host:port`, as
/// a session names its host), in Personal and in every team open on this
/// device, as (team, connection id): a draft kept under a label before
/// drafts named the host by its id is put back only where this is one host,
/// and that host is the file's.
typedef EditorLabelOwners = Future<List<({String? team, String connectionId})>> Function(String label);

final editorLabelOwnersProvider = Provider<EditorLabelOwners>((ref) {
  return (label) async {
    final found = <({String? team, String connectionId})>[];
    Future<void> scan(AppDatabase db, String? team) async {
      for (final c in await db.connectionsDao.getAll()) {
        final shown = c.label.isNotEmpty ? c.label : hostWithPort(c.host, c.port);
        if (shown == label) found.add((team: team, connectionId: c.id));
      }
    }

    final tree = ref.read(databaseSessionProvider);
    if (tree != null) await scan(tree, null);
    for (final e in ref.read(orchardDatabasesProvider).entries) {
      await scan(e.value, e.key);
    }
    return found;
  };
});
