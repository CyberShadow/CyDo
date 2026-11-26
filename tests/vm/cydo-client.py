import argparse
import json
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event

from websockets.sync.client import connect


def receive(ws):
    message = json.loads(ws.recv(timeout=90))
    if message.get("type") in ("error", "cydo/submission_rejected"):
        raise RuntimeError(message)
    event = message.get("event", {})
    if event.get("type") == "process/exit" or (
        event.get("type") == "cydo/task_diagnostic" and event["severity"] == "error"
    ):
        raise RuntimeError(message)
    return message


def wait_for(ws, message_type, **fields):
    while True:
        message = receive(ws)
        if message.get("type") == message_type and all(
            message.get(key) == value for key, value in fields.items()
        ):
            return message


def observe_one_shot_cgroups(stop):
    prompts = {
        "title": b"Generate a concise title",
        "suggestions": b"[SUGGESTION MODE:",
    }
    groups = {}
    while not stop.is_set():
        for process in Path("/proc").iterdir():
            if not process.name.isdecimal():
                continue
            try:
                args = (process / "cmdline").read_bytes().split(b"\0")
                if len(args) < 3 or args[0].rsplit(b"/", 1)[-1] != b"claude" or args[1] != b"-p":
                    continue
                for kind, prefix in prompts.items():
                    if kind not in groups and args[2].startswith(prefix):
                        groups[kind] = (process / "cgroup").read_text().strip()
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                # /proc changes as processes exit, and other users' processes may be private.
                continue
        if groups.keys() == prompts.keys():
            return groups
        stop.wait(0.01)
    return groups


def run(args):
    with connect("ws://localhost:3940/ws") as ws:
        wait_for(ws, "tasks_list", complete=True)
        creating = args.command == "create-and-send"
        if creating:
            correlation_id = str(uuid.uuid4())
            ws.send(json.dumps({
                "type": "create_task",
                "workspace": args.workspace,
                "project_path": args.project,
                "entry_point": "direct",
                "agent_name": "claude",
                "content": [],
                "correlation_id": correlation_id,
            }))
            tid = wait_for(ws, "task_created", correlation_id=correlation_id)["tid"]
        else:
            tid = args.tid

        ws.send(json.dumps({"type": "request_history", "tid": tid}))
        wait_for(ws, "task_history_end", tid=tid)
        ws.send(json.dumps({
            "type": "message",
            "tid": tid,
            "content": [{"type": "text", "text": args.text}],
            "correlation_id": str(uuid.uuid4()),
        }))

        titles = []
        text_items = {}
        assistant = []
        tool_outputs = []
        completed = False
        while not completed or (creating and len(titles) < 2):
            message = receive(ws)
            if message.get("tid") != tid:
                continue
            if message.get("type") == "title_update":
                # The first update contains the provisional title from the prompt.
                titles.append(message["title"])
            event = message.get("event", {})
            match event.get("type"):
                case "item/started" if event["item_type"] == "text":
                    text_items[event["item_id"]] = event.get("text", "")
                case "item/delta" if event["delta_type"] == "text_delta":
                    text_items[event["item_id"]] += event["content"]
                case "item/completed" if event["item_id"] in text_items:
                    streamed_text = text_items.pop(event["item_id"])
                    assistant.append(event.get("text", streamed_text))
                case "item/result":
                    tool_outputs.append(event["content"])
                case "turn/result":
                    if event["is_error"]:
                        raise RuntimeError(event)
                    completed = True

        result = {"assistant_text": "".join(assistant)}
        if creating:
            result.update(tid=tid, title=titles[-1])
        else:
            result.update(tool_outputs=tool_outputs)
        return result


parser = argparse.ArgumentParser()
commands = parser.add_subparsers(dest="command", required=True)
create = commands.add_parser("create-and-send")
create.add_argument("workspace")
create.add_argument("project")
create.add_argument("text")
send = commands.add_parser("send")
send.add_argument("tid", type=int)
send.add_argument("text")
args = parser.parse_args()
if args.command == "create-and-send":
    stop = Event()
    with ThreadPoolExecutor(max_workers=1) as pool:
        observation = pool.submit(observe_one_shot_cgroups, stop)
        try:
            result = run(args)
            result["one_shot_cgroups"] = observation.result(timeout=30)
        finally:
            stop.set()
else:
    result = run(args)
print(json.dumps(result))
