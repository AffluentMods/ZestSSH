import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// Where a guide's picture is loaded from: the network, or a test's own.
typedef GuideImageFor = ImageProvider Function(Uri uri);

/// A picture's request carries nothing but its address: no headers of ours.
ImageProvider guideNetworkImage(Uri uri) => NetworkImage(uri.toString());

/// One picture of a guide: its address on the docs site (already checked by
/// resolveGuideImage; nothing else is ever shown) and its words.
class GuidePicture {
  const GuidePicture({required this.uri, required this.alt});

  final Uri uri;
  final String alt;
}

/// How far a click or a double-tap zooms in.
const double kGuidePictureZoom = 2.5;

/// What is drawn straight on the viewer's backdrop (the loading spinner): the
/// backdrop is near-black in every theme, so this ink is light in every theme.
const Color _inkOnBackdrop = Color(0xFFF2F2F2);

/// Opens the guide's [pictures] full size over the guide, at [index]
/// (3.0.x, Help > Guides).
Future<void> showGuidePictureViewer(
  BuildContext context, {
  required List<GuidePicture> pictures,
  required int index,
  GuideImageFor imageFor = guideNetworkImage,
}) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black.withValues(alpha: 0.9),
    transitionDuration: const Duration(milliseconds: 150),
    reverseTransitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (_, _, _) => GuidePictureViewer(pictures: pictures, initialIndex: index, imageFor: imageFor),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ));
}

/// A guide's pictures, one at a time and full size: pinch, pan and
/// double-tap on a phone or tablet, the scroll wheel or a click on a
/// computer to zoom; a swipe, the arrow keys or the side buttons for the
/// next and previous picture; Esc, a tap beside the picture or the close
/// button to go back to the guide. The picture's words are its caption.
class GuidePictureViewer extends StatefulWidget {
  const GuidePictureViewer({
    super.key,
    required this.pictures,
    required this.initialIndex,
    this.imageFor = guideNetworkImage,
  });

  final List<GuidePicture> pictures;
  final int initialIndex;
  final GuideImageFor imageFor;

  @override
  State<GuidePictureViewer> createState() => GuidePictureViewerState();
}

class GuidePictureViewerState extends State<GuidePictureViewer> {
  late final PageController _pages = PageController(initialPage: _index);
  late final List<TransformationController> _zooms = [
    for (final _ in widget.pictures) TransformationController()..addListener(_zoomChanged),
  ];
  late final List<GlobalKey> _viewports = [for (final _ in widget.pictures) GlobalKey()];
  late int _index = widget.initialIndex.clamp(0, widget.pictures.length - 1);
  bool _zoomed = false;
  final FocusNode _focus = FocusNode(debugLabel: 'guide-picture-viewer');

  /// The picture shown now.
  int get index => _index;

  /// How far the picture shown now is zoomed in (1 when it is not).
  @visibleForTesting
  double get scale => _zooms[_index].value.getMaxScaleOnAxis();

