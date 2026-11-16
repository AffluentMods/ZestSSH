import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/src/message/msg_userauth.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_tester.dart';
import 'package:zestssh/features/hosts/widgets/host_network_overrides_section.dart' show EffectiveTestConfig;
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../../packages/zest_ssh_core/test/src/played_server.dart';

/// The Test of a team's SSH host goes by the key its vault pinned, as a
/// session does and as an FTPS host's test goes by the pinned certificate
/// (found in a security review). It read only this device's own known
/// hosts: a member who had never connected to the host has no row there (a
/// pinned key is trusted without one), so another key was asked about as a
/// new host's, and on a yes the test signed in to whoever showed it.

const _crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';

void main() {
  /// A team whose vault "Production" holds the host web-01, which this
  /// account may use and not edit, with [pinned] as its pinned key.
  Future<AppDatabase> team(PlayedHostKey pinned) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
      "VALUES (1, '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3', 'Acme', 'member', 1, ?)",
      [_crate],
    );
    await db.customStatement(
      "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'Production', 'manage', ?, 1)",
      [_crate, jsonEncode(CrateSwitches.all.toList()..sort())],
    );
    await CratePlacement(db).place('host', 'h1', _crate);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h1',
          label: 'web-01',
          host: 'web-01.example.com',
          port: const Value(22),
          createdAt: DateTime(2026, 11, 9),
          updatedAt: DateTime(2026, 11, 9),
        ));
    await TeamHostKeys(db)
        .pin('web-01.example.com', 22, SSHHostKey(type: pinned.algorithm, bytes: pinned.blob), crateId: _crate);
    // Made by someone who may edit the vault; this account may only connect.
    await db.customStatement("UPDATE orchard_crates SET level = 'use', switches = ? WHERE crate_id = ?",
        [jsonEncode([CrateSwitches.connect]), _crate]);
    expect(await TeamHostKeys(db).mayPinIn(_crate), isFalse);
    return db;
  }

  Future<(BuildContext, WidgetRef)> screen(WidgetTester tester, AppDatabase db) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    late BuildContext at;
    late WidgetRef widgetRef;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Consumer(builder: (context, ref, _) {
          at = context;
          widgetRef = ref;
          return const SizedBox();
        }),
      ),
    ));
    return (at, widgetRef);
  }

  HostTester testerOf(BuildContext at, WidgetRef ref) => HostTester(
        context: at,
        ref: ref,
        hostId: 'h1',
        addressTypedHere: false,
        addressChosenHere: (_) async => false,
        wouldGoUnwatched: (db, {hostId, keyId}) async => false,
        requireCratesOpen: (db, {hostId, keyId}) async {},
      );

  const cfg = EffectiveTestConfig(host: 'web-01.example.com', port: 22, username: 'deploy');

  testWidgets('another key than the one the team pinned stops the test: no question, no sign-in, and it says '
      'whose pin it is', (tester) async {
    final pinned = PlayedHostKey.ed25519();
    final db = (await tester.runAsync(() => team(pinned)))!;
    addTearDown(db.close);
    final server = PlayedServer(hostKey: PlayedHostKey.ed25519());
    SshService.debugOpenSocket = (host, port, timeout) async => server.socket;
    addTearDown(() => SshService.debugOpenSocket = null);
    final (at, ref) = await screen(tester, db);

    Object? asked;
    final result = await tester.runAsync(() async {
      final testing = testerOf(at, ref).fullConnection(cfg);
      // The server plays its part up to the sign-in, which must never come.
      unawaited(server
          .greet()
          .then((_) => server.next(SSH_Message_Userauth_Request.messageId))
          .then<void>((request) => asked = request)
          .catchError((Object _) {}));
      return testing.timeout(const Duration(seconds: 20));
    });
    await tester.pump();

    expect(find.byType(Dialog), findsNothing, reason: 'the key was asked about as a new host\'s');
    expect(result, isNotNull);
    expect(result!.success, isFalse);
    expect(result.message, contains('Production'), reason: result.message);
    expect(asked, isNull, reason: 'a sign-in request reached a server that did not show the pinned key');
  });

  testWidgets('the pinned key is trusted with no question, on a device that never connected to the host',
      (tester) async {
    final pinned = PlayedHostKey.ed25519();
    final db = (await tester.runAsync(() => team(pinned)))!;
    addTearDown(db.close);
    final server = PlayedServer(hostKey: pinned);
    SshService.debugOpenSocket = (host, port, timeout) async => server.socket;
    addTearDown(() => SshService.debugOpenSocket = null);
    final (at, ref) = await screen(tester, db);

    final result = await tester.runAsync(() async {
      final testing = testerOf(at, ref).fullConnection(cfg);
      await server.greet();
      await server.next(SSH_Message_Userauth_Request.messageId);
      server.send([SSH_Message_Userauth_Success().encode()]);
      return testing.timeout(const Duration(seconds: 20));
    });

    expect(result!.success, isTrue, reason: result.message);
    expect(await tester.runAsync(() => db.select(db.knownHosts).get()), isEmpty,
        reason: 'a test keeps no trust of its own');
  });
}
