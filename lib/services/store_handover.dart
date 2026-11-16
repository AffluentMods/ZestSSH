/// One ZestSSH per Windows PC, the Microsoft Store's preferred.
/// A PC with only the website's copy keeps it as
/// it is. Once the Store's copy is on the PC it wins:
///
///  * the website's copy, when it starts, hands its data over to the Store's
///    ([StoreHandover.handOver]) and opens it in its place, where the Store's
///    is at least its own version
///    (store_handover_version.dart);
///  * the Store's copy takes that data in ([StoreHandover.takeIn]), asking which to
///    keep where it holds data of its own that is not the same, and then removes the
///    website's copy with that copy's own uninstaller
///    ([StoreHandover.removeWebsiteCopy]), where the website's is at most its own
///    version; a newer website copy it leaves as it is, and opens in its place
///    (store_handover_start.dart);
///  * the website installer opens the Store's copy instead of installing, on
///    the same version rule (installer/zestssh_setup.iss).
///
/// Why a hand-over folder:
/// Windows gives a packaged app the real AppData folders that
/// already exist, and a private copy of those it creates first. With the website's
/// copy installed first, the Store's copy reads and writes the website copy's real
/// files, and nothing has to move. With the Store's copy first, its private copy of
/// the same folders hides the website copy's real files from it. A folder neither
/// copy uses ([handoverFolder]), written by the website's copy outside any package,
/// is one the Store's copy can read either way.
///
/// What is set aside (the data the person did not keep, a hand-over out of
/// date or not whole) is a full copy of hosts, keys and passwords: it is kept
/// [setAsideKept], then deleted ([ageOut]), and Delete all local data deletes it
/// at once with a hand-over still waiting ([leftovers]; found in a security
/// review).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/utils/error_kind.dart' show errorKind;
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/windows_registry.dart';

/// What the Store's copy did with a hand-over.
enum HandoverTaken {
  /// There was none waiting, or none it could take: one out of date, or not
  /// whole, is set aside instead.
  none,

  /// The website copy held no data: there was nothing to take, and it has been heard from.
  empty,

  /// It held no data of its own: the website copy's is now its.
  takenIn,

  /// It held the very same data (the website copy's own files, shared): nothing moved.
  same,

  /// Both held data; the person kept the website copy's, and the Store copy's was set aside.
  keptWebsite,

  /// Both held data; the person kept the Store copy's, and the hand-over was put away.
  keptStore,
}

/// The website's copy as it is installed: its program, the uninstaller beside
/// it, and whether it is installed for every account on the PC.
typedef WebsiteCopy = ({File program, File uninstaller, bool forAllAccounts});

/// Reads [value] of the website installer's uninstall entry
/// ([StoreHandover.uninstallKey]) for this Windows account, or ([allAccounts])
/// for the PC; null where there is none.
typedef UninstallEntryReader =
    String? Function(String value, {required bool allAccounts});

class StoreHandover {
  StoreHandover({
    required this.localAppData,
    required this.appData,
    this.programFiles,
    this.readUninstallEntry,
  });

  /// From this process's environment ([Platform.environment]) and the registry.
  factory StoreHandover.here() => StoreHandover(
    localAppData: Platform.environment['LOCALAPPDATA'] ?? '',
    appData: Platform.environment['APPDATA'] ?? '',
    programFiles: Platform.environment['ProgramFiles'],
    readUninstallEntry: _readUninstallEntry,
  );

  /// `%LOCALAPPDATA%` and `%APPDATA%` as this process sees them.
  final String localAppData;
  final String appData;

  /// `%ProgramFiles%`, where the website's copy installed for every account
  /// is by default; null: not looked in.
  final String? programFiles;

  /// Reads the website installer's uninstall entry; null: none is read.
  final UninstallEntryReader? readUninstallEntry;

  /// The Store package's family name (Partner Center's identity, 30 October 2026)
  /// and its application's id (the msix tool's: the pubspec name).
  static const packageFamily = 'AffluentLabs.ZestSSH_a13075jvne08e';
  static const appId = 'zestssh';

  /// What starts the Store's copy from outside it.
  static const appsFolderTarget = 'shell:AppsFolder\\$packageFamily!$appId';

