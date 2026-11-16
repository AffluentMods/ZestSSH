/// The Orchard's record (3.0): the roles, access and changes of an
/// Orchard as an append-only chain of
/// entries, each signed by the member who made the change and naming the
/// hash of the entry before it. Every member's app works out from the chain
/// alone who is in the Orchard, their roles and ranks, and what each may do
/// in each Crate, so a server that is not playing by the rules can neither
/// add a member, nor promote anyone, nor pass off a change by someone whose
/// role does not allow it.
///
/// The server applies the same rules (ZestSSH Cloud's
/// src/lib/orchard_record.js); a shared test vector holds the bytes
/// together. Pure Dart.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show canonicalJson;
import 'package:zestssh/features/orchards/members/member_trust.dart' show verifyMemberVerification;
import 'package:zestssh/features/orchards/members/team_recovery.dart' show verifyTeamRecovery;
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/utils/type_name.dart';

const String kRecordLabel = 'zestssh.orchard-record.v1';

/// The longest entry body, as signed.
const int kMaxRecordBody = 128 * 1024;

final Ed25519 _ed25519 = Ed25519();

// ── Switches, levels and what roles can do ──────────────────────────────

/// What someone may do in a Crate. Each access level is a
/// preset of these.
abstract final class CrateSwitches {
  static const connect = 'connect';
  static const reveal = 'reveal';
  static const add = 'add';
  static const edit = 'edit';
  static const delete = 'delete';
  static const manage = 'manage';
  static const sftp = 'sftp';
  static const forward = 'forward';
  static const agent = 'agent';

  static const all = {connect, reveal, add, edit, delete, manage, sftp, forward, agent};

  /// What a Crate's own settings can switch off for everyone in it.
  static const capped = {sftp, forward, agent};

  /// What a certificate from a Crate's authority rests on: the Crate
  /// being theirs to connect with, and the forwarding it permits.
  static const inCertificate = {connect, forward, agent};
}

/// The four access levels, least first.
enum CrateLevel { connect, use, edit, manage }

/// The switches [level] stands for. Agent forwarding is never in a preset.
Set<String> levelSwitches(CrateLevel level) {
  const c = CrateSwitches.connect, s = CrateSwitches.sftp, f = CrateSwitches.forward;
  return switch (level) {
    CrateLevel.connect => {c, s, f},
    CrateLevel.use => {c, s, f, CrateSwitches.reveal},
    CrateLevel.edit => {c, s, f, CrateSwitches.reveal, CrateSwitches.add, CrateSwitches.edit, CrateSwitches.delete},
    CrateLevel.manage => {
        c, s, f, CrateSwitches.reveal, CrateSwitches.add, CrateSwitches.edit, CrateSwitches.delete,
        CrateSwitches.manage,
      },
  };
}

/// The highest level whose switches [switches] all include, or null when
/// they do not even include Connect.
CrateLevel? levelOf(Set<String> switches) {
  CrateLevel? best;
  for (final level in CrateLevel.values) {
    final core = levelSwitches(level).difference(CrateSwitches.capped);
    if (switches.containsAll(core)) best = level;
  }
  return best;
}

/// What a role below Admin may do in the Orchard.
abstract final class RoleCan {
  static const invite = 'invite';
  static const remove = 'remove';
  static const changeRoles = 'change_roles';
  static const createCrates = 'create_crates';

  static const all = {invite, remove, changeRoles, createCrates};
}

/// The two roles every Orchard has; any other role is one its owners made.
abstract final class FixedRoles {
  static const owner = 'owner';
  static const admin = 'admin';
}

/// Ranks: owners above admins above every role the owners made (1 to
/// [maxCustomRank], higher is more senior).
const int kOwnerRank = 3000000;
const int kAdminRank = 2000000;
const int maxCustomRank = 1999999;

/// Whether going from the role [from] to [to] makes someone an owner or
/// admin who was not one. An owner stepping down to admin is not.
bool makesOwnerOrAdmin(String from, String to) =>
    (to == FixedRoles.owner && from != FixedRoles.owner) ||
    (to == FixedRoles.admin && from != FixedRoles.owner && from != FixedRoles.admin);

/// The newest record format this app reads. Format 2 (3.0): an
/// entry that makes someone an owner or admin carries the author's signed
/// statement that they compared that person's keys. An Orchard's format is
/// set by its create entry; Orchards made before format 2 stay at 1.
const int kRecordFormat = 2;

abstract final class RecordTypes {
  static const create = 'create';
  static const crateAdd = 'crate.add';
  static const crateSet = 'crate.set';
  static const roleSet = 'role.set';
  static const roleDrop = 'role.drop';
  static const memberAdd = 'member.add';
  static const memberSet = 'member.set';
  static const memberKeys = 'member.keys';
  static const memberSuspend = 'member.suspend';
  static const memberResume = 'member.resume';
  static const memberRemove = 'member.remove';

  /// A new generation of the Orchard's key or a Crate's, with its
  /// commitment.
  static const keyRotate = 'key.rotate';

  /// The Orchard's rules, set by an owner.
  static const rulesSet = 'rules.set';

  /// Team recovery turned on or off by an owner.
  static const recoverySet = 'recovery.set';

  /// A member's access given back under new keys by two owners.
  static const memberRecover = 'member.recover';

  /// A Crate's certificate authority set, rotated or turned off by an owner.
  ///
  static const caSet = 'ca.set';

  /// What the team records about its members, set by an owner.
  static const trackingSet = 'tracking.set';

  /// A Crate given to a member until a set time, or that taken back before
  /// its time (access on request).
  static const accessGrant = 'access.grant';

  /// A member's device approved, or its approval taken back (trusted
  /// devices).
  static const deviceTrust = 'device.trust';
  static const deviceRevoke = 'device.revoke';

  /// The team's events sent on to a system of its own, turned on (with the
  /// key they are signed with) or off by an owner (event export).
  static const exportSet = 'export.set';

  /// A session to a watched Crate's host that went on with nobody watching,
  /// because ZestSSH Cloud could not be reached: reported by whoever
  /// connected (3.0, the outage work).
  static const sessionUnwatched = 'session.unwatched';

  /// The Admin role changed like any other, by an owner: the Crates it opens
  /// and what it may do in the team, or back to all of it (3.3.0: it is
  /// a role like any other).
  static const adminSet = 'admin.set';

  /// What one member may do in one Crate, held below what their role and
  /// extra access give, down to nothing (vault access per member).
  ///
  static const memberLimit = 'member.limit';

  /// The team deleted by an owner: its members held back from then on, and
  /// the server purges it seven days on unless an owner undoes it first with
  /// [teamRestore] (deleting a team).
  static const teamDelete = 'team.delete';
  static const teamRestore = 'team.restore';

  static const all = {
    create, crateAdd, crateSet, roleSet, roleDrop, memberAdd, memberSet, memberKeys,
    memberSuspend, memberResume, memberRemove, keyRotate, rulesSet, recoverySet, memberRecover, caSet,
    trackingSet, accessGrant, deviceTrust, deviceRevoke, exportSet, sessionUnwatched, adminSet, memberLimit,
    teamDelete, teamRestore,
  };

  /// The kinds an app from before them cannot read: they wait
  /// for the server's switch, and the first of them in a team is an owner's
  /// (ZestSSH Cloud's src/routes/orchards.js NEW_RECORD_KINDS).
  static const newKinds = {adminSet, memberLimit, teamDelete, teamRestore};
}

/// Trusted devices (3.0). Every device has a signing key of its own
/// that never leaves it; the record lists, for each member, the keys of the
/// devices that were approved. An approval, and taking one back, is made on a
/// device that is approved already: the entry names that device ('via') and
/// carries its signature over what is approved and over the entry the new one
/// follows, so an old approval cannot be used again after the device was
/// removed. This is the label of what the approving device signs.
const String kDeviceEntryLabel = 'zestssh.orchard-device.v1';

/// The most devices one member has approved at a time.
const int kMaxMemberDevices = 20;

/// What the approving device signs under a device.trust or device.revoke
/// ([type]) about the device [device] (its key, 32 bytes) of the member
/// [uid], in an entry that follows [prev].
Uint8List deviceEntryMessage({
  required String orchardId,
  required String type,
  required String uid,
  required List<int> device,
  required List<int> prev,
}) =>
    Uint8List.fromList([
      ..._lp(utf8.encode(kDeviceEntryLabel)),
      ..._lp(utf8.encode(orchardId)),
      ..._lp(utf8.encode(type)),
      ..._lp(utf8.encode(uid)),
      ..._lp(device),
      ..._lp(prev),
    ]);

/// The latest time an access.grant may name: seconds since the epoch that
/// fit 32 bits. (How far ahead of now it may be is the server's to say; the
/// record has no clock.)
const int kMaxAccessUntil = 0xffffffff;

/// The most the sealed part of a session.unwatched takes, in bytes: as
/// base64 it fills the longest text an entry holds.
const int kMaxUnwatchedSealed = 1536;

/// A Crate given to a member until [until] (access on request): what
/// they may do there on top of what they have anyway, and when that ends by
/// itself, in seconds since the epoch.
///
/// It gives access to what the Crate holds and nothing in the record: it
/// never includes [CrateSwitches.manage], and no rule counts it, because an
/// entry carries no time and nobody could tell whether the access still
/// stood when someone signed with it.
class RecordTimedGrant {
  const RecordTimedGrant({required this.switches, required this.until});

  final Set<String> switches;
  final int until;
}

/// Event export (3.0) as the record holds it while it is on: the
/// changes to the record and what members do with the Crates' items
/// (activity) are sent on to a system the owners chose, by one device
/// of the owner who set it up. The record says that it is on, so every
/// member's app can say so, who set it up, and the key each event sent is
/// signed with. Where they go is kept on the sending device alone.
class RecordExport {
  const RecordExport({required this.key, required this.by});

  /// The Ed25519 public key (32 bytes) every event sent is signed with.
  final Uint8List key;

  /// The owner who set it up: it lasts while they are an owner.
  final String by;

  /// [key] in base64, as the entry carries it.
  String get keyText => base64Encode(key);
}

/// What an Orchard records about its members (3.0),
/// set by an owner in a tracking.set entry, all of it at once. Everything is
/// off until an owner turns it on, and every member's app shows what is on
/// and tells its person when that changes. A tracking.set entry carries
/// exactly these four: an app that finds another refuses the entry rather
/// than keep from its person something their team records.
class RecordTracking {
  const RecordTracking({this.history = false, this.activity = false, this.devices = false, this.ips = false});

  /// Nothing recorded: what every Orchard starts with.
  static const none = RecordTracking();

  /// Earlier versions of the Crates' items, with who made each and when,
  /// for owners and those who manage a Crate to look through and put back.
  /// Only versions replaced after it was turned on.
  final bool history;

  /// What members do with the Crates' items (reveal, copy, export,
  /// connect), sent by their devices sealed to the Orchard, for owners.
  final bool activity;

  /// Members' devices, with their system and app versions, for owners.
  final bool devices;

  /// The addresses members sign in from, kept by ZestSSH Cloud for owners.
  final bool ips;

  bool get isNone => !history && !activity && !devices && !ips;

  /// Read from a tracking.set body this device already accepted (or kept);
  /// anything missing or not true reads as off.
  factory RecordTracking.fromBody(Object? json) {
    if (json is! Map) return none;
    return RecordTracking(
      history: json['history'] == true,
      activity: json['activity'] == true,
      devices: json['devices'] == true,
      ips: json['ips'] == true,
    );
  }

  RecordTracking copyWith({bool? history, bool? activity, bool? devices, bool? ips}) => RecordTracking(
        history: history ?? this.history,
        activity: activity ?? this.activity,
        devices: devices ?? this.devices,
        ips: ips ?? this.ips,
      );

  /// Whether this records something [before] did not.
  bool recordsMoreThan(RecordTracking before) =>
      (history && !before.history) || (activity && !before.activity) || (devices && !before.devices) ||
      (ips && !before.ips);

  /// As a tracking.set body carries it.
  Map<String, Object?> toBody() => {'activity': activity, 'devices': devices, 'history': history, 'ips': ips};

  @override
  bool operator ==(Object other) =>
      other is RecordTracking &&
      other.history == history &&
      other.activity == activity &&
      other.devices == devices &&
      other.ips == ips;

  @override
  int get hashCode => Object.hash(history, activity, devices, ips);
}

/// How long a certificate from a Crate's authority lasts, in minutes: an
/// hour, eight hours, a day or a week.
const Set<int> kCaTtlMinutes = {60, 480, 1440, 10080};

/// The most user names one role may sign in as on a Crate's hosts.
const int kMaxCaPrincipals = 16;

/// A user name a certificate lets its holder sign in as: what sshd takes as
/// a principal, and what a Unix account name looks like.
final RegExp kCaPrincipal = RegExp(r'^[a-z_][a-z0-9_.-]{0,31}$');

/// A Crate's certificate authority (3.0): its members connect to
/// the Crate's hosts with short-lived SSH certificates it signs, instead of
/// shared passwords or keys. Owners hold its private key, kept as an item in
/// [keyCrate], a Crate only owners open; the record holds each generation's
/// public key, so every device (and each server's setup) knows which
/// signatures count.
class RecordCa {
  RecordCa({
    required this.on,
    required this.generation,
    required this.publicKeys,
    required this.ttlMinutes,
    required this.principals,
    required this.keyCrate,
  });

