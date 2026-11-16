import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';

/// The row a phone's host list draws for the host [id] ("Web 1" at
/// web1.example.com), for a test that has set up its team; and what the card
/// reads beside the team ([phoneHostCardNeeds]).
Future<Widget> phoneHostCard(WidgetTester tester, String id) async {
  late Connection host;
  await tester.runAsync(() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 19);
    await db.into(db.connections).insert(
        ConnectionsCompanion.insert(id: id, label: 'Web 1', host: 'web1.example.com', createdAt: at, updatedAt: at));
    host = (await db.connectionsDao.getById(id))!;
    await db.close();
  });
  return PhoneHostRow(
    host: ConnectionWithDetails(connection: host),
    open: false,
    health: null,
    pinned: false,
    actions: PhoneHostActions(connect: () {}, edit: () {}),
  );
}

/// What a phone's host card reads that a team's test does not set up: the
/// app's preferences, and a Squeezed account without RevenueCat.
Future<List<Override>> phoneHostCardNeeds(WidgetTester tester) async {
  late SharedPreferences prefs;
  await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  return [
    sharedPreferencesProvider.overrideWithValue(prefs),
    isProProvider.overrideWith((ref) => _Pro()),
  ];
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
