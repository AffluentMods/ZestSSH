import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/utils/redactor.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An address shown or copied with its port writes an IPv6 one between
/// brackets (3.0): "2001:db8::1:22" read as an address with
/// no port, and copied so (Copy IP:port) it could not be pasted where an
/// address and its port are asked for. Every screen and feature joins them
/// with hostWithPort; what still joins them as they are is a key the app
/// looks its own data up by, which keeps its form.
void main() {
  /// Keys the app looks its own data up by: their form stays.
  const keys = {
    // A folder sync's server, by which its manifest and its choices are kept.
    'lib/ui/screens/sftp/sftp_dual_pane_screen.dart',
    // A Proxmox cluster's id, kept with each host it imported, which sync carries.
    'lib/features/cloud_import/cloud_scans.dart',
  };

  /// The places of [files] that join a host and its port as they are, as
  /// "file:line".
  List<String> plainJoins(Map<String, String> files) {
    final join = RegExp(r'\$\{?([\w.!?]*\bhost)\}?:\$\{?([\w.!?]*\bport)');
    return [
      for (final MapEntry(key: path, value: text) in files.entries)
        for (final (i, line) in text.replaceAll('\r\n', '\n').split('\n').indexed)
          if (join.hasMatch(line)) '$path:${i + 1}',
    ]..sort();
  }

  test('every screen and feature joins an address and its port with hostWithPort, but for the keys', () {
    final files = <String, String>{};
    for (final root in ['lib/ui', 'lib/features']) {
      for (final file in Directory(root).listSync(recursive: true).whereType<File>()) {
        final path = file.path.replaceAll('\\', '/');
        if (!path.endsWith('.dart') || keys.contains(path)) continue;
        files[path] = file.readAsStringSync();
      }
    }
    expect(files, isNotEmpty);
    expect(plainJoins(files), isEmpty, reason: 'hostWithPort writes an IPv6 address between brackets');
  });

  test('the check itself finds a plain join, and not one through hostWithPort', () {
    const plain = r"final a = '${conn.host}:${conn.port}';";
    const short = r"final b = '$host:$port';";
    const through = r'final c = hostWithPort(conn.host, conn.port);';
    expect(plainJoins({'a': plain, 'b': short, 'c': through}), ['a:1', 'b:1']);
  });

  test('while the screen is recorded, an IPv6 address with its port is masked as any address is', () {
    addTearDown(() => Redactor.instance
      ..clearNames()
      ..enabled = false);
    Redactor.instance
      ..clearNames()
      ..enabled = true
      ..level = RedactLevel.layout;
    // (A stand-in for an IPv6 address is one of the documentation range,
    // 2001:db8::/32: the address masked here is outside it.)
    final shown = Redactable.address(hostWithPort('fd12:3456:789a::1', 22)).display;
    expect(shown, isNot(contains('fd12')));
    expect(shown, isNot(contains('789a')));
    expect(shown, endsWith(']:22'), reason: 'the brackets and the port stay: $shown');
  });

  testWidgets("a phone's host card shows an IPv6 address between brackets before its port", (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2026, 10, 17);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-v6', label: 'v6-host', host: '2001:db8::1', port: const Value(2222), createdAt: at, updatedAt: at));
    final host = (await db.connectionsDao.getById('h-v6'))!;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PhoneHostRow(
            host: ConnectionWithDetails(connection: host),
            open: false,
            health: null,
            pinned: false,
            actions: PhoneHostActions(connect: () {}, edit: () {}),
          ),
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('[2001:db8::1]:2222'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  });
}
