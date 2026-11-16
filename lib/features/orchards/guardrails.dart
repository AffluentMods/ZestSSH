import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/utils/type_name.dart';

// What the app lets a member do with an Orchard's items (3.0,
// "guardrails"): at Connect a Crate's passwords and keys stay hidden; SFTP,
// port forwarding and agent forwarding follow the Crate's switches; team
// items never leave in an export, a share or a QR code except an owner's
// export, and not even that when the Orchard's rules say no export; a
// Crate that asks again has its secrets shown only after the device's PIN
// or a fingerprint; and a Crate that its own offline limit has closed
// on this device allows nothing until the device is back in contact
// (rules/crate_offline.dart). These are the app's rules: a device holds the
// keys it may open and must decrypt a password to use it, which is why the
// whitepaper names them as enforced by the app, not by cryptography.

/// Whether whatever is on screen may go into an export, a share or a QR
/// code: your Tree's items always; an Orchard's only for an owner, and not
/// even then when its rules forbid exports.
bool mayExportScreenSpace(WidgetRef ref) {
  if (ref.read(activeSpaceProvider) is TreeSpace) return true;
  final orchard = ref.read(activeOrchardProvider).valueOrNull;
  if (orchard == null || orchard.rules.noExport) return false;
  // Nor while a Crate of it is closed on this device by its offline limit:
  // an export of the Orchard would carry what that Crate holds.
  if (orchard.crates.any((c) => c.closedOffline)) return false;
  return orchard.isOwner;
}

/// Whether a key's private key may be exported (a file, the system's agent,
/// a copy) from the space on screen: always in your Tree; in an Orchard,
/// unless its rules forbid exports, and by any member who may reveal it
/// ([mayRevealKey]; no owner asked: found in a security review).
bool mayExportKeysScreenSpace(WidgetRef ref, {bool watch = true}) {
  final space = watch ? ref.watch(activeSpaceProvider) : ref.read(activeSpaceProvider);
  if (space is! OrchardSpace) return true;
  final orchard = (watch ? ref.watch(activeOrchardProvider) : ref.read(activeOrchardProvider)).valueOrNull;
  return orchard != null && orchard.id == space.orchardId && !orchard.rules.noExport;
}

/// Whether the key (identity) [identityId] on screen is in a Crate that asks
/// again before its secrets are shown, once the Orchard on screen and
/// its items' Crates have been read: then its password, passphrase and
/// private key are loaded only after [confirmItIsYou]. False in your Tree;
/// true when it cannot be worked out.
Future<bool> revealAsksAgainNow(WidgetRef ref, String identityId) async {
  if (ref.read(activeSpaceProvider) is! OrchardSpace) return false;
  try {
    await ref.read(orchardSummariesProvider.future);
    await ref.read(itemCratesProvider('key').future);
  } catch (_) {
    return true;
  }
  final rules = ItemRules.of(ref, 'key', watch: false);
  final orchard = rules.orchard;
  if (orchard == null) return rules.loading;
  final crateId = rules.crates[identityId] ?? orchard.defaultCrateId;
  return orchard.crates.where((c) => c.id == crateId).firstOrNull?.confirmReveal ?? true;
}

/// The rules for the items of one kind in the space on screen, read at
/// one moment: for code with no ref at hand (a helper of a build method),
/// which gets it from build. In your Tree everything is yours; in an
/// Orchard each item has its Crate's switches, and nothing is allowed while
/// the Orchard is still being read.
class ItemRules {
  const ItemRules._({this.orchard, this.crates = const {}, this.loading = false});

  /// Your Tree: no limits.
  static const tree = ItemRules._();

  /// Watches (or, with [watch] false, reads) what the rules for [kind] need.
  factory ItemRules.of(WidgetRef ref, String kind, {bool watch = true}) {
    final space = watch ? ref.watch(activeSpaceProvider) : ref.read(activeSpaceProvider);
    if (space is! OrchardSpace) return tree;
    final orchard = (watch ? ref.watch(activeOrchardProvider) : ref.read(activeOrchardProvider)).valueOrNull;
    final crates =
        (watch ? ref.watch(itemCratesProvider(kind)) : ref.read(itemCratesProvider(kind))).valueOrNull;
    if (orchard == null || orchard.id != space.orchardId || crates == null) {
      return const ItemRules._(loading: true);
    }
    return ItemRules._(orchard: orchard, crates: crates);
  }

  final OrchardSummary? orchard;
  final Map<String, String> crates;
  final bool loading;

