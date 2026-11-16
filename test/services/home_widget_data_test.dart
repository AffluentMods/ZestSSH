// What the home screen widget is given (4.0, the iPhone's widget, and
// Android's under the lock): your Tree's hosts by id, name and address and
// nothing else of them, at most four, none while the app lock is on, and to
// which side.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/widget_service.dart';

Connection _host(String id, {String? label, String host = '10.0.0.1', int port = 22}) {
  final now = DateTime(2026, 11, 14);
  return Connection(
    id: id,
    label: label ?? 'host-$id',
    host: host,
    port: port,
    identityId: 'identity-secret-$id',
    colorIndex: 0,
    protocol: 'ssh',
    zlibCompression: false,
    startupCommand: 'export DB_PASSWORD=hunter2-$id',
    keepAliveSeconds: 0,
    wolMacAddress: 'aa:bb:cc:dd:ee:ff',
    envVars: 'API_TOKEN=s3cr3t-$id',
    forwardAgent: false,
    compatibilityMode: false,
    sortOrder: 0,
    sizeTier: 1,
    pinned: false,
    monitored: false,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final hosts = [
    _host('a', label: 'Production', host: 'prod.example.com', port: 2222),
    _host('b', label: '', host: '2001:db8::1'),
    _host('c'),
    _host('d'),
    _host('e'),
  ];

  group('homeWidgetUpdate', () {
    test('lists the first four of your Tree, by id, name and address only', () {
      final data = homeWidgetUpdate(inTree: true, locked: false, connections: hosts)!;
      expect(data.locked, isFalse);
      expect(data.hosts!.map((h) => h.id), ['a', 'b', 'c', 'd']);
      // A host with no name is shown by its address.
      expect(data.hosts![1].label, '2001:db8::1');
      final json = jsonEncode(data.toIosJson());
      expect(jsonDecode(json), {
        'v': 1,
        'locked': false,
        'hosts': [
          {'id': 'a', 'label': 'Production', 'host': 'prod.example.com', 'port': 2222},
          {'id': 'b', 'label': '2001:db8::1', 'host': '2001:db8::1', 'port': 22},
          {'id': 'c', 'label': 'host-c', 'host': '10.0.0.1', 'port': 22},
          {'id': 'd', 'label': 'host-d', 'host': '10.0.0.1', 'port': 22},
        ],
      });
      for (final secret in ['hunter2', 's3cr3t', 'identity-secret', 'DB_PASSWORD', 'API_TOKEN', 'aa:bb:cc']) {
        expect(json, isNot(contains(secret)), reason: secret);
      }
      for (final h in data.hosts!) {
        expect(h.toJson().keys, unorderedEquals(['id', 'label', 'host', 'port']));
      }
    });

    test('with the app lock on, the iPhone is given no host at all', () {
      final data = homeWidgetUpdate(inTree: true, locked: true, connections: hosts)!;
      expect(data.locked, isTrue);
      final ios = data.toIosJson();
      expect(ios, {'v': 1, 'locked': true, 'hosts': <Object>[]});
      final json = jsonEncode(ios);
      for (final word in ['Production', 'prod.example.com', '2001:db8', '10.0.0.1', 'host-c', '"a"']) {
        expect(json, isNot(contains(word)), reason: word);
      }
    });

    test('a team space on screen: nothing, unless the lock is on', () {
      expect(homeWidgetUpdate(inTree: false, locked: false, connections: hosts), isNull);
      final locked = homeWidgetUpdate(inTree: false, locked: true, connections: hosts)!;
      expect(locked.locked, isTrue);
      expect(locked.hosts, isNull, reason: 'a team space\'s hosts never go to the widget');
      expect(locked.toIosJson(), {'v': 1, 'locked': true, 'hosts': <Object>[]});
    });

    test('hosts not known yet (the database behind the lock): only the lock', () {
      expect(homeWidgetUpdate(inTree: true, locked: false, connections: null), isNull);
      final locked = homeWidgetUpdate(inTree: true, locked: true, connections: null)!;
      expect(locked.toIosJson(), {'v': 1, 'locked': true, 'hosts': <Object>[]});
    });

    test('no hosts: an empty list, not the lock', () {
      final data = homeWidgetUpdate(inTree: true, locked: false, connections: const [])!;
      expect(data.toIosJson(), {'v': 1, 'locked': false, 'hosts': <Object>[]});
    });
  });

  group('WidgetService.publish', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WidgetService.channel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WidgetService.channel, null);
    });

    test('iPhone: the data goes over the channel, none of it to the preferences', () async {
      // What a version before 4.0 left in the app's own preferences goes.
      SharedPreferences.setMockInitialValues(
          {WidgetService.prefsKey: '[{"id":"old"}]', WidgetService.lockedKey: false});
      final prefs = await SharedPreferences.getInstance();
      final data = homeWidgetUpdate(inTree: true, locked: false, connections: hosts)!;
      await WidgetService.publish(prefs, data, platform: TargetPlatform.iOS);
      expect(calls.map((c) => c.method), ['setWidgetData']);
      expect(jsonDecode(calls.single.arguments as String), data.toIosJson());
      expect(prefs.getKeys(), isEmpty);
    });

    test('iPhone, locked: the channel is told the lock and no host', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await WidgetService.publish(prefs, homeWidgetUpdate(inTree: true, locked: true, connections: hosts)!,
          platform: TargetPlatform.iOS);
      final sent = calls.single.arguments as String;
      expect(jsonDecode(sent), {'v': 1, 'locked': true, 'hosts': <Object>[]});
      expect(sent, isNot(contains('prod.example.com')));
      expect(prefs.getKeys(), isEmpty);
    });

    test('Android: the list in the preferences, as its widget reads it, and a reload', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await WidgetService.publish(prefs, homeWidgetUpdate(inTree: true, locked: false, connections: hosts)!,
          platform: TargetPlatform.android);
      expect(calls.map((c) => c.method), ['updateWidget']);
      final list = jsonDecode(prefs.getString(WidgetService.prefsKey)!) as List;
      expect(list, hasLength(4));
      expect(list.first, {'id': 'a', 'label': 'Production', 'host': 'prod.example.com', 'port': 2222});
      expect(prefs.getString(WidgetService.prefsKey), isNot(contains('hunter2')));
      expect(prefs.getBool(WidgetService.lockedKey), isFalse);
    });

    test('Android, locked: no host kept for it, the lock, and a reload; unlocked, the hosts again', () async {
      // What it listed before the lock was turned on goes.
      SharedPreferences.setMockInitialValues({WidgetService.prefsKey: '[{"id":"a","label":"Production"}]'});
      final prefs = await SharedPreferences.getInstance();
      await WidgetService.publish(prefs, homeWidgetUpdate(inTree: true, locked: true, connections: hosts)!,
          platform: TargetPlatform.android);
      expect(calls.map((c) => c.method), ['updateWidget']);
      expect(prefs.getString(WidgetService.prefsKey), '[]');
      expect(prefs.getBool(WidgetService.lockedKey), isTrue);

      await WidgetService.publish(prefs, homeWidgetUpdate(inTree: true, locked: false, connections: hosts)!,
          platform: TargetPlatform.android);
      expect(calls.map((c) => c.method), ['updateWidget', 'updateWidget']);
      expect(jsonDecode(prefs.getString(WidgetService.prefsKey)!) as List, hasLength(4));
      expect(prefs.getBool(WidgetService.lockedKey), isFalse);
    });

    test('Android, locked before the hosts are known (or in a team space): the lock, no host', () async {
      SharedPreferences.setMockInitialValues({WidgetService.prefsKey: '[{"id":"a","label":"Production"}]'});
      final prefs = await SharedPreferences.getInstance();
      await WidgetService.publish(prefs, homeWidgetUpdate(inTree: false, locked: true, connections: null)!,
          platform: TargetPlatform.android);
      expect(prefs.getString(WidgetService.prefsKey), '[]');
      expect(prefs.getBool(WidgetService.lockedKey), isTrue);
    });

    test('Android, unlocked, hosts not known: its list left as it is', () async {
      SharedPreferences.setMockInitialValues({WidgetService.prefsKey: '[{"id":"a"}]'});
      final prefs = await SharedPreferences.getInstance();
      await WidgetService.publish(prefs, const HomeWidgetData(locked: false), platform: TargetPlatform.android);
      expect(calls, isEmpty);
      expect(prefs.getString(WidgetService.prefsKey), '[{"id":"a"}]');
      expect(prefs.containsKey(WidgetService.lockedKey), isFalse);
    });

    test('a computer: nothing', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await WidgetService.publish(prefs, homeWidgetUpdate(inTree: true, locked: false, connections: hosts)!,
          platform: TargetPlatform.windows);
      expect(calls, isEmpty);
      expect(prefs.getKeys(), isEmpty);
    });
  });
}
