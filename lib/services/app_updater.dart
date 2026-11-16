import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/services/update_manifest.dart';
import 'package:zestssh/utils/type_name.dart';

/// The in-app updater of the computers (3.0: a
/// simple update button; a click, with no hosts open, shuts the app,
/// updates it and opens it again).
///
/// How a release gets from zestssh.com into place, and what is checked on
/// the way (the manifest's trust is in update_manifest.dart):
///
/// 1. [check]: whether this copy can replace itself at all, before anything
///    is downloaded (a store's copy never gets here: kStoreBuild).
/// 2. [download]: the platform's file named in the SIGNED manifest, from
///    https://zestssh.com/downloads/ only (a redirect is followed only to
///    another URL that passes the same test), into a folder of its own in the
///    system's temporary folder that only this account can open, hashed as it
///    arrives. More bytes than the manifest names stop
///    it at once; at the end the size and the SHA-256 must be the signed
///    ones, or the file is deleted unopened (ZS-1903). The request carries
///    nothing about the device. It can be cancelled at any point.
/// 3. [prepare]: the file is hashed again, as it is now; on Linux the archive
///    is unpacked next to the install
///    folder; on a Mac the disk image is attached read-only, the app copied
///    next to the running one (ditto) and the image detached, and the copied
///    app's version must be the release's. Nothing of the running copy is
///    touched yet: a failure here leaves everything as it was.
/// 4. [launch]: what is about to be started is read once more, and the
///    installer (Windows) or a small helper script (Linux,
///    Mac) is started, with every value as an argument of its own, never in
///    a shell's text. On Windows the app then waits until the setup is
///    really installing (its log is there: see [launch]), so that a setup
///    Windows does not allow (an admin install whose UAC prompt is answered
///    No) never leaves the person with no app. Then the app quits the way
///    it always quits (desktop_shell: tabs saved, sessions ended). The
///    installer waits for the app to be gone, installs silently and opens
///    the new version; the helper waits for it, swaps the new folder or app
///    in with two renames (the old one is put back where the second fails),
///    and opens it.
/// 5. At the next start, [UpdatePending] says whether the version is now the
///    new one; if not, the app says so with the installer's log (ZS-1905).
/// How long a download waits before it picks up a dropped connection
/// again, each time: three times at most.
const kDownloadResumeWaits = [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)];

class AppUpdater {
  AppUpdater({
    http.Client Function()? clientFactory,
    ProcessStarter? start,
    ProcessRunner? run,
    Directory? tempRoot,
    String? executable,
    int? pid,
    Map<String, String>? environment,
    UpdatePlatform? platform,
    Duration setupStartTimeout = kSetupStartTimeout,
    Duration setupPoll = const Duration(milliseconds: 250),
    Duration setupQuietWait = const Duration(milliseconds: 1500),
    List<Duration> resumeWaits = kDownloadResumeWaits,
  })  : _setupStartTimeout = setupStartTimeout,
        _resumeWaits = resumeWaits,
        _setupPoll = setupPoll,
        _setupQuietWait = setupQuietWait,
        _clientFactory = clientFactory ?? http.Client.new,
        _start = start ?? _startProcess,
        _run = run ?? _runProcess,
        _tempRoot = tempRoot,
        _executable = executable ?? Platform.resolvedExecutable,
        _pid = pid ?? (Platform.isWindows || Platform.isLinux || Platform.isMacOS ? _ownPid() : 0),
        _env = environment ?? Platform.environment,
        _platform = platform ?? UpdatePlatform.current;

  final http.Client Function() _clientFactory;
  final ProcessStarter _start;
  final ProcessRunner _run;
  final Directory? _tempRoot;
  final String _executable;
  final int _pid;
  final Map<String, String> _env;
  final UpdatePlatform? _platform;
  final Duration _setupStartTimeout;
  final Duration _setupPoll;
  final Duration _setupQuietWait;
  final List<Duration> _resumeWaits;

  static int _ownPid() => pid;

  /// The folders made so far ([_madeWorkDir]), by version.
  final _workDirs = <String, Directory>{};

  /// The folder an update of [version] is downloaded and logged into: one this
  /// copy made ([_madeWorkDir]), and none before it did.
  Directory workDir(String version) => _workDirs[version] ?? (throw StateError('No folder was made for $version'));

  /// [workDir], made where it is not there yet: a new folder of a name nobody
  /// can guess, that only this account can open, in the system's temporary
  /// folder. It was `<temp>/zestssh-update/<version>`, used as it was found:
  /// on Linux another account on the computer could make that folder first,
  /// open to all, change the archive after it was hashed, and have their own
  /// swap.sh run (found 30 October 2026 in a security audit).
  Future<Directory> _madeWorkDir(String version) async {
    final had = _workDirs[version];
    if (had != null && await had.exists()) return had;
    final made = await (_tempRoot ?? Directory.systemTemp).createTemp('zestssh-update-${_safeName(version)}-');
    // createTemp makes it so; a folder others can open is not used all the same.
    if (!Platform.isWindows && FileStat.statSync(made.path).mode & 0x3f != 0) {
      throw FileSystemException('Others can open the folder made for the update', made.path);
    }
    return _workDirs[version] = made;
  }

