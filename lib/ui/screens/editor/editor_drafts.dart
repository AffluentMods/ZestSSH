import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart' show sha256Of;

/// How long an unsaved draft is kept.
const Duration kEditorDraftKeptFor = Duration(days: 7);

/// The unsaved text of a file, kept on this device so a crash, a killed app
/// or a dropped connection loses nothing (3.4): what was typed,
/// what it is written in, and the hash of the file it was typed over, so
/// that when it is put back the editor can say whether the file on the host
/// changed since.
class EditorDraft {
  const EditorDraft({
    required this.text,
    required this.encoding,
    required this.lineBreak,
    required this.baseHash,
    required this.keptAt,
  });

  final String text;

  /// The encoding's and the line endings' names (EditorEncoding.name,
  /// EditorLineBreak.name).
  final String encoding;
  final String lineBreak;

  /// The SHA-256 of the file as it was read before the text was typed over
  /// it; null where it is not known.
  final String? baseHash;
  final DateTime keptAt;

  Map<String, Object?> toJson() => {
        'v': 1,
        'text': text,
        'encoding': encoding,
        'lineBreak': lineBreak,
        'baseHash': baseHash,
        'keptAt': keptAt.millisecondsSinceEpoch,
      };

  static EditorDraft? fromJson(Object? json) {
    if (json is! Map) return null;
    final text = json['text'];
    final at = json['keptAt'];
    if (text is! String || at is! int) return null;
    return EditorDraft(
      text: text,
      encoding: json['encoding'] is String ? json['encoding'] as String : 'utf8',
      lineBreak: json['lineBreak'] is String ? json['lineBreak'] as String : 'lf',
      baseHash: json['baseHash'] is String ? json['baseHash'] as String : null,
      keptAt: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// Where drafts are kept. A draft of a team's host is kept in that team's
/// own database ([team]), so it never shows on a Personal host or in another
/// team, and goes with the team's database when the team leaves the device;
/// the rest in the personal one.
abstract class EditorDraftStore {
  Future<EditorDraft?> read(String identity, {String? team});
  Future<void> write(String identity, EditorDraft draft, {String? team});
  Future<void> remove(String identity, {String? team});

  /// Deletes every draft kept before [now] less [kEditorDraftKeptFor].
  Future<void> forgetOld({DateTime? now});
}

/// Drafts in the encrypted databases (`local_state`, SQLCipher, as the
/// tab snapshot and the saved workspaces are): device-local, never synced,
/// never in a backup. A draft's key is the hash of its host's id and its
/// path, so the key names neither; the path is inside, encrypted with the
/// rest.
class LocalEditorDraftStore implements EditorDraftStore {
  LocalEditorDraftStore(this._store, {LocalStateStore? Function(String team)? teams, Iterable<LocalStateStore> Function()? allTeams})
      : _teams = teams,
        _allTeams = allTeams;

  final LocalStateStore _store;

  /// A team's own store, where its database is open (else its drafts are
  /// neither kept nor read).
  final LocalStateStore? Function(String team)? _teams;
  final Iterable<LocalStateStore> Function()? _allTeams;

  static const String prefix = 'editor_draft:';

  static String keyOf(String identity) => '$prefix${sha256Of(utf8.encode(identity))}';

  LocalStateStore? _of(String? team) => team == null ? _store : _teams?.call(team);

  @override
  Future<EditorDraft?> read(String identity, {String? team}) async {
    final store = _of(team);
    if (store == null) return null;
    final raw = await store.read(keyOf(identity));
    if (raw == null) return null;
    EditorDraft? draft;
    try {
      draft = EditorDraft.fromJson(jsonDecode(raw));
    } on FormatException {
      draft = null;
    }
    if (draft == null || DateTime.now().difference(draft.keptAt) > kEditorDraftKeptFor) {
      await store.remove(keyOf(identity));
      return null;
    }
    return draft;
  }

  @override
  Future<void> write(String identity, EditorDraft draft, {String? team}) async {
    await _of(team)?.write(keyOf(identity), jsonEncode(draft.toJson()));
  }

  @override
  Future<void> remove(String identity, {String? team}) async {
    await _of(team)?.remove(keyOf(identity));
  }

  @override
  Future<void> forgetOld({DateTime? now}) async {
    await forgetOldIn(_store, now: now);
    for (final team in _allTeams?.call() ?? const <LocalStateStore>[]) {
      await forgetOldIn(team, now: now);
    }
  }

  /// [forgetOld] in one database: run as each opens (the app unlocked, a
  /// team's database opened), so a draft is not kept past its 7 days where
  /// the editor is not opened again.
  static Future<void> forgetOldIn(LocalStateStore store, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    for (final key in await store.keysWithPrefix(prefix)) {
      final raw = await store.read(key);
      EditorDraft? draft;
      try {
        draft = raw == null ? null : EditorDraft.fromJson(jsonDecode(raw));
      } on FormatException {
        draft = null;
      }
      if (draft == null || at.difference(draft.keptAt) > kEditorDraftKeptFor) await store.remove(key);
    }
  }
}

/// The editor's drafts, in this profile's encrypted database and each open
/// team's.
final editorDraftStoreProvider = Provider<EditorDraftStore>((ref) => LocalEditorDraftStore(
      ref.watch(localStateStoreProvider),
      teams: (team) {
        final db = ref.read(orchardDatabasesProvider)[team];
        return db == null ? null : LocalStateStore(db);
      },
      allTeams: () => [for (final db in ref.read(orchardDatabasesProvider).values) LocalStateStore(db)],
    ));

/// Old drafts deleted as each database opens: the personal one at unlock,
/// a team's as it opens. Read once by the app, which keeps it.
final editorDraftSweepProvider = Provider<void>((ref) {
  void sweep(AppDatabase db) =>
      LocalEditorDraftStore.forgetOldIn(LocalStateStore(db)).catchError((Object _) {});
  ref.listen<AppDatabase?>(databaseSessionProvider, (_, db) {
    if (db != null) sweep(db);
  }, fireImmediately: true);
  ref.listen<Map<String, AppDatabase>>(orchardDatabasesProvider, (before, now) {
    for (final e in now.entries) {
      if (before?[e.key] != e.value) sweep(e.value);
    }
  }, fireImmediately: true);
});

/// A line-by-line comparison of the file on its host ([before]) with the
/// draft ([after]), for Show changes: the lines the same at the start and
/// the end are left out, and what lies between is said as lines taken out
/// and lines put in, at most [limit] of each.
({int at, List<String> removed, List<String> added, int moreRemoved, int moreAdded}) compareLines(
  String before,
  String after, {
  int limit = 400,
}) {
  final a = before.split('\n');
  final b = after.split('\n');
  var head = 0;
  while (head < a.length && head < b.length && a[head] == b[head]) {
    head++;
  }
  var tail = 0;
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] == b[b.length - 1 - tail]) {
    tail++;
  }
  final removed = a.sublist(head, a.length - tail);
  final added = b.sublist(head, b.length - tail);
  return (
    at: head + 1,
    removed: removed.take(limit).toList(),
    added: added.take(limit).toList(),
    moreRemoved: removed.length > limit ? removed.length - limit : 0,
    moreAdded: added.length > limit ? added.length - limit : 0,
  );
}