  /// Whether owners' devices sign certificates for the Crate now.
  bool on;

  /// The authority's current key: 1 when it is set up, one more with each
  /// new key.
  int generation;

  /// Each generation's Ed25519 public key.
  final Map<int, Uint8List> publicKeys;

  /// How long each certificate lasts ([kCaTtlMinutes]).
  int ttlMinutes;

  /// The user names each role signs in as ('owner', 'admin' or a role the
  /// owners made): a role not named gets no certificate.
  Map<String, List<String>> principals;

  /// The owners-only Crate that keeps the private key.
  String keyCrate;

  Uint8List get publicKey => publicKeys[generation]!;

  RecordCa copy() => RecordCa(
        on: on,
        generation: generation,
        publicKeys: {...publicKeys},
        ttlMinutes: ttlMinutes,
        principals: {for (final e in principals.entries) e.key: [...e.value]},
        keyCrate: keyCrate,
      );
}

/// The Orchard's rules to join and to stay (3.0), set by an owner
/// in a rules.set entry, all of them at once. The server holds members to
/// the ones it can check (a second factor at sign-in, an address domain, a
/// sign-in within [reauthDays] or [reauthHours]); each device holds itself to the rest (app
/// lock and its timeout, no export, the offline limit). Someone who stops
/// meeting a rule keeps what is on their device, but the Orchard stops
/// syncing for them until they do.
class RecordRules {
  const RecordRules({
    this.require2fa = false,
    this.emailDomains = const {},
    this.requireAppLock = false,
    this.maxLockMinutes = 0,
    this.noExport = false,
    this.offlineHours = 0,
    this.reauthDays = 0,
    this.reauthHours = 0,
    this.requireSso = false,
    this.ssoTwoStep = false,
    this.trustedDevices = false,
    this.screensSshOnly = false,
    this.screensLockRedirections = false,
  });

  /// No rules: what every Orchard starts with.
  static const none = RecordRules();

  /// Members sign in with a second factor.
  final bool require2fa;

  /// The address domains members' accounts must be in; empty for any.
  final Set<String> emailDomains;

  /// Members' devices use the app lock, locking within [maxLockMinutes]
  /// when that is not 0.
  final bool requireAppLock;
  final int maxLockMinutes;

  /// Nothing of the Orchard leaves in an export, a share or a QR code,
  /// owners included.
  final bool noExport;

  /// A device that has not reached ZestSSH Cloud for this many hours locks
  /// the Orchard until it does; 0 for no limit.
  final int offlineHours;

  /// Members sign in again at least this often, in days; 0 for never.
  final int reauthDays;

  /// Or in hours, for a window shorter than a day;
  /// 0 for none. Where both are set, the shorter one holds.
  final int reauthHours;

  /// How long a sign-in counts, in seconds: the shorter of [reauthDays] and
  /// [reauthHours] that is set; 0 where neither is.
  int get reauthSeconds => reauthWindow(reauthDays, reauthHours);

  /// The shorter of [days] and [hours] that is set, in seconds; 0 where
  /// neither is.
  static int reauthWindow(int days, int hours) {
    final d = days * 24 * 3600;
    final h = hours * 3600;
    if (d > 0 && h > 0) return d < h ? d : h;
    return d > 0 ? d : h;
  }

  /// Members sign in through the Orchard's company sign-in, not with
  /// a password, Google or Apple. The server checks it.
  final bool requireSso;

  /// A sign-in through the Orchard's company sign-in meets [require2fa]
  /// as an owner's choice, off by default, since the team then trusts
  /// its identity provider for the second step. The server checks it. An owner's
  /// way around a broken company sign-in still takes ZestSSH's own two-step.
  final bool ssoTwoStep;

  /// Members get in only from devices the team approved: the ones the
  /// record lists for them ([OrchardRecord.devicesOf]). The server holds
  /// every device to it, an owner's too, and a Crate's authority signs
  /// certificates only for those devices.
  final bool trustedDevices;

  /// The team's remote screens (VNC and RDP hosts, 4.0) open through an SSH
  /// host only: one with no SSH host to go through does not open, and its
  /// editor offers no direct connection. Each device holds itself to it.
  final bool screensSshOnly;

  /// Nothing of a device is shared with the team's remote screens: no
  /// clipboard either way, whatever a host's own setting says, and nothing
  /// that later sends local things to a server (drives, printers, sound in).
  /// Each device holds itself to it.
  final bool screensLockRedirections;

  bool get isNone =>
      !require2fa && emailDomains.isEmpty && !requireAppLock && maxLockMinutes == 0 && !noExport &&
      offlineHours == 0 && reauthDays == 0 && reauthHours == 0 && !requireSso && !ssoTwoStep && !trustedDevices &&
      !screensSshOnly && !screensLockRedirections;

  RecordRules copyWith({
    bool? require2fa,
    Set<String>? emailDomains,
    bool? requireAppLock,
    int? maxLockMinutes,
    bool? noExport,
    int? offlineHours,
    int? reauthDays,
    int? reauthHours,
    bool? requireSso,
    bool? ssoTwoStep,
    bool? trustedDevices,
    bool? screensSshOnly,
    bool? screensLockRedirections,
  }) =>
      RecordRules(
        require2fa: require2fa ?? this.require2fa,
        emailDomains: emailDomains ?? this.emailDomains,
        requireAppLock: requireAppLock ?? this.requireAppLock,
        maxLockMinutes: maxLockMinutes ?? this.maxLockMinutes,
        noExport: noExport ?? this.noExport,
        offlineHours: offlineHours ?? this.offlineHours,
        reauthDays: reauthDays ?? this.reauthDays,
        reauthHours: reauthHours ?? this.reauthHours,
        requireSso: requireSso ?? this.requireSso,
        ssoTwoStep: ssoTwoStep ?? this.ssoTwoStep,
        trustedDevices: trustedDevices ?? this.trustedDevices,
        screensSshOnly: screensSshOnly ?? this.screensSshOnly,
        screensLockRedirections: screensLockRedirections ?? this.screensLockRedirections,
      );

  /// Read back from [toBody]'s JSON as this device keeps it; anything
  /// missing or of the wrong kind reads as off.
  factory RecordRules.fromStored(Object? json) {
    if (json is! Map) return none;
    int number(String k) => json[k] is int ? json[k] as int : 0;
    bool flag(String k) => json[k] == true;
    final domains = json['email_domains'];
    return RecordRules(
      require2fa: flag('require_2fa'),
      emailDomains: {
        if (domains is List)
          for (final d in domains)
            if (d is String) d,
      },
      requireAppLock: flag('require_app_lock'),
      maxLockMinutes: number('max_lock_minutes'),
      noExport: flag('no_export'),
      offlineHours: number('offline_hours'),
      reauthDays: number('reauth_days'),
      reauthHours: number('reauth_hours'),
      requireSso: flag('require_sso'),
      ssoTwoStep: flag('sso_two_step'),
      trustedDevices: flag('trusted_devices'),
      screensSshOnly: flag('screens_ssh_only'),
      screensLockRedirections: flag('screens_lock_redirections'),
    );
  }

  /// As an owner's rules.set carries them from this version on: [toBody]
  /// with the two rules about remote screens always named, on or off. A
  /// rules.set that does not name them leaves them as they are
  /// ([OrchardRecord], rules.set), so that an owner's app from before them,
  /// saving the team's other rules, does not turn them off without knowing
  /// they exist; turning one off therefore takes saying so.
  Map<String, Object?> toSetBody() => {
        ...toBody(),
        'screens_ssh_only': screensSshOnly,
        'screens_lock_redirections': screensLockRedirections,
      };

  /// As this device keeps them, and as a rules.set body carried them before
  /// the rules about remote screens ([toSetBody] is what is written now).
  Map<String, Object?> toBody() => {
        'email_domains': emailDomains.toList()..sort(),
        'max_lock_minutes': maxLockMinutes,
        'no_export': noExport,
        'offline_hours': offlineHours,
        'reauth_days': reauthDays,
        'require_2fa': require2fa,
        'require_app_lock': requireAppLock,
        // Written only when on: rules from before company sign-in keep
        // the bytes they had, and an app from before it reads them as they
        // were.
        if (requireSso) 'require_sso': true,
        // Likewise.
        if (trustedDevices) 'trusted_devices': true,
        // Likewise (hours).
        if (reauthHours > 0) 'reauth_hours': reauthHours,
        // Likewise.
        if (ssoTwoStep) 'sso_two_step': true,
        // Likewise (remote screens, 4.0).
        if (screensSshOnly) 'screens_ssh_only': true,
        if (screensLockRedirections) 'screens_lock_redirections': true,
      };
}

/// Whether [domain] is an address domain as a rule names it (see [_domain]).
bool isRuleDomain(String domain) => _domain.hasMatch(domain);

/// An address domain as a rule names it: lower case letters, digits and
/// hyphens in dot-separated labels, with at least one dot.
final _domain = RegExp(r'^(?=.{3,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$');

/// At most this many domains in a rule.
const kMaxRuleDomains = 20;

// ── Entries ─────────────────────────────────────────────────────────────

/// The exact bytes an entry's signature covers.
Uint8List recordEntryMessage({
  required String orchardId,
  required int seq,
  required List<int> prev,
  required String type,
  required String bodyJson,
  required String by,
  required int byKeyVersion,
}) =>
    Uint8List.fromList([
      ..._lp(utf8.encode(kRecordLabel)),
      ..._lp(utf8.encode(orchardId)),
      ..._u32(seq),
      ..._lp(prev),
      ..._lp(utf8.encode(type)),
      ..._lp(utf8.encode(bodyJson)),
      ..._lp(utf8.encode(by)),
      ..._u32(byKeyVersion),
    ]);

/// One entry of an Orchard's record.
class RecordEntry {
  RecordEntry({
    required this.seq,
    required this.prev,
    required this.type,
    required this.bodyJson,
    required this.by,
    required this.byKeyVersion,
    required this.signature,
  });

  /// 1 for the first entry, one more for each after it.
  final int seq;

  /// The hash of the entry before; empty for the first.
  final Uint8List prev;
  final String type;

  /// The body exactly as signed: canonical JSON.
  final String bodyJson;

  /// Who made the change, and the version of their keys that signed it.
  final String by;
  final int byKeyVersion;
  final Uint8List signature;

  Map<String, Object?> get body => jsonDecode(bodyJson) as Map<String, Object?>;

  Uint8List signedMessage(String orchardId) => recordEntryMessage(
        orchardId: orchardId,
        seq: seq,
        prev: prev,
        type: type,
        bodyJson: bodyJson,
        by: by,
        byKeyVersion: byKeyVersion,
      );

  /// What the next entry names as its prev.
  Uint8List hash(String orchardId) => Uint8List.fromList(
      sha256.convert([...signedMessage(orchardId), ..._lp(signature)]).bytes);

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'prev': base64Encode(prev),
        'type': type,
        'body': bodyJson,
        'by': by,
        'by_key_version': byKeyVersion,
        'signature': base64Encode(signature),
      };

  /// An entry as the server lists it. Throws [FormatException].
  static RecordEntry fromJson(Map<String, dynamic> j) {
    final seq = j['seq'];
    final prev = j['prev'];
    final type = j['type'];
    final body = j['body'];
    final by = j['by'];
    final version = j['by_key_version'];
    final signature = j['signature'];
    if (seq is! int ||
        prev is! String ||
        type is! String ||
        body is! String ||
        by is! String ||
        version is! int ||
        signature is! String) {
      throw const FormatException('Not a record entry');
    }
    return RecordEntry(
      seq: seq,
      prev: base64Decode(prev),
      type: type,
      bodyJson: body,
      by: by,
      byKeyVersion: version,
      signature: base64Decode(signature),
    );
  }
}

/// [keys] (the account [by]) signing entry [seq] after [prev].
Future<RecordEntry> signRecordEntry(
  AccountKeys keys, {
  required String orchardId,
  required int seq,
  required List<int> prev,
  required String type,
  required Map<String, Object?> body,
  required String by,
}) async {
  final bodyJson = canonicalJson(body);
  final problem = bodyProblem(bodyJson);
  if (problem != null) throw ArgumentError(problem);
  final message = recordEntryMessage(
    orchardId: orchardId,
    seq: seq,
    prev: prev,
    type: type,
    bodyJson: bodyJson,
    by: by,
    byKeyVersion: keys.version,
  );
  return RecordEntry(
    seq: seq,
    prev: Uint8List.fromList(prev),
    type: type,
    bodyJson: bodyJson,
    by: by,
    byKeyVersion: keys.version,
    signature: await keys.sign(message),
  );
}

final _safeString = RegExp(r'^[\x20\x21\x23-\x5b\x5d-\x7e]*$');

