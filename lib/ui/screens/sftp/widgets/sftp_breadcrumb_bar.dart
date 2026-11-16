import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// A horizontally scrollable breadcrumb bar for SFTP path navigation.
///
/// Parses a path like `/home/user/docs` into tappable segments:
/// `/ > home > user > docs`, each navigating to that directory.
///
/// Layout direction mirrors Windows Explorer / macOS Finder: segments
/// flow left → right, with the root pinned to the left edge. When the
/// path is too long to fit, the bar auto-scrolls to keep the *current
/// directory* (the right-most segment) visible - same behaviour as
/// Explorer's address bar when you `cd` into a deep tree.
class SftpBreadcrumbBar extends StatefulWidget {
  final String path;
  final ValueChanged<String> onNavigate;

  const SftpBreadcrumbBar({
    super.key,
    required this.path,
    required this.onNavigate,
  });

  @override
  State<SftpBreadcrumbBar> createState() => _SftpBreadcrumbBarState();
}

class _SftpBreadcrumbBarState extends State<SftpBreadcrumbBar> {
  @override
  Widget build(BuildContext context) {
    final segments = _parseSegments(widget.path);
    // Collapse from the MIDDLE, never the left: the first
    // segment (drive / root) and the last two always survive; the middle
    // collapses behind a "…" button that lists the elided segments. Chopping
    // the left off removes the very thing - which machine, which root - you most
    // need on a two-pane browser. Where even that does not fit (a pane
    // dragged narrow, long folder names), the folder above goes behind the
    // "…" too, then the root, then the "…" itself: the current folder
    // always stays, shortened last.
    final last = segments.length - 1;
    // Which segments show, the rest behind a "…" (none where [elide] is
    // false), most first.
    final plans = <({List<int> shown, bool elide})>[
      if (segments.length <= 4)
        (shown: [for (var i = 0; i < segments.length; i++) i], elide: true)
      else
        (shown: [0, last - 1, last], elide: true),
      if (segments.length > 2) (shown: [0, last], elide: true),
      if (segments.length > 1) (shown: [last], elide: true),
      (shown: [last], elide: false),
    ];

    // No background or fixed height of its own - the breadcrumb sits INSIDE the
    // path bar's --sunken pill and must not paint a lighter box over it (that
    // was the "weird left box"), nor be taller than the 32px pill.
    return LayoutBuilder(builder: (context, box) {
      final plan = plans.firstWhere((p) => _widthOf(segments, p) <= box.maxWidth, orElse: () => plans.last);
      final shown = plan.shown;
      final children = <Widget>[];
      void addChevron() => children.add(Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Icon(LucideIcons.chevronRight,
                size: 16, color: AppColors.onSurfaceDim),
          ));
      for (var k = 0; k < shown.length; k++) {
        final i = shown[k];
        final before = k == 0 ? -1 : shown[k - 1];
        // The segments between the one before and this one, behind a "…".
        if (plan.elide && i - before > 1) {
          if (children.isNotEmpty) addChevron();
          children.add(_ElisionButton(
            segments: [for (var j = before + 1; j < i; j++) segments[j]],
            onNavigate: widget.onNavigate,
          ));
        }
        if (children.isNotEmpty) addChevron();
        final s = _BreadcrumbSegment(
          label: segments[i].label,
          isLast: i == last,
          onTap: () => widget.onNavigate(segments[i].path),
        );
        children.add(i == last ? Flexible(child: s) : s);
      }
      return Align(
        alignment: Alignment.centerLeft,
        // max so the Flexible current-directory segment fills / ellipsizes within
        // the path bar's Expanded rather than overflowing.
        child: Row(mainAxisSize: MainAxisSize.max, children: children),
      );
    });
  }

  /// The width [plan] takes with its current folder shortened to a little
  /// of its name: its other segments, its chevrons and its "…" buttons.
  double _widthOf(List<_Segment> segments, ({List<int> shown, bool elide}) plan) {
    const chevron = 20.0;
    const elision = 22.0;
    const segmentPadding = 12.0;
    const shortestLast = 40.0;
    final scaler = MediaQuery.textScalerOf(context);
    var w = 0.0;
    for (var k = 0; k < plan.shown.length; k++) {
      final i = plan.shown[k];
      final before = k == 0 ? -1 : plan.shown[k - 1];
      if (plan.elide && i - before > 1) w += (w > 0 ? chevron : 0) + elision;
      if (w > 0) w += chevron;
      if (i == segments.length - 1) {
        w += shortestLast;
      } else {
        final painter = TextPainter(
          text: TextSpan(
            text: Redactable.freeText(segments[i].label).display,
            style: const TextStyle(fontSize: 13, fontFamily: 'JetBrainsMono'),
          ),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        w += painter.width + segmentPadding + 2;
        painter.dispose();
      }
    }
    return w;
  }

  List<_Segment> _parseSegments(String path) {
    // Windows paths start with a drive letter (e.g. `C:\…` or `C:/…`).
    // Treat the drive as the root segment and split on either separator.
    // Without this branch a Windows path would render as `/` >
    // `C:\Users\foo\bar` (one giant unsplittable chunk) - the original
    // logic split only on `/` so the drive letter never broke up.
    final isWindowsPath =
        path.length >= 2 && path[1] == ':' && _isLetter(path.codeUnitAt(0));

    if (isWindowsPath) return _parseWindowsSegments(path);

    final segments = <_Segment>[];

    // Root
    segments.add(const _Segment(label: '/', path: '/'));

    if (path == '/') return segments;

    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    var accumulated = '';
    for (final part in parts) {
      accumulated += '/$part';
      segments.add(_Segment(label: part, path: accumulated));
    }

    return segments;
  }

  List<_Segment> _parseWindowsSegments(String path) {
    final segments = <_Segment>[];
    // Drive letter root (e.g. `C:`) - clicking it goes to the drive
    // root (`C:\`). No extra `/` is prepended.
    final drive = path.substring(0, 2); // "C:"
    segments.add(_Segment(label: drive, path: '$drive\\'));

    // Split everything after the drive on either separator.
    final rest = path.substring(2).split(RegExp(r'[/\\]'))
      ..removeWhere((p) => p.isEmpty);
    var accumulated = drive;
    for (final part in rest) {
      accumulated = '$accumulated\\$part';
      segments.add(_Segment(label: part, path: accumulated));
    }

    return segments;
  }

  static bool _isLetter(int code) =>
      (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
}

class _Segment {
  final String label;
  final String path;

  const _Segment({required this.label, required this.path});
}

class _BreadcrumbSegment extends StatefulWidget {
  final String label;
  final bool isLast;
  final VoidCallback onTap;

  const _BreadcrumbSegment({
    required this.label,
    required this.isLast,
    required this.onTap,
  });

  @override
  State<_BreadcrumbSegment> createState() => _BreadcrumbSegmentState();
}

class _BreadcrumbSegmentState extends State<_BreadcrumbSegment> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    // "You are here" is not an action: the current segment reads as
    // bright --text, never accent. Ancestors sit at --muted and lift to --text-2
    // on hover, which is the only cue that they're clickable.
    final Color color;
    if (widget.isLast) {
      color = AppColors.onSurface;
    } else if (_hovering) {
      color = AppColors.onSurfaceVariant;
    } else {
      color = AppColors.onSurfaceDim;
    }
    return InkWell(
      onTap: widget.isLast ? null : widget.onTap,
      onHover: widget.isLast
          ? null
          : (h) => setState(() => _hovering = h),
      borderRadius: BorderRadius.circular(4),
      // 48 by 48 at least to a finger (4.0 accessibility pass: 31 high).
      child: ConstrainedBox(
        constraints: touchSizedAt(context) ? const BoxConstraints(minWidth: 48, minHeight: 48) : const BoxConstraints(),
        child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: RedactedText(
          // Recording mode (spec 4): a segment can be a username or a host.
          Redactable.freeText(widget.label),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontFamily: 'JetBrainsMono',
            color: color,
            fontWeight: widget.isLast ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        ),
      ),
      ),
    );
  }
}

/// The "…" button standing in for the elided middle breadcrumb segments; tapping
/// it lists them, each navigating to that directory.
///
/// The list reads outwards from where the person is: the folder nearest to
/// the current one is at the top and the one nearest to the root at the
/// bottom, as a file manager lists the folders above the current one. It
/// was the other way round, which put the folder
/// most often wanted, the one just above what is shown, farthest away.
class _ElisionButton extends StatelessWidget {
  const _ElisionButton({required this.segments, required this.onNavigate});

  /// The hidden segments in the order of the path, root side first.
  final List<_Segment> segments;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: AppLocalizations.of(context)!.sftpShowElidedSegments,
      padding: EdgeInsets.zero,
      color: AppColors.v3Elevated,
      itemBuilder: (_) => [
        for (final s in segments.reversed)
          PopupMenuItem<String>(
            value: s.path,
            // Same rule as the visible segments (spec 4).
            child: RedactedText(Redactable.freeText(s.label)),
          ),
      ],
      onSelected: onNavigate,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text('…',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppColors.onSurfaceDim)),
      ),
    );
  }
}
