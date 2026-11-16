import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/backup/webdav_destination.dart';

void main() {
  group('WebDavBackupDestination secret handling', () {
    final dest = WebDavBackupDestination(
      serverUrl: 'https://cloud.example.com/remote.php/dav',
      username: 'alice',
      password: 'super-secret-token',
      remotePath: '/ZestSSH/backups/',
      label: 'Home Nextcloud',
    );

    test('toJson NEVER serializes the password (it goes to secure storage)',
        () {
      final json = dest.toJson();
      expect(json.containsKey('password'), isFalse);
      // Belt and braces: the secret value must not leak under any key.
      expect(json.values.whereType<String>(),
          isNot(contains('super-secret-token')));
      // Non-secret fields ARE persisted.
      expect(json['serverUrl'], dest.serverUrl);
      expect(json['username'], 'alice');
    });

    test('fromJson tolerates a missing password (empty), withPassword injects',
        () {
      final json = dest.toJson();
      final loaded = WebDavBackupDestination.fromJson(json);
      expect(loaded.password, isEmpty); // not present in JSON
      final hydrated = loaded.withPassword('super-secret-token');
      expect(hydrated.password, 'super-secret-token');
      expect(hydrated.id, dest.id); // id is stable across the round-trip
      expect(hydrated.serverUrl, dest.serverUrl);
    });
  });
}
