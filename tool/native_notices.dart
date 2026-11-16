// Writes assets/licenses/<platform>.txt: the licences of the native libraries a platform's build
// carries that are neither a Dart package nor a Rust crate (those reach the app's licences page on
// their own: each package's LICENSE, and packages/zest_native/NOTICES). The app registers the file
// of the platform it runs on (lib/services/platform_licences.dart), so Settings, About, Open
// source licenses lists them as it lists the packages.
//
// The texts come from what the build itself downloaded, as published:
//   windows  PDFium (the printing plugin's pdfium.dll, from bblanchon/pdfium-binaries: its LICENSE
//            holds PDFium's and those of the libraries built into it), the Firebase C++ SDK (the
//            firebase_core and firebase_auth plugins link it in: its NOTICES), and the Windows
//            Implementation Libraries and C++/WinRT (NuGet packages some plugins compile against).
//   linux    PDFium, as on Windows.
//   ios, macos
//            every pod in CocoaPods' acknowledgements of the Runner target
//            (Pods/Target Support Files/Pods-Runner/Pods-Runner-acknowledgements.plist, written by
//            `pod install` on the Mac).
//   android  every library in the output of Google's oss-licenses Gradle plugin
//            (third_party_licenses and third_party_license_metadata, written by its
//            <variant>OssLicensesTask; only the plugin, not its closed runtime library, is needed).
// The same file format as a package's NOTICES: sections split by a line of 80 hyphens, each its
// names (one per line), a blank line, then the text (flutter_tools license_collector.dart).
//
//   dart tool/native_notices.dart windows --from build/windows/x64
//   dart tool/native_notices.dart linux --from build/linux/x64/release
//   dart tool/native_notices.dart ios --from "ios/Pods/Target Support Files/Pods-Runner/Pods-Runner-acknowledgements.plist"
//   dart tool/native_notices.dart macos --from "macos/Pods/Target Support Files/Pods-Runner/Pods-Runner-acknowledgements.plist"
//   dart tool/native_notices.dart android --from android/app/build/generated/third_party_licenses/release/res/raw
// Add --check to change nothing and fail when the file is not what the build would give.
//
// Run it after a build whose native libraries changed (a plugin's PDFium or Firebase version, a pod,
// an Android library). test/docs/native_notices_test.dart checks the committed files.
import 'dart:convert';
import 'dart:io';

/// Where the platforms' files are, and the asset folder the app reads them from.
const assetDir = 'assets/licenses';

/// The platforms a file can be written for.
const platforms = ['windows', 'linux', 'android', 'ios', 'macos'];

/// What separates two licences in a NOTICES file (flutter_tools: licenseSeparator).
final separator = '\n${'-' * 80}\n';

typedef Section = ({List<String> names, String text});

/// [bytes] as text: UTF-8, or Latin-1 where a file is not UTF-8 (PDFium's LICENSE writes its
/// copyright signs in Latin-1), with CRLF as LF and long dashes as plain hyphens (this repository
/// keeps no em or en dash in any file); nothing else of a text is changed.
String plainText(List<int> bytes) {
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = latin1.decode(bytes);
  }
  return text
      .replaceAll('\r\n', '\n')
      .replaceAll(String.fromCharCode(0x2014), '-')
      .replaceAll(String.fromCharCode(0x2013), '-')
      .trimRight();
}

/// A text with no line of 80 hyphens, which would split it in two.
String _guarded(String text) => text.replaceAll(RegExp(r'^-{80}$', multiLine: true), '-' * 79);

/// The file for [sections]: identical texts are listed once with every name they cover.
String noticesFile(List<Section> sections) {
  final byText = <String, Set<String>>{};
  for (final s in sections) {
    byText.putIfAbsent(_guarded(s.text.trim()), () => <String>{}).addAll(s.names);
  }
  final merged = [for (final e in byText.entries) (names: (e.value.toList()..sort()), text: e.key)]
    ..sort((a, b) {
      final n = a.names.first.toLowerCase().compareTo(b.names.first.toLowerCase());
      return n != 0 ? n : a.text.compareTo(b.text);
    });
  return '${merged.map((s) => '${s.names.join('\n')}\n\n${s.text}').join(separator)}\n';
}

