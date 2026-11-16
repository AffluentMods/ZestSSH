import 'dart:convert';

import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;

// A setup file (3.0, setup as code): an Orchard's Crates, roles,
// rules, members and host lists as one JSON document, written by a person
// or by the app, which the app compares with the Orchard and applies.
//
// Three things hold for every file:
//
//  - It never carries a secret. A host names the key it signs in with by
//    that key's name; the key itself is made in the app, by a person.
//  - It says what should be, not what to do. What a file names is made so;
//    what it does not name is left as it is, and nothing is ever taken out
//    of an Orchard because a file leaves it out.
//  - It names things the way people do: a Crate, a role, a key and a host
//    by name, a member by address. So one file can describe more than one
//    Orchard, and an exported file reads like the Team page it came from.
//
// This file is the document alone: what it may hold, how it is read (every
// problem found, each with the place it is at) and how it is written.
// Nothing here knows an Orchard; comparing is setup_plan.dart.

/// The field every setup file starts with, and the newest version this app
/// reads and writes. Version 2 names members' limits (vault access per
/// member), and version 3 names FTPS hosts (3.4.1). A file is
/// written as the lowest version that reads all it holds: one that names
/// neither as version 1, which the apps from before limits read too; one
/// with limits and no FTPS host as 2; one with an FTPS host as 3. An app
/// from before a version refuses a file of it plainly, as written for a
/// newer app.
const String kSetupFileMarker = 'zestssh_setup';
const int kSetupFileVersion = 3;

/// The version of a file that names no limits and no FTPS host.
const int kSetupFileFirstVersion = 1;

/// The version of a file that names members' limits and no FTPS host.
const int kSetupFileLimitsVersion = 2;

/// How a file says No access in a member's limits: the Crate is taken away
/// from them, whatever their role gives.
const String kSetupNoAccess = 'none';

/// The longest file read: far past any real one, and small enough to hold.
const int kSetupFileMaxChars = 4 * 1000 * 1000;

/// How much of each a file may list. Crates and roles as an Orchard may
/// have them; the rest far past a team this app is made for.
const int kSetupMaxCrates = 200;
const int kSetupMaxRoles = 30;
const int kSetupMaxMembers = 2000;
const int kSetupMaxHosts = 2000;
const int kSetupMaxTags = 20;

/// A host's other accounts, as many as sync carries (3.0, accounts per host).
const int kSetupMaxAccounts = 64;

/// The longest names: a Crate's and a role's as the dialogs take them, a
/// host's, a key's and a group's as their tables do.
const int kSetupMaxSpaceName = 50;
const int kSetupMaxItemName = 255;
const int kSetupMaxTag = 32;
const int kSetupMaxAddress = 320;

/// How a host is reached, as a file may say it: the app's protocols that go
/// to an address, `sftp` for a host that is SFTP only (files, no terminal),
/// `ftps` for FTP over TLS said after the greeting (explicit, port 21 by
/// default) and `ftps-implicit` for TLS from the first byte (port 990 by
/// default). A version from before a word here refuses a file that has it,
/// naming where in the file it is; a file with an FTPS host is written as
/// version 3, so the apps from before it say first that it is for a newer
/// app.
const String kSetupFtps = 'ftps';
const String kSetupFtpsImplicit = 'ftps-implicit';
const Set<String> kSetupProtocols = {'ssh', 'sftp', 'mosh', 'et', 'telnet', kSetupFtps, kSetupFtpsImplicit};

/// Whether [word], a protocol as a file says it, is FTPS (explicit or
/// implicit).
bool isSetupFtps(String? word) => word == kSetupFtps || word == kSetupFtpsImplicit;

/// The protocol [word] (one of [kSetupProtocols]) as a host stores it
/// ([ConnectionProtocol]'s name): the same word, but for implicit FTPS.
String setupStoredProtocol(String word) => word == kSetupFtpsImplicit ? ConnectionProtocol.ftpsImplicit.name : word;

/// The word a file says the stored protocol [stored] with; null for a host
/// a file cannot describe (a serial line, a local shell).
String? setupProtocolWord(String stored) {
  if (stored == ConnectionProtocol.ftpsImplicit.name) return kSetupFtpsImplicit;
  return stored != kSetupFtpsImplicit && kSetupProtocols.contains(stored) ? stored : null;
}

/// The port a new host of the protocol [word] is reached at when a file
/// names none: FTPS's own (21 explicit, 990 implicit), else SSH's.
int setupDefaultPort(String word) => switch (word) {
      kSetupFtps => 21,
      kSetupFtpsImplicit => 990,
      _ => 22,
    };

/// A value a file names. The value itself may be "none" (null): a host with
/// no key, access with no end. A field the file leaves out is not one of
/// these at all (null where one could be), and is left as it is.
class Named<T> {
  const Named(this.value);

  final T value;

  @override
  bool operator ==(Object other) => other is Named<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Named($value)';
}

/// What a file says of the Orchard's rules. A rule it does not name
/// stays as it is.
class SetupRules {
  const SetupRules({
    this.require2fa,
    this.emailDomains,
    this.requireAppLock,
    this.maxLockMinutes,
    this.noExport,
    this.offlineHours,
    this.reauthDays,
    this.reauthHours,
    this.requireSso,
    this.trustedDevices,
    this.screensSshOnly,
    this.screensLockRedirections,
  });

  final bool? require2fa;
  final Set<String>? emailDomains;
  final bool? requireAppLock;
  final int? maxLockMinutes;
  final bool? noExport;
  final int? offlineHours;
  final int? reauthDays;

  /// Sign in again in hours. With [reauthDays] it is one
  /// rule: a file that names either sets both, the one it leaves out to 0.
  final int? reauthHours;
  final bool? requireSso;
  final bool? trustedDevices;

