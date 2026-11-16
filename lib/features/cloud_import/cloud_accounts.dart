/// Cloud import (3.0): accounts the person chose to keep in sync. Each one's
/// token lives in this device's secure storage (the system keychain) and
/// nowhere else: never synced, never in a Crate, never sent to ZestSSH. This
/// device checks each one every 30 minutes while the app is open: new
/// machines are added, moved ones updated (the person's own edits kept), and
/// ones the account no longer lists marked. An import that is not kept uses
/// its token once and forgets it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_aws.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_import_writer.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/cloud_import/cloud_scans.dart';
import 'package:zestssh/features/cloud_import/cloud_tls.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/host_address.dart';

/// The names of what a provider's scan needs.
abstract final class CloudField {
  static const token = 'token';
  static const keyId = 'keyId';
  static const secret = 'secret';
  static const session = 'session';
  static const regions = 'regions';
  static const tenant = 'tenant';
  static const clientId = 'clientId';
  static const subscription = 'subscription';
  static const url = 'url';
  static const pin = 'pin';

  /// Tailscale's control server: empty for Tailscale itself, a Headscale
  /// server's address otherwise.
  static const server = 'server';

  /// The ones that are secrets: blanked from every error detail.
  static const secrets = {token, secret, session};
}

/// A Tree destination, as [CloudAccount.spaceId] names it.
const kCloudTreeSpace = 'tree';

/// Reads [provider]'s machines with [fields]. [clientFor] makes the HTTP
/// client (with Proxmox's confirmed certificate pinned); tests pass their
/// own. Throws [CloudError].
Future<List<CloudMachine>> scanCloud(
  CloudProvider provider,
  Map<String, String> fields, {
  http.Client Function(Uri? base, String? pin)? clientFor,
  Future<CloudCertificate?> Function(Uri base)? probe = probeCertificate,
}) async {
  String f(String k) => (fields[k] ?? '').trim();
  Uri? base;
  String? proxmoxToken;
  if (provider == CloudProvider.proxmox) {
    base = proxmoxBase(f(CloudField.url));
    if (base == null) throw CloudError(CloudErrorKind.notFound, detail: 'The Proxmox address is not an https address.');
    proxmoxToken = proxmoxTokenValue(f(CloudField.token));
    if (proxmoxToken == null) {
      throw CloudError(CloudErrorKind.signIn, detail: 'A Proxmox API token looks like root@pam!zestssh=0000-...');
    }
  }
  final pin = f(CloudField.pin);
  final client = (clientFor ?? (b, p) => b == null ? http.Client() : pinnedCloudClient(b, pinned: p))(base, pin.isEmpty ? null : pin);
  final cloud = CloudHttp(client, secrets: [for (final k in CloudField.secrets) f(k), ?proxmoxToken]);
  try {
    return switch (provider) {
      CloudProvider.digitalocean => await scanDigitalOcean(cloud, f(CloudField.token)),
      CloudProvider.hetzner => await scanHetzner(cloud, f(CloudField.token)),
      CloudProvider.tailscale => f(CloudField.server).isEmpty
          ? await scanTailscale(cloud, f(CloudField.token))
          : await scanHeadscale(cloud, f(CloudField.server), f(CloudField.token)),
      CloudProvider.azure => await scanAzure(cloud,
          secret: f(CloudField.secret),
          tenant: f(CloudField.tenant),
          clientId: f(CloudField.clientId),
          subscription: f(CloudField.subscription)),
      CloudProvider.aws => await scanAws(cloud,
          accessKeyId: f(CloudField.keyId),
          secretAccessKey: f(CloudField.secret),
          sessionToken: f(CloudField.session),
          regions: awsRegionsOf(f(CloudField.regions)) ??
              (throw CloudError(CloudErrorKind.notFound, detail: 'Regions are names like us-east-1, separated by spaces or commas.'))),
      CloudProvider.proxmox => await scanProxmox(cloud, base: base!, token: proxmoxToken!),
    };
  } on CloudError catch (e) {
    // A confirmed Proxmox certificate that no longer answers: say it changed,
    // with both fingerprints, rather than only that it is not trusted.
    if (e.kind == CloudErrorKind.certificate && base != null && pin.isNotEmpty && probe != null) {
      final now = await probe(base).catchError((Object _) => null);
      if (now != null && now.sha256 != pin) {
        throw CloudError(CloudErrorKind.certificateChanged,
            detail: 'https://${hostWithPort(base.host, base.port)}\nConfirmed: $pin\nNow:       ${now.sha256}');
      }
    }
    rethrow;
  } finally {
    client.close();
  }
}

