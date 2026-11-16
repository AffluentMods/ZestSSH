import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/utils/ppk_converter.dart';

// A made-up PuTTY key with a passphrase (version 3, Argon2id), built with
// Python's cryptography package by the format PuTTY documents.
const _passphrase = 'demo passphrase for tests';
const _encrypted = '''PuTTY-User-Key-File-3: ssh-ed25519
Encryption: aes256-cbc
Comment: demo@northwind.example
Public-Lines: 2
AAAAC3NzaC1lZDI1NTE5AAAAIHm1Vi6P5lT5QHixEuipi6eQH4U65pW+1+DjkQut
BJZk
Key-Derivation: Argon2id
Argon2-Memory: 1024
Argon2-Passes: 3
Argon2-Parallelism: 1
Argon2-Salt: 404142434445464748494a4b4c4d4e4f
Private-Lines: 1
BTQP6Gmu99rIQLq8JDbwjdp6+o026Exu4IlUh66nuZlPXn7hyGt3XbTkJEOM8nPn
Private-MAC: 255ad71837fe334e525131f365122c3aab5421a1e0c7ceae4ed88fedb59d730a
''';

/// Importing a key (3.0): a PuTTY key with a passphrase was
/// refused as "not yet supported" with the raw error in the notice, and what
/// could not be imported was said in English in every language.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final service = KeyImportService();

  test('a PuTTY key with a passphrase is known as one, and opens with it', () async {
    expect(service.isPpkFormat(_encrypted), isTrue);
    expect(service.isEncrypted(_encrypted), isTrue, reason: 'so the passphrase is asked for');
    expect(service.isEncrypted(_encrypted.replaceFirst('Encryption: aes256-cbc', 'Encryption: none')), isFalse);
    final imported = service.importPpkKey(_encrypted, _passphrase);
    expect(imported.keyType, contains('ed25519'));
    expect(imported.privatePem, contains('BEGIN OPENSSH PRIVATE KEY'));
    // Off the screen's thread, the same key.
    final inBackground = await service.importPpkKeyInBackground(_encrypted, _passphrase);
    expect(inBackground.fingerprint, imported.fingerprint);
  });

  test('what could not be imported is said for what it is', () {
    String said(Object error) => KeyImportService.problemSaid(error, en);
    Object thrownBy(void Function() body) {
      try {
        body();
      } catch (e) {
        return e;
      }
      fail('nothing was thrown');
    }

    // No passphrase given, and a wrong one.
    expect(said(thrownBy(() => service.importPpkKey(_encrypted))), en.keyImportHasPassphrase);
    expect(said(thrownBy(() => service.importPpkKey(_encrypted, 'not the passphrase'))), en.identityIncorrectPassphrase);
    expect(KeyImportService.isPassphraseError('${thrownBy(() => service.importPpkKey(_encrypted, 'not it'))}'), isTrue,
        reason: 'so the passphrase is asked for again');
    expect(KeyImportService.isPassphraseError('${const PpkPassphraseError(missing: true)}'), isTrue,
        reason: 'an empty answer is asked again too');
    // A file changed after it was written (no passphrase in play).
    expect(said(const FormatException('PPK Private-MAC verification failed - the key file is corrupt')), en.keyImportDamaged);
    // A kind of key, or of file, that is not read.
    expect(said(const FormatException('Unsupported PPK key type: ssh-dss. Only ssh-rsa and ssh-ed25519 are supported.')),
        en.keyImportUnsupportedKind);
    expect(said(const FormatException('PEM header must start with -----BEGIN')), en.keyImportNotAKey);
    expect(said(thrownBy(() => service.importPpkKey('hello'))), en.keyImportNotAKey);
    expect(said(const FormatException('No valid keys found in PEM')), en.keyImportNoKeys);
    expect(said(StateError('something else')), en.keyImportNotImported);
    // Never the raw error in the sentence.
    for (final error in [const FormatException('PEM header must start with -----BEGIN'), StateError('something else')]) {
      expect(said(error), isNot(contains('Exception')));
      expect(said(error), isNot(contains('Bad state')));
    }
  });

  test('the screens say it that way, with what was thrown to copy', () {
    final editor = File('lib/ui/screens/identity/identity_edit_screen.dart').readAsStringSync();
    expect(editor, isNot(contains('translateError(')));
    expect(editor, isNot(contains('identityImportFailed(e.toString())')));
    expect('KeyImportService.problemSaid(e, l10n)'.allMatches(editor).length, 4);
    expect("showTopSnackBar(context, msg, isError: true, details: '\$e');".allMatches(editor).length, 1);
    expect('await importService.importPpkKeyInBackground(content, passphrase);'.allMatches(editor).length, 3);
    for (final rel in ['lib/ui/screens/settings/settings_screen.dart', 'lib/ui/screens/settings/data_settings_screen.dart']) {
      final screen = File(rel).readAsStringSync();
      expect(screen, contains('if (importService.isEncrypted(content)) {'), reason: rel);
      expect(screen, contains('l10n.keyImportHasPassphrase'), reason: rel);
      expect(screen, contains('KeyImportService.problemSaid(e, l10n),'), reason: rel);
      expect(screen, isNot(contains('translateError(')), reason: rel);
    }
  });

  test('every language says them its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final l = lookupAppLocalizations(locale);
      for (final say in <String Function(AppLocalizations)>[
        (x) => x.keyImportHasPassphrase,
        (x) => x.keyImportDamaged,
        (x) => x.keyImportUnsupportedKind,
        (x) => x.keyImportNotAKey,
        (x) => x.keyImportNoKeys,
        (x) => x.keyImportNotImported,
      ]) {
        expect(say(l), isNot(say(en)), reason: '$locale');
      }
    }
  });
}
