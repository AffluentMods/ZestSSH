import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/connect_link.dart' show quickConnectLinkText;
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart' show phoneGroupPickWanted;
import 'package:zestssh/features/keys/key_agent.dart'
    show oweWhatIsNotedIn, settleAgentKeysAtOpening, systemAgentProvider, takeBackAgentKeys, takeBackOwedAgentKeys;
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/activity/activity_notes.dart' show forgetLastReveals;
import 'package:zestssh/features/orchards/member_picture.dart' show forgetMemberPictures;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show forgetUnwatchedNotYet;
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart' show TeamSessionLogs;
import 'package:zestssh/features/orchards/watch/session_watch.dart' show SessionWatches;
import 'package:zestssh/features/screens/window/screen_windows.dart';
import 'package:zestssh/features/sharing/session_shares.dart' show SessionShares;
import 'package:zestssh/features/sharing/share_providers.dart' show ShareViews;
import 'package:zestssh/features/orchards/spaces.dart' show TreeSpace, kOrchardsEnabled, OrchardDatabasesNotifier;
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/idle_lock_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart' show TeamPremium, isCloudSyncProvider, isProProvider;
import 'package:zestssh/providers/redaction_providers.dart' show redactionFleetRegistrar;
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/router/router.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/deep_link_service.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/services/shortcut_service.dart' show ShortcutService;
import 'package:zestssh/services/google_desktop_oauth.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/multi_window_service.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart' show keychainDenials;
import 'package:zestssh/services/profiles/locked_copies.dart' show LockedCopyInfo, LockedCopyRefused;
import 'package:zestssh/services/profiles/older_version_data.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/session_log_service.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';
import 'package:zestssh/services/tray_service.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart' show EditorWindows;
import 'package:zestssh/ui/widgets/zest_a11y.dart' show forgetAnnouncements;
import 'package:zestssh/ui/screens/help/contact_support_screen.dart' show forgetContactSupportDraft;
import 'package:zestssh/ui/screens/help/report_issue_screen.dart' show forgetReportIssueDrafts;
import 'package:zestssh/ui/screens/help/support_hub_compose.dart' show forgetSupportHubDraft;
import 'package:zestssh/ui/screens/home/home_screen.dart' show manageSectionWanted;
import 'package:zestssh/services/purchase_service.dart' show PurchaseService;
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

/// The app's side of profiles (to-do 60): what a sign-in, a sign-out and a
/// deletion do to what is running, around what [ProfileManager] does to the
/// data. On a phone, and in a test that does not ask for profiles, every step
/// here is nothing at all.
final profileControllerProvider = Provider<ProfileController>((ref) => ProfileController(ref));

/// What survives a change of profile, because it is the device's or holds the
/// change itself; everything else is built again for the next person, so that
/// nothing of the one before stays in memory or is written over the next one's.
/// A test names each of these, so one added here is a decision.
@visibleForTesting
List<ProviderBase<Object?>> get survivesAChange => _survivesAChange;

List<ProviderBase<Object?>> get _survivesAChange => [
      // How the service stands is nobody's, and the app's root ties itself to it
      // once (_tieCloudReach): built again, nothing would tell it anything.
      cloudReachProvider,
      sharedPreferencesProvider,
      secureStorageProvider,
      databaseSessionProvider,
      isAppLockedProvider,
      securityLockServiceProvider,
      vaultSlotServiceProvider,
      hardwareVaultServiceProvider,
      localAuthProvider,
      routerProvider,
      authStateProvider,
      idleClockProvider,
      profileControllerProvider,
    ];

/// What is said of a sign-in whose profile cannot open ([e]), ending in its code.
/// ZestSSH Cloud out of reach is said as everywhere else: how the service stands,
/// with that code. An answer of the service that is no failure of its own is none
/// of the situations named, and is said as what it is: the data did not open.
String profileCannotOpenWords(AppLocalizations l10n, ProfileCannotOpen e) {
  switch (e.code) {
    case 'profile-offline':
      final cause = e.cause;
      final said = cause == null
          ? null
          : cloudStopped(l10n, cause,
              lead: l10n.profileCannotOpenOffline, status: cause is LockedCopyRefused ? cause.status : null);
      if (said != null) return said;
    case 'profile-signed-in-long-ago':
      return ErrorCodes.withCode(l10n.profileCannotOpenSignInAgain, ErrorCodes.profileNeedsFreshSignIn);
    case 'profile-copy-broken':
      return ErrorCodes.withCode(l10n.profileCannotOpenBroken, ErrorCodes.profileCopyDoesNotOpen);
    case 'profile-too-many-accounts':
      return ErrorCodes.withCode(l10n.accountsFullBody, ErrorCodes.tooManyAccounts);
  }
  return ErrorCodes.withCode(l10n.profileCannotOpenOther, ErrorCodes.profileDidNotOpen);
}

/// Builds again everything that may hold a person's state in [container].
void refreshPersonState(ProviderContainer container, {Iterable<ProviderBase<Object?>>? keep}) {
  final kept = (keep ?? _survivesAChange).toSet();
  for (final element in container.getAllProviderElements().toList()) {
    if (kept.contains(element.origin)) continue;
    element.invalidateSelf();
  }
}

/// One line of the account row's list ([ProfileController.accountsHere]).
@immutable
class ComputerAccount {
  const ComputerAccount({
    required this.entry,
    required this.inUse,
    required this.needsSignIn,
    this.lost = false,
    this.someoneElses = false,
  });

  final ProfileEntry entry;

  /// The one on screen.
  final bool inUse;

  /// Picking it takes that account's sign-in: it is signed out, or someone else's
  /// (from a security review).
  final bool needsSignIn;

  /// It can never open again: Remove is all there is to do with it.
  final bool lost;

  /// Someone else's, as far as this computer knows: removing it takes its own
  /// sign-in first, so one person cannot delete another's data from a computer
  /// they share (found in a security review).
  final bool someoneElses;

  String get id => entry.id;

  /// What the list calls it: its address, as it was at its last sign-in.
  String get label => entry.label ?? entry.uid ?? '';

  /// Signed out here: only that account's sign-in opens it.
  bool get signedOut => entry.state != ProfileState.open;
}

