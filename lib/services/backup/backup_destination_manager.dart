import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/auto_backup_service.dart' show AutoBackupKind;
import 'package:zestssh/services/backup/backup_destination.dart';
import 'package:zestssh/services/backup/google_drive_destination.dart';
import 'package:zestssh/services/backup/local_destination.dart';
import 'package:zestssh/services/backup/webdav_destination.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/profiles/keychain.dart';

/// Manages multiple [BackupDestination]s and orchestrates multi-destination
/// backup operations.
///
/// Destinations are persisted as JSON in [SharedPreferences] so the user's
/// configuration survives restarts.
class BackupDestinationManager {
  static const _prefsKey = 'backup_destinations';

  final SharedPreferences _prefs;

  /// Secrets (WebDAV passwords) live HERE - Keychain / EncryptedSharedPreferences
  /// - keyed by destination id, never in the plaintext prefs JSON.
  final FlutterSecureStorage _secure;

  static String _secretKey(String id) => 'backup_dest_secret_$id';

  /// Your Tree's database, whose seal keeps the passwords while the
  /// encrypting lock is on (SecretSeal); none while the app is locked.
  final AppDatabase? Function() _tree;

  /// In-memory list of configured destinations.
  List<BackupDestination> _destinations;

  BackupDestinationManager({
    required SharedPreferences prefs,
    FlutterSecureStorage? secureStorage,
    List<BackupDestination>? initial,
    AppDatabase? Function()? tree,
  })  : _prefs = prefs,
        _secure = secureStorage ?? appKeychain,
        _tree = tree ?? (() => SecretSeal.openTree),
        _destinations = initial ?? [];

  /// Persist a destination's secret to secure storage (WebDAV password).
  Future<void> _writeSecret(BackupDestination dest) async {
    if (dest is WebDavBackupDestination && dest.password.isNotEmpty) {
      final slot = _secretKey(dest.id);
      await _secure.write(key: slot, value: await keepSealed(_tree(), slot, dest.password));
    }
  }

  /// Current list of configured destinations (read-only view).
  List<BackupDestination> get destinations =>
      List.unmodifiable(_destinations);

  // ── CRUD ─────────────────────────────────────────────────────────

  /// Add a new destination and persist.
  Future<void> addDestination(BackupDestination destination) async {
    // Prevent duplicate IDs.
    if (_destinations.any((d) => d.id == destination.id)) {
      throw StateError(
        'Destination with id "${destination.id}" already exists.',
      );
    }
    _destinations.add(destination);
    await _writeSecret(destination);
    await _persist();
    AppLogger.info(
      'Backup destination added: ${destination.displayName} '
      '(${destination.name})',
    );
  }

  /// Remove a destination by [id] and persist.
  Future<bool> removeDestination(String id) async {
    final lengthBefore = _destinations.length;
    _destinations.removeWhere((d) => d.id == id);
    await _secure.delete(key: _secretKey(id));
    await _persist();
    return _destinations.length < lengthBefore;
  }

  /// Replace a destination in-place (e.g. after editing credentials).
  Future<void> updateDestination(BackupDestination destination) async {
    final index =
        _destinations.indexWhere((d) => d.id == destination.id);
    if (index == -1) {
      throw StateError(
        'Destination with id "${destination.id}" not found.',
      );
    }
    _destinations[index] = destination;
    await _writeSecret(destination);
    await _persist();
  }

  /// Get a destination by its [id].
  BackupDestination? getDestination(String id) {
    try {
      return _destinations.firstWhere((d) => d.id == id);
    } catch (_) {
      return null;
    }
  }

  // ── Multi-destination operations ─────────────────────────────────

  /// Upload a backup file to ALL configured destinations.
  ///
  /// Failures are logged and collected but do NOT stop other
  /// destinations from receiving the backup.
  Future<Map<String, String?>> backupToAll(
    File backupFile,
    String filename,
  ) async {
    final errors = <String, String?>{};

    for (final dest in _destinations) {
      try {
        final authed = await dest.isAuthenticated();
        if (!authed) {
          errors[dest.id] = 'Not authenticated';
          AppLogger.warning(
            'Skipping ${dest.displayName}: not authenticated',
          );
          continue;
        }
        await dest.uploadBackup(backupFile, filename);
        errors[dest.id] = null; // null = success
      } catch (e) {
        errors[dest.id] = e.toString();
        AppLogger.error(
          'Backup to ${dest.displayName} failed',
          e,
        );
      }
    }

    final successes = errors.values.where((e) => e == null).length;
    AppLogger.info(
      'Backup distributed: $successes/${_destinations.length} destinations OK',
    );
    return errors;
  }