  /// Null in your Tree; else what this account may do with the item [key].
  Set<String>? switchesOf(String key) {
    if (loading) return const {};
    final o = orchard;
    if (o == null) return null;
    final crateId = crates[key] ?? o.defaultCrateId;
    return o.crates.where((c) => c.id == crateId).firstOrNull?.switches ?? const {};
  }

  bool allows(String key, String what) {
    final s = switchesOf(key);
    return s == null || s.contains(what);
  }

  /// Its secrets may be shown, copied or exported (a key's password,
  /// passphrase and private key).
  bool mayReveal(String key) => allows(key, CrateSwitches.reveal);

  /// It may be edited (or deleted, with [delete]).
  bool mayChange(String key, {bool delete = false}) =>
      allows(key, delete ? CrateSwitches.delete : CrateSwitches.edit);
}

/// What this account may do with the item [key] of [kind] ('host', 'key',
/// 'snippet', ...) in the space on screen: null in your Tree, where
/// everything is yours; in an Orchard, its Crate's switches. Nothing while
/// the Orchard is still being read. [watch] rebuilds the caller when they
/// change (in build); callbacks pass false.
Set<String>? itemSwitches(WidgetRef ref, String kind, String key, {bool watch = true}) =>
    ItemRules.of(ref, kind, watch: watch).switchesOf(key);

/// Whether new items may be made in the space on screen: always in your
/// Tree; in an Orchard, when a Crate lets this account add (new items go
/// there).
bool mayAddScreenSpace(WidgetRef ref, {bool watch = true}) {
  final space = watch ? ref.watch(activeSpaceProvider) : ref.read(activeSpaceProvider);
  if (space is! OrchardSpace) return true;
  final orchard = (watch ? ref.watch(activeOrchardProvider) : ref.read(activeOrchardProvider)).valueOrNull;
  if (orchard == null || orchard.id != space.orchardId || !orchard.active) return false;
  final target = orchard.crates.where((c) => c.id == orchard.defaultCrateId).firstOrNull;
  return target != null && target.canAdd;
}

/// Whether this account may see, copy or export the secrets of the key
/// (identity) [identityId] on screen: its password, passphrase and private
/// key. At Connect it uses them to connect and nothing more.
bool mayRevealKey(WidgetRef ref, String identityId, {bool watch = true}) {
  final s = itemSwitches(ref, 'key', identityId, watch: watch);
  return s == null || s.contains(CrateSwitches.reveal);
}

/// Whether this account may change the item [key] of [kind] on screen:
/// edit it (or delete it, with [delete]).
bool mayChangeItem(WidgetRef ref, String kind, String key, {bool delete = false, bool watch = true}) {
  final s = itemSwitches(ref, kind, key, watch: watch);
  return s == null || s.contains(delete ? CrateSwitches.delete : CrateSwitches.edit);
}

/// [mayRevealKey] once the Orchard on screen and its items' Crates have been
/// read: for deciding, before anything secret is loaded, whether to load it.
Future<bool> mayRevealKeyNow(WidgetRef ref, String identityId) async {
  if (ref.read(activeSpaceProvider) is! OrchardSpace) return true;
  try {
    await ref.read(orchardSummariesProvider.future);
    await ref.read(itemCratesProvider('key').future);
  } catch (_) {
    return false;
  }
  return mayRevealKey(ref, identityId, watch: false);
}

// ── In a session (no screen at hand) ────────────────────────────────────

/// What this account may do with the item [key] of [kind] in the database
/// [db] a session works in: null for your Tree's, where everything is
/// yours; in an Orchard's, its Crate's switches, and none of them while
/// the Crate is closed on this device by its own offline limit.
Future<Set<String>?> itemSwitchesIn(AppDatabase db, String kind, String key) async {
  if (!db.isOrchard) return null;
  final placement = CratePlacement(db);
  final crateId = await placement.crateOf(kind, key);
  if (crateId == null || (await closedCratesIn(db)).containsKey(crateId)) return const {};
  return placement.switchesOf(crateId);
}

/// Whether the host [connectionId] may use [what] (SFTP, port forwarding,
/// agent forwarding) in [db], the database its sessions work in: always for
/// a quick connect (no saved host) and in your Tree; never when the
/// Orchard's database has closed (null [db] for a saved host).
Future<bool> hostAllowsIn(AppDatabase? db, String? connectionId, String what) async {
  if (connectionId == null) return true;
  if (db == null) return false;
  final s = await itemSwitchesIn(db, 'host', connectionId);
  return s == null || s.contains(what);
}

/// A session was about to hand an Orchard's secret, or a use of it, beyond
/// what the member's access allows (3.0). [message] says what, in
/// the person's language.
class OrchardAccessRefused implements Exception, HasTypeName {
  const OrchardAccessRefused(this.message);