  /// The website installer's uninstall entry, by its AppId
  /// (installer/zestssh_setup.iss, [Setup] AppId; Inno adds _is1): in
  /// HKEY_CURRENT_USER for one Windows account, HKEY_LOCAL_MACHINE for all.
  static const uninstallKey =
      r'Software\Microsoft\Windows\CurrentVersion\Uninstall\{F47AC10B-58CC-4372-A567-0E02B2C3D479}_is1';

  /// How long what is set aside is kept before it is deleted ([ageOut]).
  static const setAsideKept = Duration(days: 30);

  /// The folder Windows keeps for an installed package: there while it is installed.
  Directory get _packageFolder =>
      Directory(p.join(localAppData, 'Packages', packageFamily));

  /// Whether the Store's copy is installed for this Windows account.
  bool get storeCopyInstalled => _packageFolder.existsSync();

  /// The two folders ZestSSH keeps its data in on Windows (active_profile.dart
  /// [ProfilePaths.base]; getApplicationSupportDirectory with Runner.rc's names).
  Directory get localData =>
      Directory(p.join(localAppData, 'com.affluentlabs.zestssh'));
  Directory get roamingData =>
      Directory(p.join(appData, 'Affluent Labs', 'ZestSSH'));

  /// Where the website's copy leaves its data for the Store's copy.
  Directory get handoverFolder =>
      Directory(p.join(localAppData, 'ZestSSH Handover'));
  File get _ready => File(p.join(handoverFolder.path, 'ready.json'));
  Directory get _handLocal => Directory(p.join(handoverFolder.path, 'local'));
  Directory get _handRoaming =>
      Directory(p.join(handoverFolder.path, 'roaming'));

  /// Whether a hand-over is waiting, written whole.
  bool get handoverReady => _ready.existsSync();

  /// The name of the lock both copies take while one hands over or takes in
  /// (store_handover_start.dart; found in a security
  /// review): one of this Windows session's, by the hand-over
  /// folder's path, so each account's is its own.
  String get lockName =>
      'Local\\ZestSSH.Handover.${sha256.convert(utf8.encode(p.normalize(handoverFolder.path).toLowerCase())).toString().substring(0, 16)}';

  /// When the waiting hand-over was written; null where none is, or its mark
  /// says no time.
  DateTime? get handoverAt =>
      DateTime.tryParse('${_readMark()?['at'] ?? ''}')?.toLocal();

  /// When the website copy's data in the waiting hand-over was last changed:
  /// the newest of its files when it was handed over, or when it was handed
  /// over where its mark does not say. Said in the question which data to keep.
  DateTime? get handedOverLastUsed {
    final mark = _readMark();
    if (mark == null) return null;
    return (DateTime.tryParse('${mark['lastUsed'] ?? ''}') ??
            DateTime.tryParse('${mark['at'] ?? ''}'))
        ?.toLocal();
  }

