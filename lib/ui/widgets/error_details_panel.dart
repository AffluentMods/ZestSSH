import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';

/// "Technical details" under an error: a disclosure that shows the report of
/// the failure (`ErrorReport.build`: scrubbed, its labels in English) as
/// text that can be selected, with "Copy details" beside it.
///
/// Made for the screens that stand alone (the app could not start, its
/// database could not be opened, an update of it failed): they run without
/// the rest of the app, so this needs nothing but the app's words and colours.
class ErrorDetailsPanel extends StatefulWidget {
  const ErrorDetailsPanel({super.key, required this.report});

  /// What is shown and copied.
  final String report;

  @override
  State<ErrorDetailsPanel> createState() => _ErrorDetailsPanelState();
}

class _ErrorDetailsPanelState extends State<ErrorDetailsPanel> {
  bool _open = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context)?.databaseErrorTechnicalDetails ?? 'Technical details';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            // (A button, so that the keyboard and a screen reader reach it.)
            TextButton(
              key: const ValueKey('error-details-toggle'),
              onPressed: () => setState(() => _open = !_open),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.onSurfaceDim,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: const TextStyle(fontSize: 12.5)),
                  const SizedBox(width: 4),
                  Icon(_open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18),
                ],
              ),
            ),
            CopyDetailsButton(detail: widget.report, color: AppColors.onSurfaceDim),
          ],
        ),
        if (_open) ...[
          const SizedBox(height: 10),
          ConstrainedBox(
            // Bounded, so that a long report does not push the screen's own
            // buttons out of a small window.
            constraints: const BoxConstraints(maxHeight: 220),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.divider),
              ),
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    widget.report,
                    key: const ValueKey('error-details-text'),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: AppColors.onSurfaceDim,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Where a person who cannot get into the app writes for help.
String get kSupportEmail => kZestSupportAddress;

/// Writes to support from a screen that stands alone. The report is put on
/// the clipboard first (a long one does not fit in a mail link), then the
/// mail app opens with a short message that says to paste it. Says on the
/// screen what happened: the mail app opened, or none did and where to
/// write instead. [launch] opens a link; a test's own stands in.
Future<void> writeToSupportWithDetails(
  BuildContext context,
  String report, {
  Future<bool> Function(Uri uri)? launch,
}) async {
  final t = AppLocalizations.of(context) ?? gl10n;
  final messenger = ScaffoldMessenger.maybeOf(context);
  await Clipboard.setData(ClipboardData(text: report));
  final uri = Uri(
    scheme: 'mailto',
    path: kSupportEmail,
    // (Spaces as %20: a mail app reads a + as a plus.)
    query: 'subject=${Uri.encodeComponent(t.errorMailSubject)}&body=${Uri.encodeComponent(t.errorMailBody)}',
  );
  var opened = false;
  try {
    opened = await (launch ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication))(uri);
  } catch (_) {
    // (No mail app: said below.)
  }
  messenger
    ?..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(opened ? t.errorMailOpened : t.errorMailNoApp(kSupportEmail)),
      duration: const Duration(seconds: 8),
    ));
}
