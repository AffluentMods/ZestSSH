import 'dart:convert';
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/services/backup/backup_destination.dart';
import 'package:zestssh/utils/logger.dart';

/// Backup destination for Google Drive using the REST API v3.
///
/// Authentication is handled through Google Sign-In (already in the app
/// for Firebase Auth). When the user authenticates for Drive backups we
/// request the `drive.file` scope, which limits access to files created
/// by ZestSSH - the app never sees the user's other Drive files.
///
/// All API calls use raw HTTP via the `http` package against
/// `https://www.googleapis.com/drive/v3` and the multipart upload
/// endpoint at `https://www.googleapis.com/upload/drive/v3`.
///
/// Backup files are stored in a dedicated "ZestSSH Backups" folder
/// so they are easy to find in the user's Drive.
class GoogleDriveBackupDestination extends BackupDestination {
  /// Optional user-assigned label.
  final String label;

  /// Google Sign-In instance configured with Drive file scope.
  GoogleSignIn? _googleSignIn;

  /// Cached Google Sign-In account from the current session.
  GoogleSignInAccount? _account;

  /// Cached Drive folder ID for the "ZestSSH Backups" folder.
  String? _backupFolderId;

  /// The Drive scope that limits access to app-created files only.
  static const _driveFileScope = 'https://www.googleapis.com/auth/drive.file';

  /// Base URL for Drive API v3 metadata operations.
  static const _driveApiBase = 'https://www.googleapis.com/drive/v3';

  /// Base URL for Drive API v3 media upload operations.
  static const _driveUploadBase =
      'https://www.googleapis.com/upload/drive/v3';

  /// Name of the folder created in the user's Drive root.
  static const _backupFolderName = 'ZestSSH Backups';

  /// MIME type for Google Drive folders.
  static const _folderMimeType = 'application/vnd.google-apps.folder';

  GoogleDriveBackupDestination({String? label})
      : label = label ?? 'Google Drive';

  @override
  String get id => 'google_drive';

  @override
  String get name => 'google_drive';

  @override
  String get displayName => label;

  @override
  bool get survivesUninstall => true;

  // ── Auth helpers ──────────────────────────────────────────────────

  /// Lazily initialise [GoogleSignIn] with the Drive file scope.
  GoogleSignIn get _signIn {
    _googleSignIn ??= GoogleSignIn(scopes: [_driveFileScope]);
    return _googleSignIn!;
  }

  /// Get a valid access token, refreshing silently if needed.
  ///
  /// Returns `null` if the user is not signed in.
  Future<String?> _getAccessToken() async {
    // Try silent sign-in first (restores previous session).
    _account ??= await _signIn.signInSilently();
    if (_account == null) return null;

    final auth = await _account!.authentication;
    return auth.accessToken;
  }

  /// Build standard authorization headers for Drive API calls.
  Future<Map<String, String>> _authHeaders() async {
    final token = await _getAccessToken();
    if (token == null) {
      throw StateError(
        'Not authenticated with Google Drive. '
        'Call authenticate() first.',
      );
    }
    return {
      'Authorization': 'Bearer $token',
    };
  }

  @override
  Future<bool> isAuthenticated() async {
    try {
      final token = await _getAccessToken();
      return token != null;
    } catch (e) {
      AppLogger.debug('Google Drive auth check failed: $e');
      return false;
    }
  }

  @override
  Future<void> authenticate() async {
    try {
      _account = await _signIn.signIn();
      if (_account == null) {
        throw StateError('Google Sign-In was cancelled by the user.');
      }
      AppLogger.info(
        'Google Drive authenticated as ${_account!.email}',
      );
    } catch (e) {
      AppLogger.error('Google Drive authentication failed', e);
      rethrow;
    }
  }

  // ── Folder management ─────────────────────────────────────────────

