# MCP interop harness

Drives ZestSSH's MCP server (`lib/features/mcp`) with the official MCP client SDKs, to check
that real clients can use it. Not part of the app's test suite: it needs Node and Python and the
SDKs installed here.

`interop_test.dart` starts the real `McpServer` and `McpProtocol` on 127.0.0.1 (port 0, a test
token) with four stand-in tools (`echo`, `count`, `fail`, `hold`). There is no app and no database.
Each client then runs these steps:

- connect, and record the protocol revision it agreed;
- list the tools;
- call `echo` (a result with structured content);
- call `count` with no arguments;
- call `fail` (a result with `isError`);
- call `echo` with a wrong argument (`isError`);
- call an unknown tool (a JSON-RPC error);
- call `hold` and give up after 1.5 s (whether the server learns of it);
- connect with a wrong token (401).

The test records what reached the server on each request: the method, `MCP-Protocol-Version`,
the `_meta` revision and the status.

| Client | Package (pinned) | Modes run |
|---|---|---|
| `ts_client.mjs` | `@modelcontextprotocol/sdk` (the 1.x line) | its default |
| `ts_client.mjs` | `@modelcontextprotocol/client` (the 2.x line) | default (legacy), `auto`, pinned to 2026-07-28 |
| `py_client.py` | `mcp` 1.x (`requirements-1x.txt`) | `streamablehttp_client` and `ClientSession` |
| `py_client.py` | `mcp` 2.x (`requirements.txt`) | `Client` in `auto` (its default), `legacy`, `2026-07-28` |

## Run it

From this folder, once:

```
npm install
python -m venv .venv && .venv/Scripts/python -m pip install -r requirements.txt
python -m venv .venv1 && .venv1/Scripts/python -m pip install -r requirements-1x.txt
```

On macOS and Linux the venv's Python is `.venv/bin/python`. Then, from the app's root:

```
flutter test --no-pub tool/mcp_interop/interop_test.dart
```

Each client's report, with what the server saw, is written to `build/mcp_interop/report.json`.

To try newer SDKs, change the pins in `package.json` and the requirements files. Use versions
published at least two weeks ago.