  /// The two rules about remote screens (4.0): through an SSH host only, and
  /// nothing of a device shared with them.
  final bool? screensSshOnly;
  final bool? screensLockRedirections;

  /// Every rule of [rules], named.
  factory SetupRules.of(RecordRules rules) => SetupRules(
        require2fa: rules.require2fa,
        emailDomains: {...rules.emailDomains},
        requireAppLock: rules.requireAppLock,
        maxLockMinutes: rules.maxLockMinutes,
        noExport: rules.noExport,
        offlineHours: rules.offlineHours,
        reauthDays: rules.reauthDays,
        // Named only when set, so the file of a team without them stays
        // readable by apps from before hours; the days alone say none.
        reauthHours: rules.reauthHours > 0 ? rules.reauthHours : null,
        requireSso: rules.requireSso,
        trustedDevices: rules.trustedDevices,
        // Named only when on, like the hours: the file of a team without
        // them stays readable by apps from before remote screens.
        screensSshOnly: rules.screensSshOnly ? true : null,
        screensLockRedirections: rules.screensLockRedirections ? true : null,
      );

  /// The rules [now] with what this names put over them.
  RecordRules over(RecordRules now) {
    final reauth = reauthDays != null || reauthHours != null;
    return now.copyWith(
      require2fa: require2fa,
      emailDomains: emailDomains == null ? null : {...emailDomains!},
      requireAppLock: requireAppLock,
      maxLockMinutes: maxLockMinutes,
      noExport: noExport,
      offlineHours: offlineHours,
      reauthDays: reauth ? reauthDays ?? 0 : null,
      reauthHours: reauth ? reauthHours ?? 0 : null,
      requireSso: requireSso,
      trustedDevices: trustedDevices,
      screensSshOnly: screensSshOnly,
      screensLockRedirections: screensLockRedirections,
    );
  }

  Map<String, Object?> toJson() => {
        if (require2fa != null) 'require_2fa': require2fa,
        if (emailDomains != null) 'email_domains': emailDomains!.toList()..sort(),
        if (requireAppLock != null) 'require_app_lock': requireAppLock,
        if (maxLockMinutes != null) 'max_lock_minutes': maxLockMinutes,
        if (noExport != null) 'no_export': noExport,
        if (offlineHours != null) 'offline_hours': offlineHours,
        if (reauthDays != null) 'reauth_days': reauthDays,
        if (reauthHours != null) 'reauth_hours': reauthHours,
        if (requireSso != null) 'require_sso': requireSso,
        if (trustedDevices != null) 'trusted_devices': trustedDevices,
        if (screensSshOnly != null) 'screens_ssh_only': screensSshOnly,
        if (screensLockRedirections != null) 'screens_lock_redirections': screensLockRedirections,
      };
}

/// What a file says the team records about its members. What it does
/// not name stays as it is.
class SetupRecords {
  const SetupRecords({this.history, this.activity, this.devices, this.ips});

  final bool? history;
  final bool? activity;
  final bool? devices;
  final bool? ips;

  factory SetupRecords.of(RecordTracking tracking) => SetupRecords(
        history: tracking.history,
        activity: tracking.activity,
        devices: tracking.devices,
        ips: tracking.ips,
      );

  /// What the team records [now] with what this names put over it.
  RecordTracking over(RecordTracking now) =>
      now.copyWith(history: history, activity: activity, devices: devices, ips: ips);

  Map<String, Object?> toJson() => {
        if (history != null) 'history': history,
        if (activity != null) 'activity': activity,
        if (devices != null) 'devices': devices,
        if (ips != null) 'ips': ips,
      };
}

/// A host of a Crate, by name. Only a new host needs an address; what a
/// file does not name of a host that exists stays as it is.
class SetupHost {
  const SetupHost({
    required this.name,
    this.address,
    this.port,
    this.protocol,
    this.key,
    this.accounts,
    this.group,
    this.tags,
  });

  final String name;
  final String? address;
  final int? port;

  /// One of [kSetupProtocols], as a file says it.
  final String? protocol;

  /// The name of the key it signs in with (a saved login: its user name and
  /// its key or password, which stay in the app); named as none, it asks
  /// when connecting. An FTPS host names its login the same way.
  final Named<String?>? key;

  /// Its other accounts (3.0, accounts per host): the names of the keys it
  /// can also be signed in with, in their order; empty, none.
  final List<String>? accounts;

  /// The name of the group it is shown in; named as none, in no group.
  final Named<String?>? group;

  /// Its tags, in small letters.
  final Set<String>? tags;

  Map<String, Object?> toJson() => {
        'name': name,
        if (address != null) 'address': address,
        if (port != null) 'port': port,
        if (protocol != null) 'protocol': protocol,
        if (key != null) 'key': key!.value,
        if (accounts != null) 'accounts': accounts,
        if (group != null) 'group': group!.value,
        if (tags != null) 'tags': tags!.toList()..sort(),
      };
}

/// A Crate, by name, with its settings and (when the file lists them) its
/// hosts.
class SetupCrate {
  const SetupCrate({
    required this.name,
    this.ownersOnly,
    this.allow,
    this.askAgain,
    this.sessionLogs,
    this.watched,
    this.unwatchedAway,
    this.offlineHours,
    this.hosts,
  });

  final String name;

  /// Only owners open it. Said when a Crate is added; one that exists can
  /// be opened to admins and roles, never closed to them.
  final bool? ownersOnly;

  /// Which of SFTP, port forwarding and agent forwarding it allows at all
  /// ([CrateSwitches.capped]).
  final Set<String>? allow;

  /// Showing or copying a secret from it asks for the device PIN or a
  /// fingerprint first.
  final bool? askAgain;

  /// Sessions to its hosts are logged.
  final bool? sessionLogs;

  /// Sessions to its hosts are watched.
  final bool? watched;

