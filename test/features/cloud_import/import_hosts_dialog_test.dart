import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/cloud_import/cloud_tls.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';

/// Import hosts (3.0 cloud import), driven as a person would: pick a
/// provider, give a token, scan, choose hosts, choose where they go. The
/// token is used once unless Keep in sync is on (then it stays on this
/// device only); Proxmox's own certificate is compared before anything is
/// sent; a failure says why and offers its details; the SSH config, PuTTY
/// and CSV file sources hand over to their own imports.

final l10n = lookupAppLocalizations(const Locale('en'));

const _cert = CloudCertificate(
  sha256: 'D2:93:C9:44:ED:19:1C:66:05:72:E1:C4:F2:0C:B6:33:88:71:60:CD:18:CD:D5:1A:C6:CA:63:85:FF:6C:F0:70',
  subject: 'CN=pve.test',
  issuer: 'CN=pve.test',
);

/// No Orchard on this device. (In a build with Orchards on, the dialog lists
/// the Crates hosts could go into; the app's own storage reads the disk,
/// which a widget test neither should nor can wait for.)
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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late List<(CloudProvider, Map<String, String>)> scans;
  late Object? scanError;
  late List<CloudMachine> machines;
  late int probes;
  late ImportHostsResult? result;
  late bool closed;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    scans = [];
    scanError = null;
    probes = 0;
    result = null;
    closed = false;
    machines = const [
      CloudMachine(provider: CloudProvider.hetzner, id: '42', name: 'builder', publicAddress: '203.0.113.8', where: 'ash', tags: ['role:ci'], user: 'root'),
      CloudMachine(provider: CloudProvider.hetzner, id: '43', name: 'backup-fsn', publicAddress: '198.51.100.2', where: 'fsn1', user: 'root'),
    ];
  });

  tearDown(() => db.close());

  Future<void> open(WidgetTester tester, {bool recording = false}) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => recording),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showZestModal<ImportHostsResult>(
                  context: context,
                  size: ZestModalSize.large,
                  child: ImportHostsDialog(
                    scan: (provider, fields) async {
                      scans.add((provider, fields));
                      if (scanError != null) throw scanError!;
                      return machines;
                    },
                    probe: (base) async {
                      probes++;
                      return _cert;
                    },
                  ),
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.cloudImpTitle), findsWidgets);
  }

  Future<void> type(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(TextField)), text);
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> toConnect(WidgetTester tester, CloudProvider p) async {
    // The list of apps above the clouds is longer than the dialog: brought into view first.
    await tester.ensureVisible(find.byKey(ValueKey('cloud-source-${p.name}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('cloud-source-${p.name}')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.cloudImpScan), findsOneWidget);
  }

  testWidgets('a one-time import: scan, choose, import into the Tree; the token is not kept', (tester) async {
    await open(tester);
    await toConnect(tester, CloudProvider.hetzner);
    // The trust line: here only, not kept, and the least the token needs.
    expect(find.text('${l10n.cloudImpTrustDevice} ${l10n.cloudImpTrustNotKept} ${l10n.cloudImpTokenHetzner}'), findsOneWidget);
    await type(tester, 'cloud-field-token', 'hz-secret-token');
    await press(tester, l10n.cloudImpScan);
    expect(scans.single.$1, CloudProvider.hetzner);
    expect(scans.single.$2[CloudField.token], 'hz-secret-token');
    expect(find.text(l10n.cloudImpFound(2, 'Hetzner Cloud')), findsOneWidget);
    expect(find.text('builder'), findsOneWidget);
    expect(find.text(l10n.cloudImpStNew), findsNWidgets(2));

    // Leave one out.
    await tester.tap(find.byKey(const ValueKey('cloud-row-0')));
    await tester.pump();
    await press(tester, l10n.cloudImpNext);
    expect(find.text(l10n.cloudImpTree), findsOneWidget);
    expect(find.text(l10n.cloudImpSignInHintRoot('Hetzner Cloud')), findsOneWidget);
    await press(tester, l10n.cloudImpImportN(1));

    expect(closed, isTrue);
    final done = result! as ImportedFromCloud;
    expect(done.outcome.added, 1);
    expect(done.kept, isFalse);
    final hosts = await db.connectionsDao.getAll();
    expect(hosts.single.label, 'builder', reason: 'backup-fsn comes first by name and was left out');
    expect(CloudLink.decode(hosts.single.cloudSource)!.label, 'Hetzner Cloud');
    expect((await db.connectionGroupsDao.getAll()).single.name, 'Hetzner Cloud');
    expect(await const FlutterSecureStorage().read(key: CloudAccountStore.key), isNull, reason: 'used once, not kept');
  });

  testWidgets('Compatibility mode for every host imported, off unless ticked: item 53, in a cloud import too', (tester) async {
    await open(tester);
    await toConnect(tester, CloudProvider.hetzner);
    await type(tester, 'cloud-field-token', 'hz-secret-token');
    await press(tester, l10n.cloudImpScan);
    await press(tester, l10n.cloudImpNext);
    expect(find.text(l10n.csvImpCompatibility), findsOneWidget);
    expect(find.text(l10n.csvImpCompatibilityNote), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cloud-compatibility')));
    await tester.pump();
    await press(tester, l10n.cloudImpImportN(2));
    expect({for (final c in await db.connectionsDao.getAll()) c.label: c.compatibilityMode}, {'builder': true, 'backup-fsn': true});
  });

  testWidgets('Compatibility mode stays off where it is not ticked', (tester) async {
    await open(tester);
    await toConnect(tester, CloudProvider.hetzner);
    await type(tester, 'cloud-field-token', 'hz-secret-token');
    await press(tester, l10n.cloudImpScan);
    await press(tester, l10n.cloudImpNext);
    await press(tester, l10n.cloudImpImportN(2));
    expect([for (final c in await db.connectionsDao.getAll()) c.compatibilityMode], [false, false]);
  });

  testWidgets('Keep in sync keeps the account, token and destination on this device', (tester) async {
    await open(tester);
    await toConnect(tester, CloudProvider.hetzner);
    await type(tester, 'cloud-account-name', 'Hetzner CI');
    await type(tester, 'cloud-field-token', 'hz-secret-token');
    await tester.tap(find.byType(ZestSwitch).first);
    await tester.pumpAndSettle();
    expect(find.text('${l10n.cloudImpTrustDevice} ${l10n.cloudImpTrustKept} ${l10n.cloudImpTokenHetzner}'), findsOneWidget);
    await press(tester, l10n.cloudImpScan);
    await press(tester, l10n.cloudImpNext);
    await press(tester, l10n.cloudImpImportN(2));
    final kept = (await CloudAccountStore(const FlutterSecureStorage()).load()).single;
    expect(kept.provider, CloudProvider.hetzner);
    expect(kept.label, 'Hetzner CI');
    expect(kept.fields[CloudField.token], 'hz-secret-token');
    expect(kept.spaceId, kCloudTreeSpace);
    expect(kept.groupName, 'Hetzner CI');
    expect((result! as ImportedFromCloud).kept, isTrue);
  });

  testWidgets('what is missing or malformed is said at the field, and nothing is sent', (tester) async {
    await open(tester);
    await toConnect(tester, CloudProvider.proxmox);
    await press(tester, l10n.cloudImpScan);
    expect(find.text(l10n.cloudImpNeedField), findsNWidgets(2));
    await type(tester, 'cloud-field-url', 'http://pve.lan');
    await type(tester, 'cloud-field-token', 'just-a-password');
    await press(tester, l10n.cloudImpScan);
    expect(find.text(l10n.cloudImpBadUrl), findsOneWidget);
    expect(find.text(l10n.cloudImpBadProxmoxToken), findsOneWidget);
    expect(scans, isEmpty);
    expect(probes, 0);
  });

  testWidgets('AWS regions that are not region names are said at the field, and nothing is sent', (tester) async {
    await open(tester);
    await toConnect(tester, CloudProvider.aws);
    await type(tester, 'cloud-field-keyId', 'AKIAIOSFODNN7EXAMPLE');
    await type(tester, 'cloud-field-secret', 'secret-access-key');
    await type(tester, 'cloud-field-regions', 'us-east-1 evil.example');
    await press(tester, l10n.cloudImpScan);
    expect(find.text(l10n.cloudImpBadRegions), findsOneWidget);
    expect(scans, isEmpty);
    // Fixed, it goes.
    await type(tester, 'cloud-field-regions', 'us-east-1');
    await press(tester, l10n.cloudImpScan);
    expect(scans.single.$2[CloudField.regions], 'us-east-1');
  });

  testWidgets('Proxmox: its certificate is compared before anything is sent; a wrong fingerprint cannot be trusted', (tester) async {
    await open(tester);
    await toConnect(tester, CloudProvider.proxmox);
    await type(tester, 'cloud-field-url', '192.168.20.10');
    await type(tester, 'cloud-field-token', 'root@pam!zestssh=aaaa-bbbb');
    await press(tester, l10n.cloudImpScan);
    expect(probes, 1);
    expect(scans, isEmpty, reason: 'nothing sent before the certificate is confirmed');
    expect(find.byKey(const ValueKey('cloud-certificate')), findsOneWidget);
    expect(find.text(_cert.sha256), findsOneWidget);

    await type(tester, 'cloud-certificate-paste', '24:E8:BD:E5:AB:3F:B2:0D:82:B6:6C:9E:08:CC:01:18:66:D5:22:C1:F4:88:7C:3F:9E:2F:FE:13:BB:BB:26:E1');
    expect(find.text(l10n.cloudImpCertNoMatch), findsOneWidget);
    await press(tester, l10n.cloudImpCertTrust);
    expect(scans, isEmpty, reason: 'a fingerprint that does not match cannot be trusted');

    await type(tester, 'cloud-certificate-paste', _cert.sha256.toLowerCase().replaceAll(':', ' '));
    expect(find.text(l10n.cloudImpCertMatch), findsOneWidget);
    machines = const [CloudMachine(provider: CloudProvider.proxmox, id: '192.168.20.10:8006/pve/101', name: 'metrics', privateAddress: '192.168.20.21')];
    await press(tester, l10n.cloudImpCertTrust);
    expect(scans.single.$2[CloudField.pin], _cert.sha256, reason: 'the scan trusts exactly that certificate');
    expect(find.text('metrics'), findsOneWidget);
  });

  testWidgets('a failed scan says why in words and offers its details, with the token nowhere on screen', (tester) async {
    await open(tester);
    await toConnect(tester, CloudProvider.hetzner);
    await type(tester, 'cloud-field-token', 'hz-secret-token');
    scanError = CloudError(CloudErrorKind.signIn, status: 401, detail: 'GET https://api.hetzner.cloud/v1/servers -> 401\n{"error":"unauthorized"}');
    await press(tester, l10n.cloudImpScan);
    expect(find.byKey(const ValueKey('cloud-error')), findsOneWidget);
    expect(find.textContaining('did not accept these keys'), findsOneWidget);
    expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
    // The token stays in its obscured field; nothing displayed shows it.
    expect(find.descendant(of: find.byKey(const ValueKey('cloud-error')), matching: find.textContaining('hz-secret-token')), findsNothing);
    final field = tester.widget<EditableText>(
        find.descendant(of: find.byKey(const ValueKey('cloud-field-token')), matching: find.byType(EditableText)));
    expect(field.obscureText, isTrue);
    // Copy details puts the request and answer on the clipboard.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await tester.tap(find.text(l10n.desktopShellCopyDetails));
    await tester.pump();
    expect(copied, contains('-> 401'));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('while the screen is recorded it asks first; declining stays on Source', (tester) async {
    await open(tester, recording: true);
    await tester.tap(find.byKey(const ValueKey('cloud-source-aws')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recModeRevealTitle), findsOneWidget);
    await tester.tap(find.text(l10n.recModeRevealCancel).last);
    await tester.pumpAndSettle();
    expect(find.text(l10n.cloudImpScan), findsNothing);
    expect(find.byKey(const ValueKey('cloud-source-aws')), findsOneWidget);
  });

  testWidgets('the SSH config source hands over to its own import', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('file-source-ssh-config')));
    await tester.pumpAndSettle();
    expect(result, isA<ImportFromSshConfig>());
  });

  testWidgets('the CSV file source hands over to its own import', (tester) async {
    await open(tester);
    expect(find.text(l10n.cloudImpCsvDesc), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('file-source-csv')));
    await tester.pumpAndSettle();
    expect(result, isA<ImportFromCsv>());
    expect((result! as ImportFromCsv).kind, HostFileKind.csv);
  });

  testWidgets('MobaXterm and SecureCRT are apps to import from, and each hands over to the file import as itself',
      (tester) async {
    for (final (key, kind) in [('mobaxterm', HostFileKind.mobaxterm), ('securecrt', HostFileKind.securecrt)]) {
      await open(tester);
      expect(find.text(l10n.migrateFromApps.toUpperCase()), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('file-source-$key')));
      await tester.pumpAndSettle();
      expect(result, isA<ImportFromCsv>());
      expect((result! as ImportFromCsv).kind, kind);
    }
  });

  testWidgets('Termius opens its guide, and Paste a list the file import as a pasted list', (tester) async {
    await open(tester);
    expect(find.text(l10n.importTermiusDesc), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('file-source-termius')));
    await tester.pumpAndSettle();
    expect(result, isA<ImportTermiusGuide>());
    await open(tester);
    // Under the clouds, below the dialog's first screen (4.0).
    await tester.ensureVisible(find.byKey(const ValueKey('file-source-paste')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('file-source-paste')));
    await tester.pumpAndSettle();
    expect((result! as ImportFromCsv).kind, HostFileKind.paste);
  });

  testWidgets('every app and cloud is a tile of a grid, at least 48 tall and as wide as the others; Let us know is last',
      (tester) async {
    await open(tester);
    final tiles = find.byType(ImportSourceCard);
    expect(tiles, findsAtLeastNWidgets(8));
    final widths = <double>{};
    for (final e in tiles.evaluate()) {
      final box = e.renderObject! as RenderBox;
      expect(box.size.height, greaterThanOrEqualTo(48));
      widths.add(box.size.width.roundToDouble());
    }
    expect(widths, hasLength(1), reason: 'one width: a grid of tiles (4.0)');
    final ask = tester.getTopLeft(find.byKey(const ValueKey('import-ask-source'))).dy;
    for (final e in tiles.evaluate()) {
      expect((e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy, lessThan(ask));
    }
  });

  testWidgets('the steps stand apart from the section under them', (tester) async {
    await open(tester);
    // Its head sat close under them (found in a design review).
    final gap = find.byKey(const ValueKey('cloud-steps-gap'));
    expect(tester.getSize(gap).height, 24);
  });

  testWidgets('"Need to import something else? Let us know" closes it for a suggestion', (tester) async {
    await open(tester);
    expect(find.text(l10n.migrateAskTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('import-ask-source')));
    await tester.pumpAndSettle();
    expect(result, isA<ImportAskForSource>());
  });

  testWidgets('a host already here by address is not doubled unless ticked, and then it is linked', (tester) async {
    final at = DateTime.utc(2026, 9, 26);
    await db.connectionsDao.insertConnection(ConnectionsCompanion.insert(id: 'mine', label: 'My builder', host: '203.0.113.8', createdAt: at, updatedAt: at));
    await open(tester);
    await toConnect(tester, CloudProvider.hetzner);
    await type(tester, 'cloud-field-token', 'hz-secret-token');
    await press(tester, l10n.cloudImpScan);
    expect(find.text(l10n.cloudImpStHere), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cloud-row-1'))); // builder: tick it to link
    await tester.pump();
    await press(tester, l10n.cloudImpNext);
    await press(tester, l10n.cloudImpImportN(2));
    final out = (result! as ImportedFromCloud).outcome;
    expect((out.added, out.linked), (1, 1));
    final hosts = {for (final c in await db.connectionsDao.getAll()) c.id: c};
    expect(hosts, hasLength(2));
    expect(CloudLink.decode(hosts['mine']!.cloudSource)!.machineId, '42');
  });
}