/// The sections of a NOTICES file, as flutter_tools and the app read them.
List<Section> parseNotices(String file) => [
  for (final raw in file.replaceAll('\r\n', '\n').split(separator))
    if (raw.contains('\n\n'))
      (names: raw.substring(0, raw.indexOf('\n\n')).split('\n'), text: raw.substring(raw.indexOf('\n\n') + 2).trim()),
];

/// PDFium's LICENSE from pdfium-binaries: blocks between `# BEGIN <title>` and `# END ...` lines,
/// each a section under the name PDFium, opened by a line that says which binary and which
/// library it is.
List<Section> pdfiumSections(String licence, String version) {
  final sections = <Section>[];
  final begin = RegExp(r'^# BEGIN (.+)$', multiLine: true);
  final matches = begin.allMatches(licence).toList();
  if (matches.isEmpty) throw const FormatException('PDFium LICENSE: no "# BEGIN" block');
  for (final m in matches) {
    final end = licence.indexOf(RegExp(r'^# END ', multiLine: true), m.end);
    if (end < 0) throw FormatException('PDFium LICENSE: "${m.group(1)}" has no END');
    final body = licence.substring(m.end, end).trim();
    sections.add((
      names: const ['PDFium'],
      text:
          'PDFium chromium/$version (pdfium.dll or libpdfium.so, from '
          'https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium/$version), '
          'which the printing plugin carries (the recovery kit is printed through it): ${m.group(1)!.trim()}.\n\n$body',
    ));
  }
  return sections;
}

/// The Firebase C++ SDK's NOTICES: components headed by their name between two lines of `=`.
List<Section> firebaseCppSections(String notices, String version) {
  final lines = notices.split('\n');
  final heads = <(int, String)>[];
  for (var i = 0; i + 2 < lines.length; i++) {
    if (RegExp(r'^=+$').hasMatch(lines[i]) &&
        RegExp(r'^=+$').hasMatch(lines[i + 2]) &&
        lines[i + 1].trim().isNotEmpty) {
      heads.add((i, lines[i + 1].trim()));
    }
  }
  if (heads.isEmpty) throw const FormatException('Firebase C++ SDK NOTICES: no component heading');
  return [
    for (var h = 0; h < heads.length; h++)
      (
        names: const ['Firebase C++ SDK'],
        text:
            'Firebase C++ SDK $version (linked into the app on Windows by the firebase_core and firebase_auth '
            'plugins; https://firebase.google.com/download/cpp): ${heads[h].$2}.\n\n'
            '${lines.sublist(heads[h].$1 + 3, h + 1 < heads.length ? heads[h + 1].$1 : lines.length).join('\n').trim()}',
      ),
  ];
}

/// A NuGet package's LICENSE (and ThirdPartyNotices.txt where it has one), under [name].
List<Section> nugetSections(Directory package, String name) {
  final version = package.uri.pathSegments
      .where((s) => s.isNotEmpty)
      .last
      .split('.')
      .skipWhile((p) => int.tryParse(p) == null)
      .join('.');
  final out = <Section>[];
  for (final file in ['LICENSE', 'ThirdPartyNotices.txt']) {
    final f = File('${package.path}/$file');
    if (!f.existsSync()) continue;
    out.add((
      names: [name],
      text:
          '$name $version (NuGet), which Windows plugins compile against.\n\n'
          '${plainText(f.readAsBytesSync()).split('\n').map((l) => l.startsWith('    ') ? l.substring(4) : l).join('\n').trim()}',
    ));
  }
  if (out.isEmpty) throw StateError('${package.path} has no LICENSE');
  return out;
}

