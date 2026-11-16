import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/backup/backup_destination_manager.dart';
import 'package:zestssh/services/backup/webdav_destination.dart';

/// Proves the security-audit fix: a legacy WebDAV password sitting in the
/// PLAINTEXT prefs JSON (from a build that predated the secure-storage move) is
/// migrated into secure storage AND scrubbed from prefs on the next load.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secretValue = 'super-secret-webdav-token';
  const prefsKey = 'backup_destinations';

  test('legacy plaintext WebDAV password is migrated to secure storage and '
      'scrubbed from prefs on load', () async {
    // A legacy prefs entry that STILL carries the password inline (old format).
    final legacy = [
      {
        'name': 'webdav',
        'serverUrl': 'https://cloud.example.com/remote.php/dav',
        'username': 'alice',
        'password': secretValue,
        'remotePath': '/ZestSSH/backups/',
        'label': 'Home Nextcloud',
      }
    ];
    SharedPreferences.setMockInitialValues({prefsKey: jsonEncode(legacy)});
    FlutterSecureStorage.setMockInitialValues({}); // nothing migrated yet

    final prefs = await SharedPreferences.getInstance();
    final mgr = BackupDestinationManager(
      prefs: prefs,
      secureStorage: const FlutterSecureStorage(),
    );
    await mgr.loadFromPrefs();

    // 1) The destination loaded and its password is available in memory.
    final dest = mgr.destinations.single as WebDavBackupDestination;
    expect(dest.password, secretValue);

    // 2) The secret is now in secure storage.
    final secureDump = await const FlutterSecureStorage().readAll();
    expect(secureDump.values, contains(secretValue),
        reason: 'password must be migrated into secure storage');

    // 3) The plaintext prefs JSON no longer contains the password.
    final rewritten = prefs.getString(prefsKey) ?? '';
    expect(rewritten.contains(secretValue), isFalse,
        reason: 'plaintext password must be scrubbed from prefs');
    expect(rewritten.contains('password'), isFalse,
        reason: 'the password field itself must be gone from prefs');

    // 4) A fresh manager over the now-scrubbed prefs still recovers the
    //    password from secure storage (round-trips end to end).
    final mgr2 = BackupDestinationManager(
      prefs: prefs,
      secureStorage: const FlutterSecureStorage(),
    );
    await mgr2.loadFromPrefs();
    expect((mgr2.destinations.single as WebDavBackupDestination).password,
        secretValue);
  });
}
