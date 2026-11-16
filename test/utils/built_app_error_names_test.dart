import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText;
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/utils/error_translator.dart';

/// What the app makes of the SSH package's errors where it reads them as
/// text, in an app built as the released ones are: with its names
/// obfuscated (3.0).
///
/// An error of the package printed what the program calls its type. In such
/// a build that is a made-up name of two letters, so that the app, which
/// looks for "SSHKeyDecryptError" or "SSHNoAnswerError" in the text, found
/// them in every test and never where it was released: a mistyped passphrase
/// of a key being imported was "could not be imported", and a host that went
/// quiet "an unexpected error".
///
/// No test is built that way (the package's own test of this builds a
/// program so, and reads what it prints). What a test can do is what such a
/// build does to a class: call it something else. The classes at the end are
/// the package's errors under names of the kind such a build gives them.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));

  test('a mistyped passphrase of a key in OpenSSH\'s format is known as that, and so is none', () {
    final pem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519-passphrase/id_ed25519').readAsStringSync();
    final service = KeyImportService();
    SSHKeyDecryptError thrownWith(String? passphrase) {
      try {
        service.importOpenSSHKey(pem, passphrase);
      } on SSHKeyDecryptError catch (e) {
        return e;
      }
      fail('the key opened');
    }

    final mistyped = thrownWith('not the passphrase');
    final none = thrownWith(null);
    expect((mistyped.message, none.message), ('Invalid passphrase', 'Private key is encrypted'));
    // As it is thrown in a test, and as a built app has it.
    for (final error in [mistyped, none, _Aa(mistyped.message), _Aa(none.message)]) {
      expect(KeyImportService.isPassphraseError('$error'), isTrue, reason: 'so the passphrase is asked for again');
      expect(KeyImportService.problemSaid(error, en), en.identityIncorrectPassphrase);
      expect(ConnectionError.translate('$error', host: 'web-01').title, en.errKeyPassphraseRequiredTitle);
    }
  });

  test('a connection that failed is said as what it failed with', () {
    ConnectionError said(Object error) =>
        ConnectionError.translate(connectionFailureText(error), host: 'web-01', port: 22, username: 'deploy');
    final cases = <(Object, Object, ConnectionErrorType)>[
      (SSHNoAnswerError(const Duration(seconds: 45), 3), _Bb(), ConnectionErrorType.timeout),
      (SSHStateError('Transport is closed'), _Cc('Transport is closed'), ConnectionErrorType.sshProtocol),
      (SSHPacketError('Malformed packet: no length'), _Dd('Malformed packet: no length'), ConnectionErrorType.sshProtocol),
      (
        SSHHandshakeError('Invalid version: SSH-1.5-old'),
        _Ee('Invalid version: SSH-1.5-old'),
        ConnectionErrorType.sshProtocol
      ),
      (SSHInternalError('a state that cannot be'), _Ff('a state that cannot be'), ConnectionErrorType.sshProtocol),
    ];
    for (final (inATest, built, type) in cases) {
      expect(said(inATest).type, type, reason: '$inATest');
      expect(said(built).type, type, reason: 'in a built app: $inATest');
      expect(said(built).description, said(inATest).description);
      expect(said(built).rawError, '$inATest', reason: 'and its details name it');
    }
    expect(said(_Bb()).description, en.errTimeoutDesc('web-01'));
  });

  test('Server Monitor files a host that went quiet as one that could not be reached', () {
    CantCheckReason filed(Object failedWith) => failedCheckReason(
        MonitorHostStatus(MonitorHostState.error, failedWith: failedWith, updatedAt: DateTime(2026, 10, 10, 12)));
    expect(filed(SSHNoAnswerError(const Duration(seconds: 45), 3)), CantCheckReason.unreachable);
    expect(filed(_Bb()), CantCheckReason.unreachable);
    expect(filed(_Cc('Transport is closed')), CantCheckReason.checkFailed);
  });
}

class _Aa extends SSHKeyDecryptError {
  _Aa(super.message);
}

class _Bb extends SSHNoAnswerError {
  _Bb() : super(const Duration(seconds: 45), 3);
}

class _Cc extends SSHStateError {
  _Cc(super.message);
}

class _Dd extends SSHPacketError {
  _Dd(super.message);
}

class _Ee extends SSHHandshakeError {
  _Ee(super.message);
}

class _Ff extends SSHInternalError {
  _Ff(super.error);
}
