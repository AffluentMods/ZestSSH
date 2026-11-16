import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show TableUpdateQuery, Variable;
import 'package:flutter/foundation.dart' show mapEquals, setEquals, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/network_state.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/team/join_readiness.dart' show accountPageOpenerProvider;
import 'package:zestssh/features/orchards/team/team_sync_offer.dart' show teamSyncNotification, teamSyncToldKey;
import 'package:zestssh/router/router.dart' show routerProvider;
import 'package:zestssh/services/purchase_service.dart' show PurchaseService;
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/members/invite_maker_checks.dart';
import 'package:zestssh/features/orchards/members/team_recovery.dart';
import 'package:zestssh/features/orchards/directory/directory_roles.dart';
import 'package:zestssh/features/orchards/directory/orchard_directory_api.dart';
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart';
import 'package:zestssh/features/orchards/export/event_exporter.dart';
import 'package:zestssh/features/orchards/export/export_settings.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/key_replacement.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart' show latestRecordIn;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/offline_pass.dart' show kAllOfOrchard;
import 'package:zestssh/features/orchards/rules/offline_warnings.dart';
import 'package:zestssh/features/orchards/rules/orchard_contact.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/rules/reauth_warning.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show crateDisplayName, orchardDisplayName;
import 'package:zestssh/features/sharing/share_nudges.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/models/enums.dart' show SecurityLockMethod;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/account/device_approval_alerts.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/two_step_api.dart' show securityNudges;
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/services/profiles/keychain.dart' show keychainWaitsForPerson;
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/providers/profile_providers.dart';

/// ZestSSH Cloud's Orchard routes with the account's own sign-in: the
/// Firebase ID token, or the desktop session (like the account keys).
final orchardsApiProvider = Provider<OrchardsApi>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return OrchardsApi(
    bearer: () async =>
        await AuthService.getIdToken(forceRefresh: false) ??
        await AccountSecret.sessionToken.read(storage),
  );
});

/// ZestSSH Cloud's domain routes for Orchards.
final orchardDomainsApiProvider = Provider<OrchardDomainsApi>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return OrchardDomainsApi(
    bearer: () async =>
        await AuthService.getIdToken(forceRefresh: false) ??
        await AccountSecret.sessionToken.read(storage),
  );
});

/// ZestSSH Cloud's directory sync routes for Orchards (owners and admins).
final orchardDirectoryApiProvider = Provider<OrchardDirectoryApi>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return OrchardDirectoryApi(
    bearer: () async =>
        await AuthService.getIdToken(forceRefresh: false) ??
        await AccountSecret.sessionToken.read(storage),
  );
});

/// ZestSSH Cloud's billing route for Orchards: seats and Business
/// Services, for members. Nothing is bought through it.
/// Asks ZestSSH Cloud for this account's entitlements (the team's among
/// them); tests replace it.
Future<({bool pro, bool cloudSync, bool team})?> Function() teamEntitlementAsk = PurchaseService.fetchWebEntitlements;

final orchardBillingApiProvider = Provider<OrchardBillingApi>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return OrchardBillingApi(
    bearer: () async =>
        await AuthService.getIdToken(forceRefresh: false) ??
        await AccountSecret.sessionToken.read(storage),
  );
});

/// An Orchard's seats and Business Services, read while shown.
final orchardBillingProvider = FutureProvider.autoDispose.family<OrchardBilling, String>(
    (ref, orchardId) => ref.watch(orchardBillingApiProvider).get(orchardId));

/// The Orchards whose last sync kept new items waiting on this device for
/// seats: more people than seats.
final orchardSeatsShortProvider = StateProvider<Set<String>>((ref) => const <String>{});

/// Of those, the Orchards where it was what their vaults hold, not how many
/// people they have (CrateSyncReport.vaultsFull).
final orchardVaultsFullProvider = StateProvider<Set<String>>((ref) => const <String>{});

/// The domains [orchardId] proved, for telling guests apart:
/// empty when there are none or they cannot be read (the server holds to
/// it either way).
final orchardProvenDomainsProvider = FutureProvider.autoDispose.family<List<String>, String>((ref, orchardId) async {
  try {
    return [
      for (final d in await ref.watch(orchardDomainsApiProvider).list(orchardId))
        if (d.verified) d.domain,
    ];
  } catch (_) {
    return const [];
  }
});

/// Which Orchard's directory sync to read, and whether this account runs
/// the Orchard there (an owner or admin whose membership counts now).
typedef DirectoryReader = ({String orchardId, bool manages});

DirectoryReader directoryReaderOf(OrchardSummary o) =>
    (orchardId: o.id, manages: o.active && (o.isOwner || o.role == FixedRoles.admin));

/// An Orchard's directory sync, for its owners and admins; null for anyone
/// else, when it cannot be read, or while it is off. Read again when the
/// Orchard list changes (a directory's change nudges its managers).
final orchardDirectoryProvider = FutureProvider.autoDispose.family<OrchardDirectory?, DirectoryReader>((ref, key) async {
  ref.watch(orchardListVersionProvider);
  if (!key.manages) return null;
  try {
    final directory = await ref.watch(orchardDirectoryApiProvider).get(key.orchardId);
    return directory.enabled ? directory : null;
  } catch (_) {
    return null;
  }
});

/// ZestSSH Cloud's company sign-in routes for Orchards (owners).
final orchardSsoApiProvider = Provider<OrchardSsoApi>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return OrchardSsoApi(
    bearer: () async =>
        await AuthService.getIdToken(forceRefresh: false) ??
        await AccountSecret.sessionToken.read(storage),
  );
});

/// An Orchard's company sign-in as ZestSSH Cloud keeps it (owners only):
/// the Rules page asks whether it is on before offering "Sign in with SSO".
final orchardSsoProvider = FutureProvider.autoDispose.family<OrchardSso, String>(
    (ref, orchardId) => ref.watch(orchardSsoApiProvider).get(orchardId));

/// The signed-in account and its keys, once this device holds the keys the
/// server published. A new sign-in starts over.
final orchardAuthorProvider = Provider<OrchardAuthorSource>((ref) {
  final uid = ref.watch(currentUserProvider)?.uid;
  return OrchardAuthorSource(
    () async {
      final ready = await ref.read(accountKeyServiceProvider).readyKeys();
      return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
    },
    // With the server out of reach and nothing known yet in this run: the
    // keys this device holds for the account as the server last confirmed
    // them.
    lastConfirmed: () async {
      if (uid == null) return null;
      final keys = await ref.read(accountKeyServiceProvider).confirmedKeysHere(uid);
      return keys == null ? null : CrateAuthor(uid: uid, keys: keys);
    },
  );
});

/// Asks the server which keys are this account's at most every ten minutes,
/// one question at a time. Keys that are not ready yet are asked about
/// again the next time.
///
/// When the server cannot be asked, what it said last stands (or, with
/// nothing said yet in this run, the keys the device holds as confirmed):
/// an Orchard on this device goes on working while the server is down, and
/// so does a certificate the device holds that is still good. Nothing more
/// is opened by it, since everything that goes through the server is held
/// to the account's keys by the server. (Until this was held, ten minutes
/// into an outage every use of the keys failed, a valid certificate
/// included.)
class OrchardAuthorSource {
  OrchardAuthorSource(
    this._load, {
    DateTime Function()? clock,
    Future<CrateAuthor?> Function()? lastConfirmed,
  })  : _clock = clock ?? DateTime.now,
        _lastConfirmed = lastConfirmed;

  static const recheckAfter = Duration(minutes: 10);

  /// After the server could not be asked it is left alone for this long,
  /// and what is known is used at once: a server that is down must not make
  /// every use of the keys wait for a connection to give up.
  static const askAgainAfterFailure = Duration(minutes: 1);

  final Future<CrateAuthor?> Function() _load;
  final Future<CrateAuthor?> Function()? _lastConfirmed;
  final DateTime Function() _clock;
  CrateAuthor? _author;
  DateTime? _at;
  DateTime? _failedAt;
  Future<CrateAuthor?>? _loading;

  /// Whether the keys this device holds may stand in while the server
  /// cannot be asked: while it has said nothing yet in this run. Not after
  /// [forget] (they may be the very keys that were replaced), and not after
  /// the server answered that the account's keys are not ready here.
  bool _deviceKeysMayStandIn = true;

  /// Asks the server again next time: after this device replaced the
  /// account's keys, or learned that another device did. Until the server
  /// has answered, nothing stands in for its answer.
  void forget() {
    _author = null;
    _at = null;
    _failedAt = null;
    _deviceKeysMayStandIn = false;
  }

  Future<CrateAuthor?> call() {
    final author = _author;
    final at = _at;
    if (author != null && at != null && _clock().difference(at) < recheckAfter) {
      return Future.value(author);
    }
    final failedAt = _failedAt;
    if (author != null && failedAt != null && _clock().difference(failedAt) < askAgainAfterFailure) {
      return Future.value(author);
    }
    return _loading ??= _ask().whenComplete(() {
      _loading = null;
    });
  }

  Future<CrateAuthor?> _ask() async {
    final CrateAuthor? loaded;
    try {
      loaded = await _load();
    } catch (_) {
      // The server could not be asked. (That the keys are not ready, or are
      // not this account's any more, it says as an answer, not as a failure.)
      final known = _author ?? (_deviceKeysMayStandIn ? await _lastConfirmed?.call() : null);
      if (known == null) rethrow;
      _author = known;
      _failedAt = _clock();
      return known;
    }
    _author = loaded;
    _at = loaded == null ? null : _clock();
    _failedAt = null;
    // The server has spoken: from here on its last word is what stands.
    _deviceKeysMayStandIn = false;
    return loaded;
  }
}

