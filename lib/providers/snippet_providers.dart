import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/daos/snippet_categories_dao.dart';
import 'package:zestssh/database/daos/snippets_dao.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/shell_fill.dart';

export 'package:zestssh/utils/shell_fill.dart' show shellEscapeArg;

// ── Snippet list ─────────────────────────────────────────────────

/// Stream of all snippets ordered by category then label.
final snippetsProvider = StreamProvider<List<Snippet>>((ref) {
  final dao = ref.watch(snippetsDaoProvider);
  return dao.watchAll();
});

/// Available categories for filtering / editor autocomplete.
///
/// Derived from the live [snippetsProvider] stream so a category the user
/// just created shows up immediately. (This used to be a cached
/// FutureProvider over `dao.getCategories()`, which never refreshed after a
/// create - so a brand-new category was missing from the snippet editor's
/// category autocomplete until the app was restarted.)
final snippetCategoriesProvider = Provider<List<String>>((ref) {
  final snippets = ref.watch(snippetsProvider).valueOrNull ?? const <Snippet>[];
  return snippets
      .map((s) => s.category)
      .where((c) => c != null && c.isNotEmpty)
      .cast<String>()
      .toSet()
      .toList()
    ..sort();
});

/// Search query for filtering snippets.
final snippetSearchQueryProvider = StateProvider<String>((ref) => '');

// ── Category metadata (persisted: order / color / hidden) ────────

/// Live stream of the persisted per-category metadata rows (schema v22).
/// A category only has a row here once the user customizes it; the desktop
/// snippets view merges these against the live snippet categories.
final snippetCategoryMetaProvider = StreamProvider<List<SnippetCategory>>((
  ref,
) {
  final dao = ref.watch(snippetCategoriesDaoProvider);
  return dao.watchAll();
});

/// Convenience view of [snippetCategoryMetaProvider] keyed by category name.
/// Returns an empty map while the stream is loading so callers can look up
/// metadata without unwrapping the AsyncValue at every use site.
final snippetCategoryMetaMapProvider = Provider<Map<String, SnippetCategory>>((
  ref,
) {
  final rows =
      ref.watch(snippetCategoryMetaProvider).valueOrNull ??
      const <SnippetCategory>[];
  return {for (final r in rows) r.name: r};
});

// ── Ephemeral sort/filter (NOT persisted - resets on restart) ────

/// How the snippet category sections are ordered in the desktop view. This is
/// deliberately an in-memory [StateProvider]: it is NEVER written to the DB or
/// SharedPreferences, so it resets to [SnippetSortMode.arranged] on restart.
/// The persisted arrange order lives in the `snippet_categories` table instead.
enum SnippetSortMode {
  /// Use the user's saved drag order (`SnippetCategories.sortOrder`).
  arranged('Arranged'),

  /// Category sections A → Z by name.
  nameAsc('Name A-Z'),

  /// Category sections Z → A by name.
  nameDesc('Name Z-A'),

  /// Sections (and snippets within them) by most-recently-updated first.
  recentlyUpdated('Recently updated');

  const SnippetSortMode(this.label);
  final String label;
}

/// Ephemeral sort mode for the desktop snippets view. Not persisted.
final snippetSortModeProvider = StateProvider<SnippetSortMode>(
  (ref) => SnippetSortMode.arranged,
);

// ── Category CRUD (persisted mutations) ──────────────────────────

final snippetCategoryCrudProvider = Provider<SnippetCategoryCrudNotifier>((
  ref,
) {
  return SnippetCategoryCrudNotifier(
    ref.watch(databaseProvider),
    ref.watch(snippetCategoriesDaoProvider),
    ref.watch(snippetsDaoProvider),
  );
});

/// Mutations for snippet-category metadata. Every write upserts the lazy row,
/// so callers never have to check whether the category is customized yet.
class SnippetCategoryCrudNotifier {
  final AppDatabase _db;
  final SnippetCategoriesDao _categoriesDao;
  final SnippetsDao _snippetsDao;

  SnippetCategoryCrudNotifier(this._db, this._categoriesDao, this._snippetsDao);

  /// Set (or clear, with null) a category's accent color. A non-null
  /// [colorValue] (ARGB int) persists an arbitrary custom colour that overrides
  /// the palette index.
  Future<void> setColor(String name, int? colorIndex, {int? colorValue}) =>
      _categoriesDao.setColor(name, colorIndex, colorValue: colorValue);