  /// While ZestSSH Cloud cannot be reached, so that nobody can be asked to
  /// watch, everyone who may connect to its hosts may do so after giving a
  /// reason, and not owners alone (the outage work).
  final bool? unwatchedAway;

  /// How many hours a device may go without reaching ZestSSH Cloud before
  /// the Crate closes on it; 0 for no limit of its own.
  final int? offlineHours;

  /// Its hosts; null when the file says nothing of them.
  final List<SetupHost>? hosts;

  Map<String, Object?> toJson() => {
        'name': name,
        if (ownersOnly != null) 'owners_only': ownersOnly,
        if (allow != null) 'allow': allow!.toList()..sort(),
        if (askAgain != null) 'ask_again': askAgain,
        if (sessionLogs != null) 'session_logs': sessionLogs,
        if (watched != null) 'watched': watched,
        if (unwatchedAway != null) 'unwatched_away': unwatchedAway,
        if (offlineHours != null) 'offline_hours': offlineHours,
        if (hosts != null) 'hosts': [for (final h in hosts!) h.toJson()],
      };
}

/// A role the owners make, by name: what it may do in the Orchard and what
/// it gives in each Crate (by the Crate's name). Roles stand in a file
/// highest first.
class SetupRole {
  const SetupRole({required this.name, this.can, this.crates});

  final String name;

  /// What it may do in the Orchard ([RoleCan.all]).
  final Set<String>? can;

  /// Crate name to the switches it gives there. Named, it is all the role
  /// gives: a Crate left out of it is one the role does not open.
  final Map<String, Set<String>>? crates;

  Map<String, Object?> toJson() => {
        'name': name,
        if (can != null) 'can': can!.toList()..sort(),
        if (crates != null) 'crates': {for (final c in crates!.entries) c.key: switchesJson(c.value)},
      };
}

/// A member, by address.
class SetupMember {
  const SetupMember({required this.email, this.role, this.crates, this.limits, this.until});

  /// Their address, in small letters.
  final String email;

  /// 'owner', 'admin' or the name of a role.
  final String? role;

  /// Their extra Crates: Crate name to switches. Named, it is all of them:
  /// an empty one takes every extra Crate away.
  final Map<String, Set<String>>? crates;

  /// Their limits (vault access per member): Crate name to the
  /// switches they are held to there at most, whatever their role and extra
  /// Crates give; an empty set is No access, which takes the Crate away.
  /// Named, it is all of them: an empty one clears every limit they have.
  ///
  /// A Crate may be named both here and in [crates]. For a role made by
  /// hand, an exact level can take extra access to add what the role does
  /// not give and a limit to hold back what it gives, and the member panel
  /// writes both. (The approved design had such a file refused; that was
  /// written before this case was found, and an exported team must read
  /// back as itself.)
  final Map<String, Set<String>>? limits;

  /// When their access ends, in seconds since the epoch; named as none, it
  /// does not end.
  final Named<int?>? until;

  Map<String, Object?> toJson() => {
        'email': email,
        if (role != null) 'role': role,
        if (crates != null) 'crates': {for (final c in crates!.entries) c.key: switchesJson(c.value)},
        if (limits != null) 'limits': {for (final l in limits!.entries) l.key: limitJson(l.value)},
        if (until != null) 'until': until!.value == null ? null : setupTime(until!.value!),
      };
}

/// A setup file, read. Each part is null when the file says nothing of it.
class SetupFile {
  const SetupFile({this.orchard, this.rules, this.records, this.crates, this.roles, this.members});

  /// The Orchard it is for, by name. A file that names one is applied to no
  /// other; one that names none describes any Orchard.
  final String? orchard;
  final SetupRules? rules;
  final SetupRecords? records;
  final List<SetupCrate>? crates;

  /// Highest first.
  final List<SetupRole>? roles;
  final List<SetupMember>? members;

  /// The version it is written as: the lowest that reads all it holds. The
  /// newest where a Crate lists an FTPS host, which only apps that know
  /// FTPS read; else the second where a member names limits; else the
  /// first, which every app with setup files reads.
  int get version {
    final ftps = (crates ?? const <SetupCrate>[])
        .any((c) => (c.hosts ?? const <SetupHost>[]).any((h) => isSetupFtps(h.protocol)));
    if (ftps) return kSetupFileVersion;
    if ((members ?? const <SetupMember>[]).any((m) => m.limits != null)) return kSetupFileLimitsVersion;
    return kSetupFileFirstVersion;
  }

  Map<String, Object?> toJson() => {
        kSetupFileMarker: version,
        if (orchard != null) 'orchard': orchard,
        if (rules != null) 'rules': rules!.toJson(),
        if (records != null) 'records': records!.toJson(),
        if (crates != null) 'crates': [for (final c in crates!) c.toJson()],
        if (roles != null) 'roles': [for (final r in roles!) r.toJson()],
        if (members != null) 'members': [for (final m in members!) m.toJson()],
      };
}

/// A setup file as text: two spaces a level, fields in one order, a line
/// end at the end. What [readSetupFile] reads back as the same file.
String writeSetupFile(SetupFile file) => '${const JsonEncoder.withIndent('  ').convert(file.toJson())}\n';

/// How two names are told to be the same: as written, spaces at the ends
/// and the case of letters aside.
String setupNameKey(String name) => name.trim().toLowerCase();

/// A time as a file writes it: UTC, to the second (2027-01-31T17:00:00Z).
String setupTime(int seconds) {
  final t = secondsAsDate(seconds, isUtc: true);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}Z';
}

final _time = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?(Z|[+-]\d{2}:\d{2})$');

