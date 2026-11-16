import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Axis;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/local_state_store.dart';

/// Whether this build fills an empty install with made-up demo data, for
/// marketing footage:
///
///   flutter run --debug --dart-define=ZEST_DEMO_SEED=true
///
/// Only a debug build asked for it. [kDebugMode] is a constant false in a
/// release or profile build, so this is too, and the seed is left out of
/// those builds altogether (nothing reaches [DemoSeed] but through it).
const bool kDemoSeed = kDebugMode && bool.fromEnvironment('ZEST_DEMO_SEED');

/// What a seeded install was filled with ([DemoSeed.fillIfEmpty]).
typedef DemoSeedResult = ({int hosts, int keys, int snippets});

/// The start's way in (lib/main.dart): seeds [db] where this build was asked
/// to ([kDemoSeed]) and it is empty ([DemoSeed.isEmpty]); null and nothing
/// written otherwise. A failure is logged by the caller and never stops the
/// app from starting.
Future<DemoSeedResult?> seedDemoIfAsked({
  required AppDatabase db,
  required SharedPreferences prefs,
  required IdentitySecretStore secrets,
}) async {
  if (!kDemoSeed) return null;
  return DemoSeed(db: db, prefs: prefs, secrets: secrets).fillIfEmpty();
}

/// The made-up world of the screenshot tests and the website: twelve hosts
/// (the demo fleet of test/visual, every address private and none of them
/// answering), their systems, the groups Web, Databases,
/// Hypervisors and Network, a few tags, three workspaces, two Ed25519 keys made
/// fresh on this device, saved snippets, port forwards, alerts and some command
/// history. No account: the install stays a guest's.
class DemoSeed {
  DemoSeed({
    required this.db,
    required this.prefs,
    required this.secrets,
    KeyGenerationService? keys,
    DateTime Function()? clock,
  })  : _keys = keys ?? KeyGenerationService(),
        _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final SharedPreferences prefs;

  /// Where the two keys' private halves go: the store the app keeps them in.
  final IdentitySecretStore secrets;

  final KeyGenerationService _keys;
  final DateTime Function() _clock;

  /// Set in the database once it is seeded: a database seeded once is never
  /// seeded again, also after everything in it was deleted.
  static const doneKey = 'demo_seed_done';

  /// The demo hosts: id, name, address, the key or account it signs in with,
  /// its system (as the app keeps what it found out), its group.
  static const hosts = <(String, String, String, String, String, String?)>[
    ('demo-web-01', 'web-01', '192.168.10.21', 'ops', 'ubuntu', 'demo-g-web'),
    ('demo-web-02', 'web-02', '192.168.10.22', 'ops', 'ubuntu', 'demo-g-web'),
    ('demo-db-primary', 'db-primary', '192.168.10.31', 'ops', 'debian', 'demo-g-db'),
    ('demo-cache-01', 'cache-01', '192.168.10.41', 'ops', 'alpine', 'demo-g-db'),
    ('demo-log-store', 'log-store', '192.168.10.24', 'ops', 'rocky', null),
    ('demo-monitoring', 'monitoring', '192.168.10.60', 'ops', 'ubuntu', null),
    ('demo-build-runner', 'build-runner', '192.168.10.50', 'build', 'debian', null),
    ('demo-edge-router', 'edge-router', '192.168.20.1', 'router', 'openwrt', 'demo-g-net'),
    ('demo-hypervisor-a', 'hypervisor-a', '192.168.20.11', 'hypervisors', 'debian', 'demo-g-hv'),
    ('demo-hypervisor-b', 'hypervisor-b', '192.168.20.12', 'hypervisors', 'debian', 'demo-g-hv'),
    ('demo-mac-studio', 'mac-studio', '192.168.10.30', 'ops', 'macos', null),
    ('demo-vpn-gateway', 'vpn-gateway', '192.168.10.23', 'ops', 'alpine', 'demo-g-net'),
  ];

  /// Whether [db] holds nothing a person made: no host, key, group, snippet,
  /// forward, alert, command or workspace, and was never seeded.
  static Future<bool> isEmpty(AppDatabase db) async {
    Future<bool> none(TableInfo<Table, Object?> table) async {
      final count = countAll();
      final row = await (db.selectOnly(table)..addColumns([count])).getSingle();
      return (row.read(count) ?? 0) == 0;
    }

    for (final table in <TableInfo<Table, Object?>>[
      db.connections,
      db.identities,
      db.connectionGroups,
      db.snippets,
      db.portForwardRules,
      db.terminalTriggers,
      db.commandHistory,
    ]) {
      if (!await none(table)) return false;
    }
    final store = LocalStateStore(db);
    if (await store.read(doneKey) != null) return false;
    if (await store.read(kSavedTabGroupsKey) != null) return false;
    return true;
  }

