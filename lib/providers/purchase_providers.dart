import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:zestssh/features/orchards/spaces.dart' show kOrchardsEnabled;
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart' show orchardDatabaseStorageProvider, sharedPreferencesProvider;
import 'package:zestssh/services/purchase_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

// ── Pro status ───────────────────────────────────────────────────

/// Whether the current user has the Pro entitlement.
///
/// This is the single source of truth for feature-gating.
/// UI checks `ref.watch(isProProvider)` to show/hide Pro features.
final isProProvider = StateNotifierProvider<ProStatusNotifier, bool>((ref) {
  return ProStatusNotifier(ref);
});

/// Squeezed and Juiced for the members of a paid team, on a phone:
/// a phone's own answer comes from
/// RevenueCat, which knows nothing of teams, so it also asks ZestSSH Cloud,
/// whose answer counts the team. A computer needs none of this: its answer
/// is ZestSSH Cloud's already. Asked only for an account signed in that has
/// a team on this device (nobody else's phone asks anything new), at most
/// once a minute unless forced; an answer that does not come keeps the last
/// one, kept on the device for the account so a start with no network keeps
/// it (ZestSSH Cloud being down must not take what the team gives), and it
/// only ever adds to RevenueCat's.
class TeamPremium {
  TeamPremium._();

  /// Tests: true takes a phone's way on a computer.
  static bool? debugPhone;

  /// Whether this device takes a phone's way (RevenueCat, then the team).
  static bool get onPhone => debugPhone ?? !isDesktopPlatform;

  /// Asks ZestSSH Cloud whether the signed-in account is in a paid team:
  /// null when it cannot be asked. Tests replace it.
  static Future<bool?> Function() ask = () async => (await PurchaseService.fetchWebEntitlements())?.team;

  static bool _last = false;
  static DateTime? _askedAt;
  static Future<bool>? _asking;

  /// The last answer this device had, and the account it was for.
  static const keptKey = 'team_premium_member';
  static const keptForKey = 'team_premium_uid';

  /// Tests: forgets the last answer.
  static void debugReset() => forget();

  /// The last answer kept on this device for the account signed in: false
  /// where none is, or it is another account's. A computer keeps ZestSSH
  /// Cloud's answer here too, for a start with no network.
  static bool keptFor(Ref ref) {
    try {
      final uid = ref.read(currentUserProvider)?.uid;
      if (uid == null) return false;
      final prefs = ref.read(sharedPreferencesProvider);
      return prefs.getString(keptForKey) == uid && (prefs.getBool(keptKey) ?? false);
    } catch (_) {
      // No store in this scope (a test of something else).
      return false;
    }
  }

  /// Keeps [answer] for the account signed in (a computer's: ZestSSH
  /// Cloud's answer).
  static Future<void> keep(Ref ref, bool answer) async {
    try {
      final uid = ref.read(currentUserProvider)?.uid;
      if (uid == null) return;
      final prefs = ref.read(sharedPreferencesProvider);
      await prefs.setBool(keptKey, answer);
      await prefs.setString(keptForKey, uid);
    } catch (_) {
      // Not kept: the next answer that comes is used all the same.
    }
  }

  /// What was last heard is one account's: a change of profile asks again.
  static void forget() {
    _last = false;
    _askedAt = null;
    _asking = null;
  }

  /// Whether the signed-in account has Squeezed and Juiced from a paid team,
  /// as last heard. [force] asks again whatever the time.
  static Future<bool> active(Ref ref, {bool force = false}) async {
    if (!onPhone || !kOrchardsEnabled) return false;
    if (ref.read(currentUserProvider) == null) {
      debugReset();
      return false;
    }
    final List<String> teams;
    try {
      teams = await ref.read(orchardDatabaseStorageProvider).list();
    } catch (_) {
      return _last;
    }
    if (teams.isEmpty) {
      debugReset();
      return false;
    }
    final uid = ref.read(currentUserProvider)!.uid;
    final at = _askedAt;
    if (!force && at != null && DateTime.now().difference(at) < const Duration(minutes: 1)) return _last;
    return _asking ??= () async {
      final prefs = ref.read(sharedPreferencesProvider);
      try {
        final answer = await ask();
        if (answer != null) {
          _last = answer;
          _askedAt = DateTime.now();
          await prefs.setBool(keptKey, answer);
          await prefs.setString(keptForKey, uid);
        } else if (at == null) {
          // Not answered since the app started: the last answer this device
          // had for this account.
          _last = prefs.getString(keptForKey) == uid && (prefs.getBool(keptKey) ?? false);
        }
        return _last;
      } catch (_) {
        return _last;
      } finally {
        _asking = null;
      }
    }();
  }
}

