import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/identity/identity_cert_expiry.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// Reminders of certificates that run out: a notice for each saved key whose
/// OpenSSH certificate runs out soon, and one when it has run out, so that
/// it is renewed before a sign-in is refused for it.
///
/// A key is told of once for what its certificate's time makes of it, for as
/// long as the app runs: once when it runs out soon, and once more when it
/// has run out. One that was renewed is told of again when the new
/// certificate's time comes. (See [IdentityCertExpiry.certReminder] for when
/// that is.)
///
/// The saved keys are looked at when they have been read, whenever they
/// change, and once an hour, since a certificate runs out while the app
/// runs. (Until 3.0 they were looked at once, when the app started and no
/// key had been read yet, and again at each unlock: so the reminders came
/// only after the app had been locked.)
///
/// They follow the setting "Security alerts": nothing is told while it is
/// off, and what stands is told when it is turned on. Nothing is looked at
/// while the app is locked.
class CertReminders {
  CertReminders(this._ref) {
    _ref.listen(identitiesProvider, (_, _) => _lookSoon());
    _ref.listen(notifySecurityAlertsProvider, (_, _) => _lookSoon());
    _hourly = Timer.periodic(const Duration(hours: 1), (_) => _look());
    _ref.onDispose(() {
      _soon?.cancel();
      _hourly.cancel();
    });
    _lookSoon();
  }

  final Ref _ref;

  /// The clock the reminders go by. (The tests set it.)
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// What each key was last told of.
  final Map<String, CertReminder> _told = {};
  late final Timer _hourly;
  Timer? _soon;

  /// One look for a burst of changes, and none from within a build.
  void _lookSoon() {
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 300), _look);
  }

  void _look() {
    // (While the app is locked, the keys it holds are those it held before.)
    if (!_ref.read(dbReadyProvider)) return;
    final keys = _ref.read(identitiesProvider).valueOrNull;
    if (keys == null) return;
    final telling = _ref.read(notifySecurityAlertsProvider);
    final at = clock();
    for (final key in keys) {
      final due = key.certReminder(now: at);
      if (due == null) {
        _told.remove(key.id);
      } else if (telling && _told[key.id] != due) {
        _told[key.id] = due;
        _tell(key, due, at);
      }
    }
  }

  void _tell(Identity key, CertReminder due, DateTime at) {
    final l10n = gl10n;
    final name = Redactable.keyName(key.label).display;
    final notices = _ref.read(notificationCenterProvider.notifier);
    switch (due) {
      case CertReminder.ranOut:
        notices.error(l10n.certReminderRanOutTitle(name), body: l10n.certReminderRanOutBody);
      case CertReminder.runsOutSoon:
        notices.warning(
          l10n.certReminderSoonTitle(name),
          body: l10n.certReminderSoonBody(certExpirySaid(key, l10n, now: at)!),
        );
    }
  }
}

/// Instantiated once at app start (see app.dart), so that the reminders come
/// for as long as the app runs.
final certRemindersProvider = Provider<CertReminders>(CertReminders.new);
