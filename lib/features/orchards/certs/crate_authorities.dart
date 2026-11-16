import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';

/// A Crate's certificate authority as the screens show it (3.0),
/// from the Orchard's record on this device.
class CrateAuthorityView {
  const CrateAuthorityView({
    required this.crateId,
    required this.on,
    required this.generation,
    required this.ttlMinutes,
    required this.principals,
    required this.keyCrate,
    required this.publicKeys,
    this.newKeyNeeded = false,
    this.myUserNames,
    this.keyHere = false,
  });

  final String crateId;
  final bool on;
  final int generation;
  final int ttlMinutes;

  /// The user names each role signs in as ('owner', 'admin' or a role id).
  final Map<String, List<String>> principals;

  /// The owners-only Crate that keeps its key.
  final String keyCrate;

  /// Each generation's public key.
  final Map<int, Uint8List> publicKeys;

  /// Someone who could open [keyCrate] lost that since the current key was
  /// made ([authoritiesNeedingNewKey]).
  final bool newKeyNeeded;

  /// The user names this account's role signs in as; null when it is not a
  /// member (the record does not have it).
  final List<String>? myUserNames;

  /// Whether the key its certificates are signed with is on this device:
  /// an owner's, once the Crate that keeps it has synced here. Such a
  /// device signs its own certificate and the requests handed to it.
  final bool keyHere;

  /// The current key as a host trusts it.
  String get keyLine => ed25519KeyLine(publicKeys[generation]!, 'zestssh-ca-$generation');

  /// The earlier keys, for hosts to stop trusting.
  List<String> get oldKeyLines => [
        for (final g in publicKeys.keys.toList()..sort())
          if (g != generation) ed25519KeyLine(publicKeys[g]!, 'zestssh-ca-$g'),
      ];

  /// The current key's SHA256 fingerprint, as OpenSSH shows it.
  String get fingerprint => OpenSSHKeySerializer.fingerprintFromPublicKeyString(keyLine);

  static CrateAuthorityView of(String crateId, RecordCa ca,
          {bool newKeyNeeded = false, String? myRole, bool keyHere = false}) =>
      CrateAuthorityView(
        crateId: crateId,
        on: ca.on,
        generation: ca.generation,
        ttlMinutes: ca.ttlMinutes,
        principals: {for (final e in ca.principals.entries) e.key: List.unmodifiable(e.value)},
        keyCrate: ca.keyCrate,
        publicKeys: Map.unmodifiable(ca.publicKeys),
        newKeyNeeded: newKeyNeeded,
        myUserNames: myRole == null ? null : List.unmodifiable(ca.principals[myRole] ?? const <String>[]),
        keyHere: keyHere,
      );
}

/// The authority, while on, of the Crate the key [identityId] is in (the
/// Crate new keys go to when null): what a team certificate key there signs
/// in with. Null in your Tree, and where it is off or there is none.
CrateAuthorityView? keyCrateAuthority(WidgetRef ref, String? identityId) {
  final rules = ItemRules.of(ref, 'key');
  final orchard = rules.orchard;
  if (orchard == null) return null;
  final crateId = identityId == null ? orchard.defaultCrateId : rules.crates[identityId] ?? orchard.defaultCrateId;
  if (crateId == null) return null;
  final authority = ref.watch(crateAuthoritiesProvider(orchard.id)).valueOrNull?[crateId];
  return authority != null && authority.on ? authority : null;
}

/// The authority whose key [identity] is: a key in the authority's key Crate
/// whose public half is the one the record names now. Null otherwise.
CrateAuthorityView? authorityOfKey(WidgetRef ref, Identity identity) {
  final rules = ItemRules.of(ref, 'key');
  final orchard = rules.orchard;
  final line = identity.publicKeyData?.trim().split(RegExp(r'\s+'));
  if (orchard == null || line == null || line.length < 2) return null;
  final crateId = rules.crates[identity.id] ?? orchard.defaultCrateId;
  final authorities = ref.watch(crateAuthoritiesProvider(orchard.id)).valueOrNull ?? const {};
  for (final a in authorities.values) {
    if (a.keyCrate == crateId && a.keyLine.split(' ')[1] == line[1]) return a;
  }
  return null;
}

/// The user names any role signs in as with [authority], sorted.
List<String> authorityUserNames(CrateAuthorityView authority) =>
    {for (final names in authority.principals.values) ...names}.toList()..sort();

/// The certificate authorities of [orchardId]'s Crates, by Crate, as this
/// device's record has them. Read again after a change here and after each
/// sync.
final crateAuthoritiesProvider =
    FutureProvider.autoDispose.family<Map<String, CrateAuthorityView>, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  ref.watch(orchardSummariesProvider);
  final service = ref.watch(orchardServiceProvider);
  final db = await service.databases.open(orchardId);
  final record = await LocalRecord.load(db, orchardId);
  final latest = record.latest;
  if (!latest.crates.values.any((c) => c.ca != null)) return const {};
  final me = (await service.currentAuthor())?.uid;
  final due = await authoritiesNeedingNewKey(orchardId, record.entries);
  final role = me == null ? null : latest.members[me]?.role;
  return {
    for (final c in latest.crates.values)
      if (c.ca != null)
        c.id: CrateAuthorityView.of(
          c.id,
          c.ca!,
          newKeyNeeded: due.contains(c.id),
          myRole: role,
          keyHere: await service.authorityKey(orchardId, c.id, record: latest) != null,
        ),
  };
});