/// Why [bodyJson] cannot be a body, or null: it must be a canonical JSON
/// object whose strings are printable ASCII without quotes or backslashes
/// and whose numbers are whole, so the app and the server sign the very
/// same bytes.
String? bodyProblem(String bodyJson) {
  if (bodyJson.length > kMaxRecordBody) return 'body too large';
  final Object? decoded;
  try {
    decoded = jsonDecode(bodyJson);
  } on FormatException {
    return 'body is not JSON';
  }
  if (decoded is! Map) return 'body is not an object';
  if (canonicalJson(decoded) != bodyJson) return 'body is not canonical';
  String? check(Object? v) {
    if (v is String) return _safeString.hasMatch(v) ? null : 'unsafe string';
    if (v is int) return v < 0 || v > 9007199254740991 ? 'number out of range' : null;
    if (v is bool) return null;
    if (v is List) {
      for (final x in v) {
        final p = check(x);
        if (p != null) return p;
      }
      return null;
    }
    if (v is Map) {
      for (final e in v.entries) {
        if (!_safeString.hasMatch(e.key as String)) return 'unsafe key';
        final p = check(e.value);
        if (p != null) return p;
      }
      return null;
    }
    return 'unsupported value';
  }

  return check(decoded);
}

// ── The state a chain describes ─────────────────────────────────────────

/// One version of a member's keys, as the record holds it.
class RecordKeys {
  const RecordKeys({
    required this.version,
    required this.signingKey,
    required this.encryptionKey,
    required this.createdAt,
    required this.selfSignature,
  });

  final int version;
  final Uint8List signingKey;
  final Uint8List encryptionKey;
  final int createdAt;
  final Uint8List selfSignature;

  Uint8List get fingerprint =>
      accountKeysFingerprint(signingKey: signingKey, encryptionKey: encryptionKey);

  PublishedAccountKeys published(String uid) => PublishedAccountKeys(
        uid: uid,
        version: version,
        createdAt: createdAt,
        encryptionKey: encryptionKey,
        signingKey: signingKey,
        signature: selfSignature,
      );
}

enum MemberStatus { active, suspended, removed }

/// The most seconds since the epoch a DateTime can say: the year 275,760.
const int kMaxDateSeconds = 8640000000000;

/// [seconds] since the epoch as a moment, held to what a DateTime can say. A
/// server from before end dates were bounded took any whole number, and the
/// record keeps what it took: one entry must not break every screen that reads
/// it. Whoever shows or writes an end date reads it through this.
DateTime secondsAsDate(int seconds, {bool isUtc = false}) => DateTime.fromMillisecondsSinceEpoch(
      seconds.clamp(-kMaxDateSeconds, kMaxDateSeconds) * 1000,
      isUtc: isUtc,
    );

class RecordMember {
  RecordMember({
    required this.uid,
    required this.role,
    required this.keys,
    required this.since,
    Map<String, Set<String>>? grants,
    Map<String, RecordTimedGrant>? timed,
    Map<String, Set<String>>? limits,
    Set<String>? devices,
    this.endsAt,
    this.endsFromOwner = false,
    this.status = MemberStatus.active,
  })  : grants = grants ?? {},
        timed = timed ?? {},
        limits = limits ?? {},
        devices = devices ?? {};

  final String uid;

  /// 'owner', 'admin' or the id of a role the owners made.
  String role;

  /// Every version of their keys the record holds.
  final Map<int, RecordKeys> keys;

  /// The entry that added them.
  final int since;

  /// Crates given to them on top of their role, with the switches given.
  Map<String, Set<String>> grants;

  /// Crates given to them until a set time, by Crate. One whose time
  /// has passed stays here until it is replaced: only a clock tells.
  final Map<String, RecordTimedGrant> timed;

  /// Their limit in a Crate, by Crate (member.limit): what they may do there
  /// for good is held within it; an empty set is No access. Owners and
  /// admins have none.
  final Map<String, Set<String>> limits;

  /// Their approved devices: each device's key, in base64 as an entry
  /// writes it.
  final Set<String> devices;

  /// When their access ends, in seconds since the epoch; null for never.
  int? endsAt;

  /// Whether an owner signed the entry that gave [endsAt]. Only this device's
  /// reading of who signed what: nothing in the record says so, and nothing is
  /// decided by it but what an owner is asked (an end date lets someone in from
  /// outside the team's domains, whoever gave it).
  bool endsFromOwner;
  MemberStatus status;

  RecordKeys get currentKeys => keys[keys.keys.reduce((a, b) => a > b ? a : b)]!;

  RecordMember copy() => RecordMember(
        uid: uid,
        role: role,
        keys: {...keys},
        since: since,
        grants: {for (final e in grants.entries) e.key: {...e.value}},
        timed: {...timed},
        limits: {for (final e in limits.entries) e.key: {...e.value}},
        devices: {...devices},
        endsAt: endsAt,
        endsFromOwner: endsFromOwner,
        status: status,
      );
}

class RecordRole {
  RecordRole({
    required this.id,
    required this.rank,
    required this.nameEnc,
    required this.nameGeneration,
    required this.can,
    required this.crates,
  });

  final String id;
  int rank;

  /// The role's name, encrypted with the Orchard's key of [nameGeneration].
  String nameEnc;
  int nameGeneration;
  Set<String> can;
  Map<String, Set<String>> crates;

  RecordRole copy() => RecordRole(
        id: id,
        rank: rank,
        nameEnc: nameEnc,
        nameGeneration: nameGeneration,
        can: {...can},
        crates: {for (final e in crates.entries) e.key: {...e.value}},
      );
}

/// The Admin role as an owner set it (admin.set): what it may do in the
/// team ([RoleCan]) and the Crates it opens, as a role.set holds them.
class RecordAdminRole {
  RecordAdminRole({required this.can, required this.crates});

  Set<String> can;
  Map<String, Set<String>> crates;

  RecordAdminRole copy() => RecordAdminRole(
        can: {...can},
        crates: {for (final e in crates.entries) e.key: {...e.value}},
      );
}

class RecordCrate {
  RecordCrate({
    required this.id,
    required this.ownersOnly,
    required this.allow,
    this.generation = 1,
    Map<int, Uint8List>? commits,
    this.confirmReveal = false,
    this.sessionLogs = false,
    this.watched = false,
    this.unwatchedAway = false,
    this.offlineHours = 0,
    this.ca,
  }) : commits = commits ?? {};

  final String id;
  bool ownersOnly;

  /// Which of [CrateSwitches.capped] the Crate allows at all.
  Set<String> allow;

  /// The current generation of the Crate's key: 1 when it is added, one
  /// more with each key.rotate.
  int generation;

  /// The commitment to each generation of the Crate's key, from the entry
  /// that made it ([keyCommitment]).
  final Map<int, Uint8List> commits;

  /// Devices ask for the device PIN or a fingerprint again before showing or
  /// copying a secret from this Crate.
  bool confirmReveal;

  /// Sessions to this Crate's hosts are logged for its owners and those who
  /// manage it: off until an owner turns it on, and every member is
  /// told, before and during each session.
  bool sessionLogs;

  /// Sessions to this Crate's hosts start only once someone who manages it
  /// has joined to watch, and are held while nobody does (session
  /// moderation): off until an owner turns it on, and every member is
  /// told. While it is on the Crate allows the terminal only ([allow] is
  /// empty): nobody can watch a file transfer, a forwarded port or a
  /// forwarded agent. The app keeps to it; the record says who may watch.
  bool watched;

  /// While ZestSSH Cloud cannot be reached nobody can be asked to watch.
  /// An owner may then connect to one of this Crate's hosts after giving a
  /// reason; this says whether everyone else who may connect there may do
  /// the same (3.0, the outage work). Off until an owner turns it on.
  /// Whoever connects so reports it in the record once their device is back
  /// ([RecordTypes.sessionUnwatched]). It matters only while [watched] is
  /// on, and is kept through that being turned off and on. The devices keep
  /// to it; the record says what it is.
  bool unwatchedAway;

  /// How many hours a device may go without reaching ZestSSH Cloud before
  /// this Crate closes on it; 0 for no limit of its own (3.0, the outage
  /// work). The Orchard's own limit
  /// ([RecordRules.offlineHours]) closes all of the Orchard; this closes
  /// one Crate, so that a team can keep what is harmless open on a device
  /// that is away and close what is not. It keeps people out, so it is the
  /// owners' to set, as the Orchard's rules are. The device keeps to it;
  /// the record says what it is.
  int offlineHours;

  /// The Crate's certificate authority, once an owner set one up.
  RecordCa? ca;

  RecordCrate copy() => RecordCrate(
      id: id,
      ownersOnly: ownersOnly,
      allow: {...allow},
      generation: generation,
      commits: {...commits},
      confirmReveal: confirmReveal,
      sessionLogs: sessionLogs,
      watched: watched,
      unwatchedAway: unwatchedAway,
      offlineHours: offlineHours,
      ca: ca?.copy());
}

/// Why an entry was refused: the chain is not trusted from [seq] on.
class RecordRejected implements Exception, HasTypeName {
  const RecordRejected(this.seq, this.reason);

  final int seq;
  final String reason;

  @override
  String toString() => 'Orchard record entry $seq refused: $reason';

  @override
  String get typeName => 'RecordRejected';
}

/// What an Orchard's record says: its members, roles and Crates.
class OrchardRecord {
  OrchardRecord(this.orchardId);

  final String orchardId;

  /// The last entry applied (0 before the first), and its hash.
  int seq = 0;
  Uint8List head = Uint8List(0);

  final members = <String, RecordMember>{};
  final roles = <String, RecordRole>{};
  final crates = <String, RecordCrate>{};

  /// The current generation of the Orchard's own key: 1 from create, one
  /// more with each key.rotate of it.
  int orchardGeneration = 0;

  /// The commitment to each generation of the Orchard's key, from the entry
  /// that made it.
  final orchardCommits = <int, Uint8List>{};

  /// The keys ('orchard' or a Crate id) whose current generation someone who
  /// may have held it may hold no more, by an entry (removed, suspended, a
  /// role or what they were given taken down, access until a set time ended
  /// early): those wait to be replaced, until a key.rotate of them. The
  /// server's word for it alone let a server keep in use a key that someone
  /// who left still holds (found in a client security
  /// review). See [keysDueAt] for access that ends by the clock.
  final keysDue = <String>{};

  /// For each key, who came to hold its current generation by an entry: who
  /// gained it then, and the member an entry about their access names (an
  /// end date set, access until a set time given): a device seals every
  /// generation to whoever gains access by a change. Cleared with the
  /// key's next generation. When their access ends by the clock, the key
  /// waits ([keysDueAt]).
  final keyGainers = <String, Set<String>>{};

  /// The entry that made each key's current generation ('orchard' or a
  /// Crate id): create, crate.add or key.rotate.
  final generationSeq = <String, int>{};

  /// The keys that wait to be replaced at [nowSeconds]: [keysDue], and each
  /// key someone held and holds no more at [nowSeconds], their end date or
  /// the end of what they were given until a set time come: one they
  /// came to hold during its current generation ([keyGainers]), and, where
  /// [firstSeen] says when this device first saw an entry (seconds), one
  /// whose access ended after this device first saw the entry that made the
  /// current generation: it ran when that generation was made, so it reached
  /// them. The record has no clock: access that ended between a
  /// generation's making and this device seeing it is the server's to say.
  Set<String> keysDueAt(int nowSeconds, {int? Function(int seq)? firstSeen}) {
    final holds = entitlementsAt(nowSeconds);
    final due = {
      ...keysDue,
      for (final e in keyGainers.entries)
        if (e.value.any((uid) => !(holds[uid]?.contains(e.key) ?? false))) e.key,
    };
    if (firstSeen == null) return due;
    for (final m in members.values) {
      if (m.status != MemberStatus.active) continue;
      for (final scope in _mayHold(m.uid)[m.uid] ?? const <String>{}) {
        if (holds[m.uid]?.contains(scope) ?? false) continue;
        final made = generationSeq[scope];
        final seen = made == null ? null : firstSeen(made);
        final ended = _clockEnd(m, scope);
        if (seen != null && ended != null && ended > seen) due.add(scope);
      }
    }
    return due;
  }

  /// When [m]'s access to [scope] ends by the clock, in seconds: their end
  /// date, and for a Crate they were given only until a set time, that time
  /// if earlier. Null when nothing of it ends by itself.
  int? _clockEnd(RecordMember m, String scope) {
    final ends = m.endsAt;
    if (scope == kOrchardScope || switchesOf(m.uid, scope).isNotEmpty) return ends;
    final until = m.timed[scope]?.until;
    if (until == null) return ends;
    return ends != null && ends < until ? ends : until;
  }

  /// What each active member of [only] (every member when null) may hold a
  /// key of, as the record alone can say: what they hold for good and the
  /// Crates they were given until a set time, whether or not that time has
  /// come.
  Map<String, Set<String>> _mayHold([String? only]) => {
        for (final m in only == null ? members.values : [?members[only]])
          if (m.status == MemberStatus.active)
            m.uid: {
              kOrchardScope,
              for (final c in crates.keys)
                if (switchesAt(m.uid, c, 0).isNotEmpty) c,
            },
      };

  /// What the active member [uid] holds for good: the Orchard's key and
  /// each Crate they may do something in for good.
  Set<String> _forGood(String uid) => {
        if (members[uid]?.status == MemberStatus.active) ...{
          kOrchardScope,
          for (final c in crates.keys)
            if (switchesOf(uid, c).isNotEmpty) c,
        },
      };

