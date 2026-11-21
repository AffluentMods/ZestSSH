// Drives ZestSSH's MCP server with an official TypeScript MCP client and
// prints what happened as one JSON object on stdout.
//
//   node ts_client.mjs <url> <token> <package> <mode>
//
// <package>: "sdk" (@modelcontextprotocol/sdk, the 1.x line) or "client"
// (@modelcontextprotocol/client, the 2.x line).
// <mode>: "default" (the package's own default), "auto" (2.x: probe
// server/discover, fall back to initialize) or "pin" (2.x: 2026-07-28 only).

import { readFileSync } from 'node:fs';

const [url, token, pkg, mode] = process.argv.slice(2);

const versionOf = (name) =>
  JSON.parse(readFileSync(new URL(`./node_modules/${name}/package.json`, import.meta.url))).version;

let Client;
let StreamableHTTPClientTransport;
let packageName;
if (pkg === 'sdk') {
  packageName = '@modelcontextprotocol/sdk';
  ({ Client } = await import('@modelcontextprotocol/sdk/client/index.js'));
  ({ StreamableHTTPClientTransport } = await import('@modelcontextprotocol/sdk/client/streamableHttp.js'));
} else {
  packageName = '@modelcontextprotocol/client';
  ({ Client, StreamableHTTPClientTransport } = await import('@modelcontextprotocol/client'));
}

const report = { client: `${packageName}@${versionOf(packageName)}`, mode, steps: [] };

function clientOptions() {
  if (pkg !== 'client' || mode === 'default') return undefined;
  return { versionNegotiation: { mode: mode === 'pin' ? { pin: '2026-07-28' } : 'auto' } };
}

function connectTo(withToken) {
  const transport = new StreamableHTTPClientTransport(new URL(url), {
    requestInit: { headers: { Authorization: `Bearer ${withToken}` } },
  });
  const client = new Client({ name: 'zestssh-interop-ts', title: 'Interop (TypeScript)', version: '1.0.0' }, clientOptions());
  return { client, transport };
}

const describe = (e) => ({
  error: e?.constructor?.name ?? typeof e,
  message: String(e?.message ?? e),
  code: e?.code,
  status: e?.data?.status ?? e?.status,
});

async function step(name, expect, run) {
  try {
    const value = await run();
    const ok = expect(value, null);
    report.steps.push({ name, ok, value });
  } catch (e) {
    const ok = expect(null, e);
    report.steps.push({ name, ok, ...describe(e) });
  }
}

const { client, transport } = connectTo(token);
await step('connect', (_, e) => e === null, async () => {
  await client.connect(transport);
  return {
    negotiated: client.getNegotiatedProtocolVersion?.() ?? transport.protocolVersion ?? null,
    era: client.getProtocolEra?.() ?? null,
    server: client.getServerVersion?.() ?? null,
    sessionId: transport.sessionId ?? null,
    instructions: (client.getInstructions?.() ?? '').slice(0, 40),
  };
});
report.negotiated = report.steps[0].value?.negotiated ?? null;
report.era = report.steps[0].value?.era ?? null;

if (report.steps[0].ok) {
  await step('listTools', (v) => v != null && ['echo', 'fail', 'count'].every((n) => v.includes(n)), async () => {
    const r = await client.listTools();
    return r.tools.map((t) => t.name);
  });
  await step('callTool echo', (v) => v?.isError !== true && v?.content?.[0]?.text === 'echo: hello' && v?.structuredContent?.text === 'hello', () =>
    client.callTool({ name: 'echo', arguments: { text: 'hello' } }));
  await step('callTool count (no arguments)', (v) => v?.isError !== true && v?.content?.[0]?.text === '3', () =>
    client.callTool({ name: 'count' }));
  await step('callTool fail (isError)', (v) => v?.isError === true && /on purpose/.test(v?.content?.[0]?.text ?? ''), () =>
    client.callTool({ name: 'fail', arguments: {} }));
  await step('callTool echo, a wrong argument (isError)', (v) => v?.isError === true, () =>
    client.callTool({ name: 'echo', arguments: { text: 7 } }));
  await step('callTool unknown tool (an error)', (v, e) => (e != null && /nope|Unknown tool/i.test(String(e.message))) || v?.isError === true, () =>
    client.callTool({ name: 'nope', arguments: {} }));
  // A call the client gives up on after 1.5 s: the SDK cancels it.
  await step('callTool hold, given up after 1.5 s (an error here)', (_, e) => e != null, () =>
    pkg === 'sdk'
      ? client.callTool({ name: 'hold', arguments: {} }, undefined, { timeout: 1500 })
      : client.callTool({ name: 'hold', arguments: {} }, { timeout: 1500 }));
  // (Time for the cancellation to go out before close() stops the transport.)
  await new Promise((r) => setTimeout(r, 500));
  await step('close', (_, e) => e === null, () => client.close());
}

const bad = connectTo('zmcp_wrong');
// Refused is what counts; the report keeps what the client made of it.
await step('wrong token (401)', (_, e) => e != null, async () => {
  await bad.client.connect(bad.transport);
  // (A pinned client sends nothing until its first request.)
  await bad.client.listTools();
  return 'connected';
});
try {
  await bad.client.close();
} catch {}

report.ok = report.steps.every((s) => s.ok);
process.stdout.write(`${JSON.stringify(report)}\n`);
process.exit(0);