class ProStatusNotifier extends StateNotifier<bool> {
  ProStatusNotifier(this._ref) : super(false) {
    _init();
    _wireAuthRefresh();
  }

  final Ref _ref;

  /// A phone's answers: RevenueCat's and the team's (see [TeamPremium]).
  bool _store = false;
  bool _team = false;

  void _setPhone() {
    final next = _store || _team;
    if (mounted && state != next) {
      state = next;
      AppLogger.info('Pro status: $next');
    }
    if (TeamPremium.onPhone) _seat(_team);
  }

  /// Says whether the account's plan comes from a paid team's seat
  /// ([teamSeatProvider]), as last heard.
  void _seat(bool active) {
    if (!mounted) return;
    try {
      _ref.read(teamSeatProvider.notifier).state = active;
    } catch (_) {
      // The container is going away.
    }
  }

  /// A computer's answer from ZestSSH Cloud: Squeezed, and whether it comes
  /// from a team's seat (kept for a start with no network).
  void _setWeb(({bool pro, bool cloudSync, bool team}) web) {
    if (!mounted) return;
    if (state != web.pro) state = web.pro;
    _seat(web.team);
    unawaited(TeamPremium.keep(_ref, web.team));
  }

  /// On mobile the RC SDK's identity follows Firebase auth - but
  /// `Purchases.logIn(uid)` is fired from PurchaseService.init's
  /// own listener, which races with this notifier's `_init()`. If
  /// `isProUser()` runs before logIn completes, we read the
  /// anonymous user's state (= false) and stick there because
  /// `addCustomerInfoUpdateListener` doesn't always fire on a pure
  /// identity switch (no entitlement-state delta to broadcast).
  ///
  /// Re-querying whenever Firebase auth state changes - with a
  /// brief delay so PurchaseService.init's listener runs first -
  /// closes that cold-start race. It also re-runs on sign-out so we
  /// drop back to Free.
  void _wireAuthRefresh() {
    _ref.listen(authStateProvider, (prev, next) async {
      if (!mounted) return;
      // Let the PurchaseService.init auth listener call
      // Purchases.logIn(uid) + restorePurchases() FIRST. We're both
      // subscribed to the same stream; without this delay we race
      // and read stale CustomerInfo.
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      await refresh();
    });
  }

  Future<void> _init() async {
    // Check current status
    _store = await PurchaseService.isProUser();
    if (TeamPremium.onPhone) _team = await TeamPremium.active(_ref);
    if (!mounted) return;
    state = _store || _team;
    if (TeamPremium.onPhone) _seat(_team);

    // Listen for changes (purchase, restore, expiration)
    PurchaseService.addCustomerInfoListener((customerInfo) {
      if (!mounted) return;
      _store = customerInfo
              .entitlements.all[PurchaseService.proEntitlementId]?.isActive ??
          false;
      _setPhone();
    });

    // On desktop the RC SDK is unavailable - fall back to the
    // backend entitlement endpoint, which reads the user's web
    // (Stripe / RevenueCat web) purchase state via the Firebase JWT.
    // Returns null when the user isn't signed in, in which case we
    // leave state alone.
    if (!TeamPremium.onPhone) {
      // Seed from the last known-good entitlement first, so a cold launch with
      // no network keeps Pro instead of dropping to Free, then refresh from the
      // backend when a network is available (which re-persists the cache).
      final cached = await PurchaseService.readCachedDesktopEntitlements();
      if (cached != null && mounted && state != cached.pro) {
        state = cached.pro;
      }
      // And whether it came from a team's seat, as last heard here.
      if (cached != null) _seat(TeamPremium.keptFor(_ref));
      final web = await PurchaseService.fetchWebEntitlements();
      if (web != null) _setWeb(web);
    }
  }

