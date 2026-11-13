import CuflCore
import Foundation

private func printUsage() {
    let usage = """
    cuflllm — Computer Use For LLMs (macOS Accessibility + OCR Service)

    USAGE:
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
    """
    print(usage)
}

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

private func flagValue(_ args: [String], name: String) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

private func positionalArgs(_ args: [String], valueFlags: Set<String>) -> [String] {
    var result: [String] = []
    var skipNext = false
    for arg in args {
        if skipNext {
            skipNext = false
            continue
        }
        if valueFlags.contains(arg) {
            skipNext = true
            continue
        }
        if arg.hasPrefix("--") {
            continue
        }
        result.append(arg)
    }
    return result
}

private func isElementId(_ token: String) -> Bool {
    guard token.hasPrefix("e"), token.count > 1 else { return false }
    return token.dropFirst().allSatisfy(\.isNumber)
}

let allArgs = Array(CommandLine.arguments.dropFirst())
guard let command = allArgs.first else {
    printUsage()
    exit(0)
}

let subArgs = Array(allArgs.dropFirst())
let jsonOutput = subArgs.contains("--json")
let service = CuflService()

switch command {
case "help", "--help", "-h":
    printUsage()

case "doctor":
    let report = service.doctor(
        promptAccessibility: subArgs.contains("--prompt"),
        promptScreenRecording: subArgs.contains("--prompt-screen")
    )
    if jsonOutput {
        printJSON(report)
    } else {
        print("Accessibility Trusted : \(report.accessibilityTrusted ? "YES" : "NO")")
        print("Screen Recording Ready: \(report.screenRecordingTrusted ? "YES" : "NO (optional OCR fallback)")")
        print("Frontmost App         : \(report.frontmostApp ?? "(unknown)")")
        print("Visible Windows       : \(report.visibleWindowCount)")
        for note in report.notes {
            print("- \(note)")
        }
    }

case "windows":
    let windows = service.listWindows()
    if jsonOutput {
        printJSON(windows)
    } else {
        print(TreeFormatter.formatWindows(windows))
    }

case "snapshot", "state":
    let windowId = flagValue(subArgs, name: "--window")
    let maxEls = Int(flagValue(subArgs, name: "--max") ?? "100") ?? 100
    let ocr = OCRMode(rawValue: flagValue(subArgs, name: "--ocr") ?? "auto") ?? .auto
    let snap = service.captureSnapshot(targetWindowId: windowId, maxElements: maxEls, ocr: ocr)
    if jsonOutput {
        printJSON(snap)
    } else {
        print(TreeFormatter.formatSnapshot(snap, maxElements: maxEls))
    }

case "menu":
    let items = service.getMenuBar()
    if jsonOutput {
        printJSON(items)
    } else {
        print(TreeFormatter.formatMenu(items))
    }

case "click":
    let pos = positionalArgs(subArgs, valueFlags: ["--mode"])
    guard let id = pos.first else {
        fputs("Error: cuflllm click requires an element id (e.g. cuflllm click e3)\n", stderr)
        exit(1)
    }
    let kind: ActionKind = subArgs.contains("--double") ? .doubleClick : (subArgs.contains("--right") ? .rightClick : .click)
    let mode = flagValue(subArgs, name: "--mode")
    let res = service.performAction(ActionRequest(action: kind, id: id, clickMode: mode))
    if jsonOutput {
        printJSON(res)
    } else {
        print(res.compactText ?? res.message)
    }
    if !res.ok { exit(1) }

case "type":
    let pos = positionalArgs(subArgs, valueFlags: ["--id", "--text"])
    let explicitId = flagValue(subArgs, name: "--id")
    let explicitText = flagValue(subArgs, name: "--text")
    let targetId: String?
    let text: String

    if let explicitText {
        targetId = explicitId ?? pos.first(where: { isElementId($0) })
        text = explicitText
    } else if pos.count >= 2 && isElementId(pos[0]) {
        targetId = pos[0]
        text = pos.dropFirst().joined(separator: " ")
    } else if let first = pos.first {
        targetId = explicitId
        text = pos.joined(separator: " ")
        _ = first
    } else {
        fputs("Error: cuflllm type requires text (e.g. cuflllm type e2 \"hello\" --enter)\n", stderr)
        exit(1)
    }

    let res = service.performAction(ActionRequest(
        action: .typeText,
        id: targetId,
        text: text,
        clearFirst: subArgs.contains("--clear"),
        pressEnter: subArgs.contains("--enter")
    ))
    if jsonOutput {
        printJSON(res)
    } else {
        print(res.compactText ?? res.message)
    }
    if !res.ok { exit(1) }

case "key":
    let pos = positionalArgs(subArgs, valueFlags: [])
    guard let keySpec = pos.first else {
        fputs("Error: cuflllm key requires a key or shortcut (e.g. cuflllm key cmd+l)\n", stderr)
        exit(1)
    }
    let res = service.performAction(ActionRequest(action: .pressKey, key: keySpec))
    if jsonOutput {
        printJSON(res)
    } else {
        print(res.compactText ?? res.message)
    }
    if !res.ok { exit(1) }

case "scroll":
    let pos = positionalArgs(subArgs, valueFlags: ["--id", "--amount"])
    let dir = ScrollDirection(rawValue: pos.first ?? "down") ?? .down
    let id = flagValue(subArgs, name: "--id")
    let amount = Int(flagValue(subArgs, name: "--amount") ?? "360") ?? 360
    let res = service.performAction(ActionRequest(action: .scroll, id: id, direction: dir, amount: amount))
    if jsonOutput {
        printJSON(res)
    } else {
        print(res.compactText ?? res.message)
    }
    if !res.ok { exit(1) }

case "open":
    let pos = positionalArgs(subArgs, valueFlags: [])
    guard !pos.isEmpty else {
        fputs("Error: cuflllm open requires an application name (e.g. cuflllm open Notes)\n", stderr)
        exit(1)
    }
    let res = service.performAction(ActionRequest(action: .openApp, appName: pos.joined(separator: " ")))
    if jsonOutput {
        printJSON(res)
    } else {
        print(res.compactText ?? res.message)
    }
    if !res.ok { exit(1) }

case "focus":
    let pos = positionalArgs(subArgs, valueFlags: [])
    guard let winId = pos.first else {
        fputs("Error: cuflllm focus requires a window id (e.g. cuflllm focus w2)\n", stderr)
        exit(1)
    }
    let res = service.performAction(ActionRequest(action: .focusWindow, windowId: winId))
    if jsonOutput {
        printJSON(res)
    } else {
        print(res.compactText ?? res.message)
    }
    if !res.ok { exit(1) }

case "menu-click":
    let pos = positionalArgs(subArgs, valueFlags: [])
    guard !pos.isEmpty else {
        fputs("Error: cuflllm menu-click requires a menu id (m4) or path (\"File > New\")\n", stderr)
        exit(1)
    }
    let raw = pos.joined(separator: " ")
    let req: ActionRequest
    if raw.hasPrefix("m"), raw.dropFirst().allSatisfy(\.isNumber) {
        req = ActionRequest(action: .clickMenu, id: raw)
    } else {
        req = ActionRequest(action: .clickMenu, menuPath: raw)
    }
    let res = service.performAction(req)
    if jsonOutput {
        printJSON(res)
    } else {
        print(res.compactText ?? res.message)
    }
    if !res.ok { exit(1) }

case "act":
    guard let rawJSON = subArgs.first, let data = rawJSON.data(using: .utf8) else {
        fputs("Error: cuflllm act requires a JSON ActionRequest argument\n", stderr)
        exit(1)
    }
    do {
        let req = try JSONDecoder().decode(ActionRequest.self, from: data)
        let res = service.performAction(req)
        printJSON(res)
        if !res.ok { exit(1) }
    } catch {
        fputs("Invalid ActionRequest JSON: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

case "batch":
    guard let rawJSON = subArgs.first, let data = rawJSON.data(using: .utf8) else {
        fputs("Error: cuflllm batch requires a JSON BatchActionRequest argument\n", stderr)
        exit(1)
    }
    do {
        let req = try JSONDecoder().decode(BatchActionRequest.self, from: data)
        let res = service.performBatch(req)
        if jsonOutput {
            printJSON(res)
        } else {
            print(res.compactText ?? res.steps.joined(separator: "\n"))
        }
        if !res.ok { exit(1) }
    } catch {
        fputs("Invalid BatchActionRequest JSON: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

case "serve":
    let host = flagValue(subArgs, name: "--host") ?? "127.0.0.1"
    let portVal = UInt16(flagValue(subArgs, name: "--port") ?? "8787") ?? 8787
    let server = HTTPServer(service: service, host: host, port: portVal)
    do {
        try server.runForever()
    } catch {
        fputs("HTTP server error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }

case "mcp":
    let mcp = MCPServer(service: service)
    mcp.runForever()

default:
    fputs("Unknown command '\(command)'\n", stderr)
    printUsage()
    exit(1)
}
