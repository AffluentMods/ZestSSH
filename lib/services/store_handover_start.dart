import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/store_handover.dart';
import 'package:zestssh/services/store_handover_version.dart';
import 'package:zestssh/services/update_check_service.dart' show kStoreBuild;
import 'package:zestssh/ui/screens/error/store_handover_screen.dart';
import 'package:zestssh/utils/error_kind.dart' show errorKind;
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/windows_named_lock.dart';
import 'package:zestssh/utils/windows_programs.dart';

/// What the Store's copy has to say once it is up, about the website's copy;
/// and what the website's copy has to say about an older Store copy
/// ([storeCopyOlder]).
enum StoreHandoverNotice {
  /// The website copy was removed, and this one has its data.
  removed,

  /// The website copy was removed, and this one kept its own data, as the
  /// person chose: the website copy's is set aside.
  removedKeptStore,

  /// The website copy's uninstaller did not remove it.
  notRemoved,

  /// The website copy is installed for every account on the PC: it is left
  /// as it is, and the person is told it is there.
  forAllAccounts,

  /// The website copy's data is hidden from this one: opening it once hands it over.
  openWebsiteOnce,

  /// Said by the website copy: the Store copy is older than it.
  storeCopyOlder,
}

StoreHandoverNotice? _notice;

/// The names of the folders set aside at this start of what the person chose
/// not to keep, said once the app is up.
List<String>? _setAsideSaid;

/// The notice the start left, once: app.dart says it after the first frame.
StoreHandoverNotice? takeStoreHandoverNotice() {
  final n = _notice;
  _notice = null;
  return n;
}

/// The folders this start set aside of what the person did not keep, once:
/// app.dart names them after the first frame. Null where there were none.
List<String>? takeStoreHandoverSetAside() {
  final s = _setAsideSaid;
  _setAsideSaid = null;
  return s;
}

/// How often the Store's copy tries to remove the website's where it did not
/// go; and whether it told the person of a website copy installed for every
/// account ([StoreHandoverNotice.forAllAccounts]).
const _removeTriedKey = 'store_handover_remove_tried';
const _removeRetry = Duration(days: 1);

/// The older Store copy's version the website's copy last said needs updating:
/// said once for each, not at every start.
const _olderToldKey = 'store_handover_older_told';

/// A hand-over written this recently means the website copy has just handed
/// its start to this one: the Store copy never hands it back.
const _justHandedOver = Duration(minutes: 1);

/// How long the Store's copy waits for a hand-over that is being written.
const _lockWait = Duration(seconds: 10);