  /// Keeps at each destination of [ids] (those [justCopied] was just copied
  /// to) as many automatic backups of each kind as this device keeps
  /// ([AutoBackupKind.keep]), the newest by name; the older ones of that kind
  /// are deleted (3.4.2 sweep, L8: the app deleted none, and with a backup on
  /// every change each place filled without end). A backup the person made,
  /// and anything else there, is never touched, nor is [justCopied]. A place
  /// that cannot be listed or cleared is left as it is; answers with the
  /// names deleted, by destination.
  Future<Map<String, List<String>>> pruneAutoBackups(Iterable<String> ids, {required String justCopied}) async {
    final kind = AutoBackupKind.of(justCopied);
    final deleted = <String, List<String>>{};
    if (kind == null) return deleted;
    for (final id in ids) {
      final dest = getDestination(id);
      if (dest == null) continue;
      try {
        final names = [
          for (final f in await dest.listBackups())
            if (AutoBackupKind.of(f.filename) == kind) f.filename,
        ];
        // The one just copied is among those kept, whatever the names say.
        if (!names.contains(justCopied)) continue;
        names.sort((a, b) => b.compareTo(a));
        final kept = {...names.take(kind.keep), justCopied};
        for (final name in names) {
          if (kept.contains(name)) continue;
          await dest.deleteBackup(name);
          (deleted[id] ??= []).add(name);
        }
      } catch (e) {
        AppLogger.warning('Old automatic backups at ${dest.displayName} not cleared: ${errorKind(e)}');
      }
    }
    return deleted;
  }

  /// Check health of all configured destinations.
  Future<BackupHealthStatus> checkHealth() async {
    final statuses = <DestinationHealthStatus>[];

    for (final dest in _destinations) {
      try {
        final authed = await dest.isAuthenticated();
        List<BackupFileInfo> backups = [];
        if (authed) {
          try {
            backups = await dest.listBackups();
          } catch (_) {
            // Listing may fail even if auth works - treat as degraded.
          }
        }

        statuses.add(DestinationHealthStatus(
          destinationId: dest.id,
          destinationName: dest.displayName,
          isAuthenticated: authed,
          lastSuccessfulBackup: backups.isNotEmpty
              ? backups.first.createdAt
              : null,
          consecutiveFailures: authed ? 0 : 1,
        ));
      } catch (e) {
        statuses.add(DestinationHealthStatus(
          destinationId: dest.id,
          destinationName: dest.displayName,
          isAuthenticated: false,
          lastError: e.toString(),
          consecutiveFailures: 1,
        ));
      }
    }

    return BackupHealthStatus(destinations: statuses);
  }

  // ── Persistence ──────────────────────────────────────────────────

  /// Save the current destination list to SharedPreferences as JSON.
  Future<void> _persist() async {
    final jsonList =
        _destinations.map((d) => d.toJson()).toList();
    await _prefs.setString(_prefsKey, jsonEncode(jsonList));
  }

  /// Load destinations from SharedPreferences.
  ///
  /// Call this once at app startup after constructing the manager.
  Future<void> loadFromPrefs() async {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      _destinations = [];
      return;
    }

    try {
      final jsonList = jsonDecode(raw) as List<dynamic>;
      final parsed = jsonList
          .map((e) => _fromJson(e as Map<String, dynamic>))
          .whereType<BackupDestination>()
          .toList();
      // Re-inject WebDAV secrets from secure storage (they are not in the JSON).
      final hydrated = <BackupDestination>[];
      var migratedLegacyPlaintext = false;
      for (final d in parsed) {
        if (d is WebDavBackupDestination && d.password.isEmpty) {
          // Opened where the encrypting lock sealed it; none where it does
          // not open (the app is locked).
          final slot = _secretKey(d.id);
          final pw = await openKept(_tree(), slot, await _secure.read(key: slot));
          hydrated.add(pw == null ? d : d.withPassword(pw));
        } else if (d is WebDavBackupDestination && d.password.isNotEmpty) {
          // A NON-empty password came from a legacy prefs JSON that predates the
          // secure-storage migration (older builds serialized the password into
          // the plaintext prefs). Migrate it into secure storage now and flag a
          // re-persist so the current toJson (which omits the password) rewrites
          // the prefs file and scrubs the plaintext credential.
          await _writeSecret(d);
          hydrated.add(d);
          migratedLegacyPlaintext = true;
        } else {
          hydrated.add(d);
        }
      }
      _destinations = hydrated;
      // One-time scrub: rewrite prefs so any lingering plaintext password field
      // is removed (toJson no longer includes it).
      if (migratedLegacyPlaintext) {
        await _persist();
        AppLogger.info('Migrated a legacy plaintext WebDAV password to secure '
            'storage and scrubbed it from prefs');
      }
      AppLogger.info(
        'Loaded ${_destinations.length} backup destination(s) from prefs',
      );
    } catch (e) {
      AppLogger.error('Failed to load backup destinations', e);
      _destinations = [];
    }
  }

  /// Deserialize a single destination from its JSON representation.
  static BackupDestination? _fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String?;
    switch (name) {
      case 'local':
        return LocalBackupDestination.fromJson(json);
      case 'webdav':
        return WebDavBackupDestination.fromJson(json);
      case 'google_drive':
        return GoogleDriveBackupDestination.fromJson(json);
      default:
        AppLogger.warning('Unknown backup destination type: $name');
        return null;
    }
  }
}
