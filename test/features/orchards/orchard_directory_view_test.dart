import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/directory/orchard_directory_api.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/orchard_directory_view.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';

import 'fake_crate_server.dart';

/// Directory sync on the Team page's Sign-in page (3.0):
/// turning it on shows the token once; each group maps to a role; each
/// change the directory asks for is acted on with the Orchard's usual
/// signed change and then set aside, and one the signed record already
/// reflects is set aside on its own; admins see the queue but do not run
/// the directory.

const _owner = 'owner-1';
const _alice = 'alice-2';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

/// ZestSSH Cloud's directory routes for one Orchard, in memory.
class _Directory {
  var enabled = false;
  var lowers = false;
  var autoRoles = false;

  /// Groups mapped as made for them (auto: true), by id.
  final auto = <String>{};
  var people = <String, List<Map<String, Object?>>>{};
  var groups = <Map<String, Object?>>[];
  var pending = <Map<String, Object?>>[];
  final dismissed = <int>[];
  final mapped = <String, Object?>{};
  var tokens = 0;

  http.Response json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Future<http.Response> answer(http.Request request) async {
    final tail = request.url.pathSegments.skip(4).toList(); // v1 orchards <id> directory [...]
    switch ((request.method, tail.join('/'))) {
      case ('GET', ''):
        return json(200, {
          'enabled': enabled,
          'scim_url': enabled ? 'https://api.test/scim/v2/o' : null,
          'last_contact': null,
          'lowers': lowers,
          'auto_roles': autoRoles,
          'groups': [
            for (final g in groups) {...g, 'auto_role': auto.contains(g['id'])},
          ],
          'pending': pending,
          'held': const [],
        });
      case ('POST', ''):
        enabled = true;
        tokens++;
        return json(201, {'token': 'scim-token-$tokens', 'scim_url': 'https://api.test/scim/v2/o'});
      case ('PUT', 'settings'):
        final body = jsonDecode(request.body) as Map;
        if (body.containsKey('auto_roles')) autoRoles = body['auto_roles'] == true;
        if (body.containsKey('lowers')) {
          lowers = body['lowers'] == true;
          // Off, what waited to lower someone goes.
          if (!lowers) pending.removeWhere((c) => c['kind'] == 'lower');
        }
        return json(200, {'lowers': lowers, 'auto_roles': autoRoles});
      case ('DELETE', ''):
        enabled = false;
        return json(200, {'removed': true});
    }
    if (request.method == 'GET' && tail.length == 3 && tail[0] == 'groups' && tail[2] == 'people') {
      return json(200, {'people': people[tail[1]] ?? const []});
    }
    if (request.method == 'PUT' && tail.length == 2 && tail[0] == 'groups') {
      final body = jsonDecode(request.body) as Map;
      final role = body['role'];
      mapped[tail[1]] = role;
      body['auto'] == true ? auto.add(tail[1]) : auto.remove(tail[1]);
      final g = groups.firstWhere((g) => g['id'] == tail[1]);
      g['role'] = role;
      return json(200, g);
    }
    if (request.method == 'DELETE' && tail.length == 2 && tail[0] == 'changes') {
      final id = int.parse(tail[1]);
      dismissed.add(id);
      final before = pending.length;
      pending.removeWhere((c) => c['id'] == id);
      return pending.length < before ? json(200, {'removed': true}) : json(404, {'code': 'not-found'});
    }
    return json(404, {'code': 'not-found'});
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late _MemoryStorage storage;
  late FakeCrateServer server;
  late OrchardService service;
  late _Directory directory;
  late String orchardId;
  late String memberRole;
  final keys = <String, AccountKeys>{};

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = _MemoryStorage();
    directory = _Directory();
  });

  tearDown(() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  });

  /// The owner's Orchard, with Alice in it as a Member.
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        for (final uid in [_owner, _alice]) {
          keys[uid] ??= await AccountKeys.generate();
        }
        server = FakeCrateServer(accountUid: _owner);
        for (final uid in [_owner, _alice]) {
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        service = OrchardService(
          server: server,
          databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
          author: () async => CrateAuthor(uid: _owner, keys: keys[_owner]!),
        );
        orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        memberRole = server.recordOf(orchardId).roles.values.single.id;
        await service.invite(orchardId, email: '$_alice@example.com', role: memberRole);
        final invite = (await service.invites(orchardId)).single;
        server.acceptAs(orchardId, invite.id, _alice);
        await service.confirmInvite(orchardId, (await service.invites(orchardId)).single);
      });

  Future<void> open(WidgetTester tester, {String role = FixedRoles.owner}) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = OrchardDirectoryApi(
        client: MockClient(directory.answer), baseUrl: 'https://api.test/v1', bearer: () async => 't');
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardServiceProvider.overrideWithValue(service),
        orchardDirectoryApiProvider.overrideWithValue(api),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: OrchardDirectoryView(
              orchard: OrchardSummary(id: orchardId, name: 'Acme', role: role, crates: const [], defaultCrateId: null),
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
  }

  bool toasted(WidgetTester tester, String message) {
    if (find.text(message).evaluate().isNotEmpty) return true;
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    return container.read(notificationCenterProvider).history.any((n) => '${n.title} ${n.body ?? ''}'.contains(message));
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.tap(f);
    await settle(tester);
  }

  testWidgets('turned on, the token shows once with where it goes; then off again after asking', (tester) async {
    await build(tester);
    await open(tester);
    expect(find.text(l10n.directoryIntro), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('directory-on')));
    expect(find.text(l10n.directoryTokenTitle), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('directory-token')), matching: find.text('scim-token-1')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('directory-url')), matching: find.text('https://api.test/scim/v2/o')),
        findsOneWidget);
    await tap(tester, find.text(l10n.directoryTokenSaved));
    expect(find.text('scim-token-1'), findsNothing, reason: 'shown only that once');
    expect(find.text(l10n.directoryOnNoContact), findsOneWidget);

    await tap(tester, find.byKey(const ValueKey('directory-off')));
    expect(find.text(l10n.directoryOffTitle), findsOneWidget);
    await tap(tester, find.text(l10n.directoryTurnOff).last);
    expect(directory.enabled, isFalse);
    expect(find.byKey(const ValueKey('directory-on')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a group maps to a role; changes already done are set aside by themselves', (tester) async {
    await build(tester);
    await tester.runAsync(() => service.invite(orchardId, email: 'asked@example.com', role: memberRole));
    directory
      ..enabled = true
      ..groups = [
        {'id': 'g1', 'name': 'Engineering', 'role': null, 'members': 3},
      ]
      ..pending = [
        // Alice is a Member already: nothing left to do.
        {'id': 7, 'kind': 'raise', 'email': '$_alice@example.com', 'uid': _alice, 'role': memberRole},
        // Invited already.
        {'id': 8, 'kind': 'add', 'email': 'Asked@example.com', 'uid': null, 'role': memberRole},
      ];
    await open(tester);
    expect(directory.dismissed, [7, 8]);
    expect(find.byKey(const ValueKey('directory-change-7')), findsNothing);
    expect(find.text(l10n.directoryChangesEmpty), findsOneWidget);
    expect(find.text(l10n.directoryGroupLine('Engineering', 3)), findsOneWidget);

    await tap(tester, find.descendant(of: find.byKey(const ValueKey('directory-group-g1')), matching: find.byType(ZestSelect<String?>)));
    expect(find.descendant(of: find.byKey(ValueKey('zest-select-item-$memberRole')), matching: find.text('Member')),
        findsOneWidget);
    await tap(tester, find.byKey(ValueKey('zest-select-item-$memberRole')));
    expect(directory.mapped, {'g1': memberRole});
  });

  testWidgets('the directory lowers no role unless an owner lets it; turned off, what waited to lower goes',
      (tester) async {
    await build(tester);
    directory.enabled = true;
    await open(tester);
    final toggle = find.byKey(const ValueKey('directory-lowers-switch'));
    expect(tester.widget<ZestSwitch>(toggle).value, isFalse);
    expect(find.text(l10n.directoryLowersBody), findsOneWidget);
    await tap(tester, toggle);
    expect(directory.lowers, isTrue);
    expect(tester.widget<ZestSwitch>(toggle).value, isTrue);
    directory.pending = [
      {'id': 5, 'kind': 'lower', 'email': '$_alice@example.com', 'uid': _alice, 'role': memberRole},
    ];
    await tap(tester, toggle);
    expect(directory.lowers, isFalse);
    expect(directory.pending, isEmpty);
    expect(find.text(l10n.directoryChangesEmpty), findsOneWidget);
  });

  testWidgets('directory groups become roles: the switch makes a role for each group; a role of that name is used; '
      'a renamed group renames its role', (tester) async {
    await build(tester);
    directory
      ..enabled = true
      ..groups = [
        {'id': 'g1', 'name': 'Platform', 'role': null, 'members': 2},
        {'id': 'g2', 'name': 'member', 'role': null, 'members': 1},
      ];
    await open(tester);
    final toggle = find.byKey(const ValueKey('directory-auto-roles-switch'));
    expect(tester.widget<ZestSwitch>(toggle).value, isFalse);
    expect(find.text(l10n.directoryAutoRolesBody), findsOneWidget);
    expect(find.byKey(const ValueKey('directory-auto-roles-waiting')), findsNothing, reason: 'only while it is on');
    await tap(tester, toggle);
    expect(directory.autoRoles, isTrue);
    final record = server.recordOf(orchardId);
    final platform = record.roles.values.where((r) => r.id == directory.mapped['g1']).single;
    // No vaults, no powers, below every other role; mapped as made for it.
    expect(platform.crates, isEmpty);
    expect(platform.can, isEmpty);
    expect(platform.rank, lessThan(record.roles[memberRole]!.rank));
    expect(directory.auto, {'g1'});
    // "member" is the team's Member already: used, and left as an owner named it.
    expect(directory.mapped['g2'], memberRole);
    expect(record.roles, hasLength(2));
    expect(toasted(tester, l10n.directoryAutoRolesMade(2)), isTrue);

    // The directory renames Platform: its role follows; Member does not.
    directory.groups = [
      {'id': 'g1', 'name': 'Platform team', 'role': platform.id, 'members': 2},
      {'id': 'g2', 'name': 'Everyone', 'role': memberRole, 'members': 1},
      {'id': 'g3', 'name': 'Support', 'role': null, 'members': 1},
    ];
    // Opened again: Support waits for its role; Make them now makes it, and
    // renames Platform's.
    await tester.pumpWidget(const SizedBox());
    await open(tester);
    expect(find.text(l10n.directoryAutoRolesWaiting(1)), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('directory-auto-roles-now')));
    expect(toasted(tester, l10n.directoryAutoRolesMade(1)), isTrue);
    final names = {for (final r in (await tester.runAsync(() => service.roles(orchardId)))!) r.id: r.name};
    expect(names[platform.id], 'Platform team');
    expect(names[memberRole], 'Member', reason: 'a role an owner named keeps its name');
    expect(names[directory.mapped['g3']], 'Support');
    expect(directory.auto, {'g1', 'g3'});
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a group opens to its people, each with where they stand', (tester) async {
    await build(tester);
    directory
      ..enabled = true
      ..groups = [
        {'id': 'g1', 'name': 'Platform', 'role': memberRole, 'members': 3},
      ]
      ..people = {
        'g1': [
          {'email': '$_alice@example.com', 'active': true, 'state': 'member', 'role': memberRole},
          {'email': 'new@example.com', 'active': true, 'state': 'waiting', 'role': null},
          {'email': 'gone@example.com', 'active': false, 'state': 'outside', 'role': null},
        ],
      };
    await open(tester);
    expect(find.byKey(const ValueKey('directory-person-new@example.com')), findsNothing);
    await tap(tester, find.byKey(const ValueKey('directory-group-open-g1')));
    expect(find.descendant(of: find.byKey(const ValueKey('directory-person-new@example.com')),
        matching: find.text(l10n.directoryPersonWaiting)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('directory-person-gone@example.com')),
        matching: find.text(l10n.directoryPersonOff)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('directory-person-$_alice@example.com')),
        matching: find.text('Member')), findsOneWidget);
  });

  testWidgets('Invite all: every waiting invitation at once after asking, each then set aside', (tester) async {
    await build(tester);
    directory
      ..enabled = true
      ..pending = [
        {'id': 3, 'kind': 'add', 'email': 'new@example.com', 'uid': null, 'role': memberRole},
        {'id': 4, 'kind': 'add', 'email': 'other@example.com', 'uid': null, 'role': memberRole},
      ];
    await open(tester);
    await tap(tester, find.byKey(const ValueKey('directory-invite-all')));
    expect(find.text(l10n.directoryInviteAllTitle(2)), findsOneWidget);
    await tap(tester, find.text(l10n.directoryInviteAll(2)).last);
    final invites = await tester.runAsync(() => service.invites(orchardId));
    expect(invites!.map((i) => i.email).toSet(), containsAll(['new@example.com', 'other@example.com']));
    expect(directory.dismissed.toSet(), {3, 4});
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a removal the directory asked for: the signed change, then set aside', (tester) async {
    await build(tester);
    directory
      ..enabled = true
      ..pending = [
        {'id': 9, 'kind': 'remove', 'email': '$_alice@example.com', 'uid': _alice, 'role': null},
      ];
    await open(tester);
    final row = find.byKey(const ValueKey('directory-change-9'));
    expect(row, findsOneWidget);
    expect(find.text(l10n.directoryChangeRemove('$_alice@example.com')), findsOneWidget);

    // Set aside would drop it; this time, act on it.
    await tap(tester, find.descendant(of: row, matching: find.text(l10n.orchardRemoveConfirm)));
    expect(find.text(l10n.orchardRemoveTitle('$_alice@example.com')), findsOneWidget);
    await tap(tester, find.text(l10n.orchardRemoveConfirm).last);
    expect(server.recordOf(orchardId).members[_alice]!.status, MemberStatus.removed);
    expect(server.rotations, isNotEmpty, reason: 'what she could open gets new keys');
    expect(directory.dismissed, [9]);
    expect(find.byKey(const ValueKey('directory-change-9')), findsNothing);
    expect(toasted(tester, l10n.directoryChangeDone), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an invitation the directory asked for, and one set aside', (tester) async {
    await build(tester);
    directory
      ..enabled = true
      ..pending = [
        {'id': 3, 'kind': 'add', 'email': 'new@example.com', 'uid': null, 'role': memberRole},
        {'id': 4, 'kind': 'add', 'email': 'other@example.com', 'uid': null, 'role': memberRole},
      ];
    await open(tester);
    final invite3 = find.descendant(of: find.byKey(const ValueKey('directory-change-3')), matching: find.text(l10n.directoryInvite));
    // Asked first: cancelling does nothing.
    await tap(tester, invite3);
    expect(find.text(l10n.directoryInviteTitle('new@example.com')), findsOneWidget);
    await tap(tester, find.text(l10n.cancel).last);
    expect(directory.dismissed, isEmpty);
    expect((await tester.runAsync(() => service.invites(orchardId)))!.map((i) => i.email), isNot(contains('new@example.com')));
    await tap(tester, invite3);
    await tap(tester, find.text(l10n.directoryInvite).last);
    final invites = await tester.runAsync(() => service.invites(orchardId));
    expect(invites!.map((i) => (i.email, i.role)), contains(('new@example.com', memberRole)));
    expect(directory.dismissed, [3]);

    await tap(tester, find.descendant(of: find.byKey(const ValueKey('directory-change-4')), matching: find.text(l10n.directorySetAside)));
    expect(directory.dismissed, [3, 4]);
    expect(find.text(l10n.directoryChangesEmpty), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an admin sees the queue, not the switches', (tester) async {
    await build(tester);
    directory
      ..enabled = true
      ..groups = [
        {'id': 'g1', 'name': 'Engineering', 'role': null, 'members': 1},
      ];
    await open(tester, role: FixedRoles.admin);
    expect(find.byKey(const ValueKey('directory-off')), findsNothing);
    expect(find.byKey(const ValueKey('directory-token-new')), findsNothing);
    final select = tester.widget<ZestSelect<String?>>(
        find.descendant(of: find.byKey(const ValueKey('directory-group-g1')), matching: find.byType(ZestSelect<String?>)));
    expect(select.onChanged, isNull, reason: 'only owners map groups');
    expect(find.byKey(const ValueKey('directory-lowers')), findsNothing, reason: 'only owners say whether it lowers');
    expect(find.byType(ZestButton), findsNothing);
  });
}

/// Lets the requests finish, then the frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    if (i >= 3 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
