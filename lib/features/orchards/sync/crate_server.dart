import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/member_picture.dart' show isKnownPictureAddress;
import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/members/team_recovery.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/type_name.dart';

/// One generation of an Orchard's or a Crate's key, sealed to this account,
/// with who sealed it and their signature ([keyCopySignatureMessage]). The
/// signature fields are null on a copy stored before the server checked
/// them, and a device refuses such a copy.
class SealedSpaceKey {
  const SealedSpaceKey(
    this.generation,
    this.sealed, {
    this.recipientKeyVersion,
    this.sealedBy,
    this.sealerKeyVersion,
    this.signature,
  });

  final int generation;
  final Uint8List sealed;

  /// The version of this account's keys the copy is sealed to.
  final int? recipientKeyVersion;

  /// The account that sealed and signed the copy, and the version of its
  /// keys that signed.
  final String? sealedBy;
  final int? sealerKeyVersion;
  final Uint8List? signature;
}

/// A Crate this account can open, as the server lists it. What the account
/// may do in it follows from the Orchard's record, which the device reads
/// and checks for itself; the server's own reading ([switches]) is only a
/// hint.
class RemoteCrate {
  const RemoteCrate({
    required this.id,
    required this.nameEnc,
    required this.keyGeneration,
    required this.level,
    required this.keys,
    this.switches = const {},
    this.ownersOnly = false,
    this.allow = const {CrateSwitches.forward, CrateSwitches.sftp},
    this.rotationDue = false,
  });

  final String id;
  final Uint8List nameEnc;

  /// The generation new writes must use.
  final int keyGeneration;

  /// 'connect', 'use', 'edit' or 'manage': the nearest level to [switches].
  final String level;
  final List<SealedSpaceKey> keys;

  final Set<String> switches;
  final bool ownersOnly;

  /// Which of sftp, forward and agent the Crate allows at all.
  final Set<String> allow;

  /// Someone lost access, so its key waits to be replaced.
  final bool rotationDue;
}

/// A team being deleted as ZestSSH Cloud says it: the owner who
/// asked and the number of their signed team.delete entry (both null for a
/// team it ends because nobody is left in it), when it took the request,
/// when the team goes (seven days on), and whether its purge began (after
/// which nothing undoes it).
class TeamDeletion {
  const TeamDeletion({required this.by, required this.seq, required this.askedAt, required this.purgeAt, this.purging = false});

  final String? by;
  final int? seq;
  final DateTime askedAt;
  final DateTime purgeAt;
  final bool purging;

  /// [raw] as the server sends it, or null when it is not one.
  static TeamDeletion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final asked = raw['asked_at'] is String ? DateTime.tryParse(raw['asked_at'] as String) : null;
    final purge = raw['purge_at'] is String ? DateTime.tryParse(raw['purge_at'] as String) : null;
    if (asked == null || purge == null) return null;
    return TeamDeletion(
      by: raw['by'] is String ? raw['by'] as String : null,
      seq: raw['seq'] is int ? raw['seq'] as int : null,
      askedAt: asked.toUtc(),
      purgeAt: purge.toUtc(),
      purging: raw['purging'] == true,
    );
  }

  Map<String, Object?> toJson() => {
        'by': by,
        'seq': seq,
        'asked_at': askedAt.toUtc().toIso8601String(),
        'purge_at': purgeAt.toUtc().toIso8601String(),
        'purging': purging,
      };
}

/// What ZestSSH Cloud says of an entry this device holds of a team it no
/// longer lists for this account ([CrateServer.recordHolds]): whether its
/// record holds it, and, for a team that was deleted, when that
/// was. The server keeps a deleted team's fingerprints for 90 days, so that
/// every device holding its record hears that it holds the entry, and is
/// told the team was deleted only once it shows it held it.
class RecordHolds {
  const RecordHolds(this.holds, {this.deletedAt});

  final bool holds;
  final DateTime? deletedAt;

  bool get deleted => holds && deletedAt != null;
}

/// An Orchard this account is in, with the Crates it can open. A member who
/// is suspended, or whose access ended, learns only that ([status]); the
/// rest is then empty.
class RemoteOrchard {
  const RemoteOrchard({
    required this.id,
    required this.nameEnc,
    required this.keyGeneration,
    required this.role,
    required this.keys,
    required this.crates,
    this.membersTag,
    this.invitesWaiting,
    this.status = 'active',
    this.recordSeq = 0,
    this.rotationDue = false,
    this.can = const {},
    this.rulesUnmet = const [],
    this.ruleDomains = const [],
    this.heldDeviceRules,
    this.deviceRemoved = false,
    this.copiesMissing = false,
    this.deleting,
  });

  /// A membership that does not count now: suspended, ended, held back by
  /// the rules ([rulesUnmet] says which), or the team being deleted
  /// ([deleting]).
  RemoteOrchard.inactive(this.id, this.status,
      {this.role = '',
      this.rulesUnmet = const [],
      this.ruleDomains = const [],
      this.heldDeviceRules,
      this.deviceRemoved = false,
      this.deleting})
      : nameEnc = Uint8List(0),
        keyGeneration = 0,
        keys = const [],
        crates = const [],
        membersTag = null,
        invitesWaiting = null,
        recordSeq = 0,
        rotationDue = false,
        copiesMissing = false,
        can = const {};

  final String id;
  final Uint8List nameEnc;
  final int keyGeneration;

  /// 'owner', 'admin' or the id of a role the owners made.
  final String role;

  /// 'active', 'suspended', 'ended', 'rules' (this account falls short of
  /// a rule the server checks) or 'deleting' (the team is being deleted,
  /// see [deleting]).
  final String status;

  /// While [status] is 'deleting': who asked and the day it goes. Every
  /// member is held back meanwhile, owners too; any of them may read the
  /// record, and owners may undo it until that day.
  final TeamDeletion? deleting;

  /// While [status] is 'rules': which ('two_step', 'email_domain',
  /// 'reauth', 'sso', and 'trusted_device' when the Orchard lets in approved
  /// devices only and this one is not), and the domains the address
  /// rule allows.
  final List<String> rulesUnmet;
  final List<String> ruleDomains;

  /// While this device is held back as not approved: it was approved once
  /// and someone took that back. It then drops what it holds of the
  /// Orchard.
  final bool deviceRemoved;

  /// While [status] is 'rules' or 'deleting': the rules this account's
  /// devices keep to meanwhile, as the server keeps them (the app lock and its timeout, no
  /// export, the offline limit; only those are read). The account cannot
  /// read the record they are in, so a change made together with the rule
  /// it falls short of reaches its devices only this way. Null from a
  /// server that does not say.
  final RecordRules? heldDeviceRules;

  /// How many entries the Orchard's record holds.
  final int recordSeq;

  /// Someone lost access, so the Orchard's key waits to be replaced.
  final bool rotationDue;

  /// The server was restored from a backup and lost key copies sealed to
  /// members (the restore work): a device that holds those keys seals them
  /// again ([CrateServer.missingCopies]).
  final bool copiesMissing;

  /// What the account may do in the Orchard, as the server reads the record.
  final Set<String> can;

  bool get active => status == 'active';

  /// Moves whenever the members, their roles, their keys or the checks of
  /// their keys change: the member list is read again only then.
  final String? membersTag;

  /// How many people accepted an invitation and wait for someone to confirm
  /// them; null for those whose role invites no one.
  final int? invitesWaiting;
  final List<SealedSpaceKey> keys;
  final List<RemoteCrate> crates;
}

/// An invitation as the members who may invite see it.
class OrchardInvite {
  const OrchardInvite({
    required this.id,
    required this.email,
    required this.role,
    this.grants = const {},
    this.endsAt,
    required this.expiresAt,
    required this.expired,
    this.invitedBy,
    this.acceptedUid,
    this.acceptedKeys,
    this.acceptedRulesUnmet = const [],
    this.acceptedProvider,
    this.code,
    this.acceptedDevice,
  });

  final String id;

  /// The device they accepted on, as they offered it for approval;
  /// null where none was offered (an older app) or it was malformed. Only
  /// offered beside "Let them in" once its statement checks out with
  /// [acceptedKeys] (OrchardService.joinDeviceOffer).
  final JoinDevice? acceptedDevice;

  /// The address invited; for an invite code ([code]), the address of whoever
  /// used it, and empty until someone does.
  final String email;

  /// An invite code's own; null for an
  /// invitation to an address.
  final InviteCodeInfo? code;

  /// How the person who used an invite code signed in ('google.com',
  /// 'password', ...), for whoever lets them in.
  final String? acceptedProvider;

  bool get byCode => code != null;

  /// 'owner', 'admin' or the id of a role the owners made.
  final String role;

  /// Crates offered on top of the role, with the switches offered.
  final Map<String, Set<String>> grants;

  /// When the access offered ends, in seconds since the epoch; null for
  /// never.
  final int? endsAt;
  final DateTime expiresAt;
  final bool expired;

  /// The address of whoever invited them last.
  final String? invitedBy;

  /// Set once the person accepted: their account, and the keys they
  /// published, which an owner or admin compares with them before
  /// confirming.
  final String? acceptedUid;
  final PublishedAccountKeys? acceptedKeys;

  /// The Orchard's rules they fell short of when they accepted: a
  /// confirmation waits until they accept again within them.
  final List<String> acceptedRulesUnmet;

  bool get accepted => acceptedUid != null;
}

/// A device offered for approval with an invitation as it is accepted (the
/// security UX review's R18; crypto/join_device.dart): the device's key, and
/// the joining account's signature over the team, the account and that key.
class JoinDevice {
  const JoinDevice({required this.key, required this.signature, this.platform});

  /// The device's key (32 bytes).
  final Uint8List key;

  /// The account's Ed25519 signature over joinDeviceMessage (64 bytes).
  final Uint8List signature;

  /// The platform the accepting session reported ('windows', 'macos',
  /// 'linux', 'android' or 'ios'), as the server lists it; null where not
  /// known. Not signed: a hint beside the device's code, which is.
  final String? platform;

  /// [key] as the record and the server write it.
  String get keyText => deviceKeyText(key);

  Map<String, String> toJson() => {'device_key': keyText, 'device_sig': base64Encode(signature)};

  /// The device the server lists with an invitation; null for anything but a
  /// key of 32 bytes and a signature of 64, each in the one spelling base64
  /// gives its bytes.
  static JoinDevice? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final key = deviceKeyBytes(raw['key']);
    final sig = raw['sig'];
    if (key == null || sig is! String) return null;
    final Uint8List signature;
    try {
      signature = base64Decode(sig);
    } on FormatException {
      return null;
    }
    if (signature.length != 64 || base64Encode(signature) != sig) return null;
    final platform = raw['platform'];
    return JoinDevice(key: key, signature: signature, platform: platform is String ? platform : null);
  }
}

/// An invite code as those who may invite see it: whose keys its tags name,
/// the code sealed to its maker's own account key (only for the maker's
/// devices), and once used, the person's tag, the platform they used it on
/// (what their session reports) and when.
class InviteCodeInfo {
  const InviteCodeInfo({
    required this.makerUid,
    required this.makerKeyVersion,
    this.sealed,
    this.joinerTag,
    this.usedPlatform,
    this.usedAt,
    this.uses = 0,
    this.usesMax = 1,
    this.fromCode,
  });

  final String makerUid;
  final int makerKeyVersion;
  final Uint8List? sealed;
  final Uint8List? joinerTag;

  /// 'windows', 'macos', 'linux', 'android' or 'ios'; null where not known.
  final String? usedPlatform;
  final DateTime? usedAt;

  /// A team code: how many have used it, of how many it was made for.
  final int uses;
  final int usesMax;

  /// A use of a team code: the code's own invitation id, which its tags
  /// and its sealed code were made with (the maker's device checks with
  /// it). Null for a code used by one person.
  final String? fromCode;
}

/// An invite code made on this device, as the server took it.
class InviteCodeSaved {
  const InviteCodeSaved({required this.inviteId, required this.expiresAt});

  final String inviteId;
  final DateTime expiresAt;
}

