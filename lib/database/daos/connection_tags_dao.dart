import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/connection_tags.dart';

part 'connection_tags_dao.g.dart';

/// Free-form tags decorating connections.
///
/// All writes go through [normalize] so callers don't have to worry
/// about casing or whitespace. Reads always return canonical-form
/// strings, which means UI dedup is trivial (sets / direct equality).
@DriftAccessor(tables: [ConnectionTags])
class ConnectionTagsDao extends DatabaseAccessor<AppDatabase>
    with _$ConnectionTagsDaoMixin {
  ConnectionTagsDao(super.db);

  /// Maximum tag length the schema allows. Kept in sync with the column
  /// definition in [ConnectionTags] so callers can show a counter.
  static const int maxLength = 32;

  /// Canonicalise a user-entered tag.
  ///
  /// - Trim outer whitespace.
  /// - Lowercase (ASCII fold; we don't try to be clever with Unicode).
  /// - Collapse internal whitespace runs to a single space.
  /// - Truncate to [maxLength] chars.
  ///
  /// Returns `null` if the result is empty so callers can drop it.
  static String? normalize(String raw) {
    final trimmed = raw.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    final collapsed = trimmed.replaceAll(RegExp(r'\s+'), ' ');
    return collapsed.length > maxLength
        ? collapsed.substring(0, maxLength)
        : collapsed;
  }

  // ── Per-connection reads ─────────────────────────────────────────

  /// All tags attached to [connectionId], alphabetically sorted.
  Future<List<String>> getTagsForConnection(String connectionId) async {
    final rows = await (select(connectionTags)
          ..where((t) => t.connectionId.equals(connectionId))
          ..orderBy([(t) => OrderingTerm(expression: t.tag)]))
        .get();
    return rows.map((r) => r.tag).toList(growable: false);
  }

  /// Live updates of [getTagsForConnection].
  Stream<List<String>> watchTagsForConnection(String connectionId) {
    return (select(connectionTags)
          ..where((t) => t.connectionId.equals(connectionId))
          ..orderBy([(t) => OrderingTerm(expression: t.tag)]))
        .watch()
        .map((rows) => rows.map((r) => r.tag).toList(growable: false));
  }

  // ── Mutations ────────────────────────────────────────────────────

  /// Add a tag to a connection. No-op if the canonical form already
  /// exists for the connection. Returns the canonical tag actually
  /// written, or `null` if the input was empty after normalisation.
  Future<String?> addTag(String connectionId, String rawTag) async {
    final tag = normalize(rawTag);
    if (tag == null) return null;
    await into(connectionTags).insert(
      ConnectionTagsCompanion(
        connectionId: Value(connectionId),
        tag: Value(tag),
        createdAt: Value(DateTime.now()),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    return tag;
  }

  /// Replace the entire tag set for [connectionId] with [tags]. Tags
  /// are normalised; duplicates collapse. Pass an empty iterable to
  /// clear all tags for the connection.
  Future<void> setTagsForConnection(
    String connectionId,
    Iterable<String> tags,
  ) async {
    final canonical = <String>{};
    for (final raw in tags) {
      final t = normalize(raw);
      if (t != null) canonical.add(t);
    }
    final now = DateTime.now();
    await transaction(() async {
      await (delete(connectionTags)
            ..where((t) => t.connectionId.equals(connectionId)))
          .go();
      if (canonical.isEmpty) return;
      await batch((b) {
        b.insertAll(connectionTags, [
          for (final t in canonical)
            ConnectionTagsCompanion(
              connectionId: Value(connectionId),
              tag: Value(t),
              createdAt: Value(now),
            ),
        ]);
      });
    });
  }

  /// Remove a single tag from a connection. Idempotent.
  Future<void> removeTag(String connectionId, String rawTag) async {
    final tag = normalize(rawTag);
    if (tag == null) return;
    await (delete(connectionTags)
          ..where((t) =>
              t.connectionId.equals(connectionId) & t.tag.equals(tag)))
        .go();
  }

  /// Remove every tag attached to [connectionId]. Called from the
  /// connection delete path so deleting a host also drops its tags.
  Future<void> clearTagsForConnection(String connectionId) {
    return (delete(connectionTags)
          ..where((t) => t.connectionId.equals(connectionId)))
        .go();
  }

  /// Remove [tag] from every connection it's attached to. Called by
  /// "rename / merge tag" UI when the user wipes a tag from the
  /// vocabulary entirely.
  Future<void> deleteTagGlobally(String rawTag) async {
    final tag = normalize(rawTag);
    if (tag == null) return;
    await (delete(connectionTags)..where((t) => t.tag.equals(tag))).go();
  }

  /// Rename a tag everywhere it appears. If [oldTag] and [newTag]
  /// canonicalise to the same string, this is a no-op.
  ///
  /// If [newTag] already exists on a connection that also has [oldTag],
  /// the duplicate row is silently dropped (composite PK enforces
  /// uniqueness).
  Future<void> renameTagGlobally(String oldRaw, String newRaw) async {
    final oldTag = normalize(oldRaw);
    final newTag = normalize(newRaw);
    if (oldTag == null || newTag == null || oldTag == newTag) return;
    await transaction(() async {
      final affected = await (select(connectionTags)
            ..where((t) => t.tag.equals(oldTag)))
          .get();
      if (affected.isEmpty) return;
      // Drop old rows first so re-inserting the new tag can't collide
      // with itself on connections that already have newTag.
      await (delete(connectionTags)..where((t) => t.tag.equals(oldTag)))
          .go();
      final now = DateTime.now();
      await batch((b) {
        b.insertAll(
          connectionTags,
          [
            for (final r in affected)
              ConnectionTagsCompanion(
                connectionId: Value(r.connectionId),
                tag: Value(newTag),
                createdAt: Value(now),
              ),
          ],
          mode: InsertMode.insertOrIgnore,
        );
      });
    });
  }

  // ── Vocabulary queries ───────────────────────────────────────────

  /// Distinct list of every tag in use across all connections, ordered
  /// alphabetically. Powers tag autocomplete and the filter strip.
  Future<List<String>> getAllTags() async {
    final query = selectOnly(connectionTags, distinct: true)
      ..addColumns([connectionTags.tag])
      ..orderBy([
        OrderingTerm(expression: connectionTags.tag),
      ]);
    final rows = await query.get();
    return rows
        .map((r) => r.read(connectionTags.tag))
        .whereType<String>()
        .toList(growable: false);
  }

  /// Live updates of [getAllTags].
  Stream<List<String>> watchAllTags() {
    final query = selectOnly(connectionTags, distinct: true)
      ..addColumns([connectionTags.tag])
      ..orderBy([
        OrderingTerm(expression: connectionTags.tag),
      ]);
    return query.watch().map((rows) => rows
        .map((r) => r.read(connectionTags.tag))
        .whereType<String>()
        .toList(growable: false));
  }

  /// Connection ids that carry [rawTag]. Empty list if the tag is
  /// unused. Input is normalised before the query so callers don't
  /// have to canonicalise themselves.
  Future<List<String>> getConnectionIdsWithTag(String rawTag) async {
    final tag = normalize(rawTag);
    if (tag == null) return const [];
    final rows = await (select(connectionTags)
          ..where((t) => t.tag.equals(tag)))
        .get();
    return rows.map((r) => r.connectionId).toList(growable: false);
  }

  /// Live version of [getConnectionIdsWithTag].
  Stream<List<String>> watchConnectionIdsWithTag(String rawTag) {
    final tag = normalize(rawTag);
    if (tag == null) return Stream.value(const []);
    return (select(connectionTags)..where((t) => t.tag.equals(tag)))
        .watch()
        .map((rows) =>
            rows.map((r) => r.connectionId).toList(growable: false));
  }

  /// One-shot `connectionId` → sorted tags, for every connection that has at
  /// least one tag. Used by cloud sync to serialize the tag assignments; sorted
  /// so the sync-blob round-trip is byte-stable (no spurious echo push).
  Future<Map<String, List<String>>> getAllAssignments() async {
    final rows = await select(connectionTags).get();
    final grouped = <String, List<String>>{};
    for (final r in rows) {
      grouped.putIfAbsent(r.connectionId, () => <String>[]).add(r.tag);
    }
    // Sort BOTH the tag lists AND the outer connectionId keys, so the emitted
    // map is a pure function of tag content (independent of local rowid order).
    // Otherwise two devices that tagged the same hosts in a different order emit
    // differently-ordered maps -> different fingerprint -> a redundant echo push.
    final keys = grouped.keys.toList()..sort();
    final out = <String, List<String>>{};
    for (final k in keys) {
      out[k] = grouped[k]!..sort();
    }
    return out;
  }

  /// Map from `connectionId` → list of tags, for every connection that
  /// has at least one tag. Lets the host grid render tag chips without
  /// firing a query per card.
  Stream<Map<String, List<String>>> watchAllAssignments() {
    return select(connectionTags).watch().map((rows) {
      final out = <String, List<String>>{};
      for (final r in rows) {
        out.putIfAbsent(r.connectionId, () => <String>[]).add(r.tag);
      }
      // Stable, alphabetical render order per host.
      for (final entry in out.values) {
        entry.sort();
      }
      return out;
    });
  }

  /// Tag → count of connections carrying it. Useful for filter chip
  /// labels ("prod (4)") and "merge / rename" admin UI.
  Stream<Map<String, int>> watchTagCounts() {
    final query = selectOnly(connectionTags)
      ..addColumns([connectionTags.tag, connectionTags.tag.count()])
      ..groupBy([connectionTags.tag])
      ..orderBy([OrderingTerm(expression: connectionTags.tag)]);
    return query.watch().map((rows) {
      final out = <String, int>{};
      for (final r in rows) {
        final tag = r.read(connectionTags.tag);
        final count = r.read(connectionTags.tag.count());
        if (tag != null && count != null) out[tag] = count;
      }
      return out;
    });
  }
}
