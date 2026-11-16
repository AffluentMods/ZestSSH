import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/profiles/keychain.dart';

/// Custom profile-avatar upload / download against the HOSTED api.zestssh.com.
///
/// Avatars always live on the hosted backend regardless of the user's chosen
/// sync backend, and are authenticated with the ZestSSH ACCOUNT bearer (mobile
/// Firebase ID token, or the desktop session JWT). A custom/self-hosted sync
/// server token is deliberately NOT used here - the account credential must
/// never be sent to a third-party server (mirrors the sync backend's rule).
class AvatarService {
  static String get _base => kZestApiBase;

  static FlutterSecureStorage get _storage => appKeychain;

  /// The account bearer: mobile Firebase ID token, else the desktop session
  /// JWT stashed in secure storage. Null when signed out.
  static Future<String?> _bearer() async {
    var token = await AuthService.getIdToken(forceRefresh: false);
    token ??= await AccountSecret.sessionToken.read(_storage);
    return token;
  }

  /// Downscale any picked image to a small PNG (max 256px wide) so it fits the
  /// server's 512 KB cap, loads fast, and looks identical on every device.
  /// Uses `dart:ui` only - no image package dependency.
  static Future<Uint8List> encodeAvatarPng(Uint8List input) async {
    final codec = await ui.instantiateImageCodec(input, targetWidth: 256);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (data == null) {
      throw Exception('Could not encode avatar image');
    }
    return data.buffer.asUint8List();
  }

  /// Upload [pngBytes] as the user's custom avatar. Returns the public URL, or
  /// null on failure / signed out (caller keeps the local copy either way).
  static Future<String?> upload(Uint8List pngBytes) async {
    final token = await _bearer();
    if (token == null) return null;
    try {
      final resp = await PinnedHttpClient.client.post(
        Uri.parse('$_base/account/avatar'),
        headers: {
          'Authorization': 'Bearer $token',
          ...DeviceSessionHeader.headers,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'data': base64Encode(pngBytes),
          'mime': 'image/png',
        }),
      // Times of their own, as every other ZestSSH Cloud call has (found in a
      // code audit).
      ).timeout(const Duration(seconds: 60));
      if (resp.statusCode == 200) {
        final url = (jsonDecode(resp.body) as Map<String, dynamic>)['avatar_url'];
        return url is String && url.isNotEmpty ? url : null;
      }
      AppLogger.warning('Avatar upload failed: HTTP ${resp.statusCode}');
      return null;
    } catch (e) {
      AppLogger.warning('Avatar upload error: $e');
      return null;
    }
  }

  /// Delete the user's custom avatar on the server (best-effort).
  static Future<void> delete() async {
    final token = await _bearer();
    if (token == null) return;
    try {
      await PinnedHttpClient.client.delete(
        Uri.parse('$_base/account/avatar'),
        headers: {'Authorization': 'Bearer $token', ...DeviceSessionHeader.headers},
      ).timeout(const Duration(seconds: 30));
    } catch (e) {
      AppLogger.warning('Avatar delete error: $e');
    }
  }

  /// Fetch the current synced avatar URL from `GET /account` (null when none
  /// or signed out).
  static Future<String?> fetchUrl() async {
    final token = await _bearer();
    if (token == null) return null;
    try {
      final resp = await PinnedHttpClient.client.get(
        Uri.parse('$_base/account'),
        headers: {'Authorization': 'Bearer $token', ...DeviceSessionHeader.headers},
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final url = (jsonDecode(resp.body) as Map<String, dynamic>)['avatar_url'];
        return url is String && url.isNotEmpty ? url : null;
      }
      return null;
    } catch (e) {
      AppLogger.warning('Avatar fetch error: $e');
      return null;
    }
  }
}