/// An invite code's offer as the server gives it to whoever holds the code,
/// before they accept: what their device checks against the code (the
/// maker's keys and tag, the offer exactly) and opens with it.
class InviteCodeOffer {
  const InviteCodeOffer({
    required this.invite,
    required this.grants,
    required this.makerKeys,
    required this.ownerTag,
    required this.offerSealed,
  });

  /// The offer as an invitation shows it (role, Crates, end date, who made
  /// it, the rules and what the team records).
  final MyInvite invite;
  final Map<String, Set<String>> grants;
  final PublishedAccountKeys makerKeys;
  final Uint8List ownerTag;
  final Uint8List offerSealed;
}

/// An invitation as the invited person sees it: who invited them, the
/// role, how many Crates it opens and when the access ends. The Orchard's
/// name is encrypted for its members, so it is not known until they are in.
class MyInvite {
  const MyInvite({
    required this.id,
    required this.orchardId,
    required this.role,
    required this.crates,
    required this.expiresAt,
    required this.accepted,
    this.invitedBy,
    this.endsAt,
    this.rulesUnmet = const [],
    this.tracking = RecordTracking.none,
    this.exported = false,
    this.sessionLogs = 0,
    this.watched = 0,
    this.byCode = false,
  });

  final String id;
  final String orchardId;

  /// An invite code this account used (not an invitation to its address).
  final bool byCode;

  /// 'owner', 'admin' or the id of a role the owners made (its name is
  /// encrypted for the members).
  final String role;
  final int crates;
  final DateTime expiresAt;

  /// When the access offered ends, in seconds since the epoch.
  final int? endsAt;

  /// They accepted; an owner or admin still has to confirm them.
  final bool accepted;
  final String? invitedBy;

  /// The Orchard's rules the server checks that this account does not meet
  /// yet: accepting waits until it does.
  final List<String> rulesUnmet;

  /// What the Orchard records about its members, as the server says
  /// before they join; once in, the app checks it against the record.
  final RecordTracking tracking;

  /// Whether the Orchard sends its events on to a system of its own (event
  /// export), as the server says before they join.
  final bool exported;

  /// How many of the Crates offered log their sessions.
  final int sessionLogs;

  /// How many of the Crates offered have their sessions watched.
  final int watched;
}

/// An invitation sent: its id, and whether an email went out.
class InviteSent {
  const InviteSent(this.inviteId, {required this.emailed});

  final String inviteId;
  final bool emailed;
}

/// One generation of the Orchard's key or a Crate's, sealed to [uid] (to
/// the version of their keys the record holds now) and signed by whoever
/// made the change it comes with ([keyCopySignatureMessage]): what a change
/// to the record that lets someone open the Orchard or a Crate must bring.
/// [crateId] is null for the Orchard's own key.
class GrantCopy {
  const GrantCopy({
    required this.uid,
    this.crateId,
    required this.generation,
    required this.sealed,
    required this.signature,
  });

  final String uid;
  final String? crateId;
  final int generation;
  final Uint8List sealed;
  final Uint8List signature;

  Map<String, dynamic> toJson() => {
        'uid': uid,
        if (crateId != null) 'crate_id': crateId,
        'generation': generation,
        'sealed': base64Encode(sealed),
        'signature': base64Encode(signature),
      };
}

/// A new Crate: its id, its encrypted name, its record entry (crate.add),
/// and its key sealed to everyone it opens to.
class NewCrate {
  const NewCrate({
    required this.id,
    required this.nameEnc,
    required this.entry,
    required this.copies,
  });

  final String id;
  final Uint8List nameEnc;
  final RecordEntry entry;
  final List<GrantCopy> copies;
}

/// An Orchard's first Crate: its key sealed to the owner, who signs the copy
/// with the same version of their keys it is sealed to.
class FirstCrate {
  const FirstCrate({
    required this.id,
    required this.nameEnc,
    required this.keySealed,
    required this.keySignature,
  });

  final String id;
  final Uint8List nameEnc;
  final Uint8List keySealed;
  final Uint8List keySignature;
}

/// A new Orchard with its first Crate and the first entry of its record.
class NewOrchard {
  const NewOrchard({
    required this.id,
    required this.nameEnc,
    required this.keySealed,
    required this.keyVersion,
    required this.keySignature,
    required this.firstCrate,
    required this.record,
  });

  final String id;
  final Uint8List nameEnc;
  final Uint8List keySealed;

  /// The creator's account key version: the copy is sealed to it and
  /// signed with it.
  final int keyVersion;
  final Uint8List keySignature;
  final FirstCrate firstCrate;

  /// The record's first entry (create), signed by the owner.
  final RecordEntry record;
}

/// A page of an Orchard's record, oldest first.
class RecordPage {
  const RecordPage({required this.entries, required this.seq, required this.more, this.receipt});

  final List<RecordEntry> entries;

  /// How many entries the record holds on the server.
  final int seq;
  final bool more;

  /// With the last page: the server's receipt for the record as it stands
  /// at [seq] (the restore work), which this device keeps to send entries
  /// back should the server be restored from an older backup. Null from a
  /// server that gives none.
  final String? receipt;
}

/// A key copy the server lacks after a restore (the restore work): for
/// [uid], of the Orchard's key ([crateId] null) or a Crate's, at
/// [generation], to be sealed to their keys of [recipientKeyVersion].
class MissingCopy {
  const MissingCopy({required this.uid, this.crateId, required this.generation, required this.recipientKeyVersion});

  final String uid;
  final String? crateId;
  final int generation;
  final int recipientKeyVersion;
}

/// A name a device brings back with record entries the server lost: the
/// Orchard's ([crateId] null) or a Crate's, encrypted under that key's
/// [generation].
class MendName {
  const MendName({this.crateId, required this.generation, required this.nameEnc});

  final String? crateId;
  final int generation;
  final Uint8List nameEnc;

  Map<String, dynamic> toJson() => {
        'crate_id': crateId,
        'generation': generation,
        'name_enc': base64Encode(nameEnc),
      };
}

/// What a device asks of a Crate along with its changes (the restore
/// work): whether the server still holds the version of [itemId] at
/// [revision], the newest this device knows in that Crate.
class ItemCheck {
  const ItemCheck(this.itemId, this.revision);

  final String itemId;
  final int revision;
}


/// One item as the server holds it now.
class RemoteItem {
  const RemoteItem({required this.revision, required this.item});

  final int revision;

  /// Null only for a deletion written without a record, which ZestSSH never
  /// writes; such an item is refused like any other that does not open.
  final SealedItem? item;
}

/// A deleted item in a Crate's trash: the deletion, and the version
/// it replaced, which the server keeps until [keptUntil].
class TrashedItem {
  const TrashedItem({required this.itemId, required this.deletion, required this.last, required this.keptUntil});

  final String itemId;
  final RemoteItem deletion;
  final RemoteItem last;
  final DateTime keptUntil;
}

/// One earlier version of a Crate's item, replaced at [replacedAt] by
/// the server's clock; [id] orders them and pages through them.
class HistoryVersion {
  const HistoryVersion({
    required this.id,
    required this.itemId,
    required this.revision,
    required this.item,
    required this.replacedAt,
  });

  final int id;
  final String itemId;

  /// The revision it had; null for a version kept from a conflict it lost
  /// before it reached the server.
  final int? revision;
  final SealedItem item;
  final DateTime replacedAt;
}

/// A page of a Crate's version history, newest first, with the
/// version each item on it has now; only versions replaced since [since],
/// when an owner last turned version history on.
class HistoryPage {
  const HistoryPage({required this.versions, required this.current, required this.since, required this.more});

  final List<HistoryVersion> versions;
  final Map<String, RemoteItem> current;
  final DateTime since;
  final bool more;
}

/// One thing a member's device did, sealed with the Orchard's key of
/// [keyGeneration] ([sealActivity]).
class SealedActivity {
  const SealedActivity({required this.keyGeneration, required this.sealed});

  final int keyGeneration;
  final Uint8List sealed;
}

/// A sealed activity event as owners read it, with the account that sent
/// it ([uid]) and when the server took it ([at]).
class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.uid,
    required this.keyGeneration,
    required this.sealed,
    required this.at,
  });

  final int id;
  final String uid;
  final int keyGeneration;
  final Uint8List sealed;
  final DateTime at;
}

/// A page of an Orchard's activity: newest first, or, read forward from an
/// event, oldest first.
class ActivityPage {
  const ActivityPage({required this.events, required this.more});

  final List<ActivityEntry> events;
  final bool more;
}

/// A team session log as the server keeps it: its sealed header, who
/// sent it ([uid]), how far it got, and whether it ended properly.
class RemoteSessionLog {
  const RemoteSessionLog({
    required this.id,
    required this.uid,
    required this.keyGeneration,
    required this.header,
    required this.chunks,
    required this.bytes,
    required this.closed,
    required this.startedAt,
    required this.updatedAt,
  });

  final String id;
  final String uid;
  final int keyGeneration;
  final Uint8List header;
  final int chunks;
  final int bytes;
  final bool closed;
  final DateTime startedAt;
  final DateTime updatedAt;
}

/// A page of a Crate's session logs, newest first.
class SessionLogPage {
  const SessionLogPage({required this.logs, required this.more});

  final List<RemoteSessionLog> logs;
  final bool more;
}

/// A page of a session log's chunks, in order.
class SessionLogChunkPage {
  const SessionLogChunkPage({required this.chunks, required this.more});

  final List<({int seq, int keyGeneration, Uint8List sealed})> chunks;
  final bool more;
}

/// A page of a Crate's changes, oldest first.
class ItemsPage {
  const ItemsPage({
    required this.items,
    required this.latest,
    required this.more,
    required this.keyGeneration,
    this.head,
    this.check,
  });

  final List<(String itemId, RemoteItem item)> items;

  /// Read on from here.
  final int latest;
  final bool more;
  final int keyGeneration;

  /// The Crate's newest revision on the server; null from a server that
  /// does not say. Below what this device read: the server went back in
  /// time (a restore from a backup).
  final int? head;

  /// The answer to an [ItemCheck]: whether the server still holds that
  /// version. Null when none was asked, or from a server that does not say.
  final bool? check;
}

/// One write: the item, and the revision it was based on (null for an item
/// this device has never seen on the server in this Crate).
class ItemWrite {
  const ItemWrite(this.item, this.baseRevision);

  final SealedItem item;
  final int? baseRevision;
}

sealed class WriteResult {
  const WriteResult(this.itemId);

  final String itemId;
}

class WriteOk extends WriteResult {
  const WriteOk(super.itemId, this.revision);

  final int revision;
}

/// The item changed on the server since the version the write was based on.
class WriteConflict extends WriteResult {
  const WriteConflict(super.itemId, this.current);

  /// The version on the server now; null if the item is not there.
  final RemoteItem? current;
}

/// Why a request to the Orchard routes did not go through.
class OrchardServerException implements Exception, HasTypeName {
  const OrchardServerException(this.status, this.code,
      {this.reason,
      this.recipients,
      this.unmet,
      this.need,
      this.seats,
      this.seatsUsed,
      this.seatsNeeded,
      this.deleting,
      this.withinSeconds});

  final int status;

  /// For 'team-being-deleted': who asked and the day the team
  /// goes.
  final TeamDeletion? deleting;

  /// For 'recent-sign-in-required': how recent the sign-in must be, where
  /// the server says (ten minutes to delete a team, two hours for its other
  /// changes).
  final int? withinSeconds;

  /// For 'record-refused': the rule the entry broke, as the server words it
  /// (the app's record gives the same reason for the same entry). For
  /// 'seats-needed', 'storage' where it is what the team's vaults hold that is
  /// short of seats, not how many people it has.
  final String? reason;

  /// For a key rotation's 'copies-changed': whom the server says the
  /// new key must reach.
  final List<String>? recipients;

  /// For 'rules-unmet', 'rules-unmet-by-you' and 'invitee-rules-unmet'
  /// say which of the Orchard's rules ('two_step', 'email_domain',
  /// 'reauth').
  final List<String>? unmet;

  /// For 'read-only': the switch the request needed ('add', 'edit',
  /// 'delete', 'manage').
  final String? need;