/// One ZestSSH per Windows PC, the Store's preferred (store_handover.dart), at
/// the start, before any data opens, before any window shows, and before the
/// preferences are first read: a hand-over taken in brings its own, and
/// preferences read before it would be written back over them at their first
/// change (shared_preferences_windows keeps them in memory, and writes the
/// whole file at each change).
/// Returns true where this process is to end: the website's copy has
/// handed over and the Store's opens in its place, the Store's copy has found a
/// newer website copy and that one opens in its place, or another copy is
/// handing over or taking in right now.
///
/// [rawPrefs] gives the PC's preferences: asked for only once nothing more is
/// to be taken in. [command]: started for a command on a terminal (zestssh
/// admin ...): nothing is handed over or taken in. [storeCopyVersion] stands in
/// for reading the installed Store copy's version (null: none installed),
/// [websiteCopyVersion] for reading the website copy's from its program,
/// [thisVersion] for this copy's own, [packaged] for whether this process runs
/// as a Microsoft Store package, [takeLock] for the lock both copies take
/// (given back by what it returns; null: another holds it), and
/// [openStoreCopy] and [openWebsiteCopy] for opening the other copy, in tests.
///
/// Only ZestSSH, the release, hands over or takes in ([official]; the build's
/// own flag unless a test says): a community build is not the program the
/// Store's copy is, and must neither give its data to that one, take that
/// one's, nor end to open it (found in a security audit).
Future<bool> storeHandoverAtStart({
  required Future<SharedPreferences> Function() rawPrefs,
  StoreHandover? handover,
  bool? storeBuild,
  bool? official,
  bool command = false,
  Future<void> Function()? openStoreCopy,
  Future<bool> Function()? askKeepWebsite,
  Future<int> Function(String exe, List<String> args)? runUninstaller,
  DateTime Function()? now,
  Future<String?> Function()? storeCopyVersion,
  Future<String> Function()? thisVersion,
  Future<String> Function(File program)? websiteCopyVersion,
  Future<void> Function(File program)? openWebsiteCopy,
  bool Function()? packaged,
  Future<void Function()?> Function(StoreHandover h, Duration wait)? takeLock,
}) async {
  if (!(official ?? zestOfficial)) return false;
  final h = handover ?? StoreHandover.here();
  final clock = now ?? DateTime.now;
  final lock = takeLock ?? _takeHandoverLock;
  if (!(storeBuild ?? kStoreBuild)) {
    // A build of the website's that runs as a package is the Store's copy,
    // built without ZEST_STORE=true: it would hand over to itself, and start
    // itself again, for ever. It hands nothing over.
    if ((packaged ?? runsAsPackage)()) {
      AppLogger.warning(
        'This copy runs as a Microsoft Store package but was built as the website\'s: it hands nothing over',
      );
      return false;
    }
    // Another copy on this PC is handing over or taking in right now (one
    // ZestSSH at a time, which the window's own check leaves to chance where
    // the other does not answer in time): this start ends, and leaves
    // the hand-over alone. Started for a command, it runs all the same.
    final release = await lock(h, Duration.zero);
    if (release == null) {
      AppLogger.info(
        'Another ZestSSH on this PC is handing its data over or taking it in: ${command ? 'the command runs, and the hand-over is left alone' : 'this start ends'}',
      );
      return !command;
    }
    try {
      return await _websiteCopyStarts(
        h,
        rawPrefs: rawPrefs,
        command: command,
        clock: clock,
        openStoreCopy: openStoreCopy,
        storeCopyVersion: storeCopyVersion,
        thisVersion: thisVersion,
      );
    } finally {
      release();
    }
  }
  if (command) return false;
  final release = await lock(h, _lockWait);
  if (release == null) {
    AppLogger.info(
      'Another ZestSSH on this PC is handing its data over or taking it in: this start ends',
    );
    return true;
  }
  try {
    return await _storeCopyStarts(
      h,
      rawPrefs: rawPrefs,
      clock: clock,
      askKeepWebsite: askKeepWebsite,
      runUninstaller: runUninstaller,
      thisVersion: thisVersion,
      websiteCopyVersion: websiteCopyVersion,
      openWebsiteCopy: openWebsiteCopy,
    );
  } finally {
    release();
  }
}

/// The website's copy: where the Store's is installed, at least as new, it goes to it.
Future<bool> _websiteCopyStarts(
  StoreHandover h, {
  required Future<SharedPreferences> Function() rawPrefs,
  required bool command,
  required DateTime Function() clock,
  Future<void> Function()? openStoreCopy,
  Future<String?> Function()? storeCopyVersion,
  Future<String> Function()? thisVersion,
}) async {
  await _ageOut(h, clock);
  // A hand-over this copy left before, and the Store copy did not take in, is
  // out of date from here on, whatever this start does: it starts as itself,
  // and its data may change, or it hands over again.
  // A Store copy that took it in weeks later
  // would take old data in and remove the copy that holds the new.
  try {
    if (await h.withdrawHandover()) {
      AppLogger.info(
        'A hand-over the Store copy did not take in was withdrawn',
      );
    }
  } catch (e) {
    AppLogger.warning(
      'A hand-over the Store copy did not take in was not withdrawn (${errorKind(e)})',
    );
  }
  if (command) return false;
  if (!h.storeCopyInstalled) return false;
  // Only to a Store copy at least as new as this one:
  // this copy can be a release ahead of the Store's
  // (on zestssh.com before the Store has it), and its data may already be in
  // a shape the older one cannot read (3.3's per-account profiles, for a
  // 3.2.7). An older Store copy is left alone until the Store updates it, and
  // this copy starts as it is and says so once.
  final String? store;
  final String mine;
  final bool storeIsNewEnough;
  try {
    store = await (storeCopyVersion ?? installedStoreCopyVersion)();
    mine = await (thisVersion ?? _thisVersion)();
    // A version that is not one throws here, and counts as not read.
    storeIsNewEnough =
        store != null &&
        storeCopyMayTakeOver(storeVersion: store, websiteVersion: mine);
  } catch (e) {
    // The safe side: nothing is handed over to a copy that may be older. This
    // copy starts as it would have with no Store copy, and looks again at its
    // next start; an older Store copy opening on data it cannot read is the
    // one thing this is here to prevent.
    AppLogger.warning(
      'The Store copy\'s version could not be read (${errorKind(e)}): this copy starts as it is',
    );
    return false;
  }
  if (store == null) {
    // Its folder is there, but Windows has no such package for this account
    // (a folder left behind): there is nothing to open.
    AppLogger.info(
      'No ZestSSH from the Microsoft Store is installed for this account: this copy starts as it is',
    );
    return false;
  }
  if (!storeIsNewEnough) {
    AppLogger.info(
      'ZestSSH from the Microsoft Store is $store, older than this copy ($mine): nothing is handed over until it is updated',
    );
    final prefs = await rawPrefs();
    if (prefs.getString(_olderToldKey) != store) {
      await prefs.setString(_olderToldKey, store);
      _notice = StoreHandoverNotice.storeCopyOlder;
    }
    return false;
  }
  try {
    await h.handOver();
  } catch (e) {
    // Nothing is lost: this copy starts as it would have, and offers again
    // next time. What was copied so far goes: it is never taken (no mark).
    AppLogger.warning(
      'The hand-over to the Store copy did not finish (${errorKind(e)}): this copy starts as it is',
    );
    try {
      await h.withdrawHandover();
    } catch (_) {}
    return false;
  }
  await (openStoreCopy ?? _openStoreCopyAfterThisEnds)();
  AppLogger.info(
    'Handed over to ZestSSH from the Microsoft Store, which opens in this one\'s place',
  );
  return true;
}

