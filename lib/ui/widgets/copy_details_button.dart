import 'dart:async';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// A small "Copy details" text button for error surfaces.
///
/// Errors shown to the user are kept short and plain; when there IS a raw
/// technical string worth keeping (a status line, an exception trace, an HTTP
/// body) it lives behind this button rather than in the headline. A normal
/// user ignores it; someone asking for help taps it to take the real thing
/// with them. Tapping copies [detail] to the clipboard and briefly flips the
/// label to "Copied".
///
/// What is copied is what the caller gives, scrubbed first ([ReportScrub]):
/// an error surface gives the report `ErrorReport.build` makes of the
/// failure, which has every name and secret taken out already, and one that
/// gave the error as it was thrown copied its secrets and names with it (3.0,
/// 17 October 2026). [asItIs] copies the person's own text as it is.
class CopyDetailsButton extends StatefulWidget {
  /// The text placed on the clipboard when tapped.
  final String detail;

  /// Foreground colour. Defaults to the muted secondary text tone so the
  /// button reads as a quiet affordance under the main message.
  final Color? color;

  /// Idle label. Defaults to "Copy details", in the app's language.
  final String? label;

  const CopyDetailsButton({
    super.key,
    required this.detail,
    this.color,
    this.label,
    this.asItIs = false,
  });

  /// Copies [detail] as it is, unscrubbed: where it is the person's own text
  /// to take with them (an Orchard's setup file, read back), and no report
  /// of a failure.
  final bool asItIs;

  @override
  State<CopyDetailsButton> createState() => _CopyDetailsButtonState();
}

class _CopyDetailsButtonState extends State<CopyDetailsButton> {
  bool _copied = false;
  Timer? _resetTimer;

  Future<void> _copy() async {
    final text = widget.asItIs ? widget.detail : ReportScrub.scrub(widget.detail);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppColors.v3TextSecondary;
    // (A surface drawn before the app's words are loaded says it in English.)
    final l10n = AppLocalizations.of(context);
    final idle = widget.label ?? l10n?.desktopShellCopyDetails ?? 'Copy details';
    final done = l10n?.migrationErrorCopied ?? 'Copied';
    return TextButton.icon(
      onPressed: _copy,
      icon: Icon(
        _copied ? LucideIcons.check : LucideIcons.copy,
        size: 14,
        color: color,
      ),
      label: Text(
        _copied ? done : idle,
        style: TextStyle(fontSize: 12, color: color),
      ),
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        // 32 on a computer, as the app's small buttons; 44 for a finger.
        minimumSize: Size(0, zestUsesSheets(context) ? 44 : 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
      ),
    );
  }
}
