import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/help/guides/guide_markdown.dart';
import 'package:zestssh/features/help/guides/guides_index.g.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/help/guide_picture_viewer.dart';

/// Opens [uri] outside the app: the browser, or the mail app for an address.
typedef GuideOutsideOpener = void Function(Uri uri);

void _openOutside(Uri uri) {
  // ignore: discarded_futures
  launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// A guide's blocks, drawn with the app's own widgets (3.0, Help > Guides).
///
/// Nothing here is a web view: headings, steps, lists, code and tables are
/// Text, pictures are loaded only from the docs site ([resolveGuideImage];
/// any other picture shows its words instead), and a link opens another
/// guide in the reader or the browser outside the app ([resolveGuideLink]),
/// never a page inside it. The text can be selected and copied. A picture
/// opens full size over the guide ([showGuidePictureViewer]), with the
/// guide's other pictures a swipe or an arrow key away.
class GuideMarkdownView extends StatefulWidget {
  const GuideMarkdownView({
    super.key,
    required this.blocks,
    required this.slug,
    required this.onOpenGuide,
    this.onOpenOutside = _openOutside,
    this.fontSize = 13.5,
    this.imageFor = guideNetworkImage,
  });

  final List<GuideBlock> blocks;

  /// The guide shown, for links and pictures written relative to it.
  final String slug;

  /// A link to another guide: open it in the reader.
  final ValueChanged<String> onOpenGuide;

  final GuideOutsideOpener onOpenOutside;

  /// The body text's size: smaller in the Help panel, larger on a phone.
  final double fontSize;

  /// Where the pictures load from: the network (tests give their own).
  final GuideImageFor imageFor;

  @override
  State<GuideMarkdownView> createState() => _GuideMarkdownViewState();
}

class _GuideMarkdownViewState extends State<GuideMarkdownView> {
  final List<TapGestureRecognizer> _recognizers = [];
  late final Set<String> _known = {for (final g in kGuidesIndex) g.slug};

  @override
  void dispose() {
    _drop();
    super.dispose();
  }

  void _drop() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  void _follow(String href) {
    switch (resolveGuideLink(href, slug: widget.slug, knownSlugs: _known)) {
      case GuideLinkToGuide(:final slug):
        widget.onOpenGuide(slug);
      case GuideLinkOutside(:final uri):
        widget.onOpenOutside(uri);
      case GuideLinkNone():
        break; // (A link the reader does not follow.)
    }
  }

  /// The guide's pictures from the docs site, in the order they stand, and
  /// where each is in that list: what the viewer pages through.
  final List<GuidePicture> _pictures = [];
  final Map<GuideImage, int> _pictureAt = Map.identity();

  void _gather(List<GuideBlock> blocks) {
    for (final b in blocks) {
      switch (b) {
        case GuideImage():
          final uri = resolveGuideImage(b.src, slug: widget.slug);
          if (uri != null) {
            _pictureAt[b] = _pictures.length;
            _pictures.add(GuidePicture(uri: uri, alt: b.alt));
          }
        case GuideCallout():
          _gather(b.children);
        case GuideList():
          for (final item in b.items) {
            _gather(item);
          }
        default:
          break;
      }
    }
  }

  void _openPicture(int at) {
    // ignore: discarded_futures
    showGuidePictureViewer(context, pictures: List.of(_pictures), index: at, imageFor: widget.imageFor);
  }

  @override
  Widget build(BuildContext context) {
    _drop();
    _pictures.clear();
    _pictureAt.clear();
    _gather(widget.blocks);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _blocks(widget.blocks),
      ),
    );
  }

  double get _size => widget.fontSize;

  TextStyle get _body => TextStyle(fontSize: _size, height: 1.5, color: ZestTokens.textSecondary);

  List<Widget> _blocks(List<GuideBlock> blocks) {
    final out = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final first = i == 0;
      out.add(switch (b) {
        GuideHeading() => Padding(
            padding: EdgeInsets.only(top: first ? 0 : (b.level <= 2 ? 20 : 14), bottom: 6),
            child: Semantics(
              header: true,
              child: Text.rich(
                _spans(b.spans,
                    TextStyle(
                      fontSize: b.level <= 1 ? _size + 6 : (b.level == 2 ? _size + 3.5 : _size + 1.5),
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: ZestTokens.textPrimary,
                    )),
              ),
            ),
          ),
        GuideParagraph() => Padding(
            padding: EdgeInsets.only(top: first ? 0 : 8),
            child: Text.rich(_spans(b.spans, _body)),
          ),
        GuideList() => Padding(
            padding: EdgeInsets.only(top: first ? 0 : 8),
            child: _list(b),
          ),
        GuideCode() => Padding(
            padding: EdgeInsets.only(top: first ? 0 : 10),
            child: _GuideCodeBlock(code: b.code, fontSize: _size - 1),
          ),
        GuideImage() => Padding(
            padding: EdgeInsets.only(top: first ? 0 : 10, bottom: 2),
            child: _GuidePicture(
              alt: b.alt,
              uri: resolveGuideImage(b.src, slug: widget.slug),
              fontSize: _size - 1,
              imageFor: widget.imageFor,
              onOpen: switch (_pictureAt[b]) {
                final int at => () => _openPicture(at),
                null => null,
              },
            ),
          ),
        GuideCallout() => Padding(
            padding: EdgeInsets.only(top: first ? 0 : 10),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
              decoration: BoxDecoration(
                color: ZestTokens.surfaceRaisedAlt,
                border: Border(left: BorderSide(color: ZestTokens.brand, width: 3)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (b.title != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(b.title!,
                          style: TextStyle(fontSize: _size, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                    ),
                  ..._blocks(b.children),
                ],
              ),
            ),
          ),
        GuideTable() => Padding(
            padding: EdgeInsets.only(top: first ? 0 : 10),
            child: _table(b),
          ),
        GuideRule() => const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1)),
      });
    }
    return out;
  }

  Widget _list(GuideList list) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var n = 0; n < list.items.length; n++)
          Padding(
            padding: EdgeInsets.only(top: n == 0 ? 0 : 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: list.ordered ? _size * 1.9 : _size * 1.3,
                  child: Text(
                    list.ordered ? '${list.start + n}.' : '•',
                    style: _body.copyWith(
                      color: list.ordered ? ZestTokens.brand : ZestTokens.textTertiary,
                      fontWeight: list.ordered ? FontWeight.w600 : FontWeight.w400,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _blocks(list.items[n]),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _table(GuideTable table) {
    TableRow row(List<List<GuideSpan>> cells, {bool head = false}) => TableRow(
          decoration: head ? BoxDecoration(color: ZestTokens.surfaceRaisedAlt) : null,
          children: [
            for (final c in cells)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text.rich(_spans(c, head ? _body.copyWith(fontWeight: FontWeight.w600) : _body)),
              ),
          ],
        );
    final columns = table.head.length;
    List<List<GuideSpan>> fit(List<List<GuideSpan>> cells) => [
          for (var i = 0; i < columns; i++) i < cells.length ? cells[i] : const <GuideSpan>[],
        ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: ZestTokens.borderSubtle),
        children: [row(table.head, head: true), for (final r in table.rows) row(fit(r))],
      ),
    );
  }

  TextSpan _spans(List<GuideSpan> spans, TextStyle base) {
    return TextSpan(
      style: base,
      children: [
        for (final s in spans) _span(s, base),
      ],
    );
  }

  InlineSpan _span(GuideSpan s, TextStyle base) {
    var style = base;
    if (s.bold) style = style.copyWith(fontWeight: FontWeight.w600, color: ZestTokens.textPrimary);
    if (s.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    if (s.code) {
      style = style.copyWith(
        fontFamily: 'JetBrainsMono',
        fontSize: (base.fontSize ?? _size) - 1,
        backgroundColor: ZestTokens.surfaceChip,
        color: ZestTokens.textPrimary,
      );
    }
    TapGestureRecognizer? tap;
    final href = s.href;
    if (href != null) {
      style = style.copyWith(
        color: ZestTokens.brand,
        decoration: TextDecoration.underline,
        decorationColor: ZestTokens.brand.withValues(alpha: 0.5),
      );
      tap = TapGestureRecognizer()..onTap = () => _follow(href);
      _recognizers.add(tap);
    }
    return TextSpan(
      text: s.text,
      style: style,
      recognizer: tap,
      mouseCursor: tap == null ? null : SystemMouseCursors.click,
    );
  }
}

/// A code block: the terminal font, scrolled sideways when long, with Copy.
class _GuideCodeBlock extends StatelessWidget {
  const _GuideCodeBlock({required this.code, required this.fontSize});

  final String code;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        border: Border.all(color: ZestTokens.borderSubtle),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 10, 40, 10),
            child: Text(
              code,
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: fontSize, height: 1.45, color: ZestTokens.textPrimary),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              tooltip: l10n.copy,
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              color: ZestTokens.textTertiary,
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              icon: const Icon(LucideIcons.copy),
            ),
          ),
        ],
      ),
    );
  }
}

