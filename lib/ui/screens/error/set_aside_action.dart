import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_report.dart';

/// Set this aside and start fresh, on the screens of a start that failed: what did
/// not open goes to a folder of its own, and nothing is deleted. It says what it does
/// first, and a failure is said here, with its details to copy.
class SetAsideAction extends StatefulWidget {
  const SetAsideAction({
    super.key,
    required this.onSetAside,
    required this.buttonKey,
    this.enabled = true,
    this.onBusy,
    this.title,
    this.body,
  });

  final Future<void> Function() onSetAside;
  final Key buttonKey;
  final bool enabled;

  /// What it asks, where that is not the words for a database.
  final String? title;
  final String? body;

  /// Told while it runs, for what must wait on the same screen.
  final ValueChanged<bool>? onBusy;

  @override
  State<SetAsideAction> createState() => _SetAsideActionState();
}

class _SetAsideActionState extends State<SetAsideAction> {
  bool _running = false;
  String? _failure;

  Future<void> _confirm() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: widget.title ?? l10n.databaseErrorSetAsideTitle,
      body: widget.body ?? l10n.databaseErrorSetAsideBody,
      confirmLabel: l10n.databaseErrorSetAside,
    );
    if (ok != true || !mounted) return;
    setState(() {
      _running = true;
      _failure = null;
    });
    widget.onBusy?.call(true);
    try {
      await widget.onSetAside();
    } catch (e, stack) {
      if (!mounted) return;
      setState(() => _failure = ErrorReport.build(
            what: l10n.databaseErrorSetAsideFailed,
            where: 'Setting the data aside to start fresh',
            error: e,
            stack: stack,
          ));
    } finally {
      if (mounted) {
        setState(() => _running = false);
        widget.onBusy?.call(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final failure = _failure;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton(
          key: widget.buttonKey,
          onPressed: _running || !widget.enabled ? null : _confirm,
          child: Text(l10n.databaseErrorSetAside),
        ),
        if (failure != null) ...[
          const SizedBox(height: 8),
          Text(
            l10n.databaseErrorSetAsideFailed,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.error, height: 1.45),
          ),
          ErrorDetailsPanel(report: failure),
        ],
      ],
    );
  }
}
