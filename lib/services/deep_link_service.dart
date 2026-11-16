import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/utils/logger.dart';

/// Handles incoming deep links with the `zestssh://` scheme and
/// automation intents from external apps (Tasker, Shortcuts, etc.).
///
/// Supported deep links:
/// - `zestssh://connection/new` → New connection screen
/// - `zestssh://connection/edit/<id>` → Edit connection
/// - `zestssh://import/ssh-config` → SSH config import
/// - `zestssh://snippets` → Snippets screen
/// - `zestssh://settings` → Settings screen
/// - `zestssh://connect?host=X&user=Y&port=Z` → Quick connect, with it typed in
///   (answerQuickConnectLink, lib/features/hosts/connect_link.dart)
/// - `zestssh://execute?connection=X&command=Y` → Run command
/// - `zestssh://snippet?connection=X&name=Y` → Run saved snippet
/// - `zestssh://batch?connections=A,B,C&command=Y&timeout=Z&parallel=true`
///   → Run command across multiple connections
/// - `zestssh://workflow?name=X&key=Y` → Run a saved workflow by name or ID
/// - `zestssh://auth/callback` → the account page; it signs nothing in (a
///   computer's sign-in comes back to the app on 127.0.0.1, with a code)
/// - `zestssh://join#CODE` or `zestssh://join?code=CODE` → "Join a team" with
///   the invite code typed in; nothing is asked of anyone until the person
///   continues (answerJoinLink, lib/features/orchards/widgets/join_team.dart)
///
/// Automation intents (Android):
/// - `com.affluentlabs.zestssh.CONNECT` → Verify connection
/// - `com.affluentlabs.zestssh.EXECUTE` → Run command
/// - `com.affluentlabs.zestssh.SNIPPET` → Run saved snippet
/// - `com.affluentlabs.zestssh.WORKFLOW` → Run saved workflow
class DeepLinkService {
  static const _channel = MethodChannel('com.affluentlabs.zestssh/deeplink');

  static final _linkController = StreamController<Uri>.broadcast(onListen: _deliverEarly);

  /// Links that came before the app listened, after the one it opens with
  /// ([initialLink]): handed to it once it listens, in the order they came.
  /// On Windows a second start of the app hands its link to this one, which
  /// may still be starting; such a link was lost. Kept to a few: a page that
  /// fires links by the hundred gets no more answered than these.
  static final _early = <Uri>[];
  static const _maxEarly = 8;

  /// A change of profile: a link that was waiting was for the person who was here.
  static void forgetEarly() {
    _early.clear();
    _initialLink = null;
    _initialAutomation = null;
    _unreadableWaiting = false;
  }

  /// Stream of incoming automation intent payloads.
  static final _automationController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of automation intents from external apps.
  static Stream<Map<String, dynamic>> get automationStream =>
      _automationController.stream;

  /// Security: callback that must approve a deep-link automation request
  /// (execute, snippet, batch, workflow) before it proceeds.
  ///
  /// The caller receives:
  /// - [action]: the automation type ("execute", "snippet", "batch", "workflow")
  /// - [command]: the command or snippet name; for a workflow, the name the
  ///   link gives (may be null)
  /// - [connectionId]: the target connection ID or name; for a batch, every one
  ///   of them, separated by commas; for a workflow, the id the link gives (may
  ///   be null): the question finds the workflow as the run does, by the id
  ///   first
  ///
  /// Must return `true` to allow the automation, or `false` to reject.
  /// If not set, automation deep links are silently blocked - this prevents
  /// drive-by deep links from executing arbitrary commands on user servers.
  /// The app sets it (answerAutomationLinks,
  /// lib/features/automation/automation_link_question.dart).
  static Future<bool> Function(
    String action,
    String? command,
    String? connectionId, [
    Map<String, String> variables,
  ])? onAutomationRequested;

  /// Stream of incoming deep link URIs.
  static Stream<Uri> get linkStream => _linkController.stream;

  /// Initial deep link when the app was cold-started via a deep link.
  static Uri? _initialLink;
  static Uri? get initialLink => _initialLink;

  /// Maximum length of any incoming deep-link URI in bytes.
  /// Defends against malicious 1 MB intent payloads designed to OOM
  /// or to bypass downstream validators with overflow tricks.
  static const int _maxUriBytes = 2048;

