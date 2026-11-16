import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// One of a host's other accounts, as "Connect as" offers it (3.0, accounts
/// per host): the identity's id, username and label.
typedef HostAccountChoice = ({String id, String username, String label});

/// The other accounts of the host [connectionId] in the space in view, in
/// their order, kept current: what a host's menu offers under "Connect as".
final hostAccountChoicesProvider =
    StreamProvider.autoDispose.family<List<HostAccountChoice>, String>((ref, connectionId) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.hostAccounts).join([
    innerJoin(db.identities, db.identities.id.equalsExp(db.hostAccounts.identityId)),
  ])
    ..where(db.hostAccounts.connectionId.equals(connectionId))
    ..orderBy([OrderingTerm(expression: db.hostAccounts.position)]);
  return query.watch().map((rows) => [
        for (final row in rows)
          (
            id: row.readTable(db.identities).id,
            username: row.readTable(db.identities).username,
            label: row.readTable(db.identities).label,
          ),
      ]);
});

/// The other accounts of [connectionId] in the space in view, read once:
/// for a menu that reads them as it opens.
Future<List<HostAccountChoice>> hostAccountChoicesNow(WidgetRef ref, String connectionId) async {
  final ids = await ref.read(hostAccountsDaoProvider).otherAccountsOf(connectionId);
  if (ids.isEmpty) return const [];
  final byId = {for (final i in await ref.read(identitiesDaoProvider).getAll()) i.id: i};
  return [
    for (final id in ids)
      if (byId[id] case final i?) (id: i.id, username: i.username, label: i.label),
  ];
}

/// "Connect as" and the account, for each of [choices]: the account by its
/// username, and by its identity's label as well where the username is not
/// enough to tell it from the host's default ([defaultUsername]) or from
/// another of them. Names are shown as recording mode shows them.
List<({String id, String text})> connectAsItems(
  AppLocalizations l10n,
  WidgetRef ref,
  List<HostAccountChoice> choices, {
  String? defaultUsername,
}) {
  int sharing(String username) =>
      choices.where((c) => c.username == username).length + (defaultUsername == username ? 1 : 0);
  return [
    for (final c in choices)
      (
        id: c.id,
        text: l10n.hostConnectAs(sharing(c.username) > 1
            ? '${Redactable.username(c.username).displayIn(ref)} '
                '(${Redactable.keyName(c.label).displayIn(ref)})'
            : Redactable.username(c.username).displayIn(ref)),
      ),
  ];
}