final orchardServiceProvider = Provider<OrchardService>((ref) => OrchardService(
      server: ref.watch(orchardsApiProvider),
      databases: ref.watch(orchardDatabasesProvider.notifier),
      author: ref.watch(orchardAuthorProvider).call,
      // This device's own signing key, in the system's secure storage.
      deviceKeys: DeviceIdentityStore(ref.watch(secureStorageProvider)),
      // What an invite code's maker's keys were checked as (the first record
      // read of that team must hold them).
      makerChecks: InviteMakerChecks(ref.watch(secureStorageProvider)),
      // A login asks nothing of a service the app knows is not answering.
      cloudAway: () => ref.read(cloudReachProvider).state.value.inTheWay,
      onServerList: (ids, uid) => ref.read(profileControllerProvider).teamsOnServer(ids, uid: uid),
      // Reaching ZestSSH Cloud opens what the offline limits closed.
      onContact: () {
        unawaited(ref.read(orchardContactProvider.notifier).reached());
        if (ref.read(orchardDatabasesProvider.notifier).reopenOffline()) {
          ref.read(orchardListVersionProvider.notifier).state++;
        }
        // And the Crates their own limits had closed: they are open from
        // this moment for whoever asks; the screens are told.
        final scheduler = ref.read(orchardSyncSchedulerProvider);
        if (scheduler.cratesClosedHere || scheduler.closingSoonHere) unawaited(scheduler.checkOfflineLimits());
      },
      // An offline pass an owner signed for this device changes what the
      // limits close here from this moment.
      onPass: () {
        ref.read(orchardListVersionProvider.notifier).state++;
        unawaited(ref.read(orchardSyncSchedulerProvider).checkOfflineLimits());
      },
      // The device that sends an Orchard's events on says what it has left
      // before its sending ends.
      flushEvents: (orchardId) => ref.read(orchardEventExporterProvider).flush(orchardId),
      // A deleted team left this device: said in the
      // notifications, which outlive its database.
      onTeamDeleted: (gone) {
        final l10n = gl10n;
        final name = orchardDisplayName(gone.name, l10n);
        ref.read(notificationCenterProvider.notifier).info(
              l10n.noticeTeamDeletedTitle(name),
              body: gone.byMe
                  ? l10n.noticeTeamDeletedByYouBody
                  : gone.byName != null
                      // (Masked while recording, as everywhere a person is named.)
                      ? l10n.noticeTeamDeletedByBody(Redactable.account(gone.byName!).display)
                      : l10n.noticeTeamDeletedBody,
            );
        ref.read(orchardListVersionProvider.notifier).state++;
      },
    ));

/// This device's app lock as an Orchard's rules see it: on (with a
/// PIN or biometrics), and how many minutes the app may be left before it
/// locks (0 at once, a negative number never). Read afresh when either
/// setting changes.
final deviceLockProvider = FutureProvider<({bool on, int minutes})>((ref) async {
  final enabled = ref.watch(securityLockEnabledProvider);
  ref.watch(autoLockTimeoutProvider);
  final lock = ref.read(securityLockServiceProvider);
  final method = await lock.getLockMethod();
  final minutes = await lock.getAutoLockTimeout();
  return (on: enabled && method != SecurityLockMethod.none, minutes: minutes);
});

/// The rules of [rules] this device falls short of now, read from its
/// settings as they stand.
Future<List<UnmetRule>> deviceUnmetNow(Ref ref, RecordRules rules) async {
  final lock = ref.read(securityLockServiceProvider);
  final on = ref.read(settingsServiceProvider).securityLockEnabled &&
      await lock.getLockMethod() != SecurityLockMethod.none;
  return deviceUnmet(rules, lockOn: on, lockMinutes: await lock.getAutoLockTimeout());
}

final orchardSyncProvider = Provider<OrchardSyncCoordinator>((ref) => OrchardSyncCoordinator(
      service: ref.watch(orchardServiceProvider),
      server: ref.watch(orchardsApiProvider),
      databases: ref.watch(orchardDatabasesProvider.notifier),
      // The account replaced its keys on another device: ask for them now,
      // and fetch them through sync at once rather than at the next sync.
      onStaleAccountKeys: () {
        ref.read(orchardAuthorProvider).forget();
        ref.read(accountKeyCheckerProvider).recheckSoon();
        unawaited(ref.read(autoSyncServiceProvider).triggerSync());
      },
      deviceRules: (rules) => deviceUnmetNow(ref, rules),
    ));

/// Replacing the account's keys and what depended on them (3.0);
/// its follow-up carries on after each Orchard sync.
final keyReplacementProvider = Provider<KeyReplacement>((ref) => KeyReplacement(
      keys: ref.watch(accountKeyServiceProvider),
      orchards: ref.watch(orchardServiceProvider),
      sync: ref.watch(orchardSyncProvider),
      progress: PrefsKeyReplacementProgressStore(ref.watch(sharedPreferencesProvider)),
      forgetAuthor: () => ref.read(orchardAuthorProvider).forget(),
    ));

// ── The switcher's list ─────────────────────────────────────────────────

/// A Crate as the switcher and the host list show it.
class CrateSummary {
  const CrateSummary({
    required this.id,
    required this.name,
    required this.level,
    this.switches = const {},
    this.ownersOnly = false,
    this.allow = kDefaultCrateAllow,
    this.rotationDue = false,
    this.confirmReveal = false,
    this.offlineHours = 0,
    this.closedOffline = false,
    this.closesAt,
    this.passUntil,
  });

  final String id;

  /// Null while its key has not opened on this device.
  final String? name;

  /// 'connect', 'use', 'edit' or 'manage': the nearest level to [switches].
  final String level;

  /// What this account may do in it, from the Orchard's record. None
  /// of it while the Crate is [closedOffline].
  final Set<String> switches;
  final bool ownersOnly;

  /// Which of sftp, forward and agent the Crate allows at all.
  final Set<String> allow;

  /// Someone lost access, so its key waits to be replaced (by whoever
  /// manages it).
  final bool rotationDue;

  /// Showing or copying a secret from it asks for the device PIN or a
  /// fingerprint first.
  final bool confirmReveal;

  /// How many hours a device may go without reaching ZestSSH Cloud before
  /// this Crate closes on it; 0 for no limit of its own.
  final int offlineHours;

  /// Closed on this device by that limit until the device reaches ZestSSH
  /// Cloud again: its hosts do not connect, its keys sign in nowhere, and
  /// nothing in it is shown in clear, copied, exported or changed. Its
  /// items stay listed.
  final bool closedOffline;

  /// While it is open and about to close by that limit (in the last
  /// quarter of it): the last second, since the epoch, at which it is still
  /// open on this device. Null otherwise.
  final int? closesAt;

  /// While an offline pass an owner signed for this device holds for it
  /// (its own, or one for all of the Orchard, whichever reaches further):
  /// the last second, since the epoch, the pass holds. Null otherwise.
  final int? passUntil;

  bool allows(String s) => switches.contains(s);

  /// Adds, edits or deletes anything at all.
  bool get canWrite => allows(CrateSwitches.add) || allows(CrateSwitches.edit) || allows(CrateSwitches.delete);

  /// New items (and items moved here) arrive as additions.
  bool get canAdd => allows(CrateSwitches.add);
}

/// What the Admin role [admin] gives in the Crate [crateId] (null [admin]:
/// as every team starts, everything but in an owners-only one): the
/// record's own answer ([OrchardRecord.roleSwitches]), for what the screens
/// say before anything is changed.
Set<String> adminSwitches(RecordAdminRole? admin, {required String crateId, required bool ownersOnly}) {
  if (ownersOnly) return const {};
  if (admin == null) return {...CrateSwitches.all};
  return {...?admin.crates[crateId]};
}

/// An Orchard on this device, as the switcher shows it.
class OrchardSummary {
  const OrchardSummary({
    required this.id,
    required this.name,
    required this.role,
    required this.crates,
    required this.defaultCrateId,
    this.can = const {},
    this.status = 'active',
    this.recordProblem,
    this.rotationDue = false,
    this.invitesWaiting = 0,
    this.rules = RecordRules.none,
    this.rulesUnmet = const [],
    this.ruleDomains = const [],
    this.deviceRemoved = false,
    this.closedOffline = false,
    this.closesAt,
    this.passUntil,
    this.adminRole,
    this.deleting,
    this.deletedAt,
  });

  /// An Orchard closed on this device by its offline limit, as this
  /// device last knew it ([last], when it did).
  factory OrchardSummary.closedOffline(String id, {OrchardSummary? last}) => OrchardSummary(
        id: id,
        name: last?.name,
        role: last?.role ?? '',
        crates: const [],
        defaultCrateId: null,
        status: last?.status ?? 'active',
        rules: last?.rules ?? RecordRules.none,
        closedOffline: true,
        adminRole: last?.adminRole,
      );

  final String id;

  /// Null while its key has not opened on this device.
  final String? name;

  /// 'owner', 'admin' or the id of a role the owners made.
  final String role;
  final List<CrateSummary> crates;

  /// Where new items go on this device.
  final String? defaultCrateId;

  /// What this account may do in the Orchard itself (change_roles,
  /// create_crates, invite, remove), from the record.
  final Set<String> can;

  /// 'active', 'suspended', 'ended', 'rules' (held back by a rule the
  /// server checks), [kRecoveryWaitStatus] (this account started over
  /// with new keys and waits for two owners to give its access back),
  /// [kDeletingStatus] (the team is being deleted: see
  /// [deleting]) or [kDeletedStatus] (ZestSSH Cloud says it was deleted, at
  /// [deletedAt], and this device asks before it removes it).
  final String status;

  /// While the team is being deleted: who asked and the day it goes, as the
  /// server last listed it (kept after it was deleted, to name who asked).
  final TeamDeletion? deleting;

  /// When ZestSSH Cloud says the team was deleted ([kDeletedStatus]).
  final DateTime? deletedAt;

  /// The Orchard's rules, from its record as this device last read it.
  final RecordRules rules;

  /// The Admin role as an owner changed it (admin.set, 3.3.0); null while it
  /// is as every team starts: every vault that is not owners-only, at
  /// Manage, and everything in the team. See [adminSwitchesIn].
  final RecordAdminRole? adminRole;

