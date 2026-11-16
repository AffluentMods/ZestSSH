import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/secret_seal.dart' show KeySecretUnread;
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/platform_utils.dart' show isDesktopPlatform;

/// What is said where ZestSSH Cloud refuses this device because the account
/// syncs on as many devices as one person may: the path to the Devices
/// section as this device has it, a computer's (Settings, Account and
/// security, Devices) or a phone's (More, Account, Devices) (22 October
/// 2026: a phone was given the computer's).
String cloudDeviceLimitWords(AppLocalizations t, {bool? onComputer}) =>
    (onComputer ?? debugCloudDeviceLimitOnComputer ?? isDesktopPlatform)
        ? t.syncCloudDeviceLimit
        : t.syncCloudDeviceLimitPhone;

/// Stands in for the platform in tests.
@visibleForTesting
bool? debugCloudDeviceLimitOnComputer;

/// What stopped a step of sync, as the person is told (3.0).
///
/// Whatever a sync fails with was said as "Couldn't reach the sync server"
/// in one of six wordings: the hosted service being down, a person's own
/// storage being down, and a failure on the device itself that had nothing
/// to do with any server. Three situations with three different things to
/// do, and each is said as what it is now, with its code:
///
/// * Sync to ZestSSH Cloud that could not reach it says how ZestSSH Cloud
///   stands (lib/services/cloud/cloud_failure.dart): the device offline,
///   the service not responding, no secure connection, a fault of its own.
/// * Sync to a store of the person's own (WebDAV, S3, Google Drive, a
///   server of theirs) that could not reach it says what the network said,
///   and that it is their storage ([ErrorCodes.syncStoreUnreachable]).
/// * What failed on the device says that ([ErrorCodes.syncFailedHere]),
///   with what was caught kept for the details.
///
/// What the store itself said in so many words (it holds no vault, the
/// keys are not the account's) is left exactly as it was said.
abstract final class SyncFailure {
  /// A failure met while the store was being asked. [hosted] is whether the
  /// store is ZestSSH Cloud.
  static SyncException ofStore(Object error, {required bool hosted}) {
    if (hosted) {
      // (Data that did not come in time is ZestSSH Cloud not answering,
      // and said as that: down, blocked here, nothing reached.)
      final cloud = cloudFailureOf(error is StoreNoAnswerInTime ? TimeoutException(error.detail) : error);
      if (cloud != null) {
        return SyncException(cloud.message(gl10n),
            detail: error is SyncException ? error.detail ?? cloud.detail : cloud.detail);
      }
      return _asIs(error);
    }
    if (isNoAnswer(error)) {
      final friendly = describeNetworkError(error, subject: gl10n.errSubjectSyncServer);
      return SyncException(
        ErrorCodes.withCode(friendly.message, ErrorCodes.syncStoreUnreachable),
        detail: friendly.detail,
      );
    }
    final cloudLike = cloudFailureOf(error);
    if (cloudLike != null && error is SyncException) {
      // Their own server answering with a fault of its own: its words, and
      // the code that says whose storage it is.
      return SyncException(
        ErrorCodes.withCode(error.message, ErrorCodes.syncStoreUnreachable),
        detail: error.detail ?? cloudLike.detail,
      );
    }
    return _asIs(error);
  }

  /// What is said where ZestSSH Cloud keeps no copy for this account
  /// (SyncHostingRequiredException): its storage comes with Juiced, which the
  /// account does not have, and storage of the person's own is free; with
  /// its code. (It was "Couldn't reach the sync server" in 2.2.1, and the
  /// server's own English after.)
  static String get hostingNotIncluded =>
      ErrorCodes.withCode(gl10n.syncHostingNeedsJuiced, ErrorCodes.syncHostingNotIncluded);

  /// What is said where ZestSSH Cloud refuses this device because the
  /// account syncs on as many devices as one person may
  /// (SyncCloudDeviceLimitException); with its code.
  static String get cloudDeviceLimit =>
      ErrorCodes.withCode(cloudDeviceLimitWords(gl10n), ErrorCodes.syncCloudDeviceLimit);