  /// A host's share link (`zestssh://share?d=...`) is longer: its `d` is the
  /// whole host in base64, held by [ConnectionShareUrlService] to its own
  /// caps (10 KB of base64, each field 1 KB, 20 forwards). Held to these
  /// here, one with a forward or a few tags (over 256 characters of `d`)
  /// never reached the app.
  static const int _maxShareUriBytes = ConnectionShareUrlService.maxLinkChars;

  /// Length-bound any individual query parameter we accept.
  static const int _maxParamLength = 256;

  /// Validate that a URI string is small enough and parses cleanly.
  /// Returns the parsed [Uri] or null if it should be rejected.
  static Uri? _safeParse(String raw) {
    if (raw.length > _maxShareUriBytes) {
      AppLogger.warning('Deep link rejected: oversize (${raw.length} bytes)');
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme != 'zestssh') return null;
    final share = (uri.host + uri.path) == 'share';
    if (!share && raw.length > _maxUriBytes) {
      AppLogger.warning('Deep link rejected: oversize (${raw.length} bytes)');
      return null;
    }
    // Reject any individual query parameter that exceeds the per-param cap
    // (a session token too: no address of this app takes one). A share
    // link's `d` is the share parser's to cap and read.
    try {
      for (final entry in uri.queryParametersAll.entries) {
        if (share && entry.key == 'd') continue;
        for (final v in entry.value) {
          if (v.length > _maxParamLength) {
            AppLogger.warning(
                'Deep link rejected: oversize query param "${entry.key}"');
            return null;
          }
        }
      }
      // What answers a link reads its parts decoded, the fragment and the
      // path too (a join link's code).
      Uri.decodeComponent(uri.fragment);
      Uri.decodeComponent(uri.path);
    } on ArgumentError {
      _unreadable();
      return null;
    } on FormatException {
      // `zestssh://x?a=%FF`: Uri parses it and throws where its parts are
      // decoded. It came out of DeepLinkService.init(), so any page that opened
      // it while the app was closed got the failed-to-start screen, and Try
      // again read the same link again.
      _unreadable();
      return null;
    }
    return uri;
  }

  /// Whether a link that could not be read waits to be said (nothing listened
  /// when it came).
  static bool _unreadableWaiting = false;

  static final _unreadableLinks = StreamController<void>.broadcast();

  /// A link came that could not be read, and nothing is done with it: the
  /// app says so where it is on screen ([takeUnreadableLink] for one that came
  /// before it listened).
  static Stream<void> get unreadableLinks => _unreadableLinks.stream;

  /// Whether a link that could not be read came before the app listened to
  /// [unreadableLinks]; said once, so the next call is false.
  static bool takeUnreadableLink() {
    final waiting = _unreadableWaiting;
    _unreadableWaiting = false;
    return waiting;
  }

  static void _unreadable() {
    // Not the link: it may carry a key.
    AppLogger.warning('Deep link rejected: it cannot be decoded');
    if (_unreadableLinks.hasListener) {
      _unreadableLinks.add(null);
    } else {
      _unreadableWaiting = true;
    }
  }

  /// [uri] as the app's log names it: what it is, not what it carries (an
  /// automation link's key, a command, a host).
  static String _named(Uri uri) => '${uri.scheme}://${uri.host}${uri.path}';

  /// Cold-start automation payload (if app was launched by an intent).
  static Map<String, dynamic>? _initialAutomation;
  static Map<String, dynamic>? get initialAutomation => _initialAutomation;

