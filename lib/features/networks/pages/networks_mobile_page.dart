import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/network_providers.dart';
import '../../../theme/app_colors.dart';
import '../models/network.dart';
import '../widgets/networks_list_view.dart';
import 'network_editor_page.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';
import 'package:zestssh/ui/widgets/phone_list.dart' show kPhonePageMaxWidth;

/// Route id used to signal "create a brand-new network" on the
/// `/networks/edit/:id` route. Networks use a UUID or the reserved
/// `system_default` id, so this sentinel can never collide with a real one.
const String kNewNetworkRouteId = 'new';

/// Mobile Networks screen (Doc-3 A2). A thin, full-screen host around the
/// shared [NetworksListView]: the same evaluation-order list, reorder,
/// first-match ordinals, pinned-last Default and override-count disclosure
/// the desktop page uses - but editing/creating pushes the editor as a full
/// route (`/networks/edit/:id`) instead of opening a side pane.
class NetworksMobileScreen extends ConsumerWidget {
  const NetworksMobileScreen({super.key});

  void _openEditor(BuildContext context, String networkId) {
    context.push('/networks/edit/$networkId');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final networksAsync = ref.watch(allNetworksProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.networksPageTitle),
        // Added with a "+" in the bar, as every list page (a floating
        // button before); the empty page keeps its own button.
        actions: [
          const GuideHelpButton(feature: 'networks', size: 20),
          IconButton(
            key: const ValueKey('networks-add'),
            onPressed: () => _openEditor(context, kNewNetworkRouteId),
            tooltip: l10n.networksAdd,
            icon: const Icon(LucideIcons.plus),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: networksAsync.when(
        // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
        skipLoadingOnReload: true,
        loading: () => Center(
          child: CircularProgressIndicator(color: AppColors.v3AccentPrimary),
        ),
        error: (e, _) => Center(
          child: Text(
            'Error: $e',
            style: TextStyle(color: AppColors.v3Error),
          ),
        ),
        data: (networks) {
          if (networks.isEmpty) {
            return NetworksEmptyState(
              title: l10n.networksEmptyState,
              description: l10n.networksEmptyDescription,
              ctaLabel: l10n.networksAdd,
              onCta: () => _openEditor(context, kNewNetworkRouteId),
            );
          }
          // On a tablet, the one centred column of a phone page's content,
          // as wide as the Hosts tab's (it hugged the left, narrower).
          return SafeArea(
            child: NetworksListView(
              networks: networks,
              onEdit: (id) => _openEditor(context, id),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              maxWidth: kPhonePageMaxWidth,
              alignment: Alignment.topCenter,
            ),
          );
        },
      ),
    );
  }
}

/// Full-screen host for [NetworkEditorPage] when reached via the
/// `/networks/edit/:id` route on mobile. Resolves the network to edit from
/// the live list (or a brand-new one for [kNewNetworkRouteId]); the editor
/// itself renders its own header/footer and, given [onClose], pops the route
/// on save / cancel / delete.
class NetworkEditorRoutePage extends ConsumerWidget {
  const NetworkEditorRoutePage({super.key, required this.networkId});

  final String networkId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creating = networkId == kNewNetworkRouteId;
    final networksAsync = ref.watch(allNetworksProvider);

    return Scaffold(
      body: SafeArea(
        child: networksAsync.when(
          // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
          skipLoadingOnReload: true,
          loading: () => Center(
            child:
                CircularProgressIndicator(color: AppColors.v3AccentPrimary),
          ),
          error: (e, _) => Center(
            child: Text(
              'Error: $e',
              style: TextStyle(color: AppColors.v3Error),
            ),
          ),
          data: (networks) {
            Network? existing;
            if (!creating) {
              for (final n in networks) {
                if (n.id == networkId) {
                  existing = n;
                  break;
                }
              }
              // The network was deleted (or the id is bogus): pop back to the
              // list rather than showing an editor bound to nothing.
              if (existing == null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted && context.canPop()) context.pop();
                });
                return const SizedBox.shrink();
              }
            }
            return NetworkEditorPage(
              network: existing,
              onClose: () {
                if (context.canPop()) context.pop();
              },
            );
          },
        ),
      ),
    );
  }
}
