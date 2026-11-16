import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// Guards cross-device settings sync (blob schema_version 12).
///
/// The allowlisted app/terminal settings travel in the encrypted blob. Two
/// invariants matter: (1) the gather -> restore -> gather round-trip must be
/// byte-stable so it never triggers an endless echo push, and (2) only
/// allowlisted keys travel, with every value type-checked and bounds-clamped
/// so a hostile blob can't write arbitrary or out-of-range prefs.
SyncDataService _service(
        AppDatabase db, FlutterSecureStorage storage, SettingsService s) =>
    SyncDataService(
      database: db,
      connectionsDao: db.connectionsDao,
      identitiesDao: db.identitiesDao,
      groupsDao: db.connectionGroupsDao,
      knownHostsDao: db.knownHostsDao,
      snippetsDao: db.snippetsDao,
      snippetCategoriesDao: db.snippetCategoriesDao,
      portForwardRulesDao: db.portForwardRulesDao,
      networksDao: db.networksDao,
      connectionTagsDao: db.connectionTagsDao,
      secureStorage: storage,
      settingsService: s,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  const storage = FlutterSecureStorage();
  final key = List<int>.filled(32, 7);

  late AppDatabase src;
  late AppDatabase dst;

  setUp(() {
    src = AppDatabase.forTesting(NativeDatabase.memory());
    dst = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await src.close();
    await dst.close();
  });

  Future<SettingsService> settingsWith(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return SettingsService(await SharedPreferences.getInstance());
  }

  test('allowlisted settings travel and apply on the other device', () async {
    final srcSettings = await settingsWith(const {});
    await srcSettings.setTerminalThemeId('solarized');
    await srcSettings.setScrollbackLines(12345);
    await srcSettings.setBellEnabled(false);
    await srcSettings.setDefaultUsername('deploy');
    await srcSettings.setDefaultPort(2222);
    await srcSettings.setTerminalFontSize(16.5);

    final blob = await _service(src, storage, srcSettings).gatherAll();
    // What this build writes (21 since the icon colour of a host).
    expect(blob['schema_version'], 22);
    expect(blob['settings'], isA<Map>());

    final dstSettings = await settingsWith(const {});
    await _service(dst, storage, dstSettings).restoreAll(blob);

    expect(dstSettings.terminalThemeId, 'solarized');
    expect(dstSettings.scrollbackLines, 12345);
    expect(dstSettings.bellEnabled, false);
    expect(dstSettings.defaultUsername, 'deploy');
    expect(dstSettings.defaultPort, 2222);
    expect(dstSettings.terminalFontSize, 16.5);
  });

  // 3.0: a phone could not turn security alerts off, and a
  // computer's choice did not reach it.
  test('the switches of security alerts and of failed transfers travel, as those of notifications beside them',
      () async {
    final srcSettings = await settingsWith(const {});
    await srcSettings.setNotifySecurityAlerts(false);
    await srcSettings.setNotifyTransferFailed(false);
    await srcSettings.setNotifyTransferComplete(false);

    final blob = await _service(src, storage, srcSettings).gatherAll();
    final dstSettings = await settingsWith(const {});
    expect(dstSettings.notifySecurityAlerts, isTrue);
    await _service(dst, storage, dstSettings).restoreAll(blob);

    expect(dstSettings.notifySecurityAlerts, isFalse);
    expect(dstSettings.notifyTransferFailed, isFalse);
    expect(dstSettings.notifyTransferComplete, isFalse);
  });

  test('device-local keys never travel (sync/security/prometheus/onboarding)',
      () async {
    final srcSettings = await settingsWith(const {});
    await srcSettings.setSyncServerVersion(99);
    await srcSettings.setSecurityLockEnabled(true);
    await srcSettings.setPrometheusUrl('http://10.0.0.5:9090');
    await srcSettings.setOnboardingComplete();
    await srcSettings.setMonitorDataSource('prometheus');

    final blob = await _service(src, storage, srcSettings).gatherAll();
    final settings = Map<String, dynamic>.from(blob['settings'] as Map);

    expect(settings.containsKey('sync_server_version'), isFalse);
    expect(settings.containsKey('security_lock_enabled'), isFalse);
    expect(settings.containsKey('prometheus_url'), isFalse);
    expect(settings.containsKey('onboarding_complete'), isFalse);
    expect(settings.containsKey('monitor_data_source'), isFalse);
  });

  test('round-trip is byte-stable: fingerprint matches, no echo push',
      () async {
    final srcSettings = await settingsWith(const {});
    await srcSettings.setTerminalThemeId('nord');
    await srcSettings.setScrollbackLines(0); // unlimited
    await srcSettings.setSoftKeyboardRow1Order(const ['esc', 'tab', 'ctrl']);

    final blobA = await _service(src, storage, srcSettings).gatherAll();

    final dstSettings = await settingsWith(const {});
    await _service(dst, storage, dstSettings).restoreAll(blobA);
    final blobB = await _service(dst, storage, dstSettings).gatherAll();

    // The settings sub-object must be identical after a restore, and the
    // whole-blob content fingerprint (which now folds in `settings`) must
    // match, so the pull's own restore writes don't trigger an echo push.
    expect(blobB['settings'], equals(blobA['settings']));
    expect(
      SyncDataService.contentFingerprint(blobB, key),
      SyncDataService.contentFingerprint(blobA, key),
    );
  });

  test('hostile values are type-checked and bounds-clamped on import',
      () async {
    final dstSettings = await settingsWith(const {});
    // A blob with out-of-range numbers, wrong types, and an over-long string.
    final blob = {
      'schema_version': 12,
      'settings': {
        'default_port': 999999, // out of range -> clamp to 65535
        'terminal_font_size': 900.0, // -> clamp to 48.0
        'scrollback_lines': -5, // -> clamp to 0
        'bell_enabled': 'not-a-bool', // wrong type -> ignored
        'terminal_theme': 'x' * 999999, // -> capped
        'not_an_allowlisted_key': 'evil', // -> ignored entirely
      },
    };

    await _service(dst, storage, dstSettings).restoreAll(blob);

    expect(dstSettings.defaultPort, 65535);
    expect(dstSettings.terminalFontSize, 48.0);
    expect(dstSettings.scrollbackLines, 0);
    // Wrong-typed bool never written -> stays at its default (true).
    expect(dstSettings.bellEnabled, true);
    expect(dstSettings.terminalThemeId.length, lessThanOrEqualTo(16384));
  });

  test('synced string prefs are stripped of control + bidi/RTL chars on import',
      () async {
    final dstSettings = await settingsWith(const {});
    // A hostile blob pushing an RTL override + embedded newline + zero-width
    // char into the SSH default username (which flows into logs/dialogs).
    final blob = {
      'schema_version': 12,
      'settings': {
        // ro + RTL-override + ot + newline + admin + zero-width-space
        'default_username': 'ro\u202Eot\nadmin\u200B',
      },
    };
    await _service(dst, storage, dstSettings).restoreAll(blob);
    final u = dstSettings.defaultUsername;
    for (final cp in u.runes) {
      expect(cp >= 0x20 && cp != 0x7F, isTrue,
          reason: 'no control chars survive');
      expect(cp < 0x200B || cp > 0x200F, isTrue, reason: 'no bidi/zero-width');
      expect(cp < 0x202A || cp > 0x202E, isTrue, reason: 'no bidi override');
    }
    expect(u, 'rootadmin');
  });
}