  /// The entries about one member's access, by the member they name ('uid'):
  /// only theirs can change.
  static const _memberAccessEntries = {
    RecordTypes.memberAdd,
    RecordTypes.memberSet,
    RecordTypes.memberSuspend,
    RecordTypes.memberResume,
    RecordTypes.memberRemove,
    RecordTypes.memberRecover,
    RecordTypes.accessGrant,
    RecordTypes.memberLimit,
  };

  /// The entries that can change anyone's access: a Crate made or changed,
  /// a role changed or dropped. No other entry changes what anyone may do
  /// in a Crate.
  static const _everyoneAccessEntries = {
    RecordTypes.create,
    RecordTypes.crateAdd,
    RecordTypes.crateSet,
    RecordTypes.roleSet,
    RecordTypes.roleDrop,
    RecordTypes.adminSet,
  };

  /// The Orchard's rules.
  RecordRules rules = RecordRules.none;

  /// The record's format, from its create entry (see [kRecordFormat]).
  int format = 1;

  /// Whether two owners together may give a member their access back under
  /// new keys. Off until an owner turns it on, which needs two owners.
  bool teamRecovery = false;

  /// What the team records about its members: nothing until an owner
  /// turns some of it on.
  RecordTracking tracking = RecordTracking.none;

  /// Event export while it is on; null while it is off.
  RecordExport? eventExport;

  /// The Admin role as an owner set it (admin.set); null while it is as every
  /// team starts: every Crate that is not owners-only, and everything in the
  /// team.
  RecordAdminRole? adminRole;

  /// Whether the record holds an entry of [RecordTypes.newKinds]: after the
  /// first, nobody is asked about older versions again, and anyone may make
  /// the next (until then only an owner).
  bool newKindsUsed = false;

  /// While the team is being deleted (team.delete): the owner who
  /// asked and their entry. Null otherwise, and once an owner undid it.
  ({String by, int seq})? deleting;

  /// The state after every entry of [entries], checked one by one. Throws
  /// [RecordRejected] at the first that fails. [trusted] entries (ones this
  /// device checked when they arrived, read back from its own database) skip
  /// the signature checks and follow every other rule.
  static Future<OrchardRecord> replay(String orchardId, Iterable<RecordEntry> entries,
      {bool trusted = false}) async {
    final record = OrchardRecord(orchardId);
    for (final e in entries) {
      await record.append(e, trusted: trusted);
    }
    return record;
  }

  OrchardRecord copy() {
    final c = OrchardRecord(orchardId)
      ..seq = seq
      ..head = head
      ..orchardGeneration = orchardGeneration
      ..rules = rules
      ..format = format
      ..teamRecovery = teamRecovery
      ..tracking = tracking
      ..eventExport = eventExport
      ..adminRole = adminRole?.copy()
      ..newKindsUsed = newKindsUsed
      ..deleting = deleting;
    c.orchardCommits.addAll(orchardCommits);
    c.keysDue.addAll(keysDue);
    c.keyGainers.addAll({for (final e in keyGainers.entries) e.key: {...e.value}});
    c.generationSeq.addAll(generationSeq);
    c.members.addAll({for (final e in members.entries) e.key: e.value.copy()});
    c.roles.addAll({for (final e in roles.entries) e.key: e.value.copy()});
    c.crates.addAll({for (final e in crates.entries) e.key: e.value.copy()});
    return c;
  }

  // ── Questions the app asks ──

  int rankOfRole(String role) => switch (role) {
        FixedRoles.owner => kOwnerRank,
        FixedRoles.admin => kAdminRank,
        _ => roles[role]?.rank ?? 0,
      };

  /// The rank of an active member; 0 for anyone else.
  int rankOf(String uid) {
    final m = members[uid];
    return m == null || m.status != MemberStatus.active ? 0 : rankOfRole(m.role);
  }

  bool isActive(String uid) => members[uid]?.status == MemberStatus.active;

  bool isOwner(String uid) => isActive(uid) && members[uid]!.role == FixedRoles.owner;

  /// Whether [uid] is an active admin (not an owner).
  bool isAdmin(String uid) => isActive(uid) && members[uid]!.role == FixedRoles.admin;

  List<String> get owners => [
        for (final m in members.values)
          if (m.status == MemberStatus.active && m.role == FixedRoles.owner) m.uid,
      ];

  /// The active admins.
  List<String> get admins => [
        for (final m in members.values)
          if (m.status == MemberStatus.active && m.role == FixedRoles.admin) m.uid,
      ];

  /// How many approved devices the owners have between them.
  int get ownerDevices {
    var n = 0;
    for (final uid in owners) {
      n += members[uid]!.devices.length;
    }
    return n;
  }

  /// The approved devices of [uid] (their keys in base64); none for someone
  /// who is not in the Orchard (a removed member's are gone with them).
  Set<String> devicesOf(String uid) {
    final m = members[uid];
    return m == null ? {} : {...m.devices};
  }

  /// What a role alone gives on a Crate (before a member's own grants).
  Set<String> roleSwitches(String role, String crateId) {
    final crate = crates[crateId];
    if (crate == null) return {};
    return switch (role) {
      FixedRoles.owner => {...CrateSwitches.all},
      FixedRoles.admin => crate.ownersOnly ? {} : {...?(adminRole == null ? CrateSwitches.all : adminRole!.crates[crateId])},
      _ => crate.ownersOnly ? {} : {...?roles[role]?.crates[crateId]},
    };
  }

  /// What the active member [uid] may do in the Crate [crateId] for good:
  /// their role's switches and their own grant, within what the Crate
  /// allows. Access given until a set time is not counted: every rule
  /// of the record asks this, and a record has no clock. What someone may
  /// do with the Crate's items at a given moment is [switchesAt].
  Set<String> switchesOf(String uid, String crateId) {
    final m = members[uid];
    final crate = crates[crateId];
    if (m == null || crate == null || m.status != MemberStatus.active) return {};
    final s = <String>{
      ...roleSwitches(m.role, crateId),
      if (!crate.ownersOnly || m.role == FixedRoles.owner) ...?m.grants[crateId],
    };
    // Their limit there, where one is set (member.limit): it only takes
    // away. Owners and admins have none.
    final limit = m.role == FixedRoles.owner || m.role == FixedRoles.admin ? null : m.limits[crateId];
    if (limit != null) s.removeWhere((x) => !limit.contains(x));
    return s..removeWhere((x) => CrateSwitches.capped.contains(x) && !crate.allow.contains(x));
  }

  /// What the active member [uid] may do in the Crate [crateId] at
  /// [nowSeconds]: what they may do for good ([switchesOf]) and what they
  /// were given until a later time, within what the Crate allows;
  /// nothing once their own access to the Orchard has ended. With 0 for
  /// [nowSeconds] it answers what they may EVER have done under this state
  /// of the record, which is how a version someone wrote is judged: it names
  /// the state it was written under, and nothing in it says when.
  Set<String> switchesAt(String uid, String crateId, int nowSeconds) {
    final m = members[uid];
    final crate = crates[crateId];
    if (m == null || crate == null || m.status != MemberStatus.active) return {};
    final endsAt = m.endsAt;
    if (endsAt != null && endsAt <= nowSeconds) return {};
    final permanent = switchesOf(uid, crateId);
    final timed = m.timed[crateId];
    // (Never an owners-only Crate: nothing is given in one, and a Crate is
    // owners-only from the start or never.)
    if (timed == null || timed.until <= nowSeconds) return permanent;
    return {...permanent, ...timed.switches}
      ..removeWhere((x) => CrateSwitches.capped.contains(x) && !crate.allow.contains(x));
  }

  /// When what the member [uid] may do in the Crate [crateId] at
  /// [nowSeconds] next becomes less by itself, in seconds since the epoch:
  /// their time in the Orchard ending, or the end of what they were given
  /// until a set time where that adds to what they have for good (any
  /// switch, or one of [of] when given). Null when nothing of it ends by
  /// itself, and when they have nothing there. A certificate from the
  /// Crate's authority never outlasts it, asked [of]
  /// [CrateSwitches.inCertificate].
  int? accessEndsAt(String uid, String crateId, int nowSeconds, {Set<String>? of}) {
    final now = switchesAt(uid, crateId, nowSeconds);
    if (now.isEmpty) return null;
    final m = members[uid]!;
    final added = now.difference(switchesOf(uid, crateId));
    final counts = of == null ? added.isNotEmpty : added.any(of.contains);
    final given = counts ? m.timed[crateId]!.until : null;
    final ends = m.endsAt;
    if (given == null || (ends != null && ends < given)) return ends;
    return given;
  }

  /// What a member may do in the Orchard ([RoleCan]): owners all of it;
  /// admins what the Admin role may ([adminRole]: all of it until an owner
  /// changes it); anyone else what their role may.
  bool can(String uid, String what) {
    final m = members[uid];
    if (m == null || m.status != MemberStatus.active) return false;
    if (m.role == FixedRoles.owner) return true;
    if (m.role == FixedRoles.admin) return adminRole?.can.contains(what) ?? true;
    return roles[m.role]?.can.contains(what) ?? false;
  }

  /// Which keys each active member may hold for good: 'orchard' for the
  /// Orchard's own, and the id of each Crate they can open. A Crate given
  /// until a set time is not counted (no key is sealed on an answer that
  /// has no time in it): see [entitlementsAt].
  Map<String, Set<String>> entitlements() => {
        for (final m in members.values)
          if (m.status == MemberStatus.active)
            m.uid: {
              kOrchardScope,
              for (final c in crates.keys)
                if (switchesOf(m.uid, c).isNotEmpty) c,
            },
      };

  /// The entitlements that hold keys at [nowSeconds]: those of the record,
  /// with the Crates given until a later time, less members whose
  /// access ended by then. Entries carry no time, so the record cannot say
  /// this itself; keys follow it, here and on the server
  /// (entitlementsAt in the server's orchard_record.js).
  Map<String, Set<String>> entitlementsAt(int nowSeconds) => {
        for (final m in members.values)
          if (m.status == MemberStatus.active && (m.endsAt == null || m.endsAt! > nowSeconds))
            m.uid: {
              kOrchardScope,
              for (final c in crates.keys)
                if (switchesAt(m.uid, c, nowSeconds).isNotEmpty) c,
            },
      };

  /// Who holds [scope]'s key ('orchard' or a Crate id) at [nowSeconds], end
  /// dates counted, [skip] (accounts deleted since) aside: whom a new
  /// generation of it goes to. Sorted.
  List<String> holdersAt(String scope, int nowSeconds, {Set<String> skip = const {}}) => [
        for (final e in entitlementsAt(nowSeconds).entries)
          if (e.value.contains(scope) && !skip.contains(e.key)) e.key,
      ]..sort();

  /// The keys the record holds for [uid] at [version].
  RecordKeys? keysOf(String uid, int version) => members[uid]?.keys[version];

  /// The current generation of [scope]'s key: 'orchard' for the Orchard's
  /// own, else a Crate id; 0 for a Crate the record does not have.
  int generationOf(String scope) =>
      scope == kOrchardScope ? orchardGeneration : (crates[scope]?.generation ?? 0);

  /// The commitment the record holds to generation [generation] of
  /// [scope]'s key ('orchard' or a Crate id), or null. A device opens a key
  /// copy only when the key in it matches ([keyCommitment]), so no one, the
  /// server included, can pass off a key of their own as one a member made.
  Uint8List? keyCommitOf(String scope, int generation) =>
      scope == kOrchardScope ? orchardCommits[generation] : crates[scope]?.commits[generation];

  // ── Applying an entry ──

