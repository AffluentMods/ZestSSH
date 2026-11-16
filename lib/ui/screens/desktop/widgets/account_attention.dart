import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/theme/app_colors.dart';

/// True when the signed-in user can use cloud sync (paid Cloud Sync or a free
/// bring-your-own backend) but first-time setup is still unfinished, which is
/// exactly the state in which the recovery key has not been saved yet (a
/// completed sync always has a saved key). Mirrors the Account panel's own
/// attention logic in profile_screen.dart.
///
/// Drives the quiet setup dot on the account icon; it clears once setup lands.
final accountSetupNeedsAttentionProvider = FutureProvider<bool>((ref) async {
  final canUseSync =
      ref.watch(isCloudSyncProvider) || ref.watch(syncIsBringYourOwnProvider);
  if (!canUseSync) return false;
  // Re-read the snapshot whenever sync status changes (e.g. setup completes and
  // the first push lands) so the dot clears without needing an app restart.
  ref.watch(syncStatusProvider);
  final snapshot = await ref.watch(syncSetupStateServiceProvider).snapshot();
  return snapshot.isInProgress;
});

/// Overlays a small, quiet amber dot on the top-right of [child] while cloud
/// sync setup needs attention. Renders [child] unchanged otherwise, so it stays
/// invisible until there is genuinely something to finish, with no nagging.
class AccountAttentionDot extends ConsumerWidget {
  const AccountAttentionDot({
    super.key,
    required this.child,
    this.size = 6,
    this.ringColor,
  });

  final Widget child;
  final double size;

  /// Colour of the thin ring that lifts the dot off the icon. Defaults to the
  /// sidebar background; pass the surface colour when the icon sits elsewhere.
  final Color? ringColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final needsAttention =
        ref.watch(accountSetupNeedsAttentionProvider).valueOrNull ?? false;
    if (!needsAttention) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -1,
          right: -1,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: AppColors.warning,
              shape: BoxShape.circle,
              border: Border.all(
                color: ringColor ?? AppColors.v3Background,
                width: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