  /// Toggle a category's hidden state.
  Future<void> setHidden(String name, bool hidden) =>
      _categoriesDao.setHidden(name, hidden);

  /// Persist a new category ordering (the arrange panel drag result).
  Future<void> updateOrder(List<String> orderedNames) =>
      _categoriesDao.updateOrder(orderedNames);

  /// Rename a category everywhere ATOMICALLY: rewrite every snippet carrying
  /// [oldName] to [newName] AND move the metadata row, inside one transaction.
  /// No-op when the new name is blank or unchanged.
  Future<void> renameCategory(String oldName, String rawNewName) async {
    final newName = rawNewName.trim();
    if (newName.isEmpty || newName == oldName) return;
    await _db.transaction(() async {
      await _snippetsDao.renameCategory(oldName, newName);
      await _categoriesDao.rename(oldName, newName);
    });
  }

  /// Remove a category's metadata row (snippets keep their category string).
  Future<void> deleteMeta(String name) => _categoriesDao.deleteByName(name);

  /// Delete a whole category/group ATOMICALLY: reassign every snippet carrying
  /// [name] to Uncategorized (category → NULL) AND drop the metadata row, inside
  /// one transaction. The snippets' commands are preserved - only the grouping
  /// is removed. Intended for user-created groups; the caller gates this so
  /// built-in groups (those containing seeded default snippets) can't be deleted.
  Future<void> deleteCategory(String name) async {
    await _db.transaction(() async {
      await _snippetsDao.clearCategory(name);
      await _categoriesDao.deleteByName(name);
    });
  }
}

// ── CRUD ─────────────────────────────────────────────────────────

final snippetCrudProvider = Provider<SnippetCrudNotifier>((ref) {
  return SnippetCrudNotifier(
    ref.watch(snippetsDaoProvider),
    ref.watch(connectionsDaoProvider),
  );
});

class SnippetCrudNotifier {
  final SnippetsDao _dao;
  final ConnectionsDao _connectionsDao;

  SnippetCrudNotifier(this._dao, this._connectionsDao);

