import AppKit
import ApplicationServices
import Foundation

public final class CuflService: @unchecked Sendable {
    private let engine = AccessibilityEngine()
    private let executor = ActionExecutor()
    private let lock = NSLock()

    private var lastSnapshot: ScreenSnapshot?
    private var elementRefs: [String: AXRefBox] = [:]
    private var windowRefs: [String: AXRefBox] = [:]
    private var menuItems: [MenuItemInfo] = []
    private var menuRefs: [String: AXRefBox] = [:]
    private var menuPid: Int32 = 0

    private let cacheURL: URL

    public init(cacheDirectory: URL? = nil) {
        let baseDir = cacheDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("cufl", isDirectory: true)
        self.cacheURL = baseDir.appendingPathComponent("last_snapshot.json")
        self.lastSnapshot = loadCachedSnapshot()
    }

    public func doctor(promptAccessibility: Bool = false, promptScreenRecording: Bool = false) -> DoctorReport {
        let axTrusted = engine.isTrusted(prompt: promptAccessibility)
        if promptScreenRecording && !OCRFallback.isScreenRecordingTrusted() {
            OCRFallback.requestScreenRecordingAccess()
        }
        let srTrusted = OCRFallback.isScreenRecordingTrusted()
        let windows = engine.listWindows()
        let livePid = engine.liveFrontmostPid()
        let frontApp = (livePid > 0 ? NSRunningApplication(processIdentifier: livePid)?.localizedName : nil)
            ?? NSWorkspace.shared.frontmostApplication?.localizedName

        var notes: [String] = []
        if !axTrusted {
            notes.append("Accessibility NOT trusted: grant access to your terminal/binary in System Settings > Privacy & Security > Accessibility.")
        } else {
            notes.append("Accessibility permission is active.")
        }
        if !srTrusted {
            notes.append("Screen Recording NOT granted (optional: only needed for Vision OCR fallback on non-accessible canvas/custom apps).")
        } else {
            notes.append("Screen Recording permission is active (OCR fallback ready).")
        }

        return DoctorReport(
            accessibilityTrusted: axTrusted,
            screenRecordingTrusted: srTrusted,
            frontmostApp: frontApp,
            visibleWindowCount: windows.count,
            notes: notes
        )
    }

    public func listWindows() -> [WindowInfo] {
        engine.listWindows()
    }

    public func captureSnapshot(
        targetWindowId: String? = nil,
        maxElements: Int = 100,
        ocr: OCRMode = .auto
    ) -> ScreenSnapshot {
        let captured = engine.captureSnapshot(targetWindowId: targetWindowId, maxElements: maxElements)
        var snapshot = captured.snapshot

        let shouldRunOCR: Bool
        switch ocr {
        case .never:
            shouldRunOCR = false
        case .always:
            shouldRunOCR = snapshot.focusedWindow != nil
        case .auto:
            let winW = snapshot.focusedWindow?.bounds.width ?? 0
            let interactiveCount = snapshot.elements.filter(\.isInteractive).count
            shouldRunOCR = snapshot.focusedWindow != nil && winW > 120 && (snapshot.elements.count < 4 || interactiveCount == 0)
        }

        if shouldRunOCR, let win = snapshot.focusedWindow {
            let ocrOut = OCRFallback.recognizeWindowText(
                window: win,
                startingIdIndex: snapshot.elements.count + 1,
                maxItems: max(20, maxElements - snapshot.elements.count)
            )
            if !ocrOut.elements.isEmpty {
                snapshot.elements.append(contentsOf: ocrOut.elements)
            }
            if let note = ocrOut.note {
                snapshot.notes.append(note)
            }
        }

        lock.lock()
        self.lastSnapshot = snapshot
        self.elementRefs = captured.elementRefs
        self.windowRefs = captured.windowRefs
        lock.unlock()

        saveCachedSnapshot(snapshot)
        return snapshot
    }

