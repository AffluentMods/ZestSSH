// Remote screens (4.0): a phone's row of extra keys over its soft keyboard,
// for what a phone's keyboard lacks: Esc, Tab, the arrows, Home, End, PgUp,
// PgDn, Del, F1 to F12, Ctrl+Alt+Del, and Ctrl, Alt and Super held for the
// next key. It sends key events through the screen's keyboard (keysyms and
// scancodes), not a terminal's escape sequences, so it is a row of its own;
// its keys look like the terminal's row (Settings, Terminal, Keyboard row:
// its key size, the outline round the arrows).
//
// Ctrl, Alt and Super stay at the start; the rest are pages swiped sideways.
// Every key is a finger's target (the 4.0 accessibility pass): at least 44
// across, so a page holds as many keys as fit at that (4 on a narrow phone,
// 5 on most, 6 on a wide one or a tablet), and 48 down at the medium size
// with what its target takes of the bar's own edge, as the terminal's row.
// On an RDP host Super's cap reads "Win": it is the same key, and the name
// its person knows it by (the Windows key by itself is in the bar's menu).
// A modifier tapped once is held for the next key ([ScreenKeyboard.latched],
// let go once a key used it), tapped again it stays held until a third tap.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/screens/view/keysyms.dart';
import 'package:zestssh/features/screens/view/screen_keyboard.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/ui/widgets/hit_area.dart';

/// How a modifier of the bar is held.
enum ScreenLatch {
  /// Not held.
  off,

  /// Held for the next key only.
  once,

  /// Held until it is tapped again.
  locked,
}

/// One key of a page: its cap, what it sends, and an icon in place of the cap.
class _BarKey {
  const _BarKey(this.id, this.cap, this.keys, {this.icon, this.arrow = false});

  final String id;
  final String cap;

  /// One key, or a chord pressed in order (Ctrl+Alt+Del).
  final List<ScreenKey> keys;
  final IconData? icon;
  final bool arrow;
}

class ScreenKeyBar extends ConsumerStatefulWidget {
  const ScreenKeyBar({super.key, required this.keyboard, this.windowsKey = false});

  final ScreenKeyboard keyboard;

  /// The Super key's cap reads "Win" (an RDP host's).
  final bool windowsKey;

  static const _esc = _BarKey('esc', 'Esc', [ScreenKey.escape]);
  static const _tab = _BarKey('tab', 'Tab', [ScreenKey.tab]);
  static const _arrows = [
    _BarKey('left', '←', [ScreenKey.left], icon: LucideIcons.arrowLeft, arrow: true),
    _BarKey('up', '↑', [ScreenKey.up], icon: LucideIcons.arrowUp, arrow: true),
    _BarKey('down', '↓', [ScreenKey.down], icon: LucideIcons.arrowDown, arrow: true),
    _BarKey('right', '→', [ScreenKey.right], icon: LucideIcons.arrowRight, arrow: true),
  ];
  static const _home = _BarKey('home', 'Home', [ScreenKey.home]);
  static const _end = _BarKey('end', 'End', [ScreenKey.end]);
  static const _pgup = _BarKey('pgup', 'PgUp', [ScreenKey.pageUp]);
  static const _pgdn = _BarKey('pgdn', 'PgDn', [ScreenKey.pageDown]);
  static const _del = _BarKey('del', 'Del', [ScreenKey.delete]);

  /// Said whole to a screen reader; drawn on two lines, in one key's place.
  static const _cad = _BarKey('cad', 'Ctrl+Alt+Del', [ScreenKey.controlLeft, ScreenKey.altLeft, ScreenKey.delete]);

  static List<_BarKey> _f(int from, int to) => [for (var n = from; n <= to; n++) _BarKey('f$n', 'F$n', [ScreenKey.f(n)])];

  /// The pages swiped sideways, after the modifiers, for [perPage] keys to a
  /// page (4, 5 or 6): the arrows always together, Esc with them where there
  /// is room.
  static List<List<_BarKey>> _pagesFor(int perPage) => switch (perPage) {
        <= 4 => [
            _arrows,
            const [_esc, _tab, _home, _end],
            const [_pgup, _pgdn, _del, _cad],
            _f(1, 4),
            _f(5, 8),
            _f(9, 12),
          ],
        5 => [
            const [_esc, ..._arrows],
            const [_tab, _home, _end, _pgup, _pgdn],
            [_del, _cad, ..._f(1, 3)],
            _f(4, 8),
            _f(9, 12),
          ],
        _ => [
            const [_esc, _tab, ..._arrows],
            const [_home, _end, _pgup, _pgdn, _del, _cad],
            _f(1, 6),
            _f(7, 12),
          ],
      };

  /// The least width of a key's target: with it a page holds what fits.
  static const double minKeyTarget = 44;

