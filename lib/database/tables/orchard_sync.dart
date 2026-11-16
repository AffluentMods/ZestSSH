import 'package:drift/drift.dart';

// Orchard bookkeeping (3.0). These tables exist in every database so
// there is one schema, but only an Orchard's own database ever fills them:
// your Tree syncs as one encrypted blob and never touches them.

/// Which Crate each item of this Orchard belongs in, and the server copy this
/// device's version is based on. [kind] and [itemKey] name the local rows
/// (the row's id, or a snippet category's name). An item's id on the server
/// is derived from them and its Crate, so every device names it the same way.
@DataClassName('CrateItemMetaRow')
class CrateItemsMeta extends Table {
  TextColumn get kind => text()();

  TextColumn get itemKey => text()();

  /// The Crate the item belongs in.
  TextColumn get crateId => text().withLength(min: 36, max: 36)();

  /// The revision of the item's copy in that Crate this version is based on.
  /// Null while the Crate has no copy this device knows of.
  IntColumn get serverRevision => integer().nullable()();

  /// Epoch milliseconds of this version's edit: the newer edit wins a
  /// conflict.
  IntColumn get editedAt => integer().nullable()();

  /// What the last version received carried that this app version does not
  /// know (JSON): record fields, whole tables, and columns of known tables
  /// with each row's key. Sent back with the next version this device
  /// writes, so an older app never erases what a newer one added (see
  /// ItemExtras, which also takes them in after an update).
  TextColumn get extra => text().nullable()();

  /// The account that wrote the version this device holds: after a key
  /// replacement an account signs again only what it wrote last. Null while
  /// not known (a version kept before this was).
  TextColumn get author => text().nullable()();

  /// Whether the Crate's copy [serverRevision] names is a deletion:
  /// the item is in the Crate's trash, and bringing it back is adding it,
  /// on this device (its write guard and what it sends) as on the server.
  BoolColumn get serverDeleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {kind, itemKey};
}

/// Copies of an item left in a Crate it no longer belongs in: after a move,
/// or when a newer copy elsewhere won. The next push replaces each with a
/// deletion that names the item's Crate now.
@DataClassName('CrateLeftoverRow')
class CrateLeftovers extends Table {
  TextColumn get kind => text()();

  TextColumn get itemKey => text()();

  TextColumn get crateId => text().withLength(min: 36, max: 36)();

  /// The revision of the copy there.
  IntColumn get revision => integer()();

  /// When the item left, in epoch milliseconds: the deletion's edit time.
  IntColumn get editedAt => integer()();

  @override
  Set<Column> get primaryKey => {kind, itemKey, crateId};
}

/// Local changes waiting to reach the server: one row per item, however often
/// it changed. Filled by triggers, so no write path can forget it.
@DataClassName('CrateOutboxRow')
class CrateOutbox extends Table {
  TextColumn get kind => text()();

  TextColumn get itemKey => text()();

  /// A number that rises with every change ([OrchardSyncControl.changeSeq]):
  /// a push clears the row only if nothing changed since it read it.
  IntColumn get changeSeq => integer()();

  /// Epoch milliseconds of the latest change, by this device's clock.
  IntColumn get editedAt => integer()();

  @override
  Set<Column> get primaryKey => {kind, itemKey};
}

/// This Orchard as this device knows it (one row, id 1): what the switcher
/// shows when offline, and where new items go.
@DataClassName('OrchardInfoRow')
class OrchardInfo extends Table {
  IntColumn get id => integer()();

  TextColumn get orchardId => text().withLength(min: 36, max: 36)();

  /// The Orchard's name, opened with its key. Null until it could be opened.
  TextColumn get name => text().nullable()();

  /// 'owner', 'admin' or the id of a role the owners made (the record).
  TextColumn get role => text()();

  IntColumn get keyGeneration => integer()();

  /// The Crate new items go into on this device.
  TextColumn get defaultCrateId =>
      text().withLength(min: 36, max: 36).nullable()();

  /// The server's tag for this Orchard's members when this device last read
  /// them: the list is read again only when it moves.
  TextColumn get membersTag => text().nullable()();

  /// What this account may do in the Orchard itself, from the record: a
  /// JSON list of change_roles, create_crates, invite and remove.
  TextColumn get can => text().withDefault(const Constant('[]'))();

  /// 'active', 'suspended' (by someone above them), 'ended' (their access
  /// had an end date that passed) or 'rules' (they fall short of a rule the
  /// server checks). Only an active member syncs.
  TextColumn get status => text().withDefault(const Constant('active'))();

