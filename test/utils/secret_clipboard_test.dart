import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/utils/secret_clipboard.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// A secret copied to the clipboard is taken off it 45 seconds later, the
/// screen it was copied from closed or not, and when the app locks (found in
/// a security review of the client): each screen cancelled its
/// own timer when it closed, so a secret copied, pasted and the screen closed
/// within 45 seconds stayed on the clipboard for good.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboard;

  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          clipboard = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return clipboard == null ? null : <String, Object?>{'text': clipboard};
      }
      return null;
    });
  });

  tearDown(() async {
    await SecretClipboard.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('copied from a screen that closes at once, a secret is still taken off 45 seconds later', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => SecretClipboard.copy('ZEST-DEMO-RECOVERY-KEY'),
          child: const Text('Copy'),
        ),
      ),
    ));
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(clipboard, 'ZEST-DEMO-RECOVERY-KEY');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 44));
    expect(clipboard, 'ZEST-DEMO-RECOVERY-KEY');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(clipboard, isEmpty);
    expect(SecretClipboard.holding, isFalse);
  });

  testWidgets('an invite code or its link is taken off after 3 minutes, and what is said says 3 minutes', (tester) async {
    expect(kInviteClipboardLife, const Duration(minutes: 3));
    await SecretClipboard.copy('https://zestssh.com/join#ZEST-DEMO', life: kInviteClipboardLife);
    await tester.pump(const Duration(seconds: 179));
    expect(clipboard, 'https://zestssh.com/join#ZEST-DEMO');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(clipboard, isEmpty);

    final l10n = lookupAppLocalizations(const Locale('en'));
    final said = clearsSoon(l10n, l10n.inviteCodeLinkCopied, note: l10n.inviteClipboardAutoClearNote);
    expect(said.split(String.fromCharCode(10)), [l10n.inviteCodeLinkCopied, l10n.inviteClipboardAutoClearNote]);
    expect(l10n.inviteClipboardAutoClearNote, contains('3 minutes'));
    expect(said, isNot(contains('45')));
  });

  testWidgets('what was copied since is left on the clipboard', (tester) async {
    await SecretClipboard.copy('demo-api-key');
    clipboard = 'notes the person copied';
    await tester.pump(const Duration(seconds: 46));
    expect(clipboard, 'notes the person copied');
  });

  test('locking the app takes a copied secret off at once', () async {
    SharedPreferences.setMockInitialValues(const {});
    FlutterSecureStorage.setMockInitialValues({});
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
    ]);
    addTearDown(container.dispose);
    await SecretClipboard.copy('-----BEGIN OPENSSH PRIVATE KEY-----');
    await container.read(isAppLockedProvider.notifier).lock();
    await Future<void>.delayed(Duration.zero);
    expect(clipboard, isEmpty);
  });

  test('what is said after such a copy says that the clipboard clears, on a line of its own', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final said = clearsSoon(l10n, l10n.shareConnectionCopied).split(String.fromCharCode(10));
    expect(said, [l10n.shareConnectionCopied, l10n.identityEditClipboardAutoClearNote]);
    expect(said.last, contains('45'));
  });

  test('every screen that says a secret it copies is cleared copies it as one', () {
    // File, and how many secrets it copies.
    const copies = {
      'lib/ui/screens/identity/identity_edit_screen.dart': 1,
      // A deep link's URL (an API key is copied only from the dialog that shows it once).
      'lib/features/automation/widgets/triggers_view.dart': 1,
      'lib/features/automation/widgets/api_key_once_dialog.dart': 1,
      'lib/ui/screens/profile/recovery_key_screen.dart': 1,
      'lib/ui/screens/profile/widgets/two_step_dialogs.dart': 2,
      // The phone's API keys copy none: a key is shown once, in api_key_once_dialog.
      'lib/ui/screens/settings/automation_settings_screen.dart': 0,
      // The link, Tasker's intent and adb's command, each with the key.
      'lib/ui/screens/automation/automation_wizard_screen.dart': 1,
      // What lets whoever holds it in, or act for a team (found in a
      // review, and the directory's token beside it): a
      // certificate's hand-over value, an invite code and its link, a shared
      // host's link, the token a directory signs in with.
      'lib/features/orchards/widgets/cert_handover_dialogs.dart': 1,
      'lib/features/orchards/widgets/invite_people_dialog.dart': 1,
      'lib/ui/screens/connection/share_connection_sheet.dart': 1,
      'lib/features/orchards/widgets/orchard_directory_view.dart': 1,
    };
    for (final entry in copies.entries) {
      final text = File(entry.key).readAsStringSync();
      expect('SecretClipboard.copy('.allMatches(text).length, entry.value, reason: entry.key);
    }
    // No screen clears the clipboard by a timer of its own.
    final ownClears = [
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') &&
            !file.path.replaceAll(r'\', '/').endsWith('utils/secret_clipboard.dart') &&
            file.readAsStringSync().contains("ClipboardData(text: '')"))
          file.path,
    ];
    expect(ownClears, isEmpty);
  });

  // The guard above knows only the files it names: a copy written anywhere
  // else was looked at by nobody (a review found 81 plain
  // copies in files it did not name, four of them of values that let their
  // holder in). Every plain copy in the app is listed here, by file. A new
  // one fails this until someone has said which it is: a secret (a key, a
  // password, a token, a code or link that lets its holder in or act for
  // someone) goes through SecretClipboard.copy and into the list above;
  // anything else is added here.
  test('every plain copy to the clipboard is one somebody looked at', () {
    const plain = {
      'lib/features/automation/widgets/run_output_drawer.dart': 1,
      'lib/features/cloud_import/ui/import_hosts_dialog.dart': 2,
      'lib/features/hosts/pages/hosts_home_page.dart': 1,
      'lib/features/hosts/phone/phone_hosts_view.dart': 1,
      'lib/features/hosts/widgets/host_panel.dart': 1,
      'lib/features/networks/widgets/network_form_fields.dart': 1,
      'lib/features/orchards/team/team_seats.dart': 1,
      'lib/features/orchards/team/team_seats_sheet.dart': 1,
      'lib/features/orchards/team/team_setup.dart': 1,
      'lib/features/orchards/team/team_trust.dart': 3,
      'lib/features/orchards/widgets/crate_authority_view.dart': 1,
      'lib/features/orchards/widgets/crate_session_logs_view.dart': 1,
      'lib/features/orchards/widgets/fingerprint_view.dart': 1,
      'lib/features/orchards/widgets/orchard_directory_view.dart': 1,
      'lib/features/orchards/widgets/orchard_domains_view.dart': 1,
      'lib/features/orchards/widgets/orchard_exposure.dart': 1,
      'lib/features/orchards/widgets/orchard_sso_view.dart': 1,
      'lib/features/orchards/widgets/team_export_view.dart': 2,
      'lib/features/password_managers/widgets/password_manager_dialogs.dart': 1,
      'lib/features/password_managers/widgets/password_manager_tool_setup.dart': 1,
      'lib/features/run/install_key_view.dart': 1,
      'lib/features/run/run_on_hosts_view.dart': 1,
      'lib/features/screens/session/screen_clipboard.dart': 1,
      'lib/features/screens/xprogram/x_program_install_text.dart': 1,
      'lib/providers/terminal_providers.dart': 1,
      'lib/ui/screens/automation/automation_history_screen.dart': 1,
      'lib/ui/screens/automation/workflow_editor_screen.dart': 1,
      'lib/ui/screens/command_history/command_history_screen.dart': 1,
      'lib/ui/screens/command_history/desktop_history_page.dart': 1,
      'lib/ui/screens/desktop/widgets/hardware_token_dialog.dart': 1,
      'lib/ui/screens/desktop/widgets/help_dock.dart': 2,
      'lib/ui/screens/desktop/widgets/inspector_panel.dart': 1,
      'lib/ui/screens/desktop/widgets/keys_detail_pane.dart': 1,
      'lib/ui/screens/desktop/widgets/keys_inspector_pane.dart': 1,
      'lib/ui/screens/desktop/widgets/keys_view.dart': 1,
      'lib/ui/screens/desktop/widgets/port_forward_detail_pane.dart': 1,
      'lib/ui/screens/desktop/widgets/session_chrome.dart': 1,
      'lib/ui/screens/desktop/widgets/session_slide_panel.dart': 1,
      'lib/ui/screens/desktop/widgets/settings_inline_view.dart': 1,
      'lib/ui/screens/desktop/widgets/snippet_detail_view.dart': 1,
      'lib/ui/screens/desktop/widgets/snippets_library_view.dart': 1,
      'lib/ui/screens/editor/text_editor_screen.dart': 1,
      // Copy answer (4.0): Astryx's answer, written from the public docs.
      'lib/ui/screens/help/ask_astryx_screen.dart': 1,
      'lib/ui/screens/help/contact_support_screen.dart': 1,
      'lib/ui/screens/help/guide_markdown_view.dart': 1,
      'lib/ui/screens/help/report_issue_screen.dart': 1,
      'lib/ui/screens/help/support_hub_compose.dart': 1,
      'lib/ui/screens/help/support_hub_page.dart': 1,
      'lib/ui/screens/help/ticket_actions.dart': 3,
      'lib/ui/screens/help/ticket_detail_screen.dart': 1,
      'lib/ui/screens/home/home_screen.dart': 1,
      'lib/ui/screens/identity/identity_edit_screen.dart': 2,
      'lib/ui/screens/identity/identity_list_screen.dart': 1,
      'lib/ui/screens/identity/key_generation_screen.dart': 1,
      'lib/ui/screens/profile/profile_screen.dart': 1,
      'lib/ui/screens/purchase/entitlement_diagnostic_dialog.dart': 1,
      'lib/ui/screens/settings/help_support_screen.dart': 1,
      'lib/ui/screens/sftp/sftp_browser_screen.dart': 1,
      'lib/ui/screens/sftp/widgets/sftp_pane.dart': 2,
      'lib/ui/screens/sftp/widgets/transfer_queue_panel.dart': 1,
      'lib/ui/screens/snippets/snippets_screen.dart': 2,
      'lib/ui/screens/terminal/terminal_screen.dart': 2,
      // The changed key's command; the first connection's fingerprint and its
      // command (4.0): a host key's fingerprint is public, and so is the command.
      'lib/ui/screens/terminal/widgets/host_key_changed_dialog.dart': 3,
      'lib/ui/screens/terminal/widgets/sign_in_link_dialog.dart': 1,
      'lib/ui/screens/terminal/widgets/terminal_selection_toolbar.dart': 1,
      'lib/ui/screens/transcripts/transcript_viewer_screen.dart': 1,
      'lib/ui/widgets/broken_widget_notice.dart': 1,
      'lib/ui/widgets/browser_sign_in_help.dart': 1,
      'lib/ui/widgets/copy_details_button.dart': 1,
      'lib/ui/widgets/error_details_panel.dart': 1,
      'lib/ui/widgets/file_saved_dialog.dart': 1,
      // The line a shell needs to report its folder (bash or zsh), from the app's own text (4.0).
      'lib/ui/widgets/terminal_folder_help.dart': 1,
      'lib/ui/widgets/terminal_paste.dart': 1,
      'lib/ui/widgets/top_snackbar.dart': 1,
    };
    final found = <String, int>{};
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.endsWith('utils/secret_clipboard.dart')) continue;
      final n = 'Clipboard.setData('.allMatches(file.readAsStringSync()).length;
      if (n > 0) found[path] = n;
    }
    for (final entry in found.entries) {
      expect(entry.value, plain[entry.key] ?? 0,
          reason: '${entry.key} copies to the clipboard as it is: is it a secret? (see the comment above)');
    }
    expect(plain.keys.where((path) => !found.containsKey(path)), isEmpty, reason: 'listed, and copy nothing now');
  });
}
