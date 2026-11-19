import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/models/network.dart' show kDefaultNetworkId;
import 'package:zestssh/features/orchards/guardrails.dart' show isOrchardWriteRefused;
import 'package:zestssh/features/orchards/orchard_providers.dart' show OrchardSummary, CrateSummary, readOrchardSummary;
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show CrateClosedOffline;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart';
import 'package:zestssh/models/enums.dart' show AuthMethod, ConnectionProtocol;
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

// Move to... and Copy to... (3.4: as in
// 1Password, a quick pick of the vault, where there is write access). Hosts,
// keys, snippets and port forwards go from Personal to a team's vault, back,
// from one team to another, and between the vaults of one team.
//
// Nothing new is sent anywhere: an item arriving in a team is written into
// that team's own database on this device and put into its vault, exactly as
// saving a new item there does; its vault's sync seals it with the vault's
// key on the next sync, and the database's write guard refuses it where this
// account may not add (AppDatabase.createOrchardTriggers). An item arriving
// in Personal is a new row of your own database, which your own sync carries.
// A key's secrets go from where its space keeps them to where the other
// keeps them (IdentitySecretStore): the OS secure storage, or a team's
// database.
//
// Each item of a batch is written whole or not at all (a savepoint of its
// own in one transaction where it lands), and only one that arrived leaves
// where it was (Move): what could not go stays where it was and is named.

/// Whether a batch leaves its items where they were (Copy) or not (Move).
enum TransferMode { move, copy }

/// The kinds Move to... and Copy to... take, as the items' records name them.
abstract final class TransferKinds {
  static const host = 'host';
  static const key = 'key';
  static const snippet = 'snippet';
  static const forward = 'forward';

  static const all = {host, key, snippet, forward};
}

/// Where an item can be saved: Personal, or a vault of a team.
@immutable
class SavePlace {
  const SavePlace.personal()
      : orchardId = null,
        crateId = null;

  const SavePlace.vault(String this.orchardId, String this.crateId);

  final String? orchardId;
  final String? crateId;

  bool get isPersonal => orchardId == null;

  Space get space => orchardId == null ? const TreeSpace() : OrchardSpace(orchardId!);

  @override
  bool operator ==(Object other) => other is SavePlace && other.orchardId == orchardId && other.crateId == crateId;

  @override
  int get hashCode => Object.hash(orchardId, crateId);

  @override
  String toString() => isPersonal ? 'SavePlace(personal)' : 'SavePlace($orchardId/$crateId)';
}

/// What a linked item is to the items that use it.
enum LinkKind { key, host, network, snippet }

/// What to do with a linked item the place does not have.
enum LinkChoice { move, copy, leave }

/// A linked item, by kind and key in the space the batch comes from.
@immutable
class LinkRef {
  const LinkRef(this.kind, this.key);

  final LinkKind kind;
  final String key;

  @override
  bool operator ==(Object other) => other is LinkRef && other.kind == kind && other.key == key;

  @override
  int get hashCode => Object.hash(kind, key);

  @override
  String toString() => 'LinkRef(${kind.name}, $key)';
}

/// Why an item did not go, or could not.
enum TransferRefusal {
  /// It is already there (nothing to do; never said as a failure).
  alreadyThere,

  /// It is not there any more.
  notFound,

  /// Its vault is closed on this device by its offline limit.
  closedOffline,

  /// Move: this account may not delete it where it is.
  mayNotRemove,

  /// The place does not let this account add.
  mayNotAdd,

  /// A team's items leave it only as its owners take them (the rule for an
  /// export, a share or a QR code: the whitepaper's guardrails).
  ownersOnly,

  /// The team's rules keep its items in it (no export).
  teamKeepsItems,

  /// A key whose secrets this account may not see does not leave its vault:
  /// its secrets would be seen wherever it went.
  keySecretsHidden,

  /// A team certificate, or the key a vault's certificates are signed with,
  /// belongs to its vault.
  keyBelongsToVault,

  /// A local shell is never a team's (it runs on the computer of whoever
  /// opens it).
  localShellNotInTeam,

  /// A port forward goes with its host, which stays.
  needsItsHost,

  /// Something it uses could not go with it.
  linkFailed,

  /// The database refused the write (its write guard).
  writeRefused,

  /// Anything else; the log names it.
  failed,
}

/// An item that did not go, or could not, and why.
@immutable
class TransferProblem {
  const TransferProblem({required this.kind, required this.key, required this.label, required this.reason, this.link});

  final String kind;
  final String key;
  final String label;
  final TransferRefusal reason;

  /// For [TransferRefusal.linkFailed]: the label of what could not go.
  final String? link;

  @override
  String toString() => 'TransferProblem($kind $key: ${reason.name})';
}

/// A linked item the place does not have, as the question asks about it.
@immutable
class TransferLink {
  const TransferLink({
    required this.ref,
    required this.label,
    required this.choices,
    required this.usedElsewhere,
    this.refusal,
    this.neededByForward = false,
  });

  final LinkRef ref;
  final String label;

  /// What may be done with it: always [LinkChoice.leave].
  final Set<LinkChoice> choices;

  /// How many items where it is, not in the batch, use it too: moved, they
  /// lose it.
  final int usedElsewhere;

  /// Why it can be neither moved nor copied (or not moved), where it cannot.
  final TransferRefusal? refusal;

  /// A port forward of the batch is for this host: left, the forward stays.
  final bool neededByForward;

  /// What the question starts on: a copy where one may be made (nothing
  /// where it is loses it), else leaving it.
  LinkChoice get suggested => choices.contains(LinkChoice.copy) ? LinkChoice.copy : LinkChoice.leave;
}

/// A new item an editor made, captured before it was written anywhere
/// ("Save in", 3.4): its rows as a record carries them and, for a key, its
/// secrets.
@immutable
class ItemDraft {
  const ItemDraft({required this.kind, required this.key, required this.rows, this.secrets = const {}});

  final String kind;
  final String key;
  final Map<String, Object?> rows;
  final Map<IdentitySecret, String> secrets;
}

/// What one item of a batch is, while it is planned and written.
class _Unit {
  _Unit({required this.kind, required this.key, required this.label, required this.rows, this.primary = false});

  final String kind;
  final String key;
  final String label;
  Map<String, Object?> rows;
  final bool primary;

  /// For a key: its secrets, read where its space keeps them.
  Map<IdentitySecret, String> secrets = const {};

  /// The vault it is in (a team's item), where it was read.
  String? crateId;

  /// Its key where it lands.
  String? newKey;

  /// A host's port forwards, which go with it.
  final List<_Unit> forwards = [];

  /// What it uses, by link.
  final List<LinkRef> uses = [];

