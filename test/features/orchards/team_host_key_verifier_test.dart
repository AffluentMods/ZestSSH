import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/changed_host_keys_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../helpers/orchard_db_fixture.dart';

/// What a connect trusts in an Orchard with team-pinned host keys (3.0),
/// through the terminal's own host key verifier on a real Orchard
/// database: a pinned key is trusted with no prompt, on a device that never
/// saw the host; another key stops the connection, and only someone who may
/// edit the pin's Crate can replace it (for everyone); someone who may edit
/// the host's Crate trusts a new host's key for everyone when they trust it;
/// someone who may not is not offered that. The background monitor trusts
/// a pinned key and refuses any other there. A session opened by a run with
/// nobody there (automation, 3.0) trusts a pinned key or one this device
/// trusts, and is stopped by any other, nobody asked. A pin counts only for
/// the hosts of its own Crate: another Crate's pin of a host's address is
/// not the host's, and a jump host on the way goes by its own Crate's pin.

const _editCrate = kFixtureCrateId; // every switch
const _viewCrate = '77777777-7777-4777-8777-777777777777'; // connect only

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late ProviderContainer container;
  late ActiveSessionsNotifier sessions;
  // Why the last key that was checked was not accepted; null where it was.
  HostKeyNotAccepted? refused;

  SSHHostKey key(int seed) =>
      SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => (seed + i) & 0xff)));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(db);
    await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'View', 'connect', ?, 1)",
        [_viewCrate, jsonEncode(switchList(levelSwitches(CrateLevel.connect)))]);
    // Two hosts as the sync engine leaves them: one in each Crate.
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    final at = DateTime(2026, 9, 25);
    for (final (id, crate) in [('h-edit', _editCrate), ('h-view', _viewCrate)]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id, label: id, host: '$id.example.com', createdAt: at, updatedAt: at));
      await db.customStatement(
          "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', ?, ?, 1)", [id, crate]);
    }
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      sharedPreferencesProvider.overrideWithValue(prefs),
      askBeforeTrustingKeysProvider.overrideWith((ref) => true),
    ]);
    sessions = container.read(activeSessionsProvider.notifier);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// A pin as another device's sync leaves it, in [crate].
  Future<void> pinnedElsewhere(String host, SSHHostKey k, String crate) async {
    final id = teamHostKeyId(host, 22, null, crateId: crate);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.customStatement(
        "INSERT INTO team_host_keys (id, host, port, via_scope, host_keys) VALUES (?, ?, 22, '', ?)",
        [id, host, jsonEncode([hostKeyLine(k)])]);
    await db.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('hostkey', ?, ?, 1)",
        [id, crate]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
  }

  /// Runs [connectionId]'s verifier on [host] presenting [k], or on the
  /// jump host [through] on the way to it; each prompt it raises is handed to
  /// [answer] (true trusts), and collected.
  Future<(bool, List<HostKeyVerification>)> verify(String connectionId, String host, SSHHostKey k,
      {bool Function(HostKeyVerification v)? answer,
      bool unattended = false,
      ({String id, String host})? through}) async {
    final prompts = <HostKeyVerification>[];
    final queue = container.read(hostKeyVerificationQueueProvider.notifier);
    final sub = container.listen<List<HostKeyVerification>>(hostKeyVerificationQueueProvider, (_, next) {
      for (final v in next) {
        if (prompts.contains(v)) continue;
        prompts.add(v);
        scheduleMicrotask(() => queue.resolve(v, answer?.call(v) ?? false));
      }
    });
    try {
      final verifier = sessions.debugHostKeyVerifier(
          connectionId: connectionId, dialedHost: host, dialedPort: 22, unattended: unattended);
      // A key that is not accepted is not answered with a no: the check fails, saying why.
      refused = null;
      try {
        final hop = through;
        return (hop == null ? await verifier(host, 22, k) : await verifier(hop.host, 22, k, hostId: hop.id), prompts);
      } on HostKeyNotAccepted catch (e) {
        refused = e;
        return (false, prompts);
      }
    } finally {
      sub.close();
    }
  }

  Future<TeamHostKeyPin?> pinOf(String host, String crate) => TeamHostKeys(db).pinFor(host, 22, crateId: crate);

  /// The host [id] (at [id].example.com:22) as the background monitor checks it.
  TrustTarget target(String id) => (
        hostId: id,
        host: '$id.example.com',
        port: 22,
        viaScope: null,
        savedHost: '$id.example.com',
        savedPort: 22,
      );

  test('a pinned key is trusted with no prompt, on a device that never saw the host', () async {
    await pinnedElsewhere('h-view.example.com', key(1), _viewCrate);
    final (ok, prompts) = await verify('h-view', 'h-view.example.com', key(1));
    expect(ok, isTrue);
    expect(prompts, isEmpty);
    expect(await KnownHostsService(db.knownHostsDao).verify('h-view.example.com', 22, key(1)).then((o) => o.result),
        HostKeyVerifyResult.newHost, reason: 'nothing learned on this device: the pin decides');
  });

  test('another key: someone who may not edit the pin\'s Crate is stopped, even answering yes', () async {
    await pinnedElsewhere('h-view.example.com', key(1), _viewCrate);
    final (ok, prompts) = await verify('h-view', 'h-view.example.com', key(2), answer: (_) => true);
    expect(ok, isFalse);
    expect((refused!.why, refused!.crate, refused!.host, refused!.port),
        (HostKeyRefusal.pinnedOther, 'View', 'h-view.example.com', 22));
    final prompt = prompts.single;
    expect(prompt.isChanged, isTrue);
    expect(prompt.teamPin!.pinned, isTrue);
    expect(prompt.teamPin!.mayChange, isFalse);
    expect(prompt.teamPin!.crateName, 'View');
    expect(prompt.expectedFingerprint, isNotNull, reason: 'the pinned key is shown beside the one presented');
    expect((await pinOf('h-view.example.com', _viewCrate))!.matches(key(1)), isTrue, reason: 'the pin is unchanged');
  });

  test("another key: someone who may edit the pin's Crate replaces it for everyone, or not", () async {
    await pinnedElsewhere('h-edit.example.com', key(1), _editCrate);
    var (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(2), answer: (_) => false);
    expect(ok, isFalse);
    expect((refused!.why, refused!.host, refused!.port), (HostKeyRefusal.declinedChanged, 'h-edit.example.com', 22));
    expect(prompts.single.teamPin!.mayChange, isTrue);
    expect((await pinOf('h-edit.example.com', _editCrate))!.matches(key(1)), isTrue, reason: 'declined: nothing changes');

    (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(2), answer: (_) => true);
    expect(ok, isTrue);
    expect(refused, isNull);
    final pin = (await pinOf('h-edit.example.com', _editCrate))!;
    expect(pin.matches(key(2)), isTrue);
    expect(pin.matches(key(1)), isFalse, reason: 'replaced, not added');
    expect(pin.crateId, _editCrate);
  });

  test('a new host: someone who may edit its Crate trusts the key for everyone, unless they say not to', () async {
    var (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(3), answer: (v) {
      v.teamPin!.forEveryone = false;
      return true;
    });
    expect(ok, isTrue);
    expect(prompts.single.isChanged, isFalse);
    expect(prompts.single.teamPin!.mayChange, isTrue);
    expect(prompts.single.teamPin!.pinned, isFalse);
    expect(prompts.single.teamPin!.crateName, 'Fixture');
    expect(await pinOf('h-edit.example.com', _editCrate), isNull, reason: 'trusted here only');

    (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(4), answer: (_) => true);
    expect(ok, isTrue);
    final pin = (await pinOf('h-edit.example.com', _editCrate))!;
    expect(pin.matches(key(4)), isTrue);
    expect(pin.crateId, _editCrate);
  });

  test('a new host where this account may not edit: trusted here only, never offered for everyone', () async {
    final (ok, prompts) = await verify('h-view', 'h-view.example.com', key(5), answer: (_) => true);
    expect(ok, isTrue);
    expect(prompts.single.teamPin, isNull);
    expect(await pinOf('h-view.example.com', _viewCrate), isNull);
  });

  // A pin counted for every host at its address, whichever Crate it was in:
  // someone who may edit View could have a key of their choosing trusted for
  // a host of Fixture with no question, or stop that host's own key.
  test("another Crate's pin of a host's address is not the host's: its key is not trusted by itself there, nor does it "
      "stop the host's own, which is pinned in the host's Crate beside it", () async {
    await pinnedElsewhere('h-edit.example.com', key(1), _viewCrate);
    var (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(1), answer: (_) => false);
    expect(ok, isFalse, reason: "View's key, not trusted by itself for a host of Fixture");
    expect(prompts.single.isChanged, isFalse, reason: 'asked as a host this device has not seen');
    expect(refused!.why, HostKeyRefusal.declinedNew);

    (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(2), answer: (_) => true);
    expect((ok, refused), (true, null), reason: "View's pin does not stop it");
    expect(prompts.single.teamPin!.pinned, isFalse);
    expect(prompts.single.teamPin!.mayChange, isTrue);
    expect(prompts.single.teamPin!.crateName, 'Fixture');
    // Pinned for everyone in Fixture, beside View's, which is as it was.
    expect((await pinOf('h-edit.example.com', _editCrate))!.matches(key(2)), isTrue);
    expect((await pinOf('h-edit.example.com', _viewCrate))!.matches(key(1)), isTrue);
    expect((await pinOf('h-edit.example.com', _viewCrate))!.matches(key(2)), isFalse);

    // From then on Fixture's pin decides for h-edit: View's key is another key there.
    (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(1), answer: (_) => false);
    expect(ok, isFalse);
    expect(prompts.single.isChanged, isTrue);
    expect(prompts.single.teamPin!.pinned, isTrue);
    expect(prompts.single.teamPin!.crateName, 'Fixture');
    expect(refused!.why, HostKeyRefusal.declinedChanged);
  });

  test("a jump host on the way goes by its own Crate's pin, not by that of the host it leads to", () async {
    // h-view is the jump host on the way to h-edit. View pinned its address,
    // and so did Fixture, h-edit's Crate, with another key.
    await pinnedElsewhere('h-view.example.com', key(1), _viewCrate);
    await pinnedElsewhere('h-view.example.com', key(2), _editCrate);
    const jumpHost = (id: 'h-view', host: 'h-view.example.com');
    var (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(1), through: jumpHost);
    expect((ok, refused, prompts.length), (true, null, 0), reason: "View's pin, the jump host's own: nobody asked");

    (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(2), through: jumpHost, answer: (_) => true);
    expect(ok, isFalse, reason: "Fixture's key is another than the one the jump host's Crate pinned");
    expect((refused!.why, refused!.crate, refused!.host), (HostKeyRefusal.pinnedOther, 'View', 'h-view.example.com'));
    expect(prompts.single.teamPin!.crateName, 'View');
  });

  test('a key that its person does not accept says which it was: one this device had not seen, or another than the '
      'one it trusts', () async {
    final known = KnownHostsService(db.knownHostsDao);
    var (ok, prompts) = await verify('h-view', 'h-view.example.com', key(6), answer: (_) => false);
    expect(ok, isFalse);
    expect(prompts.single.isChanged, isFalse);
    expect((refused!.why, refused!.host, refused!.port, refused!.crate),
        (HostKeyRefusal.declinedNew, 'h-view.example.com', 22, null));
    expect((await known.verify('h-view.example.com', 22, key(6))).result, HostKeyVerifyResult.newHost,
        reason: 'not trusted');

    // Accepted once; then the host shows another.
    (ok, prompts) = await verify('h-view', 'h-view.example.com', key(6), answer: (_) => true);
    expect((ok, refused), (true, null));
    (ok, prompts) = await verify('h-view', 'h-view.example.com', key(7), answer: (_) => false);
    expect(ok, isFalse);
    expect(prompts.single.isChanged, isTrue);
    expect(refused!.why, HostKeyRefusal.declinedChanged);
    expect((await known.verify('h-view.example.com', 22, key(6))).result, HostKeyVerifyResult.trusted,
        reason: 'the key it trusted is still the one');
    // And accepted, it is the one from then on.
    (ok, prompts) = await verify('h-view', 'h-view.example.com', key(7), answer: (_) => true);
    expect((ok, refused), (true, null));
    expect((await known.verify('h-view.example.com', 22, key(7))).result, HostKeyVerifyResult.trusted);
  });

  test('a run with nobody there: a pinned key or a trusted one is taken; any other stops it, nobody asked',
      () async {
    final known = KnownHostsService(db.knownHostsDao);
    bool marked(String host) => container.read(changedHostKeysProvider.notifier).isChanged(host, 22);
    // A pinned key: taken, as it is for a person.
    await pinnedElsewhere('h-edit.example.com', key(1), _editCrate);
    var (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(1), unattended: true);
    expect((ok, refused, prompts.length), (true, null, 0));

    // Another key than the pin, where its person could replace the pin: stopped, its card marked, the pin kept.
    (ok, prompts) = await verify('h-edit', 'h-edit.example.com', key(2), answer: (_) => true, unattended: true);
    expect(ok, isFalse);
    expect(prompts, isEmpty);
    expect((refused!.why, refused!.host, refused!.port),
        (HostKeyRefusal.changedUnattended, 'h-edit.example.com', 22));
    expect(marked('h-edit.example.com'), isTrue);
    expect((await pinOf('h-edit.example.com', _editCrate))!.matches(key(1)), isTrue);
    expect((await pinOf('h-edit.example.com', _editCrate))!.matches(key(2)), isFalse);

    // A host this device has not seen, where "ask before trusting" is off: not trusted by itself, nobody asked.
    container.read(askBeforeTrustingKeysProvider.notifier).state = false;
    (ok, prompts) = await verify('h-view', 'h-view.example.com', key(6), answer: (_) => true, unattended: true);
    expect(ok, isFalse);
    expect(prompts, isEmpty);
    expect((refused!.why, refused!.host, refused!.port), (HostKeyRefusal.unknownUnattended, 'h-view.example.com', 22));
    expect((await known.verify('h-view.example.com', 22, key(6))).result, HostKeyVerifyResult.newHost);
    expect(marked('h-view.example.com'), isFalse, reason: 'nothing changed: the host is new');

    // Trusted here (by a person): taken. Then another key: stopped, its card marked, the trusted key kept.
    await known.trustHost('h-view.example.com', 22, key(6));
    (ok, prompts) = await verify('h-view', 'h-view.example.com', key(6), unattended: true);
    expect((ok, refused, prompts.length), (true, null, 0));
    (ok, prompts) = await verify('h-view', 'h-view.example.com', key(7), answer: (_) => true, unattended: true);
    expect(ok, isFalse);
    expect(prompts, isEmpty);
    expect(refused!.why, HostKeyRefusal.changedUnattended);
    expect(marked('h-view.example.com'), isTrue);
    expect((await known.verify('h-view.example.com', 22, key(6))).result, HostKeyVerifyResult.trusted);
    expect((await known.verify('h-view.example.com', 22, key(7))).result, HostKeyVerifyResult.changed);

    // What a session says of each, and that neither is taken for its person's own no.
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(hostKeyNotAcceptedText(l10n, refused!), l10n.automationSvcHostKeyChanged);
    expect(hostKeyNotAcceptedText(l10n, HostKeyNotAccepted(HostKeyRefusal.unknownUnattended, host: 'h', port: 22)),
        l10n.automationSvcHostKeyUnknown);
    expect(hostKeyDeclinedByItsPerson(refused!), isFalse);
    expect(hostKeyDeclinedByItsPerson(HostKeyNotAccepted(HostKeyRefusal.unknownUnattended, host: 'h', port: 22)),
        isFalse);
    expect(hostKeyDeclinedByItsPerson(HostKeyNotAccepted(HostKeyRefusal.declinedNew, host: 'h', port: 22)), isTrue);
  });

  test('the background monitor trusts a pinned key and refuses any other there', () async {
    await pinnedElsewhere('h-view.example.com', key(1), _viewCrate);
    final factory = container.read(sshConnectionFactoryProvider);
    final signal = HostKeyReviewSignal();
    final verifier = factory.buildTrustOnlyHostKeyVerifier(signal, target: target('h-view'));
    expect(await verifier('h-view.example.com', 22, key(1)), isTrue);
    expect(signal.needsReview, isFalse);
    expect(await verifier('h-view.example.com', 22, key(2)), isFalse);
    expect(signal.changed, isTrue);
  });

  test('the background monitor goes by the pins of the Crate of each host it checks a key for', () async {
    // View pinned the address of h-edit, a host of Fixture, and of h-view, a host of its own.
    await pinnedElsewhere('h-edit.example.com', key(1), _viewCrate);
    await pinnedElsewhere('h-view.example.com', key(3), _viewCrate);
    final factory = container.read(sshConnectionFactoryProvider);
    var signal = HostKeyReviewSignal();
    final verifier = factory.buildTrustOnlyHostKeyVerifier(signal, target: target('h-edit'));
    expect(await verifier('h-edit.example.com', 22, key(1)), isFalse, reason: "View's key is not h-edit's");
    expect([signal.needsReview, signal.changed], [true, false], reason: 'a host this device has not seen');

    // h-view, as the jump host on the way to h-edit: its own Crate's pin.
    final viaJumpHost = factory.buildTrustOnlyHostKeyVerifier(signal = HostKeyReviewSignal(), target: target('h-edit'));
    expect(await viaJumpHost('h-view.example.com', 22, key(3), hostId: 'h-view'), isTrue);
    expect(signal.needsReview, isFalse);
    expect(await viaJumpHost('h-view.example.com', 22, key(3)), isFalse,
        reason: "not named as the jump host: Fixture's pins, none of that address");

    // Fixture's own pin of h-edit decides there.
    await pinnedElsewhere('h-edit.example.com', key(2), _editCrate);
    final fixtures = factory.buildTrustOnlyHostKeyVerifier(signal = HostKeyReviewSignal(), target: target('h-edit'));
    expect(await fixtures('h-edit.example.com', 22, key(2)), isTrue);
    expect(signal.needsReview, isFalse);
    expect(await fixtures('h-edit.example.com', 22, key(1)), isFalse);
    expect(signal.changed, isTrue);
  });

  test('with "ask before trusting" off and a person there: a new host is trusted by itself, a changed key is still asked '
      'about', () async {
    final known = KnownHostsService(db.knownHostsDao);
    container.read(askBeforeTrustingKeysProvider.notifier).state = false;
    // New: trusted with no prompt.
    var (ok, prompts) = await verify('h-view', 'h-view.example.com', key(8));
    expect((ok, prompts.length), (true, 0));
    expect((await known.verify('h-view.example.com', 22, key(8))).result, HostKeyVerifyResult.trusted);
    // Another key than the one trusted: asked, whatever the setting; a no stops it and keeps the key trusted.
    (ok, prompts) = await verify('h-view', 'h-view.example.com', key(9), answer: (_) => false);
    expect(prompts, hasLength(1));
    expect(ok, isFalse);
    expect((await known.verify('h-view.example.com', 22, key(8))).result, HostKeyVerifyResult.trusted);
  });
}