  /// Someone lost access, so the Orchard's key waits to be replaced.
  BoolColumn get rotationDue => boolean().withDefault(const Constant(false))();

  /// Why this device stopped trusting what the server says of the Orchard's
  /// record (a record that does not follow the one here, or breaks the
  /// rules); null while all is well. Nothing syncs while it is set.
  TextColumn get recordProblem => text().nullable()();

  /// The Orchard's rules from its record, as RecordRules.toBody JSON;
  /// null while none are known.
  TextColumn get rules => text().nullable()();

  /// While [status] is 'rules': the rules the server says this account
  /// falls short of, and the domains the address rule allows (JSON
  /// {"unmet": [...], "email_domains": [...]}); null otherwise.
  TextColumn get held => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// The Orchard's record as this device holds it (3.0; the chain in
/// lib/features/orchards/record/orchard_record.dart): every entry, checked
/// when it arrived, in order. Who is in the Orchard, their roles and what
/// each may do in each Crate follow from it.
@DataClassName('OrchardRecordRow')
class OrchardRecordEntries extends Table {
  IntColumn get seq => integer()();

  /// The hash of the entry before; empty for the first.
  BlobColumn get prev => blob()();

  TextColumn get type => text()();

  /// The body exactly as signed.
  TextColumn get body => text()();

  TextColumn get byUid => text()();

  IntColumn get byKeyVersion => integer()();

  BlobColumn get signature => blob()();

  /// This entry's hash: what the next names as its prev, and what an item
  /// written after it names as its anchor.
  BlobColumn get hash => blob()();

  /// When this device first saw the entry, in seconds since the epoch (3.0):
  /// entries carry no time, so the Trust page shows this
  /// instead. Kept here only, never sent. Null for entries kept before it
  /// was noted.
  IntColumn get firstSeen => integer().nullable()();

  @override
  Set<Column> get primaryKey => {seq};
}

/// What to change after someone lost access (3.0; the Overview's
/// "Change these next"): each key they could use, ranked,
/// until someone marks it changed. Kept on the device that took their
/// access away.
@DataClassName('ChangeNextRow')
class ChangeNext extends Table {
  /// Who lost access, and the record entry that took it.
  TextColumn get subjectUid => text()();
  IntColumn get entrySeq => integer()();

  /// The key (a saved login) and what it was called then.
  TextColumn get keyId => text()();
  TextColumn get label => text()();
  TextColumn get crateId => text()();

  /// They could see or copy it; otherwise they could only connect with it.
  BoolColumn get couldReveal => boolean()();

  /// Its place in the list, first to change first.
  IntColumn get rank => integer()();

  /// When someone marked it changed, in seconds since the epoch; null while
  /// it waits.
  IntColumn get doneAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {subjectUid, entrySeq, keyId};
}

/// The members of this Orchard and the keys this device trusts for each
/// (3.0; lib/features/orchards/members/member_trust.dart). Pinned
/// the first time a member is seen; a change of keys is followed only
/// through endorsements, and anything else waits in [pendingKeys] (a hard
/// stop) until someone compares the new fingerprint and accepts it.
@DataClassName('MemberKeyRow')
class MemberKeys extends Table {
  TextColumn get uid => text()();

  TextColumn get email => text().nullable()();

  /// 'owner', 'admin' or the id of a role the owners made.
  TextColumn get role => text()();

  /// 'active', 'suspended' or 'removed', from the record. Members who left
  /// stay, with the keys pinned for them, so what they signed while they
  /// were in still checks out; they are not shown.
  TextColumn get status => text().withDefault(const Constant('active'))();

  /// When their access ends, in seconds since the epoch; null for never.
  IntColumn get endsAt => integer().nullable()();

  /// The pinned keys; null for a member with no keys yet.
  IntColumn get keyVersion => integer().nullable()();
  BlobColumn get signingKey => blob().nullable()();
  BlobColumn get encryptionKey => blob().nullable()();

  /// This device's person compared the pinned keys' fingerprint.
  BoolColumn get verifiedByMe => boolean().withDefault(const Constant(false))();

  /// Members whose checked statements cover the pinned keys (JSON list).
  TextColumn get verifiedBy => text().withDefault(const Constant('[]'))();

  /// Keys the server shows that this device does not follow (published
  /// JSON), or null.
  TextColumn get pendingKeys => text().nullable()();

  /// The server says the account was deleted since the record added it:
  /// shown as such, sealed to no more, and offered for removal.
  BoolColumn get accountDeleted => boolean().withDefault(const Constant(false))();

