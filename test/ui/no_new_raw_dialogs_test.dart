import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// No NEW raw dialog (3.4, the dialog rules):
/// every pop-up is the app's own [ZestDialogShell], through
/// ZestConfirmDialog.show, showZestModal, showZestInputDialog, showZestChoice,
/// showZestBusy or ZestDialogShell.showModal, which keep the six rules (a
/// neutral dialog, colour only by meaning; one footer; a small icon, no lines;
/// no dialog over a dialog; buttons that say what they do; paths in the
/// system's style). A Material `AlertDialog(`, `SimpleDialog(` or a raw
/// `showDialog(` draws a dialog of its own, which keeps none of them.
///
/// This reads lib/ and holds that no file has more of them than it is allowed
/// below. The sweep began with 83 files and 171
/// places, and 16 showGeneralDialog and SimpleDialog places; a first pass
/// moved every dialog among them onto the shell, and the host
/// list's (remade with its multi-select and bulk edit) followed as that pass
/// landed. A second pass moved the custom colour and the theme and
/// font pickers onto it, and a phone's sheets: of the 35 raw
/// showModalBottomSheet places, every question and form is the shell now (a
/// phone's sheet by itself), and what stays is a menu. What stays is listed
/// with why: the shell's own, and routes that hold something that is not a
/// dialog. When a file has
/// fewer than its number here, this fails until its number is lowered (or its
/// line taken out), so the lists never keep room for a new one. Never raise a
/// number or add a file: use the shell.
void main() {
  /// The shell itself: the showDialog under every dialog of the app.
  const shell = <String, int>{
    // ZestConfirmDialog.show and ZestConfirmDialog.ask (a computer's dialog;
    // a phone's is a sheet).
    'lib/ui/widgets/zest_dialog.dart': 2,
    // showZestModal, under showZestInputDialog, showZestChoice, showZestBusy
    // and ZestDialogShell.showModal.
    'lib/ui/widgets/zest_modal.dart': 1,
  };

  /// showDialog as the route for something that is not a dialog, so it has
  /// no title, footer or buttons of a dialog to keep: a menu or popover placed
  /// at the control that opened it (a clear barrier), a command palette, or a
  /// whole screen with its own header, navigation and buttons shown in a
  /// window on a computer.
  const notDialogs = <String, int>{
    // The hosts' filter menu, under the Filter button (it stays open while
    // choices are ticked).
    'lib/features/hosts/pages/hosts_home_page.dart': 1,
    // The alert menu, placed at the metric it is for.
    'lib/features/hosts/widgets/host_panel_sections.dart': 1,
    // The network editor page in a window (the same page as in the split view).
    'lib/features/networks/pages/network_editor_page.dart': 1,
    // The vault menu, under the vault button.
    'lib/features/orchards/widgets/vault_picker.dart': 1,
    // The host editor screen in a window.
    'lib/ui/screens/connection/connection_edit_screen.dart': 1,
    // Quick connect, a palette.
    'lib/ui/screens/desktop/widgets/quick_connect_v3.dart': 1,
    // The Settings pop-up, and the licenses screen in a window.
    'lib/ui/screens/desktop/widgets/settings_inline_view.dart': 2,
    // The snippet palette.
    'lib/ui/screens/desktop/widgets/snippet_quick_picker.dart': 1,
    // The key editor screen in a window.
    'lib/ui/screens/identity/identity_edit_screen.dart': 1,
    // The key generation screen in a window.
    'lib/ui/screens/identity/key_generation_screen.dart': 1,
    // The sync setup flow, a screen of three steps, in a window.
    // The pricing page, its tiers and their buttons.
    'lib/ui/screens/purchase/pricing_modal.dart': 1,
    // The PIN setup screen (its own app bar) in a window.
    'lib/ui/screens/security/pin_setup_screen.dart': 1,
    // The sync storage screen in a window (its own header and unsaved-changes guard).
    'lib/ui/screens/settings/sync_backend_screen.dart': 1,
    // The theme editor screen in a window.
    'lib/ui/screens/settings/widgets/custom_theme_builder.dart': 1,
    // The source popover, at the pane's source button.
    'lib/ui/screens/sftp/widgets/sftp_source_picker.dart': 1,
    // The snippet editor page in a window (one build for a window, a phone's
    // page and a pane, with its own header and footer).
    'lib/ui/screens/snippets/widgets/snippet_edit_dialog.dart': 1,
    // Copy from screen, a full-screen view with its own app bar.
    'lib/ui/screens/terminal/terminal_screen.dart': 1,
    // The command palette.
    'lib/ui/widgets/command_palette.dart': 1,
  };

  /// `showGeneralDialog(`, `SimpleDialog(` and `CupertinoAlertDialog(`: the
  /// other dialogs of the framework. What stays is a side panel that slides in
  /// at an edge, or a menu placed at its control, never a dialog.
  const otherKinds = <String, int>{
    // The group editor, a side panel.
    'lib/features/groups/widgets/group_editor_panel.dart': 1,
    // A phone's group sheets, a side panel on a tablet.
    'lib/features/groups/widgets/phone_group_sheets.dart': 1,
    // A join request's review, a side panel on a computer.
    'lib/features/orchards/widgets/join_review.dart': 1,
    // The workspace editor, a side panel.
    'lib/features/workspaces/widgets/workspace_edit_dialog.dart': 1,
    // Arrange the snippets, a side panel.
    'lib/ui/screens/desktop/widgets/snippets_library_view.dart': 1,
    // The account and space menu, placed at its control, and the plan popover
    // beside its chip: the one route they share (showAtControl).
    'lib/ui/screens/profile/account_switch.dart': 1,
    // The account panel, sliding in from the left.
    'lib/ui/screens/profile/profile_screen.dart': 1,
    // A remote screen's session panel, sliding in from the end side over the
    // picture (4.0: everything a session can do, in its groups).
    'lib/features/screens/menu/screen_session_panel.dart': 1,
  };

  /// `showModalBottomSheet(`: a phone's sheet of its own. A question or a form
  /// is the shell (showZestModal, ZestConfirmDialog.show, showZestChoice,
  /// showZestInputDialog: a phone's sheet by themselves), with a title, one
  /// row of buttons at the bottom that say what they do, and no tinted tiles.
  /// What stays is a menu: a list of actions, each doing what it says as it is
  /// tapped, or a list to pick from that acts as it is tapped.
  const sheetShell = <String, int>{
    // showZestSheet, under every dialog of the app's on a phone.
    'lib/ui/widgets/zest_sheet.dart': 1,
  };
  const sheetMenus = <String, int>{
    // Where you are: your own space, a team's, an invitation, a new team.
    'lib/features/orchards/widgets/space_switcher_sheet.dart': 1,
    // A key's actions (a phone's Keys tab on Home).
    'lib/ui/screens/home/home_screen.dart': 1,
    // A key's actions, in the Keys list (the branch that adds its multi-select
    // works in this file).
    'lib/ui/screens/identity/identity_list_screen.dart': 1,
    // The port forward help: a notice, left to the branch that adds the
    // forwards list's multi-select, which works in this file. Its next one.
    'lib/ui/screens/port_forward/port_forward_screen.dart': 1,
    // The account photo's actions.
    'lib/ui/screens/profile/profile_screen.dart': 1,
    // Import data and Export data: each a list of the ways, one tap each.
    'lib/ui/screens/settings/data_settings_screen.dart': 2,
    // Import data and Export data, as in data_settings_screen.
    'lib/ui/screens/settings/settings_screen.dart': 2,
    // A custom theme's actions (Edit, Delete), on a long press in the picker.
    'lib/ui/screens/settings/widgets/theme_picker.dart': 1,
    // A file's actions.
    'lib/ui/screens/sftp/sftp_browser_screen.dart': 1,
    // A snippet's and a category's actions, in the Snippets list (the branch
    // that adds its multi-select works in this file).
    'lib/ui/screens/snippets/snippets_screen.dart': 2,
    // The terminal's: a snippet to run, the actions on a selection or a
    // paste, and a clip from the clipboard history, each acting as tapped.
    'lib/ui/screens/terminal/terminal_screen.dart': 3,
  };

  final alert = RegExp(r'\bAlertDialog\(');
  final show = RegExp(r'\bshowDialog\s*(<|\()');
  final other = RegExp(r'\bshowGeneralDialog\s*(<|\()|\bSimpleDialog\(|\bCupertinoAlertDialog\(');
  final sheet = RegExp(r'\bshowModalBottomSheet\s*(<|\()');

  /// The places [patterns] find in [text], outside comments.
  int count(String text, List<RegExp> patterns) {
    var n = 0;
    for (final line in text.replaceAll('\r\n', '\n').split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) continue;
      for (final p in patterns) {
        n += p.allMatches(line).length;
      }
    }
    return n;
  }

  int rawIn(String text) => count(text, [alert, show]);
  int otherIn(String text) => count(text, [other]);
  int sheetsIn(String text) => count(text, [sheet]);

  Map<String, int> found(int Function(String) counter) => {
        for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
          if (file.path.endsWith('.dart') && !file.path.replaceAll('\\', '/').contains('/generated/'))
            if (counter(file.readAsStringSync()) case final n when n > 0) file.path.replaceAll('\\', '/'): n,
      };

  int allowedRaw(String path) => shell[path] ?? notDialogs[path] ?? 0;

  test('no file has a raw AlertDialog or showDialog it is not allowed: new dialogs use the shell', () {
    final grown = <String>[
      for (final MapEntry(key: path, value: n) in found(rawIn).entries)
        if (n > allowedRaw(path)) '$path: $n (allowed ${allowedRaw(path)})',
    ]..sort();
    expect(grown, isEmpty,
        reason: 'a new dialog is a ZestDialogShell: ZestConfirmDialog.show(...), showZestModal(child: '
            'ZestDialogShell(...)), showZestInputDialog(...), showZestChoice(...), showZestBusy(...) or '
            'ZestDialogShell.showModal(...), never a raw AlertDialog or showDialog');
  });

  test('no file has a showGeneralDialog, SimpleDialog or CupertinoAlertDialog it is not allowed', () {
    final grown = <String>[
      for (final MapEntry(key: path, value: n) in found(otherIn).entries)
        if (n > (otherKinds[path] ?? 0)) '$path: $n (allowed ${otherKinds[path] ?? 0})',
    ]..sort();
    expect(grown, isEmpty,
        reason: 'one of a few choices is showZestChoice(...); a question or a form is the shell (see above)');
  });

  int allowedSheets(String path) => sheetShell[path] ?? sheetMenus[path] ?? 0;

  test("no file has a raw showModalBottomSheet it is not allowed: a phone's question or form is the shell", () {
    final grown = <String>[
      for (final MapEntry(key: path, value: n) in found(sheetsIn).entries)
        if (n > allowedSheets(path)) '$path: $n (allowed ${allowedSheets(path)})',
    ]..sort();
    expect(grown, isEmpty,
        reason: "a phone's question or form is the shell: showZestModal(child: ZestDialogShell(...)), "
            'ZestConfirmDialog.show(...), showZestChoice(...) or showZestInputDialog(...), each a sheet on a phone; '
            'a menu of actions may be a list');
  });

  test('the lists only shrink: a file whose places went leaves them', () {
    final raw = found(rawIn);
    final others = found(otherIn);
    final sheets = found(sheetsIn);
    final stale = <String>[
      for (final MapEntry(key: path, value: n) in notDialogs.entries)
        if ((raw[path] ?? 0) < n) '$path: now ${raw[path] ?? 0}, listed $n',
      for (final MapEntry(key: path, value: n) in otherKinds.entries)
        if ((others[path] ?? 0) < n) '$path: now ${others[path] ?? 0} of the other kinds, listed $n',
      for (final MapEntry(key: path, value: n) in sheetMenus.entries)
        if ((sheets[path] ?? 0) < n) '$path: now ${sheets[path] ?? 0} sheets, listed $n',
    ]..sort();
    expect(stale, isEmpty, reason: 'lower the number in this test (or take the line out at 0)');
  });

  test('the counts as they are now: 3 of the shell, 19 that are not dialogs (the custom colour and the theme '
      "and font pickers are the shell), 8 side panels and menus; of a phone's 35 raw sheets, the shell's 1 and 16 "
      'menus', () {
    int sum(Map<String, int> m) => m.values.fold(0, (a, b) => a + b);
    expect(sum(shell), 3);
    // (20 until 3.4.2, which took out the setup flow nothing opened.)
    expect(sum(notDialogs), 19);
    // (7 after the second pass; 8 with a remote screen's session panel, 4.0.)
    expect(sum(otherKinds), 8);
    expect(sum(sheetShell), 1);
    expect(sum(sheetMenus), 16);
    final keys = [...shell.keys, ...notDialogs.keys];
    expect(keys.toSet().length, keys.length, reason: 'a file in one list only');
    final sheetKeys = [...sheetShell.keys, ...sheetMenus.keys];
    expect(sheetKeys.toSet().length, sheetKeys.length, reason: 'a file in one list only');
  });

  test('the check finds each shape, and not a comment or another widget', () {
    // (Held against this file's own words, which no app code reads.)
    expect(rawIn('    showDialog(context: context, builder: (_) => const SizedBox());'), 1);
    expect(rawIn('    final ok = await showDialog<bool>(\n      context: context,'), 1);
    expect(rawIn('      builder: (ctx) => AlertDialog(title: Text(t)),'), 1);
    expect(rawIn('  /// Replaces the old showDialog( and AlertDialog( here.'), 0);
    expect(rawIn('    CupertinoAlertDialog(title: t); _showDialog(); showDialogs(x);'), 0);
    expect(otherIn('    return showGeneralDialog<void>(context: context,'), 1);
    expect(otherIn('      builder: (ctx) => SimpleDialog(title: t),'), 1);
    expect(otherIn('      builder: (ctx) => CupertinoAlertDialog(title: t),'), 1);
    expect(otherIn('          SimpleDialogOption(onPressed: p), AlertDialog(); _showGeneralDialog();'), 0);
    expect(otherIn('  // a SimpleDialog( it was'), 0);
    expect(sheetsIn('    showModalBottomSheet(context: context, builder: (_) => const Menu());'), 1);
    expect(sheetsIn('    return showModalBottomSheet<String>(\n      context: context,'), 1);
    expect(sheetsIn('  /// It was a showModalBottomSheet( of its own.'), 0);
    expect(sheetsIn('    showZestSheet<void>(context: context, child: c); _showModalBottomSheet();'), 0);
  });
}