  /// Signed out on this device: Free at once, whatever was cached. On a
  /// computer [refresh] has no account to ask then and left the last tier in
  /// place (29 October 2026).
  void signedOut() {
    _store = false;
    _team = false;
    if (mounted) state = false;
    _seat(false);
  }

  /// Force refresh.  On mobile this re-queries RevenueCat; on
  /// desktop it re-queries the ZestSSH backend (which proxies RC).
  Future<void> refresh() async {
    if (!TeamPremium.onPhone) {
      final web = await PurchaseService.fetchWebEntitlements();
      if (web != null) _setWeb(web);
      return;
    }
    _store = await PurchaseService.isProUser();
    _team = await TeamPremium.active(_ref);
    _setPhone();
  }

  /// Decision-time forced refresh - invalidates RC's cache and asks
  /// the server, then updates [state] and returns the fresh value.
  ///
  /// Use at gating points (e.g. connection-save limit) where falling
  /// through to "Free tier" because of a stale cache would deny a
  /// paying user. The regular [refresh] reads RC's SDK cache, which
  /// can be stale right after a Purchases.logIn that ran on cold
  /// start. [forceRefresh] guarantees a network round-trip.
  Future<bool> forceRefresh() async {
    if (!TeamPremium.onPhone) {
      final web = await PurchaseService.fetchWebEntitlements();
      if (web != null) _setWeb(web);
      return state;
    }
    _store = await PurchaseService.forceRefreshIsPro();
    _team = await TeamPremium.active(_ref, force: true);
    _setPhone();
    return _store || _team;
  }
}

// ── Cloud Sync status ────────────────────────────────────────────

/// Whether the current user has the Cloud Sync entitlement.
final isCloudSyncProvider =
    StateNotifierProvider<CloudSyncStatusNotifier, bool>((ref) {
  return CloudSyncStatusNotifier(ref);
});

/// The single canonical PAID tier label, or null for Free.
///
/// Tier is rendered from THIS one source, in one style, everywhere it appears
/// (Account card, About, the rail footer) so it can never disagree between
/// screens. It collapses to the highest tier held: Juiced (hosted Cloud) over
/// Squeezed (Pro). Brand tier names are data, not translated copy; a Free user
/// gets null so each caller supplies its own localized "Free" wording.
final tierLabelProvider = Provider<String?>((ref) {
  if (ref.watch(isCloudSyncProvider)) return 'Juiced';
  if (ref.watch(isProProvider)) return 'Squeezed';
  return null;
});

/// Whether the signed-in account has Squeezed and Juiced from a paid team
/// now, its seat active (lib/team_premium.js on the server: an active
/// member of a team that paid for its seats). Its plan is then said in plain
/// words, never by the fruit names. Written by
/// [ProStatusNotifier] from what it hears: ZestSSH Cloud's answer on a
/// computer (kept for a start with no network), [TeamPremium] on a phone.
final teamSeatProvider = StateProvider<bool>((ref) => false);

/// The plans an account can have, as the app says them:
/// Free; Squeezed, the full app; Juiced,
/// ZestSSH Cloud only; the Bundle, both; or a team's seat, which gives both
/// while it is active.
enum AccountPlan { free, squeezed, juiced, bundle, teamSeat }

/// This account's plan ([AccountPlan]), from the one source the rest of the
/// app gates features by.
final accountPlanProvider = Provider<AccountPlan>((ref) {
  final pro = ref.watch(isProProvider);
  final cloud = ref.watch(isCloudSyncProvider);
  // A seat gives both; what the account bought itself is not said beside
  // it.
  if (ref.watch(teamSeatProvider) && (pro || cloud)) return AccountPlan.teamSeat;
  if (pro && cloud) return AccountPlan.bundle;
  if (pro) return AccountPlan.squeezed;
  if (cloud) return AccountPlan.juiced;
  return AccountPlan.free;
});

class CloudSyncStatusNotifier extends StateNotifier<bool> {
  CloudSyncStatusNotifier(this._ref) : super(false) {
    _init();
    _wireAuthRefresh();
  }

  final Ref _ref;

  /// A phone's answers: RevenueCat's and the team's (see [TeamPremium]).
  bool _store = false;
  bool _team = false;