  /// For 'seats-full' and 'seats-needed': the Orchard's seats, and
  /// how many people hold one.
  final int? seats;
  final int? seatsUsed;

  /// For 'seats-full' and 'seats-needed': how many more seats would
  /// let the request through.
  final int? seatsNeeded;

  /// The server's error code: 'not-found', 'read-only', 'forbidden',
  /// 'stale-key', 'no-keys', 'orchard-limit', 'crate-limit', 'id-taken',
  /// 'invalid-request', 'generation-moved' (a rename under a key replaced
  /// meanwhile), for invitations 'already-member',
  /// 'rate-limited', 'not-accepted', 'expired', 'ended', 'invite-changed',
  /// for key copies 'copies-changed' or 'bad-signature', for the record
  /// 'record-moved' (someone else's entry went in first: read the record and
  /// try again) or 'record-refused' (see [reason]), and after a restore
  /// 'record-fork' and 'record-unproven' ([CrateServer.mendRecord]) and
  /// 'not-entitled' (sealing again a key this account does not hold),
  /// 'recent-sign-in-required' when changing who is in the Orchard or what
  /// they may do, and for the Orchard's rules (see [unmet])
  /// 'rules-unmet' (this account falls short), 'rules-unmet-by-you' (rules
  /// an owner set that they do not meet) and 'invitee-rules-unmet', and for
  /// team recovery 'team-recovery-off', 'owners-only',
  /// 'not-for-yourself' and 'not-waiting' (the member's published keys are
  /// not the ones named, or not past the record's), and for certificates
  /// 'no-authority' (the Crate's authority is off), 'no-principals'
  /// (this account's role signs in as nobody), 'clock' (the request's time
  /// is far from the server's), 'already-signed' and 'bad-certificate', and
  /// for what the team records 'history-off' and 'activity-off', and
  /// for session logs 'session-logs-off', 'out-of-order', 'log-closed',
  /// 'log-full' and 'session-logs-team-full' (what the team's seats keep of
  /// them is used up), and for the record's own limits 'record-full' and
  /// 'record-entry-too-large', and for seats 'seats-full' (an invitation needs a
  /// seat) and 'seats-needed' (more people than seats, or vaults that hold what
  /// the seats keep, [reason]: nothing new is added)
  /// and 'business-services-required' (company sign-in and directory sync),
  /// and for trusted devices 'device-not-named' (this sign-in has not
  /// said which device it is), 'device-approved' (nothing to ask for),
  /// 'device-not-approved' (only an approved device answers a request, and
  /// only one gets a certificate while the rule is on), 'answered' (someone
  /// answers the request already), 'not-answered' and 'reveal-mismatch'
  /// (what a device showed is not what it committed to: the request ended);
  /// or null.
  final String? code;

  /// Another entry went into the record first.
  bool get recordMoved => status == 409 && code == 'record-moved';

  /// The Crate or Orchard is not there for this account (deleted, or access
  /// removed). Also what the server says while Orchards are switched off.
  bool get notFound => status == 404;

  /// The server has no such route: one a deploy behind this app (its
  /// "Not found" carries no code, where a route that is there and finds
  /// nothing says 'not-found'). What the route is for is then done as before
  /// it (the restore work's routes: GET .../record/holds, POST
  /// .../record/mend), never a failure of the whole refresh.
  bool get routeMissing => status == 404 && code == null;

  /// The account replaced its keys and this request was made with the old
  /// ones: this device must fetch the new keys first.
  bool get staleAccountKeys => status == 409 && code == 'stale-account-keys';

  /// Changing who is in the Orchard or what they may do needs a sign-in
  /// from the last few minutes (with the second factor when the account has
  /// one).
  bool get recentSignInRequired => status == 403 && code == 'recent-sign-in-required';

  /// This account falls short of the Orchard's rules: [unmet] says
  /// which.
  bool get rulesUnmet => status == 403 && code == 'rules-unmet';

  /// The team is being deleted: every member is held back,
  /// owners too, until an owner undoes it or the team goes ([deleting] says
  /// who asked and when).
  bool get teamBeingDeleted => code == 'team-being-deleted';

  /// Only that this device is not approved holds it back.
  bool get deviceNotApproved => rulesUnmet && unmet != null && unmet!.length == 1 && unmet!.single == 'trusted_device';

  @override
  String toString() => 'Orchards: HTTP $status ${code ?? ''}';

  @override
  String get typeName => 'OrchardServerException';
}

/// A request for access (3.0) as the server keeps it: a member
/// asks for a Crate, or for more in one they open, for a set time.
class AccessRequest {
  const AccessRequest({
    required this.id,
    required this.crateId,
    required this.level,
    required this.seconds,
    required this.noteEnc,
    required this.noteGeneration,
    required this.expiresAt,
    this.uid,
  });

  final String id;

  /// The Crate asked for, or null when the member could not name it (nobody
  /// reads the name of a Crate they do not open): the note says which.
  final String? crateId;

  /// How far: connect, use or edit.
  final CrateLevel level;

  /// For how long, from the moment it is given.
  final int seconds;

  /// What the member says they need, encrypted under the Orchard's key of
  /// [noteGeneration] (encryptAccessNote), when they said anything.
  final Uint8List? noteEnc;
  final int? noteGeneration;

  /// When the request lapses unanswered, in seconds since the epoch.
  final int expiresAt;

  /// Who asks, for a request that waits for this account's answer; null for
  /// this account's own.
  final String? uid;
}

/// The requests for access in an Orchard that concern this account.
typedef AccessRequests = ({List<AccessRequest> mine, List<AccessRequest> waiting});

/// A device's request to be approved for an Orchard (3.0), as
/// ZestSSH Cloud passes it between the device that asks and the one that
/// answers. The server relays these bytes and cannot make them match: the
/// asking device commits to its key and a random value before it sees
/// anything of the other side.
class DeviceTrustRequest {
  const DeviceTrustRequest({
    required this.id,
    required this.stage,
    required this.expiresAt,
    this.uid,
    this.commitment,
    this.responderNonce,
    this.sameAccount = false,
    this.deviceKey,
    this.nonce,
  });

  final String id;

  /// 'created' (nobody answered yet), 'responded' (someone did, with
  /// [responderNonce]) or 'revealed' (the asking device then showed its
  /// [deviceKey] and [nonce]).
  final String stage;

  /// When it lapses, in seconds since the epoch: ten minutes after it was
  /// made, whatever its stage.
  final int expiresAt;

  /// Whose device asks, for a request this account could answer; null for
  /// this device's own.
  final String? uid;

  /// What the asking device committed to ([deviceTrustCommitment]), for a
  /// request this account could answer.
  final Uint8List? commitment;

  /// The answering device's random value, once someone answered.
  final Uint8List? responderNonce;

  /// For this device's own request, once answered: whether the answer came
  /// from another device of the same account.
  final bool sameAccount;

  /// What the asking device showed, for the device that answered.
  final Uint8List? deviceKey;
  final Uint8List? nonce;
}

/// The requests to approve a device in an Orchard that concern this device:
/// its own, and those of others it could answer.
typedef DeviceTrustRequests = ({List<DeviceTrustRequest> mine, List<DeviceTrustRequest> waiting});

/// A write under an old Crate key: the key changed, fetch the new one.
class StaleCrateKey extends OrchardServerException {
  const StaleCrateKey(this.keyGeneration) : super(409, 'stale-key');

  final int keyGeneration;

  @override
  String get typeName => 'StaleCrateKey';
}

/// What the Crate sync needs from ZestSSH Cloud, so tests can stand in for
/// the server.
abstract class CrateServer {
  /// The Orchards this account is in, with the Crates it can open and its
  /// sealed keys.
  Future<List<RemoteOrchard>> orchards();

  /// The entries of an Orchard's record after [after], a page at a time.
  Future<RecordPage> record(String orchardId, {required int after});

  /// Appends [entries] (signed by this account, in order at the end of the
  /// record) with the key copies they call for, and returns the record's
  /// length. Throws an [OrchardServerException] with
  /// [OrchardServerException.recordMoved] when another entry went in first.
  Future<int> appendRecord(String orchardId, List<RecordEntry> entries, {List<GrantCopy> copies = const []});

  /// After the server was restored from an older backup: sends back the
  /// record's entries after [after] (the server's last, which this device
  /// holds the same) as this device holds them, up to the entry [receipt]
  /// (the server's own) is for, with the names of Crates and keys they add
  /// that this device can seal ([names]). Returns the record's length. Throws
  /// an [OrchardServerException]: 'record-moved' (another device sent them
  /// first, or another entry went in: read the record again), 'record-fork'
  /// (the server's record parts ways with this one), 'record-unproven' (the
  /// server gave no receipt for them) or 'record-refused'.
  Future<int> mendRecord(String orchardId,
      {required int after, required List<RecordEntry> entries, required String receipt, List<MendName> names = const []});

  /// Whether the server's record of [orchardId] holds entry [seq] with
  /// [hash]: asked when the server does not list an Orchard this device
  /// holds, to tell a server that lost entries (a restore) from one that
  /// took this account out, or deleted the team (then when).
  Future<RecordHolds> recordHolds(String orchardId, int seq, Uint8List hash);

  /// Deletes the team (owners): the signed team.delete [entry],
  /// next in the record. Every member is held back from then on, owners
  /// too, and the team goes seven days on unless an owner undoes it. A retry
  /// of a request that went through answers the same. Throws an
  /// [OrchardServerException]: 'feature-not-yet' (new kinds of entry are
  /// off), 'recent-sign-in-required' (a sign-in from the last ten minutes),
  /// 'team-being-deleted' (asked already), 'owners-only', 'rules-unmet', or
  /// the record's own refusals.
  Future<TeamDeletion> deleteTeam(String orchardId, RecordEntry entry);

  /// Undoes deleting the team before its day (owners): the
  /// signed team.restore [entry]. Returns the record's length. Throws an
  /// [OrchardServerException]: 'team-not-being-deleted', 'undo-too-late'
  /// (its day came), 'recent-sign-in-required', 'owners-only',
  /// 'rules-unmet'.
  Future<int> restoreTeam(String orchardId, RecordEntry entry);

  /// The key copies the server lacks after a restore.
  Future<List<MissingCopy>> missingCopies(String orchardId);

  /// Sends key copies sealed again by this account (each for one of
  /// [missingCopies]); returns how many the server still lacks.
  Future<int> fillCopies(String orchardId, List<GrantCopy> copies);

  /// Creates an Orchard with its first Crate. A retry of a create that went
  /// through is a success.
  Future<void> createOrchard(NewOrchard orchard);

  Future<void> createCrate(String orchardId, NewCrate crate);

  /// A Crate's new name, encrypted with its key of [generation]; 409
  /// 'generation-moved' when a rotation replaced that key meanwhile.
  Future<void> renameCrate(String crateId, Uint8List nameEnc, {required int generation});

  /// The Orchard's new name (owners and admins), likewise.
  Future<void> renameOrchard(String orchardId, Uint8List nameEnc, {required int generation});

  /// A Crate's changes after revision [since], oldest first; with [check],
  /// whether the server still holds that version (see [ItemsPage.check]).
  Future<ItemsPage> changes(String crateId, {required int since, int? limit, ItemCheck? check});

  /// Writes items to a Crate, signed with the account keys of version
  /// [keyVersion]. Throws [StaleCrateKey] when a write used an old Crate key,
  /// and an [OrchardServerException] with [OrchardServerException.staleAccountKeys]
  /// when the account's keys are newer than [keyVersion]; nothing is written
  /// then.
  Future<List<WriteResult>> write(String crateId, List<ItemWrite> writes, {required int keyVersion});

  /// Keeps a version that lost a conflict in the item's history.
  Future<void> keepInHistory(String crateId, SealedItem item, {int? revision});

  /// Moves an Orchard's key to its next generation (owners and admins) and
  /// returns it.
  /// Makes the next generation of the Orchard's key or a Crate's: the
  /// key.rotate [entry] (signed by this account, next in the record), the
  /// name encrypted under the new key, and a copy of it for exactly everyone
  /// who holds that key now. Returns the new generation. A 'copies-changed'
  /// refusal names the [OrchardServerException.recipients] it wants.
  Future<int> rotateKey(String orchardId, RecordEntry entry,
      {required Uint8List nameEnc, required List<GrantCopy> copies});