/// The time [text] names, in seconds since the epoch, or null when it is
/// not one a file may carry: a date and a time of day with the zone said (Z
/// or an offset), so that it means one moment wherever it is read. A day
/// that no month has is not rolled into the next.
int? parseSetupTime(String text) {
  final m = _time.firstMatch(text.trim());
  if (m == null) return null;
  int n(int g) => int.parse(m.group(g)!);
  final year = n(1), month = n(2), day = n(3), hour = n(4), minute = n(5);
  final second = m.group(6) == null ? 0 : n(6);
  if (month < 1 || month > 12 || hour > 23 || minute > 59 || second > 59) return null;
  // (Day 0 of the next month is the last day of this one.)
  if (day < 1 || day > DateTime.utc(year, month + 1, 0).day) return null;
  var offset = Duration.zero;
  final zone = m.group(7)!;
  if (zone != 'Z') {
    final h = int.parse(zone.substring(1, 3)), min = int.parse(zone.substring(4, 6));
    if (h > 23 || min > 59) return null;
    offset = Duration(hours: h, minutes: min) * (zone.startsWith('-') ? -1 : 1);
  }
  final at = DateTime.utc(year, month, day, hour, minute, second).subtract(offset);
  final seconds = at.millisecondsSinceEpoch ~/ 1000;
  return seconds < 1 ? null : seconds;
}

/// Switches as a file writes them: an access level by its name where they
/// are exactly one ('use'), with agent forwarding on top ('use+agent'), or
/// else the switches themselves, sorted.
Object switchesJson(Set<String> switches) {
  for (final level in CrateLevel.values) {
    final base = levelSwitches(level);
    if (_sameSet(switches, base)) return level.name;
    if (_sameSet(switches, {...base, CrateSwitches.agent})) return '${level.name}+agent';
  }
  return switches.toList()..sort();
}

/// What a member is held to in a Crate, as a file writes it: No access as
/// [kSetupNoAccess], else the switches as [switchesJson] writes them.
Object limitJson(Set<String> switches) => switches.isEmpty ? kSetupNoAccess : switchesJson(switches);

bool _sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

// ── Reading ─────────────────────────────────────────────────────────────

/// What is wrong with a file, each kind said one way wherever it turns up.
enum SetupFileFault {
  /// Longer than [kSetupFileMaxChars].
  tooBig,

  /// Not JSON at all ([SetupFileProblem.line] and column say where).
  notJson,

  /// JSON, and not a setup file: no [kSetupFileMarker], or its top is not
  /// an object.
  notSetupFile,

  /// Written for a newer version of the app ([SetupFileProblem.value]).
  newerVersion,

  /// A field this version does not know: a spelling slip is not skipped.
  unknownField,

  /// A field that would carry a secret. A file never does.
  secretField,

  /// The same field twice in one object: which one counts would be a guess.
  duplicateField,

  /// Not the kind of value that goes there ([SetupFileProblem.kind]).
  wrongKind,

  /// A field that must be there is not.
  missing,

  /// Text with nothing in it.
  empty,

  /// Longer than [SetupFileProblem.max] characters.
  tooLong,

  /// More than [SetupFileProblem.max] of them.
  tooMany,

  /// A number outside [SetupFileProblem.min] to [SetupFileProblem.max].
  outOfRange,

  /// Not one of [SetupFileProblem.allowed].
  notOneOf,

  /// The same name twice where each stands for one thing
  /// ([SetupFileProblem.value]).
  duplicate,

  /// A role named like one of the Orchard's own two (owner, admin).
  reservedRole,

  /// Not an address domain as a rule names one.
  notADomain,

  /// Not an email address.
  notAnAddress,

  /// Not a time with its zone said.
  notATime,

  /// Switches without Connect: nothing else works without it.
  needsConnect,

  /// A character that does not show, or that turns the reading direction
  /// around: a name must read as what it is.
  oddCharacters,

  /// A Crate named as watched that also allows something: a watched Crate
  /// allows the terminal only.
  watchedAllows,
}

/// The kind of value a field takes. [limit] is what a member is held to in
/// a Crate: a [level], or none for No access.
enum SetupKind { text, number, yesNo, list, object, textOrNothing, level, limit }

/// One thing wrong with a file, and where: [path] as a JSON tool would
/// write it (`crates[2].hosts[0].port`), empty for the file as a whole.
class SetupFileProblem {
  const SetupFileProblem(
    this.fault,
    this.path, {
    this.kind,
    this.min,
    this.max,
    this.allowed = const [],
    this.value,
    this.line,
    this.column,
  });

  final SetupFileFault fault;
  final String path;
  final SetupKind? kind;
  final int? min;
  final int? max;
  final List<String> allowed;
  final String? value;
  final int? line;
  final int? column;

  @override
  String toString() => [
        fault.name,
        if (path.isNotEmpty) path,
        if (kind != null) kind!.name,
        if (min != null) 'min $min',
        if (max != null) 'max $max',
        if (allowed.isNotEmpty) allowed.join('|'),
        if (value != null) value,
        if (line != null) 'line $line',
        if (column != null) 'column $column',
      ].join(' ');
}

/// A file as it was read: the file, or everything wrong with it, never
/// both. Fields said twice come first, then what is wrong part by part
/// (rules, what the team records, Crates, roles, members).
class SetupFileRead {
  const SetupFileRead.ok(SetupFile this.file) : problems = const [];
  const SetupFileRead.failed(this.problems) : file = null;

  final SetupFile? file;
  final List<SetupFileProblem> problems;

  bool get ok => file != null;
}

/// Field names that would carry a secret, in small letters.
const _secretFields = {
  'password',
  'passphrase',
  'private_key',
  'privatekey',
  'secret',
  'token',
  'key_data',
  'pin',
};

