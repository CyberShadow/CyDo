#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3Packages.websockets
"""
CyDo WebSocket inspector — connect to the backend and inspect live state.

Usage:
  ./docs/tools/ws-inspect.py                    # list tasks
  ./docs/tools/ws-inspect.py tasks              # list tasks
  ./docs/tools/ws-inspect.py history 3          # fetch full history for task 3
  ./docs/tools/ws-inspect.py watch              # stream all live events
  ./docs/tools/ws-inspect.py watch 3            # stream events for task 3 only
"""

import asyncio
import json
import sys

import websockets

URL = "ws://localhost:3456/ws"


def fmt(obj):
    """Pretty-print JSON, compact for small objects."""
    return json.dumps(obj, indent=2, ensure_ascii=False)


async def list_tasks():
    """Connect, receive initial messages, print tasks list, disconnect."""
    async with websockets.connect(URL) as ws:
        # Server sends workspaces_list then tasks_list on connect
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            if msg.get("type") == "tasks_list":
                tasks = msg.get("tasks", [])
                if not tasks:
                    print("No tasks.")
                    return
                for t in sorted(tasks, key=lambda x: x.get("tid", 0)):
                    tid = t.get("tid", "?")
                    title = t.get("title", "(untitled)")
                    status = t.get("status", "?")
                    alive = t.get("alive", False)
                    ws_name = t.get("workspace", "")
                    parent = t.get("parent_tid", 0)
                    indicator = "*" if alive else " "
                    parent_str = f"  parent={parent}" if parent else ""
                    print(f"  {indicator} [{tid:>3}] {status:<10} {title}{parent_str}")
                return


async def fetch_history(tid: int):
    """Request and print full history for a task."""
    async with websockets.connect(URL) as ws:
        # Drain initial messages
        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            if msg.get("type") == "tasks_list":
                break

        # Request history
        await ws.send(json.dumps({"type": "request_history", "tid": tid}))

        while True:
            msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
            if msg.get("type") == "task_history_end" and msg.get("tid") == tid:
                break
            # Print each history event
            if msg.get("tid") == tid:
                event = msg.get("event")
                user_event = msg.get("unconfirmedUserEvent")
                if event:
                    etype = event.get("type", "?")
                    subtype = event.get("subtype", "")
                    label = f"{etype}.{subtype}" if subtype else etype
                    # For assistant messages, show text preview
                    if etype == "assistant":
                        content = event.get("message", {}).get("content", [])
                        text = "".join(
                            b.get("text", "") for b in content if b.get("type") == "text"
                        )
                        preview = text[:200].replace("\n", "\\n")
                        print(f"  {label}: {preview}")
                    elif etype == "user":
                        content = event.get("message", {}).get("content", "")
                        if isinstance(content, str):
                            preview = content[:200].replace("\n", "\\n")
                        else:
                            preview = str(content)[:200]
                        print(f"  {label}: {preview}")
                    else:
                        print(f"  {label}")
                elif user_event:
                    content = user_event.get("message", {}).get("content", "")
                    preview = str(content)[:200].replace("\n", "\\n")
                    print(f"  user (unconfirmed): {preview}")


async def watch(tid_filter: int | None = None):
    """Stream live events (optionally filtered to one task)."""
    async with websockets.connect(URL) as ws:
        print(f"Connected to {URL}, streaming events" +
              (f" for task {tid_filter}" if tid_filter is not None else "") +
              "... (Ctrl+C to stop)")
        while True:
            raw = await ws.recv()
            msg = json.loads(raw)
            msg_tid = msg.get("tid")

            # Skip initial bulk messages unless watching all
            if msg.get("type") in ("workspaces_list", "tasks_list"):
                if tid_filter is None:
                    print(f"[init] {msg['type']}: {len(msg.get('tasks', msg.get('workspaces', [])))} entries")
                continue

            if tid_filter is not None and msg_tid != tid_filter:
                continue

            # Format the event compactly
            event = msg.get("event")
            user_event = msg.get("unconfirmedUserEvent")
            ts = msg.get("timestamp", "")
            prefix = f"[{ts}] tid={msg_tid}"

            if event:
                etype = event.get("type", "?")
                subtype = event.get("subtype", "")
                label = f"{etype}.{subtype}" if subtype else etype

                if etype == "assistant":
                    content = event.get("message", {}).get("content", [])
                    text = "".join(
                        b.get("text", "") for b in content if b.get("type") == "text"
                    )
                    preview = text[:300].replace("\n", "\\n")
                    print(f"{prefix} {label}: {preview}")
                elif etype in ("exit", "stderr"):
                    print(f"{prefix} {label}: {json.dumps(event)}")
                else:
                    # For tool_use, result, system etc — show type + truncated JSON
                    compact = json.dumps(event, ensure_ascii=False)
                    if len(compact) > 400:
                        compact = compact[:400] + "..."
                    print(f"{prefix} {label}: {compact}")
            elif user_event:
                content = user_event.get("message", {}).get("content", "")
                preview = str(content)[:200].replace("\n", "\\n")
                print(f"{prefix} user(unconfirmed): {preview}")
            elif msg.get("type") == "title_update":
                print(f"{prefix} title_update: {msg.get('title', '')}")
            elif msg.get("type") == "task_created":
                print(f"{prefix} task_created: workspace={msg.get('workspace', '')}")
            else:
                compact = json.dumps(msg, ensure_ascii=False)
                if len(compact) > 400:
                    compact = compact[:400] + "..."
                print(f"{prefix} {msg.get('type', '?')}: {compact}")


async def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "tasks"

    if cmd == "tasks":
        await list_tasks()
    elif cmd == "history" and len(args) >= 2:
        await fetch_history(int(args[1]))
    elif cmd == "watch":
        tid = int(args[1]) if len(args) >= 2 else None
        await watch(tid)
    else:
        print(__doc__.strip())
        sys.exit(1)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
