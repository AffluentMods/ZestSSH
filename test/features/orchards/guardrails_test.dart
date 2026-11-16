import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show ScreenCarrierRoute, screenCarrierRouteIn;

/// The guardrails (3.0): at Connect a key's secrets stay hidden and
/// never become a file, and its password goes only to a host this account
/// cannot change; a password from a Crate that asks again goes to a host it
/// may change only once the person confirms it is them; SFTP, port
/// forwarding and agent forwarding follow the host's Crate; nothing of an
/// Orchard leaves in an export except an owner's, and not even that when the
/// Orchard's rules say no export; and while an Orchard is still being
/// read, nothing is allowed.

const _keysConnect = '11111111-1111-4111-8111-111111111111';
const _keysUse = '22222222-2222-4222-8222-222222222222';
const _hostsEdit = '33333333-3333-4333-8333-333333333333';
const _hostsConnect = '44444444-4444-4444-8444-444444444444';
const _hostsBare = '55555555-5555-4555-8555-555555555555';
const _orchard = '66666666-6666-4666-8666-666666666666';
const _hostsEditOnly = '88888888-8888-4888-8888-888888888888';
const _hostsAddOnly = '99999999-9999-4999-8999-999999999999';
const _keysAsk = '77777777-7777-4777-8777-777777777777';