  /// How many keys a page holds where the bar is [width] wide: the three
  /// modifiers and the page's keys each at least [minKeyTarget] across.
  static int perPageFor(double width) => ((width - 8) / minKeyTarget).floor().clamp(7, 9) - 3;

  static const _modifiers = [
    (ScreenModifier.ctrl, 'Ctrl'),
    (ScreenModifier.alt, 'Alt'),
    (ScreenModifier.superKey, 'Super'),
  ];

  /// The bar's height at a key size, padding included.
  static double heightFor(SoftKeySize size, {required bool landscape}) => keyHeight(size, landscape: landscape) + 8;

  /// As the terminal's row of keys (Settings, Terminal, Keyboard row): its
  /// medium is 44, which its target makes 48 with the bar's own edge.
  static double keyHeight(SoftKeySize size, {required bool landscape}) => switch (size) {
        SoftKeySize.small => landscape ? 28 : 36,
        SoftKeySize.medium => landscape ? 32 : 44,
        SoftKeySize.large => landscape ? 38 : 52,
      };

  @override
  ConsumerState<ScreenKeyBar> createState() => _ScreenKeyBarState();
}

class _ScreenKeyBarState extends ConsumerState<ScreenKeyBar> {
  final _pages = PageController();
  int _page = 0;

  /// The modifiers held until tapped again.
  final Set<ScreenModifier> _locked = {};

  ScreenKeyboard get _kb => widget.keyboard;

  @override
  void initState() {
    super.initState();
    _attach(_kb);
  }

  @override
  void didUpdateWidget(ScreenKeyBar old) {
    super.didUpdateWidget(old);
    if (old.keyboard != widget.keyboard) {
      _detach(old.keyboard);
      _locked.clear();
      _attach(widget.keyboard);
    }
  }

  void _attach(ScreenKeyboard kb) {
    kb.latched.addListener(_changed);
    kb.onLatchedUsed = _used;
  }

  void _detach(ScreenKeyboard kb) {
    kb.latched.removeListener(_changed);
    if (kb.onLatchedUsed == _used) kb.onLatchedUsed = null;
  }