  /// [file] as it is now against the [sha256] and [size] of the release: read
  /// again just before it is unpacked or started, whatever was found while it
  /// came. Deleted, and an [UpdateFailure] (ZS-1903), where it changed since.
  Future<void> _checkStill(File file, {required String sha256, required int size}) async {
    final int found;
    final String hash;
    try {
      found = await file.length();
      hash = (await crypto.sha256.bind(file.openRead()).first).toString();
    } on FileSystemException catch (e) {
      throw UpdateFailure(ErrorCodes.updateFileMismatch, 'The downloaded file could not be read again: ${e.message}', e);
    }
    if (found == size && hash == sha256) return;
    try {
      await file.delete();
    } on FileSystemException {
      // (Nothing runs it: what follows stops here.)
    }
    throw UpdateFailure(ErrorCodes.updateFileMismatch,
        'The file changed after it was checked: expected $size bytes with SHA-256 $sha256, found $found with $hash.');
  }

  // ── 1. Can this copy update itself? ─────────────────────────────────

  /// Whether this copy can install [info] itself, and where; or why not.
  /// Looks at the disk only, downloads nothing.
  InstallCheck check(UpdateInfo info) {
    final platform = _platform;
    if (platform == null) return const CannotInstall(InstallBlock.notAComputer);
    if (info.package == null) return const CannotInstall(InstallBlock.noPackage);
    switch (platform) {
      case UpdatePlatform.windows:
        final dir = p.dirname(_executable);
        // A copy the ZestSSH setup installed has its uninstaller beside it
        // (unins000.exe): the setup knows where it is and upgrades it. A
        // folder copied by hand, or a build, has none.
        final hasUninstaller = _safeList(dir).any((f) => RegExp(r'^unins\d{3}\.exe$', caseSensitive: false).hasMatch(p.basename(f)));
        if (!hasUninstaller) return CannotInstall(InstallBlock.notInstalledBySetup, place: dir);
        return CanInstall(InstallTarget(platform: platform, executable: _executable, installDir: dir));
      case UpdatePlatform.linux:
        if (_env.containsKey('FLATPAK_ID') || _env.containsKey('SNAP') || _env.containsKey('APPIMAGE')) {
          return CannotInstall(InstallBlock.systemPackage, place: p.dirname(_executable));
        }
        final dir = p.dirname(_executable);
        // The swap renames the folder, so both it and the folder it is in
        // must be writable: a copy under /usr or /opt owned by root is not.
        if (!_writable(dir) || !_writable(p.dirname(dir))) {
          return CannotInstall(InstallBlock.folderNotWritable, place: dir);
        }
        return CanInstall(InstallTarget(platform: platform, executable: _executable, installDir: dir));
      case UpdatePlatform.macos:
        final bundle = macBundleOf(_executable);
        if (bundle == null) return CannotInstall(InstallBlock.notInstalledBySetup, place: p.dirname(_executable));
        if (bundle.startsWith('/Volumes/')) return CannotInstall(InstallBlock.diskImage, place: bundle);
        // Opened straight from Downloads with the quarantine on, macOS runs a
        // read-only copy somewhere else (App Translocation).
        if (bundle.contains('/AppTranslocation/')) return CannotInstall(InstallBlock.translocated, place: bundle);
        if (!_writable(bundle) || !_writable(p.dirname(bundle))) {
          return CannotInstall(InstallBlock.folderNotWritable, place: bundle);
        }
        return CanInstall(InstallTarget(platform: platform, executable: _executable, installDir: bundle));
    }
  }

  /// The `.app` bundle [executable] runs from (`/X/ZestSSH.app` for
  /// `/X/ZestSSH.app/Contents/MacOS/ZestSSH`), or null.
  static String? macBundleOf(String executable) {
    final macos = p.posix.dirname(executable);
    final contents = p.posix.dirname(macos);
    final bundle = p.posix.dirname(contents);
    if (p.posix.basename(macos) != 'MacOS' || p.posix.basename(contents) != 'Contents' || !bundle.endsWith('.app')) {
      return null;
    }
    return bundle;
  }

  // ── 2. Download ─────────────────────────────────────────────────────