/// What lives outside the app's state and would be the next person's, forgotten at
/// each change of profile. Every static or top-level store in lib that can hold a
/// person's data is either here or said to be nobody's, in a table a test keeps
/// (test/services/profiles/account_switch_test.dart): a new one fails it until it is
/// put in one or the other.
void forgetWhatLivesOutsideTheAppState() {
  // The access token Google gave, kept for an hour; whoever waits for this database
  // to open again; links the app has yet to answer.
  GoogleDesktopOAuth.instance.forgetMemory();
  SecretSeal.dropWaiters();
  DeepLinkService.forgetEarly();
  DeviceSessionHeader.current = null;
  AppLogger.forget();
  TrayService.instance?.updateMonitorState(critical: 0, warning: 0, hosts: const []);
  // Whether the account is in a paid team: the next one's is asked for.
  TeamPremium.forget();
  // Sessions the person was watched in, and team logs: all have ended by now.
  SessionWatches.reset();
  TeamSessionLogs.reset();
  // A host waiting to be connected to, a link waiting to be read.
  ShortcutService.pendingConnection.value = null;
  quickConnectLinkText.value = null;
  manageSectionWanted.value = null;
  // A group just made, waiting to be picked in a phone's list of hosts.
  phoneGroupPickWanted.value = null;
  // A secret copied is taken off the clipboard now, not on its time; what the last
  // ask of the store said of the account.
  unawaited(SecretClipboard.clear());
  PurchaseService.lastDiagnostic = null;
  // What was typed to support and not sent: a person's words.
  forgetContactSupportDraft();
  forgetReportIssueDrafts();
  forgetSupportHubDraft();
  // Pictures and the last reveals of a team's members.
  forgetMemberPictures();
  forgetLastReveals();
  forgetUnwatchedNotYet();
  // The names of the person's hosts, groups, keys and accounts that a report is
  // scrubbed of and recording mode masks: the next profile's are given as its lists
  // load (redactionFleetRegistrar), and no one else's stay among them.
  ReportScrub.forgetNames();
  Redactor.instance.clearNames();
  // What a screen reader was being told (a terminal's lines among it).
  forgetAnnouncements();
}

/// What an "Add account" was told of its sign-in (from a security review): the mark of
/// whose it is, made before the sign-in. It goes with that flow's sign-in and no other:
/// two at once each have their own.
class SignInSaid {
  const SignInSaid(this.person);

  /// Whose the account is ([ProfileEntry.person]); null where nothing was said.
  final String? person;

  /// A sign-in that nobody asked about.
  static const nothing = SignInSaid(null);
}

class ProfileController {
  ProfileController(this._ref);

  final Ref _ref;

  /// What the app's root stops as a database closes, and starts as one opens:
  /// the same as for the app lock (ZestSSHApp).
  VoidCallback? onStop;
  VoidCallback? onStart;

  ProfileManager? get _manager => Profiles.on ? ProfileManager.instance : null;

  bool get on => _manager != null;

  /// How many sessions close when the account on screen signs out, or one signs
  /// in, or another is switched to: said first.
  int get openSessions => _ref.read(activeSessionsProvider).length;

  // ── The accounts of this computer ──────────────────────────────────

  /// What the account row lists: the accounts of this computer, and guest data, the
  /// one in use marked. Nothing here says more than the list does. Empty on a phone.
  List<ComputerAccount> get accountsHere {
    final manager = _manager;
    if (manager == null) return const [];
    final list = manager.list;
    // One person's accounts open for each other; from guest data, only where this
    // computer has only ever had one person's accounts ([ProfileList.shared]).
    bool asks(ProfileEntry e) => e.state != ProfileState.open || _someoneElses(manager, e);

    return [
      for (final e in list.accounts)
        ComputerAccount(
          entry: e,
          inUse: e.id == list.current,
          needsSignIn: asks(e),
          someoneElses: e.id != list.current && _someoneElses(manager, e),
        ),
      for (final e in list.entries)
        if (e.uid != null && e.state == ProfileState.lost) ComputerAccount(entry: e, inUse: false, needsSignIn: false, lost: true),
    ];
  }

  /// Whether [e] is someone else's than whoever is on screen (from security reviews):
  /// [ProfileManager.someoneElses].
  static bool _someoneElses(ProfileManager manager, ProfileEntry e) => manager.someoneElses(e);

  /// Whether guest data is what is on screen.
  bool get guestDataOnScreen => _manager != null && _manager!.currentEntry?.uid == null;

  /// How many accounts this computer holds, and whether there is room for one more.
  bool get roomForAnotherAccount => (_manager?.list.accounts.length ?? 0) < ProfileList.maxAccounts;

  /// The guest data set aside when a deleted account's data became the guest data.
  List<ProfileEntry> get keptGuestData => _manager?.list.keptGuestData ?? const [];

  /// Whether "Add account" has whose it is to ask: an account of someone is signed in
  /// here to call it another of, or this computer holds one person's accounts only.
  /// From guest data every account here counts, signed in or not, as it does for
  /// [accountsHere]: counting only those signed in let a second person, whose own
  /// account was signed out, answer "Mine" and become the first, whose accounts then
  /// opened with no sign-in (found in a security review).
  /// Nor where this computer ever had a second person's ([ProfileList.shared]): the
  /// second removing their own account left one person's, whose mark "Mine" then gave
  /// them.
  bool get addAsksWhose {
    final manager = _manager;
    if (manager == null) return false;
    if (manager.currentEntry?.uid != null) return true;
    return !manager.list.shared && manager.list.peopleHere == 1;
  }

  /// What the sign-in of an "Add account" is said to be: one of the same person's as
  /// those on screen ([mine]), or someone else's. Asked before the sign-in, so nothing
  /// is said twice; it holds through a Try again, and is forgotten once the sign-in has
  /// come. Nobody asked, nothing is said. What comes back goes with that flow's sign-in
  /// ([openForAccount]), whatever another "Add account" says meanwhile, and to
  /// [forgetNextSignIn] as the flow ends.
  Future<SignInSaid> nextSignInIs({required bool mine}) async {
    final manager = _manager;
    if (manager == null) return SignInSaid.nothing;
    var person = newProfileId();
    // "Mine" stands only where the question was the app's to ask ([addAsksWhose]):
    // the account on screen, or from guest data the one person whose accounts are
    // all that is here. Said anywhere else (the question shown by a mistake, or
    // left open while a second person's account came), it makes the sign-in
    // nobody's here but its own, never the first person's.
    if (mine && addAsksWhose) {
      final current = manager.currentEntry;
      final theirs = manager.list.ofSomeone;
      final hers = current?.uid != null
          ? current
          : theirs.where((a) => a.state == ProfileState.open).firstOrNull ?? theirs.firstOrNull;
      if (hers != null) person = await manager.personOf(hers);
    }
    final said = SignInSaid(person);
    _signInsSaid.add(said);
    return said;
  }

  /// The sign-in [said] was said of will not come ("Add account" was cancelled or
  /// failed), or has come. What another "Add account" was told stands.
  void forgetNextSignIn(SignInSaid said) => _signInsSaid.remove(said);

  /// What each "Add account" under way was told.
  final _signInsSaid = <SignInSaid>[];

  /// What the sign-in whose session is awaited was said to be.
  SignInSaid? _saidOfThisSignIn;

  /// Whose a sign-in that came is: what its flow was told ([said]). One that cannot say
  /// which flow it is of (a Mac's, through Firebase) may be any under way: where they all
  /// say the same it is that, and where not it may be the one said to be someone else's,
  /// so it is nobody's here, and opens no account with no sign-in.
  String? _personOfSignIn(SignInSaid? said) {
    if (said != null) return said.person;
    final people = {for (final s in _signInsSaid) s.person};
    return people.length <= 1 ? people.firstOrNull : newProfileId();
  }

  /// The app's root, as an account new on this computer has finished signing in:
  /// guest data may be here to ask about.
  VoidCallback? onGuestData;

  /// This sign-in made the account's profile: once its session is written, what guest
  /// data holds is asked about, once.
  bool _askAboutGuestData = false;

  /// A sign-in opened its profile, and its session is not written yet: it has
  /// none for a moment, and that is no sign-out that stopped.
  bool _awaitingSession = false;

