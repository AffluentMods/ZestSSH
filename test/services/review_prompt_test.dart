import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/review_prompt.dart';
import 'package:zestssh/services/settings_service.dart';

/// The stores' rating prompt: asked for only
/// right after something went well, the fifth session a person kept open a
/// while and closed themselves, at least a week after the app was first
/// opened, once per version; never after a failure, never with another
/// session open. What it counts stays on the device.
class _Review extends Fake implements InAppReview {
  int asked = 0;
  bool available = true;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> requestReview() async => asked++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late _Review review;
  late DateTime now;
  var version = '3.0.0';

  ReviewPrompt prompt() => ReviewPrompt(prefs, review: review, version: () async => version, now: () => now);

  Future<bool> good({bool others = false}) =>
      prompt().sessionEnded(lasted: const Duration(minutes: 5), byThePerson: true, othersOpen: others);

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
    review = _Review();
    now = DateTime(2026, 11, 1, 12);
    version = '3.0.0';
  });

  test('the fifth good session after the first week asks once in a version, and a new version may ask again', () async {
    await prompt().seen();
    for (var i = 0; i < 4; i++) {
      expect(await good(), isFalse, reason: 'session ${i + 1} of five');
    }
    expect(await good(), isFalse, reason: 'five, but the app was opened today');
    now = now.add(const Duration(days: 8));
    expect(await good(), isTrue);
    expect(review.asked, 1);
    expect(await good(), isFalse, reason: 'once in a version');
    version = '3.0.1';
    expect(await good(), isTrue);
    expect(review.asked, 2);
  });

  test('a session that failed, that the person did not close, that was short, or with another open: never', () async {
    await prompt().seen();
    now = now.add(const Duration(days: 30));
    for (var i = 0; i < 6; i++) {
      await good(others: true);
    }
    expect(review.asked, 0, reason: 'another session open: they are still working');
    expect(await prompt().sessionEnded(lasted: const Duration(minutes: 5), byThePerson: false, othersOpen: false), isFalse);
    expect(await prompt().sessionEnded(lasted: const Duration(seconds: 20), byThePerson: true, othersOpen: false), isFalse);
    expect(review.asked, 0);
    expect(await good(), isTrue, reason: 'then one that went well, alone');
  });

  test('where the store offers no prompt, nothing is asked and the version is not spent', () async {
    await prompt().seen();
    now = now.add(const Duration(days: 30));
    review.available = false;
    for (var i = 0; i < 5; i++) {
      await good();
    }
    expect(review.asked, 0);
    expect(prefs.getString(ReviewPrompt.askedVersionKey), isNull);
  });

  test('its counts are no setting: resetting settings keeps them', () {
    for (final k in [ReviewPrompt.firstSeenKey, ReviewPrompt.goodSessionsKey, ReviewPrompt.askedVersionKey]) {
      expect(SettingsService.keptKeys, contains(k), reason: k);
    }
  });
}
