import Foundation

public final class MCPServer: @unchecked Sendable {
    private let service: CuflService

    public init(service: CuflService) {
        self.service = service
    }

    public func runForever() {
        FileHandle.standardError.write(Data("cuflllm MCP server ready on stdio\n".utf8))
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let responseLine = handleMessageLine(trimmed) {
                if let data = (responseLine + "\n").data(using: .utf8) {
                    FileHandle.standardOutput.write(data)
                }
            }
        }
    }

    public func handleMessageLine(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encodeResponse(id: NSNull(), result: nil, error: (code: -32700, message: "Parse error"))
        }

        let id = json["id"]
        guard let method = json["method"] as? String else {
            if let id {
                return encodeResponse(id: id, result: nil, error: (code: -32600, message: "Invalid Request: missing method"))
            }
            return nil
        }

        // Notifications have no id and expect no JSON-RPC reply
        if id == nil {
            return nil
        }
        let reqId = id!
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let clientProto = params["protocolVersion"] as? String ?? "2024-11-05"
            let result: [String: Any] = [
                "protocolVersion": clientProto,
                "capabilities": [
                    "tools": [:]
                ],
                "serverInfo": [
                    "name": "cuflllm",
                    "version": "0.1.0"
                ]
            ]
            return encodeResponse(id: reqId, result: result, error: nil)

        case "ping":
            return encodeResponse(id: reqId, result: [:], error: nil)

        case "tools/list":
            return encodeResponse(id: reqId, result: ["tools": Self.toolDefinitions()], error: nil)

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return encodeResponse(id: reqId, result: nil, error: (code: -32602, message: "Missing tool name"))
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let toolOutcome = callTool(name: toolName, arguments: args)
            let result: [String: Any] = [
                "content": [
                    ["type": "text", "text": toolOutcome.text]
                ],
                "isError": toolOutcome.isError
            ]
            return encodeResponse(id: reqId, result: result, error: nil)

        default:
            return encodeResponse(id: reqId, result: nil, error: (code: -32601, message: "Method not found: \(method)"))
        }
    }

    private func callTool(name: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
        switch name {
        case "cuflllm_get_screen_state":
            let maxEls = (arguments["max_elements"] as? NSNumber)?.intValue ?? 100
            let ocrRaw = arguments["ocr"] as? String ?? "auto"
            let ocr = OCRMode(rawValue: ocrRaw) ?? .auto
            let windowId = arguments["window_id"] as? String
            let snap = service.captureSnapshot(targetWindowId: windowId, maxElements: maxEls, ocr: ocr)
            return (TreeFormatter.formatSnapshot(snap, maxElements: maxEls), false)

        case "cuflllm_list_windows":
            let windows = service.listWindows()
            return (TreeFormatter.formatWindows(windows), false)

        case "cuflllm_get_menu_bar":
            let items = service.getMenuBar()
            return (TreeFormatter.formatMenu(items), false)

        case "cuflllm_click":
            guard let id = arguments["id"] as? String else {
                return ("Missing required argument 'id'", true)
            }
            let kindStr = arguments["kind"] as? String ?? "single"
            let action: ActionKind = kindStr == "double" ? .doubleClick : (kindStr == "right" ? .rightClick : .click)
            let mode = arguments["click_mode"] as? String
            let res = service.performAction(ActionRequest(action: action, id: id, clickMode: mode))
            return (res.compactText ?? res.message, !res.ok)

        case "cuflllm_type_text":
            guard let text = arguments["text"] as? String else {
                return ("Missing required argument 'text'", true)
            }
            let id = arguments["id"] as? String
            let clearFirst = (arguments["clear_first"] as? Bool) ?? false
            let pressEnter = (arguments["press_enter"] as? Bool) ?? false
            let res = service.performAction(ActionRequest(
                action: .typeText,
                id: id,
                text: text,
                clearFirst: clearFirst,
                pressEnter: pressEnter
            ))
            return (res.compactText ?? res.message, !res.ok)

        case "cuflllm_press_key":
            guard let key = arguments["key"] as? String else {
                return ("Missing required argument 'key'", true)
            }
            let mods = arguments["modifiers"] as? [String] ?? []
            let res = service.performAction(ActionRequest(action: .pressKey, key: key, modifiers: mods))
            return (res.compactText ?? res.message, !res.ok)

        case "cuflllm_scroll":
            let dirStr = arguments["direction"] as? String ?? "down"
            let dir = ScrollDirection(rawValue: dirStr) ?? .down
            let id = arguments["id"] as? String
            let amount = (arguments["amount"] as? NSNumber)?.intValue ?? 360
            let res = service.performAction(ActionRequest(action: .scroll, id: id, direction: dir, amount: amount))
            return (res.compactText ?? res.message, !res.ok)

        case "cuflllm_open_app":
            guard let appName = arguments["app_name"] as? String else {
                return ("Missing required argument 'app_name'", true)
            }
            let res = service.performAction(ActionRequest(action: .openApp, appName: appName))
            return (res.compactText ?? res.message, !res.ok)

        case "cuflllm_focus_window":
            guard let windowId = arguments["window_id"] as? String else {
                return ("Missing required argument 'window_id'", true)
            }
            let res = service.performAction(ActionRequest(action: .focusWindow, windowId: windowId))
            return (res.compactText ?? res.message, !res.ok)

        case "cuflllm_click_menu":
            let id = arguments["id"] as? String
            let menuPath = arguments["menu_path"] as? String
            let res = service.performAction(ActionRequest(action: .clickMenu, id: id, menuPath: menuPath))
            return (res.compactText ?? res.message, !res.ok)

        case "cuflllm_batch":
            guard let data = try? JSONSerialization.data(withJSONObject: arguments),
                  let batchReq = try? JSONDecoder().decode(BatchActionRequest.self, from: data) else {
                return ("Invalid arguments for cuflllm_batch: expected { \"actions\": [...] }", true)
            }
            let res = service.performBatch(batchReq)
            return (res.compactText ?? res.steps.joined(separator: "\n"), !res.ok)

        default:
            return ("Unknown tool '\(name)'", true)
        }
    }

    private func encodeResponse(id: Any, result: [String: Any]?, error: (code: Int, message: String)?) -> String? {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id
        ]
        if let error {
            payload["error"] = [
                "code": error.code,
                "message": error.message
            ]
        } else {
            payload["result"] = result ?? [:]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    public static func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "cuflllm_get_screen_state",
                "description": "Read structured OS accessibility elements (plus optional OCR fallback) for the active macOS window with numbered element IDs like e1, e2.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_id": ["type": "string", "description": "Optional window ID (e.g. w2) to inspect instead of the frontmost window."],
                        "max_elements": ["type": "integer", "description": "Maximum elements to return (default 100)."],
                        "ocr": ["type": "string", "enum": ["auto", "always", "never"], "description": "Vision OCR fallback mode (default auto)."]
                    ]
                ]
            ],
            [
                "name": "cuflllm_click",
                "description": "Click a UI element by its ID (e.g. e3) and return the updated screen state and diff.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Element ID from screen state (e.g. e3)."],
                        "kind": ["type": "string", "enum": ["single", "double", "right"], "description": "Click type (default single)."],
                        "click_mode": ["type": "string", "enum": ["auto", "ax", "mouse"], "description": "Press via Accessibility or mouse coordinates (default auto)."]
                    ],
                    "required": ["id"]
                ]
            ],
            [
                "name": "cuflllm_type_text",
                "description": "Focus/click an optional element ID and type text, optionally clearing existing text or pressing Enter.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Optional target input element ID (e.g. e2)."],
                        "text": ["type": "string", "description": "Text to type."],
                        "clear_first": ["type": "boolean", "description": "Select-all and delete before typing (default false)."],
                        "press_enter": ["type": "boolean", "description": "Press Return after typing (default false)."]
                    ],
                    "required": ["text"]
                ]
            ],
            [
                "name": "cuflllm_press_key",
                "description": "Press a key or keyboard shortcut (e.g. 'return', 'escape', 'cmd+l', or key='s' with modifiers=['cmd']).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string", "description": "Key name or combo like 'cmd+l', 'return', 'escape', 'tab'."],
                        "modifiers": ["type": "array", "items": ["type": "string"], "description": "Optional modifier list: cmd, ctrl, opt, shift."]
                    ],
                    "required": ["key"]
                ]
            ],
            [
                "name": "cuflllm_scroll",
                "description": "Scroll up, down, left, or right over an element or the active window.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Optional element ID to scroll over."],
                        "direction": ["type": "string", "enum": ["up", "down", "left", "right"], "description": "Scroll direction (default down)."],
                        "amount": ["type": "integer", "description": "Scroll distance in pixels (default 360)."]
                    ]
                ]
            ],
            [
                "name": "cuflllm_open_app",
                "description": "Open or bring a macOS application to the front (e.g. 'Notes', 'Safari', 'Finder', 'Terminal').",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app_name": ["type": "string", "description": "Application name or bundle identifier."]
                    ],
                    "required": ["app_name"]
                ]
            ],
            [
                "name": "cuflllm_focus_window",
                "description": "Switch focus to another visible window ID from OTHER_WINDOWS or cuflllm_list_windows (e.g. w2).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "window_id": ["type": "string", "description": "Window ID such as w1, w2."]
                    ],
                    "required": ["window_id"]
                ]
            ],
            [
                "name": "cuflllm_list_windows",
                "description": "List all visible on-screen macOS application windows with IDs and bounds.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "cuflllm_get_menu_bar",
                "description": "Inspect the frontmost app's top menu bar items (e.g. File > New Window) with IDs and keyboard shortcuts.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "cuflllm_click_menu",
                "description": "Trigger a menu bar item by ID (m12) or path ('File > New Window').",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "Menu item ID from cuflllm_get_menu_bar."],
                        "menu_path": ["type": "string", "description": "Menu path such as 'File > Save...'."]
                    ]
                ]
            ],
            [
                "name": "cuflllm_batch",
                "description": "Execute multiple deterministic UI actions in one fast round-trip and return the final screen diff + snapshot.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "actions": [
                            "type": "array",
                            "description": "Sequence of ActionRequest objects (e.g. [{\"action\":\"click\",\"id\":\"e3\"},{\"action\":\"type_text\",\"text\":\"youtube.com\",\"press_enter\":true}]).",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "action": ["type": "string"],
                                    "id": ["type": "string"],
                                    "text": ["type": "string"],
                                    "clear_first": ["type": "boolean"],
                                    "press_enter": ["type": "boolean"],
                                    "key": ["type": "string"],
                                    "modifiers": ["type": "array", "items": ["type": "string"]],
                                    "direction": ["type": "string"],
                                    "amount": ["type": "integer"],
                                    "app_name": ["type": "string"],
                                    "window_id": ["type": "string"],
                                    "settle_ms": ["type": "integer"]
                                ],
                                "required": ["action"]
                            ]
                        ],
                        "stop_on_error": ["type": "boolean", "description": "Stop immediately if a step fails (default true)."],
                        "step_settle_ms": ["type": "integer", "description": "Wait time between intermediate steps in ms (default 90)."],
                        "final_settle_ms": ["type": "integer", "description": "Wait time after final step before snapshotting (default 150/450)."]
                    ],
                    "required": ["actions"]
                ]
            ]
        ]
    }
}