    public func getMenuBar() -> [MenuItemInfo] {
        let frontPid = engine.liveFrontmostPid()
        let result = engine.captureMenuBar(pid: frontPid > 0 ? frontPid : nil)
        lock.lock()
        self.menuItems = result.items
        self.menuRefs = result.refs
        self.menuPid = frontPid
        lock.unlock()
        return result.items
    }

    public func performAction(_ request: ActionRequest) -> ActionResult {
        lock.lock()
        var currentSnap = self.lastSnapshot
        var currentElementRefs = self.elementRefs
        var currentWindowRefs = self.windowRefs
        var currentMenuItems = self.menuItems
        var currentMenuRefs = self.menuRefs
        let currentMenuPid = self.menuPid
        lock.unlock()

        let needsSnapshot = (request.id != nil)
            || request.action == .focusWindow
            || (request.action == .scroll && currentSnap == nil)

        if currentSnap == nil && needsSnapshot {
            let fresh = captureSnapshot(maxElements: request.maxElements ?? 100, ocr: request.ocr ?? .auto)
            lock.lock()
            currentSnap = fresh
            currentElementRefs = self.elementRefs
            currentWindowRefs = self.windowRefs
            lock.unlock()
        }

        let previousSnapshot = currentSnap
        let targetPid = currentSnap?.frontPid ?? engine.liveFrontmostPid()

        var outcome: (ok: Bool, message: String) = (false, "Unhandled action")

        switch request.action {
        case .click:
            guard let id = request.id else {
                return ActionResult(ok: false, message: "Missing required 'id' for click")
            }
            guard let node = currentSnap?.elements.first(where: { $0.id == id }) else {
                return ActionResult(ok: false, message: "Unknown element id '\(id)'. Call get_screen_state first.")
            }
            outcome = executor.clickElement(
                node: node,
                axRef: currentElementRefs[id]?.element,
                pid: targetPid,
                mode: request.clickMode ?? "auto"
            )

        case .doubleClick:
            guard let id = request.id else {
                return ActionResult(ok: false, message: "Missing required 'id' for double_click")
            }
            guard let node = currentSnap?.elements.first(where: { $0.id == id }) else {
                return ActionResult(ok: false, message: "Unknown element id '\(id)'. Call get_screen_state first.")
            }
            outcome = executor.doubleClickElement(node: node, pid: targetPid)

        case .rightClick:
            guard let id = request.id else {
                return ActionResult(ok: false, message: "Missing required 'id' for right_click")
            }
            guard let node = currentSnap?.elements.first(where: { $0.id == id }) else {
                return ActionResult(ok: false, message: "Unknown element id '\(id)'. Call get_screen_state first.")
            }
            outcome = executor.rightClickElement(node: node, pid: targetPid)

        case .clickPoint:
            guard let x = request.x, let y = request.y else {
                return ActionResult(ok: false, message: "Missing required 'x' and 'y' for click_point")
            }
            let ok = executor.clickPoint(x: x, y: y)
            outcome = ok
                ? (true, "Clicked screen point (\(Int(x.rounded())), \(Int(y.rounded())))")
                : (false, "Failed to click screen point (\(x), \(y))")

        case .typeText:
            let text = request.text ?? ""
            var targetNode: UIElementNode?
            var axRef: AXUIElement?
            if let id = request.id {
                guard let node = currentSnap?.elements.first(where: { $0.id == id }) else {
                    return ActionResult(ok: false, message: "Unknown element id '\(id)'. Call get_screen_state first.")
                }
                targetNode = node
                axRef = currentElementRefs[id]?.element
            }
            outcome = executor.typeText(
                text: text,
                targetNode: targetNode,
                axRef: axRef,
                pid: targetNode != nil ? targetPid : 0,
                clearFirst: request.clearFirst ?? false,
                pressEnter: request.pressEnter ?? false
            )

        case .pressKey:
            guard let key = request.key else {
                return ActionResult(ok: false, message: "Missing required 'key' for press_key")
            }
            outcome = executor.pressKeyCombo(key: key, modifiers: request.modifiers ?? [])

        case .scroll:
            let dir = request.direction ?? .down
            let amount = request.amount ?? 360
            var scrollPoint: CGPoint?
            if let id = request.id, let node = currentSnap?.elements.first(where: { $0.id == id }) {
                scrollPoint = CGPoint(x: node.bounds.centerX, y: node.bounds.centerY)
            } else if let win = currentSnap?.focusedWindow {
                scrollPoint = CGPoint(x: win.bounds.centerX, y: win.bounds.centerY)
            }
            if targetPid > 0 {
                executor.activateApp(pid: targetPid)
            }
            outcome = executor.scroll(direction: dir, amount: amount, at: scrollPoint)

        case .focus:
            guard let id = request.id else {
                return ActionResult(ok: false, message: "Missing required 'id' for focus")
            }
            guard let node = currentSnap?.elements.first(where: { $0.id == id }) else {
                return ActionResult(ok: false, message: "Unknown element id '\(id)'.")
            }
            if let axRef = currentElementRefs[id]?.element, executor.focusElement(axRef, pid: targetPid) {
                outcome = (true, "Focused \(id)")
            } else {
                let ok = executor.clickPoint(x: node.bounds.centerX, y: node.bounds.centerY)
                outcome = ok ? (true, "Focused \(id) via click") : (false, "Failed to focus \(id)")
            }

        case .openApp:
            guard let appName = request.appName else {
                return ActionResult(ok: false, message: "Missing required 'app_name' for open_app")
            }
            outcome = executor.openApplication(name: appName)

        case .focusWindow:
            guard let windowId = request.windowId else {
                return ActionResult(ok: false, message: "Missing required 'window_id' for focus_window")
            }
            let liveWindows = engine.listWindows()
            guard let win = liveWindows.first(where: { $0.id == windowId })
                ?? currentSnap?.windows.first(where: { $0.id == windowId }) else {
                return ActionResult(ok: false, message: "Unknown window_id '\(windowId)'.")
            }
            let axWin = currentWindowRefs[windowId]?.element ?? engine.resolveWindowElement(windowId: windowId, windows: liveWindows)
            outcome = executor.focusWindow(window: win, axWindow: axWin)

        case .clickMenu:
            let livePid = engine.liveFrontmostPid()
            if currentMenuItems.isEmpty || (livePid > 0 && currentMenuPid != livePid) {
                let refreshed = getMenuBar()
                lock.lock()
                currentMenuItems = refreshed
                currentMenuRefs = self.menuRefs
                lock.unlock()
            }
            let match: MenuItemInfo?
            if let id = request.id {
                match = currentMenuItems.first(where: { $0.id == id })
            } else if let path = request.menuPath {
                let q = path.lowercased()
                match = currentMenuItems.first(where: { $0.path.lowercased() == q })
                    ?? currentMenuItems.first(where: { $0.path.lowercased().contains(q) })
            } else {
                return ActionResult(ok: false, message: "Provide either 'id' (e.g. m12) or 'menu_path' (e.g. 'File > New Window').")
            }

            guard let found = match, let axRef = currentMenuRefs[found.id]?.element else {
                return ActionResult(ok: false, message: "Menu item not found. Call get_menu_bar first to inspect available menu items.")
            }
            outcome = executor.clickMenuItem(item: found, axRef: axRef, pid: livePid > 0 ? livePid : targetPid)
        }

        let defaultSettle: Int
        if request.action == .openApp {
            defaultSettle = outcome.message.hasPrefix("Activated ") ? 100 : 450
        } else {
            defaultSettle = 150
        }
        let settleMs = max(0, min(request.settleMs ?? defaultSettle, 5000))
        if outcome.ok && settleMs > 0 {
            Thread.sleep(forTimeInterval: Double(settleMs) / 1000.0)
        }

        let shouldIncludeSnapshot = request.includeSnapshot ?? true
        if !shouldIncludeSnapshot {
            return ActionResult(ok: outcome.ok, message: outcome.message)
        }

        let updatedSnapshot = captureSnapshot(
            targetWindowId: request.action == .focusWindow ? request.windowId : nil,
            maxElements: request.maxElements ?? 100,
            ocr: request.ocr ?? .auto
        )
        let diff = TreeFormatter.computeDiff(previous: previousSnapshot, current: updatedSnapshot)
        let textBlock = formatActionText(ok: outcome.ok, message: outcome.message, diff: diff, snapshot: updatedSnapshot, maxElements: request.maxElements ?? 100)

        return ActionResult(
            ok: outcome.ok,
            message: outcome.message,
            diff: diff,
            snapshot: updatedSnapshot,
            compactText: textBlock
        )
    }

