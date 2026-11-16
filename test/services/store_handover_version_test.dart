import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/services/store_handover.dart';
import 'package:zestssh/services/store_handover_version.dart';
import 'package:zestssh/utils/windows_programs.dart';

/// The website copy hands over only to a Store copy at least as new as itself
/// (found in a review): how the two versions are read
/// and compared.
void main() {
  group('whether the Store copy may take this copy\'s data', () {
    bool takes(String store, String mine) =>
        storeCopyMayTakeOver(storeVersion: store, websiteVersion: mine);

    test('an older Store copy may not: 3.2.7 under 3.3.0', () {
      expect(takes('3.2.7.0', '3.3.0'), isFalse);
      expect(takes('3.2.7', '3.3.0'), isFalse);
      expect(takes('3.2.9.0', '3.3.0'), isFalse);
    });

    test(
      'the same version may: the package\'s 3.3.0.0 is the app\'s 3.3.0',
      () {
        expect(takes('3.3.0.0', '3.3.0'), isTrue);
        expect(takes('3.3.0', '3.3.0'), isTrue);
      },
    );

    test('a newer one may', () {
      expect(takes('3.3.1.0', '3.3.0'), isTrue);
      expect(takes('4.0.0.0', '3.3.0'), isTrue);
    });

    test('parts are numbers, not text: 3.10 is newer than 3.9', () {
      expect(takes('3.10.0.0', '3.9.0'), isTrue);
      expect(takes('3.9.0.0', '3.10.0'), isFalse);
      expect(takes('3.3.10.0', '3.3.9'), isTrue);
    });

    test(
      'a build part is left out: the Store package carries none (the msix tool drops it)',
      () {
        expect(takes('3.3.0.0', '3.3.0+300'), isTrue);
        expect(takes('3.2.7.0', '3.3.0+300'), isFalse);
        expect(takes('3.3.0+1', '3.3.0+999'), isTrue);
      },
    );

    test('what is not a version is never taken as older or newer', () {
      for (final pair in [
        ('', '3.3.0'),
        ('3.3.0.0', ''),
        ('garbage', '3.3.0'),
        ('3.3.x.0', '3.3.0'),
        ('3.3.0.0', 'v3.3.0'),
      ]) {
        expect(
          () => takes(pair.$1, pair.$2),
          throwsFormatException,
          reason: '$pair',
        );
      }
    });
  });

  // The same rule from the Store copy's side (found in a review):
  // it takes over a website copy of at most its own version,
  // read from that copy's program (3.4.0+310), its own from its program too.
  group('whether the Store copy may take over the website copy', () {
    bool takesOver(String mine, String website) =>
        storeCopyMayTakeOver(storeVersion: mine, websiteVersion: website);

    test('an older website copy, or the same release: yes', () {
      expect(takesOver('3.3.0', '3.2.7+299'), isTrue);
      expect(takesOver('3.3.0', '3.3.0+300'), isTrue);
      expect(
        takesOver('3.3.0', '3.3.0+301'),
        isTrue,
        reason: 'another build of the same release is the same version',
      );
      expect(takesOver('3.10.0', '3.9.4+400'), isTrue);
    });

    test('a newer website copy: no', () {
      expect(takesOver('3.3.0', '3.4.0+310'), isFalse);
      expect(takesOver('3.3.0', '3.3.1+305'), isFalse);
      expect(takesOver('3.9.0', '3.10.0+400'), isFalse);
    });
  });

  group('the version in a program file', () {
    test(
      'is its product version, as Windows itself reads it',
      () async {
        final cmd = windowsSystemProgram('cmd.exe');
        final read = programProductVersion(cmd);
        expect(read, isNotEmpty);
        expect(read, matches(RegExp(r'^\d+\.\d+')));
        // Windows' own reading of the same field (.NET's FileVersionInfo).
        final shell = await Process.run(windowsPowerShell, [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-Item -LiteralPath \$env:ZEST_PROBE).VersionInfo.ProductVersion',
        ], environment: {'ZEST_PROBE': cmd});
        expect(shell.exitCode, 0);
        expect(read, '${shell.stdout}'.trim());
      },
      skip: !Platform.isWindows,
    );

    test(
      'a file that is not there, or is no program: not read',
      () async {
        final dir = await Directory.systemTemp.createTemp('zest_program_');
        addTearDown(() => dir.delete(recursive: true));
        final text = File(p.join(dir.path, 'zestssh.exe'))
          ..writeAsStringSync('not a program');
        for (final path in [text.path, p.join(dir.path, 'missing.exe')]) {
          expect(
            () => programProductVersion(path),
            throwsA(isA<ProgramVersionUnreadable>()),
            reason: path,
          );
        }
      },
      skip: !Platform.isWindows,
    );
  });

  group('the version in a package\'s full name', () {
    test('is its second part', () {
      expect(
        packageVersionOf('AffluentLabs.ZestSSH_3.2.7.0_x64__a13075jvne08e'),
        '3.2.7.0',
      );
      expect(
        packageVersionOf(
          'Microsoft.Windows.ShellExperienceHost_10.0.26100.8115_neutral_neutral_cw5n1h2txyewy',
        ),
        '10.0.26100.8115',
      );
    });

    test('a name that holds none gives none', () {
      expect(packageVersionOf(''), isNull);
      expect(packageVersionOf('AffluentLabs.ZestSSH_a13075jvne08e'), isNull);
      expect(packageVersionOf('AffluentLabs.ZestSSH_3.2.7_x64__x'), isNull);
    });

    test('of several, the highest, compared as numbers', () {
      expect(
        highestPackageVersion([
          'AffluentLabs.ZestSSH_3.9.0.0_x64__a13075jvne08e',
          'AffluentLabs.ZestSSH_3.10.0.0_x64__a13075jvne08e',
          'not a package',
        ]),
        '3.10.0.0',
      );
      expect(highestPackageVersion(const []), isNull);
      expect(highestPackageVersion(['not a package']), isNull);
    });
  });

  group('asking Windows', () {
    const none = 'ZestSSH.NoSuchPackage_0000000000000';

    test(
      'GetPackagesByPackageFamily answers a family with no package: none',
      () {
        expect(packageFullNamesByFamily(none), isEmpty);
      },
      skip: !Platform.isWindows,
    );

    test('Get-AppxPackage answers the same', () async {
      expect(await packageFullNamesByPowerShell(none), isEmpty);
    }, skip: !Platform.isWindows);

    test('and the lookup says no Store copy for it', () async {
      expect(await installedStoreCopyVersion(family: none), isNull);
    }, skip: !Platform.isWindows);

    test(
      'only a family name\'s own letters go into the PowerShell command',
      () async {
        for (final family in [
          "x'; Write-Output 1 #_a13075jvne08e",
          'AffluentLabs.ZestSSH',
          'AffluentLabs ZestSSH_a13075jvne08e',
        ]) {
          await expectLater(
            packageFullNamesByPowerShell(family),
            throwsArgumentError,
            reason: family,
          );
        }
      },
    );

    test('the Store package is looked for by its family name', () {
      expect(StoreHandover.packageFamily, 'AffluentLabs.ZestSSH_a13075jvne08e');
      expect(
        RegExp(
          r'^[A-Za-z0-9.\-]+_[a-z0-9]{13}$',
        ).hasMatch(StoreHandover.packageFamily),
        isTrue,
      );
    });
  });
}