const _topFields = {kSetupFileMarker, 'orchard', 'rules', 'records', 'crates', 'roles', 'members'};
const _ruleFields = {
  'require_2fa',
  'email_domains',
  'require_app_lock',
  'max_lock_minutes',
  'no_export',
  'offline_hours',
  'reauth_days',
  'reauth_hours',
  'require_sso',
  'trusted_devices',
  'screens_ssh_only',
  'screens_lock_redirections',
};
const _recordFields = {'history', 'activity', 'devices', 'ips'};
const _crateFields = {
  'name',
  'owners_only',
  'allow',
  'ask_again',
  'session_logs',
  'watched',
  'unwatched_away',
  'offline_hours',
  'hosts',
};
const _hostFields = {'name', 'address', 'port', 'protocol', 'key', 'accounts', 'group', 'tags'};
const _roleFields = {'name', 'can', 'crates'};
const _memberFields = {'email', 'role', 'crates', 'limits', 'until'};

/// As ZestSSH Cloud takes an address for an invitation.
final _email = RegExp(
    r"^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$");

/// Whether [text] holds a character a name must not: one that does not
/// show (a control, a line break, a space, a hyphen or a sign of no width),
/// or one that turns the reading direction around. Either could make a name
/// read as another in a list of changes: two Crates that look the same and
/// are not.
///
/// The two joiners of no width (U+200C, U+200D) are let through: Persian
/// and the Indic scripts are spelled with them, and so are emoji made of
/// several.
bool _oddCharacters(String text) => text.runes.any((r) =>
    r <= 0x1f ||
    (r >= 0x7f && r <= 0x9f) ||
    r == 0xad ||
    r == 0x61c ||
    r == 0x180e ||
    r == 0x200b ||
    r == 0x200e ||
    r == 0x200f ||
    (r >= 0x2028 && r <= 0x202e) ||
    (r >= 0x2060 && r <= 0x206f) ||
    r == 0xfeff);

/// Whether [text] is a name a file may carry as it is: something in it, at
/// most [max] characters, none that does not read as itself, and no space
/// at either end.
bool isSetupName(String text, {required int max}) =>
    text.isNotEmpty && text == text.trim() && text.runes.length <= max && !_oddCharacters(text);

/// Whether [email] is an address a file may name a member by (in small
/// letters, as ZestSSH Cloud takes one for an invitation).
bool isSetupAddress(String email) => email.length <= kSetupMaxAddress && _email.hasMatch(email);

/// Reads [text] as a setup file: the file when nothing is wrong with it,
/// else every problem found.
SetupFileRead readSetupFile(String text) {
  if (text.length > kSetupFileMaxChars) {
    return const SetupFileRead.failed([SetupFileProblem(SetupFileFault.tooBig, '', max: kSetupFileMaxChars)]);
  }
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException catch (e) {
    final at = _lineAndColumn(text, e.offset);
    return SetupFileRead.failed([SetupFileProblem(SetupFileFault.notJson, '', line: at?.line, column: at?.column)]);
  }
  if (json is! Map<String, Object?>) {
    return const SetupFileRead.failed([SetupFileProblem(SetupFileFault.notSetupFile, '')]);
  }
  final marker = json[kSetupFileMarker];
  if (marker is! int || marker < 1) {
    return const SetupFileRead.failed([SetupFileProblem(SetupFileFault.notSetupFile, '')]);
  }
  if (marker > kSetupFileVersion) {
    return SetupFileRead.failed([SetupFileProblem(SetupFileFault.newerVersion, kSetupFileMarker, value: '$marker')]);
  }
  final problems = <SetupFileProblem>[
    for (final path in duplicateFields(text)) SetupFileProblem(SetupFileFault.duplicateField, path),
  ];
  final file = _Reading(problems).file(json);
  return problems.isEmpty ? SetupFileRead.ok(file) : SetupFileRead.failed(problems);
}

({int line, int column})? _lineAndColumn(String text, int? offset) {
  if (offset == null || offset < 0 || offset > text.length) return null;
  var line = 1, column = 1;
  for (var i = 0; i < offset; i++) {
    if (text.codeUnitAt(i) == 0x0a) {
      line++;
      column = 1;
    } else {
      column++;
    }
  }
  return (line: line, column: column);
}

/// The fields of [json] (well-formed JSON) that an object holds twice, each
/// as its place. A decoder keeps the last of them without a word; a file
/// that changes who may open what is not read on a guess.
List<String> duplicateFields(String json) {
  final out = <String>[];
  final open = <_Open>[];
  String placeOfNext() {
    if (open.isEmpty) return '';
    final top = open.last;
    return top.isObject ? _join(top.path, top.key!) : '${top.path}[${top.index}]';
  }

  var i = 0;
  while (i < json.length) {
    final c = json.codeUnitAt(i);
    switch (c) {
      case 0x7b: // {
        open.add(_Open(placeOfNext(), isObject: true));
      case 0x5b: // [
        open.add(_Open(placeOfNext(), isObject: false));
      case 0x7d || 0x5d: // } ]
        open.removeLast();
      case 0x2c: // ,
        final top = open.last;
        if (top.isObject) {
          top.expectsKey = true;
        } else {
          top.index++;
        }
      case 0x22: // "
        final start = i;
        i++;
        while (json.codeUnitAt(i) != 0x22) {
          i += json.codeUnitAt(i) == 0x5c ? 2 : 1; // a backslash takes the next character with it
        }
        final top = open.isEmpty ? null : open.last;
        if (top != null && top.isObject && top.expectsKey) {
          final key = jsonDecode(json.substring(start, i + 1)) as String;
          if (!top.keys.add(key)) out.add(_join(top.path, key));
          top
            ..key = key
            ..expectsKey = false;
        }
    }
    i++;
  }
  return out;
}

class _Open {
  _Open(this.path, {required this.isObject});

  final String path;
  final bool isObject;
  final keys = <String>{};
  String? key;
  bool expectsKey = true;
  int index = 0;
}

String _join(String path, String field) => path.isEmpty ? field : '$path.$field';

/// Reads a decoded file part by part, adding what is wrong to [problems].
class _Reading {
  _Reading(this.problems);