  /// Find or create the "ZestSSH Backups" folder in the user's Drive.
  ///
  /// The folder ID is cached for the lifetime of this instance to avoid
  /// redundant API calls during a single backup session.
  Future<String> _ensureBackupFolder() async {
    if (_backupFolderId != null) return _backupFolderId!;

    final headers = await _authHeaders();

    // Search for an existing folder by name.
    final query = Uri.encodeComponent(
      "name = '$_backupFolderName' "
      "and mimeType = '$_folderMimeType' "
      "and trashed = false",
    );
    final searchUri = Uri.parse(
      '$_driveApiBase/files?q=$query&fields=files(id,name)&spaces=drive',
    );

    final searchResponse = await http.get(searchUri, headers: headers).timeout(driveAnswerTime());
    if (searchResponse.statusCode != 200) {
      throw HttpException(
        'Drive folder search failed: '
        '${searchResponse.statusCode} ${searchResponse.body}',
      );
    }

    final searchData =
        jsonDecode(searchResponse.body) as Map<String, dynamic>;
    final files = searchData['files'] as List<dynamic>;

    if (files.isNotEmpty) {
      _backupFolderId = (files.first as Map<String, dynamic>)['id'] as String;
      AppLogger.debug(
        'Found existing Drive backup folder: $_backupFolderId',
      );
      return _backupFolderId!;
    }

    // Create the folder.
    final createUri = Uri.parse(
      '$_driveApiBase/files',
    );
    final createResponse = await http.post(
      createUri,
      headers: {
        ...headers,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonEncode({
        'name': _backupFolderName,
        'mimeType': _folderMimeType,
      }),
    ).timeout(driveAnswerTime());

    if (createResponse.statusCode != 200) {
      throw HttpException(
        'Drive folder creation failed: '
        '${createResponse.statusCode} ${createResponse.body}',
      );
    }

    final createData =
        jsonDecode(createResponse.body) as Map<String, dynamic>;
    _backupFolderId = createData['id'] as String;
    AppLogger.info(
      'Created Drive backup folder: $_backupFolderId',
    );
    return _backupFolderId!;
  }

  // ── Backup operations ─────────────────────────────────────────────

  @override
  Future<void> uploadBackup(File file, String filename) async {
    final folderId = await _ensureBackupFolder();
    final headers = await _authHeaders();
    final bytes = await file.readAsBytes();

    // Check if a file with the same name already exists in the folder
    // and delete it so we don't accumulate duplicates.
    await _deleteExistingFile(filename, folderId, headers);

    // Use multipart upload: metadata part + media part.
    final boundary = 'zestssh_backup_${DateTime.now().millisecondsSinceEpoch}';
    final metadata = jsonEncode({
      'name': filename,
      'parents': [folderId],
    });

    final body = StringBuffer()
      ..writeln('--$boundary')
      ..writeln('Content-Type: application/json; charset=UTF-8')
      ..writeln()
      ..writeln(metadata)
      ..writeln('--$boundary')
      ..writeln('Content-Type: application/octet-stream')
      ..writeln('Content-Transfer-Encoding: base64')
      ..writeln()
      ..writeln(base64Encode(bytes))
      ..writeln('--$boundary--');

    final uploadUri = Uri.parse(
      '$_driveUploadBase/files?uploadType=multipart&fields=id,name,size',
    );

    final response = await http.post(
      uploadUri,
      headers: {
        ...headers,
        'Content-Type': 'multipart/related; boundary=$boundary',
      },
      body: body.toString(),
    ).timeout(driveAnswerTime(body.length));

    if (response.statusCode != 200) {
      throw HttpException(
        'Drive upload failed: ${response.statusCode} ${response.body}',
      );
    }

    AppLogger.info('Google Drive backup uploaded: $filename');
  }

  @override
  Future<List<BackupFileInfo>> listBackups() async {
    final folderId = await _ensureBackupFolder();
    final headers = await _authHeaders();

    final allFiles = <BackupFileInfo>[];
    String? pageToken;

    do {
      final query = Uri.encodeComponent(
        "'$folderId' in parents "
        "and name contains '.zest' "
        "and trashed = false",
      );
      var url =
          '$_driveApiBase/files?q=$query'
          '&fields=nextPageToken,files(id,name,size,createdTime)'
          '&orderBy=createdTime desc'
          '&pageSize=100'
          '&spaces=drive';

      if (pageToken != null) {
        url += '&pageToken=${Uri.encodeComponent(pageToken)}';
      }

      final response = await http.get(Uri.parse(url), headers: headers).timeout(driveAnswerTime());

      if (response.statusCode != 200) {
        throw HttpException(
          'Drive list failed: ${response.statusCode} ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final files = data['files'] as List<dynamic>;

      for (final raw in files) {
        final file = raw as Map<String, dynamic>;
        final name = file['name'] as String;
        if (!name.endsWith('.zest')) continue;

        allFiles.add(BackupFileInfo(
          filename: name,
          createdAt: DateTime.parse(file['createdTime'] as String),
          sizeBytes: int.tryParse('${file['size'] ?? '0'}') ?? 0,
          destinationId: id,
        ));
      }

      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null);

    // Sort newest first (API already returns this order, but be safe).
    allFiles.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return allFiles;
  }

  @override
  Future<File> downloadBackup(String filename, String localPath) async {
    final fileId = await _findFileId(filename);
    if (fileId == null) {
      throw FileSystemException(
        'Backup not found on Google Drive: $filename',
      );
    }

    final headers = await _authHeaders();
    final uri = Uri.parse('$_driveApiBase/files/$fileId?alt=media');
    final response = await http.get(uri, headers: headers).timeout(driveAnswerTime());

    if (response.statusCode != 200) {
      throw HttpException(
        'Drive download failed: ${response.statusCode}',
        uri: uri,
      );
    }

    final file = File(localPath);
    await file.writeAsBytes(response.bodyBytes);
    AppLogger.info(
      'Google Drive backup downloaded: $filename -> $localPath',
    );
    return file;
  }

  @override
  Future<void> deleteBackup(String filename) async {
    final fileId = await _findFileId(filename);
    if (fileId == null) {
      AppLogger.warning(
        'Google Drive backup not found for deletion: $filename',
      );
      return;
    }

    final headers = await _authHeaders();
    final uri = Uri.parse('$_driveApiBase/files/$fileId');
    final response = await http.delete(uri, headers: headers).timeout(driveAnswerTime());

    // 204 No Content is the standard success for DELETE.
    if (response.statusCode != 204 && response.statusCode != 200) {
      throw HttpException(
        'Drive delete failed: ${response.statusCode} ${response.body}',
        uri: uri,
      );
    }
    AppLogger.info('Google Drive backup deleted: $filename');
  }

  // ── Private helpers ───────────────────────────────────────────────

  /// Find the Drive file ID for a backup by filename within the backup folder.
  Future<String?> _findFileId(String filename) async {
    final folderId = await _ensureBackupFolder();
    final headers = await _authHeaders();

    final escapedName = filename.replaceAll("'", "\\'");
    final query = Uri.encodeComponent(
      "'$folderId' in parents "
      "and name = '$escapedName' "
      "and trashed = false",
    );
    final uri = Uri.parse(
      '$_driveApiBase/files?q=$query&fields=files(id)&spaces=drive',
    );

    final response = await http.get(uri, headers: headers).timeout(driveAnswerTime());
    if (response.statusCode != 200) return null;

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final files = data['files'] as List<dynamic>;
    if (files.isEmpty) return null;

    return (files.first as Map<String, dynamic>)['id'] as String;
  }

  /// Delete an existing file with [filename] in [folderId] if one exists.
  ///
  /// This prevents duplicate files when re-uploading a backup with the
  /// same name (e.g. overwriting today's scheduled backup).
  Future<void> _deleteExistingFile(
    String filename,
    String folderId,
    Map<String, String> headers,
  ) async {
    final escapedName = filename.replaceAll("'", "\\'");
    final query = Uri.encodeComponent(
      "'$folderId' in parents "
      "and name = '$escapedName' "
      "and trashed = false",
    );
    final uri = Uri.parse(
      '$_driveApiBase/files?q=$query&fields=files(id)&spaces=drive',
    );

    try {
      final response = await http.get(uri, headers: headers).timeout(driveAnswerTime());
      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final files = data['files'] as List<dynamic>;

      for (final raw in files) {
        final fileId = (raw as Map<String, dynamic>)['id'] as String;
        await http.delete(
          Uri.parse('$_driveApiBase/files/$fileId'),
          headers: headers,
        ).timeout(driveAnswerTime());
        AppLogger.debug(
          'Deleted existing Drive backup before re-upload: $filename',
        );
      }
    } catch (e) {
      // Non-fatal - the upload will still succeed, just with a duplicate.
      AppLogger.debug('Failed to delete existing backup: $e');
    }
  }

  // ── Serialization ─────────────────────────────────────────────────

  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'id': id,
        'label': label,
      };

  factory GoogleDriveBackupDestination.fromJson(Map<String, dynamic> json) {
    return GoogleDriveBackupDestination(
      label: json['label'] as String?,
    );
  }
}

/// How long a Google Drive request waits for its answer: 30 seconds, and one
/// more for every 50 KB it sends ([bodyBytes]), so a large backup on a slow
/// line is not cut off. They had no time of their own: Drive that took a
/// request and never answered held a backup for good (found in a code
/// audit).
Duration driveAnswerTime([int bodyBytes = 0]) => Duration(seconds: 30 + bodyBytes ~/ (50 * 1024));
