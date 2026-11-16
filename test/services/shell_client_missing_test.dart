// A Mosh or Eternal Terminal host whose client is not installed here (or
// that is opened on a phone, which has none) says what is missing and how to
// install it, with its code. It was an UnsupportedError, which every screen
// showed as "An unexpected error occurred", the install hint in English under
// the details; and the Windows hint for Mosh said `wsl apt install mosh`,
// which apt refuses without sudo (found in the 3.0 docs
// check).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText;
import 'package:zestssh/services/eternal_terminal_service.dart';
import 'package:zestssh/services/mosh_service.dart';
import 'package:zestssh/services/shell_client_missing.dart';
import 'package:zestssh/utils/error_translator.dart';

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const mosh = ShellClientMissing(ShellClient.mosh, onPhone: false);
  const et = ShellClientMissing(ShellClient.eternalTerminal, onPhone: false);

  test('a computer without Mosh: what is missing, its code, and the commands for its system', () {
    final linux = shellClientMissingText(l10n, mosh, os: 'linux');
    expect(linux, startsWith(ErrorCodes.withCode(l10n.connMoshMissing, ErrorCodes.moshNotInstalled)));
    expect(linux, contains('sudo apt install mosh'));
    expect(linux, contains('sudo dnf install mosh'));
    expect(shellClientMissingText(l10n, mosh, os: 'macos'), contains('brew install mosh'));

    final windows = shellClientMissingText(l10n, mosh, os: 'windows');
    expect(windows, startsWith(ErrorCodes.withCode(l10n.connMoshMissingWindows, ErrorCodes.moshNotInstalled)));
    expect(windows, contains('wsl --install'));
    // As root, as apt needs (as the Eternal Terminal line always was).
    expect(windows, contains('wsl sudo apt install mosh'));
    expect(windows, isNot(contains('wsl apt install')));
  });

  test('every install line of Windows that runs apt runs it as root', () {
    for (final line in [...moshInstallCommands('windows'), ...etInstallCommands('windows')]) {
      if (line.contains('apt ')) expect(line, contains('sudo apt'), reason: line);
    }
  });

  test('a computer without Eternal Terminal: the same, with its own code and commands', () {
    final linux = shellClientMissingText(l10n, et, os: 'linux');
    expect(linux, startsWith(ErrorCodes.withCode(l10n.connEtMissing, ErrorCodes.etNotInstalled)));
    expect(linux, contains('sudo apt install et'));
    final windows = shellClientMissingText(l10n, et, os: 'windows');
    expect(windows, startsWith(ErrorCodes.withCode(l10n.connEtMissingWindows, ErrorCodes.etNotInstalled)));
    expect(windows, contains('wsl sudo apt install et'));
    expect(shellClientMissingText(l10n, et, os: 'macos'), contains('brew install MisterTea/et/et'));
  });

  test('a phone: the host opens on a computer, or over SSH; no commands', () {
    const onPhone = ShellClientMissing(ShellClient.mosh, onPhone: true);
    expect(shellClientMissingText(l10n, onPhone, os: 'linux'),
        ErrorCodes.withCode(l10n.connShellClientOnComputerOnly('Mosh'), ErrorCodes.shellClientOnComputerOnly));
    expect(
        shellClientMissingText(l10n, const ShellClientMissing(ShellClient.eternalTerminal, onPhone: true)),
        contains('Eternal Terminal'));
  });

  test('a failed connection shows it as the app said it, not as an unexpected error', () {
    final kept = connectionFailureText(mosh);
    final shown = ConnectionError.translate(kept);
    expect(shown.type, ConnectionErrorType.saidByApp);
    // This computer's words and commands, whichever system it is.
    expect(shown.description, shellClientMissingText(l10n, mosh));
    expect(shown.description, contains(ErrorCodes.moshNotInstalled.code));
    // As it was: an UnsupportedError, said as nothing the app knew.
    expect(ConnectionError.translate(connectionFailureText(UnsupportedError('Mosh is not installed'))).type,
        ConnectionErrorType.unknown);
  });
}
