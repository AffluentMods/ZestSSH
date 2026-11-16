import 'dart:async';

import 'package:zestssh/utils/logger.dart';

/// A link that comes while the app is locked waits until it is unlocked, then
/// is answered as any link is (found in a security
/// review of the client). With the app lock that hides the screen (the default; only the
/// encrypting lock closes the database), a link was answered behind the lock
/// screen: its question showed over it, so whoever had the device could add a
/// host someone shared or open a session to a saved one, and a link to a host
/// by its name said whether one of that name was saved.
///
/// Only the latest link waits; one before it is dropped, as the person would
/// see only the last.
class LinkGate {
  LinkGate({required this.locked, required this.answer});

  /// Whether the app is locked now.
  final bool Function() locked;

  /// Answers a link, the app unlocked.
  final Future<void> Function(Uri uri) answer;

  Uri? _waiting;

  /// The link waiting for the app to be unlocked, if any.
  Uri? get waiting => _waiting;

  /// [uri] is answered now, or once the app is unlocked ([unlocked]).
  Future<void> offer(Uri uri) async {
    if (locked()) {
      AppLogger.info('Deep link waits until the app is unlocked');
      _waiting = uri;
      return;
    }
    await answer(uri);
  }

  /// Every link of [links] is offered here: how the app hands this gate the
  /// links that come while it runs.
  StreamSubscription<Uri> listenTo(Stream<Uri> links) => links.listen(offer);

  /// What the app lock says now ([locked] each time it changes): unlocked,
  /// the link waiting is answered.
  void lockChanged(bool locked) {
    if (!locked) unawaited(unlocked());
  }

  /// The app was unlocked: the link waiting, if any, is answered.
  Future<void> unlocked() async {
    final uri = _waiting;
    if (uri == null || locked()) return;
    _waiting = null;
    await answer(uri);
  }
}