  @override
  void dispose() {
    for (final z in _zooms) {
      z.dispose();
    }
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _zoomChanged() {
    final zoomed = scale > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _close() => Navigator.of(context).maybePop();

  void _go(int to) {
    if (to < 0 || to >= widget.pictures.length || to == _index) return;
    // ignore: discarded_futures
    _pages.animateToPage(to, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
  }

  void _pageChanged(int i) {
    // The picture left behind is shown whole again when it comes back.
    _zooms[_index].value = Matrix4.identity();
    setState(() {
      _index = i;
      _zoomed = false;
    });
  }

  /// Zooms in on [global] (a point on the screen), or back out when zoomed.
  void _toggleZoom(Offset global) {
    final zoom = _zooms[_index];
    if (scale > 1.01) {
      zoom.value = Matrix4.identity();
      return;
    }
    final box = _viewports[_index].currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final at = zoom.toScene(box.globalToLocal(global));
    const s = kGuidePictureZoom;
    zoom.value = Matrix4.identity()
      ..translateByDouble(-at.dx * (s - 1), -at.dy * (s - 1), 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _go(_index + 1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _go(_index - 1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final count = widget.pictures.length;
    final alt = widget.pictures[_index].alt.trim();
    const onDark = Colors.white;
    final faint = Colors.white.withValues(alpha: 0.7);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Material(
        key: const ValueKey('guide-picture-viewer'),
        type: MaterialType.transparency,
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: PageView.builder(
                  controller: _pages,
                  itemCount: count,
                  physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                  onPageChanged: _pageChanged,
                  itemBuilder: (context, i) => _page(i),
                ),
              ),
              // The top: which picture, how to use the viewer, and Close.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                  child: Row(
                    children: [
                      if (count > 1)
                        Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Text(
                            l10n.guidePictureCount(_index + 1, count),
                            key: const ValueKey('guide-picture-count'),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: onDark),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          isTouchLayout ? l10n.guidePictureHintTouch : l10n.guidePictureHintComputer,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, height: 1.35, color: faint),
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('guide-picture-close'),
                        tooltip: l10n.close,
                        color: onDark,
                        onPressed: _close,
                        icon: const Icon(LucideIcons.x, size: 22),
                      ),
                    ],
                  ),
                ),
              ),
              if (count > 1) ...[
                _side(
                  left: true,
                  key: const ValueKey('guide-picture-previous'),
                  tooltip: l10n.guidePicturePrevious,
                  icon: LucideIcons.chevronLeft,
                  onPressed: _index > 0 ? () => _go(_index - 1) : null,
                ),
                _side(
                  left: false,
                  key: const ValueKey('guide-picture-next'),
                  tooltip: l10n.guidePictureNext,
                  icon: LucideIcons.chevronRight,
                  onPressed: _index < count - 1 ? () => _go(_index + 1) : null,
                ),
              ],
              // The picture's words, as its caption.
              if (alt.isNotEmpty)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 12,
                  child: Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 760),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        alt,
                        key: const ValueKey('guide-picture-caption'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13.5, height: 1.4, color: onDark),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _side({
    required bool left,
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return Positioned(
      left: left ? 8 : null,
      right: left ? null : 8,
      top: 0,
      bottom: 0,
      child: Center(
        child: IconButton.filled(
          key: key,
          tooltip: tooltip,
          onPressed: onPressed,
          style: IconButton.styleFrom(
            backgroundColor: Colors.black.withValues(alpha: 0.5),
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.black.withValues(alpha: 0.2),
            disabledForegroundColor: Colors.white.withValues(alpha: 0.3),
          ),
          icon: Icon(icon, size: 22),
        ),
      ),
    );
  }

  Widget _page(int i) {
    final picture = widget.pictures[i];
    Offset? doubleTapAt;
    return InteractiveViewer(
      key: _viewports[i],
      transformationController: _zooms[i],
      minScale: 1,
      maxScale: 6,
      // Whole, a sideways drag is the PageView's swipe; zoomed in, a pan.
      panEnabled: i == _index && _zoomed,
      child: Stack(
        children: [
          // Beside the picture: back to the guide.
          Positioned.fill(
            child: GestureDetector(
              key: ValueKey('guide-picture-backdrop-$i'),
              behavior: HitTestBehavior.opaque,
              onTap: _close,
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(56, 56, 56, 64),
              child: GestureDetector(
                key: ValueKey('guide-picture-image-$i'),
                // A click zooms (a computer); a tap on a touch screen does
                // nothing, as a double-tap zooms there.
                onTapUp: (d) {
                  if (d.kind == PointerDeviceKind.mouse) _toggleZoom(d.globalPosition);
                },
                onDoubleTapDown: (d) => doubleTapAt = d.globalPosition,
                onDoubleTap: () {
                  final at = doubleTapAt;
                  if (at != null) _toggleZoom(at);
                },
                child: MouseRegion(
                  cursor: i == _index && _zoomed ? SystemMouseCursors.zoomOut : SystemMouseCursors.zoomIn,
                  child: Semantics(
                    image: true,
                    label: picture.alt,
                    child: Image(
                      image: widget.imageFor(picture.uri),
                      fit: BoxFit.contain,
                      excludeFromSemantics: true,
                      errorBuilder: (_, _, _) => Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.image, size: 28, color: Colors.white.withValues(alpha: 0.6)),
                            const SizedBox(height: 8),
                            Text(picture.alt,
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 13.5, color: Colors.white.withValues(alpha: 0.8))),
                          ],
                        ),
                      ),
                      loadingBuilder: (context, child, progress) => progress == null
                          ? child
                          : const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2, color: _inkOnBackdrop),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