  final List<SetupFileProblem> problems;

  void _add(SetupFileFault fault, String path,
          {SetupKind? kind, int? min, int? max, List<String> allowed = const [], String? value}) =>
      problems.add(SetupFileProblem(fault, path, kind: kind, min: min, max: max, allowed: allowed, value: value));

  /// Says every field of [map] that is not one of [known].
  void _known(Map<String, Object?> map, String path, Set<String> known) {
    for (final k in map.keys) {
      if (known.contains(k)) continue;
      _add(_secretFields.contains(k.toLowerCase()) ? SetupFileFault.secretField : SetupFileFault.unknownField,
          _join(path, k));
    }
  }

  Map<String, Object?>? _object(Object? v, String path) {
    if (v is Map<String, Object?>) return v;
    _add(SetupFileFault.wrongKind, path, kind: SetupKind.object);
    return null;
  }

  List<Object?>? _list(Object? v, String path, {required int max}) {
    if (v is! List) {
      _add(SetupFileFault.wrongKind, path, kind: SetupKind.list);
      return null;
    }
    if (v.length > max) {
      _add(SetupFileFault.tooMany, path, max: max);
      return null;
    }
    return v;
  }

  bool? _flag(Map<String, Object?> map, String path, String field) {
    if (!map.containsKey(field)) return null;
    final v = map[field];
    if (v is bool) return v;
    _add(SetupFileFault.wrongKind, _join(path, field), kind: SetupKind.yesNo);
    return null;
  }

  int? _number(Map<String, Object?> map, String path, String field, {required int min, required int max}) {
    if (!map.containsKey(field)) return null;
    final v = map[field];
    if (v is! int) {
      _add(SetupFileFault.wrongKind, _join(path, field), kind: SetupKind.number);
      return null;
    }
    if (v < min || v > max) {
      _add(SetupFileFault.outOfRange, _join(path, field), min: min, max: max);
      return null;
    }
    return v;
  }

  /// [v] as a name or another line of text: trimmed, with something in it,
  /// at most [max] characters, and none that does not read as itself.
  String? _text(Object? v, String path, {required int max, SetupKind kind = SetupKind.text}) {
    if (v is! String) {
      _add(SetupFileFault.wrongKind, path, kind: kind);
      return null;
    }
    final t = v.trim();
    if (t.isEmpty) {
      _add(SetupFileFault.empty, path);
      return null;
    }
    if (t.runes.length > max) {
      _add(SetupFileFault.tooLong, path, max: max);
      return null;
    }
    if (_oddCharacters(t)) {
      _add(SetupFileFault.oddCharacters, path);
      return null;
    }
    return t;
  }

  String? _field(Map<String, Object?> map, String path, String field, {required int max}) =>
      map.containsKey(field) ? _text(map[field], _join(path, field), max: max) : null;

  /// A field that is text or, said as null, nothing.
  Named<String?>? _textOrNothing(Map<String, Object?> map, String path, String field, {required int max}) {
    if (!map.containsKey(field)) return null;
    final v = map[field];
    if (v == null) return const Named(null);
    final t = _text(v, _join(path, field), max: max, kind: SetupKind.textOrNothing);
    return t == null ? null : Named(t);
  }

  /// The required name of a list's entry.
  String? _name(Map<String, Object?> map, String path, String field, {required int max}) {
    if (!map.containsKey(field)) {
      _add(SetupFileFault.missing, _join(path, field));
      return null;
    }
    return _text(map[field], _join(path, field), max: max);
  }

  /// A list of words, each one of [allowed] (the case of letters aside). A
  /// word that is none of them is said; the others still count for whatever
  /// else is wrong with the list, so that is said in the same reading.
  Set<String>? _words(Map<String, Object?> map, String path, String field, Set<String> allowed) {
    if (!map.containsKey(field)) return null;
    final at = _join(path, field);
    final list = _list(map[field], at, max: allowed.length * 4);
    if (list == null) return null;
    final out = <String>{};
    for (var i = 0; i < list.length; i++) {
      final v = list[i];
      final word = v is String ? v.trim().toLowerCase() : null;
      if (word == null || !allowed.contains(word)) {
        _add(SetupFileFault.notOneOf, '$at[$i]', allowed: allowed.toList()..sort());
      } else {
        out.add(word);
      }
    }
    return out;
  }

  /// Crate name to switches: each a level by name, or the switches listed.
  /// With [limits], what a member is held to: No access as well.
  Map<String, Set<String>>? _crateMap(Map<String, Object?> map, String path, String field, {bool limits = false}) {
    if (!map.containsKey(field)) return null;
    final at = _join(path, field);
    final raw = _object(map[field], at);
    if (raw == null) return null;
    if (raw.length > kSetupMaxCrates) {
      _add(SetupFileFault.tooMany, at, max: kSetupMaxCrates);
      return null;
    }
    final out = <String, Set<String>>{};
    final seen = <String>{};
    var ok = true;
    for (final e in raw.entries) {
      final place = _join(at, e.key);
      final name = _text(e.key, place, max: kSetupMaxSpaceName);
      final switches = _switches(e.value, place, limit: limits);
      if (name == null || switches == null) {
        ok = false;
        continue;
      }
      if (!seen.add(setupNameKey(name))) {
        _add(SetupFileFault.duplicate, place, value: name);
        ok = false;
        continue;
      }
      out[name] = switches;
    }
    return ok ? out : null;
  }

