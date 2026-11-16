import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A host whose files were asked for before it was connected (a phone's
/// host sheet, Files): its terminal opens them once its session is up, as
/// [tmuxPendingConnectionProvider] does for tmux.
final sftpPendingConnectionProvider = StateProvider<String?>((ref) => null);
