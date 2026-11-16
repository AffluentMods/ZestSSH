import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/entitlement_diagnostics.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';

/// Thrown when a purchase API is called on a platform RevenueCat
/// doesn't support (Windows / Linux / macOS).  Distinct from
/// [PlatformException] so the UI can branch on it and render a
/// "purchases are mobile-only" affordance instead of a generic
/// "Store not available" error that looks like a bug.
class PurchaseUnavailableException implements Exception, HasTypeName {
  const PurchaseUnavailableException([this.message =
      'Purchases are only available on the Android and iOS apps.']);
  final String message;

  @override
  String toString() => message;

  @override
  String get typeName => 'PurchaseUnavailableException';
}

/// Manages in-app purchases via RevenueCat.
///
/// ZestSSH pricing:
/// - Free tier: SSH, SFTP, unlimited hosts, 5 sessions on desktop / 3 on mobile, 3 terminal themes
/// - Squeezed ($9.99 one-time, entitlement "ZestSSH Pro"): unlimited sessions, all themes, port forwarding, jump hosts, automation
/// - Juiced ($24.99 one-time): the hosted ZestSSH Cloud storage for sync (sync itself is free on any backend)
/// - Bundle ($29.99 lifetime): Squeezed + Juiced together
///
/// Entitlement IDs (configured in RevenueCat dashboard):
/// - "ZestSSH Pro" → pro features
/// - "cloud sync" entitlement → the hosted ZestSSH Cloud backend (Juiced)
class PurchaseService {
  static const _androidApiKey = String.fromEnvironment('REVENUECAT_ANDROID_KEY');
  static const _iosApiKey = String.fromEnvironment('REVENUECAT_IOS_KEY');

  static const proEntitlementId = 'pro';
  static const cloudSyncEntitlementId = 'cloud sync';

  static bool _initialized = false;

  /// True only on Android / iOS - the platforms RevenueCat Flutter
  /// SDK supports today.  Windows / macOS / Linux users must
  /// purchase on mobile and let Cloud Sync share the entitlement
  /// across their devices.
  static bool get isPlatformSupported =>
      Platform.isAndroid || Platform.isIOS;

  /// Whether RevenueCat has been initialised (mobile only).
  static bool get isAvailable => _initialized;

  /// Sets RevenueCat up with [apiKey] through [configure]; false where it
  /// cannot (a build with no key, or the SDK refusing what it was given),
  /// and the app goes on as a computer does, Free until an entitlement
  /// comes another way. Purchases are not what a person opens an SSH app
  /// for: a phone build with no key stood at "ZestSSH could not start"
  /// (found in an emulator check).
  @visibleForTesting
  static Future<bool> configureWith(
    String apiKey, {
    required Future<void> Function(PurchasesConfiguration configuration) configure,
  }) async {
    if (apiKey.isEmpty) {
      AppLogger.warning('RevenueCat not set up: this build has no API key, so purchases are off');
      return false;
    }
    try {
      await configure(PurchasesConfiguration(apiKey));
      return true;
    } catch (e, stack) {
      AppLogger.error('RevenueCat could not be set up, so purchases are off until the next start', e, stack);
      return false;
    }
  }

  /// Initialise RevenueCat SDK. Call once at app start (mobile only).
  static Future<void> init() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    final ready = await configureWith(
      Platform.isAndroid ? _androidApiKey : _iosApiKey,
      configure: (configuration) async {
        await Purchases.setLogLevel(kReleaseMode ? LogLevel.warn : LogLevel.debug);
        await Purchases.configure(configuration);
      },
    );
    if (!ready) return;
    _initialized = true;
    AppLogger.info('RevenueCat initialised');