  /// Checks [e] against the chain and the rules, and applies it. On any
  /// failure the state is left as it was and [RecordRejected] is thrown.
  /// [trusted] skips the signature checks (see [replay]).
  Future<void> append(RecordEntry e, {bool trusted = false}) async {
    if (e.seq != seq + 1) throw RecordRejected(e.seq, 'out of order');
    if (!_equal(e.prev, head)) throw RecordRejected(e.seq, 'does not follow the entry before');
    if (!RecordTypes.all.contains(e.type)) throw RecordRejected(e.seq, 'unknown type');
    final problem = bodyProblem(e.bodyJson);
    if (problem != null) throw RecordRejected(e.seq, problem);
    final body = e.body;
    final next = copy();
    final signer = await next._apply(e, body, trusted);
    if (!trusted && !await _verify(signer, e.signedMessage(orchardId), e.signature)) {
      throw RecordRejected(e.seq, 'bad signature');
    }
    // A key someone may have held before this entry and may not hold after
    // it waits to be replaced ([keysDue]); one someone gains by it, or holds
    // after an entry about their access, they hold this generation of
    // ([keyGainers]).
    final named = _memberAccessEntries.contains(e.type) ? body['uid'] as String? : null;
    if (named != null || _everyoneAccessEntries.contains(e.type)) {
      final before = _mayHold(named);
      final after = next._mayHold(named);
      for (final held in before.entries) {
        for (final scope in held.value) {
          if (!(after[held.key]?.contains(scope) ?? false)) next.keysDue.add(scope);
        }
      }
      // What an entry naming a member gives them: the Crate of access until
      // a set time; what they hold for good, for the rest (an end date set,
      // added, back, recovered). Not a Crate given until a time long past.
      final givenToNamed = named == null
          ? const <String>{}
          : e.type == RecordTypes.accessGrant
              ? {if (next.members[named]?.timed.containsKey(body['crate']) ?? false) body['crate'] as String}
              : next._forGood(named);
      for (final has in after.entries) {
        for (final scope in has.value) {
          if (!(before[has.key]?.contains(scope) ?? false) || (has.key == named && givenToNamed.contains(scope))) {
            (next.keyGainers[scope] ??= <String>{}).add(has.key);
          }
        }
      }
    }
    // The entry that made a key's current generation.
    for (final scope in [kOrchardScope, ...next.crates.keys]) {
      if (next.generationOf(scope) != generationOf(scope)) next.generationSeq[scope] = e.seq;
    }
    // Account keys replaced, by the member (member.keys) or by two owners
    // (member.recover): the old ones, and every key opened with them,
    // may be in other hands (a lost or stolen device), so each key the
    // member may hold waits too.
    final replaced = switch (e.type) {
      RecordTypes.memberKeys => e.by,
      RecordTypes.memberRecover => body['uid'] as String?,
      _ => null,
    };
    if (replaced != null) next.keysDue.addAll(next._mayHold(replaced)[replaced] ?? const <String>{});
    // Commit.
    members
      ..clear()
      ..addAll(next.members);
    roles
      ..clear()
      ..addAll(next.roles);
    crates
      ..clear()
      ..addAll(next.crates);
    orchardGeneration = next.orchardGeneration;
    orchardCommits
      ..clear()
      ..addAll(next.orchardCommits);
    keysDue
      ..clear()
      ..addAll(next.keysDue);
    keyGainers
      ..clear()
      ..addAll(next.keyGainers);
    generationSeq
      ..clear()
      ..addAll(next.generationSeq);
    rules = next.rules;
    format = next.format;
    teamRecovery = next.teamRecovery;
    tracking = next.tracking;
    eventExport = next.eventExport;
    adminRole = next.adminRole;
    newKindsUsed = next.newKindsUsed;
    deleting = next.deleting;
    seq = e.seq;
    head = e.hash(orchardId);
  }

  /// Applies [e] to this copy and returns the key its signature must verify
  /// with. Throws [RecordRejected].
  Future<List<int>> _apply(RecordEntry e, Map<String, Object?> body, bool trusted) async {
    final r = _Body(e.seq, body, trusted: trusted);
    if (e.type == RecordTypes.create) return _create(e, r);
    if (seq == 0) throw RecordRejected(e.seq, 'the record must start with create');

    if (e.type == RecordTypes.memberKeys) return _memberKeys(e, r);

    final actor = members[e.by];
    if (actor == null || actor.status != MemberStatus.active) {
      throw RecordRejected(e.seq, 'not an active member');
    }
    final keys = actor.keys[e.byKeyVersion];
    if (keys == null || e.byKeyVersion != actor.currentKeys.version) {
      throw RecordRejected(e.seq, 'not signed with their current keys');
    }
    // While the team is being deleted, only what lets it be
    // seen, undone and left (replacing one's own keys came before).
    if (deleting != null && !_whileDeleting(e, body)) throw RecordRejected(e.seq, 'the team is being deleted');
    switch (e.type) {
      case RecordTypes.crateAdd:
        _crateAdd(e, r, actor);
      case RecordTypes.crateSet:
        _crateSet(e, r);
      case RecordTypes.roleSet:
        _roleSet(e, r);
      case RecordTypes.roleDrop:
        _roleDrop(e, r);
      case RecordTypes.memberAdd:
        await _memberAdd(e, r);
      case RecordTypes.memberSet:
        await _memberSet(e, r);
      case RecordTypes.memberSuspend:
      case RecordTypes.memberResume:
      case RecordTypes.memberRemove:
        _memberStatus(e, r);
      case RecordTypes.keyRotate:
        _keyRotate(e, r);
      case RecordTypes.rulesSet:
        _rulesSet(e, r);
      case RecordTypes.recoverySet:
        _recoverySet(e, r);
      case RecordTypes.memberRecover:
        await _memberRecover(e, r);
      case RecordTypes.caSet:
        _caSet(e, r);
      case RecordTypes.trackingSet:
        _trackingSet(e, r);
      case RecordTypes.accessGrant:
        _accessGrant(e, r);
      case RecordTypes.deviceTrust:
        await _deviceTrust(e, r);
      case RecordTypes.deviceRevoke:
        await _deviceRevoke(e, r);
      case RecordTypes.exportSet:
        _exportSet(e, r);
      case RecordTypes.sessionUnwatched:
        _sessionUnwatched(e, r);
      case RecordTypes.adminSet:
        _adminSet(e, r);
      case RecordTypes.memberLimit:
        _memberLimit(e, r);
      case RecordTypes.teamDelete:
        _teamDelete(e, r);
      case RecordTypes.teamRestore:
        _teamRestore(e, r);
    }
    if (RecordTypes.newKinds.contains(e.type)) newKindsUsed = true;
    // Event export lasts while the owner who set it up is one: it is
    // their device that sends.
    if (eventExport case final x? when !isOwner(x.by)) eventExport = null;
    // While only approved devices get in, nothing leaves the owners
    // without one: nobody could manage the Orchard any more.
    if (rules.trustedDevices && ownerDevices == 0) {
      throw RecordRejected(e.seq, 'would leave no owner with an approved device');
    }
    return keys.signingKey;
  }

  /// What device.trust and device.revoke share: the fields, the member whose
  /// device it is, and that the author may decide about it (the member
  /// themselves, an owner for anyone, an admin for those below admin).
  ({String uid, RecordMember target, Uint8List device, Uint8List via, Uint8List sig, RecordMember author})
      _deviceEntry(RecordEntry e, _Body r) {
    if (r.map_.keys.any((k) => !_deviceFields.contains(k))) throw RecordRejected(e.seq, 'malformed device');
    final uid = r.str('uid');
    final target = members[uid];
    if (target == null || target.status == MemberStatus.removed) throw RecordRejected(e.seq, 'not a member');
    final device = r.bytes('device', 32);
    final via = r.bytes('via', 32);
    final sig = r.bytes('sig', 64);
    final author = members[e.by]!;
    if (uid != e.by) {
      final above = author.role == FixedRoles.owner ||
          (author.role == FixedRoles.admin && target.role != FixedRoles.owner && target.role != FixedRoles.admin);
      if (!above) throw RecordRejected(e.seq, 'only an owner, or an admin for those below');
    }
    return (uid: uid, target: target, device: device, via: via, sig: sig, author: author);
  }

  static const _deviceFields = {'uid', 'device', 'via', 'sig'};

  /// A device of a member approved, on a device of the author's that is
  /// approved already. The one exception is an owner's own first device,
  /// which approves itself, and only while the rule is off: with the rule
  /// on, an owner without a device is approved by another owner like anyone.
  Future<void> _deviceTrust(RecordEntry e, _Body r) async {
    final d = _deviceEntry(e, r);
    final key = base64Encode(d.device);
    final through = base64Encode(d.via);
    final first = d.uid == e.by &&
        through == key &&
        d.author.role == FixedRoles.owner &&
        d.author.devices.isEmpty &&
        !rules.trustedDevices;
    if (!first && !d.author.devices.contains(through)) throw RecordRejected(e.seq, 'not from an approved device');
    if (!r.trusted && !await _deviceSigned(e, d.uid, d.device, d.via, d.sig)) {
      throw RecordRejected(e.seq, 'bad device signature');
    }
    if (d.target.devices.contains(key)) throw RecordRejected(e.seq, 'already approved');
    if (d.target.devices.length >= kMaxMemberDevices) throw RecordRejected(e.seq, 'too many devices');
    d.target.devices.add(key);
  }

  /// A device's approval taken back, on an approved device of the
  /// author's.
  Future<void> _deviceRevoke(RecordEntry e, _Body r) async {
    final d = _deviceEntry(e, r);
    if (!d.author.devices.contains(base64Encode(d.via))) throw RecordRejected(e.seq, 'not from an approved device');
    if (!r.trusted && !await _deviceSigned(e, d.uid, d.device, d.via, d.sig)) {
      throw RecordRejected(e.seq, 'bad device signature');
    }
    if (!d.target.devices.remove(base64Encode(d.device))) throw RecordRejected(e.seq, 'not an approved device');
  }

  /// Whether [sig] is the device [via]'s signature over what [e] says about
  /// the device [device] of [uid].
  Future<bool> _deviceSigned(RecordEntry e, String uid, List<int> device, List<int> via, List<int> sig) => _verify(
        via,
        deviceEntryMessage(orchardId: orchardId, type: e.type, uid: uid, device: device, prev: e.prev),
        sig,
      );

  /// A Crate given to a member until a set time, or that taken back early
  /// (access on request).
  ///
  /// Giving: by someone who manages the Crate for good and ranks above the
  /// member, handing out only what they have themselves; never to oneself,
  /// to an owner or admin (they open every Crate that is not owners-only
  /// already), nor an owners-only Crate; never [CrateSwitches.manage]. A
  /// new grant takes the place of the one the member had for that Crate.
  ///
  /// Taking back ('until' 0, no switches): by anyone who manages the Crate
  /// for good, or by the member themselves; from a suspended member too, so
  /// that nothing comes back with them when they are resumed.
  ///
  /// The body holds these fields and no other: what an entry gives is all
  /// there is to read in it.
  void _accessGrant(RecordEntry e, _Body r) {
    if (r.map_.keys.any((k) => !_accessGrantFields.contains(k))) throw RecordRejected(e.seq, 'malformed access');
    final uid = r.str('uid');
    final target = members[uid];
    if (target == null || target.status == MemberStatus.removed) throw RecordRejected(e.seq, 'not a member');
    final id = r.id('crate');
    final crate = crates[id];
    if (crate == null || crate.ownersOnly) throw RecordRejected(e.seq, 'no such Crate, or owners-only');
    // The request this answers, when it answers one: kept as it is signed.
    if (r.has('req')) r.id('req');
    final until = r.int_('until');
    final manages = switchesOf(e.by, id).contains(CrateSwitches.manage);
    if (until == 0) {
      if (r.has('switches')) throw RecordRejected(e.seq, 'malformed switches');
      if (!manages && uid != e.by) throw RecordRejected(e.seq, 'ending access to a Crate needs manage on it');
      if (!target.timed.containsKey(id)) throw RecordRejected(e.seq, 'nothing to end');
      target.timed.remove(id);
      return;
    }
    // (No number in a body is below zero: see bodyProblem.)
    if (until > kMaxAccessUntil) throw RecordRejected(e.seq, 'malformed until');
    final switches = r.stringSet('switches', CrateSwitches.all);
    if (!switches.contains(CrateSwitches.connect)) throw RecordRejected(e.seq, 'malformed switches');
    if (switches.contains(CrateSwitches.manage)) {
      throw RecordRejected(e.seq, 'access until a set time never includes manage');
    }
    if (target.status != MemberStatus.active) throw RecordRejected(e.seq, 'not an active member');
    if (uid == e.by) throw RecordRejected(e.seq, 'nobody gives themselves access');
    if (target.role == FixedRoles.owner || target.role == FixedRoles.admin) {
      throw RecordRejected(e.seq, 'owners and admins need no extra Crate');
    }
    if (!manages) throw RecordRejected(e.seq, 'giving a Crate needs manage on it');
    if (rankOf(e.by) <= rankOfRole(target.role)) throw RecordRejected(e.seq, 'only people below you');
    final mine = switchesOf(e.by, id);
    final handed = switches.where((x) => !CrateSwitches.capped.contains(x) || crate.allow.contains(x));
    if (!mine.containsAll(handed)) throw RecordRejected(e.seq, 'hands out more than they have');
    target.timed[id] = RecordTimedGrant(switches: switches, until: until);
  }

  static const _accessGrantFields = {'uid', 'crate', 'until', 'switches', 'req'};

  /// A limit for one member in one Crate (vault access per member, design
  /// 66): what they may do there for good is what their role and their extra
  /// access give, within it; switches [] is No access, which takes the Crate
  /// away. No switches clears it (From role). Setting one ends what they
  /// were given there until a set time; given after it, such access adds on
  /// top until it ends. Written by someone who manages the Crate for good
  /// and ranks above the member (an owner always does), never about an
  /// owner, an admin or oneself, never in an owners-only Crate. Lifting or
  /// loosening a limit gives access back, so it hands out only what the
  /// writer has. One that changes nothing is refused. The body holds these
  /// fields and no other. (The server decides it the same way:
  /// ZestSSH Cloud's src/lib/orchard_record.js memberLimit.)
  void _memberLimit(RecordEntry e, _Body r) {
    if (r.map_.keys.any((k) => !_memberLimitFields.contains(k))) throw RecordRejected(e.seq, 'malformed limit');
    final uid = r.str('uid');
    final target = members[uid];
    if (target == null || target.status == MemberStatus.removed) throw RecordRejected(e.seq, 'not a member');
    final id = r.id('crate');
    final crate = crates[id];
    if (crate == null || crate.ownersOnly) throw RecordRejected(e.seq, 'no such Crate, or owners-only');
    if (uid == e.by) throw RecordRejected(e.seq, 'nobody limits themselves');
    if (target.role == FixedRoles.owner || target.role == FixedRoles.admin) {
      throw RecordRejected(e.seq, 'owners and admins have no limits');
    }
    if (!switchesOf(e.by, id).contains(CrateSwitches.manage)) {
      throw RecordRejected(e.seq, 'limiting a Crate needs manage on it');
    }
    if (rankOf(e.by) <= rankOfRole(target.role)) throw RecordRejected(e.seq, 'only people below you');
    final was = target.limits[id];
    Set<String>? next;
    if (r.has('switches')) {
      next = r.stringSet('switches', CrateSwitches.all, allowEmpty: true);
      if (next.isNotEmpty && !next.contains(CrateSwitches.connect)) throw RecordRejected(e.seq, 'malformed switches');
    }
    if (next == null ? was == null : was != null && _sameSet(was, next)) {
      throw RecordRejected(e.seq, 'nothing to change');
    }
    final before = _switchesByCrate(uid);
    if (next == null) {
      target.limits.remove(id);
    } else {
      target.limits[id] = next;
      target.timed.remove(id);
    }
    _handsOutOnlyOwn(e, uid, before);
  }

