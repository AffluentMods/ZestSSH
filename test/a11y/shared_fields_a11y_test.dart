import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../visual/shots_util.dart';
import 'a11y_checks.dart';

/// The app's shared fields and the theme's text buttons, held to the 4.0
/// accessibility pass (the gaps the area passes left):
/// a click anywhere in a field's box puts the keyboard in its input, and the
/// input's own target is the box (it was its line of 16 in a box of 40); an
/// input is said by its name, a grouped one too (a port was an unnamed box);
/// a hint reads at 3:1; a text button is a mouse's 32 high (30); the dialogs'
/// own text field a finger's 48 on a phone (45); a follow-up shown in a
/// dialog's place says its title, and the dialog its own as it comes back.
void main() {
  var fonts = false;

  Future<void> pump(WidgetTester tester, Widget body,
      {String theme = 'default_dark', bool touch = false, Size size = const Size(900, 700)}) async {
    if (!fonts) {
      await tester.runAsync(loadShotFonts);
      fonts = true;
    }
    debugTouchLayout = touch;
    addTearDown(() => debugTouchLayout = null);
    final t = BuiltInThemes.getById(theme);
    AppColors.applyTheme(t.colorScheme);
    addTearDown(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: t.toThemeData(compact: !touch),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(24), child: body)),
    ));
    await tester.pumpAndSettle();
  }

  Widget form() => ZestFieldLabels(
        labels: const ['Name', 'Address', 'Password'],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ZestField(key: ValueKey('name'), label: 'Name', placeholder: 'web-01'),
            const SizedBox(height: 8),
            const ZestFieldGroup(
              key: ValueKey('address'),
              label: 'Address',
              fields: [
                ZestField.grouped(label: 'Host', placeholder: '192.168.1.10'),
                SizedBox(width: kZestPortSegmentWidth, child: ZestField.grouped(label: 'Port', placeholder: '22')),
              ],
            ),
            const SizedBox(height: 8),
            const ZestField(key: ValueKey('password'), label: 'Password', obscureText: true, value: 'secret'),
            const SizedBox(height: 8),
            TextButton(onPressed: () {}, child: const Text('Change')),
          ],
        ),
      );

  EditableText editable(WidgetTester tester, Finder within) =>
      tester.widget<EditableText>(find.descendant(of: within, matching: find.byType(EditableText)).first);

  testWidgets('a click on a field\'s name or beside its words puts the keyboard in its input', (tester) async {
    await pump(tester, form());
    final name = find.byKey(const ValueKey('name'));
    final box = tester.getRect(name);
    // On the name's cell.
    await tester.tapAt(box.centerLeft + const Offset(20, 0));
    await tester.pump();
    expect(editable(tester, name).focusNode.hasFocus, isTrue);
    // At the very foot of the box, under the words' line.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tapAt(box.bottomRight + const Offset(-4, -3));
    await tester.pump();
    expect(editable(tester, name).focusNode.hasFocus, isTrue);

    // A group: its name goes to its first input, a press beside the port's
    // words to the port.
    final group = find.byKey(const ValueKey('address'));
    final groupBox = tester.getRect(group);
    await tester.tapAt(groupBox.centerLeft + const Offset(20, 0));
    await tester.pump();
    final host = find.descendant(of: group, matching: find.byType(EditableText)).first;
    final port = find.descendant(of: group, matching: find.byType(EditableText)).last;
    expect(tester.widget<EditableText>(host).focusNode.hasFocus, isTrue);
    await tester.tapAt(groupBox.centerRight + const Offset(-4, 0));
    await tester.pump();
    expect(tester.widget<EditableText>(port).focusNode.hasFocus, isTrue);
  });

  testWidgets('each input is said by its name once, a grouped one too, and is a mouse\'s 32 at least', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, form());
    for (final (name, hint) in [('Name', 'web-01'), ('Host', '192.168.1.10'), ('Port', '22')]) {
      final node = find.bySemanticsLabel(RegExp('^$name'));
      expect(node, findsOneWidget, reason: '$name is said once, by its input');
      final data = tester.getSemantics(node);
      expect(data.flagsCollection.isTextField, isTrue, reason: name);
      // Its hint is said after its name.
      expect('${data.label} ${data.hint}', contains(hint), reason: name);
      expect(data.rect.height, greaterThanOrEqualTo(40), reason: '$name: its target is the box');
    }
    expect(find.bySemanticsLabel('Address'), findsOneWidget, reason: 'the group says its name');
    // The eye is a button by name.
    expect(find.bySemanticsLabel('Show'), findsOneWidget);
    await expectA11y(tester, computer: true, where: 'a form of fields', except: {'secret'});
    handle.dispose();
  });

  for (final theme in ['default_dark', 'graphite', 'default_light']) {
    testWidgets('$theme: the hints read at 3:1 on the field\'s well, and the words at 4.5:1', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, form(), theme: theme);
      await expectA11y(tester, computer: true, where: '$theme form');
      handle.dispose();
    });
  }

  testWidgets('a text button of the theme is a mouse\'s 32 high on a computer, the field\'s look kept at 40',
      (tester) async {
    await pump(tester, form());
    expect(tester.getSize(find.byType(TextButton)).height, 32);
    expect(tester.getSize(find.byKey(const ValueKey('name'))).height, 40);
  });

  testWidgets('touch sized, a field\'s input and its box are a finger\'s 48', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, form(), touch: true, size: const Size(412, 900));
    expect(tester.getSize(find.byKey(const ValueKey('name'))).height, greaterThanOrEqualTo(48));
    final data = tester.getSemantics(find.bySemanticsLabel(RegExp('^Name')));
    expect(data.rect.height, greaterThanOrEqualTo(48));
    await expectA11y(tester, computer: false, where: 'a phone\'s form', except: {'secret'});
    handle.dispose();
  });

  testWidgets('the dialogs\' text field: a finger\'s 48 on a phone, as before with a mouse', (tester) async {
    final handle = tester.ensureSemantics();
    final controller = TextEditingController(text: 'web-01');
    addTearDown(controller.dispose);
    Widget fields() => Column(mainAxisSize: MainAxisSize.min, children: [
          ZestTextField(key: const ValueKey('plain'), controller: controller, label: 'Name', autofocus: false),
          const SizedBox(height: 8),
          ZestTextField(key: const ValueKey('select'), controller: controller, label: 'Note', autofocus: false, likeSelect: true),
        ]);
    await pump(tester, fields(), touch: true, size: const Size(412, 900));
    for (final key in ['plain', 'select']) {
      final input = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(TextField));
      expect(tester.getSize(input).height, greaterThanOrEqualTo(48), reason: key);
    }
    await expectA11y(tester, computer: false, where: 'a phone\'s dialog fields');
    await pump(tester, fields());
    final plain = find.descendant(of: find.byKey(const ValueKey('plain')), matching: find.byType(TextField));
    final select = find.descendant(of: find.byKey(const ValueKey('select')), matching: find.byType(TextField));
    expect(tester.getSize(plain).height, greaterThanOrEqualTo(32));
    expect(tester.getSize(select).height, 34);
    await expectA11y(tester, computer: true, where: 'a computer\'s dialog fields');
    handle.dispose();
  });

  testWidgets('a follow-up shown in a dialog\'s place says its title, and the dialog says its own as it comes back',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => ZestDialogShell.showModal<void>(
            context,
            size: ZestModalSize.compact,
            tone: ZestDialogTone.info,
            title: 'Rename web-01',
            body: Builder(
              builder: (inner) => TextButton(
                onPressed: () => showZestInPlace<void>(
                  context: inner,
                  size: ZestModalSize.compact,
                  builder: (followUp) => ZestDialogShell(
                    tone: ZestDialogTone.warning,
                    title: 'Discard the new name?',
                    body: const Text('It was not saved.'),
                    secondaryAction: (label: 'Keep editing', onPressed: () => zestDialogPop(followUp)),
                  ),
                ),
                child: const Text('ask'),
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    tester.takeAnnouncements();
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    expect(tester.takeAnnouncements(), contains(isAccessibilityAnnouncement('Discard the new name?')));
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(tester.takeAnnouncements(), contains(isAccessibilityAnnouncement('Rename web-01')));
    expect(find.text('ask'), findsOneWidget);
    handle.dispose();
  });
}

