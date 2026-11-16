import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/settings_service.dart';

/// "Reset all settings" puts the settings back to their defaults, and
/// leaves everything else the app keeps in the same store as it is.
///
/// It cleared the whole store but for recording mode. The store holds much
/// that is no setting: what sync knows of the state it last shared (the
/// hash, the version, what is waiting to go), the switch of the app lock
/// (so a reset turned the lock off, with no PIN asked), that the first-run
/// steps were done, reports waiting to be sent, pins, saved tab groups,
/// custom themes, a Prometheus server's sign-in. The question a person is
/// asked before a reset promises that only settings go.
///
/// Now the reset removes the keys that are settings ([SettingsService.
/// resetKeys]) and nothing else. Every key the code keeps in the store is
/// said to be a setting or not: the last test here reads the code, and
/// fails for a key that is in neither list.
void main() {
  /// A store with something under every key the two lists name, one key for
  /// each beginning of a key, and a key that neither list knows; and what
  /// was put there.
  Future<(SharedPreferences, Map<String, Object>)> filled() async {
    final values = <String, Object>{};
    var n = 0;
    for (final key in [...SettingsService.resetKeys, ...SettingsService.keptKeys]) {
      n++;
      // One of each kind a store holds, in turn.
      values[key] = switch (n % 5) {
        0 => true,
        1 => 'what $key held',
        2 => n,
        3 => n + 0.5,
        _ => <String>['of', key],
      };
    }
    for (final prefix in [...SettingsService.resetPrefixes, ...SettingsService.keptPrefixes]) {
      values['${prefix}host-7'] = 'what $prefix held';
    }
    values['a_key_of_another_version'] = 'what nobody here knows of';
    SharedPreferences.setMockInitialValues(values);
    return (await SharedPreferences.getInstance(), values);
  }

  test('the settings are gone from the store, and everything else in it is as it was', () async {
    final (prefs, values) = await filled();
    expect(prefs.getKeys(), values.keys.toSet(), reason: 'the store as it was filled');

    await SettingsService(prefs).resetAllToDefaults();

    for (final key in SettingsService.resetKeys) {
      expect(prefs.containsKey(key), isFalse, reason: key);
    }
    for (final prefix in SettingsService.resetPrefixes) {
      expect(prefs.containsKey('${prefix}host-7'), isFalse, reason: prefix);
    }
    final kept = {
      ...SettingsService.keptKeys,
      for (final prefix in SettingsService.keptPrefixes) '${prefix}host-7',
      'a_key_of_another_version',
    };
    expect(prefs.getKeys(), kept);
    for (final key in kept) {
      expect(prefs.get(key), values[key], reason: key);
    }
    // A second reset has nothing left to do.
    await SettingsService(prefs).resetAllToDefaults();
    expect(prefs.getKeys(), kept);
  });

  test('a setting reads as its default afterwards; the app lock, sync and the first-run steps are as before',
      () async {
    SharedPreferences.setMockInitialValues({
      'scrollback_lines': 1000,
      'terminal_font_size': 22.0,
      'terminal_theme': 'solarized_dark',
      'reachability_checks_enabled': true,
      'security_lock_enabled': true,
      'encrypting_lock_enabled': true,
      'sync_content_hash': 'made-up-hash',
      'sync_server_version': 41,
      'sync_dirty': true,
      'sync_mode': 'webdav',
      'onboarding_complete': true,
      'terminal_theme_host-7': 'dracula',
      'zest_split_keys': 0.4,
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsService(prefs);
    expect(settings.scrollbackLines, 1000);

    await settings.resetAllToDefaults();

    expect(settings.scrollbackLines, 50000);
    expect(settings.terminalFontSize, 14.0);
    expect(settings.terminalThemeId, 'zest_night');
    expect(prefs.containsKey('reachability_checks_enabled'), isFalse);
    expect(prefs.containsKey('zest_split_keys'), isFalse);
    // The lock is not turned off by a reset.
    expect(settings.securityLockEnabled, isTrue);
    expect(settings.encryptingLockEnabled, isTrue);
    // Sync goes on from where it was.
    expect(prefs.getString('sync_content_hash'), 'made-up-hash');
    expect(prefs.getInt('sync_server_version'), 41);
    expect(prefs.getBool('sync_dirty'), isTrue);
    expect(prefs.getString('sync_mode'), 'webdav');
    expect(prefs.getBool('onboarding_complete'), isTrue);
    // A host's own terminal theme is the host's: only the app's is a setting.
    expect(prefs.getString('terminal_theme_host-7'), 'dracula');
  });

  test('no key is in both lists, no beginning stands for a key of the other list, and what must be kept is', () {
    expect(SettingsService.resetKeys.intersection(SettingsService.keptKeys), isEmpty);
    for (final key in SettingsService.keptKeys) {
      expect(SettingsService.isResetKey(key), isFalse, reason: key);
      expect(SettingsService.resetPrefixes.any(key.startsWith), isFalse, reason: key);
    }
    for (final key in SettingsService.resetKeys) {
      expect(SettingsService.isResetKey(key), isTrue, reason: key);
      expect(SettingsService.keptPrefixes.any(key.startsWith), isFalse, reason: key);
    }
    for (final prefix in SettingsService.keptPrefixes) {
      expect(SettingsService.isResetKey('${prefix}x'), isFalse, reason: prefix);
    }
    for (final prefix in SettingsService.resetPrefixes) {
      expect(SettingsService.isResetKey('${prefix}x'), isTrue, reason: prefix);
    }
    expect(SettingsService.isResetKey('a_key_of_another_version'), isFalse);
    expect(SettingsService.keptKeys, containsAll(SettingsService.recordingKeys));
    // Named one by one: a list is easily edited, and these are the ones a reset must never take.
    expect(
      SettingsService.keptKeys,
      containsAll(<String>[
        'security_lock_enabled',
        'encrypting_lock_enabled',
        'sync_content_hash',
        'sync_dirty',
        'sync_dirty_since',
        'sync_server_version',
        'sync_store_updated_at',
        'sync_mode',
        'sync_recovery_key_set',
        'last_sync_time',
        'onboarding_complete',
        'changed_host_keys',
        'feedback_queue_v1',
        'persisted_sessions',
        'pins_migrated_to_db',
        'desktop_entitlement_pro',
        'desktop_entitlement_cloud_sync',
        'prometheus_bearer_token',
        'prometheus_basic_auth_password',
        'custom_app_themes_v1',
        'desktop_saved_tab_groups',
      ]),
    );
  });

  test('every key the code keeps in the store is said to be a setting or not, and both lists name only keys the '
      'code has', () {
    // A call on the store with its key: a text, or a name that is a constant text somewhere in the code.
    final call = RegExp(
      r"""\.(?:get(?:String|Bool|Int|Double|StringList)?|set(?:String|Bool|Int|Double|StringList)|remove|containsKey)\(\s*(?:'([^'$]+)'|"([^"$]+)"|([A-Za-z_][A-Za-z0-9_.]*))""",
    );
    final constant = RegExp(r"(?:static\s+)?const\s+(?:String\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'([^']+)'");
    final ofTheStore = RegExp(r'prefs|Prefs|Preferences|_store\b|_p\b|\bp\.');

    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart') && !f.path.contains('l10n'))
        .toList();
    expect(files.length, greaterThan(300), reason: 'run from the root of the app');
    final texts = {for (final f in files) f.path: f.readAsStringSync()};
    // Each class may have a `_key` of its own, so a name in a file holds a set.
    final inFile = <String, Map<String, Set<String>>>{};
    final anywhere = <String, Set<String>>{};
    texts.forEach((path, text) {
      for (final m in constant.allMatches(text)) {
        ((inFile[path] ??= {})[m.group(1)!] ??= {}).add(m.group(2)!);
        (anywhere[m.group(1)!] ??= {}).add(m.group(2)!);
      }
    });

    final found = <String, String>{};
    texts.forEach((path, text) {
      if (!text.contains('SharedPreferences') && !text.toLowerCase().contains('prefs')) return;
      for (final line in text.split('\n')) {
        if (!ofTheStore.hasMatch(line)) continue;
        for (final m in call.allMatches(line)) {
          final said = m.group(1) ?? m.group(2);
          if (said != null) {
            found[said] = path;
            continue;
          }
          final name = m.group(3)!.split('.').last;
          // A constant of the same file by any name; one of another file only by a name that is a key's
          // (kSomething, somethingKey): a variable called "key" or "id" is no constant of somewhere else.
          final own = inFile[path]?[name];
          if (own != null) {
            for (final value in own) {
              found[value] = path;
            }
            continue;
          }
          final keyName = RegExp(r'^_?k[A-Z]|[Kk]ey$').hasMatch(name) && name != 'key';
          final values = keyName ? anywhere[name] ?? const <String>{} : const <String>{};
          if (values.length == 1) found[values.single] = path;
        }
      }
    });

    // The reading finds what it is to find.
    expect(found.length, greaterThan(120));
    expect(found.keys, containsAll(<String>['sync_dirty', 'terminal_theme', 'shortcut_overrides', 'settings_last_section']));

    final listed = {...SettingsService.resetKeys, ...SettingsService.keptKeys};
    bool begun(String key) =>
        [...SettingsService.resetPrefixes, ...SettingsService.keptPrefixes].any(key.startsWith);
    final unsaid = {
      for (final entry in found.entries)
        if (!listed.contains(entry.key) && !begun(entry.key)) entry.key: entry.value,
    };
    expect(
      unsaid,
      isEmpty,
      reason: 'a key is kept in the preferences store that SettingsService does not know: put it into resetKeys '
          'if "Reset all settings" is to put it back to its default (a setting, a layout), and into keptKeys if '
          'it is anything else',
    );
    expect(listed.difference(found.keys.toSet()), isEmpty, reason: 'a list names a key the code no longer has');
  });
}