  static const _memberLimitFields = {'uid', 'crate', 'switches'};

  /// Whether a team being deleted takes [e]: see
  /// [_whileDeleting]. (Replacing one's own keys is taken anyway.)
  static bool takenWhileDeleting(RecordEntry e) =>
      e.type == RecordTypes.memberKeys || _whileDeleting(e, e.body);

  /// What a team being deleted still takes: an owner's or an
  /// admin's undo, someone leaving, someone ending early what they were given until a set
  /// time, a device taking back its own approval, and the trail of watched
  /// sessions. (Replacing one's own keys is taken before this is asked: it
  /// writes into every team someone is in.)
  static bool _whileDeleting(RecordEntry e, Map<String, Object?> body) => switch (e.type) {
        RecordTypes.teamRestore || RecordTypes.sessionUnwatched => true,
        RecordTypes.memberRemove => body['uid'] == e.by,
        RecordTypes.accessGrant => body['uid'] == e.by && body['until'] == 0,
        RecordTypes.deviceRevoke => body['via'] is String && body['via'] == body['device'],
        _ => false,
      };

  /// The team deleted: by an owner, with nothing in the body.
  /// Its members are held back from then on ([deleting]); the server purges
  /// it seven days on unless an owner or an admin undoes it first. (The server decides
  /// it the same way: ZestSSH Cloud's src/lib/orchard_record.js teamDelete.)
  void _teamDelete(RecordEntry e, _Body r) {
    if (r.map_.isNotEmpty) throw RecordRejected(e.seq, 'malformed delete');
    if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners delete the team');
    deleting = (by: e.by, seq: e.seq);
  }

  /// Deleting the team undone: by an owner or an admin, with
  /// nothing in the body, only while it is being deleted. Admins too:
  /// a team whose only owner went bad, or had their
  /// account taken, can still be stopped in its seven days.
  void _teamRestore(RecordEntry e, _Body r) {
    if (r.map_.isNotEmpty) throw RecordRejected(e.seq, 'malformed restore');
    if (!isOwner(e.by) && !isAdmin(e.by)) throw RecordRejected(e.seq, 'only owners and admins undo deleting the team');
    if (deleting == null) throw RecordRejected(e.seq, 'not being deleted');
    deleting = null;
  }

  /// What the team records, all of it at once, by an owner: exactly
  /// the four switches, nothing else.
  void _trackingSet(RecordEntry e, _Body r) {
    if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners set what the team records');
    final next = RecordTracking(
      history: r.flag('history'),
      activity: r.flag('activity'),
      devices: r.flag('devices'),
      ips: r.flag('ips'),
    );
    if (r.map_.length != 4) throw RecordRejected(e.seq, 'malformed tracking');
    tracking = next;
    // Nothing is sent on while no activity is recorded.
    if (!next.activity) eventExport = null;
  }

  /// Event export, owners only: on, with the key the events are signed
  /// with, or off, and nothing else in the entry. On only while the team
  /// records activity.
  void _exportSet(RecordEntry e, _Body r) {
    if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners set event export');
    final on = r.flag('on');
    final key = on ? r.bytes('key', 32) : null;
    if (r.map_.length != (on ? 2 : 1)) throw RecordRejected(e.seq, 'malformed export');
    if (on && !tracking.activity) throw RecordRejected(e.seq, 'event export needs activity recorded');
    eventExport = key == null ? null : RecordExport(key: key, by: e.by);
  }

