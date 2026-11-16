import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_dialog_common.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';

// A workspace's "opened {when}" takes the words made to stand inside a
// sentence (3.0): French said "ouvert Il y a 5 min", and
// under a minute every language said none minutes ago.
void main() {
  setUpAll(initializeDateFormatting);

  for (final locale in AppLocalizations.supportedLocales) {
    test('in $locale, a workspace opened 5 minutes ago says so inside its sentence', () {
      final l10n = lookupAppLocalizations(locale);
      final when = DateTime.now().subtract(const Duration(minutes: 5, seconds: 10));
      expect(workspaceOpenedLabel(l10n, when), l10n.workspaceOpenedRelative(timeAgoInSentence(l10n, when)));
      expect(workspaceOpenedLabel(l10n, DateTime.now()), l10n.workspaceOpenedRelative(l10n.settingsMobJustNow));
      expect(workspaceOpenedLabel(l10n, null), l10n.workspaceNeverOpened);
    });
  }

  test('in French the time inside the sentence starts small', () {
    final label = workspaceOpenedLabel(lookupAppLocalizations(const Locale('fr')),
        DateTime.now().subtract(const Duration(minutes: 5, seconds: 10)));
    expect(label, isNot(contains('Il y a')));
    expect(label, contains('il y a'));
  });
}
