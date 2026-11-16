import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// A desktop toast's title holds 120 characters: a longer message keeps its
/// first sentences as the title and the rest below it, so nothing is lost.
void main() {
  test('a short message is the title alone', () {
    expect(splitToastMessage('Rules saved'), ('Rules saved', null));
    final exactly = 'x' * 120;
    expect(splitToastMessage(exactly), (exactly, null));
  });

  test('a long one splits after the last sentence that fits', () {
    const message = 'This device has no screen lock or app PIN to confirm it is you, so secrets from this Crate '
        'stay hidden here. Set one up first.';
    final (title, body) = splitToastMessage(message);
    expect(title, 'This device has no screen lock or app PIN to confirm it is you, so secrets from this Crate '
        'stay hidden here.');
    expect(body, 'Set one up first.');
    expect('$title $body', message, reason: 'nothing lost');
  });

  test('two short sentences that fit stay together in the title', () {
    const message = 'Saved. Synced. ' 'And then a much longer third sentence that pushes the whole message well '
        'past the length a title can hold here.';
    final (title, body) = splitToastMessage(message);
    expect(title, 'Saved. Synced.');
    expect(body, startsWith('And then'));
  });

  test('Chinese, Japanese and Hindi full stops end a sentence without a space', () {
    final ja = '${'あ' * 60}。${'い' * 80}';
    final (title, body) = splitToastMessage(ja);
    expect(title, '${'あ' * 60}。');
    expect(body, 'い' * 80);
    final hi = '${'क' * 50}। ${'ख' * 90}';
    expect(splitToastMessage(hi).$1, '${'क' * 50}।');
  });

  test('a decimal point or an address is not a sentence end', () {
    final message = 'Version 2.2 of example.com is ${'long ' * 30}';
    final (title, body) = splitToastMessage(message);
    expect(title, endsWith('…'), reason: 'no sentence end: split at a space');
    expect(title.length, lessThanOrEqualTo(121));
    expect(body, isNotEmpty);
  });

  test('one long word is cut at the limit and carried on below', () {
    final word = 'a' * 300;
    final (title, body) = splitToastMessage(word);
    expect(title, '${'a' * 119}…');
    expect(body, 'a' * 181);
  });
}
