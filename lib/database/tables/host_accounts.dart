import 'package:drift/drift.dart';

/// The other accounts of a host (3.0, accounts per host): identities a host
/// can also be signed in to with, in their order, beside its default one,
/// which stays `connections.identity_id` (so everything that reads a host's
/// identity reads its default, as before).
///
/// Like [ConnectionTags], no foreign keys: a host's rows go with it in its
/// delete path, an identity's when it is deleted (where a host whose
/// default it was takes its first other account instead), and sync sweeps
/// any left over. In an Orchard they travel with the host in its record.
@TableIndex(name: 'idx_host_accounts_identity', columns: {#identityId})
class HostAccounts extends Table {
  /// `connections.id`.
  TextColumn get connectionId => text()();

  /// `identities.id`: never the host's default one.
  TextColumn get identityId => text()();

  /// Where it stands among the host's other accounts, from 0.
  IntColumn get position => integer()();

  @override
  Set<Column> get primaryKey => {connectionId, identityId};
}