/// The Store's copy. It takes over only a website copy of at most its own
/// version. The website's copy
/// can be a release ahead (3.4 on zestssh.com before the Store has it), its
/// data in a shape this copy cannot read: taking that data in, or opening the
/// real folders this copy shares with a website copy installed first, would
/// open it with the older program, and removing the website copy would leave
/// only the copy that cannot read it. A newer website copy is left as it is
/// and opens in this one's place until the Store has its version; at that
/// start it finds this copy older, stays, and says once that this one needs
/// updating, so neither hands its start back.
///
/// Decided before any data opens and before anything is drawn: the window
/// shows with the first frame (windows/runner/flutter_window.cpp), so a start
/// handed over shows nothing of this copy. Where no website copy is installed
/// nothing is read, and a waiting hand-over is taken in as before.
Future<bool> _storeCopyStarts(
  StoreHandover h, {
  required Future<SharedPreferences> Function() rawPrefs,
  required DateTime Function() clock,
  Future<bool> Function()? askKeepWebsite,
  Future<int> Function(String exe, List<String> args)? runUninstaller,
  Future<String> Function()? thisVersion,
  Future<String> Function(File program)? websiteCopyVersion,
  Future<void> Function(File program)? openWebsiteCopy,
}) async {
  await _ageOut(h, clock);
  final copy = h.websiteCopy;

  /// Whether this copy may take the website copy over (at most this one's
  /// version); null where either version cannot be read.
  Future<({bool mayTakeOver, String website, String mine})?> compare(
    File program,
  ) async {
    try {
      final website = await (websiteCopyVersion ?? _websiteCopyVersion)(
        program,
      );
      // The package's version, where the website's copy reads it.
      final mine = await (thisVersion ?? _storeCopyOwnVersion)();
      // A version that is not one throws here, and counts as not read.
      return (
        mayTakeOver: storeCopyMayTakeOver(
          storeVersion: mine,
          websiteVersion: website,
        ),
        website: website,
        mine: mine,
      );
    } catch (e) {
      AppLogger.warning(
        'The website copy\'s version could not be read (${errorKind(e)}): this copy starts as it is, and takes nothing in and removes nothing',
      );
      return null;
    }
  }

  if (copy != null) {
    final versions = await compare(copy.program);
    // The safe side: neither taken over nor handed the start. Taking it over
    // could give data of a newer copy to this older one and remove the copy
    // that reads it; handing the start to it could hand it to a program that
    // does not run (its version is in every build since 1.3.4, so a copy
    // whose version cannot be read is most likely broken), and the person
    // would get no ZestSSH at all. This copy starts as it did before the
    // hand-over existed, takes nothing in, removes nothing, says nothing, and
    // looks again at its next start. What is left: where it shares a website
    // copy's real folders it opens them, as every start before 3.3 did.
    if (versions == null) return false;
    if (!versions.mayTakeOver) {
      // The website copy has just handed its start to this one, which finds
      // it newer: the two read their versions apart (a package versioned
      // apart from the program). Handing the start back would have them hand
      // it to each other for ever: this copy starts as it is, takes
      // nothing in and removes nothing.
      final at = h.handoverAt;
      if (at != null && clock().difference(at).abs() < _justHandedOver) {
        AppLogger.warning(
          'ZestSSH from zestssh.com has just handed over to this copy, which finds it newer (${versions.website} against ${versions.mine}): neither hands its start back; this copy starts as it is, and takes nothing in and removes nothing',
        );
        return false;
      }
      try {
        await (openWebsiteCopy ?? _openWebsiteCopyAfterThisEnds)(copy.program);
      } catch (e) {
        // Not opened: this copy starts rather than leave the person with none,
        // and still takes nothing in and removes nothing.
        AppLogger.warning(
          'ZestSSH from zestssh.com is newer than this copy and was not opened (${errorKind(e)}): this copy starts as it is',
        );
        return false;
      }
      AppLogger.info(
        'ZestSSH from zestssh.com is ${versions.website}, newer than this copy (${versions.mine}): it opens in this one\'s place until the Store has its version',
      );
      return true;
    }
  }

  final HandoverTaken taken;
  try {
    taken = await h.takeIn(
      keepWebsite: askKeepWebsite ?? () => _askKeepWebsite(h),
    );
  } catch (e) {
    AppLogger.warning(
      'A hand-over from the website copy was not taken in (${errorKind(e)}): it waits for the next start',
    );
    return false;
  } finally {
    // What the person chose not to keep is named to them, even where the
    // take-in stopped after it was set aside.
    if (h.lastSetAside.isNotEmpty) _setAsideSaid = h.lastSetAside;
  }
  if (copy == null) return false;
  if (!h.mayRemoveWebsiteCopy(taken: taken)) {
    _notice = StoreHandoverNotice.openWebsiteOnce;
    return false;
  }
  final prefs = await rawPrefs();
  final tried = DateTime.tryParse(prefs.getString(_removeTriedKey) ?? '');
  if (copy.forAllAccounts) {
    // Installed for every account on the PC (C:\Program Files): its uninstaller
    // asks for an administrator, and would remove it for every account.
    // It is left as it is: the person is told once, and again after
    // each hand-over it makes.
    if (taken == HandoverTaken.none && tried != null) return false;
    await prefs.setString(_removeTriedKey, clock().toUtc().toIso8601String());
    _notice = StoreHandoverNotice.forAllAccounts;
    return false;
  }
  if (taken == HandoverTaken.none &&
      tried != null &&
      clock().difference(tried) < _removeRetry) {
    return false;
  }
  // The website copy can have been updated while this one asked or copied:
  // read again, just before it goes.
  final again = await compare(copy.program);
  if (again == null || !again.mayTakeOver) {
    AppLogger.info(
      'ZestSSH from zestssh.com changed while this copy started: it is not removed this time',
    );
    return false;
  }
  await prefs.setString(_removeTriedKey, clock().toUtc().toIso8601String());
  bool gone;
  try {
    gone = await h.removeWebsiteCopy(run: runUninstaller);
  } catch (e) {
    AppLogger.warning('The website copy was not removed (${errorKind(e)})');
    gone = false;
  }
  _notice = !gone
      ? StoreHandoverNotice.notRemoved
      : taken == HandoverTaken.keptStore
      ? StoreHandoverNotice.removedKeptStore
      : StoreHandoverNotice.removed;
  return false;
}

