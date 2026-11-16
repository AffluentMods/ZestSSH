import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/settings_service.dart';

/// Every setting is a profile's or the device's, and goes through one helper.
void main() {
  group('the tags', () {
    test('every key is a profile\'s or the device\'s, and none both', () {
      final listed = {...SettingsService.resetKeys, ...SettingsService.keptKeys};
      final tagged = {...SettingsService.deviceKeys, ...SettingsService.profileKeys};
      expect(SettingsService.deviceKeys.intersection(SettingsService.profileKeys), isEmpty);
      expect(listed.difference(tagged), isEmpty, reason: 'a key with neither tag: say whose it is in SettingsService');
      expect(tagged.difference(listed), isEmpty, reason: 'a tag on a key that is neither reset nor kept');
    });

    test('every beginning of a key is a profile\'s or the device\'s, and none both', () {
      final listed = {...SettingsService.resetPrefixes, ...SettingsService.keptPrefixes};
      final tagged = {...SettingsService.devicePrefixes, ...SettingsService.profilePrefixes};
      expect(SettingsService.devicePrefixes.toSet().intersection(SettingsService.profilePrefixes.toSet()), isEmpty);
      expect(listed, tagged);
    });

    test('what the design says is a person\'s is, and what it says is the device\'s is', () {
      for (final key in [
        // Pins, recent hosts, per-host themes and system kinds, folder sync, monitors and their alerts.
        'desktop_pinned_connections', 'pinned_connection_ids', 'quick_connect_recent', 'terminal_theme_host-1',
        'os_kind_host-1', 'sftp_sync_host-1', 'monitor_threshold_config_v1', 'monitor_host_alert_prefs_v1',
        // Saved tab groups and open tabs, the default identity, the avatar and name, notification history.
        'desktop_saved_tab_groups', 'desktop_work_tabs', 'persisted_sessions', 'default_identity_id',
        'profile_custom_avatar_path', 'tree_display_name_override', 'notification_history',
        // The entitlement copy, team premium, password managers, backup destinations.
        'desktop_entitlement_pro', 'desktop_entitlement_cloud_sync', 'team_premium_member', 'password_managers_v1',
        'backup_destinations',
        // The spec's: theme, font and cursor, snippets, host key asking, sync choices.
        'app_theme_id', 'terminal_font', 'cursor_style', 'auto_execute_snippets', 'ask_before_trusting_keys', 'sync_mode',
        // The scaling their new remote screens are saved with (4.0).
        'screen_default_scaling',
      ]) {
        expect(SettingsService.isProfileKey(key), isTrue, reason: key);
      }
      for (final key in [
        // The app lock, window and layout, update checks, recording mode.
        'security_lock_enabled', 'encrypting_lock_enabled', 'desktop_sidebar_width', 'sftp_dock_height', 'zest_split_keys',
        'update_check_enabled', 'update_last_check_ms', 'recording_mode_enabled', 'recording_mask_salt', 'onboarding_complete',
        // A remote screen's pointer on this phone (its default and each host's), the menu key on this computer's
        // keyboard, what recording mode on this device does to the picture (4.0).
        'screen_default_touch', 'screen_touch.host-1', 'screen_menu_key', 'screen_recording',
      ]) {
        expect(SettingsService.isProfileKey(key), isFalse, reason: key);
      }
    });

    test('a key made with an account\'s id in it is the profile\'s, so its name never stays on the device', () {
      expect(SettingsService.isProfileKey('team_sync_offer_told_some-account'), isTrue);
      expect(SettingsService.isProfileKey('jump_gate_notice_shown:host'), isTrue);
    });
  });

  group('the code', () {
    Map<String, String> sources() => {
          for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
            if (f.path.endsWith('.dart') && !f.path.contains('generated') && !f.path.endsWith('.g.dart'))
              f.path.replaceAll('\\', '/'): f.readAsStringSync(),
        };

    test('asks the system for its preferences in the one helper: a setting written anywhere else fails here', () {
      final asked = {
        for (final e in sources().entries)
          if (e.value.contains('SharedPreferences.getInstance(')) e.key,
      };
      expect(asked, {'lib/services/profiles/profile_preferences.dart'});
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('systemPreferences()'));
    });

    test('opens the keychain in one place: a new one fails here', () {
      final opened = {
        for (final e in sources().entries)
          if (RegExp(r'\bFlutterSecureStorage\(').hasMatch(e.value.replaceAll(RegExp(r'//[^\n]*'), ''))) e.key,
      };
      expect(opened, {'lib/services/profiles/keychain.dart'},
          reason: 'open the keychain through appKeychain (lib/services/profiles/keychain.dart)');
    });

    test('a window of its own reads no setting of a person: it is handed them', () {
      final main = File('lib/main.dart').readAsStringSync();
      final start = main.indexOf('class _StandaloneDetachedWindow');
      expect(start, greaterThan(0));
      final popOuts = main.substring(start);
      expect(popOuts, isNot(contains('appPreferences')));
      expect(popOuts, isNot(contains('systemPreferences')));
      expect(popOuts, isNot(contains('getBool(')));
      expect(popOuts, contains('widget.copyOnSelect'));
      final editor = File('lib/ui/screens/editor/text_editor_screen.dart').readAsStringSync();
      expect(editor, contains('widget.handedSettings'));
    });

    test('names no account in a keychain name outside a profile, and every device name is listed', () {
      // What the app reads and writes by a fixed name and is the device's.
      for (final name in [
        'security_pin_hash', 'security_lock_method', 'security_auto_lock_timeout', 'security_idle_lock_minutes',
        'security_lock_with_computer',
        'pin_failed_attempts', 'pin_lockout_until', 'vault_slots', 'vault_tpm_sealed_key',
        'recovery_proof_accounts_v1', 'pinned_cert_hashes', 'rc_stranded_anon_id', 'orchard_owners_v1',
      ]) {
        expect(KeychainNames.isDevice(name), isTrue, reason: name);
      }
      // And what is a person's stays one.
      for (final name in [
        'identity_key_x', 'ca_key_x', 'session_token', 'session_uid', 'sync_dek', 'sync_salt', 'device_id', 'device_session_v1',
        'automation_api_keys', 'google_desktop_oauth_v1', 'auto_backup_password', 'zestssh_transcript_encryption_key',
        'prometheus_bearer_token', 'cloud_accounts_v1', 'sync_backend_config', 'backup_dest_secret_x',
        'orchard_db_key_x', 'account_keys_v1_x', 'orchard_device_key_v1.x', 'orchard_export_v1.x',
        'lockout_recovery_v1',
      ]) {
        expect(KeychainNames.isDevice(name), isFalse, reason: name);
      }
      expect(KeychainNames.inner('account_keys_v1_abc', 'abc'), 'account_keys_v1_me');
      expect(KeychainNames.outer('account_keys_v1_me', 'abc'), 'account_keys_v1_abc');
      expect(KeychainNames.inner('orchard_export_v1.abc.team', 'abc'), 'orchard_export_v1.me.team');
      expect(KeychainNames.outer('orchard_export_v1.me.team', 'abc'), 'orchard_export_v1.abc.team');
      expect(KeychainNames.inner('identity_key_abc', 'abc'), 'identity_key_abc');
      expect(KeychainNames.accountOf('orchard_export_v1.abc.team.sent'), 'abc');
    });
  });

  group('the helper', () {
    late SharedPreferences raw;
    late ProfilePreferences prefs;
    late AppDatabase db;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'desktop_sidebar_width': 240.0,
        'lock2_app_lock': true,
        'security_lock_enabled': false,
        'app_theme_id': 'lock-screen-theme',
      });
      raw = await SharedPreferences.getInstance();
      prefs = ProfilePreferences(raw);
      db = AppDatabase.forTesting(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
    });
    tearDown(() => db.close());

    test('a device key is the system store\'s; a person\'s is the database\'s, every type', () async {
      await prefs.load(db);
      expect(prefs.getDouble('desktop_sidebar_width'), 240.0);
      await prefs.setDouble('desktop_sidebar_width', 250);
      expect(raw.getDouble('desktop_sidebar_width'), 250);

      await prefs.setBool('copy_on_select', false);
      await prefs.setInt('default_port', 2222);
      await prefs.setDouble('terminal_font_size', 14);
      await prefs.setString('terminal_theme', 'dracula');
      await prefs.setStringList('pinned_connection_ids', ['a', 'b']);
      for (final key in ['copy_on_select', 'default_port', 'terminal_font_size', 'terminal_theme', 'pinned_connection_ids']) {
        expect(raw.containsKey(key), isFalse, reason: key);
      }
      // Read back from the database, as the next start does.
      final again = ProfilePreferences(raw);
      await again.load(db);
      expect(again.getBool('copy_on_select'), isFalse);
      expect(again.getInt('default_port'), 2222);
      expect(again.getDouble('terminal_font_size'), 14.0);
      expect(again.getString('terminal_theme'), 'dracula');
      expect(again.getStringList('pinned_connection_ids'), ['a', 'b']);
      expect(again.getKeys(), containsAll(['copy_on_select', 'desktop_sidebar_width']));
      expect(again.containsKey('terminal_theme'), isTrue);

      await again.remove('terminal_theme');
      final third = ProfilePreferences(raw);
      await third.load(db);
      expect(third.getString('terminal_theme'), isNull);
    });

    test('before a profile was read a person\'s key is none, and a write to one is dropped', () async {
      expect(prefs.getString('terminal_theme'), isNull);
      expect(await prefs.setString('terminal_theme', 'a default written at start'), isFalse);
      await db.into(db.localState).insert(
          LocalStateCompanion.insert(key: '${ProfilePreferences.storePrefix}terminal_theme', value: '"dracula"', updatedAt: 1));
      await prefs.load(db);
      expect(prefs.getString('terminal_theme'), 'dracula', reason: 'what the database holds stands');
    });

    test('the app lock closes the database: what was read stays, what is written waits for the unlock', () async {
      await prefs.load(db);
      await prefs.setString('terminal_theme', 'one');
      await prefs.detach();
      expect(prefs.getString('terminal_theme'), 'one');
      await prefs.setString('terminal_theme', 'two');
      expect(prefs.getString('terminal_theme'), 'two');
      expect(await ProfilePreferences.readStored(db), {'terminal_theme': 'one'});
      await prefs.reattach(db);
      expect(await ProfilePreferences.readStored(db), {'terminal_theme': 'two'});
    });

    test('forgotten: nothing of the profile stays in memory', () async {
      await prefs.load(db);
      await prefs.setString('terminal_theme', 'one');
      await prefs.forget();
      expect(prefs.loaded, isFalse);
      expect(prefs.getString('terminal_theme'), isNull);
    });

    test('the look of the lock screen: the person\'s where one is open, else the last one\'s', () async {
      expect(prefs.getString('app_theme_id'), 'lock-screen-theme');
      await prefs.load(db);
      expect(prefs.getString('app_theme_id'), 'lock-screen-theme');
      await prefs.setString('app_theme_id', 'mine');
      expect(prefs.getString('app_theme_id'), 'mine');
      expect(raw.getString('app_theme_id'), 'mine');
    });

    test('the lock\'s switches are under new names, and the old ones stay off for an older version', () async {
      expect(prefs.getBool('security_lock_enabled'), isTrue);
      await prefs.setBool('encrypting_lock_enabled', true);
      expect(raw.getBool('lock2_encrypting'), isTrue);
      expect(raw.containsKey('encrypting_lock_enabled'), isFalse);
      expect(raw.getBool('security_lock_enabled'), isFalse);
      expect(prefs.getKeys().where((k) => k == 'security_lock_enabled').length, 1);
      expect(prefs.getKeys(), isNot(contains('lock2_app_lock')));
    });

    test('clear is the person\'s: the device\'s stay', () async {
      await prefs.load(db);
      await prefs.setString('terminal_theme', 'one');
      await prefs.clear();
      expect(prefs.getString('terminal_theme'), isNull);
      expect(await ProfilePreferences.readStored(db), isEmpty);
      expect(prefs.getDouble('desktop_sidebar_width'), 240.0);
    });

    test('Reset all settings goes through it, and puts the person\'s settings back', () async {
      await prefs.load(db);
      await prefs.setString('terminal_theme', 'one');
      await prefs.setString('desktop_saved_tab_groups', 'kept');
      await SettingsService(prefs).resetAllToDefaults();
      expect(prefs.getString('terminal_theme'), isNull);
      expect(prefs.getString('desktop_saved_tab_groups'), 'kept');
      expect(prefs.getDouble('desktop_sidebar_width'), isNull, reason: 'a layout is a setting too');
    });
  });

  group('a change of profile builds the app\'s state afresh', () {
    test('what read a person\'s settings reads the next person\'s, and what survives is told apart', () async {
      SharedPreferences.setMockInitialValues({});
      final raw = await SharedPreferences.getInstance();
      final prefs = ProfilePreferences(raw);
      final first = AppDatabase.forTesting(NativeDatabase.memory());
      final second = AppDatabase.forTesting(NativeDatabase.memory());
      await first.customSelect('SELECT 1').get();
      await second.customSelect('SELECT 1').get();
      await prefs.load(first);
      await prefs.setString('terminal_theme', 'first');
      await prefs.load(second);
      await prefs.setString('terminal_theme', 'second');
      await prefs.load(first);

      final person = Provider<String?>((ref) => ref.read(sharedPreferencesProvider).getString('terminal_theme'));
      var builds = 0;
      final kept = Provider<int>((ref) => ++builds);
      final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(container.dispose);
      expect(container.read(person), 'first');
      expect(container.read(kept), 1);

      await prefs.load(second);
      expect(container.read(person), 'first', reason: 'what this is about: it holds the person before');
      refreshPersonState(container, keep: [kept, sharedPreferencesProvider]);
      expect(container.read(person), 'second');
      expect(container.read(kept), 1);
      await first.close();
      await second.close();
    });
  });
}