  /// When this copy's own data was last changed: the newest of its files.
  /// Said in the question which data to keep.
  Future<DateTime?> ownDataLastUsed() async {
    DateTime? newest;
    for (final d in [localData, roamingData]) {
      if (!d.existsSync()) continue;
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final t = await e.lastModified();
        if (newest == null || t.isAfter(newest)) newest = t;
      }
    }
    return newest;
  }

  /// The language this copy's settings name ('app_locale', which stays in the
  /// PC's preferences: profile_preferences.dart, layered), read from the file
  /// itself: the preferences are not opened before a hand-over is taken in
  /// (store_handover_start.dart). Null where none is chosen or it cannot be read.
  String? get preferredLanguage {
    try {
      final file = File(p.join(roamingData.path, 'shared_preferences.json'));
      if (!file.existsSync()) return null;
      final all = jsonDecode(file.readAsStringSync());
      final code = all is Map ? all['flutter.app_locale'] : null;
      return code is String && code.isNotEmpty ? code : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether this PC's Store copy keeps a private copy of the data folders, which
  /// hides the website copy's real ones from it: it was installed and started
  /// before the website copy wrote any.
  bool get websiteDataHiddenFromStore =>
      Directory(
        p.join(
          _packageFolder.path,
          'LocalCache',
          'Local',
          'com.affluentlabs.zestssh',
        ),
      ).existsSync() ||
      Directory(
        p.join(
          _packageFolder.path,
          'LocalCache',
          'Roaming',
          'Affluent Labs',
          'ZestSSH',
        ),
      ).existsSync();

  // ── The website's copy ────────────────────────────────────────────────

  /// The website's copy, at its start and before it opens anything: copies its
  /// data into [handoverFolder] and marks it ready (the mark written last, so a
  /// hand-over cut short is never taken). Each copy is on the disk before the
  /// mark is written, and the mark lists every file with its SHA-256, so a copy
  /// that did not come out whole is never taken either. Its own files stay as
  /// they are. A copy with no data marks an empty hand-over: the Store's copy,
  /// which may not see this copy's folders, then knows there is nothing to wait
  /// for. Returns whether there was data to hand over.
  Future<bool> handOver({DateTime? now}) async {
    if (handoverFolder.existsSync()) {
      await handoverFolder.delete(recursive: true);
    }
    final held = _hasData(localData, roamingData);
    await handoverFolder.create(recursive: true);
    final files = <String, String>{};
    DateTime? lastUsed;
    if (held) {
      for (final (from, to, name) in [
        (localData, _handLocal, 'local'),
        (roamingData, _handRoaming, 'roaming'),
      ]) {
        final copied = await _copyTree(from, to);
        copied.hashes.forEach((rel, hash) => files['$name/$rel'] = hash);
        if (copied.newest case final t?) {
          if (lastUsed == null || t.isAfter(lastUsed)) lastUsed = t;
        }
      }
    }
    await _ready.writeAsString(
      jsonEncode({
        'at': (now ?? DateTime.now()).toUtc().toIso8601String(),
        'held': held,
        'lastUsed': lastUsed?.toUtc().toIso8601String(),
        'files': files,
      }),
      flush: true,
    );
    return held;
  }

  /// The website's copy, starting as itself: a hand-over it left before and the
  /// Store's copy did not take in is out of date from now on (this copy's data
  /// may change from here), and goes; it is a copy of this copy's own data,
  /// which stays where it is. The mark goes first, so what may be left of the
  /// folder is never taken. Returns whether there was one.
  Future<bool> withdrawHandover() async {
    if (!handoverFolder.existsSync()) return false;
    if (_ready.existsSync()) await _ready.delete();
    await handoverFolder.delete(recursive: true);
    return true;
  }

  // ── The Store's copy ──────────────────────────────────────────────────

  /// The Store's copy, at its start and before it opens anything: takes a waiting
  /// hand-over in. Where it holds data of its own that differs, [keepWebsite] is
  /// asked which to keep; what is not kept is set aside. The hand-over is gone
  /// after.
  ///
  /// A hand-over is not taken, and is set aside instead, where it is out of
  /// date (written before the website copy was last installed or updated,
  /// [websiteInstalledAt]: that copy may have run on newer data since) or not
  /// whole (a file missing, added or changed against its mark).
  Future<HandoverTaken> takeIn({
    required Future<bool> Function() keepWebsite,
    DateTime? now,
  }) async {
    _lastSetAside.clear();
    if (!handoverReady) return HandoverTaken.none;
    final stamp = _stamp(now ?? DateTime.now());
    final mark = _readMark();
    final at = DateTime.tryParse('${mark?['at'] ?? ''}');
    final installed = websiteInstalledAt;
    if (mark == null ||
        (at != null && installed != null && at.isBefore(installed))) {
      AppLogger.warning(
        'A hand-over from the website copy is out of date (written before that copy was last installed or updated) or its mark is not read: set aside, not taken in',
      );
      await _setAside(handoverFolder, stamp);
      return HandoverTaken.none;
    }
    if (mark['files'] case final Map<String, dynamic> files
        when !await _whole(files)) {
      AppLogger.warning(
        'A hand-over from the website copy is not whole: set aside, not taken in',
      );
      await _setAside(handoverFolder, stamp);
      return HandoverTaken.none;
    }
    final HandoverTaken taken;
    if (!_hasData(_handLocal, _handRoaming)) {
      taken = HandoverTaken.empty;
    } else if (!_hasData(localData, roamingData)) {
      await _takeInto(stamp, setAsideOwn: false);
      taken = HandoverTaken.takenIn;
    } else if (await _sameData(_handLocal, localData) &&
        await _sameData(_handRoaming, roamingData)) {
      taken = HandoverTaken.same;
    } else if (await keepWebsite()) {
      await _takeInto(stamp, setAsideOwn: true);
      taken = HandoverTaken.keptWebsite;
    } else {
      // The website copy's data is kept beside, for [setAsideKept].
      await _setAside(handoverFolder, stamp, chosen: true);
      return HandoverTaken.keptStore;
    }
    await handoverFolder.delete(recursive: true);
    return taken;
  }

  /// Copies the hand-over in where this copy keeps its data: first into
  /// folders beside those ("... (taking in)"), and put in place only once both
  /// came out whole. A copy cut short (a file another program holds open, a
  /// full disk, a copy that did not come out the same) throws with this
  /// copy's own data as it was and the hand-over still waiting: it had set
  /// this copy's data aside first and left it on a part copy, so that a
  /// later "keep this app's data" kept the part copy and its own data aged
  /// out of the set-aside folders ([ageOut]) after 30 days (found in a
  /// code review). [setAsideOwn]: this copy's own data is set aside as
  /// the hand-over goes in (the person kept the website copy's); it is put
  /// back where putting the hand-over in place fails.
  Future<void> _takeInto(String stamp, {required bool setAsideOwn}) async {
    final moves = [(_handLocal, localData), (_handRoaming, roamingData)];
    final stages = [for (final (_, to) in moves) Directory('${to.path} (taking in)')];
    Future<void> dropStages() async {
      for (final s in stages) {
        try {
          if (s.existsSync()) await s.delete(recursive: true);
        } catch (_) {}
      }
    }

    try {
      for (var i = 0; i < moves.length; i++) {
        if (stages[i].existsSync()) await stages[i].delete(recursive: true);
        if (moves[i].$1.existsSync()) await _copyTree(moves[i].$1, stages[i]);
      }
    } catch (_) {
      await dropStages();
      rethrow;
    }
    // A folder the hand-over goes into whole, where none was: taken out again
    // where a later step fails, as it holds nothing but the hand-over's copy.
    final made = <Directory>[];
    try {
      if (setAsideOwn) {
        await _setAside(localData, stamp, chosen: true);
        await _setAside(roamingData, stamp, chosen: true);
      }
      for (var i = 0; i < moves.length; i++) {
        if (!stages[i].existsSync()) continue;
        if (!moves[i].$2.existsSync()) made.add(moves[i].$2);
        await _moveInto(stages[i], moves[i].$2);
      }
    } catch (_) {
      for (final d in made) {
        try {
          if (d.existsSync()) await d.delete(recursive: true);
        } catch (_) {}
      }
      if (setAsideOwn) {
        for (final own in [localData, roamingData]) {
          final aside = Directory('${own.path} (set aside $stamp)');
          if (!aside.existsSync()) continue;
          try {
            if (own.existsSync()) await own.delete(recursive: true);
            await aside.rename(own.path);
            _lastSetAside.remove(p.basename(aside.path));
          } catch (_) {}
        }
      }
      await dropStages();
      rethrow;
    }
  }

  /// Puts what [stage] holds in [to]: the folder renamed where [to] is not
  /// there, else each file moved in over the one of its name.
  static Future<void> _moveInto(Directory stage, Directory to) async {
    if (!to.existsSync()) {
      await to.parent.create(recursive: true);
      await stage.rename(to.path);
      return;
    }
    await for (final e in stage.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final target = File(p.join(to.path, p.relative(e.path, from: stage.path)));
      await target.parent.create(recursive: true);
      if (target.existsSync()) await target.delete();
      await e.rename(target.path);
    }
    await stage.delete(recursive: true);
  }

  /// The names of the folders the last [takeIn] set aside, of the person's
  /// choice (what they did not keep): said to them once the app is up.
  List<String> get lastSetAside => List.unmodifiable(_lastSetAside);
  final _lastSetAside = <String>[];

  /// The website copy: where its uninstall entry says it is, for this Windows
  /// account (its installer's default) or for everyone, in whatever folder the
  /// person chose; else in the installer's default folders. Only a folder given
  /// as a whole path that holds both its program and its uninstaller counts,
  /// and where the entry names an uninstaller, only that one, in that folder.
  WebsiteCopy? get websiteCopy {
    var entry = false;
    final read = readUninstallEntry;
    for (final allAccounts in [false, true]) {
      if (read == null) break;
      String? value(String name) {
        try {
          return read(name, allAccounts: allAccounts);
        } catch (_) {
          return null;
        }
      }

      final location = value('InstallLocation');
      final appPath = value('Inno Setup: App Path');
      final uninstallString = value('UninstallString');
      if (location == null && appPath == null && uninstallString == null) {
        continue;
      }
      entry = true;
      final named = uninstallString == null ? null : _unquoted(uninstallString);
      for (final folder in [
        location,
        appPath,
        if (named != null) p.dirname(named),
      ]) {
        final copy = _copyIn(folder, allAccounts);
        if (copy == null) continue;
        // The uninstaller the entry names, where it names one: the one run.
        if (named != null &&
            !p.equals(p.normalize(named), copy.uninstaller.path)) {
          continue;
        }
        return copy;
      }
    }
    // An entry that names no such folder is believed: nothing else is run.
    if (entry) return null;
    return _copyIn(p.join(localAppData, 'Programs', 'ZestSSH'), false) ??
        (programFiles == null
            ? null
            : _copyIn(p.join(programFiles!, 'ZestSSH'), true));
  }

  /// The website copy's uninstaller ([websiteCopy]).
  File? get websiteUninstaller => websiteCopy?.uninstaller;

  /// The website copy's program, in the folder of its uninstaller
  /// ([websiteCopy]; the installer puts both in its {app} folder,
  /// installer/zestssh_setup.iss): the copy that would be removed is the one
  /// whose version the Store's copy reads, and the one it opens where that
  /// copy is newer (store_handover_start.dart).
  File? get websiteProgram => websiteCopy?.program;

  /// When the website copy was last installed or updated: its uninstall log's
  /// last write (unins000.dat, which its installer writes at every install
  /// and update). Not its program's: Inno Setup gives each file it installs
  /// the time it had when the installer was built, in the build machine's
  /// local time read as this PC's (TimeStampsInUTC is not set), so on a PC
  /// west of where it was built the program is hours "newer" than the
  /// install, and a hand-over written right after the install was taken for
  /// one written before it (found in a code review). Null where it
  /// is not installed or the log cannot be read.
  DateTime? get websiteInstalledAt {
    final copy = websiteCopy;
    if (copy == null) return null;
    try {
      final log = File(p.join(copy.uninstaller.parent.path, 'unins000.dat'));
      return log.existsSync() ? log.lastModifiedSync() : null;
    } catch (_) {
      return null;
    }
  }

  /// The program's and the uninstaller's file names (installer/zestssh_setup.iss,
  /// MyAppExeName; Inno's first uninstaller).
  static const programName = 'zestssh.exe';
  static const uninstallerName = 'unins000.exe';

  /// Whether the website's copy may go now: it is installed, and its data is in
  /// the Store's copy (it shares the real folders, or a hand-over was taken).
  bool mayRemoveWebsiteCopy({required HandoverTaken taken}) =>
      websiteCopy != null &&
      (taken != HandoverTaken.none || !websiteDataHiddenFromStore);

  /// Removes the website's copy with its own uninstaller, quietly (its data
  /// folders stay: the uninstaller deletes only its program folder). Returns
  /// whether it is gone. [run] stands in for starting the uninstaller in tests.
  Future<bool> removeWebsiteCopy({
    Future<int> Function(String exe, List<String> args)? run,
  }) async {
    final copy = websiteCopy;
    if (copy == null) return true;
    final code = await (run ?? _run)(copy.uninstaller.path, const [
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
    ]);
    if (code != 0) return false;
    // Inno's uninstaller answers when the uninstall is done (its help,
    // Uninstaller Exit Codes): the copy of itself it runs from the temporary
    // folder ends this one at the end, and then deletes this one's file, which
    // can stay a while, or until Windows restarts where something holds it
    // open. What counts is that the program is gone.
    for (var i = 0; i < 40 && copy.program.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return !copy.program.existsSync();
  }

  static Future<int> _run(String exe, List<String> args) async =>
      (await Process.run(exe, args)).exitCode;

  // ── What is set aside ─────────────────────────────────────────────────

  /// What is set aside of the hand-over, and a hand-over still waiting: full
  /// copies of the person's data, which Delete all local data deletes
  /// (local_data_wiper.dart).
  List<Directory> leftovers() => [
    if (handoverFolder.existsSync()) handoverFolder,
    for (final (d, _) in _setAsideFolders()) d,
    // A take-in cut short where the app itself stopped ([_takeInto]).
    for (final d in [localData, roamingData])
      if (Directory('${d.path} (taking in)').existsSync()) Directory('${d.path} (taking in)'),
  ];

  /// What of [leftovers] a wipe of the one profile [id] deletes (Delete all
  /// local data without Everything, on a computer). Each is a copy of the
  /// whole data folders, every profile on the PC in it: one that holds no
  /// other profile's folder goes whole; of any other only [id]'s own folder
  /// goes, and the rest stays for its people, who were told it is kept 30
  /// days. The keychain and settings in a copy are the PC's, whole, and stay
  /// with it (found in a code review: a wipe of one profile
  /// deleted another person's set-aside copy).
  List<Directory> leftoversOfProfile(String id) {
    final out = <Directory>[];
    for (final d in leftovers()) {
      final local = _localPartOf(d);
      final profiles = Directory(p.join(local.path, 'profiles'));
      final others = profiles.existsSync() &&
          profiles.listSync(followLinks: false).any((e) => e is Directory && p.basename(e.path) != id && _hasFiles(e));
      if (!others) {
        out.add(d);
        continue;
      }
      final own = Directory(p.join(profiles.path, id));
      if (own.existsSync()) out.add(own);
    }
    return out;
  }

  /// The copy of the local data folder [leftover] holds, or goes with: its
  /// `local` folder for a hand-over, itself for a copy of the local folder,
  /// and for a copy of the roaming folder the local one set aside with it.
  Directory _localPartOf(Directory leftover) {
    final name = p.basename(leftover.path);
    final local = p.basename(localData.path);
    if (name.startsWith(p.basename(handoverFolder.path))) return Directory(p.join(leftover.path, 'local'));
    if (name.startsWith(local)) return leftover;
    final m = _setAsideName.firstMatch(name);
    final stamp = m == null ? null : name.substring(m[1]!.length);
    return stamp == null
        ? Directory('${localData.path} (taking in)')
        : Directory(p.join(localAppData, '$local$stamp'));
  }

  /// Deletes what was set aside [setAsideKept] or longer ago (its name says
  /// when). Returns how many went.
  Future<int> ageOut({DateTime? now}) async {
    final limit = (now ?? DateTime.now()).toUtc().subtract(setAsideKept);
    var gone = 0;
    for (final (d, at) in _setAsideFolders()) {
      if (!at.isBefore(limit)) continue;
      try {
        await d.delete(recursive: true);
        gone++;
      } catch (e) {
        AppLogger.warning(
          'Data set aside by a hand-over was not deleted yet (${errorKind(e)})',
        );
      }
    }
    return gone;
  }

  static final _setAsideName = RegExp(
    r'^(.+) \(set aside (\d{4})-(\d{2})-(\d{2}) (\d{2})(\d{2})(\d{2})\)$',
  );

  /// The folders [_setAside] made, with when (UTC).
  List<(Directory, DateTime)> _setAsideFolders() {
    final out = <(Directory, DateTime)>[];
    for (final (parent, names) in [
      (
        Directory(localAppData),
        {p.basename(handoverFolder.path), p.basename(localData.path)},
      ),
      (roamingData.parent, {p.basename(roamingData.path)}),
    ]) {
      if (!parent.existsSync()) continue;
      final List<FileSystemEntity> entries;
      try {
        entries = parent.listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final e in entries) {
        if (e is! Directory) continue;
        final m = _setAsideName.firstMatch(p.basename(e.path));
        if (m == null || !names.contains(m[1])) continue;
        final n = [for (var i = 2; i <= 7; i++) int.parse(m[i]!)];
        out.add((e, DateTime.utc(n[0], n[1], n[2], n[3], n[4], n[5])));
      }
    }
    return out;
  }

  // ── Files ─────────────────────────────────────────────────────────────

  static bool _hasData(Directory local, Directory roaming) =>
      _hasFiles(local) ||
      File(p.join(roaming.path, 'flutter_secure_storage.dat')).existsSync();

  static bool _hasFiles(Directory d) =>
      d.existsSync() &&
      d.listSync(recursive: true, followLinks: false).any((e) => e is File);

  /// [folder] as the website copy's, where it is a whole path (a drive's or
  /// a network share's) holding both the program and the uninstaller.
  static WebsiteCopy? _copyIn(String? folder, bool forAllAccounts) {
    if (folder == null) return null;
    var dir = _unquoted(folder);
    if (!RegExp(r'^([A-Za-z]:[\\/]|\\\\[^\\/?.])').hasMatch(dir)) return null;
    dir = p.normalize(dir);
    final program = File(p.join(dir, programName));
    final uninstaller = File(p.join(dir, uninstallerName));
    if (!FileSystemEntity.isFileSync(program.path) ||
        !FileSystemEntity.isFileSync(uninstaller.path)) {
      return null;
    }
    return (
      program: program,
      uninstaller: uninstaller,
      forAllAccounts: forAllAccounts,
    );
  }

  static String _unquoted(String s) {
    final t = s.trim();
    return t.length >= 2 && t.startsWith('"') && t.endsWith('"')
        ? t.substring(1, t.length - 1).trim()
        : t;
  }

  static String? _readUninstallEntry(
    String value, {
    required bool allAccounts,
  }) {
    if (!Platform.isWindows) return null;
    if (!allAccounts) {
      return readRegistryString(RegistryRoot.currentUser, uninstallKey, value);
    }
    return readRegistryString(RegistryRoot.localMachine, uninstallKey, value) ??
        readRegistryString(RegistryRoot.localMachine32, uninstallKey, value);
  }

  Map<String, dynamic>? _readMark() {
    try {
      final mark = jsonDecode(_ready.readAsStringSync());
      return mark is Map<String, dynamic> ? mark : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether the hand-over holds just the files [files] lists, each with its
  /// SHA-256.
  Future<bool> _whole(Map<String, dynamic> files) async {
    final found = <String, String>{
      for (final e in (await _listing(_handLocal)).entries)
        'local/${e.key}': e.value,
      for (final e in (await _listing(_handRoaming)).entries)
        'roaming/${e.key}': e.value,
    };
    if (found.length != files.length) return false;
    for (final e in files.entries) {
      if (found[e.key] != e.value) return false;
    }
    return true;
  }

  /// Copies [from] into [to], each file written to the disk (flushed) and read
  /// back the same, its time of last change kept. Returns each file's SHA-256
  /// by its path inside [from] ('/' between folders), and the newest time of
  /// last change among them.
  static Future<({Map<String, String> hashes, DateTime? newest})> _copyTree(
    Directory from,
    Directory to,
  ) async {
    final hashes = <String, String>{};
    DateTime? newest;
    if (!from.existsSync()) return (hashes: hashes, newest: newest);
    await to.create(recursive: true);
    await for (final e in from.list(recursive: true, followLinks: false)) {
      final rel = p.relative(e.path, from: from.path);
      final target = p.join(to.path, rel);
      if (e is Directory) {
        await Directory(target).create(recursive: true);
      } else if (e is File) {
        await Directory(p.dirname(target)).create(recursive: true);
        final modified = await e.lastModified();
        final out = await File(target).open(mode: FileMode.write);
        try {
          await for (final chunk in e.openRead()) {
            await out.writeFrom(chunk);
          }
          await out.flush();
        } finally {
          await out.close();
        }
        await File(target).setLastModified(modified);
        final hash = await _hash(e);
        if (await _hash(File(target)) != hash) {
          throw FileSystemException('A copy did not come out the same', target);
        }
        hashes[p.split(rel).join('/')] = hash;
        if (newest == null || modified.isAfter(newest)) newest = modified;
      }
    }
    return (hashes: hashes, newest: newest);
  }

  /// Whether [a] and [b] hold the same files with the same bytes.
  static Future<bool> _sameData(Directory a, Directory b) async {
    final left = await _listing(a);
    final right = await _listing(b);
    if (left.length != right.length) return false;
    for (final e in left.entries) {
      if (right[e.key] != e.value) return false;
    }
    return true;
  }

  /// Each file's SHA-256 by its path inside [d], '/' between folders.
  static Future<Map<String, String>> _listing(Directory d) async {
    final out = <String, String>{};
    if (!d.existsSync()) return out;
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is File) {
        out[p.split(p.relative(e.path, from: d.path)).join('/')] = await _hash(
          e,
        );
      }
    }
    return out;
  }

  static Future<String> _hash(File f) async =>
      (await sha256.bind(f.openRead()).first).toString();

  /// Renames [d] to say it is set aside, and when. [chosen]: what the person
  /// chose not to keep, named to them ([lastSetAside]).
  Future<void> _setAside(
    Directory d,
    String stamp, {
    bool chosen = false,
  }) async {
    if (!d.existsSync()) return;
    final aside = '${d.path} (set aside $stamp)';
    await d.rename(aside);
    if (chosen) _lastSetAside.add(p.basename(aside));
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    final u = t.toUtc();
    return '${u.year}-${two(u.month)}-${two(u.day)} ${two(u.hour)}${two(u.minute)}${two(u.second)}';
  }
}
