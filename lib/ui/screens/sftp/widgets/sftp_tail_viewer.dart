import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Live `tail -f` viewer for a remote log. Streams new lines as they arrive,
/// auto-scrolling to the bottom until the user scrolls up (scroll-lock), and
/// stops the follow when closed. Reading a log without downloading a dead
/// snapshot.
class SftpTailViewer extends StatefulWidget {
  const SftpTailViewer({
    super.key,
    required this.service,
    required this.path,
    required this.fileName,
    required this.hostLabel,
  });

  final SftpService service;
  final String path;
  final String fileName;
  final String hostLabel;

  static Future<void> show(
    BuildContext context, {
    required SftpService service,
    required String path,
    required String fileName,
    required String hostLabel,
  }) {
    return showZestModal<void>(
      context: context,
      size: ZestModalSize.large,
      child: SftpTailViewer(
        service: service,
        path: path,
        fileName: fileName,
        hostLabel: hostLabel,
      ),
    );
  }

  @override
  State<SftpTailViewer> createState() => _SftpTailViewerState();
}

class _SftpTailViewerState extends State<SftpTailViewer> {
  final List<String> _lines = [];
  final ScrollController _scroll = ScrollController();
  StreamSubscription<String>? _sub;
  Future<void> Function()? _cancel;
  bool _follow = true;
  bool _connecting = true;
  bool _ended = false;

  /// What the program on the host said when the lines ended by themselves
  /// (the file is not there, it may not be read); null where it said nothing.
  String? _said;
  Object? _error;
  StackTrace? _errorStack;

  static const int _maxLines = 5000;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _start();
  }

  Future<void> _start() async {
    try {
      final t = await widget.service.tailFile(widget.path);
      if (!mounted) {
        await t.cancel();
        return;
      }
      _cancel = t.cancel;
      setState(() => _connecting = false);
      unawaited(t.said.then((said) {
        if (mounted && said.isNotEmpty) setState(() => _said = said);
      }));
      _sub = t.lines.listen(
        (line) {
          if (!mounted) return;
          setState(() {
            _lines.add(line);
            if (_lines.length > _maxLines) {
              _lines.removeRange(0, _lines.length - _maxLines);
            }
          });
          if (_follow) _scrollToEnd();
        },
        onDone: () {
          if (mounted) setState(() => _ended = true);
        },
      );
    } catch (e, stack) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = e;
          _errorStack = stack;
        });
      }
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom = _scroll.offset >= _scroll.position.maxScrollExtent - 24;
    if (atBottom != _follow) setState(() => _follow = atBottom);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _cancel?.call();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final live = !_connecting && _error == null && !_ended;
    // The shell (the dialog rules of 3.4): the file and where it is in its
    // head (the host masked in recording mode; the path is not an
    // identifier), the lines, whether they are followed under them, Jump to
    // the end a link in the footer, and Close.
    return Consumer(
      builder: (context, ref, _) => ZestDialogShell(
        size: ZestModalSize.large,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.scrollText,
        title: widget.fileName,
        subtitle: '${Redactable.host(widget.hostLabel).displayIn(ref)}   ${widget.path}',
        bodyScrolls: false,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 440),
                child: _buildBody(),
              ),
            ),
            if (live || _ended) ...[
              const SizedBox(height: 8),
              Row(
                key: const ValueKey('sftp-tail-state'),
                children: [
                  if (live && _follow) ...[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: AppColors.v3TextSecondary, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    _ended ? l10n.sftpTailEnded : (_follow ? l10n.sftpTailFollowing : ''),
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ],
          ],
        ),
        // Scrolled up, off the newest lines: back to them, and following.
        tertiaryKey: const ValueKey('sftp-tail-jump'),
        tertiaryAction: live && !_follow
            ? (
                label: l10n.sftpTailJumpToEnd,
                onPressed: () {
                  setState(() => _follow = true);
                  _scrollToEnd();
                },
              )
            : null,
        primaryAction: (label: l10n.close, icon: null, onPressed: () => Navigator.of(context).pop()),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      // Why, in the app's language, with its report (it was the raw error in
      // a sentence).
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                AppLocalizations.of(context)!.sftpTailStopped(
                    sftpErrorMessage(_error!, name: widget.fileName, op: SftpOp.download)),
                key: const ValueKey('sftp-tail-failed'),
                style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            ErrorDetailsPanel(
              report: ErrorReport.build(
                what: sftpErrorMessage(_error!, op: SftpOp.download),
                where: 'Files: following a file',
                error: _error,
                stack: _errorStack,
              ),
            ),
          ],
        ),
      );
    }
    if (_connecting) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.v3TextSecondary),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          // Behind the lines, where they ended by themselves: why, as the
          // host said it. (It said "Ended", and of a file that may not be
          // read nothing else.)
          itemCount: _lines.length + (_said == null ? 0 : 1),
          itemBuilder: (context, i) => i == _lines.length
              ? Padding(
                  padding: EdgeInsets.only(top: _lines.isEmpty ? 0 : 8),
                  child: Text(
                    AppLocalizations.of(context)!.sftpTailStopped(_said!),
                    key: const ValueKey('sftp-tail-said'),
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.v3TextPrimary),
                  ),
                )
              : Text(
                  _lines[i],
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 11.5,
                    height: 1.4,
                    color: AppColors.textSecondary,
                  ),
                ),
        ),
      ),
    );
  }
}
