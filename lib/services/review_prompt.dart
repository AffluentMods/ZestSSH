import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/utils/logger.dart';

/// Asking for a rating, on a phone: the
/// stores' own prompt, never a popup of the app's, and only right after
/// something went well. A session that was open for a while and that the
/// person closed themselves counts; the fifth such one, at least a week
/// after the app was first opened, and never twice in one version. Never
/// at start, after an error, or while a session is open (the person is at
/// their list of hosts by then). Apple and Google decide whether the prompt
/// shows at all; the app never learns whether it did, or what was said.
///
/// What it counts stays on this device, in its own settings: nothing about
/// it is sent anywhere.
class ReviewPrompt {
  ReviewPrompt(this._prefs, {InAppReview? review, Future<String> Function()? version, DateTime Function()? now})
      : _review = review ?? InAppReview.instance,
        _version = version ?? _appVersion,
        _now = now ?? DateTime.now;

  final SharedPreferences _prefs;
  final InAppReview _review;
  final Future<String> Function() _version;
  final DateTime Function() _now;

  static const firstSeenKey = 'review_first_seen';
  static const goodSessionsKey = 'review_good_sessions';
  static const askedVersionKey = 'review_asked_version';

  /// How long a session lasts before closing it counts as something that went well.
  static const goodSessionLength = Duration(minutes: 1);

  /// How many of those, and how long after the app was first opened.
  static const goodSessionsBeforeAsking = 5;
  static const waitAfterFirstSeen = Duration(days: 7);

  static Future<String> _appVersion() async => (await PackageInfo.fromPlatform()).version;

  /// Whether asking is for this device at all: a phone or a tablet.
  static bool get onThisDevice =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  /// Whether the build names a page in a store of its own (the release's:
  /// its App Store id and Play listing). One that names none asks nobody for
  /// a review and shows no "Rate": its people must not be sent to review the
  /// release.
  static bool get hasStorePage => kZestAppStoreId != '' || kZestPlayPackage != '';

  /// Notes when the app was first opened (once).
  Future<void> seen() async {
    if (_prefs.getInt(firstSeenKey) == null) {
      await _prefs.setInt(firstSeenKey, _now().millisecondsSinceEpoch);
    }
  }

  /// A session ended: [lasted] how long it was connected, [byThePerson]
  /// whether they closed it (not an error, not the server), [othersOpen]
  /// whether another session is still open. Asks when it is the moment.
  /// True when the stores' prompt was asked for.
  Future<bool> sessionEnded({required Duration lasted, required bool byThePerson, required bool othersOpen}) async {
    if (!onThisDevice || !hasStorePage) return false;
    if (!byThePerson || lasted < goodSessionLength) return false;
    await seen();
    final good = (_prefs.getInt(goodSessionsKey) ?? 0) + 1;
    await _prefs.setInt(goodSessionsKey, good);
    if (othersOpen || good < goodSessionsBeforeAsking) return false;
    final first = DateTime.fromMillisecondsSinceEpoch(_prefs.getInt(firstSeenKey)!);
    if (_now().difference(first) < waitAfterFirstSeen) return false;
    final version = await _version();
    if (_prefs.getString(askedVersionKey) == version) return false;
    try {
      if (!await _review.isAvailable()) return false;
      await _prefs.setString(askedVersionKey, version);
      await _review.requestReview();
      return true;
    } catch (e) {
      AppLogger.info('The stores\' rating prompt could not be asked for ($e)');
      return false;
    }
  }

  /// Opens ZestSSH's page in the store to rate it (Settings, About).
  Future<void> openStorePage() => _review.openStoreListing(appStoreId: kZestAppStoreId);
}

final reviewPromptProvider = Provider<ReviewPrompt>((ref) => ReviewPrompt(ref.read(sharedPreferencesProvider)));