Set<String> _level(CrateLevel l) => levelSwitches(l);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('in the database a session works in', () {
    late AppDatabase db;
    late AppDatabase tree;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      tree = AppDatabase.forTesting(NativeDatabase.memory());
      await db.customStatement(
          'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
          "VALUES (1, ?, 'Acme', 'member-role', 1, ?)",
          [_orchard, _hostsEdit]);
      Future<void> crate(String id, Set<String> switches) => db.customStatement(
          "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'c', 'use', ?, 1)",
          [id, jsonEncode(switchList(switches))]);
      await crate(_keysConnect, _level(CrateLevel.connect));
      await crate(_keysUse, _level(CrateLevel.use));
      await crate(_hostsEdit, {..._level(CrateLevel.edit), CrateSwitches.agent});
      await crate(_hostsConnect, _level(CrateLevel.connect));
      await crate(_hostsBare, {CrateSwitches.connect});
      await crate(_hostsEditOnly, {CrateSwitches.connect, CrateSwitches.edit});
      await crate(_hostsAddOnly, {CrateSwitches.connect, CrateSwitches.add});
      // Use, in a Crate that asks again before its secrets are shown.
      await crate(_keysAsk, _level(CrateLevel.use));
      await db.customStatement('UPDATE orchard_crates SET confirm_reveal = 1 WHERE crate_id = ?', [_keysAsk]);
      Future<void> place(String kind, String key, String crateId) => db.customStatement(
          'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES (?, ?, ?, 1)',
          [kind, key, crateId]);
      await place('key', 'k-connect', _keysConnect);
      await place('key', 'k-use', _keysUse);
      await place('key', 'k-ask', _keysAsk);
      await place('host', 'h-edit', _hostsEdit);
      await place('host', 'h-connect', _hostsConnect);
      await place('host', 'h-bare', _hostsBare);
      await place('host', 'h-edit-only', _hostsEditOnly);
      await place('host', 'h-add-only', _hostsAddOnly);
    });

    tearDown(() async {
      await db.close();
      await tree.close();
    });

    Matcher refusedWith(String message) =>
        throwsA(isA<OrchardAccessRefused>().having((e) => e.message, 'message', message));

    test("a key reached at Connect never becomes a file; one at Use does; your Tree's always", () async {
      await expectLater(requireRevealIn(db, 'k-connect', refusal: 'no file'), refusedWith('no file'));
      await requireRevealIn(db, 'k-use', refusal: 'no file');
      await requireRevealIn(tree, 'k-connect', refusal: 'no file');
      expect(keyFileRefusal, gl10n.orchardKeyFileNeedsReveal);
    });

    test('a hidden password goes only to a host this account cannot change', () async {
      await expectLater(requirePasswordHostIn(db, 'k-connect', 'h-edit'), refusedWith(gl10n.orchardPasswordWrongHost),
          reason: 'it could point that host at a server of its own');
      // Either right is enough to re-point a host: edit changes it, add
      // makes one.
      await expectLater(
          requirePasswordHostIn(db, 'k-connect', 'h-edit-only'), refusedWith(gl10n.orchardPasswordWrongHost));
      await expectLater(
          requirePasswordHostIn(db, 'k-connect', 'h-add-only'), refusedWith(gl10n.orchardPasswordWrongHost));
      await requirePasswordHostIn(db, 'k-connect', 'h-connect');
      await requirePasswordHostIn(db, 'k-use', 'h-edit');
      await requirePasswordHostIn(tree, 'k-connect', 'h-edit');
    });

    test('a password from a Crate that asks again goes to a host this account may change only once the person '
        'confirms it is them', () async {
      expect(await revealAsksAgainIn(db, 'k-ask'), isTrue);
      expect(await revealAsksAgainIn(db, 'k-use'), isFalse);
      expect(await revealAsksAgainIn(tree, 'k-ask'), isFalse, reason: 'your Tree');
      // Shown at Use, so the rule for hidden passwords lets it go anywhere;
      // asking again is what keeps it from a host this account could point
      // at a server of its own.
      await requirePasswordHostIn(db, 'k-ask', 'h-edit');
      expect(await passwordAsksAgainIn(db, 'k-ask', 'h-edit'), isTrue);
      expect(await passwordAsksAgainIn(db, 'k-ask', 'h-edit-only'), isTrue);
      expect(await passwordAsksAgainIn(db, 'k-ask', 'h-add-only'), isTrue);
      expect(await passwordAsksAgainIn(db, 'k-ask', 'h-connect'), isFalse, reason: 'a host someone else keeps');
      expect(await passwordAsksAgainIn(db, 'k-use', 'h-edit'), isFalse, reason: 'a Crate that does not ask again');
      expect(await passwordAsksAgainIn(tree, 'k-ask', 'h-edit'), isFalse);
    });

    // Found in a security review: no end-to-end check stands between
    // a remote screen's carrier and its VNC server, so whoever may change the
    // carrier decides where the screen's password goes.
    test("a remote screen's carrier counts as the screen does: a hidden password never goes through a carrier this "
        'account may change, and one that asks again asks for it', () async {
      final at = DateTime(2026, 11, 9);
      Future<void> host(String id, {String protocol = 'ssh', String? via, String address = '10.0.0.1', int port = 22}) =>
          db.into(db.connections).insert(ConnectionsCompanion.insert(
                id: id,
                label: id,
                host: address,
                port: Value(port),
                protocol: Value(protocol),
                connectViaId: Value(via),
                createdAt: at,
                updatedAt: at,
              ));
      // Written before they are placed (a Crate at Connect takes no new host).
      await host('h-edit', address: 'bastion.example.com');
      await host('c-connect', address: 'gw.example.com', port: 2222);
      await host('s-through-edit', protocol: 'vnc', via: 'h-edit', address: 'localhost', port: 5900);
      await host('s-through-connect', protocol: 'vnc', via: 'c-connect', address: 'localhost', port: 5900);
      await host('s-through-gone', protocol: 'vnc', via: 'h-gone', address: 'localhost', port: 5900);
      for (final id in ['s-through-edit', 's-through-connect', 's-through-gone', 'c-connect']) {
        await CratePlacement(db).place('host', id, _hostsConnect);
      }

      Future<ScreenCarrierRoute> route(String id) async =>
          (await screenCarrierRouteIn(db, (await db.connectionsDao.getById(id))!))!;
      final viaEdit = await route('s-through-edit');
      expect(viaEdit, (id: 'h-edit', via: 'bastion.example.com:22'));
      expect(await route('s-through-connect'), (id: 'c-connect', via: 'gw.example.com:2222'));
      expect(await screenCarrierRouteIn(db, (await db.connectionsDao.getById('h-edit'))!), isNull,
          reason: 'an SSH host has no carrier');

      // The screen itself only at Connect, its carrier at Edit: refused.
      await requirePasswordHostIn(db, 'k-connect', 's-through-edit');
      await expectLater(requirePasswordHostIn(db, 'k-connect', 's-through-edit', carrierId: viaEdit.id),
          refusedWith(gl10n.orchardPasswordWrongHost), reason: 'it could point the carrier at an SSH server of its own');
      await requirePasswordHostIn(db, 'k-connect', 's-through-connect', carrierId: 'c-connect');
      await requirePasswordHostIn(db, 'k-use', 's-through-edit', carrierId: 'h-edit');

      // Asking again.
      expect(await passwordAsksAgainIn(db, 'k-ask', 's-through-edit'), isFalse);
      expect(await passwordAsksAgainIn(db, 'k-ask', 's-through-edit', carrierId: 'h-edit'), isTrue);
      expect(await passwordAsksAgainIn(db, 'k-ask', 's-through-connect', carrierId: 'c-connect'), isFalse);

      // A carrier that is gone names its id, with no route, and is judged as
      // a host where new items go: this account may add there, so refused
      // (its session stops before this anyway: its carrier is gone).
      expect(await route('s-through-gone'), (id: 'h-gone', via: null));
      await expectLater(requirePasswordHostIn(db, 'k-connect', 's-through-gone', carrierId: 'h-gone'),
          refusedWith(gl10n.orchardPasswordWrongHost));
    });

    test('held back by the rules, every Crate asks again: a switch changed meanwhile cannot reach this device',
        () async {
      await db.customStatement("UPDATE orchard_info SET status = 'rules' WHERE id = 1");
      expect(await revealAsksAgainIn(db, 'k-use'), isTrue);
      expect(await passwordAsksAgainIn(db, 'k-use', 'h-edit'), isTrue);
      expect(await passwordAsksAgainIn(db, 'k-use', 'h-connect'), isFalse);
    });

    test('a password typed at a prompt is saved back only where the key may change', () async {
      expect(await mayEditIn(db, 'key', 'k-connect'), isFalse);
      expect(await mayEditIn(db, 'key', 'k-use'), isFalse);
      expect(await mayEditIn(db, 'host', 'h-edit'), isTrue);
      expect(await mayEditIn(tree, 'key', 'anything'), isTrue);
    });

    test("SFTP, port forwarding and agent forwarding follow the host's Crate", () async {
      expect(await hostAllowsIn(db, 'h-connect', CrateSwitches.sftp), isTrue);
      expect(await hostAllowsIn(db, 'h-connect', CrateSwitches.forward), isTrue);
      expect(await hostAllowsIn(db, 'h-connect', CrateSwitches.agent), isFalse, reason: 'never in a level');
      expect(await hostAllowsIn(db, 'h-edit', CrateSwitches.agent), isTrue);
      expect(await hostAllowsIn(db, 'h-bare', CrateSwitches.sftp), isFalse);
      expect(await hostAllowsIn(db, 'h-bare', CrateSwitches.forward), isFalse);
      expect(await hostAllowsIn(tree, 'h-bare', CrateSwitches.sftp), isTrue, reason: 'your Tree');
      expect(await hostAllowsIn(null, 'h-edit', CrateSwitches.sftp), isFalse, reason: 'its Orchard closed');
      expect(await hostAllowsIn(null, null, CrateSwitches.sftp), isTrue, reason: 'a quick connect');
    });
  });

  group('on screen', () {
    CrateSummary crate(String id, Set<String> switches) =>
        CrateSummary(id: id, name: id, level: 'use', switches: switches);
    final keys = crate(_keysConnect, _level(CrateLevel.connect));
    final keysUse = crate(_keysUse, _level(CrateLevel.use));
    final hosts = crate(_hostsEdit, _level(CrateLevel.edit));

    OrchardSummary orchard(
            {String role = 'member-role', String? defaultCrate = _hostsEdit, RecordRules rules = RecordRules.none}) =>
        OrchardSummary(
          id: _orchard,
          name: 'Acme',
          role: role,
          crates: [keys, keysUse, hosts],
          defaultCrateId: defaultCrate,
          rules: rules,
        );

    /// Runs [check] with a ref in a scope where [space] is on screen, the
    /// Orchard reads as [summary] and its keys sit in their Crates.
    Future<T> within<T>(WidgetTester tester, Space space, AsyncValue<OrchardSummary?> summary,
        T Function(WidgetRef ref) check,
        {AsyncValue<Map<String, String>> keyCrates = const AsyncData({'k-connect': _keysConnect, 'k-use': _keysUse})}) async {
      late T result;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          activeSpaceProvider.overrideWith((ref) => space),
          activeOrchardProvider.overrideWithValue(summary),
          itemCratesProvider('key').overrideWith((ref) => switch (keyCrates) {
                AsyncData(:final value) => Stream.value(value),
                _ => const Stream.empty(),
              }),
        ],
        child: Consumer(builder: (context, ref, _) {
          ref.watch(itemCratesProvider('key'));
          return const SizedBox();
        }),
      ));
      await tester.pump();
      final element = tester.element(find.byType(Consumer));
      result = check(element as WidgetRef);
      return result;
    }

    testWidgets('your Tree: everything is yours', (tester) async {
      final r = await within(tester, const TreeSpace(), const AsyncData(null), (ref) => (
            mayRevealKey(ref, 'k-connect', watch: false),
            mayChangeItem(ref, 'host', 'h', delete: true, watch: false),
            mayExportScreenSpace(ref),
            mayAddScreenSpace(ref, watch: false),
          ));
      expect(r, (true, true, true, true));
    });

    testWidgets("an Orchard: each key by its Crate, and export is an owner's", (tester) async {
      final r = await within(tester, const OrchardSpace(_orchard), AsyncData(orchard()), (ref) {
        final rules = ItemRules.of(ref, 'key', watch: false);
        return (
          rules.mayReveal('k-connect'),
          rules.mayReveal('k-use'),
          rules.mayChange('k-use'),
          rules.switchesOf('k-new'),
          mayExportScreenSpace(ref),
          mayAddScreenSpace(ref, watch: false),
        );
      });
      expect(r.$1, isFalse, reason: 'Connect hides it');
      expect(r.$2, isTrue);
      expect(r.$3, isFalse, reason: 'Use does not change it');
      expect(r.$4, hosts.switches, reason: 'not placed yet: where new items go');
      expect(r.$5, isFalse, reason: 'only an owner exports');
      expect(r.$6, isTrue);
    });

    testWidgets('an owner exports; an account that can add nowhere adds nothing', (tester) async {
      expect(await within(tester, const OrchardSpace(_orchard), AsyncData(orchard(role: FixedRoles.owner)),
          (ref) => mayExportScreenSpace(ref)), isTrue);
      expect(await within(tester, const OrchardSpace(_orchard), AsyncData(orchard(defaultCrate: null)),
          (ref) => mayAddScreenSpace(ref, watch: false)), isFalse);
    });

    testWidgets("no export: not even an owner's, and no private key leaves",
        (tester) async {
      const noExport = RecordRules(noExport: true);
      final owner = await within(tester, const OrchardSpace(_orchard),
          AsyncData(orchard(role: FixedRoles.owner, rules: noExport)), (ref) => (
                mayExportScreenSpace(ref),
                mayExportKeysScreenSpace(ref, watch: false),
                mayRevealKey(ref, 'k-use', watch: false),
              ));
      expect(owner, (false, false, true), reason: 'shown at Use still, but not exported');
      final member = await within(tester, const OrchardSpace(_orchard), AsyncData(orchard()),
          (ref) => (mayExportScreenSpace(ref), mayExportKeysScreenSpace(ref, watch: false)));
      expect(member, (false, true), reason: 'without the rule a key it may reveal may be exported');
    });

    testWidgets(
        'a Crate its own offline limit has closed on this device: its keys are not shown or changed, nothing is '
        "added to it, and nothing leaves in an export, an owner's included", (tester) async {
      // As the Orchard's summary gives a Crate that is closed here: no
      // switches, whatever the record gives the account in it.
      const closed = CrateSummary(id: _keysUse, name: _keysUse, level: 'use', offlineHours: 24, closedOffline: true);
      OrchardSummary withClosed({String? newItemsGoTo = _hostsEdit}) => OrchardSummary(
            id: _orchard,
            name: 'Acme',
            role: FixedRoles.owner,
            crates: [keys, closed, hosts],
            defaultCrateId: newItemsGoTo,
          );
      final r = await within(tester, const OrchardSpace(_orchard), AsyncData(withClosed()), (ref) => (
            mayRevealKey(ref, 'k-use', watch: false),
            mayChangeItem(ref, 'key', 'k-use', watch: false),
            mayChangeItem(ref, 'key', 'k-use', delete: true, watch: false),
            mayExportScreenSpace(ref),
            mayAddScreenSpace(ref, watch: false),
          ));
      expect(r.$1, isFalse, reason: 'not shown, copied or exported');
      expect((r.$2, r.$3), (false, false), reason: 'not changed, not deleted');
      expect(r.$4, isFalse, reason: "an export of the Orchard would carry what the closed Crate holds: not an owner's");
      expect(r.$5, isTrue, reason: 'new items go into a Crate that is open');
      // Where new items would go into the closed Crate, nothing is added.
      expect(
          await within(tester, const OrchardSpace(_orchard), AsyncData(withClosed(newItemsGoTo: _keysUse)),
              (ref) => mayAddScreenSpace(ref, watch: false)),
          isFalse);
      // The Crate beside it is as it was.
      expect(
          await within(tester, const OrchardSpace(_orchard), AsyncData(withClosed()),
              (ref) => ItemRules.of(ref, 'key', watch: false).switchesOf('k-connect')),
          keys.switches);
    });

    testWidgets("no export leaves your Tree's exports alone", (tester) async {
      final tree = await within(tester, const TreeSpace(), AsyncData(orchard(rules: const RecordRules(noExport: true))),
          (ref) => (mayExportScreenSpace(ref), mayExportKeysScreenSpace(ref, watch: false)));
      expect(tree, (true, true));
    });

    testWidgets('while the Orchard is still being read, nothing is allowed', (tester) async {
      final r = await within(tester, const OrchardSpace(_orchard), const AsyncLoading(), (ref) => (
            mayRevealKey(ref, 'k-use', watch: false),
            mayChangeItem(ref, 'host', 'h', watch: false),
            mayExportScreenSpace(ref),
            mayAddScreenSpace(ref, watch: false),
          ));
      expect(r, (false, false, false, false));
    });
  });
}