  /// A Crate's certificate authority, owners only: set up (generation
  /// 1), its settings changed (the same generation and public key), a new
  /// key (the next generation, a key never used before), or turned off. The
  /// private key is kept in another Crate that only owners open.
  void _caSet(RecordEntry e, _Body r) {
    if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners set a certificate authority');
    final id = r.id('crate');
    final crate = crates[id];
    if (crate == null) throw RecordRejected(e.seq, 'no such Crate');
    final ca = crate.ca;
    if (!r.flag('on')) {
      if (ca == null || !ca.on) throw RecordRejected(e.seq, 'nothing to change');
      ca.on = false;
      return;
    }
    final keyCrate = r.id('key_crate');
    final vault = crates[keyCrate];
    if (vault == null || keyCrate == id || !vault.ownersOnly) {
      throw RecordRejected(e.seq, 'the key is kept in another Crate only owners open');
    }
    final generation = r.int_('generation');
    final publicKey = r.bytes('public_key', 32);
    final ttl = r.int_('ttl_minutes');
    if (!kCaTtlMinutes.contains(ttl)) throw RecordRejected(e.seq, 'malformed ttl_minutes');
    final principals = r.principals('principals', {FixedRoles.owner, FixedRoles.admin, ...roles.keys});
    if (ca == null) {
      if (generation != 1) throw RecordRejected(e.seq, 'not the next generation');
      crate.ca = RecordCa(
        on: true,
        generation: 1,
        publicKeys: {1: publicKey},
        ttlMinutes: ttl,
        principals: principals,
        keyCrate: keyCrate,
      );
      return;
    }
    if (generation == ca.generation) {
      if (!_sameBytes(publicKey, ca.publicKey)) throw RecordRejected(e.seq, 'a new key is a new generation');
    } else if (generation == ca.generation + 1) {
      if (ca.publicKeys.values.any((k) => _sameBytes(k, publicKey))) {
        throw RecordRejected(e.seq, 'that key was used before');
      }
      ca.publicKeys[generation] = publicKey;
      ca.generation = generation;
    } else {
      throw RecordRejected(e.seq, 'not the next generation');
    }
    ca.on = true;
    ca.ttlMinutes = ttl;
    ca.principals = principals;
    ca.keyCrate = keyCrate;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Team recovery on or off: owners only; on needs two owners, since
  /// two different owners approve each recovery.
  void _recoverySet(RecordEntry e, _Body r) {
    if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners set team recovery');
    final on = r.flag('on');
    if (on && owners.length < 2) throw RecordRejected(e.seq, 'team recovery needs two owners');
    teamRecovery = on;
  }

  /// A member's access given back under new keys, with team recovery
  /// on: written by one owner and carrying a second owner's approval of the
  /// same keys. Neither may be the member. The member's keys move to the new
  /// ones, which teammates then follow as they follow a vouched change.
  Future<void> _memberRecover(RecordEntry e, _Body r) async {
    if (!teamRecovery) throw RecordRejected(e.seq, 'team recovery is off');
    if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners recover a member');
    final uid = r.str('uid');
    final target = members[uid];
    if (target == null || target.status == MemberStatus.removed) throw RecordRejected(e.seq, 'not a member');
    final approverUid = r.str('approver');
    if (uid == e.by || uid == approverUid) throw RecordRejected(e.seq, 'nobody recovers themselves');
    if (approverUid == e.by) throw RecordRejected(e.seq, 'two different owners');
    if (!isOwner(approverUid)) throw RecordRejected(e.seq, 'the second approval is not from an owner');
    final approver = members[approverUid]!;
    final approverVersion = r.int_('approver_key_version');
    final approverKeys = approver.keys[approverVersion];
    if (approverKeys == null || approverVersion != approver.currentKeys.version) {
      throw RecordRejected(e.seq, 'the second owner approves with their current keys');
    }
    final next = await r.map('keys').keys(uid);
    // Later, not only the next: a member who lost the keys they started over
    // with too starts over again, one version further on, before anyone
    // recovers them.
    if (next.version <= target.currentKeys.version) {
      throw RecordRejected(e.seq, 'keys must be a later version');
    }
    final approval = r.bytes('approval', 64);
    if (!r.trusted &&
        !await verifyTeamRecovery(
          approverKeys.signingKey,
          approval,
          orchardId: orchardId,
          subjectUid: uid,
          subjectKeyVersion: next.version,
          fingerprint: next.published(uid).fingerprint,
          approverUid: approverUid,
          approverKeyVersion: approverVersion,
        )) {
      throw RecordRejected(e.seq, 'the second owner did not approve these keys');
    }
    target.keys[next.version] = next;
    // Under new keys they start with no device approved: the devices
    // approved before held the keys that are gone.
    target.devices.clear();
  }

  Future<List<int>> _create(RecordEntry e, _Body r) async {
    if (e.seq != 1 || seq != 0) throw RecordRejected(e.seq, 'create comes first, once');
    final owner = r.map('owner');
    final uid = owner.str('uid');
    final keys = await owner.keys(uid);
    if (e.by != uid || e.byKeyVersion != keys.version) {
      throw RecordRejected(e.seq, 'create is signed by the owner');
    }
    final orchardCommit = r.bytes('key_commit', 32);
    if (r.has('format')) {
      final f = r.int_('format');
      if (f < 1 || f > kRecordFormat) throw RecordRejected(e.seq, 'a record format this app cannot read');
      format = f;
    }
    final crate = r.map('crate');
    final crateId = crate.id('id');
    crates[crateId] = RecordCrate(
      id: crateId,
      ownersOnly: crate.flag('owners_only'),
      allow: crate.allow('allow'),
      commits: {1: crate.bytes('key_commit', 32)},
    );
    for (final raw in r.list('roles')) {
      final role = _roleFrom(r.at(raw));
      if (roles.containsKey(role.id)) throw RecordRejected(e.seq, 'a role twice');
      roles[role.id] = role;
    }
    _uniqueRanks(e.seq);
    members[uid] = RecordMember(uid: uid, role: FixedRoles.owner, keys: {keys.version: keys}, since: e.seq);
    orchardGeneration = 1;
    orchardCommits[1] = orchardCommit;
    return keys.signingKey;
  }

  void _crateAdd(RecordEntry e, _Body r, RecordMember actor) {
    final id = r.id('id');
    if (crates.containsKey(id)) throw RecordRejected(e.seq, 'that Crate exists');
    final ownersOnly = r.flag('owners_only');
    if (ownersOnly ? actor.role != FixedRoles.owner : !can(actor.uid, RoleCan.createCrates)) {
      throw RecordRejected(e.seq, 'not allowed to add that Crate');
    }
    crates[id] = RecordCrate(
      id: id,
      ownersOnly: ownersOnly,
      allow: r.allow('allow'),
      commits: {1: r.bytes('key_commit', 32)},
    );
    // Someone below Admin manages the Crate they made; a Crate an admin
    // makes while the Admin role was changed, Admin manages (an admin has no
    // Crate of their own).
    if (actor.role != FixedRoles.owner && actor.role != FixedRoles.admin) {
      actor.grants[id] = levelSwitches(CrateLevel.manage);
    }
    if (actor.role == FixedRoles.admin && !ownersOnly) adminRole?.crates[id] = levelSwitches(CrateLevel.manage);
  }

  void _crateSet(RecordEntry e, _Body r) {
    final id = r.id('id');
    final crate = crates[id];
    if (crate == null) throw RecordRejected(e.seq, 'no such Crate');
    if (!r.has('owners_only') &&
        !r.has('allow') &&
        !r.has('confirm_reveal') &&
        !r.has('session_logs') &&
        !r.has('watched') &&
        !r.has('unwatched_away') &&
        !r.has('offline_hours')) {
      throw RecordRejected(e.seq, 'nothing to change');
    }
    if (r.has('owners_only')) {
      final ownersOnly = r.flag('owners_only');
      if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners mark a Crate owners-only');
      // Taking a Crate away from admins means a new key: not here.
      if (ownersOnly && !crate.ownersOnly) throw RecordRejected(e.seq, 'owners-only is set when the Crate is added');
      // A certificate authority's key stays with owners.
      if (!ownersOnly && crates.values.any((c) => c.ca?.keyCrate == id)) {
        throw RecordRejected(e.seq, "that Crate keeps a certificate authority's key");
      }
      crate.ownersOnly = ownersOnly;
    }
    if (r.has('allow')) {
      if (!switchesOf(e.by, id).contains(CrateSwitches.manage)) {
        throw RecordRejected(e.seq, 'changing a Crate needs manage');
      }
      crate.allow = r.allow('allow');
    }
    if (r.has('confirm_reveal')) {
      if (!switchesOf(e.by, id).contains(CrateSwitches.manage)) {
        throw RecordRejected(e.seq, 'changing a Crate needs manage');
      }
      crate.confirmReveal = r.flag('confirm_reveal');
    }
    // Session logs are tracking: the owners' call.
    if (r.has('session_logs')) {
      final on = r.flag('session_logs');
      if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners set session logs');
      crate.sessionLogs = on;
    }
    // Watched sessions are oversight too: the owners' call.
    if (r.has('watched')) {
      final on = r.flag('watched');
      if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners set watched sessions');
      crate.watched = on;
    }
    // While ZestSSH Cloud cannot be reached nobody can be asked to watch. An
    // owner may then connect to a watched Crate's host after giving a
    // reason; whether anyone else may is said here (3.0, the outage work).
    // It is part of how the Crate's sessions are watched, so the owners'
    // call as that is.
    if (r.has('unwatched_away')) {
      final on = r.flag('unwatched_away');
      if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners set watched sessions');
      crate.unwatchedAway = on;
    }
    // A Crate's own offline limit keeps people out of it: the owners' call,
    // as the Orchard's rules are. A year at most, as theirs (and never
    // below nought: no number in an entry is, see [bodyProblem]).
    if (r.has('offline_hours')) {
      final hours = r.int_('offline_hours');
      if (!isOwner(e.by)) throw RecordRejected(e.seq, "only owners set a Crate's offline limit");
      if (hours > 8760) throw RecordRejected(e.seq, 'rule out of range');
      crate.offlineHours = hours;
    }
    // What goes on in a file transfer, a forwarded port or a forwarded
    // agent cannot be watched: a watched Crate allows none of them, however
    // the entry that would have it otherwise is put.
    if (crate.watched && crate.allow.isNotEmpty) {
      throw RecordRejected(e.seq, 'a watched Crate allows the terminal only');
    }
  }

  /// A session to a watched Crate's host that went on with nobody watching
  /// because ZestSSH Cloud could not be reached (3.0, the outage work),
  /// reported by whoever connected once their device is back. It changes
  /// nothing: it is there to be read, by the owners and by whoever manages
  /// the Crate. Any active member may write one, whatever they may open
  /// now: what they could open when they connected may have ended since,
  /// and a report is an admission, not a right. Beyond the Crate and the
  /// time, what it says is sealed with one of the Crate's keys ('gen' says
  /// which).
  void _sessionUnwatched(RecordEntry e, _Body r) {
    if (r.map_.keys.any((k) => !_unwatchedFields.contains(k))) throw RecordRejected(e.seq, 'malformed session');
    final crate = crates[r.id('crate')];
    if (crate == null) throw RecordRejected(e.seq, 'no such Crate');
    final at = r.int_('at');
    if (at < 1 || at > kMaxAccessUntil) r._bad('at');
    final gen = r.int_('gen');
    if (gen < 1 || gen > crate.generation) r._bad('gen');
    r.sealed('sealed', kMaxUnwatchedSealed);
  }

  static const _unwatchedFields = {'crate', 'at', 'gen', 'sealed'};

  /// The Orchard's rules, all at once, by an owner.
  void _rulesSet(RecordEntry e, _Body r) {
    if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners set the rules');
    final domains = r.stringList('email_domains');
    final valid = domains.length <= kMaxRuleDomains &&
        domains.every(_domain.hasMatch) &&
        [for (var i = 1; i < domains.length; i++) domains[i - 1].compareTo(domains[i]) < 0].every((x) => x);
    if (!valid) throw RecordRejected(e.seq, 'malformed email_domains');
    int within(String k, int max) {
      final v = r.int_(k);
      if (v < 0 || v > max) throw RecordRejected(e.seq, 'rule out of range');
      return v;
    }

    final maxLock = within('max_lock_minutes', 1440);
    final offline = within('offline_hours', 8760);
    final reauth = within('reauth_days', 365);
    // In hours: newer apps write it; missing means none.
    final reauthHours = r.has('reauth_hours') ? within('reauth_hours', 8760) : 0;
    final requireLock = r.flag('require_app_lock');
    if (maxLock > 0 && !requireLock) throw RecordRejected(e.seq, 'a lock timeout needs the app lock');
    final require2fa = r.flag('require_2fa');
    final noExport = r.flag('no_export');
    // Company sign-in: newer apps write it; missing means off.
    final requireSso = r.has('require_sso') ? r.flag('require_sso') : false;
    // That sign-in counting as two-step: likewise.
    final ssoTwoStep = r.has('sso_two_step') ? r.flag('sso_two_step') : false;
    // Approved devices only: likewise. Turning it on takes two approved
    // devices among the owners (one lost still leaves one to manage with),
    // one of them the author's.
    final trustedDevices = r.has('trusted_devices') ? r.flag('trusted_devices') : false;
    if (trustedDevices && !rules.trustedDevices) {
      if (ownerDevices < 2) throw RecordRejected(e.seq, 'two approved devices among the owners first');
      if (members[e.by]!.devices.isEmpty) throw RecordRejected(e.seq, 'not from an approved device');
    }
    // Remote screens (4.0). Unlike the rules above, one that is not named
    // stays as it is: a rules.set from an app before these two (which names
    // neither) must not turn them off behind its owner's back. Apps that
    // know them always name both ([RecordRules.toSetBody]).
    final screensSshOnly = r.has('screens_ssh_only') ? r.flag('screens_ssh_only') : rules.screensSshOnly;
    final screensLock =
        r.has('screens_lock_redirections') ? r.flag('screens_lock_redirections') : rules.screensLockRedirections;
    rules = RecordRules(
      require2fa: require2fa,
      emailDomains: {...domains},
      requireAppLock: requireLock,
      maxLockMinutes: maxLock,
      noExport: noExport,
      offlineHours: offline,
      reauthDays: reauth,
      reauthHours: reauthHours,
      requireSso: requireSso,
      ssoTwoStep: ssoTwoStep,
      trustedDevices: trustedDevices,
      screensSshOnly: screensSshOnly,
      screensLockRedirections: screensLock,
    );
  }

  /// A new generation of the Orchard's key (owners and admins) or a
  /// Crate's (Manage on it), exactly one past the current one, with the
  /// commitment to the new key.
  void _keyRotate(RecordEntry e, _Body r) {
    final generation = r.int_('generation');
    if (r.has('crate')) {
      final id = r.id('crate');
      final crate = crates[id];
      if (crate == null) throw RecordRejected(e.seq, 'no such Crate');
      if (!switchesOf(e.by, id).contains(CrateSwitches.manage)) {
        throw RecordRejected(e.seq, 'replacing a Crate key needs manage');
      }
      if (generation != crate.generation + 1) throw RecordRejected(e.seq, 'not the next generation');
      crate.commits[generation] = r.bytes('key_commit', 32);
      crate.generation = generation;
      keysDue.remove(id);
      keyGainers.remove(id);
      return;
    }
    final role = members[e.by]!.role;
    if (role != FixedRoles.owner && role != FixedRoles.admin) {
      throw RecordRejected(e.seq, 'only owners and admins replace the Orchard key');
    }
    if (generation != orchardGeneration + 1) throw RecordRejected(e.seq, 'not the next generation');
    orchardCommits[generation] = r.bytes('key_commit', 32);
    orchardGeneration = generation;
    keysDue.remove(kOrchardScope);
    keyGainers.remove(kOrchardScope);
  }

  void _roleSet(RecordEntry e, _Body r) {
    if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners change roles');
    final role = _roleFrom(r);
    roles[role.id] = role;
    _uniqueRanks(e.seq);
  }

  /// The Admin role changed, owners only: {can, crates} as a role.set holds
  /// them (no name, no rank: Admin stays Admin, below the owners and above
  /// every other role), or {all: true}, back to every Crate that is not
  /// owners-only and everything in the team. Whatever it is, admins keep
  /// what only the rank gives: approving devices and changing those below
  /// them, and replacing the Orchard key.
  void _adminSet(RecordEntry e, _Body r) {
    if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners change roles');
    if (r.has('all')) {
      if (r.map_.length != 1 || !r.flag('all')) throw RecordRejected(e.seq, 'malformed admin');
      adminRole = null;
      return;
    }
    if (r.map_.length != 2 || !r.has('can') || !r.has('crates')) throw RecordRejected(e.seq, 'malformed admin');
    final can = r.stringSet('can', RoleCan.all, allowEmpty: true);
    final crates = _openCrates(e.seq, r.crateMap('crates'));
    adminRole = RecordAdminRole(can: can, crates: crates);
  }

  void _roleDrop(RecordEntry e, _Body r) {
    if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners change roles');
    final id = r.str('id');
    final moveTo = r.str('move_to');
    if (!roles.containsKey(id) || !roles.containsKey(moveTo) || id == moveTo) {
      throw RecordRejected(e.seq, 'no such role');
    }
    for (final m in members.values) {
      if (m.role == id) m.role = moveTo;
    }
    roles.remove(id);
    // A role that is gone signs in as nobody.
    for (final c in crates.values) {
      c.ca?.principals.remove(id);
    }
  }

  Future<void> _memberAdd(RecordEntry e, _Body r) async {
    final uid = r.str('uid');
    final known = members[uid];
    if (known != null && known.status != MemberStatus.removed) {
      throw RecordRejected(e.seq, 'already a member');
    }
    final keys = await r.keys(uid);
    final role = r.str('role');
    final grants = r.has('grants') ? _openCrates(e.seq, r.crateMap('grants')) : <String, Set<String>>{};
    final endsAt = r.has('ends_at') ? r.int_('ends_at') : null;
    _checkRoleExists(e.seq, role);
    if (role == FixedRoles.owner || role == FixedRoles.admin) {
      if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners add owners and admins');
      if (grants.isNotEmpty) throw RecordRejected(e.seq, 'owners and admins need no extra Crate');
    } else if (!can(e.by, RoleCan.invite) || rankOf(e.by) <= rankOfRole(role)) {
      throw RecordRejected(e.seq, 'not allowed to add someone in that role');
    }
    if (role == FixedRoles.owner && endsAt != null) throw RecordRejected(e.seq, 'owners do not end');
    if (format >= 2 && (role == FixedRoles.owner || role == FixedRoles.admin)) {
      await _checkCompared(e, r, uid, keys);
    }
    final before = _switchesByCrate(uid);
    members[uid] = RecordMember(
      uid: uid,
      role: role,
      keys: {keys.version: keys},
      since: e.seq,
      grants: grants,
      endsAt: endsAt == 0 ? null : endsAt,
      endsFromOwner: endsAt != null && endsAt != 0 && isOwner(e.by),
    );
    _handsOutOnlyOwn(e, uid, before);
  }

  Future<void> _memberSet(RecordEntry e, _Body r) async {
    final uid = r.str('uid');
    final target = members[uid];
    if (target == null || target.status == MemberStatus.removed) throw RecordRejected(e.seq, 'not a member');
    if (!r.has('role') && !r.has('grants') && !r.has('ends_at')) throw RecordRejected(e.seq, 'nothing to change');
    final newRole = r.has('role') ? r.str('role') : target.role;
    _checkRoleExists(e.seq, newRole);

    if (uid == e.by) {
      // An owner stepping down to admin, while another owner stays.
      if (target.role != FixedRoles.owner ||
          newRole != FixedRoles.admin ||
          r.has('grants') ||
          r.has('ends_at') ||
          owners.length < 2) {
        throw RecordRejected(e.seq, 'you cannot change your own role');
      }
      target.role = newRole;
      return;
    }
    // Only people below you; owners are equals.
    if (rankOf(e.by) <= rankOfRole(target.role)) throw RecordRejected(e.seq, 'only people below you');
    if (r.has('role') || r.has('ends_at')) {
      if (newRole == FixedRoles.owner || newRole == FixedRoles.admin) {
        if (!isOwner(e.by)) throw RecordRejected(e.seq, 'only owners make owners and admins');
      } else if (!can(e.by, RoleCan.changeRoles) || rankOf(e.by) <= rankOfRole(newRole)) {
        throw RecordRejected(e.seq, 'not allowed to give that role');
      }
    }
    // Nobody ranks above an owner, so nobody could resume one: only an
    // active member is made an owner.
    if (newRole == FixedRoles.owner && target.status != MemberStatus.active) {
      throw RecordRejected(e.seq, 'not active');
    }
    final grants = r.has('grants') ? _openCrates(e.seq, r.crateMap('grants')) : target.grants;
    if (r.has('grants')) {
      final touched = {...target.grants.keys, ...grants.keys};
      for (final c in touched) {
        final same = _sameSet(target.grants[c], grants[c]);
        if (!same && !switchesOf(e.by, c).contains(CrateSwitches.manage)) {
          throw RecordRejected(e.seq, 'giving a Crate needs manage on it');
        }
      }
    }
    if ((newRole == FixedRoles.owner || newRole == FixedRoles.admin) && grants.isNotEmpty) {
      throw RecordRejected(e.seq, 'owners and admins need no extra Crate');
    }
    if (format >= 2 && makesOwnerOrAdmin(target.role, newRole)) await _checkCompared(e, r, uid, target.currentKeys);
    final before = _switchesByCrate(uid);
    target
      ..role = newRole
      ..grants = grants;
    // An owner or admin opens every Crate a grant until a set time could
    // name: theirs are done with.
    if (newRole == FixedRoles.owner || newRole == FixedRoles.admin) {
      target.timed.clear();
      // And they have no limits.
      target.limits.clear();
    }
    if (r.has('ends_at')) {
      final endsAt = r.int_('ends_at');
      target.endsAt = endsAt == 0 ? null : endsAt;
      target.endsFromOwner = endsAt != 0 && isOwner(e.by);
    }
    if (target.role == FixedRoles.owner && target.endsAt != null) {
      throw RecordRejected(e.seq, 'owners do not end');
    }
    _handsOutOnlyOwn(e, uid, before);
  }

  /// In a format-2 record, making [uid] an owner or admin carries the
  /// author's statement that they compared [keys], [uid]'s keys (3.0):
  /// the member verification statement, the very bytes the server
  /// keeps for "verified by", signed with the keys that sign the entry.
  Future<void> _checkCompared(RecordEntry e, _Body r, String uid, RecordKeys keys) async {
    final statement = r.bytes('verified', 64);
    if (r.trusted) return;
    final author = members[e.by]?.keys[e.byKeyVersion];
    final ok = author != null &&
        await verifyMemberVerification(
          author.signingKey,
          statement,
          orchardId: orchardId,
          subjectUid: uid,
          subjectKeyVersion: keys.version,
          fingerprint: keys.fingerprint,
          verifierUid: e.by,
          verifierKeyVersion: e.byKeyVersion,
        );
    if (!ok) throw RecordRejected(e.seq, 'made an owner or admin without comparing their keys');
  }

  // A suspended member keeps their keys current too: replacing account keys
  // records them in every Orchard that lists the account, so a member
  // resumed later is not left on keys they no longer hold.
  Future<List<int>> _memberKeys(RecordEntry e, _Body r) async {
    final member = members[e.by];
    if (member == null || member.status == MemberStatus.removed) throw RecordRejected(e.seq, 'not a member');
    final current = member.currentKeys;
    final next = await r.keys(e.by);
    if (next.version != current.version + 1 || e.byKeyVersion != next.version) {
      throw RecordRejected(e.seq, 'keys must be the next version, signed with them');
    }
    final endorsement = r.bytes('endorsement', 64);
    if (r.trusted) {
      member.keys[next.version] = next;
      return next.signingKey;
    }
    final published = PublishedAccountKeys(
      uid: e.by,
      version: next.version,
      createdAt: next.createdAt,
      encryptionKey: next.encryptionKey,
      signingKey: next.signingKey,
      signature: next.selfSignature,
      endorsement: endorsement,
    );
    if (!await published.endorsedBy(current.published(e.by))) {
      throw RecordRejected(e.seq, 'the previous keys did not vouch for these');
    }
    member.keys[next.version] = next;
    return next.signingKey;
  }

  void _memberStatus(RecordEntry e, _Body r) {
    final uid = r.str('uid');
    final target = members[uid];
    if (target == null || target.status == MemberStatus.removed) throw RecordRejected(e.seq, 'not a member');
    final leaving = uid == e.by && e.type == RecordTypes.memberRemove;
    if (!leaving) {
      if (!can(e.by, RoleCan.remove) || rankOf(e.by) <= rankOfRole(target.role)) {
        throw RecordRejected(e.seq, 'only people below you');
      }
    }
    switch (e.type) {
      case RecordTypes.memberSuspend:
        if (target.status != MemberStatus.active) throw RecordRejected(e.seq, 'not active');
        target.status = MemberStatus.suspended;
      case RecordTypes.memberResume:
        if (target.status != MemberStatus.suspended) throw RecordRejected(e.seq, 'not suspended');
        target.status = MemberStatus.active;
      default:
        target.status = MemberStatus.removed;
        // Whoever comes back starts with no device approved.
        target.devices.clear();
    }
    if (owners.isEmpty) throw RecordRejected(e.seq, 'an Orchard keeps an owner');
  }

  // ── Rule helpers ──

  /// [map] with every Crate one this record has, and not owners-only: a role
  /// or a grant never reaches an owners-only Crate.
  Map<String, Set<String>> _openCrates(int at, Map<String, Set<String>> map) {
    for (final id in map.keys) {
      final crate = crates[id];
      if (crate == null || crate.ownersOnly) throw RecordRejected(at, 'no such Crate, or owners-only');
    }
    return map;
  }

  void _checkRoleExists(int at, String role) {
    if (role != FixedRoles.owner && role != FixedRoles.admin && !roles.containsKey(role)) {
      throw RecordRejected(at, 'no such role');
    }
  }

  void _uniqueRanks(int at) {
    final ranks = roles.values.map((r) => r.rank).toList();
    if (ranks.toSet().length != ranks.length) throw RecordRejected(at, 'two roles share a rank');
  }

  Map<String, Set<String>> _switchesByCrate(String uid) => {
        for (final c in crates.keys) c: switchesOf(uid, c),
      };

  /// Whoever made the change hands out only switches they have themselves.
  void _handsOutOnlyOwn(RecordEntry e, String uid, Map<String, Set<String>> before) {
    for (final c in crates.keys) {
      final gained = switchesOf(uid, c).difference(before[c] ?? const {});
      if (!switchesOf(e.by, c).containsAll(gained)) {
        throw RecordRejected(e.seq, 'hands out more than they have');
      }
    }
  }

  RecordRole _roleFrom(_Body r) {
    final id = r.id('id');
    if (id == FixedRoles.owner || id == FixedRoles.admin) throw RecordRejected(r.seq, 'that role is fixed');
    final rank = r.int_('rank');
    if (rank < 1 || rank > maxCustomRank) throw RecordRejected(r.seq, 'rank out of range');
    final can = r.stringSet('can', RoleCan.all, allowEmpty: true);
    final roleCrates = _openCrates(r.seq, r.crateMap('crates'));
    return RecordRole(
      id: id,
      rank: rank,
      nameEnc: r.str('name_enc'),
      nameGeneration: r.int_('name_gen'),
      can: can,
      crates: roleCrates,
    );
  }

  static Future<bool> _verify(List<int> key, List<int> message, List<int> signature) async {
    if (key.length != 32 || signature.length != 64) return false;
    try {
      return await _ed25519.verify(
        message,
        signature: Signature(signature, publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)),
      );
    } catch (_) {
      return false;
    }
  }
}

