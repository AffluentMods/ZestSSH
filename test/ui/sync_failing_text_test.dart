import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/ui/screens/sync/sync_failing_text.dart';

/// What is said of a sync that is failing, wherever it is said (the status
/// bar, the Tree's row in the switcher, the Account page): what stopped it
/// and, while the app keeps trying by itself, that it does (3.0, 8 October
/// 2026). A server that is down for a while is nobody's to do something
/// about, and until this was held nothing told a failure that passes from
/// one that needs the person.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  test('a failure that needs somebody: what stopped it, and no more', () {
    const health = SyncHealthState(SyncHealth.failing, problem: 'The keys do not match.');
    expect(syncFailingText(health, en, unknown: 'Sync error'), 'The keys do not match.');
  });

  test('a failure the app tries again by itself: what stopped it, and that it keeps trying', () {
    const health = SyncHealthState(SyncHealth.failing, problem: 'The sync server refused the connection.', retrying: true);
    expect(syncFailingText(health, en, unknown: 'Sync error'),
        'The sync server refused the connection. ZestSSH keeps trying by itself.');
  });

  test('a message that ends in a code keeps the code at its end', () {
    const health = SyncHealthState(SyncHealth.failing,
        problem: 'The sync server refused the connection. (ZS-1201)', retrying: true);
    expect(syncFailingText(health, en, unknown: 'Sync error'),
        'The sync server refused the connection. ZestSSH keeps trying by itself. (ZS-1201)');
    const paused = SyncHealthState(SyncHealth.failing, problem: 'The sync server refused the connection. (ZS-1201)');
    expect(syncFailingText(paused, en, unknown: 'Sync error'), 'The sync server refused the connection. (ZS-1201)');
  });

  test('ZestSSH Cloud not responding already says that the app keeps at it: it is not said twice', () {
    final problem = '${en.cloudNotResponding} (ZS-1101)';
    final health = SyncHealthState(SyncHealth.failing, problem: problem, retrying: true);
    expect(syncFailingText(health, en, unknown: 'Sync error'), problem);
    expect(problem, contains('keeps checking'));
  });

  test('nothing known of what stopped it: the words given for that', () {
    expect(syncFailingText(const SyncHealthState(SyncHealth.failing), en, unknown: 'Sync error'), 'Sync error');
    expect(syncFailingText(const SyncHealthState(SyncHealth.failing, retrying: true), en, unknown: 'Sync error'),
        'Sync error ZestSSH keeps trying by itself.');
  });

  test('every language says what stopped it first, then that the app keeps trying, in its own words', () {
    const problem = 'PROBLEM.';
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      final said = l.syncFailingKeepsTrying(problem);
      expect(said, startsWith(problem), reason: '$locale');
      expect(said.length, greaterThan(problem.length + 8), reason: '$locale');
      expect(said, contains('ZestSSH'), reason: '$locale');
      if (locale.languageCode != 'en') {
        expect(said, isNot(en.syncFailingKeepsTrying(problem)), reason: '$locale');
      }
    }
  });
}