/// A cloud account kept on this device.
class CloudAccount {
  const CloudAccount({
    required this.id,
    required this.provider,
    required this.label,
    required this.fields,
    this.spaceId = kCloudTreeSpace,
    this.crateId,
    this.identityId,
    this.groupName,
    this.preferPrivate = false,
    this.checkedAt,
    this.found,
    this.problem,
    this.problemDetail,
  });

  final String id;
  final CloudProvider provider;

  /// The account's name, as the person gave it.
  final String label;

  /// What its scan needs, token included.
  final Map<String, String> fields;

  /// [kCloudTreeSpace], or the Orchard's id.
  final String spaceId;
  final String? crateId;
  final String? identityId;
  final String? groupName;
  final bool preferPrivate;

  /// The last check that reached the provider, and how many machines it
  /// listed.
  final DateTime? checkedAt;
  final int? found;

  /// What stopped the last check, with its details for Copy details; null
  /// when it went through.
  final CloudErrorKind? problem;
  final String? problemDetail;

  Space get space => spaceId == kCloudTreeSpace ? const TreeSpace() : OrchardSpace(spaceId);

  CloudAccount checked({DateTime? at, int? found, CloudErrorKind? problem, String? detail}) => CloudAccount(
        id: id,
        provider: provider,
        label: label,
        fields: fields,
        spaceId: spaceId,
        crateId: crateId,
        identityId: identityId,
        groupName: groupName,
        preferPrivate: preferPrivate,
        checkedAt: problem == null ? at : checkedAt,
        found: problem == null ? found : this.found,
        problem: problem,
        problemDetail: detail,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'provider': provider.name,
        'label': label,
        'fields': fields,
        'space': spaceId,
        'crate': crateId,
        'identity': identityId,
        'group': groupName,
        'private': preferPrivate,
        'checked': checkedAt?.toUtc().toIso8601String(),
        'found': found,
        'problem': problem?.name,
        'detail': problemDetail,
      };

