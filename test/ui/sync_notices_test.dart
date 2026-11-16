import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The sync notices are said in the app's language (3.0):
/// "Cloud sync paused", the disagreement over a host's key and the
/// wrong clock were English, and two of the errors behind them too.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  test('every language says them its own way, with what they name', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      expect(t.syncHostKeyConflictBody('web-01:22'), contains('web-01:22'), reason: '$locale');
      expect(t.syncClockBehind(7), contains('7'), reason: '$locale');
      expect(t.syncClockAhead(7), contains('7'), reason: '$locale');
      expect(t.syncClockBehind(7), isNot(t.syncClockAhead(7)), reason: '$locale');
      if (locale.languageCode == 'en') continue;
      for (final say in <String Function(AppLocalizations)>[
        (l) => l.syncPausedTitle,
        (l) => l.syncHostKeyConflictTitle,
        (l) => l.syncHostKeyConflictBody('web-01:22'),
        (l) => l.syncClockWrongTitle,
        (l) => l.syncClockBehind(7),
        (l) => l.syncClockAhead(7),
        (l) => l.syncTooLargeRefused,
        (l) => l.syncCannotDecrypt,
        (l) => l.syncStoreWentBackTitle,
        (l) => l.syncStoreWentBackBody,
      ]) {
        expect(say(t), isNot(say(en)), reason: '$locale');
      }
    }
  });

  test('the app says them through the app\'s words, not English of its own', () {
    final app = File('lib/app.dart').readAsStringSync();
    for (final english in ["'Cloud sync paused'", "'Host key disagreement", "\"This device's clock looks wrong\""]) {
      expect(app, isNot(contains(english)), reason: english);
    }
    for (final word in [
      'gl10n.syncHostKeyConflictTitle',
      'gl10n.syncClockWrongTitle',
      'gl10n.syncStoreWentBackTitle',
      'gl10n.syncStoreWentBackBody',
      'autoSync.storeWentBack.addListener(_onStoreWentBack)',
    ]) {
      expect(app, contains(word), reason: word);
    }
    // The pause is said by the function the app's root calls for it.
    expect(app, contains('showSyncPausedNotice('));
    final pause = File('lib/ui/screens/sync/sync_now.dart').readAsStringSync();
    expect(pause, contains('title: gl10n.syncPausedTitle,'));
    expect(pause, isNot(contains("'Cloud sync")));
    final service = File('lib/services/auto_sync_service.dart').readAsStringSync();
    expect(service, isNot(contains('unexpectedly large and was not')));
    expect(service, isNot(contains("can't decrypt your cloud data")));
  });
}
