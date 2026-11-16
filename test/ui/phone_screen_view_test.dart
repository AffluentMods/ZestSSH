// A phone's remote screen (4.0): PhoneScreenView on a phone-sized
// surface over the fake engine. Frames shown, immersive while connected, the
// picture fitted inside the safe area, the host's saved options, Touch or
// Mouse pointer remembered per host, the key bar with its sticky modifiers,
// the picture sliding up for the keyboard, the bar that hides, the ended
// state and recording mode's cover.
import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/phone/phone_screen_view.dart';
import 'package:zestssh/features/screens/phone/screen_key_bar.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/keysyms.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_keyboard.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../a11y/a11y_checks.dart';
import '../features/screens/view/screen_view_fixture.dart';

const _phone = Size(390, 844);
const _ctrl = ScreenKey.controlLeft;

class _Screen {
  _Screen(this.native, this.session, this.engine);
  final FakeScreenNative native;
  final ScreenSession session;
  final FakeScreenSession engine;

  int _seq = 0;

  void frame(List<ScreenTile> tiles, {int width = 800, int height = 500}) {
    _seq++;
    engine.frames.add(ScreenFrame(seq: _seq, width: width, height: height, updates: 1, tiles: tiles));
    engine.emit(ScreenEventKind.frame, a: _seq);
  }

  List<(int, int, bool)> takeKeys() {
    final out = List.of(engine.keys);
    engine.keys.clear();
    return out;
  }
}

Future<_Screen> _connect(
  WidgetTester tester, {
  int width = 800,
  int height = 500,
  Map<String, Object?>? connected,
}) async {
  final native = FakeScreenNative();
  final session = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
  final engine = native.sessions.single;
  if (connected == null) {
    engine.connect(width: width, height: height);
  } else {
    // What the engine says of an RDP session (relative mouse taken, say).
    engine.emitJson(ScreenEventKind.connected, {'width': width, 'height': height, ...connected});
  }
  await tester.pump();
  addTearDown(session.close);
  return _Screen(native, session, engine);
}

