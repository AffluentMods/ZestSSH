import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SSHChannelOpenError;
import 'package:zestssh/database/database.dart' show PortForwardRule;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/port_forward_messages.dart';
import 'package:zestssh/services/port_forward_service.dart';
import 'package:zestssh/utils/redactor.dart';

/// What is said about a port forward that did not start (3.0):
/// why, from what starting it threw, in the app's language. Every failure was
/// said to be the local port in use, in English.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  PortForwardRule rule({String type = 'local', String? label, int bindPort = 15432}) => PortForwardRule(
        id: 'r1',
        connectionId: 'h-db1',
        type: type,
        bindAddress: '127.0.0.1',
        bindPort: bindPort,
        remoteHost: '10.50.0.7',
        remotePort: 5432,
        autoStart: false,
        reconnect: false,
        exitOnFailure: false,
        gatewayPorts: false,
        label: label,
        createdAt: DateTime(2026, 10, 1),
      );

  tearDown(() => Redactor.instance.enabled = false);

  test("a forward's name: its label, SOCKS and its port, or where it goes; masked while recording", () {
    expect(forwardDisplayName(rule(label: 'Postgres on db-01')), 'Postgres on db-01');
    expect(forwardDisplayName(rule(type: 'dynamic', bindPort: 1080)), 'SOCKS5 :1080');
    expect(forwardDisplayName(rule()), '10.50.0.7:5432');
    expect(forwardDisplayName(rule(label: '  ')), '10.50.0.7:5432', reason: 'a blank label is no name');

    Redactor.instance.enabled = true;
    expect(forwardDisplayName(rule()), '${Redactable.address('10.50.0.7').display}:5432');
    expect(forwardDisplayName(rule()), isNot(contains('10.50.0.7')));
    expect(forwardDisplayName(rule(label: 'tunnel to 10.50.0.7')), isNot(contains('10.50.0.7')));
  });

  test('why it did not start, from what starting it threw', () {
    final r = rule();
    expect(
      forwardFailureSentence(
          en, StateError('Concurrent port forward limit reached (50). Stop an existing forward before starting a new one.'), r),
      en.pfFailedTooMany(maxConcurrentForwards),
    );
    expect(forwardFailureSentence(en, StateError('Server refused the remote forward for 10.50.0.7:5432'), r),
        en.pfFailedRefused);
    // A port in use, as Linux, macOS and Windows say it.
    for (final code in [98, 48, 10048]) {
      expect(
        forwardFailureSentence(en, SocketException('Failed to create server socket', osError: OSError('', code)), r),
        en.pfFailedPortInUse(15432),
        reason: '$code',
      );
    }
    expect(forwardFailureSentence(en, const SocketException('bind failed (OS Error: Address already in use)'), r),
        en.pfFailedPortInUse(15432));
    expect(
      forwardFailureSentence(en,
          const SocketException('Only one usage of each socket address (protocol/network address/port) is normally permitted'), r),
      en.pfFailedPortInUse(15432),
    );
    // This app holds the port already (another session's forward): Dart's own words.
    expect(
      forwardFailureSentence(
        en,
        const SocketException('Failed to create server socket',
            osError: OSError('The shared flag to bind() needs to be `true` if binding multiple times on the same '
                '(address, port) combination.')),
        r,
      ),
      en.pfFailedPortInUse(15432),
    );
    // A port that may not be opened.
    for (final code in [13, 10013]) {
      expect(
        forwardFailureSentence(en, SocketException('Failed to create server socket', osError: OSError('', code)), r),
        en.pfFailedPortDenied(15432),
        reason: '$code',
      );
    }
    expect(forwardFailureSentence(en, const SocketException('bind failed (OS Error: Permission denied)'), r),
        en.pfFailedPortDenied(15432));
    // Anything else: the details say.
    expect(forwardFailureSentence(en, const SocketException('Network is unreachable'), r), en.pfFailedOther);
    expect(forwardFailureSentence(en, StateError('something new'), r), en.pfFailedOther);
  });

  test('every language says each of these its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      final said = [
        t.pfFailedTooMany(50),
        t.pfFailedRefused,
        t.pfFailedPortInUse(15432),
        t.pfFailedPortDenied(15432),
        t.pfFailedOther,
        t.pfHostGone,
        t.pfNoForwarding,
        t.pfStillConnecting('web-01'),
        t.pfSessionLimitBody(4),
      ];
      expect(said.toSet(), hasLength(said.length), reason: '$locale');
      expect(t.pfFailedPortInUse(15432), contains('15432'), reason: '$locale');
      expect(t.pfStartFailedTitle('web-db'), contains('web-db'), reason: '$locale');
      if (locale.languageCode != 'en') {
        expect(t.pfFailedPortInUse(15432), isNot(en.pfFailedPortInUse(15432)), reason: '$locale');
      }
    }
  });

  // A forward that runs, and what it says when its connections are not made.
  PortForward running({
    PortForwardType type = PortForwardType.local,
    String? label,
    String bindAddress = '127.0.0.1',
  }) =>
      PortForward(
        id: 'r1',
        type: type,
        bindAddress: bindAddress,
        bindPort: 15432,
        remoteHost: '10.50.0.7',
        remotePort: 5432,
        label: label,
      );

  test("a running forward's name is what its rule's is; masked while recording", () {
    expect(runningForwardName(running(label: 'Postgres on db-01')), 'Postgres on db-01');
    expect(runningForwardName(running(type: PortForwardType.dynamic)), 'SOCKS5 :15432');
    expect(runningForwardName(running()), '10.50.0.7:5432');
    expect(runningForwardName(running(label: '  ')), '10.50.0.7:5432', reason: 'a blank label is no name');
    for (final type in ['local', 'remote', 'dynamic']) {
      final asForward = PortForwardType.values.byName(type);
      expect(runningForwardName(running(type: asForward)), forwardDisplayName(rule(type: type)), reason: type);
    }

    Redactor.instance.enabled = true;
    expect(runningForwardName(running()), isNot(contains('10.50.0.7')));
    expect(runningForwardName(running(label: 'tunnel to 10.50.0.7')), isNot(contains('10.50.0.7')));
  });

  test('why the connections of a running forward are not made, from what one of them failed with', () {
    String says(Object error, [PortForward? forward]) =>
        forwardTroubleSentence(en, ForwardTrouble(forward ?? running(), error));

    // The host passes no connections on.
    expect(says(SSHChannelOpenError(1, 'open failed')), en.pfHostPassesNothingOn);
    // It could not connect to where the forward leads, with what it said of that.
    expect(says(SSHChannelOpenError(2, 'connect failed: Connection refused')),
        '${en.pfHostCannotConnect('10.50.0.7:5432')} ${en.pfHostSaid('connect failed: Connection refused')}');
    expect(says(SSHChannelOpenError(2, '')), en.pfHostCannotConnect('10.50.0.7:5432'));
    // It did not open the way for another reason.
    expect(says(SSHChannelOpenError(4, 'resource shortage')), '${en.pfHostDidNotOpen} ${en.pfHostSaid('resource shortage')}');
    expect(says(SSHChannelOpenError(3, '  ')), en.pfHostDidNotOpen);
    // What it said is text, on one line, with nothing in it that steers a terminal.
    final steered = says(SSHChannelOpenError(2, 'no\x1b[2J route\nto host'));
    expect(steered, startsWith(en.pfHostCannotConnect('10.50.0.7:5432')));
    expect(steered, isNot(contains('\x1b')));
    expect(steered, isNot(contains('\n')));
    expect(steered, contains('route to host'));

    // A forward from a port on the host: this device's own side of it.
    final fromHost = running(type: PortForwardType.remote, bindAddress: '192.168.10.50');
    expect(says(const SocketException('Connection refused'), fromHost), en.pfNothingAnswersThere('192.168.10.50:15432'));

    Redactor.instance.enabled = true;
    expect(says(SSHChannelOpenError(2, '')), isNot(contains('10.50.0.7')));
    expect(says(const SocketException('Connection refused'), fromHost), isNot(contains('192.168.10.50')));
  });

  test('every language says each of those its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      final said = [
        t.pfTroubleTitle('web-db'),
        t.pfHostPassesNothingOn,
        t.pfHostCannotConnect('10.50.0.7:5432'),
        t.pfHostDidNotOpen,
        t.pfHostSaid('Connection refused'),
        t.pfNothingAnswersThere('127.0.0.1:3000'),
      ];
      expect(said.toSet(), hasLength(said.length), reason: '$locale');
      expect(t.pfTroubleTitle('web-db'), contains('web-db'), reason: '$locale');
      expect(t.pfHostCannotConnect('10.50.0.7:5432'), contains('10.50.0.7:5432'), reason: '$locale');
      expect(t.pfHostSaid('Connection refused'), contains('Connection refused'), reason: '$locale');
      expect(t.pfNothingAnswersThere('127.0.0.1:3000'), contains('127.0.0.1:3000'), reason: '$locale');
      if (locale.languageCode != 'en') {
        expect(t.pfHostPassesNothingOn, isNot(en.pfHostPassesNothingOn), reason: '$locale');
        expect(t.pfHostDidNotOpen, isNot(en.pfHostDidNotOpen), reason: '$locale');
        expect(t.pfHostSaid('x'), isNot(en.pfHostSaid('x')), reason: '$locale');
      }
    }
  });

  test('the report behind it: what the connection failed with, the kind and the ports, every address out', () {
    final report = forwardTroubleReport(
        ForwardTrouble(running(), SSHChannelOpenError(2, 'connect failed for 10.50.0.7: Connection refused')));
    expect(report, contains('A connection through a port forward'));
    expect(report, contains('Connection refused'));
    expect(report, contains('Kind: local'));
    expect(report, contains('Local port: 15432'));
    expect(report, isNot(contains('10.50.0.7')));
  });

  test('the report of a forward that did not start: what it threw, its kind and ports, every address out', () {
    final report = forwardFailureReport(rule(), const SocketException('bind failed for 10.50.0.7'));
    expect(report, contains('Starting a port forward'));
    expect(report, contains('bind failed'));
    expect(report, contains('Kind: local'));
    expect(report, contains('Local port: 15432'));
    expect(report, isNot(contains('10.50.0.7')));
  });
}
