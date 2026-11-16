import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// On an iPhone or iPad, what the app saves for the person (backups, SFTP
/// downloads, a terminal's text, session logs and recordings) goes to the
/// app's Documents folder, which the Files app showed only once the app says
/// so (neither key was set, so a backup
/// or a download could never leave the device). What must stay out of sight
/// is not kept there: the database, the Orchards' databases and the backups
/// made before a migration are in Application Support, the secrets in the
/// Keychain, the settings in the app's preferences.
///
/// iOS's files do not run here: they are read.
void main() {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();

  test('the Files app shows the app\'s Documents folder', () {
    expect(plist, matches(RegExp(r'<key>UIFileSharingEnabled</key>\s*<true/>')));
    expect(plist, matches(RegExp(r'<key>LSSupportsOpeningDocumentsInPlace</key>\s*<true/>')));
  });

  test('the database and the copies made before a migration are not in Documents', () {
    final database = File('lib/database/database.dart').readAsStringSync();
    expect(database, isNot(contains('getApplicationDocumentsDirectory')));
    expect(database, contains('_databaseDirectory() => ProfilePaths.databaseDirectory()'));
    // On a phone that is the folder below, as ever; on a computer a profile
    // inside it.
    final paths = File('lib/services/profiles/active_profile.dart').readAsStringSync();
    final dir = RegExp(r'static Future<Directory> base\(\) async \{(.*?)\n  \}', dotAll: true)
        .firstMatch(paths)!
        .group(1)!;
    expect(dir, contains('getApplicationSupportDirectory()'));
    expect(dir, isNot(contains('getApplicationDocumentsDirectory')));
    final migration = File('lib/services/migration_backup_service.dart').readAsStringSync();
    expect(migration, isNot(contains('getApplicationDocumentsDirectory')));
  });
}