/// The calls made to the system's UI mode (immersive or edge to edge).
final List<String> _uiModes = [];

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    _uiModes.clear();
  });

  Future<void> pumpPhone(
    WidgetTester tester, {
    required ScreenSession? session,
    String sessionId = 's1',
    String? connectionId = 'c1',
    String label = 'build box',
    ScreenOptions options = ScreenOptions.defaults,
    bool rdp = false,
    Locale locale = const Locale('en'),
    Size size = _phone,
    Widget? stateBody,
    bool recording = false,
    Widget Function(Widget)? wrapToolbar,
    VoidCallback? onDisconnect,
    VoidCallback? onFiles,
    ProviderContainer? container,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') _uiModes.add(call.arguments as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final view = PhoneScreenView(
      sessionId: sessionId,
      connectionId: connectionId,
      label: label,
      session: session,
      options: options,
      rdp: rdp,
      stateBody: stateBody,
      onBack: () {},
      onDisconnect: onDisconnect ?? () {},
      wrapToolbar: wrapToolbar,
      decodeTile: syncDecode,
      onFiles: onFiles,
    );
    final app = MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: RepaintBoundary(key: pictureKey, child: view),
    );
    await tester.pumpWidget(container != null
        ? UncontrolledProviderScope(container: container, child: app)
        : ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              recordingModeProvider.overrideWith((ref) => recording),
              recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
            ],
            child: app,
          ));
    await tester.pump();
  }

  ScreenController controllerOf(WidgetTester tester) => tester.widget<ScreenView>(find.byType(ScreenView)).controller;

  /// Brings the page of the key bar that holds the key [id] in front (a page
  /// holds as many keys as fit at a finger's width, so which page that is
  /// depends on the bar's width); the modifiers are always there.
  Future<void> showBarKey(WidgetTester tester, String id) async {
    final target = find.byKey(ValueKey('screen-key-$id'));
    final pages = find.byKey(const ValueKey('screen-key-pages'));
    if (target.hitTestable().evaluate().isNotEmpty) return;
    // Back to the first page, then on, a page at a time, until it is there.
    // (Most of a page's width: a drag loses its first 20 to telling a drag from a tap.)
    final step = tester.getSize(pages).width * 0.85;
    for (var i = 0; i < 6; i++) {
      await tester.drag(pages, Offset(step, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
    }
    for (var i = 0; i < 6 && target.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(pages, Offset(-step, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
    }
    expect(target.hitTestable(), findsOneWidget, reason: 'the key $id is on no page');
  }

  /// Taps a button of the top bar, bringing the bar back first where it hid itself.
  Future<void> tapBar(WidgetTester tester, String key) async {
    if (find.byKey(ValueKey(key)).hitTestable().evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('screen-phone-show-toolbar')));
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.byKey(ValueKey(key)));
  }

  /// Lets the bar's own timer and the double tap's window run out.
  Future<void> settle(WidgetTester tester) async {
    await settleFrames(tester);
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('connected: immersive, the picture fitted inside the safe area, frames shown', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    expect(_uiModes, ['SystemUiMode.immersiveSticky']);
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsOneWidget);
    expect(find.text('build box'), findsOneWidget);

    s.frame([tile(0, 0, 800, 500, const Color(0xFFCC2200))]);
    await settleFrames(tester);
    final c = controllerOf(tester);
    expect(c.hasPicture, isTrue);
    expect(s.engine.fullRefreshes, 1, reason: 'a page opened on a session asks for the whole picture');
    // 800 x 500 on 390 wide: fit at 390 / 800, centred between the notch and
    // the home indicator.
    final r = c.viewport.pictureRect;
    expect(r.width, closeTo(390, 0.01));
    expect(r.top, greaterThanOrEqualTo(47));
    expect(r.bottom, lessThanOrEqualTo(_phone.height - 34));
    final p = await probe(tester);
    expect(p.at(195, r.center.dy), isColor(const Color(0xFFCC2200)));
    expect(p.at(195, 20), isColor(Colors.black), reason: 'the letterbox above the picture');
    await settle(tester);
  });

  testWidgets("the host's saved options: 1:1 and view only", (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester,
        session: s.session, options: const ScreenOptions(scaling: ScreenScaling.oneToOne, viewOnly: true));
    final c = controllerOf(tester);
    expect(c.fit, ScreenFit.oneToOne);
    expect(c.viewOnly, isTrue);
    // View only: a tap sends nothing.
    await tester.tapAt(const Offset(195, 400));
    await settle(tester);
    expect(s.engine.pointers, isEmpty);
  });

  testWidgets('Touch by default, Mouse pointer from the bar, remembered for the host on this device', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    expect(controllerOf(tester).touchMode, ScreenTouchMode.touch);
    // The bar's button asks which, each with a line that says how it works.
    await tester.tap(find.byKey(const ValueKey('screen-phone-mode')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-touch-question')), findsOneWidget);
    expect(find.text('Your finger moves the pointer, like a trackpad; tap to click.'), findsOneWidget);
    expect(find.text('Tap where you want to click; hold for a right click.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-touch-question-mousePointer')));
    await tester.pump();
    expect(controllerOf(tester).touchMode, ScreenTouchMode.mousePointer);
    expect(prefs.getString(screenTouchPrefKey('c1')), 'mouse');
    expect(find.text('Mouse pointer: drag to move the pointer, tap to click'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));

    // A new page on the host (a session later): Mouse pointer again.
    final again = await _connect(tester);
    await pumpPhone(tester, session: again.session, sessionId: 's2');
    expect(controllerOf(tester).touchMode, ScreenTouchMode.mousePointer);
    // Another host keeps Touch.
    final other = await _connect(tester);
    await pumpPhone(tester, session: other.session, sessionId: 's3', connectionId: 'c2');
    expect(controllerOf(tester).touchMode, ScreenTouchMode.touch);
    await settle(tester);
  });

  testWidgets('Settings, Remote screens: Mouse pointer by default for a host never switched; a host switched to '
      'Touch keeps it', (tester) async {
    await prefs.setString(kScreenTouchDefaultKey, 'mouse');
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    expect(controllerOf(tester).touchMode, ScreenTouchMode.mousePointer);
    await tester.tap(find.byKey(const ValueKey('screen-phone-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-touch-question-touch')));
    await tester.pump();
    expect(prefs.getString(screenTouchPrefKey('c1')), 'touch');
    await tester.pump(const Duration(seconds: 3));
    final again = await _connect(tester);
    await pumpPhone(tester, session: again.session, sessionId: 's2');
    expect(controllerOf(tester).touchMode, ScreenTouchMode.touch, reason: "the host's own wins over the default");
    final unsaved = await _connect(tester);
    await pumpPhone(tester, session: unsaved.session, sessionId: 's3', connectionId: null);
    expect(controllerOf(tester).touchMode, ScreenTouchMode.mousePointer);
    await settle(tester);
  });

  testWidgets('Settings, Remote screens: recording mode may show the picture', (tester) async {
    await prefs.setString(kScreenRecordingKey, 'show');
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session, recording: true);
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsNothing);
    expect(s.engine.pauses, 0);
    await settle(tester);
  });

  testWidgets('the key bar: keys as key events, Ctrl held for one key or until tapped again', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    expect(find.byKey(const ValueKey('screen-key-bar')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-key-bar')), findsOneWidget);
    expect(tester.testTextInput.isVisible, isTrue, reason: 'the soft keyboard is asked for');
    s.takeKeys();

    Future<void> key(String id) async {
      await showBarKey(tester, id);
      await tester.tap(find.byKey(ValueKey('screen-key-$id')));
      await tester.pump();
    }

    // Esc alone.
    await key('esc');
    expect(s.takeKeys(), [(0xff1b, 0x01, true), (0xff1b, 0x01, false)]);

    // Ctrl once: around the next key only.
    await key('ctrl');
    expect(s.takeKeys(), isEmpty);
    await key('tab');
    expect(s.takeKeys(), [
      (_ctrl.keysym, _ctrl.scancode, true),
      (0xff09, 0x0f, true),
      (0xff09, 0x0f, false),
      (_ctrl.keysym, _ctrl.scancode, false),
    ]);
    await key('tab');
    expect(s.takeKeys(), [(0xff09, 0x0f, true), (0xff09, 0x0f, false)], reason: 'let go after one key');

    // Ctrl twice: held for every key until the third tap.
    await key('ctrl');
    await key('ctrl');
    expect(find.byKey(const ValueKey('screen-key-ctrl-locked')), findsOneWidget);
    await key('left');
    await key('up');
    expect(s.takeKeys(), [
      (_ctrl.keysym, _ctrl.scancode, true),
      (0xff51, 0xcb, true),
      (0xff51, 0xcb, false),
      (_ctrl.keysym, _ctrl.scancode, false),
      (_ctrl.keysym, _ctrl.scancode, true),
      (0xff52, 0xc8, true),
      (0xff52, 0xc8, false),
      (_ctrl.keysym, _ctrl.scancode, false),
    ]);
    await key('ctrl');
    expect(find.byKey(const ValueKey('screen-key-ctrl-locked')), findsNothing);
    await key('esc');
    expect(s.takeKeys(), [(0xff1b, 0x01, true), (0xff1b, 0x01, false)]);

    // Alt and Super together for one key.
    await key('alt');
    await key('superKey');
    await key('down');
    expect(s.takeKeys(), [
      (ScreenKey.altLeft.keysym, ScreenKey.altLeft.scancode, true),
      (ScreenKey.superLeft.keysym, ScreenKey.superLeft.scancode, true),
      (0xff54, 0xd0, true),
      (0xff54, 0xd0, false),
      (ScreenKey.superLeft.keysym, ScreenKey.superLeft.scancode, false),
      (ScreenKey.altLeft.keysym, ScreenKey.altLeft.scancode, false),
    ]);

    // A swipe to the next page: Home, End, ..., Ctrl+Alt+Del as one chord.
    await tester.drag(find.byKey(const ValueKey('screen-key-pages')), const Offset(-300, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await key('cad');
    expect(s.takeKeys(), [
      (_ctrl.keysym, _ctrl.scancode, true),
      (ScreenKey.altLeft.keysym, ScreenKey.altLeft.scancode, true),
      (0xffff, 0xd3, true),
      (0xffff, 0xd3, false),
      (ScreenKey.altLeft.keysym, ScreenKey.altLeft.scancode, false),
      (_ctrl.keysym, _ctrl.scancode, false),
    ]);
    // Two more: F1 to F6, then F7 to F12.
    await tester.drag(find.byKey(const ValueKey('screen-key-pages')), const Offset(-300, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await key('f5');
    expect(s.takeKeys(), [(ScreenKey.f(5).keysym, 0x3f, true), (ScreenKey.f(5).keysym, 0x3f, false)]);
    await tester.drag(find.byKey(const ValueKey('screen-key-pages')), const Offset(-300, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await key('ctrl');
    await key('f12');
    expect(s.takeKeys(), [
      (_ctrl.keysym, _ctrl.scancode, true),
      (ScreenKey.f(12).keysym, 0x58, true),
      (ScreenKey.f(12).keysym, 0x58, false),
      (_ctrl.keysym, _ctrl.scancode, false),
    ]);

    // The soft keyboard's text goes as keys too.
    tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: '  a', selection: TextSelection.collapsed(offset: 3)));
    await tester.pump();
    expect(s.takeKeys(), [(0x61, 0, true), (0x61, 0, false)]);

    // The keyboard button again: the bar and the soft keyboard go.
    await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-key-bar')), findsNothing);
    await settle(tester);
  });

  testWidgets('the soft keyboard covers the bottom: the picture keeps its size and slides up to the last tap',
      (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    s.frame([tile(0, 0, 800, 500, const Color(0xFF2266CC))]);
    await settleFrames(tester);
    final c = controllerOf(tester);
    final before = c.viewport.pictureRect;

    // A tap near the picture's bottom: the remote pointer goes there.
    final tapAt = Offset(200, before.bottom - 10);
    await tester.tapAt(tapAt);
    await settle(tester);
    expect(c.pointer.placed, isTrue);

    // The keyboard comes up (300 high) with the key bar over it.
    await tester.tap(find.byKey(const ValueKey('screen-phone-show-toolbar')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump();
    final after = c.viewport.pictureRect;
    expect(after.size, before.size, reason: 'never shrunk to a strip');
    expect(after.top, lessThan(before.top));
    final barTop = tester.getTopLeft(find.byKey(const ValueKey('screen-key-bar'))).dy;
    expect(c.viewport.obscuredBottom, closeTo(_phone.height - barTop, 0.5), reason: 'the keyboard and the bar');
    final pointerNow = c.viewport.toLocal(c.pointer.x + 0.5, c.pointer.y + 0.5);
    expect(pointerNow.dy, lessThanOrEqualTo(barTop - 24 + 0.5), reason: 'the tapped point stays above the keys');

    // The keyboard goes by itself (Back): the bar goes, the picture comes back.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-key-bar')), findsNothing);
    expect(c.viewport.pictureRect.top, closeTo(before.top, 0.01));
    await settle(tester);
  });

  testWidgets('the bar hides itself; the tab brings it back; a finger on the picture hides it', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsOneWidget);
    await tester.pump(PhoneScreenView.toolbarStays);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('screen-phone-show-toolbar')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsOneWidget);
    await tester.tapAt(const Offset(195, 420));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsNothing);
    await settle(tester);
  });

  testWidgets('a slow tap meant for the bar as it hides itself clicks nothing on the remote; a tap after that does',
      (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    s.frame([tile(0, 0, 800, 500, const Color(0xFF2266CC))]);
    await settleFrames(tester);
    await tester.pump(PhoneScreenView.toolbarStays);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('screen-phone-show-toolbar')), findsOneWidget);
    // On the picture, 100 ms after the bar went: on master, a click on the remote.
    await tester.tapAt(const Offset(195, 420));
    await settle(tester);
    expect(s.engine.pointers, isEmpty, reason: 'a late tap meant for the bar');
    expect(find.byKey(const ValueKey('screen-phone-late-tap-guard')), findsNothing);
    await tester.tapAt(const Offset(150, 400));
    await settle(tester);
    expect(s.engine.pointers, isNotEmpty, reason: 'once the moment is over, a tap clicks');
  });

  testWidgets('the bar stays while the soft keyboard is up, and hides itself again once it went', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(PhoneScreenView.toolbarStays * 3);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsOneWidget);
    // The keyboard goes by itself: the bar's time runs again.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsOneWidget);
    await tester.pump(PhoneScreenView.toolbarStays);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsNothing);
    await settle(tester);
  });

  testWidgets('the session swipe wraps the bar only, never the picture', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester,
        session: s.session, wrapToolbar: (bar) => KeyedSubtree(key: const ValueKey('swipe'), child: bar));
    expect(find.descendant(of: find.byKey(const ValueKey('swipe')), matching: find.byType(ScreenView)), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('swipe')), matching: find.byKey(const ValueKey('screen-phone-toolbar'))),
        findsOneWidget);
    await settle(tester);
  });

  testWidgets('the Windows key: by itself from the menu whatever the key bar holds; on an RDP host the bar calls '
      'Super "Win"', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session, rdp: true);
    await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
    await tester.pump();
    final superKey = find.byKey(const ValueKey('screen-key-superKey'));
    expect(find.descendant(of: superKey, matching: find.text('Win')), findsOneWidget);
    expect(find.descendant(of: superKey, matching: find.text('Super')), findsNothing);
    expect(find.bySemanticsLabel('Win modifier key'), findsOneWidget);
    // Ctrl held for the next key: the menu's key goes alone, and Ctrl is still held after it.
    await tester.tap(find.byKey(const ValueKey('screen-key-ctrl')));
    await tester.pump();
    s.takeKeys();
    await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
    await tester.pumpAndSettle();
    // The list builds its rows as they come into view: brought there first.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('screen-panel-sendSuper')),
      150,
      scrollable: find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('screen-panel-sendSuper')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-sendSuper')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing, reason: 'a key sent closes the panel');
    expect(s.takeKeys(), [
      (ScreenKey.superLeft.keysym, ScreenKey.superLeft.scancode, true),
      (ScreenKey.superLeft.keysym, ScreenKey.superLeft.scancode, false),
    ]);
    expect(controllerOf(tester).keyboard.latched.value, {ScreenModifier.ctrl});
    await settle(tester);

    // View only: the panel sends no key, and says why. A switch keeps the
    // panel open, showing its new place.
    await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-viewOnly')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('screen-panel-sendSuper')),
      150,
      scrollable: find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable)),
    );
    await tester.pumpAndSettle();
    final superButton = find.descendant(
        of: find.byKey(const ValueKey('screen-panel-sendSuper')), matching: find.byType(OutlinedButton));
    expect(tester.widget<OutlinedButton>(superButton).onPressed, isNull);
    // (Under the keys; the Send text switch, greyed for the same reason, says it too.)
    expect(find.text('Not while View only is on'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('screen-panel-close')));
    await tester.pumpAndSettle();
    await settle(tester);
  });

  testWidgets('a screen logged for its team says so on a phone for as long as it is, clear of the bar and of the tab '
      'that brings it back, with what the log holds a tap away; one that is not says nothing', (tester) async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    final en = lookupAppLocalizations(const Locale('en'));
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session, rdp: true);
    final chip = find.byKey(const ValueKey('team-logged-s1'));
    expect(chip, findsNothing);

    TeamSessionLogs.expect('s1');
    await tester.pump();
    expect(chip, findsOneWidget);
    expect(find.descendant(of: chip, matching: find.text(en.sessionLoggedChip)), findsOneWidget);
    expect(tester.widget<Tooltip>(find.ancestor(of: chip, matching: find.byType(Tooltip))).message,
        en.screenSessionLoggedTooltipRdp);
    // The bar is shown: the chip is under it.
    final bar = tester.getRect(find.byKey(const ValueKey('screen-phone-toolbar')));
    expect(tester.getRect(chip).top, greaterThanOrEqualTo(bar.bottom));
    // The bar hides itself: the chip stays, beside the tab that brings the bar back.
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsNothing);
    expect(chip, findsOneWidget);
    final tab = tester.getRect(find.byKey(const ValueKey('screen-phone-show-toolbar')));
    expect(tester.getRect(chip).overlaps(tab), isFalse);
    expect(tester.getRect(chip).top, greaterThanOrEqualTo(47), reason: 'inside the safe area');
    // A tap on it shows what the log holds, and is no click on the remote.
    s.engine.pointers.clear();
    await tester.tap(chip);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(en.screenSessionLoggedTooltipRdp), findsOneWidget);
    expect(s.engine.pointers, isEmpty);

    await tester.runAsync(() => TeamSessionLogs.end('s1'));
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(chip, findsNothing);
    await settle(tester);
  });

  testWidgets('the Logged chip never reaches the tab that brings the bar back, in any language, on a narrow phone, '
      'while the log waits to be sent too: the tab stays the thing a tap there reaches', (tester) async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    final s = await _connect(tester);
    for (final locale in AppLocalizations.supportedLocales) {
      for (final width in [320.0, 360.0]) {
        await pumpPhone(tester, session: s.session, rdp: true, locale: locale, size: Size(width, 700));
        TeamSessionLogs.expect('s1');
        // (Its log has not started: it waits, the longer of the chip's two labels on a computer.)
        await tester.pump();
        await settle(tester);
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
        final chip = find.byKey(const ValueKey('team-logged-s1'));
        final tab = find.byKey(const ValueKey('screen-phone-show-toolbar'));
        expect(chip, findsOneWidget, reason: '$locale $width');
        expect(tester.getRect(chip).right, lessThanOrEqualTo(tester.getRect(tab).left), reason: '$locale $width');
        expect(tester.getRect(chip).left, greaterThanOrEqualTo(0), reason: '$locale $width');
        // The tab is what a tap on it reaches.
        await tester.tap(tab);
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
        expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsOneWidget, reason: '$locale $width');
        TeamSessionLogs.reset();
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6));
      }
    }
  });

  testWidgets('a screen reader can press what it reads: a key of the key bar, a held modifier, and the tab that '
      'brings the bar back', (tester) async {
    final handle = tester.ensureSemantics();
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
    await tester.pump();
    s.takeKeys();

    void press(Finder what) {
      final node = tester.getSemantics(what);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue, reason: '$what has no press');
      tester.semantics.tap(find.semantics.byPredicate((n) => n.id == node.id));
    }

    // Esc: pressed as a tap presses it.
    press(find.bySemanticsLabel('Esc key'));
    await tester.pump();
    expect(s.takeKeys(), [(0xff1b, 0x01, true), (0xff1b, 0x01, false)]);
    // Ctrl held for the next key, said as on; then Tab goes with it.
    press(find.bySemanticsLabel('Ctrl modifier key'));
    await tester.pump();
    expect(tester.getSemantics(find.bySemanticsLabel('Ctrl modifier key')).getSemanticsData().flagsCollection.isToggled,
        Tristate.isTrue);
    await showBarKey(tester, 'tab');
    press(find.bySemanticsLabel('Tab key'));
    await tester.pump();
    expect(s.takeKeys(), [
      (_ctrl.keysym, _ctrl.scancode, true),
      (0xff09, 0x0f, true),
      (0xff09, 0x0f, false),
      (_ctrl.keysym, _ctrl.scancode, false),
    ]);

    // The keyboard closed, the bar hides itself: the tab brings it back, pressed the same way.
    await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
    await tester.pump();
    await settle(tester);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsNothing);
    final en = lookupAppLocalizations(const Locale('en'));
    press(find.bySemanticsLabel(en.screenPhoneShowToolbar));
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsOneWidget);
    handle.dispose();
    await settle(tester);
  });

  testWidgets('accessibility: the page meets the 4.0 pass (named controls, a finger\'s targets, contrast) with its '
      'bar, its key bar on each page of keys, its menu and its bar hidden, on a narrow phone and a wide one, for a '
      'VNC screen and an RDP host', (tester) async {
    // A phone's sizes: touch sized, as a phone draws it (the computer running the tests drew a
    // mouse's, and the finger's 48 checks held controls a phone never shows).
    debugTouchLayout = true;
    addTearDown(() => debugTouchLayout = null);
    final handle = tester.ensureSemantics();
    final s = await _connect(tester);
    final found = <String>[];
    // A key of the key bar is held to what the terminal's row of keys is (test/a11y/
    // terminal_area_a11y_test.dart): 44 across and 48 down, since a row of keys on a phone has
    // no room for 48 across. Everything else on the page is held to 48 square.
    final sized = RegExp(r'label: "[^"]* key".*found Size\(([0-9.]+), ([0-9.]+)\)');
    bool aKeyOfTheRowsSize(String line) {
      final m = sized.firstMatch(line.replaceAll('\n', ' '));
      return m != null && double.parse(m[1]!) >= 44 && double.parse(m[2]!) >= 48;
    }

    Future<void> check(String where) async => found.addAll([
          for (final f in await a11yCheck(tester, computer: false, where: where))
            if (!aKeyOfTheRowsSize(f)) f,
        ]);

    for (final (width, rdp) in [(390.0, false), (360.0, true), (320.0, false), (430.0, true)]) {
      final at = '${width.toInt()} wide, ${rdp ? 'RDP' : 'VNC'}';
      await pumpPhone(tester, session: s.session, rdp: rdp, size: Size(width, 760));
      await check('$at, the bar');
      // The key bar, every page of it.
      await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
      await tester.pump();
      for (final id in ['left', 'tab', 'del', 'f1', 'f6', 'f12']) {
        await showBarKey(tester, id);
        await check('$at, the key bar at $id');
      }
      // The menu.
      await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
      await tester.pumpAndSettle();
      await check('$at, the menu');
      await tester.tapAt(const Offset(5, 500));
      await tester.pumpAndSettle();
      // The question of the touch mode.
      await tester.tap(find.byKey(const ValueKey('screen-phone-mode')));
      await tester.pumpAndSettle();
      await check('$at, the touch question');
      await tester.tapAt(const Offset(5, 20));
      await tester.pumpAndSettle();
      // The keyboard away, the bar hidden: the tab that brings it back.
      await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
      await tester.pump();
      await settle(tester);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsNothing, reason: at);
      await check('$at, the bar hidden');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    }
    expect(found.toSet().toList(), isEmpty);
    handle.dispose();
  });

  testWidgets('the key bar holds as many keys to a page as fit at a finger\'s width, the arrows always together, '
      'and every key is on some page at every width', (tester) async {
    expect([for (final w in [320.0, 360.0, 390.0, 412.0, 430.0, 800.0]) ScreenKeyBar.perPageFor(w)], [4, 5, 5, 6, 6, 6]);
    final s = await _connect(tester);
    for (final width in [320.0, 360.0, 390.0, 430.0]) {
      await pumpPhone(tester, session: s.session, size: Size(width, 760));
      await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
      await tester.pump();
      // The arrows are on one page.
      await showBarKey(tester, 'left');
      for (final id in ['up', 'down', 'right']) {
        expect(find.byKey(ValueKey('screen-key-$id')).hitTestable(), findsOneWidget, reason: '$id at $width');
      }
      // Each key is at least 44 across with what its target takes, and reachable.
      for (final id in ['esc', 'tab', 'home', 'end', 'pgup', 'pgdn', 'del', 'cad', for (var n = 1; n <= 12; n++) 'f$n']) {
        await showBarKey(tester, id);
        expect(tester.getSize(find.byKey(ValueKey('screen-key-$id'))).width + 4, greaterThanOrEqualTo(44),
            reason: '$id at $width');
      }
      for (final id in ['ctrl', 'alt', 'superKey']) {
        expect(tester.getSize(find.byKey(ValueKey('screen-key-$id'))).width + 4, greaterThanOrEqualTo(44),
            reason: '$id at $width');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    }
  });

  testWidgets('at the system\'s largest text (200 percent) nothing of the page overflows or is cut: the bar, the '
      'key bar, the menu and the Logged chip, on a narrow phone too', (tester) async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final s = await _connect(tester);
    for (final width in [320.0, 390.0]) {
      await pumpPhone(tester, session: s.session, rdp: true, label: 'a host with quite a long name', size: Size(width, 760));
      TeamSessionLogs.expect('s1');
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'the bar at $width');
      await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'the key bar at $width');
      await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'the menu at $width');
      // Every entry of the panel is on the screen whole, scrolled to.
      for (final id in ['fit', 'viewOnly', 'sendCtrlAltDel', 'sendSuper', 'touchPointer']) {
        final row = find.byKey(ValueKey('screen-panel-$id'));
        await tester.scrollUntilVisible(row, 120, scrollable: find.descendant(
            of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable)));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        expect(tester.getRect(row).right, lessThanOrEqualTo(width), reason: '$id at $width');
        expect(tester.takeException(), isNull, reason: '$id at $width');
      }
      await tester.tapAt(const Offset(5, 500));
      await tester.pumpAndSettle();
      TeamSessionLogs.reset();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    }
  });

  testWidgets('the panel: its groups, each option with its line; a scaling picked stays open and shows it; '
      'Ctrl+Alt+Del closes it; Disconnect at its top', (tester) async {
    final s = await _connect(tester);
    var disconnects = 0;
    await pumpPhone(tester, session: s.session, onDisconnect: () => disconnects++);
    await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
    await tester.pumpAndSettle();
    expect(find.text('Screen options'), findsOneWidget);
    // The list builds its rows as they come into view: each group's head is brought there.
    final list = find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable));
    for (final g in ['session', 'video', 'input']) {
      await tester.scrollUntilVisible(find.byKey(ValueKey('screen-panel-group-$g')), 150, scrollable: list);
      expect(find.byKey(ValueKey('screen-panel-group-$g')), findsOneWidget, reason: g);
    }
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-fit')), -150, scrollable: list);
    await tester.pumpAndSettle();
    expect(find.text('The whole remote screen in view.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-panel-fill')));
    await tester.pumpAndSettle();
    expect(controllerOf(tester).fit, ScreenFit.fill);
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget, reason: 'a choice keeps the panel open');
    expect(
        find.descendant(of: find.byKey(const ValueKey('screen-panel-fill')), matching: find.byIcon(LucideIcons.circleDot)),
        findsOneWidget,
        reason: 'Fill shows as the one in use');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-sendCtrlAltDel')), 150, scrollable: list);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('screen-panel-sendCtrlAltDel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-sendCtrlAltDel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing);
    expect(s.takeKeys().length, 6);
    await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-disconnect')));
    await tester.pumpAndSettle();
    expect(disconnects, 1);
    await settle(tester);
  });

  testWidgets('Keep the bar shown: the bar stays past its time and under a finger on the picture, on this device, '
      'until turned off', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
    await tester.pumpAndSettle();
    expect(find.text('The bar over the picture stays instead of hiding itself.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-panel-keepBar')));
    await tester.pumpAndSettle();
    expect(prefs.getBool('screen_bar_kept'), isTrue);
    await tester.tap(find.byKey(const ValueKey('screen-panel-close')));
    await tester.pumpAndSettle();
    await tester.pump(PhoneScreenView.toolbarStays * 2);
    expect(find.byKey(const ValueKey('bar-shown')), findsOneWidget, reason: 'past its own time');
    await tester.tapAt(const Offset(200, 500));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('bar-shown')), findsOneWidget, reason: 'a finger on the picture leaves it');

    // A screen later on this phone: kept still. Turned off: it hides itself again.
    await pumpPhone(tester, session: s.session, sessionId: 's2');
    await tester.pump(PhoneScreenView.toolbarStays * 2);
    expect(find.byKey(const ValueKey('bar-shown')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-keepBar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-close')));
    await tester.pumpAndSettle();
    await tester.pump(PhoneScreenView.toolbarStays * 2);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bar-shown')), findsNothing);
    await settle(tester);
  });

  testWidgets('Files: offered only where the screen goes through an SSH host, and opens its files', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel-files'), skipOffstage: false), findsNothing);
    await tester.tap(find.byKey(const ValueKey('screen-panel-close')));
    await tester.pumpAndSettle();

    var opened = 0;
    await pumpPhone(tester, session: s.session, sessionId: 's2', onFiles: () => opened++);
    await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
    await tester.pumpAndSettle();
    final files = find.byKey(const ValueKey('screen-panel-files'));
    await tester.scrollUntilVisible(files, 120,
        scrollable: find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable)));
    await tester.ensureVisible(files);
    await tester.pumpAndSettle();
    expect(find.text('The files of the SSH host this screen goes through, in SFTP.'), findsOneWidget);
    await tester.tap(files);
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing, reason: 'it closes the panel');
    await settle(tester);
  });

  testWidgets('the first time in Touch: one line says a hold is a right click; Got it, and it never shows again',
      (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    expect(find.text('Hold your finger on the picture for a right click.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-hint-got-it')));
    await tester.pump();
    await pumpPhone(tester, session: s.session, sessionId: 's2');
    expect(find.byKey(const ValueKey('screen-hint-holdForRightClick')), findsNothing);
    await settle(tester);
  });

  testWidgets("not connected: the terminal's view in its place, edge to edge again", (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    expect(_uiModes, ['SystemUiMode.immersiveSticky']);
    await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
    await tester.pump();
    // The session dropped: what the terminal shows then.
    await pumpPhone(tester, session: null, stateBody: const Text('Reconnecting', key: ValueKey('dropped')));
    expect(find.byKey(const ValueKey('dropped')), findsOneWidget);
    expect(find.byType(ScreenView), findsNothing);
    expect(find.byKey(const ValueKey('screen-key-bar')), findsNothing);
    expect(_uiModes.last, 'SystemUiMode.edgeToEdge');
    expect(tester.testTextInput.isVisible, isFalse);
    expect(s.engine.pauses, 1, reason: 'nobody takes its frames any more');
    expect(find.text('build box'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('recording mode: the picture covered until "Show for this session"', (tester) async {
    final s = await _connect(tester);
    Redactor.instance
      ..clearNames()
      ..enabled = true
      ..level = RedactLevel.layout
      ..registerNames(['build box']);
    addTearDown(() => Redactor.instance
      ..clearNames()
      ..enabled = false);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      recordingModeProvider.overrideWith((ref) => true),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
    ]);
    addTearDown(container.dispose);
    await pumpPhone(tester, session: s.session, container: container);
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsOneWidget);
    expect(find.text('Recording mode is on, so the remote screen is hidden.'), findsOneWidget);
    expect(s.engine.pauses, 1, reason: 'nothing is taken while covered');
    expect(find.text('build box'), findsNothing, reason: "the host's name is masked");
    expect(find.text(Redactable.host('build box').display), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('screen-recording-show')));
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsNothing);
    expect(s.engine.resumes, 1);
    expect(container.read(screenShownWhileRecordingProvider), {'s1'});

    // Another session is covered again.
    final other = await _connect(tester);
    await pumpPhone(tester, session: other.session, sessionId: 's2', container: container);
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsOneWidget);

    // Recording mode turned off: no cover.
    container.read(recordingModeProvider.notifier).state = false;
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsNothing);
    await settle(tester);
  });

  testWidgets('a remote with two displays: the bar has the display button, its list picks one, and the panel has '
      'the Displays group; with one display there is neither', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    expect(find.byKey(const ValueKey('screen-display-button')), findsNothing, reason: 'one display');

    // The server made two of it.
    s.engine
      ..emit(ScreenEventKind.resize, a: (1600 << 32) | 500)
      ..displays(const [
        [0, 0, 800, 500],
        [800, 0, 800, 500],
      ]);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-display-button')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-display-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-display-picker-1')));
    await tester.pumpAndSettle();
    final c = controllerOf(tester);
    expect(c.displays.value.shown, 1);
    expect((c.width, c.height), (800, 500));
    expect(s.engine.shown.last, (800, 0, 800, 500));
    // The panel's Displays group, from the same list.
    await tapBar(tester, 'screen-phone-more');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-display-all')), 150,
        scrollable: find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('screen-panel-display-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-display-all')));
    await tester.pumpAndSettle();
    expect(c.displays.value.shown, isNull);
    await tester.tap(find.byKey(const ValueKey('screen-panel-close')));
    await tester.pumpAndSettle();
    await settle(tester);

    // A narrow phone at the largest text: the button is an icon that says which display is
    // shown, a finger's size, and the bar overflows nothing.
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    Future<void> at(Size size) async {
      await pumpPhone(tester, session: s.session, size: size);
      await tester.pump();
      if (find.byKey(const ValueKey('screen-phone-toolbar')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('screen-phone-show-toolbar')));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(tester.takeException(), isNull, reason: 'the bar at $size and 200 percent');
      expect(tester.getRect(find.byKey(const ValueKey('screen-phone-toolbar'))).right, lessThanOrEqualTo(size.width));
    }

    await at(const Size(375, 700));
    final button = find.byKey(const ValueKey('screen-display-button'));
    expect(button, findsOneWidget);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(button).width, lessThanOrEqualTo(48));
    expect(find.byTooltip('All displays'), findsOneWidget);
    // The narrowest: no place for it in the bar; the panel has the displays.
    await at(const Size(320, 640));
    expect(find.byKey(const ValueKey('screen-display-button')), findsNothing);
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    // Normal text: an icon on an ordinary phone (its words would leave the host's name no
    // room), the button with its words on a large one.
    await at(_phone);
    expect(find.byTooltip('All displays'), findsOneWidget);
    expect(find.text('All'), findsNothing);
    await at(const Size(440, 900));
    expect(find.text('All'), findsOneWidget);
    await settle(tester);
  });

  testWidgets('Send text: a switch of the panel puts the field along the bottom, what is sent there is typed into '
      'the remote, and asking for the keys takes the field away', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    expect(find.byKey(const ValueKey('screen-phone-send-text')), findsNothing);
    await tapBar(tester, 'screen-phone-more');
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-sendText')), 150, scrollable: list);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('screen-panel-sendText')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-sendText')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-phone-send-text')), findsOneWidget);
    // Along the bottom, inside the safe area.
    final bar = tester.getRect(find.byKey(const ValueKey('screen-phone-send-text')));
    expect(bar.bottom, lessThanOrEqualTo(_phone.height - 34 + 0.5));
    s.takeKeys();
    await tester.enterText(find.byKey(const ValueKey('screen-send-text-field')), 'ok');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('screen-send-text-send')));
    await tester.pump();
    expect(s.takeKeys().where((k) => k.$3).map((k) => k.$1), [0x6f, 0x6b], reason: 'o and k, typed');
    // The keys asked for: one keyboard at a time.
    await tapBar(tester, 'screen-phone-keyboard');
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-phone-send-text')), findsNothing);
    await settle(tester);
  });

  testWidgets('Relative mouse on a phone: in Mouse pointer mode the panel has the switch with a line of its own, and '
      'on, a finger moves the remote by how far it travels', (tester) async {
    final s = await _connect(tester, connected: const {'protocol': 'rdp', 'relative_mouse': true});
    await pumpPhone(tester, session: s.session, rdp: true, options: const ScreenOptions(relativeMouse: true));
    final c = controllerOf(tester);
    final list = find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable));
    // Touch (the default): no such switch.
    await tapBar(tester, 'screen-phone-more');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-sendText')), 150, scrollable: list);
    expect(find.byKey(const ValueKey('screen-panel-relativeMouse')), findsNothing);
    // Mouse pointer, picked as its person picks it: the switch is there.
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-touchPointer')), 150, scrollable: list);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('screen-panel-touchPointer')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-touchPointer')));
    await tester.pumpAndSettle();
    expect(c.touchMode, ScreenTouchMode.mousePointer);
    if (find.byKey(const ValueKey('screen-panel')).evaluate().isEmpty) {
      await tapBar(tester, 'screen-phone-more');
      await tester.pumpAndSettle();
    }
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-relativeMouse')), 150, scrollable: list);
    await tester.pumpAndSettle();
    expect(find.textContaining('A tap still clicks.'), findsOneWidget, reason: 'the line for a phone, not the one of a computer');
    await tester.ensureVisible(find.byKey(const ValueKey('screen-panel-relativeMouse')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-relativeMouse')));
    await tester.pumpAndSettle();
    expect(c.relativeMouse, isTrue);
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget, reason: 'a switch keeps the panel open');
    await tester.tap(find.byKey(const ValueKey('screen-panel-close')));
    await tester.pumpAndSettle();
    expect(c.touch.relative, isTrue);
    expect(tester.takeException(), isNull);
    await settle(tester);
  });

  testWidgets('Smooth scaling: the switch of a phone\'s panel turns it on for the picture and keeps it on the device',
      (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    final c = controllerOf(tester);
    expect(c.smoothScaling, isFalse);
    await tapBar(tester, 'screen-phone-more');
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-smoothScaling')), 150, scrollable: list);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('screen-panel-smoothScaling')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-smoothScaling')));
    await tester.pumpAndSettle();
    expect(c.smoothScaling, isTrue);
    final container = ProviderScope.containerOf(tester.element(find.byKey(const ValueKey('screen-panel'))));
    expect(container.read(screenSmoothScalingProvider), isTrue);
    expect(find.byKey(const ValueKey('screen-panel')), findsOneWidget, reason: 'a switch keeps the panel open');
    await tester.tap(find.byKey(const ValueKey('screen-panel-close')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await settle(tester);
  });

  testWidgets('Text size on the remote: an RDP screen on a phone asks for a size and the remote is told it',
      (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session, rdp: true);
    final c = controllerOf(tester);
    await tapBar(tester, 'screen-phone-more');
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-textSize')), 150, scrollable: list);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('screen-panel-textSize')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-textSize')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-text-size-question')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('screen-text-size-question-200')));
    await tester.pumpAndSettle();
    expect(c.textScale, 200);
    expect(s.engine.layouts, hasLength(1));
    expect((s.engine.layouts.single.single as Map)['scale'], 200);
    expect(tester.takeException(), isNull);
    await settle(tester);
  });

  testWidgets('Session details: the switch of the panel opens the sheet and closes the panel; it is sampled while the '
      'sheet is open and no longer once it is closed', (tester) async {
    final s = await _connect(tester);
    await pumpPhone(tester, session: s.session);
    final c = controllerOf(tester);
    expect(c.detailsShown, isFalse);
    await tapBar(tester, 'screen-phone-more');
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byKey(const ValueKey('screen-panel-list')), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.byKey(const ValueKey('screen-panel-sessionDetails')), 150, scrollable: list);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('screen-panel-sessionDetails')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('screen-panel-sessionDetails')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-panel')), findsNothing, reason: 'the panel gets out of the way');
    expect(find.text('Session details'), findsWidgets);
    expect(c.detailsShown, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(c.details.value.last, hasLength(2));

    // Closed, however it goes: no longer sampled.
    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pumpAndSettle();
    expect(c.detailsShown, isFalse);
    final kept = c.details.value;
    await tester.pump(const Duration(seconds: 3));
    expect(c.details.value, same(kept));
    expect(tester.takeException(), isNull);
    await settle(tester);
  });
}
