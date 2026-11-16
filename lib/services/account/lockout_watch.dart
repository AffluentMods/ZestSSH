import 'dart:async';

import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/utils/logger.dart';

/// Tells this device's person, wherever they are in the app, when someone
/// asked to recover their account (the two-step contract, section 6.5): a
/// notice with "This wasn't me" on every signed-in device, besides the
/// email. ZestSSH Cloud says so on the live line ({type: 'security'}, open
/// while the account is in a team); every device also asks when the account
/// signs in and when the app comes back to the front, at most every
/// [every], so one without the line is told too. Nothing is kept of it.
class LockoutRecoveryWatch {
  LockoutRecoveryWatch({
    required this.api,
    required this.tell,
    required this.clear,
    this.now = DateTime.now,
    this.every = const Duration(minutes: 30),
  });

  final TwoStepApi Function() api;

  /// Shows the notice of [waiting].
  final void Function(WaitingRecovery waiting) tell;

  /// Takes the notice away: nothing waits any more.
  final void Function() clear;

  final DateTime Function() now;
  final Duration every;

  DateTime? _askedAt;
  Future<void>? _running;

  /// The recovery told of, by its day, so it is told once.
  DateTime? _told;

  /// Asks ZestSSH Cloud, unless it was asked less than [every] ago; [now]
  /// asks at once (the account signed in, or the live line said so).
  Future<void> check({bool now = false}) {
    final at = this.now();
    final asked = _askedAt;
    if (!now && asked != null && at.difference(asked) < every) return Future<void>.value();
    return _running ??= _check(at).whenComplete(() => _running = null);
  }

  Future<void> _check(DateTime at) async {
    _askedAt = at;
    try {
      final waiting = (await api().state()).lockoutRecovery;
      if (waiting == null) {
        if (_told != null) clear();
        _told = null;
        return;
      }
      if (_told == waiting.completesAt) return;
      _told = waiting.completesAt;
      tell(waiting);
    } catch (e) {
      // Signed out, offline, or a server before 3.3: the next look tells.
      AppLogger.info('Lock-out recovery: not looked at ($e)');
    }
  }

  /// The account signed out or changed: what was told belongs to it.
  void forget() {
    _askedAt = null;
    _told = null;
  }
}
