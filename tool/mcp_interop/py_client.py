"""Drives ZestSSH's MCP server with the official Python MCP client (the `mcp`
package) and prints what happened as one JSON object on stdout.

    python py_client.py <url> <token> <mode>

<mode>: "session" (1.x: streamablehttp_client and ClientSession), or, for the
2.x line's Client: "auto" (its default: probe server/discover, fall back to
initialize), "legacy" (initialize only) or "2026-07-28" (that revision only).
"""

import json
import re
import sys
import traceback
from importlib.metadata import version

import anyio

URL, TOKEN, MODE = sys.argv[1:4]
HEADERS = {"Authorization": f"Bearer {TOKEN}"}

report = {"client": f"mcp@{version('mcp')} (Python)", "mode": MODE, "steps": []}


def describe(e: BaseException) -> dict:
    # An exception group (anyio's task groups) says little: name what is inside.
    inner = e
    while isinstance(inner, BaseExceptionGroup) and inner.exceptions:
        inner = inner.exceptions[0]
    where = traceback.extract_tb(inner.__traceback__)[-3:] if inner.__traceback__ else []
    return {"error": type(inner).__name__, "message": str(inner)[:300],
            "at": [f"{f.filename.split('site-packages')[-1]}:{f.lineno} {f.line}" for f in where]}


async def step(name, expect, run):
    try:
        with anyio.fail_after(20):
            value = await run()
        report["steps"].append({"name": name, "ok": bool(expect(value, None)), "value": value})
    except BaseException as e:  # noqa: BLE001 (a report of whatever happened)
        if isinstance(e, KeyboardInterrupt):
            raise
        report["steps"].append({"name": name, "ok": bool(expect(None, e)), **describe(e)})


def result_of(r) -> dict:
    return {
        "isError": bool(getattr(r, "isError", None) or getattr(r, "is_error", None)),
        "text": r.content[0].text if r.content else None,
        "structuredContent": getattr(r, "structuredContent", None) or getattr(r, "structured_content", None),
    }


def refused(_, e) -> bool:
    # Refused is what counts; the report keeps what the client made of it.
    return e is not None


async def run_calls(list_tools, call_tool, hold):
    await step("listTools", lambda v, e: v is not None and {"echo", "fail", "count"} <= set(v),
               lambda: _names(list_tools))
    await step("callTool echo",
               lambda v, e: v is not None and not v["isError"] and v["text"] == "echo: hello"
               and (v["structuredContent"] or {}).get("text") == "hello",
               lambda: _call(call_tool, "echo", {"text": "hello"}))
    await step("callTool count (no arguments)", lambda v, e: v is not None and not v["isError"] and v["text"] == "3",
               lambda: _call(call_tool, "count", None))
    await step("callTool fail (isError)", lambda v, e: v is not None and v["isError"] and "on purpose" in v["text"],
               lambda: _call(call_tool, "fail", {}))
    await step("callTool echo, a wrong argument (isError)", lambda v, e: v is not None and v["isError"],
               lambda: _call(call_tool, "echo", {"text": 7}))
    await step("callTool unknown tool (an error)",
               lambda v, e: (e is not None and re.search(r"nope|unknown tool", str(e) + repr(e), re.I))
               or (v is not None and v["isError"]),
               lambda: _call(call_tool, "nope", {}))
    # A call the client gives up on after 1.5 s: the SDK may cancel it.
    await step("callTool hold, given up after 1.5 s (an error here)", lambda v, e: e is not None, hold)
    # (Time for a cancellation to go out before the transport closes.)
    await anyio.sleep(0.5)


async def _names(list_tools):
    r = await list_tools()
    return [t.name for t in r.tools]


async def _call(call_tool, name, arguments):
    return result_of(await call_tool(name, arguments))


async def main_session():
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    async def connect_and_run():
        async with streamablehttp_client(URL, headers=HEADERS) as (read, write, _):
            async with ClientSession(read, write) as session:
                init = await session.initialize()
                report["negotiated"] = init.protocolVersion
                report["steps"].append({"name": "connect", "ok": True,
                                        "value": {"negotiated": init.protocolVersion,
                                                  "server": init.serverInfo.model_dump()}})
                from datetime import timedelta

                await run_calls(session.list_tools, session.call_tool,
                                lambda: session.call_tool("hold", {}, read_timeout_seconds=timedelta(seconds=1.5)))
        return "closed"

    await step("session (connect, calls, close)", lambda v, e: e is None, connect_and_run)

    async def wrong_token():
        async with streamablehttp_client(URL, headers={"Authorization": "Bearer zmcp_wrong"}) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
        return "connected"

    await step("wrong token (401)", refused, wrong_token)


async def main_client():
    from mcp import Client
    from mcp.client.streamable_http import streamable_http_client
    from mcp.shared._httpx_utils import create_mcp_http_client
    from mcp.types import Implementation

    def transport(headers):
        return streamable_http_client(URL, http_client=create_mcp_http_client(headers=headers))

    async def connect_and_run():
        async with Client(transport(HEADERS), mode=MODE,
                          client_info=Implementation(name="zestssh-interop-py", title="Interop (Python)",
                                                     version="1.0.0")) as client:
            info = client.server_info
            report["negotiated"] = client.protocol_version
            report["steps"].append({"name": "connect", "ok": True,
                                    "value": {"negotiated": client.protocol_version,
                                              "server": info if isinstance(info, dict) else (info.model_dump() if info else None)}})
            await run_calls(client.list_tools, client.call_tool,
                            lambda: client.call_tool("hold", {}, read_timeout_seconds=1.5))
        return "closed"

    await step("client (connect, calls, close)", lambda v, e: e is None, connect_and_run)

    async def wrong_token():
        async with Client(transport({"Authorization": "Bearer zmcp_wrong"}), mode=MODE) as client:
            # (A pinned client sends nothing until its first request.)
            await client.list_tools()
        return "connected"

    await step("wrong token (401)", refused, wrong_token)


async def main():
    if MODE == "session":
        await main_session()
    else:
        await main_client()
    report["ok"] = all(s["ok"] for s in report["steps"])
    sys.stdout.write(json.dumps(report, default=str) + "\n")


anyio.run(main)