    public func performBatch(_ request: BatchActionRequest) -> BatchActionResult {
        guard !request.actions.isEmpty else {
            return BatchActionResult(
                ok: false,
                completedCount: 0,
                totalCount: 0,
                steps: ["ERROR: Batch 'actions' array cannot be empty."]
            )
        }

        lock.lock()
        let beforeBatchSnapshot = self.lastSnapshot
        lock.unlock()

        let stopOnError = request.stopOnError ?? true
        let defaultStepSettle = max(0, min(request.stepSettleMs ?? 90, 5000))
        var stepsLog: [String] = []
        var completed = 0
        var allOk = true
        var lastFocusWindowId: String?

        for (index, var step) in request.actions.enumerated() {
            let isLast = (index == request.actions.count - 1)
            step.includeSnapshot = false
            if step.settleMs == nil {
                if isLast {
                    if let finalMs = request.finalSettleMs {
                        step.settleMs = finalMs
                    } else if step.action != .openApp {
                        step.settleMs = 150
                    }
                } else if step.action != .openApp {
                    step.settleMs = defaultStepSettle
                }
            }
            if step.action == .focusWindow {
                lastFocusWindowId = step.windowId
            } else if step.action == .openApp {
                lastFocusWindowId = nil
            }

            let stepResult = performAction(step)
            stepsLog.append("[\(index + 1)/\(request.actions.count)] \(stepResult.ok ? "OK" : "ERROR"): \(stepResult.message)")
            if stepResult.ok {
                completed += 1
            } else {
                allOk = false
                if stopOnError { break }
            }
        }

        let shouldIncludeSnapshot = request.includeSnapshot ?? true
        if !shouldIncludeSnapshot {
            return BatchActionResult(
                ok: allOk,
                completedCount: completed,
                totalCount: request.actions.count,
                steps: stepsLog
            )
        }

        let maxEls = request.maxElements ?? 100
        let updatedSnapshot = captureSnapshot(
            targetWindowId: lastFocusWindowId,
            maxElements: maxEls,
            ocr: request.ocr ?? .auto
        )
        let diff = TreeFormatter.computeDiff(previous: beforeBatchSnapshot, current: updatedSnapshot)

        var sections: [String] = []
        sections.append("BATCH \(allOk ? "OK" : "PARTIAL") (\(completed)/\(request.actions.count) steps):")
        sections.append(stepsLog.joined(separator: "\n"))
        if let diff {
            sections.append(TreeFormatter.formatDiff(diff))
        }
        sections.append(TreeFormatter.formatSnapshot(updatedSnapshot, maxElements: maxEls))

        return BatchActionResult(
            ok: allOk,
            completedCount: completed,
            totalCount: request.actions.count,
            steps: stepsLog,
            diff: diff,
            snapshot: updatedSnapshot,
            compactText: sections.joined(separator: "\n\n")
        )
    }

    public func formatActionText(
        ok: Bool,
        message: String,
        diff: ScreenDiff?,
        snapshot: ScreenSnapshot,
        maxElements: Int
    ) -> String {
        var sections: [String] = []
        sections.append("\(ok ? "OK" : "ERROR"): \(message)")
        if let diff {
            sections.append(TreeFormatter.formatDiff(diff))
        }
        sections.append(TreeFormatter.formatSnapshot(snapshot, maxElements: maxElements))
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Disk Cache (for stateless CLI follow-ups)

    private func loadCachedSnapshot() -> ScreenSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(ScreenSnapshot.self, from: data)
    }

    private func saveCachedSnapshot(_ snapshot: ScreenSnapshot) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
