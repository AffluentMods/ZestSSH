import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/link_gate.dart';

/// A link that comes while the app is locked waits until it is unlocked
/// (found in a security review): with the lock
/// that hides the screen, a link was answered behind it, its question shown
/// over the lock screen to whoever had the device.
void main() {
  test('while locked a link waits, the latest alone, and is answered once unlocked; unlocked, at once', () async {
    var locked = true;
    final answered = <Uri>[];
    final gate = LinkGate(locked: () => locked, answer: (uri) async => answered.add(uri));
    await gate.offer(Uri.parse('zestssh://share?d=demo'));
    await gate.offer(Uri.parse('zestssh://connect?name=web-01'));
    expect(answered, isEmpty);
    expect(gate.waiting, Uri.parse('zestssh://connect?name=web-01'));

    await gate.unlocked();
    expect(answered, isEmpty, reason: 'still locked');
    locked = false;
    await gate.unlocked();
    expect(answered, [Uri.parse('zestssh://connect?name=web-01')]);
    expect(gate.waiting, isNull);
    await gate.unlocked();
    expect(answered, hasLength(1), reason: 'answered once');

    await gate.offer(Uri.parse('zestssh://upgrade-complete'));
    expect(answered.last, Uri.parse('zestssh://upgrade-complete'));
  });

  // What the app does with the gate, run: links from a stream and the lock's
  // changes, as app.dart wires them (they were checked only as its text,
  // as a review found).
  test('links that come while locked wait for the lock to say unlocked, then are answered', () async {
    var locked = true;
    final answered = <Uri>[];
    final gate = LinkGate(locked: () => locked, answer: (uri) async => answered.add(uri));
    final links = StreamController<Uri>();
    final sub = gate.listenTo(links.stream);
    addTearDown(sub.cancel);
    links.add(Uri.parse('zestssh://connect?name=web-01'));
    await pumpEventQueue();
    expect(answered, isEmpty, reason: 'answered behind the lock screen');
    gate.lockChanged(true);
    await pumpEventQueue();
    expect(answered, isEmpty);
    locked = false;
    gate.lockChanged(false);
    await pumpEventQueue();
    expect(answered, [Uri.parse('zestssh://connect?name=web-01')]);
    links.add(Uri.parse('zestssh://share?d=demo'));
    await pumpEventQueue();
    expect(answered.last, Uri.parse('zestssh://share?d=demo'), reason: 'unlocked, at once');
  });

  test('the app hands every link it is given to the gate, and tells it when it is unlocked', () {
    final app = File('lib/app.dart').readAsStringSync().replaceAll('\r\n', '\n');
    expect(app, contains('_deepLinkSub = _linkGate.listenTo(DeepLinkService.linkStream);'));
    expect(app, contains('_navigateToDeepLink(initialLink);'));
    expect(app, contains('Future<void> _navigateToDeepLink(Uri uri) => _linkGate.offer(uri);'));
    expect(app, contains('ref.listenManual<bool>(isAppLockedProvider, (_, locked) => _linkGate.lockChanged(locked));'));
    expect(app, contains('LinkGate(locked: () => ref.read(isAppLockedProvider), answer: _answerDeepLink)'));
  });
}
