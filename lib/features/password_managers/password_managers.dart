import 'dart:convert';
import 'dart:io';

import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';

// Fetching a password from the person's password manager when connecting
// (3.0): used once by the caller and never kept here. What unlocks
// a manager that needs it (Bitwarden's session, KeePassXC's database
// password) is kept in memory only, until ZestSSH locks ([lock]).

/// This device's password manager settings: set once, never synced.
class PasswordManagerSettings {
  const PasswordManagerSettings({this.paths = const {}, this.keePassXc});

  /// A tool's path when it is not where ZestSSH looks.
  final Map<PasswordManagerKind, String> paths;

  /// KeePassXC's database on this device.
  final KeePassXcDatabase? keePassXc;
}

/// Asks the person for what unlocks [kind]: Bitwarden's master password or
/// KeePassXC's database password. [again] after a wrong one. Null when they
/// cancel.
typedef PmAskUnlock = Future<String?> Function(PasswordManagerKind kind, {required bool again});

/// What a password manager says an item is, for the person to check before
/// its password goes to a host.
class PasswordRefDescription {
  const PasswordRefDescription({required this.title, this.where, this.username});

  /// The item's name as the manager has it.
  final String title;

  /// The vault, or the database and group.
  final String? where;
  final String? username;
}

/// An item a password can come from, as a picker lists it.
class PasswordManagerItem {
  const PasswordManagerItem({required this.title, required this.ref, this.where, this.username, this.url});

  final String title;

  /// The vault, or the group in the database.
  final String? where;
  final String? username;

  /// The item's address, when the manager lists one (1Password's primary
  /// URL, Bitwarden's first).
  final String? url;

  /// What the key keeps.
  final PasswordRef ref;
}

class PasswordManagers {
  PasswordManagers({
    PmProcessRunner runner = const SystemPmProcessRunner(),
    required PasswordManagerSettings Function() settings,
    Map<String, String>? environment,
    bool Function(String path)? exists,
    List<String> Function(String dir)? listDir,
    bool? isWindows,
    bool? isMacOS,
    this.timeout = const Duration(seconds: 120),
  })  : _runner = runner,
        _settings = settings,
        _environment = environment ?? Platform.environment,
        _exists = exists ?? ((p) => File(p).existsSync()),
        _listDir = listDir ?? (exists == null ? _foldersIn : (_) => const []),
        _isWindows = isWindows ?? Platform.isWindows,
        _isMacOS = isMacOS ?? Platform.isMacOS;

  final PmProcessRunner _runner;
  final PasswordManagerSettings Function() _settings;
  final Map<String, String> _environment;
  final bool Function(String path) _exists;
  final List<String> Function(String dir) _listDir;
  final bool _isWindows;
  final bool _isMacOS;