  void _setPhone() {
    final next = _store || _team;
    if (mounted && state != next) {
      state = next;
      AppLogger.info('Cloud Sync status: $next');
    }
  }

  /// See ProStatusNotifier._wireAuthRefresh - identical reasoning.
  void _wireAuthRefresh() {
    _ref.listen(authStateProvider, (prev, next) async {
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      await refresh();
    });
  }

  Future<void> _init() async {
    _store = await PurchaseService.isCloudSyncUser();
    if (TeamPremium.onPhone) _team = await TeamPremium.active(_ref);
    if (!mounted) return;
    state = _store || _team;

    PurchaseService.addCustomerInfoListener((customerInfo) {
      if (!mounted) return;
      _store = customerInfo.entitlements
              .all[PurchaseService.cloudSyncEntitlementId]?.isActive ??
          false;
      _setPhone();
    });

    // Desktop fallback - same as ProStatusNotifier.  The backend
    // endpoint returns both flags in one call so we re-use the same
    // result here without a second round-trip.
    if (!TeamPremium.onPhone) {
      // Seed from cache first (see ProStatusNotifier._init) so an offline cold
      // launch keeps the tier the user paid for, then refresh when online.
      final cached = await PurchaseService.readCachedDesktopEntitlements();
      if (cached != null && mounted && state != cached.cloudSync) {
        state = cached.cloudSync;
      }
      final web = await PurchaseService.fetchWebEntitlements();
      if (web != null && mounted && state != web.cloudSync) {
        state = web.cloudSync;
      }
    }
  }

  /// Signed out on this device: Free at once, whatever was cached. On a
  /// computer [refresh] has no account to ask then and left the last tier in
  /// place (29 October 2026).
  void signedOut() {
    _store = false;
    _team = false;
    if (mounted) state = false;
  }

  Future<void> refresh() async {
    if (!TeamPremium.onPhone) {
      final web = await PurchaseService.fetchWebEntitlements();
      if (web != null && mounted) state = web.cloudSync;
      return;
    }
    _store = await PurchaseService.isCloudSyncUser();
    _team = await TeamPremium.active(_ref);
    _setPhone();
  }

  /// See ProStatusNotifier.forceRefresh - same pattern, bypasses RC's
  /// SDK cache.
  Future<bool> forceRefresh() async {
    if (!TeamPremium.onPhone) {
      final web = await PurchaseService.fetchWebEntitlements();
      if (web != null && mounted) state = web.cloudSync;
      return state;
    }
    _store = await PurchaseService.forceRefreshIsCloudSync();
    _team = await TeamPremium.active(_ref, force: true);
    _setPhone();
    return _store || _team;
  }
}

// ── Free tier limits ─────────────────────────────────────────────

/// The free tier's sessions open at once on a computer (Windows, macOS,
/// Linux). Every string that names the limit takes it as a placeholder, so
/// a change is made here and nowhere else.
const freeSessionLimitDesktop = 5;

/// The free tier's sessions open at once on a phone; tablets and Chromebooks
/// count as phones.
const freeSessionLimitMobile = 3;

/// Maximum number of concurrent active sessions on the free tier.
///
/// Free users can save unlimited connections but only have a limited
/// number of sessions open at the same time: terminals, files-only
/// sessions and remote screen tabs (4.0) each take one.
final int freeSessionLimit = isDesktopPlatform ? freeSessionLimitDesktop : freeSessionLimitMobile;

/// Maximum number of free terminal themes.
const freeThemeLimit = 3;

/// Maximum number of hosts a free-tier user can opt in to agentless SSH
/// monitoring (Server Monitor). Beyond this the AgentlessMonitorPoller marks
/// the overflow "upgrade to monitor" and never opens a connection for them.
/// Pro/Squeezed users have no monitor cap.
const freeMonitorLimit = 5;

// ── Offerings ────────────────────────────────────────────────────

/// Available offerings (product packages) from RevenueCat.
final offeringsProvider = FutureProvider<Offerings>((ref) async {
  return PurchaseService.getOfferings();
});

// ── Customer info ────────────────────────────────────────────────

/// Full customer info for the account/subscription screen.
final customerInfoProvider = FutureProvider<CustomerInfo>((ref) async {
  return PurchaseService.getCustomerInfo();
});
