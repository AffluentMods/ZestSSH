import 'dart:async';
import 'dart:math' as math;

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/ui/widgets/hit_area.dart';

/// The row of keys above a phone's or a tablet's keyboard in a terminal.
///
/// Its keys are the two rows Settings orders (soft_key_catalog.dart's
/// defaults: ESC / | - HOME ↑ END ~ over TAB CTRL ALT DEL ← ↓ → mic), every
/// key one width, at the size Settings picks. As two rows, the rows' F keys,
/// PgUp, PgDn and INS are on an FN page, FN at the end as tall as the rows;
/// in landscape the two rows are one. Scrollable, every key is in the rows,
/// which scroll together where they do not fit. While a hardware keyboard is
/// typed on, the row can keep only the keys such a keyboard lacks
/// ([TerminalSoftKeyboard.onlyMissingKeys]).
///
/// CTRL and ALT are sticky toggles (mutually exclusive).
/// Active modifier state exposed to the parent so it can intercept
/// system-keyboard input and apply Ctrl/Alt before sending to the shell.
enum SoftKeyModifier { none, ctrl, alt }

class TerminalSoftKeyboard extends ConsumerStatefulWidget {
  final void Function(String key) onKey;
  final VoidCallback? onMicPressed;
  final bool isListening;

  /// Whether the row has its mic: not where nothing listens to it (a
  /// terminal of the computer's shell on a tablet, 4.0).
  final bool mic;

  /// Notifier for the current active modifier. The parent should listen
  /// to this and transform system-keyboard text input accordingly.
  final ValueNotifier<SoftKeyModifier>? modifierNotifier;

  /// Where set, a key at the row's end brings up the on-screen keyboard: shown
  /// once a hardware keyboard was typed on, as a tap on the terminal no
  /// longer does then.
  final VoidCallback? onShowKeyboard;

  /// Only the keys a laptop-style keyboard lacks (F1 to F12, INS, DEL, HOME,
  /// END, PgUp, PgDn): a hardware keyboard is typed on, and Settings keeps
  /// those (the default on a tablet, 3.2.1).
  final bool onlyMissingKeys;

  const TerminalSoftKeyboard({
    super.key,
    required this.onKey,
    this.onMicPressed,
    this.isListening = false,
    this.mic = true,
    this.modifierNotifier,
    this.onShowKeyboard,
    this.onlyMissingKeys = false,
  });

  @override
  ConsumerState<TerminalSoftKeyboard> createState() =>
      _TerminalSoftKeyboardState();
}

class _TerminalSoftKeyboardState extends ConsumerState<TerminalSoftKeyboard> {
  bool _ctrlActive = false;
  bool _altActive = false;
  bool _fnMode = false;
  Timer? _repeatTimer;

  @override
  void initState() {
    super.initState();
    // Listen for external modifier resets (e.g. when terminal_providers
    // consumes Ctrl+key from the system keyboard and resets the modifier).
    widget.modifierNotifier?.addListener(_onExternalModifierChange);
  }

  void _onExternalModifierChange() {
    final notifier = widget.modifierNotifier;
    if (notifier == null) return;
    final newCtrl = notifier.value == SoftKeyModifier.ctrl;
    final newAlt = notifier.value == SoftKeyModifier.alt;
    if (newCtrl != _ctrlActive || newAlt != _altActive) {
      setState(() {
        _ctrlActive = newCtrl;
        _altActive = newAlt;
      });
    }
  }

  @override
  void dispose() {
    widget.modifierNotifier?.removeListener(_onExternalModifierChange);
    _repeatTimer?.cancel();
    super.dispose();
  }

