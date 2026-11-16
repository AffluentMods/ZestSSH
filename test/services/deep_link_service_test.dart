import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/deep_link_service.dart';

void main() {
  // ── uriToRoute ───────────────────────────────────────────────────

  group('DeepLinkService.uriToRoute', () {
    group('valid navigation routes', () {
      test('connection/new maps to /connection/edit', () {
        final uri = Uri.parse('zestssh://connection/new');
        expect(DeepLinkService.uriToRoute(uri), '/connection/edit');
      });

      test('snippets maps to /snippets', () {
        final uri = Uri.parse('zestssh://snippets');
        expect(DeepLinkService.uriToRoute(uri), '/snippets');
      });

      test('settings maps to /settings', () {
        final uri = Uri.parse('zestssh://settings');
        expect(DeepLinkService.uriToRoute(uri), '/settings');
      });

      test('upgrade maps to /upgrade', () {
        final uri = Uri.parse('zestssh://upgrade');
        expect(DeepLinkService.uriToRoute(uri), '/upgrade');
      });

      test('identities maps to /identities', () {
        final uri = Uri.parse('zestssh://identities');
        expect(DeepLinkService.uriToRoute(uri), '/identities');
      });

      test('profile maps to /profile', () {
        final uri = Uri.parse('zestssh://profile');
        expect(DeepLinkService.uriToRoute(uri), '/profile');
      });
    });

    group('automation routes map to home', () {
      test('connect maps to /', () {
        final uri = Uri.parse('zestssh://connect?host=example.com&user=root');
        expect(DeepLinkService.uriToRoute(uri), '/');
      });

      test('execute maps to /', () {
        final uri = Uri.parse(
            'zestssh://execute?connection=myserver&command=uptime');
        expect(DeepLinkService.uriToRoute(uri), '/');
      });

      test('snippet maps to /', () {
        final uri = Uri.parse(
            'zestssh://snippet?connection=myserver&name=deploy');
        expect(DeepLinkService.uriToRoute(uri), '/');
      });

      test('batch maps to /', () {
        final uri = Uri.parse(
            'zestssh://batch?connections=a,b,c&command=uptime');
        expect(DeepLinkService.uriToRoute(uri), '/');
      });
    });

    group('connection/edit with ID', () {
      test('valid alphanumeric ID is accepted', () {
        final uri = Uri.parse('zestssh://connection/edit/abc-123');
        expect(
          DeepLinkService.uriToRoute(uri),
          '/connection/edit/abc-123',
        );
      });

      test('valid UUID-style ID is accepted', () {
        final uri = Uri.parse(
            'zestssh://connection/edit/550e8400-e29b-41d4-a716-446655440000');
        expect(
          DeepLinkService.uriToRoute(uri),
          '/connection/edit/550e8400-e29b-41d4-a716-446655440000',
        );
      });

      test('ID with injection characters is rejected', () {
        final uri = Uri.parse('zestssh://connection/edit/id;DROP TABLE');
        expect(DeepLinkService.uriToRoute(uri), isNull);
      });

      test('ID with slashes is rejected', () {
        final uri = Uri.parse('zestssh://connection/edit/../../etc/passwd');
        // The path parsing splits on slashes so this won't match the
        // startsWith check correctly, yielding null.
        expect(DeepLinkService.uriToRoute(uri), isNull);
      });

      test('ID with special characters is rejected', () {
        final uri = Uri.parse('zestssh://connection/edit/id<script>');
        expect(DeepLinkService.uriToRoute(uri), isNull);
      });
    });

    group('invalid routes', () {
      test('non-zestssh scheme returns null', () {
        final uri = Uri.parse('https://connection/new');
        expect(DeepLinkService.uriToRoute(uri), isNull);
      });

      test('unknown path returns null', () {
        final uri = Uri.parse('zestssh://nonexistent');
        expect(DeepLinkService.uriToRoute(uri), isNull);
      });

      test('empty path returns null', () {
        final uri = Uri.parse('zestssh://');
        expect(DeepLinkService.uriToRoute(uri), isNull);
      });
    });

    test('auth/callback maps to /profile', () {
      final uri = Uri.parse('zestssh://auth/callback?token=abc123');
      expect(DeepLinkService.uriToRoute(uri), '/profile');
    });

    test('import/ssh-config maps correctly', () {
      final uri = Uri.parse('zestssh://import/ssh-config');
      expect(DeepLinkService.uriToRoute(uri), '/import/ssh-config');
    });
  });

  // ── extractAutomationParams ──────────────────────────────────────

  group('DeepLinkService.extractAutomationParams', () {
    // Install an auto-approving callback so happy-path tests pass.
    // Individual tests override this when testing rejection behaviour.
    setUp(() {
      DeepLinkService.onAutomationRequested = (_, __, ___, [variables = const {}]) async => true;
    });

    tearDown(() {
      DeepLinkService.onAutomationRequested = null;
    });

    group('execute action', () {
      test('extracts all parameters', () async {
        final uri = Uri.parse(
          'zestssh://execute?connection=myserver&command=uptime'
          '&timeout=60&grep=load&head=5&tail=2'
          '&callback=https://hooks.example.com/result',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);

        expect(result, isNotNull);
        expect(result!['action'], 'execute');
        expect(result['connection_id'], 'myserver');
        expect(result['command'], 'uptime');
        expect(result['timeout'], 60);
        expect(result['grep'], 'load');
        expect(result['head'], 5);
        expect(result['tail'], 2);
        // SECURITY (1.5.35): a URL-supplied `callback` webhook is
        // deliberately ignored - honouring it would let a drive-by link
        // exfiltrate command output to an endpoint the user never sees.
        expect(result['callback'], isNull);
      });

      test('uses default timeout of 30 when not specified', () async {
        final uri = Uri.parse(
          'zestssh://execute?connection=srv&command=ls',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);

        expect(result, isNotNull);
        expect(result!['timeout'], 30);
      });

      test('uses default timeout when timeout is not parseable', () async {
        final uri = Uri.parse(
          'zestssh://execute?connection=srv&command=ls&timeout=abc',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);

        expect(result, isNotNull);
        expect(result!['timeout'], 30);
      });

      test('returns null when command is missing', () async {
        final uri = Uri.parse('zestssh://execute?connection=srv');
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });
    });

    group('snippet action', () {
      test('extracts snippet name and connection', () async {
        final uri = Uri.parse(
          'zestssh://snippet?connection=prod&name=deploy',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);

        expect(result, isNotNull);
        expect(result!['action'], 'snippet');
        expect(result['connection_id'], 'prod');
        expect(result['snippet_name'], 'deploy');
      });

      test('extracts var_ prefixed variables', () async {
        final uri = Uri.parse(
          'zestssh://snippet?connection=prod&name=deploy'
          '&var_branch=main&var_env=staging',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);

        expect(result, isNotNull);
        expect(result!['var_branch'], 'main');
        expect(result['var_env'], 'staging');
      });

      test('ignores non-var_ query params besides known ones', () async {
        final uri = Uri.parse(
          'zestssh://snippet?connection=prod&name=deploy&random=ignored',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);

        expect(result, isNotNull);
        expect(result!.containsKey('random'), isFalse);
      });

      test('returns null when snippet name is missing', () async {
        final uri = Uri.parse('zestssh://snippet?connection=prod');
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('accepts snippet_name as alternative param', () async {
        final uri = Uri.parse(
          'zestssh://snippet?connection=prod&snippet_name=restart',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);
        expect(result, isNotNull);
        expect(result!['snippet_name'], 'restart');
      });
    });

    group('batch action', () {
      test('parses comma-separated connections', () async {
        final uri = Uri.parse(
          'zestssh://batch?connections=web1,web2,db1&command=uptime',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);

        expect(result, isNotNull);
        expect(result!['action'], 'batch');
        expect(result['connection_ids'], ['web1', 'web2', 'db1']);
        expect(result['command'], 'uptime');
        expect(result['parallel'], isTrue);
      });

      test('parallel defaults to true', () async {
        final uri = Uri.parse(
          'zestssh://batch?connections=a,b&command=ls',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);
        expect(result!['parallel'], isTrue);
      });

      test('parallel=false is respected', () async {
        final uri = Uri.parse(
          'zestssh://batch?connections=a,b&command=ls&parallel=false',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);
        expect(result!['parallel'], isFalse);
      });

      test('returns null when connections param is empty', () async {
        final uri = Uri.parse('zestssh://batch?connections=&command=ls');
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('returns null when command is missing', () async {
        final uri = Uri.parse('zestssh://batch?connections=a,b');
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('trims whitespace in connection IDs', () async {
        final uri = Uri.parse(
          'zestssh://batch?connections=a,%20b%20,c&command=ls',
        );
        final result =
            await DeepLinkService.extractAutomationParams(uri);
        expect(result, isNotNull);
        expect(result!['connection_ids'], ['a', 'b', 'c']);
      });
    });

    group('confirmation callback', () {
      test('blocks automation when callback is null', () async {
        DeepLinkService.onAutomationRequested = null;
        final uri = Uri.parse(
          'zestssh://execute?connection=srv&command=ls',
        );
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('blocks automation when user rejects', () async {
        DeepLinkService.onAutomationRequested = (_, __, ___, [variables = const {}]) async => false;
        final uri = Uri.parse(
          'zestssh://execute?connection=srv&command=ls',
        );
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('passes action, command, and connectionId to callback', () async {
        String? capturedAction;
        String? capturedCommand;
        String? capturedConnectionId;
        DeepLinkService.onAutomationRequested =
            (action, command, connectionId, [variables = const {}]) async {
          capturedAction = action;
          capturedCommand = command;
          capturedConnectionId = connectionId;
          return true;
        };
        final uri = Uri.parse(
          'zestssh://execute?connection=myhost&command=uptime',
        );
        await DeepLinkService.extractAutomationParams(uri);
        expect(capturedAction, 'execute');
        expect(capturedCommand, 'uptime');
        expect(capturedConnectionId, 'myhost');
      });
    });

    group('missing required params', () {
      test('returns null when connection is missing for execute', () async {
        final uri = Uri.parse('zestssh://execute?command=ls');
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('returns null when connection is missing for snippet', () async {
        final uri = Uri.parse('zestssh://snippet?name=deploy');
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('returns null for non-automation paths', () async {
        final uri = Uri.parse('zestssh://settings');
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('returns null for non-zestssh scheme', () async {
        final uri = Uri.parse('https://execute?connection=a&command=ls');
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });
    });

    group('control character rejection', () {
      test('rejects connection ID with control characters', () async {
        final uri = Uri.parse(
          'zestssh://execute?connection=srv%00injected&command=ls',
        );
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('rejects batch connection ID with control characters', () async {
        final uri = Uri.parse(
          'zestssh://batch?connections=ok,bad%0Ainjected&command=ls',
        );
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('rejects connection with newline', () async {
        final uri = Uri.parse(
          'zestssh://execute?connection=a%0Ab&command=ls',
        );
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });

      test('rejects connection with tab', () async {
        final uri = Uri.parse(
          'zestssh://execute?connection=a%09b&command=ls',
        );
        expect(
          await DeepLinkService.extractAutomationParams(uri),
          isNull,
        );
      });
    });
  });
}
