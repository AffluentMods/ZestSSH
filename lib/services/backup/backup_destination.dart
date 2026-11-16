import 'dart:io';

/// Metadata for a backup file stored in a [BackupDestination].
class BackupFileInfo {
  final String filename;
  final DateTime createdAt;
  final int sizeBytes;

  /// Which destination this file lives in (matches [BackupDestination.id]).
  final String destinationId;

  const BackupFileInfo({
    required this.filename,
    required this.createdAt,
    required this.sizeBytes,
    required this.destinationId,
  });

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'createdAt': createdAt.toIso8601String(),
        'sizeBytes': sizeBytes,
        'destinationId': destinationId,
      };

  factory BackupFileInfo.fromJson(Map<String, dynamic> json) {
    return BackupFileInfo(
      filename: json['filename'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      sizeBytes: json['sizeBytes'] as int,
      destinationId: json['destinationId'] as String,
    );
  }
}

/// Health status for a single backup destination.
class DestinationHealthStatus {
  final String destinationId;
  final String destinationName;
  final bool isAuthenticated;
  final DateTime? lastSuccessfulBackup;
  final int consecutiveFailures;
  final String? lastError;

  const DestinationHealthStatus({
    required this.destinationId,
    required this.destinationName,
    required this.isAuthenticated,
    this.lastSuccessfulBackup,
    this.consecutiveFailures = 0,
    this.lastError,
  });

  bool get isHealthy => isAuthenticated && consecutiveFailures == 0;
}

/// Aggregate health across all configured destinations.
class BackupHealthStatus {
  final List<DestinationHealthStatus> destinations;

  const BackupHealthStatus({required this.destinations});

  bool get allHealthy => destinations.every((d) => d.isHealthy);
  int get healthyCount => destinations.where((d) => d.isHealthy).length;
  int get totalCount => destinations.length;
}

/// Abstract backup destination for auto-backups.
///
/// Each implementation handles upload, download, listing, and deletion
/// of `.zest` backup files at a specific storage location (local disk,
/// WebDAV server, cloud provider, etc.).
abstract class BackupDestination {
  /// Unique identifier for this destination instance (e.g. 'local',
  /// 'webdav_nextcloud_home').
  String get id;

  /// Machine-readable type key (e.g. 'local', 'webdav', 'google_drive').
  String get name;

  /// Human-readable label shown in the UI.
  String get displayName;

  /// Whether backups survive an app uninstall. Local storage on Android
  /// does NOT survive uninstall; WebDAV/cloud destinations do.
  bool get survivesUninstall;

  /// Whether the destination is currently authenticated and reachable.
  Future<bool> isAuthenticated();

  /// Trigger any authentication flow needed (OAuth, credential prompt, etc.).
  /// No-op for destinations that are always authenticated (e.g. local).
  Future<void> authenticate();

  /// Upload a backup file to this destination.
  Future<void> uploadBackup(File file, String filename);

  /// List all `.zest` backup files at this destination.
  Future<List<BackupFileInfo>> listBackups();

  /// Download a backup file to [localPath] and return the local [File].
  Future<File> downloadBackup(String filename, String localPath);

  /// Delete a backup file from this destination.
  Future<void> deleteBackup(String filename);

  /// Serialize destination configuration for persistence.
  Map<String, dynamic> toJson();

  /// Deserialize a destination from persisted configuration.
  /// Implementations register themselves in [BackupDestination.fromJson].
  static BackupDestination fromJson(Map<String, dynamic> json) {
    // Lazy import avoidance - we switch on the 'name' key.
    // Concrete factories are registered in backup_destination_registry.dart.
    throw UnsupportedError(
      'Use BackupDestinationRegistry.fromJson() instead. '
      'Direct BackupDestination.fromJson is not supported.',
    );
  }
}