  /// What the Admin role gives in [crate]: nothing in an owners-only vault;
  /// otherwise what an owner set, everything until one changes it.
  Set<String> adminSwitchesIn(CrateSummary crate) =>
      adminSwitches(adminRole, crateId: crate.id, ownersOnly: crate.ownersOnly);

  /// While [status] is 'rules': which rules the server says this account
  /// falls short of ('two_step', 'email_domain', 'reauth'), and the domains
  /// the address rule allows.
  final List<String> rulesUnmet;
  final List<String> ruleDomains;

  /// While this device is held back as not approved: it was approved
  /// once and someone took that back, and what it held of the Orchard is
  /// gone from it.
  final bool deviceRemoved;

  /// Held back, and only because this device is not approved: nothing
  /// the account could fix by signing in differently.
  bool get onlyDeviceHeld =>
      status == 'rules' && rulesUnmet.length == 1 && rulesUnmet.single == kTrustedDeviceRule;

  /// Closed on this device by its offline limit until the device reaches
  /// ZestSSH Cloud again: not opened, not shown, its hosts do not
  /// connect.
  final bool closedOffline;

  /// While it is open and its own offline limit is about to close all of
  /// it here (in the last quarter of the limit): the last second, since the
  /// epoch, at which it is still open. Null otherwise.
  final int? closesAt;

  /// While an offline pass an owner signed for all of it holds on this
  /// device: the last second, since the epoch, the pass holds. Null
  /// otherwise.
  final int? passUntil;

  /// Why this device stopped following the Orchard's record; null while all
  /// is well.
  final String? recordProblem;

  /// Someone lost access, so the Orchard's key waits to be replaced.
  final bool rotationDue;

  /// People who accepted an invitation and wait for this account to
  /// confirm them (those who may invite), as of the last sync.
  final int invitesWaiting;

  bool get isOwner => role == FixedRoles.owner;

  bool get canAddCrates => can.contains(RoleCan.createCrates);

  /// Invites people and confirms them.
  bool get canInvite => can.contains(RoleCan.invite);

  /// Syncs: an active member, and a record this device follows.
  bool get active => status == 'active' && recordProblem == null && !closedOffline;

  /// Keys wait to be replaced that this account may replace: the
  /// Orchard's own (owners and admins) or a Crate's it manages.
  bool get keysWaiting =>
      (rotationDue && (role == FixedRoles.owner || role == FixedRoles.admin)) ||
      crates.any((c) => c.rotationDue && c.allows(CrateSwitches.manage));

  /// A Crate this account writes in, whose key waits to be replaced, and whose
  /// key it may not replace itself: what it saves there can still be opened
  /// with the key someone who left holds, until someone who manages the Crate
  /// replaces it. Null for none. Said, and nothing more: connecting and saving
  /// go on.
  CrateSummary? get writesUnderWaitingKey => crates
      .where((c) => c.rotationDue && !c.allows(CrateSwitches.manage) && (c.allows(CrateSwitches.add) || c.allows(CrateSwitches.edit)))
      .firstOrNull;
}

Set<String> _jsonSet(String? json) {
  if (json == null) return const {};
  try {
    return {
      for (final s in jsonDecode(json) as List)
        if (s is String) s,
    };
  } catch (_) {
    return const {};
  }
}

/// Reads an Orchard's own database for the switcher.
///
/// While the server holds this account back by the Orchard's rules it
/// cannot read the record, so it cannot learn what changed there: the rules
/// are the record's as last read, held to at least the device rules the
/// server says are in force, and every Crate counts as one that asks again
/// before its secrets are shown or leave the device.
Future<OrchardSummary> readOrchardSummary(AppDatabase db, String orchardId,
    {int invitesWaiting = 0}) async {
  final info = await db
      .customSelect('SELECT name, role, default_crate_id, can, status, record_problem, rotation_due, rules, held '
          'FROM orchard_info WHERE id = 1')
      .getSingleOrNull();
  final crates = await db
      .customSelect('SELECT crate_id, name, level, switches, owners_only, allow, rotation_due, confirm_reveal '
          'FROM orchard_crates ORDER BY name, crate_id')
      .get();
  final held = _json(info?.read<String?>('held'));
  final status = info?.read<String>('status') ?? 'active';
  // Being deleted, or deleted.
  final deletion = status == kDeletingStatus || status == kDeletedStatus ? deletionHeldIn(held) : null;
  List<String> strings(Object? raw) => [
        if (raw is List)
          for (final s in raw)
            if (s is String) s,
      ];
  // Each Crate's own offline limit, from the record as this device has it,
  // and the Crates it has closed here (rules/crate_offline.dart).
  final record = await latestRecordIn(db);
  final limits = await crateLimitsIn(db);
  final closed = limits.closed;
  final rules = rulesInForce(_json(info?.read<String?>('rules')), held);
  // The Orchard's own limit about to close all of it here.
  final all = await orchardClosingAt(db, rules.offlineHours);
  // The offline passes that hold here now, by what each is for.
  final passes = await passesHoldingIn(db);
  final passForAll = passes[kAllOfOrchard];
  return OrchardSummary(
    id: orchardId,
    name: info?.read<String?>('name'),
    role: info?.read<String>('role') ?? '',
    defaultCrateId: info?.read<String?>('default_crate_id'),
    can: _jsonSet(info?.read<String>('can')),
    status: status,
    recordProblem: info?.read<String?>('record_problem'),
    rotationDue: (info?.read<int>('rotation_due') ?? 0) == 1,
    invitesWaiting: invitesWaiting,
    rules: rules,
    closesAt: all,
    passUntil: passForAll,
    adminRole: record?.adminRole,
    rulesUnmet: held is Map ? strings(held['unmet']) : const [],
    ruleDomains: held is Map ? strings(held['email_domains']) : const [],
    deviceRemoved: status == 'rules' && held is Map && held['device_removed'] == true,
    deleting: deletion?.deleting,
    deletedAt: status == kDeletedStatus ? deletion?.deletedAt : null,
    crates: [
      for (final c in crates)
        CrateSummary(
          id: c.read<String>('crate_id'),
          name: c.read<String?>('name'),
          level: c.read<String>('level'),
          // A Crate closed here allows nothing, whatever the record gives.
          switches:
              closed.containsKey(c.read<String>('crate_id')) ? const {} : _jsonSet(c.read<String>('switches')),
          ownersOnly: c.read<int>('owners_only') == 1,
          allow: _jsonSet(c.read<String>('allow')),
          rotationDue: c.read<int>('rotation_due') == 1,
          confirmReveal: status == 'rules' || c.read<int>('confirm_reveal') == 1,
          offlineHours: record?.crates[c.read<String>('crate_id')]?.offlineHours ?? 0,
          closedOffline: closed.containsKey(c.read<String>('crate_id')),
          // (No later than all of the Orchard closes, where that is sooner.)
          closesAt: switch (limits.closing[c.read<String>('crate_id')]) {
            final own? when all != null && all < own => all,
            final own => own,
          },
          // (Its own pass, or one for all of the Orchard: the longer.)
          passUntil: switch (passes[c.read<String>('crate_id')]) {
            final own? when passForAll != null && passForAll > own => passForAll,
            final own => own ?? passForAll,
          },
        ),
    ],
  );
}

/// [raw] decoded, or null when it is not JSON.
Object? _json(String? raw) {
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

/// The roles an Orchard's owners made, their names opened.
final orchardRolesProvider = FutureProvider.family<List<OrchardRoleView>, String>((ref, orchardId) {
  ref.watch(orchardListVersionProvider);
  return ref.read(orchardServiceProvider).roles(orchardId);
});

/// Bumped when the list of Orchards or their names may have changed: after
/// making one, a refresh, or a sync.
final orchardListVersionProvider = StateProvider<int>((ref) => 0);

/// "Offline pass from an owner" asked for where there is no screen to open
/// it from (the action of the notice that says an offline limit is about
/// to close something): for a Crate, or for all of an Orchard
/// (kAllOfOrchard). The app answers it over whatever screen is up
/// (answerPassAskRequests in widgets/cert_handover_dialogs.dart), and takes
/// it away as it does.
final passAskRequestProvider = StateProvider<({String orchardId, String crateId})?>((ref) => null);

/// This device's part in event export (3.0): it sends an Orchard's
/// events on when an owner set that up here.
final Provider<OrchardEventExporter> orchardEventExporterProvider = Provider<OrchardEventExporter>((ref) {
  // A new one for each account: nothing it holds for one (a key, an address)
  // stays for the next.
  ref.watch(currentUserProvider);
  return OrchardEventExporter(
    // (Asked for at each use, and not watched: the service asks this
    // exporter for what is left before a change ends the sending.)
    service: () => ref.read(orchardServiceProvider),
    settings: ExportSettingsStore(ref.watch(secureStorageProvider)),
    post: httpExportPost(),
    onChanged: () => ref.read(exportVersionProvider.notifier).state++,
  );
});

/// Moves whenever where event export stands may have changed on this
/// device: set up, turned off, events sent or not.
final exportVersionProvider = StateProvider<int>((ref) => 0);

/// Where event export stands in an Orchard, as this device sees it.
final exportStandingProvider = FutureProvider.autoDispose.family<ExportStanding, String>((ref, orchardId) {
  ref.watch(orchardListVersionProvider);
  ref.watch(exportVersionProvider);
  return ref.read(orchardEventExporterProvider).standing(orchardId);
});

/// Moves whenever the requests for access may have changed (3.0):
/// the live line said so, or this device made, answered or withdrew one.
/// Whatever lists them reads again.
final accessRequestsVersionProvider = StateProvider<int>((ref) => 0);

/// The requests for access in an Orchard that concern this account: its
/// own, and those of others it can answer.
final accessRequestsProvider =
    FutureProvider.autoDispose.family<AccessRequestViews, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  ref.watch(accessRequestsVersionProvider);
  return ref.read(orchardServiceProvider).accessRequests(orchardId);
});