/// What a hand-over set aside goes once it is [StoreHandover.setAsideKept] old.
Future<void> _ageOut(StoreHandover h, DateTime Function() clock) async {
  try {
    final gone = await h.ageOut(now: clock());
    if (gone > 0) {
      AppLogger.info('$gone set aside by a hand-over 30 days ago or more went');
    }
  } catch (e) {
    AppLogger.warning(
      'What a hand-over set aside was not looked at (${errorKind(e)})',
    );
  }
}

/// The lock both copies take while one hands over or takes in ([wait]: how
/// long to wait for it): a named one of this Windows session, by the
/// hand-over folder's path ([StoreHandover.lockName]). Gives back what returns
/// it; null where another holds it all that time. Where Windows gives no such
/// lock at all, it goes on as before the lock was there.
Future<void Function()?> _takeHandoverLock(
  StoreHandover h,
  Duration wait,
) async {
  final until = DateTime.now().add(wait);
  while (true) {
    final WindowsNamedLock? lock;
    try {
      lock = WindowsNamedLock.tryTake(h.lockName);
    } catch (e) {
      AppLogger.warning(
        'The hand-over\'s lock was not there (${errorKind(e)}): this copy goes on without it',
      );
      return () {};
    }
    if (lock != null) return lock.release;
    if (!DateTime.now().isBefore(until)) return null;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

/// This copy's version, from its program file (package_info_plus).
Future<String> _thisVersion() async =>
    (await PackageInfo.fromPlatform()).version;

/// The Store copy's own version, from its package's name.
Future<String> _storeCopyOwnVersion() async => storeCopyOwnVersion();

/// The website copy's version, from its program file: the field it reads its
/// own from (store_handover_version.dart, [programProductVersion]).
Future<String> _websiteCopyVersion(File program) async =>
    programProductVersion(program.path);

/// Opens the website's copy once this process has ended, for the reason in
/// [_openStoreCopyAfterThisEnds]: a website copy started while this one still
/// ran would find this one's window (made at the start, not shown yet), hand
/// its start to it, and end, and then this one would end too.
///
/// Explorer starts it, as the Start menu would: a program this one started
/// itself would be its child, and a Store app's children can run inside its
/// package's environment, where AppData is the package's private copy.
Future<void> _openWebsiteCopyAfterThisEnds(File program) =>
    _openAfterThisEnds(program.path);

/// Opens the Store's copy once this process has ended: the two copies share the
/// "one ZestSSH at a time" check (windows/runner/single_instance.cpp), and a Store
/// copy that started while this one still ran would hand its start back to it.
/// As the website's copy is opened (with /d, so no AutoRun command of the PC's
/// runs first, and /v:off, so the ! in its name stays; found in a
/// security review).
Future<void> _openStoreCopyAfterThisEnds() => _start(openStoreCopyCommand());

/// What opens the Store's copy once this process has ended.
@visibleForTesting
({List<String> arguments, Map<String, String> environment})
openStoreCopyCommand() =>
    openAfterThisEndsCommand(StoreHandover.appsFolderTarget);

Future<void> _openAfterThisEnds(String target) =>
    _start(openAfterThisEndsCommand(target));

Future<void> _start(
  ({List<String> arguments, Map<String, String> environment}) command,
) async {
  await Process.start(
    windowsSystemProgram('cmd.exe'),
    command.arguments,
    environment: command.environment,
    mode: ProcessStartMode.detached,
  );
}

/// The variable [openAfterThisEndsCommand] passes the path in.
const _openTargetVariable = 'ZESTSSH_OPEN_AFTER_THIS_ENDS';

/// cmd.exe's arguments, and the variable they read [target]'s path from, that
/// open [target] (a program's path, or the Store copy's shell:AppsFolder name)
/// with Explorer ([opener] in tests) once this process has ended: ping.exe
/// waits a second between its [pings].
///
/// Why a variable: the path holds the Windows account's folder (C:\Users\Ana
/// Maria\AppData\Local\Programs\ZestSSH\zestssh.exe), so it needs quotes, and
/// Dart passes a quote inside an argument to cmd.exe as \", which cmd.exe does
/// not read as one. cmd.exe puts a variable's value in before it reads the line
/// (/s: the quotes Dart puts around the whole line are taken off first), so the
/// quotes in the value are read as quotes, and a space, an & or a % in the path
/// stays part of it. /d: no AutoRun command of the PC's runs first; /v:off: a !
/// in the path (the Store copy's name has one) is a !.
@visibleForTesting
({List<String> arguments, Map<String, String> environment})
openAfterThisEndsCommand(String target, {String? opener, int pings = 3}) {
  final ping = windowsSystemProgram('ping.exe');
  return (
    arguments: [
      '/d',
      '/v:off',
      '/s',
      '/c',
      '$ping -n $pings 127.0.0.1 >nul & ${opener ?? windowsExplorer} %$_openTargetVariable%',
    ],
    environment: {_openTargetVariable: '"$target"'},
  );
}

/// Asks, on a screen of its own before anything opens, which data to keep,
/// with when each was last used. The language is this copy's own, read from
/// its preferences' file: the preferences are not opened yet.
Future<bool> _askKeepWebsite(StoreHandover h) async {
  final answer = Completer<bool>();
  final storeLastUsed = await h.ownDataLastUsed();
  runApp(
    StoreHandoverQuestionApp(
      onAnswer: answer.complete,
      language: h.preferredLanguage,
      websiteLastUsed: h.handedOverLastUsed,
      storeLastUsed: storeLastUsed,
    ),
  );
  return answer.future;
}