  /// Null for anything that is not one (damaged storage never crashes).
  static CloudAccount? fromJson(Object? json) {
    if (json is! Map) return null;
    final provider = CloudProvider.values.where((p) => p.name == json['provider']).firstOrNull;
    final id = json['id'];
    final fields = json['fields'];
    if (provider == null || id is! String || fields is! Map) return null;
    String? s(String k) => json[k] is String ? json[k] as String : null;
    return CloudAccount(
      id: id,
      provider: provider,
      label: s('label') ?? '',
      fields: {
        for (final e in fields.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      spaceId: s('space') ?? kCloudTreeSpace,
      crateId: s('crate'),
      identityId: s('identity'),
      groupName: s('group'),
      preferPrivate: json['private'] == true,
      checkedAt: DateTime.tryParse(s('checked') ?? ''),
      found: json['found'] is int ? json['found'] as int : null,
      problem: CloudErrorKind.values.where((k) => k.name == json['problem']).firstOrNull,
      problemDetail: s('detail'),
    );
  }
}

/// The kept accounts in this device's secure storage, with their tokens:
/// sealed while the encrypting lock is on (AccountSecret; before,
/// kept as they were, so whatever read that storage used those accounts
/// without the PIN).
class CloudAccountStore {
  CloudAccountStore(this._storage, {AppDatabase? Function()? tree}) : _tree = tree ?? (() => SecretSeal.openTree);

  static String get key => AccountSecret.cloudImports.slot;
  final FlutterSecureStorage _storage;

  /// Your Tree's database, whose seal keeps the accounts; none while the app
  /// is locked.
  final AppDatabase? Function() _tree;

  /// The kept accounts. Throws [SecretSealBroken] where they are sealed and
  /// the app is locked, so that nothing writes them over as if there were
  /// none.
  Future<List<CloudAccount>> load() async {
    final raw = await AccountSecret.cloudImports.readOrThrow(_storage, tree: _tree);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      return [
        if (list is List)
          for (final a in list) ?CloudAccount.fromJson(a),
      ];
    } on FormatException {
      return const [];
    }
  }

  Future<void> save(List<CloudAccount> accounts) async {
    if (accounts.isEmpty) {
      await AccountSecret.cloudImports.delete(_storage);
    } else {
      await AccountSecret.cloudImports
          .write(_storage, jsonEncode([for (final a in accounts) a.toJson()]), tree: _tree);
    }
  }
}

/// What a check of a kept account does unattended: adds new machines that
/// look like they run SSH, updates moved ones and marks gone ones. It never
/// links a host that happens to share an address (that is the person's call,
/// in the import screens), and never adds phones or Windows.
Iterable<CloudRow> unattendedRows(List<CloudRow> rows) => rows.where((r) =>
    r.status == CloudRowStatus.fresh || r.status == CloudRowStatus.changed || r.status == CloudRowStatus.gone);

/// Checks [account] against [db]: scans (with [scan]) and applies
/// [unattendedRows].
Future<({CloudImportOutcome outcome, int found})> checkCloudAccount(
  CloudAccount account,
  AppDatabase db, {
  Future<List<CloudMachine>> Function(CloudProvider, Map<String, String>) scan = scanCloud,
  DateTime Function() now = DateTime.now,
}) async {
  final machines = await scan(account.provider, account.fields);
  final rows = planCloudImport(
    provider: account.provider,
    machines: machines,
    hosts: await cloudExistingHosts(db),
    label: account.label,
    preferPrivate: account.preferPrivate,
  );
  final outcome = await applyCloudImport(
    CloudImportTarget(
      db: db,
      label: account.label,
      crateId: account.crateId,
      identityId: account.identityId,
      groupName: account.groupName,
      preferPrivate: account.preferPrivate,
    ),
    unattendedRows(rows),
    now: now,
  );
  return (outcome: outcome, found: machines.length);
}

/// How often a kept account is checked.
const kCloudCheckEvery = Duration(minutes: 30);

/// The kept accounts, and the checks. Watched by the Cloud accounts list;
/// [start] runs at unlock, [stop] at lock.
class CloudAccountsController extends StateNotifier<List<CloudAccount>> {
  CloudAccountsController(
    this._ref,
    this._store, {
    Future<List<CloudMachine>> Function(CloudProvider, Map<String, String>)? scan,
    DateTime Function()? now,
  })  : _scan = scan ?? scanCloud,
        _now = now ?? DateTime.now,
        super(const []) {
    unawaited(reload());
  }

  final Ref _ref;
  final CloudAccountStore _store;
  final Future<List<CloudMachine>> Function(CloudProvider, Map<String, String>) _scan;
  final DateTime Function() _now;
  Timer? _timer;
  Timer? _first;
  Future<void>? _running;

  Future<void> reload() async {
    try {
      final loaded = await _store.load();
      if (mounted) state = loaded;
    } on SecretSealBroken {
      // Sealed and the app locked: read again at the unlock ([start]).
    } catch (e) {
      AppLogger.warning('Cloud accounts could not be read: $e');
    }
  }

  /// Keeps [account] (or replaces the one with its id).
  Future<void> keep(CloudAccount account) async {
    final next = [for (final a in await _store.load()) if (a.id != account.id) a, account];
    await _store.save(next);
    if (mounted) state = next;
  }

  /// Stops checking an account and deletes its token from this device. The
  /// hosts it imported stay, still marked where they came from.
  Future<void> forget(String id) async {
    final next = [for (final a in await _store.load()) if (a.id != id) a];
    await _store.save(next);
    if (mounted) state = next;
  }

  /// Checks every kept account now, one at a time; a second call while one
  /// runs waits for it instead of checking twice.
  Future<void> checkAll() => _running ??= _checkAll().whenComplete(() => _running = null);

  Future<void> _checkAll() async {
    final List<CloudAccount> kept;
    try {
      kept = await _store.load();
    } on SecretSealBroken {
      // Locked meanwhile: checked again after the unlock.
      return;
    }
    for (final a in kept) {
      await checkOne(a.id);
    }
  }

