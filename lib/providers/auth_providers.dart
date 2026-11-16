import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart' show keptSessionUid;
import 'package:zestssh/services/profiles/active_profile.dart' show Profiles;
import 'package:zestssh/providers/sync_providers.dart' show syncProviderConfigProvider;
import 'package:zestssh/services/sync/sync_backend.dart' show SyncBackendKind;
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/utils/logger.dart';

/// Stream of Firebase auth state changes.
final authStateProvider = StreamProvider<User?>((ref) {
  return AuthService.authStateChanges;
});

/// Desktop session state - set when signing in via browser on desktop.
/// Holds email/name from the session token exchange.
final desktopSessionProvider =
    StateProvider<UserProfile?>((ref) => null);

/// Whether the user is currently signed in (Firebase OR desktop session).
final isSignedInProvider = Provider<bool>((ref) {
  final firebaseUser = ref.watch(authStateProvider).valueOrNull;
  if (firebaseUser != null) return true;
  final desktopSession = ref.watch(desktopSessionProvider);
  return desktopSession != null;
});

/// The session kept in the profile open now, as the app's state holds it: null where
/// none is kept. A session that names no account is the account of no profile: on a
/// computer it is never taken for "an unknown account", and goes.
Future<UserProfile?> keptDesktopSession(FlutterSecureStorage storage) async {
  final token = await AccountSecret.sessionToken.read(storage);
  if (token == null) return null;
  final email = await storage.read(key: 'session_email');
  final name = await storage.read(key: 'session_name');
  final photo = await storage.read(key: 'session_photo');
  // A session kept before its account's id was: the token says it.
  final uid = await keptSessionUid(storage, token);
  if (uid == null && Profiles.on) {
    await AccountSecret.sessionToken.delete(storage);
    return null;
  }
  return UserProfile(uid: uid ?? 'desktop-session', email: email, displayName: name, photoUrl: photo);
}

/// Current user display info (Firebase OR desktop session).
final currentUserProvider = Provider<UserProfile?>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user != null) {
    return UserProfile(
      uid: user.uid,
      email: user.email,
      displayName: user.displayName,
      photoUrl: user.photoURL,
    );
  }
  // Fall back to desktop session
  return ref.watch(desktopSessionProvider);
});

/// Simple user profile data class.
class UserProfile {
  final String uid;
  final String? email;
  final String? displayName;
  final String? photoUrl;

  const UserProfile({
    required this.uid,
    this.email,
    this.displayName,
    this.photoUrl,
  });
}

/// Sync status provider.
final syncStatusProvider =
    StateNotifierProvider<SyncStatusNotifier, SyncState>((ref) {
  // Whether sync goes to ZestSSH Cloud, as it stands when something fails:
  // what is said of a failure depends on whose storage it was.
  return SyncStatusNotifier(
    hosted: () => ref.read(syncProviderConfigProvider).kind == SyncBackendKind.zestServer,
  );
});

class SyncState {
  final bool isSyncing;
  final DateTime? lastSyncedAt;
  final int? blobSize;

  /// Plain-language error headline shown in the sync-status card. Never a raw
  /// exception string - see [SyncStatusNotifier.setErrorFrom].
  final String? error;

  /// Raw technical text behind a "Copy details" button, when [error] came from
  /// a source that had something worth keeping. Null otherwise.
  final String? errorDetail;

  const SyncState({
    this.isSyncing = false,
    this.lastSyncedAt,
    this.blobSize,
    this.error,
    this.errorDetail,
  });

  SyncState copyWith({
    bool? isSyncing,
    DateTime? lastSyncedAt,
    int? blobSize,
    String? error,
    String? errorDetail,
  }) {
    return SyncState(
      isSyncing: isSyncing ?? this.isSyncing,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      blobSize: blobSize ?? this.blobSize,
      error: error,
      errorDetail: errorDetail,
    );
  }
}

class SyncStatusNotifier extends StateNotifier<SyncState> {
  SyncStatusNotifier({bool Function()? hosted})
      : _hosted = hosted ?? (() => true),
        super(const SyncState());

  /// Whether sync goes to ZestSSH Cloud (and not to storage of the
  /// person's own).
  final bool Function() _hosted;

  void setSyncing(bool syncing) {
    state = state.copyWith(isSyncing: syncing, error: null);
  }

  void setSynced(DateTime at, int size) {
    state = SyncState(
      isSyncing: false,
      lastSyncedAt: at,
      blobSize: size,
      error: null,
    );
  }

  void setError(String error, {String? detail}) {
    state = state.copyWith(isSyncing: false, error: error, errorDetail: detail);
    AppLogger.error(
        'Sync error: $error${detail != null ? ' | detail: $detail' : ''}');
  }

  /// Translate any caught object into a headline a person can act on, with
  /// what stands behind it kept for "Copy details", so that the sync-status
  /// card never shows a raw `SocketException` / `ClientException` / stack
  /// trace. What the store said in so many words is left as it was said; a
  /// store that could not be reached, or answered with a fault of its own,
  /// is said as that, with its code ([SyncFailure.ofStore]).
  void setErrorFrom(Object e) {
    final failure = SyncFailure.ofStore(e, hosted: _hosted());
    setError(failure.message, detail: failure.detail);
  }

  /// What [setErrorFrom] says of [e], for a notice that says the same.
  String messageOf(Object e) => SyncFailure.ofStore(e, hosted: _hosted()).message;

  void clear() {
    state = const SyncState();
  }
}
