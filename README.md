# cuflllm — Computer Use For LLMs

A fast, zero-dependency macOS desktop automation service that replaces screenshot-heavy VLM loops with structured **Accessibility (`AXUIElement`)**, **Window Server (`CGWindowListCopyWindowInfo`)**, and **on-device Vision OCR (`ScreenCaptureKit` + `VNRecognizeTextRequest`)** snapshots.

Designed to let local LLMs (~27B–32B models via Ollama, LM Studio, or MLX) as well as cloud/MCP agents read and control desktop apps with tiny token budgets and low latency.

Repository: [github.com/newuser00000/cuflllm](https://github.com/newuser00000/cuflllm)

---

## Why cuflllm?

Most computer-use setups capture a full PNG screenshot every step, burn thousands of vision tokens, guess pixel coordinates, and repeat round-trips after every single click.

cuflllm instead reads the live OS Accessibility tree, strips hidden/decorative clutter, assigns short stable-per-snapshot IDs (`e1`, `e2`, ...), executes actions (or multi-step batches), and returns only what changed (`DIFF:`) plus the updated compact state:

```text
BATCH OK (8/8 steps):

[1/8] OK: Pressed e4 (button "All Clear") via AXPress
...
[8/8] OK: Pressed e22 (button "Equals") via AXPress

DIFF: +0 added, -0 removed, 2 value changes
  ~ e1 (static_text "Last Expression"): val="9 × 7 + 37"
  ~ e2 (static_text "Edit field"): val="100"

APP: Calculator (com.apple.calculator, pid=70128)
WINDOW: "Calculator" (w1, 833,315 230x408)
OTHER_WINDOWS: w2=Terminal, w3=Firefox
ELEMENTS (showing 27/27):
e1 | static_text | "Last Expression" | val="9 × 7 + 37" | (978,374 76x26)
e2 | static_text | "Edit field" | val="100" | (1001,404 52x36)
e3 | button | "Delete" | (843,448 48x48) | press
e4 | button | "All Clear" | (897,448 48x48) | press
...
e22 | button | "Equals" | (1005,664 48x48) | press
```

---

## Features

- **Token-Efficient Screen Representation:** 1-line-per-element text snapshots (`id | role | label | value | bounds | actions/state`) plus JSON output when programmatic fields are needed.
- **LLM-Focused Tree Pruning:**
  - Drops off-screen, invisible, zero-size, and redundant container nodes.
  - Collapses nested `static_text` inside labeled buttons, tabs, and links (common in SwiftUI, Safari, Firefox, and Electron apps).
  - Infers missing text-field labels from adjacent `static_text` labels to the left or directly above.
  - Labels macOS traffic-light window buttons (`Close Window`, `Minimize Window`, `Zoom Window`, `Full Screen`).
  - Automatically activates `AXEnhancedUserInterface` / `AXManualAccessibility` per PID for Chromium, Electron, VS Code, Slack, Discord, Spotify, Claude, Notion, Obsidian, and Firefox.
- **On-Device Vision OCR Fallback (`ocr=auto|always|never`):** When a window exposes fewer than 4 elements or zero interactive controls (e.g., custom canvases or non-accessible UI), cuflllm captures the window locally via `ScreenCaptureKit` and extracts text bounding boxes with `VNRecognizeTextRequest`.
- **Single & Multi-Step Batch Execution (`POST /batch` / `cuflllm_batch`):** Run sequences like *minimize/switch app -> new tab -> focus -> type URL + Enter* in a single HTTP/MCP call with per-step settle controls and one final `DIFF:` + snapshot.
- **Menu Bar Inspection & Triggering:** Lists top menu bar paths and shortcuts (`m32 | "Window > Minimize" | Cmd+M`) so agents can trigger commands reliably without guessing UI paths.
- **Privacy & Safety by Default:**
  - `AXSecureTextField` values are redacted as `[REDACTED]`.
  - HTTP server binds to `127.0.0.1` by default.
  - Included Python agent supports `--confirm` for `[y/N]` approval before every desktop action.
- **Zero External Dependencies:** Pure Swift 6 using built-in Apple frameworks (`AppKit`, `ApplicationServices`, `CoreGraphics`, `ScreenCaptureKit`, `Vision`), plus a standard-library-only Python runner.

---

## Requirements

- **macOS 14.0+**
- **Swift 6.0+** (Xcode or Apple Command Line Tools)
- **Python 3** *(optional, only for `agent/run_agent.py`)*

---

## Quick Start

### 1. Clone & Build

```bash
git clone https://github.com/newuser00000/cuflllm.git
cd cuflllm
swift build -c release
```

The compiled binary will be at `.build/release/cuflllm`.

### 2. Run Tests

```bash
# With full Xcode installed:
swift test

# With Command Line Tools only (pass the TestingMacros plugin path):
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

### 3. Grant macOS Permissions

Run the built-in diagnostic command from the **same terminal app** where you will run `cuflllm`:

```bash
.build/release/cuflllm doctor --prompt
```

1. Open **System Settings -> Privacy & Security -> Accessibility** and enable your terminal app (e.g., Terminal, iTerm2, Ghostty, VS Code) or the `cuflllm` binary itself.
2. *(Optional, only needed for `ocr=auto|always` fallback on non-accessible windows)* Request Screen Recording access:
   ```bash
   .build/release/cuflllm doctor --prompt-screen
   ```
   and enable **Screen Recording** for your terminal app.

### 4. Sanity Check

```bash
.build/release/cuflllm doctor
.build/release/cuflllm windows
.build/release/cuflllm snapshot --max 40
```

---

## Usage Modes

### 1. Local HTTP Daemon (`cuflllm serve`)

Starts a local stateful server (default `127.0.0.1:8787`) that tracks element/window/menu caches and computes automatic diffs across steps:

```bash
.build/release/cuflllm serve --host 127.0.0.1 --port 8787
```

#### Endpoints

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/health` | Permission status (`accessibility_trusted`, `screen_recording_trusted`) and live `frontmost_app` |
| `GET` | `/doctor` | Full diagnostic report JSON |
| `GET` | `/windows` | Visible on-screen windows (`?format=text` or JSON) |
| `GET` | `/state` | Screen snapshot (`?format=text\|json`, `max_elements=100`, `ocr=auto\|always\|never`, `window_id=w2`) |
| `GET` | `/menu` | Frontmost application's menu bar items (`?format=text` or JSON) |
| `POST` | `/act` | Execute one `ActionRequest` and return `diff` + updated `snapshot` + `compact_text` |
| `POST` | `/batch` | Execute multiple `ActionRequest` steps sequentially in one round-trip |
| `POST` | `/open_app` | Open/activate an application (`{"app_name": "Firefox"}`) |
| `POST` | `/focus_window` | Focus a window by ID (`{"window_id": "w2"}`) |

#### Examples

Single action (`POST /act`):

```bash
curl -s http://127.0.0.1:8787/act \
  -H 'Content-Type: application/json' \
  -d '{"action":"click","id":"e3"}'
```

Multi-step batch (`POST /batch`):

```bash
curl -s http://127.0.0.1:8787/batch \
  -H 'Content-Type: application/json' \
  -d '{
    "actions": [
      {"action": "open_app", "app_name": "Firefox"},
      {"action": "press_key", "key": "t", "modifiers": ["cmd"], "settle_ms": 180},
      {"action": "type_text", "text": "https://www.youtube.com", "press_enter": true}
    ],
    "stop_on_error": true,
    "step_settle_ms": 90,
    "final_settle_ms": 500,
    "max_elements": 60,
    "ocr": "never"
  }'
```

Supported `action` values in `/act` and `/batch`: `click`, `double_click`, `right_click`, `click_point`, `type_text`, `press_key`, `scroll`, `focus`, `open_app`, `focus_window`, `click_menu`.

---

### 2. Local 27B / OpenAI-Compatible Agent (`agent/run_agent.py`)

A zero-dependency Python loop using OpenAI-compatible tool calling (works with Ollama, LM Studio, vLLM, MLX servers, etc.). Start `cuflllm serve` in one terminal, then run:

```bash
# Ollama example
python3 agent/run_agent.py "Open Calculator and compute 9 * 7 + 37" \
  --llm-url http://127.0.0.1:11434/v1 \
  --model gemma3:27b \
  --confirm

# LM Studio (1234) or MLX (8080) example
python3 agent/run_agent.py "Open Firefox, start a new tab, and open example.com" \
  --llm-url http://127.0.0.1:1234/v1 \
  --model your-27b-model-id
```

Agent options:
- `--cuflllm-url` (default `http://127.0.0.1:8787`)
- `--llm-url` (default `CUFLLLM_LLM_URL` or `http://127.0.0.1:11434/v1`)
- `--model` (default `CUFLLLM_MODEL` or `gemma3:27b`)
- `--api-key` (default `CUFLLLM_API_KEY` or `local`)
- `--max-steps` (default `15`)
- `--confirm` (require interactive `[y/N]` confirmation before every UI action)

---

### 3. MCP Server (`cuflllm mcp`)

Any MCP client can connect directly over stdio:

```json
{
  "mcpServers": {
    "cuflllm": {
      "command": "/path/to/cuflllm/.build/release/cuflllm",
      "args": ["mcp"]
    }
  }
}
```

Exposed MCP tools (11):
- `cuflllm_get_screen_state`
- `cuflllm_click`
- `cuflllm_type_text`
- `cuflllm_press_key`
- `cuflllm_scroll`
- `cuflllm_open_app`
- `cuflllm_focus_window`
- `cuflllm_list_windows`
- `cuflllm_get_menu_bar`
- `cuflllm_click_menu`
- `cuflllm_batch`

---

### 4. Direct CLI Commands

```text
cuflllm doctor [--prompt] [--prompt-screen] [--json]
cuflllm windows [--json]
cuflllm snapshot [--window <id>] [--max <n>] [--ocr auto|always|never] [--json]
cuflllm menu [--json]
cuflllm click <id> [--double | --right] [--mode auto|ax|mouse] [--json]
cuflllm type [id] <text> [--clear] [--enter] [--json]
cuflllm key <key-or-combo> [--json]
cuflllm scroll [up|down|left|right] [--id <id>] [--amount <px>] [--json]
cuflllm open <app-name> [--json]
cuflllm focus <window-id> [--json]
cuflllm menu-click <id-or-path> [--json]
cuflllm act <json-ActionRequest>
cuflllm batch <json-BatchActionRequest>
cuflllm serve [--host 127.0.0.1] [--port 8787]
cuflllm mcp
```

---

## Project Structure

```text
cuflllm/
├── LICENSE
├── Package.swift
├── README.md
├── Sources/
│   ├── CuflCore/
│   │   ├── AccessibilityEngine.swift  # Live AX tree walk, pruning, label inference, enhanced UI
│   │   ├── ActionExecutor.swift       # AXPress, CGEvent mouse/keyboard, window focus & app activation
│   │   ├── CuflService.swift          # Snapshot/menu caches, action execution, batching, ScreenDiff
│   │   ├── HTTPServer.swift           # Lightweight POSIX socket HTTP server
│   │   ├── MCPServer.swift            # JSON-RPC stdio MCP server (11 tools)
│   │   ├── Models.swift               # Snapshot, ActionRequest, BatchActionRequest, Diff schemas
│   │   ├── OCRFallback.swift          # ScreenCaptureKit + Vision text recognition fallback
│   │   └── TreeFormatter.swift        # Compact token-efficient text formatter + diff engine
│   └── cuflllm/
│       └── main.swift                 # CLI entrypoint
├── Tests/
│   └── CuflCoreTests/
│       └── CuflCoreTests.swift        # Swift Testing suite
└── agent/
    └── run_agent.py                   # Zero-dependency OpenAI-compatible agent loop
```

---

## Contributing & Roadmap

Contributions, bug reports, and benchmarks across different macOS apps and local models are very welcome via [GitHub Issues](https://github.com/newuser00000/cuflllm/issues) and [Pull Requests](https://github.com/newuser00000/cuflllm/pulls). Areas of active interest:

- **Mobile / Assistive Port (Android `AccessibilityService`):** Exposing the same compact tree + `ScreenDiff` + `/batch` + safety confirmation loop as an on-device Android accessibility assistant for visually impaired users and low-bandwidth agents.
- **Voice / TTS Confirmation Loop:** Spoken diff summaries and voice confirmation before high-stakes actions.
- **App-Specific Accessibility Quirks:** Improved pruning/focus handling for additional Electron, SwiftUI, and web-engine apps.
- **CI Workflow:** GitHub Actions `macos` build and `swift test` checks.

---

## License

Licensed under the [MIT License](LICENSE) — Copyright (c) 2026 [newuser00000](https://github.com/newuser00000).
