import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/password_managers/agent_sources.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/providers/core_providers.dart';

// This device's password manager settings (3.0): where each tool
// is when it is not where ZestSSH looks, and KeePassXC's database. Kept in
// this device's preferences (none of it is secret, and it is not in the
// settings that sync), and the one [PasswordManagers] that fetches with
// them. The app forgets what unlocked Bitwarden or KeePassXC when it locks
// or signs out ([PasswordManagers.lock], called from the app's root and the
// sign-out).

const _prefsKey = 'password_managers_v1';

class PasswordManagerSettingsNotifier extends StateNotifier<PasswordManagerSettings> {
  PasswordManagerSettingsNotifier(this._prefs) : super(read(_prefs));

  final SharedPreferences _prefs;

  /// The settings stored in [prefs]; anything unreadable is left out.
  static PasswordManagerSettings read(SharedPreferences prefs) {
    try {
      final json = jsonDecode(prefs.getString(_prefsKey) ?? '{}');
      if (json is! Map) return const PasswordManagerSettings();
      final paths = <PasswordManagerKind, String>{};
      final rawPaths = json['paths'];
      if (rawPaths is Map) {
        for (final e in rawPaths.entries) {
          final kind = PasswordManagerKind.fromCode(e.key);
          if (kind != null && e.value is String && (e.value as String).isNotEmpty) paths[kind] = e.value as String;
        }
      }
      final kpx = json['kpx'];
      final database = kpx is Map && kpx['path'] is String && (kpx['path'] as String).isNotEmpty
          ? KeePassXcDatabase(
              path: kpx['path'] as String,
              keyFile: kpx['keyFile'] is String && (kpx['keyFile'] as String).isNotEmpty ? kpx['keyFile'] as String : null,
              noPassword: kpx['noPassword'] == true,
            )
          : null;
      return PasswordManagerSettings(paths: paths, keePassXc: database);
    } catch (_) {
      return const PasswordManagerSettings();
    }
  }

  Future<void> _save(PasswordManagerSettings s) async {
    state = s;
    await _prefs.setString(
        _prefsKey,
        jsonEncode({
          'paths': {for (final e in s.paths.entries) e.key.code: e.value},
          if (s.keePassXc case final db?)
            'kpx': {'path': db.path, 'keyFile': ?db.keyFile, 'noPassword': db.noPassword},
        }));
  }

  /// Where [kind]'s tool is on this device; null or empty: where ZestSSH
  /// looks.
  Future<void> setToolPath(PasswordManagerKind kind, String? path) {
    final paths = {...state.paths}..remove(kind);
    if (path != null && path.trim().isNotEmpty) paths[kind] = path.trim();
    return _save(PasswordManagerSettings(paths: paths, keePassXc: state.keePassXc));
  }

  /// KeePassXC's database on this device, or none.
  Future<void> setKeePassXc(KeePassXcDatabase? database) =>
      _save(PasswordManagerSettings(paths: state.paths, keePassXc: database));
}

final passwordManagerSettingsProvider =
    StateNotifierProvider<PasswordManagerSettingsNotifier, PasswordManagerSettings>(
        (ref) => PasswordManagerSettingsNotifier(ref.watch(sharedPreferencesProvider)));

/// Fetches passwords from password managers on this device (desktops only:
/// null on phones, which have no tools to fetch with).
final passwordManagersProvider = Provider<PasswordManagers?>((ref) {
  if (!PasswordManagers.supported) return null;
  final managers = PasswordManagers(settings: () => ref.read(passwordManagerSettingsProvider));
  ref.onDispose(managers.lock);
  return managers;
});

/// Where the agent of an agent-backed key listens on this device: [override]
/// (this device's own setting) when set, else [source]'s place, else null
/// for the system agent.
String? agentSocketHere(String? source, {String? override}) => agentSocketFor(
      AgentSource.of(source),
      override: override,
      environment: Platform.environment,
      exists: (p) => FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound,
      isWindows: Platform.isWindows,
      isMacOS: Platform.isMacOS,
    );
