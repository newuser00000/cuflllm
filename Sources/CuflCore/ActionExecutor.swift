import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct ParsedKeyCombo: Sendable, Equatable {
    public let keyCode: CGKeyCode
    public let flags: CGEventFlags
    public let normalizedName: String
}

public enum KeyMapper {
    private static let keyMap: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48,
        "space": 49, " ": 49,
        "`": 50,
        "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53,
        "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101,
        "f11": 103, "f13": 105, "f16": 106, "f14": 107, "f10": 109,
        "f12": 111, "f15": 113,
        "home": 115, "pageup": 116, "page_up": 116,
        "forwarddelete": 117, "forward_delete": 117,
        "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "page_down": 121,
        "f1": 122,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]

    public static func parseKeySpec(key: String, modifiers: [String] = []) -> ParsedKeyCombo? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var allMods = modifiers.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        var keyToken = trimmed.lowercased()

        // Support combined specs like "cmd+shift+p" or "ctrl+c"
        if keyToken.contains("+") && keyToken != "+" {
            let parts = keyToken.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if let last = parts.last, !last.isEmpty {
                allMods.append(contentsOf: parts.dropLast())
                keyToken = last
            }
        }

        guard let code = keyMap[keyToken] else {
            return nil
        }

        var flags = CGEventFlags()
        var modLabels: [String] = []
        for mod in allMods {
            switch mod {
            case "cmd", "command", "meta", "super":
                flags.insert(.maskCommand)
                if !modLabels.contains("cmd") { modLabels.append("cmd") }
            case "ctrl", "control":
                flags.insert(.maskControl)
                if !modLabels.contains("ctrl") { modLabels.append("ctrl") }
            case "opt", "option", "alt":
                flags.insert(.maskAlternate)
                if !modLabels.contains("opt") { modLabels.append("opt") }
            case "shift":
                flags.insert(.maskShift)
                if !modLabels.contains("shift") { modLabels.append("shift") }
            default:
                break
            }
        }

        let label = (modLabels + [keyToken]).joined(separator: "+")
        return ParsedKeyCombo(keyCode: code, flags: flags, normalizedName: label)
    }
}

public final class ActionExecutor: Sendable {
    public init() {}

