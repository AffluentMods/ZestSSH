import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';

import '../../helpers/fake_editor_source.dart';
import '../../visual/shots_util.dart';

/// The editor's toolbar on a computer (3.4, as
/// designed; Save and the other actions stood indented, not
/// at the right): the host, the path and the
/// owner stand at the left, and the actions (Find, Wrap, the language, Save
/// as root, Save, More) at the right, More at the toolbar's right padding and
/// Save just before it, whatever the window's width and the path's length.
void main() {
  const rootOwned = FileAccess(owner: 'root:root', mode: '644', writable: false, canSudo: true);
  const mine = FileAccess(owner: 'deploy:deploy', mode: '644', writable: true, canSudo: true);

  Rect rectOf(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

  setUpAll(loadShotFonts);

  for (final width in [700.0, 1000.0, 1280.0, 1600.0, 1920.0]) {
    for (final (name, path, access) in [
      ('a short path', '/etc/hosts', mine),
      ('a root file', '/etc/nginx/nginx.conf', rootOwned),
      ('a long path', '/home/deploy/apps/storefront/releases/2026-11-06/config/production/settings.yaml', mine),
    ]) {
      testWidgets('$width wide, $name: Save and More stand at the right, the path at the left', (tester) async {
        final file = FakeEditorSource(path, text: 'a: 1\n', accessIs: access);
        await openEditorPage(tester, [file], size: Size(width, 800), theme: BuiltInThemes.getById('graphite').toThemeData());
        await openFile(tester, file);
        // Measured in the app's own fonts (the test font's letters are boxes).
        expect(tester.getSize(find.text('Save')).width, lessThan(40), reason: 'the app font is not loaded');

        final bar = rectOf(tester, 'editor-toolbar');
        final more = rectOf(tester, 'editor-more');
        final save = rectOf(tester, 'editor-save');
        // The toolbar's right padding is 8.
        expect(more.right, moreOrLessEquals(bar.right - 8, epsilon: 0.5), reason: 'More at the right padding');
        expect(save.right, moreOrLessEquals(more.left - 4, epsilon: 0.5), reason: 'Save just before More');
        // Find, Wrap and the language come before Save, in that order.
        final findTool = rectOf(tester, 'editor-tool-find');
        final wrap = rectOf(tester, 'editor-tool-wrap');
        final language = rectOf(tester, 'editor-tool-language');
        expect(findTool.right, lessThanOrEqualTo(wrap.left));
        expect(wrap.right, lessThanOrEqualTo(language.left));
        expect(language.right, lessThan(save.left));
        if (access == rootOwned) {
          final root = rectOf(tester, 'editor-save-as-root');
          expect(root.right, moreOrLessEquals(save.left - 6, epsilon: 0.5), reason: 'Save as root just before Save');
          expect(language.right, lessThan(root.left));
        }
        // The path starts at the left (after the host) and never runs under
        // the actions.
        final pathRect = rectOf(tester, 'editor-path');
        expect(pathRect.left, lessThan(bar.left + 200));
        expect(pathRect.right, lessThanOrEqualTo(findTool.left));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
