import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/profile_avatar_providers.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Whether the person's own picture may be fetched from [url]: https only,
/// with a host and no user name in it. The address
/// comes from their own sign-in (Google's or a company's picture) or from
/// ZestSSH Cloud, so no list of hosts fits it as one fits a team member's
/// picture (`isKnownPictureAddress`); it was fetched whatever it was, a plain
/// http address in clear included. Anything else shows the initial.
bool ownPictureAllowed(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty && uri.userInfo.isEmpty;
}

/// Single source of truth for the account avatar across the app (desktop
/// sidebar, profile popover, and the profile screen), so the sites never drift.
///
/// Resolution order (highest priority first):
///   1. A custom photo the user uploaded: the local cached file
///      ([customAvatarPathProvider]) on this device, else the synced
///      ([syncedAvatarUrlProvider]) copy on the account's other devices.
///   2. The signed-in provider photo (Google / Apple `photoUrl`) rendered as a
///      [NetworkImage], with a graceful fallback to the initial on load error
///      or when offline.
///   3. The initial letter of the display name / email (the historic default),
///      or `?` when signed out.
///
/// Always circular. Pass [borderColor] + [borderWidth] for a ring; the ring is
/// painted *over* the image edge so [size] stays the exact rendered diameter.
class ProfileAvatar extends ConsumerWidget {
  const ProfileAvatar({
    super.key,
    required this.size,
    this.backgroundColor,
    this.foregroundColor,
    this.borderColor,
    this.borderWidth = 0,
  });

  /// Rendered diameter in logical pixels.
  final double size;

  /// Fill behind the initial (defaults to the brand accent).
  final Color? backgroundColor;

  /// Initial text color (defaults to white).
  final Color? foregroundColor;

  /// Optional ring color. Only drawn when [borderWidth] > 0.
  final Color? borderColor;

  /// Optional ring width, painted over the image edge (keeps [size] exact).
  final double borderWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final customPath = ref.watch(customAvatarPathProvider);
    final syncedUrl = ref.watch(syncedAvatarUrlProvider);

    // A password account's name comes back empty, not missing: the email's
    // first letter then, never a '?'.
    final displayName = user?.displayName?.trim();
    final name = (displayName != null && displayName.isNotEmpty) ? displayName : user?.email?.trim();
    final initial = (name != null && name.isNotEmpty)
        ? name.substring(0, 1).toUpperCase()
        : '?';
    final bg = backgroundColor ?? AppColors.v3AccentPrimary;
    final fg = foregroundColor ?? Colors.white;

    ImageProvider? provider;
    if (customPath != null) {
      provider = FileImage(File(customPath));
    } else if (syncedUrl != null && ownPictureAllowed(syncedUrl)) {
      provider = NetworkImage(syncedUrl);
    } else if (user?.photoUrl != null && ownPictureAllowed(user!.photoUrl!)) {
      provider = NetworkImage(user.photoUrl!);
    }

    Widget avatar = SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Initial is always painted underneath so it shows through while a
            // network image loads, or if any image fails to decode.
            DecoratedBox(
              decoration: BoxDecoration(color: bg),
              child: Center(
                child: Text(
                  initial,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: size * 0.42,
                  ),
                ),
              ),
            ),
            if (provider != null)
              Image(
                image: provider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                // On decode / network failure, reveal the initial underneath.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
                // Keep the initial visible until the first frame is ready
                // instead of flashing an empty circle.
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) return child;
                  return const SizedBox.shrink();
                },
              ),
          ],
        ),
      ),
    );

    if (borderWidth > 0) {
      avatar = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: borderColor ?? AppColors.v3BorderSubtle,
            width: borderWidth,
          ),
        ),
        child: avatar,
      );
    }
    return avatar;
  }
}