/// Moves whenever the requests of devices to be approved may have changed
/// (3.0): the live line said so, or this device answered one.
final deviceRequestsVersionProvider = StateProvider<int>((ref) => 0);

/// The requests of devices in an Orchard that this account could answer
/// from this device.
final deviceRequestsProvider =
    FutureProvider.autoDispose.family<List<DeviceRequestView>, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  ref.watch(deviceRequestsVersionProvider);
  return ref.read(orchardServiceProvider).deviceRequests(orchardId);
});

/// Where an Orchard stands with approved devices, and this device in it.
final deviceStandingProvider = FutureProvider.autoDispose.family<DeviceStanding, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  return ref.read(orchardServiceProvider).deviceStanding(orchardId);
});

/// The devices an Orchard's record lists for a member.
final memberDevicesProvider =
    FutureProvider.autoDispose.family<List<MemberDevice>, ({String orchardId, String uid})>((ref, at) async {
  ref.watch(orchardListVersionProvider);
  return ref.read(orchardServiceProvider).memberDevices(at.orchardId, at.uid);
});

/// What members of an Orchard hold until a set time, soonest to end first.
final timedAccessProvider = FutureProvider.autoDispose.family<List<TimedAccess>, String>((ref, orchardId) async {
  ref.watch(orchardListVersionProvider);
  return ref.read(orchardServiceProvider).timedAccess(orchardId);
});

/// Team recovery in an Orchard (3.0) as this device can stand
/// behind it: on or off, and who waits (everyone, for an owner; this
/// account, otherwise). Read again whenever the Orchards change.
final teamRecoveryStatusProvider =
    FutureProvider.autoDispose.family<TeamRecoveryStatus, String>((ref, orchardId) {
  ref.watch(orchardListVersionProvider);
  return ref.read(orchardServiceProvider).teamRecovery(orchardId);
});

/// The Orchards on this device, read from their own databases so the
/// switcher works offline. Empty while locked or when Orchards are off.
final orchardSummariesProvider = FutureProvider<List<OrchardSummary>>((ref) async {
  if (!kOrchardsEnabled) return const [];
  ref.watch(orchardListVersionProvider);
  if (ref.watch(databaseSessionProvider) == null) return const [];
  final databases = ref.watch(orchardDatabasesProvider.notifier);
  final waiting = ref.read(orchardSyncProvider).service.invitesWaiting;
  final last = ref.read(_lastSummariesProvider);
  final out = <OrchardSummary>[];
  for (final id in await databases.onDevice()) {
    try {
      final summary = await readOrchardSummary(await databases.open(id), id, invitesWaiting: waiting[id] ?? 0);
      last[id] = summary;
      out.add(summary);
    } on OrchardClosedOffline {
      // Listed as closed, named as this device last knew it.
      out.add(OrchardSummary.closedOffline(id, last: last[id]));
    } catch (e) {
      AppLogger.warning('Orchards: an Orchard on this device did not open ($e)');
    }
  }
  out.sort((a, b) => (a.name ?? '').toLowerCase().compareTo((b.name ?? '').toLowerCase()));
  return out;
});

/// Each Orchard as it was last read on this device, for naming one the
/// offline limit closed.
final _lastSummariesProvider = Provider<Map<String, OrchardSummary>>((ref) {
  ref.watch(databaseSessionProvider);
  return {};
});

/// The invitations to this account's address, as the last Orchard
/// sync read them. A new sign-in starts over.
final myInvitesProvider = StateProvider<List<MyInvite>>((ref) {
  ref.watch(currentUserProvider);
  return const [];
});

/// The Orchard on screen, or null while the Tree is.
final activeOrchardProvider = Provider<AsyncValue<OrchardSummary?>>((ref) {
  final space = ref.watch(activeSpaceProvider);
  if (space is! OrchardSpace) return const AsyncData(null);
  return ref.watch(orchardSummariesProvider).whenData(
      (list) => list.where((o) => o.id == space.orchardId).firstOrNull);
});

// ── Crates in the host list ─────────────────────────────────────────────

/// Crate bookkeeping for the Orchard on screen; null while the Tree is.
final cratePlacementProvider = Provider<CratePlacement?>((ref) {
  if (ref.watch(activeSpaceProvider) is! OrchardSpace) return null;
  return CratePlacement(ref.watch(databaseProvider));
});

/// Each host's Crate in the Orchard on screen, by connection id. A host not
/// placed yet is in the Crate new items go to ([OrchardSummary.defaultCrateId]).
final hostCratesProvider = StreamProvider<Map<String, String>>((ref) {
  final placement = ref.watch(cratePlacementProvider);
  if (placement == null) return Stream.value(const {});
  return placement.watchHostCrates();
});

/// Each item of a kind ('host', 'key', 'snippet', ...) with its Crate in
/// the Orchard on screen, by item key. An item not placed yet is in the
/// Crate new items go to. Empty while the Tree is on screen.
final itemCratesProvider = StreamProvider.family<Map<String, String>, String>((ref, kind) {
  final placement = ref.watch(cratePlacementProvider);
  if (placement == null) return Stream.value(const {});
  return placement.watchCrates(kind);
});

/// The Crate the host list shows; null shows every Crate. Starts over when
/// the space changes.
final selectedCrateFilterProvider = StateProvider<String?>((ref) {
  ref.watch(activeSpaceProvider);
  return null;
});

// ── Keeping Orchards in sync ────────────────────────────────────────────

/// Syncs the Orchards while the app is unlocked: at unlock, every fifteen
/// minutes, and a few seconds after a change on this device. A change is
/// noticed through the Orchard's item tables, and a sync runs only if
/// something is queued, so what a sync writes never starts another.
final orchardSyncSchedulerProvider =
    Provider<OrchardSyncScheduler>((ref) => OrchardSyncScheduler(ref));

/// The device's network changing (debounced), watched afresh on each call.
final orchardNetworkChangesProvider =
    Provider<Stream<ConnectivityKind> Function()>((ref) => watchConnectivityChanges);

/// The live line to ZestSSH Cloud (3.0), over the same pinned TLS
/// as every other request. [OrchardSyncScheduler] keeps it open while the
/// app is unlocked and the account is in an Orchard.
final orchardStreamProvider = Provider<OrchardStream>((ref) {
  final storage = ref.watch(secureStorageProvider);
  final stream = OrchardStream(
    url: OrchardStream.urlFor(OrchardsApi.defaultBase),
    connect: (url) =>
        WebSocket.connect(url.toString(), customClient: PinnedHttpClient.newHttpClient()),
    token: ({bool fresh = false}) async =>
        await AuthService.getIdToken(forceRefresh: fresh) ??
        await AccountSecret.sessionToken.read(storage),
    session: () => DeviceSessionHeader.current,
  );
  ref.onDispose(() => unawaited(stream.dispose()));
  return stream;
});

/// When this account last really signed in (seconds since the epoch), or null
/// where that cannot be told: a phone's from Firebase, a computer's from its
/// session token. Tests stand in.
final accountSignedInAtProvider = Provider<Future<int?> Function()>((ref) => () async {
      final user = AuthService.currentUser;
      if (user != null) {
        try {
          final at = (await user.getIdTokenResult()).authTime;
          return at == null ? null : at.millisecondsSinceEpoch ~/ 1000;
        } catch (_) {
          return null;
        }
      }
      final token = await AccountSecret.sessionToken.read(ref.read(secureStorageProvider));
      return token == null ? null : sessionTokenSignedInAt(token);
    });

/// The later of [accountSignedInAtProvider] and a passkey's confirmation on this
/// device, which meets a team's Sign-in lasts as well.
final accountConfirmedAtProvider = Provider<Future<int?> Function()>((ref) => () async {
      final signedIn = await ref.read(accountSignedInAtProvider)();
      final tapped = ref.read(settingsServiceProvider).stepUpAt;
      if (signedIn == null || tapped == null) return signedIn ?? tapped;
      return signedIn > tapped ? signedIn : tapped;
    });

/// Asks for a new sign-in where the person is, from the notice that a team's
/// Sign-in lasts is about to run out: the app has a screen to do it from. [n]
/// counts the asks; [signInOnly]: that team requires company sign-in.
final reauthSignInRequestProvider = StateProvider<({int n, bool signInOnly})>((_) => (n: 0, signInOnly: false));

class OrchardSyncScheduler {
  OrchardSyncScheduler(this._ref) {
    _ref.onDispose(stop);
  }

  /// Says when a team's Sign-in lasts is about to run out.
  late final _reauthWatch = ReauthWatch(
    signedInAt: () => _ref.read(accountSignedInAtProvider)(),
    confirmedAt: () => _ref.read(accountConfirmedAtProvider)(),
    tell: (team, ends) => _ref.read(notificationCenterProvider.notifier).show(reauthSoonNotice(
          orchardId: team.id,
          team: orchardDisplayName(team.name, gl10n),
          windowSeconds: team.seconds,
          ends: ends,
          l10n: gl10n,
          // (A notice can stay on screen longer than this account is signed in.)
          onSignIn: () {
            if (_stopped) return;
            final asked = _ref.read(reauthSignInRequestProvider.notifier);
            asked.state = (n: asked.state.n + 1, signInOnly: team.signInOnly);
          },
        )),
    takeDown: (id) => _ref.read(notificationCenterProvider.notifier).remove(reauthSoonNoticeId(id)),
  );

  static const interval = Duration(minutes: 15);
  static const settle = Duration(seconds: 3);

  /// Word from the live line that arrives together is one sync.
  static const nudgeSettle = Duration(seconds: 1);

  /// How often the offline limits are checked.
  static const clockTick = Duration(minutes: 1);

  /// How often the device that sends an Orchard's events on looks for
  /// new ones, besides after each sync. (A test makes it shorter.)
  @visibleForTesting
  static Duration exportTick = const Duration(minutes: 1);

  /// How often an account in no Orchard reads its invitations (only those,
  /// not a sync): the live line is closed then, so the word the server
  /// sends the moment someone invites it reaches nobody. (A test makes it
  /// shorter.)
  @visibleForTesting
  static Duration invitesTick = const Duration(minutes: 2);

