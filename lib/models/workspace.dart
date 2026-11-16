import 'package:zestssh/models/pane_tree.dart';

/// A saved workspace captures the complete desktop layout state.
class Workspace {
  final String id;
  final String name;
  final List<WorkspaceWindow> windows;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  const Workspace({
    required this.id,
    required this.name,
    required this.windows,
    required this.createdAt,
    this.lastUsedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'windows': windows.map((w) => w.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
    'lastUsedAt': lastUsedAt?.toIso8601String(),
  };

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
    id: json['id'] as String,
    name: json['name'] as String,
    windows: (json['windows'] as List)
        .map((w) => WorkspaceWindow.fromJson(w as Map<String, dynamic>))
        .toList(),
    createdAt: DateTime.parse(json['createdAt'] as String),
    lastUsedAt: json['lastUsedAt'] != null
        ? DateTime.parse(json['lastUsedAt'] as String)
        : null,
  );
}

/// A single window within a workspace.
class WorkspaceWindow {
  final double left;
  final double top;
  final double width;
  final double height;
  final PaneNode? paneTree;
  final List<String> connectionIds;
  final bool isMainWindow;

  const WorkspaceWindow({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.paneTree,
    required this.connectionIds,
    this.isMainWindow = true,
  });

  Map<String, dynamic> toJson() => {
    'left': left,
    'top': top,
    'width': width,
    'height': height,
    'paneTree': paneTree?.toJson(),
    'connectionIds': connectionIds,
    'isMainWindow': isMainWindow,
  };

  factory WorkspaceWindow.fromJson(Map<String, dynamic> json) => WorkspaceWindow(
    left: (json['left'] as num).toDouble(),
    top: (json['top'] as num).toDouble(),
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
    paneTree: json['paneTree'] != null
        ? PaneNode.fromJson(json['paneTree'] as Map<String, dynamic>)
        : null,
    connectionIds: (json['connectionIds'] as List).cast<String>(),
    isMainWindow: json['isMainWindow'] as bool? ?? true,
  );
}
