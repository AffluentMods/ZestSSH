import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/providers/core_providers.dart';

/// Distinct alphabetical list of every tag in use across all
/// connections. Drives the tag autocomplete and the filter strip.
final allTagsProvider = StreamProvider<List<String>>((ref) {
  return ref.watch(connectionTagsDaoProvider).watchAllTags();
});

/// Live tag → host count map. Lets filter chips render counts ("prod 4")
/// without forcing every consumer to recompute from the assignments map.
final tagCountsProvider = StreamProvider<Map<String, int>>((ref) {
  return ref.watch(connectionTagsDaoProvider).watchTagCounts();
});

/// Live tags for a single connection. Streamed so the edit form / chip
/// row update without manual refreshes.
final tagsForConnectionProvider =
    StreamProvider.family<List<String>, String>((ref, connectionId) {
  return ref
      .watch(connectionTagsDaoProvider)
      .watchTagsForConnection(connectionId);
});

/// Map of every connection that has at least one tag → its tag list.
/// Cards on the host grid read from this single stream rather than
/// firing a per-card subscription.
final allTagAssignmentsProvider =
    StreamProvider<Map<String, List<String>>>((ref) {
  return ref.watch(connectionTagsDaoProvider).watchAllAssignments();
});

/// Currently active tag filters (canonical form, e.g. "prod"). Empty
/// set means "no tag filter active". Filter behaviour is OR: a host
/// matches if any of its tags appears in this set.
///
/// Lives at app scope so the host grid and the bulk-action bar share
/// the same selection - tapping a chip on the home page also affects
/// keyboard-shortcut filters elsewhere.
final activeTagFiltersProvider =
    NotifierProvider<ActiveTagFiltersNotifier, Set<String>>(
  ActiveTagFiltersNotifier.new,
);

class ActiveTagFiltersNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  void toggle(String rawTag) {
    final tag = ConnectionTagsDao.normalize(rawTag);
    if (tag == null) return;
    if (state.contains(tag)) {
      state = state.where((t) => t != tag).toSet();
    } else {
      state = {...state, tag};
    }
  }

  void clear() => state = const <String>{};

  void replace(Iterable<String> tags) {
    final canonical = <String>{};
    for (final raw in tags) {
      final t = ConnectionTagsDao.normalize(raw);
      if (t != null) canonical.add(t);
    }
    state = canonical;
  }
}

/// Mutating helpers for tags. Hides the DAO behind a single ref.read
/// surface - UI never has to touch the DAO directly.
final tagsCrudProvider = Provider<TagsCrudNotifier>((ref) {
  return TagsCrudNotifier(ref.watch(connectionTagsDaoProvider));
});

class TagsCrudNotifier {
  TagsCrudNotifier(this._dao);
  final ConnectionTagsDao _dao;

  /// Add a tag to a single connection. Returns the canonical form
  /// actually written, or null if the input was empty after
  /// normalisation. Idempotent.
  Future<String?> addTag(String connectionId, String rawTag) =>
      _dao.addTag(connectionId, rawTag);

  /// Replace the full tag set for a single connection.
  Future<void> setTagsForConnection(
      String connectionId, Iterable<String> tags) =>
      _dao.setTagsForConnection(connectionId, tags);

  /// Remove a single tag from a single connection.
  Future<void> removeTag(String connectionId, String rawTag) =>
      _dao.removeTag(connectionId, rawTag);

  /// Bulk-add a tag to several connections at once. Used by the
  /// multi-select toolbar.
  Future<void> addTagToMany(Iterable<String> connectionIds, String rawTag) =>
      Future.wait(connectionIds.map((id) => _dao.addTag(id, rawTag)))
          .then((_) {});

  /// Bulk-remove a tag from several connections.
  Future<void> removeTagFromMany(
          Iterable<String> connectionIds, String rawTag) =>
      Future.wait(
              connectionIds.map((id) => _dao.removeTag(id, rawTag)))
          .then((_) {});

  /// Delete a tag from the entire vocabulary (every connection).
  Future<void> deleteTagGlobally(String rawTag) =>
      _dao.deleteTagGlobally(rawTag);

  /// Rename a tag everywhere it appears.
  Future<void> renameTagGlobally(String oldTag, String newTag) =>
      _dao.renameTagGlobally(oldTag, newTag);
}
