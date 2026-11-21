// English written into the app's screens (3.0; found
// by a scan of lib/). What the app shows (a message, a title, a
// button, a label, a tooltip, a hint) comes from the strings of the twelve
// languages, never from the code: a workflow not saved said "Save failed:" and
// the error as thrown, in English, in every language; the desktop's bell,
// its Keys page, its hosts panel, a phone's selection bar (Copy, Share), the
// drop of files on a terminal and the notice of a new privacy policy were in
// English too.
//
// What this finds: a text written in the code with words in it (two or more,
// or one starting with a capital) given to a snackbar, to a Text, to a
// TextSpan, or as a title, body, label, message, tooltip, hint or the like.
// What it lets be is listed below with why; an allowance that is no longer
// needed fails it too.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What is let be: a file and the start of the text in it, with why.
const _allowed = <String, String>{
  'lib/core/errors/error_codes.dart|': "the codes' own pages, in English by design, fed to the docs",
  'lib/services/demo_seed.dart|': 'the made-up demo data of a debug build for marketing footage (ZEST_DEMO_SEED)',
  'lib/ui/screens/terminal/widgets/soft_key_catalog.dart|': 'the names of keys, as keyboards print them',
  'lib/database/database.dart|Post-migration integrity check failed': 'a fault for the copied details',
  'lib/features/orchards/export/event_exporter.dart|': "events sent to a team's own collector",
  'lib/services/ssh_service.dart|Failed to start ': "the SSH core's own words, matched, not shown",
  'lib/services/desktop_auth_server.dart|': 'the pages a browser shows a developer when a sign-in breaks',
  'lib/features/mcp/mcp_service.dart|': "the MCP tools' names and words, read by the person's AI model, not shown",
  'lib/ui/windows/editor_window.dart|ZestSSH Editor': "a window of its own's name for the system",
  'lib/ui/screens/desktop/widgets/cert_import_dialog.dart|ssh-ed25519-cert-v01': 'a certificate, as an example',
  'lib/ui/screens/import/ssh_config_import_screen.dart|Host myserver': 'an SSH config, as an example',
  'lib/ui/screens/monitoring/prometheus_config_sheet.dart|-----BEGIN CERTIFICATE': 'a certificate, as an example',
  'lib/features/orchards/widgets/orchard_sso_view.dart|-----BEGIN CERTIFICATE': 'a certificate, as an example',
  'lib/ui/screens/snippets/widgets/snippet_edit_dialog.dart|docker restart': 'a command, as an example',
  'lib/features/cloud_import/ui/import_hosts_dialog.dart|Termius': 'a name',
  'lib/features/cloud_import/ui/import_hosts_dialog.dart|Remmina': 'a name',
  'lib/ui/screens/desktop/widgets/hardware_token_dialog.dart|Bitwarden': 'a name',
  'lib/ui/screens/purchase/desktop_upgrade_view.dart|Squeezed': 'a name',
  'lib/ui/screens/purchase/desktop_upgrade_view.dart|Juiced': 'a name',
  'lib/ui/screens/settings/about_screen.dart|Discord': 'a name',
  'lib/ui/screens/settings/settings_screen.dart|Nextcloud': 'a name, the label a new place is given',
};

void main() {
  test('nothing the app shows is written in English in the code, but what is listed with why', () {
    const literal = r'''(?:'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*")''';
    /// A text written in the code, after [start].
    RegExp after(String start) => RegExp('$start($literal)');
    final shown = [
      after(r'showTopSnackBar\(\s*\w+,\s*'),
      after(r'\b(?:title|body|confirmLabel|cancelLabel|label|message|tooltip|hintText|labelText|subtitle|helperText|'
          r'semanticLabel|text|headline|hint|barrierLabel)\s*:\s*'),
      // What a shown field falls back on, and either side of a choice made
      // in place for one (found in a review: hintText: x ?? 'Add tag…'
      // and tooltip: playing ? 'Pause' : 'Play' went past it).
      after(r'\b(?:title|label|message|tooltip|hintText|labelText|subtitle|hint|text)\s*:\s*[\w.!()]+\s*\?\?\s*'),
      after(r'\b(?:title|label|message|tooltip|hintText|labelText|subtitle|hint|text)\s*:\s*[\w.!()]+\s*\?\s*'),
      after(r'''\b(?:title|label|message|tooltip|hintText|labelText|subtitle|hint|text)\s*:\s*[\w.!()]+\s*\?\s*'''
          r'''(?:'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*"|[\w.()]+)\s*:\s*'''),
      after(r'\bText\(\s*'),
      after(r'\bTextSpan\(\s*text:\s*'),
      after(r'reportBlocked\(\s*\w+,\s*'),
    ];
    final words = RegExp(r"[A-Za-z]{2,}(?:'[a-z]+)?(?:\s+[A-Za-z]{2,})+|^[A-Z][a-z]{2,}(?: [A-Za-z]+)*[.!?]?$");
    final interpolated = RegExp(r'\$\{[^}]*\}|\$[A-Za-z_]\w*');

    final found = <String>[];
    final used = <String>{};
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.endsWith('.g.dart') || path.startsWith('lib/l10n/')) continue;
      final text = file.readAsStringSync().replaceAll('\r\n', '\n');
      final lines = text.split('\n');
      for (final pattern in shown) {
        for (final m in pattern.allMatches(text)) {
          final first = '\n'.allMatches(text.substring(0, m.start)).length;
          // (Each pattern ends with the text it finds.)
          final last = '\n'.allMatches(text.substring(0, m.end - m.group(1)!.length)).length;
          final around = lines.sublist(first, last + 1).join(' ');
          if (lines[first].trim().startsWith('//') || around.contains('AppLogger') || around.contains('ValueKey')) {
            continue;
          }
          final said = m.group(1)!;
          final inner = said.substring(1, said.length - 1).replaceAll(interpolated, ' ');
          if (!words.hasMatch(inner)) continue;
          final allowance = _allowed.keys.where((key) {
            final [file, start] = key.split('|');
            return file == path && said.substring(1).startsWith(start);
          }).firstOrNull;
          if (allowance != null) {
            used.add(allowance);
          } else {
            found.add('$path:${last + 1}: $said');
          }
        }
      }
    }
    expect(found, isEmpty, reason: 'words for the twelve languages\' strings');
    expect(used, _allowed.keys.toSet(), reason: 'every allowance is still needed');
  });
}