/// Reads a body's fields, refusing anything malformed.
class _Body {
  _Body(this.seq, this.map_, {this.trusted = false});

  final int seq;
  final Map<String, Object?> map_;

  /// Read back from this device's own database: signatures are not checked
  /// again.
  final bool trusted;

  Never _bad(String what) => throw RecordRejected(seq, 'malformed $what');

  bool has(String k) => map_.containsKey(k);

  _Body at(Object? raw) => raw is Map<String, Object?> ? _Body(seq, raw, trusted: trusted) : _bad('object');

  _Body map(String k) => at(map_[k]);

  String str(String k) {
    final v = map_[k];
    return v is String && v.isNotEmpty && v.length <= 2048 ? v : _bad(k);
  }

  /// An id: letters, digits and dashes.
  String id(String k) {
    final v = str(k);
    return RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(v) ? v : _bad(k);
  }

  int int_(String k) {
    final v = map_[k];
    return v is int ? v : _bad(k);
  }

  bool flag(String k) {
    final v = map_[k];
    return v is bool ? v : _bad(k);
  }

  List<Object?> list(String k) {
    final v = map_[k];
    return v is List ? v : _bad(k);
  }

  /// A list of strings (each as [str] takes them).
  List<String> stringList(String k) {
    final v = list(k);
    return [
      for (final x in v)
        if (x is String && x.isNotEmpty && x.length <= 2048) x else _bad(k),
    ];
  }

  /// Standard, padded base64 of exactly [length] bytes, spelled the one way
  /// base64 spells those bytes. The server accepts no other spelling, so the
  /// two never disagree about an entry.
  Uint8List bytes(String k, int length) {
    final v = map_[k];
    if (v is! String || !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(v)) _bad(k);
    try {
      final b = base64Decode(v);
      return b.length == length && base64Encode(b) == v ? b : _bad(k);
    } on FormatException {
      _bad(k);
    }
  }

  /// Standard, padded base64 of 1 to [max] bytes, spelled the one way
  /// base64 spells those bytes (as [bytes] takes them): something sealed for
  /// those who hold a key. The record does not read it.
  Uint8List sealed(String k, int max) {
    final v = map_[k];
    if (v is! String || !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(v)) _bad(k);
    try {
      final b = base64Decode(v);
      return b.isNotEmpty && b.length <= max && base64Encode(b) == v ? b : _bad(k);
    } on FormatException {
      _bad(k);
    }
  }

  /// A sorted list of distinct strings from [allowed].
  Set<String> stringSet(String k, Set<String> allowed, {bool allowEmpty = false}) {
    final v = map_[k];
    return _sortedSet(v, allowed, allowEmpty: allowEmpty) ?? _bad(k);
  }

  Set<String>? _sortedSet(Object? v, Set<String> allowed, {bool allowEmpty = false}) {
    if (v is! List || (v.isEmpty && !allowEmpty)) return null;
    final out = <String>[];
    for (final x in v) {
      if (x is! String || !allowed.contains(x)) return null;
      if (out.isNotEmpty && out.last.compareTo(x) >= 0) return null; // sorted, distinct
      out.add(x);
    }
    return out.toSet();
  }

  /// A Crate's settings: which of [CrateSwitches.capped] it allows.
  Set<String> allow(String k) => stringSet(k, CrateSwitches.capped, allowEmpty: true);

  /// Crate id -> switches, each set including connect.
  Map<String, Set<String>> crateMap(String k) {
    final v = map_[k];
    if (v is! Map<String, Object?>) _bad(k);
    final out = <String, Set<String>>{};
    for (final e in v.entries) {
      final switches = _sortedSet(e.value, CrateSwitches.all);
      if (switches == null || !switches.contains(CrateSwitches.connect)) _bad(k);
      out[e.key] = switches;
    }
    return out;
  }

  /// A certificate authority's user names by role: each role one of
  /// [roles], each list 1 to [kMaxCaPrincipals] sorted, distinct names of
  /// the [kCaPrincipal] form; at least one role.
  Map<String, List<String>> principals(String k, Set<String> roles) {
    final v = map_[k];
    if (v is! Map<String, Object?> || v.isEmpty) _bad(k);
    final out = <String, List<String>>{};
    for (final e in v.entries) {
      final names = e.value;
      if (!roles.contains(e.key) || names is! List || names.isEmpty || names.length > kMaxCaPrincipals) _bad(k);
      final list = <String>[];
      for (final n in names) {
        if (n is! String || !kCaPrincipal.hasMatch(n)) _bad(k);
        if (list.isNotEmpty && list.last.compareTo(n) >= 0) _bad(k); // sorted, distinct
        list.add(n);
      }
      out[e.key] = list;
    }
    return out;
  }

  /// A member's keys as the entry carries them, self-signed for [uid].
  Future<RecordKeys> keys(String uid) async {
    final keys = RecordKeys(
      version: int_('key_version'),
      signingKey: bytes('ed25519_pub', 32),
      encryptionKey: bytes('x25519_pub', 32),
      createdAt: int_('created_at'),
      selfSignature: bytes('self_sig', 64),
    );
    if (keys.version < 1 || (!trusted && !await keys.published(uid).verify())) {
      throw RecordRejected(seq, 'keys that do not sign for $uid');
    }
    return keys;
  }
}

/// Which keys each account gains between [before] and [after]: 'orchard'
/// for the Orchard's own, and the ids of Crates. What a change must bring
/// sealed to whoever gains it (the server checks the same). With
/// [nowSeconds], end dates count ([OrchardRecord.entitlementsAt]): someone
/// whose access ended holds nothing, and one given a later end date gains
/// everything again.
Map<String, Set<String>> entitlementsGained(OrchardRecord before, OrchardRecord after, {int? nowSeconds}) {
  final had = nowSeconds == null ? before.entitlements() : before.entitlementsAt(nowSeconds);
  final has = nowSeconds == null ? after.entitlements() : after.entitlementsAt(nowSeconds);
  return {
    for (final e in has.entries)
      if (e.value.difference(had[e.key] ?? const {}).isNotEmpty)
        e.key: e.value.difference(had[e.key] ?? const {}),
  };
}

/// The scope name of the Orchard's own key, next to Crate ids.
const String kOrchardScope = 'orchard';

/// The body fields of a member's keys, for entries that carry them.
Map<String, Object?> recordKeysBody(PublishedAccountKeys keys) => {
      'key_version': keys.version,
      'ed25519_pub': base64Encode(keys.signingKey),
      'x25519_pub': base64Encode(keys.encryptionKey),
      'created_at': keys.createdAt,
      'self_sig': base64Encode(keys.signature),
    };

/// Switches as a body lists them: sorted.
List<String> switchList(Iterable<String> switches) => switches.toList()..sort();

bool _sameSet(Set<String>? a, Set<String>? b) =>
    (a == null || a.isEmpty) && (b == null || b.isEmpty) ||
    (a != null && b != null && a.length == b.length && a.containsAll(b));

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

List<int> _lp(List<int> bytes) {
  final out = Uint8List(4 + bytes.length);
  ByteData.sublistView(out, 0, 4).setUint32(0, bytes.length);
  out.setRange(4, out.length, bytes);
  return out;
}

List<int> _u32(int value) {
  final out = Uint8List(4);
  ByteData.sublistView(out).setUint32(0, value);
  return out;
}