  /// Downloads [info]'s package into [workDir], checking it as it comes,
  /// and gives the file once its size and SHA-256 are the signed ones.
  /// [onProgress] is told the bytes so far and the bytes in all. Throws an
  /// [UpdateFailure] (ZS-1901, ZS-1903) or, where [cancel] was used,
  /// [UpdateCancelled].
  Future<File> download(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    UpdateCancelToken? cancel,
  }) async {
    final pkg = info.package;
    if (pkg == null || !isAllowedDownloadUrl(pkg.url)) {
      throw UpdateFailure(ErrorCodes.updateNotSigned, 'The release names no file for this computer that may be downloaded.');
    }
    final File target;
    final File part;
    try {
      final dir = await _madeWorkDir(info.version);
      target = File(p.join(dir.path, _safeName(pkg.fileName)));
      part = File('${target.path}.part');
      if (await part.exists()) await part.delete();
      if (await target.exists()) await target.delete();
    } on FileSystemException catch (e) {
      throw UpdateFailure(ErrorCodes.updateDownloadFailed, 'The temporary folder could not be written: ${e.message}', e);
    }

    final client = _clientFactory();
    cancel?._onCancel = client.close;
    IOSink? out;
    try {
      final resp = await _get(client, pkg.url, cancel);
      final length = resp.contentLength;
      if (length != null && length != pkg.size) {
        throw UpdateFailure(ErrorCodes.updateFileMismatch,
            'The site says the file is $length bytes; the signed release names ${pkg.size}.');
      }
      out = part.openWrite();
      var digest = _DigestSink();
      var hasher = crypto.sha256.startChunkedConversion(digest);
      var received = 0;
      onProgress?.call(0, pkg.size);
      // A connection that drops mid-way is picked up where it stopped, a
      // few times (before, one try, and
      // "Connection closed while receiving data" ended it).
      http.StreamedResponse? coming = resp;
      var resumes = 0;
      while (true) {
        try {
          if (coming == null) {
            final again = await _get(client, pkg.url, cancel, from: received);
            if (again.statusCode == 200) {
              // The site sent all of it again: start over, hashed afresh.
              final length = again.contentLength;
              if (length != null && length != pkg.size) {
                await again.stream.drain<void>();
                throw UpdateFailure(ErrorCodes.updateFileMismatch,
                    'The site says the file is $length bytes; the signed release names ${pkg.size}.');
              }
              await out!.close();
              out = part.openWrite();
              digest = _DigestSink();
              hasher = crypto.sha256.startChunkedConversion(digest);
              received = 0;
              onProgress?.call(0, pkg.size);
            } else if (again.headers['content-range'] != 'bytes $received-${pkg.size - 1}/${pkg.size}') {
              await again.stream.drain<void>();
              throw UpdateFailure(ErrorCodes.updateFileMismatch,
                  'The site sent another part (${again.headers['content-range'] ?? 'none named'}) than the rest from byte $received of ${pkg.size}.');
            }
            coming = again;
          }
          await for (final chunk in coming.stream.timeout(const Duration(seconds: 45))) {
            if (cancel?.cancelled ?? false) throw const UpdateCancelled();
            received += chunk.length;
            if (received > pkg.size) {
              throw UpdateFailure(ErrorCodes.updateFileMismatch,
                  'More than the ${pkg.size} bytes the signed release names came; the download was stopped.');
            }
            hasher.add(chunk);
            out!.add(chunk);
            onProgress?.call(received, pkg.size);
          }
          break;
        } on UpdateFailure {
          rethrow;
        } on UpdateCancelled {
          rethrow;
        } catch (e) {
          if ((cancel?.cancelled ?? false) || !_dropped(e)) rethrow;
          // All of it came before the connection dropped: the checks below
          // say whether it is the file.
          if (received == pkg.size) break;
          if (resumes >= _resumeWaits.length) rethrow;
          await Future<void>.delayed(_resumeWaits[resumes++]);
          if (cancel?.cancelled ?? false) throw const UpdateCancelled();
          coming = null;
        }
      }
      if (cancel?.cancelled ?? false) throw const UpdateCancelled();
      hasher.close();
      await out!.flush();
      await out.close();
      out = null;
      if (received != pkg.size) {
        throw UpdateFailure(ErrorCodes.updateFileMismatch, 'Size: expected ${pkg.size} bytes, found $received.');
      }
      final found = digest.value.toString();
      if (found != pkg.sha256) {
        throw UpdateFailure(ErrorCodes.updateFileMismatch, 'SHA-256: expected ${pkg.sha256}, found $found.');
      }
      await part.rename(target.path);
      return target;
    } on UpdateFailure {
      await _quietDelete(part, out);
      rethrow;
    } on UpdateCancelled {
      await _quietDelete(part, out);
      rethrow;
    } catch (e) {
      await _quietDelete(part, out);
      if (cancel?.cancelled ?? false) throw const UpdateCancelled();
      final what = e is TimeoutException
          ? 'The site sent nothing for 45 seconds.'
          : e is FileSystemException
              ? 'The file could not be written: ${e.message}'
              : 'The download stopped: $e';
      throw UpdateFailure(ErrorCodes.updateDownloadFailed, what, e);
    } finally {
      cancel?._onCancel = null;
      client.close();
    }
  }

  /// Whether [e] is the connection dropping or going quiet mid-way, which a
  /// download picks up again from where it stopped.
  static bool _dropped(Object e) =>
      e is http.ClientException || e is SocketException || e is HttpException || e is TimeoutException;

  /// GET [url] with redirects followed by hand, each to a URL that passes
  /// [isAllowedDownloadUrl] too, at most three. With [from], only the bytes
  /// from there on are asked for, and the site may answer 206 with them or
  /// 200 with all of it.
  Future<http.StreamedResponse> _get(http.Client client, Uri url, UpdateCancelToken? cancel, {int? from}) async {
    var at = url;
    for (var hop = 0; hop < 4; hop++) {
      if (cancel?.cancelled ?? false) throw const UpdateCancelled();
      // A plain request: no version, no id, nothing about the device.
      final req = http.Request('GET', at)
        ..followRedirects = false
        ..headers['Accept'] = '*/*';
      if (from != null) req.headers['Range'] = 'bytes=$from-';
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      final code = resp.statusCode;
      if (code >= 300 && code < 400) {
        final loc = resp.headers['location'];
        await resp.stream.drain<void>();
        final next = loc == null ? null : at.resolve(loc);
        if (next == null || !isAllowedDownloadUrl(next)) {
          throw UpdateFailure(ErrorCodes.updateDownloadFailed,
              'The site sent the download elsewhere ($code to ${next == null ? 'nowhere' : '${next.scheme}://${next.host}'}), which is not followed.');
        }
        at = next;
        continue;
      }
      if (code != 200 && !(code == 206 && from != null)) {
        await resp.stream.drain<void>();
        throw UpdateFailure(ErrorCodes.updateDownloadFailed, 'The site answered $code for ${at.path}.');
      }
      return resp;
    }
    throw UpdateFailure(ErrorCodes.updateDownloadFailed, 'The site redirected the download more than three times.');
  }

  // ── 3. Prepare ──────────────────────────────────────────────────────

  /// Gets the downloaded [file] ready to go in place of [target], touching
  /// nothing of the running copy, and gives what [launch] starts.
  /// [currentBuild] is the running copy's build number, where it can read
  /// it: a release of the same version is newer only by a higher build
  /// ([compareReleases]). [reopen] false: the new version is installed and
  /// not opened (Update and close: the app is updated
  /// and stays off).
  Future<PreparedUpdate> prepare(UpdateInfo info, File file, InstallTarget target,
      {required String currentVersion, int? currentBuild, bool reopen = true}) async {
    // No downgrade, and no "update" to the version that runs.
    if (compareReleases(info.version, info.build, currentVersion, currentBuild) <= 0) {
      throw UpdateFailure(ErrorCodes.updateNotSigned,
          'The release ${_named(info.version, info.build)} is not newer than this version (${_named(currentVersion, currentBuild)}): an update never goes back.');
    }
    final pkg = info.package;
    if (pkg == null) {
      throw UpdateFailure(ErrorCodes.updateNotSigned, 'The release names no file for this computer.');
    }
    final Directory dir;
    try {
      dir = await _madeWorkDir(info.version);
    } on FileSystemException catch (e) {
      throw UpdateFailure(ErrorCodes.updateInstallFailed, 'The temporary folder could not be written: ${e.message}', e);
    }
    await _checkStill(file, sha256: pkg.sha256, size: pkg.size);
    switch (target.platform) {
      case UpdatePlatform.windows:
        final log = p.join(dir.path, 'setup.log');
        return PreparedUpdate(
          version: info.version,
          build: info.build,
          executable: file.path,
          arguments: windowsInstallerArgs(logPath: log, relaunch: reopen),
          logPath: log,
          waitsForSetupLog: true,
          // An elevated setup asks Windows first: what starts is what was
          // checked, however long this took.
          checks: [(path: file.path, sha256: pkg.sha256, size: pkg.size)],
        );
      case UpdatePlatform.linux:
        return _prepareLinux(info, file, target, dir, reopen: reopen);
      case UpdatePlatform.macos:
        return _prepareMac(info, file, target, dir, reopen: reopen);
    }
  }

  Future<PreparedUpdate> _prepareLinux(UpdateInfo info, File file, InstallTarget target, Directory dir,
      {required bool reopen}) async {
    final install = target.installDir;
    final staging = p.join(p.dirname(install), '.zestssh-update-${_safeName(info.version)}');
    try {
      await _deleteIfThere(staging);
      await Directory(staging).create();
      final r = await _run('tar', ['-xzf', file.path, '-C', staging]);
      if (r.exitCode != 0) {
        await _deleteIfThere(staging);
        throw UpdateFailure(ErrorCodes.updateInstallFailed, 'Unpacking the archive failed (tar exit ${r.exitCode}): ${_short(r.stderr)}');
      }
      // The release archive holds the bundle's contents at its top (tar -C
      // bundle .); one folder at the top that holds them is taken as well.
      var root = staging;
      if (!File(p.join(root, 'zestssh')).existsSync()) {
        final dirs = Directory(root).listSync().whereType<Directory>().toList();
        if (dirs.length == 1 && File(p.join(dirs.single.path, 'zestssh')).existsSync()) root = dirs.single.path;
      }
      if (!File(p.join(root, 'zestssh')).existsSync()) {
        await _deleteIfThere(staging);
        throw const UpdateFailure(ErrorCodes.updateInstallFailed, 'The archive holds no zestssh program.');
      }
      final script = File(p.join(dir.path, 'swap.sh'));
      await script.writeAsString(kLinuxSwapScript);
      final log = p.join(dir.path, 'swap.log');
      return PreparedUpdate(
        version: info.version,
        build: info.build,
        executable: '/bin/sh',
        arguments: [script.path, '$_pid', install, root, log, swapThen(reopen: reopen)],
        logPath: log,
        staged: staging,
        checks: [_scriptCheck(script.path, kLinuxSwapScript)],
      );
    } on FileSystemException catch (e) {
      await _deleteIfThere(staging);
      throw UpdateFailure(ErrorCodes.updateInstallFailed, 'The new version could not be unpacked: ${e.message}', e);
    }
  }

  Future<PreparedUpdate> _prepareMac(UpdateInfo info, File file, InstallTarget target, Directory dir,
      {required bool reopen}) async {
    final bundle = target.installDir;
    final mount = p.join(dir.path, 'mnt');
    final staged = p.join(p.dirname(bundle), '.${p.basenameWithoutExtension(bundle)}-update-${_safeName(info.version)}.app');
    var attached = false;
    try {
      await _deleteIfThere(staged);
      await Directory(mount).create(recursive: true);
      final a = await _run('/usr/bin/hdiutil', ['attach', '-nobrowse', '-readonly', '-noautoopen', '-mountpoint', mount, file.path]);
      if (a.exitCode != 0) {
        throw UpdateFailure(ErrorCodes.updateInstallFailed, 'The disk image could not be opened (hdiutil exit ${a.exitCode}): ${_short(a.stderr)}');
      }
      attached = true;
      final apps = Directory(mount).listSync().whereType<Directory>().where((d) => d.path.endsWith('.app')).toList();
      final same = apps.where((d) => p.basename(d.path) == p.basename(bundle)).toList();
      final source = same.isNotEmpty ? same.first : (apps.length == 1 ? apps.single : null);
      if (source == null) throw const UpdateFailure(ErrorCodes.updateInstallFailed, 'The disk image holds no ZestSSH app.');
      final c = await _run('/usr/bin/ditto', [source.path, staged]);
      if (c.exitCode != 0) {
        throw UpdateFailure(ErrorCodes.updateInstallFailed, 'The app could not be copied from the disk image (ditto exit ${c.exitCode}): ${_short(c.stderr)}');
      }
      // The copied app must be the release: a disk image built from a stale
      // app would otherwise go in under the new version's name.
      final v = await _run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleShortVersionString', p.join(staged, 'Contents', 'Info.plist')]);
      final found = '${v.stdout}'.trim();
      if (v.exitCode != 0 || compareVersions(found, info.version) != 0) {
        throw UpdateFailure(ErrorCodes.updateInstallFailed, 'The disk image holds version ${found.isEmpty ? 'unknown' : found}; the release is ${info.version}.');
      }
      // And where the release names its build, the copied app's build too
      // (two builds of one version differ only there).
      if (info.build != null) {
        final b = await _run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleVersion', p.join(staged, 'Contents', 'Info.plist')]);
        final foundBuild = int.tryParse('${b.stdout}'.trim());
        if (b.exitCode != 0 || foundBuild != info.build) {
          throw UpdateFailure(ErrorCodes.updateInstallFailed,
              'The disk image holds build ${foundBuild ?? 'unknown'}; the release is build ${info.build}.');
        }
      }
      final script = File(p.join(dir.path, 'swap.sh'));
      await script.writeAsString(kMacSwapScript);
      final log = p.join(dir.path, 'swap.log');
      return PreparedUpdate(
        version: info.version,
        build: info.build,
        executable: '/bin/sh',
        arguments: [script.path, '$_pid', bundle, staged, log, swapThen(reopen: reopen)],
        logPath: log,
        staged: staged,
        checks: [_scriptCheck(script.path, kMacSwapScript)],
      );
    } on UpdateFailure {
      await _deleteIfThere(staged);
      rethrow;
    } on FileSystemException catch (e) {
      await _deleteIfThere(staged);
      throw UpdateFailure(ErrorCodes.updateInstallFailed, 'The new version could not be copied: ${e.message}', e);
    } finally {
      if (attached) {
        final d = await _run('/usr/bin/hdiutil', ['detach', mount]);
        if (d.exitCode != 0) await _run('/usr/bin/hdiutil', ['detach', '-force', mount]);
      }
    }
  }

  // ── 4. Launch ───────────────────────────────────────────────────────

  /// Starts [prepared]'s installer or helper so that it outlives the app.
  /// The app quits right after it returns (the caller's part), and only
  /// then: where this throws, the app stays open.
  ///
  /// On Windows it returns only once the setup is really installing. What
  /// Inno Setup does (its source, 6.7.1, Setup.MainFunc.pas): Setup.exe
  /// starts without elevation; for an install that needs an administrator
  /// (an earlier "all users" install) its first process starts a second,
  /// elevated one through UAC and waits for it, BEFORE it opens any log; the
  /// log named by /LOG is created only by the process that goes on to
  /// install, before the setup's own InitializeSetup. Answered No, the first
  /// process ends with exit code 2 (ecCancelledBeforeInstall) and no log. So:
  /// * the log there (deleted before the start) means it installs: return;
  /// * the setup ended first: exit code 2 is Windows not allowing it
  ///   ([UpdateFailure.notAllowed]), any other is ZS-1905 with the code;
  /// * no log after [kSetupStartTimeout], or [cancel] used: the setup is
  ///   stopped, and the marker [windowsCancelMarkerFor] is left for it, so
  ///   that a Yes given later installs nothing (installer/zestssh_setup.iss
  ///   reads it before it would close the app).
  /// [onWaiting] is called once the setup has been quiet for a moment (the
  /// UAC prompt is likely up), for the dialog to say so.
  Future<void> launch(PreparedUpdate prepared, {UpdateCancelToken? cancel, void Function()? onWaiting}) async {
    try {
      for (final c in prepared.checks) {
        await _checkStill(File(c.path), sha256: c.sha256, size: c.size);
      }
    } on UpdateFailure {
      if (prepared.staged != null) await _deleteIfThere(prepared.staged!);
      rethrow;
    }
    if (prepared.waitsForSetupLog) return _launchSetup(prepared, cancel, onWaiting);
    try {
      await _start(prepared.executable, prepared.arguments, mode: ProcessStartMode.detached);
    } catch (e) {
      if (prepared.staged != null) await _deleteIfThere(prepared.staged!);
      throw UpdateFailure(ErrorCodes.updateInstallFailed, 'The installer could not be started: $e', e);
    }
  }

  Future<void> _launchSetup(PreparedUpdate prepared, UpdateCancelToken? cancel, void Function()? onWaiting) async {
    final log = File(prepared.logPath);
    final marker = File(windowsCancelMarkerFor(prepared.logPath));
    try {
      // A log or a marker of an earlier try would say the wrong thing.
      if (await log.exists()) await log.delete();
      if (await marker.exists()) await marker.delete();
    } on FileSystemException catch (e) {
      throw UpdateFailure(ErrorCodes.updateInstallFailed, 'The log of an earlier try could not be removed: ${e.message}', e);
    }
    final Process setup;
    try {
      // Not detached: the app must see the setup end (a UAC No). It still
      // outlives the app: on Windows a started process is in no job of the
      // app's (dart:io puts only Process.run's children in one).
      setup = await _start(prepared.executable, prepared.arguments, mode: ProcessStartMode.normal);
    } catch (e) {
      throw UpdateFailure(ErrorCodes.updateInstallFailed, 'The installer could not be started: $e', e);
    }
    // The setup writes nothing to these; read so that it never waits on them.
    unawaited(setup.stdout.drain<void>().catchError((Object _) {}));
    unawaited(setup.stderr.drain<void>().catchError((Object _) {}));
    int? ended;
    unawaited(setup.exitCode.then((c) => ended = c, onError: (Object _) => ended = -1));

    final since = DateTime.now();
    var told = false;
    while (true) {
      if (await log.exists()) return;
      final code = ended;
      if (code != null) {
        if (await log.exists()) return;
        if (code == kSetupCancelledExitCode) {
          throw const UpdateFailure.notAllowed(
              'The setup ended with exit code 2 before it opened its log: Windows asked to allow it and the answer was No. Nothing was changed.');
        }
        throw UpdateFailure(ErrorCodes.updateInstallFailed,
            'The setup ended with exit code $code before it opened its log: it never started installing. Nothing was changed.');
      }
      final waited = DateTime.now().difference(since);
      final cancelled = cancel?.cancelled ?? false;
      if (cancelled || waited >= _setupStartTimeout) {
        await _stopSetup(setup, marker);
        if (cancelled) throw const UpdateCancelled();
        throw UpdateFailure.notAllowed(
            'The setup had not started installing after ${_setupStartTimeout.inSeconds} seconds (no log at ${prepared.logPath}): '
            'it was stopped, and told not to install if Windows allows it later. Nothing was changed.');
      }
      if (!told && waited >= _setupQuietWait) {
        told = true;
        onWaiting?.call();
      }
      await Future<void>.delayed(_setupPoll);
    }
  }

  /// Leaves the marker that tells the setup not to install, then ends the
  /// setup's processes that run as this account (the first one and the
  /// Setup.tmp it started; an elevated one is not this account's to end,
  /// and it reads the marker).
  Future<void> _stopSetup(Process setup, File marker) async {
    try {
      await marker.writeAsString('The app stopped waiting for this update at ${DateTime.now().toUtc().toIso8601String()}.\n');
    } catch (_) {}
    try {
      await _run('taskkill', ['/PID', '${setup.pid}', '/T', '/F']);
    } catch (_) {}
    try {
      setup.kill();
    } catch (_) {}
  }

  // ── helpers ─────────────────────────────────────────────────────────

  /// What [launch] reads again of the helper script [text] written at [path].
  static ({String path, String sha256, int size}) _scriptCheck(String path, String text) {
    final bytes = utf8.encode(text);
    return (path: path, sha256: crypto.sha256.convert(bytes).toString(), size: bytes.length);
  }

  static List<String> _safeList(String dir) {
    try {
      return [for (final e in Directory(dir).listSync()) e.path];
    } on FileSystemException {
      return const [];
    }
  }

  /// Whether a file can be made in [dir] (and is removed again).
  static bool _writable(String dir) {
    final probe = File(p.join(dir, '.zestssh-write-test-${DateTime.now().microsecondsSinceEpoch}'));
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static Future<void> _deleteIfThere(String path) async {
    try {
      final d = Directory(path);
      if (await d.exists()) await d.delete(recursive: true);
    } on FileSystemException {
      // (Left behind in a folder of its own; the next try deletes it.)
    }
  }

  static Future<void> _quietDelete(File part, IOSink? out) async {
    try {
      await out?.close();
    } catch (_) {}
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {}
  }

  static String _short(Object? text) {
    final s = '${text ?? ''}'.trim();
    return s.length <= 400 ? s : '${s.substring(0, 400)}...';
  }

  /// A version with its build where known, as Copy details shows it.
  static String _named(String version, int? build) => build == null ? version : '$version (build $build)';

  /// A version or file name as a single safe path segment.
  static String _safeName(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  static Future<Process> _startProcess(String exe, List<String> args, {ProcessStartMode mode = ProcessStartMode.normal}) =>
      Process.start(exe, args, mode: mode, runInShell: false);

  static Future<ProcessResult> _runProcess(String exe, List<String> args) => Process.run(exe, args, runInShell: false);
}

/// The Windows installer's arguments for an update (Inno Setup): silent,
/// no message boxes, no reboot, the running app closed if it is still
/// there, the app opened again afterwards (/RELAUNCH: the setup's [Run]
/// entry that only an update starts, installer/zestssh_setup.iss), and its
/// log written where Copy details can read it. A list: each is one
/// argument, never joined into a command line by hand.
/// How long the app waits for the Windows setup to start installing (UAC
/// answered) before it stops it and stays open.
const Duration kSetupStartTimeout = Duration(minutes: 2);

/// Inno Setup's exit code for a setup cancelled before it installed
/// anything: a UAC prompt answered No (ecCancelledBeforeInstall).
const int kSetupCancelledExitCode = 2;

/// The file the app leaves beside the setup's log where it stopped waiting
/// for it: the setup then installs nothing (installer/zestssh_setup.iss,
/// UpdateCancelledByApp, which builds the same name from /LOG).
String windowsCancelMarkerFor(String logPath) => '$logPath.cancelled';

/// The setup's arguments. /FROMAPP says the app started it (it waits for
/// the app to quit, and for the app's word that it stopped waiting); without
/// /RELAUNCH it opens nothing once it has installed (Update and close;
/// installer/zestssh_setup.iss, UpdateRequested and IsUpdateRelaunch).
List<String> windowsInstallerArgs({required String logPath, bool relaunch = true}) => [
      '/VERYSILENT',
      '/SUPPRESSMSGBOXES',
      '/NORESTART',
      '/CLOSEAPPLICATIONS',
      '/FROMAPP',
      if (relaunch) '/RELAUNCH',
      '/LOG=$logPath',
    ];

/// The helper's last argument (Linux, macOS): "open" opens the app once it
/// is done, "stay" leaves it closed (Update and close), the old version put
/// back too.
String swapThen({required bool reopen}) => reopen ? 'open' : 'stay';

/// The Linux helper, run as
/// `/bin/sh swap.sh <pid> <install folder> <new folder> <log> <open|stay>`.
/// Every value comes in as an argument and is only ever
/// used inside double quotes: no path is written into this text, so no
/// folder name can run as a command.
const String kLinuxSwapScript = r'''#!/bin/sh
# ZestSSH update helper (Linux). ZestSSH starts it, detached, just before it
# quits for an update: it waits for the app to quit, puts the new version in
# the place of the old one with two renames, and opens it. Where the second
# rename fails, the old version is put back and opened.
#   $1  the process id of the ZestSSH that is quitting
#   $2  the install folder (where zestssh is)
#   $3  the new version, unpacked beside it
#   $4  the log file
#   $5  open (the default): open ZestSSH when done; stay: leave it closed
set -u
pid="$1"
app="$2"
new="$3"
log="$4"
then="${5:-open}"
exec >>"$log" 2>&1
open_app() {
  if [ "$then" = "open" ]; then
    nohup "$app/zestssh" >/dev/null 2>&1 &
  fi
}
echo "ZestSSH update helper: waiting for the app (pid $pid) to quit"
if [ -z "$app" ] || [ ! -d "$app" ] || [ -z "$new" ] || [ ! -x "$new/zestssh" ]; then
  echo "The install folder or the new version is missing: nothing was changed."
  exit 1
fi
tries=0
while kill -0 "$pid" 2>/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -ge 120 ]; then
    echo "The app did not quit within a minute: nothing was changed."
    exit 1
  fi
  sleep 0.5
done
old="$app.old.$$"
if ! mv -- "$app" "$old"; then
  echo "The old version could not be moved aside: nothing was changed."
  open_app
  exit 1
fi
if ! mv -- "$new" "$app"; then
  echo "The new version could not be moved in: the old one is put back."
  mv -- "$old" "$app"
  open_app
  exit 1
fi
rm -rf -- "$old"
if [ "$then" = "open" ]; then
  echo "Updated: opening ZestSSH"
else
  echo "Updated: ZestSSH stays closed, as asked"
fi
open_app
exit 0
''';

/// The macOS helper, run as
/// `/bin/sh swap.sh <pid> <ZestSSH.app> <new .app beside it> <log> <open|stay>`,
/// as the Linux one: values as arguments only, always in double quotes.
const String kMacSwapScript = r'''#!/bin/sh
# ZestSSH update helper (macOS). ZestSSH starts it, detached, just before it
# quits for an update: it waits for the app to quit, puts the new app (copied
# from the disk image beside the old one) in the place of the old one with two
# renames, and opens it. Where the second rename fails, the old app is put
# back and opened.
#   $1  the process id of the ZestSSH that is quitting
#   $2  the app bundle (.../ZestSSH.app)
#   $3  the new app bundle, beside it
#   $4  the log file
#   $5  open (the default): open ZestSSH when done; stay: leave it closed
set -u
pid="$1"
app="$2"
new="$3"
log="$4"
then="${5:-open}"
exec >>"$log" 2>&1
open_app() {
  if [ "$then" = "open" ]; then
    /usr/bin/open "$app"
  fi
}
echo "ZestSSH update helper: waiting for the app (pid $pid) to quit"
if [ -z "$app" ] || [ ! -d "$app" ] || [ -z "$new" ] || [ ! -d "$new/Contents/MacOS" ]; then
  echo "The app or the new version is missing: nothing was changed."
  exit 1
fi
tries=0
while kill -0 "$pid" 2>/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -ge 120 ]; then
    echo "The app did not quit within a minute: nothing was changed."
    exit 1
  fi
  sleep 0.5
done
old="$app.old.$$"
if ! mv -- "$app" "$old"; then
  echo "The old app could not be moved aside: nothing was changed."
  open_app
  exit 1
fi
if ! mv -- "$new" "$app"; then
  echo "The new app could not be moved in: the old one is put back."
  mv -- "$old" "$app"
  open_app
  exit 1
fi
rm -rf -- "$old"
if [ "$then" = "open" ]; then
  echo "Updated: opening ZestSSH"
else
  echo "Updated: ZestSSH stays closed, as asked"
fi
open_app
exit 0
''';

/// Starts a process ([Process.start]'s shape; a test puts its own).
typedef ProcessStarter = Future<Process> Function(String executable, List<String> arguments, {ProcessStartMode mode});

/// Runs a process to its end ([Process.run]'s shape; a test puts its own).
typedef ProcessRunner = Future<ProcessResult> Function(String executable, List<String> arguments);

/// Where and how this copy installs an update.
class InstallTarget {
  const InstallTarget({required this.platform, required this.executable, required this.installDir});

  final UpdatePlatform platform;
  final String executable;

  /// Windows and Linux: the folder the program is in. macOS: the `.app`.
  final String installDir;
}

/// Why this copy cannot install an update itself.
enum InstallBlock {
  /// A phone or a tablet.
  notAComputer,

  /// The release has no file for this platform.
  noPackage,

  /// Windows: no ZestSSH setup installed this copy (no uninstaller beside
  /// it); macOS: the program is not inside an `.app`.
  notInstalledBySetup,

  /// The folder (or the one it is in) cannot be written by this account.
  folderNotWritable,

  /// Linux: a Flatpak, a Snap or an AppImage, which their system updates.
  systemPackage,

  /// macOS: run from the disk image itself.
  diskImage,

  /// macOS: run where macOS put a read-only copy (App Translocation).
  translocated,
}

/// What [AppUpdater.check] found.
sealed class InstallCheck {
  const InstallCheck();
}

/// It can: here is where.
class CanInstall extends InstallCheck {
  const CanInstall(this.target);
  final InstallTarget target;
}

/// It cannot, and why; [place] is the folder in question (for Copy
/// details, which takes the account's name out).
class CannotInstall extends InstallCheck {
  const CannotInstall(this.reason, {this.place});
  final InstallBlock reason;
  final String? place;
}

/// What [AppUpdater.launch] starts.
class PreparedUpdate {
  const PreparedUpdate({
    required this.version,
    this.build,
    required this.executable,
    required this.arguments,
    required this.logPath,
    this.staged,
    this.waitsForSetupLog = false,
    this.checks = const [],
  });

  final String version;

  /// The release's build number, where its manifest names one: the start
  /// after the update tells two builds of one version apart by it.
  final int? build;
  final String executable;
  final List<String> arguments;

  /// Where the installer or the helper writes what it did.
  final String logPath;

  /// The new folder or app made beside the running one (Linux, macOS),
  /// removed again where the launch fails.
  final String? staged;

  /// What [AppUpdater.launch] reads once more just before it starts anything:
  /// the setup itself (Windows), the helper script (Linux, macOS).
  final List<({String path, String sha256, int size})> checks;

  /// Windows: [AppUpdater.launch] returns only once the setup's log is
  /// there (it is installing), never on the start alone.
  final bool waitsForSetupLog;
}

/// An update that did not go through, with its code and, in English, what
/// exactly happened (for Copy details).
class UpdateFailure implements Exception, HasTypeName {
  const UpdateFailure(this.code, this.detail, [this.cause]) : notAllowed = false;

  /// Windows did not allow the setup (its UAC prompt answered No, or not
  /// answered in time): ZS-1905, said in its own words.
  const UpdateFailure.notAllowed(this.detail)
      : code = ErrorCodes.updateInstallFailed,
        cause = null,
        notAllowed = true;

  @override
  String get typeName => 'UpdateFailure';

  final ErrorCode code;
  final String detail;
  final Object? cause;

  /// See [UpdateFailure.notAllowed].
  final bool notAllowed;

  @override
  String toString() => '${code.code}: $detail';
}

/// The person cancelled the download.
class UpdateCancelled implements Exception, HasTypeName {
  const UpdateCancelled();

  @override
  String get typeName => 'UpdateCancelled';

  @override
  String toString() => 'The update was cancelled.';
}

/// Cancels a download under way.
class UpdateCancelToken {
  bool _cancelled = false;
  void Function()? _onCancel;

  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? _value;
  crypto.Digest get value => _value!;

  @override
  void add(crypto.Digest data) => _value = data;

  @override
  void close() {}
}
