import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/export/event_export.dart';
import 'package:zestssh/features/orchards/export/event_exporter.dart';
import 'package:zestssh/features/orchards/export/export_settings.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_view.dart' show kTeamPageWidth;
import 'package:zestssh/features/orchards/widgets/orchard_rules_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_export_view.dart';
import 'package:zestssh/features/orchards/widgets/team_tracking_view.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

import '../../../helpers/last_line.dart';
import '../../../visual/shots_util.dart';
import '../fake_crate_server.dart';
import 'package:zestssh/l10n/time_text.dart';

/// Event export (3.0) on screen, on a real Orchard: what a member
/// sees of it, what an owner needs before it can be set up, the dialog that
/// sets it up (what is wrong with an address is said, a test event is sent
/// and its outcome shown, turning it on asks first and then shows the key),
/// how it is going on the device that sends, another address, turning it
/// off, and another device taking over. Each device has its own service,
/// secure storage and receiver against one (fake) server.

const _owner = 'owner-1';
const _owner2 = 'owner-2';
const _alice = 'alice';

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

class _Keychain implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        return Future<String?>.value(values[key]);
      case #write:
        values[key!] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        values.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

/// The system that receives the events.
class _Receiver {
  final requests = <({ExportDestination to, String body})>[];
  ExportDelivery? refuse;

  Future<ExportDelivery> post(ExportDestination to, String body) async {
    requests.add((to: to, body: body));
    return refuse ?? const ExportDelivery.delivered(200);
  }

  /// The events of the last request.
  List<Map<String, dynamic>> get last {
    final r = requests.last;
    return r.to.format == ExportFormat.array
        ? [for (final e in jsonDecode(r.body) as List) e as Map<String, dynamic>]
        : [
            for (final line in r.body.split('\n'))
              if (line.isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
          ];
  }
}

class _Device {
  _Device(this.shared, this.uid, this.keys, this.signIn, this.receiver, {_MemoryStorage? storage, _Keychain? keychain})
      : storage = storage ?? _MemoryStorage(),
        keychain = keychain ?? _Keychain() {
    databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: this.storage);
    service = OrchardService(
      server: shared.as(uid, device: signIn),
      databases: databases,
      author: () async => CrateAuthor(uid: uid, keys: keys),
      deviceKeys: DeviceIdentityStore(this.keychain),
    );
    exporter = exporterWith(null);
  }

  final FakeCrateServer shared;
  final String uid;
  final AccountKeys keys;
  final String signIn;
  final _Receiver receiver;
  final _MemoryStorage storage;
  final _Keychain keychain;
  late final OrchardDatabasesNotifier databases;
  late final OrchardService service;
  late final OrchardEventExporter exporter;

  OrchardEventExporter exporterWith(void Function()? onChanged) => OrchardEventExporter(
        service: () => service,
        settings: ExportSettingsStore(keychain),
        post: receiver.post,
        onChanged: onChanged,
      );

  /// The same device with a service of its own, as after the app was
  /// started again: a scope disposes what it is given, and this one stays.
  _Device again() => _Device(shared, uid, keys, signIn, receiver, storage: storage, keychain: keychain);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    if (i >= 1 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final acme = orchardDisplayName('Acme', l10n);
  const address = 'https://logs.example.com/ingest';

  late FakeCrateServer server;
  late _Receiver receiver;
  late _Device laptop;
  late _Device phone;
  late _Device second;
  late _Device alice;
  late String orchardId;

  /// An Orchard of two owners (the first with a laptop and a phone) and
  /// alice, a member. With [activity], it records activity.
  Future<void> setUpOrchard(WidgetTester tester, {bool activity = true}) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    receiver = _Receiver();
    await tester.runAsync(() async {
      final ownerKeys = await AccountKeys.generate();
      final owner2Keys = await AccountKeys.generate();
      final aliceKeys = await AccountKeys.generate();
      await server.publish(_owner, ownerKeys, email: '$_owner@example.com');
      await server.publish(_owner2, owner2Keys, email: '$_owner2@example.com');
      await server.publish(_alice, aliceKeys, email: '$_alice@example.com');
      laptop = _Device(server, _owner, ownerKeys, 'laptop', receiver);
      phone = _Device(server, _owner, ownerKeys, 'phone', receiver);
      second = _Device(server, _owner2, owner2Keys, 'second-laptop', receiver);
      alice = _Device(server, _alice, aliceKeys, 'alice-laptop', receiver);
      orchardId = await laptop.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final member = server.recordOf(orchardId).roles.values.single.id;
      for (final (person, role) in [(alice, member), (second, FixedRoles.owner)]) {
        await laptop.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
        final invite = (await laptop.service.invites(orchardId)).single;
        server.acceptAs(orchardId, invite.id, person.uid);
        await laptop.service.confirmInvite(orchardId, (await laptop.service.invites(orchardId)).single);
      }
      if (activity) await laptop.service.setTracking(orchardId, const RecordTracking(activity: true));
      for (final d in [laptop, phone, second, alice]) {
        await d.service.refresh();
      }
    });
    addTearDown(() async {
      for (final d in [laptop, phone, second, alice]) {
        for (final db in d.storage.dbs.values) {
          try {
            await db.close();
          } catch (_) {}
        }
      }
    });
  }

