import 'dart:async';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/keyboard_lock_warning.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';

/// Shows queued server questions one at a time until none are left or the
/// caller goes away. A dialog torn down without an answer (its page was
/// replaced, for example by the lock screen) leaves its question queued for
/// the next pending check, so nothing is lost and nothing is answered
/// without the person.
Future<void> showServerQuestions(
  BuildContext context,
  WidgetRef ref, {
  required bool Function() isMounted,
}) async {
  ServerQuestionRequest? next() => ref.read(serverQuestionProvider);
  var request = next();
  while (request != null && isMounted()) {
    final current = request;
    if (current.isOpen) {
      try {
        await Future.any<void>([
          showServerQuestionDialog(context, current),
          // Withdrawn while showing: the dialog closes itself.
          current.answer.then((_) {}),
        ]);
      } catch (e) {
        AppLogger.error('Failed to show a server question', e);
        current.cancel();
      }
      if (current.isOpen) break;
    }
    ref.read(serverQuestionQueueProvider.notifier).remove(current);
    request = next();
  }
}

/// Shows one server question ([request]) as the app's dialog (a phone's
/// sheet), until it is answered, cancelled or withdrawn. Escape and a tap
/// outside leave it, as every answer is a button (the close button is
/// Cancel); one taken away unanswered (its page replaced) leaves the
/// question open.
Future<void> showServerQuestionDialog(BuildContext context, ServerQuestionRequest request) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    barrierDismissible: false,
    onDismissAttempt: () async => false,
    useRootNavigator: true,
    child: ServerQuestionDialog(request: request),
  );
}

/// A server's keyboard-interactive question (a one-time code, a new password)
/// for the person to answer.
///
/// Everything shown comes from the server, and the dialog says so: a hostile
/// server can ask for anything, so nothing is ever filled in. Secret answers
/// (the server's echo flag off) are hidden, keep out of keyboard learning,
/// and are revealed only through the recording-mode gate. The dialog closes
/// itself when the question is withdrawn (the sign-in ended or timed out).
class ServerQuestionDialog extends StatefulWidget {
  const ServerQuestionDialog({super.key, required this.request});

  final ServerQuestionRequest request;

  @override
  State<ServerQuestionDialog> createState() => _ServerQuestionDialogState();
}

class _ServerQuestionDialogState extends State<ServerQuestionDialog> {
  late final List<TextEditingController> _controllers;
  late final List<FocusNode> _focusNodes;
  late final List<bool> _hidden;
  bool _finished = false;

  List<ServerPrompt> get _prompts => widget.request.question.prompts;

  @override
  void initState() {
    super.initState();
    _controllers = [for (final _ in _prompts) TextEditingController()];
    _focusNodes = [for (final _ in _prompts) FocusNode()];
    _hidden = [for (final p in _prompts) !p.echo];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNodes.isNotEmpty) _focusNodes.first.requestFocus();
    });
    // Withdrawn (the sign-in ended, or nobody answered in time): close.
    widget.request.answer.then((_) {
      if (!_finished && mounted) _close();
    });
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  void _close() {
    _finished = true;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  void _send() {
    if (_finished) return;
    widget.request.reply([for (final c in _controllers) c.text]);
    _close();
  }

  void _cancel() {
    if (_finished) return;
    widget.request.cancel();
    _close();
  }

  void _submitted(int index) {
    if (index + 1 < _focusNodes.length) {
      _focusNodes[index + 1].requestFocus();
    } else {
      _send();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final request = widget.request;
    final question = request.question;

    // The app's dialog (the dialog rules, 3.4): neutral, one footer (Cancel,
    // Send); the close button cancels, as Cancel does.
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.messageSquare,
      title: l10n.serverQuestionTitle,
      maxWidth: 500,
      onClose: _cancel,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Recording mode: `user@host` goes through the free-text rule,
          // as in the password prompt.
          RedactedText(
            Redactable.freeText('${request.username}@${request.host}'),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
              color: AppColors.v3TextSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.serverQuestionFromServer,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: AppColors.v3TextSecondary,
            ),
          ),
          if (question.name.isNotEmpty) ...[
            const SizedBox(height: 14),
            RedactedText(
              Redactable.freeText(question.name),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.v3TextPrimary,
              ),
            ),
          ],
          if (question.instruction.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 160),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.v3Background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.v3BorderSubtle),
              ),
              child: SingleChildScrollView(
                child: RedactedText(
                  Redactable.freeText(question.instruction),
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12.5,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
              ),
            ),
          ],
          for (var i = 0; i < _prompts.length; i++) ...[
            const SizedBox(height: 14),
            RedactedText(
              Redactable.freeText(_prompts[i].text.isEmpty
                  ? l10n.serverQuestionAnswer
                  : _prompts[i].text),
              style: TextStyle(
                fontSize: 13,
                color: AppColors.v3TextPrimary,
              ),
            ),
            const SizedBox(height: 6),
            _field(i, l10n),
          ],
          // Caps/Num-lock advisory for hidden answers (desktop only).
          if (_prompts.any((p) => !p.echo)) const KeyboardLockWarning(),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: _cancel),
      primaryAction: (label: l10n.serverQuestionSend, icon: null, onPressed: _send),
    );
  }

  Widget _field(int i, AppLocalizations l10n) {
    final secret = !_prompts[i].echo;
    final last = i == _prompts.length - 1;
    return TextField(
      controller: _controllers[i],
      focusNode: _focusNodes[i],
      obscureText: _hidden[i],
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 14),
      decoration: InputDecoration(
        filled: true,
        fillColor: AppColors.v3Background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.v3BorderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.v3BorderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.v3AccentPrimary, width: 1.2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        suffixIcon: secret
            ? IconButton(
                tooltip: _hidden[i]
                    ? l10n.serverQuestionShowAnswer
                    : l10n.serverQuestionHideAnswer,
                icon: Icon(
                  _hidden[i] ? LucideIcons.eye : LucideIcons.eyeOff,
                  size: 16,
                  color: AppColors.v3TextTertiary,
                ),
                onPressed: () async {
                  // Revealing an answer while recording mode is on.
                  if (_hidden[i] &&
                      !await confirmRevealWhileRecording(context)) {
                    return;
                  }
                  if (!mounted) return;
                  setState(() => _hidden[i] = !_hidden[i]);
                },
              )
            : null,
      ),
      onSubmitted: (_) => _submitted(i),
    );
  }
}
