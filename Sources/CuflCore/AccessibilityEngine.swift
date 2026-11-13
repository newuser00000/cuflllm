import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public struct AXRefBox: @unchecked Sendable, Hashable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    public static func == (lhs: AXRefBox, rhs: AXRefBox) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

public struct CapturedTreeResult: @unchecked Sendable {
    public let snapshot: ScreenSnapshot
    public let elementRefs: [String: AXRefBox]
    public let windowRefs: [String: AXRefBox]
}

public struct CapturedMenuResult: @unchecked Sendable {
    public let items: [MenuItemInfo]
    public let refs: [String: AXRefBox]
}

public enum TreePruner {
    public static func normalizeRole(_ rawRole: String) -> String {
        switch rawRole {
        case "AXButton": return "button"
        case "AXTextField": return "text_field"
        case "AXSecureTextField": return "secure_text_field"
        case "AXTextArea": return "text_area"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXPopUpButton": return "popup"
        case "AXComboBox": return "combo_box"
        case "AXMenuButton": return "menu_button"
        case "AXMenuItem": return "menu_item"
        case "AXLink": return "link"
        case "AXTab", "AXTabGroup": return rawRole == "AXTab" ? "tab" : "tab_group"
        case "AXSlider": return "slider"
        case "AXIncrementor": return "stepper"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXStaticText": return "static_text"
        case "AXHeading": return "heading"
        case "AXImage": return "image"
        case "AXRow": return "row"
        case "AXCell": return "cell"
        case "AXToolbar": return "toolbar"
        case "AXWindow": return "window"
        case "AXSheet": return "sheet"
        case "AXDialog": return "dialog"
        case "AXWebArea": return "web_area"
        case "AXTable": return "table"
        case "AXOutline": return "outline"
        case "AXList": return "list"
        default:
            if rawRole.hasPrefix("AX") {
                return rawRole.dropFirst(2).lowercased()
            }
            return rawRole.lowercased()
        }
    }

    public static let interactiveRawRoles: Set<String> = [
        "AXButton", "AXTextField", "AXSecureTextField", "AXTextArea",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXMenuButton", "AXMenuItem", "AXLink", "AXTab", "AXSlider",
        "AXIncrementor", "AXDisclosureTriangle", "AXSegmentedControl",
        "AXSearchField", "AXSwitch"
    ]

    public static let labelBubbleRoles: Set<String> = [
        "AXButton", "AXLink", "AXTab", "AXMenuItem", "AXRadioButton",
        "AXCheckBox", "AXSwitch", "AXMenuButton", "AXRow", "AXComboBox", "AXPopUpButton"
    ]