  /// This device's person compared an earlier version of the member's keys,
  /// the member replaced them since (each version vouched for by the one
  /// before), and nobody here compared the new ones (3.0): shown in
  /// amber until someone compares again.
  BoolColumn get replacedSinceCompared => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {uid};
}

/// The Crates of this Orchard this account can open, and how far this device
/// has read each.
@DataClassName('OrchardCrateRow')
class OrchardCrates extends Table {
  TextColumn get crateId => text().withLength(min: 36, max: 36)();

  /// The Crate's name, opened with its key. Null until it could be opened.
  TextColumn get name => text().nullable()();

  /// 'connect', 'use', 'edit' or 'manage': the nearest level to [switches].
  TextColumn get level => text()();

  /// What this account may do in the Crate, from the record: a JSON
  /// list of connect, reveal, add, edit, delete, manage, sftp, forward and
  /// agent.
  TextColumn get switches => text().withDefault(const Constant('[]'))();

  /// Only the Orchard's owners open it.
  BoolColumn get ownersOnly => boolean().withDefault(const Constant(false))();

  /// Which of sftp, forward and agent the Crate allows at all (JSON list).
  TextColumn get allow => text().withDefault(const Constant('["forward","sftp"]'))();

  /// Someone lost access, so the Crate's key waits to be replaced.
  BoolColumn get rotationDue => boolean().withDefault(const Constant(false))();

  /// Showing or copying a password, passphrase or private key from it asks
  /// for the device PIN or a fingerprint first.
  BoolColumn get confirmReveal => boolean().withDefault(const Constant(false))();

  IntColumn get keyGeneration => integer()();

  /// The last revision read from the server.
  IntColumn get lastRevision => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {crateId};
}

/// Opened keys of this Orchard: the Orchard key and each Crate's key, one row
/// per generation. They live inside the Orchard's own encrypted database, so
/// deleting that file deletes them.
@DataClassName('SpaceKeyRow')
class SpaceKeys extends Table {
  /// 'orchard' or 'crate'.
  TextColumn get scope => text()();

  TextColumn get scopeId => text().withLength(min: 36, max: 36)();

  IntColumn get generation => integer()();

  BlobColumn get secret => blob()();

  @override
  Set<Column> get primaryKey => {scope, scopeId, generation};
}

/// The secrets of an Orchard's keys (private key, password, passphrase and
/// certificate). Kept inside the Orchard's database rather than the OS
/// secure storage, so they go when the Orchard goes, and the Tree's clean-up
/// of unknown secrets can never mistake them for leftovers.
@DataClassName('OrchardSecretRow')
class OrchardSecrets extends Table {
  TextColumn get identityId => text()();

  TextColumn get privateKey => text().nullable()();

  TextColumn get password => text().nullable()();

  TextColumn get passphrase => text().nullable()();

  /// An OpenSSH user certificate for the key, base64.
  TextColumn get certificate => text().nullable()();

  @override
  Set<Column> get primaryKey => {identityId};
}

/// One row (id 1). [applying] is 1 while the sync engine writes changes that
/// came from the server, so the outbox triggers leave them out; it is set and
/// cleared inside that transaction and reset whenever the database opens.
/// [changeSeq] rises with every recorded change.
@DataClassName('OrchardSyncControlRow')
class OrchardSyncControl extends Table {
  IntColumn get id => integer()();

  IntColumn get applying => integer().withDefault(const Constant(0))();

  IntColumn get changeSeq => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// A host key the team pinned (3.0): an Orchard item ('hostkey')
/// kept in a Crate, so each member's device trusts exactly these keys at
/// that endpoint when it connects to the Crate's hosts, and nothing else.
/// Only someone who may edit the Crate writes one. The endpoint is the host
/// (as known hosts write it), its port and the jump route it is reached
/// through.
@DataClassName('TeamHostKeyRow')
class TeamHostKeys extends Table {
  /// "host|port|route|crate": one pin per endpoint and route in each Crate,
  /// which counts only for the hosts of that Crate ("host|port|route" for
  /// one made before pins carried their Crate).
  TextColumn get id => text()();

  TextColumn get host => text()();

  IntColumn get port => integer()();

  /// The jump route (known_hosts.via_scope); '' when reached directly.
  TextColumn get viaScope => text().withDefault(const Constant(''))();

  /// The keys trusted there: a JSON list of "type base64" lines.
  TextColumn get hostKeys => text()();

  @override
  Set<Column> get primaryKey => {id};
}