  /// What someone may do in a Crate: a level by name ('use', 'use+agent'),
  /// or the switches listed, Connect among them. A [limit] (what a member is
  /// held to there) may be No access too: [kSetupNoAccess], or no switches.
  Set<String>? _switches(Object? v, String path, {bool limit = false}) {
    if (v is String) {
      final t = v.trim().toLowerCase();
      if (limit && t == kSetupNoAccess) return {};
      final agent = t.endsWith('+agent');
      final name = agent ? t.substring(0, t.length - '+agent'.length) : t;
      final level = CrateLevel.values.where((l) => l.name == name).firstOrNull;
      if (level == null) {
        _add(SetupFileFault.notOneOf, path, allowed: [
          if (limit) kSetupNoAccess,
          for (final l in CrateLevel.values) l.name,
          for (final l in CrateLevel.values) '${l.name}+agent',
        ]);
        return null;
      }
      return {...levelSwitches(level), if (agent) CrateSwitches.agent};
    }
    if (v is! List) {
      _add(SetupFileFault.wrongKind, path, kind: limit ? SetupKind.limit : SetupKind.level);
      return null;
    }
    if (limit && v.isEmpty) return {};
    final out = <String>{};
    var ok = true;
    for (var i = 0; i < v.length; i++) {
      final x = v[i];
      final word = x is String ? x.trim().toLowerCase() : null;
      if (word == null || !CrateSwitches.all.contains(word)) {
        _add(SetupFileFault.notOneOf, '$path[$i]', allowed: CrateSwitches.all.toList()..sort());
        ok = false;
      } else {
        out.add(word);
      }
    }
    if (!ok) return null;
    if (!out.contains(CrateSwitches.connect)) {
      _add(SetupFileFault.needsConnect, path);
      return null;
    }
    return out;
  }

  SetupFile file(Map<String, Object?> json) {
    _known(json, '', _topFields);
    return SetupFile(
      orchard: _field(json, '', 'orchard', max: kSetupMaxSpaceName),
      rules: json.containsKey('rules') ? _rules(json['rules'], 'rules') : null,
      records: json.containsKey('records') ? _records(json['records'], 'records') : null,
      crates: json.containsKey('crates') ? _crates(json['crates'], 'crates') : null,
      roles: json.containsKey('roles') ? _roles(json['roles'], 'roles') : null,
      members: json.containsKey('members') ? _members(json['members'], 'members') : null,
    );
  }

  SetupRules? _rules(Object? v, String path) {
    final map = _object(v, path);
    if (map == null) return null;
    _known(map, path, _ruleFields);
    Set<String>? domains;
    if (map.containsKey('email_domains')) {
      final at = _join(path, 'email_domains');
      final list = _list(map['email_domains'], at, max: kMaxRuleDomains);
      if (list != null) {
        domains = {};
        for (var i = 0; i < list.length; i++) {
          final d = list[i];
          final domain = d is String ? d.trim().toLowerCase() : null;
          if (domain == null || !isRuleDomain(domain)) {
            _add(SetupFileFault.notADomain, '$at[$i]');
          } else {
            domains.add(domain);
          }
        }
      }
    }
    return SetupRules(
      require2fa: _flag(map, path, 'require_2fa'),
      emailDomains: domains,
      requireAppLock: _flag(map, path, 'require_app_lock'),
      maxLockMinutes: _number(map, path, 'max_lock_minutes', min: 0, max: 1440),
      noExport: _flag(map, path, 'no_export'),
      offlineHours: _number(map, path, 'offline_hours', min: 0, max: 8760),
      reauthDays: _number(map, path, 'reauth_days', min: 0, max: 365),
      reauthHours: _number(map, path, 'reauth_hours', min: 0, max: 8760),
      requireSso: _flag(map, path, 'require_sso'),
      trustedDevices: _flag(map, path, 'trusted_devices'),
      screensSshOnly: _flag(map, path, 'screens_ssh_only'),
      screensLockRedirections: _flag(map, path, 'screens_lock_redirections'),
    );
  }

  SetupRecords? _records(Object? v, String path) {
    final map = _object(v, path);
    if (map == null) return null;
    _known(map, path, _recordFields);
    return SetupRecords(
      history: _flag(map, path, 'history'),
      activity: _flag(map, path, 'activity'),
      devices: _flag(map, path, 'devices'),
      ips: _flag(map, path, 'ips'),
    );
  }

  /// Each entry of the list at [path] read by [one]; a name that came
  /// before (as [keyOf] tells names apart) is said and left out.
  List<T>? _each<T>(
    Object? v,
    String path, {
    required int max,
    required T? Function(Map<String, Object?> map, String path) one,
    required String Function(T) keyOf,
    required String Function(T) nameOf,
    required String nameField,
  }) {
    final list = _list(v, path, max: max);
    if (list == null) return null;
    final out = <T>[];
    final seen = <String>{};
    for (var i = 0; i < list.length; i++) {
      final at = '$path[$i]';
      final map = _object(list[i], at);
      if (map == null) continue;
      final entry = one(map, at);
      if (entry == null) continue;
      if (!seen.add(keyOf(entry))) {
        _add(SetupFileFault.duplicate, _join(at, nameField), value: nameOf(entry));
        continue;
      }
      out.add(entry);
    }
    return out;
  }

  List<SetupCrate>? _crates(Object? v, String path) => _each<SetupCrate>(
        v,
        path,
        max: kSetupMaxCrates,
        one: _crate,
        keyOf: (c) => setupNameKey(c.name),
        nameOf: (c) => c.name,
        nameField: 'name',
      );

