import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/utils/logger.dart';

/// One host as the home screen widget shows it: its id (the link the widget
/// opens, zestssh://connect?id=), its name and its address. Nothing else of
/// the host goes to the widget: no user, key, password, startup command or
/// environment, since the widget's list sits outside every encrypted database.
@immutable
class HomeWidgetHost {
  const HomeWidgetHost({required this.id, required this.label, required this.host, required this.port});

  /// [c] as the widget shows it: its name, else its address.
  factory HomeWidgetHost.of(Connection c) =>
      HomeWidgetHost(id: c.id, label: c.label.isNotEmpty ? c.label : c.host, host: c.host, port: c.port);

  final String id;
  final String label;
  final String host;
  final int port;

  Map<String, Object> toJson() => {'id': id, 'label': label, 'host': host, 'port': port};
}

/// What the home screen widget is given: the hosts it lists (at most
/// [HomeWidgetData.maxHosts]), and whether the app lock is on.
@immutable
class HomeWidgetData {
  const HomeWidgetData({required this.locked, this.hosts});

  /// The most hosts a widget lists (Android's has four places, the iPhone's
  /// shows four).
  static const maxHosts = 4;

  /// The app lock is on. The widget then shows no host at all, only that the
  /// app is locked.
  final bool locked;

  /// The hosts, your Tree's; null where they are not known (a team space is
  /// on screen, or the database is not open yet behind the lock).
  final List<HomeWidgetHost>? hosts;

  /// What the iPhone's widget reads (ZestSSHWidget.swift): version 1, the
  /// lock, and the hosts, none of them while the lock is on.
  Map<String, Object> toIosJson() => {
        'v': 1,
        'locked': locked,
        'hosts': [if (!locked) ...?hosts?.map((h) => h.toJson())],
      };
}

/// What the widget is to be told, from what the app knows now: null where it
/// is to be left as it is.
///
/// Only your Tree's hosts go there ([inTree]): an Orchard's hosts never leave
/// its encrypted database. With the app lock on ([locked]) the
/// widget is told so even before the hosts are known, so the widget (Android's
/// and the iPhone's) stops showing names the moment the lock is turned on,
/// whichever space is on screen.
HomeWidgetData? homeWidgetUpdate({required bool inTree, required bool locked, required List<Connection>? connections}) {
  if (!inTree || connections == null) return locked ? const HomeWidgetData(locked: true) : null;
  return HomeWidgetData(
    locked: locked,
    hosts: [for (final c in connections.take(HomeWidgetData.maxHosts)) HomeWidgetHost.of(c)],
  );
}

/// Provides data to native home screen widgets (Android / iOS).
///
/// Android's widget (QuickConnectWidget.kt) reads a JSON list of hosts the
/// app keeps in its SharedPreferences, and whether the app is locked. The iPhone's (ios/ZestSSHWidget) cannot
/// read the app's own preferences: it is given its data over the widget
/// channel, which AppDelegate.swift keeps in the App Group both share, and
/// told to reload.
class WidgetService {
  /// Android's widget reads this key ("flutter.widget_connections").
  @visibleForTesting
  static const prefsKey = 'widget_connections';

  /// And this one ("flutter.widget_locked"): the app lock is on, so it lists
  /// no host and says so.
  @visibleForTesting
  static const lockedKey = 'widget_locked';

  @visibleForTesting
  static const channel = MethodChannel('com.affluentlabs.zestssh/widget');

  /// Gives the widget [data]. [platform] is the system's (a test names one).
  static Future<void> publish(SharedPreferences prefs, HomeWidgetData data, {TargetPlatform? platform}) async {
    switch (platform ?? defaultTargetPlatform) {
      case TargetPlatform.android:
        // With the lock on, no host is kept for the widget at all (it listed
        // them under the lock before 4.0); unlocked, it is left as it is
        // until the hosts are known.
        final hosts = data.locked ? const <HomeWidgetHost>[] : data.hosts;
        if (hosts == null) return;
        await prefs.setString(prefsKey, jsonEncode([for (final h in hosts) h.toJson()]));
        await prefs.setBool(lockedKey, data.locked);
        try {
          await channel.invokeMethod('updateWidget');
        } on MissingPluginException {
          // Widget channel not registered yet
        } catch (e) {
          AppLogger.debug('Widget update skipped: $e');
        }
      case TargetPlatform.iOS:
        // Before 4.0 the list went to the app's own preferences, where the
        // widget could not read it: what an older version left there goes.
        if (prefs.containsKey(prefsKey)) await prefs.remove(prefsKey);
        if (prefs.containsKey(lockedKey)) await prefs.remove(lockedKey);
        try {
          await channel.invokeMethod('setWidgetData', jsonEncode(data.toIosJson()));
        } on MissingPluginException {
          // WidgetKit not available
        } catch (e) {
          AppLogger.debug('Widget reload skipped: $e');
        }
      default:
        return;
    }
  }
}