    public static let containerRawRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXSplitter",
        "AXLayoutArea", "AXLayoutItem", "AXUnknown", "AXGenericElement",
        "AXSection", "AXListMarker", "AXToolbar", "AXTabGroup"
    ]

    public static func isInteractive(rawRole: String, subrole: String?, actions: [String]) -> Bool {
        if rawRole == "AXStaticText" || rawRole == "AXHeading" || rawRole == "AXImage" {
            return false
        }
        if interactiveRawRoles.contains(rawRole) { return true }
        if let subrole, subrole == "AXSwitch" || subrole == "AXSearchField" || subrole == "AXCloseButton" {
            return true
        }
        let actionable = actions.contains("AXPress") || actions.contains("AXIncrement") || actions.contains("AXConfirm")
        if actionable && !containerRawRoles.contains(rawRole) && rawRole != "AXWindow" && rawRole != "AXWebArea" {
            return true
        }
        return false
    }

    public static func formatActionNames(_ axActions: [String]) -> [String] {
        var mapped: [String] = []
        for action in axActions {
            switch action {
            case "AXPress": mapped.append("press")
            case "AXConfirm": mapped.append("confirm")
            case "AXIncrement": mapped.append("inc")
            case "AXDecrement": mapped.append("dec")
            case "AXShowMenu": mapped.append("menu")
            default: break
            }
        }
        return Array(NSOrderedSet(array: mapped)) as? [String] ?? mapped
    }

    /// Infers missing labels on input controls from adjacent static_text elements (left or just above).
    public static func inferAdjacentLabels(_ nodes: [UIElementNode]) -> [UIElementNode] {
        let inputRoles: Set<String> = [
            "text_field", "secure_text_field", "text_area",
            "combo_box", "popup", "checkbox", "radio", "slider"
        ]
        let textCandidates = nodes.filter { ($0.role == "static_text" || $0.role == "heading") && !$0.label.isEmpty }

        return nodes.map { node in
            guard inputRoles.contains(node.role), node.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return node
            }
            var updated = node
            var bestLabel: String?
            var bestScore = Double.greatestFiniteMagnitude

            for candidate in textCandidates {
                let cBounds = candidate.bounds
                let nBounds = node.bounds

                // Candidate to the left on roughly the same horizontal row
                let verticalOverlap = min(cBounds.maxY, nBounds.maxY) - max(cBounds.y, nBounds.y)
                let horizontalGap = nBounds.x - cBounds.maxX
                if verticalOverlap > -6 && horizontalGap >= -8 && horizontalGap <= 240 {
                    let score = max(0, horizontalGap) + abs(cBounds.centerY - nBounds.centerY) * 1.5
                    if score < bestScore {
                        bestScore = score
                        bestLabel = candidate.label
                    }
                }

                // Candidate directly above and left-aligned
                let verticalGap = nBounds.y - cBounds.maxY
                let xDelta = abs(cBounds.x - nBounds.x)
                if verticalGap >= -4 && verticalGap <= 44 && xDelta <= 60 {
                    let score = verticalGap * 2.0 + xDelta + 15.0
                    if score < bestScore {
                        bestScore = score
                        bestLabel = candidate.label
                    }
                }
            }

            if let bestLabel {
                updated.label = bestLabel
            }
            return updated
        }
    }
}

public final class AccessibilityEngine: @unchecked Sendable {
    private let enhancedLock = NSLock()
    private var enhancedActivatedPids = Set<Int32>()

    private static let enhancedUIBundlePrefixes: [String] = [
        "com.google.Chrome",
        "com.google.antigravity",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.chromium",
        "com.vivaldi",
        "company.thebrowser.Browser",
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.anthropic.claudefordesktop",
        "com.spotify.client",
        "com.openai.chat",
        "com.linear",
        "md.obsidian",
        "notion.id",
        "org.mozilla.firefox",
        "com.electron"
    ]

    public init() {}

