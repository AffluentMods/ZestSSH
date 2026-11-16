import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/port_forward_service.dart';
import 'package:zestssh/services/socks5_service.dart';
import 'package:zestssh/ui/screens/port_forward/port_forward_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// A session's port forwards on a phone: a forward that did
/// not start said only "Failed to update port forward. Please try again.". It
/// says why now, as the computer's do, with the details to copy.
class _PortInUse extends Fake implements PortForwardService {
  @override
  bool isActive(String id) => false;

  @override
  Socks5ProxyServer? getSocks5Server(String id) => null;

  @override
  Future<void> startForward(PortForward forward) async =>
      throw const SocketException('Address already in use', osError: OSError('Address already in use', 98));
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets('a forward that did not start says why', (tester) async {
    // The phone's own toast, as on a phone.
    debugTopSnackBarOnPhone = true;
    addTearDown(() => debugTopSnackBarOnPhone = null);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime.utc(2026, 10, 22);
    await tester.runAsync(() async {
      await db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: const Value('h1'),
        label: const Value('web-01'),
        host: const Value('web-01.example.com'),
        port: const Value(22),
        protocol: const Value('ssh'),
        createdAt: Value(at),
        updatedAt: Value(at),
      ));
      await db.portForwardRulesDao.insertRule(PortForwardRulesCompanion.insert(
        id: 'r1',
        connectionId: 'h1',
        type: 'local',
        bindPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
        label: const Value('Web'),
        createdAt: at,
      ));
    });
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        portForwardRulesDaoProvider.overrideWithValue(db.portForwardRulesDao),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: PortForwardScreen(portForwardService: _PortInUse(), connectionLabel: 'web-01', connectionId: 'h1'),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(en.portForwardStart));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(en.pfSessionStartFailed('Web', en.pfFailedPortInUse(8080))), findsOneWidget);
    expect(find.text('Failed to update port forward. Please try again.'), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });
}
