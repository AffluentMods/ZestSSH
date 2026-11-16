import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart' show ImportCompatibilityOption;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/windows_programs.dart';
import 'package:zestssh/utils/host_address.dart';

/// Whether PuTTY's saved sessions can be imported here, as on Windows. Null
/// in the app (the system it runs on decides).
@visibleForTesting
bool? debugPuttyImportHere;

/// Whether this device can import PuTTY's saved sessions: they are kept in
/// Windows' registry. Elsewhere nothing offers it (a computer's palette did,
/// and its page said it was for Windows alone).
bool get puttyImportHere => debugPuttyImportHere ?? Platform.isWindows;

/// Screen for importing saved PuTTY sessions from the Windows registry.
///
/// On non-Windows platforms this screen shows an informational message
/// explaining that PuTTY session import is only available on Windows.
class PuttyImportScreen extends ConsumerStatefulWidget {
  const PuttyImportScreen({super.key, this.debugSessions});

  /// Stands in for the registry in tests: each session's name, host, port and
  /// user.
  @visibleForTesting
  final List<(String, String, int, String)>? debugSessions;

  @override
  ConsumerState<PuttyImportScreen> createState() => _PuttyImportScreenState();
}

class _PuttyImportScreenState extends ConsumerState<PuttyImportScreen> {
  bool _isScanning = false;
  List<_PuttyScanResult> _results = [];
  String? _error;
  final Set<int> _selected = {};

  /// Compatibility mode for every session imported (off unless ticked).
  bool _compatibility = false;

  /// A saved session with somewhere to go. Never a leading dash: it reads as an
  /// option (-oProxyCommand) wherever it is passed later.
  static bool _takesHost(String? host) => host != null && host.isNotEmpty && !host.startsWith('-');

  @override
  void initState() {
    super.initState();
    final given = widget.debugSessions;
    if (given != null) {
      _results = [
        for (final (name, host, port, user) in given)
          if (_takesHost(host)) _PuttyScanResult(name: name, host: host, port: port, username: user),
      ];
    } else if (Platform.isWindows) {
      _scanRegistry();
    }
  }

  Future<void> _scanRegistry() async {
    setState(() {
      _isScanning = true;
      _error = null;
    });

    try {
      // Query Windows registry for PuTTY saved sessions
      final result = await Process.run(windowsSystemProgram('reg.exe'), [
        'query',
        r'HKCU\Software\SimonTatham\PuTTY\Sessions',
      ]);

      if (result.exitCode != 0) {
        if (mounted) {
          setState(() {
            _isScanning = false;
            _results = [];
          });
        }
        return;
      }

      final output = result.stdout as String;
      final sessions = <_PuttyScanResult>[];

      // Each sub-key is a session name
      final lines = output.split('\n').where(
            (l) => l.trim().startsWith(r'HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\'),
          );

      for (final line in lines) {
        final trimmed = line.trim();
        // Validate registry path strictly to prevent querying unexpected keys
        if (!trimmed.startsWith(r'HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\')) {
          continue;
        }

        final sessionName = Uri.decodeComponent(
          trimmed.split(r'\').last,
        );
        if (sessionName.isEmpty || sessionName == 'Default%20Settings') continue;

        // Read session details
        final sessionResult = await Process.run(windowsSystemProgram('reg.exe'), [
          'query',
          trimmed,
        ]);

        if (sessionResult.exitCode == 0) {
          final data = sessionResult.stdout as String;
          final host = _extractRegValue(data, 'HostName');
          final port = _extractRegValue(data, 'PortNumber');
          final user = _extractRegValue(data, 'UserName');

          if (_takesHost(host)) {
            sessions.add(_PuttyScanResult(
              name: sessionName,
              host: host!,
              port: int.tryParse(port ?? '22') ?? 22,
              username: user ?? '',
            ));
          }
        }
      }

      if (mounted) {
        setState(() {
          _results = sessions;
          _isScanning = false;
        });
      }
    } catch (e) {
      AppLogger.error('PuTTY registry scan failed', e);
      if (mounted) {
        setState(() {
          _error = AppLocalizations.of(context)!.puttyImportScanFailed;
          _isScanning = false;
        });
      }
    }
  }

  String? _extractRegValue(String regOutput, String valueName) {
    final escaped = RegExp.escape(valueName);
    final regex = RegExp(
      '\\s+$escaped\\s+REG_(SZ|DWORD)\\s+(.+)',
      caseSensitive: false,
    );
    final match = regex.firstMatch(regOutput);
    return match?.group(2)?.trim();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ResponsiveScaffold(
      title: l10n.settingsImportPuttySessions,
      body: _buildBody(context, l10n),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (!Platform.isWindows && widget.debugSessions == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.info,
                  size: 48, color: AppColors.textSecondary),
              const SizedBox(height: 16),
              Text(
                l10n.puttyImportWindowsOnly,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_isScanning) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.alertCircle,
                size: 48, color: AppColors.error),
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: AppColors.error)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _scanRegistry,
              icon: const Icon(LucideIcons.refreshCw),
              label: Text(l10n.retry),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.searchX,
                size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(
              l10n.puttyImportNoSessionsFound,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            l10n.puttyImportFoundSessions(_results.length),
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, index) {
              final session = _results[index];
              final isSelected = _selected.contains(index);

              return CheckboxListTile(
                // Recording mode: the session name is a host label, the
                // subtitle a `user@host:port` composed from typed parts.
                title: RedactedText(Redactable.host(session.name)),
                subtitle: Consumer(
                  builder: (context, ref, _) => Text(
                    '${session.username.isNotEmpty ? '${Redactable.username(session.username).displayIn(ref)}@' : ''}'
                    '${Redactable.address(hostWithPort(session.host, session.port)).displayIn(ref)}',
                  ),
                ),
                value: isSelected,
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selected.add(index);
                    } else {
                      _selected.remove(index);
                    }
                  });
                },
                secondary: const Icon(LucideIcons.terminal),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ImportCompatibilityOption(
            key: const ValueKey('putty-compatibility'),
            value: _compatibility,
            onChanged: (v) => setState(() => _compatibility = v),
          ),
        ),
        if (_results.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (_selected.length == _results.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(
                          List.generate(_results.length, (i) => i),
                        );
                      }
                    });
                  },
                  child: Text(
                    _selected.length == _results.length
                        ? l10n.puttyImportDeselectAll
                        : l10n.puttyImportSelectAll,
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _selected.isEmpty ? null : () => _importSelected(context),
                  icon: const Icon(LucideIcons.download),
                  label: Text(l10n.puttyImportImportSessions(_selected.length)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _importSelected(BuildContext context) async {
    final dao = ref.read(connectionsDaoProvider);
    final now = DateTime.now();
    var imported = 0;

    for (final index in _selected) {
      final session = _results[index];
      try {
        await dao.insertConnection(ConnectionsCompanion.insert(
          id: const Uuid().v4(),
          label: session.name,
          host: session.host,
          port: Value(session.port),
          compatibilityMode: Value(_compatibility),
          createdAt: now,
          updatedAt: now,
        ));
        imported++;
      } catch (e) {
        AppLogger.error('Failed to import PuTTY session: ${session.name}', e);
      }
    }

    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showTopSnackBar(
      context,
      l10n.puttyImportImportedSessions(imported),
      isSuccess: imported > 0,
      isError: imported == 0,
    );
    Navigator.of(context).pop();
  }
}

class _PuttyScanResult {
  final String name;
  final String host;
  final int port;
  final String username;

  const _PuttyScanResult({
    required this.name,
    required this.host,
    required this.port,
    required this.username,
  });
}
