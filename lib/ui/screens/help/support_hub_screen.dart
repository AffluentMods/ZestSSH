import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/help/support_hub_page.dart';

/// The Support Hub on a phone (in a
/// phone's width): the same page as on a computer, a route of its own, with
/// the list first and a conversation or a new report over it. A phone takes
/// no picture of the app, so no screenshot is offered.
class SupportHubScreen extends ConsumerStatefulWidget {
  const SupportHubScreen({super.key, this.tab, required this.onClose});

  /// The tab to open on; null keeps the one it was left on.
  final HubTab? tab;
  final VoidCallback onClose;

  @override
  ConsumerState<SupportHubScreen> createState() => _SupportHubScreenState();
}

class _SupportHubScreenState extends ConsumerState<SupportHubScreen> {
  @override
  void initState() {
    super.initState();
    final tab = widget.tab;
    if (tab != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(supportHubTabProvider.notifier).state = tab;
        ref.read(supportHubComposeProvider.notifier).state = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.v3Background,
      body: SafeArea(
        child: SupportHubPage(captureScreenshot: null, onClose: widget.onClose),
      ),
    );
  }
}
