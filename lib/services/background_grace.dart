// A little time in the background (4.0, remote screens). iOS suspends an app
// a few seconds after it leaves the screen, and a suspended app's sockets can
// be taken from it at any time; no background mode fits a remote screen (one
// used for it would be refused in review). What the app can ask for is
// UIApplication.beginBackgroundTask: about 30 seconds to finish cleanly. The
// channel is answered in ios/Runner/AppDelegate.swift; every other platform
// answers nothing, and gets no grace (it needs none: Android keeps its
// sessions under the foreground service, a computer keeps them anyway).
import 'package:flutter/services.dart';

/// What [BackgroundGrace] does, so tests can give their own.
abstract interface class BackgroundGraceApi {
  /// Asks for time to finish in the background: how long the system gives,
  /// or null where it gives none. [onExpired] is called if the time runs out
  /// before [end] (said by the system, a moment before it suspends the app).
  Future<Duration?> begin({required VoidCallback onExpired});

  /// The work is done (or the app is back in front): the time is given back.
  Future<void> end();
}

/// No time in the background: every platform but iOS.
class NoBackgroundGrace implements BackgroundGraceApi {
  const NoBackgroundGrace();

  @override
  Future<Duration?> begin({required VoidCallback onExpired}) async => null;

  @override
  Future<void> end() async {}
}

/// iOS's background task on `com.affluentlabs.zestssh/background`.
class BackgroundGrace implements BackgroundGraceApi {
  BackgroundGrace({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const channelName = 'com.affluentlabs.zestssh/background';

  final MethodChannel _channel;
  VoidCallback? _onExpired;

  @override
  Future<Duration?> begin({required VoidCallback onExpired}) async {
    _onExpired = onExpired;
    try {
      final seconds = await _channel.invokeMethod<double>('begin');
      if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
      return Duration(milliseconds: (seconds * 1000).round());
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> end() async {
    _onExpired = null;
    try {
      await _channel.invokeMethod<void>('end');
    } on MissingPluginException {
      // Nothing to give back.
    } on PlatformException {
      // As above.
    }
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'expired') return;
    final expired = _onExpired;
    _onExpired = null;
    expired?.call();
  }
}