  /// The checks running or waiting, by account: "Check now" while the timed
  /// check has the same account in hand waits for that one.
  final _checking = <String, Future<CloudImportOutcome?>>{};

  /// The last check started: each waits for the one before, so no two plan
  /// against the same hosts before either wrote (both would add every new
  /// machine).
  Future<void> _queue = Future<void>.value();

  /// Checks one account and records how it went. Returns what it did, or
  /// null when it could not run (its space is not open here, or it is gone).
  /// Checks run one at a time; asked for an account whose check is running
  /// or waiting, it returns that check.
  Future<CloudImportOutcome?> checkOne(String id) {
    final running = _checking[id];
    if (running != null) return running;
    final check = _queue.then((_) => _checkOne(id));
    _queue = check.then<void>((_) {}, onError: (Object _) {});
    _checking[id] = check;
    return check.whenComplete(() {
      if (identical(_checking[id], check)) _checking.remove(id);
    });
  }

  Future<CloudImportOutcome?> _checkOne(String id) async {
    final List<CloudAccount> kept;
    try {
      kept = await _store.load();
    } on SecretSealBroken {
      return null;
    }
    final account = kept.where((a) => a.id == id).firstOrNull;
    if (account == null) return null;
    final space = account.space;
    if (space is OrchardSpace && kOrchardsEnabled && !await _ref.read(orchardDatabasesProvider.notifier).isHere(space.orchardId)) {
      // Its team left this device (left, removed, or deleted).
      // Opening it would make its database anew, empty, for hosts nobody
      // sees: the account goes with the team.
      AppLogger.info('Cloud account ${account.provider.name}: its team left this device, and the account with it');
      await forget(account.id);
      return null;
    }
    final AppDatabase? db;
    try {
      db = await _databaseFor(space);
    } catch (e) {
      AppLogger.warning('Cloud account ${account.provider.name}: its space is not open: $e');
      return null;
    }
    if (db == null) return null;
    CloudAccount after;
    CloudImportOutcome? outcome;
    try {
      final result = await checkCloudAccount(account, db, scan: _scan, now: _now);
      outcome = result.outcome;
      final refused = outcome.failures.isEmpty
          ? null
          : outcome.failures.map((f) => '${f.name}: ${f.error}').join('\n');
      after = account.checked(
        at: _now(),
        found: result.found,
        problem: refused == null ? null : CloudErrorKind.notAllowed,
        detail: refused,
      );
    } on CloudError catch (e) {
      after = account.checked(problem: e.kind, detail: e.detail);
    } catch (e) {
      after = account.checked(problem: CloudErrorKind.answer, detail: '$e');
    }
    // Written back only if the account is still kept (forgetting during a
    // check must not bring it back), and only while they can be read (the
    // app locked during the check: the next check says how it went).
    final List<CloudAccount> all;
    try {
      all = await _store.load();
    } on SecretSealBroken {
      return outcome;
    }
    if (all.any((a) => a.id == id)) {
      final next = [for (final a in all) a.id == id ? after : a];
      await _store.save(next);
      if (mounted) state = next;
    }
    return outcome;
  }

  Future<AppDatabase?> _databaseFor(Space space) async {
    if (space is OrchardSpace) {
      if (!kOrchardsEnabled) return null;
      return _ref.read(orchardDatabasesProvider.notifier).open(space.orchardId);
    }
    return _ref.read(databaseSessionProvider);
  }

  /// Checks a minute after unlock, then every [kCloudCheckEvery]; nothing
  /// runs when nothing is kept.
  void start() {
    // Read again: what was kept could not be read while the app was locked.
    unawaited(reload());
    _timer ??= Timer.periodic(kCloudCheckEvery, (_) => unawaited(checkAll()));
    _first ??= Timer(const Duration(minutes: 1), () => unawaited(checkAll()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _first?.cancel();
    _first = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

final cloudAccountStoreProvider = Provider<CloudAccountStore>((ref) => CloudAccountStore(ref.watch(secureStorageProvider)));

final cloudAccountsProvider = StateNotifierProvider<CloudAccountsController, List<CloudAccount>>(
    (ref) => CloudAccountsController(ref, ref.watch(cloudAccountStoreProvider)));