  /// The names of the folders in [dir] on this device; none where it is not
  /// there or cannot be read.
  static List<String> _foldersIn(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return const [];
      return [
        for (final e in d.listSync(followLinks: false))
          if (e is Directory) e.uri.pathSegments.where((s) => s.isNotEmpty).last,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Whether [path] is a tool this device would run, by the same check as a
  /// path found ([passwordManagerToolRunnable]): a path the person chose is
  /// kept only when it passes.
  bool runnable(String path) => passwordManagerToolRunnable(path.trim(), exists: _exists, isWindows: _isWindows);

  /// What a tool's file is called on this device (`op.exe` on Windows).
  String toolFileName(PasswordManagerKind kind) {
    final name = switch (kind) {
      PasswordManagerKind.onePassword => 'op',
      PasswordManagerKind.bitwarden => 'bw',
      PasswordManagerKind.keePassXc => 'keepassxc-cli',
    };
    return _isWindows ? '$name.exe' : name;
  }

  /// The system this device runs, as the setup's install line is chosen:
  /// 'windows', 'macos' or 'linux'.
  String get platform => _isWindows ? 'windows' : (_isMacOS ? 'macos' : 'linux');

  /// How long a tool may take (a fingerprint prompt waiting on the person).
  final Duration timeout;

  String? _bitwardenSession;
  String? _keePassXcPassword;

  /// Whether this device can use password managers' tools at all.
  static bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// Forgets what unlocks the managers (ZestSSH locked, or signed out).
  void lock() {
    _bitwardenSession = null;
    _keePassXcPassword = null;
  }

  /// Whether a manager is unlocked for this run (tests).
  bool get unlockedForTests => _bitwardenSession != null || _keePassXcPassword != null;

  /// Where [kind]'s tool is on this device, or null.
  String? toolPath(PasswordManagerKind kind) => findPasswordManagerCli(kind,
      configured: _settings().paths[kind],
      environment: _environment,
      exists: _exists,
      listDir: _listDir,
      isWindows: _isWindows,
      isMacOS: _isMacOS);

  String _tool(PasswordManagerKind kind) =>
      toolPath(kind) ?? (throw const PasswordManagerException(PmFailure.notInstalled));

  Future<PmProcessResult> _run(PasswordManagerKind kind, List<String> args,
          {Map<String, String> environment = const {}, String? stdin}) =>
      _runner.run(_tool(kind), args, environment: environment, stdin: stdin, timeout: timeout);

  PasswordManagerException _failure(PasswordManagerKind kind, PmProcessResult r) =>
      PasswordManagerException(classifyFailure(kind, r.stderr), details: _details(r.stderr));

  /// What a tool said as its error, short (it is shown and can be copied).
  static String? _details(String stderr) {
    final s = stderr.trim();
    if (s.isEmpty) return null;
    return s.length > 600 ? '${s.substring(0, 600)}...' : s;
  }

  /// [ref]'s password, fetched now. [ask] unlocks a manager that needs it.
  Future<String> fetch(PasswordRef ref, {required PmAskUnlock ask}) => switch (ref.kind) {
        PasswordManagerKind.onePassword => _fetchOnePassword(ref),
        PasswordManagerKind.bitwarden => _fetchBitwarden(ref, ask),
        PasswordManagerKind.keePassXc => _fetchKeePassXc(ref, ask),
      };

  Future<String> _fetchOnePassword(PasswordRef ref) async {
    final r = await _run(PasswordManagerKind.onePassword, fetchArgs(ref));
    if (r.exitCode != 0) throw _failure(PasswordManagerKind.onePassword, r);
    return passwordFromOutput(r.stdout);
  }

  Map<String, String> get _bitwardenEnv => {
        'BW_NOINTERACTION': 'true',
        'BW_SESSION': ?_bitwardenSession,
      };

  /// Unlocks Bitwarden's CLI with the master password the person types: the
  /// session it gives back is kept in memory until [lock].
  Future<void> _unlockBitwarden(PmAskUnlock ask) async {
    var again = false;
    for (var tries = 0; tries < 3; tries++) {
      final password = await ask(PasswordManagerKind.bitwarden, again: again);
      if (password == null) throw const PasswordManagerException(PmFailure.cancelled);
      // Handed over in the environment of this one run, never as an
      // argument (others on the machine can read those).
      final r = await _run(PasswordManagerKind.bitwarden, const ['unlock', '--passwordenv', 'ZESTSSH_BW_PASSWORD', '--raw'],
          environment: {'BW_NOINTERACTION': 'true', 'ZESTSSH_BW_PASSWORD': password});
      if (r.exitCode == 0 && r.stdout.trim().isNotEmpty) {
        _bitwardenSession = r.stdout.trim();
        return;
      }
      final failure = classifyFailure(PasswordManagerKind.bitwarden, r.stderr);
      if (failure != PmFailure.wrongPassword) throw PasswordManagerException(failure, details: _details(r.stderr));
      again = true;
    }
    throw const PasswordManagerException(PmFailure.wrongPassword);
  }

  Future<String> _fetchBitwarden(PasswordRef ref, PmAskUnlock ask) async {
    if (_bitwardenSession == null) await _unlockBitwarden(ask);
    var synced = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      final r = await _run(PasswordManagerKind.bitwarden, fetchArgs(ref), environment: _bitwardenEnv);
      if (r.exitCode == 0) return passwordFromOutput(r.stdout);
      final failure = classifyFailure(PasswordManagerKind.bitwarden, r.stderr);
      if (failure == PmFailure.locked) {
        _bitwardenSession = null;
        await _unlockBitwarden(ask);
      } else if (failure == PmFailure.notFound && !synced) {
        // Items added since the CLI last synced are not there yet.
        synced = true;
        await _run(PasswordManagerKind.bitwarden, const ['sync'], environment: _bitwardenEnv);
      } else {
        throw PasswordManagerException(failure, details: _details(r.stderr));
      }
    }
    throw const PasswordManagerException(PmFailure.failed);
  }

  KeePassXcDatabase _database() =>
      _settings().keePassXc ?? (throw const PasswordManagerException(PmFailure.noDatabase));

  /// Runs keepassxc-cli with the database password on its input: asked for
  /// once, kept in memory until [lock], asked again when it is wrong.
  Future<PmProcessResult> _runKeePassXc(List<String> args, PmAskUnlock ask) async {
    final db = _database();
    var again = false;
    for (var tries = 0; tries < 3; tries++) {
      String? password;
      if (!db.noPassword) {
        password = _keePassXcPassword ??= await ask(PasswordManagerKind.keePassXc, again: again);
        if (password == null) throw const PasswordManagerException(PmFailure.cancelled);
      }
      final r = await _run(PasswordManagerKind.keePassXc, args, stdin: password == null ? '' : '$password\n');
      if (r.exitCode == 0) return r;
      final failure = classifyFailure(PasswordManagerKind.keePassXc, r.stderr);
      if (failure != PmFailure.wrongPassword || db.noPassword) return r;
      _keePassXcPassword = null;
      again = true;
    }
    throw const PasswordManagerException(PmFailure.wrongPassword);
  }

  Future<String> _fetchKeePassXc(PasswordRef ref, PmAskUnlock ask) async {
    final r = await _runKeePassXc(fetchArgs(ref, database: _database()), ask);
    if (r.exitCode != 0) throw _failure(PasswordManagerKind.keePassXc, r);
    return passwordFromOutput(r.stdout);
  }

  /// What the manager says [ref] is (never what a synced label claims), for
  /// the person's yes before its password first goes to a host. Only names:
  /// nothing secret is kept from the answer.
  Future<PasswordRefDescription> describe(PasswordRef ref, {required PmAskUnlock ask}) async {
    switch (ref.kind) {
      case PasswordManagerKind.onePassword:
        // The reference names the vault and the item as op resolves them;
        // an item given by its id is looked up by name (the list holds no
        // secrets).
        final parts = ref.target.substring('op://'.length).split('/');
        if (!_opId.hasMatch(parts[1])) return PasswordRefDescription(title: parts[1], where: parts[0]);
        final r = await _run(PasswordManagerKind.onePassword, ['item', 'list', '--vault=${parts[0]}', '--format=json']);
        if (r.exitCode != 0) throw _failure(PasswordManagerKind.onePassword, r);
        final Object? items;
        try {
          items = jsonDecode(r.stdout);
        } on FormatException {
          throw const PasswordManagerException(PmFailure.failed);
        }
        for (final item in items is List ? items : const []) {
          if (item is Map && item['id'] == parts[1]) {
            final vault = item['vault'];
            return PasswordRefDescription(
              title: item['title'] is String ? item['title'] as String : parts[1],
              where: vault is Map && vault['name'] is String ? vault['name'] as String : parts[0],
            );
          }
        }
        throw const PasswordManagerException(PmFailure.notFound);
      case PasswordManagerKind.bitwarden:
        if (_bitwardenSession == null) await _unlockBitwarden(ask);
        final r = await _run(PasswordManagerKind.bitwarden, ['get', 'item', ref.target], environment: _bitwardenEnv);
        if (r.exitCode != 0) throw _failure(PasswordManagerKind.bitwarden, r);
        final item = _json(r.stdout);
        final login = item?['login'];
        return PasswordRefDescription(
          title: item?['name'] is String ? item!['name'] as String : ref.target,
          username: login is Map && login['username'] is String ? login['username'] as String : null,
        );
      case PasswordManagerKind.keePassXc:
        return PasswordRefDescription(title: ref.target, where: _database().path);
    }
  }

  /// [kind]'s items a password can come from, for the person to pick one:
  /// names, where they are and user names, never a password. 1Password and
  /// KeePassXC list names only. Bitwarden's tool has no way to list without
  /// the items' contents, so it is only ever asked for what matches
  /// [search], and everything but the names is dropped as it is read.
  Future<List<PasswordManagerItem>> listItems(PasswordManagerKind kind,
      {String search = '', required PmAskUnlock ask}) async {
    final query = search.trim().toLowerCase();
    bool matches(PasswordManagerItem i) =>
        query.isEmpty ||
        i.title.toLowerCase().contains(query) ||
        (i.where?.toLowerCase().contains(query) ?? false) ||
        (i.username?.toLowerCase().contains(query) ?? false);
    switch (kind) {
      case PasswordManagerKind.onePassword:
        final r = await _run(kind, const ['item', 'list', '--format=json']);
        if (r.exitCode != 0) throw _failure(kind, r);
        final items = <PasswordManagerItem>[];
        for (final item in _jsonList(r.stdout)) {
          if (item is! Map) continue;
          final id = item['id'], title = item['title'], vault = item['vault'];
          if (id is! String || title is! String || vault is! Map) continue;
          final vaultName = vault['name'] is String ? vault['name'] as String : null;
          final vaultId = vault['id'] is String ? vault['id'] as String : null;
          // By name when both names use only what 1Password's references
          // allow (what the person sees is what op resolves); by id when not,
          // so a name holding a slash can never name another item.
          final byName = vaultName != null && _opName.hasMatch(vaultName) && _opName.hasMatch(title);
          final ref = byName
              ? PasswordRef.onePassword('op://$vaultName/$title/password')
              : (vaultId == null ? null : PasswordRef.onePassword('op://$vaultId/$id/password'));
          if (ref == null) continue;
          final info = item['additional_information'];
          String? url;
          final urls = item['urls'];
          if (urls is List) {
            for (final u in urls) {
              if (u is Map && u['href'] is String && (url == null || u['primary'] == true)) url = u['href'] as String;
            }
          }
          items.add(PasswordManagerItem(
              title: title,
              where: vaultName,
              username: info is String && info.isNotEmpty ? info : null,
              url: url,
              ref: ref));
        }
        return [for (final i in items) if (matches(i)) i]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case PasswordManagerKind.bitwarden:
        if (query.isEmpty) return const [];
        if (_bitwardenSession == null) await _unlockBitwarden(ask);
        final r = await _run(kind, ['list', 'items', '--search=${search.trim()}'], environment: _bitwardenEnv);
        if (r.exitCode != 0) throw _failure(kind, r);
        final items = <PasswordManagerItem>[];
        for (final item in _jsonList(r.stdout)) {
          if (item is! Map) continue;
          final id = item['id'], name = item['name'], login = item['login'];
          // Only items with a login hold a password.
          if (id is! String || name is! String || login is! Map) continue;
          final ref = PasswordRef.bitwarden(id);
          if (ref == null) continue;
          final uris = login['uris'];
          final first = uris is List && uris.isNotEmpty && uris.first is Map ? (uris.first as Map)['uri'] : null;
          items.add(PasswordManagerItem(
              title: name,
              username: login['username'] is String ? login['username'] as String : null,
              url: first is String ? first : null,
              ref: ref));
        }
        return items;
      case PasswordManagerKind.keePassXc:
        final db = _database();
        final r = await _runKeePassXc(
            [
              'ls',
              '--quiet',
              '--recursive',
              '--flatten',
              if (db.keyFile case final key?) ...['--key-file', key],
              if (db.noPassword) '--no-password',
              '--',
              db.path,
            ],
            ask);
        if (r.exitCode != 0) throw _failure(kind, r);
        final items = <PasswordManagerItem>[];
        for (final line in const LineSplitter().convert(r.stdout)) {
          final entry = line.trim();
          // Groups end with a slash; the recycle bin holds deleted entries.
          if (entry.isEmpty || entry.endsWith('/') || entry.startsWith('Recycle Bin/')) continue;
          final ref = PasswordRef.keePassXc(entry);
          if (ref == null) continue;
          final slash = entry.lastIndexOf('/');
          items.add(PasswordManagerItem(
              title: slash < 0 ? entry : entry.substring(slash + 1),
              where: slash < 0 ? null : entry.substring(0, slash),
              ref: ref));
        }
        return [for (final i in items) if (matches(i)) i];
    }
  }

  /// 1Password's vaults, for choosing where a moved password goes: names and
  /// ids only.
  Future<List<({String id, String name})>> onePasswordVaults() async {
    final r = await _run(PasswordManagerKind.onePassword, const ['vault', 'list', '--format=json']);
    if (r.exitCode != 0) throw _failure(PasswordManagerKind.onePassword, r);
    return [
      for (final v in _jsonList(r.stdout))
        if (v is Map && v['id'] is String && v['name'] is String && _opId.hasMatch(v['id'] as String))
          (id: v['id'] as String, name: v['name'] as String),
    ];
  }

  /// Puts [password] into [kind] as a new item (moving a saved password out
  /// of ZestSSH) and gives back the reference to it. The password goes
  /// to the tool on its input, never as an argument (others on the machine
  /// can read those): 1Password takes a JSON template, Bitwarden an encoded
  /// item, KeePassXC the entry's password after the database's. [vaultId]
  /// is 1Password's vault; [entryPath] KeePassXC's new entry.
  Future<PasswordRef> store(
    PasswordManagerKind kind, {
    required String title,
    required String username,
    required String password,
    String? url,
    String? vaultId,
    String? entryPath,
    required PmAskUnlock ask,
  }) async {
    switch (kind) {
      case PasswordManagerKind.onePassword:
        if (vaultId == null || !_opId.hasMatch(vaultId)) throw const PasswordManagerException(PmFailure.notFound);
        final template = jsonEncode({
          'title': title,
          'category': 'LOGIN',
          'fields': [
            {'id': 'username', 'type': 'STRING', 'purpose': 'USERNAME', 'label': 'username', 'value': username},
            {'id': 'password', 'type': 'CONCEALED', 'purpose': 'PASSWORD', 'label': 'password', 'value': password},
          ],
          if (url != null) 'urls': [{'href': url, 'primary': true}],
        });
        final r = await _run(kind, ['item', 'create', '-', '--vault=$vaultId', '--format=json'], stdin: template);
        if (r.exitCode != 0) throw _failure(kind, r);
        final item = _json(r.stdout);
        final id = item?['id'];
        final ref = id is String && _opId.hasMatch(id) ? PasswordRef.onePassword('op://$vaultId/$id/password') : null;
        return ref ?? (throw const PasswordManagerException(PmFailure.failed));
      case PasswordManagerKind.bitwarden:
        if (_bitwardenSession == null) await _unlockBitwarden(ask);
        final item = base64.encode(utf8.encode(jsonEncode({
          'type': 1,
          'name': title,
          'notes': null,
          'favorite': false,
          'fields': const [],
          'login': {
            'username': username,
            'password': password,
            'totp': null,
            'uris': [if (url != null) {'match': null, 'uri': url}],
          },
          'reprompt': 0,
        })));
        final r = await _run(kind, const ['create', 'item'], environment: _bitwardenEnv, stdin: item);
        if (r.exitCode != 0) throw _failure(kind, r);
        final id = _json(r.stdout)?['id'];
        final ref = id is String ? PasswordRef.bitwarden(id) : null;
        return ref ?? (throw const PasswordManagerException(PmFailure.failed));
      case PasswordManagerKind.keePassXc:
        final ref = entryPath == null ? null : PasswordRef.keePassXc(entryPath);
        if (ref == null) throw const PasswordManagerException(PmFailure.notFound);
        final db = _database();
        final args = [
          'add',
          '--quiet',
          // One argument each, so a value can never read as an option.
          '--username=$username',
          if (url != null) '--url=$url',
          '--password-prompt',
          if (db.keyFile case final key?) ...['--key-file', key],
          if (db.noPassword) '--no-password',
          '--',
          db.path,
          ref.target,
        ];
        // The database's password first (asked for once), then the entry's.
        var again = false;
        for (var tries = 0; tries < 3; tries++) {
          String? unlock;
          if (!db.noPassword) {
            unlock = _keePassXcPassword ??= await ask(PasswordManagerKind.keePassXc, again: again);
            if (unlock == null) throw const PasswordManagerException(PmFailure.cancelled);
          }
          final r = await _run(kind, args, stdin: '${unlock == null ? '' : '$unlock\n'}$password\n');
          if (r.exitCode == 0) return ref;
          final failure = classifyFailure(kind, r.stderr);
          if (failure != PmFailure.wrongPassword || db.noPassword) throw PasswordManagerException(failure, details: _details(r.stderr));
          _keePassXcPassword = null;
          again = true;
        }
        throw const PasswordManagerException(PmFailure.wrongPassword);
    }
  }

  static List<Object?> _jsonList(String s) {
    try {
      final v = jsonDecode(s);
      return v is List ? v : const [];
    } on FormatException {
      return const [];
    }
  }

  /// A 1Password id (vaults and items): 26 lowercase letters and digits.
  static final RegExp _opId = RegExp(r'^[a-z0-9]{26}$');

  /// A name 1Password's secret references take as it is: letters, digits,
  /// spaces, dots, dashes and underscores, not starting with a dash or a
  /// space.
  static final RegExp _opName = RegExp(r'^[A-Za-z0-9._][A-Za-z0-9 ._-]*$');

  static Map<String, Object?>? _json(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, Object?> ? v : null;
    } on FormatException {
      return null;
    }
  }
}