  /// The app coming to the front reads the invitations at most this often
  /// ([foregrounded]): a window gains focus with every switch back to it.
  static const foregroundGap = Duration(seconds: 20);

  final Ref _ref;
  Timer? _periodic;
  Timer? _clock;
  Timer? _export;
  Timer? _invites;
  DateTime? _lastForeground;
  bool _readingInvites = false;

  /// One telling of new invitations at a time, so that two reads at once
  /// never tell the same one twice.
  Future<void> _telling = Future<void>.value();
  ProviderSubscription<bool>? _lockSetting;
  ProviderSubscription<AsyncValue<int>>? _lockTimeout;
  ProviderSubscription<Map<String, AppDatabase>>? _openDatabases;
  ProviderSubscription<AppDatabase?>? _unlocked;
  StreamSubscription<ConnectivityKind>? _networkChanges;
  ConnectivityKind? _network;

  /// The last sync could not finish (offline, most often): the network
  /// coming back syncs at once, for the changes made meanwhile.
  bool _unfinished = false;

  /// The app's knowledge of how ZestSSH Cloud stands, while this listens to
  /// it for outages that were proven ([outageProven]).
  CloudReachService? _reach;

  /// The rules each Orchard was under when its offline limit closed it here.
  /// A closed Orchard is not read, so this is all that is known of its limit
  /// while it is closed, and the only thing it is ever opened again by short
  /// of the device reaching ZestSSH Cloud.
  final _closedByLimit = <String, RecordRules>{};

  /// The Crates each Orchard had closed on this device by their own offline
  /// limits when that was last looked at. Whether a Crate is closed is
  /// worked out afresh by whoever asks (rules/crate_offline.dart); this is
  /// only how the screens come to hear that it changed.
  final _closedCrates = <String, Set<String>>{};

  /// Whether, as of the last look, a Crate of some Orchard was closed here
  /// by its own offline limit.
  bool get cratesClosedHere => _closedCrates.values.any((c) => c.isNotEmpty);

  /// What was about to close in each Orchard at the last look: the Orchard
  /// itself ('', by its own limit) and Crates (by id), each with the last
  /// second it is open. For telling the lists, which show when, each time
  /// that changes.
  final _closingSoon = <String, Map<String, int>>{};

  /// What this device's person has been told is about to close, by Orchard:
  /// each item with the end it was told with. Said again when that is no
  /// longer what stands: in a new stretch away, with an item more or less,
  /// and when an end has moved.
  final _toldClosing = <String, Map<String, int>>{};

  /// Whether, as of the last look, something was about to close here.
  bool get closingSoonHere => _closingSoon.values.any((c) => c.isNotEmpty);
  final _watched = <String, (AppDatabase, StreamSubscription<void>)>{};
  final _pending = <String, Timer>{};
  bool _syncingAll = false;
  bool _syncAgain = false;
  OrchardStream? _stream;
  StreamSubscription<OrchardStreamEvent>? _streamEvents;
  Timer? _nudge;
  final _nudgedOrchards = <String>{};
  bool _nudgedAll = false;

  /// Fires when what this account may do next becomes less by itself (what
  /// it was given until a set time, or its time in an Orchard): the
  /// Orchards are brought up to date at that moment, not at the next round.
  Timer? _accessEnd;

  /// An end further away than this is left to a later sync to set.
  static const accessEndHorizon = Duration(days: 1);

  /// Whether such a moment is set now.
  @visibleForTesting
  bool get watchesAccessEnd => _accessEnd != null;

  /// Stopped (disposed, or locked until the next start): a sync already on
  /// its way finishes its current step and then touches nothing, since the
  /// providers it would read may be gone.
  bool _stopped = false;

  /// Starts (or restarts, after an unlock) and syncs everything now.
  void start() {
    if (!kOrchardsEnabled) return;
    _stopped = false;
    _periodic?.cancel();
    // A round by itself waits while macOS's no to a saved key stands (3.3.2):
    // each could bring its question up again; the person's Try again ends it.
    _periodic = Timer.periodic(interval, (_) {
      if (!keychainWaitsForPerson) unawaited(syncAll());
    });
    _openDatabases ??= _ref.listen<Map<String, AppDatabase>>(
      orchardDatabasesProvider,
      (_, open) => _watch(open),
      fireImmediately: true,
    );
    // Locking closes every database, and the live line with them.
    _unlocked ??= _ref.listen<AppDatabase?>(databaseSessionProvider, (_, db) {
      if (db == null) _closeStream();
    });
    _networkChanges ??= _ref.read(orchardNetworkChangesProvider)().listen(
      _networkChanged,
      onError: (Object _) {/* no word on the network: the 15 minute runs remain */},
    );
    // An Orchard held back by this device's app lock syncs once it is fixed.
    //
    _lockSetting ??= _ref.listen<bool>(securityLockEnabledProvider, (_, _) => unawaited(syncAll()));
    _lockTimeout ??= _ref.listen<AsyncValue<int>>(autoLockTimeoutProvider, (before, now) {
      // A change, not the first read of it.
      final was = before?.valueOrNull;
      if (was != null && now.hasValue && now.value != was) unawaited(syncAll());
    });
    // An outage of ZestSSH Cloud's own that its status service proved does
    // not count towards an offline limit, for as long as its proof may be
    // believed, and no longer once the service is known to be up.
    if (_reach == null) {
      final reach = _ref.read(cloudReachProvider);
      _reach = reach;
      reach.addOutageListener(_onOutageProven);
      reach.state.addListener(_onReachChanged);
    }
    _clock?.cancel();
    _clock = Timer.periodic(clockTick, (_) {
      if (!keychainWaitsForPerson) unawaited(checkOfflineLimits());
    });
    _export?.cancel();
    _export = Timer.periodic(exportTick, (_) {
      if (!keychainWaitsForPerson) unawaited(exportRounds());
    });
    _invites?.cancel();
    _invites = Timer.periodic(invitesTick, (_) {
      if (!keychainWaitsForPerson) unawaited(checkInvites());
    });
    unawaited(checkOfflineLimits());
    unawaited(syncAll());
  }

  /// Sends on what the Orchards this device sends for have that is new
  /// (event export). Nothing where it sends for none.
  Future<void> exportRounds() async {
    if (_stopped || _ref.read(databaseSessionProvider) == null) return;
    await _ref.read(orchardEventExporterProvider).rounds();
  }

  /// Directory groups become roles (3.3.0): for each team this account owns
  /// where an owner turned that on, the roles its new or renamed groups need,
  /// made here (only an owner signs a role into the record; ZestSSH Cloud
  /// nudges the owners' devices when a group arrives or is renamed). A
  /// sign-in too old for role changes, or ZestSSH Cloud out of reach, leaves
  /// them for the Directory sync page's Make them now.
  Future<void> _makeDirectoryRoles() async {
    if (_stopped || _ref.read(databaseSessionProvider) == null) return;
    final List<OrchardSummary> summaries;
    try {
      summaries = await _summariesNow();
    } catch (_) {
      return;
    }
    for (final o in summaries) {
      if (_stopped) return;
      if (!o.isOwner || !o.active) continue;
      try {
        final api = _ref.read(orchardDirectoryApiProvider);
        final directory = await api.get(o.id);
        if (!directoryRolesWanted(directory)) continue;
        final done = await makeDirectoryRoles(_ref.read(orchardServiceProvider), api, o.id, directory);
        if (done.made + done.renamed > 0) {
          AppLogger.info('Orchards: ${done.made} role(s) made and ${done.renamed} renamed for directory groups');
        }
      } catch (e) {
        // Said once a run per team at most, without what the groups are.
        AppLogger.info('Orchards: roles for directory groups wait (${errorKind(e)})');
      }
    }
  }

  /// The Orchards on this device, as whatever lists them has them, read
  /// while listening to the list. A list that is told to look again while
  /// it is being read (a sync that has just ended tells it) is read anew
  /// only for someone who listens to it: merely asked, it would leave this
  /// waiting for the next one who asks, a screen that shows the Orchards or
  /// the look a minute on, and an Orchard past its limit open for as long.
  Future<List<OrchardSummary>> _summariesNow() async {
    final listening = _ref.listen<AsyncValue<List<OrchardSummary>>>(orchardSummariesProvider, (_, _) {});
    try {
      return await _ref.read(orchardSummariesProvider.future);
    } finally {
      listening.close();
    }
  }