  /// Another device wrote to the store first, twice in a row ([conflict],
  /// kept for the details): nothing is wrong and nothing was lost, and it is
  /// said as that. (It was "Version conflict: server is at v1, expected v3.
  /// Pull and retry.", in English whatever the language.)
  static SyncException writtenFirst(SyncConflictException conflict) => SyncException(
        ErrorCodes.withCode(gl10n.syncOtherDeviceWroteFirst, ErrorCodes.syncWrittenFirst),
        detail: conflict.message,
      );

  // ── What a store of the person's own said, in their language ────────
  // (3.0, 16 October 2026: WebDAV, S3 and Google Drive failing was said in
  // English, in every language.) Each is the situation it is, with what was
  // said of it in English kept for the details; one that answered with a
  // fault keeps "HTTP <status>" in its words, so that [ofStore] tells it for
  // a fault of the store's own.

  /// The store answered [status] to a request ([what], for the details):
  /// refused (401, 403), no such place (404), or a fault of its own.
  static SyncException storeAnswered(int status, String what) => SyncException(
        switch (status) {
          401 || 403 => gl10n.syncStoreRefused,
          404 => gl10n.syncStoreNotThere,
          _ => gl10n.syncStoreFault(status),
        },
        detail: what,
      );

  /// The store did not answer in time ([what], for the details), with the
  /// code a store that does not answer at all is said with.
  static SyncException storeNoAnswerInTime(String what) => StoreNoAnswerInTime(
        ErrorCodes.withCode(gl10n.syncStoreNoAnswerInTime, ErrorCodes.syncStoreUnreachable),
        detail: what,
      );

  /// What the store holds, or what was to go to it, is larger than the app
  /// takes ([what], for the details).
  static SyncException storeTooLarge(String what) => SyncException(gl10n.syncStoreTooLarge, detail: what);

  /// The store holds no sync data yet.
  static SyncException get storeEmpty => SyncException(gl10n.syncStoreEmpty, detail: 'No sync data found');

  /// A failure on this device: reading what is to be sent, taking in what
  /// was fetched, anything that is not the store's. macOS not letting ZestSSH
  /// read a key it saved is said as that, with its code (3.3.2), and so is a
  /// key whose saved secret does not open here, with the key's name (4.0,
  /// found in a security audit: it was this device's whole sync failing with no word of why).
  static SyncException onDevice(Object error) => switch (error) {
        SyncException() => error,
        KeySecretUnread() => SyncException(keySecretUnread(error), detail: '$error (${error.slot})'),
        KeychainAccessDenied() => SyncException(
            ErrorCodes.withCode(gl10n.macKeychainDeniedTitle, ErrorCodes.macKeychainDenied),
            detail: '$error',
          ),
        _ => SyncException(
            ErrorCodes.withCode(gl10n.syncFailedOnDevice(gl10n.accountSyncNow), ErrorCodes.syncFailedHere),
            detail: '$error',
          ),
      };

  /// What is said where the secret of a key is kept on this device and does
  /// not open here, so nothing was gathered to send or to back up; with its
  /// code.
  static String keySecretUnread(KeySecretUnread error) =>
      ErrorCodes.withCode(gl10n.keySecretUnreadHere(error.label), ErrorCodes.syncKeySecretUnread);

  static SyncException _asIs(Object error) {
    if (error is SyncException) return error;
    final friendly = describeNetworkError(error, subject: gl10n.errSubjectSyncServer);
    return SyncException(friendly.message, detail: friendly.detail);
  }
}

/// A store that did not answer in time ([SyncFailure.storeNoAnswerInTime]).
/// Of ZestSSH Cloud, [SyncFailure.ofStore] says it as the service not
/// answering (down, blocked here, nothing reached), as it says a request
/// that got no answer at all.
class StoreNoAnswerInTime extends SyncException {
  const StoreNoAnswerInTime(super.message, {super.detail});

  @override
  String get typeName => 'StoreNoAnswerInTime';
}