  /// What the sign-in that opened the profile asks of its locked copy: a new secret
  /// in place of the one just fetched; and that the sign-in is fresh, so what is
  /// retired can go at ZestSSH Cloud.
  bool _replaceSecret = false;
  bool _signedInNow = false;

  /// Changes of profile run one at a time: each is many steps, each assuming what
  /// the one before it left.
  Future<void> _tail = Future<void>.value();

  Future<T> _oneAtATime<T>(Future<T> Function() change) {
    final run = _tail.then((_) => change());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// The session of a sign-in is written into its profile: the last step. What
  /// was waiting for it goes on, and the locked copy is told to ZestSSH Cloud only
  /// now: nothing else writes to the keychain meanwhile.
  Future<void> sessionKept() async {
    if (!_awaitingSession) return;
    _awaitingSession = false;
    _signInsSaid.remove(_saidOfThisSignIn);
    _saidOfThisSignIn = null;
    await afterOpened();
    await settleCopy();
    if (_askAboutGuestData) {
      _askAboutGuestData = false;
      await _manager?.forgetWhoseUnknown();
      onGuestData?.call();
    }
  }

  /// The session could not be written: this is no sign-in. The profile it opened
  /// comes to what any profile of an account with no session comes to as it
  /// opens ([afterOpened]). On Windows and Linux that is a sign-out that stopped,
  /// and it locks again. On a Mac a session that reads as none is no sign-out by
  /// itself ([ProfileManager.signedOut]): the data
  /// stays open, and the notice says to sign in. Another account on this computer
  /// still opens it only with this account's own sign-in, as before
  /// ([ProfileManager.planForSwitch]).
  Future<void> sessionNotKept() async {
    if (!_awaitingSession) return;
    _awaitingSession = false;
    _replaceSecret = false;
    _signedInNow = false;
    _askAboutGuestData = false;
    await afterOpened();
  }

  /// Stops all that runs for the profile on screen: its sessions and pop-out
  /// windows, the editor's windows of their own, sync, the teams, the monitors,
  /// and what lives outside the app's state. Each stops as for the app lock, and
  /// what a provider runs goes as the provider is built again
  /// ([refreshPersonState]; the main window's editor and its tabs among them).
  Future<void> _stopWhatRuns() async {
    // A browser sign-in still waiting is the person's who was here.
    DesktopBrowserSignIn.cancel();
    // The editor's windows of their own, with their tabs: the next person never
    // sees, edits or keeps a draft of a file of the profile before (security
    // review 3.4.1). They are not MultiWindowService's.
    await EditorWindows.instance.closeAll();
    // A screen shown in a window of its own goes back to its tab (its
    // session ends just below with every other).
    await ScreenWindows.instance.closeAll();
    try {
      await MultiWindowService.instance.closeAllWindows();
      await _ref.read(activeSessionsProvider.notifier).endAllSessions();
    } catch (e) {
      AppLogger.warning('Closing sessions at a change of profile: ${errorKind(e)}');
    }
    // What a share ended here tells its viewers, and what this device watches
    // closes: neither goes on under the next person.
    try {
      await Future.wait([SessionShares.stopAll(), ShareViews.closeAll()]).timeout(const Duration(seconds: 5));
    } catch (e) {
      AppLogger.warning('Closing what was shared at a change of profile: ${errorKind(e)}');
    }
    // The keys this profile gave to the system's agent are taken back while its
    // database can still say which they are.
    await takeBackAgentKeys(_ref.read(systemAgentProvider), _ref.read(databaseSessionProvider),
        keychain: _ref.read(secureStorageProvider));
    try {
      await _ref.read(autoSyncServiceProvider).suspend();
    } catch (_) {/* not started */}
    onStop?.call();
    if (kOrchardsEnabled) {
      try {
        _ref.read(orchardSyncSchedulerProvider).stop();
      } catch (_) {/* not started */}
    }
    _ref.read(activeSpaceProvider.notifier).state = const TreeSpace();
    await _ref.read(orchardDatabasesProvider.notifier).closeAll();
    await SessionLogService.endAll();
    SessionTranscriptService.forgetAll();
    forgetWhatLivesOutsideTheAppState();
  }

  /// Puts the next profile in place of the one on screen. The two databases are
  /// open side by side for a moment and the session is never empty, so a screen
  /// that is up stays up (a sign-in in the middle of joining a team goes on).
  Future<void> _flip(Future<AppDatabase> Function() next, {Future<void> Function()? beforeStart}) async {
    final manager = _manager!;
    final was = manager.currentEntry?.id;
    final wasOpen = _ref.read(databaseSessionProvider);
    // [_stopWhatRuns] suspends sync, and where the person stays nothing builds it anew.
    AutoSyncService? syncThatRan;
    try {
      final sync = _ref.read(autoSyncServiceProvider);
      if (!sync.isSuspended) syncThatRan = sync;
    } catch (_) {/* not started */}
    await _stopWhatRuns();
    // Nothing is sealed or opened with the old seal from here on.
    SecretSeal.openTree = null;
    final prefs = _ref.read(sharedPreferencesProvider);
    final AppDatabase db;
    try {
      db = await next();
    } catch (_) {
      // Stayed where it was, whatever the change had got to: what closed for it is
      // said by the caller, and nothing of it is lost.
      if (was != null && wasOpen != null) {
        try {
          await manager.stayOn(was, wasOpen);
        } catch (e) {
          AppLogger.warning('Staying where it was: ${errorKind(e)}');
        }
      }
      SecretSeal.openTree = wasOpen;
      if (wasOpen != null) {
        // The names a report is scrubbed of went with the rest: the profile that
        // stays gives its own again.
        _ref.invalidate(redactionFleetRegistrar);
        _ref.read(redactionFleetRegistrar);
        try {
          syncThatRan?.resume();
        } catch (e) {
          AppLogger.warning('Sync was not resumed where the person stayed: ${errorKind(e)}');
        }
      }
      onStart?.call();
      rethrow;
    }
    await TerminalThemes.loadCustomThemes(prefs);
    refreshPersonState(_ref.container);
    await _ref.read(databaseSessionProvider.notifier).swap(db);
    assert(identical(manager, _manager));
    if (beforeStart != null) await beforeStart();
    onStart?.call();
  }

  /// What leaving the profile on screen takes. One with no session of its own to go
  /// back to cannot stay signed in behind another (a Mac whose Firebase is about to be
  /// someone else): it locks, as at a sign-out. Read before the change, while its seal
  /// is there. On a Mac none read is no sign-out by itself ([ProfileManager.signedOut]):
  /// a sign-in the keychain did not show stays as it is, and its own sign-in opens it.
  Future<Future<void> Function()> _whatLeavingTakes() async {
    final manager = _manager!;
    final entry = manager.currentEntry;
    if (entry == null || entry.uid == null) return () async {};
    String? token;
    try {
      token = await AccountSecret.sessionToken.read(_ref.read(secureStorageProvider));
    } catch (e) {
      // Nothing says it has none: it stays signed in, and its next opening decides.
      AppLogger.warning('A session was not read at a change of profile: ${errorKind(e)}');
      return () async {};
    }
    // What it came to is said once the next one is open: never unsaid.
    return token == null && (manager.firebaseUid?.call() != null || await manager.signedOut(entry))
        ? () async {
            final end = await manager.lockCurrent();
            _leftLocked = end;
          }
        : () async {};
  }

  /// What leaving the profile on screen came to ([_whatLeavingTakes]), said once the
  /// next one is open ([_sayLeft]).
  SignOutEnd? _leftLocked;

  void _sayLeft() {
    final end = _leftLocked;
    _leftLocked = null;
    if (end != null) _sayLockEnd(end, LockedCopyAtCloud.held);
  }

  // ── A switch ───────────────────────────────────────────────────────

  /// Opens [id] in place of what is on screen, with no sign-in: guest data, or an
  /// account still signed in here that is not someone else's, which goes on being
  /// signed in behind it, with its session and its data as they are. Only an account's
  /// own sign-out locks it. A switch asks for no PIN: the lock stands as it stood.
  /// Throws [ProfileCannotOpen], with the person where they were, what closed for the
  /// change said by the caller; `profile-signed-in-long-ago` for someone else's, which
  /// takes its own sign-in.
  Future<void> switchTo(String id) async {
    final manager = _manager;
    if (manager == null) return;
    await _oneAtATime(() async {
      final target = manager.list.byId(id);
      if (target == null || id == manager.list.current) return;
      await _switchWith(() => manager.planForSwitch(target));
    });
  }

  /// [switchTo] guest data, which this computer makes where it has none now.
  Future<void> switchToGuest() async {
    final manager = _manager;
    if (manager == null || manager.currentEntry?.uid == null) return;
    await _oneAtATime(() => _switchWith(manager.planForGuest));
  }

  Future<void> _switchWith(Future<AccountPlan> Function() plan) async {
    final manager = _manager!;
    final prepared = await manager.prepare(await plan());
    final leave = await _whatLeavingTakes();
    try {
      await _flip(() async {
        await leave();
        await manager.commit(prepared);
        return prepared.db;
      }, beforeStart: _restoreKeptSession);
    } catch (e) {
      try {
        await prepared.db.close();
      } catch (_) {/* best effort */}
      throw ProfileCannotOpen('profile-not-opened', e);
    } finally {
      _sayLeft();
    }
  }

  /// The session the profile now open keeps, in the app's state, and what the account
  /// has read again: at a start this waits for the first frame, and a switch has no
  /// moment with nobody signed in to spare.
  Future<void> _restoreKeptSession() async {
    try {
      final storage = _ref.read(secureStorageProvider);
      final kept = await keptDesktopSession(storage);
      if (kept == null) return;
      _ref.read(desktopSessionProvider.notifier).state = kept;
      unawaited(_ref.read(isProProvider.notifier).refresh());
      unawaited(_ref.read(isCloudSyncProvider.notifier).refresh());
    } catch (e) {
      AppLogger.warning('A kept session was not restored at a switch: ${errorKind(e)}');
    }
  }

  /// Whether Firebase is what keeps the account on screen signed in (a Mac): it stays
  /// signed in as one person, so that account cannot stay signed in behind another.
  bool get heldByFirebase {
    final manager = _manager;
    return manager != null && manager.currentEntry?.uid != null && manager.firebaseUid?.call() != null;
  }

  // ── Locked copies at ZestSSH Cloud ─────────────────────────────────

  Future<String> _bearerOnScreen() async {
    final bearer = await AccountSecret.sessionToken.read(_ref.read(secureStorageProvider)) ??
        await AuthService.getIdToken(forceRefresh: false);
    if (bearer == null) throw const LockedCopyRefused(401, 'not-signed-in');
    return bearer;
  }

  /// The account's locked copies as ZestSSH Cloud lists them, and which is this
  /// computer's own (null where it has none yet).
  Future<(List<LockedCopyInfo>, String?)> lockedCopiesAtCloud() async {
    final manager = _manager;
    if (manager == null) return (const <LockedCopyInfo>[], null);
    final entry = manager.currentEntry;
    final here = entry == null ? null : await manager.copies.confirmed(entry.id);
    return (await manager.api.list(bearer: await _bearerOnScreen()), here?.id);
  }

  /// Deletes the copy [id] at ZestSSH Cloud. Throws [LockedCopyRefused] with
  /// `recent-sign-in-required` where the sign-in is too old for that.
  Future<void> deleteLockedCopyAtCloud(String id) async {
    final manager = _manager;
    if (manager == null) return;
    await manager.api.delete(bearer: await _bearerOnScreen(), id: id);
  }

  // ── Removing an account ────────────────────────────────────────────

  /// The account [id] goes from this computer, on the person's word: its data, its
  /// keys, its files, all that the design lists. What it synced stays at ZestSSH Cloud.
  /// Signed in, it first tells ZestSSH Cloud, as far as it can, that its copy and this
  /// session are done with; locked, it holds no session to say so with, and its copy
  /// stays listed under Locked copies, where it opens nothing any more. On screen, guest
  /// data opens first. Throws [ProfileCannotOpen] with nothing changed where guest data
  /// did not open; false where a folder would not go yet.
  Future<bool> removeFromComputer(String id) async {
    final manager = _manager;
    if (manager == null) return true;
    final target = manager.list.byId(id);
    if (target == null || target.uid == null) return true;
    if (id == manager.list.current) return _removeOnScreen(manager, target);
    // Someone else's takes its own sign-in first: signed in, it is on screen and
    // goes from there. One that can never open again is anyone's to clear.
    if (target.state != ProfileState.lost && _someoneElses(manager, target)) {
      throw const ProfileCannotOpen('profile-signed-in-long-ago');
    }
    return _oneAtATime(() async {
      if (target.state == ProfileState.open) {
        final bearer = await manager.sessionOf(target);
        if (bearer != null) await _tellCloudItIsDone(manager, target, bearer);
      }
      // The keys it gave the system's agent, read before its note goes with its folder,
      // go back with what else is owed; what an agent does not take back now stays on the
      // computer's list for the next opening.
      await _oweAgentKeysOf(manager, [target]);
      await takeBackOwedAgentKeys(_ref.read(systemAgentProvider), _ref.read(secureStorageProvider),
          except: manager.list.current);
      return manager.removeAccount(id);
    });
  }

  Future<bool> _removeOnScreen(ProfileManager manager, ProfileEntry target) => _oneAtATime(() async {
        // Read while its seal is there; told only once guest data has opened: until
        // then the person may stay here, with their session and their copy as they were.
        String? bearer;
        try {
          bearer = await _bearerOnScreen();
        } catch (e) {
          AppLogger.warning('No session to tell ZestSSH Cloud with (${errorKind(e)})');
        }
        final prepared = await manager.prepare(await manager.planForGuest());
        try {
          // A Mac: Firebase would open this account again as soon as guest data did.
          if (heldByFirebase) await AuthService.signOut();
          await _flip(() async {
            await manager.commit(prepared);
            return prepared.db;
          });
        } catch (e) {
          try {
            await prepared.db.close();
          } catch (_) {/* best effort */}
          throw ProfileCannotOpen('profile-not-opened', e);
        }
        if (bearer != null) await _tellCloudItIsDone(manager, target, bearer);
        return manager.removeAccount(target.id);
      });

  /// ZestSSH Cloud is told, as [bearer]'s account, that this computer's copy and this
  /// session are done with. Best effort, and said by nobody: what is left there opens
  /// nothing here, and an answer about that account's session says nothing about the
  /// one on screen.
  Future<void> _tellCloudItIsDone(ProfileManager manager, ProfileEntry target, String bearer) async {
    try {
      final copy = await manager.copies.confirmed(target.id);
      if (copy != null) await manager.api.delete(bearer: bearer, id: copy.id, onScreen: false);
    } catch (e) {
      AppLogger.warning('The locked copy at ZestSSH Cloud was left (${errorKind(e)})');
    }
    await endSessionOf(bearer);
  }

  /// Ends the session [bearer] at ZestSSH Cloud, as a stand-in test says it did.
  @visibleForTesting
  static Future<void> Function(String bearer) endSession =
      (bearer) => DeviceSessionsApi(bearer: () async => bearer, onScreen: false).endOwnSession();

  /// [endSession], best effort: a session this computer no longer uses leaves the
  /// account's device list as it goes.
  Future<void> endSessionOf(String bearer) async {
    try {
      await endSession(bearer);
    } catch (e) {
      AppLogger.warning('A session was left at ZestSSH Cloud (${errorKind(e)})');
    }
  }

  // ── A sign-in ──────────────────────────────────────────────────────

  /// The account [uid] signed in: its profile opens, or a new one is made, in
  /// the design's order. ZestSSH Cloud's checks have passed and the caller has
  /// written nothing yet: it writes the session into the profile after this.
  /// Throws [ProfileCannotOpen], with nothing changed, where it cannot open. [said] is
  /// what this sign-in's own flow was told of it; null where it cannot say
  /// ([_personOfSignIn]).
  Future<void> openForAccount({required String uid, String? label, required String? bearer, SignInSaid? said}) async {
    final manager = _manager;
    if (manager == null) return;
    await _oneAtATime(() async {
      final plan = await manager.planForAccount(uid: uid, label: label, bearer: bearer, person: _personOfSignIn(said));
      _saidOfThisSignIn = said ?? _signInsSaid.singleOrNull;
      _replaceSecret = plan.replaceSecret;
      _signedInNow = true;
      _awaitingSession = true;
      // Guest data the move could not tell whose it was is asked about at any sign-in.
      final guest = manager.list.guest;
      _askAboutGuestData = plan.isFresh || (guest != null && await manager.whoseUnknown(guest.id));
      if (plan.known != null && plan.hex == null) return; // It is the one on screen.
      final PreparedProfile prepared;
      try {
        prepared = await manager.prepare(plan);
      } catch (_) {
        _awaitingSession = false;
        rethrow;
      }
      final leave = await _whatLeavingTakes();
      try {
        await _flip(() async {
          await leave();
          await manager.commit(prepared);
          return prepared.db;
        });
      } catch (e) {
        _awaitingSession = false;
        try {
          await prepared.db.close();
        } catch (_) {/* best effort */}
        throw ProfileCannotOpen('profile-not-opened', e);
      } finally {
        _sayLeft();
      }
      if (plan.losing != null) {
        _ref.read(notificationCenterProvider.notifier).warning(
              gl10n.profileCopyLostTitle,
              body: ErrorCodes.withCode(gl10n.profileCopyLostBody, ErrorCodes.profileCopyLost),
            );
      }
    });
  }

  // ── Guest data ─────────────────────────────────────────────────────

  /// What guest data holds beside the account on screen, if anything to ask about.
  Future<GuestDataSummary?> guestData() async => _manager?.lookAtGuest(into: _ref.read(databaseSessionProvider));

  /// It comes into the account on screen, with what the person just said. Throws, with
  /// guest data as it was, where it cannot. No sync runs meanwhile: one that read this
  /// account before it would write over what came in on what it read then, so a cycle
  /// in flight ends first, and none starts until it has come.
  Future<void> bringGuestData() async {
    final manager = _manager;
    final db = _ref.read(databaseSessionProvider);
    if (manager == null || db == null) return;
    await _oneAtATime(() async {
      AutoSyncService? sync;
      try {
        final service = _ref.read(autoSyncServiceProvider);
        if (!service.isSuspended) {
          await service.suspend();
          sync = service;
        }
      } catch (_) {/* not started */}
      try {
        await manager.bringGuestInto(
          _ref.read(syncDataServiceProvider),
          db: db,
          keychain: _ref.read(secureStorageProvider),
        );
      } finally {
        // Its saved tab groups and custom themes are in the store now: what is in memory
        // is read again, or the next save would write over them.
        _ref.invalidate(savedTabGroupsProvider);
        await _readThemesAgain(db);
        sync?.resume();
      }
    });
  }

  Future<void> _readThemesAgain(AppDatabase db) async {
    try {
      await ProfilePreferences.instance?.load(db);
      await TerminalThemes.loadCustomThemes(_ref.read(sharedPreferencesProvider));
      _ref.invalidate(customAppThemesProvider);
    } catch (e) {
      AppLogger.warning('Custom themes were not read again (${errorKind(e)})');
    }
  }

  // ── A sign-out ─────────────────────────────────────────────────────

  /// Before the person's own sign-out, while its session still works: what
  /// ZestSSH Cloud says of the profile on screen's locked copy
  /// ([ProfileManager.lockedCopyAtCloud]), for [lockAfterSignOut]. Null on a
  /// phone, on a computer with guest data on screen, and where no session is
  /// left to ask with, which locks as a sign-out from elsewhere does.
  Future<LockedCopyAtCloud?> lockedCopyBeforeSignOut() async {
    final manager = _manager;
    if (manager == null || manager.currentEntry?.uid == null) return null;
    final String bearer;
    try {
      bearer = await _bearerOnScreen();
    } catch (e) {
      AppLogger.warning('No session to ask ZestSSH Cloud for the locked copy with (${errorKind(e)})');
      return null;
    }
    return manager.lockedCopyAtCloud(bearer: bearer);
  }

  /// The session is gone: the profile on screen locks, and guest data opens. A
  /// profile only hidden says so, as what it means is not what was asked for.
  /// With the database closed by the app lock (the session went just as it
  /// locked) it locks all the same, and guest data is what the PIN opens.
  /// [cloud]: what [lockedCopyBeforeSignOut] found. Only where ZestSSH Cloud
  /// holds the copy does it lock; otherwise the profile is hidden, its key kept
  /// here, and where the account itself is gone its data is kept as guest data.
  /// A sign-out from elsewhere has no session left to ask with, and locks on
  /// the copy confirmed here. [told]: the person's own sign-out, which said what it
  /// does; anything else that locks says so, as hiding always does.
  Future<void> lockAfterSignOut({LockedCopyAtCloud cloud = LockedCopyAtCloud.held, bool told = false}) async {
    final manager = _manager;
    if (manager == null) return;
    try {
      await _lockAfterSignOut(manager, cloud, told);
    } finally {
      await manager.signOutDone();
    }
  }

  Future<void> _lockAfterSignOut(ProfileManager manager, LockedCopyAtCloud cloud, bool told) async {
    await _oneAtATime(() async {
      if (manager.currentEntry?.uid == null) return;
      if (cloud == LockedCopyAtCloud.accountGone) {
        // No secret will ever open it again: it stays open, as the data of an
        // account deleted here does, and is guest data from now on.
        await manager.markAccountGone();
        await manager.keepCurrentAsGuest();
        _ref.read(notificationCenterProvider.notifier).warning(
              gl10n.accountDeleteKeptLocalSnack,
              body: gl10n.profileAccountGoneKeptBody,
            );
        return;
      }
      late SignOutEnd end;
      if (_ref.read(databaseSessionProvider) == null) {
        await _stopWhatRuns();
        end = await manager.lockCurrentWhileClosed(cloud: cloud);
      } else {
        await _flip(() async {
          end = await manager.lockCurrent(cloud: cloud);
          return manager.openGuest();
        });
      }
      if (end == SignOutEnd.hidden || !told) _sayLockEnd(end, cloud);
    });
  }

  /// The person's own sign-out of the profile on screen begins ([signOutAccountWith]).
  Future<void> signOutBegins() async {
    await _manager?.signOutBegins();
  }

  // ── A profile that does not open ───────────────────────────────────

  /// Whether another profile can open in place of one that did not.
  bool get canOpenOther => _manager?.canOpenAnother ?? false;

  /// The profile did not open after the PIN: the next right PIN opens guest data
  /// instead, and nothing of this one goes on running. It stays as it is, and
  /// its account's next sign-in tries it again.
  Future<void> openOtherAfterFailure() async {
    final manager = _manager;
    if (manager == null) return;
    await _oneAtATime(() async {
      await _stopWhatRuns();
      await manager.openGuestNextStart();
    });
  }

  /// Whether what did not open can be set aside: on a computer, always.
  bool get canSetAside => _manager != null;

  /// What did not open after the PIN goes to a folder of its own: the next right
  /// PIN starts fresh, and nothing is deleted.
  Future<void> setAsideAfterFailure() async {
    final manager = _manager;
    if (manager == null) return;
    await _oneAtATime(() async {
      await _stopWhatRuns();
      await manager.setAsideCurrent();
    });
  }

  /// Whether data that did not open waits on this computer, to be said to the person
  /// on screen: guest data's, or an account's that is theirs ([_mayActOnSetAside]).
  Future<bool> setAsideHere() async {
    final manager = _manager;
    if (manager == null) return false;
    return manager.setAsideHere(where: (e) => _mayActOnSetAside(manager, e));
  }

  /// Whether the person on screen may put back or delete [e], set aside: guest data's,
  /// or an account's that is not someone else's. Put back opened an account's data
  /// at the next start with its kept key, for whoever asked, and Delete took it for
  /// good; someone else's waits for its own account (found in a security
  /// review). From guest data that is where this computer has only
  /// ever had one person's accounts, the one set aside counted among them: it was not,
  /// so with Alex's set aside and Sam's here guest data counted one person and put
  /// back Alex's (found in code reviews).
  /// [ProfileList.shared].
  static bool _mayActOnSetAside(ProfileManager manager, ProfileEntry e) {
    if (e.uid == null) return true;
    // The account's own data set aside, its profile now a new one with no mark of
    // the old (a profile set aside is no person's here).
    if (manager.currentEntry?.uid == e.uid) return true;
    return !_someoneElses(manager, e);
  }

  /// What was asked to be put back could not be, this start: said once the app is up.
  bool get putBackFailed => _manager?.putBackFailed ?? false;

  /// How the app closes ([askPutBack]): set by the app's root.
  VoidCallback? onQuit;

  /// The newest of what was set aside is put back as the app next starts, with
  /// nothing of it running then. So the app closes now.
  Future<void> askPutBack() async {
    final manager = _manager;
    if (manager == null) return;
    await _oneAtATime(() => manager.askPutBack(where: (e) => _mayActOnSetAside(manager, e)));
    onQuit?.call();
  }

  /// It goes, on the person's word.
  Future<void> deleteSetAside() async {
    final manager = _manager;
    if (manager == null) return;
    await _oneAtATime(() => manager.deleteSetAside(where: (e) => _mayActOnSetAside(manager, e)));
  }

  // ── Deleting ───────────────────────────────────────────────────────

  /// The account was deleted at ZestSSH Cloud: its profile stays open, and the
  /// person says whether its data goes ([removeAfterWipe]) or stays
  /// ([keepAsGuest]).
  Future<void> accountGone() async => _manager?.markAccountGone();

  /// The copy at ZestSSH Cloud of the profile on screen goes, while the session
  /// can still say so. Best effort: what is left there opens nothing here.
  Future<void> deleteLockedCopy({required String? bearer}) async {
    final manager = _manager;
    final entry = manager?.currentEntry;
    if (manager == null || entry == null || bearer == null) return;
    try {
      final copy = await manager.copies.confirmed(entry.id);
      if (copy != null) await manager.api.delete(bearer: bearer, id: copy.id);
    } catch (e) {
      AppLogger.warning('The locked copy at ZestSSH Cloud was left (${errorKind(e)})');
    }
  }

  /// The profile on screen was wiped while it was open: it goes, and guest data
  /// opens. Nothing of another profile, the lock or the list is touched.
  Future<void> removeAfterWipe() async {
    final manager = _manager;
    if (manager == null) return;
    await _oneAtATime(() async {
      await _flip(() async {
        await manager.markCurrentRemoving();
        return manager.openGuest();
      });
      await manager.finishRemovals();
    });
  }

  /// The person kept the data of a deleted account: it is the guest data now.
  Future<void> keepAsGuest() async {
    final manager = _manager;
    if (manager == null) return;
    await _oneAtATime(() async {
      await manager.keepCurrentAsGuest();
      refreshPersonState(_ref.container);
    });
  }

  /// Everything on this computer goes, on the person's word. Throws [ProfileCannotOpen]
  /// (`profile-signed-in-long-ago`), with nothing changed, where it would take someone
  /// else's account ([mayDeleteEverything]).
  Future<void> wipeEverything() async {
    final manager = _manager;
    if (manager == null) return;
    if (!mayDeleteEverything) throw const ProfileCannotOpen('profile-signed-in-long-ago');
    await _oneAtATime(() async {
      await _flip(() async {
        await manager.beginWipeEverything();
        return manager.openGuest();
      });
      await manager.finishWipeEverything();
      _ref.read(isAppLockedProvider.notifier).unlock();
    });
  }

  /// What the note of each of [entries] says it gave the system's agent goes on the
  /// computer's list of keys owed back, before its folder goes.
  Future<void> _oweAgentKeysOf(ProfileManager manager, Iterable<ProfileEntry> entries) async {
    if (_ref.read(systemAgentProvider) == null) return;
    final keychain = _ref.read(secureStorageProvider);
    for (final e in entries) {
      if (!isProfileId(e.id)) continue;
      try {
        await oweWhatIsNotedIn(keychain, e.id, ProfilePaths.ofProfile(manager.base, e.id));
      } catch (err) {
        AppLogger.warning('Keys a profile gave the system agent were not listed (${errorKind(err)})');
      }
    }
  }

  /// Every profile's keys given to the system's agent go on the computer's list, as
  /// everything here is about to go (Delete all local data's Everything).
  Future<void> oweAgentKeysOfEveryProfile() async {
    final manager = _manager;
    if (manager == null) return;
    await _oweAgentKeysOf(manager, manager.list.entries);
  }

  /// What the accounts besides the one on screen that have a profile here are
  /// called, to say whom "everything on this device" would remove. An id says
  /// nothing to a person, and one with no name is left to the sentence's "other
  /// data".
  List<String> get otherAccounts {
    final manager = _manager;
    if (manager == null) return const [];
    return [
      for (final e in manager.list.entries)
        if (e.id != manager.list.current && e.uid != null && e.state != ProfileState.removing && e.label != null) e.label!,
    ];
  }

  /// Whether this computer holds anything a wipe of the profile on screen leaves
  /// behind: then the person is asked which they mean.
  Future<bool> otherDataHere() async => await _manager?.otherDataHere() ?? false;

  /// Whether everything on this computer is the person on screen's to delete: no
  /// account whose data is here is someone else's. Someone else's goes only
  /// with its own sign-in, from the screen it is on then, as Remove from this computer
  /// does; Everything took it with no sign-in of theirs, from guest data or from
  /// another person's account (found in a code review).
  bool get mayDeleteEverything {
    final manager = _manager;
    if (manager == null) return true;
    return !manager.list.ofSomeone.any((e) => e.id != manager.list.current && manager.someoneElses(e));
  }

  // ── After each opening ─────────────────────────────────────────────

  /// What a profile that has just opened goes on to: a sign-out that stopped is
  /// finished, the locked copy is told to ZestSSH Cloud where it has not been,
  /// and teams that wait may be used where they are. Nothing here is needed for
  /// the hosts on the device to work: a profile opens offline, always.
  Future<void> afterOpened() async {
    final manager = _manager;
    if (manager == null) return;
    // Firebase says who is signed in a while after the start, and until it has,
    // nobody signed in is no answer: nothing is decided, and nothing locks, on that.
    await manager.firebaseReported?.call();
    final entry = manager.currentEntry;
    final db = _ref.read(databaseSessionProvider);
    if (entry == null || db == null) return;
    final storage = _ref.read(secureStorageProvider);
    // What another profile still owes the system's agent goes back, and this
    // one's note is kept beside its database.
    await settleAgentKeysAtOpening(_ref.read(systemAgentProvider), db, storage);
    final firebase = manager.firebaseUid?.call();
    if (firebase != null) {
      manager.firebaseSaidSignedIn(firebase);
      _ref.read(notificationCenterProvider.notifier).remove(signInNotReadNotice);
    }
    if (entry.uid == null) {
      if (firebase == null && await manager.whoseUnknown(entry.id)) {
        _ref.read(notificationCenterProvider.notifier).show(AppNotification(
              id: 'profile-whose-unknown',
              title: gl10n.profileWhoseUnknownTitle,
              body: ErrorCodes.withCode(gl10n.profileWhoseUnknownBody, ErrorCodes.profileWhoseUnknown),
              severity: NotificationSeverity.warning,
              dismissAfter: Duration.zero,
              actionLabel: gl10n.profileSignIn,
              onAction: _openAccountPage,
            ));
      }
      // A Mac stays signed in with Firebase across starts.
      if (firebase != null) {
        final failed = await _openForFirebaseUser();
        if (failed != null) {
          _ref.read(notificationCenterProvider.notifier).warning(
                gl10n.profileCannotOpenTitle,
                body: profileCannotOpenWords(gl10n, failed),
              );
        }
      }
      return;
    }
    if (_awaitingSession) return;
    await _signInAtOpening(manager, entry, firebase, storage);
  }

  /// The sign-in of [entry], an account's profile that has just opened: read, or
  /// what its absence comes to.
  Future<void> _signInAtOpening(
      ProfileManager manager, ProfileEntry entry, String? firebase, FlutterSecureStorage storage) async {
    _signInUnread = false;
    final String? token;
    try {
      token = await AccountSecret.sessionToken.read(storage);
    } catch (e) {
      // A Mac's keychain that did not let the session be read (macOS said no, could not
      // ask, or failed): no sign-out. The data stays open, and the notice says so, with
      // Try again (3.4.1). Elsewhere it stays as it was: nothing decided on it.
      if (!manager.signInMayReadAsNone) rethrow;
      AppLogger.warning('The sign-in on this computer was not read (${errorKind(e)})');
      _saySignInNotRead(unread: e);
      return;
    }
    if (token != null) _ref.read(notificationCenterProvider.notifier).remove(signInNotReadNotice);
    if (token == null && firebase == null) {
      if (!await manager.signedOut(entry)) {
        // A Mac whose sign-in reads as nobody, and nobody signed out: the keychain may
        // not have shown it (after an update, or the app's new signature). The data
        // stays open, as it is, and the person is told to sign in again (before,
        // it locked, and empty guest data opened, saying
        // nothing).
        _saySignInNotRead();
        return;
      }
      // The account's profile with no session: a sign-out, or a sign-in, that
      // stopped before its end. It finishes as a sign-out.
      await lockAfterSignOut();
      return;
    }
    await manager.signOutDone();
    if (kOrchardsEnabled) await useHeldTeamsInPlace();
  }

  /// The notice of [_saySignInNotRead], by its id: it goes once the sign-in is read,
  /// or Firebase says who.
  static const signInNotReadNotice = 'profile-sign-in-not-read';

  /// Whether the notice stands for a keychain read that failed, which Try again reads
  /// again ([readSignInAgain]).
  bool _signInUnread = false;

  /// The data stays open, and nobody is signed in on screen: said, with Sign in. Where
  /// the keychain did not let the sign-in be read ([unread]), with Try again instead,
  /// and the details to copy.
  void _saySignInNotRead({Object? unread}) {
    _signInUnread = unread != null;
    final body = ErrorCodes.withCode(
        unread == null ? gl10n.profileSignInNotReadBody : gl10n.profileSignInUnreadBody, ErrorCodes.macSignInNotRead);
    _ref.read(notificationCenterProvider.notifier).show(AppNotification(
          id: signInNotReadNotice,
          title: gl10n.profileSignInNotReadTitle,
          body: body,
          severity: NotificationSeverity.warning,
          dismissAfter: Duration.zero,
          actionLabel: unread == null ? gl10n.profileSignIn : gl10n.macKeychainTryAgain,
          onAction: unread == null ? _openAccountPage : () => unawaited(readSignInAgain()),
          details: unread == null
              ? null
              : ErrorReport.build(
                  what: gl10n.profileSignInNotReadTitle, where: 'Reading the sign-in from the keychain', error: unread),
        ));
  }

  /// Try again, on the notice that the sign-in was not read, or on the notice that
  /// macOS said no to a saved key (ZS-1913): what macOS said no to is asked again, the
  /// sign-in of the profile on screen is read again, and the account is signed in on
  /// screen where it now reads. Never throws.
  Future<void> readSignInAgain() async {
    final manager = _manager;
    final entry = manager?.currentEntry;
    if (manager == null || entry == null || entry.uid == null || _ref.read(databaseSessionProvider) == null) return;
    try {
      if (_signInUnread) {
        keychainDenials?.tryAgain();
        _ref.read(notificationCenterProvider.notifier).remove(signInNotReadNotice);
        await _signInAtOpening(manager, entry, manager.firebaseUid?.call(), _ref.read(secureStorageProvider));
      }
      // The sign-in shown on screen, where the start could not read it.
      if (!_signInUnread && _ref.read(desktopSessionProvider) == null && manager.firebaseUid?.call() == null) {
        await _restoreKeptSession();
      }
    } catch (e) {
      AppLogger.warning('The sign-in was not read again (${errorKind(e)})');
    }
  }

  void _openAccountPage() {
    try {
      unawaited(_ref.read(routerProvider).push<void>(Routes.profile));
    } catch (e) {
      AppLogger.warning('The account page did not open from a notice (${errorKind(e)})');
    }
  }

  /// A profile that was locked, or only hidden, by anything but the person's own
  /// sign-out says so: guest data never opens in its place unsaid.
  void _sayLockEnd(SignOutEnd end, LockedCopyAtCloud cloud) {
    final notices = _ref.read(notificationCenterProvider.notifier);
    switch (end) {
      case SignOutEnd.locked:
        notices.warning(gl10n.profileLockedTitle, body: gl10n.profileLockedBody);
      case SignOutEnd.hidden:
        notices.warning(
          gl10n.profileHiddenTitle,
          body: ErrorCodes.withCode(
              switch (cloud) {
                LockedCopyAtCloud.gone => gl10n.profileHiddenCopyGoneBody,
                // Offline, or no answer: the secret is there, unchecked.
                LockedCopyAtCloud.unreachable => gl10n.profileHiddenUnreachableBody,
                // A copy never confirmed: the secret never got there.
                _ => gl10n.profileHiddenBody,
              },
              ErrorCodes.profileHiddenNotLocked),
        );
      case SignOutEnd.nothing:
        break;
    }
  }

  /// Tells ZestSSH Cloud of the open profile's locked copy, as far as it can, with
  /// what the sign-in that opened it asked for. Nothing here is needed for the
  /// hosts on the device to work, and what cannot reach ZestSSH Cloud is tried again
  /// at the next start.
  Future<void> settleCopy() async {
    final manager = _manager;
    final db = _ref.read(databaseSessionProvider);
    if (manager == null || db == null || _awaitingSession) return;
    final replace = _replaceSecret;
    final signedInNow = _signedInNow;
    _replaceSecret = false;
    _signedInNow = false;
    if (manager.currentEntry?.uid == null) return;
    final bearer = await AccountSecret.sessionToken.read(_ref.read(secureStorageProvider)) ??
        await AuthService.getIdToken(forceRefresh: false);
    await manager.settleLockedCopy(db: db, bearer: bearer, replace: replace, signedInNow: signedInNow);
  }

  /// The Firebase user is signed in and its checks passed (a Mac): its profile.
  /// Where it cannot open, Firebase signs out again and the person is told.
  Future<ProfileCannotOpen?> _openForFirebaseUser() async {
    final manager = _manager;
    final uid = manager?.firebaseUid?.call();
    if (uid == null || manager == null) return null;
    try {
      await openForAccount(
        uid: uid,
        label: AuthService.currentUser?.email,
        bearer: await AuthService.getIdToken(forceRefresh: false),
      );
      // A Firebase sign-in has no session to write: it is in.
      await sessionKept();
      return null;
    } on ProfileCannotOpen catch (e) {
      await AuthService.signOut();
      return e;
    }
  }

  /// [_openForFirebaseUser], for the end of a sign-in on a Mac.
  Future<ProfileCannotOpen?> afterFirebaseSignIn() => _manager == null ? Future.value() : _openForFirebaseUser();

  /// Held teams with no owner, whose own record names this account, may be used
  /// where they lie until ZestSSH Cloud says whose they are.
  Future<void> useHeldTeamsInPlace() async {
    final manager = _manager;
    if (manager == null) return;
    final added = await manager.useHeldTeamsInPlace((teamId, key, uid) async {
      final file = File('${ProfilePaths.heldTeams(manager.base).path}${Platform.pathSeparator}$teamId.db');
      final db = await AppDatabase.openOrchardFile(file, keyHex: key);
      try {
        return await OrchardDatabasesNotifier.namesMember(db, uid);
      } finally {
        await db.close();
      }
    });
    if (added > 0) _ref.read(orchardListVersionProvider.notifier).state++;
  }

  /// ZestSSH Cloud's list of [uid]'s teams came.
  Future<void> teamsOnServer(Set<String> ids, {required String uid}) async {
    final manager = _manager;
    final db = _ref.read(databaseSessionProvider);
    if (manager == null || db == null) return;
    await manager.teamsOnServer(ids, uid: uid, db: db, close: _ref.read(orchardDatabasesProvider.notifier).close);
  }

  // ── An older version's data ────────────────────────────────────────

  /// What an older version left at the old place, if anything. An empty one
  /// goes without asking. None is ever opened by itself.
  Future<(OlderVersionData, OlderVersionSummary)?> olderVersionData() async {
    final manager = _manager;
    if (manager == null) return null;
    final older = OlderVersionData(base: manager.base, device: manager.device, rawPrefs: manager.rawPrefs);
    if (!await older.isThere) return null;
    final summary = await older.look();
    if (summary.empty) {
      await older.delete();
      return null;
    }
    return (older, summary);
  }

  // ── Data elsewhere on this computer ────────────────────────────────

  /// Where data elsewhere is looked for: a Mac, where an update left people with an
  /// empty app and their data in another folder or a copy (6 November 2026).
  @visibleForTesting
  static bool Function() looksElsewhere = () => Platform.isMacOS;

  /// What else on this computer holds the person's data, where the profile on screen
  /// holds none ([ProfileManager.dataElsewhere]). Never throws.
  Future<DataElsewhere?> dataElsewhere() async {
    final manager = _manager;
    final db = _ref.read(databaseSessionProvider);
    if (manager == null || db == null || !looksElsewhere()) return null;
    try {
      return await manager.dataElsewhere(db);
    } catch (e) {
      AppLogger.warning('Data elsewhere on this computer was not looked for (${errorKind(e)})');
      return null;
    }
  }

  /// [found] opened or brought back: a switch to other guest data, or a copy brought
  /// into the profile on screen, with no sync running meanwhile. Throws, with nothing
  /// changed, where it cannot.
  Future<void> bringBackElsewhere(DataElsewhere found) async {
    final manager = _manager;
    final db = _ref.read(databaseSessionProvider);
    if (manager == null || db == null) return;
    if (found.kind == DataElsewhereKind.open) return switchTo(found.profile);
    if (found.kind != DataElsewhereKind.copy) return;
    await _oneAtATime(() async {
      AutoSyncService? sync;
      try {
        final service = _ref.read(autoSyncServiceProvider);
        if (!service.isSuspended) {
          await service.suspend();
          sync = service;
        }
      } catch (_) {/* not started */}
      try {
        await manager.bringBack(found, _ref.read(syncDataServiceProvider));
      } finally {
        _ref.invalidate(savedTabGroupsProvider);
        sync?.resume();
      }
    });
  }

  /// [older] brought into the profile on screen.
  Future<void> bringOlderVersionData(OlderVersionData older) => older.bringInto(_ref.read(syncDataServiceProvider));
}