  /// Closes each Orchard past its offline limit on this device: not
  /// opened, not shown, its hosts do not connect, until this device reaches
  /// ZestSSH Cloud again (which the next sync does, when it can).
  ///
  /// And opens again one that the limit closed and that is no longer past
  /// it: that happens when an outage of ZestSSH Cloud's own was proven after
  /// the Orchard closed ([outageProven]), which is the case of a device
  /// started in the middle of an outage. Only by the rules it was closed
  /// under: one whose rules this run does not know stays closed until the
  /// device reaches ZestSSH Cloud.
  Future<void> checkOfflineLimits() async {
    if (_stopped || _ref.read(databaseSessionProvider) == null) return;
    try {
      final contact = _ref.read(orchardContactProvider.notifier);
      await contact.loaded;
      await contact.sawTime();
      final summaries = await _summariesNow();
      if (_stopped) return;
      final databases = _ref.read(orchardDatabasesProvider.notifier);
      var changed = false;
      for (final o in summaries) {
        if (o.closedOffline) {
          final under = _closedByLimit[o.id];
          if (under == null || offlineLimitReached(under, _ref.read(orchardContactProvider), contact.now())) continue;
          _closedByLimit.remove(o.id);
          if (databases.reopenOne(o.id)) {
            AppLogger.info('Orchards: an Orchard closed by its offline limit opened again: the time ZestSSH Cloud '
                'itself was down does not count');
            changed = true;
          }
          continue;
        }
        // Past its limit, it still stays open while an offline pass holds
        // that an owner signed for all of it on this device. Asked before
        // the limit is measured for good, so that nothing is waited for
        // between measuring and closing.
        final open = _ref.read(orchardDatabasesProvider)[o.id];
        final held = open != null &&
            offlineLimitReached(o.rules, _ref.read(orchardContactProvider), contact.now()) &&
            await orchardPassHoldsIn(open);
        if (_stopped) return;
        // Read at the last moment: a sync that reached ZestSSH Cloud
        // meanwhile has measured the limit afresh.
        if (held || !offlineLimitReached(o.rules, _ref.read(orchardContactProvider), contact.now())) {
          // The Orchard stays open: which of its Crates their own limits
          // have closed, so that the screens hear of one closing or
          // opening.
          // (Closed under us, by the app locking: nothing to look at.)
          if (open == null) continue;
          final limits = await crateLimitsIn(open);
          // What is about to close, the Orchard itself or Crates of it: the
          // lists hear of a change, and the person is told (once, and not
          // in the moment before the first sync: [_tellClosing]).
          final near = closingSoon(await orchardClosingAt(open, o.rules.offlineHours), limits.closing);
          if (_stopped) return;
          if (!mapEquals(near, _closingSoon[o.id] ?? const <String, int>{})) changed = true;
          _tellClosing(o, near, closed: limits.closed.keys.toSet());
          final now = limits.closed.keys.toSet();
          if (!setEquals(now, _closedCrates[o.id] ?? const <String>{})) {
            AppLogger.info('Orchards: ${now.length} of an Orchard\'s Crates are closed on this device by their own '
                'offline limits, which is not what it was');
            _closedCrates[o.id] = now;
            changed = true;
          }
          continue;
        }
        AppLogger.info('Orchards: an Orchard reached its offline limit and closed until this device is back online');
        _closedByLimit[o.id] = o.rules;
        // Closed, it is no longer about to close.
        _tellClosing(o, const {});
        await databases.closeOffline(o.id);
        changed = true;
      }
      // An Orchard that is no longer on this device (the account left it,
      // or was removed from it): nothing of it is about to close here.
      for (final id in {..._closingSoon.keys, ..._toldClosing.keys}) {
        if (!summaries.any((o) => o.id == id)) _nothingClosing(id);
      }
      await _reauthWatch.check([
        for (final o in summaries)
          if (!o.closedOffline)
            (id: o.id, name: o.name ?? '', seconds: o.rules.reauthSeconds, signInOnly: o.rules.requireSso),
      ]);
      if (_stopped) return;
      if (changed && !_stopped) _ref.read(orchardListVersionProvider.notifier).state++;
    } catch (e) {
      AppLogger.warning('Orchards: the offline limits could not be checked ($e)');
    }
  }

  /// Says what is about to close in the Orchard [o] on this device ([near]:
  /// the Orchard itself as '', a Crate by its id, each with the last second
  /// it is open), where that is news: once for what is about to close and
  /// when, in each stretch the device is away. Only while the last sync
  /// could not finish: a device that is online reaches ZestSSH Cloud within
  /// moments of starting, and nothing is about to close then. With nothing
  /// about to close any more (the device is back in contact, or an outage
  /// of ZestSSH Cloud's own was proven and the limits stand still), the
  /// notice is taken down.
  ///
  /// The notice offers an offline pass, the way on where there is no
  /// internet to connect to: for the one Crate that is about to close, or
  /// for all of the Orchard where more than that is at stake ([closed]:
  /// the Crates closed here already).
  void _tellClosing(OrchardSummary o, Map<String, int> near, {Set<String> closed = const {}}) {
    if (near.isEmpty) return _nothingClosing(o.id);
    _closingSoon[o.id] = near;
    final last = _ref.read(orchardContactProvider).lastContact;
    if (!_unfinished || last == null) return;
    // Said already, of exactly these with exactly these ends: nothing new.
    // (One of them closing meanwhile is news: what is still to come is
    // said again without it.)
    if (mapEquals(_toldClosing[o.id], near)) return;
    _toldClosing[o.id] = near;
    final l10n = gl10n;
    final names = {for (final c in o.crates) c.id: crateDisplayName(c, l10n)};
    final ask = (orchardId: o.id, crateId: passToAskFor(near, closed));
    _ref.read(notificationCenterProvider.notifier).show(offlineClosingNotice(
      orchardId: o.id,
      orchard: orchardDisplayName(o.name, l10n),
      all: near[''],
      crates: [
        for (final MapEntry(key: id, value: end) in near.entries)
          if (id.isNotEmpty) (name: names[id] ?? l10n.crateUnnamed, end: end),
      ],
      lastContact: last,
      reach: _ref.read(cloudReachProvider).state.value.reach,
      l10n: l10n,
      // (A notice can stay on screen longer than this account is signed
      // in: once this is stopped it asks for nothing.)
      onAskPass: () {
        if (!_stopped) _ref.read(passAskRequestProvider.notifier).state = ask;
      },
    ));
  }

  /// Nothing of the Orchard [orchardId] is about to close on this device
  /// (any more): what was said of it is taken down.
  void _nothingClosing(String orchardId) {
    _closingSoon.remove(orchardId);
    if (_toldClosing.remove(orchardId) == null) return;
    _ref.read(notificationCenterProvider.notifier).remove(offlineClosingNoticeId(orchardId));
  }

  /// ZestSSH Cloud itself was down from [since] to [at] (seconds since the
  /// epoch): its status service said so, signed, and the app believed it
  /// (lib/services/cloud/cloud_reach.dart). That time does not count towards
  /// an offline limit, and an Orchard the limit had closed for it opens
  /// again. Nor does the time that passes until [until], up to which the
  /// statement says it may be believed: the app asks again before then, and
  /// a limit must not run between one proof and the next.
  Future<void> outageProven({required int since, required int at, int? until}) async {
    if (_stopped) return;
    try {
      final added = await _ref.read(orchardContactProvider.notifier).excuse(since: since, at: at, until: until);
      if (added) await checkOfflineLimits();
    } catch (e) {
      AppLogger.warning('Orchards: a proven outage could not be taken in ($e)');
    }
  }

  void _onOutageProven(CloudStatement proof) =>
      unawaited(outageProven(since: proof.since, at: proof.at, until: proof.until));

  /// The outage that was proven is over: ZestSSH Cloud answers again, or
  /// its status service says that it is up (and this device is what cannot
  /// reach it). Its last proof is believed no further, so the limits run
  /// from this moment.
  Future<void> outageOver() async {
    if (_stopped) return;
    try {
      final ended = await _ref.read(orchardContactProvider.notifier).outageOver();
      if (ended) await checkOfflineLimits();
    } catch (e) {
      AppLogger.warning('Orchards: the end of a proven outage could not be taken in ($e)');
    }
  }

  void _onReachChanged() {
    final reach = _reach?.state.value.reach;
    if (reach == CloudReach.answering || reach == CloudReach.blocked) unawaited(outageOver());
  }

  void stop() {
    _stopped = true;
    _reauthWatch.forget();
    _reach?.removeOutageListener(_onOutageProven);
    _reach?.state.removeListener(_onReachChanged);
    _reach = null;
    _periodic?.cancel();
    _periodic = null;
    _clock?.cancel();
    _clock = null;
    _export?.cancel();
    _export = null;
    _invites?.cancel();
    _invites = null;
    _lockSetting?.close();
    _lockSetting = null;
    _lockTimeout?.close();
    _lockTimeout = null;
    _openDatabases?.close();
    _openDatabases = null;
    _unlocked?.close();
    _unlocked = null;
    unawaited(_networkChanges?.cancel());
    _networkChanges = null;
    for (final (_, sub) in _watched.values) {
      unawaited(sub.cancel());
    }
    _watched.clear();
    for (final t in _pending.values) {
      t.cancel();
    }
    _pending.clear();
    _accessEnd?.cancel();
    _accessEnd = null;
    _closeStream();
  }

  /// Refreshes the list and keys, then syncs every Orchard, and keeps the
  /// live line open while the account is in one. Quietly does nothing while
  /// signed out, offline, or before the account's keys are on this device.
  /// Asked again while it runs, it runs once more after.
  Future<void> syncAll() async {
    if (_stopped || _ref.read(databaseSessionProvider) == null) return;
    if (_syncingAll) {
      _syncAgain = true;
      return;
    }
    _syncingAll = true;
    try {
      var inOrchards = false;
      do {
        _syncAgain = false;
        final reports = await _ref.read(orchardSyncProvider).syncAll();
        if (_stopped) return;
        _ref.read(orchardSeatsShortProvider.notifier).state = {
          for (final MapEntry(key: id, value: report) in reports.entries)
            if (report.seatsNeeded) id,
        };
        _ref.read(orchardVaultsFullProvider.notifier).state = {
          for (final MapEntry(key: id, value: report) in reports.entries)
            if (report.seatsNeeded && report.vaultsFull) id,
        };
        // In an Orchard: one that syncs, or one that holds this account or
        // this device back for now (the line says when that is over).
        inOrchards = reports.isNotEmpty || _ref.read(orchardServiceProvider).standing.containsValue('rules');
        if (inOrchards) _openStream();
      } while (_syncAgain && !_stopped && _ref.read(databaseSessionProvider) != null);
      _unfinished = false;
      // The line also stays open while an accepted invitation waits, so the
      // Orchard arrives the moment someone confirms it.
      final waiting = await _refreshInvites();
      if (_stopped) return;
      if (inOrchards || waiting) {
        _openStream();
      } else {
        _closeStream();
      }
      // A key replacement whose follow-up was cut off carries on (nothing to
      // do, and quick, when there was none).
      final left = await _ref.read(keyReplacementProvider).finish();
      if (left.isNotEmpty) AppLogger.info('Orchards: key replacement still to finish: $left');
      await _tellTeamNotices();
      await _tellAccessNotices();
      await _tellDeviceNotices();
      await _tellTeamSync();
      await _scheduleAccessEnd();
      await exportRounds();
      await _makeDirectoryRoles();
    } on AccountKeysNotReady {
      // Not yet: the next run asks again. Invitations show meanwhile (to
      // accept one, the keys must be here).
      await _refreshInvites();
    } catch (e) {
      _unfinished = true;
      AppLogger.warning('Orchards: sync did not finish ($e)');
      // What an offline limit is about to close is said now, not at the
      // next look a minute on.
      unawaited(checkOfflineLimits());
      // What this account held until a set time ends on this device all
      // the same, by its clock: its person is told, and the next end is
      // waited for.
      await _endAccessHere();
    } finally {
      // Asked again after the Orchards were synced, while this run was at
      // what follows (invitations, notices, exports): that asks for another
      // run, and gets one. (It was dropped: the loop above had ended, and
      // what was asked for waited for the next round, a quarter of an hour.)
      final again = _syncAgain;
      _syncingAll = false;
      _syncAgain = false;
      if (!_stopped) {
        _ref.read(orchardListVersionProvider.notifier).state++;
        if (again) unawaited(syncAll());
      }
    }
  }

