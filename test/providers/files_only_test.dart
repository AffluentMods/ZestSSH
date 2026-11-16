import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

/// Hosts that give files only (SFTP-only hosts
/// in the big release). A host saved as SFTP only opens
/// to its files with no terminal; a normal SSH host whose server allows SFTP
/// only, or whose shell closes the moment it opens, is said to give no
/// terminal, and its files are offered; and what needs a terminal is not
/// offered for an SFTP-only host, with why.
Connection _host(String protocol) => Connection(
      id: 'h-files',
      label: 'files-01',
      host: '192.0.2.20',
      port: 22,
      colorIndex: 0,
      protocol: protocol,
      zlibCompression: false,
      keepAliveSeconds: 0,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      createdAt: DateTime(2026, 10, 30),
      updatedAt: DateTime(2026, 10, 30),
    );

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final all = [for (final locale in AppLocalizations.supportedLocales) lookupAppLocalizations(locale)];

  test('the kind of host is stored as "sftp", the string a version from before it reads as SSH', () {
    expect(ConnectionProtocol.sftp.name, 'sftp');
    expect(ConnectionProtocol.values.firstWhere((p) => p.name == 'sftp'), ConnectionProtocol.sftp);
    // What the host editor of a version from before it does with an unknown
    // string: SSH (connection_edit_screen.dart reads it so).
    expect(
        ConnectionProtocol.values
            .where((p) => p != ConnectionProtocol.sftp)
            .firstWhere((p) => p.name == 'sftp', orElse: () => ConnectionProtocol.ssh),
        ConnectionProtocol.ssh);
  });

  test('its name says what it is for, in every language: files, and no terminal', () {
    expect(ConnectionProtocol.sftp.nameIn(en), 'SFTP only (files, no terminal)');
    for (final l10n in all) {
      expect(ConnectionProtocol.sftp.nameIn(l10n), contains('SFTP'), reason: l10n.localeName);
      expect(l10n.connectionEditProtocolSftpShort, 'SFTP', reason: l10n.localeName);
      expect(l10n.hostSftpOnlyNoTerminal, contains('SFTP'), reason: l10n.localeName);
    }
    expect(en.hostSftpOnlyNoTerminal, 'This host is SFTP only: it gives no terminal.');
  });

  test('every session to a host saved as SFTP only is files only; no other kind is', () {
    expect(opensFilesOnly('sftp'), isTrue);
    for (final other in ['ssh', 'mosh', 'et', 'telnet', 'serial', 'localShell', 'demo', 'rdp']) {
      expect(opensFilesOnly(other), isFalse, reason: other);
    }
  });

  test('what needs a terminal says why an SFTP-only host is not offered, and nothing of any other', () {
    expect(noTerminalReason(_host('sftp'), en), en.hostSftpOnlyNoTerminal);
    for (final other in ['ssh', 'mosh', 'et', 'telnet', 'serial']) {
      expect(noTerminalReason(_host(other), en), isNull, reason: other);
    }
  });

  test("OpenSSH's own words for a shell asked of a server that gives files only are recognised", () {
    expect(sftpOnlyServerWords, 'This service allows sftp connections only.');
    expect(saysSftpOnly(sftpOnlyServerWords), isTrue);
    // As a server that is not run as root also prints its log line there.
    expect(
        saysSftpOnly('Connection from user deploy 192.0.2.7 port 40156: refusing non-sftp session\n'
            'This service allows sftp connections only.'),
        isTrue);
    expect(saysSftpOnly('THIS SERVICE ALLOWS SFTP CONNECTIONS ONLY.'), isTrue);
    expect(saysSftpOnly('This account is currently not available.'), isFalse);
    expect(saysSftpOnly(''), isFalse);
  });

  group('how a shell that ended by itself is read', () {
    final started = DateTime(2026, 10, 30, 12);

    test("the server's words: SFTP only, whenever and however it ended", () {
      expect(
          terminalRefusalAtEnd(
              said: sftpOnlyServerWords,
              connectedAt: started,
              endedAt: started.add(const Duration(minutes: 5)),
              lastInput: started.add(const Duration(minutes: 4))),
          TerminalRefusal.sftpOnly);
    });

    test('a shell that ended the moment it opened, before anything was typed: closed at once', () {
      expect(
          terminalRefusalAtEnd(
              said: 'forced', connectedAt: started, endedAt: started.add(const Duration(seconds: 1)), lastInput: null),
          TerminalRefusal.closedAtOnce);
      expect(
          terminalRefusalAtEnd(said: '', connectedAt: started, endedAt: started.add(kShellAtOnce), lastInput: null),
          TerminalRefusal.closedAtOnce,
          reason: 'with nothing said, too');
    });

    test('a shell that ran, or that its person typed into: neither', () {
      expect(
          terminalRefusalAtEnd(
              said: 'logout',
              connectedAt: started,
              endedAt: started.add(kShellAtOnce + const Duration(milliseconds: 1)),
              lastInput: null),
          isNull);
      expect(
          terminalRefusalAtEnd(
              said: '',
              connectedAt: started,
              endedAt: started.add(const Duration(seconds: 1)),
              lastInput: started.add(const Duration(milliseconds: 500))),
          isNull,
          reason: 'what its person typed ended it');
      // A clock a test set back: no length that can be read, so nothing.
      expect(
          terminalRefusalAtEnd(
              said: '', connectedAt: started, endedAt: started.subtract(const Duration(days: 1)), lastInput: null),
          isNull);
    });
  });

  test('the words a session that is files only and its offers use are there in every language', () {
    for (final l10n in all) {
      final name = 'files-01';
      expect(l10n.sftpOnlyRefusalSaid(name), contains(name), reason: l10n.localeName);
      expect(l10n.sftpOnlyRefusalAtOnce(name), contains(name), reason: l10n.localeName);
      expect(l10n.connectionTestSftpWorks(12, 345, ''), allOf(contains('12'), contains('345')), reason: l10n.localeName);
      for (final s in [
        l10n.sessionFilesOnlyLine,
        l10n.sftpOnlyRefusalTitle,
        l10n.sftpOnlyOpenFiles,
        l10n.sftpOnlyMakeHost,
        l10n.sftpOnlyMakeNotAllowed,
        l10n.filesOnlyWatched,
        l10n.connectionEditSftpInfo,
        l10n.connectionEditAuthSftpOnly,
      ]) {
        expect(s.trim(), isNotEmpty, reason: l10n.localeName);
        // (No dash of either length: written by its code, so none stands here.)
        expect(s, isNot(anyOf(contains(String.fromCharCode(0x2014)), contains(String.fromCharCode(0x2013)))),
            reason: '${l10n.localeName}: $s');
      }
    }
  });
}
