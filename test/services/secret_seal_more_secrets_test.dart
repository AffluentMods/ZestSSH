import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/export/export_settings.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/auto_backup_service.dart';
import 'package:zestssh/services/backup/backup_destination_manager.dart';
import 'package:zestssh/services/backup/webdav_destination.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/google_desktop_oauth.dart';
import 'package:zestssh/services/prometheus_secure_settings.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';

/// The secrets the encrypting lock left as they were: the
/// automatic backups' password first, kept beside backups that hold every
/// key's secret, so whatever could read the system's secure storage opened
/// those backups without the PIN; then the WebDAV backup places' passwords,
/// the monitoring server's sign-in, the session recordings' key, the Google
/// sign-in on a computer, this device's team signing key and a team's event
/// export entry.
const _password = 'correct horse battery staple demo';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  const storage = FlutterSecureStorage();
  late AppDatabase db;
  late SettingsService settings;

  setUp(() async {
    L10nGlobal.update(en);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SecretSeal.openTree = null;
  });
  tearDown(() async {
    SecretSeal.openTree = null;
    await db.close();
  });

  Future<Map<String, String>> kept() => storage.readAll();

  group("the automatic backups' password", () {
    test('with the encrypting lock on it is kept sealed, and the storage alone does not give it', () async {
      await SecretSeal.setActive(db, true);
      await AutoBackupService.keepPassword(storage, db, _password);
      final raw = (await kept())[AutoBackupService.passwordKey]!;
      expect(raw, startsWith(SecretSeal.prefix));
      expect(raw, isNot(contains(_password)));
      expect(await AutoBackupService.readPassword(storage, db), _password);
      await expectLater(AutoBackupService.readPassword(storage, null), throwsA(isA<AutoBackupPasswordLocked>()),
          reason: 'without the database (the app locked) it does not open');
      final other = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(other.close);
      await SecretSeal.setActive(other, true);
      await expectLater(AutoBackupService.readPassword(storage, other), throwsA(isA<AutoBackupPasswordLocked>()),
          reason: "another database's seal does not open it");
    });

    test('a backup still runs while the app is unlocked, with the password as it was given', () async {
      await settings.setAutoBackupInterval('daily');
      await SecretSeal.setActive(db, true);
      await AutoBackupService.keepPassword(storage, db, _password);
      final backups = _Backups(db);
      final outcome =
          await AutoBackupService.checkAndRunAutoBackup(backupService: backups, settings: settings, secureStorage: storage);
      expect(outcome.status, AutoBackupStatus.made);
      expect(backups.exported, [_password]);
      final onLeaving =
          await AutoBackupService.backupIfDirty(backupService: backups, settings: settings, secureStorage: storage);
      expect(onLeaving.status, AutoBackupStatus.made);
      expect(backups.exported, [_password, _password]);
    });

    test('where it does not open, none is made, and the notice says why, not that there is no password', () async {
      await settings.setAutoBackupInterval('daily');
      await SecretSeal.setActive(db, true);
      await AutoBackupService.keepPassword(storage, db, _password);
      final other = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(other.close);
      final backups = _Backups(other);
      final outcome =
          await AutoBackupService.checkAndRunAutoBackup(backupService: backups, settings: settings, secureStorage: storage);
      expect(outcome.status, AutoBackupStatus.failed);
      expect(outcome.error, en.backupSealedPasswordLocked);
      expect(backups.exported, isEmpty);
      expect((await AutoBackupService.backupIfDirty(backupService: backups, settings: settings, secureStorage: storage)).error,
          en.backupSealedPasswordLocked);
    });

    test('with the lock off it is kept as it was', () async {
      await AutoBackupService.keepPassword(storage, db, _password);
      expect((await kept())[AutoBackupService.passwordKey], _password);
      expect(await AutoBackupService.readPassword(storage, null), _password);
    });

    test('every language says it its own way', () {
      for (final locale in AppLocalizations.supportedLocales) {
        if (locale.languageCode == 'en') continue;
        expect(lookupAppLocalizations(locale).backupSealedPasswordLocked, isNot(en.backupSealedPasswordLocked),
            reason: '$locale');
      }
    });
  });

  test('turning the lock on seals each of them, kept before as they were; turning it off keeps them as they were '
      'again', () async {
    final p12 = base64Encode(Uint8List.fromList(List<int>.generate(48, (i) => i)));
    final seed = base64Encode(List<int>.filled(32, 7));
    const plainOnes = {
      'prometheus_ca_pem': '-----BEGIN CERTIFICATE-----demo',
      'prometheus_basic_user': 'grafana-demo',
      'session_email': 'person@example.com',
    };
    final secrets = {
      AutoBackupService.passwordKey: _password,
      'backup_dest_secret_webdav_1a2b': 'webdav-pass-demo',
      'prometheus_client_cert_p12': p12,
      'prometheus_client_cert_pass': 'p12-pass-demo',
      'prometheus_bearer_token': 'bearer-demo',
      'prometheus_basic_pass': 'basic-pass-demo',
      'prometheus_custom_header_val': 'header-demo',
      'zestssh_transcript_encryption_key': 'ab' * 32,
      'google_desktop_oauth_v1': '{"refresh_token":"refresh-demo"}',
      'orchard_device_key_v1.uid-a': seed,
      'orchard_export_v1.uid-a.o-1': '{"url":"https://events.example.com","header_value":"export-demo"}',
    };
    FlutterSecureStorage.setMockInitialValues({...secrets, ...plainOnes});
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
    ]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(db);
    expect(SecretSeal.openTree, same(db), reason: 'the session tells the stores no provider reaches');

    await container.read(isAppLockedProvider.notifier).enableEncryptingLock(pin: '482915');
    var all = await kept();
    for (final e in secrets.entries) {
      expect(all[e.key], startsWith(SecretSeal.prefix), reason: e.key);
      expect(all[e.key], isNot(contains(e.value)), reason: e.key);
    }
    for (final e in plainOnes.entries) {
      expect(all[e.key], e.value, reason: '${e.key} is not a secret');
    }

    // Each is read as it was by the place that reads it.
    final prometheus = PrometheusSecureSettings(storage, tree: () => db);
    expect(await prometheus.getBearerToken(), 'bearer-demo');
    expect(await prometheus.getBasicAuthPassword(), 'basic-pass-demo');
    expect(await prometheus.getClientCertPassword(), 'p12-pass-demo');
    expect(await prometheus.getCustomHeaderValue(), 'header-demo');
    expect(base64Encode((await prometheus.getClientCertP12Bytes())!), p12);
    expect(await prometheus.getBasicAuthUser(), 'grafana-demo');
    expect(await const KeychainGoogleTokenStore().read(), '{"refresh_token":"refresh-demo"}');
    expect((await DeviceIdentityStore(storage, tree: () => db).read('uid-a'))!.seed, base64Decode(seed));
    expect(await AutoBackupService.readPassword(storage, db), _password);
    // While locked, none, never the sealed text.
    expect(await PrometheusSecureSettings(storage, tree: () => null).getBearerToken(), isNull);

    await container.read(isAppLockedProvider.notifier).disableEncryptingLock('482915');
    all = await kept();
    for (final e in secrets.entries) {
      expect(all[e.key], e.value, reason: '${e.key} kept as it was again');
    }
    // Written from now on, as they are.
    await prometheus.setBearerToken('bearer-2-demo');
    expect((await kept())['prometheus_bearer_token'], 'bearer-2-demo');
  });

  test('written while the lock is on, each store keeps its secret sealed and reads it back', () async {
    await SecretSeal.setActive(db, true);
    SecretSeal.openTree = db;

    final prometheus = PrometheusSecureSettings(storage);
    await prometheus.setBasicAuthPassword('basic-pass-demo');
    expect((await kept())['prometheus_basic_pass'], startsWith(SecretSeal.prefix));
    expect(await prometheus.getBasicAuthPassword(), 'basic-pass-demo');

    await const KeychainGoogleTokenStore().write('{"refresh_token":"refresh-demo"}');
    expect((await kept())['google_desktop_oauth_v1'], startsWith(SecretSeal.prefix));

    final exports = ExportSettingsStore(storage);
    await exports.writeSent('uid-a', 'o-1', 'as far as this');
    expect((await kept())['orchard_export_v1.uid-a.o-1.sent'], startsWith(SecretSeal.prefix));
    expect(await exports.readSent('uid-a', 'o-1'), 'as far as this');

    SharedPreferences.setMockInitialValues({});
    final manager = BackupDestinationManager(prefs: await SharedPreferences.getInstance(), secureStorage: storage);
    final dest = WebDavBackupDestination(
        serverUrl: 'https://cloud.example.com/remote.php/dav', username: 'alice', password: 'webdav-pass-demo');
    await manager.addDestination(dest);
    final slot = 'backup_dest_secret_${dest.id}';
    expect((await kept())[slot], startsWith(SecretSeal.prefix));
    final loaded = BackupDestinationManager(prefs: await SharedPreferences.getInstance(), secureStorage: storage);
    await loaded.loadFromPrefs();
    expect((loaded.destinations.single as WebDavBackupDestination).password, 'webdav-pass-demo');
  });

  test("a device's team key sealed and read while the app is locked is never replaced", () async {
    await SecretSeal.setActive(db, true);
    final store = DeviceIdentityStore(storage, tree: () => db);
    final made = await store.forAccount('uid-a');
    final raw = (await kept())[DeviceIdentityStore.storageKey('uid-a')]!;
    expect(raw, startsWith(SecretSeal.prefix));
    expect(raw, isNot(contains(base64Encode(made.seed))));

    final locked = DeviceIdentityStore(storage, tree: () => null);
    await expectLater(locked.forAccount('uid-a'), throwsA(isA<SecretSealBroken>()));
    expect((await kept())[DeviceIdentityStore.storageKey('uid-a')], raw, reason: 'the kept key is left as it is');
    expect((await store.forAccount('uid-a')).seed, made.seed);
  });

  test('which are sealed', () {
    for (final slot in [
      'auto_backup_password',
      'backup_dest_secret_webdav_x',
      'prometheus_bearer_token',
      'prometheus_basic_pass',
      'prometheus_client_cert_p12',
      'prometheus_client_cert_pass',
      'prometheus_custom_header_val',
      'zestssh_transcript_encryption_key',
      'google_desktop_oauth_v1',
      'orchard_device_key_v1.uid',
      'orchard_export_v1.uid.o',
      'lockout_recovery_v1',
    ]) {
      expect(SecretSeal.sealsSlot(slot), isTrue, reason: slot);
    }
    for (final slot in [
      'prometheus_ca_pem',
      'prometheus_basic_user',
      'device_id',
      'sync_salt',
      'zestssh_db_encryption_key',
      // An address and an account id: which account a recovery proof was made
      // for here. Read at the sign-in screen, and opens nothing.
      'recovery_proof_accounts_v1',
    ]) {
      expect(SecretSeal.sealsSlot(slot), isFalse, reason: slot);
    }
  });
}

/// A backup service made from [sealedBy], whose export answers it was made.
class _Backups implements BackupService {
  _Backups(this.sealedBy);

  @override
  final AppDatabase sealedBy;

  final List<String> exported = [];

  @override
  Future<BackupResult> exportBackup(String password,
      {String filenamePrefix = 'zestssh_backup_', bool allowUnencrypted = false}) async {
    exported.add(password);
    return const BackupResult(success: true, filePath: '/srv/demo/zestssh_auto_1.zest');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
