import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The one list of what can be done to a remote screen (4.0): a
/// computer's menu and a phone's are drawn from it and from what the session
/// offers now, so neither names an action itself.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  group('the list', () {
    test('every action has a group, words and an icon in every language', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        for (final a in ScreenAction.values) {
          expect(a.labelIn(l10n).trim(), isNotEmpty, reason: '${locale.languageCode} ${a.name}');
          expect(a.icon.codePoint, greaterThan(0), reason: a.name);
          expect(ScreenActionGroup.values, contains(a.group));
        }
        for (final g in ScreenActionGroup.values) {
          expect(g.titleIn(l10n).trim(), isNotEmpty, reason: '${locale.languageCode} ${g.name}');
        }
      }
    });

    test('a choice names the set it is one of, itself among them, and the others name none', () {
      for (final a in ScreenAction.values) {
        if (a.kind == ScreenActionKind.choice) {
          expect(a.choices, contains(a), reason: a.name);
          expect(a.choices.length, greaterThan(1), reason: a.name);
          for (final other in a.choices) {
            expect(other.choices, a.choices, reason: '${a.name} and ${other.name} are one set');
            expect(other.group, a.group, reason: 'a set is in one group');
          }
        } else {
          expect(a.choices, isEmpty, reason: a.name);
        }
      }
    });

    test('the keys an action sends, and that only the send actions send any', () {
      expect(ScreenAction.sendCtrlAltDel.keysWith(ScreenMenuKey.f8), hasLength(3));
      expect(ScreenAction.sendMenuKey.keysWith(ScreenMenuKey.f8), [ScreenMenuKey.f8.key]);
      expect(ScreenAction.sendMenuKey.labelIn(en), contains('F8'));
      expect({for (final a in ScreenAction.values) if (a.sendsKeys) a}, ScreenAction.sends.toSet());
      for (final a in ScreenAction.sends) {
        expect(a.kind, ScreenActionKind.plain);
        expect(a.group, ScreenActionGroup.input);
      }
    });

    test('a scaling and a touch mode are found from their action and back', () {
      for (final f in ScreenFit.values) {
        expect(ScreenAction.ofFit(f).fitMode, f);
      }
      for (final m in ScreenTouchMode.values) {
        expect(ScreenAction.ofTouch(m).touchMode, m);
      }
      expect(ScreenAction.remoteResize.fitMode, isNull, reason: 'the remote takes the size: not a scaling of the picture');
    });
  });

  group('what a session offers', () {
    ScreenMenuState computer({
      ScreenFit fit = ScreenFit.fit,
      bool viewOnly = false,
      bool fullScreen = false,
      bool keyboardHeld = true,
      bool rdp = false,
      bool resizing = false,
      bool clipboardTogglable = false,
      bool clipboardOn = false,
    }) =>
        ScreenMenuState.of(
          phone: false,
          fit: fit,
          viewOnly: viewOnly,
          fullScreen: fullScreen,
          keyboardHeld: keyboardHeld,
          canResizeRemote: rdp,
          resizingRemote: resizing,
          clipboardTogglable: clipboardTogglable,
          clipboardOn: clipboardOn,
        );

    ScreenMenuState phone({
      ScreenFit fit = ScreenFit.fit,
      bool viewOnly = false,
      bool clipboardTogglable = false,
      bool clipboardOn = false,
      ScreenTouchMode mode = ScreenTouchMode.touch,
      bool sendText = false,
    }) =>
        ScreenMenuState.of(
          phone: true,
          sendTextShown: sendText,
          fit: fit,
          viewOnly: viewOnly,
          clipboardTogglable: clipboardTogglable,
          clipboardOn: clipboardOn,
          touchMode: mode,
        );

    test('a computer: what its menu had before, and nothing of a phone', () {
      final s = computer();
      expect(s.inGroup(ScreenActionGroup.session),
          [ScreenAction.fit, ScreenAction.fill, ScreenAction.oneToOne, ScreenAction.viewOnly, ScreenAction.fullScreen, ScreenAction.disconnect]);
      expect(s.inGroup(ScreenActionGroup.video),
          [ScreenAction.refresh, ScreenAction.frameLimit, ScreenAction.smoothScaling]);
      expect(s.inGroup(ScreenActionGroup.input), [...ScreenAction.sends, ScreenAction.releaseKeyboard]);
      expect(s.inGroup(ScreenActionGroup.clipboard), isEmpty);
      // And, since 4.0, the session's details.
      expect(s.inGroup(ScreenActionGroup.details), [ScreenAction.sessionDetails]);
      expect(s.groups,
          [ScreenActionGroup.session, ScreenActionGroup.video, ScreenActionGroup.input, ScreenActionGroup.details]);
      expect(s.offers(ScreenAction.touchTouch), isFalse);
      expect(s.offers(ScreenAction.pasteToRemote), isFalse);
      expect(s.on, {ScreenAction.fit});
      expect(s.disabled, isEmpty);
    });

    test('a computer: RDP offers the remote taking the size, and it is the choice in use while it does', () {
      expect(computer().offers(ScreenAction.remoteResize), isFalse);
      final s = computer(rdp: true, resizing: true);
      expect(s.offers(ScreenAction.remoteResize), isTrue);
      expect(s.isOn(ScreenAction.remoteResize), isTrue);
      expect(s.isOn(ScreenAction.fit), isFalse, reason: 'one choice of the set is in use');
      expect(computer(rdp: true, fit: ScreenFit.fill).on, {ScreenAction.fill});
      // A VNC screen that was told to resize (it cannot): the scaling is what is in use.
      expect(computer(resizing: true).on, {ScreenAction.fit});
    });

    test('a computer: no keyboard to let go of where the picture does not hold it; full screen is on when it is', () {
      expect(computer(keyboardHeld: false).offers(ScreenAction.releaseKeyboard), isFalse);
      expect(computer(fullScreen: true).isOn(ScreenAction.fullScreen), isTrue);
    });

    test('a computer: the clipboard switch only where its person may turn it, and no Paste row', () {
      expect(computer().offers(ScreenAction.clipboard), isFalse);
      final s = computer(clipboardTogglable: true, clipboardOn: true);
      expect(s.inGroup(ScreenActionGroup.clipboard), [ScreenAction.clipboard]);
      expect(s.isOn(ScreenAction.clipboard), isTrue);
    });

    test('a phone: the touch modes, every key but the menu key, no full screen and no keyboard to let go of', () {
      final s = phone(mode: ScreenTouchMode.mousePointer);
      expect(s.inGroup(ScreenActionGroup.input), [
        for (final a in ScreenAction.sends)
          if (a != ScreenAction.sendMenuKey) a,
        ScreenAction.touchPointer,
        ScreenAction.touchTouch,
        ScreenAction.sendText,
      ]);
      expect(s.isOn(ScreenAction.touchPointer), isTrue);
      expect(s.isOn(ScreenAction.touchTouch), isFalse);
      expect(s.offers(ScreenAction.fullScreen), isFalse);
      expect(s.offers(ScreenAction.releaseKeyboard), isFalse);
      expect(s.offers(ScreenAction.remoteResize), isFalse);
    });

    test('a phone: Paste to remote is there with the switch, and to be picked only while the clipboard is on', () {
      expect(phone().inGroup(ScreenActionGroup.clipboard), isEmpty);
      final off = phone(clipboardTogglable: true);
      expect(off.inGroup(ScreenActionGroup.clipboard), [ScreenAction.clipboard, ScreenAction.pasteToRemote]);
      expect(off.enabled(ScreenAction.pasteToRemote), isFalse);
      expect(off.enabled(ScreenAction.clipboard), isTrue);
      final on = phone(clipboardTogglable: true, clipboardOn: true);
      expect(on.enabled(ScreenAction.pasteToRemote), isTrue);
      expect(on.isOn(ScreenAction.clipboard), isTrue);
    });

    test('a phone: Send text is a switch, on while its field is shown; a computer has none', () {
      expect(ScreenAction.sendText.kind, ScreenActionKind.toggle);
      expect(ScreenAction.sendText.group, ScreenActionGroup.input);
      expect(phone().isOn(ScreenAction.sendText), isFalse);
      expect(phone(sendText: true).isOn(ScreenAction.sendText), isTrue);
      expect(computer().offers(ScreenAction.sendText), isFalse);
      // View only: its field would send nothing, so it cannot be opened; one that is open
      // already can still be closed.
      expect(phone(viewOnly: true).whyNot[ScreenAction.sendText], ScreenWhyNot.viewOnly);
      expect(phone(viewOnly: true, sendText: true).enabled(ScreenAction.sendText), isTrue);
    });

    test('the session\'s details: a switch on a computer and on a phone, on while they are shown', () {
      expect(ScreenAction.sessionDetails.kind, ScreenActionKind.toggle);
      expect(ScreenAction.sessionDetails.group, ScreenActionGroup.details);
      for (final phoneView in [true, false]) {
        final off = ScreenMenuState.of(phone: phoneView, fit: ScreenFit.fit, viewOnly: true);
        expect(off.enabled(ScreenAction.sessionDetails), isTrue, reason: 'looking at numbers sends nothing');
        expect(off.isOn(ScreenAction.sessionDetails), isFalse);
        final on = ScreenMenuState.of(phone: phoneView, fit: ScreenFit.fit, viewOnly: false, detailsShown: true);
        expect(on.isOn(ScreenAction.sessionDetails), isTrue);
      }
    });

    test('relative mouse: a switch on a computer whose host asks for it, and why it cannot be turned on', () {
      ScreenMenuState of({bool asked = true, bool taken = true, bool here = true, bool on = false, bool viewOnly = false}) =>
          ScreenMenuState.of(
            phone: false,
            fit: ScreenFit.fit,
            viewOnly: viewOnly,
            relativeAsked: asked,
            relativeTaken: taken,
            relativeHere: here,
            relativeOn: on,
          );
      expect(ScreenAction.relativeMouse.kind, ScreenActionKind.toggle);
      expect(ScreenAction.relativeMouse.group, ScreenActionGroup.input);
      expect(computer().offers(ScreenAction.relativeMouse), isFalse, reason: 'a host that does not ask has no switch');
      expect(of(asked: false, on: true).isOn(ScreenAction.relativeMouse), isFalse);
      expect(of().enabled(ScreenAction.relativeMouse), isTrue);
      expect(of(on: true).isOn(ScreenAction.relativeMouse), isTrue);
      // Why not: this computer first (nothing its person can do), then the server, then view only.
      expect(of(here: false, taken: false, viewOnly: true).whyNot[ScreenAction.relativeMouse], ScreenWhyNot.relativeHere);
      expect(of(taken: false, viewOnly: true).whyNot[ScreenAction.relativeMouse], ScreenWhyNot.relativeServer);
      expect(of(viewOnly: true).whyNot[ScreenAction.relativeMouse], ScreenWhyNot.viewOnly);
      expect(of(taken: false).whyNotIn(en, ScreenAction.relativeMouse), 'This server does not take relative mouse movement');
      expect(of(here: false).whyNotIn(en, ScreenAction.relativeMouse), 'Not available on this computer yet');
      // A phone has no such switch (its part is the Mouse pointer mode, later).
      expect(
        ScreenMenuState.of(phone: true, fit: ScreenFit.fit, viewOnly: false, relativeAsked: true, relativeTaken: true, relativeHere: true)
            .offers(ScreenAction.relativeMouse),
        isFalse,
      );
    });

    test('text size on the remote: an entry of the Video group where the screen is RDP, on a computer and a '
        'phone, picked also while the screen is only looked at', () {
      ScreenMenuState of({required bool phone, bool offered = true, bool viewOnly = false}) => ScreenMenuState.of(
          phone: phone, fit: ScreenFit.fit, viewOnly: viewOnly, textSizeOffered: offered);
      expect(ScreenAction.textSize.kind, ScreenActionKind.plain);
      expect(ScreenAction.textSize.group, ScreenActionGroup.video);
      expect(ScreenAction.textSize.labelIn(en), 'Text size on the remote');
      for (final onPhone in [true, false]) {
        expect(of(phone: onPhone).offers(ScreenAction.textSize), isTrue);
        expect(of(phone: onPhone, offered: false).offers(ScreenAction.textSize), isFalse, reason: 'a VNC screen');
        expect(of(phone: onPhone, viewOnly: true).enabled(ScreenAction.textSize), isTrue,
            reason: 'nothing is sent to the remote as input');
        final s = of(phone: onPhone);
        final groups = [for (final a in s.offered) a.group.index];
        expect(groups, [...groups]..sort(), reason: 'still in listed order');
        expect(s.inGroup(ScreenActionGroup.video),
            [ScreenAction.refresh, ScreenAction.textSize, ScreenAction.frameLimit, ScreenAction.smoothScaling]);
      }
    });

    test('Command key as Ctrl: a switch of the Input group on a Mac only, never on a phone', () {
      ScreenMenuState of({bool phone = false, bool mac = true, bool on = false, bool viewOnly = false}) =>
          ScreenMenuState.of(
              phone: phone, fit: ScreenFit.fit, viewOnly: viewOnly, commandKeyOffered: mac, commandAsControl: on);
      expect(ScreenAction.commandAsControl.kind, ScreenActionKind.toggle);
      expect(ScreenAction.commandAsControl.group, ScreenActionGroup.input);
      expect(ScreenAction.commandAsControl.labelIn(en), 'Command key as Ctrl');
      expect(of().offers(ScreenAction.commandAsControl), isTrue);
      expect(of(mac: false, on: true).offers(ScreenAction.commandAsControl), isFalse);
      expect(of(mac: false, on: true).isOn(ScreenAction.commandAsControl), isFalse);
      expect(of(phone: true).offers(ScreenAction.commandAsControl), isFalse);
      expect(of().isOn(ScreenAction.commandAsControl), isFalse);
      expect(of(on: true).isOn(ScreenAction.commandAsControl), isTrue);
      expect(of(viewOnly: true).enabled(ScreenAction.commandAsControl), isTrue);
      final groups = [for (final a in of().offered) a.group.index];
      expect(groups, [...groups]..sort());
    });

    test('Smooth scaling: a switch of the Video group on a computer and a phone, whatever the screen', () {
      ScreenMenuState of({required bool phone, bool on = false, bool viewOnly = false}) =>
          ScreenMenuState.of(phone: phone, fit: ScreenFit.fit, viewOnly: viewOnly, smoothScaling: on);
      expect(ScreenAction.smoothScaling.kind, ScreenActionKind.toggle);
      expect(ScreenAction.smoothScaling.group, ScreenActionGroup.video);
      expect(ScreenAction.smoothScaling.labelIn(en), 'Smooth scaling');
      for (final onPhone in [true, false]) {
        expect(of(phone: onPhone).offers(ScreenAction.smoothScaling), isTrue);
        expect(of(phone: onPhone).isOn(ScreenAction.smoothScaling), isFalse);
        expect(of(phone: onPhone, on: true).isOn(ScreenAction.smoothScaling), isTrue);
        expect(of(phone: onPhone, viewOnly: true).enabled(ScreenAction.smoothScaling), isTrue);
        final groups = [for (final a in of(phone: onPhone).offered) a.group.index];
        expect(groups, [...groups]..sort());
      }
    });

    test('Open in its own window: an entry of the Session group on a computer that can, never on a phone', () {
      ScreenMenuState of({bool phone = false, bool can = true, bool viewOnly = false}) =>
          ScreenMenuState.of(phone: phone, fit: ScreenFit.fit, viewOnly: viewOnly, ownWindowOffered: can);
      expect(ScreenAction.ownWindow.kind, ScreenActionKind.plain);
      expect(ScreenAction.ownWindow.group, ScreenActionGroup.session);
      expect(ScreenAction.ownWindow.labelIn(en), 'Open in its own window');
      expect(of().offers(ScreenAction.ownWindow), isTrue);
      expect(of(can: false).offers(ScreenAction.ownWindow), isFalse);
      expect(of(phone: true).offers(ScreenAction.ownWindow), isFalse);
      expect(of(viewOnly: true).enabled(ScreenAction.ownWindow), isTrue);
      final groups = [for (final a in of().offered) a.group.index];
      expect(groups, [...groups]..sort());
    });

    test('Frame rate limit: an entry of the Video group on every screen, a computer and a phone', () {
      expect(ScreenAction.frameLimit.kind, ScreenActionKind.plain);
      expect(ScreenAction.frameLimit.group, ScreenActionGroup.video);
      expect(ScreenAction.frameLimit.labelIn(en), 'Frame rate limit');
      for (final onPhone in [true, false]) {
        final s = ScreenMenuState.of(phone: onPhone, fit: ScreenFit.fit, viewOnly: true);
        expect(s.offers(ScreenAction.frameLimit), isTrue);
        expect(s.enabled(ScreenAction.frameLimit), isTrue, reason: 'nothing is sent to the remote');
        expect(s.inGroup(ScreenActionGroup.video),
            [ScreenAction.refresh, ScreenAction.frameLimit, ScreenAction.smoothScaling]);
      }
    });

    test('relative mouse on a phone: a switch in Mouse pointer mode where the host asks, not in Touch', () {
      ScreenMenuState of({ScreenTouchMode mode = ScreenTouchMode.mousePointer, bool asked = true, bool taken = true, bool on = false}) =>
          ScreenMenuState.of(
            phone: true,
            fit: ScreenFit.fit,
            viewOnly: false,
            touchMode: mode,
            relativeAsked: asked,
            relativeTaken: taken,
            relativeHere: true,
            relativeOn: on,
          );
      expect(of().offers(ScreenAction.relativeMouse), isTrue);
      expect(of().enabled(ScreenAction.relativeMouse), isTrue);
      expect(of(on: true).isOn(ScreenAction.relativeMouse), isTrue);
      expect(of(asked: false).offers(ScreenAction.relativeMouse), isFalse);
      // Touch: a finger on a pixel is a place. No switch, and not shown as on.
      expect(of(mode: ScreenTouchMode.touch, on: true).offers(ScreenAction.relativeMouse), isFalse);
      expect(of(mode: ScreenTouchMode.touch, on: true).isOn(ScreenAction.relativeMouse), isFalse);
      // A server that does not take it: there, greyed, with the reason.
      expect(of(taken: false).whyNotIn(en, ScreenAction.relativeMouse), 'This server does not take relative mouse movement');
      final groups = [for (final a in of().offered) a.group.index];
      expect(groups, [...groups]..sort());
    });

    test('the menu of a screen in its own window: what a window does by itself, nothing of the tab', () {
      final s = ScreenMenuState.of(
        phone: false,
        fit: ScreenFit.fit,
        viewOnly: false,
        keyboardHeld: false,
        canResizeRemote: true,
        textSizeOffered: true,
        inOwnWindow: true,
      );
      for (final a in const [
        ScreenAction.fit,
        ScreenAction.remoteResize,
        ScreenAction.viewOnly,
        ScreenAction.fullScreen,
        ScreenAction.refresh,
        ScreenAction.textSize,
        ScreenAction.frameLimit,
        ScreenAction.smoothScaling,
        ScreenAction.sendCtrlAltDel,
        ScreenAction.sendMenuKey,
      ]) {
        expect(s.offers(a), isTrue, reason: a.name);
      }
      for (final a in const [
        ScreenAction.disconnect,
        ScreenAction.ownWindow,
        ScreenAction.sessionDetails,
        ScreenAction.clipboard,
        ScreenAction.files,
        ScreenAction.relativeMouse,
        ScreenAction.releaseKeyboard,
      ]) {
        expect(s.offers(a), isFalse, reason: a.name);
      }
      expect(s.groups, [ScreenActionGroup.session, ScreenActionGroup.video, ScreenActionGroup.input]);
    });

    test('what is offered is named in the order it is listed, group after group', () {
      // A list drawn from it top to bottom meets no row above the one before.
      for (final s in [
        computer(rdp: true, clipboardTogglable: true),
        phone(clipboardTogglable: true, clipboardOn: true),
      ]) {
        final groups = [for (final a in s.offered) a.group.index];
        expect(groups, [...groups]..sort(), reason: '${s.offered.map((a) => a.name)}');
      }
    });

    test('a row that cannot be picked says why, in every language; one that can says nothing', () {
      final viewOnly = phone(viewOnly: true, clipboardTogglable: true, clipboardOn: true);
      final clipboardOff = phone(viewOnly: true, clipboardTogglable: true);
      expect(viewOnly.whyNot[ScreenAction.sendCtrlAltDel], ScreenWhyNot.viewOnly);
      expect(viewOnly.whyNot[ScreenAction.pasteToRemote], ScreenWhyNot.viewOnly);
      // Both stand in the way: the clipboard is the one its person turns on first.
      expect(clipboardOff.whyNot[ScreenAction.pasteToRemote], ScreenWhyNot.clipboardOff);
      expect(viewOnly.whyNotIn(en, ScreenAction.sendCtrlAltDel), 'Not while View only is on');
      expect(clipboardOff.whyNotIn(en, ScreenAction.pasteToRemote), 'Turn on Share the clipboard first');
      expect(viewOnly.whyNotIn(en, ScreenAction.viewOnly), isNull);
      expect(computer().whyNotIn(en, ScreenAction.pasteToRemote), isNull, reason: 'not offered: nothing to say');
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        for (final w in ScreenWhyNot.values) {
          expect(w.textIn(l10n).trim(), isNotEmpty, reason: '${locale.languageCode} ${w.name}');
        }
        // The switch is named by the words it has in that language.
        expect(ScreenWhyNot.viewOnly.textIn(l10n), contains(l10n.connectionEditScreenViewOnly));
        // The line over a held pointer names the key that gets it back.
        expect(l10n.screenPointerHeld('F8'), contains('F8'));
        expect(ScreenWhyNot.clipboardOff.textIn(l10n), contains(l10n.connectionEditScreenClipboard));
      }
    });

    test('view only: nothing is sent, on a computer and on a phone', () {
      for (final s in [computer(viewOnly: true), phone(viewOnly: true, clipboardTogglable: true, clipboardOn: true)]) {
        expect(s.isOn(ScreenAction.viewOnly), isTrue);
        for (final a in ScreenAction.sends) {
          if (s.offers(a)) expect(s.enabled(a), isFalse, reason: a.name);
        }
        expect(s.enabled(ScreenAction.pasteToRemote), isFalse);
        // What sends nothing stays.
        expect(s.enabled(ScreenAction.viewOnly), isTrue);
        expect(s.enabled(ScreenAction.disconnect), isTrue);
        expect(s.enabled(ScreenAction.fill), isTrue);
      }
    });

    test('the picture covered: whatever sends to the remote is off and says so, before any other reason; the rest '
        'stays as it was', () {
      for (final phoneView in [false, true]) {
        final seen = ScreenMenuState.of(
            phone: phoneView, fit: ScreenFit.fit, viewOnly: false, clipboardTogglable: true, clipboardOn: true);
        final covered = ScreenMenuState.of(
            phone: phoneView,
            fit: ScreenFit.fit,
            viewOnly: false,
            clipboardTogglable: true,
            clipboardOn: true,
            relativeAsked: true,
            relativeTaken: true,
            relativeHere: true,
            touchMode: phoneView ? ScreenTouchMode.mousePointer : null,
            covered: true);
        for (final a in ScreenAction.sends) {
          if (!covered.offered.contains(a)) continue;
          expect(seen.enabled(a), isTrue, reason: '$a seen');
          expect(covered.enabled(a), isFalse, reason: '$a covered');
          expect(covered.whyNot[a], ScreenWhyNot.covered);
        }
        expect(covered.whyNot[ScreenAction.relativeMouse], ScreenWhyNot.covered);
        if (phoneView) {
          expect(covered.whyNot[ScreenAction.pasteToRemote], ScreenWhyNot.covered);
          expect(covered.whyNot[ScreenAction.sendText], ScreenWhyNot.covered);
        }
        // What sends nothing to the remote can still be picked.
        for (final a in [ScreenAction.viewOnly, ScreenAction.disconnect, ScreenAction.smoothScaling, ScreenAction.frameLimit, ...ScreenAction.fits]) {
          expect(covered.enabled(a), isTrue, reason: '$a');
        }
        // Covered is the reason said even where view only is on too, and where the clipboard is off.
        final both = ScreenMenuState.of(
            phone: phoneView, fit: ScreenFit.fit, viewOnly: true, clipboardTogglable: true, covered: true);
        expect(both.whyNot[ScreenAction.sendCtrlAltDel], ScreenWhyNot.covered);
        if (phoneView) expect(both.whyNot[ScreenAction.pasteToRemote], ScreenWhyNot.covered);
      }
      // The reason has words in every language.
      for (final locale in AppLocalizations.supportedLocales) {
        expect(ScreenWhyNot.covered.textIn(lookupAppLocalizations(locale)), isNotEmpty, reason: '$locale');
      }
    });

    test('what is not offered is neither on nor disabled, and cannot be picked', () {
      for (final s in [computer(viewOnly: true), phone(), computer(rdp: true, resizing: true, clipboardTogglable: true)]) {
        expect(s.on.difference(s.offered), isEmpty);
        expect(s.disabled.difference(s.offered), isEmpty);
        for (final a in ScreenAction.values) {
          if (!s.offers(a)) expect(s.enabled(a), isFalse, reason: a.name);
        }
      }
    });

    test('of a set of choices exactly one is in use', () {
      for (final s in [computer(), computer(rdp: true, resizing: true), phone(), phone(fit: ScreenFit.oneToOne)]) {
        final sets = {for (final a in s.offered) if (a.kind == ScreenActionKind.choice) a.choices.first: a.choices};
        for (final set in sets.values) {
          expect(set.where(s.isOn), hasLength(1), reason: set.map((a) => a.name).join(', '));
        }
      }
    });
  });

  group('who draws from the list', () {
    String read(String path) => File(path).readAsStringSync();

    test('the views hand the state and the action handler to their bars', () {
      final pane = read('lib/features/screens/desktop/screen_pane.dart');
      expect(pane, contains('menu: _menuState()'));
      expect(pane, contains('ScreenMenuState.of('));
      final phone = read('lib/features/screens/phone/phone_screen_view.dart');
      expect(phone, contains('menu: _menuState(c)'));
      expect(phone, contains('onAction: _act'));
      // The phone's older menu rows go through the same handler.
      expect(phone, contains('void _menu(ScreenPhoneMenu item) => _act(item.action);'));
    });

    test('the list is the model\'s: the computer\'s menu file hands it on and declares none', () {
      final menu = read('lib/features/screens/desktop/screen_menu.dart');
      expect(menu, contains("export 'package:zestssh/features/screens/model/screen_action.dart';"));
      expect(menu, isNot(contains('enum ScreenAction')));
    });
  });
}
