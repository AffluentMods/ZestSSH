import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';

import 'fake_crate_server.dart';
import 'vaults_window_helper.dart';

/// A Crate's certificate authority on screen (3.0): an owner sets
/// it up from the Crates screen (the user names each role signs in as, how
/// long certificates last, its key in a new Crate only owners open), gets
/// the commands that make a host trust it, gives it a new key and turns it
/// off, each asked first; a member sees whether it is on and the names they
/// sign in as, and nothing to change; an owner is told when someone who
/// held its key no longer can. Every language fits.

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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late FakeCrateServer server;
  final storages = <_MemoryStorage>[];
  final keys = <String, AccountKeys>{};
  late OrchardService owner;
  late String orchardId;
  late String production;
  late String member;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    for (final s in storages) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    storages.clear();
  });

  OrchardService serviceFor(String uid) {
    final storage = _MemoryStorage();
    storages.add(storage);
    return OrchardService(
      server: server.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys[uid]!),
    );
  }

  /// The owner's Orchard: Production, the role Member (use of it), alice a
  /// Member; with [authority] Production's authority set up (members sign in
  /// as deploy, owners as root, its key in "Owner keys").
  Future<void> build(WidgetTester tester, {bool authority = false}) => tester.runAsync(() async {
        server = FakeCrateServer(accountUid: 'owner-1');
        for (final uid in ['owner-1', 'owner-2', 'alice']) {
          keys[uid] = await AccountKeys.generate();
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        owner = serviceFor('owner-1');
        orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        final first = server.recordOf(orchardId).roles.values.single;
        member = first.id;
        production = first.crates.keys.single;
        await owner.invite(orchardId, email: 'alice@example.com', role: member);
        server.acceptAs(orchardId, (await owner.invites(orchardId)).single.id, 'alice');
        await owner.confirmInvite(orchardId, (await owner.invites(orchardId)).single);
        if (authority) {
          final vault = await owner.createCrate(orchardId, 'Owner keys', ownersOnly: true);
          await owner.setAuthorityKey(orchardId, production,
              keyCrate: vault,
              ttlMinutes: 1440,
              principals: {
                member: ['deploy'],
                FixedRoles.owner: ['root'],
              },
              keyLabel: 'Production certificate authority');
        }
        await owner.refresh();
      });

  /// Pumps the Crates screen of [service]'s device, opened.
  Future<void> openCrates(WidgetTester tester, OrchardService service,
      {Locale locale = const Locale('en'), ThemeData? theme, Size size = const Size(1200, 1600)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(service),
        orchardSummariesProvider.overrideWith((ref) async {
          ref.watch(orchardListVersionProvider);
          return [await readOrchardSummary(await service.databases.open(orchardId), orchardId)];
        }),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Column(
              children: [
                TextButton(onPressed: () => showOrchardCrates(context, ref, orchardId), child: const Text('open')),
                Text('${ref.watch(orchardSummariesProvider).valueOrNull?.length}'),
              ],
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    // Production's Certificates (4.0: one vault at a time, under tabs).
    await openVaultTab(tester, production, VaultTab.certificates);
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  /// Taps [f] once it is scrolled into view (a vault's card is long).
  Future<void> tapIn(WidgetTester tester, Finder f) async {
    await showInVaults(tester, f);
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
  }

  testWidgets('an owner sets up certificates: names per role, how long, the key in a new owners-only Crate',
      (tester) async {
    await build(tester);
    await openCrates(tester, owner);
    expect(key('crate-certs-state-$production-off'), findsOneWidget);
    expect(find.text(l10n.crateCertsSetUp), findsOneWidget);
    await tapIn(tester, key('crate-certs-settings-$production'));
    await settle(tester);
    expect(find.text(l10n.certDialogTitle('Production')), findsOneWidget);
    expect(find.text(l10n.certKeyCrateNew), findsOneWidget, reason: 'no owners-only Crate yet: a new one');

    // Nothing typed: nothing sent.
    await tester.tap(key('cert-save'));
    await settle(tester);
    expect(find.text(l10n.certNamesNone), findsOneWidget);
    // A name no certificate can carry: nothing sent.
    await tester.enterText(key('cert-names-$member'), 'Deploy!');
    await tester.tap(key('cert-save'));
    await settle(tester);
    expect(find.text(l10n.certNamesInvalid), findsOneWidget);
    expect(server.recordOf(orchardId).crates[production]!.ca, isNull);

    // Where the life is chosen: what an outage of ZestSSH Cloud means for
    // members whose certificate ends meanwhile.
    expect(find.text(l10n.certLifetimeOutageNote), findsOneWidget);
    expect(l10n.certLifetimeOutageNote, contains('members cannot get a new certificate'));
    await tester.enterText(key('cert-names-$member'), 'deploy, www deploy');
    await tester.enterText(key('cert-names-owner'), 'root');
    await tester.tap(key('cert-ttl-480'));
    await tester.tap(key('cert-save'));
    await settle(tester);
    final ca = server.recordOf(orchardId).crates[production]!.ca!;
    expect(ca.on, isTrue);
    expect(ca.ttlMinutes, 480);
    expect(ca.principals, {
      FixedRoles.owner: ['root'],
      member: ['deploy', 'www'],
    });
    final vault = server.recordOf(orchardId).crates[ca.keyCrate]!;
    expect(vault.ownersOnly, isTrue);
    expect(await tester.runAsync(() => owner.authorityKey(orchardId, production)), isNotNull,
        reason: 'the key is kept in the new Crate');
    expect(key('cert-editor-state'), findsOneWidget);
    expect(find.text(l10n.crateCertsOn(l10n.certLifetime8h)), findsWidgets);
    await tester.pump(const Duration(seconds: 5)); // the toast times out
  });

  testWidgets("the host commands carry the authority's key, and copy", (tester) async {
    await build(tester, authority: true);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await openCrates(tester, owner);
    expect(key('crate-certs-state-$production-on'), findsOneWidget);
    await tapIn(tester, key('crate-certs-hosts-$production'));
    await settle(tester);
    final script = (tester.widget<SelectableText>(key('cert-host-script'))).data!;
    final ca = server.recordOf(orchardId).crates[production]!.ca!;
    expect(script, contains("KEY='ssh-ed25519 "));
    expect(script, contains('zestssh-ca-1'));
    expect(script, isNot(contains('OLD=')));
    expect(find.textContaining('SHA256:'), findsOneWidget);
    await tester.tap(key('cert-host-copy'));
    await settle(tester);
    expect(copied, script);
    expect(ca.generation, 1);
    await tester.pump(const Duration(seconds: 5)); // the toast times out
  });

  testWidgets('a new key and turning off each ask first; the commands then drop the old key', (tester) async {
    await build(tester, authority: true);
    await openCrates(tester, owner);
    await tapIn(tester, key('crate-certs-settings-$production'));
    await settle(tester);
    expect(tester.widget<TextField>(key('cert-names-$member')).controller!.text, 'deploy');

    await tester.tap(key('cert-new-key'));
    await settle(tester);
    expect(find.text(l10n.certNewKeyTitle), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).crates[production]!.ca!.generation, 1, reason: 'declined: nothing changes');
    await tester.tap(key('cert-new-key'));
    await settle(tester);
    await tester.tap(find.text(l10n.certNewKey).last);
    await settle(tester);
    expect(server.recordOf(orchardId).crates[production]!.ca!.generation, 2);

    await tester.tap(key('cert-turn-off'));
    await settle(tester);
    expect(find.text(l10n.certTurnOffTitle('Production')), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).crates[production]!.ca!.on, isTrue, reason: 'declined: still on');
    await tester.tap(key('cert-turn-off'));
    await settle(tester);
    await tester.tap(find.text(l10n.certTurnOff).last);
    await settle(tester);
    expect(server.recordOf(orchardId).crates[production]!.ca!.on, isFalse);
    expect(key('cert-turn-off'), findsNothing);
    expect(find.text(l10n.certTurnOn), findsOneWidget);
    // Back on: the same key, and the commands name it and drop the first.
    await tester.tap(key('cert-save'));
    await settle(tester);
    expect(server.recordOf(orchardId).crates[production]!.ca!.on, isTrue);
    // The window's X closes it (no Close button).
    await tester.tap(find.byTooltip(l10n.close).last);
    await settle(tester);
    await tapIn(tester, key('crate-certs-hosts-$production'));
    await settle(tester);
    final script = (tester.widget<SelectableText>(key('cert-host-script'))).data!;
    expect(script, contains('zestssh-ca-2'));
    expect(script, contains('OLD='));
    expect(find.text(l10n.certHostNotesNewKey), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // the toast times out
  });

  testWidgets('a member sees that it is on and the names they sign in as, and nothing to change', (tester) async {
    await build(tester, authority: true);
    final alice = serviceFor('alice');
    await tester.runAsync(alice.refresh);
    await openCrates(tester, alice);
    expect(key('crate-certs-state-$production-on'), findsOneWidget);
    expect(find.text(l10n.crateCertsYouSignInAs('deploy')), findsOneWidget);
    expect(key('crate-certs-settings-$production'), findsNothing);
    expect(key('crate-certs-hosts-$production'), findsNothing);
  });

  testWidgets('an owner who held its key stepping down: the owners are told a new key is needed', (tester) async {
    await build(tester, authority: true);
    await tester.runAsync(() async {
      await owner.invite(orchardId, email: 'owner-2@example.com', role: FixedRoles.owner);
      server.acceptAs(orchardId, (await owner.invites(orchardId)).single.id, 'owner-2');
      await owner.confirmInvite(orchardId, (await owner.invites(orchardId)).single);
      final owner2 = serviceFor('owner-2');
      await owner2.refresh();
      await owner2.stepDown(orchardId);
      await owner.refresh();
    });
    await openCrates(tester, owner);
    expect(key('crate-certs-new-key-needed-$production'), findsOneWidget);
    await tapIn(tester, key('crate-certs-hosts-$production'));
    await settle(tester);
    expect(find.text(l10n.certHostNewKeyFirst), findsOneWidget);
  });

  testWidgets('in every language, on a phone: the Crate row, the settings and the host commands, nothing clipped',
      (tester) async {
    await tester.runAsync(() async {
      final loader = FontLoader('GeistSans');
      for (final f in ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf']) {
        loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
      }
      await loader.load();
    });
    final theme = ThemeData(fontFamily: 'GeistSans');
    await build(tester, authority: true);
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      await openCrates(tester, owner, locale: locale, theme: theme, size: const Size(390, 844));
      expect(tester.takeException(), isNull, reason: '$locale: the Crates screen');
      await tester.ensureVisible(key('crate-certs-settings-$production'));
      await tester.pumpAndSettle();
      await tapIn(tester, key('crate-certs-settings-$production'));
      await settle(tester);
      await tester.ensureVisible(key('cert-new-key'));
      await tester.pumpAndSettle();
      expect(find.text(t.certNewKey), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale: the settings');
      await tester.tap(find.byTooltip(t.close).last);
      await settle(tester);
      await tester.ensureVisible(key('crate-certs-hosts-$production'));
      await tester.pumpAndSettle();
      await tapIn(tester, key('crate-certs-hosts-$production'));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: '$locale: the host commands');
    }
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