  @override
  void dispose() {
    _detach(_kb);
    _pages.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// A key went with the held modifiers: those held for one key let go.
  void _used() {
    final keep = _kb.latched.value.where(_locked.contains).toSet();
    if (keep.length != _kb.latched.value.length) _kb.latched.value = keep;
  }

  ScreenLatch _latchOf(ScreenModifier m) {
    if (!_kb.latched.value.contains(m)) return ScreenLatch.off;
    return _locked.contains(m) ? ScreenLatch.locked : ScreenLatch.once;
  }

  void _tapModifier(ScreenModifier m) {
    haptic(ref, Haptic.medium);
    final held = {..._kb.latched.value};
    switch (_latchOf(m)) {
      case ScreenLatch.off:
        held.add(m);
      case ScreenLatch.once:
        _locked.add(m);
      case ScreenLatch.locked:
        _locked.remove(m);
        held.remove(m);
    }
    _kb.latched.value = held;
    setState(() {});
  }

  void _tapKey(_BarKey k) {
    haptic(ref, Haptic.light);
    if (k.keys.length == 1) {
      _kb.tapKey(k.keys.single);
    } else {
      // A chord carries its own modifiers: the held ones are not added to it.
      _kb.sendChord(k.keys);
    }
  }

  Color get _ink => AppColors.textSecondary;
  Color get _heldFill => AppColors.brandOrange;
  Color get _heldInk => ZestColors.onFill(Color.alphaBlend(_heldFill, AppColors.surfaceDark));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final size = ref.watch(softKeyboardKeySizeProvider);
    final grouped = ref.watch(softKeyboardStyleProvider) == SoftKeyRowStyle.grouped;
    final keyHeight = ScreenKeyBar.keyHeight(size, landscape: landscape);
    final fontSize = switch (size) {
      SoftKeySize.small => 11.0,
      SoftKeySize.medium => 12.5,
      SoftKeySize.large => 14.0,
    };
    final iconSize = switch (size) {
      SoftKeySize.small => 15.0,
      SoftKeySize.medium => 17.0,
      SoftKeySize.large => 19.0,
    };

    Widget label(String text, {bool held = false, int lines = 1}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              text,
              maxLines: lines,
              softWrap: false,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: fontSize,
                fontWeight: held ? FontWeight.bold : FontWeight.normal,
                color: held ? _heldInk : _ink,
              ),
            ),
          ),
        );

    Widget face({
      required Key key,
      required String semantics,
      required VoidCallback onTap,
      required Widget child,
      bool? toggled,
      String? value,
      Color? fill,
    }) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          // Its target takes in half the gap to the next key and the bar's
          // own edge above and below it (which is inside each key's place,
          // so that a page of keys does not cut it off): a press between two
          // keys is the nearer key's, and the medium key's 44 is a finger's 52.
          child: HitArea(
            grow: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Semantics(
              label: semantics,
              value: value,
              button: true,
              toggled: toggled,
              // What is under it is left out of what is read (the cap is said
              // by [semantics]), and its tap went with it: a screen reader
              // read the key and could not press it. The press is said here.
              onTap: onTap,
              excludeSemantics: true,
              child: Material(
                key: key,
                color: fill ?? AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: onTap,
                  child: SizedBox(height: keyHeight, child: Center(child: child)),
                ),
              ),
            ),
          ),
        );

    final modifiers = [
      for (final (m, name) in ScreenKeyBar._modifiers)
        Expanded(
          child: Builder(builder: (context) {
            final cap = m == ScreenModifier.superKey && widget.windowsKey ? 'Win' : name;
            final latch = _latchOf(m);
            final held = latch != ScreenLatch.off;
            return face(
              key: ValueKey('screen-key-${m.name}'),
              semantics: l10n.softKbModifierKeyLabel(cap),
              toggled: held,
              value: switch (latch) {
                ScreenLatch.off => null,
                ScreenLatch.once => l10n.screenKeyHeldOnce,
                ScreenLatch.locked => l10n.screenKeyHeldLocked,
              },
              fill: held ? _heldFill : null,
              onTap: () => _tapModifier(m),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  label(cap, held: held),
                  // Held until tapped again: a bar under the cap.
                  if (latch == ScreenLatch.locked)
                    Container(
                      key: ValueKey('screen-key-${m.name}-locked'),
                      width: 14,
                      height: 2,
                      margin: const EdgeInsets.only(top: 2),
                      color: _heldInk,
                    ),
                ],
              ),
            );
          }),
        ),
    ];

    Widget page(List<_BarKey> keys) {
      final row = <Widget>[];
      final arrows = <Widget>[];
      void flushArrows() {
        if (arrows.isEmpty) return;
        final block = Row(children: List.of(arrows));
        row.add(Expanded(
          flex: arrows.length,
          child: grouped
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.textSecondary.withValues(alpha: 0.45)),
                  ),
                  child: Padding(padding: const EdgeInsets.all(1), child: block),
                )
              : block,
        ));
        arrows.clear();
      }

      for (final k in keys) {
        final cell = Expanded(
          child: face(
            key: ValueKey('screen-key-${k.id}'),
            semantics: k.arrow ? l10n.softKbArrowKeyLabel(k.cap) : l10n.softKbKeyLabel(k.cap),
            onTap: () => _tapKey(k),
            child: k.icon != null
                ? Icon(k.icon, size: iconSize, color: _ink)
                // Ctrl+Alt+Del in one key's place: on two lines.
                : k.id == 'cad'
                    ? label('Ctrl+Alt\nDel', lines: 2)
                    : label(k.cap),
          ),
        );
        if (k.arrow) {
          arrows.add(cell);
        } else {
          flushArrows();
          row.add(cell);
        }
      }
      flushArrows();
      return Row(children: row);
    }

    // As many keys to a page as fit at a finger's width where the bar is.
    final perPage = ScreenKeyBar.perPageFor(MediaQuery.sizeOf(context).width - MediaQuery.paddingOf(context).horizontal);
    final pages = ScreenKeyBar._pagesFor(perPage);
    final pageCount = pages.length;
    // (The device turned, and its pages are fewer: back to the first.)
    if (_page >= pageCount) {
      _page = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients) _pages.jumpToPage(0);
      });
    }
    return MediaQuery.withNoTextScaling(
      child: Container(
        key: const ValueKey('screen-key-bar'),
        height: ScreenKeyBar.heightFor(size, landscape: landscape),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: AppColors.surfaceDark,
          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
        ),
        child: Row(
          children: [
            Expanded(flex: 3, child: Row(children: modifiers)),
            Expanded(
              flex: perPage,
              child: Semantics(
                hint: l10n.screenKeyBarSwipe,
                child: Stack(
                  children: [
                    PageView(
                      key: const ValueKey('screen-key-pages'),
                      controller: _pages,
                      onPageChanged: (i) => setState(() => _page = i),
                      children: [for (final p in pages) page(p)],
                    ),
                    // Which page is in front: a dot each, under the keys.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 3,
                      child: IgnorePointer(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            for (var i = 0; i < pageCount; i++)
                              Container(
                                width: 4,
                                height: 4,
                                margin: const EdgeInsets.symmetric(horizontal: 2),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: i == _page ? _heldFill : _ink.withValues(alpha: 0.35),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
