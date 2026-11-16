import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/avatar_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/profiles/active_profile.dart';

/// Outcome of a custom profile-photo pick.
enum AvatarPickOutcome { success, cancelled, invalidType, error }

/// The user's synced custom avatar URL from the hosted backend. Shown on
/// devices that do NOT have the local cached copy (e.g. a second phone), so a
/// custom photo set on one device appears on all of them. Null when the user
/// has no custom avatar or is signed out. Re-fetched on sign-in, cleared on
/// sign-out.
final syncedAvatarUrlProvider =
    StateNotifierProvider<SyncedAvatarNotifier, String?>((ref) {
  final notifier = SyncedAvatarNotifier();
  ref.listen(currentUserProvider, (prev, next) {
    if (next == null) {
      notifier.set(null);
    } else if (prev?.uid != next.uid) {
      notifier.refresh();
    }
  }, fireImmediately: true);
  return notifier;
});

class SyncedAvatarNotifier extends StateNotifier<String?> {
  SyncedAvatarNotifier() : super(null);

  /// Pull the current synced avatar URL from the backend (best-effort).
  Future<void> refresh() async {
    final url = await AvatarService.fetchUrl();
    if (mounted) state = url;
  }

  /// Set the URL directly (after an upload) or clear it (remove / sign-out).
  void set(String? url) {
    if (mounted) state = url;
  }
}

/// Custom profile picture (local path).
///
/// Holds the absolute path to a user-chosen avatar image that has been copied
/// into the app documents directory. `null` means the user has not set a
/// custom photo - the [ProfileAvatar] widget then falls back to the signed-in
/// provider photo (Google / Apple) and finally the initial.
///
/// This path is the on-device copy used for instant display. When the user is
/// signed in, [CustomAvatarNotifier.pickAndSet] ALSO uploads a downscaled PNG
/// to the account (best-effort) so the photo appears on their other devices
/// via [syncedAvatarUrlProvider]. The local file path itself is device-local
/// and is not part of the encrypted cloud-sync blob.
final customAvatarPathProvider =
    StateNotifierProvider<CustomAvatarNotifier, String?>((ref) {
  return CustomAvatarNotifier(ref);
});

class CustomAvatarNotifier extends StateNotifier<String?> {
  CustomAvatarNotifier(this._ref) : super(_initial(_ref));

  final Ref _ref;

  static const _prefKey = 'profile_custom_avatar_path';
  static const _allowedExtensions = {
    'png',
    'jpg',
    'jpeg',
    'webp',
    'gif',
    'bmp',
  };

  /// Reads the persisted path at construction. Guards against a stale entry
  /// whose file was removed out-of-band (e.g. the user cleared app data), so
  /// the UI degrades gracefully to the provider photo / initial instead of
  /// rendering a broken image.
  static String? _initial(Ref ref) {
    final prefs = ref.read(sharedPreferencesProvider);
    final path = prefs.getString(_prefKey);
    if (path == null || path.isEmpty) return null;
    if (!File(path).existsSync()) return null;
    return path;
  }

  /// Whether a custom photo is currently set.
  bool get hasCustom => state != null;

