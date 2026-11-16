import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/help/guides/guide_entry.dart';
import 'package:zestssh/utils/type_name.dart';

/// Why a guide could not be fetched.
class GuideFetchFailure implements Exception, HasTypeName {
  const GuideFetchFailure(this.code, this.reason, {this.status, this.cause});

  @override
  String get typeName => 'GuideFetchFailure';

  /// [ErrorCodes.guideNotReached] (no answer: offline, a timeout, a refused
  /// connection) or [ErrorCodes.guideUnreadable] (an answer that is no
  /// guide).
  final ErrorCode code;

  /// What happened, in English, for the copied details.
  final String reason;

  /// The HTTP status, where there was an answer.
  final int? status;
  final Object? cause;

  @override
  String toString() => [
        'Guide not fetched (${code.code}): $reason',
        if (status != null) 'HTTP status $status',
        if (cause != null) 'Cause: $cause',
      ].join('. ');
}

/// A guide's words as saved on this device for when it is offline.
class SavedGuide {
  const SavedGuide(this.markdown, this.savedAt);
  final String markdown;
  final DateTime savedAt;
}

/// Where the copies of guides are kept for offline.
abstract class GuideCopies {
  /// The copy of the guide at [slug], or null.
  Future<SavedGuide?> read(String slug);

  /// Keeps [markdown] as the copy of the guide at [slug]. A copy that cannot
  /// be kept is not kept: the guide is shown all the same.
  Future<void> write(String slug, String markdown);
}

/// The copies as files in the app's support folder: `guides/<slug>.md`.
/// They are public pages; nothing else is written there.
class FileGuideCopies implements GuideCopies {
  FileGuideCopies({Future<Directory?> Function()? root}) : _root = root ?? _defaultRoot;

  final Future<Directory?> Function() _root;

  static Future<Directory?> _defaultRoot() async {
    try {
      return await getApplicationSupportDirectory();
    } catch (_) {
      return null; // (No such folder here: nothing is kept.)
    }
  }

  Future<File?> _file(String slug) async {
    if (!kGuideSlug.hasMatch(slug)) return null;
    final root = await _root();
    if (root == null) return null;
    return File('${root.path}${Platform.pathSeparator}guides${Platform.pathSeparator}$slug.md');
  }

  @override
  Future<SavedGuide?> read(String slug) async {
    try {
      final file = await _file(slug);
      if (file == null || !await file.exists()) return null;
      return SavedGuide(await file.readAsString(), await file.lastModified());
    } catch (_) {
      return null; // (An unreadable copy is no copy.)
    }
  }

  @override
  Future<void> write(String slug, String markdown) async {
    try {
      final file = await _file(slug);
      if (file == null) return;
      await file.parent.create(recursive: true);
      final part = File('${file.path}.part');
      await part.writeAsString(markdown, flush: true);
      await part.rename(file.path);
    } catch (_) {
      // Not kept: the guide is shown all the same, and fetched again next time.
    }
  }
}

/// Fetches a guide's raw Markdown from the docs site and keeps a copy on the
/// device, so a guide opened once can be read offline.
///
/// The request is a plain GET of `https://docs.zestssh.com/guides/<slug>.md`:
/// no cookies, no sign-in, nothing about the person or the device beyond
/// what any web request carries (the address it comes from, and the Dart
/// HTTP client's own user agent).
class GuideRepository {
  GuideRepository({
    http.Client? client,
    GuideCopies? copies,
    this.timeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        copies = copies ?? FileGuideCopies();

  final http.Client _client;
  final GuideCopies copies;
  final Duration timeout;

  /// A guide is a few KB; an answer this big is not one.
  static const int maxBytes = 512 * 1024;

  /// The copy saved when the guide was last fetched, or null.
  Future<SavedGuide?> saved(String slug) => kGuideSlug.hasMatch(slug) ? copies.read(slug) : Future.value();

  /// Fetches the guide at [slug] and saves it; throws [GuideFetchFailure].
  Future<String> fetch(String slug) async {
    final uri = guideMarkdownUri(slug);
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers['Accept'] = 'text/markdown, text/plain;q=0.9';
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException catch (e) {
      throw GuideFetchFailure(ErrorCodes.guideNotReached, 'no answer within ${timeout.inSeconds} s', cause: e);
    } on SocketException catch (e) {
      throw GuideFetchFailure(ErrorCodes.guideNotReached, 'the docs site could not be reached', cause: e);
    } on HandshakeException catch (e) {
      throw GuideFetchFailure(ErrorCodes.guideNotReached, 'the secure connection failed', cause: e);
    } on http.ClientException catch (e) {
      throw GuideFetchFailure(ErrorCodes.guideNotReached, 'the request failed', cause: e);
    }
    if (response.statusCode != 200) {
      // (Drained, so the connection is let go.)
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw GuideFetchFailure(ErrorCodes.guideUnreadable, 'the docs site answered ${response.statusCode}',
          status: response.statusCode);
    }
    final bytes = <int>[];
    Future<void> read() async {
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) {
          throw const GuideFetchFailure(ErrorCodes.guideUnreadable, 'the answer is too big to be a guide');
        }
      }
    }

    try {
      await read().timeout(timeout);
    } on TimeoutException catch (e) {
      throw GuideFetchFailure(ErrorCodes.guideNotReached, 'the answer stopped coming', cause: e);
    } on GuideFetchFailure {
      rethrow;
    } on Exception catch (e) {
      throw GuideFetchFailure(ErrorCodes.guideNotReached, 'the answer was cut off', cause: e);
    }
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException catch (e) {
      throw GuideFetchFailure(ErrorCodes.guideUnreadable, 'the answer is not text', cause: e);
    }
    final head = text.trimLeft().toLowerCase();
    if (head.startsWith('<!doctype') || head.startsWith('<html')) {
      throw const GuideFetchFailure(ErrorCodes.guideUnreadable, 'the answer is a web page, not a guide');
    }
    await copies.write(slug, text);
    return text;
  }
}