  /// Move, or Copy (a linked item's: as its question was answered).
  TransferMode mode = TransferMode.copy;
}

/// A batch worked out: what can go, what cannot, and the linked items the
/// place does not have ([links]), which the person answers before [ItemTransfer.run].
class TransferPlan {
  TransferPlan._({
    required this.from,
    required this.to,
    required this.mode,
    required this.kind,
    required this.sameDatabase,
    required List<_Unit> ready,
    required this.refused,
    required this.links,
    required Map<LinkRef, _Unit> linked,
    required this.leftBehind,
    required this.isDraft,
    required AppDatabase source,
    required AppDatabase target,
  })  : _ready = ready,
        _linked = linked,
        _source = source,
        _target = target;

  final Space from;
  final SavePlace to;
  final TransferMode mode;
  final String kind;

  /// Within one team (a vault to another): its links stay as they are.
  final bool sameDatabase;

  /// A new item from an editor ("Save in"), not one from a list.
  final bool isDraft;

  final List<_Unit> _ready;

  /// What cannot go, and why ([TransferRefusal.alreadyThere] among them,
  /// which is no failure).
  final List<TransferProblem> refused;

  /// The linked items the place does not have, to be answered.
  final List<TransferLink> links;
  final Map<LinkRef, _Unit> _linked;

  /// Move: how many items where they are, not moving, use what moves (a key,
  /// a jump host, a snippet): they lose it.
  final int leftBehind;

  final AppDatabase _source;
  final AppDatabase _target;

  /// How many items will go.
  int get readyCount => _ready.length;

  /// The labels of the items that will go, in order.
  List<String> get readyLabels => [for (final u in _ready) u.label];

  /// The keys of the items that will go, where they are now.
  List<String> get readyKeys => [for (final u in _ready) u.key];

  /// The items that cannot go, [TransferRefusal.alreadyThere] left out.
  List<TransferProblem> get problems => [
        for (final p in refused)
          if (p.reason != TransferRefusal.alreadyThere) p,
      ];
}

/// What a batch did.
@immutable
class TransferResult {
  const TransferResult({required this.done, required this.failed, required this.newKeys, this.copiedInstead = const []});

  /// How many of the batch's own items went.
  final int done;

  /// The batch's items that did not go (each stays where it was), and why:
  /// those refused before anything was written too.
  final List<TransferProblem> failed;

  /// Each item that went, by its key where it was: its key where it is now.
  final Map<String, String> newKeys;

  /// Linked items that were to move and were copied instead (they could not
  /// leave where they were), by label.
  final List<String> copiedInstead;
}

/// Told that a key of a team, with its secrets, now also is (Copy) or only is
/// (Move) outside that team: [team] is the team's database, [key] the key's
/// id there and [crateId] the vault it was in.
typedef KeyLeftTeam = Future<void> Function(AppDatabase team, {required String key, required String label, String? crateId});

/// Moves and copies items between Personal and the vaults of teams.
class ItemTransfer {
  ItemTransfer({
    required this.tree,
    required this.openTeam,
    required this.storage,
    this.onKeyLeftTeam,
    String Function()? newId,
  }) : _newId = newId ?? (() => const Uuid().v4());

  /// Called once for each key whose secrets left a team (to Personal or to
  /// another team), after it is written there: the batch's own keys and the
  /// keys that went along with a host. Not for a key that stays in its team
  /// (another vault of it), nor for one whose copy was taken back.
  final KeyLeftTeam? onKeyLeftTeam;

  /// Your own database (Personal).
  final AppDatabase tree;

  /// Opens a team's database on this device.
  final Future<AppDatabase> Function(String orchardId) openTeam;

  /// Where Personal keys keep their secrets.
  final FlutterSecureStorage storage;

  final String Function() _newId;

  Future<AppDatabase> _db(Space space) async => space is OrchardSpace ? openTeam(space.orchardId) : tree;

  /// Works out a batch of [keys] of [kind] from [from] to [to]. [kept] adds
  /// refusals the screen knows of (a key a vault signs certificates with).
  Future<TransferPlan> plan({
    required Space from,
    required String kind,
    required List<String> keys,
    required SavePlace to,
    required TransferMode mode,
    Map<String, TransferRefusal> kept = const {},
  }) async {
    if (!TransferKinds.all.contains(kind)) throw ArgumentError.value(kind, 'kind');
    final source = await _db(from);
    final target = await _db(to.space);
    final sourceTeam = from is OrchardSpace ? await readOrchardSummary(source, from.orchardId) : null;
    final targetTeam = to.isPersonal ? null : await readOrchardSummary(target, to.orchardId!);
    final same = identical(source, target);
    final store = OrchardItemStore(source);
    final placement = source.isOrchard ? CratePlacement(source) : null;

    final ready = <_Unit>[];
    final refused = <TransferProblem>[];
    final targetRefusal = _targetRefusal(targetTeam, to);
    for (final key in {...keys}) {
      final rows = await store.read(kind, key);
      if (rows == null) {
        refused.add(TransferProblem(kind: kind, key: key, label: key, reason: TransferRefusal.notFound));
        continue;
      }
      final unit = _Unit(kind: kind, key: key, label: _labelOf(kind, rows), rows: rows, primary: true)..mode = mode;
      unit.crateId = await placement?.crateOf(kind, key);
      final reason = kept[key] ??
          (from is TreeSpace && to.isPersonal || (same && unit.crateId == to.crateId)
              ? TransferRefusal.alreadyThere
              : null) ??
          targetRefusal ??
          await _sourceRefusal(source, sourceTeam, unit, to, mode) ??
          _arrivalRefusal(unit, to);
      if (reason != null) {
        refused.add(TransferProblem(kind: kind, key: key, label: unit.label, reason: reason));
        continue;
      }
      ready.add(unit);
    }

    // A host's port forwards go with it.
    for (final u in ready) {
      if (u.kind == TransferKinds.host) await _carryForwards(source, u);
    }

    final linked = <LinkRef, _Unit>{};
    final links = <TransferLink>[];
    if (!same) {
      await _gatherLinks(
        source: source,
        target: target,
        sourceTeam: sourceTeam,
        to: to,
        ready: ready,
        linked: linked,
        links: links,
      );
    }
    final leftBehind = mode == TransferMode.move && !same ? await _usersLeftBehind(source, ready) : 0;
    return TransferPlan._(
      from: from,
      to: to,
      mode: mode,
      kind: kind,
      sameDatabase: same,
      ready: ready,
      refused: refused,
      links: links,
      linked: linked,
      leftBehind: leftBehind,
      isDraft: false,
      source: source,
      target: target,
    );
  }