  /// The Orchard's members with their published keys, earlier keys and the
  /// signed checks of their keys. Members only.
  Future<MemberList> members(String orchardId);

  /// Stores this account's signed statement that a member's current keys
  /// are theirs ([signMemberVerification]).
  Future<void> verifyMember(
    String orchardId, {
    required String subjectUid,
    required int subjectKeyVersion,
    required int keyVersion,
    required Uint8List signature,
  });

  /// Moves a Crate's key to its next generation (manage access) and returns
  /// it. Writes with the old key are refused from then on.

  // ── Invitations ──

  /// Invites [email] as [role] with the extra Crates [grants] and an end
  /// date [endsAt] (seconds since the epoch), within what the record lets
  /// this account offer. Inviting the same address again refreshes the
  /// invitation.
  Future<InviteSent> invite(
    String orchardId, {
    required String email,
    required String role,
    Map<String, Set<String>> grants = const {},
    int? endsAt,
    bool sendEmail = true,
    bool resend = false,
  });

  /// The Orchard's invitations (those who may invite).
  Future<List<OrchardInvite>> invites(String orchardId);

  // ── Invite codes ──

  /// Saves an invite code made on this device: never the code, only what is
  /// derived from it ([lookupId] as hex, [ownerTag]) and what is sealed
  /// ([codeSealed] to this account's own key, [offerSealed] under the code),
  /// with the offer. [expiresIn] is 3600, 86400, 604800 or 2592000 seconds.
  /// [replacesInvite]: an invitation to an address it is sent instead of.
  Future<InviteCodeSaved> saveInviteCode(
    String orchardId, {
    required String inviteId,
    required String lookupId,
    required Uint8List ownerTag,
    required int makerKeyVersion,
    required Uint8List codeSealed,
    required Uint8List offerSealed,
    required String role,
    Map<String, Set<String>> grants = const {},
    int? endsAt,
    required int expiresIn,
    String? replacesInvite,
    int usesMax = 1,
  });

  /// How long an unused code waits from now; returns when it lapses.
  Future<DateTime> changeInviteCodeExpiry(String orchardId, String inviteId, int expiresIn);

  /// The offer of the live, unused code whose lookup id is [lookupId].
  Future<InviteCodeOffer> inviteCodeOffer(String lookupId);

  /// Accepts that code with this account's [keyVersion] and [joinerTag], and
  /// the [device] it is used on when there is one to offer; returns
  /// the invitation's id.
  Future<String> acceptInviteCode(String lookupId,
      {required int keyVersion, required Uint8List joinerTag, JoinDevice? device});

  Future<void> withdrawInvite(String orchardId, String inviteId);

  /// Adds the person who accepted [inviteId]: [entry] is the member.add this
  /// account signed, [copies] every key they gain, sealed to them. [device]:
  /// the device.trust that follows it, approving the device they accepted on
  /// in the same step.
  Future<void> confirmInvite(String orchardId, String inviteId,
      {required RecordEntry entry, required List<GrantCopy> copies, RecordEntry? device});

  /// The invitations to the signed-in account's address.
  Future<List<MyInvite>> myInvites();

  /// Accepts [inviteId], offering the [device] it is accepted on when there
  /// is one.
  Future<void> acceptInvite(String inviteId, {JoinDevice? device});

  Future<void> declineInvite(String inviteId);

  // ── Access on request ──

  /// Asks for [crateId] (null: a Crate this account cannot name, described
  /// in the note) at [level] for [seconds]. Asking again for the same Crate
  /// changes the request there is. Throws an [OrchardServerException] with
  /// the code 'request-limit' when five already wait, and
  /// 'access-not-needed' for an owner or admin.
  Future<AccessRequest> requestAccess(String orchardId,
      {String? crateId, required CrateLevel level, required int seconds, Uint8List? noteEnc, int? noteGeneration});

  /// This account's own requests in [orchardId], and those of others it
  /// could answer.
  Future<AccessRequests> accessRequests(String orchardId);

  /// Withdraws this account's request, or declines one it could answer.
  /// Answering one with access is an access.grant entry that names it
  /// ([appendRecord]).
  Future<void> deleteAccessRequest(String orchardId, String requestId);

  // ── Trusted devices ──

  /// The id of the sign-in these requests are made with, or null when it
  /// has none (a sign-in from before sessions existed): what a device signs
  /// to say the sign-in is its own.
  Future<String?> currentSession();

  /// Says that this sign-in is the device whose key is [deviceKey] (32
  /// bytes), with that device's [signature] over [sessionDeviceMessage].
  /// Said once: another key for the same sign-in is refused
  /// ('device-key-set'). False when nothing needs it (the account is in no
  /// Orchard) or the sign-in has no session.
  Future<bool> nameDevice({required Uint8List deviceKey, required Uint8List signature});

  /// The requests to approve a device in [orchardId] that concern this
  /// device. Open to a device that is held back only as not approved.
  Future<DeviceTrustRequests> deviceRequests(String orchardId);

  /// Asks for this device to be approved in [orchardId], committing to its
  /// key and a random value ([deviceTrustCommitment]). Asking again
  /// replaces the request there is. Returns the request's id.
  Future<String> askDeviceTrust(String orchardId, Uint8List commitment);

  /// Answers the request [requestId] with this device's random value
  /// ([nonce], 32 bytes), from an approved device of someone who may
  /// approve it.
  Future<void> answerDeviceTrust(String orchardId, String requestId, Uint8List nonce);

  /// Shows what this device committed to in its request [requestId]: its
  /// key and its random value. A showing that does not match ends the
  /// request ('reveal-mismatch').
  Future<void> showDeviceTrust(String orchardId, String requestId, {required Uint8List deviceKey, required Uint8List nonce});

  /// Takes this account's request back, or declines one this device could
  /// answer. Approving one is a device.trust entry ([appendRecord]).
  Future<void> dropDeviceTrust(String orchardId, String requestId);

  // ── Team recovery ──

  /// Whether team recovery is on in [orchardId] as the server has it, and
  /// who waits for it: everyone, for an owner; only this account, otherwise.
  Future<TeamRecoveryStatus> teamRecovery(String orchardId);

  /// Stores this account's approval (an owner's) of [subjectUid]'s new keys
  /// at [keyVersion] ([signTeamRecovery]), signed with this account's keys
  /// at [approverKeyVersion].
  Future<void> approveRecovery(
    String orchardId, {
    required String subjectUid,
    required int keyVersion,
    required int approverKeyVersion,
    required Uint8List approval,
  });

  /// Takes back this account's approval of [subjectUid]'s new keys.
  Future<void> withdrawRecoveryApproval(String orchardId, String subjectUid);

  /// Recovers a member: [entry] is the member.recover this account signed
  /// (carrying another owner's approval), [copies] every generation of each
  /// key the member holds, sealed to their new keys.
  Future<void> completeRecovery(String orchardId, RecordEntry entry, {required List<GrantCopy> copies});

  // ── Certificates ──

  /// Asks for a certificate for this device's SSH key in [crateId]:
  /// [request] signed with this account's keys ([certRequestMessage]). The
  /// same request again is taken once.
  Future<void> askCertificate(String crateId, CertRequest request);

  /// The requests in [crateId] waiting for an owner's device to sign them
  /// (owners only), oldest first.
  Future<List<CertRequest>> waitingCertificates(String crateId);

  /// Hands back [certificate] (the OpenSSH certificate blob) for request
  /// [requestId] in [crateId] (owners only).
  Future<void> signCertificate(String crateId, String requestId, Uint8List certificate);

  /// This account's certificates in [crateId] that have not expired, newest
  /// first.
  Future<List<IssuedCertificate>> myCertificates(String crateId);

  // ── What the team records ──

  /// What was deleted in [crateId] in the last 30 days, with the version
  /// each deletion replaced, newest first. Needs add there.
  Future<List<TrashedItem>> trash(String crateId);

  /// Earlier versions of [crateId]'s items (of [itemId]'s only, when given),
  /// newest first, older than the version with id [before] when given. Owners
  /// and those who manage the Crate, while version history is on (409
  /// 'history-off' otherwise).
  Future<HistoryPage> itemHistory(String crateId, {String? itemId, int? before});

  /// Sends what this device did (up to 50 events), while activity is on in
  /// [orchardId] (409 'activity-off' otherwise).
  Future<void> sendActivity(String orchardId, List<SealedActivity> events);

  /// [orchardId]'s activity (owners, while activity is on): newest first,
  /// older than [before] when given; or, with [after], oldest first from
  /// just after that event (0 for the first there is), which is how the
  /// device that sends them on reads them.
  Future<ActivityPage> activity(String orchardId, {int? before, int? after});

  // ── Team session logs ──

  /// Starts the log [logId] of a session to a host in [crateId], with its
  /// sealed [header], while session logs are on there (409
  /// 'session-logs-off' otherwise). A retry of one that went in is taken.
  Future<void> startSessionLog(String crateId, String logId, {required int keyGeneration, required Uint8List header});

  /// Sends the [seq]th chunk of the log [logId] (in order; [last] ends it).
  Future<void> sendSessionLogChunk(String crateId, String logId,
      {required int seq, required int keyGeneration, required Uint8List sealed, bool last = false});

  /// [crateId]'s session logs, newest first, older than [before] when given
  /// (owners and those who manage the Crate).
  Future<SessionLogPage> sessionLogs(String crateId, {String? before});

  /// The chunks of the log [logId] after [after], in order.
  Future<SessionLogChunkPage> sessionLogChunks(String crateId, String logId, {int after = 0});

  /// Deletes the log [logId] (owners).
  Future<void> deleteSessionLog(String crateId, String logId);
}

/// A certificate an owner's device signed for one of this account's
/// requests, as the server keeps it until it expires.
class IssuedCertificate {
  const IssuedCertificate({
    required this.requestId,
    required this.sshPublicKey,
    required this.certificate,
    required this.validBefore,
  });

  final String requestId;

  /// The SSH key it was asked for (32 bytes).
  final Uint8List sshPublicKey;

  /// The OpenSSH certificate blob.
  final Uint8List certificate;

  /// Unix seconds.
  final int validBefore;
}

/// Whether ZestSSH Cloud takes new kinds of team record entry yet (the Admin
/// role changed, a member limited in a vault): they wait until
/// [kNewRecordKindsVersion] is out on every platform, phones too,
/// since an older app that meets one stops
/// syncing that team. As the last list of Orchards said; off until one says
/// otherwise.
final ValueNotifier<bool> newRecordKindsOn = ValueNotifier<bool>(false);

/// The first version that reads the new kinds of team record entry, as the
/// app names it to people: this release's own number (a test holds it to
/// pubspec.yaml's version or later).
const String kNewRecordKindsVersion = '3.3.0';

/// [CrateServer] over HTTPS: ZestSSH Cloud's routes/orchards.js, always on
/// the hosted server with the account's own sign-in.
class OrchardsApi implements CrateServer {
  OrchardsApi({http.Client? client, String? baseUrl, required this.bearer})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? defaultBase;

  /// ZestSSH Cloud's API, or the SYNC_API_BASE_URL a build names.
  static String get defaultBase => kZestApiBase;

  final http.Client _client;
  final String _base;

  /// The account's bearer: the Firebase ID token on phones, the session
  /// token on desktop. Null when signed out.
  final Future<String?> Function() bearer;