  /// [as]'s device with [body] on screen: the panel alone by default.
  Future<(ProviderContainer, _Device)> pumpPage(
    WidgetTester tester,
    _Device as, {
    bool small = false,
    Size? size,
    Widget Function(OrchardSummary orchard)? body,
    Locale locale = const Locale('en'),
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size ?? (small ? const Size(360, 640) : const Size(1100, 900));
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final view = as.again();
    Future<OrchardSummary> read() async => readOrchardSummary(await view.databases.open(orchardId), orchardId);
    final first = (await tester.runAsync(() async {
      await view.service.refresh();
      return read();
    }))!;
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(view.service),
        orchardDatabasesProvider.overrideWith((ref) => view.databases),
        orchardEventExporterProvider.overrideWith(
            (ref) => view.exporterWith(() => ref.read(exportVersionProvider.notifier).state++)),
        orchardSummariesProvider.overrideWith((ref) async {
          ref.watch(orchardListVersionProvider);
          return [await read()];
        }),
        activeOrchardProvider.overrideWith(
            (ref) => ref.watch(orchardSummariesProvider).whenData((list) => list.firstOrNull)),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        orchardSsoProvider.overrideWith((ref, id) async => const OrchardSso(kind: SsoKind.saml, active: false)),
        currentUserProvider.overrideWithValue(UserProfile(uid: as.uid, email: '${as.uid}@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: body != null ? body(first) : TeamExportPanel(orchard: first),
          ),
        ),
      ),
    ));
    await settle(tester);
    return (ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)), view);
  }

  Finder key(String k) => find.byKey(ValueKey(k));
  Finder inKey(String k, Finder f) => find.descendant(of: find.byKey(ValueKey(k)), matching: f);
  String? textOf(WidgetTester tester, String k) => tester.widget<Text>(key(k)).data;

  /// The format picked in the setup dialog's segmented control.
  ExportFormat formatOf(WidgetTester tester) =>
      tester.widget<SegmentedButton<ExportFormat>>(key('export-format')).selected.single;

  /// How event export stands, as the page's own exporter says (the one
  /// that keeps what the page's device set up).
  Future<ExportStanding> standingOf(WidgetTester tester, ProviderContainer container) async =>
      (await tester.runAsync(() => container.read(orchardEventExporterProvider).standing(orchardId)))!;

  bool toasted(ProviderContainer container, WidgetTester tester, String message) =>
      find.text(message).evaluate().isNotEmpty ||
      container.read(notificationCenterProvider).history.any((n) => n.title == message || n.body == message);

  /// Sets event export up on [d]'s device without a screen.
  Future<DeviceIdentity> setUp(
    WidgetTester tester,
    _Device d, {
    String to = address,
    ExportFormat format = ExportFormat.lines,
    String? headerName,
    String? headerValue,
  }) async =>
      (await tester.runAsync(() async {
        final key = await d.exporter.newKey();
        await d.exporter.setUp(
            orchardId, ExportDestination.of(to, format, headerName: headerName, headerValue: headerValue)!, key);
        return key;
      }))!;

  testWidgets('a member sees whether the events are sent on and who set that up, and changes nothing',
      (tester) async {
    await setUpOrchard(tester);
    await pumpPage(tester, alice);
    expect(find.text(l10n.exportTitle), findsOneWidget);
    expect(find.text(noOrphan(l10n.exportIntro)), findsOneWidget);
    expect(inKey('team-export-state-off', find.text(l10n.exportStateOff)), findsOneWidget);
    expect(textOf(tester, 'team-export-off'), l10n.exportOffNote);
    expect(textOf(tester, 'team-export-owners-only'), l10n.exportOwnersOnly);
    expect(key('team-export-set-up'), findsNothing);
    expect(key('team-export-needs-activity'), findsNothing);

    await setUp(tester, laptop);
    final (container, view) = await pumpPage(tester, alice);
    expect(inKey('team-export-state-on', find.text(l10n.exportStateOn)), findsOneWidget);
    expect(textOf(tester, 'team-export-on-member'), l10n.exportOnForMembers('owner-1@example.com'));
    for (final k in ['team-export-off', 'team-export-turn-off', 'team-export-copy-key', 'team-export-move',
      'team-export-test', 'team-export-change', 'team-export-to', 'team-export-set-up']) {
      expect(key(k), findsNothing, reason: k);
    }

    // The page on screen reads again after a sync: turned off elsewhere,
    // it says so without being opened anew.
    await tester.runAsync(() async {
      await laptop.exporter.turnOff(orchardId);
      await view.service.refresh();
    });
    container.read(orchardListVersionProvider.notifier).state++;
    await settle(tester);
    expect(inKey('team-export-state-off', find.text(l10n.exportStateOff)), findsOneWidget);
    expect(key('team-export-on-member'), findsNothing);
  });

  testWidgets('an owner sets it up: not before activity is recorded; what is wrong with an address or a header '
      'is said; a test event is sent; turning it on asks first, and then shows the key', (tester) async {
    await setUpOrchard(tester, activity: false);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    // Nothing recorded: nothing to send on, said where it can be changed.
    await pumpPage(tester, laptop);
    expect(textOf(tester, 'team-export-needs-activity'), l10n.exportNeedsActivity);
    expect(key('team-export-set-up'), findsNothing);
    expect(key('team-export-owners-only'), findsNothing);

    await tester.runAsync(() => laptop.service.setTracking(orchardId, const RecordTracking(activity: true)));
    final (container, view) = await pumpPage(tester, laptop);
    expect(key('team-export-needs-activity'), findsNothing);
    await tester.tap(key('team-export-set-up'));
    await settle(tester);
    // The dialog's title says what, the line under it whose.
    expect(find.descendant(of: find.byType(ZestDialogShell), matching: find.text(l10n.exportTitle)), findsOneWidget);
    expect(find.descendant(of: find.byType(ZestDialogShell), matching: find.text(acme)), findsOneWidget);
    expect(find.text(l10n.exportSetupIntro), findsOneWidget);
    expect(textOf(tester, 'export-what'), l10n.exportWhatIsSent);
    expect(key('export-move-note'), findsNothing);
    expect(find.text(l10n.exportTurnOn), findsOneWidget);
    // Each field holds its words 12 pixels in from its edge, as every field
    // does (a design review saw them about 24 in).
    for (final field in ['export-address', 'export-header-name', 'export-header-value']) {
      final box = find.ancestor(of: key(field), matching: find.byType(Container)).first;
      expect(tester.getTopLeft(key(field)).dx - tester.getTopLeft(box).dx, 13, reason: '$field: 12, and its hairline');
    }

    // What is wrong is said, and nothing is sent or asked.
    Future<void> turnOn() async {
      await tester.ensureVisible(key('export-save'));
      await tester.tap(key('export-save'));
      await settle(tester);
    }

    await turnOn();
    expect(find.text(l10n.exportAddressNeeded), findsOneWidget);
    await tester.enterText(key('export-address'), 'logs.example.com');
    await turnOn();
    expect(find.text(l10n.exportAddressInvalid), findsOneWidget);
    await tester.enterText(key('export-address'), 'http://logs.example.com/ingest');
    await turnOn();
    expect(find.text(l10n.exportAddressNotSecure), findsOneWidget);
    await tester.enterText(key('export-address'), ' $address ');
    await tester.enterText(key('export-header-name'), 'Authorization');
    await turnOn();
    expect(find.text(l10n.exportAddressNotSecure), findsNothing);
    expect(find.text(l10n.exportHeaderHalf), findsOneWidget);
    await tester.enterText(key('export-header-name'), 'Content-Type');
    await tester.enterText(key('export-header-value'), 'text/plain');
    await turnOn();
    expect(find.text(l10n.exportHeaderNameInvalid), findsOneWidget);
    await tester.enterText(key('export-header-name'), 'Authorization');
    await tester.enterText(key('export-header-value'), 'tökén');
    await turnOn();
    expect(find.text(l10n.exportHeaderValueInvalid), findsOneWidget);
    expect(receiver.requests, isEmpty);
    expect(find.text(l10n.exportConfirmTitle(acme)), findsNothing);
    expect(tester.widget<TextField>(key('export-header-value')).obscureText, isTrue, reason: 'a secret is typed there');

    // A test event: as an array, with the header, signed.
    await tester.enterText(key('export-header-value'), 'Splunk token-1');
    expect(formatOf(tester), ExportFormat.lines);
    await tester.tap(key('export-format-array'));
    await tester.pump();
    expect(formatOf(tester), ExportFormat.array);
    await tester.ensureVisible(key('export-test'));
    await tester.tap(key('export-test'));
    await settle(tester);
    expect(find.text(l10n.exportHeaderValueInvalid), findsNothing);
    expect(textOf(tester, 'export-tested-ok'), l10n.exportTestSent('200'));
    expect('${receiver.requests.single.to.url}', address);
    expect(receiver.requests.single.to.headers, {'Content-Type': 'application/json', 'Authorization': 'Splunk token-1'});
    final test = receiver.last.single;
    expect((test['type'], test['actor']['email']), ('test', 'owner-1@example.com'));
    expect((await tester.runAsync(() => verifyExportEvent(test)))!, isTrue);
    expect(server.recordOf(orchardId).eventExport, isNull, reason: 'a test turns nothing on');
    // One that is not taken says why.
    receiver.refuse = const ExportDelivery.failed(ExportFailure.refused, status: 403);
    await tester.tap(key('export-test'));
    await settle(tester);
    expect(textOf(tester, 'export-tested-failed'), l10n.exportTestFailed(l10n.exportFailRefused('403')));
    receiver.refuse = null;

    // Turning it on asks first, as a step of the same dialog (no second
    // dialog over it); Back changes nothing and keeps what was typed.
    await turnOn();
    expect(find.text(l10n.exportConfirmTitle(acme)), findsOneWidget);
    expect(find.text(l10n.exportConfirmBody), findsOneWidget);
    expect(find.byType(ZestDialogShell), findsOneWidget, reason: 'one dialog');
    await tester.tap(key('export-back'));
    await settle(tester);
    expect(server.recordOf(orchardId).eventExport, isNull);
    expect(find.text(l10n.exportConfirmTitle(acme)), findsNothing);
    expect(tester.widget<TextField>(key('export-address')).controller!.text.trim(), address);
    // With a sign-in that is not recent, the owner is asked to confirm it
    // is them, and told what for.
    server.requireRecentSignIn = true;
    await turnOn();
    await tester.tap(find.text(l10n.exportTurnOn).last);
    await settle(tester);
    expect(find.text(l10n.stepUpTitle), findsOneWidget);
    expect(find.text(l10n.stepUpExportOn(acme)), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).eventExport, isNull);
    expect(view.keychain.values.keys.where((k) => k.startsWith('orchard_export')), isEmpty);
    server.requireRecentSignIn = false;

    final version = container.read(orchardListVersionProvider);
    await turnOn();
    await tester.tap(find.text(l10n.exportTurnOn).last);
    await settle(tester);
    final record = server.recordOf(orchardId).eventExport!;
    expect(record.by, _owner);
    expect(record.keyText, test['key'], reason: 'the key the test event was signed with');
    expect(toasted(container, tester, l10n.exportTurnedOn), isTrue);
    expect(container.read(orchardListVersionProvider), greaterThan(version),
        reason: 'the Team pages read the record again');
    // The key, to hand to whoever runs the receiving system.
    expect(key('export-done'), findsOneWidget);
    expect(find.text(l10n.exportKeyTitle), findsOneWidget);
    expect(find.text(l10n.exportKeyHelp), findsOneWidget);
    expect(tester.widget<SelectableText>(key('export-done-key')).data, record.keyText);
    await tester.tap(key('export-done-copy'));
    await settle(tester);
    expect(copied, record.keyText);
    expect(toasted(container, tester, l10n.exportKeyCopied), isTrue);
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(key('export-done-close'));
    await settle(tester);
    expect(key('export-done'), findsNothing);

    // The panel: on, sent from here, to that host, and how it went.
    expect(inKey('team-export-state-on', find.text(l10n.exportStateOn)), findsOneWidget);
    expect(textOf(tester, 'team-export-here'), noOrphan(l10n.exportSendsHere));
    expect(textOf(tester, 'team-export-to'), 'logs.example.com');
    final standing = await standingOf(tester, container);
    expect(standing.status.sent, 1);
    expect(textOf(tester, 'team-export-status-ok'), exportStatusText(standing.status, l10n));
    expect(textOf(tester, 'team-export-status-ok'), contains('1 event so far'));
    expect(receiver.last.single['id'], 'record-${server.entriesOf(orchardId).last.seq}');
    await tester.pump(const Duration(seconds: 5));
    // The key is public, handed to whoever runs the receiving system: it
    // stays on the clipboard (it was once taken off
    // after 45 seconds, as a secret is).
    await tester.pump(kSecretClipboardLife);
    expect(copied, record.keyText, reason: 'still on the clipboard');
  });

  testWidgets('on the device that sends: how it is going, a test event, another address, and turning it off',
      (tester) async {
    await setUpOrchard(tester);
    final signing = await setUp(tester, laptop,
        format: ExportFormat.array, headerName: 'Authorization', headerValue: 'Splunk token-1');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    // The receiver stops taking events: said, with why, and that it is tried again.
    receiver.refuse = const ExportDelivery.failed(ExportFailure.certificate);
    await tester.runAsync(() async {
      await laptop.service.createCrate(orchardId, 'Vault', ownersOnly: true);
      await laptop.exporter.round(orchardId);
    });
    final (container, view) = await pumpPage(tester, laptop);
    var standing = await standingOf(tester, container);
    expect(standing.status.failure, ExportFailure.certificate);
    // It sends from here: there is nothing to take over.
    expect(key('team-export-move'), findsNothing);
    expect(key('team-export-change'), findsOneWidget);
    expect(textOf(tester, 'team-export-status-failed'), exportStatusText(standing.status, l10n));
    expect(textOf(tester, 'team-export-status-failed'), contains(l10n.exportFailCertificate));
    expect(key('team-export-status-ok'), findsNothing);
    // The page hears of the next round by itself: another reason, said at
    // once.
    receiver.refuse = const ExportDelivery.failed(ExportFailure.timeout);
    await tester.runAsync(() => container.read(orchardEventExporterProvider).round(orchardId));
    await settle(tester);
    expect(textOf(tester, 'team-export-status-failed'), contains(l10n.exportFailTimeout));
    receiver.refuse = const ExportDelivery.failed(ExportFailure.certificate);

    // A test event from the panel, with the key that signs the events.
    await tester.tap(key('team-export-test'));
    await settle(tester);
    expect(toasted(container, tester, l10n.exportTestFailed(l10n.exportFailCertificate)), isTrue);
    await tester.pump(const Duration(seconds: 5));
    receiver.refuse = null;
    await tester.tap(key('team-export-test'));
    await settle(tester);
    expect(toasted(container, tester, l10n.exportTestSent('200')), isTrue);
    expect((receiver.last.single['type'], receiver.last.single['key']), ('test', signing.key));
    await tester.tap(key('team-export-copy-key'));
    await settle(tester);
    expect(copied, signing.key);
    expect(toasted(container, tester, l10n.exportKeyCopied), isTrue);
    await tester.pump(const Duration(seconds: 5));

    // Another address: the dialog holds what is kept, and changes only that.
    await tester.tap(key('team-export-change'));
    await settle(tester);
    expect(find.text(l10n.exportChangeTitle), findsOneWidget);
    expect(tester.widget<TextField>(key('export-address')).controller!.text, address);
    expect(tester.widget<TextField>(key('export-header-name')).controller!.text, 'Authorization');
    expect(tester.widget<TextField>(key('export-header-value')).controller!.text, 'Splunk token-1');
    expect(formatOf(tester), ExportFormat.array);
    expect(find.text(l10n.exportTurnOn), findsNothing);
    expect(find.text(l10n.save), findsOneWidget);
    final entries = server.entriesOf(orchardId).length;
    await tester.enterText(key('export-address'), 'https://siem.example.net/hook');
    // A test event from here goes to the address typed, signed with the
    // key this device sends with.
    await tester.ensureVisible(key('export-test'));
    await tester.tap(key('export-test'));
    await settle(tester);
    expect(textOf(tester, 'export-tested-ok'), l10n.exportTestSent('200'));
    expect(receiver.requests.last.to.url.host, 'siem.example.net');
    expect((receiver.last.single['type'], receiver.last.single['key']), ('test', signing.key));
    expect(server.entriesOf(orchardId), hasLength(entries));
    await tester.enterText(key('export-header-name'), 'DD-API-KEY');
    await tester.enterText(key('export-header-value'), 'key-2');
    await tester.ensureVisible(key('export-save'));
    await tester.tap(key('export-save'));
    await settle(tester);
    expect(toasted(container, tester, l10n.exportSaved), isTrue);
    expect(find.text(l10n.exportChangeTitle), findsNothing, reason: 'the dialog closed');
    expect(server.entriesOf(orchardId), hasLength(entries), reason: 'nothing in the record changes');
    expect(textOf(tester, 'team-export-to'), 'siem.example.net');
    standing = await standingOf(tester, container);
    expect(standing.destination!.headers['DD-API-KEY'], 'key-2');
    expect(standing.destination!.format, ExportFormat.array, reason: 'what was not changed stays');
    expect(standing.status.failure, isNull, reason: 'what waited went to the new address');
    expect(receiver.requests.last.to.url.host, 'siem.example.net');
    expect(textOf(tester, 'team-export-status-ok'), exportStatusText(standing.status, l10n));
    await tester.pump(const Duration(seconds: 5));

    // Turning it off asks first, and says what this device does last.
    await tester.tap(key('team-export-turn-off'));
    await settle(tester);
    expect(find.text(l10n.exportTurnOffTitle(acme)), findsOneWidget);
    expect(find.text('${l10n.exportTurnOffBody}\n\n${l10n.exportTurnOffBodyHere}'), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).eventExport, isNotNull);
    server.requireRecentSignIn = true;
    await tester.tap(key('team-export-turn-off'));
    await settle(tester);
    await tester.tap(find.text(l10n.exportTurnOff).last);
    await settle(tester);
    expect(find.text(l10n.stepUpExportOff(acme)), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).eventExport, isNotNull);
    server.requireRecentSignIn = false;
    final version = container.read(orchardListVersionProvider);
    await tester.tap(key('team-export-turn-off'));
    await settle(tester);
    await tester.tap(find.text(l10n.exportTurnOff).last);
    await settle(tester);
    expect(server.recordOf(orchardId).eventExport, isNull);
    expect(toasted(container, tester, l10n.exportTurnedOff), isTrue);
    expect(container.read(orchardListVersionProvider), greaterThan(version),
        reason: 'the Team pages read the record again');
    expect(receiver.last.single['change'], 'export_off');
    expect(view.keychain.values.keys.where((k) => k.startsWith('orchard_export')), isEmpty);
    expect(inKey('team-export-state-off', find.text(l10n.exportStateOff)), findsOneWidget);
    expect(key('team-export-set-up'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    // The key is public, handed to whoever runs the receiving system: it
    // stays on the clipboard (it was once taken off
    // after 45 seconds, as a secret is).
    await tester.pump(kSecretClipboardLife);
    expect(copied, signing.key, reason: 'still on the clipboard');
  });

  testWidgets('another device sends: whose is said, and an owner can turn it off or take over from here',
      (tester) async {
    await setUpOrchard(tester);
    final signing = await setUp(tester, laptop);

    // The same owner's phone.
    await pumpPage(tester, phone);
    expect(textOf(tester, 'team-export-own'), noOrphan(l10n.exportSendsElsewhereOwn));
    for (final k in ['team-export-to', 'team-export-test', 'team-export-change', 'team-export-status-ok']) {
      expect(key(k), findsNothing, reason: k);
    }
    expect(key('team-export-turn-off'), findsOneWidget);
    expect(key('team-export-copy-key'), findsOneWidget);
    // Turning it off from here does not speak of what this device does last.
    await tester.tap(key('team-export-turn-off'));
    await settle(tester);
    expect(find.text(l10n.exportTurnOffBody), findsOneWidget);
    expect(find.textContaining(l10n.exportTurnOffBodyHere), findsNothing);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    // The other owner: told who set it up, and offered to send from here.
    final (container, view) = await pumpPage(tester, second);
    expect(textOf(tester, 'team-export-other'), noOrphan(l10n.exportSendsElsewhere('owner-1@example.com')));
    await tester.tap(key('team-export-move'));
    await settle(tester);
    expect(textOf(tester, 'export-move-note'), l10n.exportMoveNote);
    await tester.ensureVisible(key('export-cancel'));
    await tester.tap(key('export-cancel'));
    await settle(tester);
    expect(key('export-move-note'), findsNothing, reason: 'Cancel closes it');
    expect(server.recordOf(orchardId).eventExport!.by, _owner);
    await tester.tap(key('team-export-move'));
    await settle(tester);
    await tester.enterText(key('export-address'), 'https://siem.example.net/hook');
    await tester.ensureVisible(key('export-save'));
    await tester.tap(key('export-save'));
    await settle(tester);
    await tester.tap(find.text(l10n.exportTurnOn).last);
    await settle(tester);
    final record = server.recordOf(orchardId).eventExport!;
    expect(record.by, _owner2);
    expect(record.keyText, isNot(signing.key), reason: 'a key of its own');
    expect(toasted(container, tester, l10n.exportTurnedOn), isTrue);
    await tester.tap(key('export-done-close'));
    await settle(tester);
    expect(textOf(tester, 'team-export-here'), noOrphan(l10n.exportSendsHere));
    expect(textOf(tester, 'team-export-to'), 'siem.example.net');
    expect(view.keychain.values.keys.where((k) => k.startsWith('orchard_export')), hasLength(3));
    await tester.pump(const Duration(seconds: 5));

    // The first owner's laptop hears of it: no longer the one that sends.
    await tester.runAsync(() async {
      await laptop.service.refresh();
      await laptop.exporter.rounds();
    });
    await pumpPage(tester, laptop);
    expect(textOf(tester, 'team-export-other'), noOrphan(l10n.exportSendsElsewhere('owner-2@example.com')));
    expect(key('team-export-move'), findsOneWidget);

    // Once activity is no longer recorded there is nothing to take over.
    await tester.runAsync(() => laptop.service.setTracking(orchardId, RecordTracking.none));
    await pumpPage(tester, laptop);
    expect(inKey('team-export-state-off', find.text(l10n.exportStateOff)), findsOneWidget);
    expect(textOf(tester, 'team-export-needs-activity'), l10n.exportNeedsActivity);
  });

  testWidgets('the Rules page shows it, under what the team records', (tester) async {
    await setUpOrchard(tester);
    await pumpPage(tester, laptop, body: (o) => OrchardRulesView(orchardId: o.id, onSaved: () {}));
    expect(key('team-export'), findsOneWidget);
    expect(tester.getTopLeft(key('team-export')).dy,
        greaterThan(tester.getBottomLeft(find.byType(TeamTrackingPanel)).dy));
    expect(key('team-export-set-up'), findsOneWidget);
    // Everyone sees it there, not only owners.
    await pumpPage(tester, alice, body: (o) => OrchardRulesView(orchardId: o.id, onSaved: () {}));
    expect(textOf(tester, 'team-export-owners-only'), l10n.exportOwnersOnly);
  });

  testWidgets('how it is going, in words: nothing sent yet, when and how many, and each reason it did not go', (tester) async {
    // (An app on screen has the days and months of its language; here
    // nothing is on screen.)
    await initializeDateFormatting();
    final moment = DateTime(2026, 10, 2, 14, 5);
    final at = moment.millisecondsSinceEpoch ~/ 1000;
    // (The day and the time as the language writes them.)
    final when = DateFormat.yMMMd('en').add_jm().formatPlain(moment);
    expect(when, allOf(startsWith('Oct 2, 2026 2:05'), endsWith('PM')));
    expect(exportStatusText(ExportStatus.none, l10n), l10n.exportStatusNone);
    expect(exportStatusText(ExportStatus(sentAt: at, sent: 1), l10n), 'Last sent $when. 1 event so far.');
    expect(exportStatusText(ExportStatus(sentAt: at, sent: 2400), l10n), 'Last sent $when. 2400 events so far.');
    for (final (failure, status, words) in [
      (ExportFailure.refused, 503, l10n.exportFailRefused('503')),
      (ExportFailure.timeout, null, l10n.exportFailTimeout),
      (ExportFailure.certificate, null, l10n.exportFailCertificate),
      (ExportFailure.unreachable, null, l10n.exportFailUnreachable),
      (ExportFailure.other, null, l10n.exportFailOther),
    ]) {
      expect(exportFailureText(failure, status, l10n), words);
      // What stopped it counts, whatever went before.
      expect(
        exportStatusText(ExportStatus(sentAt: at - 600, sent: 5, failure: failure, failedStatus: status, failedAt: at), l10n),
        'Not sent since $when: $words. It is tried again every minute, and nothing is skipped.',
      );
    }
    expect(l10n.exportFailRefused('503'), 'the receiver answered 503');
  });

  testWidgets('in every language, on a computer and on a small phone: the panel, setting it up, and the key, '
      'nothing clipped', (tester) async {
    await tester.runAsync(() async {
      final loader = FontLoader('GeistSans');
      for (final f in ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf']) {
        loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
      }
      await loader.load();
    });
    final theme = ThemeData(fontFamily: 'GeistSans');
    await setUpOrchard(tester);
    try {
      for (final locale in AppLocalizations.supportedLocales) {
        final t = lookupAppLocalizations(locale);
        for (final small in [false, true]) {
          final where = '$locale ${small ? 'phone' : 'computer'}';
          debugDefaultTargetPlatformOverride = small ? TargetPlatform.android : null;

          // Off: a member, and an owner who sets it up from the Rules page.
          await pumpPage(tester, alice, small: small, locale: locale, theme: theme);
          expect(tester.takeException(), isNull, reason: '$where: a member, off');
          expect(find.text(t.exportOwnersOnly), findsOneWidget, reason: where);
          await pumpPage(tester, laptop,
              small: small, locale: locale, theme: theme, body: (o) => OrchardRulesView(orchardId: o.id, onSaved: () {}));
          expect(tester.takeException(), isNull, reason: '$where: the Rules page');
          await tester.ensureVisible(key('team-export-set-up'));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(key('team-export-set-up'));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where: the dialog');
          expect(find.text(t.exportWhatIsSent), findsOneWidget, reason: where);
          // Every error at once, then a test event that is not taken.
          await tester.enterText(key('export-address'), 'http://logs.example.com/in');
          await tester.enterText(key('export-header-name'), 'Authorization');
          await tester.ensureVisible(key('export-save'));
          await tester.tap(key('export-save'));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where: what is wrong');
          expect(find.text(t.exportAddressNotSecure), findsOneWidget, reason: where);
          expect(find.text(t.exportHeaderHalf), findsOneWidget, reason: where);
          await tester.enterText(key('export-address'), address);
          await tester.enterText(key('export-header-value'), 'Splunk token-1');
          receiver.refuse = const ExportDelivery.failed(ExportFailure.refused, status: 503);
          await tester.ensureVisible(key('export-test'));
          await tester.tap(key('export-test'));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where: a test that is not taken');
          expect(find.text(t.exportTestFailed(t.exportFailRefused('503'))), findsOneWidget, reason: where);
          receiver.refuse = null;
          await tester.ensureVisible(key('export-save'));
          await tester.tap(key('export-save'));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where: asked first');
          expect(find.text(t.exportConfirmBody), findsOneWidget, reason: where);
          await tester.tap(find.text(t.exportTurnOn).last);
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where: the key');
          expect(find.text(t.exportKeyHelp), findsOneWidget, reason: where);
          await tester.tap(key('export-done-close'));
          await settle(tester);
          await tester.pump(const Duration(seconds: 5));

          // On: the device that sends (with a failure said), another owner,
          // and a member.
          receiver.refuse = const ExportDelivery.failed(ExportFailure.unreachable);
          await tester.runAsync(() async {
            await laptop.service.createCrate(orchardId, 'Vault ${locale.languageCode}$small', ownersOnly: true);
          });
          final (sending, _) = await pumpPage(tester, laptop, small: small, locale: locale, theme: theme);
          await tester.runAsync(() => sending.read(orchardEventExporterProvider).round(orchardId));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where: the device that sends');
          expect(key('team-export-status-failed'), findsOneWidget, reason: where);
          receiver.refuse = null;
          await pumpPage(tester, second, small: small, locale: locale, theme: theme);
          expect(tester.takeException(), isNull, reason: '$where: another owner');
          expect(find.text(noOrphan(t.exportSendsElsewhere('owner-1@example.com'))), findsOneWidget, reason: where);
          // (Taking over from there, with what the device that sends now
          // does then.)
          await tester.ensureVisible(key('team-export-move'));
          await tester.tap(key('team-export-move'));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where: taking over');
          expect(find.text(t.exportMoveNote), findsOneWidget, reason: where);
          await tester.ensureVisible(key('export-cancel'));
          await tester.tap(key('export-cancel'));
          await settle(tester);
          await pumpPage(tester, alice, small: small, locale: locale, theme: theme);
          expect(tester.takeException(), isNull, reason: '$where: a member, on');
          expect(find.text(t.exportOnForMembers('owner-1@example.com')), findsOneWidget, reason: where);

          // Turned off again, for the next language. (On a phone it is the
          // last of the buttons, one under the other: scrolled to first.)
          await pumpPage(tester, laptop, small: small, locale: locale, theme: theme);
          await tester.ensureVisible(key('team-export-turn-off'));
          await settle(tester);
          await tester.tap(key('team-export-turn-off'));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where: turning it off');
          await tester.tap(find.text(t.exportTurnOff).last);
          await settle(tester);
          expect(server.recordOf(orchardId).eventExport, isNull, reason: where);
          await tester.pump(const Duration(seconds: 5));
        }
      }
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  // Last in this file: it loads the app's fonts, which every test after it
  // would measure with.
  testWidgets('no word alone on a line: the card\'s words on a computer, who sends on a phone', (tester) async {
    // ("on." was alone under the card's words at a Team page's width, "it."
    // under the line on which device sends on a phone 390 wide, found in a design
    // review.)
    await tester.runAsync(loadShotFonts);
    await setUpOrchard(tester);
    await setUp(tester, laptop);
    final theme = BuiltInThemes.getById('default_light').toThemeData();
    await pumpPage(tester, laptop,
        theme: theme,
        body: (o) => Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kTeamPageWidth),
                child: TeamExportPanel(orchard: o),
              ),
            ));
    expect(tester.getSize(key('team-export')).width, kTeamPageWidth);
    expectNoOrphan(tester, findWords(l10n.exportIntro), reason: 'a computer');
    await pumpPage(tester, laptop, theme: theme, size: const Size(390, 844));
    expectNoOrphan(tester, key('team-export-here'), reason: 'a phone');
    await tester.pumpWidget(const SizedBox());
  });
}