    // Bridge Firebase Auth → RevenueCat identity so RC's app_user_id
    // equals the Firebase UID once the user signs in. Without this,
    // RC uses its own anonymous device-scoped id and the backend
    // (which queries RC by firebase_uid) can't see purchases.
    //
    // SAFETY-CRITICAL CAVEAT (otherwise
    // lifetime purchases can vanish): contrary to the comment that
    // used to live here, purchases_flutter's logIn() does NOT
    // reliably migrate the anonymous user's purchases. RC only
    // merges anon → uid when the uid has NEVER been seen by the
    // project - and our backend's GET /subscribers/{uid} entitlement
    // checks auto-create empty customers, so the uid almost always
    // exists by the time a cloud-sync user signs in on mobile. The
    // logIn then just SWITCHES users, stranding the entitlements on
    // the anonymous customer. restorePurchases can't recover them
    // either: RC consumes lifetime one-time IAPs on Android after
    // processing, so Google Play no longer returns the receipt.
    //
    // _handleAuthChange therefore snapshots the pre-login customer
    // and REVERTS the identity switch whenever it would strand
    // active entitlements. All identity operations are serialized
    // through _identityChain so rapid auth-state emissions can't
    // interleave logIn/logOut/restore calls.
    AuthService.authStateChanges.listen((user) {
      _identityChain = _identityChain
          .then((_) => _handleAuthChange(user))
          .catchError((Object e) {
        AppLogger.error('RevenueCat identity sync failed', e);
      });
    });
  }

  /// Serializes identity operations from the auth-state listener.
  static Future<void> _identityChain = Future.value();

  /// The last Firebase uid the listener saw. Used to distinguish a
  /// REAL sign-out (user → null) from the stream's cold-start null
  /// emission for users who simply never signed in - calling
  /// Purchases.logOut() on the latter churned a fresh empty
  /// anonymous user on every launch.
  static String? _lastSeenUid;

  /// When a logIn would have stranded active entitlements on an
  /// anonymous customer, we revert and record the anon id here so
  /// support / diagnostics can see it (and the RC dashboard transfer
  /// can be done from a single log line).
  static String? strandedAnonymousId;

  static const _strandedKey = 'rc_stranded_anon_id';

  static Future<void> _handleAuthChange(dynamic user) async {
    if (user != null) {
      final uid = user.uid as String;
      final currentId = await Purchases.appUserID;
      if (currentId == uid) {
        // Already identified as this user - nothing to do. Skipping
        // avoids pointless logIn/restore API churn on every app
        // launch for signed-in users.
        _lastSeenUid = uid;
        return;
      }

      // Snapshot the pre-login customer so we can detect (and undo)
      // an identity switch that would orphan paid entitlements.
      List<String> preActive = const [];
      try {
        final pre = await Purchases.getCustomerInfo();
        preActive = pre.entitlements.active.keys.toList();
      } catch (_) {
        // Offline - proceed; the strand check just won't trigger.
      }

      final result = await Purchases.logIn(uid);
      _lastSeenUid = uid;
      AppLogger.info(
        'RevenueCat: logged in as $uid '
        '(created=${result.created}, preActive=$preActive)',
      );

      // Restore after logIn - rescues subscriptions and unconsumed
      // purchases (cross-device sign-in, reinstalls). NOTE: this
      // CANNOT rescue consumed lifetime one-time IAPs; for those the
      // strand-revert below is the only safety net.
      var postActive =
          result.customerInfo.entitlements.active.keys.toList();
      try {
        final info = await Purchases.restorePurchases();
        postActive = info.entitlements.active.keys.toList();
        AppLogger.info(
          'RevenueCat: restorePurchases done '
          '(active=${postActive.isEmpty ? "[none]" : postActive.join(",")})',
        );
      } catch (e) {
        AppLogger.warning('RevenueCat restorePurchases failed: $e');
      }

      // Strand check: the user we just switched AWAY from owned
      // active entitlements, and the user we switched TO has none
      // even after a restore. Undo the switch - a paying user
      // keeping their features beats backend-visible identity.
      if (preActive.isNotEmpty &&
          postActive.isEmpty &&
          currentId.startsWith(r'$RCAnonymousID:')) {
        AppLogger.warning(
          'RevenueCat: logIn($uid) would strand entitlements '
          '$preActive on $currentId - reverting identity switch',
        );
        strandedAnonymousId = currentId;
        try {
          await appKeychain.write(key: _strandedKey, value: currentId);
        } catch (_) {}
        try {
          await Purchases.logIn(currentId);
          AppLogger.info(
            'RevenueCat: reverted to $currentId - entitlements intact',
          );
        } catch (e) {
          AppLogger.error('RevenueCat: identity revert FAILED', e);
        }
      }
    } else {
      final wasSignedIn = _lastSeenUid != null;
      _lastSeenUid = null;
      if (!wasSignedIn) {
        // Cold-start null for a user who never signed in (or whose
        // sign-out happened before this launch). Don't touch RC -
        // logOut here used to churn a fresh empty anonymous user
        // every launch.
        return;
      }
      // Real sign-out transition. Drop to a fresh anonymous user so
      // we stop reporting the previous user's entitlements. Safe:
      // identified customers keep their entitlements server-side and
      // recover them by signing back in.
      try {
        final anon = await Purchases.isAnonymous;
        if (!anon) {
          await Purchases.logOut();
          AppLogger.info('RevenueCat: logged out');
        }
      } catch (e) {
        AppLogger.warning('RevenueCat logOut failed: $e');
      }
    }
  }

  /// The anon customer id recorded by a past strand-revert, if any.
  /// Surfaced by the manual Restore flow so an affected user gets an
  /// actionable message instead of "No previous purchases found."
  static Future<String?> readStrandedAnonymousId() async {
    if (strandedAnonymousId != null) return strandedAnonymousId;
    try {
      return await appKeychain.read(key: _strandedKey);
    } catch (_) {
      return null;
    }
  }

  // ── Entitlement checks ─────────────────────────────────────────

  /// Check if the user has the Pro entitlement.
  /// On desktop (where RevenueCat is unavailable), returns `false` (Free tier).
  static Future<bool> isProUser() async {
    if (!_initialized) return false; // Desktop/uninitialized: Free tier
    try {
      final customerInfo = await Purchases.getCustomerInfo();
      return customerInfo.entitlements.all[proEntitlementId]?.isActive ??
          false;
    } on PlatformException catch (e) {
      AppLogger.error('Failed to check pro status', e);
      return false;
    }
  }

  /// Force-refresh RC's customer-info cache and return whether the user
  /// is Pro. Use this at gating decision points (e.g. "can the user
  /// save another connection?") where a stale cache would incorrectly
  /// lock out a paying user.
  ///
  /// `getCustomerInfo()` normally serves from the SDK's in-memory cache
  /// and may not reflect entitlements granted server-side after the
  /// last logIn - which is the failure mode that left paying users
  /// stuck on the free-tier connection limit despite having Pro.
  /// Invalidating first guarantees a round-trip to RC's API.
  static Future<bool> forceRefreshIsPro() async {
    if (!_initialized) return false; // Desktop / not mobile
    try {
      await Purchases.invalidateCustomerInfoCache();
      final customerInfo = await Purchases.getCustomerInfo();
      return customerInfo.entitlements.all[proEntitlementId]?.isActive ??
          false;
    } on PlatformException catch (e) {
      AppLogger.error('Failed to force-refresh pro status', e);
      // Fall back to the cached check - at worst we deny a paying
      // user once and they can retry, never a false positive.
      return isProUser();
    }
  }

  /// Same as [forceRefreshIsPro] but for Cloud Sync.
  static Future<bool> forceRefreshIsCloudSync() async {
    if (!_initialized) return false;
    try {
      await Purchases.invalidateCustomerInfoCache();
      final customerInfo = await Purchases.getCustomerInfo();
      return customerInfo.entitlements.all[cloudSyncEntitlementId]?.isActive ??
          false;
    } on PlatformException catch (e) {
      AppLogger.error('Failed to force-refresh cloud sync status', e);
      return isCloudSyncUser();
    }
  }

  /// Check if the user has the Cloud Sync entitlement.
  /// On desktop (where RevenueCat is unavailable), returns `false` (Free tier).
  static Future<bool> isCloudSyncUser() async {
    if (!_initialized) return false; // Desktop/uninitialized: Free tier
    try {
      final customerInfo = await Purchases.getCustomerInfo();
      return customerInfo
              .entitlements.all[cloudSyncEntitlementId]?.isActive ??
          false;
    } on PlatformException catch (e) {
      AppLogger.error('Failed to check cloud sync status', e);
      return false;
    }
  }

  /// Get full customer info.
  static Future<CustomerInfo> getCustomerInfo() async {
    return Purchases.getCustomerInfo();
  }

  /// Listen for real-time subscription changes.
  /// No-op on desktop where RevenueCat is unavailable.
  static void addCustomerInfoListener(
      void Function(CustomerInfo) listener) {
    if (!_initialized) return;
    Purchases.addCustomerInfoUpdateListener(listener);
  }

  // ── Offerings ──────────────────────────────────────────────────

  /// Fetch available offerings (products/packages).
  ///
  /// Throws [PurchaseUnavailableException] on desktop where the
  /// RevenueCat SDK isn't supported.  Without this guard the call
  /// would hang forever (the "Opening store…" snackbar that never
  /// resolved on Windows) because the SDK plugin is missing on
  /// non-mobile platforms.
  static Future<Offerings> getOfferings() async {
    if (!isPlatformSupported) {
      throw const PurchaseUnavailableException();
    }
    return Purchases.getOfferings();
  }

  // ── Purchases ──────────────────────────────────────────────────

  /// Purchase a specific package.
  ///
  /// Returns the [CustomerInfo] after a successful purchase.
  /// Throws [PurchaseUnavailableException] on desktop.
  static Future<CustomerInfo> purchasePackage(Package package) async {
    if (!isPlatformSupported) {
      throw const PurchaseUnavailableException();
    }
    final result = await Purchases.purchase(PurchaseParams.package(package));
    return result.customerInfo;
  }

  /// Restore previous purchases (e.g. after reinstall).
  ///
  /// Throws [PurchaseUnavailableException] on desktop - desktop
  /// users restore entitlements by signing into Cloud Sync, which
  /// mirrors the purchase from their mobile account.
  static Future<CustomerInfo> restorePurchases() async {
    if (!isPlatformSupported) {
      throw const PurchaseUnavailableException();
    }
    return Purchases.restorePurchases();
  }

  // ── User identification ────────────────────────────────────────

  /// Log in an identified user (for cloud sync matching).
  static Future<LogInResult> logIn(String userId) async {
    return Purchases.logIn(userId);
  }

  /// Log out (switch back to anonymous user).
  static Future<CustomerInfo> logOut() async {
    return Purchases.logOut();
  }

  // ── Web purchases (desktop path) ───────────────────────────────

  /// Backend URL the ZestSSH server exposes for desktop clients to
  /// read their entitlement state.  The server holds RC's REST API
  /// key (the client must not) and proxies the lookup.  Stripe /
  /// RevenueCat web webhooks write the entitlement against the same
  /// Firebase UID the user signed into Cloud Sync with, so a
  /// purchase on the web becomes visible here as soon as this
  /// endpoint reports it.
  static String get _entitlementsEndpoint => kZestEntitlementsUrl;

  /// Fetch the user's entitlement state from the ZestSSH backend.
  ///
  /// Used on desktop platforms where the RevenueCat SDK is
  /// unavailable - the backend talks to RC's REST API on our behalf
  /// using the Firebase JWT to identify the user.
  ///
  /// Returns null when the user isn't signed in (no JWT to send) or
  /// when the request fails for any reason.  Callers should treat
  /// null as "leave state unchanged" rather than "no entitlement".
  /// Last entitlement-check diagnostic. Populated on every call to
  /// [fetchWebEntitlements]. Surfaced via [EntitlementDiagnosticDialog]
  /// so we can SEE what the backend is actually saying instead of
  /// debugging by guesswork. NEVER contains the raw bearer token.
  static EntitlementDiagnostic? lastDiagnostic;

  /// What ZestSSH Cloud's answer to GET /v1/entitlements says; null when it
  /// is not one. [team]: Squeezed and Juiced from a paid team (the server
  /// counts them in pro and cloudSync already), said apart for a phone,
  /// whose own answer comes from RevenueCat.
  static ({bool pro, bool cloudSync, bool team})? webEntitlementsFrom(Object? body) {
    if (body is! Map) return null;
    final team = body['team'];
    return (
      pro: body['pro'] == true,
      cloudSync: body['cloudSync'] == true || body['cloud_sync'] == true,
      team: team is Map && team['active'] == true,
    );
  }

  static Future<({bool pro, bool cloudSync, bool team})?>
      fetchWebEntitlements() async {
    final at = DateTime.now();
    String? token;
    String? tokenSource;
    try {
      // Prefer the Firebase ID token (mobile + any platform where the
      // Firebase Auth SDK is configured). On Windows / Linux there is
      // no Firebase user - sign-in goes through the browser-OAuth
      // flow handled by DesktopAuthServer, which deposits a
      // backend-signed session JWT in secureStorage under
      // `session_token`. The backend's authenticate() middleware
      // accepts either token type (Bearer JWT first, then Firebase
      // ID-token), so we send whichever one we have.
      token = await AuthService.getIdToken();
      if (token != null) {
        tokenSource = 'firebase_id_token';
      } else {
        token = await AccountSecret.sessionToken.read(appKeychain);
        if (token != null) tokenSource = 'desktop_session_token';
      }
      if (token == null) {
        lastDiagnostic = EntitlementDiagnostic(
          at: at,
          endpoint: _entitlementsEndpoint,
          error: 'No bearer token available - user not signed in.',
        );
        return null;
      }
      // Reuse the pinned-cert client the rest of the cloud-sync
      // path already uses - same hostname, same trust anchor, no
      // extra cert configuration needed.
      //
      // No routine INFO log on every call - desktop polls this on
      // sign-in, on app launch, on every upgrade-screen visit, on
      // Diagnostic dialog refresh. INFO-logging every hit is noise
      // in release builds. The diagnostic dialog and the warning
      // path below cover the cases that actually matter.
      final resp = await PinnedHttpClient.client.get(
        Uri.parse(_entitlementsEndpoint),
        headers: {
          'Authorization': 'Bearer $token',
          ...DeviceSessionHeader.headers,
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 15));
      // Cap the snippet so a giant HTML 502 page doesn't blow up
      // the diagnostic dialog. Real responses are <100 bytes.
      final snippet = resp.body.length > 1000
          ? '${resp.body.substring(0, 1000)}…'
          : resp.body;
      lastDiagnostic = EntitlementDiagnostic(
        at: at,
        endpoint: _entitlementsEndpoint,
        httpStatus: resp.statusCode,
        responseBodySnippet: snippet,
        tokenBytes: token.length,
        tokenSource: tokenSource,
        decodedPayload: decodeJwtPayload(token),
      );
      if (resp.statusCode != 200) {
        // Log the body too - backend errors include human-readable
        // messages ("Invalid token", "User not found", etc.).
        AppLogger.warning(
          'fetchWebEntitlements: HTTP ${resp.statusCode} body=$snippet',
        );
        return null;
      }
      final said = webEntitlementsFrom(jsonDecode(resp.body));
      if (said == null) return null;
      // Persist the last known-good entitlement so a later cold launch with no
      // network keeps working offline instead of dropping the user to Free
      // (the JuiceSSH failure mode). No expiry: an offline device stays on its
      // last confirmed tier indefinitely. Hosted-sync storage is still gated
      // server-side, so this client cache only seeds local feature flags.
      await _cacheDesktopEntitlements(pro: said.pro, cloudSync: said.cloudSync);
      return said;
    } on TimeoutException catch (_) {
      AppLogger.warning('fetchWebEntitlements: timed out');
      lastDiagnostic = EntitlementDiagnostic(
        at: at,
        endpoint: _entitlementsEndpoint,
        error: 'Request timed out after 15 seconds.',
        tokenBytes: token?.length,
        tokenSource: tokenSource,
        decodedPayload: token != null ? decodeJwtPayload(token) : null,
      );
      return null;
    } catch (e) {
      AppLogger.error('fetchWebEntitlements failed', e);
      lastDiagnostic = EntitlementDiagnostic(
        at: at,
        endpoint: _entitlementsEndpoint,
        error: e.toString(),
        tokenBytes: token?.length,
        tokenSource: tokenSource,
        decodedPayload: token != null ? decodeJwtPayload(token) : null,
      );
      return null;
    }
  }

  // ── Desktop entitlement offline cache ───────────────────────────
  //
  // Desktop has no RevenueCat SDK (which caches entitlements itself), so we
  // persist the last successful backend result and seed from it on launch.
  // This is a convenience cache, not a security boundary: it is deliberately
  // forgeable, matching the project's stance that a one-time app with an
  // open-source core is not worth a DRM arms race. Real hosted-sync access is
  // enforced server-side, so a tampered flag grants only local UI features.
  static const _cacheKeyPro = 'desktop_entitlement_pro';
  static const _cacheKeyCloud = 'desktop_entitlement_cloud_sync';
  static const _cacheKeyAt = 'desktop_entitlement_checked_at';

  static Future<void> _cacheDesktopEntitlements({
    required bool pro,
    required bool cloudSync,
  }) async {
    try {
      final prefs = await appPreferences();
      await prefs.setBool(_cacheKeyPro, pro);
      await prefs.setBool(_cacheKeyCloud, cloudSync);
      await prefs.setInt(_cacheKeyAt, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // A cache write failure is non-fatal: the app still works this session,
      // it just won't have an offline seed on the next cold launch.
    }
  }

  /// Forgets the last known-good desktop entitlement: signed out, it is no
  /// one's (a computer kept the last account's tier for whoever used it next,
  /// after a restart too; 29 October 2026).
  static Future<void> forgetDesktopEntitlements() async {
    try {
      final prefs = await appPreferences();
      await prefs.remove(_cacheKeyPro);
      await prefs.remove(_cacheKeyCloud);
      await prefs.remove(_cacheKeyAt);
    } catch (_) {
      // Not written: the next sign-in's answer replaces it all the same.
    }
  }

  /// The last known-good desktop entitlement, or null if the backend has never
  /// been reached successfully on this device. Callers seed their state from
  /// this before the (possibly offline) network refresh, so a cold offline
  /// launch keeps the tier the user actually paid for.
  static Future<({bool pro, bool cloudSync})?>
      readCachedDesktopEntitlements() async {
    try {
      final prefs = await appPreferences();
      if (!prefs.containsKey(_cacheKeyPro)) return null;
      return (
        pro: prefs.getBool(_cacheKeyPro) ?? false,
        cloudSync: prefs.getBool(_cacheKeyCloud) ?? false,
      );
    } catch (_) {
      return null;
    }
  }

  /// Build the web-checkout URL the desktop client opens in a
  /// browser: the tier, the platform, and a `return` deep-link so the
  /// website can bounce the user back into the desktop app once
  /// payment succeeds (`zestssh://upgrade-complete`). It names no
  /// account: the purchase goes to the account signed in on the
  /// website (the server reads it from that sign-in), so an id here
  /// would only sit in the browser's history and the website's logs.
  static Uri buildWebUpgradeUrl({String tier = 'pro'}) {
    final params = <String, String>{
      'tier': tier,
      'return': 'zestssh://upgrade-complete',
      'platform': Platform.operatingSystem,
    };
    return Uri.parse('$kZestWebsite/upgrade')
        .replace(queryParameters: params);
  }
}