  /// Tells this device's person, in every Orchard it follows, of team
  /// recovery turned on or off and of each recovery since the last sync
  /// (3.0): every member hears of them.
  Future<void> _tellTeamNotices() async {
    final service = _ref.read(orchardServiceProvider);
    final databases = <String, AppDatabase>{};
    for (final orchardId in await service.databases.onDevice()) {
      try {
        databases[orchardId] = await service.databases.open(orchardId);
      } catch (e) {
        AppLogger.info('Orchards: an Orchard could not be opened to see what changed ($e)');
      }
    }
    final l10n = gl10n;
    final notifications = await takeTeamNotifications(
      databases,
      me: (await service.currentAuthor())?.uid,
      l10n: l10n,
      orchardName: (name) => orchardDisplayName(name, l10n),
    );
    if (_stopped) return;
    for (final n in notifications) {
      _ref.read(notificationCenterProvider.notifier).show(n);
    }
  }

  /// Tells this device's person what is new about access on request (3.0)
  /// in every Orchard whose membership counts: someone asks for
  /// access this account could give, its own request was declined or lapsed,
  /// or what it was given until a set time is over. Each once. An Orchard
  /// that cannot be asked keeps nothing from the rest.
  Future<void> _tellAccessNotices() async {
    final service = _ref.read(orchardServiceProvider);
    final l10n = gl10n;
    for (final MapEntry(key: orchardId, value: standing) in service.standing.entries.toList()) {
      if (_stopped) return;
      if (standing != 'active') continue;
      try {
        AccessRequestViews? requests;
        try {
          requests = await service.accessRequests(orchardId);
        } catch (e) {
          // Offline, or held back by the rules: what ended is still told.
          AppLogger.info('Orchards: requests for access could not be read ($e)');
        }
        final notices = await service.takeAccessNotices(orchardId, requests: requests);
        if (notices.isEmpty || _stopped) continue;
        final db = await service.databases.open(orchardId);
        final emails = {
          for (final r in await db.customSelect('SELECT uid, email FROM member_keys').get())
            r.read<String>('uid'): r.read<String?>('email'),
        };
        final info = await db.customSelect('SELECT name FROM orchard_info WHERE id = 1').getSingleOrNull();
        if (_stopped) return;
        for (final n in notices) {
          _ref.read(notificationCenterProvider.notifier).show(accessNoticeNotification(
                n,
                orchardId: orchardId,
                orchard: orchardDisplayName(info?.read<String?>('name'), l10n),
                nameOf: (uid) => uid == null ? '' : emails[uid] ?? uid,
                l10n: l10n,
              ));
        }
      } catch (e) {
        AppLogger.info('Orchards: what is new about access could not be read ($e)');
      }
    }
  }

  /// Sets the moment the Orchards are next brought up to date by
  /// themselves: when what this account may do becomes less ([_accessEnd]).
  Future<void> _scheduleAccessEnd() async {
    _accessEnd?.cancel();
    _accessEnd = null;
    if (_stopped) return;
    final Duration? wait;
    try {
      wait = await _ref.read(orchardServiceProvider).timeToNextAccessEnd();
    } catch (e) {
      AppLogger.info('Orchards: when access ends could not be read ($e)');
      return;
    }
    if (wait == null || wait > accessEndHorizon || _stopped) return;
    // A second past it, so the server's clock has passed it too.
    _accessEnd = Timer(wait + const Duration(seconds: 1), () {
      _accessEnd = null;
      unawaited(syncAll());
    });
  }

  /// A sync did not get through, so nothing brought the Orchards up to
  /// date: what this account held until a set time that has come ends on
  /// this device by its clock (3.0, the outage work), its person is told of
  /// what ended, and the next end is waited for.
  Future<void> _endAccessHere() async {
    if (_stopped || _ref.read(databaseSessionProvider) == null) return;
    try {
      final service = _ref.read(orchardServiceProvider);
      final ended = await service.endAccessByClock();
      if (_stopped) return;
      for (final orchardId in ended) {
        await _tellAccessOver(service, orchardId);
      }
      await _scheduleAccessEnd();
    } catch (e) {
      AppLogger.info('Orchards: what ended by itself could not be seen to ($e)');
    }
  }

  /// Tells of what this account held until a set time in [orchardId] that
  /// is over, as the device itself knows it (no word from the server).
  Future<void> _tellAccessOver(OrchardService service, String orchardId) async {
    final notices = await service.takeAccessNotices(orchardId);
    if (notices.isEmpty || _stopped) return;
    final db = service.databases.opened(orchardId);
    final info = await db?.customSelect('SELECT name FROM orchard_info WHERE id = 1').getSingleOrNull();
    if (_stopped) return;
    final l10n = gl10n;
    for (final n in notices) {
      _ref.read(notificationCenterProvider.notifier).show(accessNoticeNotification(
            n,
            orchardId: orchardId,
            orchard: orchardDisplayName(info?.read<String?>('name'), l10n),
            nameOf: (uid) => uid ?? '',
            l10n: l10n,
          ));
    }
  }

  /// The live line said a device request moved: whatever lists them
  /// reads again, and a new one is told.
  Future<void> _devicesChanged() async {
    if (_stopped || _ref.read(databaseSessionProvider) == null) return;
    _ref.read(deviceRequestsVersionProvider.notifier).state++;
    try {
      await _tellDeviceNotices();
    } on AccountKeysNotReady {
      // Told once the keys are here.
    }
  }

  /// Tells this device's person what is new about devices (3.0):
  /// that this device was removed from an Orchard, and each device that
  /// asks to be approved and that this account could approve from here.
  /// Each once.
  /// Once per account on this device: where a team's seat gave this account
  /// ZestSSH Cloud sync (with Squeezed, while it is in a paid team) and sync
  /// is off here, a notice says so, with Set up sync. That is a member who
  /// joined, or seats an owner bought on the website, after the team was
  /// made or joined with sync off (keys made on the device).
  Future<void> _tellTeamSync() async {
    try {
      final uid = _ref.read(currentUserProvider)?.uid;
      if (uid == null) return;
      final prefs = _ref.read(sharedPreferencesProvider);
      if (prefs.getBool(teamSyncToldKey(uid)) == true) return;
      if (!_ref.read(orchardServiceProvider).standing.values.contains('active')) return;
      if (await _ref.read(syncSetupStateServiceProvider).isSyncActive()) return;
      final web = await _teamEntitlement();
      if (web != true || _stopped) return;
      await prefs.setBool(teamSyncToldKey(uid), true);
      _ref.read(notificationCenterProvider.notifier).show(teamSyncNotification(gl10n, uid, () {
        final context = _ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
        if (context != null && context.mounted) _ref.read(accountPageOpenerProvider)(context);
      }));
    } catch (e) {
      AppLogger.info('Orchards: whether the team gives sync could not be told ($e)');
    }
  }

  /// Whether ZestSSH Cloud says this account has Squeezed and Juiced from a
  /// paid team (null: it could not say). Tests stand in.
  Future<bool?> _teamEntitlement() async => (await teamEntitlementAsk())?.team;

  Future<void> _tellDeviceNotices() async {
    final service = _ref.read(orchardServiceProvider);
    final l10n = gl10n;
    for (final MapEntry(key: orchardId, value: standing) in service.standing.entries.toList()) {
      if (_stopped) return;
      try {
        List<DeviceRequestView>? requests;
        if (standing == 'active') {
          try {
            requests = await service.deviceRequests(orchardId);
          } catch (e) {
            AppLogger.info('Orchards: device requests could not be read ($e)');
          }
        }
        final notices = await service.takeDeviceNotices(orchardId, requests: requests ?? const []);
        if (notices.isEmpty || _stopped) continue;
        final db = await service.databases.open(orchardId);
        final emails = {
          for (final r in await db.customSelect('SELECT uid, email FROM member_keys').get())
            r.read<String>('uid'): r.read<String?>('email'),
        };
        final info = await db.customSelect('SELECT name FROM orchard_info WHERE id = 1').getSingleOrNull();
        if (_stopped) return;
        for (final n in notices) {
          _ref.read(notificationCenterProvider.notifier).show(deviceNoticeNotification(
                n,
                orchardId: orchardId,
                orchard: orchardDisplayName(n.orchardName ?? info?.read<String?>('name'), l10n),
                nameOf: (uid) => uid == null ? '' : emails[uid] ?? uid,
                l10n: l10n,
              ));
        }
      } catch (e) {
        AppLogger.info('Orchards: what is new about devices could not be told ($e)');
      }
    }
  }

  /// The live line said a request for access moved: whatever lists
  /// them reads again, and what is new is told.
  Future<void> _accessChanged() async {
    if (_stopped || _ref.read(databaseSessionProvider) == null) return;
    _ref.read(accessRequestsVersionProvider.notifier).state++;
    try {
      await _tellAccessNotices();
    } on AccountKeysNotReady {
      // Told once the keys are here.
    }
  }