    public func activateApp(pid: Int32) {
        guard pid > 0 else { return }
        if AccessibilityEngine.systemFrontmostPid() == pid {
            return
        }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.15)
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
    }

    public func focusElement(_ element: AXUIElement, pid: Int32) -> Bool {
        activateApp(pid: pid)
        let err = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return err == .success
    }

    public func clickElement(
        node: UIElementNode,
        axRef: AXUIElement?,
        pid: Int32,
        mode: String = "auto"
    ) -> (ok: Bool, message: String) {
        activateApp(pid: pid)

        let useAXOnly = (mode == "ax")
        let useMouseOnly = (mode == "mouse" || node.source == .ocr)

        if !useMouseOnly, let axRef, node.actions.contains("press") {
            let err = AXUIElementPerformAction(axRef, kAXPressAction as CFString)
            if err == .success {
                return (true, "Pressed \(node.id) (\(node.role) \(TreeFormatter.quote(node.label, maxLength: 40))) via AXPress")
            }
            if useAXOnly {
                return (false, "AXPress failed on \(node.id) with error \(err.rawValue)")
            }
        } else if useAXOnly {
            return (false, "Element \(node.id) does not support AXPress")
        }

        let cx = node.bounds.centerX
        let cy = node.bounds.centerY
        let ok = clickPoint(x: cx, y: cy, button: .left, clickCount: 1)
        if ok {
            return (true, "Clicked \(node.id) (\(node.role) \(TreeFormatter.quote(node.label, maxLength: 40))) at (\(Int(cx.rounded())), \(Int(cy.rounded())))")
        }
        return (false, "Failed to post mouse click at (\(Int(cx.rounded())), \(Int(cy.rounded())))")
    }

    public func doubleClickElement(node: UIElementNode, pid: Int32) -> (ok: Bool, message: String) {
        activateApp(pid: pid)
        let cx = node.bounds.centerX
        let cy = node.bounds.centerY
        let ok = clickPoint(x: cx, y: cy, button: .left, clickCount: 2)
        return ok
            ? (true, "Double-clicked \(node.id) at (\(Int(cx.rounded())), \(Int(cy.rounded())))")
            : (false, "Failed to double-click \(node.id)")
    }

    public func rightClickElement(node: UIElementNode, pid: Int32) -> (ok: Bool, message: String) {
        activateApp(pid: pid)
        let cx = node.bounds.centerX
        let cy = node.bounds.centerY
        let ok = clickPoint(x: cx, y: cy, button: .right, clickCount: 1)
        return ok
            ? (true, "Right-clicked \(node.id) at (\(Int(cx.rounded())), \(Int(cy.rounded())))")
            : (false, "Failed to right-click \(node.id)")
    }

    public func clickPoint(x: Double, y: Double, button: CGMouseButton = .left, clickCount: Int64 = 1) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let point = CGPoint(x: x, y: y)

        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.008)
        }

        let downType: CGEventType = (button == .right) ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = (button == .right) ? .rightMouseUp : .leftMouseUp

        for clickIdx in 1...max(1, clickCount) {
            guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
                  let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
                return false
            }
            down.setIntegerValueField(.mouseEventClickState, value: clickIdx)
            up.setIntegerValueField(.mouseEventClickState, value: clickIdx)
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.008)
            up.post(tap: .cghidEventTap)
            if clickIdx < clickCount {
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        return true
    }

    public func typeText(
        text: String,
        targetNode: UIElementNode?,
        axRef: AXUIElement?,
        pid: Int32,
        clearFirst: Bool,
        pressEnter: Bool
    ) -> (ok: Bool, message: String) {
        if pid > 0 {
            activateApp(pid: pid)
        }

        if let node = targetNode {
            var focused = false
            if let axRef, node.source == .ax {
                focused = focusElement(axRef, pid: pid)
            }
            if !focused || node.source == .ocr {
                _ = clickPoint(x: node.bounds.centerX, y: node.bounds.centerY)
                Thread.sleep(forTimeInterval: 0.03)
            }
        }

        if clearFirst {
            _ = pressKeyCombo(key: "a", modifiers: ["cmd"])
            Thread.sleep(forTimeInterval: 0.015)
            _ = pressKeyCombo(key: "backspace", modifiers: [])
            Thread.sleep(forTimeInterval: 0.015)
        }

        if !text.isEmpty {
            let lines = text.components(separatedBy: "\n")
            for (idx, segment) in lines.enumerated() {
                if !segment.isEmpty {
                    guard postUnicodeString(segment) else {
                        return (false, "Failed to post unicode text input")
                    }
                }
                if idx < lines.count - 1 {
                    _ = pressKeyCombo(key: "return", modifiers: [])
                    Thread.sleep(forTimeInterval: 0.008)
                }
            }
        }

        if pressEnter {
            Thread.sleep(forTimeInterval: 0.015)
            _ = pressKeyCombo(key: "return", modifiers: [])
        }

        let targetDesc = targetNode.map { " into \($0.id)" } ?? ""
        let enterNote = pressEnter ? " + Enter" : ""
        return (true, "Typed \(text.count) chars\(targetDesc)\(enterNote)")
    }

    public func pressKeyCombo(key: String, modifiers: [String]) -> (ok: Bool, message: String) {
        guard let combo = KeyMapper.parseKeySpec(key: key, modifiers: modifiers) else {
            return (false, "Unsupported key '\(key)'")
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false) else {
            return (false, "Failed to create keyboard event for '\(combo.normalizedName)'")
        }

        down.flags = combo.flags
        // Clear flags on key-up so modifier state never stays latched for subsequent keystrokes.
        up.flags = []
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.008)
        up.post(tap: .cghidEventTap)
        return (true, "Pressed \(combo.normalizedName)")
    }

    public func scroll(
        direction: ScrollDirection,
        amount: Int,
        at point: CGPoint?
    ) -> (ok: Bool, message: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return (false, "Failed to create HID event source")
        }
        if let point {
            if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
                move.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.008)
            }
        }

        let pixels = Int32(max(40, min(amount, 3000)))
        var dy: Int32 = 0
        var dx: Int32 = 0
        switch direction {
        case .down: dy = -pixels
        case .up: dy = pixels
        case .right: dx = -pixels
        case .left: dx = pixels
        }

        let steps = 3
        let stepDy = dy / Int32(steps)
        let stepDx = dx / Int32(steps)
        for _ in 0..<steps {
            guard let ev = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: stepDy,
                wheel2: stepDx,
                wheel3: 0
            ) else {
                return (false, "Failed to create scroll event")
            }
            ev.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
        }

        return (true, "Scrolled \(direction.rawValue) by \(pixels)px")
    }

    public func openApplication(name: String) -> (ok: Bool, message: String) {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return (false, "Application name cannot be empty")
        }

        let lowered = query.lowercased()
        let running = NSWorkspace.shared.runningApplications.first { app in
            (app.localizedName?.lowercased() == lowered) ||
            (app.bundleIdentifier?.lowercased() == lowered)
        }
        if let running {
            let hasWindows = prepareRunningAppWindows(pid: running.processIdentifier)
            activateApp(pid: running.processIdentifier)
            if running.isFinishedLaunching, hasWindows,
               waitForFrontmostPid(running.processIdentifier, timeout: 0.15) {
                return (true, "Activated \(running.localizedName ?? query)")
            }
            if let bundleURL = running.bundleURL {
                return launchApp(at: bundleURL, label: running.localizedName ?? query)
            }
            return (true, "Activated \(running.localizedName ?? query)")
        }

        if let byBundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
            return launchApp(at: byBundle, label: query)
        }

        if let appURL = findApplicationURL(named: query) {
            return launchApp(at: appURL, label: query)
        }

        return (false, "Could not find application '\(query)'")
    }

    public func focusWindow(window: WindowInfo, axWindow: AXUIElement?) -> (ok: Bool, message: String) {
        activateApp(pid: window.pid)
        if !waitForFrontmostPid(window.pid, timeout: 0.12),
           let bundleURL = NSRunningApplication(processIdentifier: window.pid)?.bundleURL {
            _ = launchApp(at: bundleURL, label: window.appName)
        }
        if let axWindow {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        return (true, "Focused window \(window.id) (\(window.appName): \(TreeFormatter.quote(window.title, maxLength: 50)))")
    }

    public func clickMenuItem(item: MenuItemInfo, axRef: AXUIElement, pid: Int32) -> (ok: Bool, message: String) {
        activateApp(pid: pid)
        let err = AXUIElementPerformAction(axRef, kAXPressAction as CFString)
        if err == .success {
            return (true, "Triggered menu item \(item.id): \(item.path)")
        }
        return (false, "Failed to trigger menu item \(item.path) (error \(err.rawValue))")
    }

    // MARK: - Private Helpers

    private func prepareRunningAppWindows(pid: Int32) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.35)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AnyObject],
              !windows.isEmpty else {
            return false
        }
        var anyVisible = false
        var firstMinimized: AXUIElement?
        for item in windows where CFGetTypeID(item) == AXUIElementGetTypeID() {
            let win = unsafeDowncast(item, to: AXUIElement.self)
            var minRef: CFTypeRef?
            let isMin = (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success)
                && ((minRef as? Bool) == true || (minRef as? NSNumber)?.boolValue == true)
            if isMin {
                if firstMinimized == nil { firstMinimized = win }
            } else {
                anyVisible = true
                break
            }
        }
        if !anyVisible, let win = firstMinimized {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
        return true
    }

    private func waitForFrontmostPid(_ pid: Int32, timeout: TimeInterval) -> Bool {
        guard pid > 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while AccessibilityEngine.systemFrontmostPid() != pid, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.015)
        }
        return AccessibilityEngine.systemFrontmostPid() == pid
    }

    private func launchApp(at url: URL, label: String) -> (ok: Bool, message: String) {
        let sem = DispatchSemaphore(value: 0)
        final class LaunchBox: @unchecked Sendable {
            var error: Error?
            var pid: Int32 = 0
        }
        let box = LaunchBox()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, err in
            box.pid = app?.processIdentifier ?? 0
            box.error = err
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5.0)
        if let err = box.error {
            return (false, "Failed to open \(label): \(err.localizedDescription)")
        }
        if box.pid > 0 {
            _ = waitForFrontmostPid(box.pid, timeout: 0.45)
        }
        return (true, "Opened \(url.deletingPathExtension().lastPathComponent)")
    }

    private func findApplicationURL(named query: String) -> URL? {
        let clean = query.hasSuffix(".app") ? String(query.dropLast(4)) : query
        let lowered = clean.lowercased()
        let fm = FileManager.default
        let searchDirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(NSHomeDirectory())/Applications"
        ]

        // Exact match pass first
        for dir in searchDirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("\(clean).app")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Case-insensitive & prefix match pass
        for dir in searchDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let stem = String(entry.dropLast(4)).lowercased()
                if stem == lowered || stem.contains(lowered) {
                    return URL(fileURLWithPath: dir).appendingPathComponent(entry)
                }
            }
        }
        return nil
    }

    private func postUnicodeString(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let utf16 = Array(text.utf16)
        let chunkSize = 32
        var offset = 0

        while offset < utf16.count {
            let end = min(offset + chunkSize, utf16.count)
            var slice = Array(utf16[offset..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            offset = end
            if offset < utf16.count {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        return true
    }
}
