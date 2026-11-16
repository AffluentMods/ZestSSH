import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/sync_disconnect.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';

/// The background sync, as far as turning it off goes.
class _Auto extends Fake implements AutoSyncService {
  _Auto(this.done);

  final List<String> done;

  @override
  void stopAutoSync() => done.add('stop the timers');

  @override
  Future<void> clearSyncCredentials() async => done.add('forget the keys');

  @override
  void resetFailures() => done.add('forget the failures');
}

/// Turning sync off on this device (3.0): the timers stop, the keys and
/// what the device remembered of the store are forgotten, setup is back at
/// its start, and nothing else on the device is touched.
void main() {
  const storage = FlutterSecureStorage();
  late List<String> done;
  late SettingsService settings;
  late SyncSetupStateService setup;

  setUp(() async {
    done = [];
    FlutterSecureStorage.setMockInitialValues({
      'sync_salt': 'c2FsdA==',
      'session_token': 'a-session',
      'identity_key_7': 'a-private-key',
    });
    SharedPreferences.setMockInitialValues({
      'sync_server_version': 12,
      'sync_content_hash': 'what-was-last-agreed',
      'sync_dirty': true,
      'sync_mode': 'auto',
      'app_theme_id': 'graphite',
    });
    settings = SettingsService(await SharedPreferences.getInstance());
    setup = SyncSetupStateService(storage);
    await setup.beginSetup();
    await setup.markPasswordChosen(salt: List<int>.filled(32, 7));
    await setup.markRecoverySaved(recoverySalt: List<int>.filled(32, 9));
    await setup.markRecoveryConfirmed();
    await setup.markComplete();
  });

  Future<void> disconnect() => disconnectSyncOnThisDevice(
        autoSync: _Auto(done),
        setup: setup,
        settings: settings,
        secureStorage: storage,
        lockVault: () => done.add('lock the vault'),
      );

  test('sync was on: afterwards it is not set up, and the device remembers nothing of the store', () async {
    expect(await setup.isSyncActive(), isTrue);
    await disconnect();

    final snapshot = await setup.snapshot();
    expect(snapshot.step, SyncSetupStep.notStarted);
    expect(snapshot.isComplete, isFalse);
    expect(snapshot.hasSalt, isFalse);
    expect(snapshot.hasRecoverySalt, isFalse);
    expect(await storage.read(key: 'sync_salt'), isNull, reason: 'the salt of the password that was');
    expect(settings.syncServerVersion, 0);
    expect(settings.syncContentHash, '');
    expect(settings.syncDirty, isFalse, reason: 'nothing waits to go up to a store that is not there');
  });

  test('the timers stop first, the keys go, a key held unlocked is dropped, and old failures are forgotten last',
      () async {
    await disconnect();
    expect(done, ['stop the timers', 'forget the keys', 'lock the vault', 'forget the failures']);
  });

  test('nothing else on the device is touched', () async {
    await disconnect();
    expect(await storage.read(key: 'session_token'), 'a-session', reason: 'still signed in');
    expect(await storage.read(key: 'identity_key_7'), 'a-private-key', reason: 'the data stays');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_theme_id'), 'graphite');
    expect(settings.syncMode, 'auto', reason: 'how sync runs once it is set up again is kept');
  });

  test('changing the store for another turns sync off through this, and keeps no steps of its own', () {
    final picker = File('lib/ui/screens/settings/sync_backend_screen.dart').readAsStringSync().replaceAll('\r\n', '\n');
    expect(picker, contains('Future<void> _disconnectLocally() => disconnectSyncOnThisDevice('));
    expect(picker, contains('lockVault: ref.read(vaultSessionProvider.notifier).lock,'));
    expect(picker, contains('await _disconnectLocally();'));
    for (final step in ['clearSyncCredentials()', 'setSyncServerVersion(', "delete(key: 'sync_salt')", 'stopAutoSync()']) {
      expect(picker, isNot(contains(step)), reason: step);
    }
  });

  test('on a device where sync was never set up it changes nothing and does not fail', () async {
    FlutterSecureStorage.setMockInitialValues({'session_token': 'a-session'});
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
    setup = SyncSetupStateService(storage);
    await disconnect();
    expect((await setup.snapshot()).step, SyncSetupStep.notStarted);
    expect(settings.syncServerVersion, 0);
    expect(await storage.read(key: 'session_token'), 'a-session');
  });
}