  /// Works out where a new item an editor made goes ([draft], "Save in"),
  /// from the space on screen [from], whose items it may use.
  Future<TransferPlan> planDraft({required Space from, required ItemDraft draft, required SavePlace to}) async {
    final source = await _db(from);
    final target = await _db(to.space);
    final sourceTeam = from is OrchardSpace ? await readOrchardSummary(source, from.orchardId) : null;
    final targetTeam = to.isPersonal ? null : await readOrchardSummary(target, to.orchardId!);
    final same = identical(source, target);
    final unit = _Unit(kind: draft.kind, key: draft.key, label: _labelOf(draft.kind, draft.rows), rows: draft.rows, primary: true)
      ..mode = TransferMode.copy
      ..secrets = draft.secrets;
    final refused = <TransferProblem>[];
    // A team certificate is made for its team's vault and nowhere else.
    final certificate = draft.kind == TransferKinds.key &&
        _main(unit)?['auth_method'] == AuthMethod.teamCertificate.name &&
        !same;
    final reason = (certificate ? TransferRefusal.keyBelongsToVault : null) ??
        _targetRefusal(targetTeam, to) ??
        _arrivalRefusal(unit, to);
    final ready = <_Unit>[];
    if (reason != null) {
      refused.add(TransferProblem(kind: unit.kind, key: unit.key, label: unit.label, reason: reason));
    } else {
      ready.add(unit);
    }
    final linked = <LinkRef, _Unit>{};
    final links = <TransferLink>[];
    if (!same && ready.isNotEmpty) {
      await _gatherLinks(
        source: source,
        target: target,
        sourceTeam: sourceTeam,
        to: to,
        ready: ready,
        linked: linked,
        links: links,
      );
    }
    return TransferPlan._(
      from: from,
      to: to,
      mode: TransferMode.copy,
      kind: draft.kind,
      sameDatabase: same,
      ready: ready,
      refused: refused,
      links: links,
      linked: linked,
      leftBehind: 0,
      isDraft: true,
      source: source,
      target: target,
    );
  }

  // ── Rights ──────────────────────────────────────────────────────────────

  /// What [plan]'s source and target teams allow as [run] starts, read again
  /// from their databases: why a unit may not go now (with a mode), or null.
  Future<({Future<TransferRefusal?> Function(_Unit unit, TransferMode mode) refusal})> _rightsNow(
      TransferPlan plan) async {
    final from = plan.from;
    final to = plan.to;
    final sourceTeam = from is OrchardSpace ? await readOrchardSummary(plan._source, from.orchardId) : null;
    final targetTeam = to.isPersonal ? null : await readOrchardSummary(plan._target, to.orchardId!);
    final target = _targetRefusal(targetTeam, to);
    return (
      refusal: (_Unit unit, TransferMode mode) async =>
          target ??
          // (A new item an editor made is nowhere yet: it leaves nothing.)
          (plan.isDraft && unit.primary ? null : await _sourceRefusal(plan._source, sourceTeam, unit, to, mode)) ??
          _arrivalRefusal(unit, to),
    );
  }

  /// Why nothing at all can arrive at [to], or null.
  TransferRefusal? _targetRefusal(OrchardSummary? team, SavePlace to) {
    if (to.isPersonal) return null;
    if (team == null || !team.active) return TransferRefusal.mayNotAdd;
    final crate = team.crates.where((c) => c.id == to.crateId).firstOrNull;
    if (crate == null) return TransferRefusal.mayNotAdd;
    if (crate.closedOffline) return TransferRefusal.closedOffline;
    if (!crate.canAdd) return TransferRefusal.mayNotAdd;
    return null;
  }

  /// Why [unit] may not arrive at [to] as what it is, or null: a local shell
  /// is never a team's. (An FTPS host goes into a team as any host does, 3.4:
  /// its record there is one versions before 3.4 do not read.)
  TransferRefusal? _arrivalRefusal(_Unit unit, SavePlace to) {
    if (unit.kind != TransferKinds.host || to.isPersonal) return null;
    final protocol = _main(unit)?['protocol'] as String?;
    return teamMayNotOpenWith(protocol) ? TransferRefusal.localShellNotInTeam : null;
  }

  /// Why [unit] may not leave where it is for [to] ([mode]), or null. What a
  /// team's own screens allow for one item: Move deletes it where it is
  /// (delete there, or add for one that never reached its vault: the write
  /// guard's rule); a key that leaves its vault takes its secrets where
  /// others may see them (reveal); and an item that leaves the team follows
  /// the rule for exports (its owners, and not where its rules say no).
  Future<TransferRefusal?> _sourceRefusal(
      AppDatabase source, OrchardSummary? team, _Unit unit, SavePlace to, TransferMode mode) async {
    if (unit.kind == TransferKinds.key) {
      final method = _main(unit)?['auth_method'];
      if (method == AuthMethod.teamCertificate.name) return TransferRefusal.keyBelongsToVault;
    }
    if (team == null) return null;
    final crate = team.crates.where((c) => c.id == unit.crateId).firstOrNull;
    if (crate == null || crate.closedOffline) return TransferRefusal.closedOffline;
    if (mode == TransferMode.move && !await _mayRemove(source, crate, unit.kind, unit.key)) {
      return TransferRefusal.mayNotRemove;
    }
    final leaves = to.orchardId != team.id;
    if (leaves) {
      if (team.rules.noExport) return TransferRefusal.teamKeepsItems;
      if (!team.isOwner) return TransferRefusal.ownersOnly;
    }
    if (unit.kind == TransferKinds.key && to.crateId != crate.id && !crate.allows(CrateSwitches.reveal)) {
      return TransferRefusal.keySecretsHidden;
    }
    return null;
  }

  /// Whether this account may delete the item where it is: delete in its
  /// vault, or add there for one that never reached it (the write guard's
  /// own rule).
  Future<bool> _mayRemove(AppDatabase db, CrateSummary crate, String kind, String key) async {
    final row = await db.customSelect(
      'SELECT server_revision, server_deleted FROM crate_items_meta WHERE kind = ? AND item_key = ?',
      variables: [Variable(kind), Variable(key)],
    ).getSingleOrNull();
    final onServer = row?.read<int?>('server_revision') != null && row?.read<int>('server_deleted') == 0;
    return crate.allows(onServer ? CrateSwitches.delete : CrateSwitches.add);
  }

  // ── Links ───────────────────────────────────────────────────────────────

  Future<void> _carryForwards(AppDatabase source, _Unit host) async {
    final store = OrchardItemStore(source);
    final placement = source.isOrchard ? CratePlacement(source) : null;
    final ids = await source.customSelect('SELECT id FROM port_forward_rules WHERE connection_id = ? ORDER BY id',
        variables: [Variable(host.key)]).get();
    for (final r in ids) {
      final id = r.read<String>('id');
      final rows = await store.read(TransferKinds.forward, id);
      if (rows == null) continue;
      host.forwards.add(_Unit(kind: TransferKinds.forward, key: id, label: _labelOf(TransferKinds.forward, rows), rows: rows)
        ..crateId = await placement?.crateOf(TransferKinds.forward, id));
    }
  }

