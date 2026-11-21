/// What an AI app asks of the person through ZestSSH's MCP server (4.1),
/// and the path that asks it. The server has no screen of its own: its
/// questions wait in [mcpRequestProvider] and the app answers them on
/// screen, one at a time ([answerMcpRequests]). Nothing answering in time
/// is no.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/mcp/mcp_protocol.dart';
import 'package:zestssh/utils/logger.dart';

/// A question for the person, answered once with yes or no.
sealed class McpRequest {
  McpRequest({required this.caller, required this.hostName});

  /// The AI app, as it named itself.
  final McpCaller caller;

  /// The host the question is about, as the host list shows it.
  final String hostName;

  final _answer = Completer<bool>();

  Future<bool> get answer => _answer.future;

  bool get isOpen => !_answer.isCompleted;

  void reply(bool allowed) {
    if (isOpen) _answer.complete(allowed);
  }
}

/// May the AI app read what this session's terminal shows, while it stays
/// open? Asked once for each session.
class McpReadRequest extends McpRequest {
  McpReadRequest({required super.caller, required super.hostName});
}

/// May the AI app type [command] into this session's terminal and read what
/// it prints? Asked for every command. [dangers] say what the dangerous
/// command check found in it (empty: nothing).
class McpRunRequest extends McpRequest {
  McpRunRequest({required super.caller, required super.hostName, required this.command, this.dangers = const []});

  final String command;
  final List<String> dangers;
}

/// The question waiting for the person, if any.
final mcpRequestProvider = StateProvider<McpRequest?>((ref) => null);

/// How long a question waits.
const kMcpRequestTimeout = Duration(minutes: 2);

/// The pause between one question and the next that waited for it.
const kMcpQuestionGap = Duration(milliseconds: 700);

/// Something that can read providers: a provider's `Ref` or a screen's `WidgetRef`.
typedef McpRead = T Function<T>(ProviderListenable<T> provider);

/// Puts [request] to the person, after any question already open, and waits
/// for the answer; no when none comes in [timeout], and no when [cancelled]
/// completes first (the AI app gave up on its call): the question is taken
/// back, whether it was waiting its turn or on screen.
Future<bool> askMcp(
  McpRead read,
  McpRequest request, {
  Duration timeout = kMcpRequestTimeout,
  Future<void>? cancelled,
}) async {
  if (cancelled != null) {
    unawaited(cancelled.then((_) {
      if (request.isOpen) AppLogger.info('MCP: the AI app gave up on its call; its question is taken back');
      request.reply(false);
    }));
  }
  while (true) {
    if (!request.isOpen) return request.answer;
    final open = read(mcpRequestProvider);
    if (open == null || !open.isOpen) break;
    try {
      await Future.any([open.answer, request.answer]);
    } catch (_) {}
    // After another question: a pause first, so a second click meant for
    // the one before (a double click on Run it) cannot answer this one
    // unread. (Looked at again after it: another question may have come up
    // meanwhile, and goes first.)
    await Future<void>.delayed(kMcpQuestionGap);
  }
  final controller = read(mcpRequestProvider.notifier);
  controller.state = request;
  try {
    return await request.answer.timeout(timeout, onTimeout: () {
      AppLogger.info('MCP: nobody answered in time; taken as no');
      request.reply(false);
      return false;
    });
  } finally {
    if (identical(controller.state, request)) controller.state = null;
  }
}
