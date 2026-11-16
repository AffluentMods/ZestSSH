import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/identities.dart';

part 'identities_dao.g.dart';

@DriftAccessor(tables: [Identities])
class IdentitiesDao extends DatabaseAccessor<AppDatabase>
    with _$IdentitiesDaoMixin {
  IdentitiesDao(super.db);

  Stream<List<Identity>> watchAll() {
    return (select(identities)
          ..orderBy([(t) => OrderingTerm(expression: t.label)]))
        .watch();
  }

  Future<List<Identity>> getAll() => select(identities).get();

  Future<Identity?> getById(String id) {
    return (select(identities)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<Identity?> getDefault() {
    return (select(identities)..where((t) => t.isDefault.equals(true)))
        .getSingleOrNull();
  }

  Future<void> insertIdentity(IdentitiesCompanion entry) {
    return into(identities).insert(entry);
  }

  Future<void> updateIdentity(IdentitiesCompanion entry) {
    return (update(identities)..where((t) => t.id.equals(entry.id.value)))
        .write(entry);
  }

  Future<void> deleteIdentity(String id) => transaction(() async {
        // Delete-propagation tombstone so the identity is removed on other
        // devices; in the delete's transaction, so a delete a team vault
        // refuses leaves none.
        await attachedDatabase.tombstonesDao.mark('identities', id);
        await (delete(identities)..where((t) => t.id.equals(id))).go();
      });

  /// Delete all identities.
  Future<void> deleteAll() => delete(identities).go();

  /// Clear the default flag from the identity that has it, then set the given
  /// one. Only the rows whose flag changes are written: the database stamps
  /// every row an UPDATE touches as changed now, and a key stamped so outlives
  /// a delete made on another device before this one pulled (edit beats
  /// delete), and is sent back to every device.
  Future<void> setDefault(String id) async {
    await transaction(() async {
      await (update(identities)..where((t) => t.isDefault.equals(true) & t.id.equals(id).not())).write(
        const IdentitiesCompanion(isDefault: Value(false)),
      );
      await (update(identities)..where((t) => t.id.equals(id) & t.isDefault.equals(false))).write(
        const IdentitiesCompanion(isDefault: Value(true)),
      );
    });
  }
}
