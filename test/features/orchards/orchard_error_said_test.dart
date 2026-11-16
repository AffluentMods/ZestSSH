import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// What an Orchard's screens say when nothing else says what failed (3.0).
/// Before, it was "Something went wrong:" and the error as the program
/// writes it, English in every language. An answer of ZestSSH Cloud's that
/// the app does not know says its status; anything else, that this was not
/// done on this device. Neither carries the error's own words.
void main() {
  final de = lookupAppLocalizations(const Locale('de'));

  test('an answer of ZestSSH Cloud the app does not know: what it answered, by its status', () {
    final said = orchardErrorMessage(const OrchardServerException(410, 'gone-for-good'), de);
    expect(said, de.syncCloudAnswerUnknown(410));
    expect(said, isNot(contains('gone-for-good')));
  });

  test('anything else: not done, on this device, and nothing of the error', () {
    final said = orchardErrorMessage(StateError('the record held two owners'), de);
    expect(said, de.orchardErrorNotDone);
    expect(said, isNot(contains('two owners')));
    expect(said, isNot(contains('Bad state')));
  });
}