  final String message;

  @override
  String toString() => message;

  @override
  String get typeName => 'OrchardAccessRefused';
}

/// Throws [OrchardAccessRefused] unless this account may reveal the key
/// [identityId] of [db] (its Crate's switches include reveal): what writing
/// it to a file, or signing with it for anything but a connection, needs.
Future<void> requireRevealIn(AppDatabase db, String identityId, {required String refusal}) async {
  final s = await itemSwitchesIn(db, 'key', identityId);
  if (s != null && !s.contains(CrateSwitches.reveal)) throw OrchardAccessRefused(refusal);
}

/// The person's words for a key file refused at Connect.
String get keyFileRefusal => gl10n.orchardKeyFileNeedsReveal;

/// Throws [OrchardAccessRefused] when the password of the key [identityId]
/// would go to the host [connectionId] and this account may not see that
/// password but may change the host (add or edit in its Crate): it could
/// point the host at a server of its own and read the password there. A
/// key's private key never leaves the device when it signs in, so this is
/// about passwords only.
///
/// [carrierId] is the SSH host a remote screen is reached through (4.0): no
/// end-to-end check stands between it and the VNC server (VNC
/// authentication is not bound to the server the way SSH's host key is), so
/// whoever may change the carrier decides where the password goes as surely
/// as whoever may change the screen (found in a security review).
Future<void> requirePasswordHostIn(AppDatabase db, String identityId, String connectionId, {String? carrierId}) async {
  final key = await itemSwitchesIn(db, 'key', identityId);
  if (key == null || key.contains(CrateSwitches.reveal)) return;
  for (final id in [connectionId, ?carrierId]) {
    final host = await itemSwitchesIn(db, 'host', id);
    if (host != null && (host.contains(CrateSwitches.add) || host.contains(CrateSwitches.edit))) {
      throw OrchardAccessRefused(gl10n.orchardPasswordWrongHost);
    }
  }
}

/// Whether the key (identity) [identityId] of [db], the database a session
/// works in, is in a Crate that asks again before its secrets are shown or
/// leave the device. False in your Tree. True when it cannot be worked
/// out, and for every Crate while the server holds this account back by the
/// Orchard's rules: a Crate switched to ask again meanwhile cannot reach
/// this device.
Future<bool> revealAsksAgainIn(AppDatabase db, String identityId) async {
  if (!db.isOrchard) return false;
  try {
    final info = await db.customSelect('SELECT status FROM orchard_info WHERE id = 1').getSingleOrNull();
    if (info?.read<String>('status') == 'rules') return true;
    final crateId = await CratePlacement(db).crateOf('key', identityId);
    if (crateId == null) return true;
    final crate = await db.customSelect('SELECT confirm_reveal FROM orchard_crates WHERE crate_id = ?',
        variables: [Variable<String>(crateId)]).getSingleOrNull();
    return crate == null || crate.read<int>('confirm_reveal') == 1;
  } catch (_) {
    return true;
  }
}

/// Whether the password of the key [identityId] may go to the host
/// [connectionId] of [db] only once the person confirms it is them:
/// the key is in a Crate that asks again, and this account may change the
/// host (add or edit in its Crate), so it could point the host at a server
/// of its own and read the password there without that check. Never in your
/// Tree. A key's private key never leaves the device when it signs in, so
/// this is about passwords only. A remote screen's [carrierId] counts as the
/// host does ([requirePasswordHostIn]).
Future<bool> passwordAsksAgainIn(AppDatabase db, String identityId, String connectionId, {String? carrierId}) async {
  if (!await revealAsksAgainIn(db, identityId)) return false;
  for (final id in [connectionId, ?carrierId]) {
    final host = await itemSwitchesIn(db, 'host', id);
    if (host == null || host.contains(CrateSwitches.add) || host.contains(CrateSwitches.edit)) return true;
  }
  return false;
}

/// Whether this account may change the item [key] of [kind] in [db]: a
/// password typed at a prompt is saved back only where it may.
Future<bool> mayEditIn(AppDatabase db, String kind, String key) async {
  final s = await itemSwitchesIn(db, kind, key);
  return s == null || s.contains(CrateSwitches.edit);
}

/// Whether [error] is an Orchard's database refusing a write this account
/// may not make (its write guard; see AppDatabase.createOrchardTriggers).
bool isOrchardWriteRefused(Object error) => '$error'.contains('orchard-access');

/// Whether [error] is an Orchard's database refusing to turn a team's host
/// from FTPS into another kind, or the other way (3.4; kTeamHostKindRefused).
bool isTeamHostKindRefused(Object error) => '$error'.contains(kTeamHostKindRefused);
