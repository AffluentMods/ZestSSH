import 'dart:async';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/terminal_paste.dart';
import 'package:zestssh/models/redactable.dart';

/// Data class passed via route extras to [SessionReplayScreen].
class SessionReplayData {
  final String sessionId;
  final String connectionLabel;
  final DateTime startedAt;
  final List<RecordingEntry> entries;

  const SessionReplayData({
    required this.sessionId,
    required this.connectionLabel,
    required this.startedAt,
    required this.entries,
  });

  /// Total duration of the recording.
  Duration get duration =>
      entries.isNotEmpty ? entries.last.timestamp : Duration.zero;
}

/// Screen that replays a recorded terminal session.
///
/// Uses a [Terminal] to render the output frame-by-frame with
/// play/pause, speed control, and a seek slider.
class SessionReplayScreen extends StatefulWidget {
  final SessionReplayData data;

  const SessionReplayScreen({super.key, required this.data});

  @override
  State<SessionReplayScreen> createState() => _SessionReplayScreenState();
}

class _SessionReplayScreenState extends State<SessionReplayScreen> {
  late final Terminal _terminal;
  final TerminalController _terminalController = TerminalController();
  final _copyOnRelease = CopyOnRelease();
  Timer? _playTimer;
  int _currentIndex = 0;
  bool _isPlaying = false;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 5000);
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    _terminalController.dispose();
    super.dispose();
  }

  void _play() {
    if (_currentIndex >= widget.data.entries.length) {
      _currentIndex = 0;
      _terminal.buffer.clear();
    }

    setState(() => _isPlaying = true);
    _scheduleNextEntry();
  }

  void _pause() {
    _playTimer?.cancel();
    setState(() => _isPlaying = false);
  }

  void _stop() {
    _playTimer?.cancel();
    _terminal.buffer.clear();
    setState(() {
      _isPlaying = false;
      _currentIndex = 0;
    });
  }

  void _scheduleNextEntry() {
    if (_currentIndex >= widget.data.entries.length) {
      setState(() => _isPlaying = false);
      return;
    }

    final entry = widget.data.entries[_currentIndex];
    final prevTimestamp = _currentIndex > 0
        ? widget.data.entries[_currentIndex - 1].timestamp
        : Duration.zero;

    final delay = (entry.timestamp - prevTimestamp) * (1 / _speed);
    // Cap max delay at 2 seconds to keep replay snappy
    final cappedDelay = delay > const Duration(seconds: 2)
        ? const Duration(seconds: 2)
        : delay;

    _playTimer = Timer(cappedDelay, () {
      if (!mounted) return;
      _terminal.write(entry.data);
      _currentIndex++;
      setState(() {});
      _scheduleNextEntry();
    });
  }

  void _seekTo(int index) {
    _playTimer?.cancel();
    _terminal.buffer.clear();

    // Replay all entries up to index
    for (var i = 0; i <= index && i < widget.data.entries.length; i++) {
      _terminal.write(widget.data.entries[i].data);
    }

    setState(() {
      _currentIndex = index + 1;
      _isPlaying = false;
    });
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$m:$s';
    }
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final totalDuration = widget.data.duration;
    final currentTime = _currentIndex > 0 && _currentIndex <= widget.data.entries.length
        ? widget.data.entries[_currentIndex - 1].timestamp
        : Duration.zero;

    final l10n = AppLocalizations.of(context)!;
    // In the person's language, and with no dash (it read "web-01 - Replay"
    // in every language, as the screenshot tests showed).
    final host = Redactable.host(widget.data.connectionLabel);
    return ResponsiveScaffold(
      title: host.isEmpty ? l10n.replayTitleNoHost : l10n.replayTitle(host.display),
      actions: [
        // Speed control
        PopupMenuButton<double>(
          icon: const Icon(LucideIcons.gauge),
          tooltip: AppLocalizations.of(context)!.replayPlaybackSpeed,
          onSelected: (speed) {
            setState(() => _speed = speed);
          },
          itemBuilder: (_) => [
            for (final s in [0.5, 1.0, 2.0, 4.0, 8.0])
              PopupMenuItem(
                value: s,
                child: Text(
                  '${s}x',
                  style: TextStyle(
                    fontWeight: s == _speed ? FontWeight.bold : null,
                    color: s == _speed ? AppColors.accentInk : null,
                  ),
                ),
              ),
          ],
        ),
      ],
      body: Column(
        children: [
          // Terminal
          Expanded(
            child: Container(
              color: Colors.black,
              child: Consumer(
                builder: (context, ref, _) => Listener(
                  onPointerDown: _copyOnRelease.down,
                  onPointerUp: (e) {
                    // PuTTY-style copy on highlight - here it copies text out
                    // of a recorded session, a mouse's selection alone.
                    if (!_copyOnRelease.up(e)) return;
                    copySelectionIfEnabled(ref, _terminal, _terminalController);
                  },
                  child: TerminalView(
                    _terminal,
                    controller: _terminalController,
                    readOnly: true,
                    cursorBlink: ref.watch(cursorBlinkProvider),
                  ),
                ),
              ),
            ),
          ),

          // Controls bar
          Container(
            color: AppColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                // Seek slider
                if (widget.data.entries.isNotEmpty)
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      value: _currentIndex
                          .clamp(0, widget.data.entries.length)
                          .toDouble(),
                      max: widget.data.entries.length.toDouble(),
                      activeColor: AppColors.brandOrange,
                      onChanged: (v) => _seekTo(v.toInt().clamp(
                            0,
                            widget.data.entries.length - 1),
                          ),
                    ),
                  ),

                // Time + play controls
                Row(
                  children: [
                    Text(
                      _formatDuration(currentTime),
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(LucideIcons.square),
                      tooltip: AppLocalizations.of(context)!.runOnHostsStop,
                      onPressed: _currentIndex > 0 ? _stop : null,
                    ),
                    IconButton(
                      icon: Icon(_isPlaying ? LucideIcons.pause : LucideIcons.play),
                      tooltip: _isPlaying ? l10n.replayPause : l10n.replayPlay,
                      onPressed: _isPlaying ? _pause : _play,
                      color: AppColors.accentInk,
                      iconSize: 32,
                    ),
                    const Spacer(),
                    Text(
                      _formatDuration(totalDuration),
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
