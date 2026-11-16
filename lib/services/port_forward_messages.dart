import 'dart:io';

import 'package:zestssh/database/database.dart' show PortForwardRule;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SSHChannelOpenError;
import 'package:zestssh/services/port_forward_service.dart'
    show ForwardTrouble, PortForward, PortForwardType, maxConcurrentForwards;
import 'package:zestssh/services/ssh_service.dart' show shownHostText;
import 'package:zestssh/utils/error_report.dart';

/// A forward's name as it is said in a notice: its own label, or where it
/// goes, masked in recording mode (3.0: the label, or the address
/// it goes to, as it is).
String forwardDisplayName(PortForwardRule rule) {
  final label = rule.label;
  if (label != null && label.trim().isNotEmpty) return Redactable.freeText(label).display;
  if (rule.type == 'dynamic') return 'SOCKS5 :${rule.bindPort}';
  return '${Redactable.address(rule.remoteHost).display}:${rule.remotePort}';
}

/// Why [rule] could not start, in [t]'s language, from what starting it
/// threw: too many forwards run, the host refused it, the port
/// on this device is in use or may not be opened, or something else (its
/// details say what). Every failure was said to be a port in use.
String forwardFailureSentence(AppLocalizations t, Object error, PortForwardRule rule) =>
    forwardStartFailureSentence(t, error, rule.bindPort);

/// [forwardFailureSentence] for a forward that is no saved rule (a phone's
/// session forward), its port on this device being [bindPort].
String forwardStartFailureSentence(AppLocalizations t, Object error, int bindPort) {
  final text = error.toString();
  if (text.contains('Concurrent port forward limit reached')) return t.pfFailedTooMany(maxConcurrentForwards);
  if (text.contains('Server refused the remote forward')) return t.pfFailedRefused;
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    final lower = text.toLowerCase();
    // Linux, macOS and Windows say a port in use their own ways, and Dart
    // its own when this app holds it already (another session's forward).
    if (code == 98 ||
        code == 48 ||
        code == 10048 ||
        lower.contains('address already in use') ||
        lower.contains('only one usage of each socket address') ||
        lower.contains('binding multiple times on the same (address, port)')) {
      return t.pfFailedPortInUse(bindPort);
    }
    if (code == 13 || code == 10013 || lower.contains('permission denied') || lower.contains('access permissions')) {
      return t.pfFailedPortDenied(bindPort);
    }
  }
  return t.pfFailedOther;
}

/// The report behind a forward that did not start: what it threw, of which
/// kind, and its ports (every name and address taken out).
String forwardFailureReport(PortForwardRule rule, Object error) => ErrorReport.build(
      what: 'A port forward did not start',
      where: 'Starting a port forward',
      error: error,
      details: 'Kind: ${rule.type}\nLocal port: ${rule.bindPort}\nTo: ${rule.remoteHost}:${rule.remotePort}',
    );

/// [forwardFailureReport] for a forward that is no saved rule.
String forwardStartFailureReport(PortForward forward, Object error) => ErrorReport.build(
      what: 'A port forward did not start or stop',
      where: 'Starting or stopping a port forward',
      error: error,
      details: 'Kind: ${forward.type.name}\nLocal port: ${forward.bindPort}\nTo: ${forward.remoteHost}:${forward.remotePort}',
    );

/// A running forward's name as it is said in a notice: what
/// [forwardDisplayName] says of the rule it was started from.
String runningForwardName(PortForward forward) {
  final label = forward.label;
  if (label != null && label.trim().isNotEmpty) return Redactable.freeText(label).display;
  if (forward.type == PortForwardType.dynamic) return 'SOCKS5 :${forward.bindPort}';
  return '${Redactable.address(forward.remoteHost).display}:${forward.remotePort}';
}

/// Why the connections of a running forward are not made, in [t]'s language,
/// from what one of them failed with. The host passes no connections on (it
/// answered with the reason code 1); it could not connect to where the
/// forward leads (2), or did not open the way for another reason, each with
/// what the host itself said of it, as text and nothing else; or, for a
/// forward from a port on the host, this device could not connect to where
/// it hands its connections on.
String forwardTroubleSentence(AppLocalizations t, ForwardTrouble trouble) {
  final forward = trouble.forward;
  final error = trouble.error;
  if (error is! SSHChannelOpenError) {
    return t.pfNothingAnswersThere('${Redactable.address(forward.bindAddress).display}:${forward.bindPort}');
  }
  if (error.code == 1) return t.pfHostPassesNothingOn;
  final sentence = error.code == 2
      ? t.pfHostCannotConnect('${Redactable.address(forward.remoteHost).display}:${forward.remotePort}')
      : t.pfHostDidNotOpen;
  final said = shownHostText(error.description);
  return said.isEmpty ? sentence : '$sentence ${t.pfHostSaid(said)}';
}

/// The report behind it: what the connection failed with, the forward's kind
/// and its ports (every name and address taken out).
String forwardTroubleReport(ForwardTrouble trouble) => ErrorReport.build(
      what: 'A port forward runs, and its connections are not made',
      where: 'A connection through a port forward',
      error: trouble.error,
      details: 'Kind: ${trouble.forward.type.name}\nLocal port: ${trouble.forward.bindPort}\n'
          'To: ${trouble.forward.remoteHost}:${trouble.forward.remotePort}',
    );
