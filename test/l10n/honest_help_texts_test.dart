import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Three texts of the app promised more than it does (found in a security
/// review): "All SSH connections are end-to-end encrypted" and credentials
/// that "never leave the device unless you enable Cloud Sync" (Telnet is
/// offered and is plain text; team vaults, backups and a shared host carry
/// credentials too); passwords "never written to disk in plain text" (an
/// export without a password, a plain session log); and a list of what still
/// reaches ZestSSH's servers with a custom sync store that left out the
/// guides, the Support Hub and RevenueCat. They say what is so now, in every
/// language, and this keeps the old promises from coming back.
void main() {
  const languages = ['en', 'de', 'es', 'fr', 'it', 'pt', 'ru', 'ja', 'ko', 'zh', 'ar', 'hi'];
  Map<String, dynamic> arb(String language) =>
      jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync()) as Map<String, dynamic>;

  test('"is my data safe" names what is not encrypted and the ways a password leaves the device', () {
    for (final language in languages) {
      final text = arb(language)['helpFaqDataSafeBody'] as String;
      expect(text, contains('Telnet'), reason: language);
      for (final kind in ['SSH', 'SFTP', 'FTPS', 'Mosh']) {
        expect(text, contains(kind), reason: '$language: $kind');
      }
    }
    final english = arb('en')['helpFaqDataSafeBody'] as String;
    expect(english.toLowerCase(), isNot(contains('end-to-end')));
    expect(english, isNot(contains('never leave')));
    for (final way in ['team vaults', 'backup', 'host you share']) {
      expect(english, contains(way));
    }
  });

  test('"how are passwords stored" says when one is written as plain text', () {
    final english = arb('en')['helpFaqPasswordsBody'] as String;
    expect(english, isNot(contains('never written')));
    expect(english, contains('export without a password'));
    expect(english, contains('session log'));
    for (final language in languages) {
      final text = arb(language)['helpFaqPasswordsBody'] as String;
      expect(text, contains('Android Keystore / iOS Keychain / Windows Credential Manager / macOS Keychain'),
          reason: language);
      expect(text.length, greaterThan((english.length * 0.4).round()), reason: '$language: the two new sentences');
    }
  });

  test('the note of a custom sync store lists everything the app still asks for elsewhere', () {
    for (final language in languages) {
      final text = arb(language)['syncBackendOwnStorageNote'] as String;
      for (final named in ['docs.zestssh.com', 'zestssh.com', 'RevenueCat', 'ZestSSH']) {
        expect(text, contains(named), reason: '$language: $named');
      }
    }
  });

  test('the banner of a sync store says what the store can see, while the store is told it in clear', () {
    // A security review found the banner said the
    // store "only ever holds an unreadable blob", and the file there names
    // the kind of device that pushed and when, beside the encrypted data.
    final manifest = File('lib/services/sync/sync_manifest.dart').readAsStringSync();
    final inClear = manifest.contains("'device_id': deviceId") && manifest.contains("'updated_at':");
    expect(inClear, isTrue, reason: 'if these moved inside the encryption, the banner may say less again');
    final english = arb('en')['syncBackendEncryptedBanner'] as String;
    expect(english, isNot(contains('only ever holds')));
    expect(english, isNot(contains('unreadable blob')));
    expect(english, contains('when a device last synced'));
    expect(english, contains('what kind of device'));
    for (final language in languages) {
      final text = arb(language)['syncBackendEncryptedBanner'] as String;
      expect(text, contains('ZestSSH'), reason: language);
      expect(text.length, greaterThan((english.length * 0.3).round()), reason: '$language: the second sentence');
    }
  });
}
