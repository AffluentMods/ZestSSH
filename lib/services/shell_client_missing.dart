import 'dart:io';

import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/eternal_terminal_service.dart';
import 'package:zestssh/services/mosh_service.dart';
import 'package:zestssh/utils/type_name.dart';

/// The two kinds of session the app opens through a program of the
/// computer's own: Mosh's `mosh` and Eternal Terminal's `et`.
enum ShellClient { mosh, eternalTerminal }

/// A Mosh or Eternal Terminal host that cannot be opened here: its client is
/// not installed on this computer (or, on Windows, in WSL), or the device is
/// a phone or a tablet, which has none ([onPhone]; a host synced from a
/// computer is there too). It was an UnsupportedError, which the screens
/// showed as "An unexpected error occurred" with the install hint, in
/// English, under the details (found while checking the 3.0 docs).
class ShellClientMissing implements Exception, HasTypeName {
  const ShellClientMissing(this.client, {required this.onPhone});

  final ShellClient client;
  final bool onPhone;

  /// In English, for the log: what is missing, never where it was going.
  @override
  String toString() => onPhone
      ? 'ShellClientMissing: ${client.name} does not open on a phone or tablet'
      : 'ShellClientMissing: the ${client.name} client is not installed';

  @override
  String get typeName => 'ShellClientMissing';
}

/// The code a [ShellClientMissing] is named by, the same in every language.
ErrorCode shellClientMissingCode(ShellClientMissing e) => e.onPhone
    ? ErrorCodes.shellClientOnComputerOnly
    : switch (e.client) {
        ShellClient.mosh => ErrorCodes.moshNotInstalled,
        ShellClient.eternalTerminal => ErrorCodes.etNotInstalled,
      };

/// The system [shellClientMissingText] gives the commands for: this one's,
/// or the one a test names.
String get _thisSystem => Platform.isMacOS
    ? 'macos'
    : Platform.isWindows
        ? 'windows'
        : Platform.isLinux
            ? 'linux'
            : 'other';

/// What a connection that failed with [e] says, in the person's language:
/// what is missing and what to do, with its code, and under it the commands
/// that install the client on this system ([os]: 'macos', 'linux' or
/// 'windows'; this computer's where none is named), which are typed as they
/// are and so are not translated. On a phone, that the host opens on a
/// computer, or over SSH.
String shellClientMissingText(AppLocalizations l10n, ShellClientMissing e, {String? os}) {
  final code = shellClientMissingCode(e);
  final name = switch (e.client) {
    ShellClient.mosh => 'Mosh',
    ShellClient.eternalTerminal => 'Eternal Terminal',
  };
  if (e.onPhone) return ErrorCodes.withCode(l10n.connShellClientOnComputerOnly(name), code);
  final system = os ?? _thisSystem;
  final windows = system == 'windows';
  final said = switch (e.client) {
    ShellClient.mosh => windows ? l10n.connMoshMissingWindows : l10n.connMoshMissing,
    ShellClient.eternalTerminal => windows ? l10n.connEtMissingWindows : l10n.connEtMissing,
  };
  final commands = switch (e.client) {
    ShellClient.mosh => moshInstallCommands(system),
    ShellClient.eternalTerminal => etInstallCommands(system),
  };
  final withCode = ErrorCodes.withCode(said, code);
  if (commands.isEmpty) return withCode;
  return '$withCode\n\n${commands.map((c) => '  $c').join('\n')}';
}
