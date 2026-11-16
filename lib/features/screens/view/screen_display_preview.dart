// Remote screens (4.0): a small live picture of one of the remote's
// displays, for the strip left of a computer's remote picture.
//
// It reads the display through a view of the session's picture (the engine's
// own reader for a part of it), whose picture the engine makes smaller: a
// display of 3840 by 2160 comes as 480 by 270, not as itself. A view is never
// told of a change, so the picture is asked for twice a second, which is all
// a picture this size needs; while the screen is paused (its tab not in
// front), covered (recording mode) or not shown, nothing is asked and nothing
// is drawn.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/features/screens/model/screen_displays.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/theme/app_colors.dart';

class ScreenDisplayPreview extends StatefulWidget {
  const ScreenDisplayPreview({
    super.key,
    required this.controller,
    required this.index,
    required this.size,
    this.covered = false,
    this.decodeTile,
  });

  final ScreenController controller;

  /// The display's number ([ScreenDisplay.index]).
  final int index;

  /// The size it is drawn at, in logical pixels.
  final Size size;

  /// Recording mode covers the remote picture: this one too, as a plain box.
  final bool covered;
  final ScreenTileDecoder? decodeTile;

  /// How often the display's picture is asked for.
  static const every = Duration(milliseconds: 500);

  /// How many times smaller a side the engine makes the picture of a display
  /// of [width] by [height] remote pixels, drawn at [size] logical pixels on
  /// a screen of [devicePixelRatio]: as small as still fills it, 1 to 16.
  static int divideFor(int width, int height, Size size, double devicePixelRatio) {
    final w = size.width * devicePixelRatio, h = size.height * devicePixelRatio;
    if (w <= 0 || h <= 0) return 16;
    final by = width / w < height / h ? width / w : height / h;
    return by.floor().clamp(1, 16);
  }

  @override
  State<ScreenDisplayPreview> createState() => _ScreenDisplayPreviewState();
}

class _ScreenDisplayPreviewState extends State<ScreenDisplayPreview> {
  ScreenViewReader? _view;
  ScreenDisplay? _of;
  int _divide = 1;
  Timer? _timer;
  ui.Image? _image;
  bool _taking = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.displays.addListener(_sync);
    _timer = Timer.periodic(ScreenDisplayPreview.every, (_) => unawaited(_take()));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
    unawaited(_take());
  }

  @override
  void didUpdateWidget(ScreenDisplayPreview old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.displays.removeListener(_sync);
      widget.controller.displays.addListener(_sync);
      _close();
    }
    _sync();
    if (widget.covered && !old.covered) _drop();
  }

  ScreenDisplay? get _display {
    final list = widget.controller.displays.value.list;
    return widget.index >= 0 && widget.index < list.length ? list[widget.index] : null;
  }

  /// The view on the display as it is now: opened, or opened again where the
  /// display or the size it is drawn at changed.
  void _sync() {
    if (!mounted) return;
    final d = _display;
    final divide = d == null
        ? 1
        : ScreenDisplayPreview.divideFor(d.width, d.height, widget.size, MediaQuery.devicePixelRatioOf(context));
    if (d == _of && divide == _divide && (_view != null || d == null)) return;
    _close();
    _of = d;
    _divide = divide;
    if (d == null) return;
    _view = widget.controller.session.openView(x: d.x, y: d.y, width: d.width, height: d.height, divide: divide);
  }

  void _close() {
    _epoch++;
    _view?.close();
    _view = null;
    _of = null;
    _drop();
  }

  void _drop() {
    final image = _image;
    if (image == null) return;
    _image = null;
    image.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _take() async {
    final view = _view;
    final c = widget.controller;
    if (view == null || _taking || widget.covered || c.isPaused || c.isClosed || !mounted) return;
    final frame = view.takeFrame();
    if (frame == null) return;
    final epoch = _epoch;
    _taking = true;
    ui.Image? image;
    try {
      // A view made smaller comes as one tile, all of it.
      if (frame.tiles.length == 1) image = await (widget.decodeTile ?? decodeScreenTile)(frame.tiles.single);
    } catch (_) {
      // A picture the device could not make an image of: the next one.
    } finally {
      frame.free();
      _taking = false;
    }
    if (image == null) return;
    if (!mounted || epoch != _epoch || widget.covered) {
      image.dispose();
      return;
    }
    final old = _image;
    setState(() => _image = image);
    old?.dispose();
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.displays.removeListener(_sync);
    _epoch++;
    _view?.close();
    _view = null;
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.covered ? null : _image;
    return SizedBox.fromSize(
      size: widget.size,
      child: ColoredBox(
        color: AppColors.screenLetterbox,
        child: image == null
            ? null
            // The remote's picture: left out of what a screen reader reads.
            : ExcludeSemantics(
                child: RawImage(image: image, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
              ),
      ),
    );
  }
}