    public func isTrusted(prompt: Bool = false) -> Bool {
        if prompt {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    public static func systemFrontmostPid() -> Int32 {
        if AXIsProcessTrusted() {
            let systemWide = AXUIElementCreateSystemWide()
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
               let cfVal = value,
               CFGetTypeID(cfVal) == AXUIElementGetTypeID() {
                let focusedApp = unsafeDowncast(cfVal, to: AXUIElement.self)
                var pid: pid_t = 0
                if AXUIElementGetPid(focusedApp, &pid) == .success, pid > 0 {
                    return pid
                }
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    }

    public func liveFrontmostPid() -> Int32 {
        Self.systemFrontmostPid()
    }

    public func listWindows() -> [WindowInfo] {
        let frontPid = liveFrontmostPid()
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var appCache: [Int32: NSRunningApplication] = [:]
        var results: [WindowInfo] = []
        var idx = 1

        for entry in rawList {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pidNum = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            let pid = pidNum.int32Value
            if cgRect.width <= 40 || cgRect.height <= 40 {
                continue
            }

            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? "Unknown"
            if ownerName == "Window Server" || ownerName == "Dock" {
                continue
            }

            let app: NSRunningApplication?
            if let cached = appCache[pid] {
                app = cached
            } else {
                app = NSRunningApplication(processIdentifier: pid)
                appCache[pid] = app
            }

            let appName = app?.localizedName ?? ownerName
            let bundleId = app?.bundleIdentifier
            let title = entry[kCGWindowName as String] as? String ?? ""
            let windowNumber = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0
            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? true

            let rect = Rect(
                x: Double(cgRect.origin.x),
                y: Double(cgRect.origin.y),
                width: Double(cgRect.size.width),
                height: Double(cgRect.size.height)
            )

            let info = WindowInfo(
                id: "w\(idx)",
                windowNumber: windowNumber,
                pid: pid,
                appName: appName,
                bundleId: bundleId,
                title: title,
                bounds: rect,
                layer: layer,
                isFocused: pid == frontPid && !results.contains(where: { $0.pid == frontPid }),
                isOnScreen: isOnScreen
            )
            results.append(info)
            idx += 1
        }

        return results
    }

    public func captureSnapshot(
        targetWindowId: String? = nil,
        maxElements: Int = 100,
        maxVisitedNodes: Int = 2500,
        maxDepth: Int = 28
    ) -> CapturedTreeResult {
        let windows = listWindows()
        let liveFrontPid = liveFrontmostPid()
        let frontAppObj = liveFrontPid > 0 ? NSRunningApplication(processIdentifier: liveFrontPid) : NSWorkspace.shared.frontmostApplication

        var targetWindow: WindowInfo?
        if let targetWindowId {
            targetWindow = windows.first(where: { $0.id == targetWindowId })
        }
        if targetWindow == nil {
            targetWindow = windows.first(where: { $0.isFocused }) ?? windows.first
        }

        let targetPid = targetWindow?.pid ?? (liveFrontPid > 0 ? liveFrontPid : -1)
        let targetApp = (targetPid > 0 ? NSRunningApplication(processIdentifier: targetPid) : nil) ?? frontAppObj
        let appName = targetWindow?.appName ?? targetApp?.localizedName ?? "Unknown"
        let bundleId = targetWindow?.bundleId ?? targetApp?.bundleIdentifier
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())

        var notes: [String] = []
        if !isTrusted(prompt: false) {
            notes.append("Accessibility permission is not granted. Enable it in System Settings > Privacy & Security > Accessibility.")
            let snapshot = ScreenSnapshot(
                timestamp: timestamp,
                frontApp: appName,
                frontBundleId: bundleId,
                frontPid: targetPid,
                focusedWindow: targetWindow,
                windows: windows,
                elements: [],
                totalVisitedNodes: 0,
                truncated: false,
                notes: notes
            )
            return CapturedTreeResult(snapshot: snapshot, elementRefs: [:], windowRefs: [:])
        }

        guard targetPid > 0 else {
            notes.append("No active application window found.")
            let snapshot = ScreenSnapshot(
                timestamp: timestamp,
                frontApp: appName,
                frontBundleId: bundleId,
                frontPid: targetPid,
                focusedWindow: targetWindow,
                windows: windows,
                elements: [],
                totalVisitedNodes: 0,
                truncated: false,
                notes: notes
            )
            return CapturedTreeResult(snapshot: snapshot, elementRefs: [:], windowRefs: [:])
        }

        let appElement = AXUIElementCreateApplication(targetPid)
        AXUIElementSetMessagingTimeout(appElement, 0.6)

        if let bundleId, Self.enhancedUIBundlePrefixes.contains(where: { bundleId.hasPrefix($0) }) {
            enableEnhancedAccessibility(on: appElement, pid: targetPid, force: false)
        }

        var windowRefs: [String: AXRefBox] = [:]
        if let axWindows = copyElementArray(appElement, kAXWindowsAttribute) {
            for axWin in axWindows {
                let winTitle = copyString(axWin, kAXTitleAttribute) ?? ""
                let winBounds = copyRect(axWin)
                if let matched = windows.first(where: {
                    $0.pid == targetPid &&
                    ($0.title == winTitle || (winBounds != nil && abs($0.bounds.x - winBounds!.x) < 4 && abs($0.bounds.y - winBounds!.y) < 4))
                }) {
                    windowRefs[matched.id] = AXRefBox(axWin)
                }
            }
        }

        var rootElement: AXUIElement?
        if let targetWindow, let matchedRef = windowRefs[targetWindow.id] {
            rootElement = matchedRef.element
        }
        if rootElement == nil {
            rootElement = copyElement(appElement, kAXFocusedWindowAttribute)
                ?? copyElement(appElement, kAXMainWindowAttribute)
                ?? copyElementArray(appElement, kAXWindowsAttribute)?.first
        }

        guard let root = rootElement else {
            notes.append("No accessible window root found for \(appName).")
            let snapshot = ScreenSnapshot(
                timestamp: timestamp,
                frontApp: appName,
                frontBundleId: bundleId,
                frontPid: targetPid,
                focusedWindow: targetWindow,
                windows: windows,
                elements: [],
                totalVisitedNodes: 0,
                truncated: false,
                notes: notes
            )
            return CapturedTreeResult(snapshot: snapshot, elementRefs: [:], windowRefs: windowRefs)
        }

        let rootBounds = copyRect(root) ?? targetWindow?.bounds ?? Rect(x: 0, y: 0, width: 4000, height: 4000)
        if let rootTitle = copyString(root, kAXTitleAttribute), !rootTitle.isEmpty, targetWindow?.title.isEmpty == true {
            targetWindow?.title = rootTitle
        }

        var rawResult = walkTree(
            root: root,
            windowBounds: rootBounds,
            maxElements: maxElements,
            maxVisitedNodes: maxVisitedNodes,
            maxDepth: maxDepth
        )

        // Retry after toggling AXEnhancedUserInterface if a window looked unexpectedly empty (Electron/Chromium wakes up async)
        if rawResult.nodes.count <= 4 {
            enableEnhancedAccessibility(on: appElement, pid: targetPid, force: true)
            Thread.sleep(forTimeInterval: 0.25)
            let retryResult = walkTree(
                root: root,
                windowBounds: rootBounds,
                maxElements: maxElements,
                maxVisitedNodes: maxVisitedNodes,
                maxDepth: maxDepth
            )
            if retryResult.nodes.count > rawResult.nodes.count {
                rawResult = retryResult
            }
        }

        let inferred = TreePruner.inferAdjacentLabels(rawResult.nodes)

        // Re-index ids sequentially after pruning and keep refs aligned
        var finalElements: [UIElementNode] = []
        var finalRefs: [String: AXRefBox] = [:]
        for (idx, var node) in inferred.enumerated() {
            let newId = "e\(idx + 1)"
            if let oldRef = rawResult.refs[node.id] {
                finalRefs[newId] = oldRef
            }
            node.id = newId
            finalElements.append(node)
        }

        if rawResult.truncated {
            notes.append("Tree truncated at \(finalElements.count) elements (visited \(rawResult.visited) AX nodes).")
        }

        let snapshot = ScreenSnapshot(
            timestamp: timestamp,
            frontApp: appName,
            frontBundleId: bundleId,
            frontPid: targetPid,
            focusedWindow: targetWindow,
            windows: windows,
            elements: finalElements,
            totalVisitedNodes: rawResult.visited,
            truncated: rawResult.truncated,
            notes: notes
        )

        return CapturedTreeResult(snapshot: snapshot, elementRefs: finalRefs, windowRefs: windowRefs)
    }

    public func captureMenuBar(pid: Int32? = nil) -> CapturedMenuResult {
        guard isTrusted(prompt: false) else {
            return CapturedMenuResult(items: [], refs: [:])
        }
        let targetPid = pid ?? liveFrontmostPid()
        guard targetPid > 0 else {
            return CapturedMenuResult(items: [], refs: [:])
        }

        let appEl = AXUIElementCreateApplication(targetPid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        guard let menuBar = copyElement(appEl, kAXMenuBarAttribute),
              let topMenus = copyElementArray(menuBar, kAXChildrenAttribute) else {
            return CapturedMenuResult(items: [], refs: [:])
        }

        var items: [MenuItemInfo] = []
        var refs: [String: AXRefBox] = [:]
        var nextId = 1

        for topMenu in topMenus {
            let topTitle = copyString(topMenu, kAXTitleAttribute) ?? ""
            if topTitle.isEmpty || topTitle == "Apple" { continue }

            guard let subContainers = copyElementArray(topMenu, kAXChildrenAttribute) else { continue }
            for container in subContainers {
                guard let subItems = copyElementArray(container, kAXChildrenAttribute) else { continue }
                for item in subItems {
                    let role = copyString(item, kAXRoleAttribute) ?? ""
                    guard role == "AXMenuItem" else { continue }
                    let title = copyString(item, kAXTitleAttribute) ?? ""
                    if title.isEmpty { continue }

                    let enabled = copyBool(item, kAXEnabledAttribute) ?? true
                    let shortcut = formatMenuShortcut(item)
                    let id = "m\(nextId)"
                    nextId += 1

                    let info = MenuItemInfo(
                        id: id,
                        path: "\(topTitle) > \(title)",
                        title: title,
                        shortcut: shortcut,
                        enabled: enabled
                    )
                    items.append(info)
                    refs[id] = AXRefBox(item)
                }
            }
        }

        return CapturedMenuResult(items: items, refs: refs)
    }

    public func resolveWindowElement(windowId: String, windows: [WindowInfo]) -> AXUIElement? {
        guard let win = windows.first(where: { $0.id == windowId }) else { return nil }
        let appEl = AXUIElementCreateApplication(win.pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        guard let axWindows = copyElementArray(appEl, kAXWindowsAttribute) else { return nil }
        for axWin in axWindows {
            let title = copyString(axWin, kAXTitleAttribute) ?? ""
            if !win.title.isEmpty && title == win.title {
                return axWin
            }
            if let rect = copyRect(axWin),
               abs(rect.x - win.bounds.x) < 6 && abs(rect.y - win.bounds.y) < 6 {
                return axWin
            }
        }
        return axWindows.first
    }

    // MARK: - Private Tree Walker

    private struct WalkOutput {
        var nodes: [UIElementNode]
        var refs: [String: AXRefBox]
        var visited: Int
        var truncated: Bool
    }

    private func walkTree(
        root: AXUIElement,
        windowBounds: Rect,
        maxElements: Int,
        maxVisitedNodes: Int,
        maxDepth: Int
    ) -> WalkOutput {
        var nodes: [UIElementNode] = []
        var refs: [String: AXRefBox] = [:]
        var visitedSet = Set<AXRefBox>()
        var skippedDescendants = Set<AXRefBox>()
        var visitedCount = 0
        var truncated = false
        var nextId = 1

        func dfs(_ element: AXUIElement, depth: Int) {
            if truncated { return }
            if depth > maxDepth { return }
            if visitedCount >= maxVisitedNodes || nodes.count >= maxElements {
                truncated = true
                return
            }

            let box = AXRefBox(element)
            if visitedSet.contains(box) { return }
            visitedSet.insert(box)
            visitedCount += 1

            let rawRole = copyString(element, kAXRoleAttribute) ?? ""
            if rawRole == "AXMenuBar" || rawRole == "AXMenu" {
                return
            }

            let subrole = copyString(element, kAXSubroleAttribute)
            let hidden = copyBool(element, "AXHidden") ?? false
            if hidden { return }

            let isContainerWrapper = TreePruner.containerRawRoles.contains(rawRole)
                || rawRole == "AXWebArea"
                || rawRole == "AXWindow"
                || rawRole == "AXScrollArea"

            let bounds = copyRect(element)
            let isVisibleInWindow: Bool
            if depth == 0 {
                isVisibleInWindow = true
            } else if let bounds {
                if bounds.isEmpty || !bounds.intersects(windowBounds) {
                    if !isContainerWrapper { return }
                    isVisibleInWindow = false
                } else {
                    isVisibleInWindow = true
                }
            } else {
                isVisibleInWindow = false
            }

            let actions = copyActions(element)
            let isInteractive = TreePruner.isInteractive(rawRole: rawRole, subrole: subrole, actions: actions)

            var title = copyString(element, kAXTitleAttribute) ?? ""
            let desc = copyString(element, kAXDescriptionAttribute) ?? ""
            let placeholder = copyString(element, kAXPlaceholderValueAttribute) ?? ""
            var value = copyValueString(element, rawRole: rawRole)

            if title.isEmpty {
                title = !desc.isEmpty ? desc : placeholder
            }
            if title.isEmpty, let subrole {
                switch subrole {
                case "AXCloseButton": title = "Close Window"
                case "AXMinimizeButton": title = "Minimize Window"
                case "AXFullScreenButton": title = "Full Screen"
                case "AXZoomButton": title = "Zoom Window"
                default: break
                }
            }

            var childTextNodesToSkip: [AXRefBox] = []
            if TreePruner.labelBubbleRoles.contains(rawRole) || isInteractive {
                let collected = collectChildText(from: element, maxDepth: 3)
                if title.isEmpty && !collected.text.isEmpty {
                    title = collected.text
                    childTextNodesToSkip = collected.boxes
                } else if !collected.entries.isEmpty {
                    let normTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let normVal = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    for entry in collected.entries {
                        let normChild = entry.text.lowercased()
                        if (!normTitle.isEmpty && (normTitle == normChild || normTitle.contains(normChild))) ||
                           (!normVal.isEmpty && (normVal == normChild || normVal.contains(normChild))) {
                            childTextNodesToSkip.append(entry.box)
                        }
                    }
                }
            }

            if rawRole == "AXStaticText" && title.isEmpty, let v = value, !v.isEmpty {
                title = v
                value = nil
            }

            let normalized = TreePruner.normalizeRole(rawRole)
            let shouldSkipThisNode = skippedDescendants.contains(box)
            let hasContent = !title.isEmpty || !(value ?? "").isEmpty

            let shouldKeep: Bool
            if shouldSkipThisNode || depth == 0 || !isVisibleInWindow {
                shouldKeep = false
            } else if isInteractive {
                shouldKeep = true
            } else if rawRole == "AXStaticText" || rawRole == "AXHeading" {
                shouldKeep = hasContent
            } else if rawRole == "AXImage" {
                shouldKeep = !desc.isEmpty || !title.isEmpty
            } else if rawRole == "AXCell" || rawRole == "AXRow" {
                shouldKeep = hasContent || actions.contains("AXPress")
            } else if TreePruner.containerRawRoles.contains(rawRole) {
                shouldKeep = false
            } else {
                shouldKeep = isInteractive || (!desc.isEmpty && rawRole != "AXWindow")
            }

            if shouldKeep, let effectiveBounds = bounds ?? (depth == 0 ? windowBounds : nil) {
                let elId = "e\(nextId)"
                nextId += 1

                let enabled = copyBool(element, kAXEnabledAttribute) ?? true
                let focused = copyBool(element, kAXFocusedAttribute) ?? false
                let selected = copyBool(element, kAXSelectedAttribute)
                let checked: Bool?
                if rawRole == "AXCheckBox" || rawRole == "AXSwitch" {
                    checked = copyChecked(element)
                } else {
                    checked = nil
                }

                let node = UIElementNode(
                    id: elId,
                    role: normalized,
                    rawRole: rawRole,
                    label: title,
                    value: value,
                    bounds: effectiveBounds,
                    enabled: enabled,
                    focused: focused,
                    selected: selected,
                    checked: checked,
                    actions: isInteractive ? TreePruner.formatActionNames(actions) : [],
                    isInteractive: isInteractive,
                    source: .ax,
                    depth: depth
                )
                nodes.append(node)
                refs[elId] = box
                for skipBox in childTextNodesToSkip {
                    skippedDescendants.insert(skipBox)
                }
            }

            guard let children = copyElementArray(element, kAXChildrenAttribute) else { return }
            for child in children {
                if truncated { break }
                dfs(child, depth: depth + 1)
            }
        }

        dfs(root, depth: 0)
        return WalkOutput(nodes: nodes, refs: refs, visited: visitedCount, truncated: truncated)
    }

    private func collectChildText(from element: AXUIElement, maxDepth: Int) -> (text: String, boxes: [AXRefBox], entries: [(text: String, box: AXRefBox)]) {
        var entries: [(text: String, box: AXRefBox)] = []
        var seen = Set<AXRefBox>()

        func recurse(_ node: AXUIElement, depth: Int) {
            if depth > maxDepth || entries.count >= 6 { return }
            guard let children = copyElementArray(node, kAXChildrenAttribute) else { return }
            for child in children {
                let box = AXRefBox(child)
                if seen.contains(box) { continue }
                seen.insert(box)

                let role = copyString(child, kAXRoleAttribute) ?? ""
                if role == "AXStaticText" || role == "AXHeading" {
                    let text = (copyString(child, kAXValueAttribute) ?? copyString(child, kAXTitleAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        entries.append((text, box))
                    }
                } else {
                    let desc = (copyString(child, kAXDescriptionAttribute) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !desc.isEmpty && role == "AXImage" {
                        entries.append((desc, box))
                    }
                    recurse(child, depth: depth + 1)
                }
            }
        }

        recurse(element, depth: 1)
        let text = entries.map(\.text).joined(separator: " ")
        let boxes = entries.map(\.box)
        return (text, boxes, entries)
    }

    private func enableEnhancedAccessibility(on appElement: AXUIElement, pid: Int32, force: Bool) {
        enhancedLock.lock()
        let alreadyEnabled = enhancedActivatedPids.contains(pid)
        if !alreadyEnabled || force {
            enhancedActivatedPids.insert(pid)
        }
        enhancedLock.unlock()

        guard !alreadyEnabled || force else { return }
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: - CoreFoundation Attribute Helpers

    private func copyAttribute(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private func copyElement(_ element: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let ref = copyAttribute(element, attr) else { return nil }
        guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(ref, to: AXUIElement.self)
    }

    private func copyElementArray(_ element: AXUIElement, _ attr: String) -> [AXUIElement]? {
        guard let ref = copyAttribute(element, attr) as? [AnyObject] else { return nil }
        return ref.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(item, to: AXUIElement.self)
        }
    }

    private func copyString(_ element: AXUIElement, _ attr: String) -> String? {
        guard let ref = copyAttribute(element, attr) else { return nil }
        if let str = ref as? String {
            return str
        }
        if let attrStr = ref as? NSAttributedString {
            return attrStr.string
        }
        if let num = ref as? NSNumber {
            return num.stringValue
        }
        return nil
    }

    private func copyValueString(_ element: AXUIElement, rawRole: String) -> String? {
        if rawRole == "AXSecureTextField" {
            return "[REDACTED]"
        }
        return copyString(element, kAXValueAttribute)
    }

    private func copyBool(_ element: AXUIElement, _ attr: String) -> Bool? {
        guard let ref = copyAttribute(element, attr) else { return nil }
        if let b = ref as? Bool {
            return b
        }
        if let n = ref as? NSNumber {
            return n.boolValue
        }
        return nil
    }

    private func copyChecked(_ element: AXUIElement) -> Bool? {
        guard let ref = copyAttribute(element, kAXValueAttribute) else { return nil }
        if let n = ref as? NSNumber {
            return n.intValue != 0
        }
        return nil
    }

    private func copyRect(_ element: AXUIElement) -> Rect? {
        guard let posRef = copyAttribute(element, kAXPositionAttribute),
              let sizeRef = copyAttribute(element, kAXSizeAttribute),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }

        let posVal = unsafeDowncast(posRef, to: AXValue.self)
        let sizeVal = unsafeDowncast(sizeRef, to: AXValue.self)
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posVal, .cgPoint, &pt),
              AXValueGetValue(sizeVal, .cgSize, &sz) else {
            return nil
        }
        return Rect(x: Double(pt.x), y: Double(pt.y), width: Double(sz.width), height: Double(sz.height))
    }

    private func copyActions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyActionNames(element, &names)
        guard err == .success, let arr = names as? [String] else {
            return []
        }
        return arr
    }

    private func formatMenuShortcut(_ item: AXUIElement) -> String? {
        guard let char = copyString(item, kAXMenuItemCmdCharAttribute), !char.isEmpty else {
            return nil
        }
        let modRaw = (copyAttribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
        // kAXMenuItemCmdModifiersAttribute bitmask: bit 0=Shift(1), 1=Option(2), 2=Control(4), 3=NoCmd(8)
        var parts: [String] = []
        if (modRaw & 4) != 0 { parts.append("Ctrl") }
        if (modRaw & 2) != 0 { parts.append("Opt") }
        if (modRaw & 1) != 0 { parts.append("Shift") }
        if (modRaw & 8) == 0 { parts.append("Cmd") }
        parts.append(char.uppercased())
        return parts.joined(separator: "+")
    }
}