  /// Fills [db] with the demo world where [isEmpty] says it is empty; null
  /// (and nothing written) where it is not.
  Future<DemoSeedResult?> fillIfEmpty() async {
    if (!await isEmpty(db)) return null;
    final now = _clock();
    final crud = IdentityCrudNotifier(db.identitiesDao, secrets, db.connectionsDao);

    // Two keys, made here and now: never a key kept anywhere.
    final ops = await _key(crud, 'Ops laptop', 'deploy', 'ops@laptop');
    final build = await _key(crud, 'Build key', 'ci', 'ci@build-runner');
    // Two accounts whose password is asked for when they connect: none is kept.
    final router = await crud.create(label: 'Router admin', username: 'admin', authMethod: 'password');
    final hypervisors = await crud.create(label: 'Hypervisors', username: 'root', authMethod: 'password');
    final accounts = {'ops': ops, 'build': build, 'router': router, 'hypervisors': hypervisors};

    const groups = [
      ('demo-g-web', 'Web', 0xFF4FAE78),
      ('demo-g-db', 'Databases', 0xFF7AA7E0),
      ('demo-g-hv', 'Hypervisors', 0xFFA879E8),
      ('demo-g-net', 'Network', 0xFFE6A23C),
    ];
    for (final (i, (id, name, color)) in groups.indexed) {
      await db.connectionGroupsDao.insertGroup(ConnectionGroupsCompanion(
        id: Value(id),
        name: Value(name),
        colorValue: Value(color),
        sortOrder: Value(i),
        createdAt: Value(now),
      ));
    }

    for (final (i, (id, name, address, account, os, group)) in hosts.indexed) {
      await db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value(id),
        label: Value(name),
        host: Value(address),
        port: const Value(22),
        identityId: Value(accounts[account]),
        groupId: Value(group),
        sortOrder: Value(i),
        lastConnected: Value(switch (name) {
          'web-01' => now.subtract(const Duration(hours: 2)),
          'db-primary' => now.subtract(const Duration(hours: 5)),
          'hypervisor-a' => now.subtract(const Duration(days: 1)),
          'build-runner' => now.subtract(const Duration(days: 3)),
          _ => null,
        }),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      // As the app keeps a host's system once it has connected to it.
      await prefs.setString('os_kind_$id', os);
    }

    final tags = ConnectionTagsDao(db);
    await tags.setTagsForConnection('demo-web-01', ['prod', 'nginx']);
    await tags.setTagsForConnection('demo-web-02', ['prod']);
    await tags.setTagsForConnection('demo-db-primary', ['postgres', 'prod']);
    await tags.setTagsForConnection('demo-build-runner', ['ci']);
    await tags.setTagsForConnection('demo-vpn-gateway', ['staging']);

    final snippets = await _snippets(now);

    await db.portForwardRulesDao.insertRule(PortForwardRulesCompanion(
      id: const Value('demo-pf-grafana'),
      connectionId: const Value('demo-monitoring'),
      type: const Value('local'),
      bindPort: const Value(3000),
      remoteHost: const Value('localhost'),
      remotePort: const Value(3000),
      label: const Value('Grafana'),
      createdAt: Value(now),
    ));
    await db.portForwardRulesDao.insertRule(PortForwardRulesCompanion(
      id: const Value('demo-pf-db'),
      connectionId: const Value('demo-db-primary'),
      type: const Value('local'),
      bindPort: const Value(5433),
      remoteHost: const Value('localhost'),
      remotePort: const Value(5432),
      label: const Value('Orders database'),
      createdAt: Value(now),
    ));

    for (final (i, (id, name, pattern, highlight, sound)) in const [
      ('demo-alert-error', 'Error', r'(?i)\b(error|failed|fatal)\b', 0xFFEF4444, true),
      ('demo-alert-build', 'Build finished', r'(?i)build (succeeded|successful|finished|complete)', null, true),
      ('demo-alert-warning', 'Warning', r'(?i)\bwarn(ing)?\b', 0xFFEAB308, false),
    ].indexed) {
      await db.into(db.terminalTriggers).insert(TerminalTriggersCompanion(
        id: Value(id),
        name: Value(name),
        pattern: Value(pattern),
        highlight: Value(highlight != null),
        highlightColor: Value(highlight),
        playSound: Value(sound),
        sortOrder: Value(i),
        createdAt: Value(now),
      ));
    }

    await _history(now);

    await LocalStateStore(db).write(kSavedTabGroupsKey, jsonEncode([for (final w in _workspaces(now)) w.toJson()]));

    // Past the first-run screens: the app opens on its Hosts page, a guest's.
    await prefs.setBool('onboarding_complete', true);
    await LocalStateStore(db).write(doneKey, now.toIso8601String());
    return (hosts: hosts.length, keys: 2, snippets: snippets);
  }

  Future<String> _key(IdentityCrudNotifier crud, String label, String user, String comment) async {
    final made = await _keys.generateEd25519(comment: comment);
    return crud.create(
      label: label,
      username: user,
      authMethod: 'publicKey',
      keyType: KeyType.ed25519.displayName,
      publicKeyFingerprint: made.fingerprint,
      publicKeyData: made.publicOpenSSH,
      privateKeyPem: made.privatePem,
    );
  }