  void _startRepeat(VoidCallback action) {
    _repeatTimer?.cancel();
    // Initial delay before repeat starts
    _repeatTimer = Timer(const Duration(milliseconds: 400), () {
      // Then repeat every 80ms
      _repeatTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
        action();
      });
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  void _syncModifierNotifier() {
    final notifier = widget.modifierNotifier;
    if (notifier == null) return;
    if (_ctrlActive) {
      notifier.value = SoftKeyModifier.ctrl;
    } else if (_altActive) {
      notifier.value = SoftKeyModifier.alt;
    } else {
      notifier.value = SoftKeyModifier.none;
    }
  }

  void _sendKey(String key) {
    String toSend = key;

    if (_ctrlActive && key.length == 1) {
      // Ctrl+letter → ASCII control code
      final code = key.toUpperCase().codeUnitAt(0) - 64;
      if (code >= 1 && code <= 26) {
        toSend = String.fromCharCode(code);
      }
      setState(() => _ctrlActive = false);
      _syncModifierNotifier();
    } else if (_altActive && key.length == 1) {
      // Alt+key → ESC prefix
      toSend = '\x1B$key';
      setState(() => _altActive = false);
      _syncModifierNotifier();
    }

    haptic(ref, Haptic.light);
    widget.onKey(toSend);
  }

  void _sendEscape(String escapeSequence, {bool buzz = true}) {
    // Only the initial press vibrates; auto-repeat passes buzz: false so a
    // held arrow key doesn't buzz ~12x/second.
    if (buzz) haptic(ref, Haptic.light);
    widget.onKey(escapeSequence);
  }

  /// A key's label: the theme's own ink, as each key is a cell of the theme
  /// (a fixed white was white on white on a light theme).
  Color get _keyInk => AppColors.textSecondary;

  /// A key held on (Ctrl, Alt, the mic while it listens): its fill, and the
  /// ink that reads on it.
  // The accent itself: at 85% over a light keyboard a mid accent (IntelliJ
  // Light's blue) left no ink, dark or white, that read on it.
  Color get _heldFill => AppColors.brandOrange;
  Color get _heldInk => ZestColors.onFill(Color.alphaBlend(_heldFill, AppColors.surfaceDark));

  @override
  Widget build(BuildContext context) {
    // Feed the MediaQuery orientation to _keyHeight so every key kind shares
    // one source of truth (and reacts to split-screen resizes).
    _landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    _style = ref.watch(softKeyboardStyleProvider);
    _size = ref.watch(softKeyboardKeySizeProvider);
    final scrollableMode = ref.watch(softKeyboardScrollableModeProvider);
    final disabled = ref.watch(softKeyboardDisabledKeysProvider);
    final row1 = _shownIds(ref.watch(softKeyboardRow1OrderProvider), disabled);
    final row2 = _shownIds(ref.watch(softKeyboardRow2OrderProvider), disabled);

    final Widget layout;
    if (widget.onlyMissingKeys) {
      // A hardware keyboard typed on: only the keys it lacks.
      layout = _filledGrid(_landscape
          ? [_shownIds(hardwareMissingKeyIds, disabled)]
          : [_shownIds(hardwareMissingRow1, disabled), _shownIds(hardwareMissingRow2, disabled)]);
    } else if (scrollableMode) {
      layout = _scrollingGrid([row1, row2]);
    } else {
      // The two rows: the rows' keys on the main page, their F keys, PgUp,
      // PgDn and INS on the FN page; FN (← on its page) at the end, as tall
      // as the rows. In landscape the two are one row.
      List<String> page(List<String> ids) =>
          [for (final id in ids) if (fnPageSoftKeyIds.contains(id) == _fnMode) id];
      final top = page(row1), bottom = page(row2);
      layout = _filledGrid(_landscape ? [_oneRow(top, bottom)] : [top, bottom], side: _fnMode ? 'back' : 'fn');
    }
    Widget body = KeyedSubtree(key: ValueKey('softkeys-${_style.name}'), child: layout);
    final showKeyboard = widget.onShowKeyboard;
    if (showKeyboard != null) {
      body = IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: body),
            _showKeyboardKey(showKeyboard),
          ],
        ),
      );
    }

    // The keys are a keyboard's, of a fixed size: at a phone's larger text
    // sizes their words broke in two (HOM, E) and ran out of them (found
    // 18 October 2026), so the row keeps the size the app is drawn at, as a
    // phone's own keyboard does.
    return MediaQuery.withNoTextScaling(
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceDark,
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: 0.06),
            ),
          ),
        ),
        child: body,
      ),
    );
  }

  /// The keys of [ids] the row shows, in their order. Modifiers and the mic
  /// stay even when turned off (the row is unusable without them); an
  /// unknown id is skipped, so a typo fails closed. The old 'arrows' switch
  /// hides the four arrows. The mic is left out where the row has none
  /// ([TerminalSoftKeyboard.mic]).
  List<String> _shownIds(List<String> ids, Set<String> disabled) {
    final arrowsOff = disabled.contains('arrows');
    return [
      for (final id in ids)
        if (findSoftKey(id) != null &&
            !(id == 'mic' && !widget.mic) &&
            (pinnedSoftKeyIds.contains(id) ||
                !(disabled.contains(id) || (arrowsOff && const ['up', 'down', 'left', 'right'].contains(id)))))
          id,
    ];
  }

  /// The two rows as landscape's one: each row's keys before its first
  /// arrow, Home or End, then the rows' arrows, Home and End (one block, so
  /// HOME ↑ END ← ↓ → by default), then the rest of each.
  static List<String> _oneRow(List<String> top, List<String> bottom) {
    (List<String>, List<String>, List<String>) split(List<String> ids) {
      final first = ids.indexWhere(softKeyClusterIds.contains);
      if (first < 0) return (ids, const [], const []);
      final last = ids.lastIndexWhere(softKeyClusterIds.contains);
      return (ids.sublist(0, first), ids.sublist(first, last + 1), ids.sublist(last + 1));
    }

    final (b1, c1, a1) = split(top);
    final (b2, c2, a2) = split(bottom);
    return [...b1, ...b2, ...c1, ...c2, ...a1, ...a2];
  }

  /// The key at the row's end that brings up the on-screen keyboard, as tall
  /// as the row and 44 wide.
  Widget _showKeyboardKey(VoidCallback onTap) {
    final label = AppLocalizations.of(context)!.hwKeysShowKeyboard;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 3, 4, 3),
      child: Semantics(
        label: label,
        button: true,
        excludeSemantics: true,
        child: Tooltip(
          message: label,
          child: Material(
            key: const ValueKey('keys-row-show-keyboard'),
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () {
                haptic(ref, Haptic.light);
                onTap();
              },
              child: SizedBox(
                width: 44,
                child: Icon(LucideIcons.keyboard, size: _iconSize, color: _keyInk),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Orientation captured from [MediaQuery] in [build] - the single source of
  /// truth for key height. The old getter read the raw platform view, which
  /// ignores split-screen / multi-window sizing that MediaQuery reflects.
  bool _landscape = false;

  /// The style and the size picked in Settings, captured in [build] as
  /// [_landscape] is.
  SoftKeyRowStyle _style = SoftKeyRowStyle.grouped;
  SoftKeySize _size = SoftKeySize.medium;

  // ─── The keys (3.2.1) ─────────────────────────────────────────────
  //
  // Every key is as wide as the next, in both layouts and both styles, so
  // the rows stand in columns (the
  // arrows, Home and End were bigger than the rest). Grouped outlines the
  // arrows with Home and End; Flat does not. The size sets the keys'
  // height, words and gaps; the scrollable row's keys are as wide as the
  // size says, sharing the width where they fit, up to a widest key.

  double get _keyHeight => switch (_size) {
        SoftKeySize.small => _landscape ? 28 : 36,
        SoftKeySize.medium => _landscape ? 32 : 44,
        SoftKeySize.large => _landscape ? 38 : 52,
      };

  double get _fontSize => switch (_size) {
        SoftKeySize.small => 10,
        SoftKeySize.medium => 11,
        SoftKeySize.large => 13,
      };

  double get _iconSize => switch (_size) {
        SoftKeySize.small => 16,
        SoftKeySize.medium => 18,
        SoftKeySize.large => 20,
      };

  /// The gap between keys, across and down; the outline runs in it.
  double get _gap => switch (_size) {
        SoftKeySize.small => 3,
        SoftKeySize.medium => 4,
        SoftKeySize.large => 5,
      };

  /// A scrollable key's width where the keys do not fit (the longest
  /// labels, PgUp and CTRL, fit it), and where they do, the widest it grows
  /// to before the row stands in the middle instead.
  double get _scrollKeyWidth => switch (_size) {
        SoftKeySize.small => 44,
        SoftKeySize.medium => 52,
        SoftKeySize.large => 60,
      };

  double get _scrollKeyWidthMax => switch (_size) {
        SoftKeySize.small => 60,
        SoftKeySize.medium => 76,
        SoftKeySize.large => 92,
      };

  /// The rows of a grid with something in them; none, one empty row.
  static List<List<String>> _nonEmpty(List<List<String>> rows) {
    final kept = [for (final r in rows) if (r.isNotEmpty) r];
    return kept.isEmpty ? const [[]] : kept;
  }

  static int _columns(List<List<String>> rows, String? side) =>
      rows.fold<int>(0, (m, r) => math.max(m, r.length)) + (side == null ? 0 : 1);

  double _gridHeight(int rows) => rows * (_keyHeight + _gap) - _gap;

  /// [rows] filling the width, every key one width; [side] at their end.
  Widget _filledGrid(List<List<String>> rows, {String? side}) {
    final kept = _nonEmpty(rows);
    final columns = _columns(kept, side);
    // A height of its own: the row's IntrinsicHeight (with the show keyboard
    // key) then never asks the LayoutBuilder, which cannot answer.
    return SizedBox(
      height: _gridHeight(kept.length) + 2 * _gap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: _gap),
        child: LayoutBuilder(builder: (context, box) {
          if (columns == 0) return const SizedBox.shrink();
          final width = ((box.maxWidth - _gap * (columns - 1)) / columns).floorToDouble();
          return Align(alignment: Alignment.topCenter, child: _keyGrid(kept, width, side: side));
        }),
      ),
    );
  }

  /// The scrollable layout: its rows at the size's key width, sharing the
  /// width where they fit, up to [_scrollKeyWidthMax] (then in the middle);
  /// where they do not fit, they scroll together.
  Widget _scrollingGrid(List<List<String>> rows) {
    final kept = _nonEmpty(rows);
    final columns = _columns(kept, null);
    return SizedBox(
      height: _gridHeight(kept.length) + 2 * _gap,
      child: LayoutBuilder(builder: (context, box) {
        if (columns == 0) return const SizedBox.shrink();
        final available = box.maxWidth - 8;
        final share = ((available - _gap * (columns - 1)) / columns).floorToDouble();
        final width = share.clamp(_scrollKeyWidth, _scrollKeyWidthMax);
        final grid = _keyGrid(kept, width);
        final padding = EdgeInsets.symmetric(horizontal: 4, vertical: _gap);
        if (columns * (width + _gap) - _gap <= available) {
          return Padding(padding: padding, child: Align(alignment: Alignment.topCenter, child: grid));
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          padding: padding,
          child: grid,
        );
      }),
    );
  }

  /// The keys of [rows] in columns of [keyWidth], their tops in a line;
  /// [side] (FN, or ← on its page) after them, as tall as the rows. In the
  /// Grouped style an outline runs round each block of arrows, Home and End.
  Widget _keyGrid(List<List<String>> rows, double keyWidth, {String? side}) {
    final gap = _gap;
    final h = _keyHeight;
    final columns = _columns(rows, side);
    double x(int c) => c * (keyWidth + gap);
    double y(int r) => r * (h + gap);
    final children = <Widget>[];
    if (_style == SoftKeyRowStyle.grouped) {
      final o = gap / 2;
      final boxes = _clusterBoxes(rows);
      for (var i = 0; i < boxes.length; i++) {
        final (left, top, right, bottom) = boxes[i];
        children.add(Positioned(
          key: ValueKey(i == 0 ? 'softkey-cluster' : 'softkey-cluster-$i'),
          left: x(left) - o,
          top: y(top) - o,
          width: x(right) + keyWidth - x(left) + 2 * o,
          height: y(bottom) + h - y(top) + 2 * o,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                // The theme's own ink: an edge that reads on a dark keyboard
                // and a light one.
                border: Border.all(color: AppColors.textSecondary.withValues(alpha: 0.45)),
              ),
            ),
          ),
        ));
      }
    }
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        final id = rows[r][c];
        children.add(Positioned(
          left: x(c),
          top: y(r),
          width: keyWidth,
          height: h,
          // Its target takes in half the gap round it, so a press between
          // two keys is the nearer key's, never nothing's (4.0
          // accessibility pass).
          child: KeyedSubtree(
              key: ValueKey('softkey-$id'), child: HitArea(grow: EdgeInsets.all(gap / 2), child: _cellKey(id))),
        ));
      }
    }
    if (side != null) {
      children.add(Positioned(
        left: x(columns - 1),
        top: 0,
        width: keyWidth,
        height: _gridHeight(rows.length),
        child: KeyedSubtree(
            key: ValueKey('softkey-$side'), child: HitArea(grow: EdgeInsets.all(gap / 2), child: _cellKey(side))),
      ));
    }
    return SizedBox(
      width: columns * (keyWidth + gap) - gap,
      height: _gridHeight(rows.length),
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }

  /// The blocks of arrows, Home and End in [rows] (keys next to each other
  /// across or down), each as its first and last column and row.
  static List<(int, int, int, int)> _clusterBoxes(List<List<String>> rows) {
    bool cluster(int r, int c) =>
        r >= 0 && r < rows.length && c >= 0 && c < rows[r].length && softKeyClusterIds.contains(rows[r][c]);
    final seen = <(int, int)>{};
    final boxes = <(int, int, int, int)>[];
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        if (!cluster(r, c) || seen.contains((r, c))) continue;
        var (left, top, right, bottom) = (c, r, c, r);
        final todo = [(r, c)];
        seen.add((r, c));
        while (todo.isNotEmpty) {
          final (rr, cc) = todo.removeLast();
          left = math.min(left, cc);
          right = math.max(right, cc);
          top = math.min(top, rr);
          bottom = math.max(bottom, rr);
          for (final (dr, dc) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
            final next = (rr + dr, cc + dc);
            if (cluster(next.$1, next.$2) && seen.add(next)) todo.add(next);
          }
        }
        boxes.add((left, top, right, bottom));
      }
    }
    return boxes;
  }

  /// One key by its id: a key of the catalog, or FN and its way back.
  Widget _cellKey(String id) {
    final l10n = AppLocalizations.of(context)!;
    if (id == 'fn') {
      return _keyFace('FN', onTap: () => setState(() => _fnMode = true), semanticLabel: l10n.softKbFunctionKeysMode);
    }
    if (id == 'back') {
      return _keyFace('←', onTap: () => setState(() => _fnMode = false), semanticLabel: l10n.softKbBackToNormalKeys);
    }
    final k = findSoftKey(id)!;
    switch (k.kind) {
      case SoftKeyKind.modifier:
        return id == 'ctrl'
            ? _stickyFace(k.label, _ctrlActive, _toggleCtrl)
            : _stickyFace(k.label, _altActive, _toggleAlt);
      case SoftKeyKind.mic:
        return _micFace();
      case SoftKeyKind.send:
        final sequence = k.sequence ?? k.label;
        if (k.repeatable) return _repeatableFace(k.label, sequence);
        final semantic = switch (id) {
          'tab' => l10n.softKbTabKey,
          'home' => l10n.softKbHomeKey,
          'end' => l10n.softKbEndKey,
          'del' => l10n.softKbDeleteKey,
          'ins' => l10n.softKbInsertKey,
          'pgup' => l10n.softKbPageUpKey,
          'pgdn' => l10n.softKbPageDownKey,
          _ => null,
        };
        // A sequence that begins with ESC goes as it is; ESC itself and a
        // character take a held Ctrl or Alt.
        return _keyFace(k.label,
            onTap: () => sequence.length > 1 && sequence.startsWith('\x1B') ? _sendEscape(sequence) : _sendKey(sequence),
            semanticLabel: semantic);
    }
  }

  void _toggleCtrl() {
    setState(() {
      _ctrlActive = !_ctrlActive;
      if (_ctrlActive) _altActive = false;
    });
    _syncModifierNotifier();
  }

  void _toggleAlt() {
    setState(() {
      _altActive = !_altActive;
      if (_altActive) _ctrlActive = false;
    });
    _syncModifierNotifier();
  }

  /// A key's label, on one line, shrinking where its key is narrower than it
  /// rather than break in two.
  Widget _keyLabel(String label, {bool active = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: _fontSize,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? _heldInk : _keyInk,
          ),
        ),
      ),
    );
  }

  /// A standard key.
  Widget _keyFace(
    String label, {
    required VoidCallback onTap,
    String? semanticLabel,
  }) {
    final l10n = AppLocalizations.of(context)!;
    // The key's name once ("ESC key"; it was "ESC key, ESC", the label under
    // it read as well).
    return Semantics(
      label: semanticLabel ?? l10n.softKbKeyLabel(label),
      button: true,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Center(child: _keyLabel(label)),
        ),
      ),
    );
  }

  /// Arrow key with long-press key repeat.
  Widget _repeatableFace(String label, String escapeSequence) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      label: l10n.softKbArrowKeyLabel(label),
      button: true,
      excludeSemantics: true,
      onTap: () => _sendEscape(escapeSequence),
      child: GestureDetector(
        onLongPressStart: (_) {
          _sendEscape(escapeSequence);
          _startRepeat(() => _sendEscape(escapeSequence, buzz: false));
        },
        onLongPressEnd: (_) => _stopRepeat(),
        onLongPressCancel: _stopRepeat,
        child: Material(
          color: AppColors.surfaceLight,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            onTap: () => _sendEscape(escapeSequence),
            borderRadius: BorderRadius.circular(6),
            child: Center(child: _keyLabel(label)),
          ),
        ),
      ),
    );
  }

  /// Sticky toggle key (CTRL/ALT) - highlights when active.
  Widget _stickyFace(String label, bool active, VoidCallback onTap) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      label: l10n.softKbModifierKeyLabel(label),
      button: true,
      toggled: active,
      excludeSemantics: true,
      onTap: () {
        haptic(ref, Haptic.medium);
        onTap();
      },
      child: Material(
        color: active ? _heldFill : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: () {
            haptic(ref, Haptic.medium);
            onTap();
          },
          borderRadius: BorderRadius.circular(6),
          child: Center(child: _keyLabel(label, active: active)),
        ),
      ),
    );
  }

  /// Mic button for speech-to-text.
  Widget _micFace() {
    final l10n = AppLocalizations.of(context)!;
    final listening = widget.isListening;
    return Semantics(
      label: listening ? l10n.softKbMicStop : l10n.softKbMicStart,
      button: true,
      toggled: listening,
      child: Material(
        color: listening ? _heldFill : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: () {
            haptic(ref, Haptic.medium);
            widget.onMicPressed?.call();
          },
          borderRadius: BorderRadius.circular(6),
          child: Center(
            child: Icon(
              LucideIcons.mic,
              size: _iconSize,
              color: listening ? _heldInk : _keyInk,
            ),
          ),
        ),
      ),
    );
  }
}