  static const _timeout = Duration(seconds: 30);

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await bearer();
    if (token == null) throw const OrchardServerException(401, 'signed-out');
    return {
      'Authorization': 'Bearer $token',
      ...DeviceSessionHeader.headers,
      if (json) 'Content-Type': 'application/json',
    };
  }

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function(Map<String, String> headers) send, {
    bool json = false,
    Set<int> ok = const {200, 201},
  }) async {
    final response = await send(await _headers(json: json)).timeout(_timeout);
    reportIfSessionRevoked(response);
    final body = _decode(response.body);
    if (ok.contains(response.statusCode)) return body;
    final code = body['code'] is String ? body['code'] as String : null;
    if (response.statusCode == 409 && code == 'stale-key') {
      final generation = body['key_generation'];
      throw StaleCrateKey(generation is int ? generation : 0);
    }
    final recipients = body['recipients'];
    final unmet = body['unmet'];
    throw OrchardServerException(response.statusCode, code,
        reason: body['reason'] is String ? body['reason'] as String : null,
        recipients: recipients is List ? [for (final r in recipients) if (r is String) r] : null,
        unmet: unmet is List ? [for (final u in unmet) if (u is String) u] : null,
        need: body['need'] is String ? body['need'] as String : null,
        seats: body['seats'] is int ? body['seats'] as int : null,
        seatsUsed: body['used'] is int ? body['used'] as int : null,
        seatsNeeded: body['needed'] is int ? body['needed'] as int : null,
        deleting: TeamDeletion.fromJson(body['deleting']),
        withinSeconds: body['within_seconds'] is int ? body['within_seconds'] as int : null);
  }

  @override
  Future<List<RemoteOrchard>> orchards() async {
    final body = await _send((h) => _client.get(Uri.parse('$_base/orchards'), headers: h));
    newRecordKindsOn.value = body['new_record_kinds'] == true;
    final list = body['orchards'];
    if (list is! List) throw const FormatException('Not a list of Orchards');
    return [for (final o in list) _orchard(o)];
  }

  @override
  Future<void> createOrchard(NewOrchard orchard) => _send(
        (h) => _client.post(Uri.parse('$_base/orchards'),
            headers: h,
            body: jsonEncode({
              'id': orchard.id,
              'name_enc': base64Encode(orchard.nameEnc),
              'key_version': orchard.keyVersion,
              'orchard_key_sealed': base64Encode(orchard.keySealed),
              'orchard_key_sig': base64Encode(orchard.keySignature),
              'crate': {
                'id': orchard.firstCrate.id,
                'name_enc': base64Encode(orchard.firstCrate.nameEnc),
                'crate_key_sealed': base64Encode(orchard.firstCrate.keySealed),
                'crate_key_sig': base64Encode(orchard.firstCrate.keySignature),
              },
              'record': [orchard.record.toJson()],
            })),
        json: true,
      );

  @override
  Future<void> createCrate(String orchardId, NewCrate crate) => _send(
        (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/crates'),
            headers: h,
            body: jsonEncode({
              'id': crate.id,
              'name_enc': base64Encode(crate.nameEnc),
              'record': [crate.entry.toJson()],
              'copies': [for (final c in crate.copies) c.toJson()],
            })),
        json: true,
      );

  @override
  Future<RecordPage> record(String orchardId, {required int after}) async {
    final body = await _send(
        (h) => _client.get(Uri.parse('$_base/orchards/$orchardId/record?after=$after'), headers: h));
    final entries = body['entries'];
    final seq = body['seq'];
    final more = body['more'];
    if (entries is! List || seq is! int || more is! bool) {
      throw const FormatException('Not a page of the record');
    }
    return RecordPage(
      entries: [
        for (final e in entries)
          if (e is Map<String, dynamic>) RecordEntry.fromJson(e) else throw const FormatException('Not an entry'),
      ],
      seq: seq,
      more: more,
      receipt: body['receipt'] is String ? body['receipt'] as String : null,
    );
  }

  @override
  Future<int> mendRecord(String orchardId,
      {required int after,
      required List<RecordEntry> entries,
      required String receipt,
      List<MendName> names = const []}) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/record/mend'),
          headers: h,
          body: jsonEncode({
            'after': after,
            'entries': [for (final e in entries) e.toJson()],
            'receipt': receipt,
            'names': [for (final n in names) n.toJson()],
          })),
      json: true,
    );
    final seq = body['seq'];
    if (seq is! int) throw const FormatException('No record length');
    return seq;
  }

  @override
  Future<RecordHolds> recordHolds(String orchardId, int seq, Uint8List hash) async {
    final uri = Uri.parse('$_base/orchards/$orchardId/record/holds')
        .replace(queryParameters: {'seq': '$seq', 'hash': base64Encode(hash)});
    final body = await _send((h) => _client.get(uri, headers: h));
    final holds = body['holds'];
    if (holds is! bool) throw const FormatException('No answer');
    final at = body['deleted'] == true && body['deleted_at'] is String
        ? DateTime.tryParse(body['deleted_at'] as String)
        : null;
    return RecordHolds(holds, deletedAt: holds ? at?.toUtc() : null);
  }

  @override
  Future<TeamDeletion> deleteTeam(String orchardId, RecordEntry entry) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/delete'),
          headers: h, body: jsonEncode({'record': [entry.toJson()]})),
      json: true,
    );
    return TeamDeletion.fromJson(body['deleting']) ?? (throw const FormatException('No deletion'));
  }

  @override
  Future<int> restoreTeam(String orchardId, RecordEntry entry) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/restore'),
          headers: h, body: jsonEncode({'record': [entry.toJson()]})),
      json: true,
    );
    final seq = body['seq'];
    if (seq is! int) throw const FormatException('No record length');
    return seq;
  }

  @override
  Future<List<MissingCopy>> missingCopies(String orchardId) async {
    final body =
        await _send((h) => _client.get(Uri.parse('$_base/orchards/$orchardId/copies/missing'), headers: h));
    final list = body['missing'];
    if (list is! List) throw const FormatException('Not a list of copies');
    return [
      for (final m in list)
        if (m is Map<String, dynamic> &&
            m['uid'] is String &&
            m['generation'] is int &&
            m['recipient_key_version'] is int &&
            (m['crate_id'] == null || m['crate_id'] is String))
          MissingCopy(
            uid: m['uid'] as String,
            crateId: m['crate_id'] as String?,
            generation: m['generation'] as int,
            recipientKeyVersion: m['recipient_key_version'] as int,
          ),
    ];
  }

  @override
  Future<int> fillCopies(String orchardId, List<GrantCopy> copies) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/copies'),
          headers: h, body: jsonEncode({'copies': [for (final c in copies) c.toJson()]})),
      json: true,
    );
    final left = body['copies_missing'];
    return left is int ? left : 0;
  }

  @override
  Future<int> appendRecord(String orchardId, List<RecordEntry> entries,
      {List<GrantCopy> copies = const []}) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/record'),
          headers: h,
          body: jsonEncode({
            'entries': [for (final e in entries) e.toJson()],
            'copies': [for (final c in copies) c.toJson()],
          })),
      json: true,
    );
    final seq = body['seq'];
    if (seq is! int) throw const FormatException('No record length');
    return seq;
  }

  @override
  Future<void> renameCrate(String crateId, Uint8List nameEnc, {required int generation}) => _send(
        (h) => _client.patch(Uri.parse('$_base/crates/$crateId'),
            headers: h, body: jsonEncode({'name_enc': base64Encode(nameEnc), 'generation': generation})),
        json: true,
      );

  @override
  Future<void> renameOrchard(String orchardId, Uint8List nameEnc, {required int generation}) => _send(
        (h) => _client.patch(Uri.parse('$_base/orchards/$orchardId'),
            headers: h, body: jsonEncode({'name_enc': base64Encode(nameEnc), 'generation': generation})),
        json: true,
      );

  @override
  Future<ItemsPage> changes(String crateId, {required int since, int? limit, ItemCheck? check}) async {
    final query = 'since=$since${limit == null ? '' : '&limit=$limit'}'
        '${check == null ? '' : '&check_item=${check.itemId}&check_revision=${check.revision}'}';
    final body = await _send((h) =>
        _client.get(Uri.parse('$_base/crates/$crateId/items?$query'), headers: h));
    final items = body['items'];
    final latest = body['latest'];
    final more = body['more'];
    final generation = body['key_generation'];
    if (items is! List || latest is! int || more is! bool || generation is! int) {
      throw const FormatException('Not a page of changes');
    }
    return ItemsPage(
      items: [
        for (final raw in items)
          if (raw is Map<String, dynamic> && raw['item_id'] is String)
            (raw['item_id'] as String, _remoteItem(raw['item_id'] as String, raw)),
      ],
      latest: latest,
      more: more,
      keyGeneration: generation,
      head: body['head'] is int ? body['head'] as int : null,
      check: body['check'] is bool ? body['check'] as bool : null,
    );
  }

  @override
  Future<List<WriteResult>> write(String crateId, List<ItemWrite> writes,
      {required int keyVersion}) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/crates/$crateId/items'),
          headers: h,
          body: jsonEncode({
            'key_version': keyVersion,
            'items': [
              for (final w in writes)
                {
                  'item_id': w.item.itemId,
                  'base_revision': w.baseRevision,
                  'key_generation': w.item.keyGeneration,
                  'deleted': w.item.deleted,
                  'record': base64Encode(w.item.record),
                  'signature': base64Encode(w.item.signature),
                },
            ],
          })),
      json: true,
    );
    final results = body['results'];
    if (results is! List) throw const FormatException('Not a list of results');
    return [
      for (final r in results)
        if (r is Map<String, dynamic> && r['item_id'] is String)
          switch (r['status']) {
            'ok' when r['revision'] is int =>
              WriteOk(r['item_id'] as String, r['revision'] as int),
            'conflict' => WriteConflict(
                r['item_id'] as String,
                r['current'] is Map<String, dynamic>
                    ? _remoteItem(r['item_id'] as String, r['current'] as Map<String, dynamic>)
                    : null,
              ),
            _ => throw const FormatException('Not a write result'),
          },
    ];
  }

  @override
  Future<void> keepInHistory(String crateId, SealedItem item, {int? revision}) => _send(
        (h) => _client.post(
            Uri.parse('$_base/crates/$crateId/items/${item.itemId}/history'),
            headers: h,
            body: jsonEncode({
              'base_revision': revision,
              'key_generation': item.keyGeneration,
              'deleted': item.deleted,
              'record': base64Encode(item.record),
              'signature': base64Encode(item.signature),
            })),
        json: true,
      );

  static RemoteOrchard _orchard(Object? raw) {
    if (raw is! Map<String, dynamic>) throw const FormatException('Not an Orchard');
    final id = raw['id'];
    final status = raw['status'];
    if (id is String && status == 'rules') {
      final device = raw['device_rules'];
      return RemoteOrchard.inactive(id, 'rules',
          role: raw['role'] is String ? raw['role'] as String : '',
          rulesUnmet: _list(raw['unmet']),
          ruleDomains: _list(raw['email_domains']),
          heldDeviceRules: device is Map ? RecordRules.fromStored(device) : null,
          deviceRemoved: raw['device_removed'] == true);
    }
    if (id is String && status == 'deleting') {
      // Being deleted: who asked and the day it goes, this
      // account's role (owners may undo it) and the device rules in force.
      final device = raw['device_rules'];
      return RemoteOrchard.inactive(id, 'deleting',
          role: raw['role'] is String ? raw['role'] as String : '',
          heldDeviceRules: device is Map ? RecordRules.fromStored(device) : null,
          deleting: TeamDeletion.fromJson(raw['deleting']));
    }
    // Any other standing keeps this account out of the Orchard for now:
    // suspended, ended, held back by the company's directory (
    // 'directory-removed'), or one a later server sends. One this app does
    // not know never fails the list: an entry it threw on stopped every
    // Orchard of the account from refreshing, and their offline limits ran
    // on meanwhile.
    if (id is String && status is String && status != 'active') {
      return RemoteOrchard.inactive(id, status);
    }
    final name = raw['name_enc'];
    final generation = raw['key_generation'];
    final role = raw['role'];
    final crates = raw['crates'];
    if (id is! String ||
        name is! String ||
        generation is! int ||
        role is! String ||
        crates is! List) {
      throw const FormatException('Not an Orchard');
    }
    return RemoteOrchard(
      id: id,
      nameEnc: base64Decode(name),
      keyGeneration: generation,
      role: role,
      membersTag: raw['members_tag'] is String ? raw['members_tag'] as String : null,
      invitesWaiting: raw['invites_waiting'] is int ? raw['invites_waiting'] as int : null,
      recordSeq: raw['record_seq'] is int ? raw['record_seq'] as int : 0,
      rotationDue: raw['rotation_due'] == true,
      copiesMissing: raw['copies_missing'] == true,
      can: _strings(raw['can']),
      keys: _keys(raw['keys']),
      crates: [
        for (final c in crates)
          if (c is Map<String, dynamic>) _crate(c),
      ],
    );
  }

  @override
  Future<MemberList> members(String orchardId) async {
    final body = await _send(
        (h) => _client.get(Uri.parse('$_base/orchards/$orchardId/members'), headers: h));
    final list = body['members'];
    if (list is! List) throw const FormatException('Not a list of members');
    final deleted = body['deleted'];
    return MemberList(
      [
        for (final m in list)
          if (m is Map<String, dynamic> && m['uid'] is String && m['role'] is String) _member(m),
      ],
      deleted: {
        if (deleted is List)
          for (final d in deleted)
            if (d is String) d,
      },
    );
  }

  static MemberListing _member(Map<String, dynamic> m) {
    final uid = m['uid'] as String;
    PublishedAccountKeys? keys(Object? raw) {
      if (raw is! Map<String, dynamic>) return null;
      try {
        return PublishedAccountKeys.fromJson(uid, raw);
      } on FormatException {
        return null;
      }
    }

    final history = m['history'];
    final checks = m['verifications'];
    return MemberListing(
      uid: uid,
      role: m['role'] as String,
      status: m['status'] is String ? m['status'] as String : 'active',
      endsAt: m['ends_at'] is int ? m['ends_at'] as int : null,
      email: m['email'] is String ? m['email'] as String : null,
      name: m['name'] is String && (m['name'] as String).trim().isNotEmpty ? (m['name'] as String).trim() : null,
      picture: _httpsPicture(m['picture']),
      keys: keys(m['keys']),
      history: [
        if (history is List)
          for (final h in history) ?keys(h),
      ],
      checks: [
        if (checks is List)
          for (final c in checks)
            if (c is Map<String, dynamic> &&
                c['by'] is String &&
                c['by_key_version'] is int &&
                c['key_version'] is int &&
                c['signature'] is String)
              MemberCheck(
                by: c['by'] as String,
                byKeyVersion: c['by_key_version'] as int,
                keyVersion: c['key_version'] as int,
                signature: base64Decode(c['signature'] as String),
              ),
      ],
    );
  }

  @override
  Future<void> verifyMember(
    String orchardId, {
    required String subjectUid,
    required int subjectKeyVersion,
    required int keyVersion,
    required Uint8List signature,
  }) =>
      _send(
        (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/verifications'),
            headers: h,
            body: jsonEncode({
              'subject_uid': subjectUid,
              'subject_key_version': subjectKeyVersion,
              'key_version': keyVersion,
              'signature': base64Encode(signature),
            })),
        json: true,
      );

  @override
  Future<int> rotateKey(String orchardId, RecordEntry entry,
      {required Uint8List nameEnc, required List<GrantCopy> copies}) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/rotate'),
          headers: h,
          body: jsonEncode({
            'record': [entry.toJson()],
            'name_enc': base64Encode(nameEnc),
            'copies': [for (final c in copies) c.toJson()],
          })),
      json: true,
    );
    final generation = body['key_generation'];
    if (generation is! int) throw const FormatException('No key generation');
    return generation;
  }

  @override
  Future<InviteSent> invite(
    String orchardId, {
    required String email,
    required String role,
    Map<String, Set<String>> grants = const {},
    int? endsAt,
    bool sendEmail = true,
    bool resend = false,
  }) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/invites'),
          headers: h,
          body: jsonEncode({
            'email': email,
            'role': role,
            'grants': {for (final e in grants.entries) e.key: switchList(e.value)},
            'ends_at': ?endsAt,
            'send_email': sendEmail,
            if (resend) 'resend': true,
          })),
      json: true,
    );
    final id = body['invite_id'];
    if (id is! String) throw const FormatException('No invitation id');
    return InviteSent(id, emailed: body['emailed'] == true);
  }

  @override
  Future<InviteCodeSaved> saveInviteCode(
    String orchardId, {
    required String inviteId,
    required String lookupId,
    required Uint8List ownerTag,
    required int makerKeyVersion,
    required Uint8List codeSealed,
    required Uint8List offerSealed,
    required String role,
    Map<String, Set<String>> grants = const {},
    int? endsAt,
    required int expiresIn,
    String? replacesInvite,
    int usesMax = 1,
  }) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/join-codes'),
          headers: h,
          body: jsonEncode({
            'invite_id': inviteId,
            'lookup_id': lookupId,
            'owner_tag': base64Encode(ownerTag),
            'maker_key_version': makerKeyVersion,
            'code_sealed': base64Encode(codeSealed),
            'offer_sealed': base64Encode(offerSealed),
            'role': role,
            'grants': {for (final e in grants.entries) e.key: switchList(e.value)},
            'ends_at': ?endsAt,
            'expires_in': expiresIn,
            'replaces_invite': ?replacesInvite,
            if (usesMax > 1) 'uses_max': usesMax,
          })),
      json: true,
    );
    final id = body['invite_id'];
    final expires = body['expires_at'] is String ? DateTime.tryParse(body['expires_at'] as String) : null;
    if (id is! String || expires == null) throw const FormatException('No invite code');
    return InviteCodeSaved(inviteId: id, expiresAt: expires);
  }

  @override
  Future<DateTime> changeInviteCodeExpiry(String orchardId, String inviteId, int expiresIn) async {
    final body = await _send(
      (h) => _client.patch(Uri.parse('$_base/orchards/$orchardId/join-codes/$inviteId'),
          headers: h, body: jsonEncode({'expires_in': expiresIn})),
      json: true,
    );
    final expires = body['expires_at'] is String ? DateTime.tryParse(body['expires_at'] as String) : null;
    if (expires == null) throw const FormatException('No expiry');
    return expires;
  }

  @override
  Future<InviteCodeOffer> inviteCodeOffer(String lookupId) async {
    final raw = await _send(
      (h) => _client.post(Uri.parse('$_base/invites/join-code'), headers: h, body: jsonEncode({'lookup_id': lookupId})),
      json: true,
    );
    final invite = _myInvite(raw);
    final maker = raw['maker'];
    final tag = raw['owner_tag'];
    final sealed = raw['offer_sealed'];
    if (invite == null || maker is! Map<String, dynamic> || maker['uid'] is! String || maker['keys'] is! Map<String, dynamic> ||
        tag is! String || sealed is! String) {
      throw const FormatException('Not an invite code offer');
    }
    return InviteCodeOffer(
      invite: invite,
      grants: _grants(raw['grants']),
      makerKeys: PublishedAccountKeys.fromJson(maker['uid'] as String, maker['keys'] as Map<String, dynamic>),
      ownerTag: base64Decode(tag),
      offerSealed: base64Decode(sealed),
    );
  }

  @override
  Future<String> acceptInviteCode(String lookupId,
      {required int keyVersion, required Uint8List joinerTag, JoinDevice? device}) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/invites/join-code/accept'),
          headers: h,
          body: jsonEncode({
            'lookup_id': lookupId,
            'key_version': keyVersion,
            'joiner_tag': base64Encode(joinerTag),
            ...?device?.toJson(),
          })),
      json: true,
    );
    final id = body['invite_id'];
    if (id is! String) throw const FormatException('No invitation id');
    return id;
  }

  @override
  Future<List<OrchardInvite>> invites(String orchardId) async {
    final body = await _send(
        (h) => _client.get(Uri.parse('$_base/orchards/$orchardId/invites'), headers: h));
    final list = body['invites'];
    if (list is! List) throw const FormatException('Not a list of invitations');
    return [
      for (final raw in list)
        if (raw is Map<String, dynamic>) ?_invite(raw),
    ];
  }

  static OrchardInvite? _invite(Map<String, dynamic> raw) {
    final id = raw['id'];
    final role = raw['role'];
    final expires = raw['expires_at'];
    final codeRaw = raw['code'];
    InviteCodeInfo? code;
    if (codeRaw is Map<String, dynamic> && codeRaw['maker_uid'] is String && codeRaw['maker_key_version'] is int) {
      Uint8List? bytesOf(Object? v) {
        if (v is! String) return null;
        try {
          return base64Decode(v);
        } on FormatException {
          return null;
        }
      }

      code = InviteCodeInfo(
        makerUid: codeRaw['maker_uid'] as String,
        makerKeyVersion: codeRaw['maker_key_version'] as int,
        sealed: bytesOf(codeRaw['sealed']),
        joinerTag: bytesOf(codeRaw['joiner_tag']),
        usedPlatform: codeRaw['used_platform'] is String ? codeRaw['used_platform'] as String : null,
        usedAt: codeRaw['used_at'] is String ? DateTime.tryParse(codeRaw['used_at'] as String) : null,
        uses: codeRaw['uses'] is int ? codeRaw['uses'] as int : 0,
        usesMax: codeRaw['uses_max'] is int ? codeRaw['uses_max'] as int : 1,
        fromCode: codeRaw['from_code'] is String ? codeRaw['from_code'] as String : null,
      );
    }
    final accepted = raw['accepted'];
    // An invite code's has no address of its own: whoever used it.
    final email = code != null
        ? (accepted is Map<String, dynamic> && accepted['email'] is String ? accepted['email'] as String : '')
        : raw['email'];
    if (id is! String || email is! String || role is! String || expires is! String) return null;
    final expiresAt = DateTime.tryParse(expires);
    if (expiresAt == null) return null;
    String? uid;
    PublishedAccountKeys? keys;
    var rulesUnmet = const <String>[];
    String? provider;
    if (accepted is Map<String, dynamic> && accepted['uid'] is String) {
      uid = accepted['uid'] as String;
      rulesUnmet = _list(accepted['rules_unmet']);
      provider = accepted['provider'] is String ? accepted['provider'] as String : null;
      final k = accepted['keys'];
      if (k is Map<String, dynamic>) {
        try {
          keys = PublishedAccountKeys.fromJson(uid, k);
        } on FormatException {
          keys = null;
        }
      }
    }
    return OrchardInvite(
      id: id,
      email: email,
      role: role,
      grants: _grants(raw['grants']),
      endsAt: raw['ends_at'] is int ? raw['ends_at'] as int : null,
      expiresAt: expiresAt,
      expired: raw['expired'] == true,
      invitedBy: raw['invited_by'] is String ? raw['invited_by'] as String : null,
      acceptedUid: uid,
      acceptedKeys: keys,
      acceptedRulesUnmet: rulesUnmet,
      acceptedProvider: provider,
      code: code,
      acceptedDevice: uid == null ? null : JoinDevice.fromJson(raw['accepted_device']),
    );
  }

  @override
  Future<void> withdrawInvite(String orchardId, String inviteId) => _send((h) =>
      _client.delete(Uri.parse('$_base/orchards/$orchardId/invites/$inviteId'), headers: h));

  @override
  Future<AccessRequest> requestAccess(String orchardId,
      {String? crateId, required CrateLevel level, required int seconds, Uint8List? noteEnc, int? noteGeneration}) async {
    final body = await _send(
      (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/access-requests'),
          headers: h,
          body: jsonEncode({
            'crate_id': ?crateId,
            'level': level.name,
            'seconds': seconds,
            if (noteEnc != null) 'note_enc': base64Encode(noteEnc),
            'note_gen': ?noteGeneration,
          })),
      json: true,
    );
    return _accessRequest(body) ?? (throw const FormatException('Not a request for access'));
  }

  @override
  Future<AccessRequests> accessRequests(String orchardId) async {
    final body = await _send(
        (h) => _client.get(Uri.parse('$_base/orchards/$orchardId/access-requests'), headers: h));
    final mine = body['mine'];
    final waiting = body['waiting'];
    if (mine is! List || waiting is! List) throw const FormatException('Not a list of requests for access');
    // One this version cannot read is left out: it is someone else's to
    // answer, or this account's to ask again.
    return (
      mine: [
        for (final raw in mine)
          if (raw is Map<String, dynamic>) ?_accessRequest(raw),
      ],
      waiting: [
        for (final raw in waiting)
          if (raw is Map<String, dynamic> && raw['uid'] is String) ?_accessRequest(raw),
      ],
    );
  }

  static AccessRequest? _accessRequest(Map<String, dynamic> raw) {
    final id = raw['id'];
    final crateId = raw['crate_id'];
    final level = CrateLevel.values.where((l) => l != CrateLevel.manage && l.name == raw['level']).firstOrNull;
    final seconds = raw['seconds'];
    final expiresAt = raw['expires_at'];
    final note = raw['note_enc'];
    final noteGeneration = raw['note_gen'];
    final uid = raw['uid'];
    if (id is! String || (crateId != null && crateId is! String) || level == null || seconds is! int ||
        seconds <= 0 || expiresAt is! int || (uid != null && uid is! String)) {
      return null;
    }
    Uint8List? noteEnc;
    if (note is String && noteGeneration is int) {
      try {
        noteEnc = base64Decode(note);
      } on FormatException {
        return null;
      }
    } else if (note != null || noteGeneration != null) {
      return null;
    }
    return AccessRequest(
      id: id,
      crateId: crateId as String?,
      level: level,
      seconds: seconds,
      noteEnc: noteEnc,
      noteGeneration: noteEnc == null ? null : noteGeneration as int,
      expiresAt: expiresAt,
      uid: uid as String?,
    );
  }

  @override
  Future<void> deleteAccessRequest(String orchardId, String requestId) => _send(
      (h) => _client.delete(Uri.parse('$_base/orchards/$orchardId/access-requests/$requestId'), headers: h),
      ok: const {204});

  @override
  Future<String?> currentSession() async {
    try {
      final id = (await _send((h) => _client.get(Uri.parse('$_base/sessions/current'), headers: h)))['id'];
      return id is String ? id : null;
    } on OrchardServerException catch (e) {
      if (e.status == 404 && e.code == 'no-session') return null;
      rethrow;
    }
  }

  @override
  Future<bool> nameDevice({required Uint8List deviceKey, required Uint8List signature}) async {
    try {
      await _send(
        (h) => _client.put(Uri.parse('$_base/sessions/current/device'),
            headers: h, body: jsonEncode({'key': deviceKeyText(deviceKey), 'sig': base64Encode(signature)})),
        json: true,
      );
      return true;
    } on OrchardServerException catch (e) {
      if ((e.status == 409 && e.code == 'not-needed') || (e.status == 404 && e.code == 'no-session')) return false;
      rethrow;
    }
  }

  @override
  Future<DeviceTrustRequests> deviceRequests(String orchardId) async {
    final body =
        await _send((h) => _client.get(Uri.parse('$_base/orchards/$orchardId/device-requests'), headers: h));
    final mine = body['mine'];
    final waiting = body['waiting'];
    if (mine is! List || waiting is! List) throw const FormatException('Not a list of device requests');
    // One this version cannot read is left out: it lapses by itself.
    return (
      mine: [for (final raw in mine) ?_deviceRequest(raw, mine: true)],
      waiting: [for (final raw in waiting) ?_deviceRequest(raw, mine: false)],
    );
  }

  /// A device request as the server lists it; null when malformed. One that
  /// waits for an answer names who asks and what their device committed to.
  static DeviceTrustRequest? _deviceRequest(Object? raw, {required bool mine}) {
    if (raw is! Map<String, dynamic>) return null;
    final id = raw['id'];
    final stage = raw['stage'];
    final expiresAt = raw['expires_at'];
    final uid = raw['uid'];
    if (id is! String || expiresAt is! int || !const {'created', 'responded', 'revealed'}.contains(stage)) return null;
    Uint8List? bytes32(Object? text) {
      if (text is! String) return null;
      try {
        final b = base64Decode(text);
        return b.length == 32 ? b : null;
      } on FormatException {
        return null;
      }
    }

    final commitment = bytes32(raw['commitment']);
    final responderNonce = bytes32(raw['responder_nonce']);
    final device = deviceKeyBytes(raw['device']);
    final nonce = bytes32(raw['nonce']);
    if (!mine && (uid is! String || commitment == null)) return null;
    if (stage != 'created' && responderNonce == null) return null;
    if (!mine && stage == 'revealed' && (device == null || nonce == null)) return null;
    return DeviceTrustRequest(
      id: id,
      stage: stage as String,
      expiresAt: expiresAt,
      uid: mine ? null : uid as String,
      commitment: commitment,
      responderNonce: responderNonce,
      sameAccount: raw['same_account'] == true,
      deviceKey: device,
      nonce: nonce,
    );
  }

  @override
  Future<String> askDeviceTrust(String orchardId, Uint8List commitment) async {
    final id = (await _send(
      (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/device-requests'),
          headers: h, body: jsonEncode({'commitment': base64Encode(commitment)})),
      json: true,
    ))['id'];
    if (id is! String) throw const FormatException('Not a device request');
    return id;
  }

  @override
  Future<void> answerDeviceTrust(String orchardId, String requestId, Uint8List nonce) => _send(
        (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/device-requests/$requestId/respond'),
            headers: h, body: jsonEncode({'nonce': base64Encode(nonce)})),
        json: true,
      );

  @override
  Future<void> showDeviceTrust(String orchardId, String requestId,
          {required Uint8List deviceKey, required Uint8List nonce}) =>
      _send(
        (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/device-requests/$requestId/reveal'),
            headers: h, body: jsonEncode({'device': deviceKeyText(deviceKey), 'nonce': base64Encode(nonce)})),
        json: true,
      );

  @override
  Future<void> dropDeviceTrust(String orchardId, String requestId) => _send(
      (h) => _client.delete(Uri.parse('$_base/orchards/$orchardId/device-requests/$requestId'), headers: h),
      ok: const {204});

  @override
  Future<void> confirmInvite(String orchardId, String inviteId,
          {required RecordEntry entry, required List<GrantCopy> copies, RecordEntry? device}) =>
      _send(
        (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/invites/$inviteId/confirm'),
            headers: h,
            body: jsonEncode({
              'record': [entry.toJson(), ?device?.toJson()],
              'copies': [for (final c in copies) c.toJson()],
            })),
        json: true,
      );

  @override
  Future<List<MyInvite>> myInvites() async {
    final body = await _send((h) => _client.get(Uri.parse('$_base/invites'), headers: h));
    final list = body['invites'];
    if (list is! List) throw const FormatException('Not a list of invitations');
    return [
      for (final raw in list)
        if (raw is Map<String, dynamic>) ?_myInvite(raw),
    ];
  }

  /// An invitation as the invited person sees it, or null where [raw] is
  /// not one.
  static MyInvite? _myInvite(Map<String, dynamic> raw) {
    if (raw['id'] is! String ||
        raw['orchard_id'] is! String ||
        raw['role'] is! String ||
        raw['crates'] is! int ||
        raw['expires_at'] is! String ||
        DateTime.tryParse(raw['expires_at'] as String) == null) {
      return null;
    }
    return MyInvite(
      id: raw['id'] as String,
      orchardId: raw['orchard_id'] as String,
      role: raw['role'] as String,
      crates: raw['crates'] as int,
      expiresAt: DateTime.parse(raw['expires_at'] as String),
      accepted: raw['accepted'] == true,
      invitedBy: raw['invited_by'] is String ? raw['invited_by'] as String : null,
      endsAt: raw['ends_at'] is int ? raw['ends_at'] as int : null,
      rulesUnmet: _list(raw['rules_unmet']),
      tracking: RecordTracking.fromBody(raw['tracking']),
      exported: raw['exported'] == true,
      sessionLogs: raw['session_logs'] is int ? raw['session_logs'] as int : 0,
      watched: raw['watched'] is int ? raw['watched'] as int : 0,
      byCode: raw['by_code'] == true,
    );
  }

  @override
  Future<void> acceptInvite(String inviteId, {JoinDevice? device}) => _send(
        (h) => _client.post(Uri.parse('$_base/invites/$inviteId/accept'),
            headers: h, body: jsonEncode({...?device?.toJson()})),
        json: true,
      );

  @override
  Future<TeamRecoveryStatus> teamRecovery(String orchardId) async {
    final body = await _send((h) => _client.get(Uri.parse('$_base/orchards/$orchardId/recovery'), headers: h));
    final on = body['team_recovery'];
    final owners = body['owners'];
    final waiting = body['waiting'];
    if (on is! bool || owners is! int || waiting is! List) {
      throw const FormatException('Not a team recovery status');
    }
    return TeamRecoveryStatus(on: on, owners: owners, waiting: [for (final w in waiting) ?_wait(w)]);
  }

  /// One waiting member as the server lists them; null when malformed.
  static RecoveryWait? _wait(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final uid = raw['uid'];
    final keys = raw['keys'];
    final recordKeyVersion = raw['record_key_version'];
    final approvals = raw['approvals'];
    if (uid is! String || keys is! Map<String, dynamic> || recordKeyVersion is! int) return null;
    try {
      return RecoveryWait(
        uid: uid,
        email: raw['email'] is String ? raw['email'] as String : null,
        keys: PublishedAccountKeys.fromJson(uid, keys),
        recordKeyVersion: recordKeyVersion,
        approvals: [
          if (approvals is List)
            for (final a in approvals)
              if (a is Map<String, dynamic> && a['uid'] is String && a['key_version'] is int)
                RecoveryApproval(
                  uid: a['uid'] as String,
                  keyVersion: a['key_version'] as int,
                  signature: a['approval'] is String ? base64Decode(a['approval'] as String) : null,
                ),
        ],
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> approveRecovery(
    String orchardId, {
    required String subjectUid,
    required int keyVersion,
    required int approverKeyVersion,
    required Uint8List approval,
  }) =>
      _send(
        (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/recovery/approve'),
            headers: h,
            body: jsonEncode({
              'subject_uid': subjectUid,
              'key_version': keyVersion,
              'approver_key_version': approverKeyVersion,
              'approval': base64Encode(approval),
            })),
        json: true,
      );

  @override
  Future<void> withdrawRecoveryApproval(String orchardId, String subjectUid) => _send(
        (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/recovery/withdraw'),
            headers: h, body: jsonEncode({'subject_uid': subjectUid})),
        json: true,
      );

  @override
  Future<void> completeRecovery(String orchardId, RecordEntry entry, {required List<GrantCopy> copies}) => _send(
        (h) => _client.post(Uri.parse('$_base/orchards/$orchardId/recovery'),
            headers: h,
            body: jsonEncode({
              'record': [entry.toJson()],
              'copies': [for (final c in copies) c.toJson()],
            })),
        json: true,
      );

  @override
  Future<void> askCertificate(String crateId, CertRequest request) => _send(
        (h) => _client.post(Uri.parse('$_base/crates/$crateId/certificates'),
            headers: h, body: jsonEncode(request.toJson())),
        json: true,
      );

  @override
  Future<List<CertRequest>> waitingCertificates(String crateId) async {
    final body = await _send((h) => _client.get(Uri.parse('$_base/crates/$crateId/certificates/waiting'), headers: h));
    final list = body['requests'];
    if (list is! List) throw const FormatException('Not a list of certificate requests');
    return [for (final r in list) ?CertRequest.fromJson(r)];
  }

  @override
  Future<void> signCertificate(String crateId, String requestId, Uint8List certificate) => _send(
        (h) => _client.put(Uri.parse('$_base/crates/$crateId/certificates/$requestId'),
            headers: h, body: jsonEncode({'certificate': base64Encode(certificate)})),
        json: true,
      );

  @override
  Future<List<IssuedCertificate>> myCertificates(String crateId) async {
    final body = await _send((h) => _client.get(Uri.parse('$_base/crates/$crateId/certificates/mine'), headers: h));
    final list = body['certificates'];
    if (list is! List) throw const FormatException('Not a list of certificates');
    final out = <IssuedCertificate>[];
    for (final c in list) {
      if (c is! Map<String, dynamic>) continue;
      final id = c['id'], key = c['ssh_public_key'], cert = c['certificate'], until = c['valid_before'];
      if (id is! String || key is! String || cert is! String || until is! int) continue;
      try {
        out.add(IssuedCertificate(
            requestId: id, sshPublicKey: base64Decode(key), certificate: base64Decode(cert), validBefore: until));
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  @override
  Future<void> declineInvite(String inviteId) =>
      _send((h) => _client.post(Uri.parse('$_base/invites/$inviteId/decline'), headers: h));

  /// The most pages of a trash that are read for one list: at 8 MB of
  /// records a page, more than a vault may hold.
  static const _trashPages = 64;

  /// A large trash comes a page at a time (4.0: the server ends a page at 500
  /// items or 8 MB of records, says "more" and where it ended, "next"). Each
  /// page is asked for from where the last one ended, until one says no
  /// more. A server from before answers the whole trash at once and says
  /// neither, which reads as one page. An item is listed once however a
  /// server answers, and a "next" that does not move on ends the reading.
  @override
  Future<List<TrashedItem>> trash(String crateId) async {
    final out = <TrashedItem>[];
    final seen = <String>{};
    String? after;
    for (var page = 0; page < _trashPages; page++) {
      final query = after == null ? '' : '?after=${Uri.encodeQueryComponent(after)}';
      final body = await _send((h) => _client.get(Uri.parse('$_base/crates/$crateId/trash$query'), headers: h));
      final list = body['items'];
      if (list is! List) throw const FormatException('Not a trash');
      for (final raw in list) {
        if (raw is! Map<String, dynamic>) continue;
        final id = raw['item_id'], deletion = raw['deletion'], last = raw['last'], until = raw['kept_until'];
        if (id is! String || deletion is! Map<String, dynamic> || last is! Map<String, dynamic> || until is! String) {
          continue;
        }
        final keptUntil = DateTime.tryParse(until);
        if (keptUntil == null) continue;
        if (!seen.add(id)) continue;
        try {
          out.add(TrashedItem(
              itemId: id, deletion: _remoteItem(id, deletion), last: _remoteItem(id, last), keptUntil: keptUntil));
        } on FormatException {
          continue;
        }
      }
      final next = body['next'];
      if (body['more'] != true || next is! String || next.isEmpty || next == after || list.isEmpty) break;
      after = next;
    }
    return out;
  }

  @override
  Future<HistoryPage> itemHistory(String crateId, {String? itemId, int? before}) async {
    final query = [
      if (itemId != null) 'item=${Uri.encodeQueryComponent(itemId)}',
      if (before != null) 'before=$before',
    ].join('&');
    final body = await _send((h) => _client.get(
        Uri.parse('$_base/crates/$crateId/history${query.isEmpty ? '' : '?$query'}'),
        headers: h));
    final versions = body['versions'], current = body['current'], since = body['since'], more = body['more'];
    final sinceAt = since is String ? DateTime.tryParse(since) : null;
    if (versions is! List || current is! List || sinceAt == null || more is! bool) {
      throw const FormatException('Not a page of history');
    }
    final out = <HistoryVersion>[];
    for (final raw in versions) {
      if (raw is! Map<String, dynamic>) continue;
      final id = raw['id'], item = raw['item_id'], at = raw['replaced_at'];
      final replacedAt = at is String ? DateTime.tryParse(at) : null;
      final record = raw['record'], signature = raw['signature'];
      final generation = raw['key_generation'], deleted = raw['deleted'], revision = raw['revision'];
      if (id is! int || item is! String || replacedAt == null || record is! String || signature is! String ||
          generation is! int || deleted is! bool || (revision != null && revision is! int)) {
        continue;
      }
      try {
        out.add(HistoryVersion(
          id: id,
          itemId: item,
          revision: revision as int?,
          replacedAt: replacedAt,
          item: SealedItem(
            itemId: item,
            keyGeneration: generation,
            deleted: deleted,
            record: base64Decode(record),
            signature: base64Decode(signature),
          ),
        ));
      } on FormatException {
        continue;
      }
    }
    final now = <String, RemoteItem>{};
    for (final raw in current) {
      if (raw is! Map<String, dynamic> || raw['item_id'] is! String) continue;
      try {
        now[raw['item_id'] as String] = _remoteItem(raw['item_id'] as String, raw);
      } on FormatException {
        continue;
      }
    }
    return HistoryPage(versions: out, current: now, since: sinceAt, more: more);
  }

  @override
  Future<void> sendActivity(String orchardId, List<SealedActivity> events) => _send(
        (h) => _client.post(
          Uri.parse('$_base/orchards/$orchardId/activity'),
          headers: h,
          body: jsonEncode({
            'events': [
              for (final e in events) {'key_generation': e.keyGeneration, 'sealed': base64Encode(e.sealed)},
            ],
          }),
        ),
        json: true,
      );

  @override
  Future<void> startSessionLog(String crateId, String logId, {required int keyGeneration, required Uint8List header}) =>
      _send(
        (h) => _client.post(
          Uri.parse('$_base/crates/$crateId/session-logs'),
          headers: h,
          body: jsonEncode({'id': logId, 'key_generation': keyGeneration, 'header': base64Encode(header)}),
        ),
        json: true,
      );

  @override
  Future<void> sendSessionLogChunk(String crateId, String logId,
          {required int seq, required int keyGeneration, required Uint8List sealed, bool last = false}) =>
      _send(
        (h) => _client.post(
          Uri.parse('$_base/crates/$crateId/session-logs/$logId/chunks'),
          headers: h,
          body: jsonEncode({'seq': seq, 'key_generation': keyGeneration, 'sealed': base64Encode(sealed), 'last': last}),
        ),
        json: true,
      );

  @override
  Future<SessionLogPage> sessionLogs(String crateId, {String? before}) async {
    final body = await _send((h) => _client.get(
        Uri.parse('$_base/crates/$crateId/session-logs${before == null ? '' : '?before=$before'}'),
        headers: h));
    final logs = body['logs'], more = body['more'];
    if (logs is! List || more is! bool) throw const FormatException('Not a page of session logs');
    final out = <RemoteSessionLog>[];
    for (final raw in logs) {
      if (raw is! Map<String, dynamic>) continue;
      final id = raw['id'], uid = raw['uid'], generation = raw['key_generation'], header = raw['header'];
      final chunks = raw['chunks'], bytes = raw['bytes'], closed = raw['closed'];
      final started = raw['started_at'] is String ? DateTime.tryParse(raw['started_at'] as String) : null;
      final updated = raw['updated_at'] is String ? DateTime.tryParse(raw['updated_at'] as String) : null;
      if (id is! String || uid is! String || generation is! int || header is! String || chunks is! int ||
          bytes is! int || closed is! bool || started == null || updated == null) {
        continue;
      }
      try {
        out.add(RemoteSessionLog(
          id: id,
          uid: uid,
          keyGeneration: generation,
          header: base64Decode(header),
          chunks: chunks,
          bytes: bytes,
          closed: closed,
          startedAt: started,
          updatedAt: updated,
        ));
      } on FormatException {
        continue;
      }
    }
    return SessionLogPage(logs: out, more: more);
  }

  @override
  Future<SessionLogChunkPage> sessionLogChunks(String crateId, String logId, {int after = 0}) async {
    final body = await _send((h) =>
        _client.get(Uri.parse('$_base/crates/$crateId/session-logs/$logId/chunks?after=$after'), headers: h));
    final chunks = body['chunks'], more = body['more'];
    if (chunks is! List || more is! bool) throw const FormatException('Not a page of chunks');
    final out = <({int seq, int keyGeneration, Uint8List sealed})>[];
    for (final raw in chunks) {
      if (raw is! Map<String, dynamic>) continue;
      final seq = raw['seq'], generation = raw['key_generation'], sealed = raw['sealed'];
      if (seq is! int || generation is! int || sealed is! String) continue;
      try {
        out.add((seq: seq, keyGeneration: generation, sealed: base64Decode(sealed)));
      } on FormatException {
        continue;
      }
    }
    return SessionLogChunkPage(chunks: out, more: more);
  }

  @override
  Future<void> deleteSessionLog(String crateId, String logId) =>
      _send((h) => _client.delete(Uri.parse('$_base/crates/$crateId/session-logs/$logId'), headers: h));

  @override
  Future<ActivityPage> activity(String orchardId, {int? before, int? after}) async {
    final from = after != null ? '?after=$after' : (before == null ? '' : '?before=$before');
    final body = await _send((h) => _client.get(Uri.parse('$_base/orchards/$orchardId/activity$from'), headers: h));
    final events = body['events'], more = body['more'];
    if (events is! List || more is! bool) throw const FormatException('Not a page of activity');
    final out = <ActivityEntry>[];
    for (final raw in events) {
      if (raw is! Map<String, dynamic>) continue;
      final id = raw['id'], uid = raw['uid'], generation = raw['key_generation'], sealed = raw['sealed'];
      final at = raw['at'] is String ? DateTime.tryParse(raw['at'] as String) : null;
      if (id is! int || uid is! String || generation is! int || sealed is! String || at == null) continue;
      try {
        out.add(ActivityEntry(id: id, uid: uid, keyGeneration: generation, sealed: base64Decode(sealed), at: at));
      } on FormatException {
        continue;
      }
    }
    return ActivityPage(events: out, more: more);
  }

  static RemoteCrate _crate(Map<String, dynamic> raw) {
    final id = raw['id'];
    final name = raw['name_enc'];
    final generation = raw['key_generation'];
    final level = raw['level'];
    if (id is! String || name is! String || generation is! int || level is! String) {
      throw const FormatException('Not a Crate');
    }
    return RemoteCrate(
      id: id,
      nameEnc: base64Decode(name),
      keyGeneration: generation,
      level: level,
      keys: _keys(raw['keys']),
      switches: _strings(raw['switches']),
      ownersOnly: raw['owners_only'] == true,
      allow: raw['allow'] is List ? _strings(raw['allow']) : const {CrateSwitches.forward, CrateSwitches.sftp},
      rotationDue: raw['rotation_due'] == true,
    );
  }

  static Set<String> _strings(Object? raw) => {
        if (raw is List)
          for (final s in raw)
            if (s is String) s,
      };

  /// The strings of a JSON list, in order.
  static List<String> _list(Object? raw) => [
        if (raw is List)
          for (final s in raw)
            if (s is String) s,
      ];

  /// Crate id -> switches, as an invitation carries them.
  static Map<String, Set<String>> _grants(Object? raw) => {
        if (raw is Map<String, dynamic>)
          for (final e in raw.entries)
            if (e.value is List) e.key: _strings(e.value),
      };

  static List<SealedSpaceKey> _keys(Object? raw) => [
        if (raw is List)
          for (final k in raw)
            if (k is Map<String, dynamic> &&
                k['generation'] is int &&
                k['sealed'] is String)
              SealedSpaceKey(
                k['generation'] as int,
                base64Decode(k['sealed'] as String),
                recipientKeyVersion: k['recipient_key_version'] is int
                    ? k['recipient_key_version'] as int
                    : null,
                sealedBy: k['sealed_by'] is String ? k['sealed_by'] as String : null,
                sealerKeyVersion:
                    k['sealer_key_version'] is int ? k['sealer_key_version'] as int : null,
                signature:
                    k['signature'] is String ? base64Decode(k['signature'] as String) : null,
              ),
      ];

  static RemoteItem _remoteItem(String itemId, Map<String, dynamic> raw) {
    final revision = raw['revision'];
    final generation = raw['key_generation'];
    final deleted = raw['deleted'];
    final record = raw['record'];
    final signature = raw['signature'];
    if (revision is! int || generation is! int || deleted is! bool) {
      throw const FormatException('Not an item');
    }
    return RemoteItem(
      revision: revision,
      item: record is String && signature is String
          ? SealedItem(
              itemId: itemId,
              keyGeneration: generation,
              deleted: deleted,
              record: base64Decode(record),
              signature: base64Decode(signature),
            )
          : null,
    );
  }

  static Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }
}

/// A member's picture as the server lists it: at a host it may come from
/// ([isKnownPictureAddress], for a server that does not hold to the list yet), or
/// null.
String? _httpsPicture(Object? raw) {
  if (raw is! String || raw.length > 2048) return null;
  return isKnownPictureAddress(raw) ? raw : null;
}