/// A guide's picture, from the docs site only; its words where there is no
/// picture to show (not from the docs site, offline, or not found). A tap
/// or a click on a picture shown opens it full size ([onOpen]).
class _GuidePicture extends StatelessWidget {
  const _GuidePicture({
    required this.alt,
    required this.uri,
    required this.fontSize,
    required this.imageFor,
    required this.onOpen,
  });

  final String alt;
  final Uri? uri;
  final double fontSize;
  final GuideImageFor imageFor;
  final VoidCallback? onOpen;

  Widget _words() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaisedAlt,
          border: Border.all(color: ZestTokens.borderSubtle),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(LucideIcons.image, size: 14, color: ZestTokens.textTertiary),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(alt, style: TextStyle(fontSize: fontSize, height: 1.4, color: ZestTokens.textTertiary)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final at = uri;
    if (at == null) return _words();
    final l10n = AppLocalizations.of(context)!;
    final open = onOpen;
    return Semantics(
      image: true,
      label: alt,
      hint: open == null ? null : l10n.guidePictureOpen,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: Align(
          alignment: Alignment.topLeft,
          // As tall as the picture (or its words), not as the room for it.
          heightFactor: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border.all(color: ZestTokens.borderSubtle)),
              child: Image(
                image: imageFor(at),
                fit: BoxFit.contain,
                excludeFromSemantics: true,
                // No headers of ours: the request carries nothing but the address.
                // Nothing to open while there is no picture: its words, or
                // the wait for it, are not taps.
                errorBuilder: (_, _, _) => _words(),
                frameBuilder: (context, child, frame, synchronous) => frame == null || open == null
                    ? child
                    : Tooltip(
                        message: l10n.guidePictureOpen,
                        waitDuration: const Duration(milliseconds: 600),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.zoomIn,
                          child: GestureDetector(
                            key: const ValueKey('guide-picture-open'),
                            behavior: HitTestBehavior.opaque,
                            onTap: open,
                            child: child,
                          ),
                        ),
                      ),
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : SizedBox(
                        height: 120,
                        child: Center(
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: ZestTokens.textTertiary),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