  /// Every item the units use that [target] does not have, followed through
  /// what those use in turn (a jump host's own key).
  Future<void> _gatherLinks({
    required AppDatabase source,
    required AppDatabase target,
    required OrchardSummary? sourceTeam,
    required SavePlace to,
    required List<_Unit> ready,
    required Map<LinkRef, _Unit> linked,
    required List<TransferLink> links,
  }) async {
    final batch = {for (final u in ready) '${u.kind}/${u.key}'};
    final neededByForward = <LinkRef>{};
    final queue = <_Unit>[...ready];
    while (queue.isNotEmpty) {
      final u = queue.removeLast();
      final refs = _refsOf(u);
      for (final f in u.forwards) {
        f.uses.addAll(_refsOf(f));
      }
      u.uses.addAll(refs);
      if (u.kind == TransferKinds.forward) {
        final host = _main(u)?['connection_id'] as String?;
        if (host != null) neededByForward.add(LinkRef(LinkKind.host, host));
      }
      for (final ref in {...refs, for (final f in u.forwards) ..._refsOf(f)}) {
        if (linked.containsKey(ref) || batch.contains('${_kindOf(ref.kind)}/${ref.key}')) continue;
        if (ref.kind == LinkKind.network && ref.key == kDefaultNetworkId) continue;
        final kind = _kindOf(ref.kind);
        final rows = await OrchardItemStore(source).read(kind, ref.key);
        if (rows == null) continue; // A link to nothing: nothing to take.
        final unit = _Unit(kind: kind, key: ref.key, label: _labelOf(kind, rows), rows: rows);
        if (source.isOrchard) unit.crateId = await CratePlacement(source).crateOf(kind, ref.key);
        if (kind == TransferKinds.host) await _carryForwards(source, unit);
        linked[ref] = unit;
        queue.add(unit);
      }
    }
    final targetRefusal = _targetRefusal(await _teamOf(target, to), to);
    for (final MapEntry(key: ref, value: unit) in linked.entries) {
      final copyRefusal =
          targetRefusal ?? await _sourceRefusal(source, sourceTeam, unit, to, TransferMode.copy) ?? _arrivalRefusal(unit, to);
      final moveRefusal = copyRefusal ?? await _sourceRefusal(source, sourceTeam, unit, to, TransferMode.move);
      links.add(TransferLink(
        ref: ref,
        label: unit.label,
        choices: {
          LinkChoice.leave,
          if (copyRefusal == null) LinkChoice.copy,
          if (moveRefusal == null) LinkChoice.move,
        },
        refusal: copyRefusal ?? moveRefusal,
        usedElsewhere: await _usersOf(source, ref, exclude: {for (final u in ready) u.key}),
        neededByForward: neededByForward.contains(ref),
      ));
    }
    links.sort((a, b) {
      final k = a.ref.kind.index.compareTo(b.ref.kind.index);
      return k != 0 ? k : a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
  }

  Future<OrchardSummary?> _teamOf(AppDatabase db, SavePlace to) async =>
      to.isPersonal ? null : await readOrchardSummary(db, to.orchardId!);

  static String _kindOf(LinkKind kind) => switch (kind) {
        LinkKind.key => TransferKinds.key,
        LinkKind.host => TransferKinds.host,
        LinkKind.network => 'network',
        LinkKind.snippet => TransferKinds.snippet,
      };

  /// What [unit] uses: a host's key, other accounts, jump host, startup
  /// snippet and its networks' own keys and jump hosts; a forward's host and
  /// networks; a network's VPN host is not followed (left, it is cleared).
  static List<LinkRef> _refsOf(_Unit unit) {
    final out = <LinkRef>[];
    void add(LinkKind kind, Object? key) {
      if (key is String && key.isNotEmpty) out.add(LinkRef(kind, key));
    }

    switch (unit.kind) {
      case TransferKinds.host:
        final row = _main(unit);
        add(LinkKind.key, row?['identity_id']);
        add(LinkKind.host, row?['connect_via_id']);
        add(LinkKind.snippet, row?['snippet_id']);
        for (final a in _rows(unit, 'host_accounts')) {
          add(LinkKind.key, a['identity_id']);
        }
        for (final o in _rows(unit, 'host_network_overrides')) {
          add(LinkKind.network, o['network_id']);
          add(LinkKind.key, o['identity_id']);
          add(LinkKind.host, o['jump_host_id']);
          for (final id in _chain(o['jump_chain_json'])) {
            add(LinkKind.host, id);
          }
        }
      case TransferKinds.forward:
        final row = _main(unit);
        add(LinkKind.host, row?['connection_id']);
        add(LinkKind.network, row?['network_id']);
        for (final o in _rows(unit, 'port_forward_network_overrides')) {
          add(LinkKind.network, o['network_id']);
        }
    }
    return out;
  }

  static List<String> _chain(Object? json) {
    if (json is! String || json.isEmpty) return const [];
    try {
      final decoded = jsonDecode(json);
      return [
        if (decoded is List)
          for (final id in decoded)
            if (id is String) id,
      ];
    } on FormatException {
      return const [];
    }
  }

  /// How many items of [db], besides [exclude], use [ref].
  Future<int> _usersOf(AppDatabase db, LinkRef ref, {required Set<String> exclude}) async {
    final List<String> sql = switch (ref.kind) {
      LinkKind.key => [
          'SELECT id AS k FROM connections WHERE identity_id = ?',
          'SELECT connection_id AS k FROM host_accounts WHERE identity_id = ?',
          'SELECT connection_id AS k FROM host_network_overrides WHERE identity_id = ?',
        ],
      LinkKind.host => [
          'SELECT id AS k FROM connections WHERE connect_via_id = ?',
          'SELECT connection_id AS k FROM host_network_overrides WHERE jump_host_id = ?',
          'SELECT id AS k FROM port_forward_rules WHERE connection_id = ?',
        ],
      LinkKind.network => [
          'SELECT connection_id AS k FROM host_network_overrides WHERE network_id = ?',
          'SELECT id AS k FROM port_forward_rules WHERE network_id = ?',
        ],
      LinkKind.snippet => ['SELECT id AS k FROM connections WHERE snippet_id = ?'],
    };
    final users = <String>{};
    for (final q in sql) {
      for (final r in await db.customSelect(q, variables: [Variable(ref.key)]).get()) {
        users.add(r.read<String>('k'));
      }
    }
    users.removeAll(exclude);
    return users.length;
  }

  /// Move to another space: how many items left where they are use one that
  /// moves.
  Future<int> _usersLeftBehind(AppDatabase source, List<_Unit> ready) async {
    final moving = {for (final u in ready) u.key};
    final users = <String>{};
    for (final u in ready) {
      final kind = switch (u.kind) {
        TransferKinds.key => LinkKind.key,
        TransferKinds.host => LinkKind.host,
        TransferKinds.snippet => LinkKind.snippet,
        _ => null,
      };
      if (kind == null) continue;
      final n = await _usersOf(source, LinkRef(kind, u.key), exclude: moving);
      if (n > 0) users.add(u.key);
    }
    if (users.isEmpty) return 0;
    var total = 0;
    for (final u in ready) {
      if (!users.contains(u.key)) continue;
      final kind = switch (u.kind) {
        TransferKinds.key => LinkKind.key,
        TransferKinds.host => LinkKind.host,
        _ => LinkKind.snippet,
      };
      total += await _usersOf(source, LinkRef(kind, u.key), exclude: moving);
    }
    return total;
  }

  // ── Doing it ────────────────────────────────────────────────────────────

  /// Does [plan], with each linked item as [choices] says ([TransferLink.suggested]
  /// for one not answered; a choice its item does not allow is taken as
  /// leaving it).
  Future<TransferResult> run(TransferPlan plan, {Map<LinkRef, LinkChoice> choices = const {}}) async {
    final failed = <TransferProblem>[
      for (final p in plan.refused)
        if (p.reason != TransferRefusal.alreadyThere) p,
    ];
    // The team's rules as they are now, not as they were when the plan was
    // made: a sync while the questions were asked may have turned on "keep
    // items in the team", taken an owner's role or a vault's add or reveal
    // (found in a security review). What no longer may go is said as not
    // done.
    final rightsNow = await _rightsNow(plan);
    for (final u in [...plan._ready]) {
      final reason = await rightsNow.refusal(u, u.mode);
      if (reason == null) continue;
      plan._ready.remove(u);
      failed.add(TransferProblem(kind: u.kind, key: u.key, label: u.label, reason: reason));
    }
    if (plan._ready.isEmpty) return TransferResult(done: 0, failed: failed, newKeys: const {});
    if (plan.sameDatabase && plan.mode == TransferMode.move && !plan.isDraft) {
      return _moveWithinTeam(plan, failed);
    }

    // Which linked items go, and how: only those reached through what goes.
    final allowed = {for (final l in plan.links) l.ref: l.choices};
    LinkChoice choiceOf(LinkRef ref) {
      final picked = choices[ref] ?? plan.links.where((l) => l.ref == ref).firstOrNull?.suggested ?? LinkChoice.leave;
      return (allowed[ref] ?? const {LinkChoice.leave}).contains(picked) ? picked : LinkChoice.leave;
    }

    final taken = <LinkRef, _Unit>{};
    final queue = <_Unit>[...plan._ready];
    while (queue.isNotEmpty) {
      final u = queue.removeLast();
      for (final ref in {...u.uses, for (final f in u.forwards) ...f.uses}) {
        final unit = plan._linked[ref];
        if (unit == null || taken.containsKey(ref)) continue;
        final choice = choiceOf(ref);
        if (choice == LinkChoice.leave) continue;
        final mode = choice == LinkChoice.move ? TransferMode.move : TransferMode.copy;
        // (One the rules no longer let go, now, is left where it is.)
        if (await rightsNow.refusal(unit, mode) != null) continue;
        unit.mode = mode;
        taken[ref] = unit;
        queue.add(unit);
      }
    }

    // Every item's key where it lands, before anything is written: items
    // that use each other are written in any order. A new item an editor made
    // keeps the key it was made with (it is nowhere yet).
    final idOf = <String, String>{}; // 'kind/key' -> new key
    void assign(_Unit u) {
      u.newKey = plan.isDraft && u.primary ? u.key : _newId();
      idOf['${u.kind}/${u.key}'] = u.newKey!;
      for (final f in u.forwards) {
        assign(f);
      }
    }

    for (final u in [...taken.values, ...plan._ready]) {
      assign(u);
    }

    final target = plan._target;
    final targetSecrets = IdentitySecretStore.forDatabase(target, storage);
    final sourceSecrets = IdentitySecretStore.forDatabase(plan._source, storage);
    // A key's secrets, read where its space keeps them, before anything is
    // written (a vault closed offline refuses to hand them out).
    for (final u in [...taken.values, ...plan._ready]) {
      if (u.kind != TransferKinds.key || u.secrets.isNotEmpty) continue;
      try {
        u.secrets = await _readSecrets(sourceSecrets, u.key);
      } catch (e) {
        u.secrets = const {};
        u.newKey = null; // Marked: it cannot go.
        AppLogger.warning('Move/copy: a key\'s secrets could not be read (${errorKind(e)})');
      }
    }

    final failedUnits = <_Unit>{};
    final written = <_Unit>{};
    final reasons = <_Unit, (TransferRefusal, String?)>{};
    final writtenSecrets = <String>[]; // Personal keys' new ids, to undo
    final groups = <String, String?>{}; // source group id -> target's
    final categories = <String>{};
    final now = DateTime.now().millisecondsSinceEpoch;

    // Linked items first, then the batch's own: what a unit uses has its
    // fate known when it is written.
    final order = [
      ...taken.values.where((u) => u.kind != TransferKinds.host),
      ...taken.values.where((u) => u.kind == TransferKinds.host),
      ...plan._ready,
    ];

    try {
      await target.transaction(() async {
        for (final u in order) {
          if (u.newKey == null) {
            failedUnits.add(u);
            reasons[u] = (TransferRefusal.closedOffline, null);
            continue;
          }
          // What it uses that was to go with it and did not: it stays too.
          final missing = [
            for (final ref in {...u.uses, for (final f in u.forwards) ...f.uses}) ?taken[ref],
          ].where(failedUnits.contains).toList();
          if (missing.isNotEmpty) {
            failedUnits.add(u);
            reasons[u] = (TransferRefusal.linkFailed, missing.first.label);
            continue;
          }
          // A remote screen whose carrier stays behind would arrive with
          // none, which reads as a screen reached directly: its address,
          // as the carrier saw it, dialled from the device instead (found in a
          // security review). It stays where it is.
          final carrier = plan.sameDatabase ? null : _screenCarrierOf(u);
          if (carrier != null && !idOf.containsKey('${TransferKinds.host}/$carrier')) {
            failedUnits.add(u);
            reasons[u] = (TransferRefusal.linkFailed, plan._linked[LinkRef(LinkKind.host, carrier)]?.label ?? carrier);
            continue;
          }
          if (u.kind == TransferKinds.forward && !plan.sameDatabase) {
            final host = _main(u)?['connection_id'] as String?;
            if (host != null && !idOf.containsKey('${TransferKinds.host}/$host')) {
              failedUnits.add(u);
              reasons[u] = (TransferRefusal.needsItsHost, null);
              continue;
            }
          }
          try {
            await target.transaction(() async {
              await _writeUnit(plan, u, idOf, groups, categories, now);
              if (u.kind == TransferKinds.key && u.secrets.isNotEmpty) {
                for (final MapEntry(key: s, value: v) in u.secrets.entries) {
                  await targetSecrets.write(u.newKey!, s, v);
                }
                if (!target.isOrchard) writtenSecrets.add(u.newKey!);
              }
            });
            written.add(u);
          } catch (e) {
            failedUnits.add(u);
            reasons[u] = (_reasonOf(e), null);
            if (u.kind == TransferKinds.key && !target.isOrchard) await targetSecrets.deleteAll(u.newKey!);
            AppLogger.warning('Move/copy: an item was not written (${errorKind(e)})');
          }
        }
      });
    } catch (e) {
      // Nothing was written after all.
      for (final id in writtenSecrets) {
        await targetSecrets.deleteAll(id);
      }
      AppLogger.warning('Move/copy: nothing was written (${errorKind(e)})');
      return TransferResult(
        done: 0,
        failed: [
          ...failed,
          for (final u in plan._ready) TransferProblem(kind: u.kind, key: u.key, label: u.label, reason: _reasonOf(e)),
        ],
        newKeys: const {},
      );
    }
    target.notifyOrchardItemsChanged();

    // Move: what arrived leaves where it was, the batch's own items last
    // (a key leaves the hosts that still use it).
    final copiedInstead = <String>[];
    if (!plan.isDraft) {
      final leaving = [
        for (final u in plan._ready)
          if (u.mode == TransferMode.move && !failedUnits.contains(u)) u,
        for (final u in taken.values)
          if (u.mode == TransferMode.move && !failedUnits.contains(u)) u,
      ]..sort((a, b) => _deleteOrder(a.kind).compareTo(_deleteOrder(b.kind)));
      if (leaving.isNotEmpty) {
        final source = plan._source;
        final left = <_Unit>[];
        try {
          await source.transaction(() async {
            for (final u in leaving) {
              try {
                await source.transaction(() => _deleteUnit(source, u));
                left.add(u);
              } catch (e) {
                AppLogger.warning('Move/copy: an item could not leave where it was (${errorKind(e)})');
                if (u.primary) {
                  failedUnits.add(u);
                  reasons[u] = (_reasonOf(e), null);
                } else {
                  copiedInstead.add(u.label);
                }
              }
            }
          });
        } catch (e) {
          AppLogger.warning('Move/copy: nothing left where it was (${errorKind(e)})');
          for (final u in leaving) {
            if (u.primary) {
              failedUnits.add(u);
              reasons[u] = (_reasonOf(e), null);
            } else {
              copiedInstead.add(u.label);
            }
          }
          left.clear();
        }
        source.notifyOrchardItemsChanged();
        // Personal keys' secrets go once their rows have.
        if (!source.isOrchard) {
          for (final u in left) {
            if (u.kind == TransferKinds.key) await sourceSecrets.deleteAll(u.key);
          }
        }
        // A batch item that could not leave where it was is not left in two
        // places: its copy goes.
        final undo = [
          for (final u in plan._ready)
            if (written.contains(u) && failedUnits.contains(u)) u,
        ];
        if (undo.isNotEmpty) {
          try {
            await target.transaction(() async {
              for (final u in undo) {
                await _deleteWritten(target, u);
              }
            });
          } catch (e) {
            AppLogger.warning('Move/copy: a copy could not be taken back (${errorKind(e)})');
          }
          if (!target.isOrchard) {
            for (final u in undo) {
              if (u.kind == TransferKinds.key) await targetSecrets.deleteAll(u.newKey!);
            }
          }
          target.notifyOrchardItemsChanged();
        }
      }
    }

    final keyLeft = onKeyLeftTeam;
    if (keyLeft != null && plan._source.isOrchard && !plan.sameDatabase) {
      for (final u in written) {
        if (u.kind != TransferKinds.key || u.secrets.isEmpty || failedUnits.contains(u)) continue;
        // A new key an editor made was never the team's.
        if (plan.isDraft && u.primary) continue;
        try {
          await keyLeft(plan._source, key: u.key, label: u.label, crateId: u.crateId);
        } catch (e) {
          AppLogger.info('Move/copy: a key that left its team was not noted (${errorKind(e)})');
        }
      }
    }

    final done = [for (final u in plan._ready) if (!failedUnits.contains(u)) u];
    return TransferResult(
      done: done.length,
      failed: [
        ...failed,
        for (final u in plan._ready)
          if (failedUnits.contains(u))
            TransferProblem(kind: u.kind, key: u.key, label: u.label, reason: reasons[u]?.$1 ?? TransferRefusal.failed, link: reasons[u]?.$2),
      ],
      newKeys: {for (final u in done) u.key: u.newKey!},
      copiedInstead: copiedInstead,
    );
  }

  /// The carrier [u] is reached through, where [u] is a remote screen with one.
  static String? _screenCarrierOf(_Unit u) {
    if (u.kind != TransferKinds.host) return null;
    final row = _main(u);
    final via = row?['connect_via_id'];
    return ConnectionProtocol.storedIsScreen(row?['protocol'] as String?) && via is String && via.isNotEmpty ? via : null;
  }

  static int _deleteOrder(String kind) => switch (kind) {
        TransferKinds.forward => 0,
        TransferKinds.host => 1,
        TransferKinds.snippet => 2,
        TransferKinds.key => 3,
        _ => 4,
      };

  /// Move from one vault of a team to another: the item stays in the team's
  /// database and changes vault ([CratePlacement.moveItem]), its forwards with
  /// a host.
  Future<TransferResult> _moveWithinTeam(TransferPlan plan, List<TransferProblem> failed) async {
    final placement = CratePlacement(plan._source);
    final crate = plan.to.crateId!;
    final out = <String, String>{};
    for (final u in plan._ready) {
      try {
        await placement.moveItem(u.kind, u.key, crate);
        out[u.key] = u.key;
      } catch (e) {
        AppLogger.warning('Move/copy: an item did not change vault (${errorKind(e)})');
        failed.add(TransferProblem(kind: u.kind, key: u.key, label: u.label, reason: _reasonOf(e)));
        continue;
      }
      for (final f in u.forwards) {
        if (f.crateId == crate) continue;
        try {
          await placement.moveItem(f.kind, f.key, crate);
        } catch (e) {
          // It stays in its vault, still its host's.
          AppLogger.warning('Move/copy: a port forward stayed in its vault (${errorKind(e)})');
        }
      }
    }
    return TransferResult(done: out.length, failed: failed, newKeys: out);
  }

  static TransferRefusal _reasonOf(Object e) {
    if (e is CrateClosedOffline) return TransferRefusal.closedOffline;
    if (e is RecordRefused) return TransferRefusal.localShellNotInTeam;
    if (isOrchardWriteRefused(e)) return TransferRefusal.writeRefused;
    final text = '$e';
    if (text.contains('cannot be moved into')) return TransferRefusal.mayNotAdd;
    if (text.contains('cannot be moved out of')) return TransferRefusal.mayNotRemove;
    return TransferRefusal.failed;
  }

  /// Writes [u] where it lands, with what it uses as the batch decided: a
  /// linked item that went is named by its new key, one left is not named
  /// at all (the host is saved without it), one the place already has (in
  /// the same team) stays as it is.
  Future<void> _writeUnit(
    TransferPlan plan,
    _Unit u,
    Map<String, String> idOf,
    Map<String, String?> groups,
    Set<String> categories,
    int now,
  ) async {
    final target = plan._target;
    final same = plan.sameDatabase;
    String? mapped(String kind, Object? key) {
      if (key is! String || key.isEmpty) return null;
      if (kind == 'network' && key == kDefaultNetworkId) return key;
      return idOf['$kind/$key'] ?? (same ? key : null);
    }

    final rows = _remap(u, mapped);
    final main = (rows[_mainTable(u.kind)] as List).single as Map<String, Object?>;
    if (u.kind == TransferKinds.host) {
      main['group_id'] = await _groupIn(plan, main['group_id'] as String?, groups);
      // A copy is not the machine a cloud import follows: two hosts linked to
      // one would both follow its address (as Duplicate).
      if (u.mode == TransferMode.copy && !plan.isDraft) main['cloud_source'] = null;
      // A team's shared SFTP bookmarks stay with a team: a personal host has
      // none (your own pins are yours, and stay as they are).
      if (plan.to.isPersonal) main['shared_pins'] = null;
    }
    if (u.kind == TransferKinds.snippet) await _categoryIn(plan, main['category'] as String?, categories);
    await _place(plan, u.kind, u.newKey!);
    await OrchardItemStore(target).write(u.kind, u.newKey!, data: rows, editedAt: now);
    for (final f in u.forwards) {
      final fRows = _remap(f, mapped);
      await _place(plan, f.kind, f.newKey!);
      await OrchardItemStore(target).write(f.kind, f.newKey!, data: fRows, editedAt: now);
    }
  }

  Future<void> _place(TransferPlan plan, String kind, String key) async {
    if (plan.to.isPersonal) return;
    await CratePlacement(plan._target).place(kind, key, plan.to.crateId!);
  }

  static String _mainTable(String kind) => OrchardItemStore.tablesOfKind[kind]!.first;

  /// [u]'s rows under its new key, every child row with a key of its own
  /// given a new one, and every link as [mapped] says (a row about a link
  /// that is not there is dropped).
  Map<String, Object?> _remap(_Unit u, String? Function(String kind, Object? key) mapped) {
    List<Map<String, Object?>> copy(String table) => [for (final r in _rows(u, table)) {...r}];
    final out = <String, Object?>{};
    switch (u.kind) {
      case TransferKinds.host:
        final main = copy('connections').single;
        main['id'] = u.newKey;
        main['identity_id'] = mapped(TransferKinds.key, main['identity_id']);
        main['connect_via_id'] = mapped(TransferKinds.host, main['connect_via_id']);
        main['snippet_id'] = mapped(TransferKinds.snippet, main['snippet_id']);
        out['connections'] = [main];
        out['connection_tags'] = [
          for (final t in copy('connection_tags')) {...t, 'connection_id': u.newKey},
        ];
        out['host_accounts'] = [
          for (final a in copy('host_accounts'))
            if (mapped(TransferKinds.key, a['identity_id']) case final id?) {...a, 'connection_id': u.newKey, 'identity_id': id},
        ];
        out['host_network_overrides'] = [
          for (final o in copy('host_network_overrides'))
            if (mapped('network', o['network_id']) case final network?)
              {
                ...o,
                'id': _newId(),
                'connection_id': u.newKey,
                'network_id': network,
                'identity_id': mapped(TransferKinds.key, o['identity_id']),
                'jump_host_id': mapped(TransferKinds.host, o['jump_host_id']),
                'jump_chain_json': _remapChain(o['jump_chain_json'], (id) => mapped(TransferKinds.host, id)),
              },
        ];
      case TransferKinds.key:
        final main = copy('identities').single;
        main['id'] = u.newKey;
        out['identities'] = [main];
        // Secrets are written where the place keeps them, not as rows.
        out['orchard_secrets'] = const [];
      case TransferKinds.snippet:
        final main = copy('snippets').single;
        main['id'] = u.newKey;
        out['snippets'] = [main];
      case TransferKinds.forward:
        final main = copy('port_forward_rules').single;
        main['id'] = u.newKey;
        main['connection_id'] = mapped(TransferKinds.host, main['connection_id']);
        main['network_id'] = mapped('network', main['network_id']);
        out['port_forward_rules'] = [main];
        out['port_forward_network_overrides'] = [
          for (final o in copy('port_forward_network_overrides'))
            if (mapped('network', o['network_id']) case final network?)
              {...o, 'id': _newId(), 'rule_id': u.newKey, 'network_id': network},
        ];
      case 'network':
        final main = copy('networks').single;
        main['id'] = u.newKey;
        main['bring_up_vpn'] = mapped(TransferKinds.host, main['bring_up_vpn']);
        // One place has one Default network.
        main['is_fallback'] = 0;
        out['networks'] = [main];
    }
    return out;
  }

  static String? _remapChain(Object? json, String? Function(String id) mapped) {
    if (json is! String) return null;
    if (json.trim() == '[]') return json;
    final ids = _chain(json);
    if (ids.isEmpty) return null;
    final kept = [
      for (final id in ids) ?mapped(id),
    ];
    return kept.isEmpty ? null : jsonEncode(kept);
  }

  /// The group a host goes into where it lands: within one team, its own;
  /// elsewhere the one of the same name, else a new one like it.
  Future<String?> _groupIn(TransferPlan plan, String? groupId, Map<String, String?> groups) async {
    if (groupId == null) return null;
    if (plan.sameDatabase) return groupId;
    if (groups.containsKey(groupId)) return groups[groupId];
    final source = await plan._source.customSelect('SELECT name FROM connection_groups WHERE id = ?',
        variables: [Variable(groupId)]).getSingleOrNull();
    final name = source?.read<String>('name');
    if (name == null) return groups[groupId] = null;
    final there = await plan._target.customSelect(
        'SELECT id FROM connection_groups WHERE lower(name) = lower(?) ORDER BY id LIMIT 1',
        variables: [Variable(name)]).getSingleOrNull();
    if (there != null) return groups[groupId] = there.read<String>('id');
    final rows = await OrchardItemStore(plan._source).read('group', groupId);
    if (rows == null) return groups[groupId] = null;
    final id = _newId();
    final main = {...((rows['connection_groups'] as List).single as Map<String, Object?>), 'id': id};
    await _place(plan, 'group', id);
    await OrchardItemStore(plan._target)
        .write('group', id, data: {'connection_groups': [main]}, editedAt: DateTime.now().millisecondsSinceEpoch);
    return groups[groupId] = id;
  }

  /// A snippet's category, made where it lands where that has none of the
  /// name (a snippet shows under its category's name either way).
  Future<void> _categoryIn(TransferPlan plan, String? name, Set<String> done) async {
    if (name == null || name.isEmpty || plan.sameDatabase || !done.add(name)) return;
    final there = await plan._target.customSelect('SELECT 1 FROM snippet_categories WHERE name = ?',
        variables: [Variable(name)]).getSingleOrNull();
    if (there != null) return;
    final rows = await OrchardItemStore(plan._source).read('category', name);
    if (rows == null) return;
    await _place(plan, 'category', name);
    await OrchardItemStore(plan._target)
        .write('category', name, data: rows, editedAt: DateTime.now().millisecondsSinceEpoch);
  }

  /// Takes [u] off where it was, as deleting it there does (in Personal with
  /// the mark that deletes it on your other devices too).
  Future<void> _deleteUnit(AppDatabase db, _Unit u) async {
    switch (u.kind) {
      case TransferKinds.host:
        await db.tombstonesDao.mark('connections', u.key);
        await db.connectionsDao.clearConnectViaReferences(u.key);
        await db.portForwardRulesDao.deleteByConnection(u.key);
        await db.connectionTagsDao.clearTagsForConnection(u.key);
        await db.hostAccountsDao.deleteForConnection(u.key);
        await db.networksDao.deleteOverridesForHost(u.key);
        await db.connectionsDao.deleteConnection(u.key);
      case TransferKinds.key:
        await db.hostAccountsDao.removeIdentity(u.key);
        await db.identitiesDao.deleteIdentity(u.key);
        if (db.isOrchard) await OrchardIdentitySecrets(db).deleteAll(u.key);
      case TransferKinds.snippet:
        await db.snippetsDao.deleteSnippet(u.key);
      case TransferKinds.forward:
        await db.portForwardRulesDao.deleteRule(u.key);
      case 'network':
        await db.networksDao.deleteOverridesForNetwork(u.key);
        await db.customStatement('DELETE FROM port_forward_network_overrides WHERE network_id = ?', [u.key]);
        await db.networksDao.deleteNetwork(u.key);
    }
  }

  /// Takes back what was written of [u] (a batch item that could not leave
  /// where it was), its forwards with it.
  Future<void> _deleteWritten(AppDatabase db, _Unit u) async {
    for (final f in u.forwards) {
      if (f.newKey != null) await OrchardItemStore(db).write(f.kind, f.newKey!, data: null, editedAt: 0);
    }
    await OrchardItemStore(db).write(u.kind, u.newKey!, data: null, editedAt: 0);
  }

  // ── Rows ────────────────────────────────────────────────────────────────

  static Map<String, Object?>? _main(_Unit u) {
    final rows = u.rows[_mainTable(u.kind)];
    if (rows is! List || rows.isEmpty) return null;
    final row = rows.first;
    return row is Map<String, Object?> ? row : null;
  }

  static List<Map<String, Object?>> _rows(_Unit u, String table) => [
        for (final r in (u.rows[table] as List?) ?? const [])
          if (r is Map<String, Object?>) r,
      ];

  static String _labelOf(String kind, Map<String, Object?> rows) {
    final table = OrchardItemStore.tablesOfKind[kind]?.first;
    final list = rows[table];
    final row = list is List && list.isNotEmpty && list.first is Map ? list.first as Map : const {};
    final label = switch (kind) {
      TransferKinds.forward => (row['label'] as String?)?.trim().isNotEmpty == true
          ? row['label'] as String
          : '${row['bind_port']} > ${row['remote_host']}:${row['remote_port']}',
      'network' => row['name'],
      _ => row['label'],
    };
    return label is String && label.isNotEmpty ? label : '?';
  }
}

/// The rows and secrets of a new item [write] makes in [db] ("Save in",
/// 3.4), without keeping it there: [write] runs in a transaction that is
/// rolled back, so nothing of it is ever seen in [db] (nor sent by its sync).
/// In a team's database its write guard and outbox are quiet while it runs.
/// [write] returns the new item's key. A key's secrets that Personal keeps
/// outside its database are read and then removed.
Future<ItemDraft> captureNewItem(
  AppDatabase db,
  FlutterSecureStorage storage,
  String kind,
  Future<String> Function() write,
) async {
  late ItemDraft draft;
  final secrets = IdentitySecretStore.forDatabase(db, storage);
  String? key;
  try {
    await db.transaction(() async {
      if (db.isOrchard) {
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      }
      key = await write();
      final rows = await OrchardItemStore(db).read(kind, key!);
      if (rows == null) throw StateError('The new item was not written');
      draft = ItemDraft(
        kind: kind,
        key: key!,
        rows: rows,
        secrets: kind == TransferKinds.key ? await _readSecrets(secrets, key!) : const {},
      );
      throw const _RollBack();
    });
  } on _RollBack {
    // As intended: nothing of it stays.
  } finally {
    if (!db.isOrchard && kind == TransferKinds.key && key != null) await secrets.deleteAll(key!);
  }
  return draft;
}

/// Every secret [store] keeps for the identity [id].
Future<Map<IdentitySecret, String>> _readSecrets(IdentitySecretStore store, String id) async {
  final out = <IdentitySecret, String>{};
  for (final s in IdentitySecret.values) {
    final v = await store.read(id, s);
    if (v != null) out[s] = v;
  }
  return out;
}

/// Thrown inside [captureNewItem]'s transaction so that nothing of what
/// it captured is kept; caught there and never seen elsewhere.
class _RollBack implements Exception, HasTypeName {
  const _RollBack();

  @override
  String get typeName => '_RollBack';

  @override
  String toString() => 'A new item was read and not kept';
}