String _xmlText(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// CocoaPods' acknowledgements plist: one section per pod (a dictionary with a Title and a
/// FooterText; the first and the last, CocoaPods' own header and footer, have no License key).
List<Section> podsSections(String plist) {
  final out = <Section>[];
  for (final dict in RegExp(r'<dict>(.*?)</dict>', dotAll: true).allMatches(plist)) {
    final body = dict.group(1)!;
    String? value(String key) =>
        RegExp('<key>$key</key>\\s*<string>(.*?)</string>', dotAll: true).firstMatch(body)?.group(1);
    final title = value('Title');
    final text = value('FooterText');
    if (title == null || text == null || value('License') == null) continue;
    out.add((names: [_xmlText(title).trim()], text: plainText(utf8.encode(_xmlText(text)))));
  }
  if (out.isEmpty) throw const FormatException('acknowledgements plist: no pod with a licence');
  return out;
}

/// The oss-licenses Gradle plugin's output: [metadata] lines `<offset>:<length> <name>` into
/// [licences], offsets and lengths in bytes.
List<Section> ossLicensesSections(List<int> licences, String metadata) {
  final out = <Section>[];
  for (final line in const LineSplitter().convert(metadata)) {
    final m = RegExp(r'^(\d+):(\d+) (.+)$').firstMatch(line.trim());
    if (m == null) continue;
    final start = int.parse(m.group(1)!);
    final end = start + int.parse(m.group(2)!);
    if (end > licences.length) throw FormatException('third_party_licenses is shorter than ${m.group(3)} needs');
    out.add((names: [m.group(3)!.trim()], text: plainText(licences.sublist(start, end))));
  }
  if (out.isEmpty) throw const FormatException('third_party_license_metadata: no library');
  return out;
}

/// The sections of [platform]'s file, from the build output at [from].
List<Section> sectionsFor(String platform, String from) {
  switch (platform) {
    case 'windows':
    case 'linux':
      final dir = Directory(from);
      final version = RegExp(
        r'BUILD=(\d+)',
      ).firstMatch(File('${dir.path}/pdfium-src/VERSION').readAsStringSync())!.group(1)!;
      final sections = pdfiumSections(plainText(File('${dir.path}/pdfium-src/LICENSE').readAsBytesSync()), version);
      if (platform == 'windows') {
        final zip = dir
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .firstWhere(
              (n) => RegExp(r'^firebase_cpp_sdk_windows_[\d.]+\.zip$').hasMatch(n),
              orElse: () => throw StateError('no firebase_cpp_sdk_windows_<version>.zip in $from'),
            );
        final firebaseVersion = RegExp(r'_([\d.]+)\.zip$').firstMatch(zip)!.group(1)!;
        sections.addAll(
          firebaseCppSections(
            plainText(File('${dir.path}/extracted/firebase_cpp_sdk_windows/NOTICES').readAsBytesSync()),
            firebaseVersion,
          ),
        );
        for (final (prefix, name) in [
          ('Microsoft.Windows.ImplementationLibrary.', 'Windows Implementation Libraries (WIL)'),
          ('Microsoft.Windows.CppWinRT.', 'C++/WinRT'),
        ]) {
          final packages = Directory('${dir.path}/packages')
              .listSync()
              .whereType<Directory>()
              .where((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith(prefix))
              .toList();
          if (packages.isEmpty) throw StateError('no $prefix package in $from/packages');
          for (final p in packages) {
            sections.addAll(nugetSections(p, name));
          }
        }
      }
      return sections;
    case 'ios':
    case 'macos':
      return podsSections(File(from).readAsStringSync());
    case 'android':
      return ossLicensesSections(
        File('$from/third_party_licenses').readAsBytesSync(),
        File('$from/third_party_license_metadata').readAsStringSync(),
      );
  }
  throw ArgumentError('platform: one of ${platforms.join(', ')}');
}

void main(List<String> args) {
  final platform = args.isEmpty ? '' : args.first;
  final fromAt = args.indexOf('--from');
  if (!platforms.contains(platform) || fromAt < 0 || fromAt + 1 >= args.length) {
    stderr.writeln('usage: dart tool/native_notices.dart <${platforms.join('|')}> --from <build output> [--check]');
    exit(64);
  }
  final text = noticesFile(sectionsFor(platform, args[fromAt + 1]));
  final file = File('$assetDir/$platform.txt');
  if (args.contains('--check')) {
    final now = file.existsSync() ? file.readAsStringSync().replaceAll('\r\n', '\n') : '';
    if (now != text) {
      stderr.writeln('${file.path} is not current: run dart tool/native_notices.dart $platform --from ...');
      exit(1);
    }
    stdout.writeln('${file.path} is current');
    return;
  }
  file
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
  stdout.writeln('${parseNotices(text).length} licence texts written to ${file.path}');
}
