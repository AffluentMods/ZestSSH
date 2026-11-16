import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/linux_keyring.dart';
import 'package:zestssh/services/migration_backup_service.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/older_version_data.dart';
import 'package:zestssh/services/profiles/profile_boot.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_move.dart';
import 'package:zestssh/services/profiles/profile_vault.dart';
import 'package:zestssh/services/profiles/windows_keychain.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/ui/screens/error/database_error_screen.dart';
import 'package:zestssh/ui/screens/error/migration_error_screen.dart';
import 'package:zestssh/ui/screens/error/moving_data_screen.dart';
import 'package:zestssh/ui/screens/error/startup_error_screen.dart';
import 'package:zestssh/ui/screens/profile/widgets/older_version_data_dialog.dart';
import 'package:zestssh/ui/windows/secondary_window_app.dart';

import 'profile_world.dart';

/// What a second look at profiles found: where a set aside stopped short, what was set
/// aside when nothing had moved, what read as empty, and how a person gets it back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uid = 'account-alice';
  final onWindows = Platform.isWindows ? false : 'a file held open stops a rename on Windows alone';

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  File marker() => File(p.join(ProfilePaths.root(world.base).path, 'move_v1.json'));

  Future<void> oldDevice({bool signedIn = true}) async {
    await makeOldDatabase(world, wal: 'host-in-wal');
    world.device.kept.addAll({
      KeychainNames.databaseKey: kOldKey,
      if (signedIn) ...{
        'session_token': 'made.up.token',
        'session_uid': uid,
        'session_email': 'alice@example.com',
      },
      'identity_key_k1': 'PRIVATE KEY OF K1',
    });
    await world.rawPrefs.setString('terminal_theme', 'dracula');
  }

  /// A first start as far as it goes without the database: the move is at keysNamed,
  /// and its profile has not opened.
  Future<(ProfileManager, String)> movedAsFarAsItGoes() async {
    final manager = world.launch();
    await manager.start();
    return (manager, manager.list.current!);
  }

  Future<void> expectMovedAndWhole(ProfileManager manager, String id) async {
    final db = await manager.openCurrent();
    SecretSeal.openTree = db;
    expect(manager.currentEntry!.id, id);
    expect(await hostsOf(db), ['host-in-main', 'host-in-wal']);
    expect(await world.keychainOf(Profiles.current!, db).read(key: 'identity_key_k1'), 'PRIVATE KEY OF K1');
    expect(manager.prefs.getString('terminal_theme'), 'dracula');
    expect(marker().existsSync(), isFalse, reason: 'the move is done');
    expect(world.device.kept.containsKey('identity_key_k1'), isFalse, reason: 'its originals went at its end');
    await db.close();
    SecretSeal.openTree = null;
  }

  group('F1: a set aside that stopped before its end', () {
    test('the marker stayed behind: the next start moves it with the data, and the guest takes nothing', () async {
      await oldDevice();
      final (manager, id) = await movedAsFarAsItGoes();
      final text = marker().readAsStringSync();
      await manager.setAsideCurrent();
      expect(marker().existsSync(), isFalse);
      // As if its last step, the marker's rename, did not happen: a stop, or a held file.
      marker().writeAsStringSync(text);
      Profiles.debugReset();

      final again = world.launch();
      expect(await again.moveNeeded(), isFalse, reason: 'nothing to say a move is under way');
      await again.start();
      final guest = await again.openCurrent();
      expect(marker().existsSync(), isFalse);
      final aside = await ProfileMove(base: world.base, device: world.device, rawPrefs: world.rawPrefs, folders: () => world.folders).asideFolderOf(id);
      expect(File(p.join(aside!.path, 'move_v1.json')).existsSync(), isTrue, reason: 'it went with the data');
      expect(world.device.kept['identity_key_k1'], 'PRIVATE KEY OF K1', reason: 'the original is where it was');
      expect(world.device.kept.containsKey(KeychainNames.full(id, uid, 'identity_key_k1')), isFalse, reason: 'nothing sealed with the guest\'s seal');
      expect(again.prefs.getString('terminal_theme'), isNot('dracula'), reason: 'the person\'s settings did not go to the guest');
      expect(world.rawPrefs.getString('terminal_theme'), 'dracula');
      await guest.close();
    });

    test('a database that is not the marker\'s never runs the move', () async {
      await oldDevice();
      final (first, id) = await movedAsFarAsItGoes();
      // Open another profile, as the error screen offers: the marker is still there.
      await first.list.write(world.device);
      final list = first.list;
      final guest = ProfileEntry(id: newProfileId(), made: 1);
      list.put(guest);
      list.current = guest.id;
      await list.write(world.device);
      Profiles.debugReset();

      final next = world.launch();
      await next.start();
      next.list.current = guest.id;
      final db = await next.openCurrent();
      expect(next.currentEntry!.id, guest.id);
      expect(marker().existsSync(), isTrue, reason: 'it waits for its own');
      expect(world.device.kept['identity_key_k1'], 'PRIVATE KEY OF K1');
      expect(world.device.kept.containsKey(KeychainNames.full(id, uid, 'identity_key_k1')), isFalse);
      expect(next.prefs.getString('terminal_theme'), isNot('dracula'));
      await db.close();
    });

    for (final boundary in ['setAside:listed', 'setAside:folder']) {
      test('stopped at $boundary: the next start finishes it, and nothing is lost', () async {
        await oldDevice();
        final (manager, id) = await movedAsFarAsItGoes();
        world.stop = (at) {
          if (at == boundary) throw const PlayedStop('here');
        };
        expect(await untilStopped(manager.setAsideCurrent), isTrue);
        world.stop = null;
        Profiles.debugReset();

        final next = world.launch();
        await next.start();
        expect(next.list.byId(id)!.state, ProfileState.setAside);
        expect(ProfilePaths.ofProfile(world.base, id).existsSync(), isFalse);
        expect(marker().existsSync(), isFalse);
        final db = await next.openCurrent();
        expect(await hostsOf(db), isEmpty);
        expect(next.currentEntry!.id, isNot(id));
        expect(world.device.kept['identity_key_k1'], 'PRIVATE KEY OF K1');
        await db.close();
        SecretSeal.openTree = null;
        Profiles.debugReset();

        // And it comes back whole.
        final back = world.launch();
        back.list.entries.clear();
        await back.start();
        await back.askPutBack();
        Profiles.debugReset();
        final last = world.launch();
        await last.start();
        await expectMovedAndWhole(last, id);
      });
    }

    test('with no move under way too: a profile that does not open, stopped after the list said so', () async {
      final first = world.launch();
      await first.start();
      final made = await first.openCurrent();
      await addHost(made, 'guest-host');
      await made.close();
      final id = first.currentEntry!.id;
      world.stop = (at) {
        if (at == 'setAside:listed') throw const PlayedStop('here');
      };
      expect(await untilStopped(first.setAsideCurrent), isTrue);
      world.stop = null;
      Profiles.debugReset();

      final next = world.launch();
      await next.start();
      expect(next.list.byId(id)!.state, ProfileState.setAside);
      expect(ProfilePaths.ofProfile(world.base, id).existsSync(), isFalse);
      final fresh = await next.openCurrent();
      expect(await hostsOf(fresh), isEmpty);
      expect(next.currentEntry!.id, isNot(id));
      await fresh.close();
      Profiles.debugReset();

      final back = world.launch();
      await back.start();
      await back.askPutBack();
      Profiles.debugReset();
      final last = world.launch();
      await last.start();
      expect(last.currentEntry!.id, id);
      final again = await last.openCurrent();
      expect(await hostsOf(again), ['guest-host']);
      await again.close();
    });

    test('a folder that will not go: nothing is set aside, it says so, and it can be tried again', () async {
      await oldDevice();
      final (manager, id) = await movedAsFarAsItGoes();
      final held = await File(p.join(ProfilePaths.ofProfile(world.base, id).path, 'zestssh.db')).open(mode: FileMode.append);
      await expectLater(manager.setAsideCurrent(), throwsA(isA<FileSystemException>()));
      expect((await ProfileList.read(world.device))!.byId(id)!.state, ProfileState.open);
      expect((await ProfileList.read(world.device))!.current, id);
      expect(marker().existsSync(), isTrue);
      await held.close();
      await manager.setAsideCurrent();
      expect((await ProfileList.read(world.device))!.byId(id)!.state, ProfileState.setAside);
      expect(marker().existsSync(), isFalse);
    }, skip: onWindows);
  });

  group('F2: set aside is offered once there is something to set aside', () {
    for (final (boundary, offered) in [('started', false), ('copied', false), ('filesMoved', true), ('keysNamed', true)]) {
      test('a move stopped at $boundary: ${offered ? 'it can be set aside' : 'nothing has moved, and Try again is all'}', () async {
        await oldDevice();
        world.stop = (at) {
          if (at == boundary) throw const PlayedStop('here');
        };
        final manager = world.launch();
        await untilStopped(() async {
          await manager.start();
        });
        world.stop = null;
        expect(await manager.moveCanBeSetAside(), offered);
        final way = await startWayOut(const ProfileMoveFailed('before opening', 'file error 32'), retry: () {});
        expect(way != null, offered);
      });
    }

    test('whoever asks, a move that has moved nothing is not set aside: it goes on at the next start', () async {
      await oldDevice();
      world.stop = (at) {
        if (at == 'started') throw const PlayedStop('here');
      };
      final manager = world.launch();
      await untilStopped(() async {
        await manager.start();
      });
      world.stop = null;
      await manager.setAsideCurrent();
      Profiles.debugReset();

      final next = world.launch();
      expect(await next.moveNeeded(), isTrue);
      final start = await next.start();
      expect(start.olderVersionData, isFalse, reason: 'it is no older version\'s');
      final id = next.list.current!;
      await expectMovedAndWhole(next, id);
    });

    test('no marker at all, as for the wait for Firebase and the lock: Try again is all', () async {
      await oldDevice();
      final manager = world.launch();
      expect(await manager.moveCanBeSetAside(), isFalse);
      expect(await startWayOut(const ProfileMoveFailed('firebase', 'no word'), retry: () {}), isNull);
      expect(await startWayOut(const ProfileMoveFailed('lock', 'another process'), retry: () {}), isNull);
    });

    test('what is no move has no way out here, and a keychain file that does not open has its own', () async {
      world.launch();
      expect(await startWayOut(StateError('x'), retry: () {}), isNull);
      expect(await startWayOut(const KeychainFileFailed('read', 32), retry: () {}), isNull);
      expect(await startWayOut(const KeychainFileFailed('does-not-open'), retry: () {}), isNotNull);
    });

    test('the keychain\'s way out, on the start\'s own screen, says what it is', () async {
      Future<void> set() async {}
      final app = await startupErrorAppFor(const KeychainFileFailed('does-not-open'), StackTrace.empty, onRetry: () {}, onSetAside: set);
      expect(app.keychainDoesNotOpen, isTrue);
      final other = await startupErrorAppFor(const ProfileMoveFailed('keys', 'read back'), StackTrace.empty, onRetry: () {}, onSetAside: set);
      expect(other.keychainDoesNotOpen, isFalse);
      expect(other.onSetAside, isNotNull);
    });

    group('what an older version left, and this version cannot read', () {
      test('behind the app lock: said as that', () async {
        await File(p.join(world.base.path, 'zestssh.db')).writeAsString('its database');
        world.device.kept[KeychainNames.wrappedDatabaseKey] = 'wrapped';
        final older = OlderVersionData(base: world.base, device: world.device, rawPrefs: world.rawPrefs, openDatabase: openPlayed);
        final summary = await older.look();
        expect(summary.opened, isFalse);
        expect(summary.locked, isTrue);
        final l10n = lookupAppLocalizations(const Locale('en'));
        expect(olderDataWords(l10n, summary), l10n.olderDataLocked);
      });

      test('with no key of any kind: unreadable, and not said to be locked', () async {
        await File(p.join(world.base.path, 'zestssh.db')).writeAsString('its database');
        final older = OlderVersionData(base: world.base, device: world.device, rawPrefs: world.rawPrefs, openDatabase: openPlayed);
        final summary = await older.look();
        expect(summary.opened, isFalse);
        expect(summary.locked, isFalse);
        final l10n = lookupAppLocalizations(const Locale('en'));
        expect(olderDataWords(l10n, summary), l10n.olderDataUnreadable);
      });

      Future<(BuildContext, WidgetRef)> host(WidgetTester tester) async {
        SharedPreferences.setMockInitialValues({});
        late BuildContext context;
        late WidgetRef ref;
        final prefs = await tester.runAsync(SharedPreferences.getInstance);
        await tester.pumpWidget(ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs!)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(body: Consumer(builder: (c, r, _) {
              context = c;
              ref = r;
              return const SizedBox();
            })),
          ),
        ));
        return (context, ref);
      }

      testWidgets('its question: leaving it is the first answer, and deleting it says what goes', (tester) async {
        final l10n = lookupAppLocalizations(const Locale('en'));
        final (context, ref) = await host(tester);
        final older = _Older(world);
        const summary = OlderVersionSummary(hosts: 0, keys: 0, opened: false, locked: true);

        unawaited(showOlderVersionData(context, ref, older, summary));
        await tester.pumpAndSettle();
        expect(find.text(l10n.olderDataLocked), findsOneWidget);
        expect(find.text(l10n.olderDataBring), findsNothing);
        await tester.tap(find.text(l10n.olderDataLeave));
        await tester.pumpAndSettle();
        expect(older.deleted, 0, reason: 'left as it is');

        unawaited(showOlderVersionData(context, ref, older, summary));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.olderDataDeleteInstead));
        await tester.pumpAndSettle();
        expect(find.text(l10n.olderDataDeleteUnreadBody), findsOneWidget);
        expect(find.text(l10n.olderDataDeleteBody), findsNothing, reason: 'not in words about what an older version left');
        expect(older.deleted, 0, reason: 'not before it is said');
        await tester.tap(find.text(l10n.delete));
        await tester.pumpAndSettle();
        expect(older.deleted, 1);
      });

      testWidgets('closing either question is no answer: nothing goes on to deleting it', (tester) async {
        final l10n = lookupAppLocalizations(const Locale('en'));
        final (context, ref) = await host(tester);
        final older = _Older(world);
        for (final summary in const [
          OlderVersionSummary(hosts: 0, keys: 0, opened: false, locked: true),
          OlderVersionSummary(hosts: 3, keys: 1, opened: true),
        ]) {
          unawaited(showOlderVersionData(context, ref, older, summary));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip(l10n.close));
          await tester.pumpAndSettle();
          expect(find.text(l10n.olderDataDeleteInstead), findsNothing);
          expect(find.text(l10n.delete), findsNothing, reason: 'the cross is not Delete it');
          expect(older.deleted, 0);
        }
      });

      testWidgets('what can be read keeps its own question', (tester) async {
        final l10n = lookupAppLocalizations(const Locale('en'));
        final (context, ref) = await host(tester);
        unawaited(showOlderVersionData(context, ref, _Older(world), const OlderVersionSummary(hosts: 3, keys: 1, opened: true)));
        await tester.pumpAndSettle();
        expect(find.text(l10n.olderDataBring), findsOneWidget);
        expect(find.text(l10n.olderDataLeave), findsNothing);
      });
    });
  });

  group('F4: put back', () {
    test('a move set aside midway comes back and finishes: its key, its host, its settings', () async {
      await oldDevice();
      final (manager, id) = await movedAsFarAsItGoes();
      await manager.setAsideCurrent();
      Profiles.debugReset();

      final fresh = world.launch();
      await fresh.start();
      final guest = await fresh.openCurrent();
      expect(await fresh.setAsideHere(), isTrue);
      expect((await fresh.newestSetAside())!.id, id);
      final guestId = fresh.currentEntry!.id;
      await addHost(guest, 'made-in-between');
      await fresh.askPutBack();
      await guest.close();
      Profiles.debugReset();

      final next = world.launch();
      final start = await next.start();
      expect(start.putBackFailed, isFalse);
      await expectMovedAndWhole(next, id);
      // An account's data is in nobody's way: what was made as guest data stays that.
      expect(await next.setAsideHere(), isFalse);
      expect(next.list.guest!.id, guestId);
    });

    test('guest data that came back: what stood in its place is set aside in turn, and can come back the same way', () async {
      await oldDevice(signedIn: false);
      final (manager, id) = await movedAsFarAsItGoes();
      await manager.setAsideCurrent();
      Profiles.debugReset();
      final fresh = world.launch();
      await fresh.start();
      final guest = await fresh.openCurrent();
      final guestId = fresh.currentEntry!.id;
      await addHost(guest, 'made-in-between');
      await fresh.askPutBack();
      await guest.close();
      Profiles.debugReset();

      final next = world.launch();
      await next.start();
      await expectMovedAndWhole(next, id);
      // There is one guest profile, and what stood there is whole in its folder.
      expect(next.list.guest!.id, id);
      expect((await next.newestSetAside())!.id, guestId);
      final folder = ProfilePaths.setAside(world.base).listSync().whereType<Directory>().single;
      expect(hostsInFile(p.join(folder.path, 'zestssh.db')), ['made-in-between']);
      Profiles.debugReset();

      final third = world.launch();
      await third.start();
      await third.askPutBack();
      Profiles.debugReset();

      final fourth = world.launch();
      await fourth.start();
      expect(fourth.currentEntry!.id, guestId);
      final db = await fourth.openCurrent();
      expect(await hostsOf(db), ['made-in-between']);
      await db.close();
    });

    test('an account signed in afresh meanwhile: its new profile goes aside, and there is one profile for it', () async {
      await oldDevice();
      final (manager, id) = await movedAsFarAsItGoes();
      await manager.setAsideCurrent();
      Profiles.debugReset();
      final fresh = world.launch();
      await fresh.start();
      final guest = await fresh.openCurrent();
      final prepared = await fresh.prepare(await fresh.planForAccount(uid: uid, label: 'a@example.com', bearer: 'b'));
      await guest.close();
      await fresh.commit(prepared);
      final newOne = fresh.currentEntry!.id;
      expect(newOne, isNot(id));
      await fresh.askPutBack();
      await prepared.db.close();
      Profiles.debugReset();

      final next = world.launch();
      await next.start();
      expect(next.list.byUid(uid)!.id, id);
      expect(next.list.byId(newOne)!.state, ProfileState.setAside);
      await expectMovedAndWhole(next, id);
    });

    for (final boundary in ['putBack:folder', 'putBack:listed']) {
      test('stopped at $boundary: the next start goes on from there', () async {
        await oldDevice();
        final (manager, id) = await movedAsFarAsItGoes();
        await manager.setAsideCurrent();
        Profiles.debugReset();
        final fresh = world.launch();
        await fresh.start();
        final guest = await fresh.openCurrent();
        await fresh.askPutBack();
        await guest.close();
        Profiles.debugReset();

        world.stop = (at) {
          if (at == boundary) throw const PlayedStop('here');
        };
        final stopped = world.launch();
        expect(await untilStopped(() async {
          await stopped.start();
        }), isTrue);
        world.stop = null;
        Profiles.debugReset();

        final next = world.launch();
        await next.start();
        await expectMovedAndWhole(next, id);
      });
    }

    test('a folder that will not go back: it stays set aside, and that is said', () async {
      await oldDevice();
      final (manager, id) = await movedAsFarAsItGoes();
      await manager.setAsideCurrent();
      Profiles.debugReset();
      final fresh = world.launch();
      await fresh.start();
      final guest = await fresh.openCurrent();
      await fresh.askPutBack();
      await guest.close();
      Profiles.debugReset();
      final aside = ProfilePaths.setAside(world.base).listSync().whereType<Directory>().single;
      final held = await File(p.join(aside.path, 'zestssh.db')).open(mode: FileMode.append);
      addTearDown(held.close);

      final next = world.launch();
      final start = await next.start();
      expect(start.putBackFailed, isTrue);
      expect(next.list.byId(id)!.state, ProfileState.setAside);
      final opened = await next.openCurrent();
      expect(next.currentEntry!.id, isNot(id));
      await opened.close();
    }, skip: onWindows);

    test('the app\'s side: it asks, and then closes', () async {
      await oldDevice();
      final (manager, _) = await movedAsFarAsItGoes();
      await manager.setAsideCurrent();
      Profiles.debugReset();
      final fresh = world.launch();
      await fresh.start();
      final guest = await fresh.openCurrent();
      final c = ProviderContainer(overrides: [secureStorageProvider.overrideWithValue(ProfileKeychain(world.device))]);
      addTearDown(c.dispose);
      var closed = 0;
      final profiles = c.read(profileControllerProvider)..onQuit = () => closed++;
      await profiles.askPutBack();
      expect(closed, 1);
      expect(File(p.join(ProfilePaths.root(world.base).path, 'put_back_v1')).existsSync(), isTrue);
      await guest.close();
    });

    testWidgets('the notice\'s question: put it back, or go on to delete it', (tester) async {
      final l10n = lookupAppLocalizations(const Locale('en'));
      final profiles = _Profiles();
      late BuildContext context;
      late WidgetRef ref;
      SharedPreferences.setMockInitialValues({});
      final prefs = await tester.runAsync(SharedPreferences.getInstance);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs!),
          profileControllerProvider.overrideWithValue(profiles),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: Consumer(builder: (c, r, _) {
            context = c;
            ref = r;
            return const SizedBox();
          })),
        ),
      ));
      // Closing it is no answer: it does not go on to deleting.
      unawaited(showSetAsideData(context, ref));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.close));
      await tester.pumpAndSettle();
      expect(find.text(l10n.profileSetAsideDeleteBody), findsNothing);
      expect(profiles.deleted, 0);

      unawaited(showSetAsideData(context, ref));
      await tester.pumpAndSettle();
      expect(find.text(l10n.profileSetAsideQuestion), findsOneWidget);
      await tester.tap(find.text(l10n.profileSetAsidePutBack));
      await tester.pumpAndSettle();
      expect(profiles.putBack, 1);

      unawaited(showSetAsideData(context, ref));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.olderDataDeleteInstead));
      await tester.pumpAndSettle();
      expect(find.text(l10n.profileSetAsideDeleteBody), findsOneWidget);
      expect(profiles.deleted, 0, reason: 'not before it is said');
      await tester.tap(find.text(l10n.delete));
      await tester.pumpAndSettle();
      expect(profiles.deleted, 1);
    });

    test('deleting it: the newest only, and what a move set aside midway had yet to delete', () async {
      await oldDevice();
      final (manager, id) = await movedAsFarAsItGoes();
      await manager.setAsideCurrent();
      Profiles.debugReset();
      final fresh = world.launch();
      await fresh.start();
      final guest = await fresh.openCurrent();
      expect(world.device.kept['identity_key_k1'], 'PRIVATE KEY OF K1');
      expect(world.rawPrefs.getString('terminal_theme'), 'dracula');
      await fresh.deleteSetAside();
      expect(await fresh.setAsideHere(), isFalse);
      expect(fresh.list.byId(id), isNull);
      expect(world.rawNames(id), isEmpty);
      expect(world.device.kept.containsKey('identity_key_k1'), isFalse, reason: 'it says it is deleted from this computer');
      expect(world.device.kept.containsKey(KeychainNames.databaseKey), isFalse);
      expect(world.rawPrefs.getString('terminal_theme'), isNull);
      // Nothing of what is open.
      expect(world.rawNames(fresh.currentEntry!.id), isNotEmpty);
      await guest.close();
    });

    test('where an older version made a database since, the old names are its own, and stay', () async {
      await oldDevice();
      final (manager, _) = await movedAsFarAsItGoes();
      await manager.setAsideCurrent();
      Profiles.debugReset();
      final fresh = world.launch();
      await fresh.start();
      final guest = await fresh.openCurrent();
      await File(p.join(world.base.path, 'zestssh.db')).writeAsString('an older version\'s');
      await fresh.deleteSetAside();
      expect(world.device.kept['identity_key_k1'], 'PRIVATE KEY OF K1');
      await guest.close();
    });

    test('what an older version left goes, and the old names stay for a move set aside midway: it comes back whole', () async {
      await oldDevice();
      final (manager, id) = await movedAsFarAsItGoes();
      await manager.setAsideCurrent();
      Profiles.debugReset();
      final fresh = world.launch();
      await fresh.start();
      await (await fresh.openCurrent()).close();
      await File(p.join(world.base.path, 'zestssh.db')).writeAsString('an older version\'s');
      await OlderVersionData(base: world.base, device: world.device, rawPrefs: world.rawPrefs, openDatabase: openPlayed).delete();
      expect(File(p.join(world.base.path, 'zestssh.db')).existsSync(), isFalse);
      expect(world.device.kept['identity_key_k1'], 'PRIVATE KEY OF K1');
      expect(world.rawPrefs.getString('terminal_theme'), 'dracula');
      await fresh.askPutBack();
      Profiles.debugReset();
      final back = world.launch();
      await back.start();
      await expectMovedAndWhole(back, id);
    });

    group('only what will not pass by itself is offered', () {
      for (final (error, mayPass) in [
        (const FileSystemException('held'), true),
        (const KeychainFileFailed('busy'), true),
        (PlatformException(code: 'Libsecret error'), true),
        (TimeoutException('slow'), true),
        (const VaultLockedException('unlock first'), true),
        (StateError('SqliteException(5): database is locked'), true),
        (StateError('SqliteException(13): database or disk is full'), true),
        (StateError('SqliteException(14): unable to open database file'), true),
        (StateError('SqliteException(10): disk I/O error'), true),
        (StateError('SqliteException(26): file is not a database'), false),
        (StateError('SqliteException(11): database disk image is malformed'), false),
        (StateError('Encryption key not found in secure storage, but database file already exists.'), false),
        (StateError('SqliteException(1): no such column: x'), false),
      ]) {
        test('$error', () => expect(failureMayPass(error), mayPass));
      }

      test('main asks before each screen offers it', () {
        final main = File('lib/main.dart').readAsStringSync();
        // (Data from a newer ZestSSH is never set aside either: dataStaysAsItIs,
        // as a review found.)
        expect(RegExp(r'(failureMayPass|dataStaysAsItIs)\(e\) \? null : _setAsideAndStart\(\)').allMatches(main),
            hasLength(3));
      });
    });
  });

  group('F7: the copy from before is there for the profile a sign-in opens, and never after', () {
    test('a sign-in whose database fails its upgrade: it is put back as it was, and the next one opens it', () async {
      final first = world.launch();
      await first.start();
      final guest = await first.openCurrent();
      final prepared = await first.prepare(await first.planForAccount(uid: uid, label: 'a@example.com', bearer: 'b'));
      await guest.close();
      await first.commit(prepared);
      SecretSeal.openTree = prepared.db;
      expect(await first.settleLockedCopy(db: prepared.db, bearer: 'b'), isTrue);
      await addHost(prepared.db, 'alice-host');
      final id = first.currentEntry!.id;
      expect(await first.lockCurrent(), SignOutEnd.locked);
      final guest2 = await first.openGuest();
      await prepared.db.close();
      await guest2.close();
      SecretSeal.openTree = null;
      Profiles.debugReset();

      // A later release: its upgrade fails halfway, once.
      var failing = true;
      world.openDatabase = (dir, hex) async {
        if (failing && dir.path.contains(id)) {
          await File(p.join(dir.path, 'zestssh.db')).writeAsBytes(const [1, 2, 3], flush: true);
          throw StateError('no such table: the_new_one');
        }
        return openPlayed(dir, hex);
      };
      final later = world.launch();
      await later.start();
      final onScreen = await later.openCurrent();
      await expectLater(
        () async => later.prepare(await later.planForAccount(uid: uid, label: 'a@example.com', bearer: 'b')),
        throwsA(isA<ProfileCannotOpen>().having((e) => e.code, 'code', 'profile-not-opened')),
      );
      expect(later.currentEntry!.id, isNot(id), reason: 'it stays where it is');

      failing = false;
      final again = await later.prepare(await later.planForAccount(uid: uid, label: 'a@example.com', bearer: 'b'));
      expect(await hostsOf(again.db), ['alice-host']);
      await again.db.close();
      await onScreen.close();
    });

    test('a database that passed its upgrade in this run: what fails at a later open goes back to no copy', () async {
      var failing = false;
      world.openDatabase = (dir, hex) async {
        if (failing) throw StateError('SqliteException(5): database is locked, SQL');
        return openPlayed(dir, hex);
      };
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      await db.close();
      final copy = await MigrationBackupService.createPreMigrationBackup(fromVersion: 0, toVersion: 0);
      failing = true;
      await expectLater(manager.openCurrent(), throwsStateError);
      await expectLater(MigrationBackupService.restoreFromBackup(copy), throwsStateError);
      expect(await MigrationBackupService.restoreHeld!(), isTrue);
    });

    test('before it has passed in this run, a failed upgrade is put back as ever', () async {
      final first = world.launch();
      await first.start();
      final db = await first.openCurrent();
      await db.close();
      Profiles.debugReset();
      final later = world.launch();
      await later.start();
      final copy = await MigrationBackupService.createPreMigrationBackup(fromVersion: 0, toVersion: 0);
      await MigrationBackupService.restoreFromBackup(copy);
    });

    group('with no profiles too, as on a phone', () {
      late File main;
      late DatabaseSessionNotifier session;
      final garbage = List<int>.filled(4096, 7);
      var failing = false;

      setUp(() async {
        // An upgrade that fails, with nothing left holding the file: the suite's own
        // open would refuse before it is tried.
        failing = false;
        DatabaseSessionNotifier.debugOpen = (hex) async => failing
            ? AppDatabase.forTesting(NativeDatabase.memory(setup: (_) => throw StateError('no such table: the_new_one')))
            : openPlayed(world.base, hex);
        addTearDown(() => DatabaseSessionNotifier.debugOpen = null);
        final db = await openPlayed(world.base, 'aa');
        await addHost(db, 'made-before-the-copy');
        await db.close();
        await MigrationBackupService.createPreMigrationBackup(fromVersion: 0, toVersion: 0);
        main = File(p.join(world.base.path, 'zestssh.db'));
        final c = ProviderContainer();
        addTearDown(c.dispose);
        session = c.read(databaseSessionProvider.notifier);
      });

      test('a later unlock that fails restores nothing', () async {
        await session.open('aa');
        await session.close();
        await main.writeAsBytes(garbage, flush: true);
        failing = true;
        await expectLater(session.open('aa'), throwsStateError);
        expect(await main.readAsBytes(), garbage, reason: 'the copy from the start of the run would lose all that was done since');
      });

      test('the first open of a run that fails its upgrade is put back as ever', () async {
        await main.writeAsBytes(garbage, flush: true);
        failing = true;
        await expectLater(session.open('aa'), throwsStateError);
        final back = await openPlayed(world.base, 'aa');
        expect(await hostsOf(back), ['made-before-the-copy']);
        await back.close();
      });
    });
  });

  group('F8: a computer in a language the app does not have', () {
    Future<void> expectEnglish(WidgetTester tester, Widget app) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.localesTestValue = const [Locale('nl', 'NL')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.pumpWidget(app);
      await tester.pump();
      final context = tester.element(find.byType(Scaffold).first);
      expect(AppLocalizations.of(context)!.localeName, 'en');
      expect(Directionality.of(context), TextDirection.ltr);
    }

    testWidgets('the moving screen', (tester) => expectEnglish(tester, const MovingDataApp()));
    testWidgets('a language chosen that it does not have', (tester) => expectEnglish(tester, const MovingDataApp(language: 'pl')));
    testWidgets('the database\'s', (tester) => expectEnglish(tester, DatabaseErrorApp(report: 'r', onRetry: () {}, onReset: null)));
    testWidgets('an update\'s', (tester) => expectEnglish(tester, MigrationErrorApp(report: 'r', backupRestored: false, onContinue: () {})));
    testWidgets('the start\'s', (tester) => expectEnglish(tester, StartupErrorApp(report: 'r', onRetry: () {})));
    testWidgets('a window of its own', (tester) => expectEnglish(tester, secondaryWindowApp(title: 't', home: const Scaffold())));

    test('one MaterialApp with none fails here', () {
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart') || f.path.contains('generated')) continue;
        final text = f.readAsStringSync();
        if (RegExp(r'\bMaterialApp(\.router)?\(').hasMatch(text.replaceAll(RegExp(r'//[^\n]*'), ''))) {
          expect(text, contains('localeListResolutionCallback'), reason: f.path);
        }
      }
    });
  });

  group('the lower ones', () {
    test('a sign-out or a lock that stopped: the keychain\'s copy goes at the next start', () async {
      final first = world.launch();
      await first.start();
      final guest = await first.openCurrent();
      final prepared = await first.prepare(await first.planForAccount(uid: uid, label: 'a@example.com', bearer: 'b'));
      await guest.close();
      await first.commit(prepared);
      SecretSeal.openTree = prepared.db;
      expect(await first.settleLockedCopy(db: prepared.db, bearer: 'b'), isTrue);
      final id = first.currentEntry!.id;
      final copy = File(p.join(ProfilePaths.ofProfile(world.base, id).path, 'pre_move', ProfileMove.keychainCopyName));
      await copy.parent.create(recursive: true);
      await copy.writeAsString('the keychain as the move found it');
      // As if it stopped right after the list said locked.
      first.list.put(first.list.byId(id)!.copyWith(state: ProfileState.locked));
      await first.list.write(world.device);
      await prepared.db.close();
      SecretSeal.openTree = null;
      Profiles.debugReset();

      final next = world.launch();
      await next.start();
      expect(world.device.kept.containsKey(ProfileVault.plainName(id)), isFalse, reason: 'it finished');
      expect(copy.existsSync(), isFalse);
    });

    test('a start for a command that fails ends the program before anything is shown', () async {
      final said = <String>[];
      final window = StartupWindow(
        show: (_) => said.add('shown'),
        start: () {},
        state: () async => KeyringState.unknown,
        beforeSaying: () async => said.add('ended'),
      );
      await window.failed(StateError('x'), StackTrace.empty);
      expect(said, ['ended', 'shown']);
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('if (_adminArgs != null) await endAdminWithoutData();\n'.replaceAll('\n', Platform.isWindows ? '\r\n' : '\n')));
      expect(main, contains('beforeSaying: () async {'));
    });

    group('a renewal of the session', () {
      final at = DateTime.utc(2026, 10, 30);

      DeviceSessionService service({
        required List<String> saved,
        String Function()? refresh,
        Future<String?> Function()? token,
        Future<void> Function(String) Function()? saver,
      }) =>
          DeviceSessionService(
            api: _RenewingApi(refresh ?? () => 'a renewed token'),
            store: DeviceSessionStore(world.device),
            firebaseUid: () => null,
            sessionToken: token ?? () async => 'an old token',
            saveSessionToken: (t) async => saved.add(t),
            labels: () async => const DeviceLabels(platform: 'windows'),
            now: () => at,
            issuedAt: (_) => at.subtract(const Duration(days: 30)),
            saverForNow: saver,
          );

      test('the next person\'s profile opened while its token was read: dropped', () async {
        Profiles.turnOn();
        final alice = ActiveProfile(id: newProfileId(), dir: world.base, uid: uid);
        final bob = ActiveProfile(id: newProfileId(), dir: world.base, uid: 'account-bob');
        Profiles.bind(alice);
        final saved = <String>[];
        await service(
          saved: saved,
          token: () async {
            Profiles.bind(bob);
            return 'alice\'s old token';
          },
        ).renewIfOld();
        expect(saved, isEmpty);
      });

      test('the same on the way that asks after a device with no id', () async {
        Profiles.turnOn();
        final alice = ActiveProfile(id: newProfileId(), dir: world.base, uid: uid);
        final bob = ActiveProfile(id: newProfileId(), dir: world.base, uid: 'account-bob');
        Profiles.bind(alice);
        final saved = <String>[];
        final db = await openPlayed(world.base, 'aa');
        addTearDown(db.close);
        SecretSeal.openTree = db;
        await service(
          saved: saved,
          refresh: () {
            Profiles.bind(bob);
            return 'a renewed token';
          },
        ).ensure();
        expect(saved, isEmpty);
      });

      test('what keeps it is bound to the profile that asked, name and seal, whatever opens as it writes', () async {
        Profiles.turnOn();
        final alice = ActiveProfile(id: newProfileId(), dir: world.base, uid: uid);
        final bob = ActiveProfile(id: newProfileId(), dir: world.base, uid: 'account-bob');
        final aliceDir = await Directory(p.join(world.root.path, 'a')).create();
        final bobDir = await Directory(p.join(world.root.path, 'b')).create();
        final aliceDb = await openPlayed(aliceDir, 'aa');
        final bobDb = await openPlayed(bobDir, 'bb');
        addTearDown(aliceDb.close);
        addTearDown(bobDb.close);
        final aliceSeal = await SecretSeal.forProfile(aliceDb);
        await SecretSeal.forProfile(bobDb);
        Profiles.bind(alice);
        SecretSeal.openTree = aliceDb;
        final save = renewedSessionSaver(ProfileKeychain(world.device));
        // The next person's opens.
        Profiles.bind(bob);
        SecretSeal.openTree = bobDb;
        await save('a renewed token');
        expect(world.device.kept.keys.where((k) => k.startsWith(bob.prefix)), isEmpty);
        final name = KeychainNames.full(alice.id, uid, 'session_token');
        expect(await aliceSeal.open(name, world.device.kept[name]!), isNot(isEmpty));
        final read = await AccountSecret.sessionToken.read(
          ProfileKeychain(world.device, profile: () => alice, tree: () => aliceDb),
          tree: () => aliceDb,
        );
        expect(read, 'a renewed token');
      });

      test('the app\'s own service is made with it', () {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        expect(c.read(deviceSessionServiceProvider).saverForNow, isNotNull);
      });

      test('with nothing else happening it is kept', () async {
        Profiles.turnOn();
        Profiles.bind(ActiveProfile(id: newProfileId(), dir: world.base, uid: uid));
        final saved = <String>[];
        await service(saved: saved, saver: () => (t) async => saved.add('bound $t')).renewIfOld();
        expect(saved, ['bound a renewed token']);
      });
    });
  });

  test('the strings say what they do', () {
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;
    expect(en['profileSetAsideBody'], contains('Put it back'));
    expect(en['olderDataLocked'], contains('app lock'));
  });
}

class _Older extends OlderVersionData {
  _Older(ProfileWorld world) : super(base: world.base, device: world.device, rawPrefs: world.rawPrefs);

  int deleted = 0;

  @override
  Future<void> delete() async => deleted++;
}

class _Profiles implements ProfileController {
  int putBack = 0;
  int deleted = 0;

  @override
  Future<void> askPutBack() async => putBack++;

  @override
  Future<void> deleteSetAside() async => deleted++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RenewingApi implements DeviceSessionsApi {
  _RenewingApi(this.renewed);
  final String Function() renewed;

  @override
  Future<String?> current() async => null;

  @override
  Future<String> refreshSessionToken(String token) async => renewed();

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<Object?>.value();
}