  /// Initialise deep link and automation intent handling.
  static Future<void> init() async {
    // Handle incoming links and automation intents when app is running
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDeepLink':
          final uriString = call.arguments as String?;
          if (uriString != null) {
            final uri = _safeParse(uriString);
            if (uri != null) {
              // Not the link itself: an automation link carries its key.
              AppLogger.info('Deep link received: ${_named(uri)}');
              _arrived(uri);
            }
          }
        case 'onAutomation':
          final data = call.arguments;
          if (data is Map) {
            final payload = Map<String, dynamic>.from(data);
            AppLogger.info('Automation intent received: ${payload['action']}');
            _automationController.add(payload);
          }
      }
    });

    // Check for initial link (cold start)
    try {
      final initialUriString =
          await _channel.invokeMethod<String>('getInitialLink');
      if (initialUriString != null) {
        final opened = _safeParse(initialUriString);
        if (opened != null) {
          // The link the app was started for opens first; one that came
          // before it is answered after it.
          final before = _initialLink;
          if (before != null && before != opened) _keepEarly(before);
          _initialLink = opened;
          AppLogger.info('Initial deep link: ${_named(opened)}');
        }
      }
    } on MissingPluginException {
      // Platform channel not available (e.g., desktop)
      AppLogger.info('Deep link channel not available on this platform');
    }

    // Check for cold-start automation intent
    try {
      final initialAuto =
          await _channel.invokeMethod<Map>('getInitialAutomation');
      if (initialAuto != null) {
        _initialAutomation = Map<String, dynamic>.from(initialAuto);
        AppLogger.info(
            'Initial automation intent: ${_initialAutomation!['action']}');
      }
    } on MissingPluginException {
      // Not available on this platform
    }
  }

  /// Convert a `zestssh://` URI to a GoRouter path.
  ///
  /// Returns `null` if the URI is not a valid deep link.
  static String? uriToRoute(Uri uri) {
    if (uri.scheme != 'zestssh') return null;

    final path = uri.host + uri.path;

    switch (path) {
      case 'connection/new':
        return '/connection/edit';
      case 'import/ssh-config':
        return '/import/ssh-config';
      case 'snippets':
        return '/snippets';
      case 'settings':
        return '/settings';
      case 'upgrade':
        return '/upgrade';
      case 'identities':
        return '/identities';
      case 'profile':
        return '/profile';
      case 'connect':
        // zestssh://connect?host=X&user=Y&port=Z → quick connect
        // Query params are preserved in the URI and handled by the caller.
        return '/';
      case 'execute':
        // zestssh://execute?connection=X&command=Y&timeout=Z
        // Handled by extractAutomationParams(); route to home.
        return '/';
      case 'snippet':
        // zestssh://snippet?connection=X&name=Y
        // Handled by extractAutomationParams(); route to home.
        return '/';
      case 'batch':
        // zestssh://batch?connections=A,B,C&command=Y&timeout=Z&parallel=true
        // Handled by extractAutomationParams(); route to home.
        return '/';
      case 'workflow':
        // zestssh://workflow?name=X&key=Y
        // Handled by extractAutomationParams(); route to home.
        return '/';
      case 'auth/callback':
        // zestssh://auth/callback: the account page. It signs nothing in;
        // a computer's sign-in comes back on 127.0.0.1 (N5).
        return '/profile';
      default:
        // Handle connection/edit/<id>
        if (path.startsWith('connection/edit/')) {
          final id = path.substring('connection/edit/'.length);
          if (!RegExp(r'^[a-zA-Z0-9\-]+$').hasMatch(id)) {
            AppLogger.warning('Deep link rejected: invalid connection ID');
            return null;
          }
          return '/connection/edit/$id';
        }
        AppLogger.warning('Unknown deep link path: $path');
        return null;
    }
  }

  /// Extract automation parameters from a `zestssh://execute`,
  /// `zestssh://snippet`, or `zestssh://batch` URI and convert to an
  /// automation payload compatible with the intent-based automation flow.
  ///
  /// Returns null if the URI is not an automation link or if the user
  /// rejects the confirmation prompt.
  ///
  /// Security: all automation deep links require explicit user confirmation
  /// via [onAutomationRequested] before proceeding. If the callback is not
  /// set, automation is silently blocked.
  static Future<Map<String, dynamic>?> extractAutomationParams(Uri uri) async {
    if (uri.scheme != 'zestssh') return null;
    final path = uri.host + uri.path;

    // Security: require explicit user confirmation before executing any
    // automation deep link. This prevents drive-by URIs from silently
    // running commands on the user's servers.
    Future<bool> requireConfirmation(
      String action,
      String? command,
      String? connectionId, [
      Map<String, String> variables = const {},
    ]) async {
      if (onAutomationRequested == null) {
        AppLogger.warning(
          'Automation deep link blocked - '
          'no confirmation callback set (action: $action)',
        );
        return false;
      }
      final approved =
          await onAutomationRequested!(action, command, connectionId, variables);
      if (!approved) {
        // What it would have run stays out of the log: a command can hold a
        // password, and what is logged goes into Copy details.
        AppLogger.info('Automation deep link rejected by user (action: $action)');
      }
      return approved;
    }

    // ── Batch: uses `connections` (comma-separated) instead of a
    // single `connection` parameter.
    if (path == 'batch') {
      final connectionsRaw = uri.queryParameters['connections'] ?? '';
      if (connectionsRaw.isEmpty) {
        AppLogger.warning(
            'Automation deep link missing connections parameter');
        return null;
      }
      // Validate each connection identifier
      final ids = connectionsRaw
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (ids.isEmpty) {
        AppLogger.warning(
            'Automation deep link: no valid connections after parsing');
        return null;
      }
      for (final id in ids) {
        if (RegExp(r'[\x00-\x1f]').hasMatch(id)) {
          AppLogger.warning(
              'Automation deep link rejected: invalid characters in '
              'connection "$id"');
          return null;
        }
      }
      final command = uri.queryParameters['command'];
      if (command == null || command.isEmpty) {
        AppLogger.warning('Automation deep link missing command parameter');
        return null;
      }
      final timeoutStr = uri.queryParameters['timeout'];
      final timeout =
          timeoutStr != null ? int.tryParse(timeoutStr) ?? 30 : 30;
      final parallelStr = uri.queryParameters['parallel'];
      final parallel = parallelStr != 'false'; // default true

      final payload = <String, dynamic>{
        'action': 'batch',
        'connection_ids': ids,
        'command': command,
        'timeout': timeout,
        'parallel': parallel,
      };

      // API key
      final batchKey = uri.queryParameters['key'];
      if (batchKey != null && batchKey.isNotEmpty) payload['key'] = batchKey;

      // Output filter params
      final grep = uri.queryParameters['grep'];
      if (grep != null && grep.isNotEmpty) payload['grep'] = grep;
      final headStr = uri.queryParameters['head'];
      if (headStr != null) {
        final h = int.tryParse(headStr);
        if (h != null) payload['head'] = h;
      }
      final tailStr = uri.queryParameters['tail'];
      if (tailStr != null) {
        final t = int.tryParse(tailStr);
        if (t != null) payload['tail'] = t;
      }

      // SECURITY: deliberately IGNORE any `callback` webhook supplied by the
      // deep link. A deep link is attacker-controllable (QR/link), and the
      // confirmation prompt shows only the command + connection - not where
      // the output goes. Honouring a URL-supplied callback would let a
      // drive-by link exfiltrate command output (e.g. `cat ~/.ssh/id_rsa`) to
      // an attacker endpoint the user never saw. A webhook is honoured only
      // for an Android intent from another app (Tasker), which carries the
      // automation key itself (MainActivity.kt); workflows have no webhook.
      if (uri.queryParameters['callback'] != null) {
        AppLogger.warning(
            'Automation deep link `callback` ignored for security '
            '(a webhook is honoured only for an intent from another app)');
      }

      // The question names every host it runs on.
      if (!await requireConfirmation('batch', command, ids.join(','))) {
        return null;
      }
      return payload;
    }

    // ── Workflow: does not require a connection parameter ──
    if (path == 'workflow') {
      final name = uri.queryParameters['name'];
      final id = uri.queryParameters['id'];
      if ((name == null || name.isEmpty) && (id == null || id.isEmpty)) {
        AppLogger.warning(
            'Automation deep link missing workflow name or id parameter');
        return null; // need name or id
      }
      // Both as the link has them: it was told only the name, so
      // `?name=Harmless&id=<another>` named one workflow and ran the other.
      if (!await requireConfirmation('workflow', name, id)) {
        return null;
      }
      return <String, dynamic>{
        'action': 'workflow',
        if (name != null) 'workflow_name': name,
        if (id != null) 'workflow_id': id,
        'key': uri.queryParameters['key'],
      };
    }

    // ── Single-connection actions (execute, snippet, etc.) ──
    final connectionId = uri.queryParameters['connection'] ??
        uri.queryParameters['connection_id'] ??
        uri.queryParameters['host'] ??
        '';

    if (connectionId.isEmpty) {
      AppLogger.warning('Automation deep link missing connection parameter');
      return null;
    }

    // Validate connection identifier
    if (RegExp(r'[\x00-\x1f]').hasMatch(connectionId)) {
      AppLogger.warning('Automation deep link rejected: invalid characters');
      return null;
    }

    switch (path) {
      case 'execute':
        final command = uri.queryParameters['command'];
        if (command == null || command.isEmpty) {
          AppLogger.warning('Automation deep link missing command parameter');
          return null;
        }
        final timeoutStr = uri.queryParameters['timeout'];
        final timeout =
            timeoutStr != null ? int.tryParse(timeoutStr) ?? 30 : 30;

        final execPayload = <String, dynamic>{
          'action': 'execute',
          'connection_id': connectionId,
          'command': command,
          'timeout': timeout,
        };

        // API key
        final execKey = uri.queryParameters['key'];
        if (execKey != null && execKey.isNotEmpty) {
          execPayload['key'] = execKey;
        }

        // Output filter params
        final execGrep = uri.queryParameters['grep'];
        if (execGrep != null && execGrep.isNotEmpty) {
          execPayload['grep'] = execGrep;
        }
        final execHeadStr = uri.queryParameters['head'];
        if (execHeadStr != null) {
          final h = int.tryParse(execHeadStr);
          if (h != null) execPayload['head'] = h;
        }
        final execTailStr = uri.queryParameters['tail'];
        if (execTailStr != null) {
          final t = int.tryParse(execTailStr);
          if (t != null) execPayload['tail'] = t;
        }

        // SECURITY: ignore any URL-supplied `callback` webhook - see the
        // batch handler above. A deep link must not be able to nominate an
        // exfiltration endpoint that the confirmation prompt doesn't show.
        if (uri.queryParameters['callback'] != null) {
          AppLogger.warning(
              'Automation deep link `callback` ignored for security '
              '(a webhook is honoured only for an intent from another app)');
        }

        if (!await requireConfirmation('execute', command, connectionId)) {
          return null;
        }
        return execPayload;

      case 'snippet':
        final name = uri.queryParameters['name'] ??
            uri.queryParameters['snippet_name'];
        if (name == null || name.isEmpty) {
          AppLogger.warning(
              'Automation deep link missing snippet name parameter');
          return null;
        }
        final payload = <String, dynamic>{
          'action': 'snippet',
          'connection_id': connectionId,
          'snippet_name': name,
        };
        // API key
        final snippetKey = uri.queryParameters['key'];
        if (snippetKey != null && snippetKey.isNotEmpty) {
          payload['key'] = snippetKey;
        }
        // Extract var_ prefixed query parameters as snippet variables.
        // e.g. ?var_branch=main → payload key "var_branch" = "main",
        // which the automation provider strips to {"branch": "main"}.
        for (final entry in uri.queryParameters.entries) {
          if (entry.key.startsWith('var_') && entry.key.length > 4) {
            payload[entry.key] = entry.value;
          }
        }
        // The question shows the snippet's command with these values, as
        // it runs (it showed the command without them: found 16 October
        // 2026 in the client's security review).
        final variables = {
          for (final entry in uri.queryParameters.entries)
            if (entry.key.startsWith('var_') && entry.key.length > 4) entry.key.substring(4): entry.value,
        };
        if (!await requireConfirmation('snippet', name, connectionId, variables)) {
          return null;
        }
        return payload;

      default:
        return null;
    }
  }

  /// Inject a deep link from an external source (e.g. command-line args).
  static void injectLink(Uri uri) {
    final validated = _safeParse(uri.toString());
    if (validated != null) {
      _arrived(validated);
      AppLogger.info('Injected deep link: ${_named(validated)}');
    }
  }

  /// [uri] to the app: at once when it listens; before that, the link it
  /// opens with ([initialLink]) or, when it has one, kept until it listens
  /// ([_early]).
  static void _arrived(Uri uri) {
    if (_linkController.hasListener) {
      _linkController.add(uri);
    } else if (_initialLink == null) {
      _initialLink = uri;
    } else {
      _keepEarly(uri);
    }
  }

  static void _keepEarly(Uri uri) {
    if (_early.length < _maxEarly) {
      _early.add(uri);
    } else {
      AppLogger.warning('Deep link dropped: too many before the app listened');
    }
  }

  /// The links kept before the app listened, to it now it does (once the
  /// listener is in place).
  static void _deliverEarly() {
    if (_early.isEmpty) return;
    final waiting = List.of(_early);
    _early.clear();
    scheduleMicrotask(() {
      for (final uri in waiting) {
        _linkController.add(uri);
      }
    });
  }

  /// Send an automation result back to the calling app.
  static Future<void> setAutomationResult({
    required String stdout,
    required int exitCode,
  }) async {
    try {
      await _channel.invokeMethod('setAutomationResult', {
        'stdout': stdout,
        'exit_code': exitCode,
      });
    } catch (e) {
      AppLogger.warning('Failed to set automation result: $e');
    }
  }

  /// Forgets the link the app opened with, for tests that start it again.
  @visibleForTesting
  static void debugForgetInitialLink() {
    _initialLink = null;
    _early.clear();
    _unreadableWaiting = false;
  }

  static void dispose() {
    _linkController.close();
    _automationController.close();
    _unreadableLinks.close();
  }
}