  SetupCrate? _crate(Map<String, Object?> map, String path) {
    _known(map, path, _crateFields);
    final name = _name(map, path, 'name', max: kSetupMaxSpaceName);
    final allow = _words(map, path, 'allow', CrateSwitches.capped);
    final watched = _flag(map, path, 'watched');
    if (watched == true && allow != null && allow.isNotEmpty) {
      _add(SetupFileFault.watchedAllows, _join(path, 'allow'));
    }
    final crate = SetupCrate(
      name: name ?? '',
      ownersOnly: _flag(map, path, 'owners_only'),
      allow: allow,
      askAgain: _flag(map, path, 'ask_again'),
      sessionLogs: _flag(map, path, 'session_logs'),
      watched: watched,
      unwatchedAway: _flag(map, path, 'unwatched_away'),
      // A year at most, as the record takes it.
      offlineHours: _number(map, path, 'offline_hours', min: 0, max: 8760),
      hosts: map.containsKey('hosts')
          ? _each<SetupHost>(
              map['hosts'],
              _join(path, 'hosts'),
              max: kSetupMaxHosts,
              one: _host,
              keyOf: (h) => setupNameKey(h.name),
              nameOf: (h) => h.name,
              nameField: 'name',
            )
          : null,
    );
    return name == null ? null : crate;
  }

  SetupHost? _host(Map<String, Object?> map, String path) {
    _known(map, path, _hostFields);
    final name = _name(map, path, 'name', max: kSetupMaxItemName);
    String? protocol;
    if (map.containsKey('protocol')) {
      final v = map['protocol'];
      final word = v is String ? v.trim().toLowerCase() : null;
      if (word == null || !kSetupProtocols.contains(word)) {
        _add(SetupFileFault.notOneOf, _join(path, 'protocol'), allowed: kSetupProtocols.toList()..sort());
      } else {
        protocol = word;
      }
    }
    Set<String>? tags;
    if (map.containsKey('tags')) {
      final at = _join(path, 'tags');
      final list = _list(map['tags'], at, max: kSetupMaxTags);
      if (list != null) {
        tags = {};
        for (var i = 0; i < list.length; i++) {
          final tag = _text(list[i], '$at[$i]', max: kSetupMaxTag);
          if (tag != null) tags.add(tag.toLowerCase());
        }
      }
    }
    // Its other accounts, each a key's name once (3.0, accounts per host).
    List<String>? accounts;
    if (map.containsKey('accounts')) {
      final at = _join(path, 'accounts');
      final list = _list(map['accounts'], at, max: kSetupMaxAccounts);
      if (list != null) {
        accounts = [];
        final seen = <String>{};
        for (var i = 0; i < list.length; i++) {
          final account = _text(list[i], '$at[$i]', max: kSetupMaxItemName);
          if (account == null) continue;
          if (!seen.add(setupNameKey(account))) {
            _add(SetupFileFault.duplicate, '$at[$i]', value: account);
            continue;
          }
          accounts.add(account);
        }
      }
    }
    final address = _field(map, path, 'address', max: kSetupMaxItemName);
    if (address != null && address.contains(RegExp(r'\s'))) {
      _add(SetupFileFault.oddCharacters, _join(path, 'address'));
    }
    final host = SetupHost(
      name: name ?? '',
      address: address,
      port: _number(map, path, 'port', min: 1, max: 65535),
      protocol: protocol,
      key: _textOrNothing(map, path, 'key', max: kSetupMaxItemName),
      accounts: accounts,
      group: _textOrNothing(map, path, 'group', max: kSetupMaxItemName),
      tags: tags,
    );
    return name == null ? null : host;
  }

  List<SetupRole>? _roles(Object? v, String path) => _each<SetupRole>(
        v,
        path,
        max: kSetupMaxRoles,
        one: _role,
        keyOf: (r) => setupNameKey(r.name),
        nameOf: (r) => r.name,
        nameField: 'name',
      );

  SetupRole? _role(Map<String, Object?> map, String path) {
    _known(map, path, _roleFields);
    var name = _name(map, path, 'name', max: kSetupMaxSpaceName);
    if (name != null && isFixedRoleName(name)) {
      _add(SetupFileFault.reservedRole, _join(path, 'name'), value: name);
      name = null;
    }
    final role = SetupRole(
      name: name ?? '',
      can: _words(map, path, 'can', RoleCan.all),
      crates: _crateMap(map, path, 'crates'),
    );
    return name == null ? null : role;
  }

  List<SetupMember>? _members(Object? v, String path) => _each<SetupMember>(
        v,
        path,
        max: kSetupMaxMembers,
        one: _member,
        keyOf: (m) => m.email,
        nameOf: (m) => m.email,
        nameField: 'email',
      );

  SetupMember? _member(Map<String, Object?> map, String path) {
    _known(map, path, _memberFields);
    String? email;
    if (!map.containsKey('email')) {
      _add(SetupFileFault.missing, _join(path, 'email'));
    } else {
      final v = map['email'];
      final t = v is String ? v.trim().toLowerCase() : null;
      if (t == null || t.length > kSetupMaxAddress || !_email.hasMatch(t)) {
        _add(SetupFileFault.notAnAddress, _join(path, 'email'));
      } else {
        email = t;
      }
    }
    var role = _field(map, path, 'role', max: kSetupMaxSpaceName);
    // The Orchard's own two roles are written one way.
    if (role != null && isFixedRoleName(role)) role = role.toLowerCase();
    Named<int?>? until;
    if (map.containsKey('until')) {
      final v = map['until'];
      if (v == null) {
        until = const Named(null);
      } else {
        final seconds = v is String ? parseSetupTime(v) : null;
        if (seconds == null) {
          _add(SetupFileFault.notATime, _join(path, 'until'));
        } else {
          until = Named(seconds);
        }
      }
    }
    final member = SetupMember(
      email: email ?? '',
      role: role,
      crates: _crateMap(map, path, 'crates'),
      // (A Crate in both is no problem: see SetupMember.limits.)
      limits: _crateMap(map, path, 'limits', limits: true),
      until: until,
    );
    return email == null ? null : member;
  }
}

/// Whether [name] is how one of the Orchard's own two roles is written
/// (owner, admin), the case of letters aside: no role of a file is called
/// that, and a member's role written so means the Orchard's own.
bool isFixedRoleName(String name) {
  final key = setupNameKey(name);
  return key == FixedRoles.owner || key == FixedRoles.admin;
}
