// A host's share link pasted into the app: adding a host should be as
// quick as pasting its link, and not only on a
// phone. A link made by Share (zestssh://share?d=..., or
// zestssh://add-host?...) was only read when the device opened it; nothing
// took one pasted. Import hosts now has Paste a share link, and offers a link
// on the clipboard at its top where reading the clipboard is silent (Windows,
// Linux; never an iPhone, where it would show a banner). A pasted link is
// read as strictly as an opened one, refused with words where it does not
// read, and goes through the same confirmation and save as an opened link:
// nothing is added without the person's yes.

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/ui/screens/connection/incoming_share_dialog.dart';
import 'package:zestssh/ui/screens/connection/share_link_add.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

/// A share link's `d` made from [payload] as Share makes one (base64url, no
/// padding), for links Share itself would never make.
String _linkOf(Map<String, Object?> payload) =>
    'zestssh://share?d=${base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '')}';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  /// web 01, as Share makes its link: a user, a group, tags and a forward
  /// (which makes its `d` longer than 256 characters).
  final link = ConnectionShareUrlService.buildShareUrl(
    label: 'web 01',
    host: 'web-01.example.com',
    port: 2222,
    user: 'deploy',
    groupHint: 'Prod',
    tags: const ['web', 'eu'],
    forwards: const [
      SharedForward(type: 'local', bindAddress: '127.0.0.1', bindPort: 8080, remoteHost: 'db.internal', remotePort: 80, label: 'web'),
    ],
  ).toString();

  group('a pasted text read as a share link', () {
    test('a link Share makes, and an address alone (add-host), are read', () {
      final read = readShareLink('  $link\n');
      expect(read.ok, isTrue);
      expect((read.share!.label, read.share!.host, read.share!.port, read.share!.user), ('web 01', 'web-01.example.com', 2222, 'deploy'));
      expect(read.uri.toString(), link);
      final plain = readShareLink('zestssh://add-host?host=192.0.2.10&port=2200&user=ops&label=Lab');
      expect((plain.share!.host, plain.share!.port, plain.share!.label), ('192.0.2.10', 2200, 'Lab'));
    });

    test('what is not a share link, or not one that reads, is refused, each with its words', () {
      final refused = <String, ShareLinkRefusal>{
        '': ShareLinkRefusal.empty,
        'web-01.example.com': ShareLinkRefusal.notShareLink,
        // The wrong scheme, and another of the app's links.
        link.replaceFirst('zestssh://', 'https://'): ShareLinkRefusal.notShareLink,
        'zestssh://connect?host=web-01.example.com': ShareLinkRefusal.notShareLink,
        'zestssh://execute?connection=web&command=id': ShareLinkRefusal.notShareLink,
        // Longer than any share link can be.
        'zestssh://share?d=${'A' * (ConnectionShareUrlService.maxLinkChars + 1)}': ShareLinkRefusal.tooLong,
        // Bad base64, and base64 of what is no host.
        'zestssh://share?d=!!!not-base64!!!': ShareLinkRefusal.unreadable,
        'zestssh://share?d=${base64Url.encode(utf8.encode('[1,2,3]'))}': ShareLinkRefusal.unreadable,
        // A field a share link never carries, in the payload or beside it.
        _linkOf({'v': 1, 'label': 'web', 'host': 'web-01.example.com', 'password': 'hunter2'}): ShareLinkRefusal.unreadable,
        _linkOf({'v': 1, 'label': 'web', 'host': 'web-01.example.com', 'forwards': [
          {'type': 'local', 'bindPort': 8080, 'remoteHost': 'db', 'remotePort': 80, 'private_key': 'x'},
        ]}): ShareLinkRefusal.unreadable,
        '$link&token=abc': ShareLinkRefusal.unreadable,
        'zestssh://add-host?host=web-01.example.com&key=AAAA': ShareLinkRefusal.unreadable,
        // A version it does not know, a host that is not one.
        _linkOf({'v': 2, 'label': 'web', 'host': 'web-01.example.com'}): ShareLinkRefusal.unreadable,
        _linkOf({'v': 1, 'label': 'web', 'host': 'web 01;rm -rf'}): ShareLinkRefusal.unreadable,
        // Cut in two on its way.
        '${link.substring(0, 60)} ${link.substring(60)}': ShareLinkRefusal.unreadable,
      };
      refused.forEach((text, why) {
        final read = readShareLink(text);
        expect(read.ok, isFalse, reason: text);
        expect(read.refusal, why, reason: text);
      });
      final words = {for (final r in ShareLinkRefusal.values) r: shareLinkRefusalWords(l10n, r)};
      expect(words[ShareLinkRefusal.notShareLink], l10n.shareLinkRefusedNotLink);
      expect(words[ShareLinkRefusal.tooLong], l10n.shareLinkRefusedTooLong);
      expect(words[ShareLinkRefusal.unreadable], l10n.shareLinkRefusedUnreadable);
    });

    test('the clipboard is read unasked only where that is silent', () {
      expect({for (final p in TargetPlatform.values) p: clipboardReadIsSilent(p)}, {
        TargetPlatform.android: false,
        TargetPlatform.fuchsia: false,
        TargetPlatform.iOS: false,
        TargetPlatform.linux: true,
        TargetPlatform.macOS: false,
        TargetPlatform.windows: true,
      });
    });
  });

  group('Import hosts, Paste a share link', () {
    late int clipboardReads;
    String? clipboard;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      debugTopSnackBarOnPhone = true;
      clipboardReads = 0;
      clipboard = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
          (call) async {
        if (call.method == 'Clipboard.getData') {
          clipboardReads++;
          return clipboard == null ? null : {'text': clipboard};
        }
        return null;
      });
    });

    tearDown(() {
      debugTopSnackBarOnPhone = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    /// The app with a button that opens Import hosts, over the Tree [db].
    Future<void> pumpApp(WidgetTester tester, AppDatabase db) async {
      tester.view.physicalSize = const Size(1400, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
          databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
          orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(builder: (context) => TextButton(onPressed: () => openImportHosts(context), child: const Text('go'))),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    /// Lets what runs outside the test's clock (the database) finish, until
    /// [until] is on screen.
    Future<void> settle(WidgetTester tester, Finder until) async {
      for (var i = 0; i < 40 && until.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
    }

    Future<List<Connection>> hosts(WidgetTester tester, AppDatabase db) async =>
        (await tester.runAsync(() => db.connectionsDao.getAll()))!;

    /// Adds the host shown in the confirmation open now, and checks it is said.
    Future<void> add(WidgetTester tester) async {
      await tester.tap(find.text(l10n.incomingShareAddConnection));
      await settle(tester, find.text(l10n.qrScanConnectionAdded));
      expect(find.text(l10n.qrScanConnectionAdded), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    }

    Future<void> openPaste(WidgetTester tester) async {
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.shareLinkPasteDesc), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('file-source-share-link')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('share-link-field')), findsOneWidget);
    }

    Future<void> enter(WidgetTester tester, String text) async {
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('share-link-field')), matching: find.byType(EditableText)), text);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('share-link-continue')));
      await tester.pumpAndSettle();
    }

    testWidgets('a pasted link shows its host first, nothing is added on Cancel, and on Add it is in your Tree with '
        'its user, group and tags, its forward not started', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      await pumpApp(tester, db);
      await openPaste(tester);
      // Nothing to read yet: its button waits, and says nothing.
      await tester.tap(find.byKey(const ValueKey('share-link-continue')));
      await tester.pumpAndSettle();
      expect(find.byType(IncomingShareDialog), findsNothing);
      expect(find.text(l10n.shareLinkRefusedNotLink), findsNothing);

      await enter(tester, link);
      expect(find.byType(IncomingShareDialog), findsOneWidget);
      expect(find.text('web 01'), findsOneWidget);
      expect(find.text('web-01.example.com:2222'), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(find.byType(IncomingShareDialog), findsNothing);
      expect(await hosts(tester, db), isEmpty, reason: 'nothing without the yes');

      await openPaste(tester);
      await enter(tester, link);
      await add(tester);
      final added = await hosts(tester, db);
      expect([for (final h in added) (h.label, h.host, h.port)], [('web 01', 'web-01.example.com', 2222)]);
      final id = added.single.id;
      final forwards = (await tester.runAsync(() => db.portForwardRulesDao.getByConnection(id)))!;
      expect([for (final f in forwards) (f.bindPort, f.autoStart)], [(8080, false)]);
      expect((await tester.runAsync(() => db.connectionTagsDao.getTagsForConnection(id)))!.toSet(), {'web', 'eu'});
      expect((await tester.runAsync(() => db.connectionGroupsDao.getById(added.single.groupId!)))!.name, 'Prod');
    });

    testWidgets('a malformed or hostile link is refused under the field with words, and nothing is shown or added',
        (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      await pumpApp(tester, db);
      await openPaste(tester);
      for (final (text, words) in [
        ('https://zestssh.com/share?d=abc', l10n.shareLinkRefusedNotLink),
        ('zestssh://share?d=!!!not-base64!!!', l10n.shareLinkRefusedUnreadable),
        (_linkOf({'v': 1, 'label': 'web', 'host': 'web-01.example.com', 'password': 'hunter2'}), l10n.shareLinkRefusedUnreadable),
        ('zestssh://share?d=${'A' * (ConnectionShareUrlService.maxLinkChars + 10)}', l10n.shareLinkRefusedTooLong),
      ]) {
        await enter(tester, text);
        expect(find.text(words), findsOneWidget, reason: text.length > 80 ? text.substring(0, 80) : text);
        expect(find.byType(IncomingShareDialog), findsNothing);
      }
      expect(await hosts(tester, db), isEmpty);
    });

    testWidgets('Paste from clipboard reads the clipboard on its tap and goes straight on to the host', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      await pumpApp(tester, db);
      await openPaste(tester);
      // An empty clipboard is said.
      await tester.tap(find.byKey(const ValueKey('share-link-paste')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.shareLinkClipboardEmpty), findsOneWidget);
      clipboard = link;
      await tester.tap(find.byKey(const ValueKey('share-link-paste')));
      await tester.pumpAndSettle();
      expect(find.byType(IncomingShareDialog), findsOneWidget);
      await add(tester);
      expect([for (final h in await hosts(tester, db)) h.label], ['web 01']);
    });

    testWidgets('on a computer that reads the clipboard silently, a share link on it is offered first, and added only '
        'after its confirmation', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      clipboard = link;
      await pumpApp(tester, db);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.shareLinkClipGroup.toUpperCase()), findsOneWidget);
      expect(find.text(l10n.shareLinkClipAdd('web 01')), findsOneWidget);
      expect(find.text(l10n.shareLinkClipAddDesc('deploy@web-01.example.com:2222')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('import-clipboard-share-link')));
      await tester.pumpAndSettle();
      expect(find.byType(IncomingShareDialog), findsOneWidget);
      expect(await hosts(tester, db), isEmpty);
      await add(tester);
      expect([for (final h in await hosts(tester, db)) h.label], ['web 01']);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('what is on the clipboard and no share link that reads is not offered', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      for (final text in ['ssh deploy@web-01.example.com', 'zestssh://share?d=!!!', _linkOf({'v': 1, 'host': 'h', 'token': 't'})]) {
        clipboard = text;
        await pumpApp(tester, db);
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('import-clipboard-share-link')), findsNothing, reason: text);
        await tester.tap(find.text(l10n.cancel));
        await tester.pumpAndSettle();
      }
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('on an iPhone the clipboard is never read as Import hosts opens (it would show a banner)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      clipboard = link;
      await pumpApp(tester, db);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(clipboardReads, 0);
      expect(find.byKey(const ValueKey('import-clipboard-share-link')), findsNothing);
      expect(find.byKey(const ValueKey('file-source-share-link')), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
