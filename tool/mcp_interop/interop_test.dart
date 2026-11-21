// Drives ZestSSH's MCP server (lib/features/mcp) with the official MCP client
// SDKs: the real McpServer and McpProtocol on 127.0.0.1 (port 0, a test
// token) with four stand-in tools, no app and no database. Not part of the
// app's test suite (it needs Node and Python and the SDKs installed here):
// see README.md.
//
//   flutter test --no-pub tool/mcp_interop/interop_test.dart
//
// Each client prints a JSON report of its steps; this checks every step went
// as the protocol says, and records what reached the server (the revision on
// each request) in build/mcp_interop/report.json.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/mcp/mcp_protocol.dart';
import 'package:zestssh/features/mcp/mcp_server.dart';

const _token = 'zmcp_interop-test-token';
const _dir = 'tool/mcp_interop';

/// What reached the server: one line per HTTP request.
class _Seen {
  _Seen(this.httpMethod, this.rpcMethod, this.headerVersion, this.metaVersion, this.status);

  final String httpMethod;
  final String? rpcMethod;
  final String? headerVersion;
  final String? metaVersion;
  final int status;

  Map<String, Object?> toJson() => {
        'http': httpMethod,
        'method': rpcMethod,
        'MCP-Protocol-Version': headerVersion,
        '_meta version': metaVersion,
        'status': status,
      };
}

/// The real protocol, writing down each request it answers.
class _RecordingProtocol extends McpProtocol {
  _RecordingProtocol({required super.tools})
      : super(serverName: 'ZestSSH', serverVersion: '4.1.0-interop', instructions: 'Interop harness.');

  final seen = <_Seen>[];

  @override
  Future<McpResponse> handle(String method, Map<String, String> headers, String body,
      {required String Function() newSessionId}) async {
    final answer = await super.handle(method, headers, body, newSessionId: newSessionId);
    String? rpcMethod;
    String? metaVersion;
    try {
      final m = jsonDecode(body);
      if (m is Map) {
        rpcMethod = m['method'] as String?;
        final meta = (m['params'] as Map?)?['_meta'];
        if (meta is Map) metaVersion = meta['io.modelcontextprotocol/protocolVersion'] as String?;
      }
    } catch (_) {}
    seen.add(_Seen(method, rpcMethod, headers['mcp-protocol-version'], metaVersion, answer.status));
    return answer;
  }
}

/// [held] gets how each `hold` call ended.
List<McpTool> _tools(List<String> held) => [
      McpTool(
        name: 'echo',
        title: 'Echo',
        description: 'Says the text back.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
          },
          'required': ['text'],
          'additionalProperties': false,
        },
        readOnly: true,
        idempotent: true,
        run: (args, caller) async {
          final text = args.requireString('text');
          return McpToolResult('echo: $text', structured: {'text': text, 'caller': caller.shownName});
        },
      ),
      McpTool(
        name: 'count',
        title: 'Count',
        description: 'Says 3.',
        inputSchema: const {'type': 'object', 'additionalProperties': false},
        readOnly: true,
        run: (args, caller) async => const McpToolResult('3', structured: {'count': 3}),
      ),
      McpTool(
        name: 'fail',
        title: 'Fail',
        description: 'Always fails.',
        inputSchema: const {'type': 'object', 'additionalProperties': false},
        run: (args, caller) async => const McpToolResult.error('It failed on purpose.'),
      ),
      McpTool(
        name: 'hold',
        title: 'Hold',
        description: 'Waits up to 6 seconds for the client to give up on it.',
        inputSchema: const {'type': 'object', 'additionalProperties': false},
        run: (args, caller) async {
          final gaveUp = await (caller.cancelled ?? Completer<void>().future)
              .then((_) => true)
              .timeout(const Duration(seconds: 6), onTimeout: () => false);
          held.add(gaveUp ? 'ended by the client\'s cancellation' : 'not cancelled (ran its 6 s)');
          return const McpToolResult('held');
        },
      ),
    ];

String _python(String venv) =>
    File(Platform.isWindows ? '$_dir/$venv/Scripts/python.exe' : '$_dir/$venv/bin/python').absolute.path;

/// The clients: a name, the program and its arguments (the URL and token
/// are put first).
final _clients = <(String, String, List<String>)>[
  ('ts sdk 1.x', 'node', ['$_dir/ts_client.mjs', 'sdk', 'default']),
  ('ts client 2.x default', 'node', ['$_dir/ts_client.mjs', 'client', 'default']),
  ('ts client 2.x auto', 'node', ['$_dir/ts_client.mjs', 'client', 'auto']),
  ('ts client 2.x pin 2026-07-28', 'node', ['$_dir/ts_client.mjs', 'client', 'pin']),
  ('py 1.x ClientSession', _python('.venv1'), ['$_dir/py_client.py', 'session']),
  ('py 2.x Client auto', _python('.venv'), ['$_dir/py_client.py', 'auto']),
  ('py 2.x Client legacy', _python('.venv'), ['$_dir/py_client.py', 'legacy']),
  ('py 2.x Client 2026-07-28', _python('.venv'), ['$_dir/py_client.py', '2026-07-28']),
];

void main() {
  final reports = <String, Object?>{};

  tearDownAll(() {
    final out = File('build/mcp_interop/report.json');
    out.parent.createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(reports));
    stdout.writeln('Report: ${out.absolute.path}');
  });

  for (final (name, program, args) in _clients) {
    test(name, () async {
      final held = <String>[];
      final protocol = _RecordingProtocol(tools: () => _tools(held));
      final server = McpServer(protocol: protocol, token: _token, port: 0);
      await server.start();
      try {
        final url = 'http://127.0.0.1:${server.boundPort}$kMcpPath';
        final run = await Process.run(program, [args.first, url, _token, ...args.skip(1)])
            .timeout(const Duration(minutes: 2));
        final line = (run.stdout as String).trim().split('\n').lastWhere((l) => l.startsWith('{'), orElse: () => '');
        final report = line.isEmpty ? <String, Object?>{'ok': false} : jsonDecode(line) as Map<String, Object?>;
        for (var i = 0; i < 40 && held.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        report['hold'] = held;
        report['server saw'] = [for (final s in protocol.seen) s.toJson()];
        if (line.isEmpty || run.exitCode != 0) report['stderr'] = (run.stderr as String).split('\n').take(30).join('\n');
        reports[name] = report;
        stdout.writeln('$name: ${report['client']} negotiated ${report['negotiated']}, '
            '${report['ok'] == true ? 'all steps as expected' : 'FAILED'}; hold: $held');
        for (final s in (report['steps'] as List? ?? const [])) {
          final step = s as Map;
          if (step['ok'] != true) stdout.writeln('  not as expected: ${jsonEncode(step)}');
        }
        expect(report['ok'], isTrue, reason: const JsonEncoder.withIndent('  ').convert(report));
      } finally {
        await server.stop();
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
