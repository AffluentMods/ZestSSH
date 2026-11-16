import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/app_updater.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/services/update_manifest.dart';

/// The in-app updater's download, its checks, where it may install, and what
/// it starts (lib/services/app_updater.dart).
void main() {
  late Directory tmp;

  setUp(() async => tmp = await Directory.systemTemp.createTemp('zest-updater-test-'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  final payload = utf8.encode('the released installer, byte for byte ' * 50);
  final payloadSha = crypto.sha256.convert(payload).toString();
  const url = 'https://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe';

  UpdateInfo info({String sha = '', int? size, String at = url, String version = '3.0.1', int? build}) => UpdateInfo(
        version: version,
        build: build,
        downloadUrl: 'https://zestssh.com/download',
        package: UpdatePackage(url: Uri.parse(at), sha256: sha.isEmpty ? payloadSha : sha, size: size ?? payload.length),
      );

  /// An updater whose site answers with [respond]; the requests it saw.
  (AppUpdater, List<http.BaseRequest>) serving(
      Future<http.StreamedResponse> Function(http.BaseRequest r) respond) {
    final seen = <http.BaseRequest>[];
    final updater = AppUpdater(
      tempRoot: tmp,
      clientFactory: () => MockClient.streaming((r, _) {
        seen.add(r);
        return respond(r);
      }),
      platform: UpdatePlatform.windows,
      resumeWaits: const [Duration.zero, Duration.zero, Duration.zero],
    );
    return (updater, seen);
  }

  http.StreamedResponse ok(List<int> body, {int? length}) => http.StreamedResponse(
      Stream.fromIterable([for (var i = 0; i < body.length; i += 100) body.sublist(i, i + 100 > body.length ? body.length : i + 100)]),
      200,
      contentLength: length);

  Future<UpdateFailure> failure(Future<Object?> f) async {
    try {
      await f;
    } on UpdateFailure catch (e) {
      return e;
    }
    fail('no UpdateFailure');
  }

  bool leftovers(String version) => tmp
      .listSync()
      .whereType<Directory>()
      .where((d) => p.basename(d.path).startsWith('zestssh-update-$version-'))
      .any((d) => d.listSync().any((e) => e.path.endsWith('.part') || e.path.endsWith('.exe')));

  // Another account on the computer, and a same-account process before a setup
  // Windows elevates: the file hashed as it came was not the one unpacked or
  // started (found in a security review).
  group('the folder and the file', () {
    final evil = utf8.encode('what someone else put there');
    const windows = InstallTarget(platform: UpdatePlatform.windows, executable: r'C:\Z\zestssh.exe', installDir: r'C:\Z');

    test('a folder of the old fixed name, made first by someone else, is not used, and neither is any other', () async {
      final planted = Directory(p.join(tmp.path, 'zestssh-update', '3.0.1'))..createSync(recursive: true);
      File(p.join(planted.path, 'theirs.txt')).writeAsStringSync('still here');
      final (first, _) = serving((_) async => ok(payload, length: payload.length));
      final file = await first.download(info());
      expect(p.isWithin(planted.path, file.path), isFalse);
      expect(p.basename(p.dirname(file.path)), startsWith('zestssh-update-3.0.1-'));
      expect(planted.listSync(), hasLength(1), reason: 'theirs alone: nothing of ours went in');

      final (second, _) = serving((_) async => ok(payload, length: payload.length));
      final again = await second.download(info());
      expect(p.dirname(again.path), isNot(p.dirname(file.path)), reason: 'a name nobody can guess, made afresh');
    });

    test('only this account can open it', () async {
      final (updater, _) = serving((_) async => ok(payload, length: payload.length));
      final file = await updater.download(info());
      // The temporary folder there is the account's own.
      if (Platform.isWindows) return markTestSkipped('Windows: the temporary folder is the account own');
      expect(FileStat.statSync(p.dirname(file.path)).mode & 0x3f, 0);
    });

    test('a retry of the same version uses the folder it made', () async {
      final (updater, _) = serving((_) async => ok(payload, length: payload.length));
      final file = await updater.download(info());
      final again = await updater.download(info());
      expect(again.path, file.path);
      expect(updater.workDir('3.0.1').path, p.dirname(file.path));
    });

    test('Windows: a file changed after it was downloaded is refused by prepare, and deleted (ZS-1903)', () async {
      final (updater, _) = serving((_) async => ok(payload, length: payload.length));
      final file = await updater.download(info());
      file.writeAsBytesSync(evil);
      final f = await failure(updater.prepare(info(), file, windows, currentVersion: '3.0.0'));
      expect(f.code, ErrorCodes.updateFileMismatch);
      expect(f.detail, contains('changed after'));
      expect(file.existsSync(), isFalse);
    });

    test('Windows: one changed after prepare is refused just before it starts: nothing is started', () async {
      final started = <String>[];
      final updater = AppUpdater(
        tempRoot: tmp,
        platform: UpdatePlatform.windows,
        clientFactory: () => MockClient.streaming((r, _) async => ok(payload, length: payload.length)),
        start: (exe, args, {mode = ProcessStartMode.normal}) async {
          started.add(exe);
          return _SetupProcess();
        },
      );
      final file = await updater.download(info());
      final prepared = await updater.prepare(info(), file, windows, currentVersion: '3.0.0');
      file.writeAsBytesSync(evil);
      final f = await failure(updater.launch(prepared));
      expect(f.code, ErrorCodes.updateFileMismatch);
      expect(started, isEmpty);
      expect(file.existsSync(), isFalse);
    });

    test('Linux: a changed archive is not unpacked; a changed helper is not run, and what was unpacked goes', () async {
      final install = p.join(tmp.path, 'home', 'ZestSSH');
      await Directory(install).create(recursive: true);
      final ran = <String>[];
      final started = <String>[];
      final updater = AppUpdater(
        tempRoot: tmp,
        pid: 4242,
        platform: UpdatePlatform.linux,
        clientFactory: () => MockClient.streaming((r, _) async => ok(payload, length: payload.length)),
        run: (exe, args) async {
          ran.add(exe);
          File(p.join(args[3], 'zestssh')).writeAsStringSync('#!/bin/sh\n');
          return ProcessResult(0, 0, '', '');
        },
        start: (exe, args, {mode = ProcessStartMode.normal}) async {
          started.add(exe);
          return _SetupProcess();
        },
      );
      final target = InstallTarget(platform: UpdatePlatform.linux, executable: p.join(install, 'zestssh'), installDir: install);

      final swapped = await updater.download(info());
      swapped.writeAsBytesSync(evil);
      final f = await failure(updater.prepare(info(), swapped, target, currentVersion: '3.0.0'));
      expect(f.code, ErrorCodes.updateFileMismatch);
      expect(ran, isEmpty, reason: 'tar was never run');

      final good = await updater.download(info());
      final prepared = await updater.prepare(info(), good, target, currentVersion: '3.0.0');
      expect(ran, ['tar']);
      File(prepared.arguments.first).writeAsStringSync('#!/bin/sh\necho theirs\n');
      final g = await failure(updater.launch(prepared));
      expect(g.code, ErrorCodes.updateFileMismatch);
      expect(started, isEmpty);
      expect(Directory(prepared.staged!).existsSync(), isFalse);
    });

    test('the file as it was downloaded goes through both', () async {
      final started = <String>[];
      final updater = AppUpdater(
        tempRoot: tmp,
        platform: UpdatePlatform.windows,
        clientFactory: () => MockClient.streaming((r, _) async => ok(payload, length: payload.length)),
        start: (exe, args, {mode = ProcessStartMode.normal}) async {
          started.add(exe);
          File(args.last.substring('/LOG='.length)).writeAsStringSync('Log opened.');
          return _SetupProcess();
        },
      );
      final file = await updater.download(info());
      final prepared = await updater.prepare(info(), file, windows, currentVersion: '3.0.0');
      expect(p.dirname(prepared.logPath), p.dirname(file.path));
      await updater.launch(prepared);
      expect(started, [file.path]);
    });
  });

  group('the download', () {
    test('a file of the signed size and SHA-256 is given, with its progress, and the request says nothing of the device',
        () async {
      final (updater, seen) = serving((_) async => ok(payload, length: payload.length));
      final progress = <int>[];
      final file = await updater.download(info(), onProgress: (got, total) {
        expect(total, payload.length);
        progress.add(got);
      });
      expect(await file.readAsBytes(), payload);
      expect(p.basename(file.path), 'ZestSSH-3.0.1-Setup.exe');
      expect(progress.first, 0);
      expect(progress.last, payload.length);
      final r = seen.single as http.Request;
      expect(r.url.toString(), url);
      expect(r.followRedirects, isFalse, reason: 'a redirect is checked by hand, not followed blindly');
      expect(r.headers.keys, ['Accept']);
      expect(r.url.hasQuery, isFalse);
    });

    test('a SHA-256 that differs is refused and the file deleted (ZS-1903)', () async {
      final (updater, _) = serving((_) async => ok(payload));
      final f = await failure(updater.download(info(sha: 'f' * 64)));
      expect(f.code, ErrorCodes.updateFileMismatch);
      expect(f.detail, contains('SHA-256'));
      expect(leftovers('3.0.1'), isFalse);
    });

    test('a size that differs is refused: fewer bytes, more bytes, or a length the site says first (ZS-1903)',
        () async {
      for (final (body, length, size) in [
        (payload.sublist(0, payload.length - 1), null, payload.length),
        (payload, null, payload.length - 10),
        (payload, payload.length, payload.length + 1),
      ]) {
        final (updater, _) = serving((_) async => ok(body, length: length));
        final f = await failure(updater.download(info(size: size)));
        expect(f.code, ErrorCodes.updateFileMismatch);
        expect(leftovers('3.0.1'), isFalse);
      }
    });

    test('a redirect elsewhere is not followed; one to another allowed URL is (and checked again)', () async {
      final (away, seenAway) = serving((_) async => http.StreamedResponse(const Stream.empty(), 302,
          headers: {'location': 'https://evil.example/downloads/ZestSSH-3.0.1-Setup.exe'}));
      final f = await failure(away.download(info()));
      expect(f.code, ErrorCodes.updateDownloadFailed);
      expect(seenAway, hasLength(1), reason: 'evil.example is never asked');

      final (moved, seenMoved) = serving((r) async => r.url.path.endsWith('Setup.exe')
          ? http.StreamedResponse(const Stream.empty(), 301, headers: {'location': '/downloads/ZestSSH-3.0.1-Setup-b.exe'})
          : ok(payload));
      final file = await moved.download(info());
      expect(await file.readAsBytes(), payload);
      expect(seenMoved.last.url.toString(), 'https://zestssh.com/downloads/ZestSSH-3.0.1-Setup-b.exe');
    });

    test('a URL that is not https on zestssh.com is never requested', () async {
      final (updater, seen) = serving((_) async => ok(payload));
      final f = await failure(updater.download(info(at: 'http://zestssh.com/downloads/ZestSSH-3.0.1-Setup.exe')));
      expect(f.code, ErrorCodes.updateNotSigned);
      expect(seen, isEmpty);
    });

    test('the site saying no, or no network, is ZS-1901', () async {
      final (notFound, _) = serving((_) async => http.StreamedResponse(const Stream.empty(), 404));
      expect((await failure(notFound.download(info()))).code, ErrorCodes.updateDownloadFailed);
      final (offline, _) = serving((_) async => throw http.ClientException('offline'));
      expect((await failure(offline.download(info()))).code, ErrorCodes.updateDownloadFailed);
    });

    /// The file's bytes from [from], 100 at a time, then the connection
    /// closing after [upTo] of them where given.
    Stream<List<int>> dropping(int from, {int? upTo}) async* {
      final end = upTo ?? payload.length;
      for (var i = from; i < end; i += 100) {
        yield payload.sublist(i, i + 100 > end ? end : i + 100);
      }
      if (upTo != null) throw http.ClientException('Connection closed while receiving data');
    }

    int? rangeOf(http.BaseRequest r) {
      final h = r.headers['Range'];
      return h == null ? null : int.parse(h.substring('bytes='.length, h.length - 1));
    }

    test('a connection that drops mid-way is picked up where it stopped, and the file checked as one', () async {
      final (updater, seen) = serving((r) async {
        final from = rangeOf(r);
        if (from == null) return http.StreamedResponse(dropping(0, upTo: 700), 200, contentLength: payload.length);
        // The second part drops too; the third brings the rest.
        return http.StreamedResponse(dropping(from, upTo: from == 700 ? 1300 : null), 206,
            headers: {'content-range': 'bytes $from-${payload.length - 1}/${payload.length}'});
      });
      final progress = <int>[];
      final file = await updater.download(info(), onProgress: (got, _) => progress.add(got));
      expect(await file.readAsBytes(), payload);
      expect([for (final r in seen) rangeOf(r)], [null, 700, 1300]);
      expect(progress.last, payload.length);
      expect(progress, orderedEquals([...progress]..sort()), reason: 'progress only goes on');
    });

    test('a site that sends all of it again is taken from the start; another part than asked for is refused',
        () async {
      var asked = 0;
      final (again, _) = serving((r) async => asked++ == 0
          ? http.StreamedResponse(dropping(0, upTo: 500), 200, contentLength: payload.length)
          : ok(payload, length: payload.length));
      final whole = await again.download(info());
      expect(await whole.readAsBytes(), payload);
      await whole.delete();

      var tries = 0;
      final (wrong, _) = serving((r) async => tries++ == 0
          ? http.StreamedResponse(dropping(0, upTo: 500), 200, contentLength: payload.length)
          : http.StreamedResponse(dropping(0), 206, headers: {'content-range': 'bytes 0-${payload.length - 1}/${payload.length}'}));
      final f = await failure(wrong.download(info()));
      expect(f.code, ErrorCodes.updateFileMismatch);
      expect(leftovers('3.0.1'), isFalse);
    });

    test('a connection that keeps dropping gives up after three tries, ZS-1901, and nothing is left', () async {
      final (updater, seen) = serving((r) async {
        final from = rangeOf(r) ?? 0;
        return http.StreamedResponse(dropping(from, upTo: from + 100), from == 0 ? 200 : 206,
            contentLength: from == 0 ? payload.length : null,
            headers: {if (from > 0) 'content-range': 'bytes $from-${payload.length - 1}/${payload.length}'});
      });
      final f = await failure(updater.download(info()));
      expect(f.code, ErrorCodes.updateDownloadFailed);
      expect(seen, hasLength(4), reason: 'the first try and three more');
      expect(leftovers('3.0.1'), isFalse);
    });

    test('a cancel stops it, and the part already written is deleted', () async {
      final chunks = StreamController<List<int>>();
      final (updater, _) = serving((_) async => http.StreamedResponse(chunks.stream, 200));
      final token = UpdateCancelToken();
      final going = updater.download(info(), cancel: token, onProgress: (got, _) {
        if (got > 0) token.cancel();
      });
      chunks.add(payload.sublist(0, 100));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      chunks.add(payload.sublist(100, 200));
      await expectLater(going, throwsA(isA<UpdateCancelled>()));
      await chunks.close();
      expect(leftovers('3.0.1'), isFalse);
    });
  });

  group('where this copy may update itself', () {
    test('Windows: only a copy the setup installed (its uninstaller beside it)', () async {
      final exe = p.join(tmp.path, 'ZestSSH', 'zestssh.exe');
      await File(exe).create(recursive: true);
      final updater = AppUpdater(executable: exe, platform: UpdatePlatform.windows, environment: const {});
      final no = updater.check(info());
      expect((no as CannotInstall).reason, InstallBlock.notInstalledBySetup);
      await File(p.join(tmp.path, 'ZestSSH', 'unins000.exe')).create();
      final yes = updater.check(info());
      expect((yes as CanInstall).target.installDir, p.dirname(exe));
    });

    test('a release with no file for this computer offers the download page', () {
      final updater = AppUpdater(platform: UpdatePlatform.windows);
      const noPackage = UpdateInfo(version: '3.0.1', downloadUrl: 'https://zestssh.com/download');
      expect((updater.check(noPackage) as CannotInstall).reason, InstallBlock.noPackage);
    });

    test('Linux: a folder this account can write to, never a Flatpak, Snap or AppImage', () async {
      final exe = p.join(tmp.path, 'zestssh', 'zestssh');
      await File(exe).create(recursive: true);
      expect(AppUpdater(executable: exe, platform: UpdatePlatform.linux, environment: const {}).check(info()),
          isA<CanInstall>());
      for (final env in const [
        {'FLATPAK_ID': 'com.affluentlabs.zestssh'},
        {'SNAP': '/snap/zestssh/1'},
        {'APPIMAGE': '/home/a/ZestSSH.AppImage'},
      ]) {
        final c = AppUpdater(executable: exe, platform: UpdatePlatform.linux, environment: env).check(info());
        expect((c as CannotInstall).reason, InstallBlock.systemPackage);
      }
    });

    test('macOS: the .app it runs from, never the disk image or a translocated copy', () {
      expect(AppUpdater.macBundleOf('/Applications/ZestSSH.app/Contents/MacOS/ZestSSH'), '/Applications/ZestSSH.app');
      expect(AppUpdater.macBundleOf('/usr/local/bin/zestssh'), isNull);
      CannotInstall mac(String exe) =>
          AppUpdater(executable: exe, platform: UpdatePlatform.macos, environment: const {}).check(info()) as CannotInstall;
      expect(mac('/Volumes/ZestSSH/ZestSSH.app/Contents/MacOS/ZestSSH').reason, InstallBlock.diskImage);
      expect(mac('/private/var/folders/x/T/AppTranslocation/1A2B/d/ZestSSH.app/Contents/MacOS/ZestSSH').reason,
          InstallBlock.translocated);
      expect(mac('/usr/local/bin/zestssh').reason, InstallBlock.notInstalledBySetup);
    });
  });

  group('what is started', () {
    test('Windows: the setup, silent, relaunching, logging, every argument its own', () async {
      final log = p.join(r'C:\Users\Some One\AppData\Local\Temp', 'zestssh-update', '3.0.1', 'setup.log');
      expect(windowsInstallerArgs(logPath: log), [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
        '/FROMAPP',
        '/RELAUNCH',
        '/LOG=$log',
      ]);
      // Update and close: started by the app all the same, opening nothing.
      expect(windowsInstallerArgs(logPath: log, relaunch: false), [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
        '/FROMAPP',
        '/LOG=$log',
      ]);

      final started = <(String, List<String>, ProcessStartMode)>[];
      final updater = AppUpdater(
        tempRoot: tmp,
        platform: UpdatePlatform.windows,
        start: (exe, args, {mode = ProcessStartMode.normal}) async {
          started.add((exe, args, mode));
          // The setup opens its log once it installs (Inno does, after UAC).
          File(args.last.substring('/LOG='.length)).writeAsStringSync('Log opened.');
          return _SetupProcess();
        },
      );
      final setup = File(p.join(tmp.path, 'ZestSSH-3.0.1-Setup.exe'))..writeAsBytesSync(payload);
      const target = InstallTarget(platform: UpdatePlatform.windows, executable: r'C:\Z\zestssh.exe', installDir: r'C:\Z');
      final prepared = await updater.prepare(info(), setup, target, currentVersion: '3.0.0');
      expect(prepared.executable, setup.path);
      expect(prepared.arguments.last, '/LOG=${p.join(updater.workDir('3.0.1').path, 'setup.log')}');
      await updater.launch(prepared);
      expect(started.single.$1, setup.path);
      expect(started.single.$3, ProcessStartMode.normal,
          reason: 'the app must see a setup that Windows did not allow end; it still outlives the app (no job object)');
      expect(prepared.waitsForSetupLog, isTrue);
      expect(prepared.arguments, contains('/RELAUNCH'));
      final closing = await updater.prepare(info(), setup, target, currentVersion: '3.0.0', reopen: false);
      expect(closing.arguments, isNot(contains('/RELAUNCH')));
      expect(closing.arguments, contains('/FROMAPP'));
    });

    test('no downgrade, and no "update" to the running version', () async {
      final updater = AppUpdater(tempRoot: tmp, platform: UpdatePlatform.windows);
      final setup = File(p.join(tmp.path, 'x.exe'))..writeAsBytesSync(payload);
      const target = InstallTarget(platform: UpdatePlatform.windows, executable: r'C:\Z\zestssh.exe', installDir: r'C:\Z');
      for (final running in ['3.0.1', '3.1.0']) {
        final f = await failure(updater.prepare(info(), setup, target, currentVersion: running));
        expect(f.code, ErrorCodes.updateNotSigned);
      }
    });

    test('another build of the running version: only a higher one goes in, and it is noted with its build', () async {
      final updater = AppUpdater(tempRoot: tmp, platform: UpdatePlatform.windows);
      final setup = File(p.join(tmp.path, 'x.exe'))..writeAsBytesSync(payload);
      const target = InstallTarget(platform: UpdatePlatform.windows, executable: r'C:\Z\zestssh.exe', installDir: r'C:\Z');
      final b280 = info(version: '3.0.0', build: 280);
      final prepared = await updater.prepare(b280, setup, target, currentVersion: '3.0.0', currentBuild: 279);
      expect(prepared.version, '3.0.0');
      expect(prepared.build, 280);
      for (final running in [280, 281, null]) {
        final f = await failure(updater.prepare(b280, setup, target, currentVersion: '3.0.0', currentBuild: running));
        expect(f.code, ErrorCodes.updateNotSigned, reason: 'running build $running');
      }
      // A release that names no build is not newer than its own version.
      final f = await failure(updater.prepare(info(version: '3.0.0'), setup, target, currentVersion: '3.0.0', currentBuild: 1));
      expect(f.code, ErrorCodes.updateNotSigned);
    });

    test('Linux: unpacked beside the install folder, the helper given every path as an argument', () async {
      final install = p.join(tmp.path, r"apps $(touch PWNED) 'q'", 'ZestSSH');
      await Directory(install).create(recursive: true);
      final ran = <(String, List<String>)>[];
      final updater = AppUpdater(
        tempRoot: tmp,
        pid: 4242,
        platform: UpdatePlatform.linux,
        run: (exe, args) async {
          ran.add((exe, args));
          // tar -xzf <file> -C <staging>: what the release archive holds.
          File(p.join(args[3], 'zestssh')).writeAsStringSync('#!/bin/sh\n');
          return ProcessResult(0, 0, '', '');
        },
      );
      final archive = File(p.join(tmp.path, 'ZestSSH-3.0.1-linux-x64.tar.gz'))..writeAsBytesSync(payload);
      final prepared = await updater.prepare(info(), archive,
          InstallTarget(platform: UpdatePlatform.linux, executable: p.join(install, 'zestssh'), installDir: install),
          currentVersion: '3.0.0');
      final staging = p.join(p.dirname(install), '.zestssh-update-3.0.1');
      expect(ran.single.$1, 'tar');
      expect(ran.single.$2, ['-xzf', archive.path, '-C', staging]);
      expect(prepared.executable, '/bin/sh');
      final script = prepared.arguments.first;
      expect(prepared.arguments.sublist(1), ['4242', install, staging, prepared.logPath, 'open']);
      expect(File(script).readAsStringSync(), kLinuxSwapScript);
      final closing = await updater.prepare(info(), archive,
          InstallTarget(platform: UpdatePlatform.linux, executable: p.join(install, 'zestssh'), installDir: install),
          currentVersion: '3.0.0', reopen: false);
      expect(closing.arguments.last, 'stay', reason: 'Update and close: the helper opens nothing');
    });

    test('Linux: an archive without the program is refused, and what was unpacked removed', () async {
      final install = p.join(tmp.path, 'ZestSSH');
      await Directory(install).create(recursive: true);
      final updater = AppUpdater(
        tempRoot: tmp,
        platform: UpdatePlatform.linux,
        run: (exe, args) async => ProcessResult(0, 0, '', ''),
      );
      final archive = File(p.join(tmp.path, 'a.tar.gz'))..writeAsBytesSync(payload);
      final f = await failure(updater.prepare(info(), archive,
          InstallTarget(platform: UpdatePlatform.linux, executable: p.join(install, 'zestssh'), installDir: install),
          currentVersion: '3.0.0'));
      expect(f.code, ErrorCodes.updateInstallFailed);
      expect(Directory(p.join(tmp.path, '.zestssh-update-3.0.1')).existsSync(), isFalse);
    });

    test('macOS: the image attached read-only, the app copied beside the old one, its version checked, the image detached',
        () async {
      final bundle = p.join(tmp.path, 'Applications', 'ZestSSH.app');
      await Directory(bundle).create(recursive: true);
      final ran = <(String, List<String>)>[];
      var plistVersion = '3.0.1';
      final updater = AppUpdater(
        tempRoot: tmp,
        pid: 77,
        platform: UpdatePlatform.macos,
        run: (exe, args) async {
          ran.add((exe, args));
          if (exe.endsWith('hdiutil') && args.first == 'attach') {
            Directory(p.join(args[args.indexOf('-mountpoint') + 1], 'ZestSSH.app')).createSync(recursive: true);
          }
          if (exe.endsWith('PlistBuddy')) return ProcessResult(0, 0, '$plistVersion\n', '');
          return ProcessResult(0, 0, '', '');
        },
      );
      final dmg = File(p.join(tmp.path, 'ZestSSH-3.0.1.dmg'))..writeAsBytesSync(payload);
      final target = InstallTarget(platform: UpdatePlatform.macos, executable: p.join(bundle, 'Contents', 'MacOS', 'ZestSSH'), installDir: bundle);
      final prepared = await updater.prepare(info(), dmg, target, currentVersion: '3.0.0');
      final mount = p.join(updater.workDir('3.0.1').path, 'mnt');
      final staged = p.join(p.dirname(bundle), '.ZestSSH-update-3.0.1.app');
      expect(ran[0].$1, '/usr/bin/hdiutil');
      expect(ran[0].$2, ['attach', '-nobrowse', '-readonly', '-noautoopen', '-mountpoint', mount, dmg.path]);
      expect(ran[1].$1, '/usr/bin/ditto');
      expect(ran[1].$2, [p.join(mount, 'ZestSSH.app'), staged]);
      expect(ran[2].$1, '/usr/libexec/PlistBuddy');
      expect(ran.last.$1, '/usr/bin/hdiutil');
      expect(ran.last.$2, ['detach', mount]);
      expect(prepared.arguments.sublist(1), ['77', bundle, staged, prepared.logPath, 'open']);
      expect(File(prepared.arguments.first).readAsStringSync(), kMacSwapScript);

      // A disk image that holds another version is refused, and still detached.
      ran.clear();
      plistVersion = '3.0.0';
      final f = await failure(updater.prepare(info(), dmg, target, currentVersion: '3.0.0'));
      expect(f.code, ErrorCodes.updateInstallFailed);
      expect(f.detail, contains('3.0.0'));
      expect(ran.last.$1, '/usr/bin/hdiutil');
      expect(ran.last.$2, ['detach', mount]);
    });

    test("macOS: where the release names its build, the copied app's build must be it", () async {
      final bundle = p.join(tmp.path, 'Applications', 'ZestSSH.app');
      await Directory(bundle).create(recursive: true);
      final asked = <String>[];
      var plistBuild = '280';
      final updater = AppUpdater(
        tempRoot: tmp,
        pid: 77,
        platform: UpdatePlatform.macos,
        run: (exe, args) async {
          if (exe.endsWith('hdiutil') && args.first == 'attach') {
            Directory(p.join(args[args.indexOf('-mountpoint') + 1], 'ZestSSH.app')).createSync(recursive: true);
          }
          if (exe.endsWith('PlistBuddy')) {
            asked.add(args[1]);
            return ProcessResult(0, 0, args[1].contains('CFBundleVersion') ? '$plistBuild\n' : '3.0.0\n', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );
      final dmg = File(p.join(tmp.path, 'ZestSSH-3.0.0.dmg'))..writeAsBytesSync(payload);
      final target = InstallTarget(platform: UpdatePlatform.macos, executable: p.join(bundle, 'Contents', 'MacOS', 'ZestSSH'), installDir: bundle);
      final b280 = info(version: '3.0.0', build: 280);
      final prepared = await updater.prepare(b280, dmg, target, currentVersion: '3.0.0', currentBuild: 279);
      expect(prepared.build, 280);
      expect(asked, ['Print :CFBundleShortVersionString', 'Print :CFBundleVersion']);

      plistBuild = '279';
      final f = await failure(updater.prepare(b280, dmg, target, currentVersion: '3.0.0', currentBuild: 279));
      expect(f.code, ErrorCodes.updateInstallFailed);
      expect(f.detail, contains('build 279'));
    });

    group('Windows: the app quits only once the setup is really installing', () {
      const target = InstallTarget(platform: UpdatePlatform.windows, executable: r'C:\Z\zestssh.exe', installDir: r'C:\Z');

      /// An updater whose setup is [setup]; what it ran (taskkill) and started.
      Future<(AppUpdater, PreparedUpdate, List<(String, List<String>)>)> windows(
          _SetupProcess setup, {void Function(String log)? onStart, Duration timeout = const Duration(seconds: 5)}) async {
        final ran = <(String, List<String>)>[];
        final updater = AppUpdater(
          tempRoot: tmp,
          platform: UpdatePlatform.windows,
          setupStartTimeout: timeout,
          setupPoll: const Duration(milliseconds: 5),
          setupQuietWait: const Duration(milliseconds: 20),
          start: (exe, args, {mode = ProcessStartMode.normal}) async {
            onStart?.call(args.last.substring('/LOG='.length));
            return setup;
          },
          run: (exe, args) async {
            ran.add((exe, args));
            return ProcessResult(0, 0, '', '');
          },
        );
        final file = File(p.join(tmp.path, 'ZestSSH-3.0.1-Setup.exe'))..writeAsBytesSync(payload);
        final prepared = await updater.prepare(info(), file, target, currentVersion: '3.0.0');
        return (updater, prepared, ran);
      }

      test('UAC answered Yes: it waits (saying so) until the log is there, then returns', () async {
        final setup = _SetupProcess();
        final (updater, prepared, ran) = await windows(setup, onStart: (log) {
          Future<void>.delayed(const Duration(milliseconds: 120), () => File(log).writeAsStringSync('Log opened.'));
        });
        var waiting = 0;
        await updater.launch(prepared, onWaiting: () => waiting++);
        expect(waiting, 1, reason: 'the dialog says it waits for Windows, once');
        expect(ran, isEmpty, reason: 'nothing is stopped');
        expect(File(windowsCancelMarkerFor(prepared.logPath)).existsSync(), isFalse);
      });

      test('UAC answered No: the setup ends with exit code 2 and no log; the app stays (Windows did not allow it)', () async {
        final setup = _SetupProcess();
        final (updater, prepared, _) = await windows(setup, onStart: (_) {
          Future<void>.delayed(const Duration(milliseconds: 60), () => setup.end(kSetupCancelledExitCode));
        });
        final f = await failure(updater.launch(prepared));
        expect(f.notAllowed, isTrue);
        expect(f.code, ErrorCodes.updateInstallFailed, reason: 'ZS-1905');
        expect(f.detail, contains('exit code 2'));
      });

      test('the setup ends another way before its log: ZS-1905 with its exit code, not "not allowed"', () async {
        final setup = _SetupProcess();
        final (updater, prepared, _) = await windows(setup, onStart: (_) => setup.end(1));
        final f = await failure(updater.launch(prepared));
        expect(f.notAllowed, isFalse);
        expect(f.code, ErrorCodes.updateInstallFailed);
        expect(f.detail, contains('exit code 1'));
      });

      test('no answer in time: the setup is stopped and told not to install; the app stays', () async {
        final setup = _SetupProcess();
        final (updater, prepared, ran) = await windows(setup, timeout: const Duration(milliseconds: 150));
        final f = await failure(updater.launch(prepared));
        expect(f.notAllowed, isTrue);
        expect(File(windowsCancelMarkerFor(prepared.logPath)).existsSync(), isTrue,
            reason: 'a Yes given later installs nothing (zestssh_setup.iss reads it)');
        expect(ran.single.$1, 'taskkill');
        expect(ran.single.$2, ['/PID', '${setup.pid}', '/T', '/F']);
        expect(setup.killed, isTrue);
      });

      test('Cancel while it waits: stopped and marked the same, and said as a cancel', () async {
        final setup = _SetupProcess();
        final token = UpdateCancelToken();
        final (updater, prepared, ran) = await windows(setup);
        await expectLater(updater.launch(prepared, cancel: token, onWaiting: token.cancel), throwsA(isA<UpdateCancelled>()));
        expect(File(windowsCancelMarkerFor(prepared.logPath)).existsSync(), isTrue);
        expect(ran.single.$1, 'taskkill');
      });

      test('a log or a marker left by an earlier try counts for nothing: both are removed first', () async {
        final setup = _SetupProcess();
        late String logPath;
        final (updater, prepared, _) = await windows(setup, onStart: (log) {
          logPath = log;
          expect(File(log).existsSync(), isFalse, reason: 'the old log is gone before the setup starts');
          expect(File(windowsCancelMarkerFor(log)).existsSync(), isFalse);
          setup.end(kSetupCancelledExitCode);
        });
        File(prepared.logPath).writeAsStringSync('an old log');
        File(windowsCancelMarkerFor(prepared.logPath)).writeAsStringSync('an old marker');
        final f = await failure(updater.launch(prepared));
        expect(f.notAllowed, isTrue);
        expect(logPath, prepared.logPath);
      });

      test('the setup script reads the same marker; /FROMAPP (or an older app\'s /RELAUNCH) is the app\'s update, '
          '/RELAUNCH alone opens it again', () {
        final iss = File('installer/zestssh_setup.iss').readAsStringSync().replaceAll('\r\n', '\n');
        expect(windowsCancelMarkerFor(r'C:\T\setup.log'), r'C:\T\setup.log.cancelled');
        expect(iss, contains("Copy(P, 6, Length(P) - 5) + '.cancelled'"));
        expect(iss, contains('and not UpdateCancelledByApp() do'));
        expect(iss, contains('if UpdateCancelledByApp() then'));
        expect(iss, contains('CompareText(ParamStr(I), Name) = 0'));
        // Update and close leaves /RELAUNCH out: the setup must still wait for
        // the app to quit (never taskkill /T, which ends the setup with it).
        expect(iss, contains("Result := HasParam('/FROMAPP') or HasParam('/RELAUNCH');"));
        expect(iss, contains("Result := WizardSilent and HasParam('/RELAUNCH');"));
        expect(windowsInstallerArgs(logPath: 'l', relaunch: false), contains('/FROMAPP'));
      });
    });

    test('a launch that fails is ZS-1905, and what was staged is removed', () async {
      final staged = Directory(p.join(tmp.path, '.zestssh-update-3.0.1'))..createSync();
      final updater = AppUpdater(
        tempRoot: tmp,
        platform: UpdatePlatform.linux,
        start: (exe, args, {mode = ProcessStartMode.normal}) async => throw const ProcessException('/bin/sh', [], 'no'),
      );
      final f = await failure(updater.launch(PreparedUpdate(
          version: '3.0.1', executable: '/bin/sh', arguments: const ['x'], logPath: 'l', staged: staged.path)));
      expect(f.code, ErrorCodes.updateInstallFailed);
      expect(staged.existsSync(), isFalse);
    });
  });

  group('the helper scripts', () {
    for (final (name, script) in [('Linux', kLinuxSwapScript), ('macOS', kMacSwapScript)]) {
      test('$name: takes every value as an argument and uses it only in double quotes', () {
        expect(script, startsWith('#!/bin/sh\n'));
        expect(script, contains('pid="\$1"\napp="\$2"\nnew="\$3"\nlog="\$4"\n'));
        for (final raw in script.split('\n')) {
          final line = raw.trimLeft();
          if (line.startsWith('#')) continue;
          // Every expansion of a variable outside double quotes is a word a
          // folder's name could split or glob: there must be none.
          var quoted = false;
          var single = false;
          for (var i = 0; i < line.length; i++) {
            final c = line[i];
            if (c == "'" && !quoted) single = !single;
            if (c == '"' && !single) quoted = !quoted;
            if (c == r'$' && !quoted && !single && i + 1 < line.length) {
              final next = line[i + 1];
              final arithmetic = line.startsWith(r'$((', i);
              expect(RegExp(r'[A-Za-z_{0-9@*]').hasMatch(next) && !arithmetic, isFalse,
                  reason: 'unquoted expansion in: $raw');
            }
          }
          expect(line.contains('eval'), isFalse);
          expect(line.contains('`'), isFalse, reason: 'no command substitution');
        }
        // Waits for the app, a minute at most, and puts the old one back where the new one does not go in.
        expect(script, contains('kill -0 "\$pid"'));
        expect(script, contains('mv -- "\$old" "\$app"'));
        expect(script, contains('rm -rf -- "\$old"'));
      });
    }
  });
}

/// The Windows setup's first process, as the updater sees it: it runs
/// until [end].
class _SetupProcess implements Process {
  final _ended = Completer<int>();
  bool killed = false;

  void end(int code) {
    if (!_ended.isCompleted) _ended.complete(code);
  }

  @override
  int get pid => 4321;
  @override
  Future<int> get exitCode => _ended.future;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    end(1);
    return true;
  }
}