  /// Reads the invitations to this account's address. Returns whether
  /// one it accepted waits for a confirmation. A failure keeps the last
  /// list.
  Future<bool> _refreshInvites() async {
    if (_stopped) return false;
    try {
      final invites = await _ref.read(orchardSyncProvider).service.myInvites();
      if (_stopped) return false;
      _ref.read(myInvitesProvider.notifier).state = invites;
      await _tellNewInvites(invites);
      return invites.any((i) => i.accepted);
    } catch (e) {
      if (_stopped) return false;
      AppLogger.info('Orchards: invitations could not be read ($e)');
      return _ref.read(myInvitesProvider).any((i) => i.accepted);
    }
  }

  /// Reads the invitations to this account (only those, not a sync) where
  /// nothing else would bring a new one soon: while the live line is closed,
  /// which is while the account is in no Orchard and has accepted nothing
  /// that waits. An account in no team heard of an invitation only when it
  /// opened its invitations, or a quarter of an hour on.
  /// With [always], also while the line is open (the app is
  /// back in front: a phone's line may have died meanwhile). Nothing while
  /// signed out or locked. An accepted one that waits opens the line, as
  /// [syncAll] does.
  Future<void> checkInvites({bool always = false}) async {
    if (_stopped || _readingInvites || _ref.read(databaseSessionProvider) == null) return;
    if (_ref.read(currentUserProvider) == null) return;
    if (!always && _stream != null) return;
    _readingInvites = true;
    try {
      final waiting = await _refreshInvites();
      if (waiting && !_stopped && _ref.read(databaseSessionProvider) != null) _openStream();
    } finally {
      _readingInvites = false;
    }
  }

  /// The app came back to the front (resumed, or its window has the focus
  /// again): a new invitation shows now. At most once in [foregroundGap].
  void foregrounded() {
    final now = DateTime.now();
    final last = _lastForeground;
    if (last != null && now.difference(last) < foregroundGap) return;
    _lastForeground = now;
    unawaited(checkInvites(always: true));
  }

  /// Where this device keeps the invitations its person was told of, in the
  /// Tree's own database (never synced).
  static const _toldInvitesKey = 'orchards.told_invites';

  /// Tells this device's person, in the bell, of each invitation in
  /// [invites] it has not answered and was not told of on this device yet:
  /// once each, also after a restart. Those no longer listed are forgotten.
  Future<void> _tellNewInvites(List<MyInvite> invites) {
    final next = _telling.then((_) async {
      final tree = _ref.read(databaseSessionProvider);
      if (_stopped || tree == null) return;
      try {
        final store = LocalStateStore(tree);
        final raw = await store.read(_toldInvitesKey);
        final decoded = raw == null ? null : jsonDecode(raw);
        final told = <String>{if (decoded is List) ...decoded.whereType<String>()};
        final fresh = [
          for (final i in invites)
            if (!i.accepted && !told.contains(i.id)) i,
        ];
        final listed = {for (final i in invites) i.id};
        final keep = {...told.where(listed.contains), for (final i in fresh) i.id};
        if (fresh.isEmpty && keep.length == told.length) return;
        await store.write(_toldInvitesKey, jsonEncode(keep.toList()..sort()));
        if (_stopped) return;
        final l10n = gl10n;
        for (final i in fresh) {
          _ref.read(notificationCenterProvider.notifier).show(invitationNotification(i, l10n: l10n));
        }
      } catch (e) {
        AppLogger.info('Orchards: a new invitation could not be told (${errorKind(e)})');
      }
    });
    _telling = next;
    return next;
  }

  /// ZestSSH Cloud answers again after it did not, or the device is online
  /// again (lib/services/cloud/cloud_reach.dart): the Orchards sync now, not
  /// at the next round. Whatever waited goes with that (changes made
  /// meanwhile, certificates to ask for or to sign), and a sync that reaches
  /// the server opens the live line again.
  void cloudIsBack() => unawaited(syncAll());

  /// The network came back or changed. Changes made while a sync could not
  /// finish go now; an open line is opened afresh on a new network, since
  /// it may be dead without knowing it yet. (The first word only says what
  /// the network is, on most systems, so it changes nothing by itself.)
  void _networkChanged(ConnectivityKind kind) {
    final before = _network;
    _network = kind;
    if (kind == ConnectivityKind.none) return;
    final stream = _stream;
    if (_unfinished) {
      unawaited(syncAll());
    } else if (stream != null && !stream.isConnected) {
      // A dropped line need not wait out the rest of its backoff.
      stream.retryNow();
    } else if (before != null && before != kind && stream != null) {
      stream.reconnectNow();
    }
  }

  void _openStream() {
    final stream = _stream ?? _ref.read<OrchardStream>(orchardStreamProvider);
    _stream = stream;
    _streamEvents ??= stream.events.listen(_heard);
    stream.start();
    // A sync just reached the server: a dropped line need not wait longer.
    stream.retryNow();
  }

  void _closeStream() {
    _nudge?.cancel();
    _nudge = null;
    _nudgedOrchards.clear();
    _nudgedAll = false;
    unawaited(_streamEvents?.cancel());
    _streamEvents = null;
    final stream = _stream;
    _stream = null;
    if (stream != null) unawaited(stream.stop());
  }

  void _heard(OrchardStreamEvent event) {
    switch (event) {
      case StreamConnected(:final reconnected):
        // What changed while the line was down is fetched now.
        if (reconnected) _nudged(all: true);
      case CrateChanged(:final crateId, :final revision):
        unawaited(_crateChanged(crateId, revision));
      case OrchardsChanged():
        _nudged(all: true);
      case StreamSignedOut():
        sessionRevokedSignal.value++;
      case DeviceApprovalMoved(:final id):
        deviceApprovalNudges.add(id);
      case ShareInvitesChanged():
        shareInviteNudges.add(null);
      case AccessRequestsChanged():
        unawaited(_accessChanged());
      case DeviceRequestsChanged():
        unawaited(_devicesChanged());
      case SecurityChanged():
        securityNudges.add(null);
    }
  }

  /// A Crate changed on the server: the Orchard holding it syncs, unless
  /// this device has already read that far. A Crate this device does not
  /// have yet brings the whole list.
  Future<void> _crateChanged(String crateId, int revision) async {
    try {
      for (final MapEntry(key: orchardId, value: db)
          in _ref.read(orchardDatabasesProvider).entries) {
        final row = await db.customSelect(
          'SELECT last_revision FROM orchard_crates WHERE crate_id = ?',
          variables: [Variable<String>(crateId)],
        ).getSingleOrNull();
        if (row == null) continue;
        if (row.read<int>('last_revision') < revision) _nudged(orchardId: orchardId);
        return;
      }
    } catch (_) {
      // A database closing under the question: the whole list syncs instead.
    }
    _nudged(all: true);
  }

  void _nudged({String? orchardId, bool all = false}) {
    if (_stopped) return;
    if (all) _nudgedAll = true;
    if (orchardId != null) _nudgedOrchards.add(orchardId);
    _nudge ??= Timer(nudgeSettle, () {
      _nudge = null;
      final everything = _nudgedAll;
      final orchards = {..._nudgedOrchards};
      _nudgedAll = false;
      _nudgedOrchards.clear();
      unawaited(everything ? syncAll() : _syncSome(orchards));
    });
  }

  Future<void> _syncSome(Set<String> orchardIds) async {
    for (final id in orchardIds) {
      if (_stopped || _ref.read(databaseSessionProvider) == null) return;
      try {
        _noteSeats(id, await _ref.read(orchardSyncProvider).syncOne(id));
      } on AccountKeysNotReady {
        return;
      } catch (e) {
        _unfinished = true;
        AppLogger.warning('Orchards: a change from elsewhere could not be fetched yet ($e)');
      }
    }
  }

  /// Whether [orchardId]'s sync kept new items waiting for seats.
  void _noteSeats(String orchardId, CrateSyncReport report) {
    if (_stopped) return;
    final full = _ref.read(orchardVaultsFullProvider);
    if (full.contains(orchardId) != (report.seatsNeeded && report.vaultsFull)) {
      _ref.read(orchardVaultsFullProvider.notifier).state = {
        for (final id in full)
          if (id != orchardId) id,
        if (report.seatsNeeded && report.vaultsFull) orchardId,
      };
    }
    final short = _ref.read(orchardSeatsShortProvider);
    if (short.contains(orchardId) == report.seatsNeeded) return;
    _ref.read(orchardSeatsShortProvider.notifier).state = {
      for (final id in short)
        if (id != orchardId) id,
      if (report.seatsNeeded) orchardId,
    };
  }

  void _watch(Map<String, AppDatabase> open) {
    for (final id in _watched.keys.toList()) {
      final db = open[id];
      if (db == null || !identical(db, _watched[id]!.$1)) {
        unawaited(_watched.remove(id)!.$2.cancel());
      }
    }
    for (final MapEntry(key: id, value: db) in open.entries) {
      if (_watched.containsKey(id)) continue;
      final tables = [
        for (final t in db.allTables)
          if (AppDatabase.orchardItemTables.containsKey(t.actualTableName)) t,
      ];
      final sub = db
          .tableUpdates(TableUpdateQuery.onAllTables(tables))
          .listen((_) => _changed(id, db));
      _watched[id] = (db, sub);
    }
  }

  void _changed(String orchardId, AppDatabase db) {
    _pending.remove(orchardId)?.cancel();
    _pending[orchardId] = Timer(settle, () async {
      _pending.remove(orchardId);
      try {
        final queued = await db
            .customSelect('SELECT COUNT(*) AS n FROM crate_outbox')
            .getSingle();
        if (queued.read<int>('n') == 0 || _stopped) return;
        _noteSeats(orchardId, await _ref.read(orchardSyncProvider).syncOne(orchardId));
      } on AccountKeysNotReady {
        // Sent once the keys are here.
      } catch (e) {
        _unfinished = true;
        AppLogger.warning('Orchards: a change could not be sent yet ($e)');
      }
    });
  }
}