  Future<int> _snippets(DateTime now) async {
    const rows = [
      ('Docker', 'Running Containers', 'docker ps', false, null),
      ('Docker', 'Container Logs', r'docker logs $[DOCKER] --tail 50', false, '{"variables":{"[DOCKER]":"Container name"}}'),
      ('Docker', 'Restart Container', r'docker restart $[DOCKER]', false, null),
      ('Docker', 'Prune Unused', 'docker system prune -f', true, null),
      ('Releases', 'Pull Release', 'set -e\ncd /srv/shop\ngit pull\nnpm ci', false, null),
      ('Releases', 'Build Site', 'cd /srv/shop/site && npm ci && npm run build', false, null),
      ('Files', 'Disk Usage', r'du -sh ${PATH:-.}/*', false, null),
      ('Files', 'Largest Files', 'find . -type f -size +100M', false, null),
      ('Postgres', 'Postgres Backup', 'pg_dump -Fc shop > /backups/shop.dump', false, null),
      ('Network', 'Open Ports', 'ss -tulpn', false, null),
      ('Logs', 'Tail Syslog', 'tail -f /var/log/syslog', false, null),
    ];
    for (final (i, (folder, label, command, confirm, meta)) in rows.indexed) {
      await db.snippetsDao.insertSnippet(SnippetsCompanion(
        id: Value('demo-snippet-$i'),
        label: Value(label),
        command: Value(command),
        category: Value(folder),
        confirmBeforeRun: Value(confirm),
        metadata: Value(meta),
        sortOrder: Value(i),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
    }
    return rows.length;
  }

  Future<void> _history(DateTime now) async {
    final today = DateTime(now.year, now.month, now.day);
    DateTime at(int daysAgo, int h, int m) => today.subtract(Duration(days: daysAgo)).add(Duration(hours: h, minutes: m));
    const names = {
      'demo-web-01': 'web-01',
      'demo-web-02': 'web-02',
      'demo-edge-router': 'edge-router',
      'demo-build-runner': 'build-runner',
      'demo-hypervisor-a': 'hypervisor-a',
      'demo-db-primary': 'db-primary',
    };
    final rows = <(String, String, DateTime, String, int, int)>[
      ('demo-web-01', 'systemctl status nginx', at(0, 9, 12), '/home/deploy', 0, 210),
      ('demo-web-01', 'sudo systemctl reload nginx', at(0, 9, 14), '/home/deploy', 0, 180),
      ('demo-db-primary', 'df -h /var/lib/postgresql', at(0, 8, 40), '/home/deploy', 0, 30),
      ('demo-web-02', 'pm2 restart shop', at(1, 13, 15), '/home/deploy/shop', 0, 600),
      ('demo-web-02', 'npm run build', at(1, 13, 16), '/home/deploy/shop', 0, 41000),
      ('demo-edge-router', 'nft list set inet fw blocklist | wc -l', at(2, 18, 0), '/root', 0, 130),
      ('demo-build-runner', 'sudo systemctl restart api-gateway', at(3, 19, 13), '/home/ci', 0, 1800),
      ('demo-hypervisor-a', 'qm list', at(4, 11, 39), '/root', 0, 420),
      ('demo-hypervisor-a', 'htop', at(4, 11, 41), '/root', 0, 1080000),
    ];
    for (final (i, (host, command, ranAt, cwd, exit, ms)) in rows.indexed) {
      await db.into(db.commandHistory).insert(CommandHistoryCompanion(
        id: Value('demo-history-$i'),
        command: Value(command),
        connectionId: Value(host),
        hostLabel: Value(names[host]),
        createdAt: Value(ranAt),
        cwd: Value(cwd),
        exitCode: Value(exit),
        durationMs: Value(ms),
      ));
    }
  }

  List<SavedTabGroup> _workspaces(DateTime now) {
    TabSnapshot tab(String host) => TabSnapshot(paneTreeOfConnIds: PaneLeaf.single(sessionId: host));
    TabSnapshot split(String a, String b) => TabSnapshot(
          paneTreeOfConnIds: PaneSplit.even(
            first: PaneLeaf.single(sessionId: a),
            second: PaneLeaf.single(sessionId: b),
            axis: Axis.horizontal,
          ),
        );
    final names = {for (final h in hosts) h.$1: h.$2};
    SavedTabGroup w(String id, String name, List<TabSnapshot> tabs, Duration ago) {
      final ids = <String>{for (final t in tabs) for (final l in t.paneTreeOfConnIds.allLeaves) ...l.sessionIds};
      return SavedTabGroup(
        id: id,
        name: name,
        tabs: tabs,
        createdAt: now.subtract(const Duration(days: 14)),
        lastUsedAt: now.subtract(ago),
        hostNames: {for (final h in ids) h: names[h]!},
      );
    }

    return [
      w('demo-ws-deploy', 'Deploy', [split('demo-web-01', 'demo-web-02'), tab('demo-vpn-gateway')], const Duration(hours: 2)),
      w('demo-ws-db', 'Database night', [split('demo-db-primary', 'demo-cache-01')], const Duration(days: 1)),
      w('demo-ws-morning', 'Morning check',
          [split('demo-hypervisor-a', 'demo-hypervisor-b'), split('demo-edge-router', 'demo-monitoring')], const Duration(days: 3)),
    ];
  }
}
