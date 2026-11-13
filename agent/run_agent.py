#!/usr/bin/env python3
"""
Zero-dependency local LLM computer-use runner for cuflllm.
Works with any OpenAI-compatible local server (Ollama, LM Studio, MLX, llama.cpp).
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Any


SYSTEM_PROMPT = """You are a fast, precise macOS computer-use agent.
You observe the screen via structured Accessibility snapshots (not screenshots).
Each UI element has an ID like e1, e2, etc., its role, label, value, bounds, and flags.
Windows have IDs like w1, w2.

Rules:
1. First inspect the current screen or open the needed app.
2. Prefer exact element IDs (e.g., click(id="e3")) and OS shortcuts (open_app, focus_window, press_key) over guessing.
3. Each action automatically returns the updated screen diff and current elements—only call get_screen_state if you need a fresh read or OCR.
4. Keep track of focused elements and screen diffs. Never repeat the exact same failing action more than twice; try an alternative (menu bar, shortcut, scrolling, or OCR).
5. When the user's goal is achieved—or if blocked by login/permissions/missing info—call the `done` tool with a clear summary."""


TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "get_screen_state",
            "description": "Capture the current screen elements for the frontmost window (or a specified window_id).",
            "parameters": {
                "type": "object",
                "properties": {
                    "window_id": {"type": "string", "description": "Optional window ID like w2"},
                    "ocr": {"type": "string", "enum": ["auto", "always", "never"]},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "click",
            "description": "Click an element by its ID (e.g. e3).",
            "parameters": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "kind": {"type": "string", "enum": ["single", "double", "right"]},
                },
                "required": ["id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "type_text",
            "description": "Type text into an optional element ID, optionally clearing existing content or pressing Enter.",
            "parameters": {
                "type": "object",
                "properties": {
                    "id": {"type": "string", "description": "Optional element ID to focus/click first"},
                    "text": {"type": "string"},
                    "clear_first": {"type": "boolean"},
                    "press_enter": {"type": "boolean"},
                },
                "required": ["text"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "press_key",
            "description": "Press a key or shortcut like 'return', 'escape', 'tab', 'cmd+l', 'cmd+s'.",
            "parameters": {
                "type": "object",
                "properties": {
                    "key": {"type": "string"},
                    "modifiers": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["key"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "scroll",
            "description": "Scroll over an element or the focused window.",
            "parameters": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
                    "amount": {"type": "integer"},
                },
                "required": ["direction"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_app",
            "description": "Open or activate a macOS application by name (e.g. 'Notes', 'Safari', 'Finder').",
            "parameters": {
                "type": "object",
                "properties": {"app_name": {"type": "string"}},
                "required": ["app_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "focus_window",
            "description": "Focus another visible window by ID (e.g. w2).",
            "parameters": {
                "type": "object",
                "properties": {"window_id": {"type": "string"}},
                "required": ["window_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_menu_bar",
            "description": "List menu bar items and keyboard shortcuts for the frontmost app.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "click_menu",
            "description": "Trigger a menu bar item by id (m12) or path ('File > New Window').",
            "parameters": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "menu_path": {"type": "string"},
                },
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "batch",
            "description": "Execute a fast sequence of deterministic UI actions in one round-trip (e.g. click new tab -> type URL + Enter) and return the final screen diff + state.",
            "parameters": {
                "type": "object",
                "properties": {
                    "actions": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "action": {"type": "string"},
                                "id": {"type": "string"},
                                "text": {"type": "string"},
                                "clear_first": {"type": "boolean"},
                                "press_enter": {"type": "boolean"},
                                "key": {"type": "string"},
                                "modifiers": {"type": "array", "items": {"type": "string"}},
                                "app_name": {"type": "string"},
                                "window_id": {"type": "string"},
                                "settle_ms": {"type": "integer"},
                            },
                            "required": ["action"],
                        },
                    },
                    "step_settle_ms": {"type": "integer"},
                    "final_settle_ms": {"type": "integer"},
                },
                "required": ["actions"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "done",
            "description": "Finish the task and report the final result to the user.",
            "parameters": {
                "type": "object",
                "properties": {"summary": {"type": "string"}},
                "required": ["summary"],
            },
        },
    },
]


def http_json(url: str, payload: dict[str, Any] | None = None, api_key: str = "") -> dict[str, Any]:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} from {url}: {body}") from exc


def http_text(url: str) -> str:
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8")


def call_cuflllm_tool(cuflllm_url: str, name: str, args: dict[str, Any]) -> str:
    base = cuflllm_url.rstrip("/")
    if name == "get_screen_state":
        params = ["format=text"]
        if args.get("window_id"):
            params.append(f"window_id={args['window_id']}")
        if args.get("ocr"):
            params.append(f"ocr={args['ocr']}")
        return http_text(f"{base}/state?" + "&".join(params))

    if name == "get_menu_bar":
        return http_text(f"{base}/menu?format=text")

    if name == "batch":
        try:
            res = http_json(f"{base}/batch", args)
            return res.get("compact_text") or "\n".join(res.get("steps", [])) or json.dumps(res)
        except RuntimeError as exc:
            return f"ERROR: {exc}"

    action_map: dict[str, dict[str, Any]] = {
        "click": {
            "action": (
                "double_click" if args.get("kind") == "double"
                else "right_click" if args.get("kind") == "right"
                else "click"
            ),
            "id": args.get("id"),
        },
        "type_text": {
            "action": "type_text",
            "id": args.get("id"),
            "text": args.get("text", ""),
            "clear_first": bool(args.get("clear_first", False)),
            "press_enter": bool(args.get("press_enter", False)),
        },
        "press_key": {
            "action": "press_key",
            "key": args.get("key"),
            "modifiers": args.get("modifiers", []),
        },
        "scroll": {
            "action": "scroll",
            "id": args.get("id"),
            "direction": args.get("direction", "down"),
            "amount": int(args.get("amount", 360)),
        },
        "open_app": {
            "action": "open_app",
            "app_name": args.get("app_name"),
        },
        "focus_window": {
            "action": "focus_window",
            "window_id": args.get("window_id"),
        },
        "click_menu": {
            "action": "click_menu",
            "id": args.get("id"),
            "menu_path": args.get("menu_path"),
        },
    }

    if name not in action_map:
        return f"ERROR: Unknown tool '{name}'"

    payload = {k: v for k, v in action_map[name].items() if v is not None}
    try:
        res = http_json(f"{base}/act", payload)
        return res.get("compact_text") or res.get("message") or json.dumps(res)
    except RuntimeError as exc:
        return f"ERROR: {exc}"


def extract_fallback_tool_call(content: str) -> tuple[str, dict[str, Any]] | None:
    match = re.search(r"\{.*\}", content, re.DOTALL)
    if not match:
        return None
    try:
        obj = json.loads(match.group(0))
    except json.JSONDecodeError:
        return None
    name = obj.get("tool") or obj.get("name") or obj.get("action")
    args = obj.get("arguments") or obj.get("args") or {}
    if isinstance(name, str) and isinstance(args, dict):
        return name, args
    return None


def prune_old_tool_states(messages: list[dict[str, Any]], keep_last: int = 2) -> list[dict[str, Any]]:
    tool_indices = [i for i, m in enumerate(messages) if m.get("role") == "tool" and "ELEMENTS (" in str(m.get("content", ""))]
    to_trim = set(tool_indices[:-keep_last]) if len(tool_indices) > keep_last else set()
    pruned: list[dict[str, Any]] = []
    for i, msg in enumerate(messages):
        if i in to_trim:
            first_line = str(msg["content"]).splitlines()[0]
            pruned.append({**msg, "content": f"{first_line}\n[older element list omitted to save context]"})
        else:
            pruned.append(msg)
    return pruned


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a local 27B/OpenAI-compatible LLM with cuflllm.")
    parser.add_argument("goal", help="Task for the computer-use agent to perform")
    parser.add_argument("--cuflllm-url", default="http://127.0.0.1:8787", help="cuflllm HTTP server URL")
    parser.add_argument("--llm-url", default=os.environ.get("CUFLLLM_LLM_URL", "http://127.0.0.1:11434/v1"), help="OpenAI-compatible base URL")
    parser.add_argument("--model", default=os.environ.get("CUFLLLM_MODEL", "gemma3:27b"), help="Model ID on your local LLM server")
    parser.add_argument("--api-key", default=os.environ.get("CUFLLLM_API_KEY", "local"), help="Optional API key")
    parser.add_argument("--max-steps", type=int, default=15, help="Maximum tool steps before stopping")
    parser.add_argument("--confirm", action="store_true", help="Ask y/n before executing each UI action")
    args = parser.parse_args()

    try:
        health = http_json(f"{args.cuflllm_url.rstrip('/')}/health")
    except Exception as exc:
        print(f"Cannot reach cuflllm server at {args.cuflllm_url}: {exc}", file=sys.stderr)
        print("Start it first with: .build/release/cuflllm serve", file=sys.stderr)
        return 1

    if not health.get("accessibility_trusted"):
        print("WARNING: cuflllm reports Accessibility permission is NOT granted yet.", file=sys.stderr)
        print("Run `cuflllm doctor --prompt` and enable your terminal in Privacy & Security > Accessibility.", file=sys.stderr)

    initial_state = http_text(f"{args.cuflllm_url.rstrip('/')}/state?format=text")

    messages: list[dict[str, Any]] = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {
            "role": "user",
            "content": f"GOAL: {args.goal}\n\nINITIAL SCREEN STATE:\n{initial_state}",
        },
    ]

    endpoint = f"{args.llm_url.rstrip('/')}/chat/completions"

    for step in range(1, args.max_steps + 1):
        trimmed_messages = prune_old_tool_states(messages, keep_last=2)
        response = http_json(
            endpoint,
            payload={
                "model": args.model,
                "messages": trimmed_messages,
                "tools": TOOLS,
                "temperature": 0.1,
            },
            api_key=args.api_key,
        )

        choice = response["choices"][0]["message"]
        messages.append(choice)

        tool_calls = choice.get("tool_calls") or []
        if not tool_calls and choice.get("content"):
            fallback = extract_fallback_tool_call(choice["content"])
            if fallback:
                tool_name, tool_args = fallback
                tool_calls = [
                    {
                        "id": f"fallback_{step}",
                        "type": "function",
                        "function": {"name": tool_name, "arguments": json.dumps(tool_args)},
                    }
                ]

        if not tool_calls:
            print(f"\n[Step {step}] Assistant finished:\n{choice.get('content', '')}")
            return 0

        for call in tool_calls:
            fn = call["function"]
            name = fn["name"]
            raw_args = fn.get("arguments", "{}")
            call_args = json.loads(raw_args) if isinstance(raw_args, str) else (raw_args or {})

            print(f"\n[Step {step}] -> {name}({json.dumps(call_args)})")

            if name == "done":
                print(f"\nDONE: {call_args.get('summary', '')}")
                return 0

            if args.confirm and name not in ("get_screen_state", "get_menu_bar"):
                ans = input("Execute? [y/N]: ").strip().lower()
                if ans != "y":
                    result_text = "User declined executing this action."
                    messages.append({"role": "tool", "tool_call_id": call["id"], "content": result_text})
                    continue

            result_text = call_cuflllm_tool(args.cuflllm_url, name, call_args)
            first_line = result_text.splitlines()[0] if result_text else ""
            print(f"   <- {first_line}")
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": call["id"],
                    "content": result_text,
                }
            )

    print(f"\nStopped after reaching max steps ({args.max_steps}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