  Future<String> create({
    required String label,
    required String command,
    String? category,
    bool confirmBeforeRun = false,
    bool isDefault = false,
    String? metadata,
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now();

    await _dao.insertSnippet(
      SnippetsCompanion(
        id: Value(id),
        label: Value(label),
        command: Value(CommandText.stored(command)),
        category: Value(category),
        confirmBeforeRun: Value(confirmBeforeRun),
        isDefault: Value(isDefault),
        metadata: Value(metadata),
        sortOrder: const Value(0),
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );

    return id;
  }

  /// PARTIAL update - only the non-null arguments are written. Note that
  /// [category] therefore can NOT be cleared through this method (a null
  /// `category` means "leave unchanged"). Use [updateFull] from the editor,
  /// where the whole record is being saved and an empty category must persist
  /// as uncategorized. Kept for callers that only touch a subset of fields.
  Future<void> update({
    required String id,
    String? label,
    String? command,
    String? category,
    bool? confirmBeforeRun,
  }) async {
    await _dao.updateSnippet(
      SnippetsCompanion(
        id: Value(id),
        label: label != null ? Value(label) : const Value.absent(),
        command: command != null
            ? Value(CommandText.stored(command))
            : const Value.absent(),
        category: category != null ? Value(category) : const Value.absent(),
        confirmBeforeRun: confirmBeforeRun != null
            ? Value(confirmBeforeRun)
            : const Value.absent(),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// FULL update from the snippet editor - every field is written, so passing
  /// `category: null` CLEARS the category (the snippet becomes uncategorized).
  /// This is the fix for "editing can't move a snippet back to uncategorized":
  /// the partial [update] treats a null category as "unchanged", so it could
  /// never remove one.
  Future<void> updateFull({
    required String id,
    required String label,
    required String command,
    required String? category,
    required bool confirmBeforeRun,
    required String? metadata,
  }) async {
    await _dao.updateSnippet(
      SnippetsCompanion(
        id: Value(id),
        label: Value(label),
        command: Value(CommandText.stored(command)),
        // Value(null) writes NULL - this is what makes clearing possible.
        category: Value(category),
        confirmBeforeRun: Value(confirmBeforeRun),
        // Value(null) clears the metadata (no description / no var notes left).
        metadata: Value(metadata),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Puts the snippet [id] in [category], or in none ([category] null), and
  /// changes nothing else (Move to category for several snippets, 3.4).
  Future<void> setCategory(String id, String? category) => _dao.updateSnippet(
        SnippetsCompanion(
          id: Value(id),
          category: Value(category),
          updatedAt: Value(DateTime.now()),
        ),
      );

  /// Deletes the snippet [id] and takes it off the hosts that run it at
  /// sign-in, in one transaction: a team vault refusing the snippet leaves
  /// those hosts running it.
  Future<void> delete(String id) => _dao.transaction(() async {
        // Clear snippet references from connections that use this snippet
        await _connectionsDao.clearSnippetReferences(id);
        await _dao.deleteSnippet(id);
      });

  /// Seed default snippets if none exist.
  Future<void> seedDefaults() async {
    final existing = await _dao.getAll();
    if (existing.isNotEmpty) return;

    final now = DateTime.now();
    for (final entry in _defaultSnippets) {
      await _dao.insertSnippet(
        SnippetsCompanion(
          id: Value(const Uuid().v4()),
          label: Value(entry.label),
          command: Value(entry.command),
          category: Value(entry.category),
          confirmBeforeRun: Value(entry.confirm),
          isDefault: const Value(true),
          sortOrder: Value(entry.sort),
          createdAt: Value(now),
          updatedAt: Value(now),
        ),
      );
    }
  }
}

// ── Variable parsing ────────────────────────────────────────────

/// The type of a variable placeholder in a snippet command.
enum VariableType {
  /// `${VAR}` - user types free-form text.
  freeText,

  /// `${[opt1,opt2,opt3]}` - user picks from inline list.
  inlineList,

  /// `$[DOCKER]` - app runs a command on the SSH session to populate.
  dynamicList,
}

/// A parsed variable from a snippet command.
///
/// Supports these syntaxes:
/// - `${VAR}` - free-form text input, prompted at run time
/// - `${VAR:-default}` - free-form text with a baked-in default; NOT prompted
///   at run time (the default is used unless the detail editor overrides it)
/// - `${[opt1,opt2,opt3]}` - inline dropdown with listed options
/// - `$[DOCKER]` - dynamic list populated from the remote session
class ParsedVariable {
  /// Human-readable identifier for display.
  final String name;

  /// The type of this variable.
  final VariableType type;

  /// For [inlineList]: the predefined options.
  final List<String> options;

  /// For [dynamicList]: the keyword (DOCKER, PM2, SYSTEMD, etc.)
  final String? dynamicSource;

  /// The exact `${...}` string in the command, used for replacement.
  final String matchPattern;

  /// Unique key for deduplication and the values map.
  final String key;

  /// For a free-text `${VAR:-default}` placeholder: the baked-in default value
  /// (the text after `:-`). `null` when the variable has no default - in which
  /// case it is [isRequired] and must be prompted for at run time. An empty
  /// string is a real, intentional default ("" - proceed with a blank value).
  final String? defaultValue;

  /// A masked/secret free-text variable (`${VAR:secret}` or `${VAR:password}`):
  /// its run-time input field is obscured so a token/password isn't shown on
  /// screen or shoulder-surfed. Purely about the input UI - the resolved value
  /// still substitutes into the command that runs.
  final bool secret;

  const ParsedVariable({
    required this.name,
    required this.type,
    this.options = const [],
    this.dynamicSource,
    required this.matchPattern,
    required this.key,
    this.defaultValue,
    this.secret = false,
  });

  bool get hasOptions => options.isNotEmpty;
  bool get isDynamic => type == VariableType.dynamicList;
  bool get isFreeText => type == VariableType.freeText;
  bool get isInlineList => type == VariableType.inlineList;

  /// Whether this variable carries a usable default and so should be RESOLVED
  /// silently rather than prompted for. Only free-text `${VAR:-default}`
  /// placeholders can carry one; list variables resolve through their own
  /// picker/query instead.
  bool get hasDefault => defaultValue != null;

  /// "Required" for the detected-variables table: a variable with no default
  /// must be filled in before the command can run. List variables (inline /
  /// dynamic) resolve through selection, so they are not flagged as required.
  bool get isRequired => type == VariableType.freeText && defaultValue == null;
}

/// Known dynamic list sources and the SSH commands that populate them.
const dynamicListCommands = <String, String>{
  'DOCKER': "docker ps --format '{{.Names}}'",
  'PM2': 'pm2 jlist',
  'SYSTEMD':
      'systemctl list-units --type=service --state=running --no-legend'
      " | awk '{print \$1}'",
  'SCREEN': r"screen -ls | grep -oP '\d+\.\K\S+'",
  'TMUX': "tmux list-sessions -F '#{session_name}'",
};

/// Friendly display names for dynamic list sources.
const _dynamicDisplayNames = <String, String>{
  'DOCKER': 'Docker Containers',
  'PM2': 'PM2 Processes',
  'SYSTEMD': 'Systemd Services',
  'SCREEN': 'Screen Sessions',
  'TMUX': 'Tmux Sessions',
};

/// Get a friendly display name for a dynamic source keyword.
String dynamicDisplayName(String source) =>
    _dynamicDisplayNames[source] ?? source;

/// Parse all variable placeholders from a command string.
///
/// Handles these syntaxes in order of appearance:
/// - `$[opt1,opt2,...]` - inline list (preferred new syntax)
/// - `$[DOCKER]` - dynamic list (preferred new syntax)
/// - `${VAR}` - free-form text input (prompted at run time)
/// - `${VAR:-default}` - free-form text with a default (NOT prompted; the
///   default resolves the placeholder unless the editor overrides it)
/// - `${[...]}` - legacy list syntax (backward compatible)
///
/// Returns unique variables in left-to-right order. Duplicate patterns
/// are only included once (same value is reused everywhere).
List<ParsedVariable> parseVariablesWithOptions(String command) {
  // Matches:
  //   $[...]              - new list syntax (group 1)
  //   ${[...]}            - legacy list syntax (group 2)
  //   ${WORD}             - free text (group 3)
  //   ${WORD:-default}    - free text with default (group 3 = name, 4 = default)
  //   ${WORD:secret} / ${WORD:password} - masked free-text input (group 5)
  final regex = RegExp(
    r'\$\[([^\]]+)\]|\$\{\[([^\]]+)\]\}|\$\{(\w+)(?::-([^}]*))?(?::(secret|password))?\}',
  );
  final matches = regex.allMatches(command);
  final seen = <String>{};
  final result = <ParsedVariable>[];

  for (final m in matches) {
    final newListContent = m.group(1); // $[...] - new syntax
    final legacyListContent = m.group(2); // ${[...]} - legacy
    final varName = m.group(3); // ${WORD} - free text
    final defaultVal = m.group(4); // ${WORD:-default} - the default, or null
    final fullMatch = m.group(0)!;

    final listContent = newListContent ?? legacyListContent;

    if (listContent != null) {
      // ── List syntax: $[...] or ${[...]} ──
      final key = '[$listContent]';
      if (!seen.add(key)) continue;

      // Check if it's a known dynamic source (single uppercase word)
      final isDynamic = dynamicListCommands.containsKey(listContent.trim());

      if (isDynamic) {
        final source = listContent.trim();
        result.add(
          ParsedVariable(
            name: dynamicDisplayName(source),
            type: VariableType.dynamicList,
            dynamicSource: source,
            matchPattern: fullMatch,
            key: key,
          ),
        );
      } else {
        // Inline list: split by comma
        final options = listContent
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        result.add(
          ParsedVariable(
            name: options.join(', '),
            type: VariableType.inlineList,
            options: options,
            matchPattern: fullMatch,
            key: key,
          ),
        );
      }
    } else if (varName != null) {
      // ── Free text: ${VAR}, ${VAR:-default}, ${VAR:secret} ──
      // Dedup by name: the FIRST occurrence wins, so if a command mixes
      // `${VAR:-x}` and a bare `${VAR}`, the default from the first is kept
      // and reused everywhere (they're the same variable).
      if (!seen.add(varName)) continue;
      final secretMarker = m.group(5); // "secret" | "password" | null
      result.add(
        ParsedVariable(
          name: varName,
          type: VariableType.freeText,
          matchPattern: fullMatch,
          key: varName,
          // group(4) is null when there is no `:-`; an empty string ("") is a
          // real default meaning "proceed with a blank value".
          defaultValue: defaultVal,
          secret: secretMarker != null,
        ),
      );
    }
  }
  return result;
}

/// Parse variable placeholders and return just the display names.
List<String> parseVariables(String command) {
  return parseVariablesWithOptions(command).map((v) => v.name).toList();
}

/// Check if a command has any variables (quick boolean check).
bool hasVariables(String command) {
  // Matches both $[...] (new) and ${[...]} (legacy) and ${VAR}
  return RegExp(r'\$\[[^\]]+\]|\$\{\[?[^\]\}]+\]?\}').hasMatch(command);
}

/// Replace all variable placeholders with provided values.
///
/// [values] is keyed by [ParsedVariable.key]:
/// - Free text: key = "VAR"
/// - Inline list: key = "[opt1,opt2,opt3]"
/// - Dynamic list: key = "[DOCKER]"
///
/// SECURITY: every value is written as the place it lands in takes it
/// ([fillPlaceholders]): a value like `foo; rm -rf /` becomes
/// `'foo; rm -rf /'` (a single shell argument), and in the quotes of
/// `"${VAR}"` or `'${VAR}'` it stays inside them, rather than getting
/// parsed as a command separator + new command. Without this, a
/// malicious deep-link / synced-snippet / clipboard paste could
/// inject arbitrary commands into the SSH session.
///
/// Trade-off: snippet authors who *want* to embed shell metachars
/// (like `&&` or `|`) inside a variable can't - they should put
/// those in the snippet body itself, not in the value.
///
/// A placeholder with no value in [values] is left untouched.
String resolveVariables(String command, Map<String, String> values) => fillPlaceholders(command, values);

/// What stands in a question, a preview or a run's head for a masked value
/// (`${VAR:secret}`).
const kMaskedValueShown = '••••••';

/// The masked values [values] fill into [command] (`${VAR:secret}`), as they were
/// typed.
List<String> maskedValuesIn(String command, Map<String, String> values) => [
      for (final v in parseVariablesWithOptions(command))
        if (v.secret && (values[v.key]?.isNotEmpty ?? false)) values[v.key]!,
    ];

/// [resolveVariables] as it is shown: the masked values out of sight, the real
/// command being what is checked and run. (A value typed with dots stood in
/// clear in the next dialog, and in the same one's preview: found 30 October
/// 2026 in an independent review.)
String resolveVariablesShown(String command, Map<String, String> values) => resolveVariables(command, {
      ...values,
      for (final v in parseVariablesWithOptions(command))
        if (v.secret && (values[v.key]?.isNotEmpty ?? false)) v.key: kMaskedValueShown,
    });

/// Rewrite the command so free-text variable [name] carries [defaultValue].
///
/// This is the write-side of the detected-variables table's Default cell: the
/// command string is the single source of truth for a variable's default, so
/// typing one in the table rewrites `${NAME}` → `${NAME:-value}` (and clearing
/// it rewrites back to the bare `${NAME}`). Every occurrence of the variable is
/// updated so the command stays internally consistent.
String setVariableDefault(String command, String name, String? defaultValue) {
  final pattern = RegExp(
      r'\$\{' + RegExp.escape(name) + r'(?::-[^}]*)?(?::(?:secret|password))?\}');
  // A literal '}' terminates the ${NAME:-…} placeholder, so it cannot appear
  // inside a baked default. Strip it here - the single write choke point for
  // the Default cell - rather than let it truncate the placeholder and corrupt
  // the rest of the command the next time it is parsed.
  final cleaned = defaultValue?.replaceAll('}', '');
  final replacement = (cleaned == null || cleaned.isEmpty)
      ? '\${$name}'
      : '\${$name:-$cleaned}';
  return command.replaceAll(pattern, replacement);
}

/// The variables that still need a value from the user at run time: every
/// detected variable EXCEPT free-text ones that already carry a default. List
/// variables are always included (they resolve through their picker/query).
///
/// Pairs with [defaultSeedValues]: prompt for these, seed the rest.
List<ParsedVariable> variablesToPrompt(String command) {
  return parseVariablesWithOptions(
    command,
  ).where((v) => !v.hasDefault).toList();
}

/// Of [variablesToPrompt], those [values] (keyed by [ParsedVariable.key]) gives
/// no value of: none, or a blank one. (Which of them a run needs a value for:
/// snippetVariablesToAsk.)
List<ParsedVariable> variablesStillToFill(String command, Map<String, String>? values) => [
      for (final v in variablesToPrompt(command))
        if ((values?[v.key] ?? '').trim().isEmpty) v,
    ];

/// Whether a snippet is safe to run with nobody present to answer for it, e.g.
/// the "Run snippet on connect" host setting fired automatically as the session
/// comes up. Two things disqualify a snippet: being flagged confirm-before-run
/// (the user asked to be asked), or needing any variable input at all
/// ([variablesToPrompt] non-empty, which also catches list/dynamic variables).
/// `${VAR:-default}` placeholders are fine - each takes its default
/// ([commandWithDefaults]) and [variablesToPrompt] already excludes them, unless
/// the default is blank and the command is a dangerous one with it empty.
bool snippetRunsUnattended(String command, {required bool confirmBeforeRun}) {
  if (confirmBeforeRun) return false;
  if (variablesToPrompt(command).isNotEmpty) return false;
  final blankDefault = parseVariablesWithOptions(command).any((v) => v.defaultValue?.trim().isEmpty ?? false);
  return !blankDefault || DangerousCommandService.checkFilled(commandWithDefaults(command)).isEmpty;
}

/// [command] with every variable that carries a default filled with it, every
/// occurrence of it: what runs where nothing else gives a value. Left to the
/// shell, `${DIR:-/tmp/a}` gives one occurrence its default and assigns nothing,
/// and the `${DIR}` beside it is empty: `mkdir -p ${DIR:-/tmp/a}; rm -rf ${DIR}/*`
/// ran `rm -rf /*` (found 30 October 2026 in an independent review).
String commandWithDefaults(String command) => resolveVariables(command, defaultSeedValues(command));

/// The pre-resolved values for every variable that carries a default, keyed by
/// [ParsedVariable.key]. Merge these UNDER the user's picked values so an
/// override in the run dialog always wins.
Map<String, String> defaultSeedValues(String command) {
  return {
    for (final v in parseVariablesWithOptions(command))
      if (v.hasDefault) v.key: v.defaultValue!,
  };
}

// ── Snippet metadata (persisted alongside the command, schema v23) ──────
//
// A snippet's *default* values live inside the command itself (`${VAR:-def}`),
// but a few things have no natural home in the command string: a human
// DESCRIPTION of the snippet, a per-variable description, and the snippet's
// preferred DEFAULT HOST. All persist in the nullable `Snippets.metadata` JSON
// column (v23). The shape is:
//
//   {
//     "description": "…",
//     "variables": { "<name>": "<description>" },
//     "defaultConnectionId": "<connection-id>"
//   }
//
// The default-host id is deliberately stored HERE rather than in a new
// `Snippets` column: it is a soft, optional preference (which saved host the
// snippet runs on by default), so it rides the existing metadata blob and needs
// NO schema migration or sync-blob version bump - the column and its sync path
// already exist (v23). Absent / malformed JSON decodes to an empty
// [SnippetMetadata] so a bad or pre-v23 value can never throw at a read site.

/// Parsed, typed view of the `Snippets.metadata` JSON column.
class SnippetMetadata {
  /// Free-text description of what the snippet does.
  final String? description;

  /// Per-variable descriptions, keyed by [ParsedVariable.key].
  final Map<String, String> variableDescriptions;

  /// Optional saved-connection id this snippet runs on by default. Stored in
  /// metadata (not a schema column) so it needs no migration - see the note
  /// above. Null means "no default host; ask when running".
  final String? defaultConnectionId;

  const SnippetMetadata({
    this.description,
    this.variableDescriptions = const {},
    this.defaultConnectionId,
  });

  static const empty = SnippetMetadata();

  bool get isEmpty =>
      (description == null || description!.isEmpty) &&
      variableDescriptions.isEmpty &&
      (defaultConnectionId == null || defaultConnectionId!.isEmpty);

  SnippetMetadata copyWith({
    String? description,
    Map<String, String>? variableDescriptions,
    String? defaultConnectionId,
  }) {
    return SnippetMetadata(
      description: description ?? this.description,
      variableDescriptions: variableDescriptions ?? this.variableDescriptions,
      defaultConnectionId: defaultConnectionId ?? this.defaultConnectionId,
    );
  }
}

/// Decode a `Snippets.metadata` string. Tolerant: a null, empty, or malformed
/// value yields [SnippetMetadata.empty] rather than throwing.
SnippetMetadata parseSnippetMetadata(String? raw) {
  if (raw == null || raw.trim().isEmpty) return SnippetMetadata.empty;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return SnippetMetadata.empty;
    final desc = decoded['description'];
    final vars = decoded['variables'];
    final defaultConn = decoded['defaultConnectionId'];
    final varMap = <String, String>{};
    if (vars is Map) {
      vars.forEach((k, v) {
        if (k is String && v is String && v.isNotEmpty) varMap[k] = v;
      });
    }
    return SnippetMetadata(
      description: desc is String && desc.isNotEmpty ? desc : null,
      variableDescriptions: varMap,
      defaultConnectionId:
          defaultConn is String && defaultConn.isNotEmpty ? defaultConn : null,
    );
  } catch (_) {
    return SnippetMetadata.empty;
  }
}

/// Encode [meta] to a JSON string, or `null` when empty (so an untouched
/// snippet stores NULL rather than `{}` - keeps the column and sync blob clean).
String? encodeSnippetMetadata(SnippetMetadata meta) {
  if (meta.isEmpty) return null;
  return jsonEncode({
    if (meta.description != null && meta.description!.isNotEmpty)
      'description': meta.description,
    if (meta.variableDescriptions.isNotEmpty)
      'variables': meta.variableDescriptions,
    if (meta.defaultConnectionId != null &&
        meta.defaultConnectionId!.isNotEmpty)
      'defaultConnectionId': meta.defaultConnectionId,
  });
}

/// Parse PM2 JSON output into a list of process names.
List<String> parsePm2Output(String jsonOutput) {
  try {
    // pm2 jlist outputs a JSON array of process objects
    final decoded = jsonOutput.trim();
    // Simple extraction: find all "name":"value" pairs
    final nameRegex = RegExp(r'"name"\s*:\s*"([^"]+)"');
    return nameRegex
        .allMatches(decoded)
        .map((m) => m.group(1)!)
        .toSet()
        .toList();
  } catch (_) {
    return [];
  }
}

// ── Default snippet library ─────────────────────────────────────

class _DefaultSnippet {
  final String label;
  final String command;
  final String category;
  final bool confirm;
  final int sort;

  const _DefaultSnippet(
    this.label,
    this.command,
    this.category,
    this.sort, {
    this.confirm = false,
  });
}

const _defaultSnippets = [
  // System
  _DefaultSnippet('System Stats', r'top -bn1 | head -20', 'System', 0),
  _DefaultSnippet('Disk Usage', 'df -h', 'System', 1),
  _DefaultSnippet('Memory Usage', 'free -h', 'System', 2),
  _DefaultSnippet('Uptime', 'uptime', 'System', 3),
  _DefaultSnippet("Who's Online", 'w', 'System', 4),
  _DefaultSnippet('CPU Info', 'lscpu | head -15', 'System', 5),
  _DefaultSnippet(
    'Running Processes',
    'ps aux --sort=-%mem | head -20',
    'System',
    6,
  ),
  _DefaultSnippet('Kernel Version', 'uname -a', 'System', 7),
  _DefaultSnippet('Reboot', 'sudo reboot', 'System', 8, confirm: true),

  // Services
  _DefaultSnippet(
    'Running Services',
    'systemctl list-units --type=service --state=running',
    'Services',
    0,
  ),
  _DefaultSnippet(
    'Service Status',
    r'sudo systemctl status $[SYSTEMD]',
    'Services',
    1,
  ),
  _DefaultSnippet(
    'Restart Service',
    r'sudo systemctl restart $[SYSTEMD]',
    'Services',
    2,
  ),
  _DefaultSnippet(
    'Stop Service',
    r'sudo systemctl stop $[SYSTEMD]',
    'Services',
    3,
  ),
  _DefaultSnippet(
    'View Logs',
    r"sudo journalctl -u $[SYSTEMD] --since '10 min ago' --no-pager | tail -30",
    'Services',
    4,
  ),
  _DefaultSnippet(
    'Follow Logs',
    r'sudo journalctl -u $[SYSTEMD] -f',
    'Services',
    5,
  ),
  _DefaultSnippet(
    'Enable Service',
    r'sudo systemctl enable $[SYSTEMD]',
    'Services',
    6,
  ),

  // Docker
  _DefaultSnippet('Running Containers', 'docker ps', 'Docker', 0),
  _DefaultSnippet('All Containers', 'docker ps -a', 'Docker', 1),
  _DefaultSnippet(
    'Container Logs',
    r'docker logs $[DOCKER] --tail 50',
    'Docker',
    2,
  ),
  _DefaultSnippet(
    'Follow Container Logs',
    r'docker logs $[DOCKER] -f',
    'Docker',
    3,
  ),
  _DefaultSnippet(
    'Restart Container',
    r'docker restart $[DOCKER]',
    'Docker',
    4,
  ),
  _DefaultSnippet('Stop Container', r'docker stop $[DOCKER]', 'Docker', 5),
  _DefaultSnippet(
    'Container Shell',
    r'docker exec -it $[DOCKER] /bin/sh',
    'Docker',
    6,
  ),
  _DefaultSnippet('Docker Stats', 'docker stats --no-stream', 'Docker', 7),
  _DefaultSnippet('Docker Disk Usage', 'docker system df', 'Docker', 8),
  _DefaultSnippet(
    'Prune Unused',
    'docker system prune -f',
    'Docker',
    9,
    confirm: true,
  ),

  // Network
  _DefaultSnippet('My Public IP', 'curl -s ifconfig.me', 'Network', 0),
  _DefaultSnippet('Listening Ports', 'ss -tlnp', 'Network', 1),
  _DefaultSnippet('DNS Lookup', r'dig ${DOMAIN}', 'Network', 2),
  _DefaultSnippet('Ping', r'ping -c 4 ${HOST}', 'Network', 3),
  _DefaultSnippet('Traceroute', r'traceroute ${HOST}', 'Network', 4),
  _DefaultSnippet('Connections', 'ss -s', 'Network', 5),
  _DefaultSnippet('Firewall Rules', 'sudo iptables -L -n', 'Network', 6),
  _DefaultSnippet('ARP Table', 'arp -a', 'Network', 7),

  // Files
  _DefaultSnippet(
    'Large Files',
    'find / -type f -size +100M 2>/dev/null | head -20',
    'Files',
    0,
  ),
  _DefaultSnippet(
    'Dir Sizes',
    'du -sh /* 2>/dev/null | sort -rh | head -10',
    'Files',
    1,
  ),
  _DefaultSnippet('Tail Log', r'tail -f ${LOGFILE}', 'Files', 2),
  _DefaultSnippet('Last 50 Lines', r'tail -n 50 ${LOGFILE}', 'Files', 3),
  _DefaultSnippet(
    'Find File',
    r"find / -name '${FILENAME}' 2>/dev/null",
    'Files',
    4,
  ),
  _DefaultSnippet('File Permissions', r'ls -la ${PATH}', 'Files', 5),
  _DefaultSnippet('Disk Partitions', 'lsblk', 'Files', 6),

  // Security
  _DefaultSnippet('Failed Logins', 'sudo lastb | head -20', 'Security', 0),
  _DefaultSnippet('Last Logins', 'last -20', 'Security', 1),
  _DefaultSnippet('Open Ports', 'sudo nmap -sT localhost', 'Security', 2),
  _DefaultSnippet('Auth Log', 'sudo tail -50 /var/log/auth.log', 'Security', 3),
  _DefaultSnippet('Active SSH Sessions', 'who', 'Security', 4),
  _DefaultSnippet('Check Sudo Users', 'getent group sudo', 'Security', 5),

  // Package Management
  _DefaultSnippet(
    'Update (Debian)',
    'sudo apt update && sudo apt upgrade -y',
    'Packages',
    0,
    confirm: true,
  ),
  _DefaultSnippet(
    'Update (RHEL)',
    'sudo dnf update -y',
    'Packages',
    1,
    confirm: true,
  ),
  _DefaultSnippet('Installed Packages', 'dpkg -l | wc -l', 'Packages', 2),
  _DefaultSnippet(
    'Available Updates',
    'apt list --upgradable 2>/dev/null',
    'Packages',
    3,
  ),
];
