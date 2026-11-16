// "Open an X program..." (4.0): the question on an SSH host's menu,
// and opening what it answers. A program line, as typed in a terminal on that
// host, with this device's recent ones for the host; the picture is the size
// of the window as it is opened ([xProgramSizeFor]).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/screens/desktop/screen_toolbar.dart' show kScreenToolbarHeight;
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/xprogram/x_program_recent.dart';
import 'package:zestssh/features/screens/xprogram/x_program_script.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart' show freeSessionLimit;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart' show kSessionHeaderHeight;
import 'package:zestssh/ui/widgets/hit_area.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show minTapTarget;

/// What a screen tab draws above its picture inside the page's place: the
/// session's header, the screen's toolbar and the line under each.
const double _tabChromeHeight = kSessionHeaderHeight + kScreenToolbarHeight + 2;

/// The size of the private X server for a window of [window] logical pixels:
/// on a phone (its shorter side under 600) at least 960 by 544, laid
/// landscape; elsewhere the place the tab's picture will have, from 640 by 480
/// to 3840 by 2160. Whole multiples of 8 (X servers and encoders like them),
/// rounded down, so the picture fits its place without being scaled.
///
/// [page] is the size of the page the question is asked from, where it is
/// known: on a computer the tab opens in that page's place (the window less
/// the sidebar as it stands, the title bar and the status bar), so the picture
/// is that less the tab's own header and toolbar. Without it, or where the
/// page is a narrow drawer beside something else, the place is estimated from
/// the window with the sidebar folded. (It was the window less 80 by 140
/// whatever the sidebar's width: with the sidebar open the picture was wider
/// than its place, drawn smaller, with a band above and below it.)
///
({int width, int height}) xProgramSizeFor(Size window, {Size? page}) {
  // (The limits are multiples of 8 themselves.)
  int fit(double v, int min, int max) => ((v.floor() ~/ 8) * 8).clamp(min, max);
  if (window.shortestSide < 600) {
    return (width: fit(window.longestSide, 960, 3840), height: fit(window.shortestSide, 544, 2160));
  }
  if (page != null && page.width >= window.width / 2 && page.height >= window.height / 2) {
    return (width: fit(page.width, 640, 3840), height: fit(page.height - _tabChromeHeight, 480, 2160));
  }
  return (
    width: fit(window.width - DesktopDimensions.sidebarCollapsedWidth, 640, 3840),
    height: fit(
        window.height - DesktopDimensions.pillBarHeight - DesktopDimensions.statusBarHeight - _tabChromeHeight,
        480,
        2160),
  );
}

/// Asks for the program to open on [host]: the target to open, or null where
/// the person cancelled. What is opened goes first in the host's recent list.
Future<XProgramTarget?> showXProgramDialog(BuildContext context, {required Connection host}) async {
  // (Read through the page's scope: a phone's host sheet that asked is gone by now.)
  final recent = ProviderScope.containerOf(context, listen: false).read(xProgramRecentProvider);
  final known = await recent.of(host.id);
  if (!context.mounted) return null;
  // The page that asks: the tab opens in its place.
  final page = context.findRenderObject();
  final size = xProgramSizeFor(MediaQuery.sizeOf(context),
      page: page is RenderBox && page.hasSize ? page.size : null);
  final program = await showZestModal<String>(
    context: context,
    size: ZestModalSize.standard,
    child: _XProgramDialog(hostName: host.label.isNotEmpty ? host.label : host.host, recent: known, hostId: host.id),
  );
  if (program == null) return null;
  await recent.used(host.id, program);
  return XProgramTarget(program, size.width, size.height);
}

/// On a phone: asks, opens the X program's screen and shows it; says so where
/// the plan's session limit keeps it from opening.
Future<void> openXProgramOnPhone(BuildContext context, Connection host) async {
  final target = await showXProgramDialog(context, host: host);
  if (target == null || !context.mounted) return;
  final id = ProviderScope.containerOf(context, listen: false)
      .read(activeSessionsProvider.notifier)
      .startXProgram(host, target);
  if (id == null) {
    showTopSnackBar(context, AppLocalizations.of(context)!.homeFreeSessionLimitSnack(freeSessionLimit), isError: true);
    return;
  }
  await context.push('/terminal/$id');
}

class _XProgramDialog extends ConsumerStatefulWidget {
  const _XProgramDialog({required this.hostName, required this.recent, required this.hostId});

  final String hostName;
  final String hostId;
  final List<String> recent;

  @override
  ConsumerState<_XProgramDialog> createState() => _XProgramDialogState();
}

class _XProgramDialogState extends ConsumerState<_XProgramDialog> {
  final _controller = TextEditingController();
  late List<String> _recent = widget.recent;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _problemText(AppLocalizations l10n) => switch (xProgramProblem(_controller.text)) {
        XProgramProblem.tooLong => l10n.xProgramTooLong(xProgramMaxBytes),
        XProgramProblem.controlCharacters => l10n.xProgramOneLine,
        _ => null,
      };

  void _open([String? program]) {
    final p = (program ?? _controller.text).trim();
    if (xProgramProblem(p) != null) return;
    zestDialogPop(context, p);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ready = xProgramProblem(_controller.text) == null;
    final touch = minTapTarget(context) > 32;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.appWindow,
      title: l10n.xProgramDialogTitle,
      subtitle: l10n.xProgramDialogSubtitle(widget.hostName),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ZestTextField(
            key: const ValueKey('x-program-field'),
            controller: _controller,
            label: l10n.xProgramFieldLabel,
            hintText: l10n.xProgramFieldHint,
            errorText: _problemText(l10n),
            onSubmit: _open,
          ),
          if (_recent.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(l10n.xProgramRecentLabel,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ZestTokens.textSecondary)),
                ),
                TextButton(
                  key: const ValueKey('x-program-forget'),
                  onPressed: () async {
                    await ref.read(xProgramRecentProvider).forget(widget.hostId);
                    if (mounted) setState(() => _recent = const []);
                  },
                  child: Text(l10n.xProgramForgetRecent, style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Each a pointer's 32 or a finger's 48 down (the 4.0 accessibility
            // pass; they were 30): drawn 32 or 40 high, the rest of a finger's
            // target taken from the gap between two rows of them.
            Wrap(
              spacing: 6,
              runSpacing: touch ? 8 : 6,
              children: [
                for (final (i, p) in _recent.indexed)
                  Tooltip(
                    message: p,
                    child: HitArea(
                      grow: EdgeInsets.symmetric(vertical: touch ? 4 : 0),
                      child: InkWell(
                        key: ValueKey('x-program-recent-$i'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _open(p),
                        child: Container(
                          height: touch ? 40 : 32,
                          constraints: const BoxConstraints(maxWidth: 260),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: ZestTokens.surfaceChip,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Align(
                            widthFactor: 1,
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(p,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontFamily: 'JetBrainsMono', fontSize: 12.5, color: ZestTokens.textPrimary)),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Text(l10n.xProgramDialogNote, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textSecondary)),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => zestDialogPop(context)),
      primaryAction: (label: l10n.xProgramOpenButton, icon: LucideIcons.play, onPressed: ready ? _open : null),
    );
  }
}