  /// Opens a file picker, validates the chosen image, copies it into the app
  /// documents directory, and persists its path. Returns an [AvatarPickOutcome]
  /// so callers can surface the right message.
  Future<AvatarPickOutcome> pickAndSet({String? dialogTitle}) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        dialogTitle: dialogTitle,
      );
      if (result == null || result.files.isEmpty) {
        return AvatarPickOutcome.cancelled;
      }
      final sourcePath = result.files.single.path;
      if (sourcePath == null) return AvatarPickOutcome.error;

      final ext = _extensionOf(sourcePath);
      if (!_allowedExtensions.contains(ext)) {
        return AvatarPickOutcome.invalidType;
      }

      // Crop / zoom / orient step. The frame is locked to a circle so what the
      // user adjusts matches the always-circular [ProfileAvatar]: pinch to
      // zoom, drag to reposition, rotate from the toolbar. Returns null only
      // when the user backs out of the crop screen, which cancels the change.
      final imagePath = await _cropIfSupported(sourcePath);
      if (imagePath == null) return AvatarPickOutcome.cancelled;

      // Downscale to a small PNG for BOTH the local cache and the upload, so
      // every device (this one via the file, others via the synced URL) shows
      // the same image and it fits the server's size cap.
      final png = await AvatarService.encodeAvatarPng(
        await File(imagePath).readAsBytes(),
      );

      final docs = await getApplicationDocumentsDirectory();
      final dir = ProfilePaths.forCurrent(Directory('${docs.path}/profile'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // Unique filename per pick so Flutter's image cache (keyed by file path)
      // never serves a stale bitmap after the user changes their photo.
      final dest =
          '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(dest).writeAsBytes(png);

      final previous = state;
      await _ref.read(sharedPreferencesProvider).setString(_prefKey, dest);
      state = dest;

      // Best-effort cleanup of the previously stored image.
      if (previous != null && previous != dest) {
        _deleteQuietly(previous);
      }

      // Upload so the photo syncs to the account's other devices. Best-effort:
      // if it fails (offline / signed out) the local photo still shows here.
      final url = await AvatarService.upload(png);
      if (url != null) {
        _ref.read(syncedAvatarUrlProvider.notifier).set(url);
      }
      return AvatarPickOutcome.success;
    } catch (e, st) {
      AppLogger.error('Failed to set custom profile photo', e, st);
      return AvatarPickOutcome.error;
    }
  }

  /// Clears the custom photo - the avatar falls back to the provider photo or
  /// the initial. Deletes the stored file best-effort.
  Future<void> remove() async {
    final previous = state;
    await _ref.read(sharedPreferencesProvider).remove(_prefKey);
    state = null;
    if (previous != null) _deleteQuietly(previous);
    // Clear the synced copy on the server + in memory so it disappears on the
    // account's other devices too.
    _ref.read(syncedAvatarUrlProvider.notifier).set(null);
    unawaited(AvatarService.delete());
  }

  /// Runs the native crop / zoom / orient UI and returns the path to the
  /// cropped image.
  ///
  /// image_cropper ships native croppers for Android (UCrop) and iOS
  /// (TOCropViewController) only, so on desktop (and if the plugin ever fails)
  /// the picked [sourcePath] is returned unchanged. Returns `null` only when
  /// the user backs out of the crop screen, so the caller can treat that as a
  /// cancellation rather than saving an unedited image.
  static Future<String?> _cropIfSupported(String sourcePath) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return sourcePath;
    try {
      final cropped = await ImageCropper().cropImage(
        sourcePath: sourcePath,
        aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
        compressFormat: ImageCompressFormat.png,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: gl10n.profileCropPhoto,
            toolbarColor: AppColors.v3ChromeBg,
            toolbarWidgetColor: AppColors.v3TextPrimary,
            backgroundColor: AppColors.background,
            activeControlsWidgetColor: AppColors.v3AccentPrimary,
            statusBarLight: false,
            cropStyle: CropStyle.circle,
            lockAspectRatio: true,
            aspectRatioPresets: const [CropAspectRatioPreset.square],
          ),
          IOSUiSettings(
            title: gl10n.profileCropPhoto,
            cropStyle: CropStyle.circle,
            aspectRatioLockEnabled: true,
            resetAspectRatioEnabled: false,
            aspectRatioPickerButtonHidden: true,
            aspectRatioPresets: const [CropAspectRatioPreset.square],
          ),
        ],
      );
      // A null result means the user cancelled the crop screen.
      return cropped?.path;
    } catch (e) {
      // Plugin missing or failed: fall back to the uncropped image so the user
      // can still set a photo instead of being blocked entirely.
      AppLogger.warning('Image cropper unavailable, using original image: $e');
      return sourcePath;
    }
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1 || dot == path.length - 1) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  static void _deleteQuietly(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      AppLogger.warning('Could not delete old avatar file: $e');
    }
  }
}
