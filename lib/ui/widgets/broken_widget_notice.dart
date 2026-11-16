import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/error_report.dart';

/// What stands where a part of a screen failed to build, in a build made for
/// release (3.0). It said "Something went wrong" and nothing
/// more; it says so with the details to copy now, the report of the failure
/// (scrubbed), for support or an assistant.
///
/// It may stand anywhere (in a row, in a list, with no Material above it,
/// before the app's words are loaded), so it is made of plain widgets, keeps
/// to the room it is given, and says its words in English when there are
/// none yet.
class BrokenWidgetNotice extends StatefulWidget {
  const BrokenWidgetNotice(this.details, {super.key});

  final FlutterErrorDetails details;

  @override
  State<BrokenWidgetNotice> createState() => _BrokenWidgetNoticeState();
}

class _BrokenWidgetNoticeState extends State<BrokenWidgetNotice> {
  bool _copied = false;

  Future<void> _copy(AppLocalizations t) async {
    final report = ErrorReport.build(
      what: t.mainAppSomethingWentWrong,
      where: 'Building a part of a screen',
      error: widget.details.exception,
      stack: widget.details.stack,
    );
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context) ?? gl10n;
    final style = TextStyle(color: AppColors.textSecondary, fontSize: 13, decoration: TextDecoration.none);
    return Directionality(
      textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      child: ClipRect(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.mainAppSomethingWentWrong, textAlign: TextAlign.center, style: style),
              const SizedBox(height: 6),
              Semantics(
                button: true,
                child: GestureDetector(
                  key: const ValueKey('broken-widget-copy'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _copy(t),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(
                      _copied ? t.migrationErrorCopied : t.desktopShellCopyDetails,
                      style: style.copyWith(color: AppColors.accentInk, decoration: TextDecoration.underline),
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
}
