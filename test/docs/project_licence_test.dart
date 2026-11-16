import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/native_notices.dart' show separator;
import '../helpers/repository_text.dart';

/// The app's own licence (4.0): the GNU GPL version 3 as the FSF publishes it, the additional
/// permission under its section 7 for the closed libraries the official builds link, the files a
/// person who opens the repository looks for, and the same licence in every place that names one.
void main() {
  String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

  test('LICENSE is the GNU GPL version 3, byte for byte as the FSF publishes it', () {
    // The SHA-256 of https://www.gnu.org/licenses/gpl-3.0.txt (35,149 bytes, 674 lines); the copy
    // here came from Debian's base-files (/usr/share/common-licenses/GPL-3), checked with dpkg.
    final bytes = utf8.encode(read('LICENSE'));
    expect(bytes.length, 35149);
    expect(sha256.convert(bytes).toString(), '3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986');
    expect(File('.gitattributes').readAsStringSync(), contains('LICENSE text eol=lf'));
  });

  test('the additional permission names every closed library family the official builds link', () {
    final exception = read('LICENSE-EXCEPTION.txt');
    expect(exception, contains('Additional permission under GNU GPL version 3 section 7'));
    expect(exception, contains('Copyright © 2026 Affluent Labs LLC'));
    expect(exception, contains('delete this permission statement from your'));
    const groups = [
      'com.google.android.gms', // Play services: Google Sign-In, Credential Manager's module, ML Kit's
      'com.google.mlkit', // the barcode scanner (mobile_scanner, android/app/build.gradle.kts)
      'com.google.firebase', // firebase_core, firebase_auth
      'com.google.android.recaptcha', // through firebase-auth
      'com.google.android.play', // Play In-App Review (in_app_review), Play Integrity
      'com.android.billingclient', // through RevenueCat (purchases_flutter)
      'com.amazon.device', // the Amazon Appstore SDK, through RevenueCat
      'com.revenuecat.purchases', // open source, named so that it needs no argument
    ];
    for (final group in groups) {
      expect(exception, contains(group), reason: group);
    }
    // A Maven library the app names itself, from a vendor whose libraries are closed, is one of the
    // groups above: a new one is added to the permission (and NOTICE, README) on purpose.
    final gradle = read('android/app/build.gradle.kts');
    final named = RegExp(r'''(?:implementation|api)\("([a-z0-9.\-]+):''').allMatches(gradle).map((m) => m.group(1)!);
    for (final group in named.where((g) => g.startsWith('com.google.') || g.startsWith('com.android.') || g.startsWith('com.amazon.'))) {
      expect(groups.any((g) => group == g || group.startsWith('$g.')), isTrue, reason: '$group is not in LICENSE-EXCEPTION.txt');
    }
    // The plugins that bring them, as pubspec.yaml names them.
    final pubspec = read('pubspec.yaml');
    for (final plugin in ['firebase_core', 'firebase_auth', 'google_sign_in', 'in_app_review', 'purchases_flutter', 'mobile_scanner']) {
      expect(pubspec, contains('\n  $plugin:'), reason: '$plugin: if it is gone, the permission may list less');
    }
  });

  test('the app shows its own licence: the permission and the GPL, as they are', () {
    final notices = read('third_party/zestssh/NOTICES.txt');
    final expected = 'ZestSSH\n\n${read('LICENSE-EXCEPTION.txt').trim()}${separator}ZestSSH\n\n${read('LICENSE').trim()}\n';
    expect(
      notices.replaceAll(RegExp(r'^ +', multiLine: true), ''),
      expected.replaceAll(RegExp(r'^ +', multiLine: true), ''),
      reason: 'third_party/zestssh/NOTICES.txt is "ZestSSH", a blank line and LICENSE-EXCEPTION.txt, a line of 80 '
          'hyphens, then "ZestSSH", a blank line and LICENSE: write it again from the two files',
    );
    expect(notices, contains(read('LICENSE').trim()));
    expect(read('pubspec.yaml'), contains('\n    - third_party/zestssh/NOTICES.txt\n'));
  });

  test('the files a visitor looks for are there, and the README points at each', () {
    final readme = read('README.md');
    for (final file in ['LICENSE', 'LICENSE-EXCEPTION.txt', 'NOTICE', 'CLA.md', 'CONTRIBUTING.md', 'SECURITY.md', 'TRADEMARKS.md']) {
      expect(File(file).existsSync(), isTrue, reason: file);
      expect(readme, contains('($file)'), reason: 'README links $file');
    }
    for (final file in [
      '.github/pull_request_template.md',
      '.github/ISSUE_TEMPLATE/config.yml',
      '.github/ISSUE_TEMPLATE/bug_report.yml',
      '.github/ISSUE_TEMPLATE/feature_request.yml',
    ]) {
      expect(File(file).existsSync(), isTrue, reason: file);
    }
    expect(read('.github/pull_request_template.md'), contains('Contributor License Agreement'));
    expect(read('CONTRIBUTING.md'), contains('(CLA.md)'));
    expect(read('NOTICE'), contains('Copyright © 2026 Affluent Labs LLC'));
    // Security reports go to the address the disclosure page and security.txt give.
    expect(read('SECURITY.md'), contains('**support@zestssh.com**'));
    expect(read('SECURITY.md'), contains('https://zestssh.com/security-disclosure'));
  });

  test('every place that names the licence names the same one, and none holds a placeholder', () {
    for (final path in [
      'packages/zest_native/rust/Cargo.toml',
      'packages/zest_native/rust/fuzz/Cargo.toml',
      'packages/zest_native/rust/fuzz/sancov_bounds/Cargo.toml',
    ]) {
      expect(read(path), contains('\nlicense = "GPL-3.0-only"\n'), reason: path);
    }
    expect(read('tool/linux/build_linux_repo.sh'), contains('\nLicense: GPL-3.0-only\n'));
    final placeholder = RegExp(['LicenseRef-ZestSSH', 'TBA'].join('-') + r'|' + ['announced', 'with', '4.0'].join(' '));
    final found = [
      for (final file in repositoryText(Directory('.')))
        if (placeholder.hasMatch(file.text) && file.path != 'test/docs/project_licence_test.dart') file.path,
    ];
    expect(found, isEmpty, reason: 'the licence is no longer to be announced');
  });
}
