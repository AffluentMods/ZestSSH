// A Linux desktop's word on the person at it (a security experience
// review), asked over D-Bus where
// the desktop answers; no code in the runner. Every call only reads.
//
// Idle time: GNOME's org.gnome.Mutter.IdleMonitor (GetIdletime, in
// milliseconds; X11 and Wayland alike). The freedesktop ScreenSaver's
// GetSessionIdleTime is left alone: desktops answer it in seconds or in
// milliseconds, or with 0 where they do not count, and a time read too short
// would keep the app from locking. Elsewhere the app counts its own input,
// as before.
// Lock: logind's LockedHint of this session (set by the desktop's lock
// screen, GNOME's and KDE's among them), or the freedesktop ScreenSaver's
// GetActive (KDE and others).
//
// A desktop or a bus that does not answer leaves the app as it was before:
// what is not there is not asked again, and a call that hangs is let go.

import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:zestssh/services/presence/system_presence.dart';
import 'package:zestssh/utils/logger.dart';

/// How long a call may take before it counts as no answer.
const _kCallTimeout = Duration(seconds: 2);

/// Failures of a bus in a row (no socket, a call that hangs) after which it
/// is not asked again.
const _kBusFailuresToGiveUp = 3;

class LinuxPresence implements SystemPresence {
  LinuxPresence();

  final _session = _Bus('session', DBusClient.session);
  final _system = _Bus('system', DBusClient.system);

  /// Sources that are not there on this desktop: not asked again.
  final _gone = <String>{};

  /// The path of this session's logind object that answered.
  String? _sessionPath;

  @override
  Future<Duration?> idleTime() async {
    final ms = await _call(
      _session,
      'mutter-idle',
      destination: 'org.gnome.Mutter.IdleMonitor',
      path: '/org/gnome/Mutter/IdleMonitor/Core',
      interface: 'org.gnome.Mutter.IdleMonitor',
      name: 'GetIdletime',
      signature: 't',
    );
    return ms is DBusUint64 ? Duration(milliseconds: ms.value) : null;
  }

  @override
  Future<bool?> isLocked() async {
    final hint = await _lockedHint();
    if (hint == true) return true;
    final active = await _call(
      _session,
      'screensaver-active',
      destination: 'org.freedesktop.ScreenSaver',
      path: '/org/freedesktop/ScreenSaver',
      interface: 'org.freedesktop.ScreenSaver',
      name: 'GetActive',
      signature: 'b',
    );
    final saver = active is DBusBoolean ? active.value : null;
    if (saver == true) return true;
    return hint == null && saver == null ? null : false;
  }

  /// logind's LockedHint of the session this app runs in: "auto" (the
  /// caller's session, or the person's display session), else "self".
  Future<bool?> _lockedHint() async {
    final known = _sessionPath;
    final paths = known != null
        ? [known]
        : const ['/org/freedesktop/login1/session/auto', '/org/freedesktop/login1/session/self'];
    for (final path in paths) {
      final value = await _call(
        _system,
        'logind-$path',
        destination: 'org.freedesktop.login1',
        path: path,
        interface: 'org.freedesktop.DBus.Properties',
        name: 'Get',
        values: const [DBusString('org.freedesktop.login1.Session'), DBusString('LockedHint')],
        signature: 'v',
      );
      if (value is DBusVariant && value.value is DBusBoolean) {
        _sessionPath = path;
        return (value.value as DBusBoolean).value;
      }
    }
    return null;
  }

  /// The one value a method answers with, or null when it does not answer.
  Future<DBusValue?> _call(
    _Bus bus,
    String source, {
    required String destination,
    required String path,
    required String interface,
    required String name,
    Iterable<DBusValue> values = const [],
    required String signature,
  }) async {
    if (_gone.contains(source)) return null;
    final client = bus.client;
    if (client == null) return null;
    try {
      final reply = await client
          .callMethod(
            destination: destination,
            path: DBusObjectPath(path),
            interface: interface,
            name: name,
            values: values,
            replySignature: DBusSignature(signature),
            noAutoStart: true,
          )
          .timeout(_kCallTimeout);
      bus.answered();
      return reply.returnValues.single;
    } on DBusServiceUnknownException {
      _gone.add(source);
    } on DBusUnknownObjectException {
      _gone.add(source);
    } on DBusUnknownInterfaceException {
      _gone.add(source);
    } on DBusUnknownMethodException {
      _gone.add(source);
    } on DBusUnknownPropertyException {
      _gone.add(source);
    } on DBusNotSupportedException {
      _gone.add(source);
    } on DBusAccessDeniedException {
      _gone.add(source);
    } on DBusReplySignatureException {
      _gone.add(source);
    } on DBusMethodResponseException {
      // The service answered with another error: no answer this time.
    } catch (e) {
      // No bus, a call that hangs: the connection is dropped and made again.
      await bus.failed(e);
    }
    return null;
  }

  @override
  Future<void> close() async {
    await _session.close();
    await _system.close();
  }
}

/// One of the two buses, connected when first asked, given up on after
/// failing [_kBusFailuresToGiveUp] times in a row.
class _Bus {
  _Bus(this.name, this._connect);

  final String name;
  final DBusClient Function() _connect;
  DBusClient? _client;
  int _failures = 0;

  DBusClient? get client {
    if (_failures >= _kBusFailuresToGiveUp) return null;
    try {
      return _client ??= _connect();
    } catch (e) {
      _failures = _kBusFailuresToGiveUp;
      AppLogger.warning('Presence: no $name bus ($e)');
      return null;
    }
  }

  void answered() => _failures = 0;

  Future<void> failed(Object e) async {
    final client = _client;
    _client = null;
    if (++_failures == _kBusFailuresToGiveUp) AppLogger.warning('Presence: the $name bus does not answer ($e)');
    if (client != null) unawaited(client.close().catchError((Object _) {}));
  }

  Future<void> close() async {
    final client = _client;
    _client = null;
    _failures = _kBusFailuresToGiveUp;
    if (client != null) await client.close().catchError((Object _) {});
  }
}
