import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// How long the Undo of combined tabs is offered: as long as a closed tab's.
const Duration kTabMergeUndoWindow = Duration(seconds: 5);

/// After tabs were combined ([undos], one per tab that joined, in the order
/// they joined): a notice with Undo, for [kTabMergeUndoWindow], as a closed
/// tab offers one. Undo puts every tab back as it was ([WorkTabsNotifier.
/// undoMerge], the last joined first); the sessions are not touched. Once
/// the notice is gone its Undo does nothing, also from the notification
/// history. (Undo is there so that two groups combined by accident can
/// be put back.)
void offerTabMergeUndo(BuildContext context, WidgetRef ref, List<TabMergeUndo> undos, {String? message}) {
  if (undos.isEmpty) return;
  final l10n = AppLocalizations.of(context)!;
  final notifier = ref.read(workTabsProvider.notifier);
  var open = true;
  final handle = showTopSnackBar(
    context,
    message ?? l10n.tabMergeCombined,
    duration: kTabMergeUndoWindow,
    actionLabel: l10n.desktopShellUndo,
    onAction: () {
      if (!open) return;
      open = false;
      for (final undo in undos.reversed) {
        notifier.undoMerge(undo);
      }
    },
  );
  // ignore: discarded_futures
  handle.closed.then((_) => open = false);
}
